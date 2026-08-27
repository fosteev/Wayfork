package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The reserved test UUIDs (fixtures/README.md); never real ids.
const (
	idA = "00000000-0000-4000-8000-000000000001"
	idB = "00000000-0000-4000-8000-000000000002"
	// idHex has hex letters, for the case-sensitivity checks.
	idHex = "00000000-0000-4000-8000-0000000000ab"
)

// fixtureDate is the timestamp the Dart and Swift tests pin ("2026-08-25T12:00:00Z").
var fixtureDate = time.Date(2026, 8, 25, 12, 0, 0, 0, time.UTC)

// fixturesRoot is the repository's shared fixtures/ directory; go test runs with the
// package directory as its working directory.
func fixturesRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join("..", "..", "..", "..", "fixtures")
	if _, err := os.Stat(filepath.Join(root, "README.md")); err != nil {
		t.Fatalf("fixtures directory not found at %s: %v", root, err)
	}
	return root
}

func readFixture(t *testing.T, parts ...string) string {
	t.Helper()
	path := filepath.Join(append([]string{fixturesRoot(t)}, parts...)...)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading fixture %s: %v", path, err)
	}
	return string(data)
}

func testRuntime(id, adapter, config string) OpenVPNRuntime {
	return OpenVPNRuntime{
		ID: id, Interface: adapter, Config: config,
		ConfigHash: ComputeOpenVPNConfigHash(config, nil, nil),
	}
}

func testPlan(openVPN []OpenVPNRuntime, ruleSets map[string]string, config string) RuntimePlan {
	if ruleSets == nil {
		ruleSets = map[string]string{}
	}
	return RuntimePlan{
		Version: PlanVersion,
		SingBox: SingBoxPlan{
			Config: config, ConfigHash: SHA256Hex(config), RuleSets: ruleSets,
		},
		OpenVPN:           openVPN,
		AutoReconnect:     true,
		LogLevel:          LogLevelInfo,
		OverrideSystemDNS: true,
	}
}

// twoTunnelsPlan builds the plan the app would send for fixtures/singbox/two-tunnels on
// Windows: the golden sing-box config, its six rule-set files, two OpenVPN runtimes.
func twoTunnelsPlan(t *testing.T) RuntimePlan {
	t.Helper()
	variant := filepath.Join("singbox", "two-tunnels")
	ruleSets := map[string]string{}
	for _, name := range []string{
		DirectRuleSet, DirectIPRuleSet, RuleSet(idA), IPRuleSet(idA), RuleSet(idB), IPRuleSet(idB),
	} {
		ruleSets[name] = readFixture(t, variant, name)
	}
	return testPlan(
		[]OpenVPNRuntime{
			testRuntime(idA, "Wayfork-1", "client\nremote <SERVER> 1194\n"),
			testRuntime(idB, "Wayfork-2", "client\nremote <SERVER> 443\n"),
		},
		ruleSets, readFixture(t, variant, SingBoxConfig))
}

func mustMarshal(t *testing.T, value any) string {
	t.Helper()
	data, err := MarshalWire(value)
	if err != nil {
		t.Fatalf("marshal %T: %v", value, err)
	}
	return string(data)
}

func mustUnmarshal(t *testing.T, text string, target any) {
	t.Helper()
	if err := json.Unmarshal([]byte(text), target); err != nil {
		t.Fatalf("unmarshal %s into %T: %v", text, target, err)
	}
}
