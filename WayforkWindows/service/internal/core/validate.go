package core

import (
	"fmt"
	"regexp"
	"strings"
)

var tunnelIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// ValidatePlan checks all untrusted runtime-plan fields before the service writes files or
// starts children (docs/design/08-windows.md, "Components and trust boundary").
// ValidateOptions carries what the validator needs from the service's own environment.
type ValidateOptions struct {
	// The service's own `rulesets\block-ads.srs`; a binary rule-set anywhere else is refused.
	BlockListPath string
	// Existence check for that file; nil skips it (tests).
	FileExists func(path string) bool
}

// ValidatePlan is ValidatePlanWith without a block list (any binary rule-set is refused).
func ValidatePlan(plan RuntimePlan) *DaemonError {
	return ValidatePlanWith(plan, ValidateOptions{})
}

// ValidatePlanWith enforces the plan limits (docs/design/00-architecture.md, rule 4).
func ValidatePlanWith(plan RuntimePlan, options ValidateOptions) *DaemonError {
	if plan.Version != PlanVersion {
		return ErrPlanInvalid(fmt.Sprintf(
			"unsupported plan version %d (expected %d)", plan.Version, PlanVersion,
		))
	}
	if err := validateText(plan.SingBox.Config, SingBoxConfig, false); err != nil {
		return err
	}
	for name, contents := range plan.SingBox.RuleSets {
		id, isTunnelRuleSet := RuleSetID(name)
		if name != DirectRuleSet && name != DirectIPRuleSet && (!isTunnelRuleSet || !IsTunnelID(id)) {
			return ErrPlanInvalid(fmt.Sprintf(
				"rule-set file name %q is not rules-t-<id>.json, rules-t-<id>-ip.json, their rules-g- twins, %s or %s",
				name, DirectRuleSet, DirectIPRuleSet,
			))
		}
		if err := validateText(contents, name, false); err != nil {
			return err
		}
	}
	// F18: a binary rule-set may only be the service's own bundled block list.
	for _, path := range plan.SingBox.BinaryRuleSetPaths() {
		if path != options.BlockListPath {
			return ErrPlanInvalid(fmt.Sprintf("rule-set path %q is not the bundled block list", path))
		}
		if options.FileExists != nil && !options.FileExists(path) {
			return ErrPlanInvalid("block list missing at " + path + " — reinstall Wayfork")
		}
	}
	// F17: loopback only, sane ports, one per tunnel or group, tags of our shape.
	proxyPorts := map[int]struct{}{}
	proxyExits := map[string]struct{}{}
	for _, inbound := range plan.SingBox.LocalProxyInbounds() {
		if inbound.Listen != LocalProxyListenAddress {
			return ErrPlanInvalid(fmt.Sprintf("inbound %s listens on %s, not loopback", inbound.Tag, inbound.Listen))
		}
		if inbound.Port < 1024 || inbound.Port > 65535 {
			return ErrPlanInvalid(fmt.Sprintf("inbound %s port %d is out of range", inbound.Tag, inbound.Port))
		}
		if _, exists := proxyPorts[inbound.Port]; exists {
			return ErrPlanInvalid(fmt.Sprintf("port %d is used by two inbounds", inbound.Port))
		}
		proxyPorts[inbound.Port] = struct{}{}
		exitID, ok := inbound.ExitID()
		if !ok || !IsTunnelID(exitID) {
			return ErrPlanInvalid(fmt.Sprintf("inbound tag %q is not proxy-t-<id> or proxy-g-<id>", inbound.Tag))
		}
		if _, exists := proxyExits[exitID]; exists {
			return ErrPlanInvalid("tunnel or group " + exitID + " has two local proxy ports")
		}
		proxyExits[exitID] = struct{}{}
	}
	if len(plan.OpenVPN) > MaxTunnels {
		return ErrPlanInvalid(fmt.Sprintf(
			"%d OpenVPN tunnels exceed the limit of %d", len(plan.OpenVPN), MaxTunnels,
		))
	}
	ids := make(map[string]struct{}, len(plan.OpenVPN))
	interfaces := make(map[string]struct{}, len(plan.OpenVPN))
	for _, runtime := range plan.OpenVPN {
		if !IsTunnelID(runtime.ID) {
			return ErrPlanInvalid(fmt.Sprintf("tunnel id %q is not a lowercase UUID", runtime.ID))
		}
		if _, exists := ids[runtime.ID]; exists {
			return ErrPlanInvalid("duplicate tunnel id " + runtime.ID)
		}
		ids[runtime.ID] = struct{}{}
		if !IsAdapterName(runtime.Interface) {
			return ErrPlanInvalid(fmt.Sprintf(
				"interface %q of tunnel %s is not one of Wayfork-1…Wayfork-32",
				runtime.Interface, runtime.ID,
			))
		}
		if _, exists := interfaces[runtime.Interface]; exists {
			return ErrPlanInvalid("interface " + runtime.Interface + " is used twice")
		}
		interfaces[runtime.Interface] = struct{}{}
		if err := validateText(runtime.Config, OpenVPNConfig(runtime.ID), false); err != nil {
			return err
		}
		if runtime.Credentials != nil {
			if err := validateText(runtime.Credentials.Username, "username of "+runtime.ID, true); err != nil {
				return err
			}
			if err := validateText(runtime.Credentials.Password, "password of "+runtime.ID, true); err != nil {
				return err
			}
		}
		if runtime.KeyPassphrase != nil {
			if err := validateText(*runtime.KeyPassphrase, "key passphrase of "+runtime.ID, true); err != nil {
				return err
			}
		}
	}
	return nil
}

// RuleSetID extracts the tunnel or group ID from rules-t-<id>.json, rules-t-<id>-ip.json
// and their rules-g- twins (F16).
func RuleSetID(fileName string) (string, bool) {
	var prefix string
	for _, candidate := range []string{"rules-t-", "rules-g-"} {
		if strings.HasPrefix(fileName, candidate) {
			prefix = candidate
		}
	}
	if prefix == "" || !strings.HasSuffix(fileName, ".json") {
		return "", false
	}
	id := strings.TrimSuffix(strings.TrimPrefix(fileName, prefix), ".json")
	id = strings.TrimSuffix(id, "-ip")
	if id == "" {
		return "", false
	}
	return id, true
}

// IsTunnelID reports whether id is a lowercase hyphenated UUID.
func IsTunnelID(id string) bool {
	return len(id) == 36 && tunnelIDPattern.MatchString(id)
}

func validateText(text, name string, allowEmpty bool) *DaemonError {
	bytes := len([]byte(text))
	if bytes > MaxConfigBytes {
		return ErrPlanInvalid(fmt.Sprintf("%s is %d bytes, limit %d", name, bytes, MaxConfigBytes))
	}
	if !allowEmpty && bytes == 0 {
		return ErrPlanInvalid(name + " is empty")
	}
	if strings.IndexByte(text, 0) >= 0 {
		return ErrPlanInvalid(name + " contains a NUL byte")
	}
	return nil
}
