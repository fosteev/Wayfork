package core

import (
	"fmt"
	"slices"
	"strings"
)

// The Windows resolver override is one NRPT catch-all rule — `Namespace "."` →
// `NameServers [<TUN resolver>]` — tagged with a comment so the service recognises its
// own rule again after a crash or a reboot (docs/design/08-windows.md, "Resolver
// override"; spike S6c/S7). Per-adapter DNS leaks and is not used.
const (
	NRPTNamespace = "."
	NRPTComment   = "Wayfork"
	// NRPTServiceName is what `ResolverOverrideState.active.service` carries on Windows.
	NRPTServiceName = "NRPT"
)

// NRPTRule is one local Name Resolution Policy Table rule (`Get-DnsClientNrptRule`).
type NRPTRule struct {
	// The rule id (`Name`, a `{GUID}`); empty for a rule not yet written.
	Name        string   `json:"name"`
	Namespace   string   `json:"namespace"`
	NameServers []string `json:"nameServers"`
	Comment     string   `json:"comment"`
}

// IsWayfork reports whether the rule is the service's own catch-all — a stale one with an
// old address included.
func (r NRPTRule) IsWayfork() bool {
	return r.Namespace == NRPTNamespace && r.Comment == NRPTComment
}

// IsCatchAll reports whether the rule covers every name.
func (r NRPTRule) IsCatchAll() bool {
	return r.Namespace == NRPTNamespace
}

// ResolverSnapshot is what the service sees of the local NRPT.
type ResolverSnapshot struct {
	Rules []NRPTRule
}

// ResolverOverrideRecord is `run\dns-override.json`: proof that the override was applied,
// so a service starting after a crash or a reboot knows to remove it first (the rule
// itself is found by its comment; the record is belt and braces).
type ResolverOverrideRecord struct {
	Version int    `json:"version"`
	Address string `json:"address"`
	// The rule(s) written, for diagnostics.
	Rules []NRPTRule `json:"rules"`
}

// ResolverOverrideRecordVersion is the current record format.
const ResolverOverrideRecordVersion = 1

// ResolverOverrideActionKind is what the I/O layer performs.
type ResolverOverrideActionKind string

const (
	// ResolverWrite: save `Record`, then add `Rule` (`Add-DnsClientNrptRule`).
	ResolverWrite ResolverOverrideActionKind = "write"
	// ResolverRestore: remove the rules named in `RuleNames` (`Remove-DnsClientNrptRule`),
	// then delete the record.
	ResolverRestore ResolverOverrideActionKind = "restore"
)

// ResolverOverrideAction is one step of a resolver-override plan.
type ResolverOverrideAction struct {
	Kind ResolverOverrideActionKind
	// ResolverWrite: the rule to add.
	Rule NRPTRule
	// ResolverWrite: the record to save before adding; ResolverRestore: the record to delete.
	Record ResolverOverrideRecord
	// ResolverRestore: the service's rules currently present (may be empty).
	RuleNames []string
}

// PlanResolverOverride decides what to do with the NRPT: nothing, add the catch-all, or
// remove it — and the state to report. Pure; the I/O layer performs the actions in order.
func PlanResolverOverride(
	active bool, snapshot ResolverSnapshot, saved *ResolverOverrideRecord, address string,
) ([]ResolverOverrideAction, ResolverOverrideState) {
	var ours, foreign []NRPTRule
	for _, rule := range snapshot.Rules {
		switch {
		case rule.IsWayfork():
			ours = append(ours, rule)
		case rule.IsCatchAll():
			foreign = append(foreign, rule)
		}
	}
	restore := func() []ResolverOverrideAction {
		if len(ours) == 0 && saved == nil {
			return nil
		}
		record := ResolverOverrideRecord{Version: ResolverOverrideRecordVersion, Address: address, Rules: ours}
		if saved != nil {
			record = *saved
		} else if len(ours) > 0 && len(ours[0].NameServers) > 0 {
			record.Address = ours[0].NameServers[0]
		}
		names := make([]string, 0, len(ours))
		for _, rule := range ours {
			names = append(names, rule.Name)
		}
		return []ResolverOverrideAction{{Kind: ResolverRestore, Record: record, RuleNames: names}}
	}

	if !active {
		return restore(), NewResolverOverrideOff()
	}
	if address == "" {
		return restore(), NewResolverOverrideFailed("no resolver address")
	}
	if len(foreign) > 0 {
		// Two catch-alls have no defined precedence: never add a second one.
		return restore(), NewResolverOverrideFailed(fmt.Sprintf(
			"another NRPT rule for %q (%s) points at %s",
			NRPTNamespace, foreign[0].Name, strings.Join(foreign[0].NameServers, ", ")))
	}
	if len(ours) == 1 && slices.Equal(ours[0].NameServers, []string{address}) {
		return nil, NewResolverOverrideActive(NRPTServiceName)
	}
	rule := NRPTRule{Namespace: NRPTNamespace, NameServers: []string{address}, Comment: NRPTComment}
	actions := restore()
	actions = append(actions, ResolverOverrideAction{
		Kind: ResolverWrite, Rule: rule,
		Record: ResolverOverrideRecord{
			Version: ResolverOverrideRecordVersion, Address: address, Rules: []NRPTRule{rule},
		},
	})
	return actions, NewResolverOverrideActive(NRPTServiceName)
}
