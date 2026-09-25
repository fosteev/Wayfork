package core

import (
	"slices"
	"testing"
	"time"
)

func line(source string, at time.Time, message string) LogLine {
	return LogLine{TS: NewTimestamp(at), Source: source, Level: LogLevelInfo, Message: message}
}

func messages(lines []LogLine) []string {
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		out = append(out, line.Message)
	}
	return out
}

func TestLogRingKeepsNewest(t *testing.T) {
	ring := NewLogRing(3)
	if ring.Len() != 0 || len(ring.Lines()) != 0 {
		t.Error("a new ring is not empty")
	}
	for _, message := range []string{"1", "2"} {
		ring.Append(line("s", fixtureDate, message))
	}
	if got := messages(ring.Lines()); !slices.Equal(got, []string{"1", "2"}) {
		t.Errorf("lines = %q", got)
	}
	for _, message := range []string{"3", "4", "5"} {
		ring.Append(line("s", fixtureDate, message))
	}
	if got := messages(ring.Lines()); !slices.Equal(got, []string{"3", "4", "5"}) {
		t.Errorf("lines after wrap = %q", got)
	}
	ring.Append(line("s", fixtureDate, "6"))
	if got := messages(ring.Lines()); !slices.Equal(got, []string{"4", "5", "6"}) || ring.Len() != 3 {
		t.Errorf("lines after second wrap = %q", got)
	}
	if NewLogRing(0).capacity != 1 {
		t.Error("capacity must be at least 1")
	}
}

func TestLogRingsReplayMergesSources(t *testing.T) {
	rings := NewLogRings(2)
	rings.Append(line("sing-box", fixtureDate, "sb-1"))
	rings.Append(line("openvpn:"+idA, fixtureDate, "ovpn-1"))
	rings.Append(line("sing-box", fixtureDate.Add(2*time.Second), "sb-2"))
	rings.Append(line("openvpn:"+idA, fixtureDate.Add(time.Second), "ovpn-2"))
	rings.Append(line("daemon", fixtureDate.Add(-time.Second), "d-1"))
	if got := messages(rings.Replay()); !slices.Equal(got, []string{"d-1", "sb-1", "ovpn-1", "ovpn-2", "sb-2"}) {
		t.Errorf("replay = %q", got)
	}
	// Per-source capacity: sing-box keeps only its newest two.
	rings.Append(line("sing-box", fixtureDate.Add(3*time.Second), "sb-3"))
	if got := messages(rings.Replay()); !slices.Equal(got, []string{"d-1", "ovpn-1", "ovpn-2", "sb-2", "sb-3"}) {
		t.Errorf("replay after wrap = %q", got)
	}
	if got := rings.Sources(); !slices.Equal(got, []string{"daemon", "openvpn:" + idA, "sing-box"}) {
		t.Errorf("sources = %q", got)
	}
	if LogRingCapacity != 2000 {
		t.Error("the design says 2 000 lines per source")
	}
}
