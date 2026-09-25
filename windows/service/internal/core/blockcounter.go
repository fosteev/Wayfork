package core

import (
	"strings"
	"time"
)

// BlockCounter counts sing-box's own log lines for the block-ads rule — a reject from the
// route rule or a predefined answer from the DNS rule — since local midnight (F18). In
// memory only.
type BlockCounter struct {
	count int
	day   time.Time
}

// IsBlockedLine reports whether line records one blocked flow or lookup.
func IsBlockedLine(line string) bool {
	return strings.Contains(line, "rule_set="+BlockListRuleSetTag) &&
		(strings.Contains(line, "=> reject") || strings.Contains(line, "=> predefined"))
}

// Record counts one match at now.
func (c *BlockCounter) Record(now time.Time) {
	c.rollOver(now)
	c.count++
}

// Value is the count for the day now is in; zero once midnight has passed.
func (c *BlockCounter) Value(now time.Time) int {
	c.rollOver(now)
	return c.count
}

// Reset forgets the count.
func (c *BlockCounter) Reset() { c.count = 0; c.day = time.Time{} }

func (c *BlockCounter) rollOver(now time.Time) {
	y, m, d := now.Date()
	today := time.Date(y, m, d, 0, 0, 0, 0, now.Location())
	if !c.day.Equal(today) {
		c.day = today
		c.count = 0
	}
}
