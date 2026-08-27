package core

import (
	"reflect"
	"slices"
	"testing"
	"time"
)

const reducerTunnelID = "11111111-2222-3333-4444-555555555555"

func newReducer(credentials *Credentials, keyPassphrase *string) *OpenVPNSessionReducer {
	return NewOpenVPNSessionReducer(ReducerContext{
		ID: reducerTunnelID, Interface: "Wayfork-1", Credentials: credentials, KeyPassphrase: keyPassphrase,
	})
}

func sends(effects []ReducerEffect) []string {
	var commands []string
	for _, effect := range effects {
		if effect.Kind == EffectSend {
			commands = append(commands, effect.Command)
		}
	}
	return commands
}

func containsEffect(effects []ReducerEffect, want ReducerEffect) bool {
	for _, effect := range effects {
		if reflect.DeepEqual(effect, want) {
			return true
		}
	}
	return false
}

func stateInput(name, description, ip string) ReducerInput {
	return ManagementInput(ManagementEvent{Kind: EventState, State: ManagementState{Name: name, Description: description, TunnelIP: ip}})
}

func logInput(flags, message string) ReducerInput {
	return ManagementInput(ManagementEvent{Kind: EventLog, Flags: flags, Message: message})
}

func passwordNeeded(kind string) ReducerInput {
	return ManagementInput(ManagementEvent{Kind: EventPasswordNeeded, PasswordKind: kind})
}

func expectState(t *testing.T, r *OpenVPNSessionReducer, want TunnelState) {
	t.Helper()
	if got := r.State(); !reflect.DeepEqual(got, want) {
		t.Errorf("state = %+v, want %+v", got, want)
	}
}

var now = time.Date(2026, 8, 27, 20, 0, 0, 0, time.UTC)

func TestHappyPathConnectsAddsRouteAndReportsDNS(t *testing.T) {
	r := newReducer(&Credentials{Username: "u", Password: "p"}, nil)
	r.Handle(ProcessStarted(1), now)
	expectState(t, r, NewTunnelConnecting(1))

	hello := r.Handle(ManagementConnected(), now)
	if got := sends(hello); !slices.Equal(got, []string{"state on", "log on", "bytecount 5", "hold release"}) {
		t.Errorf("hello sends %q", got)
	}
	auth := r.Handle(passwordNeeded("Auth"), now)
	if got := sends(auth); !slices.Equal(got, []string{`username "Auth" "u"`, `password "Auth" "p"`}) {
		t.Errorf("auth sends %q", got)
	}
	r.Handle(stateInput("WAIT", "", ""), now)
	expectState(t, r, NewTunnelConnecting(1))

	push := r.Handle(logInput("I", "PUSH: Received control message: 'PUSH_REPLY,dhcp-option DNS 10.8.0.1,route-gateway 10.8.0.1,ifconfig 10.8.0.27 255.255.255.0'"), now)
	if !containsEffect(push, DiscoveredDNSEffect([]string{"10.8.0.1"})) {
		t.Errorf("push effects %+v lack the DNS", push)
	}

	connected := r.Handle(stateInput("CONNECTED", "SUCCESS", "10.8.0.27"), now)
	expectState(t, r, NewTunnelConnected(now, "10.8.0.27", "Wayfork-1"))
	if !containsEffect(connected, AddScopedRouteEffect("Wayfork-1", "10.8.0.1")) {
		t.Errorf("connected effects %+v lack the scoped route with the pushed gateway", connected)
	}
	for _, effect := range connected {
		if effect.Kind == EffectLog && effect.Level == LogLevelWarning {
			t.Errorf("unexpected warning %q", effect.Message)
		}
	}
	// A second CONNECTED (after openvpn's own soft reset) must not add the route twice.
	again := r.Handle(stateInput("CONNECTED", "SUCCESS", "10.8.0.27"), now)
	for _, effect := range again {
		if effect.Kind == EffectAddScopedRoute {
			t.Error("the route was added twice")
		}
	}
}

