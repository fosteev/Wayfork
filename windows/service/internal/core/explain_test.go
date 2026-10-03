package core

import (
	"reflect"
	"testing"
)

// A minimal config: only `route` matters to RouteRules/RuleSetSelectorsByTag/RouteFinal.
// One rule of each selector kind the generator emits, plus two entries Explain does not
// model (sniff, ip_is_private) to prove RouteRules skips them.
const explainConfig = `{
  "route": {
    "final": "direct",
    "rule_set": [
      {"type": "local", "format": "source", "tag": "rules-app", "path": "rules-app.json"},
      {"type": "local", "format": "source", "tag": "rules-suffix", "path": "rules-suffix.json"},
      {"type": "local", "format": "source", "tag": "rules-ip", "path": "rules-ip.json"}
    ],
    "rules": [
      {"action": "sniff"},
      {"outbound": "t-tunnel-a", "rule_set": ["rules-app"]},
      {"outbound": "g-group-a", "rule_set": ["rules-suffix"]},
      {"outbound": "t-tunnel-b", "rule_set": ["rules-ip"]},
      {"ip_is_private": true, "outbound": "direct"}
    ]
  }
}`

func explainPlan() SingBoxPlan {
	return SingBoxPlan{
		Config: explainConfig,
		RuleSets: map[string]string{
			// The Squirrel-widened process_path_regex a Windows app rule would emit
			// (VersionedAppPath.regex, docs/roadmap/versioned-app-paths-and-ctl-connections.md):
			// any `app-<ver>` sibling under Discord matches.
			"rules-app.json":    `{"rules":[{"process_path_regex":["(?i)^C:\\\\Discord\\\\app-\\d[^\\\\]*\\\\Discord\\.exe$"]}],"version":3}`,
			"rules-suffix.json": `{"rules":[{"domain_suffix":[".example.com"]}],"version":3}`,
			"rules-ip.json":     `{"rules":[{"ip_cidr":["93.184.216.0/24"]}],"version":3}`,
		},
	}
}

func TestRouteRulesSkipsEntriesWithoutBothOutboundAndRuleSet(t *testing.T) {
	rules := explainPlan().RouteRules()
	want := []ExplainRule{
		{Outbound: "t-tunnel-a", Tags: []string{"rules-app"}},
		{Outbound: "g-group-a", Tags: []string{"rules-suffix"}},
		{Outbound: "t-tunnel-b", Tags: []string{"rules-ip"}},
	}
	if !reflect.DeepEqual(rules, want) {
		t.Errorf("RouteRules = %+v", rules)
	}
}

func TestRuleSetSelectorsByTagParsesEveryReferencedFile(t *testing.T) {
	selectors := explainPlan().RuleSetSelectorsByTag()
	if len(selectors) != 3 {
		t.Fatalf("selectors = %+v", selectors)
	}
	if !selectors["rules-app"].ProcessPathRegex.Has(`(?i)^C:\\Discord\\app-\d[^\\]*\\Discord\.exe$`) {
		t.Errorf("app selectors = %+v", selectors["rules-app"])
	}
	if !selectors["rules-suffix"].DomainSuffix.Has(".example.com") {
		t.Errorf("suffix selectors = %+v", selectors["rules-suffix"])
	}
	if !selectors["rules-ip"].IPCIDR.Has("93.184.216.0/24") {
		t.Errorf("ip selectors = %+v", selectors["rules-ip"])
	}
}

func explain(t *testing.T, query ExplainQuery) ExplainResult {
	t.Helper()
	plan := explainPlan()
	return Explain(query, plan.RouteRules(), plan.RuleSetSelectorsByTag(), plan.RouteFinal())
}

func TestExplainMatchesASquirrelWidenedProcessPathRegex(t *testing.T) {
	result := explain(t, ExplainQuery{ProcessPath: `C:\Discord\app-1.0.9259\Discord.exe`})
	if len(result.Matches) != 1 || result.Matches[0].Exit != "tunnel-a" ||
		!reflect.DeepEqual(result.Matches[0].Tags, []string{"rules-app"}) {
		t.Errorf("matches = %+v", result.Matches)
	}
	if result.Fallback != "direct" || result.Note != ExplainNote {
		t.Errorf("fallback/note = %q / %q", result.Fallback, result.Note)
	}
}

