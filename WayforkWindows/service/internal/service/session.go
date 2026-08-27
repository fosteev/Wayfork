package service

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"wayfork/service/internal/core"
)

const (
	openVPNStopTimeout       = 5 * time.Second
	managementConnectTimeout = 10 * time.Second
)

// TunnelEvent is what a session reports to the supervisor.
type TunnelEvent struct {
	ID    string
	State *core.TunnelState
	// DiscoveredDNS is set for a PUSH_REPLY (possibly empty).
	DiscoveredDNS []string
}

// OpenVPNSession is one OpenVPN tunnel: the process, its management channel, restarts
// with backoff. All decisions live in core.OpenVPNSessionReducer; this type only
// performs the effects (docs/design/04-tunnels.md, "Runtime (daemon)").
type OpenVPNSession struct {
	Runtime core.OpenVPNRuntime
	DiffKey string

	logLevel core.LogLevel
	env      Environment
	hub      *Hub
	deps     Dependencies
	onEvent  func(TunnelEvent)

	mu                 sync.Mutex
	reducer            *core.OpenVPNSessionReducer
	backoff            core.BackoffPolicy
	autoReconnect      bool
	process            Process
	management         *ManagementClient
	generation         int
	stopping           bool
	restartTimer       *time.Timer
	connectCancel      context.CancelFunc
	manualRestart      bool
	managementPort     int
	managementPassword string
}

// NewOpenVPNSession prepares a session; Start spawns it.
func NewOpenVPNSession(runtime core.OpenVPNRuntime, logLevel core.LogLevel, autoReconnect bool, env Environment, hub *Hub, deps Dependencies, onEvent func(TunnelEvent)) *OpenVPNSession {
	return &OpenVPNSession{
		Runtime: runtime, DiffKey: core.OpenVPNDiffKey(runtime, logLevel),
		logLevel: logLevel, env: env, hub: hub, deps: deps, onEvent: onEvent,
		reducer: core.NewOpenVPNSessionReducer(core.ReducerContextFor(runtime)), autoReconnect: autoReconnect,
	}
}

// ID is the tunnel id.
func (s *OpenVPNSession) ID() string { return s.Runtime.ID }

// State is the reducer's TunnelState.
func (s *OpenVPNSession) State() core.TunnelState {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reducer.State()
}

func (s *OpenVPNSession) source() string { return "openvpn:" + s.Runtime.ID }

func (s *OpenVPNSession) log(level core.LogLevel, message string) {
	s.hub.PostFrom(s.source(), level, message)
}

// Start writes the config and the management password file and spawns the first
// attempt. It fails only for problems no retry would fix.
func (s *OpenVPNSession) Start() *core.DaemonError {
	if !s.env.DevMode && s.deps.Binaries != nil {
		if err := s.deps.Binaries.Validate(s.env.OpenVPNPath()); err != nil {
			return err
		}
	}
	if err := core.WriteStringAtomic(s.env.RunPath(core.OpenVPNConfig(s.Runtime.ID)), s.Runtime.Config, 0o600); err != nil {
		return core.ErrInternal("cannot write OpenVPN config: " + err.Error())
	}
	password, err := core.RandomSecret()
	if err != nil {
		return core.ErrInternal(err.Error())
	}
	if err := core.WriteStringAtomic(s.env.RunPath(core.ManagementPasswordFile(s.Runtime.ID)), password+"\n", 0o600); err != nil {
		return core.ErrInternal("cannot write the management password: " + err.Error())
	}
	port, err := core.FreeLoopbackPort()
	if err != nil {
		return core.ErrInternal(err.Error())
	}
	s.mu.Lock()
	s.stopping = false
	s.managementPort = int(port)
	s.managementPassword = password
	attempt := s.backoff.NextAttempt()
	s.mu.Unlock()
	s.spawn(attempt)
	return nil
}