func TestConnectedWithoutPushedGatewayFallsBackToOnLink(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ManagementConnected(), now)
	effects := r.Handle(stateInput("CONNECTED", "SUCCESS", "10.8.0.2"), now)
	if !containsEffect(effects, AddScopedRouteEffect("Wayfork-1", "")) {
		t.Errorf("effects %+v lack the on-link route", effects)
	}
	if !containsEffect(effects, LogEffect(LogLevelWarning, "no route-gateway pushed for Wayfork-1; using an on-link default")) {
		t.Errorf("effects %+v lack the warning", effects)
	}
	// The gateway learned by one process does not leak into the next spawn.
	r.Handle(logInput("I", "PUSH: Received control message: 'PUSH_REPLY,route-gateway 10.8.0.1'"), now)
	r.Handle(ProcessExited(1), now)
	r.Handle(ProcessStarted(2), now)
	r.Handle(ManagementConnected(), now)
	restarted := r.Handle(stateInput("CONNECTED", "SUCCESS", "10.8.0.2"), now)
	if !containsEffect(restarted, AddScopedRouteEffect("Wayfork-1", "")) {
		t.Errorf("effects %+v reused a stale gateway", restarted)
	}
}

func TestGatewayFromStdoutBeforeManagement(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ProcessLine("1787840212.640000 1 PUSH: Received control message: 'PUSH_REPLY,route-gateway 192.168.35.1,ifconfig 192.168.35.112 255.255.255.0'"), now)
	r.Handle(ManagementConnected(), now)
	effects := r.Handle(stateInput("CONNECTED", "SUCCESS", "192.168.35.112"), now)
	if !containsEffect(effects, AddScopedRouteEffect("Wayfork-1", "192.168.35.1")) {
		t.Errorf("effects %+v lack the gateway seen on stdout", effects)
	}
}

func TestEveryHoldIsReleased(t *testing.T) {
	// openvpn hibernates again after each soft restart (`--management-hold` is persistent).
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ManagementConnected(), now)
	first := r.Handle(ManagementInput(ManagementEvent{Kind: EventHold, Message: "Waiting for hold release:0"}), now)
	if got := sends(first); !slices.Equal(got, []string{"hold release"}) {
		t.Errorf("first hold sends %q", got)
	}
	r.Handle(stateInput("WAIT", "", ""), now)
	r.Handle(stateInput("RECONNECTING", "server_poll", ""), now)
	expectState(t, r, NewTunnelReconnecting(1, 0, "server_poll"))
	again := r.Handle(ManagementInput(ManagementEvent{Kind: EventHold, Message: "Waiting for hold release:0"}), now)
	if got := sends(again); !slices.Equal(got, []string{"hold release"}) {
		t.Errorf("second hold sends %q", got)
	}
	expectState(t, r, NewTunnelReconnecting(1, 0, "server_poll"))
}

func TestReconnectingDropsRouteAndExitIsTransient(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ManagementConnected(), now)
	r.Handle(stateInput("CONNECTED", "SUCCESS", "10.8.0.2"), now)

	reconnecting := r.Handle(stateInput("RECONNECTING", "ping-restart", ""), now)
	if !containsEffect(reconnecting, DeleteScopedRouteEffect("Wayfork-1")) {
		t.Errorf("effects %+v lack the route deletion", reconnecting)
	}
	expectState(t, r, NewTunnelReconnecting(1, 0, "ping-restart"))

	r.Handle(ManagementClosed(), now)
	exited := r.Handle(ProcessExited(9), now)
	if !containsEffect(exited, ExitedEffect(TransientExit("ping-restart"))) {
		t.Errorf("effects %+v lack the transient exit", exited)
	}
	if containsEffect(exited, DeleteScopedRouteEffect("Wayfork-1")) {
		t.Error("the route was deleted twice")
	}

	r.Handle(RestartScheduled(2, 2*time.Second), now)
	expectState(t, r, NewTunnelReconnecting(2, 2, "ping-restart"))
	r.Handle(ProcessStarted(2), now)
	expectState(t, r, NewTunnelConnecting(2))
	if r.Attempt() != 2 {
		t.Errorf("attempt = %d", r.Attempt())
	}
}

