package core

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func rowFixturePlan(t *testing.T, variant string) RuntimePlan {
	t.Helper()
	dir := filepath.Join("singbox", variant)
	entries, err := os.ReadDir(filepath.Join(fixturesRoot(t), dir))
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]string{}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "rules-") {
			files[entry.Name()] = readFixture(t, dir, entry.Name())
		}
	}
	return testPlan(nil, files, readFixture(t, dir, SingBoxConfig))
}

func TestRowFileTrustBoundaryAndLegacyCompatibility(t *testing.T) {
	for _, variant := range []string{"two-tunnels", "f24-ordered-lists", "f24-follow-direct", "f24-follow-tunnel"} {
		plan := rowFixturePlan(t, variant)
		rejectedByF23 := false
		for name := range plan.SingBox.RuleSets {
			// Frozen F23 filename allowlist: an old service must reject the new
			// topology rather than silently reinterpret user precedence.
			id, known := RuleSetID(name)
			legacyAccepted := name == DirectRuleSet || name == DirectIPRuleSet || name == DirectTCPRuleSet || name == DirectUDPRuleSet || (known && IsTunnelID(id))
			if !legacyAccepted {
				rejectedByF23 = true
			}
		}
		if !rejectedByF23 {
			t.Fatalf("%s did not require the coordinated F24 service", variant)
		}
		if err := ValidatePlanWith(plan, ValidateOptions{BlockListPath: "/Applications/Wayfork.app/Contents/Resources/rulesets/block-ads.srs"}); err != nil {
			t.Fatalf("%s: %v", variant, err)
		}
	}
	if err := ValidatePlan(twoTunnelsPlan(t)); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"../rules-r-" + idA + ".json", `x\rules-r-` + idA + ".json", "rules-r-" + strings.ToUpper(idHex) + ".json", "rules-r-" + idA + "-ip.json", "rules-r-" + idA + ".json.bak", "rules-r-invalid.json"} {
		plan := testPlan(nil, map[string]string{name: "{}"}, "{}")
		if ValidatePlan(plan) == nil {
			t.Errorf("accepted unsafe row filename %q", name)
		}
	}
}

func TestRoutedDefinitionsNeedNoRuleFiles(t *testing.T) {
	config := `{"outbounds":[{"tag":"t-` + idA + `"},{"tag":"g-` + idHex + `","type":"selector"},{"tag":"t-bad"}],"endpoints":[{"tag":"t-` + idB + `","type":"wireguard"},{"tag":"t-` + idA + `"}]}`
	plan := testPlan(nil, map[string]string{"rules-r-" + idHex + ".json": "{}"}, config)
	if !slices.Equal(plan.RoutedTunnelIDs(), []string{idA, idB}) {
		t.Fatal(plan.RoutedTunnelIDs())
	}
	if !slices.Equal(plan.RoutedGroupIDs(), []string{idHex}) {
		t.Fatal(plan.RoutedGroupIDs())
	}
}

