package core

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// LogLevel is the shared app/service logging level
// (docs/design/08-windows.md, "Logging").
type LogLevel string

const (
	// LogLevelError records errors only.
	LogLevelError LogLevel = "error"
	// LogLevelWarning records warnings and errors.
	LogLevelWarning LogLevel = "warning"
	// LogLevelInfo records normal service activity.
	LogLevelInfo LogLevel = "info"
	// LogLevelDebug enables verbose diagnostics.
	LogLevelDebug LogLevel = "debug"
)

// ParseLogLevel validates a wire log-level string.
func ParseLogLevel(value string) (LogLevel, error) {
	level := LogLevel(value)
	switch level {
	case LogLevelError, LogLevelWarning, LogLevelInfo, LogLevelDebug:
		return level, nil
	default:
		return "", fmt.Errorf("unknown log level %q", value)
	}
}

// MarshalJSON rejects invalid log levels instead of putting them on the wire; the zero
// value is the default level, info.
func (l LogLevel) MarshalJSON() ([]byte, error) {
	if l == "" {
		l = LogLevelInfo
	}
	if _, err := ParseLogLevel(string(l)); err != nil {
		return nil, err
	}
	return MarshalWire(string(l))
}

// UnmarshalJSON decodes and validates a wire log level.
func (l *LogLevel) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return fmt.Errorf("log level must be a string: %w", err)
	}
	parsed, err := ParseLogLevel(value)
	if err != nil {
		return err
	}
	*l = parsed
	return nil
}

// OpenVPNVerbosity maps the shared level to openvpn --verb.
func (l LogLevel) OpenVPNVerbosity() int {
	switch l {
	case LogLevelDebug:
		return 4
	case LogLevelInfo:
		return 3
	default:
		return 1
	}
}

// SingBoxLevel maps the shared level to a sing-box log level.
func (l LogLevel) SingBoxLevel() string {
	switch l {
	case LogLevelDebug:
		return "debug"
	case LogLevelWarning:
		return "warn"
	case LogLevelError:
		return "error"
	default:
		return "info"
	}
}

// Rank returns the logging severity order, from error 0 through debug 3.
func (l LogLevel) Rank() int {
	switch l {
	case LogLevelError:
		return 0
	case LogLevelWarning:
		return 1
	case LogLevelInfo:
		return 2
	case LogLevelDebug:
		return 3
	default:
		return -1
	}
}

// Credentials contains OpenVPN username/password credentials sent in a runtime plan.
type Credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// MarshalJSON emits credentials with sorted wire keys.
func (c Credentials) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{"password": c.Password, "username": c.Username})
}

// UnmarshalJSON strictly decodes credentials.
func (c *Credentials) UnmarshalJSON(data []byte) error {
	var wire struct {
		Password *string `json:"password"`
		Username *string `json:"username"`
	}
	if err := decodeRequiredObject(data, "credentials", &wire); err != nil {
		return err
	}
	if wire.Username == nil || wire.Password == nil {
		return fmt.Errorf("credentials require username and password strings")
	}
	c.Username = *wire.Username
	c.Password = *wire.Password
	return nil
}

// OpenVPNRuntime is one desired OpenVPN child process
// (docs/design/08-windows.md, "IPC").
type OpenVPNRuntime struct {
	ID            string       `json:"id"`
	Interface     string       `json:"interface"`
	Config        string       `json:"config"`
	Credentials   *Credentials `json:"credentials,omitempty"`
	KeyPassphrase *string      `json:"keyPassphrase,omitempty"`
	ConfigHash    string       `json:"configHash"`
}

// MarshalJSON emits an OpenVPN runtime with optional secrets omitted only when absent.
func (r OpenVPNRuntime) MarshalJSON() ([]byte, error) {
	object := map[string]any{
		"config":     r.Config,
		"configHash": r.ConfigHash,
		"id":         r.ID,
		"interface":  r.Interface,
	}
	if r.Credentials != nil {
		object["credentials"] = r.Credentials
	}
	if r.KeyPassphrase != nil {
		object["keyPassphrase"] = *r.KeyPassphrase
	}
	return MarshalWire(object)
}

// UnmarshalJSON strictly decodes an OpenVPN runtime without normalizing its ID.
func (r *OpenVPNRuntime) UnmarshalJSON(data []byte) error {
	var wire struct {
		Config        *string      `json:"config"`
		ConfigHash    *string      `json:"configHash"`
		Credentials   *Credentials `json:"credentials"`
		ID            *string      `json:"id"`
		Interface     *string      `json:"interface"`
		KeyPassphrase *string      `json:"keyPassphrase"`
	}
	if err := decodeRequiredObject(data, "OpenVPN runtime", &wire); err != nil {
		return err
	}
	if wire.Config == nil || wire.ConfigHash == nil || wire.ID == nil || wire.Interface == nil {
		return fmt.Errorf("OpenVPN runtime requires string config, configHash, id, and interface fields")
	}
	*r = OpenVPNRuntime{
		ID:            *wire.ID,
		Interface:     *wire.Interface,
		Config:        *wire.Config,
		Credentials:   wire.Credentials,
		KeyPassphrase: wire.KeyPassphrase,
		ConfigHash:    *wire.ConfigHash,
	}
	return nil
}

// SingBoxPlan contains sing-box configuration and external rule-set files.
type SingBoxPlan struct {
	Config     string            `json:"config"`
	ConfigHash string            `json:"configHash"`
	RuleSets   map[string]string `json:"ruleSets"`
}

