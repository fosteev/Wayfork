package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// F14–F19 core pieces, on the same line shapes the Swift tests use.

func intPtr(v int) *int { return &v }

const (
	tunnelA = "00000000-0000-4000-8000-000000000001"
	tunnelB = "00000000-0000-4000-8000-0000000000a1"
)

func TestLatencyTrackerTransitions(t *testing.T) {
	tracker := NewLatencyTracker()
	now := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	if tr := tracker.Record("a", intPtr(62), now); tr != nil {
		t.Fatalf("first success caused %+v", tr)
	}
	tracker.Record("a", nil, now)
	tracker.Record("a", nil, now)
	tr := tracker.Record("a", nil, now)
	if tr == nil || !tr.BecameUnreachable || tr.Failures != 3 {
		t.Fatalf("third failure = %+v", tr)
	}
	if !tracker.Samples()["a"].Unreachable || tracker.Samples()["a"].LastSuccess == nil {
		t.Fatalf("sample = %+v", tracker.Samples()["a"])
	}
	tr = tracker.Record("a", intPtr(80), now.Add(time.Minute))
	if tr == nil || tr.BecameUnreachable || tr.Milliseconds != 80 {
		t.Fatalf("recovery = %+v", tr)
	}
	for i := 0; i < 20; i++ {
		tracker.Record("a", intPtr(i), now)
	}
	if got := len(tracker.Samples()["a"].History); got != ProbeHistoryLength {
		t.Fatalf("history length = %d", got)
	}
	tracker.Record("b", nil, now)
	tracker.Record("b", nil, now)
	tracker.Record("b", nil, now)
	tracker.ResetStreak("b")
	if tracker.Samples()["b"].Unreachable || tracker.Samples()["b"].FailedInARow != 0 {
		t.Fatal("ResetStreak kept the streak")
	}
	tracker.Retain(map[string]bool{"a": true})
	if _, ok := tracker.Samples()["b"]; ok {
		t.Fatal("Retain kept b")
	}
	data, _ := json.Marshal(tracker.Samples()["a"])
	if !strings.Contains(string(data), `"milliseconds":19`) || !strings.Contains(string(data), `"unreachable":false`) {
		t.Fatalf("sample wire = %s", data)
	}
	if WantedFirstLiveMember([]string{"x", "b", "a"}, tracker.Samples()) != "a" {
		t.Fatal("first live should skip unknown and failed members")
	}
	if WantedFirstLiveMember([]string{"x"}, tracker.Samples()) != "" {
		t.Fatal("no live member must leave the selector alone")
	}
}

func TestClashProbeEndpointsAndDecoding(t *testing.T) {
	endpoint := ClashAPIEndpoint{Port: 9090, Secret: "s"}
	url := endpoint.DelayURL("t-abc", ProbeURL, 5*time.Second)
	if !strings.HasPrefix(url, "http://127.0.0.1:9090/proxies/t-abc/delay?") || !strings.Contains(url, "timeout=5000") {
		t.Fatalf("delay url = %s", url)
	}
	if endpoint.ProxyURL("g-abc") != "http://127.0.0.1:9090/proxies/g-abc" {
		t.Fatalf("proxy url = %s", endpoint.ProxyURL("g-abc"))
	}
	if delay, err := DecodeClashDelay([]byte(`{"delay": 62}`)); err != nil || delay != 62 {
		t.Fatalf("delay = %d, %v", delay, err)
	}
	if _, err := DecodeClashDelay([]byte(`{"message":"x"}`)); err == nil {
		t.Fatal("a delay-less body must fail")
	}
	proxy, err := DecodeClashProxy([]byte(`{"type":"Selector","name":"g-abc","now":"t-one","all":["t-one","t-two"]}`))
	if err != nil || proxy.Now != "t-one" || len(proxy.All) != 2 {
		t.Fatalf("proxy = %+v, %v", proxy, err)
	}
	if string(ClashSelectBody("t-two")) != `{"name":"t-two"}` {
		t.Fatalf("select body = %s", ClashSelectBody("t-two"))
	}
}

