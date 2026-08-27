//go:build !windows

package ipc

import (
	"errors"
	"io"
)

// DialPipe is Windows-only; other platforms have no service to talk to.
func DialPipe(string) (io.ReadWriteCloser, error) {
	return nil, errors.New("named pipes exist on Windows only")
}
