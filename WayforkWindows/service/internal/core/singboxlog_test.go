package core

import "testing"

func TestSingBoxLogParsing(t *testing.T) {
	line := "+0300 2026-08-25 12:00:00 INFO inbound/tun[tun-in]: started"
	if SingBoxLogLevel(line) != LogLevelInfo || SingBoxLogMessage(line) != "inbound/tun[tun-in]: started" {
		t.Errorf("info line: %s / %s", SingBoxLogLevel(line), SingBoxLogMessage(line))
	}
	levels := map[string]LogLevel{
		"+0300 2026-08-25 12:00:00 WARN[123] dns: ERROR in upstream": LogLevelWarning,
		"+0300 2026-08-25 12:00:00 ERROR[123] start service: bind":   LogLevelError,
		"+0300 2026-08-25 12:00:00 FATAL start: x":                   LogLevelError,
		"DEBUG[0001] router: x":                                      LogLevelDebug,
		"-0700 2026-08-25 12:00:00 TRACE x":                          LogLevelDebug,
		"panic: runtime error":                                       LogLevelInfo,
		"":                                                           LogLevelInfo,
	}
	for line, want := range levels {
		if got := SingBoxLogLevel(line); got != want {
			t.Errorf("%q → %s, want %s", line, got, want)
		}
	}
	if !IsSingBoxStartedLine("+0300 2026-08-25 12:00:00 INFO sing-box started (0.02s)") || IsSingBoxStartedLine(line) {
		t.Error("started-line detection is wrong")
	}
	if SingBoxLogMessage("plain text") != "plain text" || SingBoxLogMessage("+0300 2026-08-25 12:00 INFO short time") != "+0300 2026-08-25 12:00 INFO short time" {
		t.Error("unknown formats must pass through")
	}
}
