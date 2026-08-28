// Package service is the privileged half of the Windows client behind the pipe: the
// supervisor that owns sing-box, the OpenVPN sessions, routes and the resolver override
// (docs/design/08-windows.md). Every Win32 call goes through the interfaces in io.go, so
// the orchestration is tested everywhere with fakes; the real implementations live in
// internal/winnet and internal/winproc.
package service

import (
	"os"
	"path/filepath"
	"runtime"

	"wayfork/service/internal/core"
)

// Version is the service version reported in DaemonInfo; set by the build.
var Version = "0.2.0"

// Environment is where the service lives and what it may execute. Every path derives
// from the service's own executable; nothing comes from the client
// (docs/design/08-windows.md, "Components and trust boundary").
type Environment struct {
	ExecutablePath string
	// %ProgramFiles%\Wayfork — the directory of the executable.
	InstallDir string
	Version    string
	// Authenticode hash of the executable; empty for an unsigned (developer) build.
	BuildID string
	Layout  core.RunLayout
	// DevMode: `--dev-apply` on an unsigned build — binaries are not trust-checked and
	// the client check is skipped. Logged loudly; never the installed configuration.
	DevMode bool
}

// BinDir is where the bundled binaries live.
func (e Environment) BinDir() string { return filepath.Join(e.InstallDir, "bin") }

// SingBoxPath is the bundled sing-box.
func (e Environment) SingBoxPath() string { return filepath.Join(e.BinDir(), executable("sing-box")) }

// OpenVPNPath is the bundled openvpn.
func (e Environment) OpenVPNPath() string { return filepath.Join(e.BinDir(), executable("openvpn")) }

// TapctlPath is the bundled tapctl.
func (e Environment) TapctlPath() string { return filepath.Join(e.BinDir(), executable("tapctl")) }

// DriverInfPath is the bundled ovpn-dco package the installer publishes with pnputil
// (docs/design/08-windows.md, "Installer").
func (e Environment) DriverInfPath() string {
	return filepath.Join(e.InstallDir, "drivers", "ovpn-dco", core.DriverOriginalName)
}

func executable(name string) string {
	if runtime.GOOS == "windows" {
		return name + ".exe"
	}
	return name
}

// RunPath is a file inside run\.
func (e Environment) RunPath(name string) string { return e.Layout.Path(name) }

// PrepareDirectories creates run\ and logs\. On Windows the caller (winnet) sets the
// SYSTEM+Administrators DACL afterwards; the POSIX mode covers test hosts.
func (e Environment) PrepareDirectories() error {
	for _, directory := range []string{e.Layout.Dir, e.Layout.LogDir} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return err
		}
	}
	return nil
}
