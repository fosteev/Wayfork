# Releasing

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project and the
version in `WayforkWindows/app/lib/core/version.dart` (and `pubspec.yaml`), date the entry in
[CHANGELOG.md](../CHANGELOG.md), commit, then build both platforms, tag `v<version>` and
attach every artefact and its `.sha256` to the GitHub release.

## macOS

`scripts/release.sh` archives the app, signs everything inside out (app, daemon, bundled
binaries) with hardened runtime and secure timestamps, and produces
`build/release/Wayfork-<version>.dmg` with a `.sha256`.

```sh
scripts/release.sh --skip-notarize    # archive + sign + DMG smoke test, any identity
```

Until the project has an Apple Developer Program membership, releases are made with
`--skip-notarize`: the script signs with the *Apple Development* identity and skips
notarization, hence the quarantine step in the README. With a *Developer ID Application*
identity in the keychain and a notarytool credentials profile
(`xcrun notarytool store-credentials <name> …`, passed as `--keychain-profile` or in
`WAYFORK_NOTARY_PROFILE`) the same script notarizes and staples the app and the DMG, and
that step goes away.

## Windows

`scripts/release-windows.ps1` builds the app once (x64 — Flutter publishes no arm64 Windows
toolchain), cross-builds the Go service for both architectures, stages the payload and
produces `build/release-windows/Wayfork-<version>-<arch>.msi` plus the bundle
`Wayfork-<version>.exe` that carries both, each with a `.sha256`. Pushing a `v<version>`
tag runs the same script in CI and attaches all of them to the release.

Artefacts are unsigned until there is an Authenticode certificate. With one,
`-CertificatePath` (and `-CertificatePassword`) signs Wayfork's own binaries, the MSIs and
the bundle with a timestamp, and the SmartScreen note in the README goes away.
