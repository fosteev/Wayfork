package service

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"wayfork/service/internal/core"
)

// fakeProcess is a child whose exit the test (or the fake runner) triggers.
type fakeProcess struct {
	pid      int
	started  time.Time
	handlers ProcessHandlers
	once     sync.Once
	exited   chan struct{}
	onKill   func()
}

func (p *fakeProcess) PID() int             { return p.pid }
func (p *fakeProcess) StartedAt() time.Time { return p.started }
func (p *fakeProcess) Exited() <-chan struct{} {
	return p.exited
}

func (p *fakeProcess) exit(code uint32) {
	p.once.Do(func() {
		if p.handlers.OnExit != nil {
			p.handlers.OnExit(code)
		}
		close(p.exited)
	})
}

func (p *fakeProcess) Terminate(timeout time.Duration) uint32 {
	select {
	case <-p.exited:
		return 0
	case <-time.After(timeout):
	}
	if p.onKill != nil {
		p.onKill()
	}
	p.exit(1)
	return 1
}

// fakeRunner spawns fake sing-box and OpenVPN children. A fake OpenVPN comes with a
// real TCP management server that plays the Windows dialogue: password prompt, hold,
// PUSH_REPLY with a route gateway, CONNECTED, SIGTERM → EXITING.
type fakeRunner struct {
	mu          sync.Mutex
	nextPID     int
	specs       []ProcessSpec
	processes   []*fakeProcess
	checkFails  string
	singBoxDies bool
	// singBoxStarted: whether the fake prints "sing-box started".
	singBoxSilent bool
	runs          []ProcessSpec
}

func (r *fakeRunner) Start(spec ProcessSpec, handlers ProcessHandlers) (Process, error) {
	r.mu.Lock()
	r.nextPID++
	process := &fakeProcess{pid: 1000 + r.nextPID, started: time.Now(), handlers: handlers, exited: make(chan struct{})}
	r.specs = append(r.specs, spec)
	r.processes = append(r.processes, process)
	singBoxSilent, singBoxDies := r.singBoxSilent, r.singBoxDies
	r.mu.Unlock()
	switch {
	case strings.Contains(spec.Executable, "sing-box"):
		go func() {
			time.Sleep(20 * time.Millisecond)
			handlers.OnLine("+0300 2026-08-27 20:00:00 INFO inbound/tun[tun-in]: started")
			if singBoxDies {
				process.exit(2)
				return
			}
			if !singBoxSilent {
				handlers.OnLine("+0300 2026-08-27 20:00:00 INFO sing-box started (0.02s)")
			}
		}()
	case strings.Contains(spec.Executable, "openvpn"):
		if err := startFakeManagement(spec, process); err != nil {
			return nil, err
		}
	}
	return process, nil
}

func (r *fakeRunner) Run(ctx context.Context, spec ProcessSpec) (CommandResult, error) {
	r.mu.Lock()
	r.runs = append(r.runs, spec)
	checkFails := r.checkFails
	r.mu.Unlock()
	switch {
	case len(spec.Args) > 0 && spec.Args[0] == "check":
		if checkFails != "" {
			return CommandResult{ExitCode: 1, Lines: []string{checkFails}}, nil
		}
		return CommandResult{Lines: []string{}}, nil
	case len(spec.Args) > 0 && spec.Args[0] == "version":
		return CommandResult{Lines: []string{"sing-box version 1.13.19", "Environment: go1.25"}}, nil
	case len(spec.Args) > 0 && spec.Args[0] == "--version":
		return CommandResult{Lines: []string{"OpenVPN 2.7.6 x86_64-w64-mingw32 [SSL (OpenSSL)]"}}, nil
	}
	return CommandResult{}, nil
}

func (r *fakeRunner) started(executable string) []ProcessSpec {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []ProcessSpec
	for _, spec := range r.specs {
		if strings.Contains(spec.Executable, executable) {
			out = append(out, spec)
		}
	}
	return out
}

func (r *fakeRunner) latest(executable string) *fakeProcess {
	r.mu.Lock()
	defer r.mu.Unlock()
	for index := len(r.specs) - 1; index >= 0; index-- {
		if strings.Contains(r.specs[index].Executable, executable) {
			return r.processes[index]
		}
	}
	return nil
}

