package core

import "time"

var backoffDelays = [...]time.Duration{
	1 * time.Second,
	2 * time.Second,
	4 * time.Second,
	8 * time.Second,
	16 * time.Second,
	32 * time.Second,
	60 * time.Second,
}

// StableUptime is the uptime after which process failures reset their retry ladder
// (docs/design/05-daemon.md, "Supervisor").
const StableUptime = 60 * time.Second

// BackoffPolicy tracks consecutive supervised-process failures.
type BackoffPolicy struct {
	failures int
}

// NextDelay records an exit after uptime and returns the delay before restart.
func (p *BackoffPolicy) NextDelay(uptime time.Duration) time.Duration {
	if uptime >= StableUptime {
		p.failures = 0
	}
	p.failures++
	index := p.failures - 1
	if index >= len(backoffDelays) {
		index = len(backoffDelays) - 1
	}
	return backoffDelays[index]
}

// NextAttempt returns the attempt number assigned to the next start.
func (p BackoffPolicy) NextAttempt() int { return p.failures + 1 }

// Reset clears the failure count.
func (p *BackoffPolicy) Reset() { p.failures = 0 }

// Failures returns the consecutive failure count.
func (p BackoffPolicy) Failures() int { return p.failures }

// CrashCounter detects repeated process exits inside a rolling window.
type CrashCounter struct {
	Limit  int
	Window time.Duration
	exits  []time.Time
}

// NewCrashCounter constructs a rolling crash counter.
func NewCrashCounter(limit int, window time.Duration) CrashCounter {
	return CrashCounter{Limit: limit, Window: window}
}

// RecordExit records an exit and reports whether the limit has been reached in the window.
func (c *CrashCounter) RecordExit(at time.Time) bool {
	c.exits = append(c.exits, at)
	kept := c.exits[:0]
	for _, exit := range c.exits {
		if at.Sub(exit) <= c.Window {
			kept = append(kept, exit)
		}
	}
	c.exits = kept
	return len(c.exits) >= c.Limit
}

// Reset clears all recorded exits.
func (c *CrashCounter) Reset() { c.exits = nil }
