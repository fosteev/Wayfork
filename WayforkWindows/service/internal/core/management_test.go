package core

import (
	"reflect"
	"slices"
	"testing"
)

func TestParsesStateNotifications(t *testing.T) {
	cases := map[string]ManagementState{
		">STATE:1724592000,CONNECTED,SUCCESS,10.8.0.2,203.0.113.1,1194,192.168.1.5,54321,,": {
			Time: 1724592000, Name: "CONNECTED", Description: "SUCCESS", TunnelIP: "10.8.0.2", RemoteIP: "203.0.113.1",
		},
		">STATE:1724592001,RECONNECTING,connection-reset,,,,,": {Time: 1724592001, Name: "RECONNECTING", Description: "connection-reset"},
		">STATE:1724592002,WAIT,,,,,,":                         {Time: 1724592002, Name: "WAIT"},
		// The spike's real line (S3b).
		">STATE:1787840212,CONNECTED,SUCCESS,10.8.0.27,91.142.94.179,1194,,": {
			Time: 1787840212, Name: "CONNECTED", Description: "SUCCESS", TunnelIP: "10.8.0.27", RemoteIP: "91.142.94.179",
		},
	}
	for line, want := range cases {
		event := ParseManagementLine(line)
		if event.Kind != EventState || event.State != want {
			t.Errorf("%s parsed as %+v", line, event)
		}
	}
}

func TestParsesLogPasswordFatalAndReplies(t *testing.T) {
	cases := map[string]ManagementEvent{
		">LOG:1724592000,I,TLS: Initial packet, sid=1, x=2": {Kind: EventLog, Flags: "I", Message: "TLS: Initial packet, sid=1, x=2"},
		">LOG:1724592000,,MANAGEMENT: >STATE:1724592000,WAIT,,,,,,": {
			Kind: EventEcho, Line: ">LOG:1724592000,,MANAGEMENT: >STATE:1724592000,WAIT,,,,,,",
		},
		">LOG:1724592000,D,MANAGEMENT: CMD 'username \"Auth\" \"alice\"'": {
			Kind: EventEcho, Line: ">LOG:1724592000,D,MANAGEMENT: CMD 'username \"Auth\" \"alice\"'",
		},
		">LOG:1724592000,D,MANAGEMENT: CMD 'password [...]'": {Kind: EventEcho, Line: ">LOG:1724592000,D,MANAGEMENT: CMD 'password [...]'"},
		">LOG:1724592000,I,MANAGEMENT: Client connected from [AF_INET]127.0.0.1:50001": {
			Kind: EventLog, Flags: "I", Message: "MANAGEMENT: Client connected from [AF_INET]127.0.0.1:50001",
		},
		">PASSWORD:Need 'Auth' username/password":      {Kind: EventPasswordNeeded, PasswordKind: "Auth"},
		">PASSWORD:Need 'Private Key' password":        {Kind: EventPasswordNeeded, PasswordKind: "Private Key"},
		">PASSWORD:Verification Failed: 'Auth'":        {Kind: EventPasswordVerificationFailed, PasswordKind: "Auth"},
		">FATAL:Options error: Unrecognized option":    {Kind: EventFatal, Message: "Options error: Unrecognized option"},
		">HOLD:Waiting for hold release:0":             {Kind: EventHold, Message: "Waiting for hold release:0"},
		">INFO:OpenVPN Management Interface Version 5": {Kind: EventInfo, Message: "OpenVPN Management Interface Version 5"},
		">BYTECOUNT:123,456":                           {Kind: EventBytecount, In: 123, Out: 456},
		">BYTECOUNT:x,456":                             {Kind: EventOther, Line: ">BYTECOUNT:x,456"},
		"SUCCESS: hold release succeeded":              {Kind: EventSuccess, Message: "hold release succeeded"},
		"SUCCESS: password is correct":                 {Kind: EventSuccess, Message: ManagementPasswordAccepted},
		"ERROR: unknown command":                       {Kind: EventError, Message: "unknown command"},
		"END":                                          {Kind: EventOther, Line: "END"},
		">NOTIFY:info,x":                               {Kind: EventOther, Line: ">NOTIFY:info,x"},
		">PASSWORD:Auth-Token:abc":                     {Kind: EventOther, Line: ">PASSWORD:Auth-Token:abc"},
		">garbage":                                     {Kind: EventOther, Line: ">garbage"},
	}
	for line, want := range cases {
		if got := ParseManagementLine(line); !reflect.DeepEqual(got, want) {
			t.Errorf("%s parsed as %+v, want %+v", line, got, want)
		}
	}
}

