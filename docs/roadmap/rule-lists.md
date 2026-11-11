# Rule lists — F24

> Status: stages 1–5 accepted; stage 6 live/native/release acceptance remains open.
> Saved work checkpoint: [rules-checkpoint.md](rules-checkpoint.md), 2026-11-11.
> Migration G1 resolved: preserve behavior with split lists (2026-11-07).
> Created 2026-11-03; reconciled 2026-11-07.
> macOS M20, Windows WM22; M19/WM21 are F23, WM20 is reserved for F22.

## Goal and authority

Rules are grouped by purpose (Claude, Telegram, Banks…) into named **lists**. One exit
menu moves the inherited rows of a list with one store edit and one apply, in Settings or
the popover. Empty per-exit sections disappear. The approved local prototype is
[rule-lists.html](../design/prototype/rule-lists.html), boards R1–R6. The maintainer's
2026-11-07 direction ("по макету делаем /roadmap-run") approves that visual/product
reference, including Direct first, user list order, row order and **Same as Everything
else**. It does not approve unrelated deletion changes or waive migration compatibility.
No Artifact publication is required or authorized by this roadmap.

## Baseline code, inspected before implementation on 2026-11-07

- Swift `Model/Store.swift` (`macos/WayforkCore/Sources/WayforkCore/`): schema 3;
  `effectiveRules` orders Direct → tunnels → groups → missing exits. `Rule.swift` stores
  a concrete `RuleTarget` on every row. `Model/ExportDocument.swift`: export 3.
- `Rules/RuleValidator.swift`: duplicate detection is per target; shadowing ranks Direct
  broad, Direct narrowed, non-Direct narrowed, non-Direct broad. `activeRulesInOrder`
  filters `effectiveRules`; it does **not** itself sort by that rank.
- `SingBox/SingBoxConfigGenerator.swift` and `RuleSetGenerator.swift`: union rules by
  exit, insert all narrowed exit rules before all broad exit rules; Direct precedes the
  block list. DNS references the broad domain/app sets, never IP/narrowed sets.
- Dart `windows/app/lib/core/model/{store,rule,export_document}.dart`,
  `rules/rule_validator.dart`, `singbox/{sing_box_config_generator,rule_set_generator}.dart`
  mirror those semantics; the generator also groups by exit. Sorting UI cannot change
  runtime precedence.
- Swift `Plan/RuntimePlanBuilder.swift`, `XPC/RuntimePlan.swift` and daemon
  `PlanValidator.swift`, `RuleSetSelectors.swift`, `ReconcilePlanner.swift` consume the
  generated plan. Routed exit IDs currently come from exit-named files.
- Windows Dart `plan/runtime_plan_builder.dart`, `ipc/runtime_plan.dart`; Go
  `windows/service/internal/core/{validate,planjson,ruleset_selectors}.go`: Go has no
  source rule model, but validates filenames, derives routed IDs and evaluates generated
  route rules for `explain`. It needs changes when file topology changes.
- `App/RuleEditing.swift`, app `AppModel+Rules.swift`, `AppModel+Control.swift`,
  `AppModel+Tunnels.swift`, `AppModel+Groups.swift`: edits and ctl share existing owners.
  Exit deletion currently removes its rules; default is `defaultTunnelID`.
- Shared golden producer: `SingBoxGeneratorTests.configVariants()`; Dart replays
  `fixtures/singbox/*/input.json`; Go reads generated plans. XHTTP fixtures stay separate.

## Design contract

