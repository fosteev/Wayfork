package service

import (
	"context"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"wayfork/service/internal/core"
)

const (
	// SingBoxSource is the log source of sing-box's output.
	SingBoxSource = "sing-box"
	// singBoxStartupGrace: how long start waits for the "started" line before checking.
	// It keeps a TUN a previous process has not finished tearing down from passing the
	// check for the new one.
	singBoxStartupGrace = 3 * time.Second
	// singBoxStartupPoll: how often the startup check repeats while the TUN comes up.
	singBoxStartupPoll = 500 * time.Millisecond
	// singBoxStartupTimeout: how long from the spawn the check may keep failing before the
	// attempt is given up. A wintun adapter re-created after a crash needs seconds, and
	// the route table lags it by a beat (H1, docs/design/03-routing.md).
	singBoxStartupTimeout = 12 * time.Second
	// singBoxStartAttempts: a start that never verifies is retried once before startFailed.
	singBoxStartAttempts = 2
	// singBoxStopTimeout: sing-box has no graceful stop when detached on Windows; the
	// TUN adapter vanishes with the process (spike S7), so the wait is short.
	singBoxStopTimeout  = 500 * time.Millisecond
	singBoxLogTailLines = 20
	// ruleSetReloadGrace: how long after a rule-set rewrite sing-box has reloaded it.
	ruleSetReloadGrace = time.Second
	// StartupProbeAddress is the public address whose route must point at the TUN.
	StartupProbeAddress = "1.1.1.1"
	// EngineStartFailed is the engine failure reason code.
	EngineStartFailed = "singbox.startFailed"
)

// SingBoxEngine owns the sing-box child: config/rule-set files, `sing-box check`, start
// with startup verification, crash counting and backoff restarts
// (docs/design/03-routing.md "Startup verification", docs/design/05-daemon.md "Supervisor").
type SingBoxEngine struct {
	env     Environment
	hub     *Hub
	deps    Dependencies
	sampler *TrafficSampler
	closer  *ConnectionCloser
	onState func(core.EngineState)

	mu sync.Mutex
	// Hash of the config the running (or last started) process was started with.
	configHash string
	// Rule-set files currently on disk.
	ruleSets        map[string]string
	checkedHash     string
	checkedEndpoint *core.ClashAPIEndpoint
	endpoint        *core.ClashAPIEndpoint
	process         Process
	generation      int
	stopping        bool
	crashes         core.CrashCounter
	backoff         core.BackoffPolicy
	restartTimer    *time.Timer
	recent          []string
	state           core.EngineState
	// startupPending: Start is still verifying; an exit belongs to it, not to handleExit.
	startupPending bool
	// aborted: AbortStartup was called while a start was verifying.
	aborted bool
	// Startup verification timings; constants by default, milliseconds in the tests.
	startupGrace   time.Duration
	startupPoll    time.Duration
	startupTimeout time.Duration
	startAttempts  int
}

// NewSingBoxEngine makes a stopped engine.
func NewSingBoxEngine(env Environment, hub *Hub, deps Dependencies, sampler *TrafficSampler, onState func(core.EngineState)) *SingBoxEngine {
	return &SingBoxEngine{
		env: env, hub: hub, deps: deps, sampler: sampler, closer: NewConnectionCloser(),
		onState: onState, ruleSets: map[string]string{},
		crashes: core.NewCrashCounter(3, time.Minute), state: core.NewEngineStopped(),
		startupGrace: singBoxStartupGrace, startupPoll: singBoxStartupPoll,
		startupTimeout: singBoxStartupTimeout,
		startAttempts:  singBoxStartAttempts,
	}
}

// IsRunning reports whether a sing-box process is supervised.
func (e *SingBoxEngine) IsRunning() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.process != nil
}

// ConfigHash is the hash of the config the running process was started with ("" = none).
func (e *SingBoxEngine) ConfigHash() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.configHash
}

// RuleSets is a copy of the rule-set files on disk.
func (e *SingBoxEngine) RuleSets() map[string]string {
	e.mu.Lock()
	defer e.mu.Unlock()
	copied := make(map[string]string, len(e.ruleSets))
	for name, contents := range e.ruleSets {
		copied[name] = contents
	}
	return copied
}

// State is the current engine state.
func (e *SingBoxEngine) State() core.EngineState {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.state
}

// LogTail is the last few lines sing-box printed.
func (e *SingBoxEngine) LogTail() []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]string(nil), e.recent...)
}