func TestRecentHostsRing(t *testing.T) {
	ring := NewRecentHosts()
	now := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	connections := []ClashConnection{
		{Chains: []string{"direct"}, Host: "News.Example.com", ProcessPath: `C:\Edge\msedge.exe`},
		{Chains: []string{"t-aaa"}, Host: "routed.example.com"},
		{Chains: []string{"direct"}, Host: "10.0.0.5"},
		{Chains: []string{"direct"}, Host: "printer.local"},
		{Chains: []string{"direct"}, Host: "[::1]"},
	}
	ring.Ingest(connections, DirectExit, now)
	rows := ring.Snapshot()
	if len(rows) != 1 || rows[0].Host != "news.example.com" || rows[0].Exit != "direct" {
		t.Fatalf("rows = %+v", rows)
	}
	// A later sighting without a process keeps the earlier process; the default exit is
	// a tunnel now, so direct flows are no longer the default route.
	ring.Ingest([]ClashConnection{{Chains: []string{"t-aaa", "direct"}, Host: "news.example.com"}}, TrafficExit{Tunnel: "aaa"}, now.Add(time.Second))
	rows = ring.Snapshot()
	if rows[0].ProcessPath != `C:\Edge\msedge.exe` || rows[0].Exit != "aaa" {
		t.Fatalf("rows = %+v", rows)
	}
	for i := 0; i < RecentHostCapacity+5; i++ {
		ring.Ingest([]ClashConnection{{Chains: []string{"direct"}, Host: "h" + string(rune('a'+i%26)) + strings.Repeat("x", i/26) + ".example"}}, DirectExit, now.Add(time.Duration(i)*time.Second))
	}
	if len(ring.Snapshot()) != RecentHostCapacity {
		t.Fatalf("ring holds %d", len(ring.Snapshot()))
	}
	ring.Clear()
	if len(ring.Snapshot()) != 0 {
		t.Fatal("Clear kept rows")
	}
	if ExitForChains([]string{"g-grp", "t-member"}).Tunnel != "grp" {
		t.Fatal("a group tag must win over its member")
	}
}

func TestBlockCounterAndLines(t *testing.T) {
	if !IsBlockedLine("INFO[0012] [3 0ms] router: match[3] logical(and)[rule_set=block-ads !domain_suffix=[.x]] => reject") {
		t.Fatal("route reject not counted")
	}
	if !IsBlockedLine("[1 0ms] dns: match[4] rule_set=block-ads => predefined") {
		t.Fatal("dns predefined not counted")
	}
	if IsBlockedLine("[5 0ms] router: match[5] rule_set=rules-direct => direct") {
		t.Fatal("a direct match counted")
	}
	var counter BlockCounter
	noon := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	counter.Record(noon)
	counter.Record(noon.Add(time.Minute))
	if counter.Value(noon.Add(time.Hour)) != 2 {
		t.Fatal("count lost within the day")
	}
	if counter.Value(noon.Add(13*time.Hour)) != 0 {
		t.Fatal("count survived midnight")
	}
}

