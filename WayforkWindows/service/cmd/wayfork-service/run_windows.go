//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"

	"wayfork/service/internal/core"
	"wayfork/service/internal/ipc"
	"wayfork/service/internal/service"
	"wayfork/service/internal/winnet"
	"wayfork/service/internal/winproc"
)

// ServiceName is the SCM name (docs/design/08-windows.md, "Installer").
const ServiceName = "Wayfork"

func run(args []string) error {
	// The subcommands come first: the installer's custom actions run as LocalSystem in
	// session 0, where IsWindowsService can read as true.
	switch {
	case len(args) == 2 && args[0] == "--dev-apply":
		return devApply(args[1])
	case len(args) == 1 && args[0] == "--install-driver":
		return installDriver()
	case len(args) == 1 && args[0] == "--uninstall-cleanup":
		return uninstallCleanup()
	}
	if len(args) > 0 {
		return errors.New("usage: wayfork-service [--dev-apply <plan.json> | --install-driver | " +
			"--uninstall-cleanup] (without arguments it runs as the Wayfork service)")
	}
	inService, err := svc.IsWindowsService()
	if err != nil {
		return err
	}
	if !inService {
		return errors.New("usage: wayfork-service [--dev-apply <plan.json> | --install-driver | " +
			"--uninstall-cleanup] (without arguments it runs as the Wayfork service)")
	}
	return svc.Run(ServiceName, &handler{})
}

// runtime is everything the service host wires together.
type runtime struct {
	env        service.Environment
	hub        *service.Hub
	runner     *winproc.Runner
	validator  *winnet.Validator
	supervisor *service.Supervisor
	listener   *ipc.PipeListener
}

// installerEnvironment is the path half of the environment: where the payload sits and
// where the service keeps its runtime files. The installer subcommands need nothing else.
func installerEnvironment() (service.Environment, error) {
	executable, err := os.Executable()
	if err != nil {
		return service.Environment{}, err
	}
	executable, _ = filepath.EvalSymlinks(executable)
	programData := os.Getenv("ProgramData")
	if programData == "" {
		programData = `C:\ProgramData`
	}
	return service.Environment{
		ExecutablePath: executable, InstallDir: filepath.Dir(executable),
		Version: service.Version, Layout: core.DefaultLayout(programData),
	}, nil
}

func buildRuntime(devMode bool, mirror func(core.LogLine)) (*runtime, error) {
	env, err := installerEnvironment()
	if err != nil {
		return nil, err
	}
	env.BuildID = buildID(env.ExecutablePath)
	env.DevMode = devMode
	if err := env.PrepareDirectories(); err != nil {
		return nil, fmt.Errorf("preparing %s: %w", env.Layout.Dir, err)
	}
	hub := service.NewHub(env.Layout.LogDir, nil)
	hub.Mirror = mirror
	for _, directory := range []string{env.Layout.Dir, env.Layout.LogDir} {
		if err := winnet.SecureDirectory(directory); err != nil {
			hub.Log(core.LogLevelWarning, "cannot restrict "+directory+": "+err.Error())
		}
	}
	runner, err := winproc.NewRunner()
	if err != nil {
		return nil, err
	}
	validator := &winnet.Validator{InstallDir: env.InstallDir}
	deps := service.Dependencies{
		Processes: runner, Network: winnet.NewNetwork(env.TapctlPath(), runner),
		Resolver: winnet.NewResolver(runner), Binaries: validator,
	}
	return &runtime{
		env: env, hub: hub, runner: runner, validator: validator,
		supervisor: service.NewSupervisor(env, hub, deps),
	}, nil
}

// buildID identifies this build: the SHA-256 of the executable (the app compares it
// with the value it shipped, docs/design/08-windows.md "IPC").
func buildID(executable string) string {
	data, err := os.ReadFile(executable)
	if err != nil {
		return ""
	}
	return core.SHA256Hex(string(data))
}

// serve accepts pipe clients until ctx ends; every client image is verified first.
func (r *runtime) serve(ctx context.Context) error {
	listener, err := ipc.ListenPipe(ipc.PipeName)
	if err != nil {
		return err
	}
	r.listener = listener
	go func() {
		<-ctx.Done()
		listener.Close()
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			r.hub.Log(core.LogLevelWarning, "pipe accept: "+err.Error())
			time.Sleep(time.Second)
			continue
		}
		if reason := r.verifyClient(conn.ClientPID); reason != "" {
			r.hub.Log(core.LogLevelWarning, fmt.Sprintf("rejecting client pid %d: %s", conn.ClientPID, reason))
			conn.Close()
			continue
		}
		r.hub.Log(core.LogLevelInfo, fmt.Sprintf("client pid %d connected", conn.ClientPID))
		go func() {
			_ = ipc.ServeConn(ctx, conn, r.supervisor, r.env.Version)
			r.hub.Log(core.LogLevelInfo, fmt.Sprintf("client pid %d disconnected", conn.ClientPID))
		}()
	}
}

// verifyClient is the counterpart of the macOS code-signing requirement: the client
// must be an Authenticode-signed executable inside the install directory.
func (r *runtime) verifyClient(pid uint32) string {
	if r.env.DevMode {
		return ""
	}
	path, err := winnet.ClientImagePath(pid)
	if err != nil {
		return "cannot resolve the client image: " + err.Error()
	}
	if err := r.validator.Validate(path); err != nil {
		return "untrusted client " + path
	}
	return ""
}

