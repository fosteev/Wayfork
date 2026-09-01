package core

import (
	"fmt"
	"time"
)

// EngineStateKind identifies an engine-state wire case.
type EngineStateKind string

const (
	// EngineStopped means no routing engine is running.
	EngineStopped EngineStateKind = "stopped"
	// EngineStarting means the routing engine is starting.
	EngineStarting EngineStateKind = "starting"
	// EngineRunning means the routing engine passed startup verification.
	EngineRunning EngineStateKind = "running"
	// EngineFailed means the routing engine cannot run.
	EngineFailed EngineStateKind = "failed"
)

// EngineState is the routing-engine state reported over IPC
// (docs/design/05-daemon.md, "XPC interface").
type EngineState struct {
	Kind   EngineStateKind
	Since  Timestamp
	Reason string
}

// NewEngineStopped returns a stopped engine state.
func NewEngineStopped() EngineState { return EngineState{Kind: EngineStopped} }

// NewEngineStarting returns a starting engine state.
func NewEngineStarting() EngineState { return EngineState{Kind: EngineStarting} }

// NewEngineRunning returns a running engine state.
func NewEngineRunning(since time.Time) EngineState {
	return EngineState{Kind: EngineRunning, Since: NewTimestamp(since)}
}

// NewEngineFailed returns a failed engine state.
func NewEngineFailed(reason string) EngineState {
	return EngineState{Kind: EngineFailed, Reason: reason}
}

// IsRunning reports whether the engine is running.
func (s EngineState) IsRunning() bool { return s.Kind == EngineRunning }

// MarshalJSON emits the Swift Codable enum wire shape.
func (s EngineState) MarshalJSON() ([]byte, error) {
	switch s.Kind {
	case "":
		// The zero value is a stopped engine.
		return MarshalWire(map[string]any{string(EngineStopped): map[string]any{}})
	case EngineStopped, EngineStarting:
		return MarshalWire(map[string]any{string(s.Kind): map[string]any{}})
	case EngineRunning:
		return MarshalWire(map[string]any{"running": map[string]any{"since": s.Since}})
	case EngineFailed:
		return MarshalWire(map[string]any{"failed": map[string]any{"reason": s.Reason}})
	default:
		return nil, fmt.Errorf("unknown engine state %q", s.Kind)
	}
}

// UnmarshalJSON decodes the Swift Codable enum wire shape.
func (s *EngineState) UnmarshalJSON(data []byte) error {
	kind, payload, err := decodeWireCase(data, "engine state")
	if err != nil {
		return err
	}
	switch EngineStateKind(kind) {
	case EngineStopped, EngineStarting:
		*s = EngineState{Kind: EngineStateKind(kind)}
	case EngineRunning:
		var value struct {
			Since *Timestamp `json:"since"`
		}
		if err := decodeRequiredObject(payload, "running engine state", &value); err != nil {
			return err
		}
		if value.Since == nil {
			return fmt.Errorf("running engine state requires since")
		}
		*s = EngineState{Kind: EngineRunning, Since: *value.Since}
	case EngineFailed:
		var value struct {
			Reason *string `json:"reason"`
		}
		if err := decodeRequiredObject(payload, "failed engine state", &value); err != nil {
			return err
		}
		if value.Reason == nil {
			return fmt.Errorf("failed engine state requires reason")
		}
		*s = EngineState{Kind: EngineFailed, Reason: *value.Reason}
	default:
		return fmt.Errorf("unknown engine state case %q", kind)
	}
	return nil
}

// TunnelStateKind identifies a tunnel-state wire case.
type TunnelStateKind string

const (
	// TunnelDisabled means the tunnel is not enabled by the plan.
	TunnelDisabled TunnelStateKind = "disabled"
	// TunnelConnecting means an OpenVPN connection attempt is in progress.
	TunnelConnecting TunnelStateKind = "connecting"
	// TunnelConnected means OpenVPN reported CONNECTED.
	TunnelConnected TunnelStateKind = "connected"
	// TunnelReconnecting means a transient failure is waiting for retry.
	TunnelReconnecting TunnelStateKind = "reconnecting"
	// TunnelFailed means a tunnel stopped retrying.
	TunnelFailed TunnelStateKind = "failed"
)

