package service

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"wayfork/service/internal/core"
)

type recordingSink struct {
	mu       sync.Mutex
	statuses []core.RuntimeStatus
	lines    []core.LogLine
	traffic  int
}

func (s *recordingSink) StatusChanged(status core.RuntimeStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.statuses = append(s.statuses, status)
}

func (s *recordingSink) LogLines(lines []core.LogLine) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lines = append(s.lines, lines...)
}

func (s *recordingSink) TrafficChanged(core.TrafficSnapshot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.traffic++
}

func (s *recordingSink) messages() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.lines))
	for _, line := range s.lines {
		out = append(out, line.Source+": "+line.Message)
	}
	return out
}

func newTestSupervisor(t *testing.T) (*Supervisor, *Hub, *fakeRunner, *fakeNetwork, *fakeResolver, Environment) {
	t.Helper()
	env := testEnvironment(t)
	hub := NewHub(env.Layout.LogDir, nil)
	runner := &fakeRunner{}
	network := newFakeNetwork()
	resolver := &fakeResolver{probes: true}
	supervisor := NewSupervisor(env, hub, Dependencies{Processes: runner, Network: network, Resolver: resolver})
	// The startup verification window at millisecond scale (H1).
	supervisor.engine.startupGrace = 30 * time.Millisecond
	supervisor.engine.startupPoll = 10 * time.Millisecond
	supervisor.engine.startupTimeout = 200 * time.Millisecond
	t.Cleanup(func() { supervisor.Shutdown(context.Background()) })
	return supervisor, hub, runner, network, resolver, env
}

