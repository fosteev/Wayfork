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

// GroupOutboundTagPrefix precedes a group id in its sing-box outbound tag (F16).
const GroupOutboundTagPrefix = "g-"

// GroupOutboundTag is the sing-box outbound tag of a group: `g-<id>`.
func GroupOutboundTag(id string) string { return GroupOutboundTagPrefix + id }

// GroupIDFromOutboundTag inverts GroupOutboundTag; false for anything else.
func GroupIDFromOutboundTag(tag string) (string, bool) {
	id, ok := strings.CutPrefix(tag, GroupOutboundTagPrefix)
	if !ok || id == "" {
		return "", false
	}
	return id, true
}

// ExitIDFromOutboundTag returns the tunnel or group id behind an outbound tag.
func ExitIDFromOutboundTag(tag string) (string, bool) {
	if id, ok := TunnelIDFromOutboundTag(tag); ok {
		return id, true
	}
	return GroupIDFromOutboundTag(tag)
}

// LocalProxyInboundTagPrefix precedes the exit's outbound tag in a `mixed` inbound's tag (F17).
const LocalProxyInboundTagPrefix = "proxy-"

// LocalProxyInboundTag is the inbound tag of an exit's local proxy port: `proxy-t-<id>`.
func LocalProxyInboundTag(outboundTag string) string { return LocalProxyInboundTagPrefix + outboundTag }

// OutboundTagFromLocalProxyInboundTag inverts LocalProxyInboundTag.
func OutboundTagFromLocalProxyInboundTag(tag string) (string, bool) {
	outbound, ok := strings.CutPrefix(tag, LocalProxyInboundTagPrefix)
	if !ok || outbound == "" {
		return "", false
	}
	return outbound, true
}

// LocalProxyListenAddress is the only address a local proxy inbound may bind.
const LocalProxyListenAddress = "127.0.0.1"

// BlockListRuleSetTag is the bundled block list's rule-set tag (F18).
const BlockListRuleSetTag = "block-ads"

// Probe constants shared with the app's generator (F14, F16).
const (
	ProbeURL              = "https://cp.cloudflare.com/generate_204"
	ProbeIntervalSeconds  = 10
	ProbeTimeoutSeconds   = 5
	ProbeHistoryLength    = 12
	ProbeFailureThreshold = 3
)