// Stop terminates the process and removes the session's files.
func (s *OpenVPNSession) Stop() {
	s.mu.Lock()
	s.stopping = true
	if s.restartTimer != nil {
		s.restartTimer.Stop()
		s.restartTimer = nil
	}
	if s.connectCancel != nil {
		s.connectCancel()
		s.connectCancel = nil
	}
	process := s.process
	management := s.management
	s.mu.Unlock()
	if process != nil {
		s.log(core.LogLevelInfo, fmt.Sprintf("stopping openvpn (pid %d)", process.PID()))
		if management != nil {
			_ = management.Send(core.ManagementSignalTerm)
		}
		process.Terminate(openVPNStopTimeout)
	}
	s.mu.Lock()
	if s.management != nil {
		s.management.Close()
		s.management = nil
	}
	s.process = nil
	s.mu.Unlock()
	for _, name := range []string{core.OpenVPNConfig(s.Runtime.ID), core.ManagementPasswordFile(s.Runtime.ID)} {
		os.Remove(s.env.RunPath(name))
	}
}

// Reconnect (user-initiated): kill the current attempt, reset backoff, start again right
// away — also for permanently failed tunnels and with autoReconnect off.
func (s *OpenVPNSession) Reconnect() {
	s.mu.Lock()
	if s.stopping {
		s.mu.Unlock()
		return
	}
	if s.restartTimer != nil {
		s.restartTimer.Stop()
		s.restartTimer = nil
	}
	s.backoff.Reset()
	process := s.process
	management := s.management
	if process != nil {
		// The exit lands in handle after Terminate returns; the exit effect respawns.
		s.manualRestart = true
	}
	s.mu.Unlock()
	s.log(core.LogLevelInfo, "reconnect requested")
	if process == nil {
		s.spawn(1)
		return
	}
	if management != nil {
		_ = management.Send(core.ManagementSignalTerm)
	}
	process.Terminate(openVPNStopTimeout)
}

// SetAutoReconnect follows the plan's autoReconnect.
func (s *OpenVPNSession) SetAutoReconnect(enabled bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.autoReconnect = enabled
}

func (s *OpenVPNSession) spawn(attempt int) {
	s.mu.Lock()
	s.generation++
	generation := s.generation
	port := s.managementPort
	password := s.managementPassword
	s.mu.Unlock()
	process, err := s.deps.Processes.Start(ProcessSpec{
		Executable: s.env.OpenVPNPath(),
		Args:       core.OpenVPNArguments(s.Runtime, s.env.Layout, port, s.logLevel),
		WorkingDir: s.env.Layout.Dir,
	}, ProcessHandlers{
		OnLine: func(line string) { s.handle(generation, core.ProcessLine(line)) },
		OnExit: func(code uint32) { s.handle(generation, core.ProcessExited(code)) },
	})
	if err != nil {
		s.log(core.LogLevelError, "spawn failed: "+err.Error())
		s.handle(generation, core.ProcessExited(1))
		return
	}
	s.mu.Lock()
	s.process = process
	ctx, cancel := context.WithTimeout(context.Background(), managementConnectTimeout)
	s.connectCancel = cancel
	s.mu.Unlock()
	s.handle(generation, core.ProcessStarted(attempt))
	go s.connectManagement(ctx, generation, port, password)
}

func (s *OpenVPNSession) connectManagement(ctx context.Context, generation int, port int, password string) {
	client, err := ConnectManagement(ctx, fmt.Sprintf("127.0.0.1:%d", port), password, ManagementHandlers{
		OnLine:  func(line string) { s.handle(generation, core.ManagementInput(core.ParseManagementLine(line))) },
		OnClose: func(error) { s.handle(generation, core.ManagementClosed()) },
	})
	s.mu.Lock()
	current := generation == s.generation && s.process != nil
	process := s.process
	if err == nil && current {
		s.management = client
	}
	s.mu.Unlock()
	if err != nil {
		if current {
			s.log(core.LogLevelError, "management channel unavailable: "+err.Error())
			process.Terminate(openVPNStopTimeout)
		}
		return
	}
	if !current {
		client.Close()
		return
	}
	s.handle(generation, core.ManagementConnected())
}