func TestApplyBringsEverythingUpAndStopTearsItDown(t *testing.T) {
	supervisor, hub, runner, network, resolver, env := newTestSupervisor(t)
	ctx := context.Background()
	sink := &recordingSink{}
	supervisor.Bootstrap(ctx)
	supervisor.Subscribe(ctx, sink)
	if network.cleanups != 1 {
		t.Errorf("bootstrap cleaned up %d times", network.cleanups)
	}

	plan := testPlan([]core.OpenVPNRuntime{tunnelRuntime(tunnelA, "Wayfork-1")},
		map[string]string{core.DirectRuleSet: `{"rules":[],"version":3}`, core.RuleSet(tunnelA): `{"rules":[{"domain":["example.com"]}],"version":3}`},
		`{"log":{"level":"info"}}`)
	result := supervisor.Apply(ctx, plan)
	if !result.OK {
		t.Fatalf("apply = %+v", result)
	}
	status := supervisor.GetStatus(ctx)
	if !status.Engine.IsRunning() || status.PlanHash != plan.PlanHash() {
		t.Errorf("status after apply = %+v", status)
	}
	// The config was checked with the Clash API injected, then installed.
	installed, err := os.ReadFile(env.RunPath(core.SingBoxConfig))
	if err != nil || !strings.Contains(string(installed), `"clash_api"`) || !strings.Contains(string(installed), `"level": "info"`) {
		t.Errorf("installed config = %s, %v", installed, err)
	}
	if _, err := os.Stat(env.RunPath(core.RuleSet(tunnelA))); err != nil {
		t.Error("rule-set not written")
	}
	if len(network.ensured) != 1 || len(network.ensured[0]) != 1 || network.ensured[0][0] != "Wayfork-1" {
		t.Errorf("adapters ensured = %v", network.ensured)
	}
	singBox := runner.started("sing-box")
	if len(singBox) != 1 || singBox[0].Args[0] != "run" || singBox[0].WorkingDir != env.Layout.Dir {
		t.Errorf("sing-box spawned as %+v", singBox)
	}

	// The tunnel connects through the fake management channel.
	eventually(t, "tunnel connected", func() bool {
		return supervisor.GetStatus(ctx).Tunnels[tunnelA].IsConnected()
	})
	eventually(t, "scoped route", func() bool {
		gateway, ok := network.route("Wayfork-1")
		return ok && gateway == "10.8.0.1"
	})
	eventually(t, "discovered DNS", func() bool {
		servers := supervisor.GetStatus(ctx).DiscoveredDNS[tunnelA]
		return len(servers) == 1 && servers[0] == "10.8.0.1"
	})
	eventually(t, "resolver override", func() bool {
		return supervisor.GetStatus(ctx).ResolverOverride.Kind == core.ResolverOverrideActive && resolver.count() == 1
	})
	if _, err := os.Stat(env.RunPath(core.ResolverOverrideRecordFile)); err != nil {
		t.Error("resolver record not written")
	}
	openvpn := runner.started("openvpn")
	if len(openvpn) != 1 || !contains(openvpn[0].Args, "--dev-node") || !contains(openvpn[0].Args, "Wayfork-1") {
		t.Errorf("openvpn spawned as %+v", openvpn)
	}
	hub.Flush()
	messages := sink.messages()
	joined := strings.Join(messages, "\n")
	for _, want := range []string{"sing-box started (pid", "openvpn:" + tunnelA + ": connected (10.8.0.27 on Wayfork-1)", "system resolver → 172.19.0.2 via NRPT"} {
		if !strings.Contains(joined, want) {
			t.Errorf("log lacks %q:\n%s", want, joined)
		}
	}
	// Usernames never reach the log: the CMD echoes were dropped by the parser.
	if strings.Contains(joined, "MANAGEMENT: >STATE") {
		t.Error("echoed state lines leaked into the log")
	}

	// Same plan again: a no-op, nothing restarts.
	if result := supervisor.Apply(ctx, plan); !result.OK {
		t.Fatalf("re-apply = %+v", result)
	}
	if len(runner.started("sing-box")) != 1 || len(runner.started("openvpn")) != 1 {
		t.Error("an unchanged plan restarted children")
	}

	// A rule-set edit is rewritten in place.
	edited := testPlan(plan.OpenVPN, map[string]string{core.DirectRuleSet: plan.SingBox.RuleSets[core.DirectRuleSet], core.RuleSet(tunnelA): `{"rules":[{"domain":["example.com","2ip.io"]}],"version":3}`}, plan.SingBox.Config)
	if result := supervisor.Apply(ctx, edited); !result.OK {
		t.Fatalf("edit apply = %+v", result)
	}
	if len(runner.started("sing-box")) != 1 {
		t.Error("a rule-set edit restarted sing-box")
	}
	if data, _ := os.ReadFile(env.RunPath(core.RuleSet(tunnelA))); !strings.Contains(string(data), "2ip.io") {
		t.Error("rule-set not rewritten")
	}

	// Stop: children gone, route and NRPT rule removed, run\ wiped but cache kept.
	os.WriteFile(env.RunPath(core.CacheFile), []byte("cache"), 0o600)
	if result := supervisor.Stop(ctx); !result.OK {
		t.Fatalf("stop = %+v", result)
	}
	status = supervisor.GetStatus(ctx)
	if status.Engine.Kind != core.EngineStopped || len(status.Tunnels) != 0 || status.PlanHash != "" {
		t.Errorf("status after stop = %+v", status)
	}
	if _, ok := network.route("Wayfork-1"); ok {
		t.Error("scoped route survived stop")
	}
	if resolver.count() != 0 || status.ResolverOverride.Kind != core.ResolverOverrideOff {
		t.Errorf("NRPT after stop: %d rules, state %+v", resolver.count(), status.ResolverOverride)
	}
	entries, _ := os.ReadDir(env.Layout.Dir)
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	if len(names) != 1 || names[0] != core.CacheFile {
		t.Errorf("run dir after stop = %v", names)
	}
	select {
	case <-runner.latest("openvpn").Exited():
	default:
		t.Error("openvpn still running after stop")
	}
	hub.Flush()
	if got := sink.statuses; len(got) < 3 {
		t.Errorf("only %d status pushes", len(got))
	}
}

func TestApplyReportsCheckAndStartupFailures(t *testing.T) {
	supervisor, _, runner, network, _, _ := newTestSupervisor(t)
	ctx := context.Background()
	supervisor.Bootstrap(ctx)

	runner.checkFails = "FATAL[0000] decode config: invalid"
	result := supervisor.Apply(ctx, testPlan(nil, nil, `{"log":{}}`))
	if result.OK || result.Error == nil || result.Error.Kind != core.DaemonConfigInvalid || !strings.Contains(result.Error.Output, "decode config") {
		t.Errorf("check failure = %+v", result)
	}
	if len(runner.started("sing-box")) != 0 {
		t.Error("sing-box was started despite a failed check")
	}

	runner.checkFails = ""
	network.tunUp = false
	result = supervisor.Apply(ctx, testPlan(nil, nil, `{"log":{}}`))
	if result.OK || result.Error == nil || result.Error.Kind != core.DaemonStartFailed || !strings.Contains(strings.Join(result.Error.LogTail, "\n"), "did not come up") {
		t.Errorf("startup failure = %+v", result)
	}
	// The adapter never came up, so the start was tried twice before giving up (H1).
	if got := len(runner.started("sing-box")); got != 2 {
		t.Errorf("%d sing-box start(s) before startFailed, want 2", got)
	}
	if status := supervisor.GetStatus(ctx); status.Engine.Kind != core.EngineFailed {
		t.Errorf("engine after startup failure = %+v", status.Engine)
	}
	select {
	case <-runner.latest("sing-box").Exited():
	default:
		t.Error("the failed sing-box was not terminated")
	}

	// A plan that dies during startup.
	network.tunUp = true
	runner.singBoxDies = true
	result = supervisor.Apply(ctx, testPlan(nil, nil, `{"log":{"level":"debug"}}`))
	if result.OK || result.Error == nil || result.Error.Kind != core.DaemonStartFailed {
		t.Errorf("exit during startup = %+v", result)
	}
	// An invalid plan never reaches the engine.
	bad := testPlan([]core.OpenVPNRuntime{tunnelRuntime(tunnelA, "utun101")}, nil, "{}")
	if result := supervisor.Apply(ctx, bad); result.OK || result.Error.Kind != core.DaemonPlanInvalid {
		t.Errorf("invalid plan = %+v", result)
	}
}

