package service

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"wayfork/service/internal/core"
)

// ManagementHandlers receive the management channel's lines and its close.
type ManagementHandlers struct {
	OnLine  func(line string)
	OnClose func(err error)
}

// ManagementClient is the TCP side of OpenVPN's management interface on Windows
// (`--management 127.0.0.1 <port> <password-file>`): it answers the password prompt,
// then hands every line to the handlers (docs/design/08-windows.md, "Go core").
type ManagementClient struct {
	conn    net.Conn
	writeMu sync.Mutex
	once    sync.Once
	closed  chan struct{}
}

// managementDialInterval is how often the client retries while OpenVPN opens its port.
const managementDialInterval = 100 * time.Millisecond

// ConnectManagement dials `address` until ctx ends (OpenVPN opens the port shortly after
// it starts), performs the password exchange and starts the reader. It returns once the
// channel is usable.
func ConnectManagement(ctx context.Context, address, password string, handlers ManagementHandlers) (*ManagementClient, error) {
	var dialer net.Dialer
	var conn net.Conn
	for {
		var err error
		conn, err = dialer.DialContext(ctx, "tcp4", address)
		if err == nil {
			break
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("management %s: %w", address, ctx.Err())
		case <-time.After(managementDialInterval):
		}
	}
	client := &ManagementClient{conn: conn, closed: make(chan struct{})}
	splitter := &core.LineSplitter{}
	var leftover []string
	if password != "" {
		var err error
		leftover, err = client.authenticate(ctx, password, splitter)
		if err != nil {
			client.Close()
			return nil, err
		}
	}
	go func() {
		for _, line := range leftover {
			if handlers.OnLine != nil {
				handlers.OnLine(line)
			}
		}
		client.read(splitter, handlers)
	}()
	return client, nil
}

// authenticate waits for `ENTER PASSWORD:`, sends the password and expects
// `SUCCESS: password is correct`. Lines that arrived in the same read as the acceptance
// are returned for the reader to deliver.
func (c *ManagementClient) authenticate(ctx context.Context, password string, splitter *core.LineSplitter) ([]string, error) {
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(10 * time.Second)
	}
	_ = c.conn.SetReadDeadline(deadline)
	defer c.conn.SetReadDeadline(time.Time{})
	var buffered []byte
	chunk := make([]byte, 4096)
	for !core.IsManagementPasswordPrompt(buffered) {
		n, err := c.conn.Read(chunk)
		if err != nil {
			return nil, fmt.Errorf("management: waiting for the password prompt: %w", err)
		}
		buffered = append(buffered, chunk[:n]...)
		if len(buffered) > 64*1024 {
			return nil, errors.New("management: no password prompt")
		}
	}
	if err := c.Send(password); err != nil {
		return nil, err
	}
	for {
		n, err := c.conn.Read(chunk)
		if err != nil {
			return nil, fmt.Errorf("management: waiting for the password reply: %w", err)
		}
		lines := splitter.Append(chunk[:n])
		for index, line := range lines {
			event := core.ParseManagementLine(line)
			switch {
			case event.Kind == core.EventSuccess && strings.Contains(event.Message, core.ManagementPasswordAccepted):
				return lines[index+1:], nil
			case event.Kind == core.EventError:
				return nil, fmt.Errorf("management: %s", event.Message)
			}
			// Anything else before the acceptance (a stray prompt echo) is dropped.
		}
	}
}

func (c *ManagementClient) read(splitter *core.LineSplitter, handlers ManagementHandlers) {
	chunk := make([]byte, 8192)
	for {
		n, err := c.conn.Read(chunk)
		if n > 0 {
			for _, line := range splitter.Append(chunk[:n]) {
				if handlers.OnLine != nil {
					handlers.OnLine(line)
				}
			}
		}
		if err != nil {
			if rest, ok := splitter.Flush(); ok && handlers.OnLine != nil {
				handlers.OnLine(rest)
			}
			c.Close()
			if handlers.OnClose != nil {
				handlers.OnClose(err)
			}
			return
		}
	}
}

// Send writes one command line. Never log what goes in here.
func (c *ManagementClient) Send(command string) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	select {
	case <-c.closed:
		return errors.New("management: closed")
	default:
	}
	_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, err := c.conn.Write([]byte(command + "\n"))
	return err
}

// Close closes the connection; the reader reports OnClose.
func (c *ManagementClient) Close() {
	c.once.Do(func() {
		close(c.closed)
		c.conn.Close()
	})
}
