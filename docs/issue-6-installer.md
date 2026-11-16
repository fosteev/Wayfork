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
- Fix committed as `e9466b5`; Windows 0.11.1 stamped at `c0df7ff` and published as
  a Windows-only pre-release on 2026-11-16. No live driver/VPN changes performed.
- [Windows CI](https://github.com/fosteev/Wayfork/actions/runs/43902575841) passed
  Go tests/vet/build and Flutter formatting, analysis, tests and Windows build.
- [Release build](https://github.com/fosteev/Wayfork/actions/runs/43902576447) passed
  on Windows, including cabinet extraction and hash verification for both OS variants
  and both architectures. Both MSI ProductVersion values are 0.11.1; both contain
  Win10 and Win11 driver packages. All three artifact SHA256 checks passed.
- [Release 0.11.1](https://github.com/fosteev/Wayfork/releases/tag/v0.11.1) includes
  the bundle EXE, both MSIs and their checksums. Reporter retest requested in
  [issue #6](https://github.com/fosteev/Wayfork/issues/6#issuecomment-6921849457).

Native acceptance required before release:
- Windows 10 and 11: clean installation and repair.
- Existing DCO 2.8.4, newer 2.8.7, and older driver: installation completes and
  Wayfork can create an adapter and establish an OpenVPN tunnel.
- Genuine publication failure still aborts; exit 259 with no usable package fails.
- Uninstall preserves an existing OpenVPN installation and any shared adapter.
- The actual Windows cabinet fallback and both MSI builds passed. The Windows
  administrative-image extraction path and explicit `-ForceCabinet` switch remain
  separate checks; the package-copy function was exercised locally for all variants.

Next: collect the reporter's result and run the native installation matrix when
the Windows test host is available. The pre-release is available for testing;
native installation acceptance and promotion to stable remain pending.
