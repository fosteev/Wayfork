package core

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// docs/design/08-windows.md, "Resolver override" (F12 on Windows: one NRPT catch-all).

const tunResolver = "172.19.0.2"

var (
	ourRule     = NRPTRule{Name: "{11111111-0000-4000-8000-000000000001}", Namespace: ".", NameServers: []string{tunResolver}, Comment: NRPTComment}
	staleRule   = NRPTRule{Name: "{11111111-0000-4000-8000-000000000002}", Namespace: ".", NameServers: []string{"172.19.0.9"}, Comment: NRPTComment}
	foreignRule = NRPTRule{Name: "{22222222-0000-4000-8000-000000000001}", Namespace: ".", NameServers: []string{"10.0.0.53"}, Comment: "corp"}
	otherRule   = NRPTRule{Name: "{33333333-0000-4000-8000-000000000001}", Namespace: ".corp.example", NameServers: []string{"10.0.0.53"}}
	savedRecord = ResolverOverrideRecord{Version: 1, Address: tunResolver, Rules: []NRPTRule{ourRule}}
	freshRule   = NRPTRule{Namespace: ".", NameServers: []string{tunResolver}, Comment: NRPTComment}
	writeAction = ResolverOverrideAction{
		Kind: ResolverWrite, Rule: freshRule,
		Record: ResolverOverrideRecord{Version: 1, Address: tunResolver, Rules: []NRPTRule{freshRule}},
	}
)

func planResolver(active bool, rules []NRPTRule, saved *ResolverOverrideRecord) ([]ResolverOverrideAction, ResolverOverrideState) {
	return PlanResolverOverride(active, ResolverSnapshot{Rules: rules}, saved, tunResolver)
}

func expectActions(t *testing.T, got, want []ResolverOverrideAction) {
	t.Helper()
	if len(got) == 0 && len(want) == 0 {
		return
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("actions = %+v, want %+v", got, want)
	}
}

func TestFirstActivationWritesTheCatchAll(t *testing.T) {
	actions, state := planResolver(true, []NRPTRule{otherRule}, nil)
	expectActions(t, actions, []ResolverOverrideAction{writeAction})
	if !reflect.DeepEqual(state, NewResolverOverrideActive(NRPTServiceName)) {
		t.Errorf("state = %+v", state)
	}
}

func TestAConsistentOverrideNeedsNothing(t *testing.T) {
	actions, state := planResolver(true, []NRPTRule{ourRule, otherRule}, &savedRecord)
	expectActions(t, actions, nil)
	if !reflect.DeepEqual(state, NewResolverOverrideActive(NRPTServiceName)) {
		t.Errorf("state = %+v", state)
	}
	// The rule is the truth; a missing record does not trigger a rewrite.
	actions, _ = planResolver(true, []NRPTRule{ourRule}, nil)
	expectActions(t, actions, nil)
}

func TestAStaleOrDuplicatedRuleIsReplaced(t *testing.T) {
	actions, state := planResolver(true, []NRPTRule{staleRule}, nil)
	expectActions(t, actions, []ResolverOverrideAction{
		{Kind: ResolverRestore, Record: ResolverOverrideRecord{Version: 1, Address: "172.19.0.9", Rules: []NRPTRule{staleRule}}, RuleNames: []string{staleRule.Name}},
		writeAction,
	})
	if !reflect.DeepEqual(state, NewResolverOverrideActive(NRPTServiceName)) {
		t.Errorf("state = %+v", state)
	}
	actions, _ = planResolver(true, []NRPTRule{ourRule, staleRule}, &savedRecord)
	expectActions(t, actions, []ResolverOverrideAction{
		{Kind: ResolverRestore, Record: savedRecord, RuleNames: []string{ourRule.Name, staleRule.Name}},
		writeAction,
	})
}

func TestAForeignCatchAllBlocksTheOverride(t *testing.T) {
	actions, state := planResolver(true, []NRPTRule{foreignRule}, nil)
	expectActions(t, actions, nil)
	if state.Kind != ResolverOverrideFailed || !strings.Contains(state.Reason, foreignRule.Name) || !strings.Contains(state.Reason, "10.0.0.53") {
		t.Errorf("state = %+v", state)
	}
	// Ours goes away rather than competing with it.
	actions, state = planResolver(true, []NRPTRule{ourRule, foreignRule}, &savedRecord)
	expectActions(t, actions, []ResolverOverrideAction{{Kind: ResolverRestore, Record: savedRecord, RuleNames: []string{ourRule.Name}}})
	if state.Kind != ResolverOverrideFailed {
		t.Errorf("state = %+v", state)
	}
}

func TestDeactivationRestoresOnlyWhatIsThere(t *testing.T) {
	actions, state := planResolver(false, []NRPTRule{otherRule}, nil)
	expectActions(t, actions, nil)
	if !reflect.DeepEqual(state, NewResolverOverrideOff()) {
		t.Errorf("state = %+v", state)
	}
	actions, _ = planResolver(false, []NRPTRule{ourRule}, &savedRecord)
	expectActions(t, actions, []ResolverOverrideAction{{Kind: ResolverRestore, Record: savedRecord, RuleNames: []string{ourRule.Name}}})
	// A record without a rule (the rule was removed by hand): only the record goes.
	actions, _ = planResolver(false, nil, &savedRecord)
	expectActions(t, actions, []ResolverOverrideAction{{Kind: ResolverRestore, Record: savedRecord, RuleNames: []string{}}})
	// A rule without a record (the service crashed before saving it): the rule goes.
	actions, _ = planResolver(false, []NRPTRule{ourRule}, nil)
	expectActions(t, actions, []ResolverOverrideAction{{Kind: ResolverRestore, Record: savedRecord, RuleNames: []string{ourRule.Name}}})
}

func TestNoResolverAddressFails(t *testing.T) {
	actions, state := PlanResolverOverride(true, ResolverSnapshot{Rules: []NRPTRule{ourRule}}, &savedRecord, "")
	expectActions(t, actions, []ResolverOverrideAction{{Kind: ResolverRestore, Record: savedRecord, RuleNames: []string{ourRule.Name}}})
	if !reflect.DeepEqual(state, NewResolverOverrideFailed("no resolver address")) {
		t.Errorf("state = %+v", state)
	}
}

func TestTheRecordRoundTripsThroughJSON(t *testing.T) {
	data, err := json.Marshal(savedRecord)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"version":1,"address":"172.19.0.2","rules":[{"name":"{11111111-0000-4000-8000-000000000001}","namespace":".","nameServers":["172.19.0.2"],"comment":"Wayfork"}]}`
	if string(data) != want {
		t.Errorf("record = %s", data)
	}
	var decoded ResolverOverrideRecord
	if err := json.Unmarshal(data, &decoded); err != nil || !reflect.DeepEqual(decoded, savedRecord) {
		t.Errorf("round trip = %+v, %v", decoded, err)
	}
	if !ourRule.IsWayfork() || !staleRule.IsWayfork() || foreignRule.IsWayfork() || otherRule.IsWayfork() {
		t.Error("IsWayfork is wrong")
	}
	if !foreignRule.IsCatchAll() || otherRule.IsCatchAll() {
		t.Error("IsCatchAll is wrong")
	}
}
