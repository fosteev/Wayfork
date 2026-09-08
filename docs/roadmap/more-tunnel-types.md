# F13 — More tunnel types

> Status: in progress · created 2026-09-07 · **stages 1–5 done and the shipping docs
> written**; what is left is stage 6's two live checks, which only the maintainer can run
> (macOS and the Windows PC), and then the optional stages 7–8

## Goal

A tunnel can be anything the pinned sing-box carries natively **and the maintainer can
stand up for a live check**: a WireGuard `.conf`, and `ss://`, `trojan://`, `vmess://`
links, imported the way `vless://` is today, on both platforms, with the secrets split off
to Keychain / DPAPI and the golden fixtures shared by the Swift, Dart and Go suites. XHTTP
through a bundled Xray-core is planned here but scoped as its own follow-up (stage 8).

## Context and constraints

- **Live servers** (settled in stage 1): the maintainer runs an Xray panel (3x-ui 2.8.11,
  Xray-core v26.2.6) that can serve `wireguard`, `shadowsocks`, `trojan`, `vmess` and
  `vless` inbounds. That is the scope fence — a kind nobody can test live does not ship.
  Shadowsocks methods the panel offers are exactly AEAD + 2022-blake3, so the "reject legacy
  ciphers" rule costs nothing in practice. Hysteria2 is not an Xray protocol and left the
  plan for want of a server.
- Two kinds exist: `openVPN` (own process, own utun / adapter, `direct` outbound with
  `bind_interface`) and `vless` (native outbound, no process). Everything in this plan is
  the **VLESS model**: no process, "ready whenever sing-box runs", secrets in
  `RuntimePlanBuilder.Secrets`, one outbound tag `t-<id>`. Design reference:
  [design/04-tunnels.md](../design/04-tunnels.md) § VLESS,
  [design/03-routing.md](../design/03-routing.md) (DoT detour when the default is a
  non-OpenVPN tunnel).
- The pinned sing-box is **1.13.19** on both platforms (`scripts/versions.env`). The
  bundled macOS binary reports tags `with_gvisor,with_quic,with_wireguard,with_utls,
  with_naive_outbound,with_tailscale,with_ocm` (checked 2026-09-07 on the installed app);
  the Windows arm64 zip reports the same family (08-windows.md § S0). So WireGuard
  (userspace stack via gVisor) and uTLS need no binary change; `with_quic` is what a later
  Hysteria2/TUIC would need, and it is already there.
- **WireGuard is an *endpoint*, not an outbound, in 1.13** (legacy `wireguard` outbound
  deprecated in 1.11; migration guide maps `local_address → address`, peer fields → `peers[]`).
  **Settled by the spike (2026-09-07, see stage 3):** an endpoint tag is a first-class
  outbound tag — accepted as `route.final`, as a route rule `outbound` and as a DNS server
  `detour`; a peer given by hostname needs no `domain_resolver` on the endpoint, it falls
  back to `route.default_domain_resolver`. WireGuard stays in this plan as a native endpoint.
- **`sing-box check` validates schema only** (spike by-product, 2026-09-07): a dangling
  `outbound` / `detour` tag passes `check` with exit 0 and only fails at `run` with
  `FATAL … outbound not found` / `outbound detour not found`. So the golden-fixture
  `sing-box check` in `TrafficTests` and the check in the daemon's apply path cannot catch
  a generator that emits a tag nobody defines — worth knowing now that the generator grows
  a second tag namespace (`endpoints[]`). Optional hardening in stage 3, not a blocker.
- Branch points per kind today (all must grow one case per new kind): `Tunnel.swift`
  (`TunnelKind`), `SecretStore.swift` (`SecretKey`), `RuntimePlanBuilder.swift`,
  `SingBoxConfigGenerator.swift`, `ImportExport.swift`, `StatusText.swift`,
  `AppModel+Tunnels.swift`, `AppModel+Seed.swift`, `TunnelsSettingsView.swift`,
  `wayforkctl/main.swift`; Dart twins under `core/model/tunnel.dart`, `core/secrets/`,
  `core/plan/runtime_plan_builder.dart`, `core/singbox/sing_box_config_generator.dart`,
  `app/model/app_model_tunnels.dart`, `app/ui/add_vless_dialog.dart`, `tunnels_page.dart`,
  `tunnel_details.dart`. The Go service does not branch on tunnel kinds (sing-box config is
  opaque to it) — *(verify)* `core/validate.go` has no outbound-type whitelist.
