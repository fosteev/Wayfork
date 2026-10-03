package core

import "reflect"

// ExplainQuery selects exactly one field to explain by: a process path, a host, or an IP
// (#2's `wayforkctl explain`; also the pipe's `explain` params — the server rejects a
// query with zero or more than one field set).
type ExplainQuery struct {
	ProcessPath string `json:"process,omitempty"`
	Host        string `json:"host,omitempty"`
	IP          string `json:"ip,omitempty"`
	// Network narrows the question to one transport, "tcp" or "udp" (F23): a route rule with
	// a `network` that does not list it is skipped. Empty asks without a transport, so a
	// narrowed rule counts as if it matched.
	Network string `json:"network,omitempty"`
}

// ValidNetwork reports whether the query's network is empty, "tcp" or "udp".
func (q ExplainQuery) ValidNetwork() bool {
	return q.Network == "" || q.Network == "tcp" || q.Network == "udp"
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
		if !rule.coversNetwork(query.Network) {
			continue
		}
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

// coversNetwork reports whether the rule applies to a query with this network: an unnarrowed
// rule always does, a narrowed one only when it lists it; an empty query network asks
// without a transport and skips nothing.
func (r ExplainRule) coversNetwork(network string) bool {
	if network == "" || len(r.Network) == 0 {
		return true
	}
	for _, covered := range r.Network {
		if covered == network {
			return true
		}
	}
	return false
}

// ExplainBoth is the reply of `explain` without --network when the TCP and the UDP answers
// differ (F23).
type ExplainBoth struct {
	TCP ExplainResult `json:"tcp"`
	UDP ExplainResult `json:"udp"`
}

// CombineExplain returns the single answer when TCP and UDP agree (today's shape) and an
// ExplainBoth otherwise.
func CombineExplain(tcp, udp ExplainResult) any {
	if reflect.DeepEqual(tcp, udp) {
		return tcp
	}
	return ExplainBoth{TCP: tcp, UDP: udp}
}