// TunnelState is the state of one OpenVPN tunnel.
type TunnelState struct {
	Kind      TunnelStateKind
	Attempt   int
	Since     Timestamp
	IP        string
	Interface string
	NextIn    float64
	Reason    string
	Permanent bool
}

// NewTunnelDisabled returns a disabled tunnel state.
func NewTunnelDisabled() TunnelState { return TunnelState{Kind: TunnelDisabled} }

// NewTunnelConnecting returns a connecting tunnel state.
func NewTunnelConnecting(attempt int) TunnelState {
	return TunnelState{Kind: TunnelConnecting, Attempt: attempt}
}

// NewTunnelConnected returns a connected tunnel state.
func NewTunnelConnected(since time.Time, ip, interfaceName string) TunnelState {
	return TunnelState{
		Kind: TunnelConnected, Since: NewTimestamp(since), IP: ip, Interface: interfaceName,
	}
}

// NewTunnelReconnecting returns a reconnecting tunnel state.
func NewTunnelReconnecting(attempt int, nextIn float64, reason string) TunnelState {
	return TunnelState{
		Kind: TunnelReconnecting, Attempt: attempt, NextIn: nextIn, Reason: reason,
	}
}

// NewTunnelFailed returns a failed tunnel state.
func NewTunnelFailed(reason string, permanent bool) TunnelState {
	return TunnelState{Kind: TunnelFailed, Reason: reason, Permanent: permanent}
}

// IsConnected reports whether the tunnel is connected.
func (s TunnelState) IsConnected() bool { return s.Kind == TunnelConnected }

// MarshalJSON emits the Swift Codable enum wire shape.
func (s TunnelState) MarshalJSON() ([]byte, error) {
	var payload map[string]any
	switch s.Kind {
	case TunnelDisabled:
		payload = map[string]any{}
	case TunnelConnecting:
		payload = map[string]any{"attempt": s.Attempt}
	case TunnelConnected:
		payload = map[string]any{"interface": s.Interface, "since": s.Since}
		if s.IP != "" {
			payload["ip"] = s.IP
		}
	case TunnelReconnecting:
		payload = map[string]any{"attempt": s.Attempt, "nextIn": s.NextIn}
		if s.Reason != "" {
			payload["reason"] = s.Reason
		}
	case TunnelFailed:
		payload = map[string]any{"permanent": s.Permanent, "reason": s.Reason}
	default:
		return nil, fmt.Errorf("unknown tunnel state %q", s.Kind)
	}
	return MarshalWire(map[string]any{string(s.Kind): payload})
}

// UnmarshalJSON decodes the Swift Codable enum wire shape.
func (s *TunnelState) UnmarshalJSON(data []byte) error {
	kind, payload, err := decodeWireCase(data, "tunnel state")
	if err != nil {
		return err
	}
	switch TunnelStateKind(kind) {
	case TunnelDisabled:
		*s = NewTunnelDisabled()
	case TunnelConnecting:
		var value struct {
			Attempt *int `json:"attempt"`
		}
		if err := decodeRequiredObject(payload, "connecting tunnel state", &value); err != nil {
			return err
		}
		if value.Attempt == nil {
			return fmt.Errorf("connecting tunnel state requires attempt")
		}
		*s = NewTunnelConnecting(*value.Attempt)
	case TunnelConnected:
		var value struct {
			Interface *string    `json:"interface"`
			IP        *string    `json:"ip"`
			Since     *Timestamp `json:"since"`
		}
		if err := decodeRequiredObject(payload, "connected tunnel state", &value); err != nil {
			return err
		}
		if value.Since == nil || value.Interface == nil {
			return fmt.Errorf("connected tunnel state requires since and interface")
		}
		ip := ""
		if value.IP != nil {
			ip = *value.IP
		}
		*s = TunnelState{Kind: TunnelConnected, Since: *value.Since, IP: ip, Interface: *value.Interface}
	case TunnelReconnecting:
		var value struct {
			Attempt *int     `json:"attempt"`
			NextIn  *float64 `json:"nextIn"`
			Reason  *string  `json:"reason"`
		}
		if err := decodeRequiredObject(payload, "reconnecting tunnel state", &value); err != nil {
			return err
		}
		if value.Attempt == nil || value.NextIn == nil {
			return fmt.Errorf("reconnecting tunnel state requires attempt and nextIn")
		}
		reason := ""
		if value.Reason != nil {
			reason = *value.Reason
		}
		*s = NewTunnelReconnecting(*value.Attempt, *value.NextIn, reason)
	case TunnelFailed:
		var value struct {
			Permanent *bool   `json:"permanent"`
			Reason    *string `json:"reason"`
		}
		if err := decodeRequiredObject(payload, "failed tunnel state", &value); err != nil {
			return err
		}
		if value.Permanent == nil || value.Reason == nil {
			return fmt.Errorf("failed tunnel state requires permanent and reason")
		}
		*s = NewTunnelFailed(*value.Reason, *value.Permanent)
	default:
		return fmt.Errorf("unknown tunnel state case %q", kind)
	}
	return nil
}

