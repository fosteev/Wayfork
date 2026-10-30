# VLESS over XHTTP through a bundled Xray-core

> Status: approved 2026-10-30 (F13 stage 8 promoted to its own roadmap) · macOS stages 0–5
> implemented and reviewed 2026-10-30, 232 tests green · the maintainer's live check (stage 5)
> is owed · Windows twin (stage W) after it

## Goal

A `vless://…?type=xhttp` link imports and routes like any other tunnel. sing-box has no
XHTTP transport (1.13.19 rejects `xhttp`/`splithttp`, upstream declined it), so each XHTTP
tunnel runs its own bundled `xray` process. The process listens on a loopback SOCKS5
port, and sing-box reaches it through a `socks` outbound tagged `t-<id>`. This is the
OpenVPN per-process model with a port instead of a `utun`. Design:
[design/04-tunnels.md → VLESS over XHTTP](../design/04-tunnels.md#vless-over-xhttp-xray).

## Context and constraints

- **Live server.** The maintainer's 3x-ui panel runs Xray-core v26.2.6 and can serve an
  XHTTP inbound. Credentials are passed only in chat and never written to the repo.
- **Pinned client.** Xray-core **v26.10.29**. The assets are
  `Xray-macos-arm64-v8a.zip` and `Xray-macos-64.zip`, each with a `.dgst` sidecar.
  Windows uses `Xray-windows-64.zip` and `Xray-windows-arm64-v8a.zip`. The zip holds `xray`.
  geoip/geosite files are not bundled because the generated config has no routing.
- **Shared fixtures.** The Dart golden test enumerates every directory under
  `fixtures/singbox/`, and so does Go `clash_test.go`. A new variant there would break
  both suites until the Windows twin lands. XHTTP goldens therefore live under a new root,
  `fixtures/xray/`, which Windows does not read yet. XHTTP links go in
  `fixtures/vless/xhttp-links.json`, not in `links.json`.
- **Bundle size.** Each arch slice of xray is about 32 MB, so the universal binary is
  about 64 MB (measured). This is accepted.
- **Mobile.** Out of scope. `ROADMAP-mobile.md` already says so.

## Decisions (do not reopen)

| # | Decision |
|---|----------|
| D1 | Model: new case `ProxyTransport.xhttp(path: String, host: String?, mode: String?, extra: String?)`. It is accepted for **VLESS only**. Trojan and VMess parsers keep rejecting `xhttp`. The stored JSON uses the case name, as the other transports do. |
| D2 | Parser: `type=xhttp` reads `path` (default `/`), `host`, `mode` and `extra`. `mode` must be one of `auto`, `packet-up`, `stream-up` or `stream-one`; an absent value stays `nil`, which means auto. Anything else → `invalid("mode must be auto, packet-up, stream-up, or stream-one")`. `extra` must percent-decode to a JSON **object** and is stored verbatim as a string; anything else → `invalid("extra must be a JSON object")`. `splithttp` stays unsupported. `flow` with xhttp → the existing `flow requires TLS/REALITY over TCP`. `allowInsecure=1` with xhttp → `unsupported("allowInsecure is not supported with XHTTP.")`, because Xray deprecates it. The writer emits `type=xhttp&path=…&host=…&mode=…&extra=…` in that order and skips nil fields. |
| D3 | Port: `127.0.0.1:(Tunnel.firstXrayPort + slot)` with `firstXrayPort = 47100`, so the range is 47100–47131 (`maxSlots` = 32). The port is deterministic from the slot, like `utun101+slot`; nothing flows back from the daemon. The SOCKS inbound has no auth because it is loopback-only, the same as F17's local proxy. |
| D4 | Plan: `RuntimePlan.xray: [XrayRuntime]`. `XrayRuntime` has `id`, `port`, `config` (the full xray JSON as a string, UUID included) and `configHash` (sha256 of `config`). Decoding is backward-compatible: a missing key means `[]`. The plan hash includes it, as it does for OpenVPN. |
| D5 | xray config (pure generator `XrayConfigGenerator` in WayforkCore): `log.loglevel: "warning"` to stdout. One inbound: `socks` on `127.0.0.1:<port>` with `udp: true` and `ip: "127.0.0.1"`. One outbound: `vless` with `vnext[{address, port, users[{id, encryption: "none"}]}]`. `streamSettings` uses the xhttp transport with `xhttpSettings {path, host?, mode (default "auto"), extra? (parsed object)}`. `security` is `none`, `tls` (`tlsSettings {serverName, alpn?, fingerprint?}`) or `reality` (`realitySettings {serverName, fingerprint (default "chrome"), password: <pbk>, shortId}`). No `mux` (XHTTP accepts only XUDP), no routing, no DNS. Whether the stream key is `network` or `method` is settled by `xray run -test` against the pinned binary, not by docs. |
| D6 | sing-box side: the tunnel is a `socks` outbound `t-<id>` with `server: 127.0.0.1`, `server_port: <port>`, `version: "5"`. The `process_path` direct rule gets the xray path next to openvpn. The XHTTP servers join the "servers always go direct" rule (`openVPNServers` / `serverRouteRule`) and the set of hosts the app pre-resolves (`resolvedServerAddresses`). This is how the process loop is closed, the same way as for openvpn. DNS goes the same way as for native VLESS: the DoT detour through `t-<id>` works over SOCKS. |
| D7 | Secrets: the config, with the UUID in it, is written by the daemon to the run directory as `t-<id>.xray.json`, mode 0600, root-owned. This is the `.ovpn` precedent. The file is removed when the session stops. Nothing is written by the app. |
| D8 | Daemon: `XraySession` actor, a simplified twin of `OpenVPNSession`. It spawns through `ManagedProcess`, restarts with the same backoff on exit, and stops on removal. It has no management socket and no routes. Logs go to `ClientHub` with source `xray:<id>`, and `wayforkctl logs --source xray` matches it. The binary is validated as `com.wayfork.bin.xray`, and its version is reported next to openvpn's. |
| D9 | UDP: sing-box sends UDP to SOCKS through UDP ASSOCIATE, and xray carries it as XUDP. No static "TCP-only" flag. If the live check (stage 5) shows dead UDP, H3's generic hint covers it, and a follow-up decides. |
| D10 | Goldens: `fixtures/xray/<variant>/{input.json, xray-<id>.json, sing-box.json}`, with variants `xhttp-reality` and `xhttp-tls-extra`. They are Swift-only until stage W. `fixtures/README.md` gets one line about this. |

## Stages

Sequential, one repo. Each stage ends with `/plan-review`, and commits happen only on the
maintainer's command.

### 0. Design and approval *(opus, done in planning)*
- [x] This roadmap with D1–D10
- [x] `docs/design/04-tunnels.md`: shape table row plus the "VLESS over XHTTP (Xray)" section
- [x] `docs/ROADMAP.md` F13 bullet and `more-tunnel-types.md` stage 8 point here

### 1. Bundle xray *(sonnet, medium)*
- [x] `scripts/versions.env`: `XRAY_VERSION=26.10.29` plus `XRAY_SHA256_ARM64` and `XRAY_SHA256_X86_64`. These are the zip hashes, taken from the `.dgst` files and checked against a local `shasum -a 256`.
- [x] `scripts/fetch-bins.sh`: `fetch_xray` modelled on `fetch_sing_box` (`:131`): download plus sha256, unzip, `lipo_or_copy` → `macos/Resources/bin/xray`, added to the result check.
- [x] `xray` added to the hard-coded binary lists in `embed-bins.sh` (`:28,34,40`), `dev-sign.sh:76` and `release.sh` (`:73,177,189`).
- [x] `DaemonEnvironment.xrayPath`. `Supervisor` validates it (`:240`) and reports `xray version` next to openvpn (`:33,142,149`, plus the status/XPC field that openvpn's version already flows through). `RuntimePlanBuilder.xrayBinaryPath(bundlePath:)` sits beside `openVPNBinaryPath` (`:93`).
- Done when `scripts/fetch-bins.sh` leaves a universal `macos/Resources/bin/xray` (`lipo -info` shows both archs and `xray version` prints 26.10.29), `scripts/dev-sign.sh` signs it, and the app plus package build.

- Review 2026-10-30: accepted. Added in review: `licenses/xray-core.txt` (MPL-2.0, verbatim
  at the tag) and an Xray-core section in `THIRD_PARTY_NOTICES.md`; the plan had missed the
  notice. As for openvpn, `performApply` now refuses every plan when `xray` is missing or
  unsigned. This is accepted because `embed-bins.sh` already embeds all binaries or none.
  `scripts/format.sh --lint` has 5 `LineLength` errors that date from 0.10.2 and are not
  from this work.

### 2. Model and parser *(sonnet, high)*
- [x] `ProxyTransport.xhttp` (D1), with every exhaustive switch it breaks fixed: the URI writer, `AddLinkSheet.transport(_:)`, `StatusText`, and the `linkURI` / `maskedLinkURI` paths. Trojan and VMess parsers keep rejecting.
- [x] `VLESSURIParser` per D2. `rejectsUnsupportedTransports` drops `xhttp` but keeps `splithttp`.
- [x] `fixtures/vless/xhttp-links.json` (accepted and rejected, the `links.json` shape), read by a new Swift test.
- Done when `swift test --package-path macos/WayforkCore` is green, a round-trip parse→write→parse holds for every accepted link, and `scripts/format.sh --lint` is clean.
- Review 2026-10-30: accepted, 209 tests green. Deviations accepted:
  - `transportBlock` got `case .xhttp: return nil` so that it compiles. Until stage 3, an
    XHTTP tunnel would come out as a plain-TCP VLESS outbound, which is wrong, so stage 3
    must branch before `vlessOutbound`.
  - The Trojan and VMess writers got unreachable fallbacks (`break` and tcp) rather than
    a crash.
  - An empty `mode=` or `extra=` is rejected, as D2 reads literally. 3x-ui always emits
    `mode`, so this was left as is.

### 3. Plan and generators *(sonnet, high)*
- [x] `Tunnel.firstXrayPort` plus `xrayPort` (D3). `XrayRuntime` plus `RuntimePlan.xray` (D4). `PlanValidator` checks the count, the port range and the config size.
- [x] `XrayConfigGenerator` (D5). `RuntimePlanBuilder` builds an `XrayRuntime` for each enabled VLESS+xhttp tunnel and disables a tunnel whose UUID is missing, as OpenVPN does.
- [x] `SingBoxConfigGenerator` per D6. The `Input` gains `xrayBinaryPath`.
- [x] Goldens per D10, plus a test that runs `macos/Resources/bin/xray run -test -c <golden>` when the binary exists and skips with a message when it does not.
- Done when the tests are green, the existing `fixtures/singbox/*` goldens are byte-identical (`git diff --stat fixtures/singbox` is empty), and `xray run -test` accepts both xray goldens.
- Review 2026-10-30: accepted, 226 tests green, and `xray run -test` really ran on both
  goldens.
  - Fixed in review: `log.access: "none"`. Without it xray writes an access line per
    connection to stdout, which is noise and leaks every domain into the daemon log.
  - Deviations accepted:
    - `Input.xrayBinaryPath` is optional and is emitted only when an XHTTP tunnel is
      routed, so the old goldens stay byte-identical.
    - `openVPNServers` was renamed to `directServers`.
    - XHTTP servers also join the `dns-direct` rule, so xray resolves the real address and
      never a fake-ip. This is better than D6 asked for.
    - The xray goldens go through `RuntimePlanBuilder`.
  - Found: xray ignores unknown keys, so `-test` does not catch a wrong key *name*. The
    names `network` and `realitySettings.password` are pinned by a unit test instead.

### 4. Daemon *(opus, high: supervision state; the OpenVPN analogy is inexact)*
- [x] `XraySession` per D8. `ReconcilePlanner` diffs `xray` by `configHash`. `Supervisor` starts and stops sessions in `performApply` and on shutdown.
- [x] `RunLayout` gets `t-<id>.xray.json` (D7), written 0600 and removed on stop.
- [x] `ClientHub` source `xray:<id>`. `wayforkctl logs --source xray` and `status` show xray sessions the way they show openvpn ones.
- [x] Reducer and planner unit tests in `WayforkDaemonCoreTests`.
- Done when the tests are green and the app builds with `scripts/dev-sign.sh`. There is no live run, because Wayfork is never restarted from a session.
- Review 2026-10-30: accepted, 227 tests green, and `dev-sign.sh` built and signed the app.
  - The xray reducer is its own: a tunnel counts as connected only on the `core: Xray … started`
    line, and every exit is transient. xray follows `autoReconnect` like openvpn and is probed
    whatever its state.
  - **Found:** xray binds with SO_REUSEPORT, so a second listener on the same port shares it
    silently and does not fail. The PID file plus `killLeftovers` at startup cover the
    daemon's own leftovers. The "port clash → bind fails" risk holds only for listeners that
    don't use SO_REUSEPORT.
  - Gap found: the app reads process state and log sources only for OpenVPN, so it shows no
    xray state. This is now stage 4b.

### 4b. App: xray state and logs *(sonnet, high)*
- [x] One notion, "tunnel has a supervised process" (OpenVPN or XHTTP), plus a per-tunnel log
  source (`openvpn:<id>` / `xray:<id>`) in WayforkCore. Every app spot that keys process state or
  logs on `isOpenVPN` uses them instead.
- Done when an XHTTP tunnel's card, its degraded/failed state, "Show log" and the Logs window
  source list behave as they do for OpenVPN, the tests cover the new helpers and status text,
  and the suite plus the app build are green.

- Review 2026-10-30: accepted, 232 tests green. `TunnelKind.hasProcess` and
  `Tunnel.logSource` were added, along with the `xray.exited` and `xray.startFailed` texts.
  Not checked visually; that is in the stage 5 checklist.

### 5. Docs and live check *(sonnet, medium for docs; the check is the maintainer's)*
- [x] (docs written 2026-10-30, uncommitted) `04-tunnels.md` is synced with anything stages 1–4 changed, along with `05-daemon.md` (xray session), `09-wayforkctl.md` (source), README (XHTTP supported, size note), CHANGELOG `Unreleased` and the ROADMAP status.
- [ ] Owed to the maintainer, after installing a build:
  - Import a 3x-ui XHTTP+REALITY link. `curl https://ifconfig.me` through a rule shows the server's IP.
  - `wayforkctl logs --source xray --since 5m` is clean.
  - A QUIC/UDP site (or `dig @1.1.1.1` routed through the tunnel) works, or H3 flags it, which decides D9.
  - `kill` the xray process: the session restarts and traffic resumes.
  - Delete the tunnel: the process and `t-<id>.xray.json` are gone.

### W. Windows twin *(after stage 5; own prompt when started)*
Go service `XraySession` under the job object, the Dart parser and generator replaying
`fixtures/xray/` and `fixtures/vless/xhttp-links.json`, `windows/versions.env` pins and
fetch, and the MSI payload. Plan it from this file once the macOS live check passes.

## Risks and open questions

- **Local proxy port overlap.** `LocalProxy.portRange` (F17) is 1024–65535, so a user can
  pick a port in 47100–47131 and clash with an xray inbound. Accepted for now; the
  follow-up is to make the allocator skip the range.
- **Backlog, found 2026-10-30 outside this work:** the bundled sing-box 1.13.19 fails REALITY
  against servers on Xray 26.7.11 or newer. The client says `reality verification failed`
  and the server says `authentication failed`. Bisected on the maintainer's server: 26.6.27
  works and 26.7.11 fails; the uTLS fingerprint makes no difference. The xray 26.10.29
  client works against every version. The server is pinned to 26.6.27 for now.
  Options:
  - Bump sing-box and check it with the same minimal config. This is its own task.
  - If upstream lags, run REALITY-over-TCP VLESS through xray with this same mechanism.
    That is a scope change and the maintainer decides.

- **Stream key / field names drift** between Xray versions (`network` vs `method`,
  `password` vs `publicKey`). The `xray run -test` gate in stage 3 catches this against the
  pinned binary.
- **First-flow loop.** The process match can miss xray's first dial, as seen with openvpn.
  The server-address rule (D6) is the backstop.
- **UDP over SOCKS** (D9) is not verified until stage 5.
- **Port clash** with another app on 47100–47131. xray binds with SO_REUSEPORT (found in
  stage 4), so it fails to bind only if the other listener does not use SO_REUSEPORT too;
  otherwise both share the port silently. The daemon's own leftovers are covered by the
  PID file and `killLeftovers`. Acceptable for now.

## Prompts

Each stage executor is started with: "Read the prompt in
`/Users/fost/Projects/Wayfork/docs/roadmap/xhttp-xray.md`, section `Prompt <N>`, and
carry it out literally."

### Prompt 1

```
Session 1 — XHTTP stage 1: bundle xray · Model: sonnet, effort: medium · first stage

Repo: /Users/fost/Projects/Wayfork. Task: fetch, embed, sign and validate a pinned universal
`xray` binary next to sing-box/openvpn. No tunnel logic yet.

Read: ~/.claude/roles/coder.md; docs/roadmap/xhttp-xray.md (Context, D8, stage 1);
rules in /Users/fost/Projects/Wayfork/CLAUDE.md.
Entry points (verified): scripts/versions.env:5-7 (sing-box pin pattern);
scripts/fetch-bins.sh:131 fetch_sing_box, :114 lipo_or_copy, :47 download, :252-257 calls and
result check; scripts/embed-bins.sh:28,34,40; scripts/dev-sign.sh:76; scripts/release.sh:73,177,189;
macos/Daemon/DaemonEnvironment.swift:20; macos/Daemon/Supervisor.swift:33,142,149,240;
macos/WayforkCore/Sources/WayforkCore/Plan/RuntimePlanBuilder.swift:93.
Template: everything sing-box/openvpn does — copy it for xray.

Already decided: XRAY_VERSION=26.10.29; assets Xray-macos-arm64-v8a.zip / Xray-macos-64.zip
from https://github.com/XTLS/Xray-core/releases/download/v26.10.29/; pin the ZIP sha256
(read the .dgst, confirm with shasum -a 256); extract only `xray`; signing identifier
com.wayfork.bin.xray; version via `xray version` (first line). Follow the version through
whatever status/XPC field already carries openVPNVersion, adding an xrayVersion beside it.

Order:
1. versions.env + fetch_xray + result check; run scripts/fetch-bins.sh.
2. Script lists (embed/dev-sign/release).
3. DaemonEnvironment.xrayPath, Supervisor validation + version, RuntimePlanBuilder.xrayBinaryPath.
Tick stage-1 boxes in the roadmap only after the check passes.

DoD: `lipo -info macos/Resources/bin/xray` lists x86_64 arm64; `macos/Resources/bin/xray version`
prints 26.10.29; `swift build --package-path macos/WayforkCore` and
`xcodebuild -project macos/Wayfork.xcodeproj -scheme Wayfork -configuration Debug
-derivedDataPath build/DerivedData build` succeed; `scripts/format.sh --lint` clean.
Long output to a log file, only tail/grep into context.

Do not: touch windows/; add parser/generator/daemon-session code; run, quit or reinstall
Wayfork (this Mac's traffic goes through it); touch others' uncommitted files.
Do not commit or push. Last message — report: done (files) / deviations / not verified / open questions.
```

### Prompt 2

```
Session 2 — XHTTP stage 2: model and parser · Model: sonnet, effort: high · after stage 1

Repo: /Users/fost/Projects/Wayfork. Task: VLESS links with type=xhttp parse into a new
ProxyTransport.xhttp case and write back; nothing routes them yet.

Read: ~/.claude/roles/coder.md; docs/roadmap/xhttp-xray.md (D1, D2, stage 2);
docs/design/04-tunnels.md sections "VLESS → URI parsing" and "VLESS over XHTTP (Xray)";
rules in /Users/fost/Projects/Wayfork/CLAUDE.md.
Entry points (verified): macos/WayforkCore/Sources/WayforkCore/Model/Tunnel.swift:108
ProxyTransport; .../VLESS/VLESSURIParser.swift:61-68 type mapping, :136-143 writer;
macos/WayforkCore/Tests/WayforkCoreTests/VLESSURIParserTests.swift:47 rejects list, :89-135
fixture loading; fixtures/vless/links.json (shape template);
macos/App/Views/Settings/AddLinkSheet.swift:399 transport formatter.
Then let the compiler list every other exhaustive switch over ProxyTransport.

Already decided: D1 and D2 verbatim. Display string in AddLinkSheet: "XHTTP <path>" plus
" · <mode>" when mode is set. Trojan/VMess parsers must still reject xhttp (add a test).
fixtures/vless/links.json is shared with Dart — do NOT edit it; new file
fixtures/vless/xhttp-links.json, read only by Swift. Accepted cases at least: reality
minimal (path only), tls with host+mode=packet-up, extra with a JSON object
(percent-encoded). Rejected at least: mode=bogus, extra=[1], extra=not-json, flow with xhttp,
allowInsecure=1 with xhttp, type=splithttp.

Examples:
- `type=xhttp&security=reality&pbk=k&sid=s&sni=a.com` → .xhttp(path:"/", host:nil, mode:nil, extra:nil)
- `type=xhttp&path=%2Fx&mode=stream-one` → path "/x", mode "stream-one"; writer gives back the same query order
- `type=xhttp&mode=fast` → invalid("mode must be auto, packet-up, stream-up, or stream-one")
- `type=xhttp&extra=%5B1%5D` → invalid("extra must be a JSON object")

DoD: `swift test --package-path macos/WayforkCore` green (if SwiftPM test fails on
environment, run `xcodebuild test -scheme WayforkCore-Package -destination 'platform=macOS'`
from macos/WayforkCore); parse→write→parse round-trip test for every accepted fixture;
app builds (xcodebuild command from Prompt 1); `scripts/format.sh --lint` clean.

Do not: touch windows/, the sing-box generator, RuntimePlan or the daemon; edit
fixtures/vless/links.json or fixtures/singbox/; run/restart Wayfork.
Do not commit or push. Last message — report: done (files) / deviations / not verified / open questions.
```

### Prompt 3

```
Session 3 — XHTTP stage 3: plan and generators · Model: sonnet, effort: high · after stage 2

Repo: /Users/fost/Projects/Wayfork. Task: an enabled VLESS+xhttp tunnel produces an
XrayRuntime in the plan and a socks outbound in sing-box.json. No daemon code.

Read: ~/.claude/roles/coder.md; docs/roadmap/xhttp-xray.md (D3–D6, D10, stage 3);
docs/design/04-tunnels.md "VLESS over XHTTP (Xray)"; fixtures/README.md;
rules in /Users/fost/Projects/Wayfork/CLAUDE.md.
Entry points (verified): Model/Tunnel.swift:357 maxSlots, :415 interfaceName (pattern for
xrayPort); XPC/RuntimePlan.swift:5 RuntimePlan, :14 openVPN, :41-48 coding, :83 plan hash,
:215 OpenVPNRuntime (template for XrayRuntime); Plan/RuntimePlanBuilder.swift:103-171
(OpenVPN runtime build :116-140, VLESS branch :141, generator input :170);
WayforkDaemonCore/PlanValidator.swift:64-89; SingBox/SingBoxConfigGenerator.swift:16-70 Input,
:193 process_path rule, :197-200 server rule, :269-273 VLESS case, :472/:498
openVPNServers/serverRouteRule; Tests/WayforkCoreTests/SingBoxGeneratorTests.swift:41 variants,
:607-640 golden driver (template for the xray golden driver).
(All paths under macos/WayforkCore/Sources/WayforkCore unless shown otherwise.)

Already decided: D3–D6 and D10 verbatim. Stage 2 left `transportBlock` returning nil for
`.xhttp`: branch on `.vless` with an `.xhttp` transport BEFORE `vlessOutbound` and emit the
socks outbound instead, and add a test that no generated outbound for an XHTTP tunnel has
`type: vless`. The pre-resolve set (resolvedServerAddresses
callers) gains XHTTP VLESS servers. The `xray run -test` test: Process on
<repo>/macos/Resources/bin/xray with `run -test -c <file>`, skipped with a message when the
binary is absent; for the stream key (`network` vs `method`) and reality key (`password` vs
`publicKey`) use whatever the pinned binary accepts — try `network`/`password` first and
record the result in the report.

Order: model/plan types + validator → XrayConfigGenerator + unit tests → builder →
sing-box generator → goldens (WAYFORK_UPDATE_GOLDEN=1) → xray -test test.

DoD: tests green (command as in Prompt 2); `git diff --stat fixtures/singbox fixtures/vless/links.json`
empty; xray -test passes on both goldens (not skipped — fetch-bins was run in stage 1);
`scripts/format.sh --lint` clean; app builds.

Do not: touch windows/ or macos/Daemon/; change output for non-xhttp tunnels; put xhttp
variants under fixtures/singbox/; run/restart Wayfork.
Do not commit or push. Last message — report: done (files) / deviations / not verified / open questions.
```

### Prompt 4

```
Session 4 — XHTTP stage 4: daemon xray sessions · Model: opus, effort: high · after stage 3

Repo: /Users/fost/Projects/Wayfork. Task: the daemon supervises one xray process per
RuntimePlan.xray entry: start, restart with backoff, stop, config file hygiene, logs.

Read: ~/.claude/roles/coder.md; docs/roadmap/xhttp-xray.md (D7, D8, stage 4);
docs/design/05-daemon.md; docs/design/09-wayforkctl.md (log sources);
rules in /Users/fost/Projects/Wayfork/CLAUDE.md.
Entry points (verified): macos/Daemon/OpenVPNSession.swift (:9 actor, :58 start, :71 stop,
:117 spawn via ManagedProcess, :22/:232-245 backoff; :202-207 routes — NOT needed for xray);
WayforkDaemonCore OpenVPNSessionReducer + OpenVPNFailure.swift; ReconcilePlanner.swift:5,40,55;
RunLayout.swift:17-22; macos/Daemon/Supervisor.swift:27 sessions, :297-318 performApply,
:372-386 stop; ClientHub.swift:53,138,164 (source key pattern `openvpn:<id>`).

Already decided: D7, D8. Stage 3 delivered `RuntimePlan.xray: [XrayRuntime]` (`id`, `port`,
`config`, `configHash`) and `PlanValidator.validateXray`, so do not redo them. The command is
`xray run -c <run dir>/t-<id>.xray.json`. Until this stage lands, an enabled XHTTP tunnel
routes to a port nobody listens on. Judgment is yours on how much of the OpenVPN reducer to share vs
a smaller xray reducer — prefer the smallest correct thing, no management protocol. The
config file is written before spawn with 0600 and removed on stop and on daemon startup
cleanup of stale run files. A port bind failure is a normal failure → backoff, error in log.

DoD: reducer/planner tests in WayforkDaemonCoreTests green; full test suite green; app
builds; `scripts/dev-sign.sh` succeeds (it does not install or restart anything — check
the script before running; if it would, skip and say so); format lint clean.

Do not: run, quit, restart or reinstall Wayfork or the daemon; touch windows/; change
OpenVPN behaviour.
Do not commit or push. Last message — report: done (files) / deviations / not verified / open questions.
```

### Prompt 4b

```
Session 4b — XHTTP stage 4b: app shows xray state and logs · Model: sonnet, effort: high · after stage 4

Repo: /Users/fost/Projects/Wayfork. Task: the app treats an XHTTP tunnel's xray process the
way it treats an OpenVPN process: state on the card, failed/degraded, "Show log", Logs window.

Read: ~/.claude/roles/coder.md; docs/roadmap/xhttp-xray.md (D8, stages 4 and 4b);
rules in /Users/fost/Projects/Wayfork/CLAUDE.md.
Entry points (verified): macos/WayforkCore/Sources/WayforkCore/Model/Tunnel.swift
(`TunnelKind.isOpenVPN`, `usesXray`); WayforkDaemonCore/XraySessionReducer.swift
(`source(for:)`, the daemon's `xray:<id>` key); app spots keyed on OpenVPN:
macos/App/Model/AppModel.swift:280,1006,1007; macos/App/Views/Logs/LogsWindowView.swift:37-38,212-215;
macos/WayforkCore/Sources/WayforkCore/App/StatusText.swift:265,272,360;
macos/WayforkCore/Sources/WayforkCore/App/GlobalState.swift:77.

Already decided:
- In WayforkCore add `TunnelKind.hasProcess` (isOpenVPN || usesXray) and
  `Tunnel.logSource: String?` ("openvpn:<id>", "xray:<id>", nil for native kinds; id lowercased).
  WayforkCore cannot import WayforkDaemonCore, so build the string there, and add a test that
  it equals `XraySessionReducer.source(for:)` in WayforkDaemonCoreTests.
- Replace `isOpenVPN` with `hasProcess` where the question is "does a process state exist"
  (StatusText:265,272,360, GlobalState:77, LogsWindowView:37). Keep `isOpenVPN` where it
  really is OpenVPN: AppModel:280 "Config" vs "UUID" (XHTTP → "UUID"), and AppModel:1006
  focus (XHTTP → .url).
- AppModel:1007 and LogsWindowView:38 use `tunnel.logSource`. LogsWindowView:212-215 shows
  "xray:<name>" for xray sources the way it shows "openvpn:<name>".
- Status words for xray states reuse the OpenVPN ones; reason codes `xray.exited` and
  `xray.startFailed` get human text next to the openvpn reasons in StatusText (grep
  "openvpn." reason codes there for the pattern).

DoD: tests green (`swift test --package-path macos/WayforkCore`); new tests for hasProcess,
logSource and the xray reason text; StatusText tests show an XHTTP tunnel with
`.failed(reason: "xray.exited")` rendered like a failed OpenVPN one; app builds (xcodebuild
command from Prompt 1); format lint shows only the 5 known LineLength errors.

Do not: touch the daemon, generators or windows/; change OpenVPN behaviour or texts;
run/restart Wayfork; git stash.
Do not commit or push. Last message — report: done (files) / deviations / not verified / open questions.
```

### Prompt 5

```
Session 5 — XHTTP stage 5: docs · Model: sonnet, effort: medium · after stage 4b

Repo: /Users/fost/Projects/Wayfork. Task: bring the docs in line with what stages 1–4b
actually shipped, including the SO_REUSEPORT finding (stage 4 review) in the risks.

Read: docs/roadmap/xhttp-xray.md (all, including the stage reports' deviations noted in
it); `git diff` of stages 1–4 against eecadbb (to a log file, read in pieces).
Update: docs/design/04-tunnels.md (XHTTP section, shape table, "What the pinned sing-box
accepts" note), docs/design/05-daemon.md (xray session), docs/design/09-wayforkctl.md
(xray log source), README.md (lines ~140 and ~306: XHTTP supported on macOS, Windows
pending; bundle size note), CHANGELOG.md Unreleased, docs/ROADMAP.md F13 status,
fixtures/README.md (fixtures/xray/ is Swift-only until stage W).

DoD: every claim matches the code (grep the symbol before writing it); no Windows claims
beyond "pending".
Do not: change code; touch windows/. Do not commit or push.
Last message — report: done (files) / deviations / open questions.
```
