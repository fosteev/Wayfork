# Connections by exit — F20

> Status: approved · created 2026-09-18 · § Feature approved 2026-09-18 (ROADMAP.md § F20,
> M16 / WM17) · stage 2 done 2026-09-18 · stage 3 (M16, macOS) and stage 4 (WM17,
> Windows) done 2026-09-18 · stage 5 owed: the manual walks (macOS, PC), F19 live check,
> CHANGELOG, release. The executing session ticks the checkboxes below as it goes; statuses live
> here and in the milestone skeletons ROADMAP.md § M16 / ROADMAP-windows.md § WM17 only.

## Goal

The Logs window answers "which exit is failing, and how badly?" with one table: every
tunnel, every group and *Not via any tunnel*, with how many connections went through it
since Turn On, how many sing-box could open, how many it could not, and the failure rate —
on macOS and Windows, from the log lines the F19 tracker already reads.

## Context and constraints

- Prototype: [design/prototype/variant-c.html](../design/prototype/variant-c.html) board
  **C9** (drawn 2026-09-18) — the segment `Log · Connections` in the Logs toolbar, the
  table, the expanded exit with its F19 rows, the popover entry points, the dark
  *Last 5 min* callout, and the note with the decisions. Windows twin not drawn yet
  (stage 2).
- F19 is the base: `FailedConnections` in
  [WayforkDaemonCore/FailedConnections.swift](../../Wayfork/WayforkCore/Sources/WayforkDaemonCore/FailedConnections.swift)
  and [internal/core/failed.go](../../WayforkWindows/service/internal/core/failed.go)
  already join sing-box's lines by connection id and know, per connection, the exit
  (`match[N] rule => t-<id>` / `g-<id>` / `direct`, `no match, using <tag>`) and the
  failure (`ERROR … open connection to …`). The design is
  [05-daemon.md § Failed connections](../design/05-daemon.md); the pane is
  [06-logging.md § Logs window](../design/06-logging.md).
- **F19 has not been checked live yet** (ROADMAP.md § M15 and ROADMAP-windows.md § WM16,
  the manual-check boxes). Its line shapes were written from sing-box's source. F20 counts
  from the same lines, so the F19 check gates stage 3 — see *Working order*.
- Verdict of the 2026-09-18 review (kept in the C9 note): no separate window — a second
  view of the Logs window; counts are connections, not requests; both counters come from
  the log, not the Clash API (`/connections` lists live connections only and misses
  anything shorter than a sample); a *reached* connection says nothing about what happened
  inside it.