func (r *runtime) shutdown() {
	if r.listener != nil {
		r.listener.Close()
	}
	r.supervisor.Shutdown(context.Background())
	r.runner.Close()
}

// handler is the SCM side: start idle, serve the pipe, stop restores networking.
type handler struct{}

func (h *handler) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}
	log, _ := eventlog.Open(ServiceName)
	if log != nil {
		defer log.Close()
	}
	mirror := func(line core.LogLine) {
		if log == nil || line.Source != service.DaemonSource {
			return
		}
		switch line.Level {
		case core.LogLevelError:
			_ = log.Error(1, line.Message)
		case core.LogLevelWarning:
			_ = log.Warning(1, line.Message)
		}
	}
	r, err := buildRuntime(false, mirror)
	if err != nil {
		if log != nil {
			_ = log.Error(1, "cannot start: "+err.Error())
		}
		return false, 1
	}
	if log != nil {
		_ = log.Info(1, "Wayfork service "+r.env.Version+" starting")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r.supervisor.Bootstrap(ctx)
	var served sync.WaitGroup
	served.Add(1)
	go func() {
		defer served.Done()
		if err := r.serve(ctx); err != nil {
			r.hub.Log(core.LogLevelError, "pipe: "+err.Error())
		}
	}()
	changes <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for request := range requests {
		switch request.Cmd {
		case svc.Interrogate:
			changes <- request.CurrentStatus
		case svc.Stop, svc.Shutdown:
			changes <- svc.Status{State: svc.StopPending, WaitHint: 30_000}
			cancel()
			r.shutdown()
			served.Wait()
			if log != nil {
				_ = log.Info(1, "Wayfork service stopped")
			}
			return false, 0
		}
	}
	return false, 0
}

// devApply runs the supervisor from a console without the SCM or the app: applies the
// plan, re-applies whenever the file changes, prints status and log lines, and serves
// the pipe for wayforkctl. Binaries and clients are not trust-checked; the plan file
// contains secrets — keep it administrator-only and delete it afterwards
// (docs/design/05-daemon.md, "Developer mode").
func devApply(planPath string) error {
	console := func(line core.LogLine) {
		fmt.Fprintf(os.Stderr, "[%s] %s %s\n", line.Source, strings.ToUpper(string(line.Level)), line.Message)
	}
	r, err := buildRuntime(true, console)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt)
	r.supervisor.Bootstrap(ctx)
	r.supervisor.Subscribe(ctx, &consoleSink{})
	go func() {
		if err := r.serve(ctx); err != nil {
			fmt.Fprintln(os.Stderr, "pipe:", err)
		}
	}()
	var lastModified time.Time
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		info, err := os.Stat(planPath)
		switch {
		case err != nil && lastModified.IsZero():
			fmt.Fprintln(os.Stderr, "waiting for", planPath)
			lastModified = time.Unix(1, 0)
		case err == nil && !info.ModTime().Equal(lastModified):
			lastModified = info.ModTime()
			data, err := os.ReadFile(planPath)
			var plan core.RuntimePlan
			if err == nil {
				err = decodePlan(data, &plan)
			}
			if err != nil {
				fmt.Fprintln(os.Stderr, "cannot read plan:", err)
				break
			}
			fmt.Fprintf(os.Stderr, "apply %s (planHash %s)\n", planPath, plan.PlanHash()[:12])
			result := r.supervisor.Apply(ctx, plan)
			encoded, _ := core.MarshalWire(result)
			fmt.Fprintf(os.Stderr, "apply → %s\n", encoded)
		}
		select {
		case <-ticker.C:
		case <-interrupt:
			fmt.Fprintln(os.Stderr, "stopping")
			cancel()
			r.shutdown()
			return nil
		}
	}
}

func decodePlan(data []byte, plan *core.RuntimePlan) error {
	return json.Unmarshal(data, plan)
}

// consoleSink prints status and traffic pushes; log lines come through the mirror.
type consoleSink struct{}

func (consoleSink) StatusChanged(status core.RuntimeStatus) {
	lines := []string{"status: engine=" + string(status.Engine.Kind)}
	if status.Engine.Reason != "" {
		lines[0] += " (" + status.Engine.Reason + ")"
	}
	for id, state := range status.Tunnels {
		lines = append(lines, fmt.Sprintf("  %s %s %s", id[:8], state.Kind, state.Reason))
	}
	for id, servers := range status.DiscoveredDNS {
		lines = append(lines, fmt.Sprintf("  %s dns=%v", id[:8], servers))
	}
	lines = append(lines, "  resolver="+string(status.ResolverOverride.Kind)+" "+status.ResolverOverride.Reason)
	fmt.Fprintln(os.Stderr, strings.Join(lines, "\n"))
}

func (consoleSink) LogLines([]core.LogLine) {}

func (consoleSink) TrafficChanged(snapshot core.TrafficSnapshot) {
	parts := []string{"traffic:"}
	for id, counters := range snapshot.Tunnels {
		parts = append(parts, fmt.Sprintf("%s ↓%.0f ↑%.0f B/s (%d conn)", id[:8], counters.DownBytesPerSecond, counters.UpBytesPerSecond, counters.Connections))
	}
	parts = append(parts, fmt.Sprintf("direct ↓%.0f ↑%.0f B/s (%d conn)", snapshot.Direct.DownBytesPerSecond, snapshot.Direct.UpBytesPerSecond, snapshot.Direct.Connections))
	fmt.Fprintln(os.Stderr, strings.Join(parts, "  "))
}
