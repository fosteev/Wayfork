# First-run guide — F22

> Status: M18 implemented and accepted 2026-09-25 (builds, 192 tests green); the manual run
> on a clean macOS user is owed by the maintainer. Next: stage 5 (Windows) and 6 (release bits). · created 2026-09-25 · macOS M18, Windows WM20 (numbers reserved, not yet
> in the roadmaps). The executor ticks the checkboxes as the work goes; statuses live here
> until F22 is added to [ROADMAP.md](../ROADMAP.md) and [ROADMAP-windows.md](../ROADMAP-windows.md).

## Goal

A new user who has just installed Wayfork ends the first launch with a working setup: the
helper is approved, one tunnel is added, one site goes through it, and they know how to
check where a site goes and what to do when a site does not open. Everything else stays
discoverable, not taught.

## Context and constraints

- What exists (checked):
  - Helper approval on the first **Turn On** is designed in
    [02-ux.md › First run and helper approval](../design/02-ux.md) (alert + 1 s polling).
  - The *No tunnels yet* popover state is drawn in
    [variant-c.html](../design/prototype/variant-c.html) (the C2 popover states: disabled
    switch, one heading, one sentence, one action; quick add and Recent hidden) and
    implemented around `macos/App/Views/Settings/TunnelsSettingsView.swift`.
  - Windows: board `#W8` in [windows.html](../design/prototype/windows.html) — first run is
    an empty Tunnels page with drag-to-import; `windows/app/lib/app/ui/pages/tunnels_page.dart`.
  - No guide, no "seen" flag, no replay anywhere.
- Constraints: phases in order (Features → Design/prototype → Implementation), each shown
  to the maintainer and approved; prototypes are local HTML in `docs/design/prototype/`,
  never published; the live Wayfork is never restarted from a session (UI is checked by
  the maintainer); README screenshots come from the prototypes
  (`scripts/render-screenshots.mjs`).
- Decisions taken for the draft (the maintainer may overturn them at stage 1):
  - **The guide does real setup, not slides.** Each step is the real action (approve,
    import, add rule, turn on, test) in a small window; a slide tour teaches a model the
    user forgets by the next screen.
  - **No coach marks over the popover.** A `MenuBarExtra(.window)` popover closes on focus
    loss and has no stable overlay layer; highlighting its controls is fragile.
    *Assumption*, not tried in code.
  - **Shown when the store has no tunnels and the guide was never finished or skipped.**
    Existing users upgrading to the release do not see it. Replay: General →
    *Show the welcome guide*.
  - **macOS first, Windows twin after the macOS boards are approved**, the same way
    variant C → W9–W15 went.

## What to teach — draft for approval

The mental model, one sentence on the first screen: *"Wayfork sends the sites you choose
through the VPN you choose; everything else goes direct."* Every step below serves that sentence.

**Taught in the guide (the setup path, in this order):**

| # | Step | Features | Why it is in the guide |
|---|------|----------|------------------------|
| 0 | Welcome: the one-sentence model + a picture (sites → tunnels, rest → direct) | — | Without it, "rules" and "tunnels" mean nothing |
| 1 | Allow the helper — explained *before* the system prompt, then polled | F3, 05-daemon | Nothing works without it; the macOS dialog alone is scary. Windows: service check only (the installer registers it) |
| 2 | Add a tunnel: drop an `.ovpn`, paste a `vless://`/other link or a subscription URL | F1, F13 | The one thing only the user can supply |
| 3 | Pick the first sites for it: a text field with a placeholder (no preset site list), with the "subdomains included" note | F2 | Teaches the rule by making one |
| 4 | Turn On, see the tunnel go green in a mini copy of the popover card | F3, F4, F9 | Shows where status lives (menu bar icon → popover) |
| 5 | Open one of those sites and see it go through the tunnel (skippable) | F9, F15/F20 sampler data | Proves it works. Not the rule tester: L2 is not implemented |

**Taught after the guide, as a dismissible "Getting started" card in the popover** (one
line each, ticked when the user does it once, card gone after all or on ✕):