// ResolverOverrideStateKind identifies a resolver-override wire case.
type ResolverOverrideStateKind string

const (
	// ResolverOverrideOff means Wayfork does not own the resolver policy.
	ResolverOverrideOff ResolverOverrideStateKind = "off"
	// ResolverOverrideActive means the Wayfork resolver policy is effective.
	ResolverOverrideActive ResolverOverrideStateKind = "active"
	// ResolverOverrideShadowed means a manual resolver shadows Wayfork.
	ResolverOverrideShadowed ResolverOverrideStateKind = "shadowed"
	// ResolverOverrideFailed means resolver activation failed.
	ResolverOverrideFailed ResolverOverrideStateKind = "failed"
)

// ResolverOverrideState reports the service's system-resolver state.
type ResolverOverrideState struct {
	Kind    ResolverOverrideStateKind
	Service string
	Manual  []string
	Reason  string
}

// NewResolverOverrideOff returns an inactive resolver override.
func NewResolverOverrideOff() ResolverOverrideState {
	return ResolverOverrideState{Kind: ResolverOverrideOff}
}

// NewResolverOverrideActive returns an active resolver override.
func NewResolverOverrideActive(service string) ResolverOverrideState {
	return ResolverOverrideState{Kind: ResolverOverrideActive, Service: service}
}

// NewResolverOverrideShadowed returns a shadowed resolver override.
func NewResolverOverrideShadowed(manual []string) ResolverOverrideState {
	return ResolverOverrideState{Kind: ResolverOverrideShadowed, Manual: nonNilSlice(manual)}
}

// NewResolverOverrideFailed returns a failed resolver override.
func NewResolverOverrideFailed(reason string) ResolverOverrideState {
	return ResolverOverrideState{Kind: ResolverOverrideFailed, Reason: reason}
}

// MarshalJSON emits the Swift Codable enum wire shape.
func (s ResolverOverrideState) MarshalJSON() ([]byte, error) {
	var payload map[string]any
	kind := s.Kind
	if kind == "" {
		// The zero value is an inactive override.
		kind = ResolverOverrideOff
	}
	switch kind {
	case ResolverOverrideOff:
		payload = map[string]any{}
	case ResolverOverrideActive:
		payload = map[string]any{"service": s.Service}
	case ResolverOverrideShadowed:
		payload = map[string]any{"manual": nonNilSlice(s.Manual)}
	case ResolverOverrideFailed:
		payload = map[string]any{"reason": s.Reason}
	default:
		return nil, fmt.Errorf("unknown resolver override state %q", s.Kind)
	}
	return MarshalWire(map[string]any{string(kind): payload})
}

