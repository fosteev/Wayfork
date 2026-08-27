//go:build windows

package winnet

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"wayfork/service/internal/service"
)

// PowerShellPath is Windows PowerShell 5.1, present on every supported Windows.
func PowerShellPath() string {
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	return filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
}

// RunPowerShell runs one script (no profile, non-interactive) and returns its output.
// Scripts are constants with validated substitutions only; nothing user-supplied is ever
// interpolated.
func RunPowerShell(ctx context.Context, runner service.ProcessRunner, script string) (string, error) {
	runCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	result, err := runner.Run(runCtx, service.ProcessSpec{
		Executable: PowerShellPath(),
		Args:       []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script},
	})
	if err != nil {
		return "", err
	}
	if !result.Succeeded() {
		return result.Output(), fmt.Errorf("powershell exited with %d: %s", result.ExitCode, result.Output())
	}
	return result.Output(), nil
}
