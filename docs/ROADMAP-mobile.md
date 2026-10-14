# Roadmap — mobile

> Status: **draft** · created 2026-10-14 · MB0 and MB1 decided by recommendation
> 2026-10-15 (maintainer delegated), awaiting maintainer review; nothing is approved yet.
> Next: MB2a, which needs the maintainer's Android phone in hand.
> Whoever works a stage ticks its checkboxes as the work is verified, not when it "should
> be done". Phase statuses live in the table below and nowhere else.

Phone client of Wayfork: Android first, iPhone after the Android end-to-end run (MB0). Same product,
rules and tunnels, same backup file, same `sing-box.json` contract as the desktop apps;
a third client, not a port. Feature numbers (F1–F23) refer to [ROADMAP.md](ROADMAP.md);
the Windows track ([ROADMAP-windows.md](ROADMAP-windows.md)) is the model for how a
platform track is run.

Work proceeds phase by phase exactly as on macOS and Windows: a phase is closed only
after explicit maintainer approval.

| Phase | Deliverable | Status |
|---|---|---|
| MB0. Decisions | Stack, engine, layout, scope — the table below | decided by recommendation 2026-10-15 (maintainer delegated), awaiting maintainer review |
| MB1. Features | Per-feature phone deltas against F1–F23, plus phone-only features | decided by recommendation 2026-10-15 (maintainer delegated), awaiting maintainer review |
| MB2a. Feasibility spike | Our generated config running on a real Android phone, go/no-go (the iPhone check moves to the iPhone stage, MB0) | not started |
| MB2b. Design | `docs/design/10-mobile.md` — every platform delta, written after the spike | not started |
| MB2c. UI prototype | `docs/design/prototype/mobile.html` — first sketch drawn 2026-10-14 (P, S, T, M, X, F, I boards, EN/RU switch), mirrored at https://claude.ai/artifact/49kVJnNXp8XHLHkpmHhqnK | sketch, not approved |
| MB3. Implementation | Milestones MM0–MM9 below | not started |

## Goal

A signed Android APK on the GitHub release page that splits a phone's traffic by site
and by app across several sing-box tunnels at once, in English and Russian, imports the
desktop backup, and passes the MM9 run on the maintainer's phone. iPhone follows after MM9
(MB0, 2026-10-15).

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
  format (1,9 МБ/с). The desktop apps have no localisation; MB0 leaves that to a separate
  future F-entry in ROADMAP.md.
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

