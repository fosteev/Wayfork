package core

import (
	"sort"
	"strings"
	"time"
)

// FailedConnections aggregates connections that could not be established by site + app
// from sing-box's own log lines (F19, docs/design/05-daemon.md, "Failed connections").
// sing-box tells one connection's story under one id (`[3921 5004ms]`); the tracker joins
// those by id and keeps one row per (host, processPath).
type FailedConnections struct {
	pending      map[string]*failedPending
	pendingOrder []string
	rows         map[string]FailedHost

	// F20: per-exit connection counters since the last Clear(), fed by the same lines.
	openedCounts      map[string]int
	failedCounts      map[string]int
	blockedCount      int
	lastFailureByExit map[string]lastFailureAt
	// sawMatchLine is whether a match/`using` line has been seen since the last Clear() —
	// while false, Exits() reports a nil Opened for every exit (log detail Problems).
	sawMatchLine bool
}

// lastFailureAt is the last failure recorded for one exit (F20).
type lastFailureAt struct {
	reason FailureReason
	at     time.Time
}

// FailedIDCapacity is how many connection ids the join remembers.
const FailedIDCapacity = 2000

type failedPending struct {
	host, processPath, exit string
	hasExit                 bool
}

// NewFailedConnections returns an empty tracker.
func NewFailedConnections() *FailedConnections {
	return &FailedConnections{
		pending: map[string]*failedPending{}, rows: map[string]FailedHost{},
		openedCounts: map[string]int{}, failedCounts: map[string]int{},
		lastFailureByExit: map[string]lastFailureAt{},
	}
}

// IsInterestingLogLine is the cheap pre-filter for the engine's relay.
func IsInterestingLogLine(message string) bool {
	if !strings.HasPrefix(message, "[") {
		return false
	}
	return strings.Contains(message, "connection to ") || strings.Contains(message, "found process path") ||
		strings.Contains(message, " => ") || strings.Contains(message, "sniffed") ||
		strings.Contains(message, "dns: exchange ") || strings.Contains(message, "using ")
}

// Ingest feeds one line (the message after the timestamp, with or without the level).
func (f *FailedConnections) Ingest(line string, level LogLevel, now time.Time) {
	id, rest, ok := splitConnectionLine(line)
	if !ok {
		return
	}
	if host, ok := valueAfter(rest, "inbound connection to "); ok {
		f.remember(id).host = stripPort(host)
	} else if host, ok := valueAfter(rest, "inbound packet connection to "); ok {
		f.remember(id).host = stripPort(host)
	} else if domain, ok := valueAfter(rest, "domain: "); ok && strings.Contains(rest, "sniffed") {
		f.remember(id).host = domain
	} else if path, ok := valueAfter(rest, "found process path: "); ok {
		f.remember(id).processPath = path
	} else if name, ok := valueAfter(rest, "dns: exchange "); ok {
		f.remember(id).host = strings.Fields(name)[0]
	} else if target, ok := valueAfterEither(rest, " => ", "using "); ok {
		blockList := strings.Contains(rest, "rule_set="+BlockListRuleSetTag)
		switch {
		case (target == "reject" || target == "predefined") && blockList:
			f.sawMatchLine = true
			f.record(id, FailureReason{Kind: FailureBlocked}, "", true, now)
		case strings.Contains(rest, "router:"):
			f.sawMatchLine = true
			pending := f.remember(id)
			exit := exitIDForTarget(target)
			// Opened counts once per connection id, at the first match/`using` line.
			if !pending.hasExit {
				f.openedCounts[exit]++
			}
			pending.exit, pending.hasExit = exit, true
		}
	} else if level == LogLevelError {
		failure, ok := valueAfter(rest, "open connection to ")
		if !ok {
			failure, ok = valueAfter(rest, "open packet connection to ")
		}
		if !ok {
			return
		}
		hostPort, errText := failure, ""
		if cut := strings.Index(failure, ": "); cut >= 0 {
			hostPort, errText = failure[:cut], failure[cut+2:]
		}
		pending := f.remember(id)
		if pending.host == "" {
			pending.host = stripPort(hostPort)
		}
		f.record(id, classifyFailure(errText, pending), "", false, now)
	}
}

// Snapshot returns the rows newest first.
func (f *FailedConnections) Snapshot() []FailedHost {
	out := make([]FailedHost, 0, len(f.rows))
	for _, row := range f.rows {
		out = append(out, row)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i].LastSeen.Time, out[j].LastSeen.Time
		if !a.Equal(b) {
			return a.After(b)
		}
		return out[i].ID() < out[j].ID()
	})
	return out
}

// Exits returns per-exit counters since the last Clear() (F20), keyed by exit id
// (`direct`, a tunnel id, a group id).
func (f *FailedConnections) Exits() map[string]ExitStats {
	ids := map[string]struct{}{}
	for id := range f.openedCounts {
		ids[id] = struct{}{}
	}
	for id := range f.failedCounts {
		ids[id] = struct{}{}
	}
	for id := range f.lastFailureByExit {
		ids[id] = struct{}{}
	}
	if f.blockedCount > 0 {
		ids["direct"] = struct{}{}
	}
	result := make(map[string]ExitStats, len(ids))
	for id := range ids {
		stats := ExitStats{Failed: f.failedCounts[id]}
		if f.sawMatchLine {
			opened := f.openedCounts[id]
			stats.Opened = &opened
		}
		if id == "direct" {
			stats.Blocked = f.blockedCount
		}
		if last, ok := f.lastFailureByExit[id]; ok {
			reason := last.reason
			stats.LastFailure = &reason
			at := NewTimestamp(last.at)
			stats.LastFailedAt = &at
		}
		result[id] = stats
	}
	return result
}

