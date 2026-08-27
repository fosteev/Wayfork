package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"

	"wayfork/service/internal/core"
)

// EventFunc receives the service's pushes (name and raw payload).
type EventFunc func(event string, data json.RawMessage)

// Client talks to the service over one connection (wayforkctl, tests).
type Client struct {
	rw      io.ReadWriteCloser
	events  EventFunc
	writeMu sync.Mutex
	mu      sync.Mutex
	nextID  int64
	waiting map[int64]chan Message
	done    chan struct{}
	err     error
	hello   chan Hello
}

// NewClient starts reading rw; events (may be nil) is called for every push.
func NewClient(rw io.ReadWriteCloser, events EventFunc) *Client {
	client := &Client{
		rw: rw, events: events, waiting: map[int64]chan Message{},
		done: make(chan struct{}), hello: make(chan Hello, 1),
	}
	go client.read()
	return client
}

// Hello waits for the service's greeting.
func (c *Client) Hello(ctx context.Context) (Hello, error) {
	select {
	case hello := <-c.hello:
		c.hello <- hello
		return hello, nil
	case <-c.done:
		return Hello{}, c.closeError()
	case <-ctx.Done():
		return Hello{}, ctx.Err()
	}
}

func (c *Client) read() {
	scanner := bufio.NewScanner(c.rw)
	scanner.Buffer(make([]byte, 64*1024), MaxLineBytes)
	for scanner.Scan() {
		var message Message
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			continue
		}
		switch {
		case message.Event == EventHello:
			var hello Hello
			if json.Unmarshal(message.Data, &hello) == nil {
				select {
				case c.hello <- hello:
				default:
				}
			}
		case message.Event != "":
			if c.events != nil {
				c.events(message.Event, message.Data)
			}
		case message.ID != nil:
			c.mu.Lock()
			waiter := c.waiting[*message.ID]
			delete(c.waiting, *message.ID)
			c.mu.Unlock()
			if waiter != nil {
				waiter <- message
			}
		}
	}
	c.mu.Lock()
	c.err = scanner.Err()
	if c.err == nil {
		c.err = io.EOF
	}
	close(c.done)
	c.mu.Unlock()
}

func (c *Client) closeError() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err == nil {
		return errors.New("connection closed")
	}
	return fmt.Errorf("connection closed: %w", c.err)
}

// Call sends a request and decodes the result into `result` (nil to discard it).
func (c *Client) Call(ctx context.Context, method string, params any, result any) error {
	var raw json.RawMessage
	if params != nil {
		encoded, err := wirePayload(params)
		if err != nil {
			return err
		}
		raw = encoded
	}
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	waiter := make(chan Message, 1)
	c.waiting[id] = waiter
	c.mu.Unlock()
	data, err := encode(Message{ID: &id, Method: method, Params: raw})
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	_, err = c.rw.Write(data)
	c.writeMu.Unlock()
	if err != nil {
		return err
	}
	select {
	case reply := <-waiter:
		if reply.Error != "" {
			return errors.New(reply.Error)
		}
		if result == nil {
			return nil
		}
		return json.Unmarshal(reply.Result, result)
	case <-c.done:
		return c.closeError()
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.waiting, id)
		c.mu.Unlock()
		return ctx.Err()
	}
}

// Close closes the connection.
func (c *Client) Close() error { return c.rw.Close() }

// GetInfo calls getInfo.
func (c *Client) GetInfo(ctx context.Context) (core.DaemonInfo, error) {
	var info core.DaemonInfo
	err := c.Call(ctx, MethodGetInfo, nil, &info)
	return info, err
}

// GetStatus calls getStatus.
func (c *Client) GetStatus(ctx context.Context) (core.RuntimeStatus, error) {
	var status core.RuntimeStatus
	err := c.Call(ctx, MethodGetStatus, nil, &status)
	return status, err
}

// Subscribe calls subscribe.
func (c *Client) Subscribe(ctx context.Context) (core.ApplyResult, error) {
	var result core.ApplyResult
	err := c.Call(ctx, MethodSubscribe, nil, &result)
	return result, err
}

// Apply calls apply.
func (c *Client) Apply(ctx context.Context, plan core.RuntimePlan) (core.ApplyResult, error) {
	var result core.ApplyResult
	err := c.Call(ctx, MethodApply, plan, &result)
	return result, err
}

// Stop calls stop.
func (c *Client) Stop(ctx context.Context) (core.ApplyResult, error) {
	var result core.ApplyResult
	err := c.Call(ctx, MethodStop, nil, &result)
	return result, err
}

// Reconnect calls reconnect.
func (c *Client) Reconnect(ctx context.Context, id string) (core.ApplyResult, error) {
	var result core.ApplyResult
	err := c.Call(ctx, MethodReconnect, ReconnectParams{ID: id}, &result)
	return result, err
}

// CollectDiagnostics calls collectDiagnostics.
func (c *Client) CollectDiagnostics(ctx context.Context) (core.DaemonDiagnostics, error) {
	var diagnostics core.DaemonDiagnostics
	err := c.Call(ctx, MethodCollectDiagnostics, nil, &diagnostics)
	return diagnostics, err
}
