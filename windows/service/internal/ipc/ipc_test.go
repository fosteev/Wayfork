package ipc

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"wayfork/service/internal/core"
)

type fakeHandler struct {
	mu       sync.Mutex
	status   core.RuntimeStatus
	applied  []core.RuntimePlan
	sink     Sink
	applyGo  chan struct{}
	unsubbed int
}

func (h *fakeHandler) GetInfo(context.Context) core.DaemonInfo {
	return core.DaemonInfo{Version: "0.1.0", InstallPath: `C:\Program Files\Wayfork`, SingBoxVersion: "1.12", OpenVPNVersion: "2.7.6"}
}

func (h *fakeHandler) GetStatus(context.Context) core.RuntimeStatus {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.status
}

func (h *fakeHandler) Apply(_ context.Context, plan core.RuntimePlan) core.ApplyResult {
	if h.applyGo != nil {
		<-h.applyGo
	}
	h.mu.Lock()
	h.applied = append(h.applied, plan)
	h.mu.Unlock()
	if plan.Version != core.PlanVersion {
		return core.ApplyFailure(core.ErrPlanInvalid("bad version"))
	}
	return core.ApplySuccess()
}

func (h *fakeHandler) Stop(context.Context) core.ApplyResult { return core.ApplySuccess() }

func (h *fakeHandler) Reconnect(_ context.Context, id string) core.ApplyResult {
	if id != "a" {
		return core.ApplyFailure(core.ErrTunnelNotFound(id))
	}
	return core.ApplySuccess()
}

func (h *fakeHandler) CollectDiagnostics(context.Context) core.DaemonDiagnostics {
	return core.DaemonDiagnostics{Routes: "r"}
}

func (h *fakeHandler) Subscribe(_ context.Context, sink Sink) core.ApplyResult {
	h.mu.Lock()
	h.sink = sink
	h.mu.Unlock()
	sink.StatusChanged(h.GetStatus(context.Background()))
	return core.ApplySuccess()
}

func (h *fakeHandler) Unsubscribe(sink Sink) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.sink == sink {
		h.sink = nil
		h.unsubbed++
	}
}

func startPair(t *testing.T, handler Handler) (*Client, chan error, chan struct{}) {
	t.Helper()
	serverSide, clientSide := net.Pipe()
	served := make(chan error, 1)
	go func() { served <- ServeConn(context.Background(), serverSide, handler, "0.1.0") }()
	events := make(chan struct{}, 16)
	client := NewClient(clientSide, func(event string, data json.RawMessage) {
		events <- struct{}{}
	})
	return client, served, events
}

func TestRequestsAndReplies(t *testing.T) {
	handler := &fakeHandler{status: core.StoppedStatus()}
	client, served, _ := startPair(t, handler)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	hello, err := client.Hello(ctx)
	if err != nil || hello.Protocol != ProtocolVersion || hello.PlanVersion != core.PlanVersion || hello.Version != "0.1.0" {
		t.Fatalf("hello = %+v, %v", hello, err)
	}
	info, err := client.GetInfo(ctx)
	if err != nil || info.InstallPath != `C:\Program Files\Wayfork` {
		t.Errorf("info = %+v, %v", info, err)
	}
	status, err := client.GetStatus(ctx)
	if err != nil || status.Engine.Kind != core.EngineStopped {
		t.Errorf("status = %+v, %v", status, err)
	}
	plan := core.RuntimePlan{Version: core.PlanVersion, SingBox: core.SingBoxPlan{Config: "{}", ConfigHash: "h", RuleSets: map[string]string{}}, OpenVPN: []core.OpenVPNRuntime{}, AutoReconnect: true, LogLevel: core.LogLevelInfo, OverrideSystemDNS: true}
	result, err := client.Apply(ctx, plan)
	if err != nil || !result.OK {
		t.Errorf("apply = %+v, %v", result, err)
	}
	plan.Version = 2
	result, err = client.Apply(ctx, plan)
	if err != nil || result.OK || result.Error == nil || result.Error.Kind != core.DaemonPlanInvalid {
		t.Errorf("bad apply = %+v, %v", result, err)
	}
	if result, err := client.Reconnect(ctx, "zz"); err != nil || result.OK || result.Error.Kind != core.DaemonTunnelNotFound {
		t.Errorf("reconnect = %+v, %v", result, err)
	}
	if result, err := client.Stop(ctx); err != nil || !result.OK {
		t.Errorf("stop = %+v, %v", result, err)
	}
	if diagnostics, err := client.CollectDiagnostics(ctx); err != nil || diagnostics.Routes != "r" {
		t.Errorf("diagnostics = %+v, %v", diagnostics, err)
	}
	if err := client.Call(ctx, "explode", nil, nil); err == nil || !strings.Contains(err.Error(), "unknown method") {
		t.Errorf("unknown method error = %v", err)
	}
	if err := client.Call(ctx, MethodReconnect, map[string]any{}, nil); err == nil {
		t.Error("reconnect without an id must fail")
	}
	client.Close()
	if err := <-served; err == nil {
		t.Error("the server must report the close")
	}
	if handler.unsubbed != 0 {
		t.Error("a connection that never subscribed must not unsubscribe")
	}
}

