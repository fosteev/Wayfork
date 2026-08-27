package core

import "strings"

// OutboundTagPrefix precedes a tunnel id in its sing-box outbound tag.
const OutboundTagPrefix = "t-"

// OutboundTag is the sing-box outbound (and DNS server) tag of a tunnel: `t-<id>`.
func OutboundTag(id string) string { return OutboundTagPrefix + id }

// TunnelIDFromOutboundTag inverts OutboundTag; false for `direct`, `block`, `dns-out`, ….
func TunnelIDFromOutboundTag(tag string) (string, bool) {
	id, ok := strings.CutPrefix(tag, OutboundTagPrefix)
	if !ok || id == "" {
		return "", false
	}
	return id, true
}

// RuleSetTag is the sing-box rule-set tag of a tunnel: `rules-t-<id>`.
func RuleSetTag(id string) string { return "rules-" + OutboundTag(id) }
