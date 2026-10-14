# Roadmap — mobile

> Status: **draft** · created 2026-10-14 · nothing below is approved yet.
> Whoever works a stage ticks its checkboxes as the work is verified, not when it "should
> be done". Phase statuses live in the table below and nowhere else.

Phone client of Wayfork: Android first, iPhone gated on a decision (MB0). Same product,
rules and tunnels, same backup file, same `sing-box.json` contract as the desktop apps;
a third client, not a port. Feature numbers (F1–F23) refer to [ROADMAP.md](ROADMAP.md);
the Windows track ([ROADMAP-windows.md](ROADMAP-windows.md)) is the model for how a
platform track is run.

Work proceeds phase by phase exactly as on macOS and Windows: a phase is closed only
after explicit maintainer approval.

| Phase | Deliverable | Status |
|---|---|---|
| MB0. Decisions | Stack, engine, layout, scope — the table below | draft |
| MB1. Features | Per-feature phone deltas against F1–F23, plus phone-only features | not started |
| MB2a. Feasibility spike | Our generated config running on a real Android phone (and iPhone if MB0 says so), go/no-go | not started |
| MB2b. Design | `docs/design/10-mobile.md` — every platform delta, written after the spike | not started |
| MB2c. UI prototype | `docs/design/prototype/mobile.html` — first sketch drawn 2026-10-14 (P, S, T, M, X, F, I boards, EN/RU switch), mirrored at https://claude.ai/artifact/49kVJnNXp8XHLHkpmHhqnK | sketch, not approved |
| MB3. Implementation | Milestones MM0–MM9 below | not started |

## Goal

A signed Android APK on the GitHub release page that splits a phone's traffic by site
and by app across several sing-box tunnels at once, in English and Russian, imports the
desktop backup, and passes the MM9 run on the maintainer's phone. iPhone follows only if
MB0 approves it.

## Context and constraints

Settled in chat on 2026-10-14 (the maintainer may overturn any of them in MB0):

- **One OS VPN, many tunnels inside it.** Android `VpnService` and iOS
  `NEPacketTunnelProvider` give one TUN per app; sing-box routes inside it exactly as on
  the Mac (fake-ip, sniffing, per-rule outbound, `direct`). Every tunnel kind that is a
  native sing-box outbound works (VLESS, VMess, Trojan, Shadowsocks, WireGuard,
  subscriptions — F13).
- **Not on the phone:** OpenVPN (per-tunnel processes and per-tunnel interfaces are
  impossible on iOS and pointless inside one TUN on Android), VLESS over XHTTP (own xray
  process), F12 resolver override (phone DNS already goes through the TUN), F17 local
  proxy port, F21 `wayforkctl`. An embedded OpenVPN 3 core is research, not a milestone.
- **Engine:** sing-box as a library (`libbox`, built with gomobile from the pinned
  1.13.19, `scripts/versions.env:5`) inside the VPN service / Network Extension. This
  reverses the Windows "no libbox" decision (ROADMAP-windows.md § W0) for phones only;
  phones cannot run a sing-box binary.
- **Logic stays in Dart.** The Windows app already holds models, parsers, rule
  normalization and the sing-box generator in pure-ish Dart
  (`windows/app/lib/core/{model,links,vless,wireguard,rules,singbox,plan}`). The phone
  app reuses that code instead of a second port. Windows-only files stay where they are
  (`secrets/dpapi_*`, `support/windows_adapters.dart`, `ipc/named_pipe_transport.dart`,
  `openvpn/`).
