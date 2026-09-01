package core

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPlanRoundTripsThroughJSON(t *testing.T) {
	plan := twoTunnelsPlan(t)
	passphrase := "secret pass"
	plan.OpenVPN[0].Credentials = &Credentials{Username: "user", Password: "p\"w\\d"}
	plan.OpenVPN[1].KeyPassphrase = &passphrase
	plan.LogLevel = LogLevelDebug
	plan.AutoReconnect = false

	encoded := mustMarshal(t, plan)
	var decoded RuntimePlan
	mustUnmarshal(t, encoded, &decoded)
	if got := mustMarshal(t, decoded); got != encoded {
		t.Errorf("plan round trip differs:\n%s\n%s", got, encoded)
	}
	if decoded.PlanHash() != plan.PlanHash() {
		t.Error("plan hash changed across the round trip")
	}
	if decoded.OpenVPN[0].Credentials == nil || decoded.OpenVPN[0].Credentials.Password != "p\"w\\d" {
		t.Errorf("credentials lost: %+v", decoded.OpenVPN[0].Credentials)
	}
	if decoded.OpenVPN[1].KeyPassphrase == nil || *decoded.OpenVPN[1].KeyPassphrase != passphrase {
		t.Errorf("key passphrase lost: %+v", decoded.OpenVPN[1].KeyPassphrase)
	}
	if decoded.OpenVPN[0].KeyPassphrase != nil || decoded.OpenVPN[1].Credentials != nil {
		t.Error("absent secrets must decode as nil")
	}
	if len(decoded.SingBox.RuleSets) != 6 || decoded.SingBox.Config != plan.SingBox.Config {
		t.Error("sing-box plan lost content")
	}
	// Absent secrets are omitted on the wire, an empty passphrase is not.
	empty := ""
	plan.OpenVPN[1].KeyPassphrase = &empty
	if got := mustMarshal(t, plan.OpenVPN[1]); !strings.Contains(got, `"keyPassphrase":""`) {
		t.Errorf("empty passphrase must be kept: %s", got)
	}
	if got := mustMarshal(t, plan.OpenVPN[0]); strings.Contains(got, "keyPassphrase") {
		t.Errorf("nil passphrase must be omitted: %s", got)
	}
}

func TestPlanDefaultsAndStrictness(t *testing.T) {
	minimal := `{"version":1,"singBox":{"config":"{}","configHash":"h","ruleSets":{}},"openVPN":[]}`
	var plan RuntimePlan
	mustUnmarshal(t, minimal, &plan)
	if !plan.AutoReconnect || plan.LogLevel != LogLevelInfo || !plan.OverrideSystemDNS {
		t.Errorf("defaults not applied: %+v", plan)
	}
	if plan.OpenVPN == nil || len(plan.OpenVPN) != 0 {
		t.Errorf("openVPN decoded as %#v", plan.OpenVPN)
	}
	explicit := `{"version":1,"singBox":{"config":"{}","configHash":"h","ruleSets":{}},"openVPN":[],` +
		`"autoReconnect":false,"logLevel":"error","overrideSystemDNS":false}`
	mustUnmarshal(t, explicit, &plan)
	if plan.AutoReconnect || plan.LogLevel != LogLevelError || plan.OverrideSystemDNS {
		t.Errorf("explicit values ignored: %+v", plan)
	}

	bad := []string{
		`{"singBox":{"config":"{}","configHash":"h","ruleSets":{}},"openVPN":[]}`,
		`{"version":1,"openVPN":[]}`,
		`{"version":1,"singBox":{"config":"{}","configHash":"h","ruleSets":{}}}`,
		`{"version":1,"singBox":{"config":7,"configHash":"h","ruleSets":{}},"openVPN":[]}`,
		`{"version":1,"singBox":{"config":"{}","configHash":"h"},"openVPN":[]}`,
		`{"version":1,"singBox":{"config":"{}","configHash":"h","ruleSets":{"a":1}},"openVPN":[]}`,
		`{"version":1,"singBox":{"config":"{}","configHash":"h","ruleSets":{}},"openVPN":[{"id":"x"}]}`,
		`{"version":1,"singBox":{"config":"{}","configHash":"h","ruleSets":{}},"openVPN":[],"logLevel":"loud"}`,
		`{"version":1,"singBox":{"config":"{}","configHash":"h","ruleSets":{}},"openVPN":[` +
			`{"id":"x","interface":"Wayfork-1","config":"c","configHash":"h","credentials":{"username":"u"}}]}`,
		`[]`,
	}
	for _, text := range bad {
		var plan RuntimePlan
		if err := json.Unmarshal([]byte(text), &plan); err == nil {
			t.Errorf("decoding %s should fail", text)
		}
	}
	// Ids are taken as they come; the validator rejects the wrong case.
	upper := `{"version":1,"singBox":{"config":"{}","configHash":"h","ruleSets":{}},"openVPN":[` +
		`{"id":"` + strings.ToUpper(idHex) + `","interface":"Wayfork-1","config":"c","configHash":"h"}]}`
	mustUnmarshal(t, upper, &plan)
	if plan.OpenVPN[0].ID != strings.ToUpper(idHex) {
		t.Errorf("id was normalized to %q", plan.OpenVPN[0].ID)
	}
}

