package service

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"wayfork/service/internal/core"
	"wayfork/service/internal/ipc"
)

// Supervisor is the single owner of every child process. Pipe handlers call it;
// Apply/Stop/Reconnect run one at a time, status queries do not wait for them
// (docs/design/05-daemon.md, "Supervisor"; docs/design/00-architecture.md, "Reconcile").
type Supervisor struct {
	env      Environment
	hub      *Hub
	deps     Dependencies
	engine   *SingBoxEngine
	sampler  *TrafficSampler
	resolver *ResolverOverride

	// opMu serializes apply/stop/reconnect; mu guards the fields below.
	opMu            sync.Mutex
	mu              sync.Mutex
	sessions        map[string]*OpenVPNSession
	status          core.RuntimeStatus
	plan            *core.RuntimePlan
	applyGeneration atomic.Int64
	versionsOnce    sync.Once
	singBoxVersion  string
	openVPNVersion  string
}

// NewSupervisor wires the engine, the sampler and the resolver override to the hub.
func NewSupervisor(env Environment, hub *Hub, deps Dependencies) *Supervisor {
	if deps.Clock == nil {
		deps.Clock = SystemClock
	}
	s := &Supervisor{env: env, hub: hub, deps: deps, sessions: map[string]*OpenVPNSession{}, status: core.StoppedStatus()}
	s.sampler = NewTrafficSampler(hub, deps.Clock)
	s.engine = NewSingBoxEngine(env, hub, deps, s.sampler, s.handleEngine)
	s.resolver = NewResolverOverride(env, hub, deps.Resolver, deps.Clock, s.handleResolver)
	return s
}

var _ ipc.Handler = (*Supervisor)(nil)

// Bootstrap (service start): restore a leftover NRPT record first, wipe run\, remove
// stray routes and addresses, then idle (docs/design/08-windows.md, "Lifecycle").
func (s *Supervisor) Bootstrap(ctx context.Context) {
	s.resolver.RestoreLeftover(ctx)
	s.wipeRunDirectory()
	if err := s.deps.Network.CleanupAdapters(ctx); err != nil {
		s.hub.Log(core.LogLevelWarning, "startup cleanup: "+err.Error())
	}
	s.updateStatus(func(status *core.RuntimeStatus) { *status = core.StoppedStatus() })
	s.hub.Log(core.LogLevelInfo, fmt.Sprintf("service %s ready (%s)", s.env.Version, s.env.InstallDir))
	if s.env.DevMode {
		s.hub.Log(core.LogLevelWarning, "developer mode: binaries and clients are not trust-checked")
	}
}

func (s *Supervisor) wipeRunDirectory() {
	entries, err := os.ReadDir(s.env.Layout.Dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if core.IsTransient(entry.Name()) {
			os.Remove(s.env.RunPath(entry.Name()))
		}
	}
}

// updateStatus edits a copy of the status under the lock and publishes it.
func (s *Supervisor) updateStatus(edit func(status *core.RuntimeStatus)) {
	s.mu.Lock()
	status := copyStatus(s.status)
	edit(&status)
	s.status = status
	s.mu.Unlock()
	s.hub.SetStatus(status)
}

func copyStatus(status core.RuntimeStatus) core.RuntimeStatus {
	copied := status
	copied.Tunnels = make(map[string]core.TunnelState, len(status.Tunnels))
	for id, state := range status.Tunnels {
		copied.Tunnels[id] = state
	}
	copied.DiscoveredDNS = make(map[string][]string, len(status.DiscoveredDNS))
	for id, servers := range status.DiscoveredDNS {
		copied.DiscoveredDNS[id] = append([]string(nil), servers...)
	}
	return copied
}

func (s *Supervisor) handleEngine(state core.EngineState) {
	s.updateStatus(func(status *core.RuntimeStatus) { status.Engine = state })
	s.resolver.SetEngineRunning(state.IsRunning())
}

func (s *Supervisor) handleResolver(state core.ResolverOverrideState) {
	s.updateStatus(func(status *core.RuntimeStatus) { status.ResolverOverride = state })
}

func (s *Supervisor) handleTunnel(event TunnelEvent) {
	s.updateStatus(func(status *core.RuntimeStatus) {
		if _, known := s.sessions[event.ID]; !known {
			return
		}
		if event.State != nil {
			status.Tunnels[event.ID] = *event.State
		}
		if event.DiscoveredDNS != nil {
			status.DiscoveredDNS[event.ID] = event.DiscoveredDNS
		}
	})
}

// GetInfo implements ipc.Handler.
func (s *Supervisor) GetInfo(ctx context.Context) core.DaemonInfo {
	s.versionsOnce.Do(func() {
		s.singBoxVersion = s.binaryVersion(ctx, s.env.SingBoxPath(), core.SingBoxVersionArguments)
		s.openVPNVersion = s.binaryVersion(ctx, s.env.OpenVPNPath(), []string{"--version"})
	})
	return core.DaemonInfo{
		Version: s.env.Version, InstallPath: s.env.InstallDir, BuildID: s.env.BuildID,
		SingBoxVersion: s.singBoxVersion, OpenVPNVersion: s.openVPNVersion,
	}
}

