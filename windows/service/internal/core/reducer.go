package core

import (
	"fmt"
	"math"
	"strings"
	"time"
)

// ReducerContext is what the reducer knows about its tunnel: id, adapter and the
// secrets it may have to hand to the management interface.
type ReducerContext struct {
	ID            string
	Interface     string
	Credentials   *Credentials
	KeyPassphrase *string
}

// ReducerContextFor takes the context of a planned OpenVPN runtime.
func ReducerContextFor(runtime OpenVPNRuntime) ReducerContext {
	return ReducerContext{
		ID: runtime.ID, Interface: runtime.Interface,
		Credentials: runtime.Credentials, KeyPassphrase: runtime.KeyPassphrase,
	}
}

// ReducerInputKind identifies a reducer input.
type ReducerInputKind string

const (
	// InputProcessStarted: a fresh openvpn process was spawned for `Attempt` (1-based).
	InputProcessStarted ReducerInputKind = "processStarted"
	// InputManagementConnected: the management socket is up (and, on Windows, its
	// password exchange is done — the socket client handles that, not the reducer).
	InputManagementConnected ReducerInputKind = "managementConnected"
	// InputManagement: a parsed management line.
	InputManagement ReducerInputKind = "management"
	// InputManagementClosed: the management socket closed.
	InputManagementClosed ReducerInputKind = "managementClosed"
	// InputProcessLine: a line of the process's own stdout/stderr. Forwarded to the log
	// only until the management socket is up (openvpn then prints every line on both).
	InputProcessLine ReducerInputKind = "processLine"
	// InputProcessExited: the process exited with `ExitCode`.
	InputProcessExited ReducerInputKind = "processExited"
	// InputRestartScheduled: the session will respawn after `NextIn`.
	InputRestartScheduled ReducerInputKind = "restartScheduled"
	// InputRetriesDisabled: the session will not respawn (`autoReconnect` off).
	InputRetriesDisabled ReducerInputKind = "retriesDisabled"
)

// ReducerInput is one thing that happened to the session.
type ReducerInput struct {
	Kind     ReducerInputKind
	Attempt  int
	Event    ManagementEvent
	Line     string
	ExitCode uint32
	NextIn   time.Duration
}

// ProcessStarted reports a spawn for the given attempt.
func ProcessStarted(attempt int) ReducerInput {
	return ReducerInput{Kind: InputProcessStarted, Attempt: attempt}
}

// ManagementConnected reports the management channel being ready.
func ManagementConnected() ReducerInput { return ReducerInput{Kind: InputManagementConnected} }

// ManagementInput wraps a parsed management line.
func ManagementInput(event ManagementEvent) ReducerInput {
	return ReducerInput{Kind: InputManagement, Event: event}
}

// ManagementClosed reports the management channel closing.
func ManagementClosed() ReducerInput { return ReducerInput{Kind: InputManagementClosed} }

// ProcessLine wraps a line of the child's own output.
func ProcessLine(line string) ReducerInput { return ReducerInput{Kind: InputProcessLine, Line: line} }

// ProcessExited reports the child's exit code.
func ProcessExited(code uint32) ReducerInput {
	return ReducerInput{Kind: InputProcessExited, ExitCode: code}
}

// RestartScheduled reports the backoff decision.
func RestartScheduled(attempt int, nextIn time.Duration) ReducerInput {
	return ReducerInput{Kind: InputRestartScheduled, Attempt: attempt, NextIn: nextIn}
}

// RetriesDisabled reports that the session will not respawn.
func RetriesDisabled() ReducerInput { return ReducerInput{Kind: InputRetriesDisabled} }

// ReducerEffectKind identifies a side effect the session must perform.
type ReducerEffectKind string

const (
	// EffectSend: write `Command` to the management socket. May contain secrets: never log it.
	EffectSend ReducerEffectKind = "send"
	// EffectLog: emit a log line for the tunnel's source.
	EffectLog ReducerEffectKind = "log"
	// EffectAddScopedRoute: add the adapter's metric-9999 default via `Gateway`
	// (docs/design/08-windows.md, "Routes"); an empty gateway means on-link.
	EffectAddScopedRoute ReducerEffectKind = "addScopedRoute"
	// EffectDeleteScopedRoute: remove that route.
	EffectDeleteScopedRoute ReducerEffectKind = "deleteScopedRoute"
	// EffectDiscoveredDNS: `dhcp-option DNS` servers from the latest PUSH_REPLY (maybe empty).
	EffectDiscoveredDNS ReducerEffectKind = "discoveredDNS"
	// EffectExited: emitted once per process exit, with the restart disposition.
	EffectExited ReducerEffectKind = "exited"
)

