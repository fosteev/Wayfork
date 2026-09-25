# wayforkctl for scripts and assistants — F21

> Status: implemented, manual checks owed · created 2026-09-25 · macOS M17, Windows WM19. Design:
> [design/09-wayforkctl.md](../design/09-wayforkctl.md). Statuses live here and in the
> two milestone skeletons.

## Context

- Asked 2026-09-25: "an MCP server so an assistant can read logs efficiently and configure
  the app". `/devil` verdict, taken as the scope: no MCP server. Extend `wayforkctl`,
  with filtered logs, rule changes through the app with an automatic revert, no secrets
  in replies, and discovery through `CLAUDE.md` and `help`.
- Facts checked while planning:
  - macOS `wayforkctl` only builds plans (`macos/WayforkCore/Sources/wayforkctl/main.swift`).
    The daemon accepts only the app (`XPCService.swift`, `CodeSigningRequirement.client`
    pins the bundle identifier), so a CLI cannot and should not talk to the daemon.
  - Rules exist in source form only in the app's `store.json`, written by
    `StoreRepository`. Every mutation goes through `AppModel.update`
    (`AppModel.swift`, "Every store mutation goes through here").
  - The app already writes every daemon line to `~/Library/Logs/Wayfork/runtime.log`
    (`LogLineFormat`, `AppLogFile` in `WayforkCore/App/LogFile.swift`), readable by the user.
  - Windows `wayforkctl diagnostics --tail N` returns per-source tails read from the
    service's log files (`Hub.Tails`); no filters.
  - No rollback / last-known-good anywhere.

## Stages

1. [x] Docs: F21, M17, WM19, design 09. — 2026-09-25.
2. [x] `WayforkCore`: `LogQuery` / `LogArchive` / `LogRedactor`, `ControlProtocol`
       types, `StoreEdit` (apply / inverse over `Store`), `ControlServer` +
       `ControlClient`; 14 tests incl. a socket round trip on a temp path. — 2026-09-25.
3. [x] `wayforkctl` commands and `help` with the *For assistants* block; `plan` moved to
       `Plan.swift`. `logs` checked against the live `runtime.log`. — 2026-09-25.
4. [x] App: `AppModel+Control.swift`, server start/stop, pending timer,
       `control-pending.json`, awaited apply result (`settleApply`, `lastApplyError`),
       notification. Builds; not run — the live app is never restarted from a session.
       — 2026-09-25.
5. [x] Release: `release.sh` builds a universal `wayforkctl` into `Contents/Resources/bin`
       and signs it (the universal `swift build` checked by hand; the full script is not
       run); README + CHANGELOG + `CLAUDE.md` *Diagnostics*. — 2026-09-25.
6. [x] Windows: `core.LogQuery` + `wayforkctl logs`; `go test`, `go vet`,
       `GOOS=windows go build` / `go vet` pass. — 2026-09-25.
7. [x] Checks: `swift test` (package, 182 + 98 tests), `xcodebuild` Debug app build,
       swift-format clean on the new files. The manual check in M17 and the VM run in WM19
       are still owed. — 2026-09-25.

## Decisions

- Default `confirmWithin` 60 s, range 10–600, `0` = commit immediately.
- One pending change at a time; the GUI's own edits are never blocked by it.
- `logs` default `--tail 100`, text output; redaction on by default.
- Exit code 3 = the app is not running.