// UnmarshalJSON decodes the Swift Codable enum wire shape.
func (s *ResolverOverrideState) UnmarshalJSON(data []byte) error {
	kind, payload, err := decodeWireCase(data, "resolver override state")
	if err != nil {
		return err
	}
	switch ResolverOverrideStateKind(kind) {
	case ResolverOverrideOff:
		*s = NewResolverOverrideOff()
	case ResolverOverrideActive:
		var value struct {
			Service *string `json:"service"`
		}
		if err := decodeRequiredObject(payload, "active resolver override", &value); err != nil {
			return err
		}
		if value.Service == nil {
			return fmt.Errorf("active resolver override requires service")
		}
		*s = NewResolverOverrideActive(*value.Service)
	case ResolverOverrideShadowed:
		var value struct {
			Manual *[]string `json:"manual"`
		}
		if err := decodeRequiredObject(payload, "shadowed resolver override", &value); err != nil {
			return err
		}
		if value.Manual == nil {
			return fmt.Errorf("shadowed resolver override requires manual")
		}
		*s = NewResolverOverrideShadowed(*value.Manual)
	case ResolverOverrideFailed:
		var value struct {
			Reason *string `json:"reason"`
		}
		if err := decodeRequiredObject(payload, "failed resolver override", &value); err != nil {
			return err
		}
		if value.Reason == nil {
			return fmt.Errorf("failed resolver override requires reason")
		}
		*s = NewResolverOverrideFailed(*value.Reason)
	default:
		return fmt.Errorf("unknown resolver override state case %q", kind)
	}
	return nil
}

// DaemonErrorKind identifies a service error wire case.
type DaemonErrorKind string

const (
	// DaemonBinaryUntrusted reports a failed executable trust check.
	DaemonBinaryUntrusted DaemonErrorKind = "binaryUntrusted"
	// DaemonPlanInvalid reports runtime-plan validation failure.
	DaemonPlanInvalid DaemonErrorKind = "planInvalid"
	// DaemonConfigInvalid reports sing-box check output.
	DaemonConfigInvalid DaemonErrorKind = "configInvalid"
	// DaemonStartFailed reports an early sing-box failure.
	DaemonStartFailed DaemonErrorKind = "startFailed"
	// DaemonTunnelNotFound reports an unknown tunnel ID.
	DaemonTunnelNotFound DaemonErrorKind = "tunnelNotFound"
	// DaemonNotRunning reports an operation requiring a running engine.
	DaemonNotRunning DaemonErrorKind = "notRunning"
	// DaemonInternalError reports an unexpected service failure.
	DaemonInternalError DaemonErrorKind = "internalError"
)

// DaemonError is an error returned by the privileged service.
type DaemonError struct {
	Kind    DaemonErrorKind
	Path    string
	Reason  string
	Output  string
	LogTail []string
	ID      string
	Message string
}

// ErrBinaryUntrusted constructs a binaryUntrusted daemon error.
func ErrBinaryUntrusted(path string) *DaemonError {
	return &DaemonError{Kind: DaemonBinaryUntrusted, Path: path}
}

// ErrPlanInvalid constructs a planInvalid daemon error.
func ErrPlanInvalid(reason string) *DaemonError {
	return &DaemonError{Kind: DaemonPlanInvalid, Reason: reason}
}

// ErrConfigInvalid constructs a configInvalid daemon error.
func ErrConfigInvalid(output string) *DaemonError {
	return &DaemonError{Kind: DaemonConfigInvalid, Output: output}
}

// ErrStartFailed constructs a startFailed daemon error.
func ErrStartFailed(logTail []string) *DaemonError {
	return &DaemonError{Kind: DaemonStartFailed, LogTail: nonNilSlice(logTail)}
}

// ErrTunnelNotFound constructs a tunnelNotFound daemon error.
func ErrTunnelNotFound(id string) *DaemonError {
	return &DaemonError{Kind: DaemonTunnelNotFound, ID: id}
}

// ErrNotRunning constructs a notRunning daemon error.
func ErrNotRunning() *DaemonError { return &DaemonError{Kind: DaemonNotRunning} }

// ErrInternal constructs an internalError daemon error.
func ErrInternal(message string) *DaemonError {
	return &DaemonError{Kind: DaemonInternalError, Message: message}
}

// Error returns a readable service error message.
func (e *DaemonError) Error() string {
	if e == nil {
		return "<nil>"
	}
	switch e.Kind {
	case DaemonBinaryUntrusted:
		return "untrusted binary: " + e.Path
	case DaemonPlanInvalid:
		return "invalid plan: " + e.Reason
	case DaemonConfigInvalid:
		return "invalid sing-box config: " + e.Output
	case DaemonStartFailed:
		return "routing engine failed to start"
	case DaemonTunnelNotFound:
		return "tunnel not found: " + e.ID
	case DaemonNotRunning:
		return "routing engine is not running"
	case DaemonInternalError:
		return "internal error: " + e.Message
	default:
		return fmt.Sprintf("unknown daemon error %q", e.Kind)
	}
}

