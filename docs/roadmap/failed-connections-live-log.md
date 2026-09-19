# Failed connections on the live log — F19/F20 fix

> Status: done · created 2026-09-19 · all stages 2026-09-19, replayed against the live log at review. The executing session ticks the checkboxes as
> it goes; the milestone boxes it closes are ROADMAP.md § M15/M16 "manual check" and
> ROADMAP-windows.md § WM16/WM17 as far as the parser goes.

## Goal

The *Can't reach* pane and the *Connections* view show real data: the daemon's tracker
parses the lines the pinned sing-box 1.13.19 actually prints, on macOS and Windows,
with tests on a recorded sample of that output.

## Context and constraints

- The live check of 2026-09-19 (`~/Library/Logs/Wayfork/runtime.log`, 13 real failures
  dropped) found the tracker's line shapes wrong. What sing-box 1.13.19 prints at
  `log.level: info`, recorded and anonymised in
  [fixtures/logs/sing-box-1.13.19.log](../../fixtures/logs/sing-box-1.13.19.log) — this
  file **is the contract**; every claim below is visible in it:
  1. The connection id is ANSI-coloured: `[\e[38;5;147m3216874115\e[0m 5.0s]`. Nothing
     strips escapes today, so `split` rejects every line.
  2. There is **no** `router: match[N] rule => outbound` / `no match, using` line. The exit
     is the tag in `outbound/<type>[<tag>]: outbound connection to <host>:<port>`
     (`outbound packet connection to` for UDP). The line can repeat for one id while
     sing-box dials (`1ms`, `206ms`).
  3. The failure is an **info** line: `connection: open connection to <host>:<port> using
     outbound/<type>[<tag>]: <error>`. No `ERROR` level, no `inbound/tun[tun-in]: open
     connection to` prefix.
  4. There is no `sniffed protocol … domain:` line. `inbound connection to` carries the
     fake-ip (`198.18.x.x`); the outbound line already carries the **domain** (sing-box
     resolves the fake-ip back before dialling) or the real IP. No fake-ip map is needed.
  5. `router: found process path: <path>, user: <name>` — the `, user: …` suffix must be
     cut from the path.
  6. `dns: exchanged A <name>. <ttl> IN A <ip>` / `dns: cached A …` have their own ids and
     are not connections.