| Topic | Decision | Why |
|---|---|---|
| Engine | sing-box as a library (`libbox`, gomobile, built from the pinned 1.13.19 — `scripts/versions.env:5`) inside the OS VPN: one TUN per phone, sing-box routes inside it (fake-ip, sniffing, per-rule outbound, `direct`) | a phone allows one VPN per app and no sing-box binary; this reverses the Windows "no libbox" decision for phones only |
| Tunnel kinds | every kind that is a native sing-box outbound: VLESS, VMess, Trojan, Shadowsocks, WireGuard, subscriptions (F13) | they need no process and no interface of their own |
| UI | Flutter, Material 3 on Android (the prototype's look); iOS controls only where the platform differs | maintainer's stack; the Windows app is already Flutter |
| Where logic lives | Dart: models, link and config parsers, rule normalisation, the sing-box generator, import/export and the status texts move from `windows/app/lib/core/{model,links,vless,wireguard,rules,singbox,plan,app}` into a shared package (MM0); Kotlin: only the `VpnService` host, connection-owner lookup, tile and notification | one copy of the logic for two apps, as the Mac and Windows share design docs; the exact file list is MB2b's |
| Secrets | Android Keystore-backed encrypted storage; iPhone Keychain in a shared access group (iPhone stage) | never plain text (CLAUDE.md § Secrets) |
| Repo layout | `mobile/` (Flutter app, Android runner now, iOS runner at the iPhone stage) and `packages/wayfork_core/` (pure Dart, path dependency of both `mobile/` and `windows/app`) — *recommended option, 2026-10-15* | the monorepo shape W0 chose; one fixtures tree for three clients |
| iPhone | Android now; iPhone after MM9 — the outline milestone below stays, its milestones are written after the Android release. TestFlight only, organisation developer account, Network Extension memory about 50 MB — *recommended option, 2026-10-15* | the Apple account and the RU store removal cost money and time before anything is proven on Android |
| Localisation | the phone app ships in English and Russian from its first release (ICU plurals, typed names never declined, locale number format). Desktop localisation is a separate future F-entry in ROADMAP.md, not part of this track — *recommended option, 2026-10-15* | the phone UI is new, so strings start in ARB files at no extra cost; the desktop apps would need a string-extraction pass of their own |
| Desktop-only tunnels | an OpenVPN tunnel from a backup is kept as *Desktop only*; its sites go **as usual**, as if they had no rule: through the default tunnel when there is one, otherwise direct (drawn on S1, T1). A desktop-only default tunnel means no default on the phone — *recommended option, 2026-10-15* | the tunnel does not exist on the phone, so its rules do nothing there; the desktop already treats a down group's rules this way (F16: they fall to the default route) |
| Sync | backup file (the desktop export format, both ways) and per-tunnel QR / share only; live sync is "Later (mobile)" — *recommended option, 2026-10-15* | no server and no account exist; the backup format already round-trips between Mac and Windows |
| Parity target | F1–F23 as the MB1 entries below say; the phone-only features MF1–MF7 | ship the same product, diverge only where the phone forces it |
| Distribution | signed APK on the GitHub release page, version shared with the desktop apps; Google Play is "Later (mobile)" | Play reviews `QUERY_ALL_PACKAGES` and VPN apps; a GitHub APK has no such review |
| Not doing | OpenVPN (no per-tunnel process or interface inside one TUN, impossible on iOS), VLESS over XHTTP (own xray process), F12 resolver override, F17 local proxy port, F21 `wayforkctl`; an embedded OpenVPN 3 core is research, not a milestone | see "Context and constraints" |

- [x] Write the decision table (engine, UI, where logic lives, secrets, repo layout,
      parity target, distribution, not doing) in this section, from "Context and
      constraints" above
- [x] Maintainer decides: **iPhone in scope or not** (TestFlight only, organisation
      account, NE memory limit about 50 MB) — Android now, iPhone after MM9 (recommended
      option, 2026-10-15)
- [x] Maintainer decides: **repo layout** — proposed `mobile/` (Flutter app, Android +
      iOS runners) and `packages/wayfork_core/` (Dart core shared with `windows/app`) —
      as proposed (recommended option, 2026-10-15)
- [x] Maintainer decides: **Russian for the desktop apps too**, or phone only for now —
      phone only; desktop is a separate future F-entry (recommended option, 2026-10-15)
- [x] Maintainer decides: **where a desktop-only tunnel's sites go** on the phone — "as
      usual" (drawn) or via the default tunnel when there is one — as usual, read as "as if
      the rule were not there": the default tunnel when there is one, otherwise direct
      (recommended option, 2026-10-15)
- [x] Maintainer decides: **sync** — backup files and per-tunnel QR only (drawn), or
      something live — backup files and per-tunnel QR (recommended option, 2026-10-15)

**Done when:** the table is in this file and the maintainer wrote "ок" on it; the status
row says approved with the date.

**Session:** opus, high; with the maintainer in chat. Sequential: everything else
depends on it.

**Decisions (2026-10-15, session MB0+MB1):**
- The five questions were answered with the recommended option; the maintainer delegated
  ("always take the recommended answer") and has not reviewed the table. Status stays
  *awaiting maintainer review*; each answer is also a line in
  [ROADMAP-mobile.pending.md](ROADMAP-mobile.pending.md).
- "As usual" means *as if the rule were not there*: the default tunnel when there is
  one, otherwise direct — the wording of the option the maintainer's delegate picked.
  The session had first read it as "never via a tunnel" (rules emitted as Direct); the
  review on 2026-10-15 restored the picked wording. It matches the prototype, where "the
  rest as usual" and a down tunnel's "sites go as usual" both mean the default route.
  Consequence for the generator (MB2b): a desktop-only tunnel's rules are left out of the
  phone config (kept in the store and the export); a desktop-only default tunnel is
  treated as none. Note: the question's other option ("via the default tunnel when there
  is one") reads the same, so the maintainer should confirm (pending file).
- iPhone after MM9 means MB2a, MB2b and MM0–MM9 are Android-only. The iPhone spike check
  and the iOS sections of `10-mobile.md` move to the iPhone stage; the I boards stay in
  the prototype as the outline, captioned "later, after MM9".
- Rows not in the plan's list were added because MB1 depends on them: Tunnel kinds,
  iPhone, Localisation, Desktop-only tunnels, Sync. Kotlin's share of the code is a
  proposal for MB2b, not a decision.
- Not verified: nothing here was tried on a phone; the engine row rests on MB2a.

### MB1. Features

What changes for the user compared with F1–F23, in the W1 format ("same" / "changed:
…" / "not on the phone: why"), plus the phone-only features.

- [x] One entry per F1–F23 with the phone delta; Android and iPhone separately where
      they differ (F10 app rules, F19 app names)
- [x] Phone-only features, numbered MF1…: Share target (S3), tunnel by QR scan and shown
      as QR (T3, T5), Quick Settings tile and the persistent notification (X1), Always-on
      VPN / Connect On Demand, backup import with desktop-only tunnels (S1, T1), Russian UI
- [x] Each MF entry has its acceptance line, as F-entries do in ROADMAP.md
- [x] "Later (mobile)" list: OpenVPN 3 core, Google Play, live sync, widgets
- [ ] Prototype boards updated where MB1 changed a decision; Artifact copy republished
      (repo file updated 2026-10-15; the Artifact copy is not republished yet)

**Done when:** the maintainer approved MB1; every F-number appears exactly once
(`grep -c '^\*\*F[0-9]' docs/ROADMAP-mobile.md` → 23).

**Session:** opus, high; with the maintainer. After MB0.

Everything not listed behaves as on the desktop. "iPhone" notes describe the iPhone stage
after MM9 (MB0); the first release is Android only. Board names (P1, S3, …) refer to
`docs/design/prototype/mobile.html`.

**F1. Tunnel configs** — changed.
- VLESS and the F13 kinds are added the same way and refused for the same reasons (the
  parsers are the shared Dart core). Inputs are phone-shaped: a link already on the
  clipboard is offered on top of *Add a tunnel* (T2), paste, file picker, QR scan (MF2).
  No drag and drop.
- Not on the phone: OpenVPN. A picked or shared `.ovpn` is refused with "OpenVPN needs
  the desktop app"; OpenVPN tunnels from a backup are kept as *Desktop only* (MF6).
- Secrets go to Android Keystore-backed encrypted storage (iPhone: Keychain in a shared
  access group). Name, edit, remove, enable/disable — same (T5).

**F2. Rules: domain → tunnel** — same patterns, order and first-match rule. Quick add is
the *Add a site* sheet (S2, last-used tunnel preselected) and Share from the browser
(MF1). Rules of a desktop-only tunnel are kept, greyed and not editable; their sites go
as usual (MB0). Swipe deletes a row, long-press moves it to another tunnel (S1).

**F3. Start / stop**
- One switch on Home (P1), the Quick Settings tile and *Turn off* in the notification
  (MF4). The first On asks Android for VPN permission once (boards F3, P3); there is no
  helper and no Login Items step.
- Off stops the VPN service; Android restores networking by itself.
- Rule and tunnel edits while On apply without a restart where libbox can reload the
  config; otherwise the service restarts with a short drop. MB2b decides which.
- Android allows one VPN at a time: another VPN app turning on stops Wayfork, and Home
  says so instead of showing an error.

**F4. Status**
- The Home tab is the popover (P1–P5): the same states, summary sentence, tunnel cards
  with status and rule count. Per-tunnel reconnect and disable live on the tunnel page
  (T5). No menu bar icon: Android's key icon in the status bar, the notification and the
  tile (MF4) show that routing is on.
- New for phones: a network change (Wi-Fi ↔ mobile data) is expected; a reconnect shows a
  short-lived note, not the error state (P4).

**F5. Logs and diagnostics** — changed. More › Logs shows the *Problems* level only, and
*Share diagnostics* sends the same sanitised bundle (app and sing-box logs, config with
secrets stripped) through the Android share sheet. A full log viewer with source and
level filters is "Later (mobile)".

**F6. Settings** — changed.
- Launch at login → Android's Always-on VPN, a system setting we link to (MF5).
- Connect on launch is dropped: the VPN service outlives the app's screens, so opening
  the app never changes the routing state.
- Automatic reconnect with backoff, DNS for direct traffic (system / custom), log level
  and retention — same, in More (M1).

**F7. Import / export** — same file format, both ways between phone, Mac and Windows.
Import from the file picker or *Open with*; export through the share sheet or a saved
file; *Export with secrets* asks for the phone's screen lock first. Desktop-only tunnels
and desktop app rules survive the round trip (MF6). No live sync (MB0); a single tunnel
moves as a QR or a shared link (MF3).

**F8. Default tunnel ("everything else") and exceptions** — same, including blocking
unmatched traffic while the default tunnel is down. A backup whose default is a
desktop-only tunnel imports with that default kept for the export, and on the phone
unmatched traffic goes direct, as without a default (the tunnel does not exist on the
phone, so F8's blocking does not apply); Home says so.

**F9. Traffic rates** — same numbers from the libbox command client instead of the
daemon's sampler: rates on the Home cards and the Direct row, plus the summary and the
rates in the notification (MF4). Totals and open connections, shown on hover on the Mac,
are on the tunnel page (T5).

**F10. Rules: application → tunnel**
- Android: an application is an installed package. Sites › Apps lists every installed
  app with a tunnel chip per row (S4), not a file dialog; the rule covers every process
  of the package. Needs the *query all packages* permission (no review on a GitHub APK).
  Same groups and order as desktop app rules. Wayfork's own traffic is never matched.
- An Android app rule is stored as the package name; a desktop build keeps it as a
  foreign rule (*not found*), as Windows does with macOS paths. Desktop app rules in a
  backup are kept on the phone, read-only, and carried back on export.
- iPhone: no app rules at all (no hook in a Network Extension); the Apps filter is not
  there (I2); app rules from a backup are kept read-only.

**F11. Rules by IP address / subnet** — same. The "covers your LAN" warning checks the
network the phone is on now; private ranges stay out of the VPN as on the desktop
(libbox route exclusion, checked in MB2a).

**F12. System resolver override** — not on the phone: every app's DNS already goes into
the VPN, whose DNS server is Wayfork's resolver. Android's *Private DNS* setting is the
phone's version of the same leak and is checked in MB2a.

**F13. More tunnel types** — same kinds, same refusals, same subscription checklist
(one-shot, URL never stored). Added input paths: clipboard offer, QR scan of a link or of
a subscription URL (MF2), file picker for a WireGuard `.conf`. XHTTP stays out, as on the
desktop.

**F14. Tunnel latency** — same probe and the same number and sparkline on the Home cards
and the tunnel page. The probe interval may be longer on phones if the MB2a battery
measurement asks for it.

**F15. Recent domains → rule** — same list below the Home cards with *Route via*.
Android: the app name comes from the connection owner (package label). iPhone: the site
only.

**F16. Tunnel groups** — same policies and the same card; groups are listed in Tunnels
(T1). Who drives a *first live* selector on the phone (the VPN service, not a daemon) is
MB2b's. A desktop-only member is skipped like a missing one; a group with only
desktop-only members behaves like a down tunnel.

**F17. Local proxy port per tunnel** — not on the phone: a port for other programs on the
same machine has no audience on a phone, and app rules (F10) already pick a tunnel per
app. LAN sharing likewise.

**F18. Block lists** — same switch, count and *Never block* field, in More. iPhone: the
Network Extension memory limit with the lists loaded is checked at the iPhone stage.

**F19. Can't reach — failed connections by site and app** — same rows, reasons and
*Route via* / *Never block* / dismiss on More › Can't reach (M2); a red dot on the More
tab replaces the menu bar badge. No log pane below the rows (F5). Android shows the app
per row; iPhone the site only.

**F20. Connections by exit** — same columns, windows and *Reset*, as a More screen;
tapping an exit lists its F19 rows. Not drawn yet (MB2c).

**F21. wayforkctl for scripts and coding assistants** — not on the phone: there is no
terminal or coding assistant on the device; Share diagnostics covers bug reports.

**F22. First-run guide** — changed: four steps — add a tunnel, pick sites, allow the
VPN, try it (boards F1–F4). No helper step; a backup import jumps to *Allow the VPN* with
everything filled. Same skip, resume and *Getting started* card, with *Share a page to
Wayfork* (MF1) in place of quick add from the popover and *Route an app* on Android only.

**F23. TCP only / UDP only for app and IP rules** — same on Android, in the app row's menu
(S4) and the IP rule's editor. iPhone: IP rules only, as there are no app rules.

#### Phone-only features

**MF1. Share target** (S3). *Share › Wayfork* on any page in a browser opens a sheet with
the registrable domain taken from the URL (as F15 does) and the tunnel list; one tap adds
a suffix rule and closes.
*Accepted when:* sharing a page from Chrome and from Firefox adds a rule for its
registrable domain, and with routing On the reloaded page leaves through that tunnel.

**MF2. Tunnel by QR scan** (T3). The camera reads the QR a VPN panel shows next to its
link; a link QR adds a tunnel, a subscription QR opens the F13 checklist; the name comes
from the link's remark and can be edited. Camera permission is asked at the first scan.
*Accepted when:* a QR of each F13 kind from the maintainer's panel adds the same tunnel
that pasting its link does; a refused link shows the parser's reason; with the camera
denied, paste still works.

**MF3. Tunnel shown as QR and shared** (T5). *Show as QR code* and *Share* hand one
tunnel, secret included, to another device; both ask for the phone's screen lock first,
like *Export with secrets*. Nothing is written to disk or to the log.
*Accepted when:* phone B scans phone A's QR and gets a working tunnel; without passing
the screen lock neither the QR nor the link is shown.

**MF4. Persistent notification and Quick Settings tile** (X1). While routing is On, the
notification Android requires carries the summary sentence, the rates and *Turn off*. The
tile turns routing on and off; a long press opens Home.
*Accepted when:* with the app swiped away, the notification's numbers move and *Turn off*
stops routing, and the tile turns it back on.

**MF5. Always-on VPN** (M1). Android may start Wayfork's VPN at boot without the app;
the service then runs the last saved config. More links to the system setting. iPhone:
Connect On Demand, at the iPhone stage.
*Accepted when:* with Always-on set, after a reboot routing is On before the app is
opened and the routed sites go through their tunnels.

**MF6. Backup import with desktop-only tunnels** (S1, T1). A Mac or Windows backup imports
as is: OpenVPN tunnels are listed under *Desktop only*, greyed, with their rules; those
sites go as usual, as if they had no rule (MB0); desktop app rules are kept read-only. A later export carries all
of it back unchanged.
*Accepted when:* a fixture backup exported from the Mac, imported on the phone and
exported again equals the original (the MM5 check), and a desktop-only tunnel's site
leaves through the default tunnel while one is set, and directly without one.

**MF7. Russian UI.** The app follows the phone's language (English otherwise); Android
13+ per-app language in system settings works, there is no switch inside the app. ICU
plurals, user-typed names never declined, numbers in the Russian format.
*Accepted when:* with the phone in Russian every screen of the prototype's RU table reads
as drawn, plurals are right for 1, 3, 6, 11 and 21 sites, and "1,9 МБ/с" uses the comma.

#### Later (mobile)

- **LM1.** Embedded OpenVPN 3 core for OpenVPN tunnels on the phone — research first.
- **LM2.** Google Play distribution (`QUERY_ALL_PACKAGES` review, VPN policy).
- **LM3.** Live sync between phone and desktop (needs a server or a pairing channel).
- **LM4.** Home-screen widgets.
- **LM5.** Full log viewer with source and level filters (F5).
- Desktop localisation (Russian on the Mac and Windows) is not a mobile item: it is a
  separate future F-entry in ROADMAP.md (MB0).

**Decisions (2026-10-15, session MB0+MB1):**
- Taken by the session where the plan was silent, each also in
  [ROADMAP-mobile.pending.md](ROADMAP-mobile.pending.md) when it changes scope: F5 full log
  viewer moved to Later (it was already drawn as Problems only); F6 *connect on launch*
  dropped; a desktop-only default tunnel means no default on the phone (unmatched
  traffic direct); an Android app rule is a package name that desktops keep as foreign; Russian
  follows the system language with no in-app switch; F20 is in, as a More screen without
  a board yet.
- Kept from the prototype without change: four tabs, Share target, QR in and out, the
  notification and tile, Always-on, four-step first run, S4 apps list.
- MF entries are numbered by the plan's list, with Always-on (MF5) separate from the
  tile and notification (MF4) because the two are tested differently.
- Later items are numbered LM1… so that no line starts with `**F<digit>`.
- Not verified: every Android behaviour above (connection owner, Private DNS, libbox
  reload, route exclusion of private ranges) waits for MB2a; nothing was run.

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
- [ ] Android: editing the profile while On (add a rule) — does SFA/libbox apply it
      without dropping the VPN, and how long is the drop if not (F3 in MB1)
- [ ] Android: SFA's dashboard shows per-outbound traffic and the connection list —
      the libbox command client that F9, F15, F19 and F20 rely on in MB1 (the gomobile
      build of libbox from 1.13.19 itself is MM1's to prove)
- [ ] Android: with *Private DNS* set to automatic and to a named provider, sites still
      match their domain rules (fake-ip answers, or SNI sniffing when the app resolved
      over DoT); private ranges stay outside the VPN (F11, F12 in MB1)
- [ ] Results and go/no-go written to `docs/design/10-mobile.md` § Spike

**Done when:** § Spike exists with each check's outcome and a GO or NO-GO line, and the
maintainer approved it.

**Session:** opus, high, plus the maintainer's phone for every run (the session prepares
configs and reads logs; the maintainer installs and taps). After MB1.

### MB2b. Design

`docs/design/10-mobile.md`, in the shape of `08-windows.md`: only the deltas, the
desktop docs stay the reference. Android only: the iOS parts below are written at the
iPhone stage (MB0, 2026-10-15).

- [ ] Process model: Android `VpnService` in the app process or its own (`:vpn`); who
      owns libbox; what survives the UI being killed
- [ ] Config handoff: Dart generator → JSON → platform channel; reload without dropping
      the TUN where libbox allows it (MB2a measured it)
- [ ] Stats, connections, logs: libbox command client in place of the daemon's sampler
      and socket; which F9/F14/F15/F19/F20 numbers come from where
- [ ] Generator changes: a `mobile` target in the Dart generator (TUN inbound, no
      OpenVPN, `package_name` instead of `process_path_regex`, a desktop-only tunnel's
      rules left out per MB0 so its sites take the default route, a desktop-only default
      tunnel treated as none)
      with golden fixtures `fixtures/singbox/mobile-*`
- [ ] Shared Dart core: the exact file list that moves to `packages/wayfork_core/`, what
      stays in `windows/app`, how the Windows app imports it
- [ ] Secrets, backup import/export, desktop-only tunnels and app rules in a backup
- [ ] Localisation: ARB files, ICU plurals, the string table from the prototype's RU
      switch as the starting contract
- [ ] Share target, QR (camera permission), Quick Settings tile, notification channels,
      Always-on VPN
- [ ] Build: libbox `.aar` from pinned sources, checksums in
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
- [ ] Desktop-only tunnels (rules left out so their sites take the default route,
      default treated as none) and foreign app rules covered by tests
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

#### iPhone (after MM9, MB0 2026-10-15)

Outline only; milestones are written after the Android release.

- [ ] Spike (SFI via TestFlight or App Store outside RU): the MB2a three-site check, plus
      Network Extension memory with our block lists (F18) loaded
- [ ] iOS sections of `10-mobile.md`: Network Extension process model, app-group config
      handoff, Keychain access group, `.xcframework` build
- [ ] Network Extension target hosting libbox, app group for config and secrets
- [ ] Cupertino deltas from the I boards; no app rules, no app names
- [ ] TestFlight distribution under an organisation account

## Session prompts

MB0, MB1, MB2a, MB2b and MB2c are sessions with the maintainer in the loop. The MB0+MB1
prompt below ran on 2026-10-15 with the five answers delegated (recommended options);
MB2a–MB2c get their own prompts when they start. MM0 has an executor prompt now because its scope is fixed by
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
  MB0: after MM9.
- **Android Private DNS.** With DNS-over-TLS on, apps may resolve real addresses and
  skip fake-ip; domain rules then rely on SNI sniffing. Checked in MB2a.
- **MB0 and MB1 decided without the maintainer** (delegated, 2026-10-15): every answer is
  in [ROADMAP-mobile.pending.md](ROADMAP-mobile.pending.md) and awaits review before MB2a.

## Order of work

MB0 → MB1 → MB2a (needs the maintainer's phone) → MB2b → MM0 → MM1 → MM2 → MM3 → MM4 →
MM5 → MM6 → MM7 → MM8 → MM9 → iPhone stage. MB2c runs alongside MB1–MB2b. Everything in
MB3 is one repo, so milestones are strictly sequential. MB0 and MB1 were written
2026-10-15 and wait for the maintainer's review; MB2a comes next, with the maintainer's
phone in hand (its prompt is written then).