Details: [model](../design/01-data-model.md#rule-lists-f24),
[UX](../design/02-ux.md#rule-lists-f24),
[routing](../design/03-routing.md#rule-lists-f24),
[ctl](../design/09-wayforkctl.md#rule-lists-f24). These are future F24 contracts;
preceding sections describing shipped F23 remain historical/current implementation.

1. **Ownership.** Schema/export 4 carry ordered `Store.lists`. Each row has one `listID`.
   A list owns its target (concrete exit or `everythingElse`); nullable `Rule.target` is a
   pinned concrete override, nil means inherit. Pin state is derived, not a second bool.
   No duplicated inherited target cache and no normalization that silently rewrites exits.
2. **Order.** Filter paused lists and disabled/unusable rows first. Rows whose declared
   effective binding is explicitly Direct (including pinned Direct in another list) form
   the exception tier, ordered by list position then row position. After the unchanged
   block list, remaining rows follow list position then row position. A pinned tunnel row
   in a Direct list belongs to the latter tier. No global F23 narrowed rank in F24.
   Narrowing filters TCP/UDP at a row's position; a later UDP row cannot jump an earlier
   broad row. Put the exception earlier, or pin it Direct as drawn in R5.
3. **Follow default.** `everythingElse` is an active match at its list/row position,
   resolving `defaultTunnelID` on each plan build. With Direct as default it still stays
   in the non-exception tier (and behind the block list), so changing the default cannot
   promote a list to an exception. It claims a match before lower lists. Pausing instead
   removes every row, pins included; lower lists can then match before the fallback.
4. **DNS.** Project the same ordered rows onto domain matchers only. Built-in local names
   and tunnel bootstrap DNS stay protected. Explicit Direct domain rows precede blocking;
   remaining domain rows follow blocking in list/row order. A selected Direct target uses
   `dns-direct`; a tunnel/group uses fake-IP for A/AAAA, and the existing `dns.final` for
   other types. An explicit fallback for non-A/AAAA at that same row prevents a later
   domain row stealing the query. App/IP/network matchers never enter DNS. The connection
   then uses the winning outbound's existing resolution behavior. No new per-list DNS
   setting or promise that an app's DNS is attributed to its process.
5. **Unavailable exits.** Keep the shipped policy: disabled, missing, or missing-secret
   exits are inert; fall through to later rows and then Everything else, with a warning.
   A configured/routed tunnel that is currently unreachable remains selected and fails,
   without direct failover. Follow-default uses exactly the current default resolution
   policy (unconfigured/unusable default resolves Direct; runtime-down default fails).
6. **Generation.** One stable `rules-r-<rule UUID>.json` source file per active row, one
   route reference at its position; `network` is on its route rule. `rules-direct.json`
   contains built-in local names only. Do not regroup non-adjacent rows by exit. Preserve
   the existing headless matcher shapes and reserved IP subtraction. Swift daemon and Go
   filename validation, plan parsing, routed-ID discovery, explain and reconcile tests
   must support this topology; see the routing document. This is a generator change.
7. **Validation.** One resolved ordered projection feeds generator and validation. Equal
   match/pattern/network within a list is a duplicate; across lists it is shadowed only
   when an earlier active row covers its full network. Disabled/paused rows do not hide
   active ones. Partial transport overlap must not remove the broad row. Warning names
   the winning list/row. Existing limited static matching need not become a general
   hostname/process/subnet overlap solver.
8. **Editing.** New lists insert at the top of user list order. Reorder, pause, target and
   move are one atomic edit/apply. Moving a row inherits the destination unless pinned;
   its pin survives. Unpin inherits immediately. GUI quick add/Recent require a list,
   defaulting to the last valid used list (else first enabled list; empty store opens
   creation). Do not silently update the same pattern in some other list. CLI legacy
   `rules add --via` uses the first explicit list with that exit, or creates an exit-named
   list; `--list` chooses membership, `--list` plus `--via` pins that row.
9. **Deletion scope.** Preserve current exit deletion: remove rows bound to that exit,
   including pins, and remove rows inherited from lists targeting it; keep the list shell
   with the missing exit ID (inert + warning), never silently retarget Direct or pause.
   Surviving pinned rows to other exits stay in that shell. Delete cascaded undersized
   groups as today; clear the default as today. Confirmation names affected lists/rows.
   Deleting a list deletes its rows after a count-based confirmation; no implicit merge.
10. **Import.** Export 4 preserves list/row order, IDs, inheritance/pins, pause and menu
    settings. Old builds reject schema/export 4. Import ≤3 uses the selected G1 migration.
    Merge lists by ID only, re-use an identical list; conflicting same ID requires import
    remapping, like conflicting row IDs. Names alone never merge routing. Append incoming
    lists in source order, disambiguate names with numeric suffixes; preview warns that
    existing earlier lists can win. Remap list, row and exit references together. Full
    replace import preserves source order exactly. Repeated identical import is idempotent.
11. **UI.** Keep Everything else on its own line, list exit menu including follow-default,
    pin chips, flat search with list names, collapsed Recent, one-apply switch + 10 s Undo.
    Show up to six eligible lists in the popover (hide section with fewer than two total
    lists); keep display selection separate from routing order. Persist show/hide; for
    overflow rank by most recent user target switch (local UI preference, UUID tie-break),
    then "N more in Settings". Hidden lists still participate in routing. Keep the existing
    Tunnels default toggle bound to the same field; no extra default setting.
12. **Control.** macOS `lists`, `lists set <id|name> --via <exit|default>`,
    `rules add … --list <id|name>`; 60 s pending/revert semantics, one transaction for a
    list switch. Windows ctl source-rule mutations remain out of scope; its generated-plan
    `explain` must still work. GUI Undo must not overwrite a newer edit; ctl crash rollback
    preserves GUI changes and restores membership/order/override together.

## Decision G1 — preserve existing routes with split migration lists

**Selected 2026-11-07.** After the recommendation to preserve routes by splitting legacy
TCP/UDP priority tiers, the maintainer instructed “продолжай на автопилоте”; root selected
that recommended option. No further migration preference question is pending. Root still
accepts stage 1 independently.

The original sketch promised both one migrated list per exit and unchanged routing.
Current F23 makes those incompatible with strict list order. Example, exits Work then Home:

| Existing rows | Shipped F23 | One list/exit, Work before Home |
|---|---|---|
| Discord broad → Work; Discord UDP → Home | UDP Home, TCP Work | UDP Work, TCP Work |
| Chat broad → Home; Chat TCP → Work | TCP Work, UDP Home | TCP Work, UDP Home |

Reversing lists fixes the first example and breaks the second's TCP result. A single
relative order cannot preserve both. Direct pins cannot represent two concrete tunnels.
The rejected alternative is one list per exit with changed overlapping routes; it is not
authorized. No invisible legacy-precedence mode is introduced.

**Pure migration procedure:**

1. Before changing membership/targets, run the frozen schema-3 duplicate/shadow analysis
   on the original store, using the shipped logic in both Swift and Dart. Keep every row
   and its original ID, pattern, match, network, note and `isEnabled` value.
2. Rows with a legacy `.duplicate` issue go into paused **Previously
   inactive** lists, one per old target, appended after normal migration lists. Bind each
   archive to its original target, `isEnabled = false`, `showInMenu = false`; preserve
   each row's own enabled flag. Names are `<exit> — Previously inactive` (Direct/unknown
   included), disambiguated normally. This is visible source data, not discarded rows or
   a hidden runtime flag. Users can explicitly enable/review/move these rows later.
3. Remaining rows become inherited rows in exit-bound lists ordered by legacy generator
   priority: Direct, then all narrowed non-Direct exits in tunnel/group order, then all
   broad exits in that order, then unknown/inert exits in original first-occurrence order.
   Within a narrowed list TCP precedes UDP, preserving source order within each network;
   broad rows preserve source order. Direct can use one list (same outbound throughout).
   Empty buckets produce no list. Use `<exit> — TCP/UDP` and `<exit>` when both buckets
   exist, otherwise the exit name. Disabled/missing-target rows are retained in their
   buckets; their disabled state/target keeps them inert without archiving them solely
   for that reason. No migrated pins or follow-default lists are created.
4. Each list ID is its first member's original row ID in the separate list namespace;
   all bucket memberships are disjoint. This is deterministic across codecs, repeated
   migration and rollback retry. Clear concrete row targets only after binding their list.
5. Present a migration summary: split lists preserve previous route priority; “N previously
   inactive rules remain in paused lists; review before enabling.” No confirmation is
   required merely to show this summary. Keep the old file recoverable until atomic save.

**Why suppression needs explicit storage:** the current duplicate pass sees disabled rows.
`x.example → Work` disabled, then identical enabled `x.example → Work`, with Direct default,
currently emits neither row. Ignoring disabled rows in the new validator would activate
Work. Keeping the second row in a paused archive preserves both its enabled flag and the
actual Direct result. Shadowed rows stay in normal split buckets: the same effective
order suppresses them naturally after unavailable exits are filtered. This distinction is
required by the actual runtime owner: `RuntimePlanBuilder` disables missing-secret exits
before legacy validation. Work without its OpenVPN config therefore allows a usable Home
row to match; archiving Home would break that route. The raw generator alone has a different
result and is not the runtime compatibility oracle. Root approved this evidence-driven
correction during stage 2 on 2026-11-07. Pure split sorting alone is insufficient only for
legacy duplicates (whose first occurrence can be disabled).

The compatibility guarantee is the initial migrated routing/DNS for the same store,
secret availability and runtime inputs through the actual runtime builder, not reproduction of every later action of the
old editor. A paused archive deliberately stays inert after subsequent edits until the
user enables/moves it. This is explicit and conservative; automatically reviving formerly
suppressed rows would change routes during the upgrade. Migration tests must prove both
counterexamples and every row's retained content/flag, plus deliberate archive activation.

**DNS equivalence argument:** legacy active Direct domains already precede blocking; all
legacy non-Direct domain rows share one A/AAAA fake-IP union, and non-A/AAAA uses `dns.final`.
Migration creates no follow-default list and archives precisely the old duplicate rows.
Splitting that union into ordered domain rows changes neither its A/AAAA membership nor
its answer server. Each new non-A/AAAA row explicitly chooses the same `dns.final`; later
rows cannot change it. Preserve all bootstrap/local/DDR/blocking/default rules. This is a
code-derived argument, to be verified by differential fixtures rather than called a live
result. A future new follow-default row is covered by F24-specific tests separately.

## Acceptance and test contract

- **Order witnesses:** two lists sharing an exit with a different-exit list between them;
  broad vs narrowed across and within lists; exact/suffix overlap; app vs domain when both
  metadata exist; overlapping IP ranges. Reverse lists/rows and assert actual plan route
  selection, not just model sorting. Pinned Direct lifts out of a non-Direct list; pinned
  tunnel in a Direct list does not. Changing tunnel/group store order has no effect.
- **Default vs pause:** matching follow-default row wins over a lower explicit exit;
  pause lets that lower exit win. Change default Direct ↔ tunnel ↔ group without rewriting
  rows. Include absent/disabled/missing-secret/runtime-down exits, group member removal,
  paused pinned Direct, independently disabled rows, hidden menu lists.
- **DNS witnesses:** Direct vs tunnel overlapping domains, follow-default Direct before a
  lower tunnel list, A/AAAA and TXT, local suffix and bootstrap host, block-list hit and
  never-block exception. App/IP/TCP/UDP changes add no DNS answer filters; no `ip_cidr`,
  process or transport matcher enters DNS. Keep IPv4-only, probe, DDR and reverse mapping.
- **Compatibility:** freeze old schema 1/2/3 and export 1/2/3 samples, migrate, compare
  representative route + DNS outcomes for the same secret/default inputs, including F23
  counterexamples, disabled-first duplicates, shadowing by missing-secret exits, archive
  activation, retained row flags and currently inert rows. Byte-identical generated config/plan hashes
  are **not** migration acceptance: the topology changes. Assert deterministic new output
  and byte parity Swift ↔ Dart against the *new* reviewed goldens separately.
- **Lifecycle:** plan validation accepts only safe UUID row filenames, rejects traversal;
  routed exits with zero rules are still discovered/probed; plan identity is deterministic;
  pattern edits cut affected connections, target/order changes cause the reconcile action
  the main-config diff requires. No claim that every change is a rule-set-only hot reload.
- **Storage/import/control:** orphan/duplicate membership rejected before saving; one row
  in one list; stable migration IDs across languages; export/import inheritance and pin
  roundtrip; ID collision and name collision; exact undo after list reorder/deletion,
  timeout and leftover pending file. One list edit produces one apply.

## Stages

Each stage uses a **fresh gpt-6.1-sol/high executor**, `fork_turns: "none"`, with root
`gpt-6-astra/high` review under `roadmap-run`. No nested agents. Requested launch settings
and runtime metadata are recorded separately. Checkboxes are marked only after root
acceptance, never on the executor's claim. No commits, push, publication, installation or
live Wayfork operations are implicit in these stages.

### 1. Reconcile features and design

- [x] Align F24/M20/WM22 entries, model, UX, routing, ctl and local prototype wording
- [x] Define ordered runtime/DNS projection, pins, pause/default, validation and lifecycle
- [x] Verify selected G1 split migration and explicit paused suppression archives
- [x] Root independently reviews design against code and approved prototype

**Done when:** coherent docs reflecting selected G1 and suppression preservation, root
review accepted. This is design work only; no app implementation.

### 2. macOS core and daemon — M20 part 1

- [x] Schema/export 4 and chosen legacy migration; membership validation and list edits
- [x] Ordered resolved projection shared by validator, generator and editing helpers
- [x] Per-row route/DNS output, pins/default/pause and carve-outs; no exit regrouping
- [x] Swift runtime/daemon safe filenames, routed IDs, selector/reconcile compatibility
- [x] Differential migration tests, ordered matcher tests, new goldens + pinned-engine check
- [x] Existing core and daemon tests pass; root review accepted

**Checks:** `scripts/format.sh`; `swift test --package-path macos/WayforkCore`;
`WAYFORK_UPDATE_GOLDEN=1 swift test --package-path macos/WayforkCore` only for deliberate
reviewed fixture regeneration, then replay without the env var. Keep raw legacy inputs
and reference outputs separately. Changes to generated config are expected; audit them.
Root must verify pinned `sing-box check` runs against the new file topology, or report
its absence explicitly. Stage 3 owns the temporary Dart/Go incompatibility; no partial
cross-platform release between 2 and 3.

### 3. Windows core and service — WM22 part 1

- [x] Dart mirror of model/migration/import/projection/generator, byte parity on new goldens
- [x] Go safe row filename validation, routed IDs, route selection/`explain` and reconcile
- [x] Legacy plans still accepted by the upgraded service; new plans rejected by old service
- [x] Dart/Go tests and Windows cross-build pass; root review accepted

**Checks:** in `windows/app`: `dart format --output=none --set-exit-if-changed lib test`,
`dart analyze --fatal-infos`, `flutter test`; in `windows/service`: `gofmt` changed Go files,
`go vet ./...`, `go test ./...`, `GOOS=windows go build ./...`. Do not modify generated
Flutter plugin files. A cross-build is not a live Windows acceptance.

### 4. macOS app and ctl — M20 part 2

- [x] R1–R5 list UI, default line, pins, list/row moves, search, pause and Undo
- [x] Recent/quick-add list selection, creation and delete alerts with existing exit policy
- [x] R3 popover list selection/overflow without changing routing order or height constraints
- [x] ctl protocol/CLI/handler/pending-file support; old-app unknown-method fails clearly
- [x] App compile and core/control tests pass; root review accepted

**Checks:** `scripts/format.sh`, `swift test --package-path macos/WayforkCore`, Release
`xcodebuild` using the checked-in macOS project/scheme discovered from the repository.
Build only; do not replace/restart the running app. Manual appearance/live checks stay open.

### 5. Windows design and UI — WM22 part 2

- [x] W-lists board in local `prototype/windows.html`, F24 delta in `08-windows.md`
- [x] Maintainer approves that board before UI implementation — 2026-11-08: "делай roadmap" after concrete board handoff; proceed with the presented W-lists design.
- [x] Fluent list UI/tray, Recent, pins/default/pause, import/delete parity
- [x] Widget tests, Dart checks and root review accepted

**Checks:** same Dart commands as stage 3; relevant `rules_page_test.dart` and tray tests.
The executor prepares the concrete local board and pauses at the explicit visual gate;
root resumes that stage's executor after approval. No Artifact publication.

### 6. Maintainer installation, live and release gate

- [ ] Authorized installation of coordinated app/helper/service builds; migration backup
- [ ] Chosen migration outcomes verified, not an unchanged plan hash
- [ ] Switch a real list between exits from Settings and popover: one apply, new connections
- [ ] Pause vs follow-default with overlapping lower list; Direct pin; app UDP/TCP witness
- [ ] DNS/default/blocking/bootstrap behavior and ctl confirm/revert verified
- [ ] Same checks on Windows; visual acceptance on both platforms
- [ ] Requested release docs/packaging/publication completed with separate authorization

**Done when:** maintainer records actual live and visual evidence. Green fixture tests
alone do not satisfy this stage. The agent never restarts the live Wayfork from a session.

## Executor prompts

Use the following common preamble for every fresh stage agent, followed by its stage
paragraph. Root includes the current accepted decisions and checkpoint explicitly;
`fork_turns: "none"` provides no parent history.

> Work in `/Users/fost/Projects/Wayfork`; confirm cwd with `pwd`. Read
> `/Users/fost/Projects/CLAUDE.md`, project `CLAUDE.md`, `README.md`, applicable nested
> instructions, `/Users/fost/.codex/WORKFLOW.md`, `/Users/fost/.codex/roles/coder.md`,
> `docs/roadmap/rule-lists.md` and its linked design sections. Implement only stage N after
> its dependencies/gates are accepted. Prove actual entry points before edits; preserve
> unrelated dirty/untracked files, especially generated Flutter plugin files. No nested
> agents, commits/push, external publication or live Wayfork operations. Keep acceptance
> boxes open for root. Report changed files, contract choices, exact checks/results,
> unresolved failures, and deviations. Record requested tool configuration separately
> from available runtime metadata; absent runtime fields are unknown.

**Stage 2:** Implement schema/export 4, the explicitly recorded G1 answer, pure list
operations and ordered generation in the Swift paths listed above. Include `App/RuleEditing`
source-rule lookups and `Model/ExportDocument`/import owners; update signatures/call sites
only enough to keep the app compilable until stage 4. Update daemon `PlanValidator`,
`RunLayout`, `RuntimePlan` routed IDs, selector/reconcile tests for row files without
weakening trust boundaries. Use the Acceptance and test contract; preserve frozen old
outputs and add ordered behavior witnesses. Review new goldens, run all stage-2 checks;
report expected temporary Dart/Go replay incompatibilities without weakening their tests.
Implement the selected G1 split migration and paused suppression archives; test the
disabled-first duplicate and missing-secret shadow cases before accepting equivalence.

**Stage 3:** Port accepted stage-2 behavior into Dart's listed owners and import/export
paths. Update Go `validate.go`, `planjson.go` and tests, row-selector/`explain`/reconcile
consumers; retain legacy-plan readability and reject unsafe paths. Service never gains
source lists or ctl mutation. Compare every shared golden byte-for-byte; add Windows app
path/network witnesses. Run Dart/Go checks and Windows cross-build; leave generated files
untouched. Record helper/service upgrade requirements.

**Stage 4:** Implement the approved local R1–R5 in `macos/App` using the accepted core
operations; inspect actual Settings/popover/Recent/default/delete/import callers first.
Lists own exits; pins survive switches, default-follow does not rewrite rows. Update
`Control/ControlProtocol.swift`, pure pending/inverse model, CLI parser/help and
`AppModel+Control.swift`; add scoped list identity, exact rollback and old-app refusal
checks. One edit must schedule one apply. Run stage-4 checks, provide a build path for
manual acceptance without installing it.

**Stage 5:** Prepare local Windows board and `08-windows.md` delta using accepted F24
semantics and existing Fluent patterns. Return for the explicit visual gate; after root
passes maintainer approval, implement only Flutter app/tray list UI, source mutations and
relevant widgets. Keep Go source-rule control out of scope; run stage-5 checks. A visual
board or widget test does not prove live routing.

**Stage 6:** Prepare a concrete manual checklist/build artifacts only within separately
authorized scope. Root/maintainer perform live installation and observation. Record
outcomes as live, fixture or build evidence accurately. Do not publish a release or
restart Wayfork on the strength of this prompt.

## Execution checkpoint — 2026-11-07

- Accepted stages: 1–5 (stage5 root review, 2026-11-08). Current stage: 6, manual acceptance checklist and signed macOS artifact ready; installation/live/release remain open;
  stage-2 acceptance failures: 1, resolved on retry. G1 resolved under the maintainer's “продолжай на автопилоте”
  direction: root selected recommended preservation by split lists.
- Required route: root `gpt-6-astra/high`, fresh stage executor `gpt-6.1-sol/high`,
  `fork_turns: "none"`. Root runtime model/effort: **unknown**, not exposed; user explicitly
  confirmed required current-chat configuration on 2026-11-07 ("потверждаю"; separate evidence).
- Stage-1 requested configuration, as provided by root: `model: "gpt-6.1-sol"`,
  `reasoning_effort: "high"`, `fork_turns: "none"`; agent task `/root/rules_stage_1`.
  Launch succeeded; returned task name `/root/rules_stage_1`; opaque agent ID was not
  exposed. Agent runtime model/effort/context capacity: unknown; requested parameters
  are not runtime proof.
- Executor cwd verified by tool `pwd`: `/Users/fost/Projects/Wayfork`.
- Stage-2 launch intent recorded successfully; requested `model: "gpt-6.1-sol"`,
  `reasoning_effort: "high"`, `fork_turns: "none"`; returned task name
  `/root/rules_stage_2` (no opaque ID exposed). Runtime model/effort unknown.
  Executor confirmed cwd by command. Stage-2 acceptance attempts: 0.
- Root also ran pre-change `go test ./...` in `windows/service`: passed;
  `/tmp/wayfork-f24-go-baseline.log`. Unpushed commits: 0 via `git rev-list` against upstream.
- Changes: stage-1 documentation only; prototype wording adjusted minimally. Existing
  untracked roadmap/prototype and three generated Windows Flutter files preserved.
  No commit/push/live operation. Unpushed status is for root to record.
- Checks: local instructions, relevant Swift/Dart/Go owners inspected; Markdown links,
  whitespace and scope checked. Executor ran no app tests/builds for documentation edits.
  Root independently ran baseline `swift test --package-path macos/WayforkCore`: green,
  Swift Testing 232 tests/3 suites including pinned sing-box acceptance; log
  `/tmp/wayfork-f24-baseline.log`. This verifies the pre-F24 baseline, not new list behavior.
- Root review: read changed design/model/routing/UX/control sections and roadmap,
  compared precedence with current Swift validator/generator and prototype; independently
  ran `git diff --check` successfully. Removed unrelated group-IP carve-out fix from
  scope during review. This is document evidence, not implementation acceptance.
- Blocker: none. Root accepted finalized split migration/suppression archives after
  independent review against the shipped validator and generator. Next: implement stage 2.


### Stage 2 executor evidence — prepared for root review, 2026-11-07

- Requested executor configuration: `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`,
  `fork_turns: "none"`; task `/root/rules_stage_2`. Available runtime model/effort/context
  capacity: **unknown**. Tool `pwd` verified `/Users/fost/Projects/Wayfork`.
- Implemented schema/export 4, atomic list edits, ordered route/DNS projection and row
  files, daemon filename validation/routed IDs, import collision handling and migration
  backups. Minimal app/control membership integration compiles; list UI/ctl commands remain
  stages 4/5. No stage-2 acceptance checkbox is claimed by the executor.
- Root-approved correction: only legacy duplicates enter paused archives. Shadowed rows
  remain in normal split lists because the actual F23 runtime builder disables missing
  secrets before validation. The frozen runtime differential checks full/missing secrets
  and defaults; raw-generator-only behavior is not the runtime oracle.
- `fixtures/legacy-f23/singbox/` contains 188 baseline files across 22 variants, verified
  byte-for-byte against pre-F24 `HEAD`. Frozen test-only F23 generator/renderer/runtime
  owner retain the old algorithms (type/name adapters only). Current goldens include three
  native F24 order/follow-default variants and pass the bundled pinned sing-box checks.
- Checks: `scripts/format.sh` completed. Initial `scripts/format.sh --lint` failed on
  an overlong end-of-line comment; the executor incorrectly reported it as passed. Root
  rejected acceptance attempt 1 for this failure. Full `swift test
  --package-path macos/WayforkCore` green: 247 core tests/3 suites and 118 daemon tests.
  Logs: `/tmp/wayfork-f24-tests.log`, `/tmp/wayfork-f24-format.log`. Release app and daemon
  build green with `xcodebuild -project macos/Wayfork.xcodeproj -scheme Wayfork
  -configuration Release -derivedDataPath /tmp/wayfork-f24-build CODE_SIGNING_ALLOWED=NO
  build`; log `/tmp/wayfork-f24-xcode.log`. Build only; no installation or live operations.
- Source compatibility detail: `Rule.listID` is optional only to decode frozen legacy rows
  before migration; schema-4 decode/save/import/edit validation rejects nil/orphan membership.
  No inherited target cache is stored. Color palette currently permits indices 0…7.
- Deliberate temporary limitation: shared F24 goldens require the stage-3 Dart/Go port;
  no cross-platform release between stages 2 and 3. Existing generated Flutter files remain
  untouched. No commits/push/publication/live changes. Root acceptance remains pending.

- Acceptance-1 correction: moved the validator comment onto its own line. Lint and
  whitespace checks were rerun individually: `scripts/format.sh --lint` exit 0
  (`/tmp/wayfork-f24-format-recheck.log`), `git diff --check` exit 0. The backup implementation
  uses atomic replacement at a content-addressed `before-schema-4-<hash>` path, not exclusive
  no-overwrite semantics: identical backup bytes are reused; a partial/corrupt retry at that
  same hash path is atomically repaired from the still-intact original. Different legacy
  bytes have different backup paths. Existing storage tests check backup/original contents
  and rejection of invalid writes; no stronger filesystem concurrency guarantee is claimed.

### Root stage-2 acceptance

Accepted 2026-11-07 on attempt 2 after the lint correction. Independent full Swift run: 247 core and 118 daemon tests passed (`/tmp/wayfork-f24-root-review.log`), including pinned-engine acceptance. Independent format lint retry exited 0 (`/tmp/wayfork-f24-root-format-recheck.log`); `git diff --check` passed. Root compared all 188 frozen files against HEAD: zero mismatches. Reviewed model/migration, projection, import, daemon validation, persistence and generated-behavior tests; inspected successful Release build log. No live or visual acceptance claimed. Stage 3 starts next; stage 2 had one failed acceptance (lint), resolved.

### Stage-3 launch

Intent recorded successfully. Requested `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`, `fork_turns: "none"`; returned task name `/root/rules_stage_3`, no opaque ID exposed. Runtime model/effort unknown. Task explicitly requires cwd verification in `/Users/fost/Projects/Wayfork`. Acceptance attempts: 0.

### Root stage-3 checks and bounded cross-platform correction

Root independently ran full Flutter tests (400 passed), Go tests (passed), and pinned `/Users/fost/flutter/bin/dart analyze --fatal-infos` (exit0). Bare PATH Dart gave unrelated SDK diagnostics; pinned 3.12.2 is the acceptance toolchain. Stage3 remains pending final review while prior stage2 executor fixes the identified name-only collision repeated-import defect to match tested Dart behavior. No parallel implementation stages; stage3 executor has handed off. Stage2 correction is limited to Swift import plus regression tests.

### Root stage-3 acceptance and import correction

Stage3 accepted after independent source review, 400 Flutter tests, pinned Dart analyze and format exit0, Go test/vet and GOOS=windows build exit0, diff check clean. Logs `/tmp/wayfork-f24-root-{flutter,dart-pinned,dart-format,go}.log`. Confirmed characters pin/hash unchanged. Stage2 same-agent import correction reviewed and independently tested (`repeatedImportReusesOnlyTheExpectedDisambiguatedListName`, passed); full executor Swift run248+118 and lint passed. Stages1–3 accepted; no visual/live acceptance claimed.

### Stage-4 launch

Intent recorded successfully. Requested `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`, `fork_turns: "none"`; returned task name `/root/rules_stage_4`, no opaque ID exposed. Runtime model/effort unknown. Cwd verification explicitly required: `/Users/fost/Projects/Wayfork`. Acceptance attempts0. Build/UI/control implementation running; no installation or live operation authorized.

### Stage 4 executor evidence — prepared for root review, 2026-11-07

- Requested executor configuration (as supplied by root): `model: "gpt-6.1-sol"`,
  `reasoning_effort: "high"`, `fork_turns: "none"`; task `/root/rules_stage_4`.
  Runtime model/effort/context capacity: **unknown**. Tool `pwd` verified
  `/Users/fost/Projects/Wayfork`. No nested agents. Stages 1–3 were accepted on entry.
- Implemented R1–R5 Settings source-list cards, Everything else line, collapsed Recent,
  flat search with list identity, list expand/rename/color/pause/menu visibility, list
  and selected-row drag moves, end-of-order list drop, context moves, concrete pins and
  Use list route. Existing pattern/match/app/IP/network/note/issue editing remains.
  New list reuses the guide's token component, with per-match hints, app chooser/drop,
  Recent checkboxes and one atomic creation at the top. Quick add and Recent choose a
  list; equal patterns in another list stay untouched.
- Shared exit menu includes groups/current member/latency, tunnel overflow, Direct and
  dynamic Everything else. Settings and popover use the same one-update route edit.
  Ten-second Undo is guarded and invalidated on intervening target changes/deletion,
  including an ABA sequence. Popover hides Lists below two total lists, caps eligible
  rows at six, ranks overflow by the most recent GUI target switch with UUID tie-break,
  and retains scrolling caps. Preference ordering never changes matching order.
- Added `lists.list` / `lists.set`, CLI parsing/help, list-scoped `rules.add` with an
  optional concrete pin, membership/priority/binding metadata and inert warnings.
  A scoped write probes the new read method first; old apps cannot silently ignore its
  list key and perform an unscoped write. Pending inverses preserve list binding,
  row membership/order/pins, and skip GUI-deleted lists or changed values. The pending
  journal is persisted before mutation; rollback/confirmation persist the latest store
  before journal removal. A tested resolution gate serializes confirm/revert/deadline,
  verifies pending ownership, and retries a failed rollback with the journal retained.
- Exit-deletion confirmations count distinct affected lists and actually removed rows,
  including doomed groups; the shipped deletion policy and surviving shells/pins remain.
  Corrected the prototype's outdated claim that only this list's connections reset:
  the approved main-config reconcile can restart the routing engine.
- Checks: `scripts/format.sh` exit 0; `scripts/format.sh --lint` exit 0;
  `git diff --check` exit 0. Full `swift test --package-path macos/WayforkCore` exit 0:
  **256 core tests in 4 suites and 118 daemon tests** (including pinned-engine checks),
  `/tmp/wayfork-f24-stage4-tests.log`. Eight focused new tests cover scoped duplicate
  handling, pending roundtrip, inverse ownership/membership/order, adopted/deleted lists,
  pins during multiselect moves, and competing async finalizers. One intermediate test
  compilation failed because a mutating gate call was inside `#expect`; evaluating the
  result before the assertion fixed it and the full retry passed.
- Release app build exit 0 with `xcodebuild -project macos/Wayfork.xcodeproj -scheme
  Wayfork -configuration Release -derivedDataPath /tmp/wayfork-f24-stage4-build
  CODE_SIGNING_ALLOWED=NO build`; `/tmp/wayfork-f24-stage4-xcode.log`. Artifact:
  `/tmp/wayfork-f24-stage4-build/Build/Products/Release/Wayfork.app`.
  Standalone Release `wayforkctl` build exit 0 (`/tmp/wayfork-f24-stage4-ctl-build.log`);
  offline help and four usage-error cases passed with expected exits 0/2. No command
  connected to the running app. No installation, live app operation, commit/push or
  publication. Existing compiler warnings are not represented as newly introduced errors.
- Manual appearance and live routing/ctl acceptance remain open for stage 6; root owns
  stage-4 acceptance checkboxes. Windows and shared fixtures were not edited by this stage.

### Root stage-4 acceptance

Accepted after independent source review and full Swift tests256+118, format lint and diff checks all exit0. Inspected latest Release app build success and ran standalone Release wayforkctl help offline. Logs `/tmp/wayfork-f24-root-stage4-{tests,lint}.log`, app `/tmp/wayfork-f24-stage4-build/Build/Products/Release/Wayfork.app`. Source review covered R1–R5 controls, recency versus matching order, scoped CLI and serialized finalization/rollback. No installation, visual or live routing acceptance. Stage5 proceeds only to its concrete local Windows board before the explicit maintainer visual gate.

### Stage-5 design launch

Intent recorded successfully. Requested `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`, `fork_turns: "none"`; returned task name `/root/rules_stage_5`, no opaque ID exposed. Runtime model/effort unknown. Executor must verify cwd. Scope is local Windows board/design only; existing explicit maintainer visual gate remains before Flutter UI implementation.

### Stage 5 design executor evidence — visual gate pending, 2026-11-07

- Requested configuration supplied by root: `model: "gpt-6.1-sol"`,
  `reasoning_effort: "high"`, `fork_turns: "none"`; task `/root/rules_stage_5`.
  Runtime model/effort/context capacity: **unknown**. Tool `pwd` confirmed
  `/Users/fost/Projects/Wayfork`; no nested agents. Stages 1–4 accepted on entry.
- Prepared five local Windows review boards starting at
  [W-lists](../design/prototype/windows.html#W-lists): Rules/route menu, light/dark tray,
  New list/search/Recent, pins/pause/context menus, warnings/migration. Added the matching
  [WM22 design delta](../design/08-windows.md#named-rule-lists-wm22-f24). Existing HTML
  boards were preserved byte-for-byte outside the scoped added style, TOC entry and
  appended boards. No Flutter, Go, Swift or fixture edits in this stage.
- Checks: `python3 /tmp/wayfork-wlists-check.py` passed unique IDs, local anchors/resource
  paths, original-board preservation, strict new-board element nesting and design-delta
  link paths. An initial checker mishandled self-closing SVG paths; the checker was fixed,
  not the valid SVG. `git diff --check` passed. No app tests/builds were needed for this
  static design-only change.
- Chromium rendered all five boards at 1420 × 980 through a loopback-only HTTP preview.
  DOM measurement found no horizontal overflow in new list rows/menus/dialog/panels or
  clipped main-window content after the scoped CSS correction. Each tray example has
  exactly six displayed lists and the completed Claude → Europe switch. Inspected
  overview, light/dark tray, creation/search, pin/context and migration/feedback captures.
  Root identified low-contrast surrounding dark-menu captions; a dark backing corrected
  them. Screenshots are in `/tmp/wayfork-wlists-review/wayfork-wlists-{overview,tray,new,pins,feedback}.png`;
  preview URL `http://127.0.0.1:8769/docs/design/prototype/windows.html#W-lists`
  (temporary server, bound to `127.0.0.1` only). Browser `file:` navigation was blocked;
  this local server was the fallback, not an external publication.
- **Remaining gate:** maintainer must approve the concrete W-lists board before Flutter
  UI implementation. Root owns stage checkboxes; no visual approval or stage-5 completion
  claimed. No live routing/migration evidence, installation, live Wayfork operation,
  external publication, commit or push. Existing unrelated work remains intact. Resume
  this executor for the implementation half only after root records that approval.

### Historical root checkpoint — visual gate (superseded by 2026-11-08 resume)

Stages1–4 accepted. Stage5 design portion independently checked: root read08-windows F24 delta, inspected corrected overview and creation/search screenshots, ran HTML integrity checker and diff check successfully; preview HTTP200 and opened in browser at `http://127.0.0.1:8769/docs/design/prototype/windows.html?v=6#W-lists`. The first stage5 board checkbox is accepted; user visual approval, Flutter UI implementation and stage6 remain open. User approval requested via async question after concrete preview was ready; no answer yet. This is the explicit stage5 gate, not a runtime-model blocker. Resume `/root/rules_stage_5` via followup after visual approval. Preview server loopback session84391 remains available. No commits/push/install/live changes; initial generated Flutter files preserved. Last required checks remain green: Swift256core+118daemon, Flutter400, pinned Dart analyze/format, Go test/vet/Windows cross-build, Release macOS app+ctl. macOS live/visual checks still open; build `/tmp/wayfork-f24-stage4-build/Build/Products/Release/Wayfork.app`. No failed acceptance in stages3–5; stage2 had one lint failure resolved before acceptance.

### Resume — 2026-11-08

User instruction "делай roadmap" follows the concrete W-lists preview and explicit approval gate; root records authorization to proceed with that design. Stage5 implementation resumes in the same executor `/root/rules_stage_5` per workflow; stage5 acceptance failures remain0. Main gpt-6-astra/high confirmation from this chat remains valid; actual runtime model/effort remain unknown. Root cwd reverified with pwd; existing dirty changes retained. No commit/push/install/live operation authorized by this continuation. Next: complete Flutter list UI/tray and tests, independent root acceptance, then prepare stage6 manual artifacts/checklist without touching live Wayfork.

### Root build preparation — 2026-11-08

`scripts/dev-sign.sh --configuration Release` exited0. Signed app: `build/DerivedData/Build/Products/Release/Wayfork.app`. The script verified app/daemon/bundled-engine signatures and matching embedded daemon TeamID. Log: `/tmp/wayfork-f24-signed-build.log`. This is a build artifact only: no installation, launch, helper registration or live acceptance. Stage6 checkboxes remain open.

### Stage 5 implementation executor evidence — prepared for root review, 2026-11-08

- Resumed the same executor `/root/rules_stage_5` after root recorded the maintainer's
  W-lists approval. Original requested launch: `model: "gpt-6.1-sol"`,
  `reasoning_effort: "high"`, `fork_turns: "none"`. Runtime model/effort/context capacity
  remain **unknown**. `pwd` reverified `/Users/fost/Projects/Wayfork`. No nested agents.
- Implemented list-owned Rules expanders, separate Everything else, flat search with
  list identity/winning row, name/color/pause/tray visibility, ordered list/header moves,
  Ctrl/Shift row selection, pin-preserving multi-row moves and end drop targets. Existing
  inline pattern/match/IP/app/network/note editing remains in `RuleEditor`/row owners.
  GUI validation now passes available routed exits to the accepted validator so a
  missing-secret exit does not falsely shadow a usable later row.
- New list ContentDialog keeps a draft of normalized tokens, app picker/drop and Recent
  selections, then creates at the top with one store edit. Invalid names/tokens leave the
  store unchanged; an invalid quick-add prefill remains editable. Recent hosts sharing a
  suffix share one token/checkbox contribution; removing it clears associated selections.
  Quick add and Recent use explicit list membership and last valid used membership;
  equal patterns in other lists remain untouched. No lists opens creation.
- Shared route controls show groups/member/latency, tunnel overflow, Direct and dynamic
  Everything else. Native tray Lists submenus and Dashboard use the same model mutation;
  the existing app has no separate Flutter tray window, so no window lifecycle was added.
  Menu visibility and most-recent-switch overflow selection (six maximum, UUID tie-break)
  never alter source list order. Dashboard list scrolling stays capped.
- One target change saves/applies once. Ten-second Undo is available from both Dashboard
  and the native tray without opening the window; binding revisions invalidate stale
  Undo after a newer route edit/deletion, including ABA. Unrelated newer row edits survive
  Undo. Disposal cancels its timer. Local last-used/expanded/switch-time preferences are
  stored separately in `rule-lists-ui.json`, using temp-file/flush/rename like the existing
  repository. Header modal actions wait for flyout closure before opening their dialog.
- Exit-delete confirmations name affected lists and count the actual removed rows,
  including cascaded groups, while preserving missing-target shells and other-exit pins.
  Import preview explains identity/order and earlier-local-list precedence; source import,
  migration and Go service behavior remain the accepted stage-3 implementation.
- Checks (all pinned SDK): `/Users/fost/flutter/bin/dart format lib/app lib/main.dart
  test/app` exit 0; `dart format --output=none --set-exit-if-changed lib test` exit 0
  (176 files, zero changes); `dart analyze --fatal-infos` exit 0, no issues;
  `/Users/fost/flutter/bin/flutter test --reporter expanded` exit 0, **416 tests passed**
  in 39 seconds. Logs `/tmp/wayfork-f24-stage5-{tests,analyze,format,format-lint}.log`.
  `git diff --check` exit 0.
- Coverage adds eight model tests, seven widget tests and one native-tray controller test:
  one apply, scoped duplicates/atomic creation, row order/pins/default/pause, overflow order,
  deletion counts, UI preference roundtrip, tokens/app picker/drop callback/Recent,
  invalid-name/prefill handling, minimum 880 × 600 layout with long names, dark selector,
  pin/list menu actions, expiry, Ctrl multiselection/end drop and tray switch/Undo while
  hidden. Existing per-exit UI expectations were updated to purpose-list behavior while
  retaining app/network/edit/drag assertions. Root's separate eight-model-test run passed.
- Intermediate verification found obsolete per-exit selectors/confirmation wording and a
  drag test hitting a clipped header. The drag test now scrolls the destination fully into
  view during dragging and passes. New regression tests exposed the shared-Recent-token
  and invalid-prefill problems identified by root, plus a flyout/modal ordering race;
  all corrected before the green full run. No check was weakened or skipped for a pass.
- No Windows native build/installation/appearance acceptance or live routing is claimed:
  Flutter tests run against fake service/window/tray adapters on macOS. The HTML board is
  still design evidence, not a running Windows capture. Stage-6 maintainer checks remain.
  No live Wayfork operation, remote operation, publication, commit or push. Existing
  untracked generated Flutter plugin files were left in place; no implementation edit to
  them, shared fixtures, Swift or Go. Root alone marks stage-5 acceptance checkboxes.

### Root stage-5 acceptance — 2026-11-08

Accepted after independent source/diff review and pinned full Flutter test416/416, Dart analyze --fatal-infos, Dart format lint176files/0changes and git diff --check, all exit0. Logs `/tmp/wayfork-f24-root-stage5-{full,analyze,format}.log`; additional independent8/8 model tests in `...-model.log`. Reviewed list/row moves, scoped creation/quick add, shared Recent token state, menu-to-dialog lifecycle, preference ordering, native tray switch/Undo, expiry and stale-target protection. Stage5 formal acceptance failures0; development failures were resolved before handoff. No live/native Windows appearance claim. Working tree remains dirty with intended stages1–5 changes and initial generated Flutter files preserved; unpushed commits0. Next: a fresh stage6 executor prepares the manual checklist only; installation/live/release gates stay open.

### Stage-6 preparation launch

Launch intent recorded successfully; requested `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`, `fork_turns: "none"`; returned task `/root/rules_stage_6`, no opaque ID exposed. Runtime model/effort/context capacity unknown. Executor must verify cwd. Scope: maintainer manual checklist/evidence only. No installation, live operations or release authorization inferred.

### Stage 6 preparation executor evidence — maintainer run still open, 2026-11-08

- Prepared [maintainer acceptance sheet](rule-lists-acceptance.md): concrete steps,
  expected outcomes and blank per-platform actual-evidence columns for coordinated
  upgrade/backup, G1 migration, R1–R5/native Windows mapping, editing/Undo, live
  routing/DNS/transport, import/delete and macOS pending ctl/old-app refusal. Release
  packaging/publication have separate unchecked authorization gates. No stage-6 live or
  visual checkbox is marked by this executor.
- `pwd` confirmed `/Users/fost/Projects/Wayfork`. Read project/parent rules,
  `~/.codex/WORKFLOW.md`, `roles/coder.md`, current roadmap and linked F24 contracts;
  checked actual CLI source/help, persistence paths and build scripts. Standalone
  Release `wayforkctl help` exited 0 offline; no command connected to the running app.
  Windows source-list mutations are explicitly unavailable; Dashboard/native tray is
  the implemented compact-control mapping, not a separate Flutter flyout window.
- Verified all 18 local links/anchors in the acceptance sheet, existing signed Release
  app/embedded daemon and root signed-build/stage-5 logs. `git diff --check` passed;
  additional no-index whitespace checks cover the new/untracked acceptance sheet and
  roadmap. Existing accepted tests/build evidence is cited separately from unrun live
  checks; no old test suite was rerun for documentation-only preparation.
- Requested launch settings supplied by root: `model: "gpt-6.1-sol"`,
  `reasoning_effort: "high"`, `fork_turns: "none"`; task `/root/rules_stage_6`.
  Actual runtime model/effort/context capacity remain **unknown**. No nested agents,
  installation, launch, helper/service registration, live mutation, remote operation,
  commit/push or publication. Only the new sheet and this append were edited.
- Remaining gate: maintainer performs authorized coordinated installation and records
  actual native appearance, migration, routing/DNS and ctl results outside the agent
  session; root reviews that evidence. Windows native build/live checks remain unrun.

### Current root checkpoint — ready for maintainer live acceptance, 2026-11-08

Stages1–5 accepted. Stage6 preparation independently reviewed: [manual acceptance checklist](rule-lists-acceptance.md), 18 local links/artifact paths resolve; CLI examples checked against offline Release help; git diff --check passed. Signed app `build/DerivedData/Build/Products/Release/Wayfork.app` independently reverified with codesign --verify --deep --strict, exit0. Live/visual/install/release stage6 boxes remain unchecked. No Windows native app build/install claim.

Root cwd `/Users/fost/Projects/Wayfork` verified with pwd; requested/confirmed main configuration remains gpt-6-astra/high, runtime model/effort unknown. Stage6 preparation acceptance failures0. Working tree intentionally dirty; unpushed commits0; initial generated Flutter files retained. No commit/push, install/restart or external publication. Real stop condition is maintainer installation and live/native observations: project CLAUDE.md prohibits restarting/reinstalling live Wayfork from this session because this session depends on its network. Next step is maintainer-run checklist on coordinated builds, then root review of actual results. Release/docs/version/publication require separate authorization.