func TestExitWhileConnectedRemovesRoute(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ManagementConnected(), now)
	r.Handle(stateInput("CONNECTED", "SUCCESS", "10.8.0.2"), now)
	exited := r.Handle(ProcessExited(1), now)
	if !containsEffect(exited, DeleteScopedRouteEffect("Wayfork-1")) {
		t.Errorf("effects %+v lack the route deletion", exited)
	}
	if !containsEffect(exited, ExitedEffect(TransientExit("exit status 1"))) {
		t.Errorf("effects %+v lack the transient exit", exited)
	}
}

func TestMissingCredentialsIsPermanent(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ManagementConnected(), now)
	effects := r.Handle(passwordNeeded("Auth"), now)
	if got := sends(effects); !slices.Equal(got, []string{"signal SIGTERM"}) {
		t.Errorf("sends %q", got)
	}
	expectState(t, r, NewTunnelFailed("ovpn.needsCredentials", true))
	// Later prompts are ignored while we wait for the process to die.
	if got := sends(r.Handle(passwordNeeded("Auth"), now)); len(got) != 0 {
		t.Errorf("late prompt sends %q", got)
	}
	exited := r.Handle(ProcessExited(0), now)
	if !containsEffect(exited, ExitedEffect(PermanentExit(FailureNeedsCredentials))) {
		t.Errorf("effects %+v lack the permanent exit", exited)
	}
	expectState(t, r, NewTunnelFailed("ovpn.needsCredentials", true))
}

func TestAuthRejectedAndKeyPassphraseArePermanent(t *testing.T) {
	r := newReducer(&Credentials{Username: "u", Password: "p"}, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ManagementConnected(), now)
	r.Handle(ManagementInput(ManagementEvent{Kind: EventPasswordVerificationFailed, PasswordKind: "Auth"}), now)
	expectState(t, r, NewTunnelFailed("ovpn.authFailed", true))
	// RECONNECTING after the failure does not resurrect the tunnel.
	r.Handle(stateInput("RECONNECTING", "auth-failure", ""), now)
	expectState(t, r, NewTunnelFailed("ovpn.authFailed", true))

	wrong := "wrong"
	k := newReducer(nil, &wrong)
	k.Handle(ProcessStarted(1), now)
	k.Handle(ManagementConnected(), now)
	if got := sends(k.Handle(passwordNeeded("Private Key"), now)); !slices.Equal(got, []string{`password "Private Key" "wrong"`}) {
		t.Errorf("passphrase sends %q", got)
	}
	k.Handle(ManagementInput(ManagementEvent{Kind: EventFatal, Message: "Error: private key password verification failed"}), now)
	expectState(t, k, NewTunnelFailed("ovpn.keyPassphrase", true))

	n := newReducer(nil, nil)
	n.Handle(ProcessStarted(1), now)
	n.Handle(ManagementConnected(), now)
	n.Handle(passwordNeeded("Private Key"), now)
	expectState(t, n, NewTunnelFailed("ovpn.needsKeyPassphrase", true))

	p := newReducer(nil, nil)
	p.Handle(ProcessStarted(1), now)
	p.Handle(ManagementConnected(), now)
	p.Handle(passwordNeeded("HTTP Proxy"), now)
	expectState(t, p, NewTunnelFailed("ovpn.unsupportedPrompt", true))
}

