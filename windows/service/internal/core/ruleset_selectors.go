package core

import (
	"encoding/json"
	"net/netip"
	"regexp"
	"sort"
	"strings"
)

// StringSet is an unordered set of strings.
type StringSet map[string]struct{}

// NewStringSet builds a set from its members.
func NewStringSet(members ...string) StringSet {
	set := StringSet{}
	for _, member := range members {
		set[member] = struct{}{}
	}
	return set
}

// Has reports membership.
func (s StringSet) Has(member string) bool {
	_, ok := s[member]
	return ok
}

// Sorted lists the members in order.
func (s StringSet) Sorted() []string {
	members := make([]string, 0, len(s))
	for member := range s {
		members = append(members, member)
	}
	sort.Strings(members)
	return members
}

// Equal reports whether both sets have the same members.
func (s StringSet) Equal(other StringSet) bool {
	if len(s) != len(other) {
		return false
	}
	for member := range s {
		if !other.Has(member) {
			return false
		}
	}
	return true
}

func (s StringSet) symmetricDifference(other StringSet) StringSet {
	result := StringSet{}
	for member := range s {
		if !other.Has(member) {
			result[member] = struct{}{}
		}
	}
	for member := range other {
		if !s.Has(member) {
			result[member] = struct{}{}
		}
	}
	return result
}

func (s StringSet) union(other StringSet) StringSet {
	result := StringSet{}
	for member := range s {
		result[member] = struct{}{}
	}
	for member := range other {
		result[member] = struct{}{}
	}
	return result
}

// RuleSetSelectors are the matchers of a rule-set file in sing-box's source format,
// flattened, and the connections they cover (docs/design/05-daemon.md, "Connection cut
// on rule change").
type RuleSetSelectors struct {
	Domain           StringSet
	DomainSuffix     StringSet
	DomainRegex      StringSet
	ProcessPathRegex StringSet
	IPCIDR           StringSet
}

// NewRuleSetSelectors makes an empty selector set.
func NewRuleSetSelectors() RuleSetSelectors {
	return RuleSetSelectors{
		Domain: StringSet{}, DomainSuffix: StringSet{}, DomainRegex: StringSet{},
		ProcessPathRegex: StringSet{}, IPCIDR: StringSet{},
	}
}

// IsEmpty reports whether no matcher is present.
func (s RuleSetSelectors) IsEmpty() bool {
	return len(s.Domain) == 0 && len(s.DomainSuffix) == 0 && len(s.DomainRegex) == 0 &&
		len(s.ProcessPathRegex) == 0 && len(s.IPCIDR) == 0
}

// Equal compares every matcher set.
func (s RuleSetSelectors) Equal(other RuleSetSelectors) bool {
	return s.Domain.Equal(other.Domain) && s.DomainSuffix.Equal(other.DomainSuffix) &&
		s.DomainRegex.Equal(other.DomainRegex) && s.ProcessPathRegex.Equal(other.ProcessPathRegex) &&
		s.IPCIDR.Equal(other.IPCIDR)
}

// ParseRuleSetSelectors reads the matchers of one file; false when it is not
// `{"rules": [{<matcher>: [..]}]}` with the matchers the generator emits (then nobody can
// tell what the file covers).
func ParseRuleSetSelectors(text string) (RuleSetSelectors, bool) {
	var file struct {
		Rules *[]map[string]json.RawMessage `json:"rules"`
	}
	if err := json.Unmarshal([]byte(text), &file); err != nil || file.Rules == nil {
		return RuleSetSelectors{}, false
	}
	selectors := NewRuleSetSelectors()
	for _, rule := range *file.Rules {
		for key, raw := range rule {
			items, ok := stringOrStrings(raw)
			if !ok {
				return RuleSetSelectors{}, false
			}
			switch key {
			case "domain":
				addLowercased(selectors.Domain, items)
			case "domain_suffix":
				addLowercased(selectors.DomainSuffix, items)
			case "domain_regex":
				addAll(selectors.DomainRegex, items)
			case "process_path_regex":
				addAll(selectors.ProcessPathRegex, items)
			case "ip_cidr":
				addAll(selectors.IPCIDR, items)
			default:
				return RuleSetSelectors{}, false
			}
		}
	}
	return selectors, true
}

