package core

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// The literals below are the ones pinned by the Dart core (test/core/ipc_test.dart); the
// three clients must agree byte for byte.

func TestEngineStateWireCases(t *testing.T) {
	cases := map[string]EngineState{
		`{"stopped":{}}`:  NewEngineStopped(),
		`{"starting":{}}`: NewEngineStarting(),
		`{"running":{"since":"2026-08-25T12:00:00Z"}}`: NewEngineRunning(fixtureDate),
		`{"failed":{"reason":"boom"}}`:                 NewEngineFailed("boom"),
	}
	for wire, state := range cases {
		if got := mustMarshal(t, state); got != wire {
			t.Errorf("encode %v = %s, want %s", state.Kind, got, wire)
		}
		var decoded EngineState
		mustUnmarshal(t, wire, &decoded)
		if got := mustMarshal(t, decoded); got != wire {
			t.Errorf("round trip of %s gave %s", wire, got)
		}
	}
	if !NewEngineRunning(fixtureDate).IsRunning() || NewEngineStarting().IsRunning() {
		t.Error("IsRunning is wrong")
	}
	for _, bad := range []string{`{"exploded":{}}`, `{"running":{}}`, `{"failed":null}`, `{}`, `[]`, `{"stopped":{},"starting":{}}`} {
		var decoded EngineState
		if err := json.Unmarshal([]byte(bad), &decoded); err == nil {
			t.Errorf("decoding %s should fail", bad)
		}
	}
}

func TestTunnelStateWireCases(t *testing.T) {
	cases := map[string]TunnelState{
		`{"disabled":{}}`:              NewTunnelDisabled(),
		`{"connecting":{"attempt":2}}`: NewTunnelConnecting(2),
		`{"connected":{"interface":"Wayfork-1","ip":"10.8.0.2","since":"2026-08-25T12:00:00Z"}}`: NewTunnelConnected(fixtureDate, "10.8.0.2", "Wayfork-1"),
		`{"connected":{"interface":"Wayfork-1","since":"2026-08-25T12:00:00Z"}}`:                 NewTunnelConnected(fixtureDate, "", "Wayfork-1"),
		`{"reconnecting":{"attempt":3,"nextIn":4.5,"reason":"ping"}}`:                            NewTunnelReconnecting(3, 4.5, "ping"),
		`{"reconnecting":{"attempt":1,"nextIn":0}}`:                                              NewTunnelReconnecting(1, 0, ""),
		`{"failed":{"permanent":true,"reason":"auth"}}`:                                          NewTunnelFailed("auth", true),
	}
	for wire, state := range cases {
		if got := mustMarshal(t, state); got != wire {
			t.Errorf("encode %v = %s, want %s", state.Kind, got, wire)
		}
		var decoded TunnelState
		mustUnmarshal(t, wire, &decoded)
		if got := mustMarshal(t, decoded); got != wire {
			t.Errorf("round trip of %s gave %s", wire, got)
		}
	}
	if !NewTunnelConnected(fixtureDate, "", "Wayfork-1").IsConnected() || NewTunnelConnecting(1).IsConnected() {
		t.Error("IsConnected is wrong")
	}
	for _, bad := range []string{`{"connected":{"since":"2026-08-25T12:00:00Z"}}`, `{"failed":{"reason":"x"}}`, `{"connecting":{"attempt":"2"}}`} {
		var decoded TunnelState
		if err := json.Unmarshal([]byte(bad), &decoded); err == nil {
			t.Errorf("decoding %s should fail", bad)
		}
	}
}

func TestResolverOverrideStateWireCases(t *testing.T) {
	cases := map[string]ResolverOverrideState{
		`{"off":{}}`:                          NewResolverOverrideOff(),
		`{"active":{"service":"Ethernet"}}`:   NewResolverOverrideActive("Ethernet"),
		`{"shadowed":{"manual":["1.1.1.1"]}}`: NewResolverOverrideShadowed([]string{"1.1.1.1"}),
		`{"shadowed":{"manual":[]}}`:          NewResolverOverrideShadowed(nil),
		`{"failed":{"reason":"denied"}}`:      NewResolverOverrideFailed("denied"),
	}
	for wire, state := range cases {
		if got := mustMarshal(t, state); got != wire {
			t.Errorf("encode %v = %s, want %s", state.Kind, got, wire)
		}
		var decoded ResolverOverrideState
		mustUnmarshal(t, wire, &decoded)
		if got := mustMarshal(t, decoded); got != wire {
			t.Errorf("round trip of %s gave %s", wire, got)
		}
	}
}