// MarshalJSON emits the Swift Codable enum wire shape.
func (e DaemonError) MarshalJSON() ([]byte, error) {
	var payload map[string]any
	switch e.Kind {
	case DaemonBinaryUntrusted:
		payload = map[string]any{"path": e.Path}
	case DaemonPlanInvalid:
		payload = map[string]any{"reason": e.Reason}
	case DaemonConfigInvalid:
		payload = map[string]any{"output": e.Output}
	case DaemonStartFailed:
		payload = map[string]any{"logTail": nonNilSlice(e.LogTail)}
	case DaemonTunnelNotFound:
		payload = map[string]any{"id": e.ID}
	case DaemonNotRunning:
		payload = map[string]any{}
	case DaemonInternalError:
		payload = map[string]any{"message": e.Message}
	default:
		return nil, fmt.Errorf("unknown daemon error %q", e.Kind)
	}
	return MarshalWire(map[string]any{string(e.Kind): payload})
}

// UnmarshalJSON decodes the Swift Codable enum wire shape.
func (e *DaemonError) UnmarshalJSON(data []byte) error {
	kind, payload, err := decodeWireCase(data, "daemon error")
	if err != nil {
		return err
	}
	switch DaemonErrorKind(kind) {
	case DaemonBinaryUntrusted:
		var value struct {
			Path *string `json:"path"`
		}
		if err := decodeRequiredObject(payload, "binaryUntrusted error", &value); err != nil {
			return err
		}
		if value.Path == nil {
			return fmt.Errorf("binaryUntrusted error requires path")
		}
		*e = *ErrBinaryUntrusted(*value.Path)
	case DaemonPlanInvalid:
		var value struct {
			Reason *string `json:"reason"`
		}
		if err := decodeRequiredObject(payload, "planInvalid error", &value); err != nil {
			return err
		}
		if value.Reason == nil {
			return fmt.Errorf("planInvalid error requires reason")
		}
		*e = *ErrPlanInvalid(*value.Reason)
	case DaemonConfigInvalid:
		var value struct {
			Output *string `json:"output"`
		}
		if err := decodeRequiredObject(payload, "configInvalid error", &value); err != nil {
			return err
		}
		if value.Output == nil {
			return fmt.Errorf("configInvalid error requires output")
		}
		*e = *ErrConfigInvalid(*value.Output)
	case DaemonStartFailed:
		var value struct {
			LogTail *[]string `json:"logTail"`
		}
		if err := decodeRequiredObject(payload, "startFailed error", &value); err != nil {
			return err
		}
		if value.LogTail == nil {
			return fmt.Errorf("startFailed error requires logTail")
		}
		*e = *ErrStartFailed(*value.LogTail)
	case DaemonTunnelNotFound:
		var value struct {
			ID *string `json:"id"`
		}
		if err := decodeRequiredObject(payload, "tunnelNotFound error", &value); err != nil {
			return err
		}
		if value.ID == nil {
			return fmt.Errorf("tunnelNotFound error requires id")
		}
		*e = *ErrTunnelNotFound(*value.ID)
	case DaemonNotRunning:
		*e = *ErrNotRunning()
	case DaemonInternalError:
		var value struct {
			Message *string `json:"message"`
		}
		if err := decodeRequiredObject(payload, "internalError error", &value); err != nil {
			return err
		}
		if value.Message == nil {
			return fmt.Errorf("internalError error requires message")
		}
		*e = *ErrInternal(*value.Message)
	default:
		return fmt.Errorf("unknown daemon error case %q", kind)
	}
	return nil
}

// RuntimeStatus is the service state pushed to IPC subscribers.
type RuntimeStatus struct {
	Engine           EngineState            `json:"engine"`
	Tunnels          map[string]TunnelState `json:"tunnels"`
	PlanHash         string                 `json:"planHash,omitempty"`
	DiscoveredDNS    map[string][]string    `json:"discoveredDNS"`
	ResolverOverride ResolverOverrideState  `json:"resolverOverride"`
}

