# Shared test fixtures

Inputs and golden outputs used by the Swift tests (`Wayfork/WayforkCore/Tests`), the Dart
tests (`WayforkWindows/app`) and the Go tests (`WayforkWindows/service`). Every client must
produce or accept exactly what is recorded here; a change to a golden file is a deliberate,
reviewed change to the product.

| Path | What | Producer / consumers |
|------|------|----------------------|
| `singbox/<variant>/input.json` | Generator input: `store` (the `store.json` v2 document), `vlessUUIDs` (tunnel id → UUID), `openVPNBinaryPath`, `resolvedServerAddresses`, `systemDNSServers`, `networkResolvers` | Written by `SingBoxGeneratorTests.generatedConfigMatchesGoldenFiles` in update mode; replayed by the Dart generator tests |
| `singbox/<variant>/sing-box.json`, `rules-*.json` | Expected `sing-box.json` and rule-set files for that input, byte for byte | Same test, plus `sing-box check` runs on macOS (`TrafficTests`) and Windows |
| `ovpn/*.ovpn`, `*.expected.ovpn` | OpenVPN profile importer samples (placeholder keys only) | `OpenVPNConfigParserTests`, Dart parser tests |
| `vless/links.json` | VLESS links every client accepts (with the parse result) or rejects | `VLESSURIParserTests`, Dart parser tests |
| `clash/connections.json` | A `GET /connections` sample from sing-box's Clash API | `TrafficTests`, `RuleSetSelectorsTests`, Go traffic tests |

Regenerating the recorded results after an intentional change:

```sh
WAYFORK_UPDATE_GOLDEN=1 swift test --package-path Wayfork/WayforkCore
```

then review the diff. Rule ids in `input.json` are renumbered (`…-0000000001NN`) because
they never reach the output; `openVPNBinaryPath` is the macOS bundle path and appears
verbatim in `sing-box.json` — the Windows generator substitutes its own path and the Dart
golden test compares with that substitution applied. Never put real servers, UUIDs or keys
here: `<SERVER>`-style placeholders and the reserved test UUIDs
(`00000000-0000-4000-8000-0000000000NN`) only.
