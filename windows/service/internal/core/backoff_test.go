package core

import (
	"testing"
	"time"
)

func TestBackoffPolicy(t *testing.T) {
	var backoff BackoffPolicy
	if backoff.NextAttempt() != 1 {
		t.Errorf("first attempt = %d", backoff.NextAttempt())
	}
	for index, want := range []time.Duration{1, 2, 4, 8, 16, 32, 60, 60, 60} {
		if got := backoff.NextDelay(time.Second); got != want*time.Second {
			t.Errorf("delay %d = %v, want %v", index, got, want*time.Second)
		}
	}
	if backoff.NextAttempt() != 10 || backoff.Failures() != 9 {
		t.Errorf("attempt %d / failures %d after nine exits", backoff.NextAttempt(), backoff.Failures())
	}
	// A process that ran for the stable uptime restarts from the first delay.
	if got := backoff.NextDelay(StableUptime); got != time.Second {
		t.Errorf("delay after a stable run = %v", got)
	}
	if got := backoff.NextDelay(StableUptime - time.Millisecond); got != 2*time.Second {
		t.Errorf("delay after an almost stable run = %v", got)
	}
	backoff.Reset()
	if backoff.Failures() != 0 || backoff.NextAttempt() != 1 {
		t.Error("reset did not clear the counter")
	}
}

func TestCrashCounter(t *testing.T) {
	counter := NewCrashCounter(3, time.Minute)
	t0 := time.Unix(1_000_000, 0)
	var hits []bool
	for _, offset := range []time.Duration{0, 10 * time.Second, 20 * time.Second} {
		hits = append(hits, counter.RecordExit(t0.Add(offset)))
	}
	if hits[0] || hits[1] || !hits[2] {
		t.Errorf("hits = %v", hits)
	}
	counter.Reset()
	// Three exits spread over more than the window never trip the counter.
	hits = hits[:0]
	for _, offset := range []time.Duration{100 * time.Second, 170 * time.Second, 240 * time.Second} {
		hits = append(hits, counter.RecordExit(t0.Add(offset)))
	}
	if hits[0] || hits[1] || hits[2] {
		t.Errorf("spread hits = %v", hits)
	}
	// Exactly at the window edge still counts; one past it does not.
	edge := NewCrashCounter(2, time.Minute)
	edge.RecordExit(t0)
	if !edge.RecordExit(t0.Add(time.Minute)) {
		t.Error("an exit at the window edge must count")
	}
	edge.Reset()
	edge.RecordExit(t0)
	if edge.RecordExit(t0.Add(time.Minute + time.Nanosecond)) {
		t.Error("an exit past the window must not count")
	}
}
