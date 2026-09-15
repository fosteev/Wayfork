package core

import "strings"

var singBoxLevelTokens = []struct {
	token string
	level LogLevel
}{
	{"FATAL", LogLevelError}, {"PANIC", LogLevelError}, {"ERROR", LogLevelError},
	{"WARN", LogLevelWarning}, {"INFO", LogLevelInfo}, {"DEBUG", LogLevelDebug},
	{"TRACE", LogLevelDebug},
}

// SingBoxLogLevel detects the level of a sing-box stdout/stderr line
// (docs/design/06-logging.md, "Sources and levels"):
// `+0300 2026-08-25 12:00:00 INFO inbound/tun[tun-in]: started` → info. Unknown formats
// (Go panics, plain text) count as info.
func SingBoxLogLevel(line string) LogLevel {
	// The level token sits near the start; scanning a bounded prefix avoids matching
	// words inside the message itself.
	prefix := line
	if len(prefix) > 48 {
		prefix = prefix[:48]
	}
	for _, token := range strings.Fields(prefix) {
		if bracket := strings.IndexByte(token, '['); bracket >= 0 {
			token = token[:bracket]
		}
		for _, candidate := range singBoxLevelTokens {
			if candidate.token == token {
				return candidate.level
			}
		}
	}
	return LogLevelInfo
}

// IsSingBoxStartedLine: sing-box logs `sing-box started (0.02s)` once every inbound is up.
func IsSingBoxStartedLine(line string) bool {
	return strings.Contains(line, "sing-box started")
}

// SingBoxLogMessage removes the timestamp prefix that the service's own LogLine.TS
// already carries. Format with `timestamp: true`: `<zone> <date> <time> <LEVEL> <message>`.
func SingBoxLogMessage(line string) string {
	parts := strings.SplitN(line, " ", 5)
	if len(parts) != 5 || parts[0] == "" || (parts[0][0] != '+' && parts[0][0] != '-') ||
		len(parts[1]) != 10 || len(parts[2]) != 8 {
		return line
	}
	return parts[4]
}

// InboundBindFailure returns the inbound whose port another program holds, from sing-box's
// start failure (`… initialize inbound/mixed[proxy-t-<id>]: listen tcp 127.0.0.1:1081: bind:
// … address already in use` — Windows says "Only one usage of each socket address"); "" for
// any other line (F17).
func InboundBindFailure(line string) string {
	if !strings.Contains(line, "address already in use") && !strings.Contains(line, "Only one usage of each socket address") {
		return ""
	}
	open := strings.Index(line, "inbound/")
	if open < 0 {
		return ""
	}
	rest := line[open:]
	bracket := strings.Index(rest, "[")
	if bracket < 0 {
		return ""
	}
	close := strings.Index(rest[bracket:], "]")
	if close < 0 {
		return ""
	}
	return rest[bracket+1 : bracket+close]
}
