package core

import (
	"fmt"
	"strings"
	"testing"
)

func validationReason(plan RuntimePlan) string {
	err := ValidatePlan(plan)
	if err == nil {
		return ""
	}
	if err.Kind != DaemonPlanInvalid {
		return "wrong error kind " + string(err.Kind)
	}
	return err.Reason
}

func TestPlanValidation(t *testing.T) {
	a := testRuntime(idA, "Wayfork-1", "remote x")
	b := testRuntime(idB, "Wayfork-2", "remote y")
	valid := []RuntimePlan{
		twoTunnelsPlan(t),
		testPlan([]OpenVPNRuntime{a}, map[string]string{RuleSet(idA): "{}"}, "{}"),
		testPlan(nil, map[string]string{DirectRuleSet: "{}"}, "{}"),
		testPlan([]OpenVPNRuntime{a}, map[string]string{IPRuleSet(idA): "{}"}, "{}"),
		testPlan(nil, map[string]string{DirectIPRuleSet: "{}"}, "{}"),
		testPlan([]OpenVPNRuntime{a, b}, nil, "{}"),
	}
	for index, plan := range valid {
		if reason := validationReason(plan); reason != "" {
			t.Errorf("valid plan %d rejected: %s", index, reason)
		}
	}
	// Empty credentials and an empty passphrase are legal values.
	withSecrets := testPlan([]OpenVPNRuntime{a}, nil, "{}")
	empty := ""
	withSecrets.OpenVPN[0].Credentials = &Credentials{}
	withSecrets.OpenVPN[0].KeyPassphrase = &empty
	if reason := validationReason(withSecrets); reason != "" {
		t.Errorf("empty secrets rejected: %s", reason)
	}

	big := strings.Repeat("x", MaxConfigBytes+1)
	many := make([]OpenVPNRuntime, MaxTunnels+1)
	for index := range many {
		many[index] = testRuntime(fmt.Sprintf("00000000-0000-4000-8000-%012d", index), fmt.Sprintf("Wayfork-%d", index%MaxSlots+1), "remote x")
	}
	wrongVersion := testPlan(nil, nil, "{}")
	wrongVersion.Version = 99
	nulCredentials := testPlan([]OpenVPNRuntime{a}, nil, "{}")
	nulCredentials.OpenVPN[0].Credentials = &Credentials{Username: "u", Password: "p\x00"}

	invalid := []struct {
		plan RuntimePlan
		want string
	}{
		{wrongVersion, "version"},
		{testPlan(nil, nil, ""), "empty"},
		{testPlan(nil, nil, big), "limit"},
		{testPlan(nil, map[string]string{"rules-t--ip.json": "{}"}, "{}"), "rules-t-<id>.json"},
		{testPlan(nil, map[string]string{"../x.json": "{}"}, "{}"), "rules-t-<id>.json"},
		{testPlan(nil, map[string]string{"rules-t-x.json": "{}"}, "{}"), "rules-t-<id>.json"},
		{testPlan(nil, map[string]string{RuleSet(strings.ToUpper(idHex)): "{}"}, "{}"), "rules-t-<id>.json"},
		{testPlan(nil, map[string]string{RuleSet(idA): ""}, "{}"), "empty"},
		{testPlan(many, nil, "{}"), "exceed"},
		{testPlan([]OpenVPNRuntime{testRuntime("../etc/passwd", "Wayfork-1", "c")}, nil, "{}"), "UUID"},
		{testPlan([]OpenVPNRuntime{testRuntime(strings.ToUpper(idHex), "Wayfork-1", "c")}, nil, "{}"), "UUID"},
		{testPlan([]OpenVPNRuntime{a, testRuntime(idA, "Wayfork-2", "c")}, nil, "{}"), "duplicate"},
		{testPlan([]OpenVPNRuntime{a, testRuntime(idB, "Wayfork-1", "c")}, nil, "{}"), "used twice"},
		{testPlan([]OpenVPNRuntime{testRuntime(idA, "utun101", "c")}, nil, "{}"), "Wayfork-1…Wayfork-32"},
		{testPlan([]OpenVPNRuntime{testRuntime(idA, "Wayfork-0", "c")}, nil, "{}"), "Wayfork-1…Wayfork-32"},
		{testPlan([]OpenVPNRuntime{testRuntime(idA, "Wayfork-33", "c")}, nil, "{}"), "Wayfork-1…Wayfork-32"},
		{testPlan([]OpenVPNRuntime{testRuntime(idA, "Wayfork", "c")}, nil, "{}"), "Wayfork-1…Wayfork-32"},
		{testPlan([]OpenVPNRuntime{testRuntime(idA, "Wayfork-1", "")}, nil, "{}"), "empty"},
		{testPlan([]OpenVPNRuntime{testRuntime(idA, "Wayfork-1", big)}, nil, "{}"), "limit"},
		{testPlan([]OpenVPNRuntime{testRuntime(idA, "Wayfork-1", "a\x00b")}, nil, "{}"), "NUL"},
		{nulCredentials, "NUL"},
	}
	for index, entry := range invalid {
		reason := validationReason(entry.plan)
		if !strings.Contains(reason, entry.want) {
			t.Errorf("invalid plan %d: reason %q does not mention %q", index, reason, entry.want)
		}
	}
}

func TestRuleSetIDAndTunnelID(t *testing.T) {
	for name, want := range map[string]string{
		RuleSet(idA):           idA,
		IPRuleSet(idA):         idA,
		"rules-t-x.json":       "x",
		"rules-t-x-ip-ip.json": "x-ip",
	} {
		id, ok := RuleSetID(name)
		if !ok || id != want {
			t.Errorf("RuleSetID(%q) = %q, %v; want %q", name, id, ok, want)
		}
	}
	for _, name := range []string{"rules-t-.json", "rules-t--ip.json", "rules-direct.json", "t-" + idA + ".ovpn", "rules-t-" + idA} {
		if _, ok := RuleSetID(name); ok {
			t.Errorf("RuleSetID(%q) should fail", name)
		}
	}
	if !IsTunnelID(idA) || !IsTunnelID(idHex) || !IsTunnelID("ffffffff-ffff-ffff-ffff-ffffffffffff") {
		t.Error("lowercase UUIDs must be accepted")
	}
	for _, id := range []string{strings.ToUpper(idHex), idA + "x", idA[:35], "00000000000040008000000000000001", "", "../etc/passwd", "0000000g-0000-4000-8000-000000000001"} {
		if IsTunnelID(id) {
			t.Errorf("IsTunnelID(%q) should be false", id)
		}
	}
}