func (s *Supervisor) binaryVersion(ctx context.Context, path string, args []string) string {
	if !s.env.DevMode && s.deps.Binaries != nil {
		if err := s.deps.Binaries.Validate(path); err != nil {
			return "untrusted"
		}
	}
	runCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	result, err := s.deps.Processes.Run(runCtx, ProcessSpec{Executable: path, Args: args})
	if err != nil || len(result.Lines) == 0 {
		return "unavailable"
	}
	// "sing-box version 1.13.19" / "OpenVPN 2.7.6 x86_64-w64-mingw32 […]"
	for _, word := range strings.Fields(result.Lines[0]) {
		if word[0] >= '0' && word[0] <= '9' {
			return word
		}
	}
	return result.Lines[0]
}

// GetStatus implements ipc.Handler.
func (s *Supervisor) GetStatus(context.Context) core.RuntimeStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	return copyStatus(s.status)
}

// Subscribe implements ipc.Handler.
func (s *Supervisor) Subscribe(_ context.Context, sink ipc.Sink) core.ApplyResult {
	s.hub.Subscribe(sink)
	return core.ApplySuccess()
}

// Unsubscribe implements ipc.Handler.
func (s *Supervisor) Unsubscribe(sink ipc.Sink) { s.hub.Unsubscribe(sink) }

// Apply implements ipc.Handler: validates, then reconciles — one at a time; an apply
// still waiting when a newer one arrives is skipped (latest wins) and answers ok.
func (s *Supervisor) Apply(ctx context.Context, plan core.RuntimePlan) core.ApplyResult {
	if err := core.ValidatePlan(plan); err != nil {
		return core.ApplyFailure(err)
	}
	generation := s.applyGeneration.Add(1)
	s.opMu.Lock()
	defer s.opMu.Unlock()
	if generation != s.applyGeneration.Load() {
		return core.ApplySuccess()
	}
	return s.performApply(ctx, plan)
}

// Stop implements ipc.Handler.
func (s *Supervisor) Stop(context.Context) core.ApplyResult {
	s.applyGeneration.Add(1)
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.performStop()
	return core.ApplySuccess()
}

// Reconnect implements ipc.Handler.
func (s *Supervisor) Reconnect(_ context.Context, id string) core.ApplyResult {
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.mu.Lock()
	session := s.sessions[id]
	s.mu.Unlock()
	if session == nil {
		return core.ApplyFailure(core.ErrTunnelNotFound(id))
	}
	session.Reconnect()
	return core.ApplySuccess()
}

// CollectDiagnostics implements ipc.Handler.
func (s *Supervisor) CollectDiagnostics(ctx context.Context) core.DaemonDiagnostics {
	tails := s.hub.Tails(200)
	daemonTail := tails[DaemonSource]
	if daemonTail == nil {
		daemonTail = []string{}
	}
	delete(tails, DaemonSource)
	return core.DaemonDiagnostics{
		DaemonLogTail: daemonTail, ChildLogTails: tails,
		RunDirectoryListing: RunListing(s.env.Layout.Dir),
		Routes:              s.deps.Network.Diagnostics(ctx),
	}
}

func (s *Supervisor) validateBinaries() *core.DaemonError {
	if s.env.DevMode || s.deps.Binaries == nil {
		return nil
	}
	for _, path := range []string{s.env.SingBoxPath(), s.env.OpenVPNPath()} {
		if err := s.deps.Binaries.Validate(path); err != nil {
			s.hub.Log(core.LogLevelError, "refusing to run untrusted binary "+path)
			return err
		}
	}
	return nil
}