// ExitDisposition says whether the session may restart after an exit.
type ExitDisposition struct {
	// Permanent: do not restart until the plan changes; `Failure` names why.
	Permanent bool
	Failure   OpenVPNFailure
	// Reason of a transient exit (restart per backoff policy).
	Reason string
}

// ReducerEffect is one side effect; the fields used depend on Kind.
type ReducerEffect struct {
	Kind      ReducerEffectKind
	Command   string
	Level     LogLevel
	Message   string
	Interface string
	Gateway   string
	Servers   []string
	Exit      ExitDisposition
}

// SendEffect builds an EffectSend.
func SendEffect(command string) ReducerEffect {
	return ReducerEffect{Kind: EffectSend, Command: command}
}

// LogEffect builds an EffectLog.
func LogEffect(level LogLevel, message string) ReducerEffect {
	return ReducerEffect{Kind: EffectLog, Level: level, Message: message}
}

// AddScopedRouteEffect builds an EffectAddScopedRoute.
func AddScopedRouteEffect(adapter, gateway string) ReducerEffect {
	return ReducerEffect{Kind: EffectAddScopedRoute, Interface: adapter, Gateway: gateway}
}

// DeleteScopedRouteEffect builds an EffectDeleteScopedRoute.
func DeleteScopedRouteEffect(adapter string) ReducerEffect {
	return ReducerEffect{Kind: EffectDeleteScopedRoute, Interface: adapter}
}

// DiscoveredDNSEffect builds an EffectDiscoveredDNS.
func DiscoveredDNSEffect(servers []string) ReducerEffect {
	return ReducerEffect{Kind: EffectDiscoveredDNS, Servers: nonNilSlice(servers)}
}

// ExitedEffect builds an EffectExited.
func ExitedEffect(disposition ExitDisposition) ReducerEffect {
	return ReducerEffect{Kind: EffectExited, Exit: disposition}
}

// PermanentExit is the disposition of a permanent failure.
func PermanentExit(failure OpenVPNFailure) ExitDisposition {
	return ExitDisposition{Permanent: true, Failure: failure}
}

// TransientExit is the disposition of an exit worth retrying.
func TransientExit(reason string) ExitDisposition {
	return ExitDisposition{Reason: reason}
}

// OpenVPNSessionReducer is the pure state machine of one OpenVPN tunnel: management
// events and process lifecycle in, TunnelState plus side effects out. The session owns
// the process, socket and timers and feeds this reducer (docs/design/04-tunnels.md,
// "Management protocol handling"; docs/design/00-architecture.md, "State machines").
type OpenVPNSessionReducer struct {
	context          ReducerContext
	state            TunnelState
	attempt          int
	managementUp     bool
	routeAdded       bool
	permanentFailure OpenVPNFailure
	lastReason       string
	// The next hop for the scoped default, from the latest PUSH_REPLY.
	routeGateway string
}

// NewOpenVPNSessionReducer starts in `connecting(attempt: 1)`.
func NewOpenVPNSessionReducer(context ReducerContext) *OpenVPNSessionReducer {
	return &OpenVPNSessionReducer{
		context: context, state: NewTunnelConnecting(1), attempt: 1,
	}
}

// Context returns the tunnel's context.
func (r *OpenVPNSessionReducer) Context() ReducerContext { return r.context }

// State returns the current TunnelState.
func (r *OpenVPNSessionReducer) State() TunnelState { return r.state }

// Attempt returns the current attempt number.
func (r *OpenVPNSessionReducer) Attempt() int { return r.attempt }

