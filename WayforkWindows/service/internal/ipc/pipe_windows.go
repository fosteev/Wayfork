//go:build windows

package ipc

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/windows"
)

// PipeSecurity: SYSTEM and Administrators full control, authenticated users may
// connect (read/write) — the app runs as the user; the service then verifies the client
// image (docs/design/08-windows.md, "IPC").
const PipeSecurity = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)"

// PipeConn is one accepted client connection. The instance is opened with
// FILE_FLAG_OVERLAPPED so that os.File runs reads and writes through the runtime poller:
// on a synchronous pipe handle the I/O manager serializes operations, and a blocked read
// would hold every write (the hello, every reply) until the peer sent something.
type PipeConn struct {
	file   *os.File
	handle windows.Handle
	// ClientPID is the connecting process (GetNamedPipeClientProcessId).
	ClientPID uint32
}

// Read implements io.Reader.
func (c *PipeConn) Read(p []byte) (int, error) { return c.file.Read(p) }

// Write implements io.Writer.
func (c *PipeConn) Write(p []byte) (int, error) { return c.file.Write(p) }

// Close disconnects and closes the instance.
func (c *PipeConn) Close() error {
	_ = windows.DisconnectNamedPipe(c.handle)
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
		windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_OVERLAPPED,
		windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS,
		windows.PIPE_UNLIMITED_INSTANCES, 64*1024, 64*1024, 0, l.sa)
	if err != nil {
		l.mu.Unlock()
		return nil, fmt.Errorf("creating the pipe: %w", err)
	}
	l.pending = handle
	l.mu.Unlock()

	err = connectNamedPipe(handle)
	l.mu.Lock()
	l.pending = 0
	closed := l.closed
	l.mu.Unlock()
	if closed {
		windows.CloseHandle(handle)
		return nil, errors.New("pipe listener closed")
	}
	if err != nil {
		windows.CloseHandle(handle)
		return nil, fmt.Errorf("waiting for a client: %w", err)
	}
	var pid uint32
	if err := windows.GetNamedPipeClientProcessId(handle, &pid); err != nil {
		windows.CloseHandle(handle)
		return nil, fmt.Errorf("identifying the client: %w", err)
	}
	return &PipeConn{file: os.NewFile(uintptr(handle), "wayfork-pipe"), handle: handle, ClientPID: pid}, nil
}

// connectNamedPipe waits for a client on an overlapped instance. Closing the listener
// cancels the wait (CancelIoEx + CloseHandle), which surfaces as an error here.
func connectNamedPipe(handle windows.Handle) error {
	event, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(event)
	overlapped := windows.Overlapped{HEvent: event}
	err = windows.ConnectNamedPipe(handle, &overlapped)
	switch {
	case err == nil, errors.Is(err, windows.ERROR_PIPE_CONNECTED):
		// ERROR_PIPE_CONNECTED: the client connected between CreateNamedPipe and Connect.
		return nil
	case errors.Is(err, windows.ERROR_IO_PENDING):
		if _, err := windows.WaitForSingleObject(event, windows.INFINITE); err != nil {
			return err
		}
		var transferred uint32
		return windows.GetOverlappedResult(handle, &overlapped, &transferred, false)
	default:
		return err
	}
}

// Close stops Accept.
func (l *PipeListener) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closed = true
	if l.pending != 0 {
		_ = windows.CancelIoEx(l.pending, nil)
		windows.CloseHandle(l.pending)
		l.pending = 0
	}
	return nil
}

// DialPipe connects to the service's pipe (wayforkctl, tests on Windows). The handle is
// overlapped for the same reason as the server's (see PipeConn); a busy pipe (every
// instance taken between two accepts) is waited for briefly.
func DialPipe(name string) (io.ReadWriteCloser, error) {
	utf16Name, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	for attempt := 0; ; attempt++ {
		handle, err := windows.CreateFile(utf16Name, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil,
			windows.OPEN_EXISTING, windows.FILE_FLAG_OVERLAPPED, 0)
		if err == nil {
			return os.NewFile(uintptr(handle), name), nil
		}
		if !errors.Is(err, windows.ERROR_PIPE_BUSY) || attempt == 10 {
			return nil, fmt.Errorf("connecting to %s: %w", name, err)
		}
		time.Sleep(200 * time.Millisecond)
	}
}
