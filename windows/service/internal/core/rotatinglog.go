package core

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	// LogFileMaxBytes is the rotation threshold of a raw child log (5 × 1 MB,
	// docs/design/08-windows.md, "Logging").
	LogFileMaxBytes int64 = 1 << 20
	// LogFileKeep is how many files a rotation keeps, the live one included.
	LogFileKeep = 5
	// logTailBytes bounds what Tail reads back.
	logTailBytes int64 = 256 * 1024
)

// RotatingLogFile appends lines to `<path>` and rotates it to `<path>.1` … `<path>.<keep-1>`
// before a write would exceed maxBytes. Safe for concurrent use.
type RotatingLogFile struct {
	mu       sync.Mutex
	path     string
	maxBytes int64
	keep     int
	file     *os.File
	size     int64
	closed   bool
}

// OpenRotatingLogFile creates the parent directory (0700) and opens or creates the log
// (0600, append). The modes matter on macOS test hosts; on Windows the directory's ACL rules.
func OpenRotatingLogFile(path string, maxBytes int64, keep int) (*RotatingLogFile, error) {
	if maxBytes <= 0 || keep <= 0 {
		return nil, errors.New("rotating log: maxBytes and keep must be positive")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("rotating log: %w", err)
	}
	log := &RotatingLogFile{path: path, maxBytes: maxBytes, keep: keep}
	if err := log.open(); err != nil {
		return nil, err
	}
	return log, nil
}

func (l *RotatingLogFile) open() error {
	// O_RDWR: Tail reads back through the same handle.
	file, err := os.OpenFile(l.path, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("rotating log: %w", err)
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return fmt.Errorf("rotating log: %w", err)
	}
	l.file = file
	l.size = info.Size()
	return nil
}

// FormatLogLine renders `<ISO-8601 UTC seconds> <LEVEL> <message>`, the raw log format.
func FormatLogLine(ts time.Time, level LogLevel, message string) string {
	return ts.UTC().Format(wireTimestampLayout) + " " + strings.ToUpper(string(level)) + " " + message
}

// WriteLine appends one formatted line.
func (l *RotatingLogFile) WriteLine(ts time.Time, level LogLevel, message string) error {
	return l.Append(FormatLogLine(ts, level, message))
}

// Append writes `line` plus a newline, rotating first when the file would grow past
// maxBytes.
func (l *RotatingLogFile) Append(line string) error {
	data := []byte(line + "\n")
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return errors.New("rotating log: closed")
	}
	if l.size+int64(len(data)) > l.maxBytes {
		if err := l.rotate(); err != nil {
			return err
		}
	}
	written, err := l.file.Write(data)
	l.size += int64(written)
	if err != nil {
		return fmt.Errorf("rotating log: %w", err)
	}
	return nil
}

func (l *RotatingLogFile) rotate() error {
	if l.file != nil {
		l.file.Close()
		l.file = nil
	}
	if l.keep == 1 {
		os.Remove(l.path)
	} else {
		os.Remove(fmt.Sprintf("%s.%d", l.path, l.keep-1))
		for index := l.keep - 2; index >= 1; index-- {
			os.Rename(fmt.Sprintf("%s.%d", l.path, index), fmt.Sprintf("%s.%d", l.path, index+1))
		}
		os.Rename(l.path, l.path+".1")
	}
	return l.open()
}

// Tail returns the last `count` complete lines of the live file (at most the last 256 KB).
func (l *RotatingLogFile) Tail(count int) []string {
	if count <= 0 {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed || l.file == nil {
		return nil
	}
	info, err := l.file.Stat()
	if err != nil || info.Size() == 0 {
		return nil
	}
	length := min(info.Size(), logTailBytes)
	start := info.Size() - length
	data := make([]byte, length)
	read, err := l.file.ReadAt(data, start)
	if err != nil && err != io.EOF {
		return nil
	}
	data = data[:read]
	if start > 0 {
		if newline := bytes.IndexByte(data, '\n'); newline >= 0 {
			data = data[newline+1:]
		}
	}
	lines := strings.Split(string(data), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > count {
		lines = lines[len(lines)-count:]
	}
	return lines
}

// Close closes the live file; later writes fail.
func (l *RotatingLogFile) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	if l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	return err
}
