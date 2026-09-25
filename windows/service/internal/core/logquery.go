package core

import (
	"sort"
	"strconv"
	"strings"
	"time"
)

// LogQuery is `wayforkctl logs`' filter (F21, docs/design/09-wayforkctl.md § Commands
// (Windows)): source, level threshold, case-insensitive substrings, a start time and a
// tail length — the same semantics as the macOS `LogQuery`.
type LogQuery struct {
	// Sources: empty means every source; `openvpn` stands for every `openvpn:<id>`.
	Sources []string
	// Level: lines at this level or more severe; empty means debug (everything).
	Level LogLevel
	// Grep: every entry must occur in the message, case-insensitively.
	Grep []string
	// Since: the zero time means no limit.
	Since time.Time
	// Tail keeps the last Tail matching lines; 0 means no cap.
	Tail int
}

// DefaultLogTail is `wayforkctl logs`' default --tail.
const DefaultLogTail = 100

func logLevelRank(level LogLevel) int {
	switch level {
	case LogLevelError:
		return 0
	case LogLevelWarning:
		return 1
	case LogLevelInfo:
		return 2
	default:
		return 3
	}
}

// Matches reports whether line passes every filter.
func (q LogQuery) Matches(line LogLine) bool {
	if q.Level != "" && logLevelRank(line.Level) > logLevelRank(q.Level) {
		return false
	}
	if !q.Since.IsZero() && line.TS.Before(q.Since) {
		return false
	}
	if len(q.Sources) > 0 {
		found := false
		for _, source := range q.Sources {
			if logSourceMatches(line.Source, source) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	message := strings.ToLower(line.Message)
	for _, needle := range q.Grep {
		if !strings.Contains(message, strings.ToLower(needle)) {
			return false
		}
	}
	return true
}

func logSourceMatches(source, filter string) bool {
	source, filter = strings.ToLower(source), strings.ToLower(filter)
	return source == filter || (filter == "openvpn" && strings.HasPrefix(source, "openvpn:"))
}

// Run filters lines, orders them by timestamp (stable for equal stamps) and keeps the
// tail.
func (q LogQuery) Run(lines []LogLine) []LogLine {
	matching := make([]LogLine, 0, len(lines))
	for _, line := range lines {
		if q.Matches(line) {
			matching = append(matching, line)
		}
	}
	sort.SliceStable(matching, func(i, j int) bool { return matching[i].TS.Before(matching[j].TS.Time) })
	if q.Tail > 0 && len(matching) > q.Tail {
		matching = matching[len(matching)-q.Tail:]
	}
	return matching
}

// ParseLogSince accepts `90s`, `15m`, `2h`, `1d` before now, or an RFC 3339 timestamp.
func ParseLogSince(text string, now time.Time) (time.Time, bool) {
	text = strings.TrimSpace(text)
	if len(text) >= 2 {
		units := map[byte]time.Duration{'s': time.Second, 'm': time.Minute, 'h': time.Hour, 'd': 24 * time.Hour}
		if unit, ok := units[text[len(text)-1]]; ok {
			if amount, err := strconv.ParseFloat(text[:len(text)-1], 64); err == nil && amount >= 0 {
				return now.Add(-time.Duration(amount * float64(unit))), true
			}
		}
	}
	if ts, err := time.Parse(time.RFC3339Nano, text); err == nil {
		return ts, true
	}
	return time.Time{}, false
}

// LogSourceForFile maps a log file stem (`sing-box`, `openvpn-<id>`, `daemon`) to the
// source name of its lines.
func LogSourceForFile(stem string) string {
	if rest, ok := strings.CutPrefix(stem, "openvpn-"); ok {
		return "openvpn:" + rest
	}
	return stem
}

// ParseLogFileLine reads one `FormatLogLine` line; false for anything else.
func ParseLogFileLine(source, text string) (LogLine, bool) {
	parts := strings.SplitN(text, " ", 3)
	if len(parts) < 2 {
		return LogLine{}, false
	}
	ts, err := time.Parse(time.RFC3339Nano, parts[0])
	if err != nil {
		return LogLine{}, false
	}
	level, err := ParseLogLevel(strings.ToLower(parts[1]))
	if err != nil || parts[1] != strings.ToUpper(parts[1]) {
		return LogLine{}, false
	}
	message := ""
	if len(parts) == 3 {
		message = parts[2]
	}
	return LogLine{TS: NewTimestamp(ts), Source: source, Level: level, Message: message}, true
}
