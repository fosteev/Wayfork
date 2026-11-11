# Rule lists — maintainer acceptance (F24 / M20 / WM22)

Prepared 2026-11-08 after root accepted implementation stages 1–5. **Stage 6 remains
open.** This is an execution sheet, not a report of installed, visual or live results.
The maintainer executes installation and all connectivity-affecting steps **outside
this agent session**, on a test machine with an independent recovery channel. No live
Wayfork was inspected, changed, installed, launched, stopped or restarted to prepare it.

Authority and contracts: [roadmap](rule-lists.md),
[model/migration](../design/01-data-model.md#rule-lists-f24),
[R1–R5 UX](../design/02-ux.md#rule-lists-f24),
[routing/DNS](../design/03-routing.md#rule-lists-f24),
[macOS ctl](../design/09-wayforkctl.md#rule-lists-f24),
[Windows mapping](../design/08-windows.md#named-rule-lists-wm22-f24).
Use placeholders only in shared evidence; keep real configurations, credentials, server
addresses, private captures and secret exports outside this repository.

## Evidence already available — not live acceptance

| Evidence | Result reported by accepted implementation/root checks | What it does not prove |
|---|---|---|
| Swift | 256 core + 118 daemon tests; format lint passed | Installed helper, macOS appearance, real routing/DNS |
| Dart/Flutter | 416 tests; pinned Dart analyze and format passed; root logs `/tmp/wayfork-f24-root-stage5-{full,analyze,format}.log` | Native Windows build, tray rendering or Windows networking; adapters in these tests are fake |
| Go | Stage-3 tests/vet and Windows cross-build passed | Native Windows service installation or live plan application |
| Shared fixtures/frozen F23 | Ordered F24 output and migration behavior checked by stages 2–3 | Provider connectivity or equivalent live DNS/traffic |
| macOS local signed build | `scripts/dev-sign.sh --configuration Release` exit 0; app/embedded daemon/engine signatures and daemon TeamID verified by root; `/tmp/wayfork-f24-signed-build.log` | Installation, launch, helper registration or runtime acceptance |
| Local design | Approved [macOS boards](../design/prototype/rule-lists.html#R1) and [Windows boards](../design/prototype/windows.html#W-lists) | Appearance of an installed app |

Existing local signed artifact:
[Wayfork.app](../../build/DerivedData/Build/Products/Release/Wayfork.app).
The preparation executor verified its directory exists and ran only standalone Release
`wayforkctl help` offline. No Windows native application build or live check was performed
on this Mac. Build instructions are in [README](../../README.md#development), signing
behavior in [dev-sign.sh](../../scripts/dev-sign.sh); Windows packaging is a separate gate
below, not an instruction to run a release script now.

## Run record and observation method

Fill both platform columns; a blank is **unrun**, not pass. Record pass/fail plus timestamp,
build/OS, sanitized log/capture path and observed winner for each row. Mark an unsupported
test setup as blocked with its reason; do not silently omit it.

| Run information | macOS actual | Windows actual |
|---|---|---|
| Maintainer/date/OS/architecture | | |
| App + helper/service build identity; signed artifact hash | | |
| Test profile/backup reference; secret availability baseline | | |
| Independent recovery channel and controlled endpoints ready | | |
| Visual capture directory; routing/DNS capture directory | | |

Prepare two controlled exits `<EXIT_A>` and `<EXIT_B>`, a group `<GROUP>`, a direct
baseline, `<CONTROLLED_DOMAIN>`, raw `<CONTROLLED_IPV4>`/subnet and an identifiable test
application `<TEST_APP>`. The endpoint must support separately observable TCP and UDP;
record its harness/version/commands in the private run record. Use a controlled
block-list hit `<BLOCKED_DOMAIN>`, a real local-name responder `<LOCAL_HOST>` and a tunnel
bootstrap hostname `<BOOTSTRAP_HOST>`. These are substitutions, not working endpoints.
Use disposable test lists, rows and exits for destructive cases.

For every route test, record the source list/row IDs, order, declared/inherited/pinned
binding and current availability, then open a **new** connection. Correlate logs/connection
view with the controlled endpoint's observed egress and protocol. A config hash, menu
label, `explain` result or cached browser tab alone is not live traffic evidence. Close
previous test clients or use a fresh process/connection and unique request marker; capture
both before and after each edit. Keep retries/background events outside the measurement
window. One list selection must yield one model edit and one apply; count corresponding
apply log events, not sing-box startup messages. A main-config reconcile can restart
sing-box and interrupt other connections; do not claim disruption is limited to this list.

## Commands and action classes

Commands below are for the maintainer after substituting placeholders. From repository
root on macOS, use the new standalone CLI, independently of which app is installed:

```sh
CTL='macos/WayforkCore/.build/release/wayforkctl'
"$CTL" help
"$CTL" status
"$CTL" lists --json
"$CTL" rules
"$CTL" failed
"$CTL" logs --source app --grep 'apply: plan' --since 10m --tail 100
"$CTL" logs --source sing-box --level warning --since 10m --tail 100
```

`help` is offline and harmless. `status`, `lists`, `rules`, `failed` and filtered `logs`
are read-only; app-dependent commands may return exit 3 when the app is not running.
**Do not start it from this agent session.** Output may contain private destinations;
sanitize evidence before sharing. Default macOS log redaction does not cover every resolved
server IP; do not use `--raw` for shared captures. `--dry-run` below validates/previews
without applying a store mutation, but requires the app/control socket.

On Windows, point `$ctl` at the coordinated installed CLI or matching test-build CLI:

```powershell
$ctl = '<PATH_TO_MATCHING_WAYFORKCTL_EXE>'
& $ctl info
& $ctl status
& $ctl logs --source daemon --grep 'apply:' --since 10m --tail 100
& $ctl connections
& $ctl explain --host '<CONTROLLED_DOMAIN>'
& $ctl explain --ip '<CONTROLLED_IPV4>' --network tcp
& $ctl explain --ip '<CONTROLLED_IPV4>' --network udp
& $ctl explain --process '<ABSOLUTE_TEST_EXE_PATH>' --network tcp
& $ctl explain --process '<ABSOLUTE_TEST_EXE_PATH>' --network udp
```

These Windows commands are read-only. `explain` evaluates the **applied generated plan**,
not source list names or real packet delivery. Windows logs have no CLI redaction; keep
raw output private. Windows has **no** `lists`, `lists set`, `rules add`, `confirm` or
`revert` source-rule API: edit lists in Flutter Rules/Dashboard/native tray only.

GUI edits, non-dry-run ctl mutations, confirm/revert, timeout rollback, imports, deletion,
helper/service upgrade, install, reconnect and app lifecycle operations can affect
connectivity. They belong to the maintainer's live run. No `--confirm-within 0`, service
stop/apply, direct store edit or installation command is needed to prepare this document.

## Coordinated installation, backup and migration

Run pre-upgrade observations with the old build first. Use disposable schema 1/2/3 profiles
on an isolated test account/machine for each migration version; do not overwrite the
maintainer's working profile to manufacture a witness. The app owns persistence.

| ID | Maintainer steps | Expected result | macOS actual evidence | Windows actual evidence |
|---|---|---|---|---|
| I1 | Before upgrade, record old app/helper/service identities, row IDs/order/flags/notes, default, secret availability and route/DNS witnesses M1–M4 below. Make a recoverable private copy using the platform's normal backup procedure; export a secretless transfer file. Back up required credentials separately using the platform's supported secure mechanism. | Recoverable pre-upgrade baseline. `store.json` alone does not back up Keychain/DPAPI secrets; a secretless export cannot restore credentials. | | |
| I2 | In a maintainer-controlled maintenance window, replace the macOS app with the signed artifact and upgrade/approve its embedded helper through the existing app workflow; check Settings › General and use Reinstall helper only if required. On Windows, use a separately authorized matching installer/repair carrying Flutter app + Go service + engines. Record actual versions/capability and apply result. | Coordinated new app/helper/service accepts safe per-row `rules-r-<UUID>.json` plans. A stale validator error is shown explicitly; no silent legacy generation or false applied status. Build success alone cannot satisfy this row. | | |
| I3 | First load each legacy test store. Inspect migration summary, list order/membership, archived count and saved schema. Locate `store.json.before-schema-4-<hash>` beside the store; compare its bytes/hash with the pre-upgrade original. | Automatic backup is recoverable and byte-equivalent to the original; summary explains split priority and paused duplicates. Save is atomic; row data retained. macOS store directory is `~/Library/Application Support/Wayfork`; Windows is `%LOCALAPPDATA%\Wayfork`. | | |
| I4 | Reopen the migrated test profile normally in the maintainer's run; compare IDs/membership/row content and backup with I3. On an isolated copy, test a pre-F24 build opening schema/export 4. | No second migration, new random list IDs, duplicate rows or changed backup bytes. Old build rejects newer schema/export without overwriting it. No downgrade converter is implied. | | |
| I5 | On the test rig only, retain an old helper/service while requesting the F24 plan; then restore the matching pair through the normal workflow. | Old validator rejects unsupported row topology explicitly; coordinated pair succeeds. New helper/service still accepts old-format plans. Do not diagnose compatibility solely by unchanged plan-version number (still 1) or matching version labels. | | |

If rollback is needed, the maintainer restores the saved old app/helper/service and
pre-upgrade profile/secure credentials together during that maintenance window. Never
feed schema 4 to an old build or edit the live store under a running app. Backup creation
is content-addressed and atomic, not an exclusive-create concurrency guarantee: identical
bytes reuse the path, a damaged retry can be repaired, changed originals get another hash.

| ID | Legacy witness and steps | Expected initial migrated behavior | macOS actual evidence | Windows actual evidence |
|---|---|---|---|---|
| M1 | Old exit order A then B: app broad → A and same app UDP → B; second app broad → B and TCP → A. Probe both transports before/after upgrade with the same secrets/default. | First app TCP A / UDP B; second app TCP A / UDP B. Narrowed exit lists precede broad exit lists, TCP before UDP inside narrowed buckets. One list per exit is not an acceptable substitute. Direct remains first; empty buckets absent. | | |
| M2 | Legacy disabled first row followed by an enabled duplicate for the same target, with Direct default. Inspect original IDs, flags, network, notes and patterns before/after. | Formerly duplicate row remains enabled as source data but belongs to paused, menu-hidden `Previously inactive` archive after normal lists; traffic stays Direct. No suppressed row activates silently. Nonduplicate disabled/missing-target rows stay in normal buckets with their flags intact. | | |
| M3 | Legacy overlapping A then B with A's required secret absent and B usable; compare against a second baseline with the secret present. Inspect shadowed row membership. | Shadowed B is retained in normal split buckets, never archived merely for shadowing. Missing-secret A is inert so B wins; with usable A, the corresponding original winner remains. Compare actual runtime builder outcomes, not a raw-generator-only oracle. | | |
| M4 | In disposable data, explicitly enable/move one archived duplicate after recording initial behavior. | Only that deliberate edit can activate it, subject to current order/other matches; source content/flags survived. Initial migration compatibility does not promise every future old-editor implicit reactivation. | | |

## Visual and editing acceptance — repeat on both platforms

Compare installed macOS views with [R1](../design/prototype/rule-lists.html#R1),
[R2](../design/prototype/rule-lists.html#R2),
[R3](../design/prototype/rule-lists.html#R3),
[R4](../design/prototype/rule-lists.html#R4) and
[R5](../design/prototype/rule-lists.html#R5), in light/dark appearance, at minimum window
size and with long names. On Windows compare the approved
[W-lists](../design/prototype/windows.html#W-lists) boards with native captures. Its compact
controls are **Dashboard + native Lists → list → exit submenus**, not a separate Flutter
tray window. Tray activation toggles the existing main window; native Undo must work while
it remains hidden. Record platform-specific interactions rather than accepting HTML or
Flutter widget screenshots as native evidence.

| ID | Maintainer steps | Expected result | macOS actual evidence | Windows actual evidence |
|---|---|---|---|---|
| U1 / R1 | Open Rules. Expand/collapse a list; edit name/color, row pattern/match/note/enabled/network; toggle pause. Check Everything else and Tunnels-page default toggle. | Purpose lists replace empty exit sections; Recent starts collapsed; counts/summary/warnings legible. One shared default field. No clipped controls/overflow at minimum size or long names. | | |
| U2 / R2 | Inspect route menu with groups, active member/latency and enough tunnels for More. Select A → B → Direct → Same as Everything else in separate windows; record applies and new flows each time. Repeat compact controls. | Same mutation from each surface; one apply per selection; inherited rows follow selected binding; pins unchanged. Default-resolved secondary label updates. Unavailable exits remain pickable with appropriate warning. | | |
| U3 / R3 | Test one total list, two lists and more than six eligible lists. Hide/show a list; switch an overflow list most recently, then inspect compact/native menu and Settings order. Test tied recency with a controlled preference fixture if needed. | Lists hidden below two total lists; at most six eligible entries and overflow count/link. Most recent GUI target switch chooses overflow entries, UUID tie-break. Hidden rows still route. No mutation of routing order; scrolling capped. Record tied fixture evidence separately from live clicks. | | |
| U4 / R4 | New list: draft normalized domain/IP/app tokens, choose/drop an app, select Recent hosts sharing a suffix, remove their shared token, cancel; repeat and Create. Try empty/duplicate/overlong name and invalid token/prefill. | Cancel/invalid input leaves store unchanged; shared suffix has one token and consistent checkboxes; editable invalid prefill. Create commits one list at top with one atomic apply and chosen color/route. Windows app picker/Browse targets `.exe`; macOS `.app`. | | |
| U5 | Add the same normalized match/network in list A and B via quick add and Recent, then repeat in A. Delete/pause last-used list; retry. Try an empty store. | Same-list duplicate is handled within A; B untouched. Last valid used list selected, else first enabled; empty store opens creation. Domain/IP/app/network/note editing remains available. | | |
| U6 / R5 | Search a pattern present in several lists; test exact/suffix and partial TCP/UDP overlap. Pause the earlier winning list or make its exit missing-secret. | Flat results show list identity/resolved binding; full shadow warning names winning list/row. Partial transport overlap does not mark entire broad row unreachable. Paused/unusable earlier rows do not falsely shadow later usable ones. | | |
| U7 / R5 | Reorder list headers and rows; move selected rows to another list using drag and context menu; drop at final end position. Use Cmd-click on macOS and Ctrl/Shift selection on Windows. Include one inherited and one pinned row. | Stable selected-row relative order; inherited row adopts destination; pin survives. End drop works, count/membership valid, each move atomic. Exit/tunnel store order changes alone do not alter list precedence. | | |
| U8 | Pin a row to Direct and another to A; switch parent list to B, move both to another list, then Use list route. Open header rename/color/delete dialogs from menus repeatedly. | Pins survive switch/move; unpin inherits immediately. Modal opens after menu closure with no stuck flyout/focus. | | |
| U9 | Switch A → B then Undo within 10 s; repeat after waiting over 10 s. Repeat from macOS popover and Windows Dashboard/native tray while window hidden. | Timely Undo restores A with one apply; expired Undo unavailable/has no effect. No extra window is required for native-tray Undo. | | |
| U10 | Switch A → B, make newer target edit to C, then invoke stale Undo; repeat A → B → A → B (ABA), list deletion, and unrelated newer row-note edit. | Newer target edit, deletion and ABA invalidate stale Undo; deleted list never resurrects. Undo after unrelated row edit restores binding only and preserves that newer row edit. | | |
| U11 | In a maintainer-controlled reopen, inspect show/hide, expanded state, last-used membership and recency; compare export fields. | Routing visibility flag persists portably; local expand/last-used/recency persist locally without changing source precedence. Windows uses `rule-lists-ui.json`; local UI preferences do not become export routing order. | | |

## Live routing, default, DNS and transport

Run the matrix on each platform. Use the platform's connection/log views plus controlled
endpoint observations. For DNS capture query name/type, selected resolver/answer and
physical-interface traffic; A/AAAA answers can also reflect the existing IPv4-only policy.
Test system resolution separately from direct listener queries. For example, on macOS a
maintainer can query the configured listener with `dig @'<WAYFORK_DNS_LISTENER>'
'<CONTROLLED_DOMAIN>' TXT`; that validates listener policy, not system-resolver adoption.
Windows `Resolve-DnsName -Name '<CONTROLLED_DOMAIN>' -Type TXT` uses the system path;
repeat A/AAAA with the same private capture procedure. Avoid browser DNS caches/DoH bypass
as the only witness. Do not publish bootstrap or provider hosts in captures.

| ID | Maintainer steps | Expected result | macOS actual evidence | Windows actual evidence |
|---|---|---|---|---|
| L1 | Put A, B, A lists in that order with overlapping domain/app/IP matchers. Swap list/row order. Test an early broad app/IP row and later narrowed TCP/UDP row; reverse them. | First active matching list/row wins in the non-Direct tier, even when nonadjacent rows share an exit. Narrowing filters at row position, never jumps earlier broad rows. Actual TCP/UDP matches agree with applied-plan evidence. | | |
| L2 | Same domain in upper follow-default list and lower explicit B list. Set default Direct, A, then group; pause/resume upper list, including a pinned Direct row. | Follow-default claims match before B; Direct-resolved follow-default is not a Direct exception. Pause removes all rows/pins so B can win before global fallback. Changing default updates resolution without rewriting row pins/membership. | | |
| L3 | Put explicit Direct domain/pin below a conflicting tunnel row and block-list hit; put tunnel-pinned row inside a Direct list. Pause/disable its owner. | Explicit Direct exception wins before block and tunnel tiers; tunnel pin remains ordinary ordered row. Paused list/disabled row absent, including its Direct pin. Follow-default resolving Direct stays after block. | | |
| L4 | Set selected exit disabled, missing, missing-secret, then configured/routed but runtime-unreachable; repeat for current default and empty/unusable group. Include valid pin in unavailable parent list. | First three are inert with warning, falling through to later rows/default. Routed runtime-down remains selected and fails, without Direct leak. Unusable default resolves Direct; runtime-down default fails. Valid other-exit pin survives unavailable parent target. | | |
| L5 | Probe same controlled app and raw IPv4/subnet with separate fresh TCP and UDP flows. Test broad inherited plus pinned Direct UDP exception; unpin/reorder and repeat. Connect by domain to an address in that subnet too. | Protocol-specific row only matches its transport; pinned Direct UDP works ahead of broad tunnel row. Domain-opened flows follow domain/fake-IP policy; raw-IP clients exercise IP rules. Process observed is actual connecting process, including local proxy cases. | | |
| L6 | Query overlapping Direct/tunnel domain rows for A, AAAA and TXT; repeat follow-default Direct above lower tunnel list and the reverse; change default tunnel/group/Direct. | Explicit Direct uses `dns-direct` before block. Ordered non-Direct domain rows select fake-IP for routed A/AAAA and existing `dns.final` for TXT; same-row non-A/AAAA fallback prevents later row stealing TXT. Follow-default Direct chooses direct at ordinary position. Existing default catch-all/IPv4-only behavior preserved. | | |
| L7 | With blocking on, query/probe controlled block-list hit, Never block exception, explicit Direct domain and follow-default Direct. Resolve local suffix responder and bootstrap hostname while changing lists/default. | Blocking remains between explicit Direct and ordinary rows. Never block, built-in local names, resolver probe, bootstrap/server protections, DDR policy/reverse mapping remain functional. Capture no unexpected bootstrap loop or DNS leakage. Do not infer success solely from endpoint reachability. | | |
| L8 | Change only app/IP/transport rows while repeating identical DNS query inputs; then test overlapping app/domain rules with known process metadata. | App/IP/network selectors never filter DNS answers. DNS source is domain projection; no promise DNS is attributed to app. Connection follows ordered available metadata/projection; correlate actual winner separately. | | |
| L9 | Probe private subnet through an active concrete tunnel-bound IP row, then pause/change target to Direct; inspect LAN warning and protected TUN/fake-IP/resolver addresses. | Existing tunnel private-range carve-out recomputed and reserved protections retained. Group-target private-range carve-out remains the existing limitation, not an F24 fix or an automatic pass claim. | | |

## macOS pending control and compatibility

The syntax below was checked against [CLI source](../../macos/WayforkCore/Sources/wayforkctl/Commands.swift)
and offline Release help. Use list/row UUIDs from read-only output to avoid ambiguous names.
Run each mutation separately, observe pending state, then finish it before the next one.
Never paste this as one batch that confirms before observation.

```sh
"$CTL" lists set '<LIST_ID>' --via '<EXIT_A_ID>' --dry-run
"$CTL" lists set '<LIST_ID>' --via '<EXIT_B_ID>' --confirm-within 60
"$CTL" status
# Only after route and independent control-channel checks: choose one completion.
"$CTL" confirm
# In a separate pending-change test, use revert instead of confirm.
"$CTL" revert
```

Additional independent tests, each requiring its own observation and confirm/revert or
timeout before proceeding:

```sh
"$CTL" lists set '<LIST_ID>' --via default --confirm-within 60
"$CTL" rules add '<CONTROLLED_DOMAIN>' --list '<LIST_ID>' --confirm-within 60
"$CTL" rules add '<CONTROLLED_DOMAIN>' --list '<LIST_ID>' --via direct --confirm-within 60
"$CTL" rules add '/Applications/<TEST_APP>.app' --list '<LIST_ID>' --via '<EXIT_A_ID>' --network udp --confirm-within 60
"$CTL" rules remove '<RULE_ID>' --confirm-within 60
```

`--list` without `--via` clears an existing pin in that list. `default` is for list
bindings only; it is not a concrete row pin. For a legacy command test use
`"$CTL" rules add '<CONTROLLED_DOMAIN>' --via '<EXIT_A_ID>' --confirm-within 60`.
Do not treat `confirm` and `revert` as read-only or run them as a diagnostic shortcut.

| ID | Maintainer steps | Expected result | macOS actual evidence |
|---|---|---|---|
| C1 | Dry-run a list switch; compare lists/rules/status and apply events before/after. Then switch a real test list and observe pending. Attempt a second mutation before completion. | Dry-run no store/apply/pending change; real switch one pending transaction/one apply. Second mutation refused as pendingChange. Output carries bindings/membership/pins/priority/warnings, without credentials. | |
| C2 | Confirm one pending switch after new-flow and recovery-channel checks; revert another. Leave a third unconfirmed beyond 60 s and inspect status/logs/notification. | Confirm preserves new target and clears pending; revert/timeout restore exact previous binding and apply once. Pending file is removed only after persistence/finalization succeeds; final status/logs agree. | |
| C3 | Add/update scoped inherited and pinned row, remove by UUID, then revert/timeout. Test list reorder while pending and move/modify row in GUI; delete destination/owner list before rollback. | Inverse preserves original value/membership/relative order/pin when still owned. Newer GUI changes survive; deleted lists not recreated; skipped inverses logged. Legacy add chooses first explicit exit-bound list or creates one, never follow-default by resolved coincidence. | |
| C4 | Use same pattern/network in a second list; mutate the selected first list only. Repeat no-via to clear pin. | Other list unchanged; undo restores selected row and previous pin/membership/order. Newly implicit list removed on rollback only if unchanged and empty. | |
| C5 | In an isolated lifecycle test, leave pending then interrupt/reopen the test app using maintainer-controlled normal recovery procedure; inspect `control-pending.json` and first apply. | Leftover inverse recovered before first apply; newer saved GUI changes preserved. Crash/launch recovery is unrun until actually exercised, not established by timeout alone. | |
| C6 | On an isolated pre-F24 running app, use new CLI `lists`, `lists set` and scoped `rules add`; compare store before/after. | Unsupported-list/unknown-method error clearly asks to update; scoped add probes lists first and does not send an unscoped fallback. Nothing changed. Exit 1 for app refusal, 2 for usage, 3 when no app; no auto-start. | |

## Transfer and destructive policy — disposable profile only

| ID | Maintainer steps | Expected result | macOS actual evidence | Windows actual evidence |
|---|---|---|---|---|
| T1 | Export schema 4 without secrets; replace-import into clean disposable profile on same and other platform, supplying required secrets securely. Compare ordered IDs/content/pause/menu flags/pins/default with source. | List/row order, inheritance vs concrete pins and follow-default survive; supported settings/default controls retain their existing semantics. No materialized inherited cache. A platform-specific app path need not run on the other OS; preserve data and test each OS with its own valid app. | | |
| T2 | Merge once and twice with existing earlier local lists; include identical IDs/content, conflicting IDs and equal names with distinct IDs. Inspect preview, remapped references and live overlap. | Identical import idempotent. Conflicts remap list/row/exit references together; names disambiguated, never identity-merged. Incoming lists append in source order; preview warns existing earlier lists can win. Repeated collision import does not create another suffixed list. | | |
| T3 | Import legacy exports 1/2/3; try schema/export newer than 4 and malformed orphan membership/duplicate IDs. | Legacy follows selected G1; newer/invalid input refused without partial store write. Existing good profile retained. | | |
| T4 | Delete disposable exit A referenced by inherited rows, A pins elsewhere, other-exit pins in its list shell, a small group and default; first cancel, then confirm. | Confirmation names distinct affected lists and actual removed rows, including doomed group effects. Removes A-bound inherited rows/A pins, keeps missing-target list shell and other-exit pins. Default/group cascade matches shipped policy; no silent Direct retarget/pause. Cancel unchanged. | | |
| T5 | Delete a disposable list containing inherited and pinned rows; cancel then confirm. | Count-based confirmation; delete removes that list and its rows, no implicit merge. Other lists unchanged. Existing target Undo/pending rollback cannot resurrect deleted list. | | |

## Final gates

Root owns roadmap checkboxes. Attach actual evidence above and request independent review
of failures/limitations before marking stage 6 live or visual items. A failed required row
keeps the corresponding gate open. A partial platform result is not cross-platform release
acceptance.

- [ ] Maintainer records coordinated installation and recoverable migration evidence.
- [ ] Maintainer records macOS native appearance, live routing/DNS and ctl acceptance.
- [ ] Maintainer records Windows native build/install, Dashboard/native-tray appearance and live routing/DNS acceptance.
- [ ] Root accepts recorded stage-6 results, with unresolved failures explicitly tracked.
- [ ] Release docs/version changes and packaging are separately authorized and completed.
- [ ] External release publication is separately authorized and completed.

Release preparation/publication are **not authorized by this checklist**. No README,
CHANGELOG, version, installer/release asset or external publication was changed as part
of this preparation.
