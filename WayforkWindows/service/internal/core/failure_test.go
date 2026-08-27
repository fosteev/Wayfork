package core

import "testing"

func TestFatalClassification(t *testing.T) {
	permanent := map[string]OpenVPNFailure{
		"Options error: Unrecognized option or missing parameter(s) in x:1: foo": FailureConfigError,
		"Cannot load inline certificate file":                                    FailureConfigError,
		"Cannot load CA certificate file ca.crt":                                 FailureConfigError,
		"OpenSSL: error: failed to parse":                                        FailureConfigError,
		"Error: private key password verification failed":                        FailureKeyPassphrase,
		"OpenSSL: error:1C800064:Provider routines::bad decrypt":                 FailureKeyPassphrase,
	}
	for message, want := range permanent {
		if got, ok := PermanentReasonForFatal(message); !ok || got != want {
			t.Errorf("%q → %q, %v; want %q", message, got, ok, want)
		}
	}
	transient := []string{
		"TLS Error: TLS handshake failed",
		"Connection reset, restarting [0]",
		// --route-nopull + pushed routes, 3–5 per connect (spike S3b): benign.
		"Options error: option 'route' cannot be used in this context ([PUSH-OPTIONS])",
		"OPTIONS IMPORT: option 'route' cannot be used in this context ([PUSH-OPTIONS])",
	}
	for _, message := range transient {
		if got, ok := PermanentReasonForFatal(message); ok {
			t.Errorf("%q classified as permanent %q", message, got)
		}
	}
	for _, failure := range []OpenVPNFailure{FailureAuthFailed, FailureNeedsCredentials, FailureKeyPassphrase, FailureNeedsKeyPassphrase, FailureConfigError, FailureUnsupportedPrompt} {
		if !failure.IsPermanent() {
			t.Errorf("%s must be permanent", failure)
		}
	}
	if FailureExited.IsPermanent() || OpenVPNFailure("").IsPermanent() {
		t.Error("exited and the zero value are not permanent")
	}
}