func TestDaemonErrorWireCases(t *testing.T) {
	cases := map[string]*DaemonError{
		`{"binaryUntrusted":{"path":"C:\\bad.exe"}}`: ErrBinaryUntrusted(`C:\bad.exe`),
		`{"planInvalid":{"reason":"too many"}}`:      ErrPlanInvalid("too many"),
		`{"configInvalid":{"output":"bad"}}`:         ErrConfigInvalid("bad"),
		`{"startFailed":{"logTail":["one","two"]}}`:  ErrStartFailed([]string{"one", "two"}),
		`{"startFailed":{"logTail":[]}}`:             ErrStartFailed(nil),
		`{"tunnelNotFound":{"id":"x"}}`:              ErrTunnelNotFound("x"),
		`{"notRunning":{}}`:                          ErrNotRunning(),
		`{"internalError":{"message":"oops"}}`:       ErrInternal("oops"),
	}
	for wire, daemonError := range cases {
		if got := mustMarshal(t, daemonError); got != wire {
			t.Errorf("encode %v = %s, want %s", daemonError.Kind, got, wire)
		}
		var decoded DaemonError
		mustUnmarshal(t, wire, &decoded)
		if got := mustMarshal(t, &decoded); got != wire {
			t.Errorf("round trip of %s gave %s", wire, got)
		}
		if decoded.Error() == "" {
			t.Errorf("%s has an empty error message", wire)
		}
	}
	var err error = ErrPlanInvalid("too many")
	if !strings.Contains(err.Error(), "too many") {
		t.Errorf("error message %q lacks the reason", err.Error())
	}
}

func TestRuntimeStatusWire(t *testing.T) {
	status := RuntimeStatus{
		Engine: NewEngineRunning(fixtureDate),
		Tunnels: map[string]TunnelState{
			"a": NewTunnelConnected(fixtureDate, "10.8.0.2", "Wayfork-1"),
			"b": NewTunnelReconnecting(3, 4, "ping-restart"),
			"c": NewTunnelFailed("auth", true),
		},
		PlanHash:         "h",
		DiscoveredDNS:    map[string][]string{"a": {"10.8.0.1"}},
		ResolverOverride: NewResolverOverrideActive("NRPT"),
	}
	want := `{"discoveredDNS":{"a":["10.8.0.1"]},"engine":{"running":{"since":"2026-08-25T12:00:00Z"}},` +
		`"planHash":"h","resolverOverride":{"active":{"service":"NRPT"}},` +
		`"tunnels":{"a":{"connected":{"interface":"Wayfork-1","ip":"10.8.0.2","since":"2026-08-25T12:00:00Z"}},` +
		`"b":{"reconnecting":{"attempt":3,"nextIn":4,"reason":"ping-restart"}},` +
		`"c":{"failed":{"permanent":true,"reason":"auth"}}}}`
	if got := mustMarshal(t, status); got != want {
		t.Errorf("status encoded as\n%s\nwant\n%s", got, want)
	}
	var decoded RuntimeStatus
	mustUnmarshal(t, want, &decoded)
	if got := mustMarshal(t, decoded); got != want {
		t.Errorf("status round trip gave\n%s", got)
	}

	stopped := `{"discoveredDNS":{},"engine":{"stopped":{}},"resolverOverride":{"off":{}},"tunnels":{}}`
	if got := mustMarshal(t, StoppedStatus()); got != stopped {
		t.Errorf("stopped status = %s, want %s", got, stopped)
	}
	if got := mustMarshal(t, RuntimeStatus{Engine: NewEngineStopped()}); got != stopped {
		t.Errorf("zero-value maps must encode as {}: %s", got)
	}
	// The original macOS contract had neither discoveredDNS nor resolverOverride.
	var legacy RuntimeStatus
	mustUnmarshal(t, `{"engine":{"stopped":{}},"tunnels":{}}`, &legacy)
	if got := mustMarshal(t, legacy); got != stopped {
		t.Errorf("legacy status decoded as %s", got)
	}
	var missing RuntimeStatus
	if err := json.Unmarshal([]byte(`{"engine":{"stopped":{}}}`), &missing); err == nil {
		t.Error("a status without tunnels must be rejected")
	}
}

