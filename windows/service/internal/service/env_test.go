package service

import (
	"path/filepath"
	"runtime"
	"testing"

	"wayfork/service/internal/core"
)

func TestEnvironmentPathsDeriveFromTheExecutable(t *testing.T) {
	installDir := filepath.Join("C:", "Program Files", "Wayfork")
	env := Environment{
		ExecutablePath: filepath.Join(installDir, "wayfork-service.exe"),
		InstallDir:     installDir,
		Layout:         core.DefaultLayout(filepath.Join("C:", "ProgramData")),
	}
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	cases := map[string]string{
		env.SingBoxPath():   filepath.Join(installDir, "bin", "sing-box"+suffix),
		env.OpenVPNPath():   filepath.Join(installDir, "bin", "openvpn"+suffix),
		env.TapctlPath():    filepath.Join(installDir, "bin", "tapctl"+suffix),
		env.DriverInfPath(): filepath.Join(installDir, "drivers", "ovpn-dco", core.DriverOriginalName),
		env.RunPath(core.DriverRecordFile): filepath.Join(
			"C:", "ProgramData", "Wayfork", "run", core.DriverRecordFile),
	}
	for got, want := range cases {
		if got != want {
			t.Errorf("path %q, want %q", got, want)
		}
	}
}
