# Mobile roadmap — pending

Decisions taken without the maintainer and checks only the maintainer can do. Each line:
`- [class] stage: what — why — how to undo`.

## Decisions to confirm

- [scope] MB0: Android now, iPhone after MM9 — maintainer picked the recommended option
  2026-10-15 — reopen in MB0 table.
- [scope] MB0: Russian UI on the phone now; desktop localisation is a separate F-entry in
  ROADMAP.md — maintainer picked 2026-10-15 — reopen in MB0 table.
- [scope] MB0: a desktop-only (OpenVPN) tunnel's sites go "as usual" on the phone —
  maintainer picked 2026-10-15 — reopen in MB0 table.
- [scope] MB0: sync = backup file + per-tunnel QR only — maintainer delegated ("always take
  the recommended answer", 2026-10-15) — reopen in MB0 table.
- [architecture] MB0: repo layout `mobile/` + `packages/wayfork_core/` — default taken by the
  orchestrator 2026-10-15 — reopen in MB0 table before MM0.
- [scope] MB1 (review 2026-10-15): "as usual" for a desktop-only tunnel's sites = as if
  the rule were not there: the default tunnel when there is one, otherwise direct; the
  generator leaves those rules out of the phone config (kept in the store and export) —
  the wording of the picked option; the session's "never via a tunnel" reading was
  reverted at review. The roadmap's own alternative ("via the default tunnel when there
  is one") reads the same, so confirm this is what was meant — to make them always
  direct instead: MB0 row, F2, F8, MF6 and MB2b/MM3 generator items back to "emitted as
  Direct".
- [scope] MB1: a backup whose default tunnel is desktop-only is treated as "no default" on
  the phone (unmatched traffic direct), the default kept for export — F8's "block while the
  default is down" would otherwise block the whole phone — edit F8 in MB1.
- [scope] MB1: F5 on the phone = Problems level + Share diagnostics; full log viewer moved
  to Later (LM5) — drawn that way in the prototype, a phone screen is too small for the
  filtered viewer — move LM5 back into F5.
- [scope] MB1: F6 "connect on launch" dropped; "launch at login" replaced by Android
  Always-on VPN (MF5) — the VPN service outlives the app's screens — restore the setting
  in F6.
- [scope] MB1: an Android app rule is stored as the package name; desktop builds keep it as
  a foreign (*not found*) rule like Windows does with macOS paths; desktop app rules are
  kept read-only on the phone — no data loss across platforms — revisit in MB2b data model.
- [scope] MB1: Russian follows the phone's language (Android 13+ per-app language), no
  in-app language switch — fewer settings, platform does it — add a switch to MF7.
- [scope] MB1: F20 Connections by exit is in the phone scope as a More screen (no board
  yet) — parity, data is the same as F19 — mark it "not on the phone" or Later in MB1.
- [architecture] MB0: iPhone after MM9 makes MB2a/MB2b/MM0–MM9 Android-only; the iPhone
  spike check and iOS sections of 10-mobile.md moved to the iPhone stage — follows from the
  iPhone answer — move them back if iPhone returns to the first release.
- [architecture] MB1 (review 2026-10-15): a desktop-only member of a group is skipped like
  a missing one; a group of only desktop-only members acts as a down tunnel (F16) —
  follows from the "as usual" answer and F16's missing-member rule — drop the sentence
  in F16 of ROADMAP-mobile.md.

## Check by hand

- MB0+MB1: the desktop-only tunnel answer — sites of an OpenVPN tunnel from a backup go
  through the default tunnel when one is set on the phone (not straight out). If you
  wanted them always direct, say so.
- MB0+MB1: the prototype copy at https://claude.ai/artifact/49kVJnNXp8XHLHkpmHhqnK is not
  republished; the repo file `docs/design/prototype/mobile.html` has the 2026-10-15 notes.
- MB0+MB1: read the MB0 table and the MB1 entries in ROADMAP-mobile.md; "ok" turns both
  phase rows into "approved <date>", or overturn any line above.
- MB2a: needs your Android phone with SFA installed; the session prepares configs and
  reads logs, you install and tap.
