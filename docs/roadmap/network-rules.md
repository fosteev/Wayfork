# TCP only / UDP only for app and IP rules — F23

> Status: stage 1 approved 2026-10-03; stage 2 (M19 macOS) accepted 2026-10-03; stage 3
> (WM21 Windows) accepted 2026-10-03; next — stage 4 (maintainer: release bits and live checks). Manual checks and open calls: [network-rules.pending.md](network-rules.pending.md). · created 2026-10-03 from issue #3 · macOS M19, Windows WM21
> (WM20 is reserved for the F22 Windows twin).

## Goal

An app or IP rule can be narrowed to TCP only or UDP only, so "Discord → Work" plus
"Discord, UDP only → Not via any tunnel" fixes Discord voice for good instead of one Direct
IP exception per voice server (issue #3).

## Decisions (approved with the plan, 2026-10-03)

- `Rule.network: RuleNetwork?` (`tcp` | `udp`, nil = both), only on `app` and `ip` rules;
  normalized to nil for every other match. Domain rules feed DNS and are not narrowed.
- Narrowed rules go to route-only files `rules-<exit>-tcp.json` / `-udp.json` (and
  `rules-direct-tcp/udp.json`), emitted only when non-empty, with `network` on the route
  rule. Route order: direct both → direct narrowed → block list → narrowed tunnels, then
  narrowed groups (store order, tcp before udp) → tunnels → groups. No narrowed rules →
  byte-identical output.
- Identity for duplicates = pattern + match + network (+ target). Shadowing by rank
  (direct both 0, direct narrowed 1, exit narrowed 2, exit both 3), then section order;
  an earlier rule shadows when its network covers the later one. No "redundant in the same
  section" special case.
- Store schema 3 and `ExportDocument.currentVersion` 3, no-op migrations.
- UI: inline network popup in macOS app/IP rows (C13); *Network* field in the Windows
  *Edit rule* dialog (W20); chip `TCP only` / `UDP only` in rows.
- ctl: macOS `rules add` takes an absolute `.app` path as an app rule and `--network`;
  Windows `explain --network`.
- Design: [01-data-model.md](../design/01-data-model.md) § Network-narrowed rules,
  [03-routing.md](../design/03-routing.md) § Network-narrowed rules,
  [02-ux.md](../design/02-ux.md) (F23 bullet), [09-wayforkctl.md](../design/09-wayforkctl.md),
  [08-windows.md](../design/08-windows.md).

## Stages

### 1. Features, design, boards — opus

- [x] F23 in `docs/ROADMAP.md` Phase 1; boards C13 (`variant-c.html`) and W20
      (`windows.html`); design sections listed above — 2026-10-03
- [x] Approved by the maintainer — 2026-10-03

### 2. macOS — M19 · sonnet, high

- [x] Core: model, schema 3, validator, rule-set + config generator, plan file names
- [x] Golden variant `network-rules`, every other golden's sing-box output unchanged
- [x] App: inline popup, chip, `addRule`/`updateRule`, quick add untouched — builds;
      the app target has no unit tests and the look is not seen yet (user)
- [x] ctl: `.app` paths, `--network`, `network` in `rules` output — usage errors run by
      hand (exit 2); the app side (`controlAddRule`) is compiled, not run (no live app)
- [x] Format, package tests, app build

**Done when:** the prompt's DoD commands pass; plan-review accepted.

**Решения (2026-10-03, по итогам сессии M19):**

- **Files (S = `macos/WayforkCore/Sources`).** `Rule.swift`: `RuleNetwork`, `Rule.network`
  with `didSet` on both `match` and `network` plus `Rule.normalizedNetwork(_:for:)`, so
  initializer, decoder and later mutation all keep nil for domain kinds; `Store` schema 3
  (no-op 2→3), `ExportDocument` 3. `RuleValidator`: `RuleKey` + network (duplicates);
  shadowing rewritten as rank (direct both 0, direct narrowed 1, exit narrowed 2, exit
  both 3) then section; four examples of 01-data-model.md are tests. `RuleSetGenerator`:
  `renderNarrowed(rules:network:)` returns nil when empty, ordinary `render`/`renderIP`
  skip narrowed rules, `directNarrowedTag/FileName`; `RoutedExit.narrowedRuleSetTag/
  FileName`. `SingBoxConfigGenerator`: direct narrowed route rules right after
  `rules-direct`, narrowed exit rules collected in the loops and inserted after the block
  list (tunnels in store order, then groups, tcp before udp). `RuntimePlan.routedIDs`,
  `PlanValidator` (+ `RunLayout.directNarrowedRuleSets`, `ruleSetID`).
  `RuleEditing.normalize` and `QuickAdd.evaluate/isUpdate` take `network` (lookup by
  pattern + network; default nil keeps the popover blind to narrowed rules) and
  `QuickAdd.evaluate` an optional explicit `match`. ctl: `ControlParams.network`,
  `ControlRuleInfo.network`, `RulePattern.inferControlMatch` (absolute path ending `.app`
  → app rule; used by the CLI and the app so both agree), `--network` in help.
  App: `AppModel+Rules` (`addRule(network:)`, `updateRule(network:)` keeps the rule's own
  network unless given, new `setNetwork`), `AppModel+Control.controlAddRule`,
  `RulesSettingsView` (`NetworkPicker`; new IP row carries `RuleEditState.network`).
- **Contract for stage 3.** Golden `fixtures/singbox/network-rules`: files
  `rules-direct-udp.json`, `rules-t-<home>-tcp.json` (process_path_regex object first, then
  ip_cidr object); route order direct, direct-udp, home-tcp, work, home. All 21 older
  `input.json` changed only in `"schemaVersion" : 3` (the golden input embeds the store);
  their `sing-box.json` / rule files are untouched. `sing-box check` 1.13.19 passes on the
  new variant (`singBoxAcceptsGeneratedConfigs` ran with the bundled binary).
- **Deviations / calls the plan left open.**
  - The chip of the board is the popup itself (C13: "Unnarrowed it reads TCP + UDP ...
    narrowed it reads TCP only / UDP only — the chip on the board"), so no separate chip.
    Both the closed label and the menu item read "TCP + UDP" (the board's menu says
    "TCP and UDP"; one title per Picker item).
  - Narrowed IP tunnel rules still carve their range out of `route_exclude_address`
    (same as unnarrowed): otherwise a LAN range would never enter the TUN.
  - `wayforkctl rules remove` has no `--network`; two rules with one pattern are
    already "use an id" in `findRule`. Not in the design, so not added.
  - `--network` with a domain pattern: usage error (exit 2) in the CLI by
    `inferControlMatch`; the app additionally refuses (`badRequest`) after fake-IP
    translation turns an address into a domain pattern.
  - `AppRuleTests.storeSchemaTwo…` renamed `storeKeepsAppRulesAndMigratesFromOne`
    (asserts 3 now). New tests in `NetworkRuleTests.swift`; plan names in
    `PlanningTests`, `TrafficFormatTests`.
- **Not checked.** Look and behaviour of the Rules page popup (user); `controlAddRule` and
  `setNetwork` against a live app; an end-to-end Discord call (stage 4). No design doc was
  edited.

**Ревью (2026-10-03, приёмка M19).** Swift test 199 green, app Debug build OK,
swift-format lint clean; fixture diff is exactly 21 × `schemaVersion` 2 → 3. Rank shadowing,
route order and plan names checked against 03-routing.md. The carve-out of narrowed tunnel
IP rules is right (a LAN range would otherwise never reach the TUN) and is now written down
in 03-routing.md § Network-narrowed rules. An unknown `network` value (`"sctp"`) fails the
rule decode like an unknown `match` does — the store is backed up as corrupt; lenient decoding
to nil was rejected because it would silently widen a narrowed rule to both transports. The
roadmap's "chip in rows" is Windows-only (W20); 02-ux.md already has the macOS popup as the
indicator.
Second pass: `StoreEdit.insertRule` refused a narrowed sibling of a both-networks rule
(`rules add <app> --via direct --network udp` → "another rule exists"; reverting `rules remove`
of such a rule lost it) — the guard now compares `network` too, test in `StoreEditTests`.
`rules` lists in section order, not route order: docs softened (09-wayforkctl.md,
`Store.effectiveRules`, help). Open: a new `wayforkctl rules add --network` against a pre-F23
app gets an unnarrowed rule with exit 0 (reply's `rule.network` is not checked).

### 3. Windows — WM21 · sonnet, high · after stage 2

- [x] Dart model, schema 3, validator, generators, heal merge identity, rule editing
- [x] Dart golden test passes on `network-rules` (generated by stage 2)
- [x] `RuleEditor` *Network* field, row chip — widget-tested; the look is not seen (user)
- [x] Go: plan file names, route rule `network`, `explain --network`
- [x] `dart format`, `dart analyze --fatal-infos`, `flutter test`, `gofmt`, `go vet`,
      `go test ./...`, `GOOS=windows go build ./...`

**Done when:** the prompt's DoD commands pass; plan-review accepted.

**Решения (2026-10-03, по итогам сессии WM21):**

- **Files (A = `windows/app/lib`, S = `windows/service`).** `A/core/model/rule.dart`:
  `RuleNetwork` (+ `fromJson` that throws on an unknown value, `normalized(network, match)`),
  `Rule.network` normalized to null for non-app/ip in the factory, so `copyWith(match: …)`
  clears it too; `copyWith` uses the `_unset` sentinel. `store.dart` schema 3 with a no-op
  2→3 migration, `export_document.dart` 3. `tunnel_group.dart`: `RoutedExit.narrowedRuleSetTag/
  FileName`. `rules/rule_validator.dart`: `_RuleKey` + network, shadowing as the Swift rank
  (`_Candidate`). `rules/versioned_app_path.dart`: heal merge identity = (target, key, network).
  `app/rule_editing.dart`: `normalize`, `QuickAdd.evaluate/isUpdate` take `network` (default
  null, so the tray never touches a narrowed rule). `singbox/rule_set_generator.dart`:
  `renderNarrowed` (null when empty), plain `render`/`renderIP` skip narrowed rules,
  `directNarrowedTag/FileName`. `singbox/sing_box_config_generator.dart`: direct narrowed
  route rules right after `rules-direct`, narrowed exit rules collected in the loops and
  inserted after the block list. `app/model/app_model_rules.dart`: `addRule(network:)`,
  `updateRule(network:)` (omitted = keep the rule's own). `app/ui/pages/rules_page.dart`:
  Network field in `RuleEditor`, chip in `_chips`.
  S: `internal/core/layout.go` (`DirectTCPRuleSet/DirectUDPRuleSet`), `validate.go`
  (accepts `rules-t-/g-<id>-tcp/-udp.json` and the two direct names, `RuleSetID` strips the
  suffix, `isRouteOnlyRuleSet`), `planjson.go` (`routedIDs` skips the twins,
  `ExplainRule.Network`), `explain.go` (`ExplainQuery.Network`, `coversNetwork`,
  `ExplainBoth`, `CombineExplain`), `ipc/server.go` (rejects a network other than tcp/udp),
  `cmd/wayforkctl/main.go` (`explain --network`, plan builder accepts the new names).
- **Contract.** Dart output equals the Swift golden byte for byte: the existing golden test
  runs `network-rules` and all 21 older variants unchanged; a Dart `network-rules` variant in
  `_configVariants` reproduces `input.json` (constructed-input test). The Windows-platform
  path regex is used for app rules in narrowed files (`platform.appPathRegex`, like the plain
  files). `explain` without `--network`: the CLI asks the service twice (tcp, udp) and prints
  `{"tcp": …, "udp": …}` only when the answers differ; a query with an empty network over the
  pipe skips no rule (so the service stays usable by older clients).
- **Deviations / calls the plan left open.**
  - The app rule row had no edit mode (double-tap and the menu's *Edit* were for non-app rules
    only), so the Network field of an app rule had nowhere to live. App rows now get *Edit*
    (menu and double-tap) opening `RuleEditor` with `lockPattern`: the path is a read-only
    field, the match a label, only the network is editable. A read-only field opens no input
    connection, so Enter is bound with `CallbackShortcuts` (on the field, after review);
    after picking a network the pattern field is re-focused so Enter still commits. This changes user-visible behaviour
    of app rows (new *Edit* item), see "Скоуп" in the report.
  - 08-windows.md says "Edit rule dialog"; the code has an inline `RuleEditor` row, so the
    field is in that row (shown while the match is app or IP), not in a dialog.
  - The Network combo uses a private non-null enum (`_NetworkChoice`): a fluent `ComboBox`
    reads a null value as "no selection".
  - Narrowed IP tunnel rules still carve `route_exclude_address` (no code change: the carve
    loop never looked at the network), as 03-routing.md says.
  - Validation error text for a bad rule-set name now lists the `-tcp`/`-udp` names; the
    leading `rules-t-<id>.json` is kept (tests match on it).
- **Not checked.** The look of the row chip, the editor field and the app *Edit* flow in the
  real window (user); `explain --network` against a running service (VM/PC, user); an
  end-to-end Discord call (stage 4). No design doc was edited.

**Ревью (2026-10-03, приёмка WM21).** flutter test 388 green (one test added: export v2
decodes, v4 refused, store 2 → 3), dart format/analyze clean; gofmt/go vet/go test/
`GOOS=windows go build` OK; `git diff macos fixtures` empty. Route and rule-set order, rank
shadowing, network normalization, heal merge identity and every Dart duplicate check
(`RuleEditing.normalize` incl. the versioned-key branch, `QuickAdd`, import merges by id,
`moveRule` has no check as before) match Swift. Go: `IsTunnelID` is a 36-char UUID, so the
`-ip`/`-tcp`/`-udp` suffix strip cannot eat an ID; a request without `network` (old client)
skips no rule, an old service ignores the field. Second pass (opus): the row-level Enter
binding of a locked app editor swallowed Enter on the focused Network combo (it submitted
instead of opening) — Enter (and numpad Enter) is now bound on the path field only. Not
fixed, noted: *Edit* on a foreign macOS app rule kept by import fails on Enter with "not an
application" (Esc works; the rule never matches on Windows anyway); `ExportDocument.decode`
parses before the version check, so a future v4 file with an unknown `network` reads as a
format error, not "newer version" (pre-existing order). Docs: 08-windows.md F23 bullet and
the W20 note now describe the inline editor and the app *Edit*, not a dialog.

### 4. Release bits and live checks — maintainer

- [ ] CHANGELOG, README rules paragraph
- [ ] macOS: `Discord → Work` + `Discord, UDP only → Not via any tunnel`, a voice call
      connects; `wayforkctl logs --grep discord` shows UDP direct
- [ ] Windows: the same on `ssh wf-pc`; `wayforkctl connections --process discord` shows
      UDP flows with `exit=direct` and replies; close issue #3

## Session prompts

### Stage 2 — M19 macOS

```
Сессия M19 — F23 TCP only / UDP only, macOS · Модель: sonnet, effort: high · после одобрения этапа 1

Работаем в /Users/fost/Projects/Wayfork. Задача: поле Rule.network (tcp|udp|nil) для app- и IP-правил на macOS — модель, генератор sing-box, валидатор, UI, wayforkctl. Стройка с нуля по готовому дизайну.

Читай: docs/roadmap/network-rules.md (этот файл, разделы Decisions и Stages); docs/design/03-routing.md § "Network-narrowed rules (F23)"; docs/design/01-data-model.md § "Network-narrowed rules (F23)"; docs/design/02-ux.md (буллет F23 в разделе Rules); docs/design/09-wayforkctl.md (F23 у rules add). Правила репо: CLAUDE.md. Доска UI: docs/design/prototype/variant-c.html#C13.
Точки входа и эталоны проверены при планировании — не перечитывать их ради подтверждения, открывать только фрагмент, который правишь.

Точки входа (S = macos/WayforkCore/Sources):
- S/WayforkCore/Model/Rule.swift — struct Rule, CodingKeys :111, init(from:) :117, encode :143 (note через encodeIfPresent — эталон для network). Добавить `public enum RuleNetwork: String, Codable, CaseIterable { case tcp, udp }` и `network: RuleNetwork?`; нормализация в init и в decoder: network = nil, если match не .app/.ip.
- S/WayforkCore/Model/Store.swift:9 currentSchemaVersion 2→3; :201 migrations — добавить no-op 2→3 по образцу 1→2.
- S/WayforkCore/Model/ExportDocument.swift:78 currentVersion 2→3 (обновить комментарий).
- S/WayforkCore/Rules/RuleValidator.swift: RuleKey :181 + network; дубли (:51) по ключу с network; затенение (:64) — переписать на ранг: direct&nil=0, direct&narrowed=1, exit&narrowed=2, exit&nil=3, затем groupOrder; E затеняет R, если тот же pattern+match, (E.network == nil || E.network == R.network) и (rankE, groupE) < (rankR, groupR). activeRulesInOrder :167 не меняется по смыслу.
- S/WayforkCore/SingBox/RuleSetGenerator.swift: generate :25/:33, renderIP :51, render :75. Добавить рендер узкого файла: объект process_path_regex (как у app) и объект ip_cidr (как renderIP, с вычитанием reserved), каждый только если не пуст. Узкие правила НЕ попадают в обычные файлы. Имена: "<ruleSetTag>-tcp/-udp", "rules-direct-tcp/-udp" (константы рядом с directIPTag :12).
- S/WayforkCore/SingBox/SingBoxConfigGenerator.swift: direct-правило :202 — сразу после него route-правила для rules-direct-tcp/udp с "network": ["tcp"]/["udp"]; блок-лист :212; перед первым туннельным route-правилом (~:267) — узкие правила туннелей в порядке store, затем групп (~:300), tcp перед udp; у каждого route.rule_set — localRuleSet(tag:path:) как :206. Файлы и правила — только для непустых наборов.
- Имена файлов в плане: S/WayforkCore/XPC/RuntimePlan.swift:68 routedIDs (исключать -tcp.json/-udp.json как -ip.json); S/WayforkDaemonCore/PlanValidator.swift:20-27 (принять rules-direct-tcp/udp.json, текст ошибки) и ruleSetID :103 (срезать -tcp/-udp как -ip); S/WayforkDaemonCore/RunLayout.swift (константы direct tcp/udp рядом с directIPRuleSet; isRuleSet :37 — проверить, что очистка старых файлов покрывает новые имена).
- S/WayforkCore/App/RuleEditing.swift:66 QuickAdd.evaluate — искать существующее правило по pattern И network == nil (новый параметр network: RuleNetwork? = nil; при non-nil — поиск по pattern+network, создание с network). isUpdate :86 — так же.
- ctl: S/wayforkctl/Commands.swift:219 rulesRequest — valued + "--network" (tcp|udp, иначе Usage), help-текст и блок "For assistants"; S/WayforkCore/Control/ControlProtocol.swift:31 ControlParams + network, :164 ControlRuleInfo + network (encodeIfPresent); macos/App/Model/AppModel+Control.swift:178 controlAddRule — абсолютный путь на ".app" (без учёта регистра) → match .app через RulePattern.normalize(…, match: .app); --network с доменным паттерном → ошибка usage (exit 2); controlRules :169 — отдавать network.
- App: macos/App/Model/AppModel+Rules.swift:34 addRule / :54 updateRule — параметр network; новый метод setNetwork(id:network:). macos/App/Views/Settings/RulesSettingsView.swift: RuleRowView :377 — для .app и .ip второй Picker (стиль как Match :424/:437) с вариантами "TCP + UDP" (nil, вторичный цвет), "TCP only", "UDP only", .help("UDP carries calls, voice and games; TCP carries everything else."); NewRuleRow :577 — тот же Picker, когда match == .ip; смена match на доменный — network = nil (это делает нормализация Rule).
- Тесты: macos/WayforkCore/Tests/WayforkCoreTests/SingBoxGeneratorTests.swift:639 configVariants — новый вариант "network-rules" по образцу "app-rules" :688 / "ip-rules" :695, два туннеля A (первый) и B: Discord app nil → A; Discord app udp → direct; Discord app udp → B (затенён direct-udp → в вывод не попадает); Slack app tcp → B (попадает в rules-t-B-tcp и бьёт A по порядку); IP 203.0.113.0/24 tcp → B; IP 198.51.100.0/24 nil → A. Ожидаемо: rules-direct-udp.json, rules-t-<B>-tcp.json, route-правила в порядке из 03-routing.md. Юнит-тесты: RuleTests (codable, нормализация network для домена), ModelTests/StoreAndSecretsTests (schema 3, миграция 2→3, отказ на 4), валидатор (все четыре примера затенения из 01-data-model.md), RuleSetGenerator (узкие файлы, пустые не создаются), QuickAdd, ControlTests (--network, .app), PlanValidator (новые имена).

Уже решено, не переспрашивать: всё из раздела Decisions файла network-rules.md; network только у app/ip; route-level network, отдельные файлы только при непустых наборах; schema 3 и export 3; popover quick add и Recent не трогают узкие правила; "redundant" случая нет.

Порядок:
1. Модель + schema/export 3 + тесты модели.
2. Валидатор (ключ, ранг) + тесты.
3. RuleSetGenerator + SingBoxConfigGenerator + имена в RuntimePlan/PlanValidator/RunLayout + тесты.
4. Golden: добавить вариант, `WAYFORK_UPDATE_GOLDEN=1 swift test --package-path macos/WayforkCore --filter SingBoxGeneratorTests`, затем `git diff --stat fixtures/` — в старых вариантах может поменяться только строка "schemaVersion" в input.json; любое изменение sing-box.json или rules-*.json старых вариантов — ошибка, чинить генератор. Проверить новый вариант `sing-box check` (TrafficTests/скрипт, как для ip-rules) на 1.13.19.
5. QuickAdd + ctl + тесты.
6. App UI.
7. swift-format по репо `.swift-format`.
Галочки в docs/roadmap/network-rules.md (stage 2) — по факту проверки.

DoD: все пункты stage 2 отмечены. Проверка: `swift test --package-path macos/WayforkCore > $SCRATCH/t.log 2>&1; tail -30 $SCRATCH/t.log` зелёный (если пакетные тесты требуют xcodebuild — запускать из каталога пакета, см. memory/CLAUDE.md); `xcodebuild` сборка приложения (схема Wayfork, Debug) без ошибок; `git diff --stat fixtures/singbox` — только новый каталог network-rules и строки schemaVersion. Длинный вывод — в лог, в контекст только tail/grep.

Не делать: Windows-код (windows/) — отдельный этап; доки дизайна не переписывать (отклонение — в отчёт); не перезапускать, не устанавливать и не выключать Wayfork; не трогать незакоммиченные файлы windows/app/lib/core/rules/versioned_app_path.dart, app_model.dart, их тесты и docs/*; «заодно улучшить» — нет. Вопрос без ответа в промте — в отчёт, не додумывать.

Не коммитить, не пушить — это сделает приёмка.
Последним сообщением — отчёт: сделано (файлы) / отклонения от плана / не проверено / открытые вопросы. Отчёт — единственное, что увидит приёмка: без него работа потеряна.
```

### Stage 3 — WM21 Windows

```
Сессия WM21 — F23 TCP only / UDP only, Windows · Модель: sonnet, effort: high · после M19 (golden network-rules уже сгенерирован)

Работаем в /Users/fost/Projects/Wayfork. Задача: двойник M19 на Windows — Dart-модель/генератор/UI и Go-сервис (имена файлов плана, explain --network). Поведение и вывод генератора побайтно как у Swift.

Читай: docs/roadmap/network-rules.md (Decisions, stage 3); docs/design/03-routing.md § "Network-narrowed rules (F23)"; docs/design/08-windows.md (буллет F23); docs/design/09-wayforkctl.md (F23 у explain). Swift-реализация M19 — эталон: macos/WayforkCore/Sources/WayforkCore/Model/Rule.swift, Rules/RuleValidator.swift, SingBox/RuleSetGenerator.swift, SingBox/SingBoxConfigGenerator.swift (git diff последнего коммита M19). Правила репо: CLAUDE.md. Доска: docs/design/prototype/windows.html#W20.
Точки входа и эталоны проверены при планировании — не перечитывать их ради подтверждения, открывать только фрагмент, который правишь.

Точки входа (W = windows/app/lib, G = windows/service):
- W/core/model/rule.dart — Rule (factory, fromJson, toJson, copyWith с _unset-сентинелом как у note, ==, hashCode) + enum RuleNetwork; нормализация network=null для не app/ip.
- W/core/model/store.dart:45 currentSchemaVersion 2→3, :345 migrations no-op 2→3. W/core/model/export_document.dart:292 currentVersion 2→3.
- W/core/rules/rule_validator.dart: _RuleKey :286 + network; дубли и затенение (:161) — ранг как в Swift.
- W/core/singbox/rule_set_generator.dart: generateForExits :46, renderIP :66, _render :104 — узкие файлы; W/core/singbox/sing_box_config_generator.dart: direct-правило :293, затем узкие direct, блок-лист, узкие туннели/группы перед туннельными правилами (~:391/:429).
- W/core/rules/versioned_app_path.dart — _mergeDuplicates: identity = (target, key(pattern), network); тест "keeps tcp and udp rules for one app apart".
- W/core/app/rule_editing.dart: проверка дублей (~:107) — + network; quickAdd (~:217/:222) — поиск только среди network == null.
- W/app/model/app_model_rules.dart:47 addRule, :79 updateRule — параметр network.
- W/app/ui/pages/rules_page.dart: RuleEditor :814 — поле "Network" (ComboBox fluent_ui: "TCP and UDP" / "TCP only" / "UDP only") только при match app/ip, onSubmit несёт network; _RuleRow :481 — чип "TCP only"/"UDP only" после метки match.
- G/internal/core/validate.go:36-42 (имена rules-direct-tcp/udp.json) и RuleSetID :125 (срезать -tcp/-udp); G/internal/core/layout.go:33 константы; G/internal/core/planjson.go:19 routedIDs (исключать -tcp/-udp), ExplainRule :141 + Network []string, RouteRules :148 читает "network".
- G/internal/core/explain.go:6 ExplainQuery + Network ("tcp"|"udp"|""), Explain :62 — правило с Network не совпадает с запросом другой сети; при пустом Network в CLI — два прогона, если ответы различаются, печатать {"tcp":…, "udp":…}. G/cmd/wayforkctl/main.go:285 explain — флаг --network.
- Тесты: rule_set_generator_test, sing_box_config_generator_test (golden :396 подхватит network-rules сам), rule_validator_test, rule_editing_test, versioned_app_path_test, rules_page_test; Go: explain_test.go, validate/planjson тесты.

По реальному коду (приёмка M19, 2026-10-03):
- Golden `fixtures/singbox/network-rules`: route rules — direct (+ direct-ip), direct-udp (network udp), t-<B>-tcp (network tcp), затем обычные A, B. Порядок определений в `route.rule_set`: rules-direct, rules-direct-ip, rules-direct-tcp/udp (только непустые), [блок-лист], затем на каждый exit подряд: `<tag>`, `<tag>-ip`, `<tag>-tcp`, `<tag>-udp` (узкие — только непустые), туннели, потом группы. Узкие route-правила при этом стоят единым блоком после блок-листа.
- Узкий файл: сначала объект `process_path_regex`, потом `ip_cidr` (с вычитанием reserved), каждый только если не пуст; обычные `<tag>.json` / `-ip.json` узкие правила пропускают.
- Узкие IP-правила туннелей карвят `route_exclude_address` так же, как обычные (03-routing.md § Network-narrowed rules, абзац Carve-out) — в Dart carve (`sing_box_config_generator.dart` ~:444) по `network` не фильтровать.
- Swift: затенение — ранг (direct both 0, direct narrowed 1, exit narrowed 2, exit both 3), затем порядок секций (туннели, потом группы); E затеняет R при `E.network == nil || E.network == R.network`. Дубли — по pattern+match+network+target. Неизвестное значение `network` в JSON — ошибка декодирования, как неизвестный `match`.
- QuickAdd ищет существующее правило по pattern И network (по умолчанию nil); `RuleEditing.normalize` проверяет дубли с network.

Уже решено, не переспрашивать: всё из Decisions; вывод Dart-генератора побайтно равен golden от Swift (golden `input.json` теперь с `schemaVersion` 3 у всех вариантов — Dart-тест должен принимать его; решения M19 — в конце раздела этапа 2); Windows `rules add` не появляется.

Порядок:
1. Модель + schema/export 3 + тесты.
2. Валидатор, rule_editing, heal merge + тесты.
3. Генераторы до зелёного golden network-rules и всех старых.
4. UI.
5. Go: имена, network в route rules, explain --network + тесты.
Галочки в docs/roadmap/network-rules.md (stage 3) — по факту проверки.

DoD: все пункты stage 3 отмечены. Проверка (вывод в $SCRATCH-логи, в контекст tail/grep): в windows/app — `dart format .`, `dart analyze --fatal-infos`, `flutter test`; в windows/service — `gofmt -l .` пусто, `go vet ./...`, `go test ./...`, `GOOS=windows go build ./...`.

Не делать: macOS-код и фикстуры не менять (расхождение с golden — чинить Dart; если golden неверен — в отчёт); доки дизайна не переписывать; не трогать ssh wf-win/wf-pc; не перезапускать Wayfork; «заодно улучшить» — нет. Вопрос без ответа — в отчёт.

Не коммитить, не пушить — это сделает приёмка.
Последним сообщением — отчёт: сделано (файлы) / отклонения от плана / не проверено / открытые вопросы. Отчёт — единственное, что увидит приёмка: без него работа потеряна.
```

## Risks and open questions

- sing-box 1.13.19 must accept `network` on a route rule next to `rule_set` (documented;
  the golden's `sing-box check` in M19 confirms).
- The heal duplicate merge (uncommitted, 2026-10-03) uses target + key; WM21 adds network.
  Until then two narrowed rules for one app cannot exist on Windows anyway (no UI).
- Pre-existing, not F23: group IP rules are never carved out of `route_exclude_address`
  (`SingBoxConfigGenerator` carves routed tunnels only), so a group IP rule inside a LAN
  range never reaches the TUN.
- Windows `connections` labels from `dns.reverse_mapping` (issue #3, "Also noticed") are
  not part of F23.
