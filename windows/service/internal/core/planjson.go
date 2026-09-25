package core

import (
	"encoding/json"
	"sort"
	"strings"
)

// RoutedTunnelIDs lists the tunnels the config routes: every routed tunnel has a
// rules-t-<id>.json, so no separate list is needed to know whom to probe (F14).
func (p RuntimePlan) RoutedTunnelIDs() []string { return p.routedIDs("rules-t-") }

// RoutedGroupIDs lists the groups the config routes, from their rules-g-<id>.json (F16).
func (p RuntimePlan) RoutedGroupIDs() []string { return p.routedIDs("rules-g-") }

func (p RuntimePlan) routedIDs(prefix string) []string {
	ids := []string{}
	for name := range p.SingBox.RuleSets {
		if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, ".json") || strings.HasSuffix(name, "-ip.json") {
			continue
		}
		ids = append(ids, strings.TrimSuffix(strings.TrimPrefix(name, prefix), ".json"))
	}
	sort.Strings(ids)
	return ids
}

func (p SingBoxPlan) root() map[string]any {
	var root map[string]any
	if err := json.Unmarshal([]byte(p.Config), &root); err != nil {
		return nil
	}
	return root
}

// RouteFinal is `route.final` of the config — `direct` or the default exit's tag (F8, F16),
// where a flow no rule matched ends up. "" when the config is not the generator's shape.
func (p SingBoxPlan) RouteFinal() string {
	route, _ := p.root()["route"].(map[string]any)
	final, _ := route["final"].(string)
	return final
}

// GroupOutbound is one group outbound as the service sees it in the config (F16).
type GroupOutbound struct {
	// "selector" (first live: the service points it) or "urltest" (fastest: sing-box's).
	Policy string
	// Member tunnel ids in the group's order (usable members only).
	Members []string
}

// GroupOutbounds returns the group outbounds of the config by group id (F16).
func (p SingBoxPlan) GroupOutbounds() map[string]GroupOutbound {
	result := map[string]GroupOutbound{}
	outbounds, _ := p.root()["outbounds"].([]any)
	for _, entry := range outbounds {
		outbound, _ := entry.(map[string]any)
		tag, _ := outbound["tag"].(string)
		id, ok := GroupIDFromOutboundTag(tag)
		policy, _ := outbound["type"].(string)
		if !ok || (policy != "selector" && policy != "urltest") {
			continue
		}
		members := []string{}
		list, _ := outbound["outbounds"].([]any)
		for _, member := range list {
			if memberTag, ok := member.(string); ok {
				if memberID, ok := TunnelIDFromOutboundTag(memberTag); ok {
					members = append(members, memberID)
				}
			}
		}
		result[id] = GroupOutbound{Policy: policy, Members: members}
	}
	return result
}

// LocalProxyInbound is one `mixed` inbound as the service sees it in the config (F17).
type LocalProxyInbound struct {
	Tag    string
	Listen string
	Port   int
}

// OutboundTag is `t-<id>` / `g-<id>` the inbound feeds, per its tag.
func (i LocalProxyInbound) OutboundTag() (string, bool) {
	return OutboundTagFromLocalProxyInboundTag(i.Tag)
}

// ExitID is the tunnel or group id behind the tag.
func (i LocalProxyInbound) ExitID() (string, bool) {
	outbound, ok := i.OutboundTag()
	if !ok {
		return "", false
	}
	return ExitIDFromOutboundTag(outbound)
}

// LocalProxyInbounds lists the `mixed` inbounds of the config in config order (F17).
func (p SingBoxPlan) LocalProxyInbounds() []LocalProxyInbound {
	result := []LocalProxyInbound{}
	inbounds, _ := p.root()["inbounds"].([]any)
	for _, entry := range inbounds {
		inbound, _ := entry.(map[string]any)
		if kind, _ := inbound["type"].(string); kind != "mixed" {
			continue
		}
		tag, _ := inbound["tag"].(string)
		listen, _ := inbound["listen"].(string)
		port, _ := inbound["listen_port"].(float64)
		result = append(result, LocalProxyInbound{Tag: tag, Listen: listen, Port: int(port)})
	}
	return result
}