// handle feeds the reducer and performs its effects, in order, under the session lock.
func (s *OpenVPNSession) handle(generation int, input core.ReducerInput) {
	s.mu.Lock()
	if generation != s.generation {
		s.mu.Unlock()
		return
	}
	before := s.reducer.State()
	effects := s.reducer.Handle(input, s.deps.Clock.Now())
	var pending []func()
	for _, effect := range effects {
		if deferred := s.perform(effect); deferred != nil {
			pending = append(pending, deferred)
		}
	}
	after := s.reducer.State()
	s.mu.Unlock()
	for _, deferred := range pending {
		deferred()
	}
	if after.Kind != before.Kind || after.Reason != before.Reason || after.Attempt != before.Attempt ||
		after.IP != before.IP || after.NextIn != before.NextIn || after.Permanent != before.Permanent {
		state := after
		s.onEvent(TunnelEvent{ID: s.Runtime.ID, State: &state})
	}
}

// perform runs one effect with the lock held; anything that must not run under the lock
// (callbacks into the supervisor, blocking route calls) is returned to run afterwards.
func (s *OpenVPNSession) perform(effect core.ReducerEffect) func() {
	switch effect.Kind {
	case core.EffectSend:
		if s.management != nil {
			if err := s.management.Send(effect.Command); err != nil {
				return func() { s.log(core.LogLevelWarning, "management write failed: "+err.Error()) }
			}
		}
	case core.EffectLog:
		level, message := effect.Level, effect.Message
		return func() { s.log(level, message) }
	case core.EffectAddScopedRoute:
		adapter, gateway := effect.Interface, effect.Gateway
		return func() {
			if err := s.deps.Network.AddScopedDefault(adapter, gateway); err != nil {
				s.log(core.LogLevelWarning, "route add failed: "+err.Error())
			}
		}
	case core.EffectDeleteScopedRoute:
		adapter := effect.Interface
		return func() {
			if err := s.deps.Network.DeleteScopedDefault(adapter); err != nil {
				s.log(core.LogLevelDebug, "route delete: "+err.Error())
			}
		}
	case core.EffectDiscoveredDNS:
		servers := effect.Servers
		return func() { s.onEvent(TunnelEvent{ID: s.Runtime.ID, DiscoveredDNS: servers}) }
	case core.EffectExited:
		return s.exited(effect.Exit)
	}
	return nil
}

// exited handles the process going away (lock held); returns the follow-up to run
// without the lock.
func (s *OpenVPNSession) exited(disposition core.ExitDisposition) func() {
	uptime := time.Duration(0)
	if s.process != nil {
		uptime = s.deps.Clock.Now().Sub(s.process.StartedAt())
	}
	if s.management != nil {
		s.management.Close()
		s.management = nil
	}
	if s.connectCancel != nil {
		s.connectCancel()
		s.connectCancel = nil
	}
	s.process = nil
	if s.stopping {
		return nil
	}
	if s.manualRestart {
		s.manualRestart = false
		return func() { s.spawn(1) }
	}
	if disposition.Permanent {
		return nil
	}
	if !s.autoReconnect {
		effects := s.reducer.Handle(core.RetriesDisabled(), s.deps.Clock.Now())
		state := s.reducer.State()
		return func() {
			for _, effect := range effects {
				if effect.Kind == core.EffectLog {
					s.log(effect.Level, effect.Message)
				}
			}
			s.onEvent(TunnelEvent{ID: s.Runtime.ID, State: &state})
		}
	}
	delay := s.backoff.NextDelay(uptime)
	attempt := s.backoff.NextAttempt()
	effects := s.reducer.Handle(core.RestartScheduled(attempt, delay), s.deps.Clock.Now())
	state := s.reducer.State()
	s.restartTimer = time.AfterFunc(delay, func() { s.respawnAfterBackoff(attempt) })
	return func() {
		for _, effect := range effects {
			if effect.Kind == core.EffectLog {
				s.log(effect.Level, effect.Message)
			}
		}
		s.onEvent(TunnelEvent{ID: s.Runtime.ID, State: &state})
	}
}

func (s *OpenVPNSession) respawnAfterBackoff(attempt int) {
	s.mu.Lock()
	skip := s.stopping || s.process != nil
	s.restartTimer = nil
	s.mu.Unlock()
	if skip {
		return
	}
	s.spawn(attempt)
}
