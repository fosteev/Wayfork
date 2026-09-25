package service

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"wayfork/service/internal/core"
	"wayfork/service/internal/ipc"
)

const (
	// hubBatchLimit / hubBatchInterval: log lines are pushed every 250 ms or 200 lines.
	hubBatchLimit    = 200
	hubBatchInterval = 250 * time.Millisecond
	// hubStatusInterval coalesces status pushes.
	hubStatusInterval = 100 * time.Millisecond
	// DaemonSource is the service's own log source.
	DaemonSource = "daemon"
)

// Hub is everything that flows from the service to the app: status (coalesced), log
// lines (batched), traffic samples — plus the per-source ring buffers for reattach and
// the raw log files (docs/design/05-daemon.md, "Logging plumbing").
type Hub struct {
	logDir string
	clock  Clock
	// Mirror receives every line as well (the console in --dev-apply, the event log).
	Mirror func(line core.LogLine)

	mu          sync.Mutex
	sinks       map[ipc.Sink]struct{}
	status      core.RuntimeStatus
	statusDirty bool
	statusTimer *time.Timer
	pending     []core.LogLine
	logTimer    *time.Timer
	rings       *core.LogRings
	files       map[string]*core.RotatingLogFile
	closed      bool
}

// NewHub makes a hub writing raw logs under logDir.
func NewHub(logDir string, clock Clock) *Hub {
	if clock == nil {
		clock = SystemClock
	}
	return &Hub{
		logDir: logDir, clock: clock, sinks: map[ipc.Sink]struct{}{},
		status: core.StoppedStatus(), rings: core.NewLogRings(core.LogRingCapacity),
		files: map[string]*core.RotatingLogFile{},
	}
}

// Post ingests one line: ring, raw file, batch.
func (h *Hub) Post(line core.LogLine) {
	if line.TS.IsZero() {
		line.TS = core.NewTimestamp(h.clock.Now())
	}
	if h.Mirror != nil {
		h.Mirror(line)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return
	}
	h.rings.Append(line)
	if file := h.fileLocked(line.Source); file != nil {
		_ = file.WriteLine(line.TS.Time, line.Level, line.Message)
	}
	h.pending = append(h.pending, line)
	if len(h.pending) >= hubBatchLimit {
		h.flushLogsLocked()
	} else if h.logTimer == nil {
		h.logTimer = time.AfterFunc(hubBatchInterval, h.flushLogs)
	}
}

// Log posts a line from the service itself.
func (h *Hub) Log(level core.LogLevel, message string) {
	h.PostFrom(DaemonSource, level, message)
}

// PostFrom posts a line for a source.
func (h *Hub) PostFrom(source string, level core.LogLevel, message string) {
	h.Post(core.LogLine{TS: core.NewTimestamp(h.clock.Now()), Source: source, Level: level, Message: message})
}

func (h *Hub) flushLogs() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.flushLogsLocked()
}

func (h *Hub) flushLogsLocked() {
	if h.logTimer != nil {
		h.logTimer.Stop()
		h.logTimer = nil
	}
	if len(h.pending) == 0 {
		return
	}
	batch := h.pending
	h.pending = nil
	for sink := range h.sinks {
		sink.LogLines(batch)
	}
}

// Status is the last status set.
func (h *Hub) Status() core.RuntimeStatus {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.status
}

// SetStatus records a status and pushes it after the coalescing interval.
func (h *Hub) SetStatus(status core.RuntimeStatus) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.status = status
	h.statusDirty = true
	if h.statusTimer == nil && !h.closed {
		h.statusTimer = time.AfterFunc(hubStatusInterval, h.flushStatus)
	}
}

func (h *Hub) flushStatus() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.statusTimer = nil
	if !h.statusDirty {
		return
	}
	h.statusDirty = false
	for sink := range h.sinks {
		sink.StatusChanged(h.status)
	}
}

// Flush pushes whatever is pending right away (tests, shutdown).
func (h *Hub) Flush() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.statusTimer != nil {
		h.statusTimer.Stop()
		h.statusTimer = nil
	}
	if h.statusDirty {
		h.statusDirty = false
		for sink := range h.sinks {
			sink.StatusChanged(h.status)
		}
	}
	h.flushLogsLocked()
}

// PushTraffic forwards a sample; nothing is stored or replayed.
func (h *Hub) PushTraffic(snapshot core.TrafficSnapshot) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for sink := range h.sinks {
		sink.TrafficChanged(snapshot)
	}
}

// Subscribe adds a sink and replays the current status plus every ring buffer to it.
func (h *Hub) Subscribe(sink ipc.Sink) {
	h.mu.Lock()
	// Pending lines are already in the rings: deliver them to the old sinks now so the
	// new one sees each line exactly once (replay, then future batches).
	h.flushLogsLocked()
	h.sinks[sink] = struct{}{}
	status := h.status
	replay := h.rings.Replay()
	h.mu.Unlock()
	sink.StatusChanged(status)
	if len(replay) > 0 {
		sink.LogLines(replay)
	}
}

// Unsubscribe removes a sink.
func (h *Hub) Unsubscribe(sink ipc.Sink) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.sinks, sink)
}

// Tails returns the last `count` lines of every raw log file on disk, keyed by file stem
// (`daemon`, `sing-box`, `openvpn-<id>`).
func (h *Hub) Tails(count int) map[string][]string {
	h.mu.Lock()
	defer h.mu.Unlock()
	result := map[string][]string{}
	entries, err := os.ReadDir(h.logDir)
	if err != nil {
		return result
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".log") {
			continue
		}
		stem := strings.TrimSuffix(name, ".log")
		source := stem
		if rest, ok := strings.CutPrefix(stem, "openvpn-"); ok {
			source = "openvpn:" + rest
		}
		lines := []string{}
		if file := h.fileLocked(source); file != nil {
			lines = append(lines, file.Tail(count)...)
		}
		result[stem] = lines
	}
	return result
}

// RunListing describes the files of a directory for diagnostics (`name size`).
func RunListing(directory string) []string {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return []string{}
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		size := int64(0)
		if info, err := entry.Info(); err == nil {
			size = info.Size()
		}
		names = append(names, entry.Name()+" "+itoa(size))
	}
	sort.Strings(names)
	return names
}

func itoa(value int64) string {
	if value == 0 {
		return "0"
	}
	digits := ""
	for value > 0 {
		digits = string(rune('0'+value%10)) + digits
		value /= 10
	}
	return digits
}

func (h *Hub) fileLocked(source string) *core.RotatingLogFile {
	if file, ok := h.files[source]; ok {
		return file
	}
	if h.logDir == "" {
		return nil
	}
	path := filepath.Join(h.logDir, core.ChildLog(source))
	file, err := core.OpenRotatingLogFile(path, core.LogFileMaxBytes, core.LogFileKeep)
	if err != nil {
		return nil
	}
	h.files[source] = file
	return file
}

// Close flushes and closes the raw log files.
func (h *Hub) Close() {
	h.Flush()
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for _, file := range h.files {
		file.Close()
	}
	h.files = map[string]*core.RotatingLogFile{}
}
