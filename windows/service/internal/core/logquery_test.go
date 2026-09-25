package core

import (
	"reflect"
	"testing"
	"time"
)

var logQueryT0 = time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)

func logQueryLine(offset int, source string, level LogLevel, message string) LogLine {
	return LogLine{
		TS: NewTimestamp(logQueryT0.Add(time.Duration(offset) * time.Second)), Source: source,
		Level: level, Message: message,
	}
}

func logQueryMessages(lines []LogLine) []string {
	messages := []string{}
	for _, line := range lines {
		messages = append(messages, line.Message)
	}
	return messages
}

func TestLogQueryFilters(t *testing.T) {
	lines := []LogLine{
		logQueryLine(0, "sing-box", LogLevelInfo, "inbound connection to example.com:443"),
		logQueryLine(1, "openvpn:abc", LogLevelWarning, "TLS handshake failed"),
		logQueryLine(2, "daemon", LogLevelError, "sing-box exited"),
		logQueryLine(3, "sing-box", LogLevelDebug, "dns: exchanged example.com"),
	}
	cases := []struct {
		name  string
		query LogQuery
		want  []string
	}{
		{"openvpn family", LogQuery{Sources: []string{"openvpn"}}, []string{"TLS handshake failed"}},
		{"level", LogQuery{Level: LogLevelWarning}, []string{"TLS handshake failed", "sing-box exited"}},
		{"grep all", LogQuery{Grep: []string{"EXAMPLE", "dns"}}, []string{"dns: exchanged example.com"}},
		{"since", LogQuery{Since: logQueryT0.Add(2 * time.Second)}, []string{"sing-box exited", "dns: exchanged example.com"}},
		{"tail", LogQuery{Tail: 1}, []string{"dns: exchanged example.com"}},
	}
	for _, c := range cases {
		if got := logQueryMessages(c.query.Run(lines)); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestLogQueryMergesByTime(t *testing.T) {
	lines := []LogLine{
		logQueryLine(2, "sing-box", LogLevelInfo, "c"),
		logQueryLine(0, "sing-box", LogLevelInfo, "a"),
		logQueryLine(2, "daemon", LogLevelInfo, "d"),
		logQueryLine(1, "daemon", LogLevelInfo, "b"),
	}
	if got := logQueryMessages(LogQuery{}.Run(lines)); !reflect.DeepEqual(got, []string{"a", "b", "c", "d"}) {
		t.Errorf("got %v", got)
	}
}

func TestParseLogSince(t *testing.T) {
	cases := map[string]time.Duration{"90s": 90 * time.Second, "15m": 15 * time.Minute, "2h": 2 * time.Hour, "1d": 24 * time.Hour}
	for text, ago := range cases {
		got, ok := ParseLogSince(text, logQueryT0)
		if !ok || !got.Equal(logQueryT0.Add(-ago)) {
			t.Errorf("%s: got %v %v", text, got, ok)
		}
	}
	if _, ok := ParseLogSince("2026-09-25T10:00:00Z", logQueryT0); !ok {
		t.Error("RFC 3339 rejected")
	}
	for _, bad := range []string{"soon", "5w", ""} {
		if _, ok := ParseLogSince(bad, logQueryT0); ok {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestParseLogFileLineRoundTrips(t *testing.T) {
	text := FormatLogLine(logQueryT0, LogLevelWarning, "dial tcp: i/o timeout")
	line, ok := ParseLogFileLine(LogSourceForFile("openvpn-t1"), text)
	want := logQueryLine(0, "openvpn:t1", LogLevelWarning, "dial tcp: i/o timeout")
	if !ok || !reflect.DeepEqual(line, want) {
		t.Errorf("got %+v %v", line, ok)
	}
	for _, bad := range []string{"", "garbage", "2026-09-25T12:00:00Z warn lower-case level", "2026-09-25T12:00:00Z NOPE x"} {
		if _, ok := ParseLogFileLine("x", bad); ok {
			t.Errorf("%q parsed", bad)
		}
	}
}