func (e *SingBoxEngine) setState(state core.EngineState) {
	e.mu.Lock()
	changed := state.Kind != e.state.Kind || state.Reason != e.state.Reason || !state.Since.Equal(e.state.Since.Time)
	e.state = state
	e.mu.Unlock()
	if changed && e.onState != nil {
		e.onState(state)
	}
}

// WriteRuleSets writes the files atomically (sing-box's watcher sees one change each).
func (e *SingBoxEngine) WriteRuleSets(files map[string]string) *core.DaemonError {
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if err := core.WriteStringAtomic(e.env.RunPath(name), files[name], 0o600); err != nil {
			return core.ErrInternal(fmt.Sprintf("cannot write %s: %v", name, err))
		}
		e.mu.Lock()
		e.ruleSets[name] = files[name]
		e.mu.Unlock()
	}
	return nil
}

// DeleteRuleSets removes files the plan no longer contains.
func (e *SingBoxEngine) DeleteRuleSets(names []string) {
	for _, name := range names {
		os.Remove(e.env.RunPath(name))
		e.mu.Lock()
		delete(e.ruleSets, name)
		e.mu.Unlock()
	}
}

// CutConnections: once sing-box has reloaded rewritten rule-sets, close the connections
// the change covers (all of them when it is unknown) so they reconnect under the new
// rules (docs/design/05-daemon.md, "Connection cut on rule change").
func (e *SingBoxEngine) CutConnections(change *core.RuleSetSelectors) {
	time.AfterFunc(ruleSetReloadGrace, func() {
		e.mu.Lock()
		endpoint := e.endpoint
		running := e.process != nil
		e.mu.Unlock()
		if endpoint == nil || !running {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		closed, err := e.closer.Close(ctx, *endpoint, change)
		switch {
		case err != nil:
			e.hub.Log(core.LogLevelWarning, "rules changed: cannot close connections ("+err.Error()+")")
		case change == nil:
			e.hub.Log(core.LogLevelInfo, fmt.Sprintf("rules changed: closed all %d connection(s)", closed))
		default:
			e.hub.Log(core.LogLevelInfo, fmt.Sprintf("rules changed: closed %d affected connection(s)", closed))
		}
	})
}

// Check writes the candidate config next to the live one — with a fresh Clash API
// endpoint injected for traffic sampling — runs `sing-box check` on it and promotes it
// to sing-box.json only when the check passes.
func (e *SingBoxEngine) Check(ctx context.Context, config, hash string) *core.DaemonError {
	if err := e.validateBinary(); err != nil {
		return err
	}
	endpoint, err := core.GenerateClashAPIEndpoint()
	if err != nil {
		return core.ErrInternal("cannot prepare clash api: " + err.Error())
	}
	injected, err := core.InjectClashAPI(endpoint, config)
	if err != nil {
		return core.ErrInternal("cannot prepare clash api: " + err.Error())
	}
	candidate := e.env.RunPath(core.SingBoxConfig + ".check")
	if err := core.WriteStringAtomic(candidate, injected, 0o600); err != nil {
		return core.ErrInternal("cannot write config: " + err.Error())
	}
	checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	result, err := e.deps.Processes.Run(checkCtx, ProcessSpec{
		Executable: e.env.SingBoxPath(),
		Args:       []string{"check", "-D", e.env.Layout.Dir, "-c", candidate},
		WorkingDir: e.env.Layout.Dir,
	})
	if err != nil {
		os.Remove(candidate)
		return core.ErrInternal("cannot run sing-box check: " + err.Error())
	}
	if !result.Succeeded() {
		os.Remove(candidate)
		return core.ErrConfigInvalid(result.Output())
	}
	if err := os.Rename(candidate, e.env.RunPath(core.SingBoxConfig)); err != nil {
		os.Remove(candidate)
		return core.ErrInternal("cannot install config: " + err.Error())
	}
	e.mu.Lock()
	e.checkedHash = hash
	e.checkedEndpoint = &endpoint
	e.mu.Unlock()
	return nil
}

func (e *SingBoxEngine) validateBinary() *core.DaemonError {
	if e.env.DevMode || e.deps.Binaries == nil {
		return nil
	}
	// The warning for an unsigned binary is logged once per apply by the supervisor.
	_, err := e.deps.Binaries.Validate(e.env.SingBoxPath())
	return err
}

// Start spawns sing-box for the config installed by Check and verifies it came up: the
// TUN adapter exists and a public address routes through it. A start that never verifies
// is retried once before it counts as failed (docs/design/03-routing.md, "Startup
// verification").
func (e *SingBoxEngine) Start(ctx context.Context) *core.DaemonError {
	e.mu.Lock()
	if e.process != nil {
		e.mu.Unlock()
		return nil
	}
	if e.restartTimer != nil {
		e.restartTimer.Stop()
		e.restartTimer = nil
	}
	e.stopping = false
	e.aborted = false
	attempts := e.startAttempts
	e.mu.Unlock()
	if err := e.validateBinary(); err != nil {
		return err
	}
	e.setState(core.NewEngineStarting())

	for attempt := 1; ; attempt++ {
		outcome, tail := e.startAttempt(ctx, attempt)
		switch outcome {
		case startupVerified, startupAbandoned:
			return nil
		case startupSpawnFailed:
			e.setState(core.NewEngineFailed(EngineStartFailed))
			return core.ErrStartFailed(tail)
		}
		if attempt < attempts {
			reason := "startup verification failed"
			if len(tail) > 0 {
				reason = tail[0]
			}
			e.hub.Log(core.LogLevelWarning, "starting sing-box once more after: "+reason)
			continue
		}
		e.setState(core.NewEngineFailed(EngineStartFailed))
		return core.ErrStartFailed(tail)
	}
}

// startupOutcome is how one spawn-and-verify attempt ended.
type startupOutcome int

const (
	// startupVerified: the TUN is up and public traffic routes through it.
	startupVerified startupOutcome = iota
	// startupUnverified: the window ran out, or the process exited during startup.
	startupUnverified
	// startupAbandoned: a stop or a newer apply took over; it sets the state itself.
	startupAbandoned
	startupSpawnFailed
)

// startAttempt spawns sing-box once and waits for the startup check to pass. The returned
// tail is the failure line followed by the last log lines of this attempt.
func (e *SingBoxEngine) startAttempt(ctx context.Context, attempt int) (startupOutcome, []string) {
	e.mu.Lock()
	e.configHash = e.checkedHash
	e.endpoint = e.checkedEndpoint
	e.generation++
	generation := e.generation
	e.recent = nil
	e.startupPending = true
	e.mu.Unlock()

	started := make(chan struct{})
	var startedOnce sync.Once
	process, err := e.deps.Processes.Start(ProcessSpec{
		Executable: e.env.SingBoxPath(),
		Args:       core.SingBoxRunArguments(e.env.Layout),
		WorkingDir: e.env.Layout.Dir,
	}, ProcessHandlers{
		OnLine: func(line string) {
			e.mu.Lock()
			e.recent = append(e.recent, line)
			if len(e.recent) > singBoxLogTailLines {
				e.recent = e.recent[len(e.recent)-singBoxLogTailLines:]
			}
			e.mu.Unlock()
			e.hub.PostFrom(SingBoxSource, core.SingBoxLogLevel(line), core.SingBoxLogMessage(line))
			if core.IsSingBoxStartedLine(line) {
				startedOnce.Do(func() { close(started) })
			}
		},
		OnExit: func(code uint32) { e.handleExit(code, generation) },
	})
	if err != nil {
		e.mu.Lock()
		e.startupPending = false
		e.mu.Unlock()
		return startupSpawnFailed, []string{"spawn failed: " + err.Error()}
	}
	e.mu.Lock()
	e.process = process
	e.mu.Unlock()
	if attempt == 1 {
		e.hub.Log(core.LogLevelInfo, fmt.Sprintf("sing-box started (pid %d)", process.PID()))
	} else {
		e.hub.Log(core.LogLevelInfo, fmt.Sprintf("sing-box started (pid %d, attempt %d)", process.PID(), attempt))
	}

	// startupPending stays set until the child is dealt with: it is what keeps handleExit
	// from treating a termination of our own as a crash worth restarting.
	failure, abandoned := e.awaitStartup(ctx, process, started)
	e.mu.Lock()
	current := e.process == process
	e.mu.Unlock()
	if abandoned || !current {
		if current {
			// Nothing is going to supervise this child: kill it and let whoever
			// interrupted the start (a stop, a newer apply) set the state.
			process.Terminate(singBoxStopTimeout)
		}
		e.mu.Lock()
		if e.process == process {
			e.process = nil
		}
		e.startupPending = false
		e.mu.Unlock()
		return startupAbandoned, nil
	}
	if failure != "" {
		e.hub.Log(core.LogLevelError, "sing-box startup verification failed: "+failure)
		process.Terminate(singBoxStopTimeout)
		e.mu.Lock()
		e.process = nil
		e.startupPending = false
		tail := append([]string{failure}, e.recent...)
		e.mu.Unlock()
		return startupUnverified, tail
	}
	e.mu.Lock()
	e.startupPending = false
	e.crashes.Reset()
	e.backoff.Reset()
	endpoint := e.endpoint
	e.mu.Unlock()
	e.setState(core.NewEngineRunning(e.deps.Clock.Now()))
	if endpoint != nil {
		e.sampler.Start(*endpoint)
	}
	return startupVerified, nil
}

// awaitStartup waits for the "started" line (or the grace period), then repeats
// verifyStartup every startupPoll until it passes or startupTimeout from the spawn is up.
func (e *SingBoxEngine) awaitStartup(ctx context.Context, process Process, started <-chan struct{}) (failure string, abandoned bool) {
	graceUntil := e.deps.Clock.Now().Add(e.startupGrace)
	deadline := e.deps.Clock.Now().Add(e.startupTimeout)
	up := false
	for {
		if e.startupAbandoned(process) {
			return "", true
		}
		select {
		case <-process.Exited():
			return "exited during startup", false
		case <-started:
			up = true
		default:
		}
		now := e.deps.Clock.Now()
		expired := !now.Before(deadline)
		// Before the grace period is over only a sing-box that says it is up is
		// checked: a TUN the previous process has not finished tearing down would
		// otherwise pass the check for this one.
		if up || !now.Before(graceUntil) || expired {
			failure = e.verifyStartup()
			if failure == "" {
				return "", false
			}
			if expired {
				return failure, false
			}
		}
		select {
		case <-process.Exited():
			return "exited during startup", false
		case <-ctx.Done():
			return "startup interrupted", false
		case <-e.deps.Clock.After(e.startupPoll):
		}
	}
}

// startupAbandoned: a stop, or an operation waiting behind this start, took over.
func (e *SingBoxEngine) startupAbandoned(process Process) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.aborted || e.stopping || e.process != process
}