// Handle applies one input and returns the effects to perform, in order.
func (r *OpenVPNSessionReducer) Handle(input ReducerInput, now time.Time) []ReducerEffect {
	switch input.Kind {
	case InputProcessStarted:
		r.attempt = input.Attempt
		r.managementUp = false
		r.routeAdded = false
		r.permanentFailure = ""
		r.lastReason = ""
		r.routeGateway = ""
		r.state = NewTunnelConnecting(input.Attempt)
		return []ReducerEffect{LogEffect(LogLevelInfo,
			fmt.Sprintf("openvpn started (attempt %d, %s)", input.Attempt, r.context.Interface))}

	case InputManagementConnected:
		r.managementUp = true
		return []ReducerEffect{
			SendEffect(ManagementStateOn), SendEffect(ManagementLogOn),
			SendEffect(ManagementBytecount), SendEffect(ManagementHoldRelease),
			LogEffect(LogLevelDebug, "management interface connected"),
		}

	case InputManagement:
		return r.handleEvent(input.Event, now)

	case InputManagementClosed:
		r.managementUp = false
		return nil

	case InputProcessLine:
		flags, message := ParseOutputLine(input.Line)
		var effects []ReducerEffect
		if !r.managementUp {
			effects = append(effects, LogEffect(LevelForLogFlags(flags), message))
		}
		if strings.Contains(flags, "F") && r.permanentFailure == "" {
			if reason, ok := PermanentReasonForFatal(message); ok {
				effects = append(effects, r.fail(reason, message)...)
			}
		}
		effects = append(effects, r.noteLogMessage(message)...)
		return effects

	case InputProcessExited:
		r.managementUp = false
		var effects []ReducerEffect
		if r.routeAdded {
			r.routeAdded = false
			effects = append(effects, DeleteScopedRouteEffect(r.context.Interface))
		}
		exit := fmt.Sprintf("exit status %d", input.ExitCode)
		if r.permanentFailure != "" {
			effects = append(effects,
				LogEffect(LogLevelError, fmt.Sprintf("openvpn exited (%s); not retrying: %s", exit, r.permanentFailure)),
				ExitedEffect(PermanentExit(r.permanentFailure)))
			return effects
		}
		reason := r.lastReason
		if reason == "" {
			reason = exit
		}
		return append(effects,
			LogEffect(LogLevelWarning, fmt.Sprintf("openvpn exited (%s)", exit)),
			ExitedEffect(TransientExit(reason)))

	case InputRestartScheduled:
		r.attempt = input.Attempt
		r.state = NewTunnelReconnecting(input.Attempt, input.NextIn.Seconds(), r.lastReason)
		return []ReducerEffect{LogEffect(LogLevelInfo, fmt.Sprintf(
			"restarting openvpn in %d s (attempt %d)", int(math.Round(input.NextIn.Seconds())), input.Attempt))}

	case InputRetriesDisabled:
		r.state = NewTunnelFailed(string(FailureExited), false)
		return []ReducerEffect{LogEffect(LogLevelWarning, "openvpn exited; automatic reconnect is off")}
	}
	return nil
}

func (r *OpenVPNSessionReducer) handleEvent(event ManagementEvent, now time.Time) []ReducerEffect {
	switch event.Kind {
	case EventState:
		return r.handleState(event.State, now)

	case EventLog:
		effects := []ReducerEffect{LogEffect(LevelForLogFlags(event.Flags), event.Message)}
		if servers, ok := PushedDNS(event.Message); ok {
			effects = append(effects, DiscoveredDNSEffect(servers))
		}
		return append(effects, r.noteLogMessage(event.Message)...)

	case EventEcho:
		return nil

	case EventPasswordNeeded:
		if r.permanentFailure != "" {
			return nil
		}
		switch event.PasswordKind {
		case "Auth":
			if r.context.Credentials == nil {
				return r.fail(FailureNeedsCredentials, "")
			}
			return []ReducerEffect{
				SendEffect(ManagementUsername(event.PasswordKind, r.context.Credentials.Username)),
				SendEffect(ManagementPassword(event.PasswordKind, r.context.Credentials.Password)),
			}
		case "Private Key":
			if r.context.KeyPassphrase == nil {
				return r.fail(FailureNeedsKeyPassphrase, "")
			}
			return []ReducerEffect{SendEffect(ManagementPassword(event.PasswordKind, *r.context.KeyPassphrase))}
		default:
			return r.fail(FailureUnsupportedPrompt, fmt.Sprintf("server asked for '%s'", event.PasswordKind))
		}

	case EventPasswordVerificationFailed:
		if r.permanentFailure != "" {
			return nil
		}
		switch event.PasswordKind {
		case "Auth":
			return r.fail(FailureAuthFailed, "")
		case "Private Key":
			return r.fail(FailureKeyPassphrase, "")
		default:
			return r.fail(FailureUnsupportedPrompt, fmt.Sprintf("verification failed for '%s'", event.PasswordKind))
		}

	case EventFatal:
		if reason, ok := PermanentReasonForFatal(event.Message); ok {
			return r.fail(reason, event.Message)
		}
		r.lastReason = event.Message
		return []ReducerEffect{LogEffect(LogLevelError, event.Message)}

	case EventError:
		return []ReducerEffect{LogEffect(LogLevelWarning, "management: "+event.Message)}

	case EventHold:
		// `--management-hold` is persistent: after every soft restart (server_poll,
		// ping-restart, SIGUSR1) openvpn hibernates again until the next `hold release`.
		return []ReducerEffect{SendEffect(ManagementHoldRelease), LogEffect(LogLevelDebug, "hold released")}
	}
	// EventInfo, EventSuccess, EventBytecount, EventOther.
	return nil
}