func stringOrStrings(raw json.RawMessage) ([]string, bool) {
	var single string
	if err := json.Unmarshal(raw, &single); err == nil {
		return []string{single}, true
	}
	var list []string
	if err := json.Unmarshal(raw, &list); err == nil && list != nil {
		return list, true
	}
	return nil, false
}

func addAll(set StringSet, items []string) {
	for _, item := range items {
		set[item] = struct{}{}
	}
}

func addLowercased(set StringSet, items []string) {
	for _, item := range items {
		set[strings.ToLower(item)] = struct{}{}
	}
}

// SymmetricDifference returns the matchers present in exactly one of the two.
func (s RuleSetSelectors) SymmetricDifference(other RuleSetSelectors) RuleSetSelectors {
	return RuleSetSelectors{
		Domain:           s.Domain.symmetricDifference(other.Domain),
		DomainSuffix:     s.DomainSuffix.symmetricDifference(other.DomainSuffix),
		DomainRegex:      s.DomainRegex.symmetricDifference(other.DomainRegex),
		ProcessPathRegex: s.ProcessPathRegex.symmetricDifference(other.ProcessPathRegex),
		IPCIDR:           s.IPCIDR.symmetricDifference(other.IPCIDR),
	}
}

// Union returns the matchers present in either.
func (s RuleSetSelectors) Union(other RuleSetSelectors) RuleSetSelectors {
	return RuleSetSelectors{
		Domain:           s.Domain.union(other.Domain),
		DomainSuffix:     s.DomainSuffix.union(other.DomainSuffix),
		DomainRegex:      s.DomainRegex.union(other.DomainRegex),
		ProcessPathRegex: s.ProcessPathRegex.union(other.ProcessPathRegex),
		IPCIDR:           s.IPCIDR.union(other.IPCIDR),
	}
}

// RuleSetChange is what changed in `files` between two versions of the rule-set files
// (name → contents). False when a file cannot be parsed: the caller then treats every
// connection as affected. A file absent on one side counts as empty.
func RuleSetChange(previous, current map[string]string, files []string) (RuleSetSelectors, bool) {
	change := NewRuleSetSelectors()
	for _, file := range files {
		before, ok := selectorsOf(previous, file)
		if !ok {
			return RuleSetSelectors{}, false
		}
		after, ok := selectorsOf(current, file)
		if !ok {
			return RuleSetSelectors{}, false
		}
		change = change.Union(before.SymmetricDifference(after))
	}
	return change, true
}

func selectorsOf(files map[string]string, name string) (RuleSetSelectors, bool) {
	text, ok := files[name]
	if !ok {
		return NewRuleSetSelectors(), true
	}
	return ParseRuleSetSelectors(text)
}

// Matches reports whether a connection with these Clash API metadata fields is covered by
// a matcher. A superset of sing-box's matching on purpose (`domain_suffix` also matches
// the bare name); empty fields never match; an invalid regex or address never matches.
func (s RuleSetSelectors) Matches(host, destinationIP, processPath string) bool {
	host = strings.ToLower(host)
	if host != "" {
		if s.Domain.Has(host) {
			return true
		}
		for suffix := range s.DomainSuffix {
			if host == suffix || strings.HasSuffix(host, suffix) || strings.HasSuffix(host, "."+suffix) {
				return true
			}
		}
		for pattern := range s.DomainRegex {
			if regexMatches(pattern, host) {
				return true
			}
		}
	}
	if processPath != "" {
		for pattern := range s.ProcessPathRegex {
			if regexMatches(pattern, processPath) {
				return true
			}
		}
	}
	if address, err := netip.ParseAddr(destinationIP); err == nil && address.Is4() {
		for cidr := range s.IPCIDR {
			if prefix, err := netip.ParsePrefix(cidr); err == nil && prefix.Addr().Is4() && prefix.Contains(address) {
				return true
			}
			if single, err := netip.ParseAddr(cidr); err == nil && single == address {
				return true
			}
		}
	}
	return false
}

func regexMatches(pattern, text string) bool {
	compiled, err := regexp.Compile(pattern)
	if err != nil {
		return false
	}
	return compiled.MatchString(text)
}