func TestFatalHandling(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ManagementConnected(), now)
	r.Handle(ManagementInput(ManagementEvent{Kind: EventFatal, Message: "Options error: bad"}), now)
	expectState(t, r, NewTunnelFailed("ovpn.configError", true))

	transient := newReducer(nil, nil)
	transient.Handle(ProcessStarted(1), now)
	transient.Handle(ManagementInput(ManagementEvent{Kind: EventFatal, Message: "TLS Error: TLS handshake failed"}), now)
	expectState(t, transient, NewTunnelConnecting(1))
	exited := transient.Handle(ProcessExited(1), now)
	if !containsEffect(exited, ExitedEffect(TransientExit("TLS Error: TLS handshake failed"))) {
		t.Errorf("effects %+v lack the transient exit with the fatal reason", exited)
	}
	transient.Handle(RetriesDisabled(), now)
	expectState(t, transient, NewTunnelFailed("ovpn.exited", false))

	// The benign --route-nopull noise never fails the tunnel, on either channel.
	benign := "Options error: option 'route' cannot be used in this context ([PUSH-OPTIONS])"
	noise := newReducer(nil, nil)
	noise.Handle(ProcessStarted(1), now)
	noise.Handle(ProcessLine("1787840212.640000 10 "+benign), now)
	noise.Handle(ManagementConnected(), now)
	noise.Handle(logInput("N", benign), now)
	noise.Handle(ManagementInput(ManagementEvent{Kind: EventFatal, Message: benign}), now)
	expectState(t, noise, NewTunnelConnecting(1))
}

func TestLogLinesCarryParsedLevel(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	effects := r.Handle(logInput("W", "WARNING: something"), now)
	if !reflect.DeepEqual(effects, []ReducerEffect{LogEffect(LogLevelWarning, "WARNING: something")}) {
		t.Errorf("effects = %+v", effects)
	}
	// Echoes carry nothing.
	echo := r.Handle(ManagementInput(ManagementEvent{Kind: EventEcho, Line: ">LOG:1,,MANAGEMENT: >STATE:1,CONNECTED,SUCCESS,,,,,"}), now)
	if len(echo) != 0 {
		t.Errorf("echo produced %+v", echo)
	}
	expectState(t, r, NewTunnelConnecting(1))
	for _, kind := range []ManagementEventKind{EventInfo, EventSuccess, EventBytecount, EventOther} {
		if effects := r.Handle(ManagementInput(ManagementEvent{Kind: kind, Message: "x", Line: "x"}), now); len(effects) != 0 {
			t.Errorf("%s produced %+v", kind, effects)
		}
	}
	if effects := r.Handle(ManagementInput(ManagementEvent{Kind: EventError, Message: "unknown command"}), now); !reflect.DeepEqual(effects, []ReducerEffect{LogEffect(LogLevelWarning, "management: unknown command")}) {
		t.Errorf("error produced %+v", effects)
	}
}

func TestProcessOutputIsForwardedOnlyBeforeManagementIsUp(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	effects := r.Handle(ProcessLine("1787840212.640000 1 library versions: OpenSSL 3.5.8"), now)
	if !reflect.DeepEqual(effects, []ReducerEffect{LogEffect(LogLevelInfo, "library versions: OpenSSL 3.5.8")}) {
		t.Errorf("stdout before management = %+v", effects)
	}
	r.Handle(ManagementConnected(), now)
	if effects := r.Handle(ProcessLine("1787840212.640000 1 TLS: soft reset"), now); len(effects) != 0 {
		t.Errorf("stdout after management = %+v", effects)
	}

	// An options error kills openvpn before the socket exists: only stdout tells us.
	o := newReducer(nil, nil)
	o.Handle(ProcessStarted(1), now)
	message := "Options error: Unrecognized option or missing or extra parameter(s) in x:3: foo"
	effects = o.Handle(ProcessLine("1787840212.640000 10 "+message), now)
	if len(effects) == 0 || !reflect.DeepEqual(effects[0], LogEffect(LogLevelError, message)) {
		t.Errorf("options error effects = %+v", effects)
	}
	expectState(t, o, NewTunnelFailed("ovpn.configError", true))
	if got := sends(effects); len(got) != 0 {
		t.Errorf("no management socket, yet sends %q", got)
	}
	exited := o.Handle(ProcessExited(1), now)
	if !containsEffect(exited, ExitedEffect(PermanentExit(FailureConfigError))) {
		t.Errorf("effects %+v lack the permanent exit", exited)
	}
}