- **UI:** Flutter, Material 3 on Android (the prototype's look), iOS controls only where
  the platform differs. Strings in English and Russian from the first release: ICU
  plurals (1 сайт / 3 сайта / 6 сайтов), user-typed names never declined, locale number
  format (1,9 МБ/с). The desktop apps have no localisation; that is a separate decision.
- **Secrets:** Android Keystore-backed encrypted storage; iOS Keychain in a shared access
  group. Never plain text (CLAUDE.md § Secrets).
- **Distribution:** Android APK on GitHub releases. Google Play is not assumed (the
  `QUERY_ALL_PACKAGES` review and VPN policy are a separate decision). iPhone: an Apple
  VPN app needs an organisation developer account and is removed from the Russian App
  Store; TestFlight or nothing.
- **Prototype:** `docs/design/prototype/mobile.html` is the repo file; the Artifact is a
  copy for comments. Rebuild the copy by dropping the doctype, `html`, `head`, `body` and
  `meta` tags (the Artifact skeleton adds them) and republish to the same URL.

## Phases

### MB0. Decisions

Fix the stack and the scope before listing features, as W0 did for Windows.

- [ ] Write the decision table (engine, UI, where logic lives, secrets, repo layout,
      parity target, distribution, not doing) in this section, from "Context and
      constraints" above
- [ ] Maintainer decides: **iPhone in scope or not** (TestFlight only, organisation
      account, NE memory limit about 50 MB)
- [ ] Maintainer decides: **repo layout** — proposed `mobile/` (Flutter app, Android +
      iOS runners) and `packages/wayfork_core/` (Dart core shared with `windows/app`)
- [ ] Maintainer decides: **Russian for the desktop apps too**, or phone only for now
- [ ] Maintainer decides: **where a desktop-only tunnel's sites go** on the phone — "as
      usual" (drawn) or via the default tunnel when there is one
- [ ] Maintainer decides: **sync** — backup files and per-tunnel QR only (drawn), or
      something live

**Done when:** the table is in this file and the maintainer wrote "ок" on it; the status
row says approved with the date.

**Session:** opus, high; with the maintainer in chat. Sequential: everything else
depends on it.

### MB1. Features

What changes for the user compared with F1–F23, in the W1 format ("same" / "changed:
…" / "not on the phone: why"), plus the phone-only features.

- [ ] One entry per F1–F23 with the phone delta; Android and iPhone separately where
      they differ (F10 app rules, F19 app names)
- [ ] Phone-only features, numbered MF1…: Share target (S3), tunnel by QR scan and shown
      as QR (T3, T5), Quick Settings tile and the persistent notification (X1), Always-on
      VPN / Connect On Demand, backup import with desktop-only tunnels (S1, T1), Russian UI
- [ ] Each MF entry has its acceptance line, as F-entries do in ROADMAP.md
- [ ] "Later (mobile)" list: OpenVPN 3 core, Google Play, live sync, widgets
- [ ] Prototype boards updated where MB1 changed a decision; Artifact copy republished

**Done when:** the maintainer approved MB1; every F-number appears exactly once
(`grep -c '^\*\*F[0-9]' docs/ROADMAP-mobile.md` → 23).

**Session:** opus, high; with the maintainer. After MB0.

### MB2a. Feasibility spike

Prove the routing scheme on a real phone before designing around it. Cheapest route: the
official sing-box apps (SFA on Android, SFI on iPhone) already wrap libbox, so a profile
with our generated config tests the engine without writing an app.

- [ ] Produce a phone-shaped `sing-box.json` from the current generator by hand: drop
      OpenVPN outbounds and `process_path*` rules, TUN inbound with `auto_route`,
      `auto_detect_interface`; keep fake-ip, sniffing, rule-sets, two or more tunnel
      outbounds, a `direct` exception (secrets from the maintainer, never committed)
- [ ] Android (SFA, sing-box 1.13.x): site A via tunnel 1, site B via tunnel 2, site C
      direct, checked by the exit IP each site reports
- [ ] Android: a `package_name` rule sends one app through a tunnel; the connection log
      names the package for direct traffic too (F15/F19 app names depend on it)
- [ ] Android: Wi-Fi ↔ mobile data switch, tunnels recover without user action; time it
- [ ] Android: battery and memory over one hour of normal use, written down
- [ ] iPhone (only if MB0 kept it, SFI via TestFlight or App Store outside RU): the same
      three-site check, plus Network Extension memory with our block lists (F18) loaded
- [ ] Results and go/no-go written to `docs/design/10-mobile.md` § Spike

**Done when:** § Spike exists with each check's outcome and a GO or NO-GO line, and the
maintainer approved it.

**Session:** opus, high, plus the maintainer's phone for every run (the session prepares
configs and reads logs; the maintainer installs and taps). After MB1.

### MB2b. Design

`docs/design/10-mobile.md`, in the shape of `08-windows.md`: only the deltas, the
desktop docs stay the reference.

- [ ] Process model: Android `VpnService` in the app process or its own (`:vpn`), iOS
      app + Network Extension; who owns libbox; what survives the UI being killed
- [ ] Config handoff: Dart generator → JSON → platform channel (Android) / app-group
      file (iOS); reload without dropping the TUN where libbox allows it
- [ ] Stats, connections, logs: libbox command client in place of the daemon's sampler
      and socket; which F9/F14/F15/F19/F20 numbers come from where
- [ ] Generator changes: a `mobile` target in the Dart generator (TUN inbound, no
      OpenVPN, `package_name` instead of `process_path_regex`, desktop-only tunnels
      skipped) with golden fixtures `fixtures/singbox/mobile-*`
- [ ] Shared Dart core: the exact file list that moves to `packages/wayfork_core/`, what
      stays in `windows/app`, how the Windows app imports it
- [ ] Secrets, backup import/export, desktop-only tunnels and app rules in a backup
- [ ] Localisation: ARB files, ICU plurals, the string table from the prototype's RU
      switch as the starting contract
- [ ] Share target, QR (camera permission), Quick Settings tile, notification channels,
      Always-on VPN
- [ ] Build: libbox `.aar` (and `.xcframework`) from pinned sources, checksums in
      `scripts/versions.env`, CI job
- [ ] Error catalogue additions (VPN permission revoked, another VPN took over, Always-on
      lockdown)

**Done when:** the maintainer approved `10-mobile.md`; implementation prompts for MM1–MM8
are written into "Session prompts" below from it.

**Session:** opus, high. After MB2a GO.

### MB2c. UI prototype

- [x] First sketch: 23 frames, EN/RU switch (2026-10-14)
- [ ] Maintainer comments on the Artifact read and answered (ArtifactComments)
- [ ] Boards updated to MB1/MB2b decisions; repo file canonical, Artifact republished
- [ ] Approved by the maintainer

**Done when:** the status row says approved with the date.

**Session:** opus, medium. Can run alongside MB1 and MB2b (prototype file only, no
overlap with docs).

### MB3. Implementation

Order follows dependencies; one repo, so every milestone is sequential. Each milestone
ends with a `/plan-review` acceptance and a commit on the maintainer's command.

#### MM0 — Shared Dart core

Move the platform-free core out of `windows/app` so both apps build from one copy.
Windows must behave exactly as before.

- [ ] `packages/wayfork_core/` created (pure Dart package, exact pins, `dart analyze
      --fatal-infos` clean)
- [ ] The MB2b file list moved with `git mv`; imports in `windows/app` rewritten to
      `package:wayfork_core/…`
- [ ] Core tests moved with the code and green under `dart test`
- [ ] `windows/app` still green: `flutter analyze`, `flutter test`
- [ ] Fixtures paths still resolve (`fixtures/README.md`)
- [ ] CI runs the package tests

**Done when:** `cd packages/wayfork_core && dart test` and `cd windows/app && flutter
test` both pass; `git diff --stat` shows moves, not rewrites.

**Session:** sonnet, high. First implementation milestone.

#### MM1 — libbox build

- [ ] `scripts/fetch-libbox.sh` (or build script) producing `libbox.aar` from sing-box
      1.13.19 with the tags the spike used; checksum pinned in `scripts/versions.env`
- [ ] Output git-ignored; CI caches it
- [ ] Smoke test: an Android instrumentation test loads libbox and prints its version

**Done when:** a clean checkout builds the `.aar` with one command and the smoke test
passes on an emulator.

**Session:** opus, high (native build, gomobile toolchain, judgement on tags). After MM0.

#### MM2 — Android VPN service

- [ ] Kotlin `VpnService` hosting libbox, started and stopped over a platform channel
- [ ] Foreground notification with summary, rates, Turn off (X1)
- [ ] Socket protection / interface detection so tunnel traffic does not loop
- [ ] Connection owner lookup (UID → package) for app rules and app names
- [ ] Revoked permission and "another VPN took over" reported to the app
- [ ] Always-on VPN supported (service starts without the UI)

**Done when:** on an emulator and on the maintainer's phone, a hand-written config from
MB2a starts, routes, survives the UI being swiped away, and stops from the notification.

**Session:** opus, high (lifecycle and state with no smoke test to lean on). After MM1.

#### MM3 — Mobile generator target

- [ ] `mobile` target in `packages/wayfork_core` generator per MB2b
- [ ] Golden fixtures `fixtures/singbox/mobile-*` (`WAYFORK_UPDATE_GOLDEN=1`)
- [ ] Desktop-only tunnels and iPhone-only restrictions covered by tests
- [ ] Desktop outputs byte-identical (existing goldens untouched)

**Done when:** `dart test` in the package passes and `git diff fixtures/singbox` shows
only new `mobile-*` files.

**Session:** sonnet, high. After MM0; can be done before MM2 but sequentially (same repo).

#### MM4 — App shell and screens

- [ ] `mobile/` Flutter app, Material 3, four tabs per prototype (Home, Sites, Tunnels,
      More)
- [ ] Store, secrets (Keystore), backup import/export wired to the core
- [ ] Home states P1–P5, Sites S1–S2, Tunnels T1 and T5, More M1
- [ ] EN and RU ARB files with ICU plurals; the prototype's RU table as source
- [ ] `flutter analyze --fatal-infos` and widget tests for each screen state

**Done when:** the app on an emulator turns routing on and off, adds a site and a
tunnel from a pasted link, in both languages; analyzer and tests clean.

**Session:** sonnet, high, from the approved prototype. After MM2 and MM3.

#### MM5 — Getting tunnels and sites in

- [ ] Clipboard offer, paste, subscription checklist, file picker (T2)
- [ ] QR scan (T3) and Show as QR behind the screen lock (T5)
- [ ] Share target: "Route <domain>" sheet (S3)
- [ ] Apps list with tunnel chip and TCP/UDP only (S4)
- [ ] Desktop-only tunnels and app rules kept through import → export round trip

**Done when:** each path adds a working tunnel or rule on the maintainer's phone; a
backup exported from the Mac, imported on the phone and exported again is equal to the
original (test with a fixture backup).

**Session:** sonnet, high. After MM4.

#### MM6 — Live numbers and diagnostics

- [ ] Rates, latency and sparkline (F9, F14) from the libbox command client
- [ ] Recent with Route (F15), Can't reach (F19), Connections by exit (F20)
- [ ] Problems log and Share diagnostics (sanitised, as on desktop)
- [ ] Block lists (F18), tunnel groups (F16)

**Done when:** every number on P1 and M2 is live on the phone and matches what the
connection log says for the same minute.

**Session:** sonnet, high. After MM5.

#### MM7 — First run and system surfaces

- [ ] First-run steps F1–F4, skip and resume as F22
- [ ] Quick Settings tile (on/off, long-press opens Home)
- [ ] Notifications: tunnel stopped working, with Retry

**Done when:** a clean install walks F1–F4 to a routed site; the tile toggles routing
with the app closed.

**Session:** sonnet, high. After MM6.

#### MM8 — Release

- [ ] Signing key kept outside the repo; `scripts/release-android.sh`
- [ ] Version shared with desktop (`0.x.y`), CHANGELOG entry, README section
- [ ] APK and checksum on the GitHub release

**Done when:** a tagged build produces a signed APK that installs over the previous one.

**Session:** sonnet, medium. After MM7.

#### MM9 — End-to-end on a phone

- [ ] Maintainer runs the MB1 acceptance lines on their phone for a day of normal use
- [ ] Findings filed as issues or folded into a hardening milestone

**Done when:** the maintainer signs the run off.

**Session:** the maintainer; opus for triage.

#### iPhone (only if MB0 keeps it)

Outline only; milestones are written after the Android release.

- [ ] Network Extension target hosting libbox, app group for config and secrets
- [ ] Cupertino deltas from the I boards; no app rules, no app names
- [ ] TestFlight distribution under an organisation account

## Session prompts

MB0, MB1, MB2a, MB2b and MB2c are sessions with the maintainer in the loop; they start
from the prompt below. MM0 has an executor prompt now because its scope is fixed by
existing code. MM1–MM8 prompts are written at the end of MB2b (its "done when"), since
they depend on the design doc.

### Prompt — MB0 + MB1 (decisions and features)

```
Session MB0+MB1 — Wayfork mobile: decisions and features · Model: opus, effort: high · first session of the mobile track

Working in /Users/fost/Projects/Wayfork. Task: close phases MB0 (decisions) and MB1 (features) of docs/ROADMAP-mobile.md with the maintainer. Nothing is implemented; this is a docs-only session.

Read: docs/ROADMAP-mobile.md (whole file, it is the plan); docs/ROADMAP-windows.md § W0 and § W1 (the format to copy); docs/ROADMAP.md feature entries F1–F23 (grep '^\*\*F[0-9]' for positions); the visible notes at the top of docs/design/prototype/mobile.html. Repo rules: CLAUDE.md. Chat in Russian, files in English.

Already decided, do not reopen: one OS VPN with sing-box routing inside; no OpenVPN, XHTTP, F12, F17, F21 on phones; libbox via gomobile; logic stays in Dart shared with windows/app; Flutter, Material 3; EN + RU; Android first, APK on GitHub.

Order:
1. Write the MB0 decision table into ROADMAP-mobile.md § MB0 (W0 format).
2. Ask the maintainer the five MB0 questions in one message, with a recommendation each; record answers in the table.
3. On "ок", mark MB0 approved with the date in the phase table.
4. Write MB1: one entry per F1–F23 (W1 format) and the MF list with acceptance lines; "Later (mobile)".
5. If an answer changes a drawn screen, update docs/design/prototype/mobile.html and republish the Artifact copy (recipe in project memory: wayfork-prototype-artifacts).
6. Ask for MB1 approval; on "ок", mark it approved.
Tick checkboxes in the roadmap only for what is actually done.

DoD: MB0 and MB1 approved in the phase table; grep -c '^\*\*F[0-9]' docs/ROADMAP-mobile.md prints 23.

Do not: write code, start the spike, touch desktop docs beyond a one-line link, commit or push (on the maintainer's command only). A question the prompt does not answer goes to the maintainer, not into a guess.

Last message: what was decided, what changed in files, what is still open.
```

### Prompt — MM0 (shared Dart core)

```
Session MM0 — Wayfork: extract the shared Dart core · Model: sonnet, effort: high · after MB2b is approved

Working in /Users/fost/Projects/Wayfork. Task: move the platform-free Dart core from windows/app/lib/core into a new pure-Dart package packages/wayfork_core and make windows/app depend on it, with no behaviour change.

Read: docs/ROADMAP-mobile.md § MM0; docs/design/10-mobile.md § Shared Dart core (it has the exact file list — follow it, do not choose files yourself); windows/app/pubspec.yaml; fixtures/README.md. Repo rules: CLAUDE.md (exact version pins, dart format + dart analyze --fatal-infos).
Entry points: windows/app/lib/core/ (modules model, links, vless, wireguard, rules, singbox, plan, app); windows/app/test/core/ (their tests).

Already decided, do not reopen: package name wayfork_core; path dependency from windows/app; Windows-only files (secrets/dpapi_*, support/windows_adapters.dart, ipc/named_pipe_transport.dart, openvpn/) stay in windows/app; moves are done with git mv so history follows.

Order:
1. Create packages/wayfork_core (pubspec with exact pins copied from windows/app where shared, analysis_options matching windows/app).
2. git mv the listed files and their tests.
3. Rewrite imports in both trees to package:wayfork_core/...; fix fixture paths in tests.
4. Add the package test job to CI next to the Windows app job.
Tick MM0 checkboxes in docs/ROADMAP-mobile.md only after the commands below pass.

DoD: cd packages/wayfork_core && dart format --set-exit-if-changed . && dart analyze --fatal-infos && dart test — pass; cd windows/app && dart format --set-exit-if-changed . && flutter analyze --fatal-infos && flutter test — pass; git diff --stat -M shows renames for the moved files.

Do not: change any logic, rename public symbols, touch the Go service, macOS sources or fixtures content, add the mobile app. Do not commit or push — acceptance does that. A question the prompt does not answer goes into the report.

Last message — report: done (files) / deviations from the plan / not verified / open questions.
```

## Risks and open questions

- **libbox and our config disagree.** The generator was written for the desktop binary;
  some fields (TUN options, `process_path*`) differ on mobile. Found in MB2a with SFA,
  before any app code.
- **App names on Android.** F15/F19 show the app per connection; that needs the
  connection-owner lookup working inside the VPN service on the maintainer's Android
  version. Checked in MB2a; if it fails, the rows show the site only, as on iPhone.
- **Battery.** Every packet goes through userspace; fake-ip keeps DNS cheap, but the
  hour-long measurement in MB2a decides whether the sampler intervals need to change on
  phones.
- **MM0 touches the shipping Windows app.** Mitigated by moves-only and full Windows
  tests; still, release it together with a Windows build check in the VM.
- **iPhone economics.** Organisation account and RU store removal; TestFlight only.
  Decision in MB0.
- **Open for the maintainer (MB0):** iPhone yes/no; repo layout; desktop Russian;
  desktop-only tunnel fallback; sync.

## Order of work

MB0 → MB1 → MB2a (needs the maintainer's phone) → MB2b → MM0 → MM1 → MM2 → MM3 → MM4 →
MM5 → MM6 → MM7 → MM8 → MM9. MB2c runs alongside MB1–MB2b. Everything in MB3 is one
repo, so milestones are strictly sequential. Start with the MB0+MB1 prompt in a fresh
opus session.
