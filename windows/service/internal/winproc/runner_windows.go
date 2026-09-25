//go:build windows

package winproc

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"wayfork/service/internal/core"
	"wayfork/service/internal/service"
)

// Runner spawns children detached and inside a job object with KILL_ON_JOB_CLOSE, so
// they die with the service no matter how it exits (docs/design/08-windows.md,
// "Components and trust boundary"; spike S8).
type Runner struct {
	job windows.Handle
}

// NewRunner creates the job object.
func NewRunner() (*Runner, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, fmt.Errorf("creating the job object: %w", err)
	}
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		windows.CloseHandle(job)
		return nil, fmt.Errorf("configuring the job object: %w", err)
	}
	return &Runner{job: job}, nil
}

// Close closes the job handle — which kills every child still inside it.
func (r *Runner) Close() {
	if r.job != 0 {
		windows.CloseHandle(r.job)
		r.job = 0
	}
}

var _ service.ProcessRunner = (*Runner)(nil)

type process struct {
	cmd      *exec.Cmd
	started  time.Time
	exited   chan struct{}
	exitCode uint32
}

func (p *process) PID() int                { return p.cmd.Process.Pid }
func (p *process) StartedAt() time.Time    { return p.started }
func (p *process) Exited() <-chan struct{} { return p.exited }

func (p *process) Terminate(timeout time.Duration) uint32 {
	select {
	case <-p.exited:
		return p.exitCode
	case <-time.After(timeout):
	}
	_ = p.cmd.Process.Kill()
	<-p.exited
	return p.exitCode
}

func command(ctx context.Context, spec service.ProcessSpec) *exec.Cmd {
	var cmd *exec.Cmd
	if ctx != nil {
		cmd = exec.CommandContext(ctx, spec.Executable, spec.Args...)
	} else {
		cmd = exec.Command(spec.Executable, spec.Args...)
	}
	cmd.Dir = spec.WorkingDir
	// Detached: a child that inherits a console dies with the launching session; the
	// service has no console anyway, and no window may ever pop up.
	cmd.SysProcAttr = &windows.SysProcAttr{
		CreationFlags: windows.CREATE_NO_WINDOW | windows.CREATE_NEW_PROCESS_GROUP,
		HideWindow:    true,
	}
	return cmd
}

// Start implements service.ProcessRunner.
func (r *Runner) Start(spec service.ProcessSpec, handlers service.ProcessHandlers) (service.Process, error) {
	cmd := command(nil, spec)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	if err := r.assign(cmd.Process.Pid); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, err
	}
	p := &process{cmd: cmd, started: time.Now(), exited: make(chan struct{})}
	var lines sync.WaitGroup
	lines.Add(1)
	go func() {
		defer lines.Done()
		readLines(stdout, handlers.OnLine)
	}()
	go func() {
		lines.Wait()
		err := cmd.Wait()
		p.exitCode = exitCode(err)
		if handlers.OnExit != nil {
			handlers.OnExit(p.exitCode)
		}
		close(p.exited)
	}()
	return p, nil
}

func (r *Runner) assign(pid int) error {
	handle, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return fmt.Errorf("opening pid %d for the job object: %w", pid, err)
	}
	defer windows.CloseHandle(handle)
	if err := windows.AssignProcessToJobObject(r.job, handle); err != nil {
		return fmt.Errorf("assigning pid %d to the job object: %w", pid, err)
	}
	return nil
}

func readLines(reader io.Reader, onLine func(string)) {
	splitter := &core.LineSplitter{}
	buffered := bufio.NewReaderSize(reader, 64*1024)
	chunk := make([]byte, 16*1024)
	for {
		n, err := buffered.Read(chunk)
		if n > 0 {
			for _, line := range splitter.Append(chunk[:n]) {
				if onLine != nil {
					onLine(line)
				}
			}
		}
		if err != nil {
			if rest, ok := splitter.Flush(); ok && onLine != nil {
				onLine(rest)
			}
			return
		}
	}
}

func exitCode(err error) uint32 {
	if err == nil {
		return 0
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return uint32(exit.ExitCode())
	}
	return 1
}

// Run implements service.ProcessRunner: a helper to completion, killed when ctx ends.
func (r *Runner) Run(ctx context.Context, spec service.ProcessSpec) (service.CommandResult, error) {
	cmd := command(ctx, spec)
	output, err := cmd.CombinedOutput()
	result := service.CommandResult{Lines: []string{}}
	splitter := &core.LineSplitter{}
	result.Lines = append(result.Lines, splitter.Append(output)...)
	if rest, ok := splitter.Flush(); ok {
		result.Lines = append(result.Lines, rest)
	}
	if ctx.Err() != nil {
		result.TimedOut = true
		result.ExitCode = 1
		return result, nil
	}
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			return result, err
		}
		result.ExitCode = uint32(exit.ExitCode())
	}
	return result, nil
}
