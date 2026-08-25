# Wayfork — project rules

macOS menu bar app for per-domain split tunneling across multiple VPNs at once.
Routing/DNS by **sing-box** (TUN, fake-ip, SNI sniffing, DNS `detour`); VLESS is a native
sing-box outbound; each OpenVPN config runs as its own `openvpn --route-nopull` process on its
own utun, reached via a `direct` outbound with `bind_interface`. GUI is a SwiftUI menu bar app
that stores configs/rules, generates `sing-box.json` and manages processes; privileged parts
(TUN, openvpn) live in a launchd daemon registered via `SMAppService`. No custom Network
Extension. Binaries (sing-box, openvpn) are bundled. Don't revisit this without a reason.

## Language
- Code, comments, commit messages, README, docs, issues: **English only**.
- Chat with the maintainer: Russian.

## Git
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `ci:`, `test:`, `build:`.
  Optional scope: `feat(rules): …`. Subject ≤ 72 chars, imperative mood.
- **No `Co-Authored-By` and no AI signatures** in commits or PRs.
- **Commit and push only on explicit request.** Never commit on your own initiative.
- `main` is stable. Work happens in `feat/*`, `fix/*`, `docs/*`.

## Swift
- SwiftUI, Swift 5.10+ (6 when practical), macOS 14+.
- Formatting: swift-format with the repo's `.swift-format`. Run it before handing work over.
- Dependencies (SPM, brew binaries): exact pinned versions, no ranges.
- Secrets are stored in Keychain, never on disk in plain text.

## Secrets
- Never commit UUIDs, keys, certificates, server addresses or real configs.
- `examples/` contains templates with placeholders only (`<SERVER>`, `<UUID>`).
- Real user configs live outside the repo (`~/Library/Application Support/Wayfork/`).

## Layout
- `Wayfork/` — app sources (Xcode project / SPM package).
- `docs/` — `ROADMAP.md`, `design/*.md` (one file per feature area), user docs.
- `scripts/` — build/packaging helpers (fetching pinned binaries, signing, etc.).
- `examples/` — config templates with placeholders.

## Docs
- Follow `docs/ROADMAP.md` phases strictly in order: Features → Design → Implementation.
- Design docs go to `docs/design/`; keep them in sync when implementation deviates.
- Generated files, build products and user data are never committed (see `.gitignore`).