- Decisions taken for the plan (assumptions are marked):
  - **Opened** = one per connection id at the `=> <outbound>` / `using <outbound>` line
    (that is where the exit becomes known; `inbound connection to` lines without a match
    line are not counted — assumption: sing-box prints the match line for every routed
    connection at `info`, the same assumption F19 makes for the *Via* column).
    **Failed** = one per `ERROR … open connection to` line, attributed to the exit the
    tracker had for that id (`direct` when none). **Reached** = opened − failed, computed
    in the app. `=> reject` on the block list is counted separately as **blocked** and is
    excluded from opened, failed and the total (C9's dimmed row).
  - The daemon keeps cumulative counters since Turn On; **Last 5 min and Reset live in the
    app** — the app already receives a snapshot every second, keeps a 5-minute ring of the
    cumulative counters and subtracts; *Reset* stores a baseline. No protocol for either,
    same code on both platforms.
  - At log detail *Problems* (sing-box `log.level` above `info`) the match lines are
    absent: `opened` is `nil` on the wire, the table shows *Failed* only, no rate, and the
    same "needs log detail Normal" hint the F19 pane and the block counter use.
  - Wire: `TrafficSnapshot.exits: [String: ExitStats]` keyed by exit id (`direct`, a
    tunnel id, a group id), `ExitStats { opened: Int?, failed: Int, blocked: Int,
    lastFailure: FailureReason?, lastFailedAt: Date? }`; optional on the wire like
    `failedHosts`, `blocked` only present under the `direct` key. Cleared with
    `FailedConnections.clear()` (Turn Off), kept across a sing-box restart.
  - Entry points: the toolbar segment; popover footer *Connections ⇧⌘L*; *Details* on a
    tunnel card whose `exits[id].failed > 0` in the last 5 min; the F19 red line keeps
    opening the *Log* view (its rows are there). Opening from the popover preselects the
    *Connections* view the way `takePreselectedSearch()` preselects the search.
  - Sorting: fixed — tunnels in the popover's order, groups after their members, *Not via
    any tunnel*, *Blocked by your list* last. No column sorting in this round.

### Decisions (2026-09-18, after the stage-3 review)

Taken by the stage-3 session and kept, or made at the review; the Windows stage mirrors
them.
- View strings live in `WayforkCore/App/ExitsText.swift` (a sibling of `FailedText`, which
  is untouched).
- No fixture file: the line shapes are the inline arrays of
  `FailedConnectionsTests.swift`; the Go tests mirror the same five cases (per-exit
  opened/failed/blocked, group tag → group id, `direct` with no match line, nil opened
  under ERROR-only input, reset on `clear()`).
- `opened` counts once per connection id, guarded by the pending entry's `exit` being unset
  at the first match / `using` line; `blocked` is always under `direct`, never per exit.
- *Details* is on tunnel cards only; group cards do not get it (a group's failures show on
  the member's card).
- *Reset* takes a baseline for *Since Turn On* only; *Last 5 min* always subtracts from the
  ring. The header's "since" switches to the Reset time once one happened. `lastFailure`
  in *Last 5 min* is shown only when it falls inside the window.
- The *Problems* hint reads the wire (`opened == nil` for every exit) and, while no exit
  has been seen at all, the log-level setting like the F19 pane (review fix).
- The rate is clamped to 100 % — an ERROR without its match line (log detail switched
  mid-run) can put failed above opened (review fix); a 0 % bar is empty, not a 2 px stub.
- *Copy* on the Connections view writes the table tab-separated (header, rows, total).
- Windows: the flyout has no footer item, so the tray menu gets `Connections` next to
  `Logs` (08-windows.md); the Logs page keeps the segment control W16 already uses.

Stage 4 (Windows, 2026-09-18):
- The `Log · Connections` toggle pair sits on its own row above the Logs page's filter
  row — inline it overflowed at the width `app_shell_test.dart` renders.
- `FailedRow` (was `_FailedRow`) is public and reused for the expanded exit; the tray entry
  is `TrayCommandShowConnections` through `AppNavigator.showConnections()`.
- *Reset* is disabled while not running.
- Test harness: a widget test that boots the model *on*, feeds traffic and pumps
  `LogsPage` leaves the 30 s traffic-stale timer pending at teardown (pre-existing, not
  F20's); the new tests end with `drainTrafficStaleTimer(tester)`. Fixing the timer's
  disposal is a separate chore.

## Feature

**F20. Connections by exit** *(proposed 2026-09-18; approved 2026-09-18 — ROADMAP.md § F20 / M16)*
- The user's question: "is it the tunnel or the site?" — one exit failing for many hosts
  looks, in the F19 pane, like many unrelated failures. F20 sums them per exit: the Logs
  window gets a second view, **Connections**, chosen by a `Log · Connections` segment in
  its toolbar. One row per exit — every tunnel, every group (with the member it is using),
  *Not via any tunnel*, and a dimmed *Blocked by your list* row outside the totals —
  with **Connections** (opened through the exit since Turn On), **Reached** (sing-box
  opened them), **Failed** (it could not), the **fail rate** with a bar (grey ≤ 1 %, amber
  ≤ 5 %, red above), and the last failure's reason and time. A total row at the bottom.
- Clicking an exit expands the F19 rows that went through it (site, app, tries, why, when)
  with *Route via ▾* on hover. `Since Turn On · Last 5 min` switches the window; *Reset*
  zeroes the counters. Opened from the popover footer (*Connections ⇧⌘L*), from *Details*
  on a tunnel card whose connections fail, and by the segment.
- Data: the F19 tracker already sees, per connection id, the chosen outbound and the
  failure; F20 adds two counters per exit next to the rows and forwards them in the
  traffic snapshot. Same lines for the numerator and the denominator; the Clash API is
  not used. At log detail *Problems* only the failed column is available.
- Numbers are connections, not requests, and *reached* means the dial succeeded — an
  HTTP 403 or a stalled download inside a reached connection is invisible. Not a live
  connection view (L2) and no history across Turn Off.
- Boards: `variant-c.html` C9; `windows.html` W17 (stage 2).

## Stages

### 1. Feature entry and approval

The feature text goes into ROADMAP.md only after the maintainer approves it; the
milestone skeletons point back here.

- [x] Maintainer approves § Feature (in as many words) or strikes parts of it. — 2026-09-18, as written.
- [x] On approval: § Feature copied into ROADMAP.md Phase 1 after F19 as **F20**
      *(added 2026-09-18; approved …)*; Phase 2 § UI prototype gains the C9 line; M16 and
      WM17 skeletons in ROADMAP.md / ROADMAP-windows.md with the checkboxes of stages 3–4.
- [x] Banner of this file → *approved* (2026-09-18).

**Done when:** `grep -n 'F20' docs/ROADMAP.md` shows the feature and the M16 skeleton.

**Session:** this one (opus), sequential.

### 2. Prototype and design notes

The Windows twin of C9 and the design paragraphs the implementation sessions read.

- [x] `windows.html`: board **W17** — the Logs page with a `Log · Connections` segment,
      the same table in fluent_ui idiom (mirror C9; the dark callout may be skipped). —
      2026-09-18: added after W16 (single-column board, dark callout skipped per the
      note above), TOC entry added, `.strip.cx` CSS mirrored under `.vc`.
- [x] [05-daemon.md](../design/05-daemon.md) § Failed connections: a paragraph *Counters
      by exit* — the two counters, where in the join they increment, `blocked`, the
      `nil` at *Problems*, `ExitStats` on the wire, cleared on `stop`. — 2026-09-18.
- [x] [06-logging.md](../design/06-logging.md) § Logs window: the *Connections* view —
      columns, the rate thresholds, expand → F19 rows, the 5-minute ring and *Reset* in
      the app, entry points and the preselect. — 2026-09-18.
- [x] [02-ux.md](../design/02-ux.md) § Variant C: wording of the view (header, column
      titles, `not counted as failures`, the *Problems* hint, the footer item). —
      2026-09-18.
- [x] [08-windows.md](../design/08-windows.md): the delta line (segment on the Logs page,
      flyout entry). — 2026-09-18: added as a WM17 bullet next to WM16's Can't reach one.

**Done when:** the four docs carry the paragraphs and W17 renders in a browser without
console errors; the maintainer approves the notes ("ок").

**Session:** sonnet, effort medium — the board mirrors C9 element for element and the
notes are the decisions above written out; sequential after stage 1 (touches the same
docs the skeletons link to).

### 3. macOS (M16)

Core types, the daemon counters, the app view. One session, one commit series
(`feat(core)`, `feat(daemon)`, `feat(app)`), tests alongside.

- [x] `WayforkCore`: `ExitStats` in `XPC/Payloads.swift`, `TrafficSnapshot.exits`
      (optional on the wire, `[:]` default), `FailedText` strings for the view. — 2026-09-18:
      strings went into a sibling `ExitsText.swift` instead of `FailedText` itself, to keep
      the F19 pane's strings from growing an unrelated section (see hand-back decisions).
- [x] `WayforkDaemonCore.FailedConnections`: `opened[exit]` at the match / `using` line,
      `failed[exit]` + `lastFailure` at the `ERROR` line, `blocked` at the block-list
      `reject`; `exits` computed property; `clear()` resets them; `opened` is `nil` while
      no match line has been seen since the last `clear()` (the *Problems* case). — 2026-09-18.
- [x] `FailedConnectionsTests`: opened / failed / blocked per exit on the recorded line
      shapes, the group tag → group id, `direct` when no match line preceded the error,
      `nil` opened under *Problems*-only input, reset on `clear()`. — 2026-09-18: extended
      the two existing tests plus two new ones, all inline (no new fixture file — see
      hand-back decisions).
- [x] Daemon: `exits` filled into the snapshot next to `failedHosts`. — 2026-09-18.
- [x] App model (`AppModel+Failed` or a new `AppModel+Exits`): the 5-minute ring of
      snapshots, the baseline for *Reset*, rows for the view in the fixed order with the
      group's *using* member from `groups`, the rate class, `Details` visibility per card.
      — 2026-09-18: new `AppModel+Exits.swift`.
- [x] `LogsWindowView`: the `Log · Connections` segmented picker in the toolbar (the
      source / level / search controls hide under *Connections*; *Reset* and *Copy*
      show), `ExitsView` per C9 (columns, bar, expand → the F19 rows filtered by exit
      with the same row actions as `FailedPaneView`, the total row, the dimmed blocked
      row, the *Problems* hint, the empty state). — 2026-09-18: new `ExitsView.swift`;
      `FailedRowView` un-privated for reuse.
- [x] Popover: footer item *Connections ⇧⌘L*, *Details* on a card with recent failures;
      both open the Logs window with the *Connections* view preselected. — 2026-09-18:
      *Details* added to `TunnelCardView` only (groups out of the literal contract — see
      hand-back decisions).
- [x] `scripts/format.sh`; package tests via `xcodebuild` from the package directory
      (see the build quirks memory); the app builds in Xcode — **do not restart the
      installed Wayfork**, the maintainer installs. — 2026-09-18: all green (see hand-back
      for exact commands).

**Done when:** `xcodebuild test` of `WayforkCore` passes with the new tests; the app
builds; a fixture-driven `FailedConnections` sample yields the C9 numbers for a hand-made
line file; the maintainer's manual check (stage 5) is listed, not done, by the session.

**Session:** sonnet, effort high (the SwiftUI view has a board but no reference view of
this shape; the daemon half is a two-counter addition to known code). Sequential after
stage 2.

### 4. Windows (WM17)

Mirror of stage 3 on the Go service and the Flutter app, on the same fixtures.

- [x] `internal/core/failed.go`: the counters and `ExitStats` (`exits` in the snapshot
      JSON, same keys and optionality as macOS; `opened` omitted when nil); tests on the
      shared line shapes; `go test ./...` on macOS and `GOOS=windows go build ./...`. —
      2026-09-18: counters added to `FailedConnections` + `Exits()` accessor; `ExitStats`
      in `status.go` next to `FailedHost`; wired into `TrafficSnapshot.Exits` and the
      service's snapshot builder (`clashhttp.go`); five cases mirrored in `wave_test.go`
      (extended `TestFailedConnectionsJoin`, two new tests); `gofmt -l`, `go vet ./...`,
      `go test ./...`, `GOOS=windows go build ./...` all clean.
- [x] Dart core: `ExitStats` decoding, the 5-minute ring and the baseline. — 2026-09-18:
      `ExitStats` in `payloads.dart` (`TrafficSnapshot.exits`); new `app_model_exits.dart`
      (`ExitRow`/`ExitsTotals`/`AppModelExits`) mirrors `AppModel+Exits.swift` — ring fed
      from `_handleTraffic`, baseline from `resetExits()`, tracking cleared on Turn On;
      `ExitsText` added to `feature_text.dart` next to `FailedText`.
- [x] `logs_page.dart`: the segment, `ExitsTable` per W17 reusing `FailedPane`'s row for
      the expansion; the flyout entry; `dart format`, `dart analyze --fatal-infos`,
      `logs_page_test.dart` extended. — 2026-09-18: `Log · Connections` ToggleButton
      segment (own row, to avoid a `RenderFlex` overflow at narrow window widths);
      `FailedRow` un-privated (was `_FailedRow`) and reused for the expanded exit; tray
      gets a `Connections` entry (`TrayCommandShowConnections`, `AppNavigator.
      showConnections()`) since the flyout has no footer; `tray_menu_test.dart` updated
      for the new entry; 5 new `logs_page_test.dart` cases. `dart format`, `dart analyze
      --fatal-infos`, `flutter test` (this project has no bare `dart test` target) all
      clean, 357 tests green.
- [x] Fixtures: stage 3 added no line file — the Go tests mirror the cases of
      `FailedConnectionsTests.swift` (decision above); nothing to share. — 2026-09-18.

**Done when:** `go test ./...`, `dart test`, `dart analyze --fatal-infos` pass; the
service and app build; the PC run (stage 5) is listed, not done.

**Session:** sonnet, effort medium; sequential after stage 3 (the contract is fixed by
the Swift side and the fixture file).

### 5. Manual checks and ship

Everything only the maintainer can see, batched with the F15–F19 checks that are
already owed.

- [ ] F19 live check first (ROADMAP.md § M15 box): the line shapes match the pinned
      sing-box. If they do not, F19 is fixed before F20 is judged.
- [ ] macOS: with one tunnel deliberately down (wrong port), `curl` through it five times
      and through direct once — the table shows the tunnel at 100 %, direct at 0 %, the
      expanded tunnel lists the host with `‹tunnel› is down`, *Last 5 min* and *Reset*
      behave, *Details* appears on the card, ⇧⌘L opens the view, *Problems* shows the hint.
- [ ] Windows PC run (`ssh wf-pc`): the same walk on the Logs page.
- [ ] CHANGELOG entry, README screenshot if the Logs window is pictured, milestone
      boxes ticked, banner here → *done*.

**Done when:** the maintainer says so; release per `scripts/release.sh` on request.

**Session:** maintainer + this session (opus) for the follow-ups.

## Session prompts

### Stage 2 — W17 board and design notes *(paste as is)*

```
Модель: sonnet, effort: medium

You are working in /Users/fost/Projects/Wayfork (read CLAUDE.md: English in the repo,
commit only when asked, no AI trailers). Task: stage 2 of docs/roadmap/connections-by-exit.md
— the Windows board W17 and the design notes for F20. Read that file first (the whole
thing), then docs/design/prototype/variant-c.html board C9 (the section with id="C9" and
the CSS block "C9 · Connections by exit"), then the F19 paragraphs in
docs/design/05-daemon.md, 06-logging.md, 02-ux.md and 08-windows.md.

1. docs/design/prototype/windows.html: add board W17 after W16 — the Logs page with a
   "Log · Connections" segment and the same table as C9 (rows, columns, bar, expanded
   exit with the F19 rows, total row, dimmed blocked row) in the file's fluent_ui idiom;
   add the TOC entry. Reuse W16's styles where they fit; keep the note short and point at
   C9 for the reasoning. No scripts, no external resources.
2. Design notes, one paragraph each, per the checkboxes of stage 2 in the roadmap file —
   write only what the decisions in § Context say; mark anything you had to assume with
   "(verify)" as the other docs do.
3. Tick the stage-2 checkboxes in docs/roadmap/connections-by-exit.md as you finish them.
   Do not touch ROADMAP.md, code, or the banner.

Hand back: the list of files touched and anything you had to assume. Do not commit.
```

### Stage 3 — macOS M16 *(paste as is)*

```
Модель: sonnet, effort: high

You are working in /Users/fost/Projects/Wayfork (read CLAUDE.md: English in the repo,
swift-format via scripts/format.sh, commit only when asked, no AI trailers; never restart
the installed Wayfork — build only). Task: stage 3 (M16) of
docs/roadmap/connections-by-exit.md — F20 "Connections by exit" on macOS. Read the roadmap
file whole; the contract is its § Context "Decisions". Then read: board C9 in
docs/design/prototype/variant-c.html (id="C9"), the F20 paragraphs in
docs/design/05-daemon.md and 06-logging.md (stage 2 wrote them),
Wayfork/WayforkCore/Sources/WayforkDaemonCore/FailedConnections.swift and its tests,
Wayfork/WayforkCore/Sources/WayforkCore/XPC/Payloads.swift (TrafficSnapshot),
Wayfork/App/Views/Logs/LogsWindowView.swift, FailedPaneView.swift,
Wayfork/App/Model/AppModel+Failed.swift, and the popover footer / tunnel card views.

Do the stage-3 checkboxes in order (core → daemon → app), ticking each in the roadmap
file when its tests pass. Rules: the wire field is optional with a [:] default so an
older daemon still decodes; `opened` is nil until a match line is seen; blocked is not a
failure and not in the total; Last 5 min and Reset are app-side (ring of snapshots +
baseline), nothing new in the XPC protocol beyond the field; fixed row order as in the
roadmap. Tests: FailedConnectionsTests on the recorded line shapes (put a hand-made line
file under fixtures/ if you need one, and describe it in fixtures/README.md so the Go
and Dart tests can share it). Run scripts/format.sh, the package tests via xcodebuild
from Wayfork/WayforkCore, and build the app scheme.

Hand back: files touched, test command and result, every decision you took beyond the
roadmap (one line each), and the manual check you could not do. Do not commit.
```

### Stage 4 — Windows WM17 *(paste as is)*

```
Модель: sonnet, effort: medium

You are working in /Users/fost/Projects/Wayfork/WayforkWindows (read ../CLAUDE.md: English,
dart format + dart analyze --fatal-infos in app/, gofmt + go vet in service/, go test must
pass on macOS, GOOS=windows go build ./... must pass; commit only when asked, no AI
trailers). Task: stage 4 (WM17) of ../docs/roadmap/connections-by-exit.md — the Windows
mirror of F20. Read the roadmap file whole; the wire contract is what stage 3 shipped in
Wayfork/WayforkCore/Sources/WayforkCore/XPC/Payloads.swift (ExitStats, TrafficSnapshot.exits) and the five cases of
Wayfork/WayforkCore/Tests/WayforkDaemonCoreTests/FailedConnectionsTests.swift (no fixture
file was added — mirror those cases in Go); the § Decisions block after § Context lists
what stage 3 settled (Reset/Last 5 min semantics, rate clamp, Problems hint, Copy, tray
entry) — follow it. Then read board W17 in ../docs/design/prototype/
windows.html, ../docs/design/08-windows.md, service/internal/core/failed.go and its tests,
app/lib/app/ui/pages/logs_page.dart and test/app/ui/logs_page_test.dart.

Do the stage-4 checkboxes in order (Go → Dart core → Flutter page), ticking each in the
roadmap file when its tests pass. Same keys, same optionality, same 5-minute ring and
baseline in the app, same fixed row order. Reuse FailedPane's row widget for the expanded
exit. Run gofmt, go vet, go test ./..., GOOS=windows go build ./..., dart format, dart
analyze --fatal-infos, dart test.

Hand back: files touched, commands and results, decisions beyond the roadmap, and the PC
run you could not do. Do not commit.
```

## Risks and open questions

- **F19 line shapes unverified live** — F20 inherits them. Known early by doing the M15
  manual check before stage 3 starts; cost of skipping it: two features rewritten at once.
- **`=> outbound` line for every connection** (assumption) — if sing-box prints the
  match line only for rule hits and not for `no match, using direct`, direct's `opened`
  undercounts. The tracker already parses `using `; stage 3's tests pin both shapes, the
  live check confirms.
- **Errors without an `info` prelude** (log detail *Problems*): the failure has a host but
  no exit — attributed to `direct`. Acceptable while `opened` is nil and no rate is shown;
  documented in the hint.
- **UDP**: `inbound packet connection to` opens a "connection" per flow; a QUIC-heavy site
  inflates the count. Counts are labelled connections; the rate is what matters.
- **Snapshot size**: one small dictionary per second — negligible next to `failedHosts`.
- Open for the maintainer: (a) approve § Feature; (b) is *Details* on the tunnel card
  wanted, or only the footer item and the segment? Default if silent: as drawn in C9.

## Working order

1 (approval, here) → 2 (W17 + notes, sonnet) → **M15 / WM16 live check by the
maintainer** → 3 (macOS, sonnet, high) → 4 (Windows, sonnet) → 5 (checks + ship). Strictly
sequential: one repo, shared docs and fixtures. Stage 2 may run while the maintainer does
the M15 check; stage 3 does not start before that check passes. — 2026-09-18: the
maintainer waived the gate; stage 3 starts with the M15 check still owed, so the F19 line
shapes are confirmed (or both fixed) at stage 5.
