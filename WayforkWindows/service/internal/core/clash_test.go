package core

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const (
	clashTunnelA = "aaaaaaaa-0000-0000-0000-000000000001"
	clashTunnelB = "aaaaaaaa-0000-0000-0000-000000000002"
)

func TestClashAPIInjectionAddsTheControllerAndKeepsTheRest(t *testing.T) {
	config := `{
  "log": { "level": "info" },
  "dns": { "servers": [ { "tag": "direct-dns", "address": "local" } ], "strategy": "ipv4_only" },
  "inbounds": [ { "type": "tun", "tag": "tun-in", "auto_route": true, "mtu": 1400,
                  "route_exclude_address": ["10.0.0.0/8", "224.0.0.0/4"], "ratio": 0.5, "big": 12345678901234567890 } ],
  "route": { "rules": [ { "protocol": "dns", "action": "hijack-dns" } ], "final": "direct" },
  "experimental": { "cache_file": { "enabled": true, "path": "cache.db", "store_fakeip": true } }
}`
	endpoint := ClashAPIEndpoint{Port: 41234, Secret: strings.Repeat("ab", 32)}
	injected, err := InjectClashAPI(endpoint, config)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := json.Unmarshal([]byte(injected), &root); err != nil {
		t.Fatalf("injected config is not JSON: %v\n%s", err, injected)
	}
	experimental := root["experimental"].(map[string]any)
	clash := experimental["clash_api"].(map[string]any)
	if clash["external_controller"] != "127.0.0.1:41234" || clash["secret"] != endpoint.Secret || len(clash) != 2 {
		t.Errorf("clash_api = %v", clash)
	}
	cache := experimental["cache_file"].(map[string]any)
	if cache["store_fakeip"] != true || cache["enabled"] != true {
		t.Errorf("cache_file = %v", cache)
	}
	inbound := root["inbounds"].([]any)[0].(map[string]any)
	if inbound["auto_route"] != true || inbound["mtu"] != 1400.0 || !reflect.DeepEqual(inbound["route_exclude_address"], []any{"10.0.0.0/8", "224.0.0.0/4"}) {
		t.Errorf("inbound = %v", inbound)
	}
	if root["route"].(map[string]any)["final"] != "direct" {
		t.Error("route.final lost")
	}
	for _, literal := range []string{`"mtu": 1400`, `"ratio": 0.5`, `"big": 12345678901234567890`, `"external_controller": "127.0.0.1:41234"`} {
		if !strings.Contains(injected, literal) {
			t.Errorf("injected config lacks %s:\n%s", literal, injected)
		}
	}
	if strings.Contains(injected, `\/`) || !strings.HasSuffix(injected, "\n") {
		t.Error("slashes must stay unescaped and the file must end with a newline")
	}
	if endpoint.ConnectionsURL() != "http://127.0.0.1:41234/connections" {
		t.Errorf("connections URL = %s", endpoint.ConnectionsURL())
	}
}

func TestClashAPIInjectionCreatesExperimentalWhenMissing(t *testing.T) {
	injected, err := InjectClashAPI(ClashAPIEndpoint{Port: 1, Secret: "s"}, `{"log": {}}`)
	if err != nil {
		t.Fatal(err)
	}
	want := "{\n  \"experimental\": {\n    \"clash_api\": {\n      \"external_controller\": \"127.0.0.1:1\",\n      \"secret\": \"s\"\n    }\n  },\n  \"log\": {}\n}\n"
	if injected != want {
		t.Errorf("injected =\n%s\nwant\n%s", injected, want)
	}
}

func TestClashAPIInjectionRejectsNonObjects(t *testing.T) {
	for _, config := range []string{"[1, 2]", "{ not json", "null", `{"experimental": 3}`} {
		if _, err := InjectClashAPI(ClashAPIEndpoint{Port: 1, Secret: "s"}, config); err == nil {
			t.Errorf("%s must be rejected", config)
		}
	}
}

func TestClashAPIEndpointGeneration(t *testing.T) {
	endpoint, err := GenerateClashAPIEndpoint()
	if err != nil {
		t.Fatal(err)
	}
	if endpoint.Port < 1024 || len(endpoint.Secret) != 64 || strings.Trim(endpoint.Secret, "0123456789abcdef") != "" {
		t.Errorf("endpoint = %+v", endpoint)
	}
	other, _ := RandomSecret()
	if other == endpoint.Secret {
		t.Error("secrets repeat")
	}
}