func TestSmallPayloadsWire(t *testing.T) {
	line := LogLine{TS: NewTimestamp(fixtureDate), Source: "openvpn:" + idA, Level: LogLevelWarning, Message: "a <b> & c"}
	wantLine := `{"level":"warning","message":"a <b> & c","source":"openvpn:` + idA + `","ts":"2026-08-25T12:00:00Z"}`
	if got := mustMarshal(t, line); got != wantLine {
		t.Errorf("log line = %s, want %s", got, wantLine)
	}
	var decodedLine LogLine
	mustUnmarshal(t, wantLine, &decodedLine)
	if decodedLine != line {
		t.Errorf("log line round trip = %+v", decodedLine)
	}
	var badLevel LogLine
	if err := json.Unmarshal([]byte(`{"level":"loud","message":"m","source":"s","ts":"2026-08-25T12:00:00Z"}`), &badLevel); err == nil {
		t.Error("an unknown log level must be rejected")
	}

	if got := mustMarshal(t, ApplySuccess()); got != `{"ok":true}` {
		t.Errorf("apply success = %s", got)
	}
	failure := ApplyFailure(ErrConfigInvalid("bad json"))
	wantFailure := `{"error":{"configInvalid":{"output":"bad json"}},"ok":false}`
	if got := mustMarshal(t, failure); got != wantFailure {
		t.Errorf("apply failure = %s, want %s", got, wantFailure)
	}
	var decodedFailure ApplyResult
	mustUnmarshal(t, wantFailure, &decodedFailure)
	if decodedFailure.OK || decodedFailure.Error == nil || decodedFailure.Error.Output != "bad json" {
		t.Errorf("apply failure round trip = %+v", decodedFailure)
	}

	info := DaemonInfo{Version: "0.1.0", InstallPath: `C:\Program Files\Wayfork`, SingBoxVersion: "1.12.0", OpenVPNVersion: "2.7.6"}
	wantInfo := `{"installPath":"C:\\Program Files\\Wayfork","openVPNVersion":"2.7.6","singBoxVersion":"1.12.0","version":"0.1.0"}`
	if got := mustMarshal(t, info); got != wantInfo {
		t.Errorf("daemon info = %s, want %s", got, wantInfo)
	}
	info.BuildID = "abc"
	if got := mustMarshal(t, info); !strings.Contains(got, `"buildID":"abc"`) {
		t.Errorf("build id missing from %s", got)
	}
	var decodedInfo DaemonInfo
	mustUnmarshal(t, wantInfo, &decodedInfo)
	if decodedInfo.InstallPath != info.InstallPath || decodedInfo.BuildID != "" {
		t.Errorf("daemon info round trip = %+v", decodedInfo)
	}

	counters := TrafficCounters{DownBytesPerSecond: 12.5, UpBytesPerSecond: 2, DownTotal: 100, UpTotal: 20, Connections: 3, OneWayUDPFlows: 1}
	if counters.IsIdle() || !(TrafficCounters{}).IsIdle() {
		t.Error("IsIdle is wrong")
	}
	snapshot := TrafficSnapshot{SampledAt: NewTimestamp(fixtureDate), Interval: 1.25, Tunnels: map[string]TrafficCounters{"a": counters}}
	wantSnapshot := `{"direct":{"connections":0,"downBytesPerSecond":0,"downTotal":0,"oneWayUDPFlows":0,"upBytesPerSecond":0,"upTotal":0},` +
		`"interval":1.25,"sampledAt":"2026-08-25T12:00:00Z",` +
		`"tunnels":{"a":{"connections":3,"downBytesPerSecond":12.5,"downTotal":100,"oneWayUDPFlows":1,"upBytesPerSecond":2,"upTotal":20}}}`
	if got := mustMarshal(t, snapshot); got != wantSnapshot {
		t.Errorf("snapshot = %s, want %s", got, wantSnapshot)
	}
	var decodedSnapshot TrafficSnapshot
	mustUnmarshal(t, wantSnapshot, &decodedSnapshot)
	if decodedSnapshot.CountersForTunnel("a") != counters || decodedSnapshot.CountersForTunnel("missing") != (TrafficCounters{}) {
		t.Errorf("snapshot round trip = %+v", decodedSnapshot)
	}
	if got := mustMarshal(t, TrafficSnapshot{}); !strings.Contains(got, `"tunnels":{}`) {
		t.Errorf("nil tunnels must encode as {}: %s", got)
	}

	diagnostics := DaemonDiagnostics{Routes: "r"}
	wantDiagnostics := `{"childLogTails":{},"daemonLogTail":[],"routes":"r","runDirectoryListing":[]}`
	if got := mustMarshal(t, diagnostics); got != wantDiagnostics {
		t.Errorf("diagnostics = %s, want %s", got, wantDiagnostics)
	}
}

