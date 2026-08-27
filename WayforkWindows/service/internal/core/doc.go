// Package core holds the service logic that needs no privileges and no Win32: plan
// validation, run layout, the OpenVPN management protocol, reconcile planning, traffic
// accounting. It is the counterpart of WayforkDaemonCore on macOS and is tested on every
// platform against the shared fixtures/ directory (docs/design/08-windows.md).
package core
