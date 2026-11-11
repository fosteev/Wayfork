# Rules layout and per-rule traffic

Approved: compact variant C layout in ../design/prototype/rules-traffic.html; implementation requested 2026-11-08.

Saved work checkpoint, 2026-11-11: [rules-checkpoint.md](rules-checkpoint.md).
Implementation and automated verification are complete; installed UI/live acceptance
remains open. The checkpoint branch is not a release or acceptance of the remaining gates.

## Scope and implementation

macOS Settings > Rules only. Preserve existing list migration, ordering, editing, pinned exits, notes, search, drag/drop and Windows work. Implement on an isolated copy of the dirty working tree at /tmp/wayfork-rule-traffic; integrate only task files after checking original baseline hashes. Initial implementation did not commit, install or restart the running VPN; the later checkpoint has explicit commit/push authority.

- Read existing sing-box /connections once per sampling interval as before. Attribute counters using its matched rule-set ID, never a second domain/app matcher or tunnel totals.
- Add backward-compatible optional rule counters to TrafficSnapshot. Missing capability or stale sample displays dashes; observed idle rules display zero. Preserve per-tunnel counters.
- Compact native rows, aligned site/match/protocol/traffic columns, notes only when populated or explicitly edited. Existing warning and pinned-route information remains accessible.
- Counters are sampled connection payload rates, not wire billing totals. Short-lived connections between polls can be missed, as with existing tunnel rates.

## Acceptance

- [x] Verify rule identity against bundled sing-box in a loopback-only isolated process (no TUN or system networking changes).
- [x] Tests: attribution, separate rules on one exit, direct/final separation, counter reset, disappearance, TCP/UDP, backwards payload decoding and unavailable/idle formatting.
- [x] Implement compact native columns, bounded exit menus, note editor, per-rule traffic cells; retain existing list actions, selection and route mutations (source review and successful build).
- [x] Swift tests, changed-file formatting and Xcode app/daemon build pass.
- [ ] Visually accept the built Rules screen in both appearances; exercise editing, notes, search, selection and drag/drop in the actual app. Verify live daemon-to-UI samples and the three-second stale transition after deployment. No live installation or restart performed in this session.

## Checkpoint

Implementation and automated checks complete. Main agent implemented directly; no delegation.
Baseline: HEAD 9a16e4d plus pre-existing dirty F24 work and prototype. Baseline hashes and
patch are outside repo in /tmp/wayfork-rule-traffic-baseline.*. The ten task files were
integrated into /Users/fost/Projects/Wayfork after original baseline hash checks and then
byte-verified against the tested worktree. No commit or push during initial implementation.

Evidence, 2026-11-08:

- Bundled sing-box 1.13.19, isolated loopback HTTP stream: actual matched route was
  `network=tcp rule_set=rules-r-00000000-0000-4000-8000-000000000101 => route(direct)`;
  a sample carried 131235 downloaded / 73 uploaded bytes. This proves the engine metadata
  shape, not the live app display. Temporary harness and sample: `/tmp/wayfork-traffic-proof.cjs`
  and `/tmp/wayfork-traffic-proof-sample.json`; the six new tests retain the relevant cases.
- `swift test --package-path macos/WayforkCore`: 124 daemon-core + 256 core tests passed,
  including six new per-rule cases. Log: `/tmp/wayfork-rule-traffic-tests.log`.
- Changed Swift files: `xcrun swift-format lint --strict --configuration .swift-format` passed.
- `xcodebuild -project macos/Wayfork.xcodeproj -scheme Wayfork -configuration Debug
  -derivedDataPath /tmp/wayfork-rule-traffic-build CODE_SIGNING_ALLOWED=NO build`: passed.
  Product: `/tmp/wayfork-rule-traffic-build/Build/Products/Debug/Wayfork.app`.
  Existing warnings remain outside this change; the isolated build has no bundled block list.
- `git diff --check` for task files passed. Running Wayfork was not quit, restarted,
  reinstalled or reconfigured, per CLAUDE.md. Actual UI and live XPC acceptance remain open.

Next step: review/deploy the build in a session where a VPN restart is explicitly allowed,
then accept the visual and live-traffic checklist above. The maintainer was given a manual
reinstallation command; its execution and the current installed state have not been
verified here. Model/effort runtime metadata: not disclosed; no executor agent.
