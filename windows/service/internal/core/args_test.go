package core

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestOpenVPNArguments(t *testing.T) {
	layout := RunLayout{Dir: filepath.Join("C:", "run"), LogDir: filepath.Join("C:", "logs")}
	runtime := testRuntime(idA, "Wayfork-5", "client")
	argv := OpenVPNArguments(runtime, layout, 7505, LogLevelDebug)
	want := []string{
		"--config", filepath.Join("C:", "run", "t-"+idA+".ovpn"),
		"--dev", "tun", "--dev-type", "tun", "--dev-node", "Wayfork-5",
		"--route-nopull",
		"--script-security", "1",
		"--management", "127.0.0.1", "7505", filepath.Join("C:", "run", "t-"+idA+".mgmt"),
		"--management-hold", "--management-query-passwords",
		"--auth-nocache", "--auth-retry", "interact",
		"--persist-tun",
		"--resolv-retry", "infinite",
		"--connect-retry", "2", "60",
		"--verb", "4",
		"--machine-readable-output", "--suppress-timestamps",
		"--dns-updown", "disable",
	}
	if !slices.Equal(argv, want) {
		t.Errorf("argv =\n%q\nwant\n%q", argv, want)
	}
	// Dropped on Windows: DEPRECATED in 2.7 (spike S3), and there is no Unix socket.
	for _, gone := range []string{"--persist-key", "--max-routes", "unix", "--windows-driver"} {
		if slices.Contains(argv, gone) {
			t.Errorf("argv must not contain %s", gone)
		}
	}
	for _, arg := range argv {
		if arg == "" || strings.ContainsAny(arg, "\n\r") {
			t.Errorf("bad argument %q", arg)
		}
	}
	if verb := OpenVPNArguments(runtime, layout, 1, LogLevelWarning); verb[slices.Index(verb, "--verb")+1] != "1" {
		t.Error("warning level must map to --verb 1")
	}

	key := OpenVPNDiffKey(runtime, LogLevelInfo)
	if key != runtime.ConfigHash+"|Wayfork-5|verb=3" {
		t.Errorf("diff key = %s", key)
	}
	if OpenVPNDiffKey(runtime, LogLevelDebug) == key {
		t.Error("the log level is part of the diff key")
	}
	moved := runtime
	moved.Interface = "Wayfork-6"
	if OpenVPNDiffKey(moved, LogLevelInfo) == key {
		t.Error("the adapter is part of the diff key")
	}
}

func TestSingBoxArguments(t *testing.T) {
	layout := RunLayout{Dir: filepath.Join("C:", "run")}
	config := filepath.Join("C:", "run", "sing-box.json")
	if got := SingBoxRunArguments(layout); !slices.Equal(got, []string{"run", "-D", layout.Dir, "-c", config}) {
		t.Errorf("run argv = %q", got)
	}
	if got := SingBoxCheckArguments(layout); !slices.Equal(got, []string{"check", "-D", layout.Dir, "-c", config}) {
		t.Errorf("check argv = %q", got)
	}
	if !slices.Equal(SingBoxVersionArguments, []string{"version"}) {
		t.Errorf("version argv = %q", SingBoxVersionArguments)
	}
}