// Every golden config still passes `sing-box check` with the Clash API injected, when the
// macOS bundle's sing-box is around (as in the Dart golden test).
func TestSingBoxAcceptsInjectedGoldenConfigs(t *testing.T) {
	binary := filepath.Join("..", "..", "..", "..", "Wayfork", "Resources", "bin", "sing-box")
	if _, err := os.Stat(binary); err != nil {
		t.Skip("no sing-box binary at " + binary)
	}
	variants, err := os.ReadDir(filepath.Join(fixturesRoot(t), "singbox"))
	if err != nil || len(variants) == 0 {
		t.Fatalf("no golden variants: %v", err)
	}
	for _, variant := range variants {
		dir := t.TempDir()
		source := filepath.Join(fixturesRoot(t), "singbox", variant.Name())
		entries, _ := os.ReadDir(source)
		for _, entry := range entries {
			data, _ := os.ReadFile(filepath.Join(source, entry.Name()))
			os.WriteFile(filepath.Join(dir, entry.Name()), data, 0o600)
		}
		endpoint, _ := GenerateClashAPIEndpoint()
		injected, err := InjectClashAPI(endpoint, readFixture(t, "singbox", variant.Name(), SingBoxConfig))
		if err != nil {
			t.Fatalf("%s: %v", variant.Name(), err)
		}
		os.WriteFile(filepath.Join(dir, SingBoxConfig), []byte(injected), 0o600)
		output, err := exec.Command(binary, "check", "-D", dir, "-c", SingBoxConfig).CombinedOutput()
		if err != nil {
			t.Errorf("sing-box check failed for %s: %v\n%s", variant.Name(), err, output)
		}
	}
}

func TestClashConnectionsDecodeTheFixture(t *testing.T) {
	decoded, err := DecodeClashConnections([]byte(readFixture(t, "clash", "connections.json")))
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Connections) != 5 {
		t.Fatalf("%d connections", len(decoded.Connections))
	}
	first := decoded.Connections[0]
	if first.ID != "0f8a9c8e-1d2b-4c3a-9e8f-7a6b5c4d3e2f" || !reflect.DeepEqual(first.Chains, []string{"t-" + clashTunnelA}) ||
		first.Upload != 4096 || first.Download != 1048576 || first.Host != "example.com" || first.DestinationIP != "198.18.0.5" || first.ProcessPath != "" {
		t.Errorf("first = %+v", first)
	}
	if decoded.Connections[1].ProcessPath != "/Applications/Safari.app/Contents/MacOS/Safari" {
		t.Errorf("second = %+v", decoded.Connections[1])
	}
	if last := decoded.Connections[4]; last.Chains == nil || len(last.Chains) != 0 {
		t.Errorf("null chains decoded as %#v", last.Chains)
	}
	exits := map[string]TrafficExit{
		"t-" + clashTunnelA: {Tunnel: clashTunnelA}, "direct": DirectExit, "dns-out": DirectExit, "block": DirectExit,
	}
	for tag, want := range exits {
		if got := ExitForChains([]string{tag}); got != want {
			t.Errorf("exit of %s = %+v", tag, got)
		}
	}
	if ExitForChains(nil) != DirectExit || ExitForChains([]string{"direct", "t-" + clashTunnelB}) != (TrafficExit{Tunnel: clashTunnelB}) {
		t.Error("chain attribution is wrong")
	}
}

func TestClashConnectionsTolerateNullAndNegativeCounters(t *testing.T) {
	decoded, err := DecodeClashConnections([]byte(`{"connections": null}`))
	if err != nil || len(decoded.Connections) != 0 || decoded.Connections == nil {
		t.Errorf("null list = %#v, %v", decoded, err)
	}
	odd, err := DecodeClashConnections([]byte(`{"connections": [{"id": "x", "upload": -5}]}`))
	if err != nil || !reflect.DeepEqual(odd.Connections, []ClashConnection{{ID: "x", Chains: []string{}}}) {
		t.Errorf("odd = %+v, %v", odd.Connections, err)
	}
	bare, _ := DecodeClashConnections([]byte(`{"connections": [{"id": "x", "metadata": null}]}`))
	if bare.Connections[0].Host != "" {
		t.Error("null metadata must give empty fields")
	}
	if _, err := DecodeClashConnections([]byte(`not json`)); err == nil {
		t.Error("garbage must fail")
	}
}

func TestTags(t *testing.T) {
	if OutboundTag(idA) != "t-"+idA || RuleSetTag(idA) != "rules-t-"+idA {
		t.Error("tags are wrong")
	}
	if id, ok := TunnelIDFromOutboundTag("t-" + idA); !ok || id != idA {
		t.Errorf("tunnel id = %q, %v", id, ok)
	}
	for _, tag := range []string{"direct", "dns-out", "block", "t-", "", "T-x"} {
		if _, ok := TunnelIDFromOutboundTag(tag); ok {
			t.Errorf("%q must not be a tunnel tag", tag)
		}
	}
}