// startFakeManagement listens on the port from argv and plays OpenVPN's management side.
func startFakeManagement(spec ProcessSpec, process *fakeProcess) error {
	port, passwordFile := "", ""
	for index, arg := range spec.Args {
		if arg == "--management" && index+3 < len(spec.Args) {
			port, passwordFile = spec.Args[index+2], spec.Args[index+3]
		}
	}
	password, err := os.ReadFile(passwordFile)
	if err != nil {
		return fmt.Errorf("fake openvpn: %w", err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:"+port)
	if err != nil {
		return fmt.Errorf("fake openvpn: %w", err)
	}
	process.onKill = func() { listener.Close() }
	go func() {
		defer listener.Close()
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		write := func(line string) { conn.Write([]byte(line + "\r\n")) }
		conn.Write([]byte("ENTER PASSWORD:"))
		reader := bufio.NewReader(conn)
		received, err := reader.ReadString('\n')
		if err != nil || strings.TrimSpace(received) != strings.TrimSpace(string(password)) {
			write("ERROR: bad password")
			return
		}
		write("SUCCESS: password is correct")
		write(">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info")
		write(">HOLD:Waiting for hold release:0")
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				return
			}
			switch strings.TrimSpace(line) {
			case "hold release":
				write("SUCCESS: hold release succeeded")
				write(">LOG:1787840212,,MANAGEMENT: >STATE:1787840212,WAIT,,,,,,")
				write(">STATE:1787840212,WAIT,,,,,,")
				write(">LOG:1787840212,I,ovpn-dco device [" + adapterOf(spec) + "] opened")
				write(">LOG:1787840213,I,PUSH: Received control message: 'PUSH_REPLY,route-gateway 10.8.0.1,dhcp-option DNS 10.8.0.1,ifconfig 10.8.0.27 255.255.255.0'")
				write(">LOG:1787840213,W,Options error: option 'route' cannot be used in this context ([PUSH-OPTIONS])")
				write(">STATE:1787840213,CONNECTED,SUCCESS,10.8.0.27,203.0.113.1,1194,,")
			case "signal SIGTERM":
				write("SUCCESS: signal SIGTERM thrown")
				write(">STATE:1787840300,EXITING,SIGTERM,,,,,")
				conn.Close()
				process.exit(0)
				return
			default:
				write("SUCCESS: ok")
			}
		}
	}()
	return nil
}

func adapterOf(spec ProcessSpec) string {
	for index, arg := range spec.Args {
		if arg == "--dev-node" && index+1 < len(spec.Args) {
			return spec.Args[index+1]
		}
	}
	return ""
}

type fakeNetwork struct {
	mu       sync.Mutex
	adapters map[string]bool
	ensured  [][]string
	cleanups int
	routes   map[string]string
	tunUp    bool
}

func newFakeNetwork() *fakeNetwork {
	return &fakeNetwork{adapters: map[string]bool{}, routes: map[string]string{}, tunUp: true}
}

func (n *fakeNetwork) AdapterPresent(name string) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	if name == core.TUNAdapterName {
		return n.tunUp
	}
	return n.adapters[name]
}

func (n *fakeNetwork) EnsureAdapters(_ context.Context, names []string) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.ensured = append(n.ensured, names)
	for _, name := range names {
		n.adapters[name] = true
	}
	return nil
}

func (n *fakeNetwork) CleanupAdapters(context.Context) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.cleanups++
	return nil
}

func (n *fakeNetwork) AddScopedDefault(adapter, gateway string) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.routes[adapter] = gateway
	return nil
}

func (n *fakeNetwork) DeleteScopedDefault(adapter string) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	delete(n.routes, adapter)
	return nil
}

func (n *fakeNetwork) RouteInterface(string) (string, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.tunUp {
		return core.TUNAdapterName, nil
	}
	return "Ethernet", nil
}

func (n *fakeNetwork) Diagnostics(context.Context) string { return "routes" }

func (n *fakeNetwork) route(adapter string) (string, bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	gateway, ok := n.routes[adapter]
	return gateway, ok
}

type fakeResolver struct {
	mu     sync.Mutex
	rules  []core.NRPTRule
	next   int
	probes bool
}

func (r *fakeResolver) Snapshot(context.Context) (core.ResolverSnapshot, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return core.ResolverSnapshot{Rules: append([]core.NRPTRule(nil), r.rules...)}, nil
}

func (r *fakeResolver) AddRule(_ context.Context, rule core.NRPTRule) (core.NRPTRule, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.next++
	rule.Name = fmt.Sprintf("{%08d-0000-4000-8000-000000000000}", r.next)
	r.rules = append(r.rules, rule)
	return rule, nil
}

func (r *fakeResolver) RemoveRules(_ context.Context, names []string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	kept := r.rules[:0]
	for _, rule := range r.rules {
		if !contains(names, rule.Name) {
			kept = append(kept, rule)
		}
	}
	r.rules = kept
	return nil
}

func (r *fakeResolver) Probe(context.Context, string) bool { return r.probes }

func (r *fakeResolver) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.rules)
}

// eventually polls `condition` for up to five seconds.
func eventually(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func testEnvironment(t *testing.T) Environment {
	t.Helper()
	root := t.TempDir()
	env := Environment{
		ExecutablePath: root + "/wayfork-service", InstallDir: root, Version: "0.1.0-test",
		Layout: core.DefaultLayout(root),
	}
	if err := env.PrepareDirectories(); err != nil {
		t.Fatal(err)
	}
	return env
}

func testPlan(openVPN []core.OpenVPNRuntime, ruleSets map[string]string, config string) core.RuntimePlan {
	if ruleSets == nil {
		ruleSets = map[string]string{}
	}
	return core.RuntimePlan{
		Version: core.PlanVersion,
		SingBox: core.SingBoxPlan{Config: config, ConfigHash: core.SHA256Hex(config), RuleSets: ruleSets},
		OpenVPN: openVPN, AutoReconnect: true, LogLevel: core.LogLevelInfo, OverrideSystemDNS: true,
	}
}

const tunnelA = "00000000-0000-4000-8000-000000000001"

func tunnelRuntime(id, adapter string) core.OpenVPNRuntime {
	config := "client\nremote <SERVER> 1194\n"
	return core.OpenVPNRuntime{ID: id, Interface: adapter, Config: config, ConfigHash: core.ComputeOpenVPNConfigHash(config, nil, nil)}
}