- Store schema: `TunnelKind` decoding throws on an unknown key, so a store written by a
  build with new kinds does not load in an older build. Decision: acceptable (solo project,
  forward-only), noted in 01-data-model.md; no schema version bump.
- Fixture inputs carry secrets as per-kind maps (`vlessUUIDs`). Decision: add parallel maps
  (`wireGuardKeys`, `passwords`…) rather than restructuring `input.json` — existing goldens
  stay valid byte for byte.
- Repo convention: milestone checkboxes live in [ROADMAP.md](../ROADMAP.md) (M8) and
  [ROADMAP-windows.md](../ROADMAP-windows.md) (WM9); fine-grained progress lives here.
  Phases are strict: feature text → design notes → code.

### Scope decisions *(approved 2026-09-07)*

| Kind | Input | Secret(s) | In this plan |
|------|-------|-----------|--------------|
| WireGuard | `.conf` file / pasted INI (`[Interface]`, `[Peer]`) | private key, preshared key | yes, first |
| Shadowsocks | `ss://` SIP002 (base64 userinfo, `plugin=`) | password | yes; AEAD + 2022 methods only, `plugin` → unsupported |
| Trojan | `trojan://pw@host:port?sni&fp&alpn&type&path&host&serviceName` | password | yes; shares the VLESS TLS/transport code |
| VMess | `vmess://` base64 JSON (V2RayN) | uuid | yes; `aid>0` → unsupported |
| Subscriptions (URL → base64 list of links) | URL | — | stage 7, optional |
| Hysteria2 | `hysteria2://` / `hy2://` | password, obfs password | **no** — no live server (not an Xray protocol); parser + generator are an afternoon once one exists |
| TUIC, AnyTLS, SOCKS/HTTP upstream, NaiveProxy | links / fields | password | **no** — add on request, same recipe |
| XHTTP via Xray-core | `vless://…type=xhttp` | uuid | stage 8, separate approval |
| IKEv2 / L2TP / other per-process VPNs | — | — | **no** (own process + system NE; out of the architecture) |

## Stages

### 1. Feature entry and approval

Turn ROADMAP L3 into a feature with the table above and get it approved before any design
text.

- [x] Rewrite [ROADMAP.md](../ROADMAP.md) § L3 as **F13. More tunnel types** (scope table,
      the VLESS-model constraint, XHTTP kept as its own bullet) and add skeleton milestones
      M8 / WM9 pointing at this file; mirror F13 in ROADMAP-windows.md § Phase W1. Done
      2026-09-07: L3 left as a one-line pointer so L4–L7 keep their numbers, F13 sits after
      F12 with the scope table, M8 in Phase 3 and WM9 in Phase W3.
- [x] Maintainer confirms the kind list, the order and the exclusions. Answered 2026-09-07:
      **the list is whatever the Xray panel can serve, so that every kind can be tested**;
      the order is the implementer's call.
- [x] Maintainer answers: which of these does he have a real server for? A 3x-ui 2.8.11 /
      Xray-core v26.2.6 panel that creates `wireguard`, `shadowsocks`, `trojan`, `vmess`
      (and `vless`) inbounds — four of the five proposed kinds. Hysteria2 has no server and
      is dropped. Panel address and credentials stay out of the repo (CLAUDE.md § Secrets);
      the maintainer creates the test inbounds, or is asked before anything is created for him.

**Done when:** the maintainer says so, in as many words; this banner flips to "in progress".

### 2. Design notes

Record every mapping before code, one section per kind in 04-tunnels.md, so the Dart port
can be written from the doc alone.

