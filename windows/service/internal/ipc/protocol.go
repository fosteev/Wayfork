// Package ipc is the app↔service channel: newline-delimited JSON over a named pipe
// (docs/design/08-windows.md, "IPC"). The framing and the method set live here and are
// tested everywhere; the pipe itself is Windows-only (pipe_windows.go).
package ipc

import (
	"context"
	"encoding/json"

	"wayfork/service/internal/core"
)

// PipeName is the service's named pipe.
const PipeName = `\\.\pipe\wayfork`

// ProtocolVersion is the framing version announced in the hello event; a mismatch is a
// hard error in the app.
const ProtocolVersion = 1

// MaxLineBytes bounds one message: a plan carries the sing-box config, the rule-sets and
// the OpenVPN bodies, each at most core.MaxConfigBytes.
const MaxLineBytes = 64 << 20

// Methods the app calls (the macOS XPC interface, docs/design/05-daemon.md), plus the
// read-only diagnostics methods `wayforkctl` alone calls (#2): `getConnections` and
// `explain`. No new access class: every authenticated user can already call
// apply/stop/diagnostics over this pipe.
const (
	MethodGetInfo            = "getInfo"
	MethodGetStatus          = "getStatus"
	MethodSubscribe          = "subscribe"
	MethodApply              = "apply"
	MethodStop               = "stop"
	MethodReconnect          = "reconnect"
	MethodCollectDiagnostics = "collectDiagnostics"
	MethodGetConnections     = "getConnections"
	MethodExplain            = "explain"
)

// Events the service pushes (the macOS WayforkClientXPC methods, plus the hello).
const (
	EventHello          = "hello"
	EventStatusChanged  = "statusChanged"
	EventLogLines       = "logLines"
	EventTrafficChanged = "trafficChanged"
)

// Message is one line on the pipe: a request (`id`, `method`, `params`), a response (`id`,
// `result` or `error`) or an event (`event`, `data`).
type Message struct {
	ID     *int64          `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
	Event  string          `json:"event,omitempty"`
	Data   json.RawMessage `json:"data,omitempty"`
}

// Hello is the first event on every connection.
type Hello struct {
	Protocol    int    `json:"protocol"`
	PlanVersion int    `json:"planVersion"`
	Version     string `json:"version"`
}

// ReconnectParams are the params of `reconnect`.
type ReconnectParams struct {
	ID string `json:"id"`
}

// CollectDiagnosticsParams are collectDiagnostics' optional params: `tail` overrides the
// service's default line cap (#2). Absent or <= 0 means the default; the service applies
// its own upper cap.
type CollectDiagnosticsParams struct {
	Tail int `json:"tail,omitempty"`
}

// Sink receives the pushes of one subscribed connection.
type Sink interface {
	StatusChanged(status core.RuntimeStatus)
	LogLines(lines []core.LogLine)
	TrafficChanged(snapshot core.TrafficSnapshot)
}

// Handler implements the methods; the supervisor is the real one.
type Handler interface {
	GetInfo(ctx context.Context) core.DaemonInfo
	GetStatus(ctx context.Context) core.RuntimeStatus
	Apply(ctx context.Context, plan core.RuntimePlan) core.ApplyResult
	Stop(ctx context.Context) core.ApplyResult
	Reconnect(ctx context.Context, id string) core.ApplyResult
	// CollectDiagnostics: tail <= 0 means the handler's own default.
	CollectDiagnostics(ctx context.Context, tail int) core.DaemonDiagnostics
	// GetConnections is the sampler's last decoded sample, or an empty snapshot when
	// sing-box has not produced one yet (#2).
	GetConnections(ctx context.Context) core.ConnectionsSnapshot
	// Explain answers `wayforkctl explain` from the currently applied plan (#2). The
	// server has already checked that exactly one of query's fields is set.
	Explain(ctx context.Context, query core.ExplainQuery) core.ExplainResult
	// Subscribe registers the connection's sink for pushes until Unsubscribe.
	Subscribe(ctx context.Context, sink Sink) core.ApplyResult
	Unsubscribe(sink Sink)
}

// encode renders a message with core.MarshalWire (no HTML escaping) plus the newline.
func encode(message Message) ([]byte, error) {
	data, err := core.MarshalWire(message)
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

// wirePayload renders a payload for a `result` or `data` field.
func wirePayload(value any) (json.RawMessage, error) {
	data, err := core.MarshalWire(value)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(data), nil
}