func TestPlanHash(t *testing.T) {
	plan := twoTunnelsPlan(t)
	hash := plan.PlanHash()
	if len(hash) != 64 || hash != plan.PlanHash() {
		t.Errorf("plan hash %q is not a stable SHA-256", hash)
	}
	// The values the Dart core computes for the same inputs (cross-client pin, taken from
	// RuntimePlan.planHash / OpenVPNRuntime.configHash; re-pinned 2026-09-01 for the H4
	// golden change).
	if hash != "9bbb5a830eb85079ee4b239f10e06601bea150a1fda67d6af8712ef4b886ab2e" {
		t.Errorf("plan hash %s differs from the Dart core's", hash)
	}
	if plan.OpenVPN[0].ConfigHash != "9bcd89cb9ed8d1ff0362c5a01b0cf2688be60cfb8b4dcaa44e848da1d311b989" {
		t.Errorf("OpenVPN config hash %s differs from the Dart core's", plan.OpenVPN[0].ConfigHash)
	}
	flipped := plan
	flipped.OverrideSystemDNS = false
	if flipped.PlanHash() == hash {
		t.Error("overrideSystemDNS must be part of the plan hash")
	}
	edited := twoTunnelsPlan(t)
	edited.SingBox.RuleSets[RuleSet(idA)] += "\n"
	if edited.PlanHash() == hash {
		t.Error("rule-set contents must be part of the plan hash")
	}
	if edited.SingBox.ConfigHash != plan.SingBox.ConfigHash {
		t.Error("rule sets must not affect the config hash")
	}
	reordered := twoTunnelsPlan(t)
	reordered.OpenVPN[0], reordered.OpenVPN[1] = reordered.OpenVPN[1], reordered.OpenVPN[0]
	if reordered.PlanHash() == hash {
		t.Error("tunnel order is part of the plan hash")
	}
	verbose := twoTunnelsPlan(t)
	verbose.LogLevel = LogLevelDebug
	verbose.AutoReconnect = false
	if verbose.PlanHash() != hash {
		t.Error("log level and auto-reconnect are not part of the plan hash")
	}

	// The exact algorithm, spelled out once.
	small := testPlan(
		[]OpenVPNRuntime{{ID: idA, Interface: "Wayfork-1", Config: "c", ConfigHash: "ch"}},
		map[string]string{"rules-direct.json": "d", "rules-t-" + idA + ".json": "a"}, "{}")
	want := SHA256Hex(strings.Join([]string{
		SHA256Hex("{}"),
		"rules-direct.json=" + SHA256Hex("d"),
		"rules-t-" + idA + ".json=" + SHA256Hex("a"),
		idA + "=ch",
		"overrideSystemDNS=true",
	}, "\n"))
	if got := small.PlanHash(); got != want {
		t.Errorf("plan hash = %s, want %s", got, want)
	}
}

func TestOpenVPNConfigHash(t *testing.T) {
	plain := ComputeOpenVPNConfigHash("client", nil, nil)
	if plain != SHA256Hex("client\x00\x00\x00") {
		t.Errorf("plain hash = %s", plain)
	}
	credentials := &Credentials{Username: "u", Password: "p"}
	if ComputeOpenVPNConfigHash("client", credentials, nil) != SHA256Hex("client\x00u\x00p\x00") {
		t.Error("credentials are hashed in the wrong shape")
	}
	passphrase := "k"
	if ComputeOpenVPNConfigHash("client", credentials, &passphrase) != SHA256Hex("client\x00u\x00p\x00k") {
		t.Error("passphrase is hashed in the wrong shape")
	}
	if ComputeOpenVPNConfigHash("client", credentials, nil) == plain {
		t.Error("credentials must change the hash")
	}
	if SHA256Hex("") != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
		t.Error("SHA256Hex is not SHA-256")
	}
}