- [x] 04-tunnels.md: retitled to "Tunnels"; a shape table up front, per-kind sections
      (grammar → meta → JSON → validation) for WireGuard, Shadowsocks, Trojan and VMess, a
      "Shared TLS and transport" section for the refactor, and a closing section recording
      what the pinned sing-box actually accepts. Two design answers that only came out of
      probing 1.13.19 directly:
      · **the endpoint's `domain_resolver` also resolves the peer's own hostname**, so it
        may be `dns-t-<id>` only when every peer is a literal IP — otherwise sing-box dies
        at start with `WireGuard is not ready yet`. The generator therefore prefers
        `Input.resolvedServerAddresses` (extended to WireGuard peers) and falls back to
        `"dns-direct"` with the hostname; peer hostnames also join the existing
        "server hosts → dns-direct" DNS rule so the app's own `getaddrinfo` sees a real
        address under the F12 override.
      · sing-box validates a WireGuard endpoint far less than assumed (no `address`, no
        peers, a peer without a port all "start"), so the parser is the gate.
- [x] 03-routing.md: new "DNS per tunnel kind (F13)" section — the split is not per kind
      but per *who resolves the destination name*: OpenVPN and WireGuard resolve locally and
      get `dns-t-<id>` plus a `domain_resolver`; the proxy kinds resolve server-side and get
      nothing per tunnel, only the DoT server when they are the default. The F8 bullet that
      said "for a VLESS default" now names all four proxy kinds.
- [x] 01-data-model.md: four new `TunnelKind` cases with their metas (`WireGuardMeta` +
      `WireGuardPeer`, `ShadowsocksMeta`, `TrojanMeta`, `VMessMeta`), three new Keychain
      accounts (`privateKey`, `presharedKey`, `password`; `uuid` reused for VMess — one
      account per secret *kind*, not per tunnel kind, so `SecretKey.all(for:)` stays
      kind-agnostic), the export-document note, and the forward-only decision with its
      escape hatch.
- [x] 02-ux.md: the **+ Add** menu (Import OpenVPN Config… / Add WireGuard… / Add from
      link…), the generalized link sheet with scheme detection and its Replace mode, the
      WireGuard sheet, a per-kind table of row summaries and expanded fields, the badges
      (`allowInsecure` extended to Trojan/VMess, the new `AllowedIPs` one), and three new
      error-catalogue codes (`import.link.invalid`, `import.link.unsupported`,
      `import.wireguard.invalid`).
- [x] 08-windows.md: "More tunnel types (WM9, F13)" — deltas only (the mappings live in
      04-tunnels.md): the Go service unchanged, wintun not involved, DPAPI key names, the
      Dart core files, the Flutter dialogs, `.conf` in the picker. The
      `core/validate.go` whitelist question stays marked *(verify)* — it is a five-minute
      check at the start of stage 5, not a design unknown.
- [x] fixtures/README.md rows for `links/<scheme>.json` and `wireguard/*.conf`, the three
      new `singbox/*` variants, the per-kind secret maps in `input.json`, and why the
      WireGuard / SS-2022 keys are real base64 rather than `<KEY>` placeholders.

**Done when:** the notes exist with no open *(verify)* marker except the endpoint one,
which stage 3 closes first. **Done 2026-09-07.** The endpoint marker is closed; what is
left open is deliberately elsewhere: `core/validate.go` *(verify)* in stage 5, and one
finding parked as *(open)* in 04-tunnels.md — 1.13.19 accepts REALITY over `ws`/`grpc`,
which the VLESS import has rejected since M1. Relaxing it is an F1 change with its own live
check, not something to slip in with F13.

### 3. Core, macOS: parsers, model, generator, fixtures

Pure WayforkCore work, protocol by protocol, each landing with its fixtures. Start with the
riskiest unknown.

- [x] Spike *(done 2026-09-07, pulled ahead of stage 2 — the WireGuard design sections
      depend on its answer)*: hand-wrote an `endpoints[]` WireGuard entry into a copy of the
      `default-vless` golden, referenced as `route.final`, as a rule `outbound` and as a DNS
      `detour`. **`sing-box check` turned out to prove nothing** — it accepts a `final` tag
      that no outbound defines (exit 0), so the spike was redone with `sing-box run` on a
      TUN-less config (one `mixed` inbound on loopback) plus two negative controls:
      · endpoint as `final`/`outbound`, peer by IP → started;
      · same with the peer given as a hostname and no `domain_resolver` on the endpoint →
        started, name resolved through `route.default_domain_resolver`;
      · bogus `route.final` → `FATAL start service: default outbound not found`;
      · bogus DNS `detour` → `FATAL start service: start dns/udp[…]: outbound detour not found`.
      Conclusion: **an endpoint tag is a first-class outbound tag**; WireGuard stays native.
      Recorded in 04-tunnels.md (stage 2).