func TestLogFlagsMapToLevels(t *testing.T) {
	cases := map[string]LogLevel{"I": LogLevelInfo, "W": LogLevelWarning, "N": LogLevelWarning, "F": LogLevelError, "D": LogLevelDebug, "": LogLevelInfo, "FN": LogLevelError, "NW": LogLevelWarning}
	for flags, want := range cases {
		if got := LevelForLogFlags(flags); got != want {
			t.Errorf("flags %q → %s, want %s", flags, got, want)
		}
	}
}

func TestExtractsPushedDNS(t *testing.T) {
	line := "PUSH: Received control message: 'PUSH_REPLY,dhcp-option DNS 10.8.0.1," +
		"route 10.8.0.0 255.255.255.0,dhcp-option DNS 10.8.0.2,dhcp-option DNS 10.8.0.1," +
		"dhcp-option DOMAIN corp,ifconfig 10.8.0.6 255.255.255.0,peer-id 3'"
	servers, ok := PushedDNS(line)
	if !ok || !slices.Equal(servers, []string{"10.8.0.1", "10.8.0.2"}) {
		t.Errorf("pushed DNS = %q, %v", servers, ok)
	}
	servers, ok = PushedDNS("PUSH: Received control message: 'PUSH_REPLY,ifconfig 10.8.0.6 255.255.255.0'")
	if !ok || len(servers) != 0 || servers == nil {
		t.Errorf("pushed DNS without servers = %#v, %v", servers, ok)
	}
	if _, ok := PushedDNS("TLS: soft reset"); ok {
		t.Error("a non-PUSH_REPLY line must not count")
	}
}

func TestExtractsPushedRouteGateway(t *testing.T) {
	// t1's PUSH_REPLY in the spike (S3b), reordered like the real server sends it.
	subnet := "PUSH: Received control message: 'PUSH_REPLY,route 10.8.0.0 255.255.255.0,dhcp-option DNS 10.8.0.1," +
		"route-gateway 10.8.0.1,topology subnet,ping 10,ping-restart 120,ifconfig 10.8.0.27 255.255.255.0,peer-id 0,cipher AES-256-GCM'"
	if gateway, ok := PushedRouteGateway(subnet); !ok || gateway != "10.8.0.1" {
		t.Errorf("route-gateway = %q, %v", gateway, ok)
	}
	net30 := "PUSH: Received control message: 'PUSH_REPLY,route 10.8.0.1,ifconfig 10.8.0.6 10.8.0.5,peer-id 1'"
	if gateway, ok := PushedRouteGateway(net30); !ok || gateway != "10.8.0.5" {
		t.Errorf("net30 gateway = %q, %v", gateway, ok)
	}
	subnetOnly := "PUSH: Received control message: 'PUSH_REPLY,ifconfig 10.8.0.6 255.255.255.0,peer-id 1'"
	if gateway, ok := PushedRouteGateway(subnetOnly); ok || gateway != "" {
		t.Errorf("a netmask was taken for a gateway: %q, %v", gateway, ok)
	}
	if _, ok := PushedRouteGateway("PUSH: Received control message: 'PUSH_REPLY,ping 10'"); ok {
		t.Error("a PUSH_REPLY without addresses must not yield a gateway")
	}
	if _, ok := PushedRouteGateway("TLS: soft reset"); ok {
		t.Error("a non-PUSH_REPLY line must not yield a gateway")
	}
}