func TestOpenedAdapterMustMatchThePlannedOne(t *testing.T) {
	ok := newReducer(nil, nil)
	ok.Handle(ProcessStarted(1), now)
	effects := ok.Handle(ProcessLine("1787840212.640000 1 ovpn-dco device [Wayfork-1] opened"), now)
	if !reflect.DeepEqual(effects, []ReducerEffect{LogEffect(LogLevelInfo, "ovpn-dco device [Wayfork-1] opened")}) {
		t.Errorf("matching adapter effects = %+v", effects)
	}
	expectState(t, ok, NewTunnelConnecting(1))

	wrong := newReducer(nil, nil)
	wrong.Handle(ProcessStarted(1), now)
	effects = wrong.Handle(ProcessLine("1787840212.640000 1 tap-windows6 device [Wayfork-2] opened"), now)
	if !containsEffect(effects, LogEffect(LogLevelInfo, "tap-windows6 device [Wayfork-2] opened")) {
		t.Errorf("effects %+v lack the log line", effects)
	}
	if !containsEffect(effects, LogEffect(LogLevelError, "tunnel failed: ovpn.configError — openvpn opened Wayfork-2 instead of Wayfork-1")) {
		t.Errorf("effects %+v lack the failure", effects)
	}
	expectState(t, wrong, NewTunnelFailed("ovpn.configError", true))

	// The same line through the management interface once it is up.
	viaManagement := newReducer(nil, nil)
	viaManagement.Handle(ProcessStarted(1), now)
	viaManagement.Handle(ManagementConnected(), now)
	effects = viaManagement.Handle(logInput("I", "ovpn-dco device [Wayfork-7] opened"), now)
	expectState(t, viaManagement, NewTunnelFailed("ovpn.configError", true))
	if got := sends(effects); !slices.Equal(got, []string{"signal SIGTERM"}) {
		t.Errorf("mismatch sends %q", got)
	}
	// A soft restart keeps the adapter and logs no open line.
	viaManagement.Handle(ProcessStarted(2), now)
	viaManagement.Handle(logInput("I", "Preserving previous TUN/TAP instance: Wayfork-1"), now)
	expectState(t, viaManagement, NewTunnelConnecting(2))
}

func TestStateTransitionsAndExiting(t *testing.T) {
	r := newReducer(nil, nil)
	r.Handle(ProcessStarted(1), now)
	r.Handle(ManagementConnected(), now)
	effects := r.Handle(stateInput("AUTH", "", ""), now)
	if !containsEffect(effects, LogEffect(LogLevelDebug, "state AUTH")) {
		t.Errorf("effects %+v lack the debug state line", effects)
	}
	r.Handle(stateInput("CONNECTED", "SUCCESS", ""), now)
	expectState(t, r, NewTunnelConnected(now, "", "Wayfork-1"))
	// Intermediate states after CONNECTED (a soft reset's GET_CONFIG) keep the connection.
	r.Handle(stateInput("GET_CONFIG", "", ""), now)
	expectState(t, r, NewTunnelConnected(now, "", "Wayfork-1"))
	r.Handle(stateInput("EXITING", "SIGTERM", ""), now)
	exited := r.Handle(ProcessExited(0), now)
	if !containsEffect(exited, ExitedEffect(TransientExit("SIGTERM"))) {
		t.Errorf("effects %+v lack the EXITING reason", exited)
	}
	if r.Context().ID != reducerTunnelID || ReducerContextFor(testRuntime(idA, "Wayfork-3", "c")).Interface != "Wayfork-3" {
		t.Error("context accessors are wrong")
	}
}