func TestFailedConnectionsJoin(t *testing.T) {
	tracker := NewFailedConnections()
	t0 := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	lines := []struct {
		level LogLevel
		line  string
	}{
		{LogLevelInfo, "[3921 0ms] inbound/tun[tun-in]: inbound connection to 203.0.113.9:443"},
		{LogLevelInfo, "[3921 1ms] router: sniffed protocol: tls, domain: cdn.gamepatch.example.net"},
		{LogLevelInfo, `[3921 1ms] router: found process path: C:\Program Files\Game\Game.exe`},
		{LogLevelInfo, "[3921 2ms] router: match[5] rule_set=rules-t-aaa => t-aaa"},
		{LogLevelError, "[3921 5004ms] inbound/tun[tun-in]: open connection to cdn.gamepatch.example.net:443: dial tcp 203.0.113.9:443: i/o timeout"},
		{LogLevelInfo, "[3930 0ms] inbound/tun[tun-in]: inbound connection to cdn.gamepatch.example.net:443"},
		{LogLevelInfo, `[3930 1ms] router: found process path: C:\Program Files\Game\Game.exe`},
		{LogLevelInfo, "[3930 2ms] router: match[5] rule_set=rules-t-aaa => t-aaa"},
		{LogLevelError, "[3930 5002ms] inbound/tun[tun-in]: open connection to cdn.gamepatch.example.net:443: dial tcp 203.0.113.9:443: i/o timeout"},
		// Problems level: only the error line — host from it, no app.
		{LogLevelError, "ERROR [40 30ms] inbound/tun[tun-in]: open connection to matchmaking.example.net:5555: dial tcp 198.51.100.2:5555: connectex: connection refused"},
		{LogLevelInfo, "[41 0ms] inbound/tun[tun-in]: inbound connection to api.example.org:443"},
		{LogLevelInfo, "[41 1ms] router: match[2] rule_set=rules-t-bbb => t-bbb"},
		{LogLevelError, "[41 3ms] inbound/tun[tun-in]: open connection to api.example.org:443: dial tcp 198.51.100.5:443: network is unreachable"},
		{LogLevelInfo, "[43 0ms] inbound/tun[tun-in]: inbound connection to telemetry.example.com:443"},
		{LogLevelInfo, "[43 1ms] router: match[3] logical(and)[rule_set=block-ads] => reject"},
		{LogLevelInfo, "[44 0ms] dns: exchange ads.example.net. IN A"},
		{LogLevelInfo, "[44 0ms] dns: match[4] rule_set=block-ads => predefined"},
		{LogLevelError, "[45 12ms] inbound/tun[tun-in]: open connection to nope.example.invalid:443: lookup nope.example.invalid: no such host"},
		{LogLevelInfo, "[47 0ms] inbound/tun[tun-in]: inbound packet connection to [2001:db8::1]:53"},
		{LogLevelError, "[47 9ms] inbound/tun[tun-in]: open packet connection to [2001:db8::1]:53: dial udp: i/o timeout"},
		{LogLevelInfo, "[48 0ms] inbound/tun[tun-in]: inbound connection to ok.example.com:443"},
		{LogLevelInfo, "sing-box started (0.02s)"},
	}
	for i, entry := range lines {
		tracker.Ingest(entry.line, entry.level, t0.Add(time.Duration(i)*time.Second))
	}
	rows := map[string]FailedHost{}
	for _, row := range tracker.Snapshot() {
		rows[row.Host] = row
	}
	if len(rows) != 7 {
		t.Fatalf("rows = %d: %+v", len(rows), rows)
	}
	game := rows["cdn.gamepatch.example.net"]
	if game.Count != 2 || game.Exit != "aaa" || game.Reason.Kind != FailureNoAnswer || game.ProcessPath != `C:\Program Files\Game\Game.exe` {
		t.Fatalf("game row = %+v", game)
	}
	if rows["matchmaking.example.net"].Reason.Kind != FailureRefused || rows["matchmaking.example.net"].ProcessPath != "" {
		t.Fatalf("refused row = %+v", rows["matchmaking.example.net"])
	}
	if rows["api.example.org"].Reason.Kind != FailureTunnelDown || rows["api.example.org"].Exit != "bbb" {
		t.Fatalf("tunnel-down row = %+v", rows["api.example.org"])
	}
	if rows["telemetry.example.com"].Reason.Kind != FailureBlocked || rows["telemetry.example.com"].Exit != "" {
		t.Fatalf("blocked row = %+v", rows["telemetry.example.com"])
	}
	if rows["ads.example.net."].Reason.Kind != FailureBlocked {
		t.Fatalf("blocked lookup row = %+v", rows["ads.example.net."])
	}
	if rows["nope.example.invalid"].Reason.Kind != FailureNoSuchName {
		t.Fatalf("no-such-name row = %+v", rows["nope.example.invalid"])
	}
	if rows["2001:db8::1"].Reason.Kind != FailureNoAnswer {
		t.Fatalf("ipv6 row = %+v", rows["2001:db8::1"])
	}
	if _, ok := rows["ok.example.com"]; ok {
		t.Fatal("a connection that did not fail was listed")
	}
	if tracker.Snapshot()[0].Host != "2001:db8::1" {
		t.Fatalf("newest first: %s", tracker.Snapshot()[0].Host)
	}
	data, _ := json.Marshal(rows["api.example.org"].Reason)
	if string(data) != `{"tunnelDown":{}}` {
		t.Fatalf("reason wire = %s", data)
	}
	data, _ = json.Marshal(FailureReason{Kind: FailureOther, Other: "boom"})
	if string(data) != `{"other":{"_0":"boom"}}` {
		t.Fatalf("other wire = %s", data)
	}
	var back FailureReason
	if err := json.Unmarshal(data, &back); err != nil || back.Other != "boom" || back.Kind != FailureOther {
		t.Fatalf("reason round trip = %+v, %v", back, err)
	}
	if !IsInterestingLogLine("[1 0ms] router: found process path: x") || IsInterestingLogLine("sing-box started") {
		t.Fatal("pre-filter is wrong")
	}
	// F20: opened once per id at the match line, failed once per ERROR line, blocked
	// always under direct and never counted as a failure.
	exits := tracker.Exits()
	if len(exits) != 3 {
		t.Fatalf("exits = %+v", exits)
	}
	if got := exits["aaa"]; got.Opened == nil || *got.Opened != 2 || got.Failed != 2 || got.Blocked != 0 || got.LastFailure == nil || got.LastFailure.Kind != FailureNoAnswer {
		t.Fatalf("aaa exit = %+v", got)
	}
	if got := exits["bbb"]; got.Opened == nil || *got.Opened != 1 || got.Failed != 1 || got.LastFailure == nil || got.LastFailure.Kind != FailureTunnelDown {
		t.Fatalf("bbb exit = %+v", got)
	}
	// direct never saw its own match line here (id 40/45/47 fall back to it), but a
	// match line was seen overall (aaa/bbb), so its opened is 0, not nil.
	if got := exits["direct"]; got.Opened == nil || *got.Opened != 0 || got.Failed != 3 || got.Blocked != 2 {
		t.Fatalf("direct exit = %+v", got)
	}
	tracker.Clear()
	if len(tracker.Snapshot()) != 0 {
		t.Fatal("Clear kept rows")
	}
	if len(tracker.Exits()) != 0 {
		t.Fatal("Clear kept exit counters")
	}
}