- [x] Hardening, done first instead of last (2026-09-07): `everyReferencedTagIsDefined`
      in `SingBoxGeneratorTests` walks every golden variant and asserts that each
      `route.final` / rule `outbound` / DNS `detour` exists among `outbounds[]` +
      `endpoints[]`, each `dns.rules[].server` and `dns.final` among the DNS servers, and
      each `rule_set` reference among the declared rule-sets. It is what `sing-box check`
      cannot do, and it guards the WireGuard work that follows rather than arriving after
      it. Green on all ten existing variants.
- [x] Refactor (2026-09-07): `tlsBlock(...)` and `transportBlock(...)` extracted from
      `vlessOutbound`; `VLESSSecurity` → `TLSSecurity` and `VLESSTransport` →
      `ProxyTransport` (JSON-neutral: neither name appears in `store.json`, so no migration
      and no fixture churn — confirmed, goldens byte-identical before and after). Only two
      source files referenced the old names.
- [x] **WireGuard, whole kind (2026-09-07)** — model (`WireGuardMeta`, `WireGuardPeer`,
      `TunnelKind.wireGuard`), `SecretKey.privateKey` / `.presharedKey`,
      `WireGuardConfParser` (INI, comments, case-insensitive keys, IPv4-only filtering,
      bare address → `/32`), the `endpoints[]` builder with both `domain_resolver`
      branches, `resolver(for:)` shared with OpenVPN, `dns.final` for a WireGuard default,
      peer hostnames in the "→ dns-direct" DNS rule, `RuntimePlanBuilder` secrets,
      `HostResolver.serverHosts`, `ImportExport`, `StatusText`, `wayforkctl`. Fixtures:
      `fixtures/wireguard/` (4 accepted + 6 rejected) and the golden variants
      `singbox/wireguard` (peer by IP) and `singbox/default-wireguard` (peer by name, the
      `dns-direct` fallback). Delegated to codex, reviewed here; 133 tests green, existing
      goldens byte-identical.
      · Review fix: the parser accepted `AllowedIPs = 10.0.0.5` without a prefix, which
        sing-box refuses outright (`decode config`) — the import would have succeeded and
        the engine then failed to start. Normalized to `/32` like `Address`, covered in the
        `split` fixture.
      · Verification beyond the suite: both new goldens were run through `sing-box run`
        with the TUN inbound swapped for a loopback `mixed` one — both start, which is what
        `check` cannot tell you.
      · The plan's open question "confirm nothing else consumes `hosts`" is answered:
        WireGuard peers join only the DNS rule, never `serverRouteRule` — sing-box dials its
        peers through its own dialer, which never passes through route rules.
- [x] **Shadowsocks, Trojan and VMess (2026-09-07)** — delegated as one batch (they share
      the parser file and the golden), reviewed here. `ProxyLinkParser` dispatches on the
      scheme and keeps `vless://` with `VLESSURIParser`; `SecretKey.password` for SS and
      Trojan, the existing `.uuid` for VMess; three outbound builders on the shared
      `tlsBlock`/`transportBlock`; fixtures `fixtures/links/{ss,trojan,vmess}.json`
      (5 accepted + 4–5 rejected each) and the golden `singbox/proxy-links` with one tunnel
      of each kind. 144 tests green, existing goldens untouched, the app still builds.
      · Still owed by stage 4: link *builders* (`uri(meta:secret:name:)`) for the Copy
        button — the parsers only read. VLESS already has one to copy the shape from.
- [x] `wayforkctl plan --link <uri>` (any scheme; `--vless` kept as an alias) and
      `--wireguard <file>`, done here rather than delegated — it is the only way to exercise
      a kind end to end before the UI exists, and it is what surfaced the fake-IP bug below.

