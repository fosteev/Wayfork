package core

import "strconv"

// OpenVPNArguments builds Windows OpenVPN child argv
// (docs/design/08-windows.md, "Adapters" and "Logging").
func OpenVPNArguments(
	runtime OpenVPNRuntime,
	layout RunLayout,
	managementPort int,
	level LogLevel,
) []string {
	return []string{
		"--config", layout.Path(OpenVPNConfig(runtime.ID)),
		"--dev", "tun",
		"--dev-type", "tun",
		"--dev-node", runtime.Interface,
		"--route-nopull",
		"--script-security", "1",
		"--management", "127.0.0.1", strconv.Itoa(managementPort),
		layout.Path(ManagementPasswordFile(runtime.ID)),
		"--management-hold",
		"--management-query-passwords",
		"--auth-nocache",
		"--auth-retry", "interact",
		"--persist-tun",
		"--resolv-retry", "infinite",
		"--connect-retry", "2", "60",
		"--verb", strconv.Itoa(level.OpenVPNVerbosity()),
		"--machine-readable-output",
		"--suppress-timestamps",
		"--dns-updown", "disable",
	}
}

// OpenVPNDiffKey returns the reconcile key whose changes restart an OpenVPN child.
func OpenVPNDiffKey(runtime OpenVPNRuntime, level LogLevel) string {
	return runtime.ConfigHash + "|" + runtime.Interface + "|verb=" +
		strconv.Itoa(level.OpenVPNVerbosity())
}

// SingBoxRunArguments builds sing-box run argv.
func SingBoxRunArguments(layout RunLayout) []string {
	return []string{"run", "-D", layout.Dir, "-c", layout.Path(SingBoxConfig)}
}

// SingBoxCheckArguments builds sing-box check argv.
func SingBoxCheckArguments(layout RunLayout) []string {
	return []string{"check", "-D", layout.Dir, "-c", layout.Path(SingBoxConfig)}
}

// SingBoxVersionArguments is sing-box version argv.
var SingBoxVersionArguments = []string{"version"}
