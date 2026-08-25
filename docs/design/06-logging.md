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

## Storage (app side)

`~/Library/Logs/Wayfork/`:

- `wayfork.log` — app's own log.
- `runtime.log` — every `LogLine` received from the daemon, one line each:
  `2026-08-25T12:00:00.123Z sing-box INFO message`.
- Rotation by size (5 MB) keeping files for `logRetentionDays`; cleanup on launch and once a
  day.

The daemon's raw copies under `/Library/Logs/Wayfork/` are for the case where the app is
not running; they are included in diagnostics via `collectDiagnostics`.

## Logs window

- Backed by an in-memory ring of the last 10 000 lines (from `runtime.log` tail on open, then
  live). Older lines are not paged in; "Open Logs Folder" is the escape hatch.
- Filters: source (multi-select), level (threshold), free-text search (case-insensitive,
  substring). Filters compose.
- Follow toggle: on by default, auto-off when the user scrolls up, back on via the button or
  scrolling to the bottom.
- Copy copies the visible (filtered) lines as text; Clear empties the in-memory ring only.
- "Show Log" from a tunnel's menu opens the window with that source pre-selected.

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