// H1: a slow TUN bring-up is a healthy start, not a failure — the check repeats until the
// adapter is there, without a second sing-box (docs/design/03-routing.md).
func TestStartupVerificationWaitsForASlowAdapter(t *testing.T) {
	supervisor, _, runner, network, _, _ := newTestSupervisor(t)
	ctx := context.Background()
	supervisor.Bootstrap(ctx)
	supervisor.engine.startupTimeout = 2 * time.Second

	network.tunUp = false
	timer := time.AfterFunc(80*time.Millisecond, func() { network.setTunUp(true) })
	defer timer.Stop()
	result := supervisor.Apply(ctx, testPlan(nil, nil, `{"log":{}}`))
	if !result.OK {
		t.Fatalf("apply with a slow adapter = %+v", result)
	}
	if status := supervisor.GetStatus(ctx); !status.Engine.IsRunning() {
		t.Errorf("engine after a slow adapter = %+v", status.Engine)
	}
	if got := len(runner.started("sing-box")); got != 1 {
		t.Errorf("%d sing-box start(s) for a slow adapter, want 1", got)
	}
}

// A sing-box that never logs its "started" line is checked once the grace period is over.
func TestStartupVerifiesASilentSingBoxAfterTheGrace(t *testing.T) {
	supervisor, _, runner, _, _, _ := newTestSupervisor(t)
	ctx := context.Background()
	supervisor.Bootstrap(ctx)

	runner.singBoxSilent = true
	if result := supervisor.Apply(ctx, testPlan(nil, nil, `{"log":{}}`)); !result.OK {
		t.Fatalf("apply with a silent sing-box = %+v", result)
	}
	if status := supervisor.GetStatus(ctx); !status.Engine.IsRunning() {
		t.Errorf("engine after a silent start = %+v", status.Engine)
	}
}

// H1: when the window does run out, the start is worth one more attempt.
func TestStartupRetriesOnceAndSucceeds(t *testing.T) {
	supervisor, hub, runner, network, _, _ := newTestSupervisor(t)
	ctx := context.Background()
	sink := &recordingSink{}
	supervisor.Bootstrap(ctx)
	supervisor.Subscribe(ctx, sink)

	network.tunUp = false
	runner.onSingBoxStart = func(spawn int) {
		if spawn == 2 {
			network.setTunUp(true)
		}
	}
	result := supervisor.Apply(ctx, testPlan(nil, nil, `{"log":{}}`))
	if !result.OK {
		t.Fatalf("apply that needed a retry = %+v", result)
	}
	if got := len(runner.started("sing-box")); got != 2 {
		t.Errorf("%d sing-box start(s), want 2", got)
	}
	if status := supervisor.GetStatus(ctx); !status.Engine.IsRunning() {
		t.Errorf("engine after the retry = %+v", status.Engine)
	}
	hub.Flush()
	if joined := strings.Join(sink.messages(), "\n"); !strings.Contains(joined, "starting sing-box once more") {
		t.Errorf("the retry is not in the log:\n%s", joined)
	}
}

