package core

import (
	"path/filepath"
	"strings"
)

// RunLayout contains service-owned runtime and log directories
// (docs/design/08-windows.md, "Filesystem layout").
type RunLayout struct {
	Dir    string
	LogDir string
}

// DefaultLayout returns the service layout below the supplied ProgramData directory.
func DefaultLayout(programData string) RunLayout {
	return RunLayout{
		Dir:    filepath.Join(programData, "Wayfork", "run"),
		LogDir: filepath.Join(programData, "Wayfork", "logs"),
	}
}

const (
	// SingBoxConfig is the generated sing-box configuration file.
	SingBoxConfig = "sing-box.json"
	// CacheFile stores persistent sing-box fake-IP mappings.
	CacheFile = "cache.db"
	// ResolverOverrideRecordFile stores the resolver-override record that must survive a service crash.
	ResolverOverrideRecordFile = "dns-override.json"
	// DirectRuleSet contains direct domain exceptions.
	DirectRuleSet = "rules-direct.json"
	// DirectIPRuleSet contains direct IP exceptions.
	DirectIPRuleSet = "rules-direct-ip.json"
)

// OpenVPNConfig returns the runtime OpenVPN config file name for id.
func OpenVPNConfig(id string) string { return "t-" + id + ".ovpn" }

// ManagementPasswordFile returns the OpenVPN management password file name for id.
func ManagementPasswordFile(id string) string { return "t-" + id + ".mgmt" }

// RuleSet returns the domain rule-set file name for id.
func RuleSet(id string) string { return "rules-t-" + id + ".json" }

// IPRuleSet returns the IP rule-set file name for id.
func IPRuleSet(id string) string { return "rules-t-" + id + "-ip.json" }

// IsTransient reports whether a runtime file is wiped during cleanup.
func IsTransient(name string) bool {
	return name != CacheFile && name != ResolverOverrideRecordFile && name != DriverRecordFile
}

// IsRuleSet reports whether name has the per-tunnel rule-set file shape.
func IsRuleSet(name string) bool {
	return strings.HasPrefix(name, "rules-t-") && strings.HasSuffix(name, ".json")
}

// ChildLog returns the raw log file name for a child source.
func ChildLog(source string) string {
	return strings.ReplaceAll(source, ":", "-") + ".log"
}

// Path returns a path inside the runtime directory.
func (l RunLayout) Path(name string) string { return filepath.Join(l.Dir, name) }

// LogPath returns the raw log path for a child source.
func (l RunLayout) LogPath(source string) string {
	return filepath.Join(l.LogDir, ChildLog(source))
}
