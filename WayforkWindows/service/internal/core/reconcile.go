package core

import "sort"

// ReconcileState is what the service currently runs, as far as reconcile cares.
type ReconcileState struct {
	SingBoxRunning bool
	// SingBoxPlan.ConfigHash of the config on disk; "" = never written.
	SingBoxConfigHash string
	// Rule-set files on disk: name → contents.
	RuleSets map[string]string
	// Running (or supervised) OpenVPN processes: tunnel id → OpenVPNDiffKey.
	OpenVPN map[string]string
}

// SingBoxActionKind is what reconcile does with sing-box.
type SingBoxActionKind string

const (
	// SingBoxNone: config and rule-sets unchanged, process running.
	SingBoxNone SingBoxActionKind = "none"
	// SingBoxRewriteRuleSets: same config, some rule-set files differ: rewrite `Files` in
	// place, no restart.
	SingBoxRewriteRuleSets SingBoxActionKind = "rewriteRuleSets"
	// SingBoxStart: write everything, `sing-box check`, start (not running yet).
	SingBoxStart SingBoxActionKind = "start"
	// SingBoxRestart: write everything, `sing-box check`, restart the running process.
	SingBoxRestart SingBoxActionKind = "restart"
)

// SingBoxAction is the sing-box step of a reconcile.
type SingBoxAction struct {
	Kind SingBoxActionKind
	// The rule-set files to rewrite (SingBoxRewriteRuleSets), sorted.
	Files []string
}

// ReconcileActions are the steps that turn a ReconcileState into a RuntimePlan
// (docs/design/00-architecture.md, "Reconcile algorithm").
type ReconcileActions struct {
	// Tunnel ids to stop first (removed or changed), sorted.
	StopOpenVPN []string
	// Tunnel ids to start afterwards (changed ones first, then added ones in plan order).
	StartOpenVPN []string
	SingBox      SingBoxAction
	// Rule-set files on disk that the plan no longer contains, sorted.
	StaleRuleSets []string
}

// IsNoOp reports whether the plan is already in effect.
func (a ReconcileActions) IsNoOp() bool {
	return len(a.StopOpenVPN) == 0 && len(a.StartOpenVPN) == 0 &&
		a.SingBox.Kind == SingBoxNone && len(a.StaleRuleSets) == 0
}

// PlanReconcile diffs the running state against the plan: OpenVPN by id + diff key,
// sing-box by config hash, rule-sets by contents.
func PlanReconcile(state ReconcileState, plan RuntimePlan) ReconcileActions {
	desired := make(map[string]string, len(plan.OpenVPN))
	for _, runtime := range plan.OpenVPN {
		desired[runtime.ID] = OpenVPNDiffKey(runtime, plan.LogLevel)
	}
	stop := []string{}
	start := []string{}
	for _, id := range sortedKeys(state.OpenVPN) {
		key, wanted := desired[id]
		switch {
		case !wanted:
			stop = append(stop, id)
		case key != state.OpenVPN[id]:
			stop = append(stop, id)
			start = append(start, id)
		}
	}
	for _, runtime := range plan.OpenVPN {
		if _, running := state.OpenVPN[runtime.ID]; !running {
			start = append(start, runtime.ID)
		}
	}

	stale := []string{}
	for _, name := range sortedKeys(state.RuleSets) {
		if _, kept := plan.SingBox.RuleSets[name]; !kept {
			stale = append(stale, name)
		}
	}
	singBox := SingBoxAction{Kind: SingBoxNone}
	switch {
	case !state.SingBoxRunning:
		singBox.Kind = SingBoxStart
	case state.SingBoxConfigHash != plan.SingBox.ConfigHash:
		singBox.Kind = SingBoxRestart
	default:
		changed := []string{}
		for _, name := range sortedKeys(plan.SingBox.RuleSets) {
			if state.RuleSets[name] != plan.SingBox.RuleSets[name] {
				changed = append(changed, name)
			}
		}
		if len(changed) > 0 {
			singBox = SingBoxAction{Kind: SingBoxRewriteRuleSets, Files: changed}
		}
	}
	return ReconcileActions{StopOpenVPN: stop, StartOpenVPN: start, SingBox: singBox, StaleRuleSets: stale}
}

func sortedKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