// H1: a stop must not wait out the verification window of a doomed start.
func TestStopAbortsAStartThatIsStillVerifying(t *testing.T) {
	supervisor, _, runner, network, _, _ := newTestSupervisor(t)
	ctx := context.Background()
	supervisor.Bootstrap(ctx)
	supervisor.engine.startupTimeout = 30 * time.Second

	network.tunUp = false
	applied := make(chan core.ApplyResult, 1)
	go func() { applied <- supervisor.Apply(ctx, testPlan(nil, nil, `{"log":{}}`)) }()
	eventually(t, "sing-box spawned", func() bool { return len(runner.started("sing-box")) == 1 })

	stopped := make(chan time.Duration, 1)
	go func() {
		start := time.Now()
		supervisor.Stop(ctx)
		stopped <- time.Since(start)
	}()
	select {
	case took := <-stopped:
		if took > 5*time.Second {
			t.Errorf("stop waited %s for the verification window", took)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("stop is still waiting for the startup verification")
	}
	<-applied
	if status := supervisor.GetStatus(ctx); status.Engine.Kind != core.EngineStopped {
		t.Errorf("engine after the aborted start = %+v", status.Engine)
	}
	select {
	case <-runner.latest("sing-box").Exited():
	default:
		t.Error("the abandoned sing-box was left running")
	}
}

func TestReconnectAndInfoAndDiagnostics(t *testing.T) {
	supervisor, _, runner, _, _, env := newTestSupervisor(t)
	ctx := context.Background()
	supervisor.Bootstrap(ctx)
	if result := supervisor.Reconnect(ctx, tunnelA); result.OK || result.Error.Kind != core.DaemonTunnelNotFound {
		t.Errorf("reconnect of an unknown tunnel = %+v", result)
	}
	plan := testPlan([]core.OpenVPNRuntime{tunnelRuntime(tunnelA, "Wayfork-1")}, nil, `{"log":{}}`)
	if result := supervisor.Apply(ctx, plan); !result.OK {
		t.Fatalf("apply = %+v", result)
	}
	eventually(t, "tunnel connected", func() bool { return supervisor.GetStatus(ctx).Tunnels[tunnelA].IsConnected() })
	first := runner.latest("openvpn")
	if result := supervisor.Reconnect(ctx, tunnelA); !result.OK {
		t.Fatalf("reconnect = %+v", result)
	}
	eventually(t, "respawn", func() bool { return len(runner.started("openvpn")) == 2 })
	select {
	case <-first.Exited():
	default:
		t.Error("the old openvpn was not terminated")
	}
	eventually(t, "tunnel reconnected", func() bool {
		return runner.latest("openvpn") != first && supervisor.GetStatus(ctx).Tunnels[tunnelA].IsConnected()
	})

	info := supervisor.GetInfo(ctx)
	if info.SingBoxVersion != "1.13.19" || info.OpenVPNVersion != "2.7.6" || info.InstallPath != env.InstallDir || info.Version != "0.1.0-test" {
		t.Errorf("info = %+v", info)
	}
	diagnostics := supervisor.CollectDiagnostics(ctx)
	if diagnostics.Routes != "routes" || len(diagnostics.DaemonLogTail) == 0 || !contains(diagnostics.RunDirectoryListing, "sing-box.json "+itoa(int64(len(mustRead(t, env.RunPath(core.SingBoxConfig)))))) {
		t.Errorf("diagnostics = %+v", diagnostics)
	}
	if _, ok := diagnostics.ChildLogTails["openvpn-"+tunnelA]; !ok {
		t.Errorf("child tails = %v", diagnostics.ChildLogTails)
	}
}

func TestHubBatchesAndReplays(t *testing.T) {
	hub := NewHub(t.TempDir(), nil)
	defer hub.Close()
	hub.Log(core.LogLevelInfo, "one")
	hub.PostFrom("sing-box", core.LogLevelWarning, "two")
	sink := &recordingSink{}
	hub.Subscribe(sink)
	if got := sink.messages(); len(got) != 2 || got[0] != "daemon: one" || got[1] != "sing-box: two" {
		t.Errorf("replay = %q", got)
	}
	hub.SetStatus(core.RuntimeStatus{Engine: core.NewEngineStarting()})
	hub.SetStatus(core.RuntimeStatus{Engine: core.NewEngineRunning(time.Now())})
	hub.Log(core.LogLevelInfo, "three")
	time.Sleep(2 * hubBatchInterval)
	sink.mu.Lock()
	statuses, lines := len(sink.statuses), len(sink.lines)
	sink.mu.Unlock()
	if statuses != 2 || lines != 3 {
		t.Errorf("after coalescing: %d statuses, %d lines", statuses, lines)
	}
	tails := hub.Tails(10)
	if len(tails["daemon"]) != 2 || !strings.HasSuffix(tails["daemon"][1], "INFO three") {
		t.Errorf("tails = %v", tails)
	}
	hub.Unsubscribe(sink)
	hub.PushTraffic(core.TrafficSnapshot{})
	if sink.traffic != 0 {
		t.Error("an unsubscribed sink received traffic")
	}
	if listing := RunListing(filepath.Join(t.TempDir(), "missing")); len(listing) != 0 {
		t.Errorf("listing of a missing dir = %v", listing)
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