// AbortStartup makes a start that is still verifying give up, so an apply or a stop
// waiting behind it is not held for the whole verification window (H1). Ignored when no
// start is in flight.
func (e *SingBoxEngine) AbortStartup() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.startupPending {
		e.aborted = true
	}
}

func (e *SingBoxEngine) verifyStartup() string {
	if !e.deps.Network.AdapterPresent(core.TUNAdapterName) {
		return core.TUNAdapterName + " did not come up"
	}
	via, err := e.deps.Network.RouteInterface(StartupProbeAddress)
	if err != nil {
		return "cannot resolve the route for " + StartupProbeAddress + ": " + err.Error()
	}
	if via != core.TUNAdapterName {
		return fmt.Sprintf("public traffic routes via %s, not %s", via, core.TUNAdapterName)
	}
	return ""
}

// Stop terminates sing-box and forgets the config hash.
func (e *SingBoxEngine) Stop() {
	e.mu.Lock()
	if e.restartTimer != nil {
		e.restartTimer.Stop()
		e.restartTimer = nil
	}
	e.stopping = true
	process := e.process
	e.mu.Unlock()
	e.sampler.Pause()
	if process != nil {
		e.hub.Log(core.LogLevelInfo, fmt.Sprintf("stopping sing-box (pid %d)", process.PID()))
		process.Terminate(singBoxStopTimeout)
	}
	e.mu.Lock()
	e.process = nil
	e.configHash = ""
	e.mu.Unlock()
	e.setState(core.NewEngineStopped())
}

