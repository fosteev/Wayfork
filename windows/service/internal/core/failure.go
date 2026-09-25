package core

import "strings"

// OpenVPNFailure is a reason code carried in `TunnelState.failed`; the app maps it to the
// messages in docs/design/02-ux.md ("Error catalogue").
type OpenVPNFailure string

const (
	// FailureAuthFailed: the server rejected username/password
	// (`>PASSWORD:Verification Failed: 'Auth'`).
	FailureAuthFailed OpenVPNFailure = "ovpn.authFailed"
	// FailureNeedsCredentials: the config asks for credentials but the plan has none.
	FailureNeedsCredentials OpenVPNFailure = "ovpn.needsCredentials"
	// FailureKeyPassphrase: private key decryption failed.
	FailureKeyPassphrase OpenVPNFailure = "ovpn.keyPassphrase"
	// FailureNeedsKeyPassphrase: the key is encrypted but the plan has no passphrase.
	FailureNeedsKeyPassphrase OpenVPNFailure = "ovpn.needsKeyPassphrase"
	// FailureConfigError: OpenVPN rejected the config (options error, unreadable
	// certificate, the wrong adapter, …).
	FailureConfigError OpenVPNFailure = "ovpn.configError"
	// FailureUnsupportedPrompt: the server asks for something the service cannot provide
	// (proxy credentials, …).
	FailureUnsupportedPrompt OpenVPNFailure = "ovpn.unsupportedPrompt"
	// FailureExited: the process exited and `autoReconnect` is off.
	FailureExited OpenVPNFailure = "ovpn.exited"
)

// IsPermanent reports whether the failure stops retries until the plan changes.
func (f OpenVPNFailure) IsPermanent() bool {
	return f != FailureExited && f != ""
}

// pushOptionsMarker tags the benign `Options error: option 'route' cannot be used in this
// context ([PUSH-OPTIONS])` that `--route-nopull` logs for every pushed route (spike S3b).
const pushOptionsMarker = "[PUSH-OPTIONS]"

// PermanentReasonForFatal classifies a `>FATAL:` (or `F`-flagged) message; false means
// transient (network, TLS handshake, …).
func PermanentReasonForFatal(message string) (OpenVPNFailure, bool) {
	if strings.Contains(message, pushOptionsMarker) {
		return "", false
	}
	lower := strings.ToLower(message)
	if strings.Contains(lower, "private key password verification failed") ||
		strings.Contains(lower, "bad decrypt") {
		return FailureKeyPassphrase, true
	}
	for _, marker := range []string{
		"cannot load certificate", "cannot load private key", "cannot load ca",
		"cannot load inline certificate", "failed to parse", "cannot read",
		"unrecognized option", "--config file",
	} {
		if strings.Contains(lower, marker) {
			return FailureConfigError, true
		}
	}
	if strings.HasPrefix(lower, "options error") {
		return FailureConfigError, true
	}
	return "", false
}
