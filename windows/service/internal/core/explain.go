package core

// ExplainQuery selects exactly one field to explain by: a process path, a host, or an IP
// (#2's `wayforkctl explain`; also the pipe's `explain` params — the server rejects a
// query with zero or more than one field set).
type ExplainQuery struct {
	ProcessPath string `json:"process,omitempty"`
	Host        string `json:"host,omitempty"`
	IP          string `json:"ip,omitempty"`
}

// HasOneField reports whether the query names exactly one of process, host, ip.
func (q ExplainQuery) HasOneField() bool {
	set := 0
	for _, v := range []string{q.ProcessPath, q.Host, q.IP} {
		if v != "" {
			set++
		}
	}
	return set == 1
}

// ExplainNote says what `explain` does not model: sniffing, fake-ip, block lists (F18's
// `reject` is a logical rule with exceptions, not a plain rule-set route) and the rules that
// carry no rule-set (sniff/hijack-dns actions, the literal process_path/domain exclusions,
// ip_is_private) — it matches the literal input against each rule-set's own selectors.
const ExplainNote = "matches the literal input only: sniffing, fake-ip, block lists and rules without a rule-set are not modelled"

// ExplainMatch is one route rule that matched the query, in route order — the first is
// the winner, the same rule sing-box would apply first.
type ExplainMatch struct {
	Exit string
	Tags []string
}

// MarshalJSON never emits a null tags array.
func (m ExplainMatch) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{"exit": m.Exit, "tags": nonNilSlice(m.Tags)})
}

// ExplainResult is Explain's ordered outcome.
type ExplainResult struct {
	// Every matching rule, in route order; Matches[0] is the winner. Empty when nothing
	// matched — the query would take Fallback.
	Matches []ExplainMatch
	// route.final: where the query ends up when no rule in Matches applies.
	Fallback string
	Note     string
}

// MarshalJSON never emits a null matches array.
func (r ExplainResult) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"matches": nonNilSlice(r.Matches), "fallback": r.Fallback, "note": r.Note,
	})
}

// Explain answers "which rule would take this process/host/IP": every RouteRules entry,
// in order, whose selectors (by RuleSetSelectorsByTag) match the query, plus the fallback
// outbound (SingBoxPlan.RouteFinal) for when none do. Pure: no I/O, no locking, so it is
// tested without a running service (#2's decisions).
func Explain(query ExplainQuery, rules []ExplainRule, selectorsByTag map[string]RuleSetSelectors, fallback string) ExplainResult {
	matches := []ExplainMatch{}
	for _, rule := range rules {
		matched := false
		for _, tag := range rule.Tags {
			if selectorsByTag[tag].Matches(query.Host, query.IP, query.ProcessPath) {
				matched = true
				break
			}
		}
		if matched {
			matches = append(matches, ExplainMatch{Exit: ExitLabel([]string{rule.Outbound}), Tags: rule.Tags})
		}
	}
	return ExplainResult{Matches: matches, Fallback: fallback, Note: ExplainNote}
}