- [x] Review fix, found by running `wayforkctl` under the live Wayfork: `HostResolver`
      returned a **fake IP** for the WireGuard peer's hostname, and the generator pinned it
      as the peer address — a tunnel that dials the TUN in circles. Under the F12 override
      every lookup goes through Wayfork, which answers with a fake IP for any name the
      *currently applied* config does not route to `dns-direct`; on the first apply after a
      tunnel is added, that is the new peer itself. `resolveIPv4` now drops answers inside
      the fake-IP range, as the Dart twin has done since August — a cross-client divergence
      nobody had noticed because only WireGuard pins a resolved address into the config.
      Side effect: `openVPNServersAlwaysGoDirectByNameAndAddress`, documented since M7 as
      "fails falsely under a live Wayfork", passes now — the fake-IP answer was exactly what
      it was tripping over. The stale caveat is removed from dead-udp-suggestions.md.

**Done when:** `xcodebuild test -scheme WayforkCore-Package -destination 'platform=macOS'`
from `Wayfork/WayforkCore` is green, goldens reviewed, `swift-format lint` clean.
**Done 2026-09-07:** 144 + 80 tests, no failures at all (see the fake-IP fix above); the
three new goldens were additionally started under a real `sing-box run` with the TUN
inbound swapped for a loopback inbound, which is the only way to prove the tag references
and the WireGuard peer resolution actually work.

### 4. App, macOS

- [x] `TunnelsSettingsView`: **Add** menu → Import OpenVPN Config…, Add WireGuard…, Add from
      link…; drop target accepts `.conf` next to `.ovpn`; seed importer takes `.conf` and
      every link scheme.
- [x] `AddLinkSheet` (renamed from `AddVLESSSheet`): scheme detection, per-kind parse
      errors, replace mode that refuses a link of another kind; `AddWireGuardSheet`: file
      picker or paste area, live preview, `AllowedIPs` warning.
