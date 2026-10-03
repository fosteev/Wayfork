# F23 — decisions to confirm and manual checks

## Решения на подтверждение

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
