package core

import "sort"

// LogRingCapacity is how many lines each source keeps for reattach
// (docs/design/05-daemon.md, "Logging plumbing").
const LogRingCapacity = 2000

// LogRing keeps the newest lines of one source.
type LogRing struct {
	lines    []LogLine
	start    int
	capacity int
}

// NewLogRing makes a ring for `capacity` lines (at least 1).
func NewLogRing(capacity int) *LogRing {
	if capacity < 1 {
		capacity = 1
	}
	return &LogRing{lines: make([]LogLine, 0, capacity), capacity: capacity}
}

// Append adds a line, dropping the oldest one when full.
func (r *LogRing) Append(line LogLine) {
	if len(r.lines) < r.capacity {
		r.lines = append(r.lines, line)
		return
	}
	r.lines[r.start] = line
	r.start = (r.start + 1) % r.capacity
}

// Len is the number of lines kept.
func (r *LogRing) Len() int { return len(r.lines) }

// Lines returns the kept lines, oldest first.
func (r *LogRing) Lines() []LogLine {
	out := make([]LogLine, 0, len(r.lines))
	out = append(out, r.lines[r.start:]...)
	return append(out, r.lines[:r.start]...)
}

// LogRings keeps one ring per source.
type LogRings struct {
	capacity int
	rings    map[string]*LogRing
	// Insertion order across sources, for a stable replay of lines with equal timestamps.
	sequence map[string][]uint64
	next     uint64
}

// NewLogRings makes an empty set of rings with the given per-source capacity.
func NewLogRings(capacity int) *LogRings {
	return &LogRings{capacity: capacity, rings: map[string]*LogRing{}, sequence: map[string][]uint64{}}
}

// Append routes a line to its source's ring.
func (r *LogRings) Append(line LogLine) {
	ring, ok := r.rings[line.Source]
	if !ok {
		ring = NewLogRing(r.capacity)
		r.rings[line.Source] = ring
	}
	ring.Append(line)
	r.next++
	sequence := append(r.sequence[line.Source], r.next)
	if len(sequence) > ring.capacity {
		sequence = sequence[len(sequence)-ring.capacity:]
	}
	r.sequence[line.Source] = sequence
}

// Sources lists the sources seen, sorted.
func (r *LogRings) Sources() []string {
	sources := make([]string, 0, len(r.rings))
	for source := range r.rings {
		sources = append(sources, source)
	}
	sort.Strings(sources)
	return sources
}

// Replay returns every kept line of every source, ordered by timestamp, then by the
// order the lines arrived in — what `subscribe` sends to a new client.
func (r *LogRings) Replay() []LogLine {
	type entry struct {
		line     LogLine
		sequence uint64
	}
	var entries []entry
	for source, ring := range r.rings {
		lines := ring.Lines()
		sequence := r.sequence[source]
		for index, line := range lines {
			entries = append(entries, entry{line: line, sequence: sequence[index]})
		}
	}
	sort.Slice(entries, func(i, j int) bool {
		if !entries[i].line.TS.Equal(entries[j].line.TS.Time) {
			return entries[i].line.TS.Before(entries[j].line.TS.Time)
		}
		return entries[i].sequence < entries[j].sequence
	})
	lines := make([]LogLine, 0, len(entries))
	for _, entry := range entries {
		lines = append(lines, entry.line)
	}
	return lines
}
