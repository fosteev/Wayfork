package core

import (
	"fmt"
	"os"
)

// WriteFileAtomic writes `data` to a temporary file next to `path`, syncs it and renames
// it over `path`, so a reader (sing-box's rule-set watcher) and a crash mid-write both see
// either the old or the new contents (docs/design/05-daemon.md, "Files written by the
// daemon"). os.Rename replaces an existing file on Windows too.
func WriteFileAtomic(path string, data []byte, perm os.FileMode) error {
	temporary := fmt.Sprintf("%s.tmp-%d", path, os.Getpid())
	file, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return fmt.Errorf("atomic write: %w", err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		os.Remove(temporary)
		return fmt.Errorf("atomic write: %w", err)
	}
	if err := file.Sync(); err != nil {
		file.Close()
		os.Remove(temporary)
		return fmt.Errorf("atomic write: %w", err)
	}
	if err := file.Close(); err != nil {
		os.Remove(temporary)
		return fmt.Errorf("atomic write: %w", err)
	}
	if err := os.Rename(temporary, path); err != nil {
		os.Remove(temporary)
		return fmt.Errorf("atomic write: %w", err)
	}
	return nil
}

// WriteStringAtomic is WriteFileAtomic for text.
func WriteStringAtomic(path, contents string, perm os.FileMode) error {
	return WriteFileAtomic(path, []byte(contents), perm)
}
