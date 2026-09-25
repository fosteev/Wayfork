package service

import (
	"context"
	"time"

	"wayfork/service/internal/core"
)

// ProcessSpec describes a child to spawn.
type ProcessSpec struct {
	Executable string
	Args       []string
	WorkingDir string
}

// ProcessHandlers receive the child's output lines and its exit.
type ProcessHandlers struct {
	OnLine func(line string)
	OnExit func(code uint32)
}

// Process is a running child. Terminate waits up to `timeout` for a voluntary exit,
// then kills the process; it returns the exit code either way and never blocks past
// the timeout by more than the kill.
type Process interface {
	PID() int
	StartedAt() time.Time
	Terminate(timeout time.Duration) uint32
	// Exited is closed once OnExit has fired.
	Exited() <-chan struct{}
}

// CommandResult is the outcome of a short-lived helper.
type CommandResult struct {
	ExitCode uint32
	Lines    []string
	// TimedOut: the helper was killed when ctx ended.
	TimedOut bool
}

// Succeeded reports a clean exit.
func (r CommandResult) Succeeded() bool { return r.ExitCode == 0 && !r.TimedOut }

// Output joins the lines.
func (r CommandResult) Output() string {
	out := ""
	for index, line := range r.Lines {
		if index > 0 {
			out += "\n"
		}
		out += line
	}
	return out
}

// ProcessRunner spawns children (detached, inside the job object on Windows) and runs
// helpers (`sing-box check`, `openvpn --version`, `tapctl`) to completion.
type ProcessRunner interface {
	Start(spec ProcessSpec, handlers ProcessHandlers) (Process, error)
	Run(ctx context.Context, spec ProcessSpec) (CommandResult, error)
}

// Network is the adapter and route side of Win32 (docs/design/08-windows.md, "Adapters",
// "Routes").
type Network interface {
	// AdapterPresent reports whether an adapter with this friendly name exists and is up.
	AdapterPresent(name string) bool
	// EnsureAdapters creates the named OpenVPN adapters that are missing (tapctl,
	// idempotent) and removes stray Wayfork-* ones that are not in the list.
	EnsureAdapters(ctx context.Context, names []string) error
	// CleanupAdapters removes leftover scoped defaults and stale addresses on every
	// Wayfork-* adapter (startup, docs/design/08-windows.md "Routes", "Table cleanup").
	CleanupAdapters(ctx context.Context) error
	// AddScopedDefault adds 0.0.0.0/0 via gateway (empty = on-link) on the adapter with
	// metric 9999 in the active store.
	AddScopedDefault(adapter, gateway string) error
	DeleteScopedDefault(adapter string) error
	// RouteInterface names the adapter a packet to `address` leaves through.
	RouteInterface(address string) (string, error)
	// Diagnostics dumps routes, adapters and the NRPT policy for collectDiagnostics.
	Diagnostics(ctx context.Context) string
}

// Resolver is the NRPT side (docs/design/08-windows.md, "Resolver override").
type Resolver interface {
	Snapshot(ctx context.Context) (core.ResolverSnapshot, error)
	// AddRule adds the rule and returns it with its assigned name.
	AddRule(ctx context.Context, rule core.NRPTRule) (core.NRPTRule, error)
	RemoveRules(ctx context.Context, names []string) error
	// Probe resolves `host` once through the system resolver (getaddrinfo).
	Probe(ctx context.Context, host string) bool
}

// BinaryValidator checks a bundled binary's Authenticode signature before every spawn
// (docs/design/08-windows.md, "Components and trust boundary").
type BinaryValidator interface {
	// Validate returns a binaryUntrusted DaemonError when the file must not run, and a
	// warning to log when it was accepted without a signature.
	Validate(path string) (string, *core.DaemonError)
}

// Clock lets tests drive time.
type Clock interface {
	Now() time.Time
	After(d time.Duration) <-chan time.Time
}

type systemClock struct{}

func (systemClock) Now() time.Time                         { return time.Now() }
func (systemClock) After(d time.Duration) <-chan time.Time { return time.After(d) }

// SystemClock is the real clock.
var SystemClock Clock = systemClock{}

// Dependencies bundles the I/O implementations the supervisor runs on.
type Dependencies struct {
	Processes ProcessRunner
	Network   Network
	Resolver  Resolver
	Binaries  BinaryValidator
	Clock     Clock
}
