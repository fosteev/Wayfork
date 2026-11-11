# Rule lists and traffic — saved work checkpoint

Date: 2026-11-11. Branch: `wip/rule-lists-traffic-2026-11-11`.
The maintainer explicitly requested committing and pushing the completed and unfinished
work to a separate branch. This is a development checkpoint, not a release or live acceptance.

## Included work

- F24 named rule lists across macOS and Windows: schema/export migration, ordered routing
  and DNS, pins, pause, follow-default, list editing, search, move/drag, popover/tray and CLI.
  Stages 1–5 were accepted; see [the roadmap](rule-lists.md).
- macOS compact Rules UI and per-rule download/upload rates, using the matched rule-set
  UUID from the existing sing-box sampling loop. No extra per-row polling.
  See [implementation and checks](rule-traffic.md).
- Approved HTML prototypes, shared fixtures, frozen migration fixtures, tests, design
  contracts and the [manual acceptance checklist](rule-lists-acceptance.md).

Per-rule traffic depends on F24's `rules-r-<UUID>` route identity, so both changes are kept
together. Bundled binaries, build outputs, user settings/credentials and the three local
Flutter `generated_plugin*` files are excluded.

## Verification evidence

- The current macOS, Windows and fixture changes were compared byte-for-byte with the
  retained 2026-11-08 implementation worktree; there were no source differences.
- macOS, 2026-11-08: 256 core + 124 daemon-core tests passed; changed Swift files passed
  strict formatting; app and daemon Debug build passed.
- F24 Windows, previously accepted on 2026-11-08: 416 Flutter tests, Dart analysis/format,
  Go tests/vet and Windows service cross-build passed. This is historical evidence, not a
  new Windows native run on 2026-11-11.
- A loopback-only sing-box 1.13.19 process verified the matched per-rule metadata shape.
  It did not test live VPN traffic or the app's display.
- The subsequent signed macOS Release build completed on 2026-11-08: app, daemon and
  bundled engine signatures passed verification; all engines and the block list were
  present. Artifact: `build/DerivedData/Build/Products/Release/Wayfork.app`, version 0.11.0,
  arm64. Build products are intentionally not part of this checkpoint.

## Remaining work — not accepted

- [ ] Run the F24 maintainer checklist for installed macOS and Windows builds: migration,
  UI behavior, live routing/DNS, transport rules, pins, pause/default, CLI rollback and
  import/delete cases. Record actual observations in its platform-specific columns.
- [ ] Visually accept the compact macOS Rules screen in both appearances; verify editing,
  notes, search, selection and drag/drop in the built app.
- [ ] Verify real daemon-to-UI rule rates, idle/unavailable values and the three-second
  stale transition after deployment. Confirm which rule wins overlapping matches.
- [ ] Build/install the native Windows app and service and verify tray/UI/networking there.
- [ ] After acceptance, decide release version, packaging and publication separately.

Installation status is unknown: a manual reinstall command was provided, but no execution
or acceptance evidence has been recorded. Committing this checkpoint does not close any
of these items. No running Wayfork instance is stopped, restarted or reconfigured for it.
