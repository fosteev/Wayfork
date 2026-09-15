# Next features — F14–F18

> Status: approved · created 2026-09-15 · F14–F18 approved 2026-09-15 (ROADMAP § F14–F18);
> prototype variant C approved 2026-09-15 (stage 2 done) · stage 3 design notes approved
> 2026-09-15 · stage 4 in progress from M10 · milestones M10–M14 / WM11–WM15 in the roadmaps

## Goal

The second wave after F13: features that change *how* Wayfork is used rather than *what*
it can connect to. The thread through all of them: today a user has to know the domain
before writing a rule and has to guess which tunnel is healthy. After this wave the app
tells them — recent traffic becomes rules in one click, a rule can point at a group that
picks the fastest live tunnel on its own, latency is on every card, and the simple cases
(block ads, use a tunnel from `curl`) need no rules at all.

Alongside the features, a **friendlier UI pass**: variant B was drawn for the maintainer,
and it shows (jargon on the cards, everything visible at once, no empty states worth the
name). Stage 2 redraws the screens the new features touch with a first-time user in mind,
before any design text is written.

## Context and constraints

- Phase gates stand ([ROADMAP.md](../ROADMAP.md)): Features → Design → Implementation, on
  both platforms. This file holds the feature text and the per-step progress; the design
  goes to `docs/design/*.md`, the prototype to `docs/design/prototype/`.
- Everything here is **sing-box configuration plus UI**: `urltest` outbound groups, a
  `mixed` inbound per tunnel, `block` outbound with a rule-set, the Clash API the daemon
  already polls for F9 (`/connections`, `/proxies/<tag>/delay`). No new binaries, no new
  privileges, no change to the daemon's trust boundary
  ([00-architecture.md](../design/00-architecture.md) § 7 keeps the Clash secret in the
  daemon; per-connection hosts cross to the app only as F15 asks below).
- The Windows client mirrors every feature ([ROADMAP-windows.md](../ROADMAP-windows.md));
  the Go service stays a config carrier where it can (`core/validate.go` has no outbound
  whitelist, so groups and inbounds pass through).
- Secrets rule as always: recent-domain lists and probe results are runtime state, never
  written to disk or to the log at `info`.

## Features

**F14. Tunnel latency** — approved, text in [ROADMAP.md](../ROADMAP.md) § F14. Listed
here because F16 builds on its measurement and the prototype draws its sparkline.

F15–F18 below were approved 2026-09-15 and copied to [ROADMAP.md](../ROADMAP.md) § F15–F18;
this file keeps the original text, the stages and the working order.

**F15. Recent domains → rule** *(proposed 2026-09-15; approved 2026-09-15)*
- While the global state is on, the app shows the domains seen in the last few minutes
  that went to the *default* route (direct or the default tunnel), newest first, with the
  app that opened them where known. Each row has one action: *Route via ‹tunnel›*, which
  creates a suffix rule for the registrable domain and moves on.
- Domains already covered by a rule are not listed (they are routed as intended); a row can
  be hidden, and a hidden domain stays hidden for the session.
- Data comes from the F9 sampler: the daemon already reads `/connections`; it forwards a
  bounded list of `(host, process, tunnel, lastSeen)` in the traffic snapshot instead of
  aggregates only. The list lives in memory, is capped (200 rows), and is cleared when the
  state leaves *on*.
- Not a live connection view (L2 keeps that): no bytes, no per-connection rows, no
  history — a to-do list of "this went where you may not want it".

**F16. Tunnel groups** *(proposed 2026-09-15; approved 2026-09-15)*
- A group is a named, ordered list of tunnels with a policy: *fastest* (lowest F14 latency,
  re-evaluated on every probe) or *first live* (the first member whose probe passes).
  A rule, an exception or the default tunnel can point at a group wherever it can point at
  a tunnel.
- Rendered as a card among the tunnels with its members inside; the active member is
  marked. Latency on the group card is the active member's; rates are the group's own
  traffic (design decision 2026-09-15, 03-routing.md § Tunnel groups).
- Maps to a sing-box `urltest` outbound (`fastest`) or `selector` driven by the daemon
  (`first live`); the probe URL and interval are F14's. This is L4 "failover" delivered
  without a fallback field on every rule.
- Groups cannot contain groups; a member that is disabled or missing is skipped, and a
  group with no live member behaves like a down tunnel (rules fall to the default route,
  the card says so).