func TestPushesAndConcurrency(t *testing.T) {
	handler := &fakeHandler{status: core.StoppedStatus(), applyGo: make(chan struct{})}
	client, served, events := startPair(t, handler)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if result, err := client.Subscribe(ctx); err != nil || !result.OK {
		t.Fatalf("subscribe = %+v, %v", result, err)
	}
	select {
	case <-events: // the replayed status
	case <-ctx.Done():
		t.Fatal("no status push after subscribe")
	}
	// An apply in flight does not block a status query.
	applied := make(chan error, 1)
	go func() {
		_, err := client.Apply(ctx, core.RuntimePlan{Version: core.PlanVersion, SingBox: core.SingBoxPlan{Config: "{}", ConfigHash: "h"}, OpenVPN: []core.OpenVPNRuntime{}})
		applied <- err
	}()
	if _, err := client.GetStatus(ctx); err != nil {
		t.Fatalf("status during apply: %v", err)
	}
	close(handler.applyGo)
	if err := <-applied; err != nil {
		t.Fatalf("apply: %v", err)
	}
	// Pushes from the service side reach the client.
	handler.mu.Lock()
	sink := handler.sink
	handler.mu.Unlock()
	sink.LogLines([]core.LogLine{{TS: core.NewTimestamp(time.Now()), Source: "daemon", Level: core.LogLevelInfo, Message: "hi"}})
	sink.TrafficChanged(core.TrafficSnapshot{})
	for range 2 {
		select {
		case <-events:
		case <-ctx.Done():
			t.Fatal("pushes did not arrive")
		}
	}
	client.Close()
	<-served
	if handler.unsubbed != 1 {
		t.Errorf("unsubscribed %d times", handler.unsubbed)
	}
}

func TestMalformedLinesGetAnErrorReply(t *testing.T) {
	serverSide, clientSide := net.Pipe()
	go ServeConn(context.Background(), serverSide, &fakeHandler{}, "0.1.0")
	defer clientSide.Close()
	reader := make(chan string, 4)
	go func() {
		buffer := make([]byte, 64*1024)
		for {
			n, err := clientSide.Read(buffer)
			if err != nil {
				return
			}
			for _, line := range strings.Split(strings.TrimSpace(string(buffer[:n])), "\n") {
				reader <- line
			}
		}
	}()
	hello := <-reader
	if !strings.HasPrefix(hello, `{"event":"hello"`) {
		t.Fatalf("first line = %s", hello)
	}
	clientSide.Write([]byte("not json\n"))
	if reply := <-reader; !strings.Contains(reply, "undecodable") {
		t.Errorf("reply = %s", reply)
	}
	clientSide.Write([]byte(`{"method":"getInfo"}` + "\n"))
	if reply := <-reader; !strings.Contains(reply, "needs id") {
		t.Errorf("reply = %s", reply)
	}
	clientSide.Write([]byte(`{"id":7,"method":"getInfo"}` + "\n"))
	if reply := <-reader; !strings.HasPrefix(reply, `{"id":7,"result":{"installPath":"C:\\Program Files\\Wayfork"`) {
		t.Errorf("reply = %s", reply)
	}
}