func TestExplainMatchesADomainSuffix(t *testing.T) {
	result := explain(t, ExplainQuery{Host: "cdn.example.com"})
	if len(result.Matches) != 1 || result.Matches[0].Exit != "group-a" {
		t.Errorf("matches = %+v", result.Matches)
	}
}

func TestExplainMatchesAnIPCIDR(t *testing.T) {
	result := explain(t, ExplainQuery{IP: "93.184.216.34"})
	if len(result.Matches) != 1 || result.Matches[0].Exit != "tunnel-b" {
		t.Errorf("matches = %+v", result.Matches)
	}
}

func TestExplainFallsBackWhenNothingMatches(t *testing.T) {
	result := explain(t, ExplainQuery{Host: "unmatched.example"})
	if len(result.Matches) != 0 || result.Fallback != "direct" {
		t.Errorf("no-match result = %+v", result)
	}
}

func TestExplainResultMarshalJSONNeverEmitsNullMatches(t *testing.T) {
	data, err := MarshalWire(ExplainResult{Fallback: "direct", Note: ExplainNote})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"fallback":"direct","matches":[],"note":"` + ExplainNote + `"}`
	if string(data) != want {
		t.Errorf("wire = %s, want %s", data, want)
	}
}

func TestRouteRulesReadsNetwork(t *testing.T) {
	plan := SingBoxPlan{Config: `{"route":{"rules":[
      {"outbound":"direct","rule_set":["rules-direct-udp"],"network":["udp"]},
      {"outbound":"t-a","rule_set":["rules-app"]}]}}`}
	want := []ExplainRule{
		{Outbound: "direct", Tags: []string{"rules-direct-udp"}, Network: []string{"udp"}},
		{Outbound: "t-a", Tags: []string{"rules-app"}},
	}
	if got := plan.RouteRules(); !reflect.DeepEqual(got, want) {
		t.Errorf("RouteRules = %+v", got)
	}
}

// Discord: UDP goes Direct, the rest through tunnel-a. A narrowed rule answers only the
// query with its network (F23).
func TestExplainSkipsRulesOfAnotherNetwork(t *testing.T) {
	selectors := map[string]RuleSetSelectors{}
	rules := []ExplainRule{
		{Outbound: "direct", Tags: []string{"rules-direct-udp"}, Network: []string{"udp"}},
		{Outbound: "t-tunnel-a", Tags: []string{"rules-direct-udp"}},
	}
	selectors["rules-direct-udp"] = RuleSetSelectors{DomainSuffix: StringSet{".discord.example": {}}}
	query := ExplainQuery{Host: "voice.discord.example"}
	query.Network = "tcp"
	tcp := Explain(query, rules, selectors, "direct")
	query.Network = "udp"
	udp := Explain(query, rules, selectors, "direct")
	query.Network = ""
	unasked := Explain(query, rules, selectors, "direct")
	if len(tcp.Matches) != 1 || tcp.Matches[0].Exit != "tunnel-a" {
		t.Errorf("tcp = %+v", tcp.Matches)
	}
	if len(udp.Matches) != 2 || udp.Matches[0].Exit != "direct" {
		t.Errorf("udp = %+v", udp.Matches)
	}
	if len(unasked.Matches) != 2 {
		t.Errorf("no network = %+v", unasked.Matches)
	}
	if _, both := CombineExplain(tcp, udp).(ExplainBoth); !both {
		t.Error("differing answers must come back as ExplainBoth")
	}
	if _, same := CombineExplain(tcp, tcp).(ExplainResult); !same {
		t.Error("equal answers keep today's shape")
	}
	if (ExplainQuery{Network: "sctp"}).ValidNetwork() || !(ExplainQuery{Network: "udp"}).ValidNetwork() {
		t.Error("ValidNetwork")
	}
}