func TestManagementPasswordPrompt(t *testing.T) {
	if !IsManagementPasswordPrompt([]byte("ENTER PASSWORD:")) {
		t.Error("the bare prompt must be recognized")
	}
	if !IsManagementPasswordPrompt([]byte(">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info\r\nENTER PASSWORD:")) {
		t.Error("the prompt after other output must be recognized")
	}
	if IsManagementPasswordPrompt([]byte("ENTER PASSWORD:\r\n")) || IsManagementPasswordPrompt([]byte(">HOLD:Waiting")) || IsManagementPasswordPrompt(nil) {
		t.Error("only a trailing prompt counts")
	}
}

func TestCommandsAreQuoted(t *testing.T) {
	if got := ManagementUsername("Auth", "alice"); got != `username "Auth" "alice"` {
		t.Errorf("username = %s", got)
	}
	if got := ManagementPassword("Auth", `p"a\s s`); got != `password "Auth" "p\"a\\s s"` {
		t.Errorf("password = %s", got)
	}
	if got := ManagementPassword("Private Key", "pp"); got != `password "Private Key" "pp"` {
		t.Errorf("key passphrase = %s", got)
	}
	if got := ManagementQuote("пароль"); got != `"пароль"` {
		t.Errorf("unicode quoting = %s", got)
	}
	if ManagementStateOn != "state on" || ManagementLogOn != "log on" || ManagementBytecount != "bytecount 5" ||
		ManagementHoldRelease != "hold release" || ManagementSignalTerm != "signal SIGTERM" {
		t.Error("command constants changed")
	}
}

func TestParseOutputLine(t *testing.T) {
	cases := map[string][2]string{
		// The spike's real stdout line: hex flags 0x1 (level 1, no severity bits) = info.
		"1787840212.640000 1 ovpn-dco device [Wayfork-1] opened": {"I", "ovpn-dco device [Wayfork-1] opened"},
		"1724592000.000001 10 Options error: bad":                {"F", "Options error: bad"},
		"1724592000.000001 11 Options error: bad":                {"F", "Options error: bad"},
		"1724592000.000001 40 WARNING: x":                        {"W", "WARNING: x"},
		"1724592000.000001 60 both":                              {"NW", "both"},
		"1724592000.000001 84 dbg":                               {"D", "dbg"},
		"1724592000 I TLS: soft reset":                           {"I", "TLS: soft reset"},
		"garbage line":                                           {"", "garbage line"},
		"1724592000.5 zz nope":                                   {"", "1724592000.5 zz nope"},
		"":                                                       {"", ""},
	}
	for line, want := range cases {
		flags, message := ParseOutputLine(line)
		if flags != want[0] || message != want[1] {
			t.Errorf("%q → (%q, %q), want (%q, %q)", line, flags, message, want[0], want[1])
		}
	}
}

func TestOpenedAdapter(t *testing.T) {
	cases := map[string]string{
		"ovpn-dco device [Wayfork-1] opened":           "Wayfork-1",
		"tap-windows6 device [Wayfork-2] opened":       "Wayfork-2",
		"wintun device [Local Area Connection] opened": "Local Area Connection",
	}
	for message, want := range cases {
		if got, ok := OpenedAdapter(message); !ok || got != want {
			t.Errorf("%q → %q, %v", message, got, ok)
		}
	}
	for _, message := range []string{
		"Preserving previous TUN/TAP instance: Wayfork-1",
		"Opened utun device utun105",
		"ovpn-dco device [Wayfork-1] opened and more",
		"device [x] opened",
	} {
		if got, ok := OpenedAdapter(message); ok {
			t.Errorf("%q must not match (got %q)", message, got)
		}
	}
}