// BinaryRuleSetPaths lists the paths of the `binary` local rule-sets the config references —
// the bundled block list (F18) and nothing else in the generator's shape.
func (p SingBoxPlan) BinaryRuleSetPaths() []string {
	result := []string{}
	route, _ := p.root()["route"].(map[string]any)
	ruleSets, _ := route["rule_set"].([]any)
	for _, entry := range ruleSets {
		ruleSet, _ := entry.(map[string]any)
		kind, _ := ruleSet["type"].(string)
		format, _ := ruleSet["format"].(string)
		path, _ := ruleSet["path"].(string)
		if kind == "local" && format == "binary" && path != "" {
			result = append(result, path)
		}
	}
	return result
}

// HasBlockList reports whether the config carries the block list's rule-set (F18).
func (p SingBoxPlan) HasBlockList() bool { return len(p.BinaryRuleSetPaths()) > 0 }

// ExplainRule is one `route.rules` entry that names a rule-set, in config order (#2's
// `explain`). Entries without both `outbound` and `rule_set` — `sniff`/`hijack-dns`
// actions, the literal `process_path`/`domain` exclusions, `ip_is_private` — are not
// modelled; `explain` says so in its `note`.
type ExplainRule struct {
	Outbound string
	Tags     []string
}

// RouteRules lists the config's `route.rules` entries that route by rule-set, in config
// order (#2's `explain`). "" when the config is not the generator's shape.
func (p SingBoxPlan) RouteRules() []ExplainRule {
	route, _ := p.root()["route"].(map[string]any)
	rules, _ := route["rules"].([]any)
	result := []ExplainRule{}
	for _, entry := range rules {
		rule, _ := entry.(map[string]any)
		outbound, _ := rule["outbound"].(string)
		tagsRaw, _ := rule["rule_set"].([]any)
		if outbound == "" || len(tagsRaw) == 0 {
			continue
		}
		tags := make([]string, 0, len(tagsRaw))
		for _, item := range tagsRaw {
			if tag, ok := item.(string); ok {
				tags = append(tags, tag)
			}
		}
		if len(tags) == 0 {
			continue
		}
		result = append(result, ExplainRule{Outbound: outbound, Tags: tags})
	}
	return result
}

// RuleSetSelectorsByTag parses every local rule-set file the config's `route.rule_set`
// names, by tag (#2's `explain`). A tag whose file is missing from RuleSets, or does not
// parse as the generator's shape, is left out — it then matches nothing.
func (p SingBoxPlan) RuleSetSelectorsByTag() map[string]RuleSetSelectors {
	route, _ := p.root()["route"].(map[string]any)
	entries, _ := route["rule_set"].([]any)
	result := map[string]RuleSetSelectors{}
	for _, entry := range entries {
		ruleSet, _ := entry.(map[string]any)
		tag, _ := ruleSet["tag"].(string)
		path, _ := ruleSet["path"].(string)
		if tag == "" || path == "" {
			continue
		}
		text, ok := p.RuleSets[path]
		if !ok {
			continue
		}
		selectors, ok := ParseRuleSetSelectors(text)
		if !ok {
			continue
		}
		result[tag] = selectors
	}
	return result
}

// StripLocalProxyInbound removes one local proxy inbound and its route rule from a config
// whose port another program holds, so the engine can start without it (F17). Returns
// ok=false when the config has no inbound with that tag.
func StripLocalProxyInbound(config, tag string) (string, bool) {
	var root map[string]any
	if err := json.Unmarshal([]byte(config), &root); err != nil {
		return "", false
	}
	inbounds, _ := root["inbounds"].([]any)
	kept := make([]any, 0, len(inbounds))
	found := false
	for _, entry := range inbounds {
		inbound, _ := entry.(map[string]any)
		if inbound["tag"] == tag {
			found = true
			continue
		}
		kept = append(kept, entry)
	}
	if !found {
		return "", false
	}
	root["inbounds"] = kept
	if route, ok := root["route"].(map[string]any); ok {
		rules, _ := route["rules"].([]any)
		keptRules := make([]any, 0, len(rules))
		for _, entry := range rules {
			rule, _ := entry.(map[string]any)
			list, _ := rule["inbound"].([]any)
			if len(list) == 1 && list[0] == tag {
				continue
			}
			keptRules = append(keptRules, entry)
		}
		route["rules"] = keptRules
	}
	data, err := MarshalWire(root)
	if err != nil {
		return "", false
	}
	return string(data) + "\n", true
}
