# wayforkctl — command line for scripts and coding assistants (F21)

Status: design 2026-09-25. Stages and checkboxes:
[roadmap/wayforkctl-agent.md](../roadmap/wayforkctl-agent.md).

## Goal

A coding assistant (or a script) running as the logged-in user answers "why does this
site fail" and makes small routing changes without the GUI, with three properties:

1. **Cheap to read.** Logs come back filtered on the machine — by source, level, text and
   time — not as a 5 MB file or 200 unfiltered lines per source.
2. **Cannot lock itself out.** On the maintainer's Mac the assistant's own traffic
   (Cursor, Terminal) goes through Wayfork. A rule change that breaks that connection
   would leave nobody to undo it, so every change made this way is **reverted unless
   confirmed** within a deadline (§ Dead-man confirm).
3. **Never around the app.** The app owns `store.json` and is the only client the daemon
   accepts (`CodeSigningRequirement.client` pins the app's bundle identifier). Changes go
   through the app's own `update` path, the same one the popover uses; the CLI never
   writes `store.json` and never talks to the daemon.

Not a goal: an MCP server (rejected 2026-09-25 — a third interface to maintain in two
languages; assistants with a shell use the CLI directly), adding or editing tunnels
(credentials stay in the GUI), anything that needs admin rights.

## Commands (macOS)

`wayforkctl` stays the executable target of the `WayforkCore` package. `plan` keeps its
developer-mode meaning (05-daemon.md § Developer mode); the new commands:

| Command | Needs the app | Changes state |
|---|---|---|
| `logs [--source S]… [--level L] [--grep T] [--since D] [--tail N] [--json] [--raw]` | no | no |
| `status` | yes | no |
| `failed` | yes | no |
| `rules [--via EXIT]` | yes | no |
| `rules add <pattern> --via EXIT [--confirm-within S] [--dry-run]` | yes | yes |
| `rules remove <pattern\|id> [--confirm-within S] [--dry-run]` | yes | yes |
| `log-level <error\|warning\|info\|debug> [--confirm-within S]` | yes | yes |
| `confirm` / `revert` | yes | yes |
| `reconnect <tunnel>` | yes | no (runtime only) |
| `help` | no | no |

`EXIT` and `<tunnel>` are a tunnel or group name (case-insensitive, exact), its id, or
`direct`. Output: `logs` prints text lines by default (`--json` → one JSON object per
line); every other command prints one pretty JSON object, like the Windows `wayforkctl`.
Exit codes: 0 success, 1 the app answered with an error, 2 usage error, 3 the app is not
running (socket missing or refusing) — so a script can tell "Wayfork is not running" from
"you asked for something wrong".

### logs

Reads the files the app already writes (06-logging.md § Storage) — `runtime.log` (every
daemon line the app received) and `wayfork.log` (the app's own lines), plus their rotated
`<name>-<stamp>.log` siblings when `--since` reaches past the current file — so it works
with the app quit and needs no privileges. The daemon's raw copies under
`/Library/Logs/Wayfork/` are root-only and are not read.

- `--source`: `app`, `daemon`, `sing-box`, `openvpn` (every `openvpn:<id>`) or an exact
  source; repeatable. Default: all.
- `--level`: threshold, `error` < `warning` < `info` < `debug`; default `debug` (all).
- `--grep`: case-insensitive substring of the message; repeatable, all must match.
- `--since`: `90s`, `15m`, `2h`, `1d` or an ISO-8601 timestamp; default: no limit.
- `--tail`: the last N matching lines; default 100, `0` = no cap.
- Lines from both files are merged by timestamp (stable for equal stamps).
- **Redaction** (default on, `--raw` turns it off): every configured server host and
  literal server address (`HostResolver.serverHosts(in:)` over `store.json`, read-only)
  is replaced by a `server-N` placeholder (numbered in store order, whole tokens only);
  a `# N server address(es) redacted` note on stderr says how many. Resolved server IPs
  that the host names map to are *not* known without a lookup and are not replaced — the
  help text says so. Everything else in a line stays as it is (06-logging.md § Export
  Diagnostics: rewriting log lines beyond exact known strings is too error-prone).

The filter is a pure function in `WayforkCore` (`LogQuery`: parse → filter → merge →
tail → redact), unit-tested on fixed lines; the CLI only finds the files.

### Control socket

The app listens on `~/Library/Application Support/Wayfork/control.sock` (the store's
directory, already mode 0700) while it runs: removed and re-created at launch, mode 0600,
removed at quit. An accepted connection whose peer's effective uid (`getpeereid`) is not
the app's is closed without a reply. Being the same user already allows editing
`store.json` directly, so the socket grants nothing new; it only makes the change go
through validation, apply and the dead-man confirm.

Protocol: one request per connection, newline-terminated JSON both ways, shaped like the
Windows pipe's messages (08-windows.md):

```json
{"id":1,"method":"rules.add","params":{"pattern":"example.com","via":"Work","confirmWithin":60,"dryRun":false}}
{"id":1,"result":{…}}
{"id":1,"error":{"code":"pendingChange","message":"…"}}
```

Methods: `status`, `failed`, `rules.list`, `rules.add`, `rules.remove`, `logLevel.set`,
`confirm`, `revert`, `reconnect`. Error codes: `badRequest`, `notFound`, `invalid`
(`RuleEditing` refused the pattern — its message is passed through), `pendingChange`,
`noPendingChange`, `internal`. Request and reply types are `Codable` in `WayforkCore`
(`ControlRequest`, `ControlReply`, …) and shared by the app and the CLI. A request larger
than 64 KB or not finished within 5 s is dropped.

The server (`ControlServer`, `WayforkCore`, BSD socket + `DispatchSource`, no app
dependencies) takes a handler closure; it is tested end to end against a temporary socket
path. The app side is `AppModel+Control.swift`, which calls the existing `quickAdd`,
`removeRule`, `update`, `reconnect` — no second rule path.

### Replies (no secrets)

- `status`: `on` (desired), the runtime state per tunnel (`id`, `name`, `kind`,
  `enabled`, `state`, `lastError`), groups (`id`, `name`, members, the member in use),
  rule count, log level, the last apply's plan hash and error, and `pending` (below).
  No server addresses, no credentials, no config text.
- `failed`: the Can't reach rows (host, app, tries, reason, exit, last seen) and the
  per-exit counters (F19, F20) exactly as the app holds them.
- `rules.list`: `id`, `pattern`, `match`, `via` (exit name, `direct` for exceptions),
  `enabled`, `note`, in route order.
- A change: `{"change": ChangeDescription, "applied": Bool, "applyError": String?,
  "pending": Pending?}` where `applied` is the result of the apply that the change
  triggered (the handler awaits it, 15 s cap); with Wayfork turned off it is `false` and
  `applyError` is `"Wayfork is off; stored only"`.

### Dead-man confirm

- Every state-changing method takes `confirmWithin` seconds: default **60**, range 10–600,
  or `0` to commit without a pending state (scripts that know they are not routed through
  Wayfork; the help text tells assistants not to use it).
- The app keeps **one** pending change: the forward change, its inverse, the deadline and
  a short description. A second change while one is pending fails with `pendingChange`;
  the assistant runs `confirm` or `revert` first.
- `confirm` clears it. `revert`, or the deadline passing, applies the inverse through
  `update` and logs `app WARNING control: reverted "<description>" (not confirmed within
  N s)` (or `(revert requested)`); on the deadline also a user notification *Wayfork
  undid a change made from the command line*.
- Inverses: an added rule → remove that rule id; a rule that `quickAdd` updated (the
  pattern already existed with another target) → restore the old rule value; a removed
  rule → re-insert it at its old position (before the rule that followed it in its group,
  else at the group's end); a log level → the old level. An inverse whose rule is gone or
  already changed by the GUI skips that rule and says so in the log line — the GUI's edit
  wins.
- The pending change is also written to `control-pending.json` next to `store.json` and
  removed on confirm/revert. At launch a leftover file means the app quit before the
  deadline: the inverse is applied before the first apply, with the log line and
  notification. This is what makes "confirm or it goes back" hold across a crash.
- The inverse logic is pure (`ControlChange` in `WayforkCore`: `apply(to: Store)`,
  `inverse`), unit-tested; the app only owns the timer and the file.

The assistant's loop is: change → check that the thing works *and* that it can still
reach its own API (the next tool call succeeding is that check) → `confirm`. If the change
cut it off, it never confirms and the change goes back by itself.

## Commands (Windows)

The Go `wayforkctl` already covers `status`, `diagnostics`, `connections`, `explain` over
the service pipe. F21 adds `logs` with the same flags and output as macOS, built
client-side on `collectDiagnostics` with `tail = 5000` (the service reads the log files,
see `Hub.Tails`): each `<ISO-8601> <LEVEL> <message>` line of each source file is parsed,
filtered, merged and cut exactly as above; the filter is a pure function in
`internal/core`. No redaction on Windows yet (the CLI would need the app's store; recorded
as an open item). This revisits the WM18 decision that dropped a `logs` command: the
diagnostics tail is unfiltered — 200 lines per source — which is exactly the token cost
F21 exists to remove; no new service method is added.

Rule changes on Windows would need a control channel into the Flutter app (the service
never sees rules in source form); that is a separate milestone, not part of F21.

## Discovery

- `wayforkctl help` prints the command table above and a short *For assistants* block:
  read with `logs`, change with the default `--confirm-within`, confirm after checking,
  never `--confirm-within 0`, never quit or restart Wayfork.
- The repository's `CLAUDE.md` has a *Diagnostics* section with the same rules and the
  build command, so an assistant working in the repo learns about the tool at session
  start.
- Release builds ship the binary at `Wayfork.app/Contents/Resources/bin/wayforkctl`
  (universal, signed like the other bundled binaries, identifier `com.wayfork.bin.wayforkctl`);
  README tells users to link it into their `PATH`. Development: `swift build -c release
  --package-path macos/WayforkCore --product wayforkctl` →
  `macos/WayforkCore/.build/release/wayforkctl`.
