package core

import (
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

func TestRotatingLogFileRotatesAndCapsFileCount(t *testing.T) {
	path := filepath.Join(t.TempDir(), "logs", "source.log")
	log, err := OpenRotatingLogFile(path, 100, 3)
	if err != nil {
		t.Fatal(err)
	}
	lines := make([]string, 5)
	for index := range lines {
		lines[index] = string(rune('0'+index)) + "-" + strings.Repeat("x", 58)
		if err := log.Append(lines[index]); err != nil {
			t.Fatal(err)
		}
	}
	if err := log.Close(); err != nil {
		t.Fatal(err)
	}
	expectFile := func(name, want string) {
		t.Helper()
		data, err := os.ReadFile(name)
		if err != nil || string(data) != want {
			t.Errorf("%s = %q, %v; want %q", name, data, err, want)
		}
	}
	expectFile(path, lines[4]+"\n")
	expectFile(path+".1", lines[3]+"\n")
	expectFile(path+".2", lines[2]+"\n")
	if _, err := os.Stat(path + ".3"); err == nil {
		t.Error("a fourth file must not exist")
	}
	if err := log.Append("late"); err == nil {
		t.Error("writes after Close must fail")
	}
}

func TestRotatingLogFileReturnsTailOfCurrentFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "source.log")
	log, err := OpenRotatingLogFile(path, LogFileMaxBytes, LogFileKeep)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	for index := range 10 {
		log.Append("line-" + string(rune('0'+index)))
	}
	if got := log.Tail(3); !slices.Equal(got, []string{"line-7", "line-8", "line-9"}) {
		t.Errorf("tail = %q", got)
	}
	if got := log.Tail(0); len(got) != 0 {
		t.Errorf("tail(0) = %q", got)
	}
	if got := log.Tail(100); len(got) != 10 {
		t.Errorf("tail(100) has %d lines", len(got))
	}
	// A reopened log continues the existing file.
	log.Close()
	reopened, err := OpenRotatingLogFile(path, LogFileMaxBytes, LogFileKeep)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	reopened.WriteLine(fixtureDate, LogLevelWarning, "again")
	if got := reopened.Tail(2); !slices.Equal(got, []string{"line-9", "2026-08-25T12:00:00Z WARNING again"}) {
		t.Errorf("tail after reopen = %q", got)
	}
}

func TestRotatingLogFileSetsRestrictivePermissions(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX modes do not apply on Windows")
	}
	directory := filepath.Join(t.TempDir(), "logs")
	path := filepath.Join(directory, "source.log")
	log, err := OpenRotatingLogFile(path, LogFileMaxBytes, LogFileKeep)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	directoryInfo, _ := os.Stat(directory)
	fileInfo, _ := os.Stat(path)
	if directoryInfo.Mode().Perm() != 0o700 || fileInfo.Mode().Perm() != 0o600 {
		t.Errorf("modes: directory %v, file %v", directoryInfo.Mode().Perm(), fileInfo.Mode().Perm())
	}
	if _, err := OpenRotatingLogFile(path, 0, 1); err == nil {
		t.Error("a zero size must be rejected")
	}
}

func TestAtomicFileWriteReplacesContents(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "rules.json")
	if err := WriteStringAtomic(path, "one", 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteStringAtomic(path, "two", 0o600); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "two" {
		t.Errorf("contents = %q, %v", data, err)
	}
	entries, _ := os.ReadDir(directory)
	if len(entries) != 1 || entries[0].Name() != "rules.json" {
		t.Errorf("leftovers in %s: %v", directory, entries)
	}
	if runtime.GOOS != "windows" {
		if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
			t.Errorf("mode = %v", info.Mode().Perm())
		}
	}
	if err := WriteFileAtomic(filepath.Join(directory, "missing", "x"), nil, 0o600); err == nil {
		t.Error("a missing directory must fail")
	}
}
