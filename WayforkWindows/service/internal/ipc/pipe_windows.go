//go:build windows

package ipc

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sync"

	"golang.org/x/sys/windows"
)

// PipeSecurity: SYSTEM and Administrators full control, authenticated users may
// connect (read/write) — the app runs as the user; the service then verifies the client
// image (docs/design/08-windows.md, "IPC").
const PipeSecurity = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)"

// PipeConn is one accepted client connection.
type PipeConn struct {
	file *os.File
	// ClientPID is the connecting process (GetNamedPipeClientProcessId).
	ClientPID uint32
}

// Read implements io.Reader.
func (c *PipeConn) Read(p []byte) (int, error) { return c.file.Read(p) }

// Write implements io.Writer.
func (c *PipeConn) Write(p []byte) (int, error) { return c.file.Write(p) }

// Close disconnects and closes the instance.
func (c *PipeConn) Close() error {
	_ = windows.DisconnectNamedPipe(windows.Handle(c.file.Fd()))
	return c.file.Close()
}

// PipeListener accepts connections on a named pipe, one instance per client.
type PipeListener struct {
	name *uint16
	sa   *windows.SecurityAttributes

	mu      sync.Mutex
	pending windows.Handle
	closed  bool
}

// ListenPipe prepares a listener for `name` (`\\.\pipe\wayfork`).
func ListenPipe(name string) (*PipeListener, error) {
	utf16Name, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	descriptor, err := windows.SecurityDescriptorFromString(PipeSecurity)
	if err != nil {
		return nil, fmt.Errorf("pipe security: %w", err)
	}
	sa := &windows.SecurityAttributes{
		Length:             uint32(unsafeSizeof()),
		SecurityDescriptor: descriptor,
	}
	return &PipeListener{name: utf16Name, sa: sa}, nil
}

func unsafeSizeof() uintptr {
	var sa windows.SecurityAttributes
	return sizeOf(sa)
}

// Accept blocks until a client connects and returns its connection.
func (l *PipeListener) Accept() (*PipeConn, error) {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return nil, errors.New("pipe listener closed")
	}
	handle, err := windows.CreateNamedPipe(l.name,
		windows.PIPE_ACCESS_DUPLEX,
		windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS,
		windows.PIPE_UNLIMITED_INSTANCES, 64*1024, 64*1024, 0, l.sa)
	if err != nil {
		l.mu.Unlock()
		return nil, fmt.Errorf("creating the pipe: %w", err)
	}
	l.pending = handle
	l.mu.Unlock()

	err = windows.ConnectNamedPipe(handle, nil)
	l.mu.Lock()
	l.pending = 0
	closed := l.closed
	l.mu.Unlock()
	if closed {
		windows.CloseHandle(handle)
		return nil, errors.New("pipe listener closed")
	}
	// ERROR_PIPE_CONNECTED: the client connected between CreateNamedPipe and Connect.
	if err != nil && !errors.Is(err, windows.ERROR_PIPE_CONNECTED) {
		windows.CloseHandle(handle)
		return nil, fmt.Errorf("waiting for a client: %w", err)
	}
	var pid uint32
	if err := windows.GetNamedPipeClientProcessId(handle, &pid); err != nil {
		windows.CloseHandle(handle)
		return nil, fmt.Errorf("identifying the client: %w", err)
	}
	return &PipeConn{file: os.NewFile(uintptr(handle), "wayfork-pipe"), ClientPID: pid}, nil
}

// Close stops Accept.
func (l *PipeListener) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closed = true
	if l.pending != 0 {
		windows.CloseHandle(l.pending)
		l.pending = 0
	}
	return nil
}

// DialPipe connects to the service's pipe (wayforkctl, tests on Windows).
func DialPipe(name string) (io.ReadWriteCloser, error) {
	utf16Name, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(utf16Name, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil,
		windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return nil, fmt.Errorf("connecting to %s: %w", name, err)
	}
	return os.NewFile(uintptr(handle), name), nil
}
