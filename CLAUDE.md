# Wayfork — project rules

macOS menu bar app for per-domain split tunneling across multiple VPNs at once.
Routing/DNS by **sing-box** (TUN, fake-ip, SNI sniffing, DNS `detour`); VLESS is a native
sing-box outbound; each OpenVPN config runs as its own `openvpn --route-nopull` process on its
own utun, reached via a `direct` outbound with `bind_interface`. GUI is a SwiftUI menu bar app
that stores configs/rules, generates `sing-box.json` and manages processes; privileged parts
(TUN, openvpn) live in a launchd daemon registered via `SMAppService`. No custom Network
Extension. Binaries (sing-box, openvpn) are bundled. Don't revisit this without a reason.

A Windows client with the same feature set lives in `WayforkWindows/`: a Flutter app plus a
Go service (`internal/core` is the pure, everywhere-tested half; Win32 stays behind
`//go:build windows`). Roadmap in `docs/ROADMAP-windows.md`, design deltas in
`docs/design/08-windows.md`; the macOS design docs remain the reference.

## Language
- Code, comments, commit messages, README, docs, issues: **English only**.
- Chat with the maintainer: Russian.

## Git
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `ci:`, `test:`, `build:`.
  Optional scope: `feat(rules): …`. Subject ≤ 72 chars, imperative mood.
  Windows scopes: `win` (Flutter app), `win-service` (Go service), `fixtures` (shared fixtures).
- **No `Co-Authored-By` and no AI signatures** in commits or PRs.
- **Commit and push only on explicit request.** Never commit on your own initiative.
- Solo project: commit straight to `main`; branches only for experiments.

## Swift
- SwiftUI, Swift 5.10+ (6 when practical), macOS 14+.
- Formatting: swift-format with the repo's `.swift-format`. Run it before handing work over.
- Dependencies (SPM, brew binaries): exact pinned versions, no ranges.
- Secrets are stored in Keychain, never on disk in plain text.

## Windows client (Dart, Go)
- Flutter with `fluent_ui`; Go 1.25 with `golang.org/x/sys` and `winipcfg`. Toolchains are
  pinned in `WayforkWindows/versions.env`; pub and Go dependencies are exact versions.
- Formatting: `dart format` + `dart analyze --fatal-infos` in `WayforkWindows/app`,
  `gofmt` + `go vet` in `WayforkWindows/service`. Run them before handing work over.
- `go test ./...` must pass on macOS too: keep Win32 in `_windows.go` files or behind
  build tags, and check with `GOOS=windows go build ./...`.
- Secrets are DPAPI-encrypted (`secrets.dat`), never plain text.

## Secrets
- Never commit UUIDs, keys, certificates, server addresses or real configs.
- `examples/` contains templates with placeholders only (`<SERVER>`, `<UUID>`).
- Real user configs live outside the repo (`~/Library/Application Support/Wayfork/`).

## Layout
- `Wayfork/` — macOS app sources (Xcode project / SPM package).
- `WayforkWindows/` — Windows client: `app/` (Flutter), `service/` (Go), `versions.env`;
  fetched binaries land in `bin/` and `drivers/` (git-ignored).
- `fixtures/` — test inputs and golden outputs shared by the Swift, Dart and Go tests
  (see `fixtures/README.md`; regenerate with `WAYFORK_UPDATE_GOLDEN=1`).
- `docs/` — `ROADMAP.md`, `design/*.md` (one file per feature area), user docs.
- `scripts/` — build/packaging helpers (fetching pinned binaries, signing, etc.).
- `examples/` — config templates with placeholders.

## Docs
- Follow `docs/ROADMAP.md` phases strictly in order: Features → Design → Implementation;
  `docs/ROADMAP-windows.md` the same way for the Windows client.
- Design docs go to `docs/design/`; keep them in sync when implementation deviates.
- Generated files, build products and user data are never committed (see `.gitignore`).
