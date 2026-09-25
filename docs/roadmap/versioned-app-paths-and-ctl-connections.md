# Versioned app paths and `wayforkctl connections` — issues #1, #2

> Status: in progress · created 2026-09-25 · session A (stages 1–3) accepted 2026-09-25,
> session B (stages 4–6) next, stage 7 owed by the maintainer · Windows only. Milestone skeleton:
> [ROADMAP-windows.md](../ROADMAP-windows.md) § WM18. The executing session ticks the
> checkboxes below as it goes; statuses live here and in § WM18 only.

## Goal

An app rule on Windows keeps matching after the app auto-updates into a new versioned
folder (Squirrel `app-<ver>`, MSIX `WindowsApps\<Name>_<ver>_<arch>__<hash>`), and the
stored path heals itself to the current build. A person or an assistant without admin
rights can ask the service "where does process X's traffic go, by which rule, and is its
UDP one-way?" with `wayforkctl connections`, and "which rule would take this exe / host /
IP?" with `wayforkctl explain`.

## Context and constraints

- Issues: [#1](https://github.com/fosteev/Wayfork/issues/1) (app rules vs Squirrel
  updates), [#2](https://github.com/fosteev/Wayfork/issues/2) (wayforkctl diagnostics).
  Both came from one debugging session: Discord voice failed because the rule pointed at
  `app-1.0.9255` while `app-1.0.9259` was running.
- Review verdict (2026-09-25, `/devil`), taken as the scope of this plan:
  - #1: one key function instead of three separate comparisons; MSIX covered as well as
    Squirrel; stored paths self-heal instead of making `exists` version-blind.
  - #2: only item 1 (`connections`) with item 2 folded in as a `oneWay` flag, plus
    `diagnostics --tail N`. **Items 3 (temporary log level) and 4 (`logs` command) are
    dropped.** `collectDiagnostics` already returns log tails without elevation
    ([supervisor.go:264](../../windows/service/internal/service/supervisor.go)), and
    `connections` gives the addresses the info level was wanted for. Added: `explain`,
    which would have caught #1 directly.
- Current code (checked while planning):
  - Regex: `WayforkPlatform.appPathRegex` in
    [platform.dart:34](../../windows/app/lib/core/platform.dart) emits
    `(?i)^<escaped path>$` on Windows; `RulePattern.appPathRegex`
    ([rule_pattern.dart:127](../../windows/app/lib/core/rules/rule_pattern.dart)) wraps it;
    `rule_set_generator.dart:124` is the only caller that emits it.
  - Duplicate detection: `rule.pattern == pattern` in
    [rule_editing.dart](../../windows/app/lib/core/app/rule_editing.dart) (validation at
    ~l.106, quick add ~l.207, `isUpdate` ~l.228).
  - Missing-exe check: `_AppFile.exists` in
    [rules_page.dart:1001](../../windows/app/lib/app/ui/pages/rules_page.dart) feeds the
    `not found` chip (l.761) and the row opacity (l.971). The chip already exists. This plan
    leaves the UI alone and only makes the stored path truthful.
  - Store mutations: `AppModel.update(mutate)` in
    [app_model.dart:~1022](../../windows/app/lib/app/model/app_model.dart) (persist +
    re-apply); load in `bootstrap()` (~l.457); `_apply()` (~l.1111).
  - The Go side evaluates `process_path_regex` with `regexp`
    ([ruleset_selectors.go:240](../../windows/service/internal/core/ruleset_selectors.go)),
    so a widened regex needs no Go change for #1.
  - Clash decode: `ClashConnection` / `DecodeClashConnections` in
    [clash.go:103-165](../../windows/service/internal/core/clash.go) drop port, rule,
    rulePayload, start. Sampler: `TrafficSampler.sample` in
    [clashhttp.go:227](../../windows/service/internal/service/clashhttp.go), every
    `samplerInterval`. One-way rule: `TrafficAccumulator.Ingest` in
    [traffic.go:~115](../../windows/service/internal/core/traffic.go) (`OneWayUDPGrace`
    10 s, keyed on `firstSeenAt` from the sampler).
  - Pipe: methods in [protocol.go:24-32](../../windows/service/internal/ipc/protocol.go),
    frame limit `MaxLineBytes = 64 MiB`. ACL `AU GRGW` plus the install-dir client check
    ([run_windows.go:163](../../windows/service/cmd/wayfork-service/run_windows.go)).
    Every authenticated user can already call `apply`/`stop`/`diagnostics`, so read-only
    `connections` opens no new class of access.
  - CLI: [cmd/wayforkctl/main.go](../../windows/service/cmd/wayforkctl/main.go), a
    `switch os.Args[1]` with `call(ctx, …)` printing JSON.
- Decisions:
  - **Versioned components** (whole path component only, case-insensitive):
    - Squirrel: `^app-\d+(\.\d+)+.*$` → regex `app-\d[^\\]*`
      (`app-2.0.1-beta` included).
    - MSIX: `^(.+)_(\d+(\.\d+){1,3})_([A-Za-z0-9]+)__([a-z0-9]+)$` → regex
      `<escaped name>_[^_\\]+_<escaped arch>__<escaped hash>`. Name, arch and publisher hash
      stay literal.
    - Anything else stays literal: `C:\my-app-1.0\x.exe`, `C:\app-1.0.exe` (last component,
      not a folder), `app-\Discord.exe`.
  - **One helper, three callers**: `VersionedAppPath` in `core/rules/versioned_app_path.dart`
    with `regex(path)` (used by the Windows branch of `appPathRegex`) and `key(path)`
    (lowercased path with each versioned component replaced by a placeholder; used by
    duplicate detection for app rules). macOS paths go through unchanged. `.app` bundles
    are stable.
  - **Self-heal**: pure `VersionedAppPath.heal(Store, AppFiles fs)` → new `Store` or the
    same instance. For every enabled or disabled app rule whose `.exe` is missing, look in
    the parent of the versioned component for siblings with the same key whose `.exe`
    exists, and take the **newest by modification time** (not by version string: MSIX and
    Squirrel sort differently). Called from `bootstrap()` after load and at the start of
    `_apply()`, through `update(...)` so it persists. `AppFiles` is an interface
    (`exists`, `listDirectories`, `modified`) with a `dart:io` implementation and a fake
    for tests.
  - **Duplicate on add**: adding `app-1.0.9259\Discord.exe` when an `app-1.0.9255` rule
    exists in the same group → treated as the same rule (the validation's `duplicate`
    failure, and quick add's `update` path replaces the stored pattern with the new one).
  - **`connections`**: the sampler keeps its last decoded sample and time; pipe method
    `getConnections` (no params) returns a `ConnectionsSnapshot { sampledAt, connections[] }`
    with `id, network, host, destinationIP, destinationPort, processPath, exit
    (tunnel id | group id | "direct" | "block"), chains, rule, rulePayload, upload,
    download, start, oneWay`. `oneWay` uses one shared pure func with
    `TrafficAccumulator`, so the flags add up to `oneWayUDPFlows` in the same sample.
    Filters (`--process <substr>`, `--exit <id|direct>`, `--udp`, `--one-way`) are applied
    **client-side** in wayforkctl. The pipe returns everything.
  - **`diagnostics --tail N`**: optional `tail` param on `collectDiagnostics` (absent → 200,
    capped at 5000). Additive, no protocol bump.
  - **`explain`**: pipe method `explain` with exactly one of `process`, `host`, `ip`. It
    answers from the **currently applied** plan: the route rules of the running sing-box
    config in order, each rule-set's selectors via the existing `RuleSetSelectors`
    matcher. It returns every matching rule in route order (the first is the winner) plus
    the final/default outbound when none match. Assumption to verify in stage 4: the
    supervisor keeps the applied `RuntimePlan` (sing-box config JSON + rule-set files) in
    reach. If it does not, `explain` reads them from the run directory.
    `explain` does not model sniffing or fake-ip: it matches the literal input and says
    so in its output (`"note"`).
- Out of scope: macOS `wayforkctl` parity, UI for connections (the app's Connections view
  already exists, WM17), naming the process in the one-way WARNING (H3 stays
  address-free and aggregate), any change to pipe access.

### Decisions after session A (2026-09-25, acceptance)

- **Heal moves off old builds that still exist**, not only missing ones. Squirrel keeps the
  previous `app-<ver>` after an update, so "heal only when the `.exe` is missing" left the
  stored path on the old build for a whole update cycle, and the Rules row kept showing
  it. Now every versioned app rule points at the newest existing build by mtime.
- **Quick add stays literal.** `RulePattern.inferMatch` never returns `RuleMatch.app`, so
  the key comparison there was dead code; reverted. Only `RuleEditing.normalize` (the
  *Application…* picker path) uses `VersionedAppPath.key`.
- **Re-adding a newer build is a `duplicate`** ("already exists in this group"), not a
  replace. The rule already matches every build, and heal moves the stored path on the
  next apply.
- MSIX heal is best-effort: `WindowsApps` cannot be listed without admin rights, so heal
  returns nothing there and only the widened regex works. That is enough for routing.

## Stages

### 1. Versioned app paths — regex and duplicates (Dart, #1)

Pure core change plus tests. No UI.

- [x] `lib/core/rules/versioned_app_path.dart`: `isVersionedComponent`, `regex(path)`,
      `key(path)` per the decisions (Squirrel + MSIX)
- [x] Windows branch of `WayforkPlatform.appPathRegex` builds from
      `VersionedAppPath.regex`. macOS branch unchanged.
- [x] `rule_editing.dart`: the app-rule duplicate check in `RuleEditing.normalize`
      compares by `VersionedAppPath.key`. Domain/IP rules still compare `pattern ==`.
      (Quick add and `isUpdate` left literal, see *Decisions after session A*.)
- [x] ~~Quick add / add of a newer path over an older app rule replaces the stored pattern~~
      Dropped: re-adding a newer build is a `duplicate`; `heal` moves the stored path.
- [x] Tests `test/core/rules/versioned_app_path_test.dart`: the regex matches
      `app-1.0.9255`, `app-1.0.9259`, `APP-2.0.1-beta`, and two MSIX versions of one
      package. It does not match `app-\Discord.exe`, `Update.exe`, `DiscordPTB\app-…\…`,
      another arch, or another publisher hash. `C:\my-app-1.0\x.exe` and `C:\app-1.0.exe`
      stay literal. The regex is also checked for RE2 compatibility (no lookarounds/backrefs).
- [x] `rule_editing_test.dart`: newer Squirrel path over an older rule → duplicate /
      update, not a second rule; different app → new rule
- [x] `rule_set_generator_test.dart`: a Windows app rule with a Squirrel path emits the
      widened regex. Golden fixtures in `fixtures/` are unchanged (their app paths are
      macOS).

**Done when:** in `windows/app`: `dart format --output=none --set-exit-if-changed .`,
`dart analyze --fatal-infos`, `flutter test` are green.

**Session:** sonnet, high; session A, stages 1–3 in one go.

### 2. Self-healing stored app paths (Dart, #1)

- [x] `AppFiles` interface + `IoAppFiles` (`dart:io`) + fake for tests
- [x] `VersionedAppPath.heal(Store, AppFiles)`: newest existing sibling build (own build
      included, missing or not) with the same key → rule's pattern replaced. Nothing found → rule untouched. Only
      rules whose path has a versioned component are touched.
- [x] `AppModel.bootstrap()` after load and `_apply()` at the start: heal through
      `update(...)`, one info log line per healed rule (`app rule healed: <old> → <new>`)
- [x] Tests: heal picks the newest by mtime among three siblings; leaves a
      non-versioned missing path alone; leaves an existing path alone; returns the same
      `Store` instance when nothing changed (so `update` is a no-op)

**Done when:** same commands as stage 1 are green. Healing a fake store with
`app-1.0.9255` missing and `app-1.0.9259` present yields the `9259` path.

**Session:** sonnet, high; session A.

### 3. Docs for #1

- [x] [08-windows.md](../design/08-windows.md) § App rules (F10) (~l.409): versioned
      components, the regex, the key, self-heal
- [x] `CHANGELOG.md` § [Unreleased]: Windows fix line
- [x] § WM18 in ROADMAP-windows.md: tick the #1 box

**Done when:** the doc describes what the code does. No other sections touched.

**Session:** sonnet, high; session A.

### 4. Go core: richer Clash decode, snapshot, one-way, explain matcher (#2)

Pure `internal/core`, tested on macOS.

- [ ] `ClashConnection` gains `DestinationPort`, `Rule`, `RulePayload`, `Start time.Time`.
      `DecodeClashConnections` fills them and tolerates them missing.
- [ ] Extract `IsOneWayUDP(connection, firstSeenAt, now) bool` and use it in
      `TrafficAccumulator.Ingest` (behaviour unchanged, existing tests stay green)
- [ ] `ConnectionsSnapshot` + builder from a sample + the accumulator's `firstSeenAt`
      per id. `MarshalJSON` never emits null slices (same style as `DaemonDiagnostics`).
- [ ] `Explain` pure func: input (process | host | ip) + ordered route rules
      (rule-set tag → outbound) + parsed `RuleSetSelectors` per tag → ordered matches and
      the fallback outbound, with a `note` that sniffing/fake-ip are not modelled
- [ ] Tests: decode with and without the new fields, including a `/connections` fixture
      in `fixtures/clash/` if one exists; one-way flags agree with `oneWayUDPFlows` for
      the same sample; `Explain` for a Squirrel-widened regex, for a domain suffix, for an
      IP CIDR, and for no match

**Done when:** in `windows/service`: `gofmt -l .` empty, `go vet ./...`,
`go test ./...` green.

**Session:** sonnet, high; session B, stages 4–6 in one go. Starts after session A is
accepted, because both touch `08-windows.md` and `ROADMAP-windows.md`.

### 5. Service, pipe and CLI (#2)

- [ ] `TrafficSampler` keeps the last decoded sample, its time and the `firstSeenAt` map
      under `mu`. It is cleared on `Pause`/`Reset`.
- [ ] `ipc`: `MethodGetConnections = "getConnections"`, `MethodExplain = "explain"`,
      optional `tail` param on `collectDiagnostics`; handler interface, server dispatch,
      client methods
- [ ] Supervisor: `GetConnections` (empty snapshot when not running), `Explain` from the
      applied plan (verify the assumption in *Decisions*; fall back to the run directory),
      `CollectDiagnostics(tail)` with the cap
- [ ] `wayforkctl connections [--process s] [--exit id|direct] [--udp] [--one-way]`,
      `wayforkctl explain --process <path> | --host <h> | --ip <a>`,
      `wayforkctl diagnostics [--tail N]`; usage text updated; JSON output like the rest
- [ ] Tests for the dispatch and for the CLI filters (a pure filter func in the ctl
      package or core)

**Done when:** `go vet ./...`, `go test ./...` green and `GOOS=windows go build ./...`
succeeds.

**Session:** sonnet, high; session B.

### 6. Docs for #2

- [ ] [08-windows.md](../design/08-windows.md) § `cmd/wayforkctl` (~l.539): the three
      commands, their JSON, the note on access (same ACL, read-only, no secrets)
- [ ] `CHANGELOG.md` § [Unreleased]: Windows addition line
- [ ] § WM18: tick the #2 box

**Done when:** docs match the code.

**Session:** sonnet, high; session B.

### 7. Live check on the PC (maintainer)

- [ ] Discord rule created on an older `app-*` path (or edit `store.json`), Discord
      running → after launch the rule shows the current path (healed). Voice goes through
      the rule's exit.
- [ ] `wayforkctl connections --process discord --udp` shows the voice UDP destination,
      its exit, `rule`/`rulePayload`, and `oneWay: true` if the exit drops UDP
- [ ] `wayforkctl explain --process "<path to Discord.exe>"` names the Discord rule first
- [ ] Close #1 and #2 with a link to the commits

**Done when:** all boxes ticked by the maintainer.

**Session:** maintainer, `ssh wf-pc`.

## Session prompts

### Session A — #1 versioned app paths (stages 1–3)

```
Session A — Windows: versioned app paths (issue #1) · Model: sonnet, effort: high · first

Work in /Users/fost/Projects/Wayfork. Task: make Windows app rules survive Squirrel and
MSIX app updates, and self-heal the stored path. This is a change to existing code.

Read: docs/roadmap/versioned-app-paths-and-ctl-connections.md (Context, Decisions,
stages 1–3); docs/design/08-windows.md lines ~405-415 (App rules F10). Repo rules:
CLAUDE.md.
Entry points: windows/app/lib/core/platform.dart:34 (appPathRegex);
windows/app/lib/core/rules/rule_pattern.dart:127 (wrapper);
windows/app/lib/core/app/rule_editing.dart ~l.106, ~l.207, ~l.228 (pattern == checks);
windows/app/lib/app/model/app_model.dart bootstrap() ~l.457, update() ~l.1022,
_apply() ~l.1111. Tests live in windows/app/test/core/{rules,app,singbox}/.
Entry points were checked while planning. Don't re-read them to confirm; open only the
fragment you edit.

Already decided, don't ask: whole-component widening only; Squirrel `app-<ver>` and MSIX
`<Name>_<ver>_<arch>__<hash>` exactly as in the roadmap's Decisions; one helper
VersionedAppPath (regex / key / heal) in lib/core/rules/versioned_app_path.dart; heal
picks the newest sibling by mtime and runs from bootstrap() and _apply() through
update(...); the "not found" chip and _AppFile in rules_page.dart stay as they are; macOS
branch unchanged; no Go changes.

Order:
1. Stage 1 (helper, regex, duplicates, tests)
2. Stage 2 (heal, AppFiles, wiring, tests)
3. Stage 3 (08-windows.md, CHANGELOG [Unreleased], tick § WM18 #1 box)
Tick the roadmap boxes only after the check passes, not when it "seems done".

DoD: stage 1–3 "Done when" criteria. Checks in windows/app:
`dart format --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`,
`flutter test > $SCRATCH/test.log 2>&1; tail -30 $SCRATCH/test.log`.

Don't: touch UI files beyond what heal needs (none expected); touch windows/service;
change the fixtures/ goldens; "improve while at it". A question the prompt doesn't
answer goes into the report; don't guess.

Don't commit or push; acceptance does that.
Last message is the report: done (files) / deviations from the plan / not checked /
open questions. The report is all acceptance will see; without it the work is lost.
```

### Session B — #2 `wayforkctl connections` / `explain` (stages 4–6)

```
Session B — Windows: wayforkctl connections / explain (issue #2) · Model: sonnet, effort: high · after session A is accepted

Work in /Users/fost/Projects/Wayfork. Task: add read-only `wayforkctl connections`,
`wayforkctl explain` and `diagnostics --tail N` to the Windows service. This is new pipe
methods on existing plumbing.

Read: docs/roadmap/versioned-app-paths-and-ctl-connections.md (Context, Decisions,
stages 4–6); docs/design/08-windows.md ~l.515-545 (pipe, wayforkctl);
docs/design/05-daemon.md § Traffic sampling. Repo rules: CLAUDE.md.
Entry points: windows/service/internal/core/clash.go:103-165 (ClashConnection, decode);
internal/core/traffic.go ~l.95-125 (Ingest, one-way rule);
internal/core/ruleset_selectors.go (RuleSetSelectors, matcher ~l.220-260);
internal/core/status.go:996 (DaemonDiagnostics + MarshalJSON pattern);
internal/service/clashhttp.go:121-300 (TrafficSampler, sample());
internal/service/supervisor.go:264 (CollectDiagnostics);
internal/ipc/protocol.go:24-32 (methods), server.go / client.go (dispatch);
cmd/wayforkctl/main.go (commands, usage).
Entry points were checked while planning. Don't re-read them to confirm; open only the
fragment you edit.

Already decided, don't ask: the snapshot fields, the exit values, the shared
IsOneWayUDP, client-side filters, the tail default 200 / cap 5000, explain = ordered
matches over the applied plan with a "sniffing/fake-ip not modelled" note, all exactly as
in the roadmap's Decisions. Log-level override and a `logs` command are out of scope.
Pipe ACL and client check are unchanged. No Dart changes.

Order:
1. Stage 4 (core: decode, IsOneWayUDP, ConnectionsSnapshot, Explain, tests)
2. Stage 5 (sampler state, ipc methods, supervisor, wayforkctl commands, tests). First
   verify the Explain assumption (where the applied plan lives) and note the answer in
   the report.
3. Stage 6 (08-windows.md wayforkctl section, CHANGELOG [Unreleased], tick § WM18 #2 box)
Tick the roadmap boxes only after the check passes, not when it "seems done".

DoD: stage 4–6 "Done when" criteria. Checks in windows/service:
`gofmt -l .` (empty), `go vet ./...`, `go test ./... > $SCRATCH/go.log 2>&1; tail -30 $SCRATCH/go.log`,
`GOOS=windows go build ./...`.

Don't: change the H3 WARNING line; add fields to getStatus; touch windows/app or
macos/; "improve while at it". A question the prompt doesn't answer goes into the report;
don't guess.

Don't commit or push; acceptance does that.
Last message is the report: done (files) / deviations from the plan / not checked /
open questions. The report is all acceptance will see; without it the work is lost.
```

## Risks and open questions

- **MSIX paths may not be pickable in practice.** The WM6 picker resolves store apps
  through `ApplicationFrameHost`. If the service-side process path differs from what the
  picker stores, the MSIX branch is dead code. It is cheap either way. Stage 7 can add a
  Store app check if one is at hand.
- **Heal picks a wrong sibling.** Squirrel leaves at most the previous build, and newest
  by mtime is the running one. For MSIX, several versions can sit side by side
  during staging. The key pins name + arch + publisher, so the worst case is a
  just-staged build that is not running yet. The regex matches both anyway.
- **`explain` vs reality.** The matcher does not model sniffing, fake-ip or DNS rules. Its
  answer is "what the rule-sets say", not "what sing-box did". `connections.rule` is the
  ground truth. Both are stated in the output note and the doc.
- **Big `connections` replies.** Thousands of connections × ~300 bytes stay far below
  the 64 MiB frame limit. No paging.
- **`diagnostics` log tails are not sanitized on the Go side** (assumption from reading
  `CollectDiagnostics`: it returns raw tails). `--tail` makes more of them reachable. The
  exposure class is the same as today. Flag it in the report if the tails contain secrets.

## Working order

Session A (stages 1–3) → `/plan-review` → session B (stages 4–6) → `/plan-review` →
stage 7 by the maintainer. A and B are in different subtrees (`windows/app`,
`windows/service`), but both edit `08-windows.md`, `CHANGELOG.md` and
`ROADMAP-windows.md`, so they run one after the other. Commits: one per session after
acceptance (`fix(win): …` for A, `feat(win-service): …` for B).
