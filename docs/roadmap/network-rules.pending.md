# F23 — decisions to confirm and manual checks

## Решения на подтверждение

- [скоуп] этап 3: app-правила на Windows получили *Edit* (пункт меню и двойной клик) — раньше
  они не редактировались вовсе, а полю *Network* (W20) иначе негде жить; редактор инлайн
  (`RuleEditor`, путь read-only, match подписью), а не диалог, как на доске W20 — диалога
  *Edit rule* на Windows нет — откат: в `rules_page.dart` вернуть `onDoubleTap: rule.isApp ?
  null : …` и `else` перед пунктом *Edit* меню; сеть app-правила тогда задаётся только
  при создании (а app-правила создаются без редактора — т.е. никак).

## Проверить руками

- Этап 2 (M19), Settings → Rules, строка app-правила (например Discord): после метки «App»
  стоит попап «TCP + UDP» серым; выбрать «UDP only» — подпись становится «UDP only» обычным
  цветом, наведение показывает «UDP carries calls, voice and games; TCP carries everything
  else.»; колонки строк с попапом и без не разъезжаются.
- Этап 2, Rules, строка IP-правила: попап после попапа Match; сменить Match на Suffix —
  попап сети пропадает, после возврата на IP правило снова «TCP + UDP». Во время правки
  текста IP-строки попап сети скрыт — убедиться, что это не мешает.
- Этап 2, Rules, новая строка в секции туннеля: ввести `203.0.113.0/24` — появляется попап
  сети; выбрать «TCP only», Enter — правило создано узким. Ввести домен — попапа нет.
- Этап 2, Rules: `Discord → Work` и рядом в Direct `Discord, UDP only` — ни одного
  «shadowed»; второе `Discord, UDP only` в другом туннеле — помечено shadowed. Две копии
  `Discord, UDP only` в одной секции — duplicate; попытка поставить второй строке ту же сеть
  через попап — ошибка «уже есть».
- Этап 2, popover quick add: добавить `203.0.113.0/24` при существующем узком правиле на
  тот же адрес — появляется новое правило без сети, узкое не тронуто (кнопка читает «Add»).
- Этап 2, после установки сборки: `wayforkctl rules add /Applications/Discord.app --via
  direct --network udp` → правило добавлено рядом с `Discord → Work`; `wayforkctl rules`
  показывает `"network": "udp"`; без `confirm` через 60 с правило исчезает, `Discord → Work`
  на месте. `wayforkctl rules add example.com --via direct --network udp` → exit 2.
- Этап 3 (WM21, Windows, после следующего релиза; `ssh wf-pc` или VM), Rules: строка
  app-правила с сетью — после метки «the app» чип «UDP only»/«TCP only», наведение —
  «Only UDP traffic of this app is matched»; у правила без сети чипа нет.
- Этап 3, Rules, app-правило: правый клик → *Edit* (и двойной клик) — строка становится
  редактором: путь серым только для чтения, «the app» подписью, рядом комбо «TCP and UDP /
  TCP only / UDP only» с подсказкой «UDP carries calls…». Выбрать «UDP only», Enter —
  правило сохранено, чип «UDP only»; Esc — без изменений. Tab на комбо + Enter — комбо
  открывается, а не сохраняет. Путь versioned-приложения (Discord `app-1.0.x`) после
  сохранения тот же.
- Этап 3, Rules, новая строка в секции туннеля: ввести `203.0.113.0/24` — появляется комбо
  сети; «TCP only», Enter — правило узкое. Ввести домен — комбо нет. Сменить Match IP на
  Suffix — комбо пропадает, сеть сбрасывается.
- Этап 3, Rules: `Discord → Work` + `Discord, UDP only` в «Not via any tunnel» — ни одного
  shadowed; второе `Discord, UDP only` в другом туннеле — shadowed; две одинаковые узкие
  строки в одной секции — duplicate, попытка выставить второй строке ту же сеть — ошибка.
- Этап 3, после установки: `wayforkctl.exe explain --process <путь Discord.exe>` — при
  правилах выше печатает `{"tcp": …, "udp": …}` (tcp → Work, udp → direct);
  `--network udp` — один ответ с direct первым; `--network sctp` — ошибка «must be tcp or
  udp»; для процесса без узких правил — привычная форма без tcp/udp.