// Clear forgets everything (Turn Off).
func (f *FailedConnections) Clear() {
	f.pending = map[string]*failedPending{}
	f.pendingOrder = nil
	f.rows = map[string]FailedHost{}
	f.openedCounts = map[string]int{}
	f.failedCounts = map[string]int{}
	f.blockedCount = 0
	f.lastFailureByExit = map[string]lastFailureAt{}
	f.sawMatchLine = false
}

func (f *FailedConnections) remember(id string) *failedPending {
	if pending, ok := f.pending[id]; ok {
		return pending
	}
	pending := &failedPending{}
	f.pending[id] = pending
	f.pendingOrder = append(f.pendingOrder, id)
	if len(f.pendingOrder) > FailedIDCapacity {
		oldest := f.pendingOrder[0]
		f.pendingOrder = f.pendingOrder[1:]
		delete(f.pending, oldest)
	}
	return pending
}

func (f *FailedConnections) record(id string, reason FailureReason, exitOverride string, overrideExit bool, now time.Time) {
	pending, ok := f.pending[id]
	if !ok || pending.host == "" {
		return
	}
	exit := "direct"
	if overrideExit {
		exit = exitOverride
	} else if pending.hasExit {
		exit = pending.exit
	}
	if reason.Kind == FailureBlocked {
		f.blockedCount++
	} else {
		f.failedCounts[exit]++
		f.lastFailureByExit[exit] = lastFailureAt{reason: reason, at: now}
	}
	key := pending.host + "|" + pending.processPath
	if row, ok := f.rows[key]; ok {
		row.Count++
		row.LastSeen = NewTimestamp(now)
		row.Reason = reason
		row.Exit = exit
		f.rows[key] = row
	} else {
		f.rows[key] = FailedHost{Host: pending.host, ProcessPath: pending.processPath, Exit: exit, Reason: reason, Count: 1, LastSeen: NewTimestamp(now)}
		if len(f.rows) > FailedHostCapacity {
			ordered := f.Snapshot()
			delete(f.rows, ordered[len(ordered)-1].ID())
		}
	}
	// One failure per connection: the id is done.
	delete(f.pending, id)
}

// splitConnectionLine reads `[3921 5004ms] inbound/tun[tun-in]: …` → ("3921", rest); the
// level token in front (`ERROR [3921 …`) is skipped.
func splitConnectionLine(line string) (string, string, bool) {
	open := strings.Index(line, "[")
	if open < 0 || open > 8 {
		return "", "", false
	}
	close := strings.Index(line[open:], "]")
	if close < 0 {
		return "", "", false
	}
	inside := line[open+1 : open+close]
	fields := strings.Fields(inside)
	if len(fields) == 0 || strings.Trim(fields[0], "0123456789") != "" {
		return "", "", false
	}
	return fields[0], strings.TrimSpace(line[open+close+1:]), true
}

func valueAfter(text, marker string) (string, bool) {
	index := strings.Index(text, marker)
	if index < 0 {
		return "", false
	}
	value := strings.TrimSpace(text[index+len(marker):])
	return value, value != ""
}

func valueAfterEither(text, first, second string) (string, bool) {
	if value, ok := valueAfter(text, first); ok {
		return value, true
	}
	return valueAfter(text, second)
}

// stripPort turns `host:443` into `host`; an IPv6 literal keeps its brackets' contents.
func stripPort(hostPort string) string {
	if strings.HasPrefix(hostPort, "[") {
		if close := strings.Index(hostPort, "]"); close > 0 {
			return hostPort[1:close]
		}
	}
	colon := strings.LastIndex(hostPort, ":")
	if colon < 0 {
		return hostPort
	}
	head := hostPort[:colon]
	if strings.Contains(head, ":") && !strings.Contains(head, ".") {
		return hostPort // bare IPv6
	}
	return head
}

func exitIDForTarget(target string) string {
	if id, ok := ExitIDFromOutboundTag(target); ok {
		return id
	}
	return target
}

func classifyFailure(errText string, pending *failedPending) FailureReason {
	text := strings.ToLower(errText)
	switch {
	case strings.Contains(text, "timeout"):
		return FailureReason{Kind: FailureNoAnswer}
	case strings.Contains(text, "connection refused"):
		return FailureReason{Kind: FailureRefused}
	case strings.Contains(text, "connection reset"):
		return FailureReason{Kind: FailureReset}
	case strings.Contains(text, "no such host") || strings.Contains(text, "nxdomain") || strings.Contains(text, "lookup"):
		return FailureReason{Kind: FailureNoSuchName}
	case strings.Contains(text, "network is unreachable") || strings.Contains(text, "no route to host"):
		if pending.hasExit && pending.exit != "direct" {
			return FailureReason{Kind: FailureTunnelDown}
		}
		return FailureReason{Kind: FailureOther, Other: errText}
	}
	return FailureReason{Kind: FailureOther, Other: errText}
}