func TestTimestampParsing(t *testing.T) {
	cases := map[string]time.Time{
		`"2026-08-25T12:00:00Z"`:             fixtureDate,
		`"2026-08-25T12:00:00.250Z"`:         fixtureDate.Add(250 * time.Millisecond),
		`"2026-08-25T15:00:00+03:00"`:        fixtureDate,
		`"2026-08-25T12:00:00.000000+00:00"`: fixtureDate,
	}
	for wire, want := range cases {
		var ts Timestamp
		mustUnmarshal(t, wire, &ts)
		if !ts.Equal(want) || ts.Location() != time.UTC {
			t.Errorf("%s parsed as %v", wire, ts)
		}
	}
	// Whole seconds, UTC on the way out — whatever came in.
	local := Timestamp{Time: time.Date(2026, 8, 25, 15, 0, 0, 999_000_000, time.FixedZone("MSK", 3*3600))}
	if got := mustMarshal(t, local); got != `"2026-08-25T12:00:00Z"` {
		t.Errorf("timestamp encoded as %s", got)
	}
	for _, bad := range []string{`"2026-08-25 12:00:00"`, `"yesterday"`, `1756123200`, `null`} {
		var ts Timestamp
		if err := json.Unmarshal([]byte(bad), &ts); err == nil {
			t.Errorf("decoding %s should fail", bad)
		}
	}
}

func TestLogLevel(t *testing.T) {
	for _, level := range []LogLevel{LogLevelError, LogLevelWarning, LogLevelInfo, LogLevelDebug} {
		parsed, err := ParseLogLevel(string(level))
		if err != nil || parsed != level {
			t.Errorf("ParseLogLevel(%q) = %q, %v", level, parsed, err)
		}
	}
	if _, err := ParseLogLevel("verbose"); err == nil {
		t.Error("ParseLogLevel must reject unknown levels")
	}
	verbosity := map[LogLevel]int{LogLevelDebug: 4, LogLevelInfo: 3, LogLevelWarning: 1, LogLevelError: 1}
	for level, want := range verbosity {
		if got := level.OpenVPNVerbosity(); got != want {
			t.Errorf("%s verbosity = %d, want %d", level, got, want)
		}
	}
	singBox := map[LogLevel]string{LogLevelDebug: "debug", LogLevelInfo: "info", LogLevelWarning: "warn", LogLevelError: "error"}
	for level, want := range singBox {
		if got := level.SingBoxLevel(); got != want {
			t.Errorf("%s sing-box level = %s, want %s", level, got, want)
		}
	}
	if !(LogLevelError.Rank() < LogLevelWarning.Rank() && LogLevelWarning.Rank() < LogLevelInfo.Rank() && LogLevelInfo.Rank() < LogLevelDebug.Rank()) {
		t.Error("ranks are not ordered error < warning < info < debug")
	}
	if _, err := json.Marshal(LogLevel("loud")); err == nil {
		t.Error("an invalid level must not reach the wire")
	}
}