// StoppedStatus returns the initial service status with non-nil maps.
func StoppedStatus() RuntimeStatus {
	return RuntimeStatus{
		Engine: NewEngineStopped(), Tunnels: map[string]TunnelState{},
		DiscoveredDNS: map[string][]string{}, ResolverOverride: NewResolverOverrideOff(),
	}
}

// MarshalJSON emits non-null status maps and omits an empty plan hash.
func (s RuntimeStatus) MarshalJSON() ([]byte, error) {
	object := map[string]any{
		"discoveredDNS":    nonNilStringSlices(s.DiscoveredDNS),
		"engine":           s.Engine,
		"resolverOverride": s.ResolverOverride,
		"tunnels":          nonNilMap(s.Tunnels),
	}
	if s.PlanHash != "" {
		object["planHash"] = s.PlanHash
	}
	return MarshalWire(object)
}

// UnmarshalJSON decodes status and defaults fields added after the original contract.
func (s *RuntimeStatus) UnmarshalJSON(data []byte) error {
	var wire struct {
		DiscoveredDNS    *map[string][]string    `json:"discoveredDNS"`
		Engine           *EngineState            `json:"engine"`
		PlanHash         *string                 `json:"planHash"`
		ResolverOverride *ResolverOverrideState  `json:"resolverOverride"`
		Tunnels          *map[string]TunnelState `json:"tunnels"`
	}
	if err := decodeRequiredObject(data, "runtime status", &wire); err != nil {
		return err
	}
	if wire.Engine == nil || wire.Tunnels == nil {
		return fmt.Errorf("runtime status requires engine and tunnels")
	}
	discoveredDNS := map[string][]string{}
	if wire.DiscoveredDNS != nil {
		discoveredDNS = *wire.DiscoveredDNS
	}
	resolver := NewResolverOverrideOff()
	if wire.ResolverOverride != nil {
		resolver = *wire.ResolverOverride
	}
	planHash := ""
	if wire.PlanHash != nil {
		planHash = *wire.PlanHash
	}
	*s = RuntimeStatus{
		Engine: *wire.Engine, Tunnels: *wire.Tunnels, PlanHash: planHash,
		DiscoveredDNS: discoveredDNS, ResolverOverride: resolver,
	}
	return nil
}

// LogLine is one structured daemon or child-process log record.
type LogLine struct {
	TS      Timestamp `json:"ts"`
	Source  string    `json:"source"`
	Level   LogLevel  `json:"level"`
	Message string    `json:"message"`
}

// MarshalJSON emits a log line with sorted wire keys.
func (l LogLine) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"level": l.Level, "message": l.Message, "source": l.Source, "ts": l.TS,
	})
}

// UnmarshalJSON strictly decodes a log line.
func (l *LogLine) UnmarshalJSON(data []byte) error {
	var wire struct {
		Level   *LogLevel  `json:"level"`
		Message *string    `json:"message"`
		Source  *string    `json:"source"`
		TS      *Timestamp `json:"ts"`
	}
	if err := decodeRequiredObject(data, "log line", &wire); err != nil {
		return err
	}
	if wire.Level == nil || wire.Message == nil || wire.Source == nil || wire.TS == nil {
		return fmt.Errorf("log line requires level, message, source, and ts")
	}
	*l = LogLine{TS: *wire.TS, Source: *wire.Source, Level: *wire.Level, Message: *wire.Message}
	return nil
}

// ApplyResult is the reply to apply and stop IPC requests.
type ApplyResult struct {
	OK    bool         `json:"ok"`
	Error *DaemonError `json:"error,omitempty"`
}

// ApplySuccess returns a successful apply result.
func ApplySuccess() ApplyResult { return ApplyResult{OK: true} }

// ApplyFailure returns a failed apply result.
func ApplyFailure(err *DaemonError) ApplyResult { return ApplyResult{Error: err} }

// MarshalJSON emits an apply result and omits a nil error.
func (r ApplyResult) MarshalJSON() ([]byte, error) {
	object := map[string]any{"ok": r.OK}
	if r.Error != nil {
		object["error"] = r.Error
	}
	return MarshalWire(object)
}

