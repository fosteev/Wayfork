package core

import (
	"sort"
	"strings"
	"time"
)

// RecentHosts is the ring of domains that took the default route, fed from every
// /connections sample (F15, docs/design/05-daemon.md, "Recent hosts"). Keyed by host: the
// newest sighting and the last known process win; the oldest goes when the ring is full.
type RecentHosts struct {
	entries map[string]RecentHost
}

// Names that are always direct by the built-in exceptions; never worth a rule.
var recentLocalSuffixes = []string{".local", ".lan", ".internal", ".home.arpa", ".localhost"}

// NewRecentHosts returns an empty ring.
func NewRecentHosts() *RecentHosts { return &RecentHosts{entries: map[string]RecentHost{}} }

// Ingest records the connections whose exit is the default route (defaultExit: the id
// behind route.final, DirectExit for direct) and whose destination is a name.
func (r *RecentHosts) Ingest(connections []ClashConnection, defaultExit TrafficExit, now time.Time) {
	for _, connection := range connections {
		if ExitForChains(connection.Chains) != defaultExit {
			continue
		}
		host := strings.ToLower(connection.Host)
		if !IsListableHost(host) {
			continue
		}
		exit := "direct"
		if defaultExit.Tunnel != "" {
			exit = defaultExit.Tunnel
		}
		processPath := connection.ProcessPath
		if processPath == "" {
			processPath = r.entries[host].ProcessPath
		}
		r.entries[host] = RecentHost{Host: host, ProcessPath: processPath, Exit: exit, LastSeen: NewTimestamp(now)}
	}
	if len(r.entries) > RecentHostCapacity {
		ordered := r.Snapshot()
		for _, entry := range ordered[RecentHostCapacity:] {
			delete(r.entries, entry.Host)
		}
	}
}

// Snapshot returns the entries newest first.
func (r *RecentHosts) Snapshot() []RecentHost {
	out := make([]RecentHost, 0, len(r.entries))
	for _, entry := range r.entries {
		out = append(out, entry)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i].LastSeen.Time, out[j].LastSeen.Time
		if !a.Equal(b) {
			return a.After(b)
		}
		return out[i].Host > out[j].Host
	})
	return out
}

// Clear empties the ring (sing-box restarted or Turn Off).
func (r *RecentHosts) Clear() { r.entries = map[string]RecentHost{} }

// IsListableHost reports a domain — not an address, not a local name.
func IsListableHost(host string) bool {
	if host == "" || !strings.Contains(host, ".") || host == "localhost" || strings.Contains(host, ":") {
		return false
	}
	if strings.Trim(host, "0123456789.") == "" {
		return false // IPv4 literal
	}
	for _, suffix := range recentLocalSuffixes {
		if strings.HasSuffix(host, suffix) {
			return false
		}
	}
	return true
}
