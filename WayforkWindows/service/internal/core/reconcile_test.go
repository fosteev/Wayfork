package core

import (
	"reflect"
	"testing"
)

func TestReconcileDiff(t *testing.T) {
	a := testRuntime(idA, "Wayfork-1", "remote x")
	b := testRuntime(idB, "Wayfork-2", "remote y")
	plan := testPlan([]OpenVPNRuntime{a, b}, map[string]string{RuleSet(idA): "A", RuleSet(idB): "B"}, "{}")
	keyA := OpenVPNDiffKey(a, LogLevelInfo)
	keyB := OpenVPNDiffKey(b, LogLevelInfo)

	// Cold start: everything starts.
	cold := PlanReconcile(ReconcileState{}, plan)
	want := ReconcileActions{
		StopOpenVPN: []string{}, StartOpenVPN: []string{idA, idB},
		SingBox: SingBoxAction{Kind: SingBoxStart}, StaleRuleSets: []string{},
	}
	if !reflect.DeepEqual(cold, want) {
		t.Errorf("cold start = %+v, want %+v", cold, want)
	}
	if cold.IsNoOp() {
		t.Error("a cold start is not a no-op")
	}

	// Same plan again: no-op.
	current := ReconcileState{
		SingBoxRunning: true, SingBoxConfigHash: plan.SingBox.ConfigHash,
		RuleSets: plan.SingBox.RuleSets, OpenVPN: map[string]string{idA: keyA, idB: keyB},
	}
	if actions := PlanReconcile(current, plan); !actions.IsNoOp() {
		t.Errorf("same plan = %+v", actions)
	}

	// Rule edit: rewrite one file, no restart.
	rules := testPlan(plan.OpenVPN, map[string]string{RuleSet(idA): "A", RuleSet(idB): "B2"}, "{}")
	if got := PlanReconcile(current, rules).SingBox; !reflect.DeepEqual(got, SingBoxAction{Kind: SingBoxRewriteRuleSets, Files: []string{RuleSet(idB)}}) {
		t.Errorf("rule edit = %+v", got)
	}

	// Tunnel B removed: stop it, sing-box config changed → restart, stale rule-set.
	removed := testPlan([]OpenVPNRuntime{a}, map[string]string{RuleSet(idA): "A"}, `{"v":2}`)
	actions := PlanReconcile(current, removed)
	if !reflect.DeepEqual(actions.StopOpenVPN, []string{idB}) || len(actions.StartOpenVPN) != 0 ||
		actions.SingBox.Kind != SingBoxRestart || !reflect.DeepEqual(actions.StaleRuleSets, []string{RuleSet(idB)}) {
		t.Errorf("removal = %+v", actions)
	}

	// Config body of A changed: restart A only.
	changed := testPlan([]OpenVPNRuntime{testRuntime(idA, "Wayfork-1", "remote z"), b}, plan.SingBox.RuleSets, "{}")
	restart := PlanReconcile(current, changed)
	if !reflect.DeepEqual(restart.StopOpenVPN, []string{idA}) || !reflect.DeepEqual(restart.StartOpenVPN, []string{idA}) || restart.SingBox.Kind != SingBoxNone {
		t.Errorf("config change = %+v", restart)
	}

	// A moved to another adapter: also a restart of A.
	moved := testPlan([]OpenVPNRuntime{testRuntime(idA, "Wayfork-3", "remote x"), b}, plan.SingBox.RuleSets, "{}")
	if got := PlanReconcile(current, moved); !reflect.DeepEqual(got.StopOpenVPN, []string{idA}) || !reflect.DeepEqual(got.StartOpenVPN, []string{idA}) {
		t.Errorf("adapter change = %+v", got)
	}

	// Log level change restarts every OpenVPN process.
	verbose := plan
	verbose.LogLevel = LogLevelDebug
	verboseActions := PlanReconcile(current, verbose)
	if !reflect.DeepEqual(verboseActions.StopOpenVPN, []string{idA, idB}) || !reflect.DeepEqual(verboseActions.StartOpenVPN, []string{idA, idB}) {
		t.Errorf("log level change = %+v", verboseActions)
	}

	// sing-box died: start it, leave tunnels alone.
	dead := current
	dead.SingBoxRunning = false
	revive := PlanReconcile(dead, plan)
	if revive.SingBox.Kind != SingBoxStart || len(revive.StopOpenVPN) != 0 || len(revive.StartOpenVPN) != 0 {
		t.Errorf("revive = %+v", revive)
	}

	// Changed tunnels restart before added ones start; stops are sorted.
	c := testRuntime("00000000-0000-4000-8000-000000000003", "Wayfork-3", "remote c")
	grown := testPlan([]OpenVPNRuntime{c, testRuntime(idB, "Wayfork-2", "remote y2"), a}, plan.SingBox.RuleSets, "{}")
	grownActions := PlanReconcile(current, grown)
	if !reflect.DeepEqual(grownActions.StopOpenVPN, []string{idB}) || !reflect.DeepEqual(grownActions.StartOpenVPN, []string{idB, c.ID}) {
		t.Errorf("grown = %+v", grownActions)
	}
}