// MarshalJSON emits empty rule sets as an object rather than null.
func (p SingBoxPlan) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"config":     p.Config,
		"configHash": p.ConfigHash,
		"ruleSets":   nonNilMap(p.RuleSets),
	})
}

// UnmarshalJSON strictly decodes a sing-box plan.
func (p *SingBoxPlan) UnmarshalJSON(data []byte) error {
	var wire struct {
		Config     *string            `json:"config"`
		ConfigHash *string            `json:"configHash"`
		RuleSets   *map[string]string `json:"ruleSets"`
	}
	if err := decodeRequiredObject(data, "sing-box plan", &wire); err != nil {
		return err
	}
	if wire.Config == nil || wire.ConfigHash == nil || wire.RuleSets == nil {
		return fmt.Errorf("sing-box plan requires config, configHash, and ruleSets")
	}
	p.Config = *wire.Config
	p.ConfigHash = *wire.ConfigHash
	p.RuleSets = *wire.RuleSets
	return nil
}

// RuntimePlan is desired service state computed by the app
// (docs/design/08-windows.md, "IPC").
type RuntimePlan struct {
	Version           int              `json:"version"`
	SingBox           SingBoxPlan      `json:"singBox"`
	OpenVPN           []OpenVPNRuntime `json:"openVPN"`
	AutoReconnect     bool             `json:"autoReconnect"`
	LogLevel          LogLevel         `json:"logLevel"`
	OverrideSystemDNS bool             `json:"overrideSystemDNS"`
}

const (
	// PlanVersion is the only runtime-plan version understood by this service.
	PlanVersion = 1
	// MaxTunnels is the maximum number of concurrent OpenVPN children.
	MaxTunnels = MaxSlots
	// MaxConfigBytes is the byte limit for every config, rule set, and credential field.
	MaxConfigBytes = 1 << 20
)

// MarshalJSON emits a complete plan with sorted keys and non-null collections.
func (p RuntimePlan) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"autoReconnect":     p.AutoReconnect,
		"logLevel":          p.LogLevel,
		"openVPN":           nonNilSlice(p.OpenVPN),
		"overrideSystemDNS": p.OverrideSystemDNS,
		"singBox":           p.SingBox,
		"version":           p.Version,
	})
}

// UnmarshalJSON strictly decodes a plan while defaulting fields added after version 1.
func (p *RuntimePlan) UnmarshalJSON(data []byte) error {
	var wire struct {
		AutoReconnect     *bool             `json:"autoReconnect"`
		LogLevel          *LogLevel         `json:"logLevel"`
		OpenVPN           *[]OpenVPNRuntime `json:"openVPN"`
		OverrideSystemDNS *bool             `json:"overrideSystemDNS"`
		SingBox           *SingBoxPlan      `json:"singBox"`
		Version           *int              `json:"version"`
	}
	if err := decodeRequiredObject(data, "runtime plan", &wire); err != nil {
		return err
	}
	if wire.Version == nil || wire.SingBox == nil || wire.OpenVPN == nil {
		return fmt.Errorf("runtime plan requires version, singBox, and openVPN")
	}
	autoReconnect := true
	if wire.AutoReconnect != nil {
		autoReconnect = *wire.AutoReconnect
	}
	logLevel := LogLevelInfo
	if wire.LogLevel != nil {
		logLevel = *wire.LogLevel
	}
	overrideSystemDNS := true
	if wire.OverrideSystemDNS != nil {
		overrideSystemDNS = *wire.OverrideSystemDNS
	}
	*p = RuntimePlan{
		Version:           *wire.Version,
		SingBox:           *wire.SingBox,
		OpenVPN:           *wire.OpenVPN,
		AutoReconnect:     autoReconnect,
		LogLevel:          logLevel,
		OverrideSystemDNS: overrideSystemDNS,
	}
	return nil
}

// PlanHash hashes every part of the plan on which the service acts.
func (p RuntimePlan) PlanHash() string {
	parts := []string{p.SingBox.ConfigHash}
	fileNames := make([]string, 0, len(p.SingBox.RuleSets))
	for fileName := range p.SingBox.RuleSets {
		fileNames = append(fileNames, fileName)
	}
	sort.Strings(fileNames)
	for _, fileName := range fileNames {
		parts = append(parts, fileName+"="+SHA256Hex(p.SingBox.RuleSets[fileName]))
	}
	for _, runtime := range p.OpenVPN {
		parts = append(parts, runtime.ID+"="+runtime.ConfigHash)
	}
	parts = append(parts, fmt.Sprintf("overrideSystemDNS=%t", p.OverrideSystemDNS))
	return SHA256Hex(strings.Join(parts, "\n"))
}

// SHA256Hex returns the lowercase SHA-256 digest of text.
func SHA256Hex(text string) string {
	digest := sha256.Sum256([]byte(text))
	return hex.EncodeToString(digest[:])
}

// ComputeOpenVPNConfigHash hashes an OpenVPN config and its optional secrets.
func ComputeOpenVPNConfigHash(config string, credentials *Credentials, keyPassphrase *string) string {
	username := ""
	password := ""
	if credentials != nil {
		username = credentials.Username
		password = credentials.Password
	}
	passphrase := ""
	if keyPassphrase != nil {
		passphrase = *keyPassphrase
	}
	return SHA256Hex(strings.Join([]string{config, username, password, passphrase}, "\x00"))
}