- Add a site from the popover in one click — quick add and **Recent** (F15).
- A site does not open → **Can't reach** shows it and offers the fix (F19).
- Route a whole app, not a site (F10).

**Not taught — discovered through the UI and the README:** default tunnel and exceptions
(F8), IP rules (F11), resolver override (F12), latency (F14), groups (F16), proxy port
(F17), block lists (F18), connections by exit (F20), logs and diagnostics (F5),
import/export (F7), `wayforkctl` (F21).

Decided at stage 1 (2026-09-25): upgrading users never see the guide (maintainer); no
preset site list in step 3 — a list of "sites to unblock" is a political statement
baked into the product; step 5 is skippable. Step 5 was the rule tester in the draft,
but L2 rule testing is not implemented (the C5 Probe line waits for it, M9), so it
uses the traffic sampler instead; which data exactly — stage 3.

## Stages

### 1. Features — F22 approved

Turn the draft above into the F22 entry and get the "ок".

- [x] Show the maintainer the *What to teach* section; record the answers to the open questions — 2026-09-25
- [x] Add **F22. First-run guide** to `docs/ROADMAP.md` › Phase 1 (scope, taught / card / not taught, trigger and replay) — 2026-09-25
- [x] Windows deltas go into the F22 entry itself (like F21): `ROADMAP-windows.md` has no
      feature list past F12, only milestones; WM20 lands there at stage 5 — 2026-09-25
- [x] Update this file's banner — 2026-09-25

**Done when:** `grep -n 'F22' docs/ROADMAP.md` finds the entry and the maintainer said "ок". Done 2026-09-25.

**Session:** opus, effort medium — this session; judgment only, no code. Sequential: everything else depends on it.

### 2. macOS prototype — boards C10–C12

Static HTML, light and dark, in the variant C style.

- [x] New file `docs/design/prototype/first-run.html`, CSS copied from `variant-c.html`, linked from its table of contents — 2026-09-25
- [x] Board C10 · Guide window, happy path: 8 frames (welcome, helper, add VPN, name + login, choose sites, turned on, try it, done), step rail instead of dots, *Skip* / *Back* / *Continue* — 2026-09-25
- [x] Board C11 · States (dark): helper waiting, import error + bad link, can't connect with *Continue anyway*, off before the switch — 2026-09-25
- [x] Board C12 · Popover with the *Getting started* card (fresh; two of three done, dark), No-tunnels popover with *Continue setup*, General replay rows — 2026-09-25
- [x] Decisions (10) and open questions in a comment at the top of the file — 2026-09-25
- [x] Layout check: every guide frame fits its 600 × 410 window, nothing sticks out (headless Chrome, measured, no screenshots) — 2026-09-25
- [x] Show it to the maintainer, iterate, record approval in `docs/ROADMAP.md` › UI prototype — approved 2026-09-25 as drawn, incl. the *only these / everything except* choice in step 4

**Done when:** the file opens locally (`open docs/design/prototype/first-run.html`), every step from *What to teach* has a frame, the maintainer approved the boards.

**Session:** opus, effort medium — layout without a reference is judgment. After stage 1.

### 3. Design — 02-ux.md and data

- [x] Step 6 data: the daemon only records default-route hosts, so the tunnel side is proven by `ExitStats.opened` growth (or the download rate when `opened` is nil) after the *Open* click, the direct side by a `RecentHost` — 2026-09-25
- [x] `02-ux.md` § First-run guide (F22) — window (AppKit `NSWindow`: SwiftUI `openWindow` is not available at launch), trigger, steps table, card, resume, replay; the helper alert section kept for non-guide paths — 2026-09-25
- [x] `01-data-model.md` § Persistence: `GuideState` in UserDefaults (`WayforkGuideState`), not in the store — 2026-09-25
- [x] Reused functions named per step in the 02-ux table — 2026-09-25
- [x] Add M18 to `docs/ROADMAP.md` › Phase 3 with the implementation checklist — 2026-09-25
- [x] Subscription with several servers kept: step 4 names the first one; the group draft is dropped — 2026-09-25