- [x] `AppModel+Tunnels`: `addLink`/`replaceLink`, `addWireGuard`/`replaceWireGuardConfig`
      (which keeps the user's DNS choice across a config replace), `linkURI`/`maskedLinkURI`
      for every link kind, `setDNS` extended to WireGuard, `importWireGuard(from:)`.
      Core got the missing half: `ProxyLinkParser.uri(...)` builders for ss/trojan/vmess
      with a round-trip test over every accepted fixture.
- [x] Tunnel card: per-kind rows (link + Copy for the four link kinds; Peer / Address / DNS
      / MTU / Replace Config… for WireGuard), the `AllowedIPs` warning line.
- [x] Daemon: nothing needed, as expected — no process, no interface; the kinds never reach
      it. Confirmed by reading `Supervisor`/`RuntimePlan`: a plan with only native tunnels
      carries an empty `openVPN` list, which is already the VLESS case.
- [x] Review fixes: the replace-link guard compared the *badge text* of the two kinds, so a
      renamed label would have silently allowed a Trojan link to overwrite a VMess tunnel —
      now a structural case match; the `AllowedIPs` warning was yellow where the rest of the
      app uses orange.

**Done when:** the app builds (`xcodebuild -project Wayfork/Wayfork.xcodeproj -scheme
Wayfork -configuration Debug -derivedDataPath build/DerivedData build`), `swift-format
lint --recursive` clean, a dev-apply plan with one tunnel of each kind passes
`sing-box check`. Build only — the live Wayfork is installed by the maintainer.
**Done 2026-09-07:** build succeeded, lint clean, 145 + 80 tests green; the plan check was
done through `wayforkctl plan --wireguard … --link …`, whose config both `sing-box check`
and a real `sing-box run` accept. What no build can cover — that the sheets look right and
that a real server answers — is the maintainer's stage-6 check.

### 5. Windows mirror

Same shape in Dart, replaying the shared fixtures; the Go service is untouched unless the
verify in Context fails.

- [x] `core/model/tunnel.dart`: kinds + metas, JSON one-key envelope identical to Swift;
      `VLESSSecurity`/`VLESSTransport*` renamed to `TlsSecurity`/`ProxyTransport*` across
      lib and test (codex had left compatibility typedefs behind — removed, one name per
      type, as on the Swift side).
- [x] `core/wireguard/` INI parser and `core/links/` link parser, with tests replaying
      `fixtures/wireguard/*` and `fixtures/links/*.json` — every accepted fixture parses to
      the byte-identical result and every rejected one throws the recorded message.
- [x] `core/secrets`: `privateKey` / `presharedKey` / `password` (the accounts test now
      asserts it lists *every* `SecretKind`, since that list drives the orphan sweep);
      `runtime_plan_builder.dart` secret maps; `sing_box_config_generator.dart` builders and
      the `endpoints[]` array — **the golden replay matches all thirteen variants byte for
      byte**, which is the real proof the two clients agree; `export_document.dart`;
      `status_text.dart` and `import_export.dart` extended for the new kinds.
- [x] Flutter: **Add** flyout with *Add WireGuard…* and *Add from link…*;
      `add_vless_dialog.dart` → `add_link_dialog.dart` with scheme detection and a per-kind
      preview; new `add_wireguard_dialog.dart` (picker or paste, live preview, the
      `AllowedIPs` warning); `tunnel_details.dart` split into `LinkDetail` and
      `WireGuardDetail`; the DNS radio/field extracted into a shared `TunnelDnsEditor` used
      by both kinds that own a resolver, rather than duplicated; `.conf` accepted by the
      drop path; widget tests for the link preview, a per-kind parse error and the
      `AllowedIPs` warning, plus model tests for WireGuard add and the wrong-kind replace
      guard. Codex ran out of quota after the core half, so all of this was done by hand.
- [x] Go: untouched and green (`go test ./...`, `GOOS=windows go build ./...`). The
      *(verify)* is closed: `core/validate.go` has no outbound-type whitelist, so
      `endpoints[]` passes through it unnoticed — the config really is opaque to the service.

**Done when:** `dart format` + `dart analyze --fatal-infos` + `flutter test` green in
`WayforkWindows/app`; `gofmt` + `go vet` + `go test ./...` green in
`WayforkWindows/service`; the new goldens match on all three suites.
**Done 2026-09-07:** 338 Dart tests, analyze clean, Go untouched and green; the golden
replay matches all thirteen `singbox/*` variants byte for byte, which is the actual proof
that the Swift and Dart generators agree about `endpoints[]` and the three new outbounds.

### 6. Ship

- [x] CHANGELOG § Unreleased (Added / Changed / Fixed, including the fake-IP resolver fix);
      README — the badge row, the one-line pitch, the Features bullet and the Tunnels
      section now name every kind and what is refused at import. M8 / WM9 are ticked except
      for their manual checks, which are the two below.
- [ ] Live check, macOS (maintainer): one inbound of each kind on the Xray panel
      (wireguard, shadowsocks, trojan, vmess), imported into Wayfork; a domain rule through
      each carries traffic; **WireGuard as default** resolves DNS through the endpoint (no
      leak: `dig` from the Mac shows the tunnel's resolver path) and survives a network
      change; H3's ⚠ stays quiet on all four (UDP actually flows).
- [ ] Live check, Windows (`ssh wf-pc`): same set, plus MSI upgrade keeps the old tunnels
      loading (store forward-only, but old → new must work).

**Done when:** both checks observed by the maintainer; banner flips to "done".

### 7. Subscriptions *(optional, after 6)*

- [ ] Paste a subscription URL → fetch (app side, plain HTTPS), base64-decode, split into
      links, run each through `ProxyLinkParser`, offer a checklist of servers to add.
      Decision: one-shot import, no auto-refresh (refresh belongs with L4 health/failover).
- [ ] Fixture: `fixtures/links/subscription.txt` + expected list; Dart twin.

**Done when:** a subscription with mixed kinds adds N tunnels with masked links.

### 8. XHTTP via bundled Xray-core *(separate approval; gets its own roadmap file)*

Kept here so the shape is not lost; it is the OpenVPN process model with a port instead of
a utun, described in ROADMAP L3. When approved, create `docs/roadmap/xhttp-xray.md` and
move these steps there.

- [ ] Pin `xray` in `versions.env` (macOS arm64/x86_64, Windows amd64/arm64), fetch/embed/
      sign as `com.wayfork.bin.xray`; `BinaryValidator` requirement.
- [ ] `XrayRuntime` in the plan (config JSON with a loopback SOCKS5 inbound on a port from a
      reserved range, XHTTP outbound); daemon `XraySession` modelled on `OpenVPNSession`
      (supervision, backoff, log tail); Go/Windows twin under the job object.
- [ ] Generator: `socks` outbound `t-<id>` → `127.0.0.1:<port>`, `process_path` direct rule
      for `xray`, DNS detour through the socks outbound; parser accepts `type=xhttp`
      (`path`, `host`, `mode`).
- [ ] UDP: check whether xray's SOCKS inbound does UDP ASSOCIATE well enough for H3 not to
      flag every XHTTP tunnel; if not, mark the tunnel TCP-only in the UI.

## Risks and open questions

- **Endpoint as outbound/detour** — the whole WireGuard stage hangs on it. Closed by the
  stage-3 spike within an hour; the fallback (per-process `wireguard-go`) is a different
  plan and not worth pre-designing.
- **WireGuard through gVisor**: userspace stack, MTU 1408 default vs. `MTU=` in the conf;
  throughput lower than a kernel tunnel. Acceptable for split-tunnel use; note in the docs.
  Peer given by hostname resolves through `route.default_domain_resolver` with no
  `domain_resolver` on the endpoint (spike, 2026-09-07).
- **`vmess://` has no standard**: the V2RayN base64-JSON form is the de-facto one; other
  forms (Shadowrocket) are rejected with a clear reason, not guessed.
- **Shadowsocks legacy ciphers / plugins**: refused at import (`import.link.unsupported`),
  matching the VLESS precedent of rejecting what sing-box would misroute or silently degrade.
- **Store forward-only**: an older build fails to load a store with a new kind. Solo
  project, accepted; if it bites, the fix is decoding unknown kinds into a disabled
  placeholder — one afternoon, not a schema version.
- **Live servers**: closed in stage 1 — the Xray panel covers all four kinds. The residual
  risk is that Xray's WireGuard inbound is Xray's own userspace implementation, so its conf
  carries no pushed `DNS =` and no server-side `AllowedIPs`: those come from whatever we
  write. Good enough to exercise the parser and the endpoint, and it is the only WireGuard
  server available; a kernel `wg` peer may behave differently on MTU.
- **`sing-box check` is not a tag checker** (spike): the apply path's config validation
  cannot catch a dangling `outbound`/`detour`. Mitigated by the optional golden-test
  assertion in stage 3 and, at runtime, by H1/H2 (a start that fails is retried and shown).

## Working order

Strictly 1 → 2 → 3 → 4 → 5 → 6 (phase gates); 7 and 8 only after 6 and only on request.
The one deliberate departure: **the endpoint spike ran before stage 2**, because every
WireGuard sentence in the design notes depends on its answer and the fallback would have
been a different plan altogether. It produced no shipped code — a throwaway config and a
`sing-box run` — so the Features → Design → Implementation gate stands.

Inside 3, after the TLS/transport refactor, kinds in the order **WireGuard → Shadowsocks →
Trojan → VMess** (implementer's call, approved 2026-09-07):

- WireGuard first — it is the only kind that changes the *shape* of the generator (a second
  tag namespace in `endpoints[]`, an INI parser instead of a URL parser, a DNS server
  detoured through the endpoint). Better to land that structure before three ordinary
  outbounds sit on top of it.
- Shadowsocks second — the simplest outbound there is (server, port, method, password, no
  TLS, no transport), so it validates the whole new-kind plumbing (model → secret key →
  parser → generator → fixtures → plan builder) with the fewest moving parts.
- Trojan third — the first consumer of the refactored TLS/transport helper; if the refactor
  was wrong, this is where it shows, with the VLESS goldens still there to compare against.
- VMess last — same helper, but the fiddliest input (base64 JSON with de-facto field names
  and numeric/string ambiguity), and nothing else depends on it.

Each kind is a self-contained commit (model + parser + generator + fixtures) so the Dart
mirror in 5 can follow kind by kind rather than waiting for all of 3. Stages 4 and 5 are
independent; stage 5 depends only on the fixtures from 3. The parser/generator work has a
crisp fixture-driven definition of done and is a good candidate for delegation; the design
notes, the refactor and the review stay here.
