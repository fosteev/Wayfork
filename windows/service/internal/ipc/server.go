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

// Conn serves one client connection: requests are dispatched concurrently (an `apply`
// in flight never delays a `getStatus`), responses and pushes are written one line at a
// time.
type Conn struct {
	rw       io.ReadWriteCloser
	handler  Handler
	version  string
	writeMu  sync.Mutex
	closed   chan struct{}
	closeErr error
	once     sync.Once
}

// ServeConn runs the connection until the peer closes it or ctx ends; it returns the
// read error (io.EOF for a clean close).
func ServeConn(ctx context.Context, rw io.ReadWriteCloser, handler Handler, serviceVersion string) error {
	conn := &Conn{rw: rw, handler: handler, version: serviceVersion, closed: make(chan struct{})}
	return conn.serve(ctx)
}

func (c *Conn) serve(ctx context.Context) error {
	defer c.close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		<-ctx.Done()
		c.close()
	}()
	if err := c.push(EventHello, Hello{Protocol: ProtocolVersion, PlanVersion: core.PlanVersion, Version: c.version}); err != nil {
		return err
	}
	scanner := bufio.NewScanner(c.rw)
	scanner.Buffer(make([]byte, 64*1024), MaxLineBytes)
	var pending sync.WaitGroup
	defer func() {
		c.handler.Unsubscribe(c)
		pending.Wait()
	}()
	for scanner.Scan() {
		line := append([]byte(nil), scanner.Bytes()...)
		if len(line) == 0 {
			continue
		}
		var message Message
		if err := json.Unmarshal(line, &message); err != nil {
			c.reply(nil, nil, fmt.Sprintf("undecodable message: %v", err))
			continue
		}
		if message.ID == nil || message.Method == "" {
			c.reply(message.ID, nil, "a request needs id and method")
			continue
		}
		pending.Add(1)
		go func() {
			defer pending.Done()
			c.dispatch(ctx, message)
		}()
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return io.EOF
}

func (c *Conn) dispatch(ctx context.Context, message Message) {
	var result any
	switch message.Method {
	case MethodGetInfo:
		result = c.handler.GetInfo(ctx)
	case MethodGetStatus:
		result = c.handler.GetStatus(ctx)
	case MethodSubscribe:
		result = c.handler.Subscribe(ctx, c)
	case MethodApply:
		var plan core.RuntimePlan
		if err := json.Unmarshal(message.Params, &plan); err != nil {
			result = core.ApplyFailure(core.ErrPlanInvalid(fmt.Sprintf("undecodable plan: %v", err)))
			break
		}
		result = c.handler.Apply(ctx, plan)
	case MethodStop:
		result = c.handler.Stop(ctx)
	case MethodReconnect:
		var params ReconnectParams
		if err := json.Unmarshal(message.Params, &params); err != nil || params.ID == "" {
			c.reply(message.ID, nil, "reconnect needs {\"id\": \"<tunnel id>\"}")
			return
		}
		result = c.handler.Reconnect(ctx, params.ID)
	case MethodCollectDiagnostics:
		result = c.handler.CollectDiagnostics(ctx)
	default:
		c.reply(message.ID, nil, "unknown method "+message.Method)
		return
	}
	payload, err := wirePayload(result)
	if err != nil {
		c.reply(message.ID, nil, fmt.Sprintf("cannot encode the reply: %v", err))
		return
	}
	c.reply(message.ID, payload, "")
}

func (c *Conn) reply(id *int64, result json.RawMessage, errorText string) {
	c.write(Message{ID: id, Result: result, Error: errorText})
}

func (c *Conn) push(event string, data any) error {
	payload, err := wirePayload(data)
	if err != nil {
		return err
	}
	return c.write(Message{Event: event, Data: payload})
}

func (c *Conn) write(message Message) error {
	data, err := encode(message)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	select {
	case <-c.closed:
		return errors.New("connection closed")
	default:
	}
	_, err = c.rw.Write(data)
	return err
}

func (c *Conn) close() {
	c.once.Do(func() {
		close(c.closed)
		c.closeErr = c.rw.Close()
	})
}

// StatusChanged implements Sink.
func (c *Conn) StatusChanged(status core.RuntimeStatus) { _ = c.push(EventStatusChanged, status) }

// LogLines implements Sink.
func (c *Conn) LogLines(lines []core.LogLine) { _ = c.push(EventLogLines, lines) }

// TrafficChanged implements Sink.
func (c *Conn) TrafficChanged(snapshot core.TrafficSnapshot) {
	_ = c.push(EventTrafficChanged, snapshot)
}