- Not seen in the live log, so kept as they are with a *(verify)* mark: the block-list
  `=> reject` / `predefined` match lines (F18's `BlockCounter` reads the same shape — if
  it never fires either, that is a separate finding), and how a group outbound prints
  (`outbound/urltest[g-<id>]` or the member's `outbound/vless[t-<id>]`).
- The relay is the one place to strip escapes: `SingBoxLog.message(of:)` /
  `level(of:)` in `WayforkDaemonCore` (fed by `SingBoxEngine`, consumed by
  `TrafficSampler` → `FailedConnections`, `BlockCounter`, `RecentHosts`, the app's Logs
  window and `runtime.log`), and the Go service's sing-box relay before
  `IsInterestingLogLine` / `Ingest` in `internal/service/clashhttp.go`.
- The wire contract (`FailedHost`, `ExitStats`, `TrafficSnapshot`) and both apps' views
  do not change.

## Decisions

- **Strip ANSI at the relay boundary**, once, for every consumer — not inside the tracker.
  The stripped line is what the app stores and shows.
- **Opened** = the first `outbound … connection to` line per id (TCP or packet); it sets
  the exit (tag → id via the existing `exitID(fromOutboundTag:)`) and the host (from that
  line, replacing the fake-ip the inbound line gave). Repeats for the same id do not count
  again.
- **Failed** = a `connection: open connection to <host> using outbound/<type>[<tag>]:
  <error>` line at **any** level; host and exit come from the line itself (so a failure
  is recorded even when its info prelude was not seen — log detail *Problems*), the
  process from the pending entry when there is one. The reason classes stay
  (`i/o timeout` → no answer, `connection refused` → refused, `connection reset` → reset,
  `no such host` / `NXDOMAIN` / `lookup … failed` → no such name, `network is
  unreachable` / `no route to host` behind a tunnel → tunnel down, else failed).
- `inbound connection to` / `inbound packet connection to` still opens the pending entry
  (host = the address as printed; a `198.18.x.x` fake-ip is replaced by the outbound
  line's host); `inbound connection from` is ignored.
- `isInteresting` / `IsInterestingLogLine` are widened to the new shapes and narrowed
  away from the dead ones (no `=> ` except the block-list reject, no `using ` alone).
- `opened` on the wire stays `nil` until the first outbound line has been seen since
  `clear()` — the *Problems* hint keeps working, since at `log.level: error` sing-box
  prints neither the outbound line nor (verify) the failure line.

## Stages

### 1. macOS

- [x] `SingBoxLog`: strip `\e[…m` sequences in `message(of:)` and before the level scan;
      `SingBoxLogTests` on the fixture lines (level, message, no escapes left).
      (2026-09-19: added `stripANSI` in `SingBoxLog.swift`, applied in both `message(of:)`
      and `level(of:)`; fixture-based coverage added to `singBoxLogParsing`'s neighbour
      test `singBoxLogStripsAnsiFromTheFixtureLines` in `PlanningTests.swift` — no
      dedicated `SingBoxLogTests.swift` existed, so the test was added next to the
      existing inline `SingBoxLog` tests rather than creating a new file.)
- [x] `FailedConnections` rewritten to the shapes above (both `ingest` branches, the
      process-path suffix, the repeat guard); `isInteresting` updated.
      (2026-09-19: opened now keys off the new `outbound/<type>[<tag>]: outbound
      connection to …` line; failed off `connection: open connection to … using
      outbound/<type>[<tag>]: …` at any level; process path suffix `, user: …` cut via
      `stripUserSuffix`; the dead `router: match`/generic `using` and `sniffed` branches
      removed; the unverified dns-exchange/block-list branches kept unchanged.)
- [x] `FailedConnectionsTests`: the old inline arrays replaced by the fixture file —
      expected rows: `chat.example.net` / Messenger / ×1 / no answer / exit `aaaaaaaa-…`
      and `203.0.113.40:27015` / Game / ×1 / refused / `direct`; exits: `aaaaaaaa-…`
      opened 3 (TCP fail, TCP ok, UDP), failed 1; `direct` opened 2, failed 1; blocked 0;
      no row for the DNS lines; the ANSI-wrapped ids join. Keep one test for the
      block-list reject shape as it was (marked verify).
      (2026-09-19: `failedConnectionReadsTheSingBox1_13_19LiveLogFixture` runs the whole
      fixture through `SingBoxLog.level(of:)`/`.message(of:)` then `ingest`, all
      expectations match; `failedConnectionBlockListShapeIsUnverified` and
      `failedConnectionExitsGroupTagMapsToGroupID` kept as verify-marked synthetic tests.
      Decision: `stripPort` strips the port off IP-literal hosts too (pre-existing
      behaviour, unchanged), so the game row is keyed `203.0.113.40`, not
      `203.0.113.40:27015` as written above — noted in the test's comment.)
- [x] `RecentHosts` and `BlockCounter` untouched unless they parse the id the same broken
      way — check and say.
      (2026-09-19: neither touches the connection id or `SingBoxLog`. `RecentHosts` is fed
      from Clash API `/connections` samples, not log lines, at all. `BlockCounter.
      isBlockedLine` matches on the raw, unstripped line — safe because the reject/
      predefined text it scans for never sits inside the ANSI-coloured id span. Left
      unchanged.)
- [x] `scripts/format.sh`; package tests via `xcodebuild` from `Wayfork/WayforkCore`;
      `xcodebuild` builds of the Wayfork and WayforkDaemon schemes.
      (2026-09-19: `scripts/format.sh` clean; `xcodebuild test -scheme
      WayforkCore-Package -destination 'platform=macOS'` → TEST SUCCEEDED; `xcodebuild
      -scheme Wayfork` and `-scheme WayforkDaemon` (same destination) → BUILD SUCCEEDED.)

**Done when:** the tests above pass on the fixture; both schemes build.

### 2. Windows

- [x] Go relay strips ANSI before `IsInterestingLogLine`; `failed.go` mirrors stage 1
      (same shapes, same guard, same suffix cut); tests read the same fixture file with
      the same expectations; `gofmt`, `go vet`, `go test ./...`, `GOOS=windows go build`.
      (2026-09-19: `stripANSI` added to `singboxlog.go`, applied in `SingBoxLogLevel` /
      `SingBoxLogMessage` — same relay boundary as the Swift side; `IsBlockedLine` still
      reads the raw, unstripped line, matching `BlockCounter` on macOS. `failed.go`'s
      `Ingest` rewritten in step with `FailedConnections.ingest` (`openedOutbound`,
      `failedConnection`, `stripUserSuffix` mirror the Swift helpers); the fixture tests
      moved into `wave_test.go` where the existing `FailedConnections` tests already
      lived, using a new `readFixtureLines` next to `readFixture` in `fixtures_test.go`.
      `gofmt -l .` clean; `go vet ./...` clean; `go test ./...` → all packages ok;
      `GOOS=windows go build ./...` clean.)
- [x] Flutter: nothing to change unless the Dart side parses log lines (check
      `lib/core` for `inbound connection to`); `dart analyze --fatal-infos` still clean.
      (2026-09-19: `lib/core` has no log-line parsing at all — confirmed by grep; no
      changes needed. `dart analyze --fatal-infos` → No issues found.)

**Done when:** Go tests pass on the fixture; the Windows build commands pass on macOS.

### 3. Docs

- [x] [05-daemon.md § Failed connections](../design/05-daemon.md): the line table and
      the reason paragraph rewritten from the fixture (keep the *(verify)* marks for the
      reject and group lines); § Counters by exit: opened at the outbound line.
      (2026-09-19: table and both paragraphs rewritten from the fixture; the block-list
      reject/predefined row and the group-tag note kept marked verify.)
- [x] [06-logging.md](../design/06-logging.md): a line that the relay strips ANSI.
      (2026-09-19: added under § Sources and levels.)
- [x] ROADMAP.md § M15 / M16 and ROADMAP-windows.md § WM16 / WM17: the parser half of the
      manual-check boxes noted as fixed from the live log on 2026-09-19; the visual walk
      stays with the maintainer.
      (2026-09-19: notes added to all four manual-check/PC-run boxes; boxes themselves
      left unticked since the visual walk is still owed.)
- [x] CHANGELOG *Unreleased › Fixed*: "*Can't reach* and *Connections* were empty: the
      tracker did not read sing-box 1.13's log (coloured ids, no match line, info-level
      failures)".
      (2026-09-19: added, first item under Unreleased › Fixed.)

## Session prompt *(one session, all stages; paste as is)*

```
Модель: sonnet, effort: high

You are working in /Users/fost/Projects/Wayfork (read CLAUDE.md: English in the repo,
swift-format via scripts/format.sh, gofmt/go vet in WayforkWindows/service, commit only
when asked, no AI trailers; never restart the installed Wayfork — build only). Task:
docs/roadmap/failed-connections-live-log.md, all three stages in order. Read that file
whole, then fixtures/logs/sing-box-1.13.19.log (it is the contract — `cat -v` it to see
the escapes), then Wayfork/WayforkCore/Sources/WayforkDaemonCore/SingBoxLog.swift and
FailedConnections.swift with their tests, Wayfork/Daemon/SingBoxEngine.swift around the
relay (grep isInteresting), WayforkWindows/service/internal/core/failed.go with its tests
and internal/service/clashhttp.go around Ingest, and docs/design/05-daemon.md § Failed
connections. Read big files by grep first, then ranges.

Do the checkboxes in order, ticking each in the roadmap file with a short
"(2026-09-19: …)" note when its check passes. The wire types and the app views do not
change. Put the fixture-reading helper next to the existing fixture helpers
(`Fixtures.url` in Swift; whatever the Go tests use for fixtures/clash). Redirect long
outputs to files under /private/tmp/claude-501/-Users-fost-Projects-Wayfork/39d0f58c-04c1-4f89-9e8c-95daa3ef3c35/scratchpad/
and read tails / grep for errors.

Hand back (concise, no logs): files touched, commands with pass/fail, every decision
beyond the roadmap (one line each), and what you found about RecentHosts / BlockCounter.
Do not commit.
```

## Risks

- The reject line shape is still unverified; a wrong guess only leaves *blocked by your
  list* rows empty, nothing else breaks.
- A group's outbound line may name the member, not the group; then F20 attributes the
  connection to the member's row. Documented as *(verify)*; fixed when a live log with a
  group is recorded.
