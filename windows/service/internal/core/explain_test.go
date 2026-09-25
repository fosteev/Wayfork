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