func TestFailedConnectionsExitsGroupTagMapsToGroupID(t *testing.T) {
	tracker := NewFailedConnections()
	t0 := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	lines := []struct {
		level LogLevel
		line  string
	}{
		{LogLevelInfo, "[80 0ms] inbound/tun[tun-in]: inbound connection to streaming.example.com:443"},
		{LogLevelInfo, "[80 1ms] router: match[1] rule_set=rules-g-ccc => g-ccc"},
		{LogLevelError, "[80 3ms] inbound/tun[tun-in]: open connection to streaming.example.com:443: dial tcp 203.0.113.5:443: i/o timeout"},
	}
	for i, entry := range lines {
		tracker.Ingest(entry.line, entry.level, t0.Add(time.Duration(i)*time.Second))
	}
	exits := tracker.Exits()
	got := exits["ccc"]
	if got.Opened == nil || *got.Opened != 1 || got.Failed != 1 || got.Blocked != 0 || got.LastFailure == nil || got.LastFailure.Kind != FailureNoAnswer {
		t.Fatalf("ccc exit = %+v", got)
	}
}

func TestFailedConnectionsExitsNilOpenedUnderProblemsOnly(t *testing.T) {
	// Log detail Problems: only ERROR lines exist, no match line is ever seen — opened
	// stays nil for every exit and every failure is attributed to direct.
	tracker := NewFailedConnections()
	t0 := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	lines := []struct {
		level LogLevel
		line  string
	}{
		{LogLevelError, "ERROR [70 30ms] inbound/tun[tun-in]: open connection to a.example.net:443: dial tcp 198.51.100.2:443: connect: connection refused"},
		{LogLevelError, "ERROR [71 30ms] inbound/tun[tun-in]: open connection to b.example.net:443: dial tcp 198.51.100.3:443: connect: connection refused"},
	}
	for i, entry := range lines {
		tracker.Ingest(entry.line, entry.level, t0.Add(time.Duration(i)*time.Second))
	}
	exits := tracker.Exits()
	if len(exits) != 1 {
		t.Fatalf("exits = %+v", exits)
	}
	if got := exits["direct"]; got.Opened != nil || got.Failed != 2 {
		t.Fatalf("direct exit = %+v", got)
	}
}