func (e *SingBoxEngine) handleExit(code uint32, generation int) {
	e.mu.Lock()
	if generation != e.generation || e.process == nil || e.stopping || e.startupPending {
		e.mu.Unlock()
		return
	}
	uptime := e.deps.Clock.Now().Sub(e.process.StartedAt())
	e.process = nil
	e.mu.Unlock()
	e.sampler.Pause()
	e.hub.Log(core.LogLevelError, fmt.Sprintf("sing-box exited unexpectedly (exit status %d) after %d s", code, int(uptime.Seconds())))
	e.mu.Lock()
	if e.crashes.RecordExit(e.deps.Clock.Now()) {
		e.mu.Unlock()
		e.hub.Log(core.LogLevelError, "sing-box crashed 3 times within 60 s; giving up")
		e.setState(core.NewEngineFailed(EngineStartFailed))
		return
	}
	delay := e.backoff.NextDelay(uptime)
	e.mu.Unlock()
	e.setState(core.NewEngineStarting())
	e.hub.Log(core.LogLevelInfo, "restarting sing-box in "+delay.String())
	e.mu.Lock()
	e.restartTimer = time.AfterFunc(delay, func() {
		if err := e.Start(context.Background()); err != nil {
			e.hub.Log(core.LogLevelError, "sing-box restart failed: "+err.Error())
		}
	})
	e.mu.Unlock()
}