func (r *OpenVPNSessionReducer) handleState(state ManagementState, now time.Time) []ReducerEffect {
	switch state.Name {
	case "CONNECTED":
		r.state = NewTunnelConnected(now, state.TunnelIP, r.context.Interface)
		ip := state.TunnelIP
		if ip == "" {
			ip = "no ip"
		}
		effects := []ReducerEffect{LogEffect(LogLevelInfo, fmt.Sprintf("connected (%s on %s)", ip, r.context.Interface))}
		if !r.routeAdded {
			r.routeAdded = true
			if r.routeGateway == "" {
				effects = append(effects, LogEffect(LogLevelWarning, fmt.Sprintf(
					"no route-gateway pushed for %s; using an on-link default", r.context.Interface)))
			}
			effects = append(effects, AddScopedRouteEffect(r.context.Interface, r.routeGateway))
		}
		return effects

	case "RECONNECTING":
		r.lastReason = state.Description
		var effects []ReducerEffect
		if r.routeAdded {
			r.routeAdded = false
			effects = append(effects, DeleteScopedRouteEffect(r.context.Interface))
		}
		if r.permanentFailure == "" {
			r.state = NewTunnelReconnecting(r.attempt, 0, r.lastReason)
		}
		return append(effects, LogEffect(LogLevelWarning, "reconnecting: "+state.Description))

	case "EXITING":
		if state.Description != "" {
			r.lastReason = state.Description
		}
		return []ReducerEffect{LogEffect(LogLevelInfo, "exiting: "+state.Description)}

	default:
		if r.permanentFailure == "" && !r.state.IsConnected() {
			r.state = NewTunnelConnecting(r.attempt)
		}
		return []ReducerEffect{LogEffect(LogLevelDebug,
			strings.TrimSpace("state "+state.Name+" "+state.Description))}
	}
}

// noteLogMessage remembers the pushed route gateway and checks the opened adapter; both
// arrive as log lines on either channel.
func (r *OpenVPNSessionReducer) noteLogMessage(message string) []ReducerEffect {
	if gateway, ok := PushedRouteGateway(message); ok {
		r.routeGateway = gateway
	}
	if r.permanentFailure != "" {
		return nil
	}
	// The adapter must be the planned one, or sing-box binds the tunnel outbound to an
	// adapter that carries nothing.
	if opened, ok := OpenedAdapter(message); ok && opened != r.context.Interface {
		return r.fail(FailureConfigError, fmt.Sprintf("openvpn opened %s instead of %s", opened, r.context.Interface))
	}
	return nil
}

func (r *OpenVPNSessionReducer) fail(reason OpenVPNFailure, detail string) []ReducerEffect {
	r.permanentFailure = reason
	r.state = NewTunnelFailed(string(reason), true)
	message := "tunnel failed: " + string(reason)
	if detail != "" {
		message += " — " + detail
	}
	effects := []ReducerEffect{LogEffect(LogLevelError, message)}
	if r.managementUp {
		effects = append(effects, SendEffect(ManagementSignalTerm))
	}
	return effects
}