func TestRowPlanSelectorsReconcileAndHash(t *testing.T) {
	plan := rowFixturePlan(t, "f24-ordered-lists")
	selectors := plan.SingBox.RuleSetSelectorsByTag()
	for _, rule := range plan.SingBox.RouteRules() {
		for _, tag := range rule.Tags {
			if _, ok := selectors[tag]; !ok {
				t.Fatalf("missing selector %s", tag)
			}
		}
	}
	state := ReconcileState{SingBoxRunning: true, SingBoxConfigHash: plan.SingBox.ConfigHash, RuleSets: plan.SingBox.RuleSets}
	if !PlanReconcile(state, plan).IsNoOp() {
		t.Fatal("identical plan changed")
	}
	var name string
	for file := range plan.SingBox.RuleSets {
		if IsRowRuleSet(file) {
			name = file
			break
		}
	}
	edited := rowFixturePlan(t, "f24-ordered-lists")
	edited.SingBox.RuleSets[name] = `{"version":3,"rules":[{"domain":["edited.example"]}]}`
	actions := PlanReconcile(state, edited)
	if actions.SingBox.Kind != SingBoxRewriteRuleSets || !slices.Equal(actions.SingBox.Files, []string{name}) {
		t.Fatal(actions)
	}
	change, ok := RuleSetChange(state.RuleSets, edited.SingBox.RuleSets, []string{name})
	if !ok || !change.Matches("edited.example", "", "") {
		t.Fatal("row edit did not cut affected domain")
	}
	if plan.PlanHash() == edited.PlanHash() {
		t.Fatal("row content absent from hash")
	}
	changedTarget := edited
	changedTarget.SingBox.Config += "\n"
	changedTarget.SingBox.ConfigHash = SHA256Hex(changedTarget.SingBox.Config)
	if PlanReconcile(state, changedTarget).SingBox.Kind != SingBoxRestart {
		t.Fatal("main config change must restart")
	}
	delete(edited.SingBox.RuleSets, name)
	if !slices.Equal(PlanReconcile(state, edited).StaleRuleSets, []string{name}) {
		t.Fatal("removed row not cleaned")
	}
}

func TestRowExplainRespectsListOrderAndTransport(t *testing.T) {
	plan := rowFixturePlan(t, "f24-ordered-lists")
	result := Explain(ExplainQuery{Host: "api.example.com"}, plan.SingBox.RouteRules(), plan.SingBox.RuleSetSelectorsByTag(), plan.SingBox.RouteFinal())
	if len(result.Matches) < 2 || result.Matches[0].Exit != idB || result.Matches[1].Exit != idA {
		t.Fatalf("non-adjacent exits regrouped: %+v", result)
	}
	direct := rowFixturePlan(t, "f24-follow-direct")
	result = Explain(ExplainQuery{Host: "api.example.com"}, direct.SingBox.RouteRules(), direct.SingBox.RuleSetSelectorsByTag(), direct.SingBox.RouteFinal())
	if len(result.Matches) == 0 || result.Matches[0].Exit != "direct" {
		t.Fatalf("follow Direct lost its position: %+v", result)
	}
	fileA, fileB := "rules-r-"+idA+".json", "rules-r-"+idB+".json"
	config := `{"route":{"final":"direct","rule_set":[{"tag":"a","path":"` + fileA + `"},{"tag":"b","path":"` + fileB + `"}],"rules":[{"rule_set":["a"],"outbound":"t-` + idA + `"},{"rule_set":["b"],"network":["udp"],"outbound":"t-` + idB + `"}]}}`
	p := SingBoxPlan{Config: config, RuleSets: map[string]string{fileA: `{"rules":[{"ip_cidr":["203.0.113.0/24"]}]}`, fileB: `{"rules":[{"ip_cidr":["203.0.113.4/32"]}]}`}}
	rules := p.RouteRules()
	result = Explain(ExplainQuery{IP: "203.0.113.4", Network: "udp"}, rules, p.RuleSetSelectorsByTag(), p.RouteFinal())
	if len(result.Matches) != 2 || result.Matches[0].Exit != idA {
		t.Fatalf("later narrowed row jumped broad row: %+v", result)
	}
	rules[0], rules[1] = rules[1], rules[0]
	result = Explain(ExplainQuery{IP: "203.0.113.4", Network: "udp"}, rules, p.RuleSetSelectorsByTag(), p.RouteFinal())
	if result.Matches[0].Exit != idB {
		t.Fatal("row reorder did not change UDP winner")
	}
	result = Explain(ExplainQuery{IP: "203.0.113.4", Network: "tcp"}, rules, p.RuleSetSelectorsByTag(), p.RouteFinal())
	if len(result.Matches) != 1 || result.Matches[0].Exit != idA {
		t.Fatal("network filter ignored")
	}
}