func TestPlanHelpersForGroupsProxiesAndTheBlockList(t *testing.T) {
	config := `{"inbounds":[{"type":"tun","tag":"tun-in"},{"type":"mixed","tag":"proxy-t-` + tunnelA + `","listen":"127.0.0.1","listen_port":1081},{"type":"mixed","tag":"proxy-g-` + tunnelB + `","listen":"127.0.0.1","listen_port":1082}],` +
		`"outbounds":[{"type":"direct","tag":"direct"},{"type":"selector","tag":"g-` + tunnelB + `","outbounds":["t-` + tunnelA + `"],"default":"t-` + tunnelA + `"},{"type":"urltest","tag":"g-fast","outbounds":["t-` + tunnelA + `"]}],` +
		`"route":{"final":"g-` + tunnelB + `","rules":[{"action":"sniff"},{"inbound":["proxy-t-` + tunnelA + `"],"outbound":"t-` + tunnelA + `"},{"inbound":["proxy-g-` + tunnelB + `"],"outbound":"g-` + tunnelB + `"}],` +
		`"rule_set":[{"type":"local","tag":"rules-direct","format":"source","path":"rules-direct.json"},{"type":"local","tag":"block-ads","format":"binary","path":"C:\\Program Files\\Wayfork\\rulesets\\block-ads.srs"}]}}`
	plan := RuntimePlan{Version: PlanVersion, SingBox: SingBoxPlan{Config: config, RuleSets: map[string]string{
		"rules-t-" + tunnelA + ".json": "{}", "rules-g-" + tunnelB + ".json": "{}", "rules-g-" + tunnelB + "-ip.json": "{}", DirectRuleSet: "{}",
	}}}
	if got := plan.RoutedTunnelIDs(); len(got) != 1 || got[0] != tunnelA {
		t.Fatalf("routed tunnels = %v", got)
	}
	if got := plan.RoutedGroupIDs(); len(got) != 1 || got[0] != tunnelB {
		t.Fatalf("routed groups = %v", got)
	}
	if plan.SingBox.RouteFinal() != "g-"+tunnelB {
		t.Fatalf("route final = %s", plan.SingBox.RouteFinal())
	}
	groups := plan.SingBox.GroupOutbounds()
	if groups[tunnelB].Policy != "selector" || len(groups[tunnelB].Members) != 1 || groups["fast"].Policy != "urltest" {
		t.Fatalf("groups = %+v", groups)
	}
	inbounds := plan.SingBox.LocalProxyInbounds()
	if len(inbounds) != 2 || inbounds[1].Port != 1082 {
		t.Fatalf("inbounds = %+v", inbounds)
	}
	if id, ok := inbounds[1].ExitID(); !ok || id != tunnelB {
		t.Fatalf("exit id = %s, %v", id, ok)
	}
	blockPath := `C:\Program Files\Wayfork\rulesets\block-ads.srs`
	if paths := plan.SingBox.BinaryRuleSetPaths(); len(paths) != 1 || paths[0] != blockPath || !plan.SingBox.HasBlockList() {
		t.Fatalf("binary paths = %v", paths)
	}
	if err := ValidatePlan(plan); err == nil || !strings.Contains(err.Reason, "not the bundled block list") {
		t.Fatalf("a foreign block list path passed: %v", err)
	}
	exists := func(string) bool { return true }
	if err := ValidatePlanWith(plan, ValidateOptions{BlockListPath: blockPath, FileExists: exists}); err != nil {
		t.Fatalf("valid plan refused: %v", err)
	}
	if err := ValidatePlanWith(plan, ValidateOptions{BlockListPath: blockPath, FileExists: func(string) bool { return false }}); err == nil || !strings.Contains(err.Reason, "missing") {
		t.Fatalf("missing list accepted: %v", err)
	}
	bad := plan
	bad.SingBox.Config = strings.Replace(config, `"listen":"127.0.0.1","listen_port":1082`, `"listen":"0.0.0.0","listen_port":1082`, 1)
	if err := ValidatePlanWith(bad, ValidateOptions{BlockListPath: blockPath, FileExists: exists}); err == nil || !strings.Contains(err.Reason, "loopback") {
		t.Fatalf("0.0.0.0 accepted: %v", err)
	}
	bad.SingBox.Config = strings.Replace(config, `"listen_port":1082`, `"listen_port":1081`, 1)
	if err := ValidatePlanWith(bad, ValidateOptions{BlockListPath: blockPath, FileExists: exists}); err == nil || !strings.Contains(err.Reason, "two inbounds") {
		t.Fatalf("duplicate port accepted: %v", err)
	}
	bad.SingBox.Config = strings.Replace(config, `"tag":"proxy-g-`+tunnelB+`"`, `"tag":"socks-in"`, 1)
	if err := ValidatePlanWith(bad, ValidateOptions{BlockListPath: blockPath, FileExists: exists}); err == nil || !strings.Contains(err.Reason, "proxy-t-<id>") {
		t.Fatalf("foreign inbound tag accepted: %v", err)
	}

	stripped, ok := StripLocalProxyInbound(config, "proxy-t-"+tunnelA)
	if !ok || strings.Contains(stripped, "proxy-t-"+tunnelA) || !strings.Contains(stripped, "proxy-g-"+tunnelB) {
		t.Fatalf("strip = %v\n%s", ok, stripped)
	}
	if _, ok := StripLocalProxyInbound(config, "proxy-t-missing"); ok {
		t.Fatal("stripping a missing inbound succeeded")
	}
	if InboundBindFailure("FATAL[0000] start service: initialize inbound/mixed[proxy-t-abc]: listen tcp 127.0.0.1:1081: bind: Only one usage of each socket address (protocol/network address/port) is normally permitted.") != "proxy-t-abc" {
		t.Fatal("Windows bind failure not parsed")
	}
	if InboundBindFailure("INFO[0000] sing-box started (0.02s)") != "" {
		t.Fatal("a started line parsed as a bind failure")
	}
	if id, ok := RuleSetID("rules-g-" + tunnelB + "-ip.json"); !ok || id != tunnelB {
		t.Fatalf("group rule-set id = %s, %v", id, ok)
	}
	if !IsRuleSet("rules-g-x.json") || IsRuleSet("rules-direct.json") {
		t.Fatal("IsRuleSet is wrong for groups")
	}
	dir := t.TempDir()
	if BlockListRelativePath != filepath.Join("rulesets", "block-ads.srs") && !strings.HasSuffix(BlockListRelativePath, "block-ads.srs") {
		t.Fatalf("relative path = %s", BlockListRelativePath)
	}
	_ = os.WriteFile(filepath.Join(dir, "x"), nil, 0o600)
}