// UnmarshalJSON strictly decodes an apply result.
func (r *ApplyResult) UnmarshalJSON(data []byte) error {
	var wire struct {
		Error *DaemonError `json:"error"`
		OK    *bool        `json:"ok"`
	}
	if err := decodeRequiredObject(data, "apply result", &wire); err != nil {
		return err
	}
	if wire.OK == nil {
		return fmt.Errorf("apply result requires ok")
	}
	*r = ApplyResult{OK: *wire.OK, Error: wire.Error}
	return nil
}

// DaemonInfo describes the installed service and bundled child binaries.
type DaemonInfo struct {
	Version        string `json:"version"`
	InstallPath    string `json:"installPath"`
	BuildID        string `json:"buildID,omitempty"`
	SingBoxVersion string `json:"singBoxVersion"`
	OpenVPNVersion string `json:"openVPNVersion"`
}

// MarshalJSON emits daemon information and omits an empty build ID.
func (i DaemonInfo) MarshalJSON() ([]byte, error) {
	object := map[string]any{
		"installPath": i.InstallPath, "openVPNVersion": i.OpenVPNVersion,
		"singBoxVersion": i.SingBoxVersion, "version": i.Version,
	}
	if i.BuildID != "" {
		object["buildID"] = i.BuildID
	}
	return MarshalWire(object)
}

// TrafficCounters contains rates, totals, and the current connection count for one exit.
type TrafficCounters struct {
	DownBytesPerSecond float64 `json:"downBytesPerSecond"`
	UpBytesPerSecond   float64 `json:"upBytesPerSecond"`
	DownTotal          uint64  `json:"downTotal"`
	UpTotal            uint64  `json:"upTotal"`
	Connections        int     `json:"connections"`
	// UDP connections that sent but received nothing for OneWayUDPGrace — the signature
	// of a tunnel server dropping UDP (H3). An aggregate count; no hosts or addresses.
	OneWayUDPFlows int `json:"oneWayUDPFlows"`
}

// IsIdle reports whether no bytes moved during the sampled interval.
func (c TrafficCounters) IsIdle() bool {
	return c.DownBytesPerSecond == 0 && c.UpBytesPerSecond == 0
}

// MarshalJSON emits traffic counters with sorted wire keys.
func (c TrafficCounters) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"connections": c.Connections, "downBytesPerSecond": c.DownBytesPerSecond,
		"downTotal": c.DownTotal, "oneWayUDPFlows": c.OneWayUDPFlows,
		"upBytesPerSecond": c.UpBytesPerSecond, "upTotal": c.UpTotal,
	})
}

// TrafficSnapshot is one traffic sample pushed while sing-box is running.
type TrafficSnapshot struct {
	SampledAt Timestamp                  `json:"sampledAt"`
	Interval  float64                    `json:"interval"`
	Tunnels   map[string]TrafficCounters `json:"tunnels"`
	Direct    TrafficCounters            `json:"direct"`
}

// CountersForTunnel returns zero counters when id is absent.
func (s TrafficSnapshot) CountersForTunnel(id string) TrafficCounters {
	return s.Tunnels[id]
}

// MarshalJSON emits a traffic snapshot with a non-null tunnels map.
func (s TrafficSnapshot) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"direct": s.Direct, "interval": s.Interval, "sampledAt": s.SampledAt,
		"tunnels": nonNilMap(s.Tunnels),
	})
}

// DaemonDiagnostics is root-side material for a diagnostics export.
type DaemonDiagnostics struct {
	DaemonLogTail       []string            `json:"daemonLogTail"`
	ChildLogTails       map[string][]string `json:"childLogTails"`
	RunDirectoryListing []string            `json:"runDirectoryListing"`
	Routes              string              `json:"routes"`
}

// MarshalJSON emits diagnostic collections as arrays and objects, never null.
func (d DaemonDiagnostics) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"childLogTails": nonNilStringSlices(d.ChildLogTails),
		"daemonLogTail": nonNilSlice(d.DaemonLogTail),
		"routes":        d.Routes, "runDirectoryListing": nonNilSlice(d.RunDirectoryListing),
	})
}