func (s *Supervisor) performApply(ctx context.Context, plan core.RuntimePlan) core.ApplyResult {
	if err := s.validateBinaries(); err != nil {
		return core.ApplyFailure(err)
	}
	adapters := make([]string, 0, len(plan.OpenVPN))
	for _, runtime := range plan.OpenVPN {
		adapters = append(adapters, runtime.Interface)
	}
	if err := s.deps.Network.EnsureAdapters(ctx, adapters); err != nil {
		s.hub.Log(core.LogLevelError, "adapters: "+err.Error())
		return core.ApplyFailure(core.ErrInternal("cannot prepare adapters: " + err.Error()))
	}

	s.mu.Lock()
	keys := make(map[string]string, len(s.sessions))
	for id, session := range s.sessions {
		keys[id] = session.DiffKey
	}
	s.mu.Unlock()
	current := core.ReconcileState{
		SingBoxRunning: s.engine.IsRunning(), SingBoxConfigHash: s.engine.ConfigHash(),
		RuleSets: s.engine.RuleSets(), OpenVPN: keys,
	}
	actions := core.PlanReconcile(current, plan)
	s.hub.Log(core.LogLevelInfo, fmt.Sprintf("apply: sing-box %s, stop %d, start %d tunnel(s)",
		actions.SingBox.Kind, len(actions.StopOpenVPN), len(actions.StartOpenVPN)))

	s.stopSessions(actions.StopOpenVPN)
	s.engine.DeleteRuleSets(actions.StaleRuleSets)

	var failure *core.DaemonError
	switch actions.SingBox.Kind {
	case core.SingBoxNone:
	case core.SingBoxRewriteRuleSets:
		changed := map[string]string{}
		for _, name := range actions.SingBox.Files {
			changed[name] = plan.SingBox.RuleSets[name]
		}
		if err := s.engine.WriteRuleSets(changed); err != nil {
			failure = err
			break
		}
		s.hub.Log(core.LogLevelInfo, fmt.Sprintf("rule-sets updated in place (%d file(s))", len(changed)))
		var selectors *core.RuleSetSelectors
		if change, ok := core.RuleSetChange(current.RuleSets, plan.SingBox.RuleSets, actions.SingBox.Files); ok {
			selectors = &change
		}
		s.engine.CutConnections(selectors)
	case core.SingBoxStart, core.SingBoxRestart:
		if err := s.engine.WriteRuleSets(plan.SingBox.RuleSets); err != nil {
			failure = err
			break
		}
		if err := s.engine.Check(ctx, plan.SingBox.Config, plan.SingBox.ConfigHash); err != nil {
			failure = err
			break
		}
		if actions.SingBox.Kind == core.SingBoxRestart {
			s.engine.Stop()
		}
		if err := s.engine.Start(ctx); err != nil {
			failure = err
		}
	}
	if failure != nil {
		s.hub.Log(core.LogLevelError, "sing-box: "+failure.Error())
	}
	s.resolver.SetDesired(plan.OverrideSystemDNS)

	for _, runtime := range plan.OpenVPN {
		if !contains(actions.StartOpenVPN, runtime.ID) {
			continue
		}
		session := NewOpenVPNSession(runtime, plan.LogLevel, plan.AutoReconnect, s.env, s.hub, s.deps, s.handleTunnel)
		s.mu.Lock()
		s.sessions[runtime.ID] = session
		s.mu.Unlock()
		s.updateStatus(func(status *core.RuntimeStatus) { status.Tunnels[runtime.ID] = core.NewTunnelConnecting(1) })
		if err := session.Start(); err != nil {
			s.updateStatus(func(status *core.RuntimeStatus) {
				status.Tunnels[runtime.ID] = core.NewTunnelFailed("ovpn.startFailed", true)
			})
			s.hub.Log(core.LogLevelError, "openvpn "+runtime.ID+": "+err.Error())
		}
	}
	s.mu.Lock()
	sessions := make([]*OpenVPNSession, 0, len(s.sessions))
	for _, session := range s.sessions {
		sessions = append(sessions, session)
	}
	s.plan = &plan
	s.mu.Unlock()
	for _, session := range sessions {
		session.SetAutoReconnect(plan.AutoReconnect)
	}
	s.updateStatus(func(status *core.RuntimeStatus) { status.PlanHash = plan.PlanHash() })
	if failure != nil {
		return core.ApplyFailure(failure)
	}
	return core.ApplySuccess()
}

func (s *Supervisor) performStop() {
	s.hub.Log(core.LogLevelInfo, "stop requested")
	s.engine.Stop()
	s.resolver.SetDesired(false)
	s.sampler.Reset()
	s.mu.Lock()
	ids := make([]string, 0, len(s.sessions))
	for id := range s.sessions {
		ids = append(ids, id)
	}
	s.mu.Unlock()
	sort.Strings(ids)
	s.stopSessions(ids)
	s.wipeRunDirectory()
	s.mu.Lock()
	s.plan = nil
	s.mu.Unlock()
	s.updateStatus(func(status *core.RuntimeStatus) {
		*status = core.StoppedStatus()
		status.ResolverOverride = s.resolver.State()
	})
	s.hub.Log(core.LogLevelInfo, "stopped")
}

func (s *Supervisor) stopSessions(ids []string) {
	s.mu.Lock()
	stopping := make([]*OpenVPNSession, 0, len(ids))
	for _, id := range ids {
		if session, ok := s.sessions[id]; ok {
			stopping = append(stopping, session)
			delete(s.sessions, id)
		}
	}
	s.mu.Unlock()
	if len(ids) > 0 {
		s.updateStatus(func(status *core.RuntimeStatus) {
			for _, id := range ids {
				delete(status.Tunnels, id)
				delete(status.DiscoveredDNS, id)
			}
		})
	}
	var wait sync.WaitGroup
	for _, session := range stopping {
		wait.Add(1)
		go func(session *OpenVPNSession) {
			defer wait.Done()
			session.Stop()
		}(session)
	}
	wait.Wait()
}

// Shutdown (service stop, Ctrl-C): bring everything down so no child outlives the
// service, restoring networking first.
func (s *Supervisor) Shutdown(ctx context.Context) {
	s.Stop(ctx)
	s.hub.Close()
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}
