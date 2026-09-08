# H5 — Actionable dead-UDP hint

> Status: in progress · created 2026-09-02 · stage 1 done, feature approved 2026-09-02

## Goal

Clicking the one-way-UDP ⚠ (H3) shows *what* is dying — process, destination, bytes sent
with no reply — and offers **Try Direct**: a prefilled, editable Direct IP rule through
the normal add-rule path. The user goes from "voice is broken" to a working rule without
reading the Clash API by hand (which is what the maintainer had to do on 2026-09-02).

## Context and constraints

- The detector and the per-exit `oneWayUDPFlows` count already exist on both platforms
  (H3, [design/05-daemon.md](../design/05-daemon.md) § "Traffic sampling"); the ⚠ with a
  tooltip is on the macOS tunnel card and the Windows dashboard row.
- **Privacy boundary is the one real design change.** F9 deliberately forwards
  aggregates only — no hosts, addresses or processes leave the daemon. This feature adds
  a *pull*: a one-shot "details for tunnel X" request made on an explicit user click,
  never streamed. The daemon already holds everything needed per connection
  (`destinationIP`, `destinationPort`, `processPath`, cumulative up/down; age via the
  accumulator's `firstSeenAt`).
- Suggest, never auto-apply: a silent auto-added Direct rule is a leak-shaped decision.
  Prefill the exact address (`/32`), keep the field editable — proposing a wide CIDR
  automatically is dangerous (104.29.0.0/16 is the whole Cloudflare front); widening is
  the user's call. Wording must say "try": Direct cannot help when the ISP drops the
  traffic too.
- Both installers ship app and daemon/service together, so an additive IPC method needs
  no protocol bump; the app must still degrade gracefully (hide the details UI) when the
  request errors (decision, matches the H3 additive-field precedent).
- Repo convention: milestone checkboxes for this task live in
  [ROADMAP.md](../ROADMAP.md) § M7 and [ROADMAP-windows.md](../ROADMAP-windows.md) § WM8
  (created in stage 1); fine-grained progress lives here.

## Stages

### 1. Feature entry and approval

The phase gate: the feature text exists and the maintainer has approved it, including
the privacy-boundary change.

- [x] Add H5 to ROADMAP.md § "Hardening (field findings, 2026-09-01)" (follow-up of H3)
      and skeleton milestones M7 / WM8 referencing this file.
- [x] Maintainer approves the feature description and the pull-based details request
      (2026-09-02, including the privacy-boundary change).

**Done when:** the maintainer says so, in as many words.

### 2. Design notes

Record the decisions before code, as with H3/H4.

- [ ] 05-daemon.md: amend the F9 privacy note — details request shape
      (`oneWayUDPDetails(tunnelID)` → rows of destination, port, process, up-bytes, age;
      aggregated per destination+process, capped at ~20, sorted by bytes desc),
      user-initiated pull only, still never in logs or snapshots.
- [ ] 02-ux.md: the flyout/popover — row content, **Try Direct** button, prefilled
      editable pattern, the "may not help if your ISP drops it too" wording.
- [ ] 08-windows.md § Hardening: the pipe request, the fluent_ui flyout, graceful
      degradation when the service predates the method.

**Done when:** notes are in the three docs with no *(verify)* markers left open.

### 3. Daemon/service: the details request

Pure detection state is already in the accumulators; retain the last sample's metadata
and answer the query.

- [ ] Swift: sampler/accumulator retain enough of the last `[ClashConnection]` to list
      one-way flows per exit; new XPC method + payload in `Payloads.swift`; wire through
      `XPCService` / `DaemonClient`.
- [ ] Go: same retention in `TrafficSampler`/`TrafficAccumulator`; request/response in
      `wire.go` + service dispatcher; Dart payload + `service_client.dart` method.
- [ ] Tests on `fixtures/clash/connections.json` (the one-way entry must come back for
      tunnel A with its destination) plus synthetic aggregation/cap cases, all three
      suites. Assumption to check: the fixture's one-way entry has an empty
      `processPath` — extend the fixture only if the aggregation tests need a non-empty
      one, and regenerate expectations in all three suites together.

**Done when:** `go test ./...`, `flutter test`, and the WayforkCore package tests pass
(`xcodebuild test -scheme WayforkCore-Package -destination 'platform=macOS'` from
`Wayfork/WayforkCore`). The old caveat that
`openVPNServersAlwaysGoDirectByNameAndAddress` fails falsely under a live Wayfork is gone
as of 2026-09-07: `HostResolver.resolveIPv4` now drops fake-IP answers (F13, see
design/04-tunnels.md), which is what the test was tripping over.

### 4. UI on both platforms

- [ ] macOS: ⚠ becomes clickable → details under the card (risk below on popover
      nesting); each row has **Try Direct** → the quick-add path prefilled with the /32
      and target Direct, editable before Add.
- [ ] Windows: same via a fluent_ui flyout on the dashboard row → `QuickAddBar` /
      `rule_editing.dart` prefill.
- [ ] Hide the details affordance when the request fails or returns empty; tooltip-only
      ⚠ remains.
- [ ] Dart widget tests (flyout rows, prefill, graceful-degradation); Swift-side strings
      through `TrafficFormat` so they are unit-tested.

**Done when:** `dart format` + `dart analyze --fatal-infos` + `flutter test` are green;
`xcrun swift-format lint --recursive` clean; the app builds
(`xcodebuild -project Wayfork/Wayfork.xcodeproj -scheme Wayfork -configuration Debug
-derivedDataPath build/DerivedData build`).

### 5. Ship

- [ ] CHANGELOG § Unreleased entry; mark M7 / WM8 checkboxes.
- [ ] Live check on the Windows PC (`ssh wf-pc`): with the Discord Direct rules removed,
      join voice → ⚠ → flyout names Discord.exe and the 104.29.x address → Try Direct →
      voice connects; re-add the permanent rules after. macOS build only — the live
      Wayfork is installed by the maintainer.

**Done when:** both checks observed by the maintainer; roadmap status here flips to
"done".

## Risks and open questions

- **Privacy boundary** — the feature is exactly a hole in it; stage 1 is the explicit
  sign-off, and the design note is the record. If declined, the fallback is a
  documentation-only recipe (docs describing the two Discord CIDRs).
- **macOS popover nesting**: a `.popover` inside the `MenuBarExtra(.window)` popover may
  misbehave; fallback is inline expansion under the tunnel card. Known unknown — decide
  in stage 4, note the outcome in 02-ux.md.
- **Stale details**: flows close between the click and the reply; the flyout must render
  an empty answer honestly ("nothing one-way right now") rather than look broken.
- **Windows app/service skew** (MSI upgrade half-applied): the request errors → the UI
  degrades to the H3 tooltip; covered by a test in stage 4.

## Working order

Strictly 1 → 2 → 3 → 4 → 5 (phase gates). Within 3 and 4 the macOS and Windows halves
are independent and can go in either order; the field pain is on Windows, so Windows
first when in doubt. Stage 3 must land before 4 on each platform — the UI has nothing to
show without the request.
