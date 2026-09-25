package core

import "strings"

// LineSplitter turns arbitrary child-process byte chunks into UTF-8 lines
// (docs/design/05-daemon.md, "Logging plumbing").
type LineSplitter struct {
	buffer []byte
}

// Append buffers b, returns every LF-terminated line, and strips one preceding CR.
func (s *LineSplitter) Append(b []byte) []string {
	s.buffer = append(s.buffer, b...)
	lines := make([]string, 0)
	start := 0
	for index, value := range s.buffer {
		if value != '\n' {
			continue
		}
		end := index
		if end > start && s.buffer[end-1] == '\r' {
			end--
		}
		lines = append(lines, strings.ToValidUTF8(string(s.buffer[start:end]), "\uFFFD"))
		start = index + 1
	}
	if start > 0 {
		copy(s.buffer, s.buffer[start:])
		s.buffer = s.buffer[:len(s.buffer)-start]
	}
	return lines
}

// Flush returns the buffered partial line once.
func (s *LineSplitter) Flush() (string, bool) {
	if len(s.buffer) == 0 {
		return "", false
	}
	line := strings.ToValidUTF8(string(s.buffer), "\uFFFD")
	s.buffer = s.buffer[:0]
	return line, true
}