**Done when:** M18 exists with checkboxes. Done 2026-09-25 (the maintainer's "давай реализовывать" after the prototype covers the design; deviations from the boards are listed in 02-ux).

**Session:** opus, effort medium. After stage 2 (the prototype fixes the strings).

### 4. macOS implementation — M18

- [x] Flag + trigger in `AppModel` (no tunnels ∧ not finished ∧ not skipped), unit-tested in `WayforkCore`/app tests — 2026-09-25
- [x] Guide window (AppKit `NSWindow` + `NSHostingController`, per the "Already decided"
      note below — not a SwiftUI `Window` scene, unavailable at launch), steps wired to the
      existing actions and sheets — 2026-09-25
- [x] Helper step drives the existing `SMAppService` flow and its polling — 2026-09-25
- [x] *Getting started* card in the popover + the three "done" signals — 2026-09-25
- [x] General › *Show the welcome guide* — 2026-09-25
- [x] swift-format, `xcodebuild` tests (from the package dir, see the build quirks), app builds — 2026-09-25
- [ ] Manual check list for the maintainer (fresh user account or wiped Application Support)

Acceptance review 2026-09-25 (own pass + `/code-review`), fixed in place:
- Step 6 proved the wrong exit in the *everything except* mode (it waited for tunnel
  traffic while the user's sites go direct there). `GuideTryItCheck.Result` is now
  `sitesProven` / `otherHost`, both mode-aware; new test for the direct exit.
- *Finish* unlocked on the "went direct" line alone; now only on the user's-site line, which
  also names the site actually opened.
- Step 4 accepted anything as a chip and ignored `quickAdd` errors; now validated per chip.
  Back + Continue again stacked a second set of rules and kept a default tunnel set by the
  first pass; now undone first.
- `openGuide` on an open window overwrote the step later saved as `stoppedAt`; resume
  without tunnels could land on a step with no tunnel; auto-open ran on a store refused as
  newer. All three fixed.
- Accepted as is: the executor's deviations listed in 02-ux › Implementation notes (M18).

**Done when:** tests pass, app builds, the maintainer ran the guide on a clean profile.

**Session:** sonnet, effort medium, background subagent; the prompt is written at the end of stage 3 from M18 (views follow the approved boards 1:1). Acceptance: `/plan-review`.

### 5. Windows twin — boards W18–W19, WM20

- [ ] Boards W18–W19 in `windows.html` ported from C10–C11 (no helper step; service-missing reuses `#W8`), approved
- [ ] `08-windows.md` delta + WM20 in `docs/ROADMAP-windows.md`
- [ ] Flutter implementation, `dart format` + `dart analyze --fatal-infos`, tests; live check on `ssh wf-win`

**Done when:** WM20 checked off, maintainer approved the live run.

**Session:** boards and design — opus, effort low (port of an approved design); implementation — sonnet, effort medium. After stage 4 or in parallel with it (different app, the contract is the approved design; no shared files except `docs/`).

### 6. Release bits

- [ ] `scripts/render-screenshots.mjs`: add the C10 welcome frame; README › First run points at the guide
- [ ] CHANGELOG entry

**Done when:** `node scripts/render-screenshots.mjs` renders the new shot; README updated.

**Session:** sonnet, effort low. Last.

## Session prompts

### Stage 4 — M18 macOS

```
Stage 4 — F22 first-run guide, macOS (M18) · Model: sonnet, effort: high · after stage 3

Work in /Users/fost/Projects/Wayfork. Task: build the first-run guide window, the Getting
started card and the resume/replay entry points in the macOS app, as designed. New code on
top of existing model functions; no new routing or daemon behaviour.

Read: docs/roadmap/first-run-guide.md (this file); docs/design/02-ux.md § "First-run guide
(F22)" (the spec — steps table, card, resume, replay); docs/design/01-data-model.md §
Persistence, the GuideState bullet; docs/design/prototype/first-run.html boards C10–C12
(layout and every string; open it in a text editor, the design notes are the comment at
the top). Repo rules: CLAUDE.md.

Entry points (checked while planning — open only the fragment you change):
- macos/App/WayforkApp.swift — scenes; macos/App/AppDelegate.swift:6
  applicationDidFinishLaunching — auto-open goes here.
- macos/App/Model/AppModel.swift: `update(_:)` ~752 (every store mutation), `status:
  RuntimeStatus?` :27, `traffic: TrafficSnapshot?` :37, `setDefaultTunnel(_:)` :252,
  `toggle()` :365 / `turnOn()` :371, `private func ensureHelperApproved()` :482,
  `openSettings(section:tunnel:focus:)` and `openLogs(source:search:connections:)` ~952–968,
  `SettingsSection` :13 (`.tunnels, .rules, .general`).
- macos/App/Services/HelperInstaller.swift: `state` :21, `register()` :33,
  `static openLoginItems()` :65, `waitUntilEnabled(pollEvery:timeout:)` :70.
- macos/App/Model/AppModel+Tunnels.swift: `importOpenVPNFromPicker()` :15,
  `importOpenVPN(from:)` :26 (appends the tunnel; the new tunnel is the last one),
  `setCredentials(tunnelID:username:password:)` :135, `importWireGuard(from:)` :197,
  `rename(tunnelID:to:)` :395. `OpenVPNMeta.needsCredentials` tells step 3b to show login.
- macos/App/Model/AppModel+Rules.swift: `quickAdd(input:target:)` :9, `addRule(pattern:match:target:)` :34;
  `RuleTarget` = `.tunnel(UUID) | .group(UUID) | .direct` (WayforkCore Model/Rule.swift:28).
- macos/App/Views/Settings/AddLinkSheet.swift:8 — `AddLinkSheet(mode: .add)`; add an
  `initialText: String = ""` parameter that pre-fills the field, nothing else changes.
- macos/App/Views/Settings/SettingsView.swift:27-40 — the existing .ovpn/.conf drop filter;
  copy it for the guide's drop zone.
- macos/App/Views/Popover/PopoverView.swift: `body` :9-47, `emptyState` :108.
- macos/App/Views/Settings/GeneralSettingsView.swift — two new rows.
- macos/App/Views/Logs/FailedPaneView.swift:7 — tick "cantReach" in its onAppear.
- Card tick call sites: popover quick add and Recent "Route via" (in the popover views,
  not inside `quickAdd`, which the guide also calls); app rule save at
  macos/App/Views/Settings/RulesSettingsView.swift:356-372.
- WayforkCore XPC/Payloads.swift: `TunnelState` :39, `RuntimeStatus.tunnels` :66,
  `TrafficSnapshot.recentHosts` :257 (`RecentHost.exit` is "direct" or a tunnel id; only
  default-route hosts), `TrafficSnapshot.exits: [String: ExitStats]` :267, `ExitStats.opened: Int?` :443.
- Tests: macos/WayforkCore/Tests/WayforkCoreTests (pattern: AppLogicTests.swift). The app
  target has no test bundle — put testable logic in WayforkCore.
- Visual reference for cards/popover: macos/App/Views/Popover/* (reuse the tunnel card view
  in step 5 instead of redrawing it).

Already decided, do not ask:
- Window = AppKit NSWindow + NSHostingController(rootView: GuideView().environment(model)),
  owned by a `GuideWindowController` held by AppModel; 600×410 content, titled "Set up
  Wayfork", closable, not resizable, not miniaturizable; `NSApp.activate(ignoringOtherApps:
  true)` on show; showing it again brings it to front. Not a SwiftUI Window scene.
- State: `GuideState` (Codable, Equatable) in WayforkCore/App/GuideState.swift with
  `outcome: Outcome?` (.finished/.skipped), `stoppedAt: GuideStep?`, `cardActive`,
  `cardDismissed`, `cardDone: Set<GuideCardItem>`; `GuideStep` = welcome, helper, addVPN,
  sites, turnOn, tryIt; `GuideCardItem` = popoverRule, cantReach, appRule. Pure functions:
  `shouldAutoOpen(tunnelCount:)` (0 tunnels ∧ outcome nil), `showsCard` (cardActive ∧
  !cardDismissed ∧ cardDone.count < 3), `resumeStep` (stoppedAt when outcome nil).
  Stored JSON-encoded in UserDefaults key "WayforkGuideState" by a small app-side
  `GuideStore`; undecodable → empty state.
- Step 6 check as a pure WayforkCore type `GuideTryItCheck`: fed a baseline
  `TrafficSnapshot` at the Open click and later snapshots, plus the tunnel id and mode;
  answers `tunnelProven` (exits[id].opened grew, or opened is nil and the tunnel's download
  rate > 0 within 20 s) and `directHost: String?` (first RecentHost after the baseline with
  exit "direct" — or the tunnel id in mode 2). Test it with hand-made snapshots.
- Helper step: new internal `func approveHelperForGuide() async -> Bool` on AppModel that
  registers if needed, opens Login Items and waits — no alert; `ensureHelperApproved` stays
  as is for Turn On. Step already enabled on arrival → ticked and skipped over.
- Step 3 link field: Return/Add presents `AddLinkSheet(mode: .add, initialText:)` as a
  sheet on the guide. Import errors use the existing alerts (the inline C11·b error box is
  NOT built — record it as a deviation in 02-ux). Detect success by a new tunnel id in
  `store.tunnels`. Subscription with several servers → step 4 names the first new one.
- Step 4 mode 1 → `quickAdd(input: token, target: .tunnel(id))` per token; mode 2 →
  `setDefaultTunnel(id)` + `quickAdd(input: token, target: .direct)`, heading "Which sites
  stay direct?". Rules are written on Continue, not per keystroke.
- Done → outcome .finished, cardActive = true. Skip guide → outcome .skipped. Window close
  → stoppedAt = current step, outcome unchanged.
- Strings are the board strings verbatim, with "Work" replaced by the tunnel's name and the
  example sites by the user's.

Order:
1. WayforkCore: GuideState + GuideTryItCheck + tests.
2. App plumbing: GuideStore, GuideWindowController, AppDelegate auto-open,
   approveHelperForGuide, AddLinkSheet initialText.
3. GuideView: rail, footer, steps 1–6 incl. C11 states a, c, d.
4. Popover: Getting started card on top (C12·a/b), No-tunnels resume (C12·c), three tick
   call sites; General rows (C12·d).
5. Docs: tick M18 lines in docs/ROADMAP.md and stage 4 lines here that you verified; list
   deviations from the boards in 02-ux § First-run guide.
Tick boxes only after the check passed.

DoD: all of the above; `swift test --package-path macos/WayforkCore` green except the known
live-Wayfork failure `openVPNServersAlwaysGoDirectByNameAndAddress` (fake-ip answers every
name on this Mac — say so in the report if it fails); `scripts/format.sh --lint` clean;
`xcodebuild -project macos/Wayfork.xcodeproj -scheme Wayfork -configuration Debug build`
succeeds. Long output → redirect to a log in your scratch dir, read tail/grep only.

Do not: start, quit, restart or install Wayfork or run the built app (this Mac's traffic goes
through the live one); touch the daemon, sing-box generation or Windows code; change
existing flows beyond the named hooks; touch the untracked windows/app/windows/flutter/*
files. A question the prompt does not answer goes into the report, not a guess.

Do not commit or push — acceptance does that.
Last message — the report: done (files) / deviations from the plan / not verified / open
questions. The report is the only thing acceptance sees.
```

## Risks and open questions

- **The user already has a VPN client running** (Hiddify etc. was a confounder before):
  step 4 can fail for reasons the guide cannot fix. The failure frame must name the likely
  cause and let the user finish the guide anyway — decided in the prototype.
- **Step 2 is where users stop** (no config at hand). The guide must let them close and
  come back to the same step; the popover *No tunnels yet* state resumes the guide.
- **Upgrade path**: existing users with tunnels never see it — intended; confirm at stage 1.
- **Can't test on a clean machine from a session**: the maintainer runs the manual check
  on a fresh macOS user; plan for it in M18.
- Open: card items final list (settled in the prototype).

## Order

1 → 2 → 3 → 4 → 6, with 5 after 4 (or its boards alongside 3). Start with stage 1: the
maintainer answers on *What to teach*.
