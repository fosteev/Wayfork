# Logs and diagnostics

F5. Two halves: the live log stream (daemon → app → window) and the diagnostics bundle.

## Sources and levels

| Source | Producer | Level detection |
|--------|----------|-----------------|
| `app` | `Logger` (os_log, subsystem `com.wayfork.app`) mirrored to file | native |
| `daemon` | daemon's own events | native |
| `sing-box` | process stdout/stderr | `DEBUG`/`INFO`/`WARN`/`ERROR` prefix; unknown → info |
| `openvpn:<name>` | management `>LOG` + process stderr | `I`→info, `W`/`N`→warning, `F`→error, `D`→debug |

Levels: `error`, `warning`, `info`, `debug`. `settings.logLevel` sets the minimum level
that is *stored and shown*; it is also passed down: sing-box `log.level`, openvpn `--verb`
(3 for info, 4 for debug, 1 otherwise).

sing-box's own stdout is ANSI-coloured (the connection id, e.g.
`\e[38;5;147m3216874115\e[0m`); the relay is the one place that strips the escapes —
`SingBoxLog.message(of:)`/`.level(of:)` on macOS, `SingBoxLogMessage`/`SingBoxLogLevel` on
Windows — so every consumer (this window, `runtime.log`, `FailedConnections`,
`BlockCounter`) sees plain text.

## Storage (app side)

`~/Library/Logs/Wayfork/`:

- `wayfork.log` — app's own log.
- `runtime.log` — every `LogLine` received from the daemon, one line each:
  `2026-08-25T12:00:00.123Z sing-box INFO message`.
- Rotation by size (5 MB): the full file is renamed to `<name>-<yyyyMMdd-HHmmss>.log` (UTC)
  and a fresh one started (`AppLogFile` in `WayforkCore`); rotated files older than
  `logRetentionDays` (by modification date) are deleted on launch, once a day and when the
  setting changes.

The daemon's raw copies under `/Library/Logs/Wayfork/` are for the case where the app is
not running; they are included in diagnostics via `collectDiagnostics`.

## Logs window

- Backed by an in-memory ring of the last 10 000 lines (`runtime.log` tail at app launch,
  then live). The daemon replays its ring buffers on `subscribe`; lines already present
  (same timestamp, source and message) are dropped so a reattach does not duplicate them.
  Older lines are not paged in; "Open Logs Folder" is the escape hatch.
- Filters: source (multi-select), level (threshold), free-text search (case-insensitive,
  substring). Filters compose.
- Follow toggle: on by default; MVP: manual toggle only (auto-off on scroll-up deferred, see
  [02-ux.md](02-ux.md)).
- Copy copies the visible (filtered) lines as text; Clear empties the in-memory ring only.
- "Show Log" from a tunnel's menu opens the window with that source pre-selected.
- **Can't reach pane (F19)**: a strip above the lines listing the connections that could
  not be established (05-daemon.md § Failed connections) — header `Can't reach · N sites
  since ‹Turn On time› — click a row to see its log lines · Clear`; columns Site · App ·
  Tried · Why · Via · Last. Clicking a row sets the search to the host, the level to
  *Everything* and shows a line `Showing lines for ‹host› · N tries, all ‹reason› · went
  ‹exit›` with *Show all lines* to go back. Row actions on hover: *Route via ▾* (a suffix
  rule for the registrable domain, as in Recent), *Never block* when the reason is the
  block list, × to dismiss for the session. Hidden while the state is off. At log detail
  *Problems* the App column is empty and the header says `which app needs log detail
  Normal`; with no rows the strip collapses to `Every site your apps tried since ‹time›
  could be reached`. The popover shows `N sites can't be reached · Show` under the summary
  while a row is younger than 5 minutes; *Show* opens this window.
- **Connections view (F20)**: a second view of the same window, chosen by a `Log ·
  Connections` segment in the toolbar; the source/level/search controls hide, *Reset* and
  *Copy* show. One row per exit — every tunnel, every group (with the member it is using),
  *Not via any tunnel*, and a dimmed *Blocked by your list* row outside the totals — with
  columns Connections, Reached, Failed, a fail-rate bar (grey ≤ 1 %, amber ≤ 5 %, red above)
  and the last failure's reason and time; a total row at the bottom. Clicking an exit
  expands the F19 rows that went through it (site, app, tries, why, when) with the same row
  actions as the Can't reach pane. `Since Turn On · Last 5 min` switches the window; the
  daemon only ever sends cumulative counters (05-daemon.md § Failed connections ›
  *Counters by exit*), so the app keeps a 5-minute ring of snapshots and subtracts for that
  view, and *Reset* stores a baseline — both live in the app, nothing new on the wire beyond
  `TrafficSnapshot.exits`. Row order is fixed: tunnels in the popover's order, groups after
  their members, *Not via any tunnel*, then *Blocked by your list* — no column sorting this
  round. Opened from the popover footer (*Connections ⇧⌘L*), from *Details* on a tunnel
  card whose exit has failed in the last 5 minutes, and from the segment; opening from the
  popover preselects this view the way `takePreselectedSearch()` preselects the search.

## Export Diagnostics

Button in General → Export; also offered in the `singbox.startFailed` error alert.
Produces `wayfork-diagnostics-<yyyyMMdd-HHmmss>.zip` via a save panel:

```
system.txt          macOS version, app version, sing-box/openvpn versions, helper status,
                    network interfaces (name, flags, addresses), `route -n get default`,
                    `scutil --dns` summary
store.json          sanitized (see below)
sing-box.json       sanitized generated config
rules-*.json        as generated
runtime.log         last 5 MB
wayfork.log         last 5 MB
daemon/             daemon.log, sing-box.log, openvpn-*.log tails from collectDiagnostics()
```

Sanitizer (`DiagnosticsSanitizer`, single function reused by both files):

- Remove: UUIDs, passwords, key passphrases, inline certificate/key blocks, REALITY
  public keys and short ids, credentials fields → replaced with `"<redacted>"`.
- Server hostnames/IPs are replaced by stable placeholders (`server-1`, `server-2`) unless
  the checkbox **Include server addresses** in the export sheet is on.
- Log lines are *not* rewritten (too error-prone); the export sheet says so.

Nothing is uploaded anywhere; the user attaches the zip to an issue by hand.