**F17. Local proxy port per tunnel** *(proposed 2026-09-15; approved 2026-09-15)*
- A tunnel (or group) can expose a local SOCKS5/HTTP port on `127.0.0.1`, shown on its card
  with a copy button: `curl --proxy socks5h://127.0.0.1:<port>`, a browser profile, a
  Telegram proxy — an explicit way to pick a tunnel without writing a rule.
- Off by default; the port is chosen by the app (stable per tunnel, stored in the model) and
  can be edited. Traffic entering the port bypasses the rules and goes to that tunnel; its
  DNS goes through the tunnel's resolver like a routed flow.
- One `mixed` inbound per enabled port and one route rule `inbound → outbound`; the
  generator emits them, the goldens cover them.
- *LAN sharing* (bind to `0.0.0.0` so a phone or a TV uses the Mac's tunnels) is a separate
  toggle behind a plain warning: the port has no password. Off by default, not in the first
  cut unless approved with the rest.

**F18. Block lists** *(proposed 2026-09-15; approved 2026-09-15)*
- Settings › General gains a *Block ads and trackers* switch backed by a bundled or
  fetched domain list (the same rule-set mechanism L1 needs for GeoSite lists). Blocked
  domains get `block` in sing-box and NXDOMAIN from the fake-ip resolver, so the browser
  fails fast instead of spinning.
- Counts blocked flows in the F9 snapshot so the switch can show "blocked N today".
- An exception field ("never block") reuses the domain-rule editor.
- Deliberately a switch, not a rule group: the audience for this feature does not want to
  see 40 000 rows.

**Candidates, not scoped** (one line each; promoted only on request):
- Notifications when a tunnel becomes unreachable / reachable again (after F14).
- Network-aware profiles: on/off or a profile per Wi-Fi SSID (needs L5).
- Multi-hop: a tunnel's traffic `detour`ed through another tunnel; UI must refuse cycles.
- Shortcuts actions (AppIntents): toggle, switch profile, route the frontmost app.
- Import a whole Clash / sing-box profile as tunnels (extends F13 stage 7).

## Stages

### 1. Feature entry and approval

- [x] F14 written into ROADMAP.md, L4 narrowed, M9 / WM10 skeletons (2026-09-15).
- [x] Maintainer approves F15–F18 (each, in as many words) or strikes some. On approval
      the texts above are copied into ROADMAP.md after F14, with M10+ / WM11+ skeletons
      pointing here, and *Later* loses the lines they replace (L2 live view stays, L4 loses
      failover). — 2026-09-15: all four approved with the prototype; ROADMAP.md § F15–F18,
      M10–M14, ROADMAP-windows.md WM11–WM15; L4 failover struck.
- [x] Maintainer confirms the UI pass scope: which screens the friendlier redraw may touch
      beyond the ones the new features need (the brief below assumes: popover, Tunnels,
      Rules, General, Add sheets; Logs untouched). — 2026-09-15: as drawn — popover,
      Tunnels, Rules, General, New group sheet; Add sheets and Logs untouched.

**Done when:** the approvals are in this file.

### 2. Prototype — friendlier screens *(brief below)*

- [x] Friction audit of variant B written as a list (what a first-time user does not
      understand, what needs two clicks that should need one). — 25 items, the comment at
      the top of variant-c.html.
- [x] `docs/design/prototype/variant-c.html`: the boards listed in the brief, light and
      dark, macOS 14 look, static HTML/CSS only like variant B. — C1–C7, 2026-09-15.
- [x] Review pass with the maintainer on rendered boards; iterate in the same file. —
      C1/C4 and W9/W12 reviewed 2026-09-15, approved as drawn.
- [x] `docs/design/prototype/windows.html` gains the Windows boards for the approved
      macOS ones (after the macOS boards are approved, not in parallel). — W9–W15,
      2026-09-15 (drawn alongside the macOS boards at the maintainer's request).

**Done when:** the maintainer approves variant C the way variant B was approved; the
approval line goes into ROADMAP.md § UI prototype.

### 3. Design notes

- [x] [02-ux.md](../design/02-ux.md): the approved screens, states, empty states and error
      strings per feature; the friction audit's fixes for existing screens. — § Variant C,
      with the M10 wording table (2026-09-15).
- [x] [01-data-model.md](../design/01-data-model.md): `TunnelGroup`, proxy port fields,
      block-list switch and exceptions in `store.json`; rule targets widen to tunnel-or-group.
      — schema stays 1, `RuleTarget.group`, `defaultTunnelID` may name a group (2026-09-15).
- [x] [03-routing.md](../design/03-routing.md): `urltest` / `selector` outbounds, `mixed`
      inbounds and their route rules, `block` rule-set; new golden variants named. — plus
      the F14 probe constants; 11 golden variants named (2026-09-15).
- [x] [05-daemon.md](../design/05-daemon.md): F14 probes, the recent-hosts list in the
      snapshot, the `first live` selector switch, the list-fetch job for F18. — the fetch
      job is deferred to L1 (bundled list only); 00-architecture § 7 amended; Probe added
      to 07-rule-testing.md (2026-09-15).
- [x] [08-windows.md](../design/08-windows.md): deltas only. — § The F14–F18 wave
      (2026-09-15).

### 4. Implementation, macOS (one feature per commit series)

Order: **M10 → F14 → F15 → F16 → F17 → F18**, see *Working order*. Milestones in
ROADMAP.md: M10 (friendlier screens, existing features only), M9 (F14), M11–M14 (F15–F18).

- [ ] M10: the friction-audit fixes on the existing screens, before any new feature. —
      code done 2026-09-15 (ROADMAP.md § M10); the maintainer's walk against the boards
      is owed, README screenshots move to stage 6.
- [ ] F14 (M9 in ROADMAP.md). — daemon + card done 2026-09-15; the manual check and
      the Windows half (WM10) are owed; Probe waits for the L2 tester.
- [ ] F15: snapshot field + cap in `WayforkCore`, the panel, *Route via* creating the rule.
- [ ] F16: model + generator + goldens, the group card, group in every tunnel picker,
      `first live` in the daemon.
- [ ] F17: model + generator + goldens, port on the card, copy button; LAN toggle only if
      approved.
- [ ] F18: list source and fetch, generator, the switch, counter, exceptions.
- [ ] Manual check per feature, listed in the design notes.

### 5. Windows mirror

- [ ] Same order, feature by feature, on the fixtures stage 4 produces; PC run per feature
      (`ssh wf-pc`). Milestones WM11–WM15 in ROADMAP-windows.md.

### 6. Ship

- [ ] CHANGELOG, README screenshots re-rendered from variant C, release per
      `scripts/release.sh`, roadmap banners flipped.

## Prototype brief *(the prompt for the stage-2 session; paste as is)*

> You are working in `/Users/fost/Projects/Wayfork`, a macOS menu bar app for per-domain
> split tunneling across several VPNs at once (read `CLAUDE.md`, then
> `docs/roadmap/next-features.md` — this file — and `docs/design/02-ux.md`). Your task is
> **stage 2 of that roadmap: a friendlier UI prototype**, `docs/design/prototype/variant-c.html`.
> Do not touch Swift, Dart or Go code, do not write design notes, do not commit; the
> maintainer reviews boards and approves before anything else happens.
>
> **Start from the approved baseline**, `docs/design/prototype/variant-b.html` (five
> boards: popover on; popover degraded/off; Settings › Tunnels; Settings › Rules; Settings
> › General) and its Windows twin `windows.html`. Keep its conventions: one static HTML
> file, CSS only, no scripts, no external assets, each screen a `<section id="C1">…`
> board with an `<h2>` caption, 2× screenshots taken from the board rect. Keep the
> architecture it depicts: popover dashboard under the menu bar, sidebar Settings with
> inline tunnel expansion, rules grouped by tunnel. Variant C is a redraw, not a new
> concept.
>
> **First, write a friction audit** (a markdown list at the top of the HTML file inside a
> comment, and in your reply): walk variant B as someone who installed the app five
> minutes ago and knows only "I want site X to go through VPN Y". Name every label that is
> our jargon and not theirs, every action that takes two clicks where one would do, every
> screen with no empty state, every number without a unit or a meaning. Fix those in the
> boards; do not add features the roadmap does not list.
>
> **Boards to draw** (light and dark for C1 and C3, light for the rest):
> - **C1 Popover, on** — per-tunnel card with rates *and* latency (F14: number + unit,
>   colour by band, a 2-minute sparkline that reads at 24 px tall), an *unreachable*
>   card, a group card (F16) with its active member marked, and the **Recent** section
>   (F15): up to five rows of domain + app icon + *Route via ▾*; an empty state that
>   says what will appear here and when.
> - **C2 Popover states** — off (what the one button does, in one sentence), degraded,
>   and "no tunnels yet" (first run: one primary action, *Add a tunnel*).
> - **C3 Settings › Tunnels** — cards for a tunnel and a group; the tunnel card expanded
>   shows the F17 proxy port (off → *Enable local proxy*; on → `127.0.0.1:1081` with a
>   copy button and a one-line hint what it is for), the group card expanded shows
>   members, policy (*Fastest* / *First live*), and the *New group…* entry point.
> - **C4 Settings › Rules** — grouped by tunnel as today, plus the **Recent** panel as a
>   side column or a top strip (pick one, say why in the caption), and a rule row whose
>   target is a group. Include the empty state for a tunnel with no rules.
> - **C5 Rule test with Probe** — the L2 "where does ‹domain› go?" field with the F14
>   *Probe* button and its three results (ok + ms, blocked, failed + reason).
> - **C6 Settings › General** — the F18 *Block ads and trackers* switch with "blocked N
>   today" and the *never block* exceptions; keep the existing General rows.
> - **C7 New group sheet** — name, pick members (drag to order), policy, one-sentence
>   explanation of each policy.
>
> **Design constraints.** macOS 14 look: system font stack, 13 px body, sidebar and
> cards with SF-style symbols drawn as inline SVG or Unicode, popover 360 px wide,
> Settings 720 × 480. Every state a real app shows must be drawable from the board:
> disabled, loading, empty, error. Colour only for meaning (latency bands, unreachable),
> never for decoration; dark boards are not inverted light boards — check contrast.
> Strings are English, short, and in the user's words: "Route via", "Fastest", "Not
> reachable", never "outbound", "urltest", "rule-set", "fake-ip".
>
> **Render and hand over.** Screenshots via the headless Chrome recipe in the memory note
> `wayfork-readme-screenshots.md` (puppeteer's cached Chrome, CDP from plain node,
> `deviceScaleFactor: 2`, clip to the board rect); write PNGs to the session scratchpad,
> not to the repo. Send the maintainer C1 and C4 first, then the rest on request. Reply
> with the friction audit, the list of boards, the one open design choice per board you
> want a decision on (at most one), and stop. Iterate in the same file on feedback.

## Risks and open questions

- **F15 privacy** — amended 2026-09-15: [00-architecture.md](../design/00-architecture.md)
  § 7 now names the bounded host list as the one thing that crosses besides aggregates;
  05-daemon.md § Recent hosts states the limits (memory only, default-route flows, ≤ 200).
- **F16 `first live` vs `urltest`** — decided 2026-09-15: keep both; `tolerance` only
  damps switching, it cannot express "prefer this one unless it is down", so *first live*
  is a daemon-driven `selector` (ten lines next to the prober). 03-routing.md § Tunnel
  groups.
- **F17 DNS** — analysed 2026-09-15: a `socks5h` / CONNECT client hands the name to the
  inbound and the exit resolves it inside the tunnel; only a `socks5://` client's own
  lookup goes the way of every unmatched query. The hint shows `socks5h://`. Generator
  check still owed when M13 starts. 03-routing.md § Local proxy ports.
- **F18 list source** — decided 2026-09-15: bundled only (OISD small, pinned URL + SHA in
  `scripts/versions.env`, compiled to `.srs` at build); the refresh job comes with L1, so
  board C6's *Update now* waits. Counting reads sing-box's log at `info`. 03-routing.md
  § Block list.
- **Prototype scope creep**: the friendlier pass will suggest redrawing screens the features
  do not touch (Logs, Add sheets). Out unless the maintainer widens the scope in stage 1.

## Working order

Strictly 1 → 2 → 3 → 4 → 5 → 6. Inside 4: **M10 → F14 → F15 → F16 → F17 → F18**.

- M10 first — the redraw of the existing screens (strings, states, empty states) lands
  without new code paths, so every later feature is drawn onto screens that already match
  variant C, and the first user-facing change of the wave is the cheapest to verify.

- F14 first — the group card (F16) shows its number, and the probe machinery is the
  liveness signal groups switch on.
- F15 second — the highest value per line of code (one snapshot field and one panel), and
  the feature the redraw is centred on; landing it early validates variant C against the
  real popover.
- F16 third — the only feature that changes the *model* (rule targets become
  tunnel-or-group); better before F17/F18 add fields around it.
- F17 and F18 last — generator additions with crisp golden-file definitions of done, good
  candidates for delegation once the design is written; the review stays here.
