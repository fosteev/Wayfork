# Issue #6: Windows driver installation

Scope: fix installation alongside a newer OpenVPN DCO driver, bundle both Windows
driver variants, and preserve shared drivers on uninstall. Implementation targets
`main`, base `9a16e4d`, using a separate worktree.
The unfinished rule-list work remains on `wip/rule-lists-traffic-2026-11-11`.

Implementation:
- Compare four-part driver versions numerically; preserve equal/newer packages.
- Validate the driver-store postcondition for successful publication and exit 259.
- Bundle pinned Win10/Win11 packages for both architectures; select by OS build.
- Refuse stale release payloads missing either variant.
- Remove only recorded packages, without forcing removal from other applications.

Verification:
- Go tests and vet pass; Windows amd64 and arm64 cross-builds pass.
- Win10 hashes were computed from both original OpenVPN 2.7.6-I001 MSIs after
  verifying their existing SHA256 pins. File-table nx20/nx21 mappings were inspected.
- PowerShell 7.4.13 parsed both modified scripts successfully. The actual
  `Get-DriverPackage` function copied and verified all four OS/architecture
  combinations from extracted MSI files; a deliberately wrong pin was rejected.
  An isolated local harness was used. Windows COM/cabinet extraction
  and a complete MSI build still need the native acceptance below.
- Native acceptance is pending: `ssh wf-win` timed out on 2026-11-16.
- Commit and push to `main` authorized on 2026-11-16. No release or live driver/VPN
  changes performed; native acceptance remains pending.

Native acceptance required before release:
- Windows 10 and 11: clean installation and repair.
- Existing DCO 2.8.4, newer 2.8.7, and older driver: installation completes and
  Wayfork can create an adapter and establish an OpenVPN tunnel.
- Genuine publication failure still aborts; exit 259 with no usable package fails.
- Uninstall preserves an existing OpenVPN installation and any shared adapter.
- Fetch both architectures normally and with `-ForceCabinet`; build both MSIs.

Next: run the native matrix when the Windows test host is available. Current code
and checks do not establish native installer acceptance or release readiness.
