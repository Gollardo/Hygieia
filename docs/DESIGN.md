# UX/UI-гипотеза Hygieia

Статус: рабочая продуктовая гипотеза и behavior contract. Принятая visual direction и component tokens описаны отдельно в [`DESIGN_SYSTEM.md`](DESIGN_SYSTEM.md).

M2 реализовал ограниченный slice: выбор локального scan root, progress/cancel и bounded list с details. M3 добавляет реализованный в коде Sunburst/navigation slice; точные UX/engineering rules находятся в [`M3_SUNBURST_MVP.md`](M3_SUNBURST_MVP.md). M5 добавляет локальные volumes и Scan This Mac с явным выбором roots, FDA help и ограниченным coverage; persistent access отсутствует. Lustral Field является presentation transform поверх того же bounded pipeline, а не второй layout truth. Apple Silicon/VoiceOver/Instruments acceptance остаётся отдельным manual gate.

## 1. Продуктовая цель

Hygieia помогает человеку быстро ответить на три вопроса:

1. что занимает место в выбранной области Mac;
2. где находится крупный объект и из чего состоит каталог;
3. какое безопасное действие можно сделать прямо сейчас.

Основной desktop layout:

```text
┌─────────────────────────────────────────────────────────────┐
│ Toolbar / Breadcrumbs                                      │
├───────────────┬───────────────────────────┬─────────────────┤
│               │                           │                 │
│ Sidebar /     │                           │ File / folder   │
│ hierarchy     │         Sunburst          │ details         │
│               │                           │                 │
│               │                           │                 │
├───────────────┴───────────────────────────┴─────────────────┤
│ Scan status / progress                                    │
└─────────────────────────────────────────────────────────────┘
```

Панели могут сворачиваться при малой ширине. Sunburst остаётся главным пространством исследования, но список/иерархия не должен быть вторичным по доступности.

## 2. Основные сценарии

- выбрать конкретную папку и найти крупнейшие вложенные объекты;
- выбрать локальный volume и увидеть распределение занятого места;
- запустить Whole Mac scan, понять ограничения доступа и coverage;
- перейти от крупного сектора к его содержимому, затем вернуться вверх;
- синхронно увидеть объект в дереве, диаграмме и details panel;
- открыть объект в Finder;
- переместить объект в корзину с понятным подтверждением;
- отменить долгий scan и сохранить понятный partial/cancelled state.

## 3. Первый запуск и empty state

Первый экран не должен сразу требовать Full Disk Access. Он объясняет ценность и предлагает два работающих entry points:

- локальные disks/volumes — основной список источников;
- **Choose a Folder…** — точное ограничение scan root.

Выбор volume открывает системную панель в его root. Выбор подтверждается штатной кнопкой панели; Cancel никогда не запускает scan. **Scan This Mac…** в toolbar открывает checklist локальных roots и помощь по FDA согласно [M5_WHOLE_MAC.md](M5_WHOLE_MAC.md).

Empty state содержит короткое описание, последнюю доступную область только если она безопасно доступна, и явную кнопку выбора. Нельзя показывать пустую Sunburst как ошибку или автоматически начинать тяжёлый scan.

## 4. Выбор folder, volume и Whole Mac

Локальные volumes перечисляются через platform adapter, но scan authority всегда подтверждается системным open panel. Перед стартом пользователь подтверждает disk/root либо конкретный каталог штатной кнопкой панели. UI не восстанавливает authority из строкового path и не пересекает mount boundaries по неявному предположению.

Whole Mac — не синоним «гарантированно прочитать всё». Flow должен:

1. кратко объяснить Full Disk Access и зачем он нужен;
2. показать кнопку открытия соответствующего System Settings pane, когда это возможно;
3. дать повторно проверить доступ или продолжить ограниченный scan;
4. после scan явно показывать пропущенные области/coverage.

Запрос доступа не маскируется под системную необходимость и не блокирует обычный folder scan.

### M5 Whole Mac UX

Внутренние non-removable roots отмечены по умолчанию; внешние — opt-in. Каждый root
требует собственного системного подтверждения. Ошибка/отмена/другая папка остаются
видимыми outcomes. Общая сумма не показывается; APFS System/Data и shared storage
не складываются. **Rescan in Explorer** создаёт свежий single-root snapshot.
FDA status — **not verified**, Settings/manual route и limited access доступны всегда.
Stop прекращает очередь; ожидающий OS call назван явно, интерфейс не блокируется.
Новый экран использует существующие panel/palette/typography без новых animations.

### M5a coverage UX

Disk capacity использует reported available capacity; неизвестные или противоречивые
значения показываются как **Capacity unavailable**, без нулевого progress bar.
Ошибка discovery отличается от пустого списка; **Refresh Disk List** доступен рядом
с источниками, folder selection остаётся доступным.

Завершение обхода подписывается **Scan finished**, при неполном покрытии — **Coverage
incomplete**. Cancelled, stale и source unavailable имеют отдельные текстовые статусы
и warning icon. Источник, исчезнувший или изменившийся к концу scan, оставляет
просматриваемый incomplete snapshot; Trash для него недоступен. Rescan не принимает
новый inode по прежнему пути: требуется повторный явный выбор.

**Scope & Coverage** открывает scrollable report: исходный root (не drill-down root),
device evidence, начало/конец scan, no-follow/same-device policy, категории issues и
не более 20 retained примеров. Доступ к неувиденным данным и процент покрытия не
выдумываются; permission denied не трактуется как доказанный FDA status.

## 5. Состояния scan

Feature state должен различать:

- `idle` — область ещё не выбрана;
- `preparing` — проверка root/options/доступа;
- `scanning` — поступают progress и partial results;
- `cancelling` — cancel принят, активные операции завершаются;
- `completed` — согласованный snapshot готов;
- `cancelled` — scan остановлен, partial result может быть доступен и помечен;
- `failed` — terminal error;
- `completedWithIssues` — результат пригоден, но coverage неполный.

Progress не должен притворяться процентом, если total заранее неизвестен. Показываются scanned items, завершённые и ожидающие каталоги, reported bytes, elapsed time и indeterminate indicator. После короткой стабильной выборки допустим приблизительный диапазон оставшегося времени по скорости сокращения уже обнаруженной directory queue; при росте queue оценка снова скрывается. Частота UI updates ограничивается, чтобы scan не замедлялся.

## 6. Progressive scan

Полная продуктовая гипотеза допускает progressive structure, но M2 следует принятому M1 ownership contract: во время scan показывает coalesced progress, а согласованный `FileTree` — только после complete/cancel. Cancelled result может быть показан как clearly incomplete partial snapshot. Live tree checkpoints требуют отдельного решения без COW-копирования миллионов nodes.

Пользователь может увидеть top-level partial structure до полного завершения, если она внутренне согласована. Обязательные правила:

- пометка «Scanning» остаётся заметной;
- размеры ещё изменяющихся каталогов визуально/текстово обозначаются как provisional;
- сортировка и sectors не должны хаотично анимироваться на каждый file event;
- updates объединяются в стабильные порции;
- destructive actions на provisional/stale path могут быть временно недоступны;
- completion мягко фиксирует финальный layout без полной смены контекста.

## 7. Sunburst interaction

Центр диаграммы представляет текущий visual root. В текущей Explorer composition единственное кольцо показывает только его direct children; угол/площадь — выбранную size metric. Вложенность раскрывается явным drill-down, а click по центру возвращает Up, когда parent доступен.

### Hover

Hover подсвечивает сектор без изменения selection и показывает компактный tooltip: имя, тип, formatted size, доля от visible root и состояние `Other`, если применимо. Tooltip не закрывает pointer target и не является единственным источником информации.

### Selection

Одиночный click выбирает реальный node. Выбор синхронизирует sidebar и details panel. Selection сохраняется при допустимом relayout и сбрасывается/переносится осознанно при смене snapshot.

Virtual `Other` можно выбрать для объяснения агрегации, но к нему нельзя применять Finder/Trash как к реальному файлу.

В M3 `Other` нельзя drill-down: это leaf-представление нескольких direct siblings без единой filesystem identity. Details сообщает parent, aggregated count и total; отдельный browsable список `Other` остаётся вопросом будущего UX.

### Drill-down и navigation

Одиночный click немедленно выбирает hit-tested sector и не ждёт окончания double-click interval. Второй близкий click в пределах системного double-click interval macOS, Enter или явное действие **Open in Chart** делает каталог новым visual root без rescan. Double click использует hit result второго клика, а не ранее выбранный сектор. Back/Forward следуют истории visual roots; Up переходит к structural parent и создаёт новую history entry. Это разные операции.

Breadcrumbs показывают путь от scan root до visual root, сокращая середину при нехватке места. Каждый доступный ancestor кликабелен. Полный filesystem path доступен в details/copy action, но не обязан целиком помещаться в toolbar.

## 8. Синхронизация hierarchy и диаграммы

Sidebar/hierarchy и Sunburst — два представления одного `FileTree`:

- selection единый;
- hover может быть локальным и не должен постоянно прокручивать sidebar;
- click в sidebar выбирает соответствующий sector, если он видим;
- если node скрыт внутри `Other` или глубже projection budget, диаграмма подсвечивает ближайшего представленного ancestor и объясняет агрегацию;
- drill-down в любом представлении обновляет breadcrumbs и оба представления;
- сортировка списка не меняет source tree.

Sidebar может переключаться между hierarchy и «Largest» projection, не создавая второй источник истины.

## 9. Details panel

Для реального node отображаются:

- имя и kind;
- logical size и allocated size с ясными labels;
- доля от текущего visual root;
- количество descendants, если вычислено;
- путь с Copy Path;
- modified date и дополнительные metadata только при наличии надёжных данных;
- scan/permission warnings, относящиеся к subtree;
- действия **Show in Finder** и **Move to Trash**.

Нельзя показывать allocated как точное «будет освобождено», особенно для clones/shared blocks. Отсутствующее или provisional значение отображается явно, а не как ноль.

Для `Other` panel объясняет: сколько объектов агрегировано, общий размер и почему отдельные sectors скрыты.

## 10. Finder и Trash

**Show in Finder** доступно только для существующего реального node. Если объект исчез, UI предлагает обновить subtree/scan и сохраняет понятную ошибку.

Show in Finder доступно и для scan root, symlink/package/hard-link member. Оно валидирует live identity, но не требует confirmation и не запускает rescan. `Other` не является filesystem object.

**Move to Trash** — единственное удаляющее действие первой версии. Перед выполнением confirmation показывает:

- точное имя и понятный путь;
- file/folder kind;
- известный размер с правильной metric label;
- формулировку «переместить в корзину», без слова «удалить навсегда».

В M4 действие запрещено для scan root, current visual root, virtual `Other`, stale/partial result, incomplete/inaccessible/volume-boundary subtree и уже отсутствующего/изменённого объекта. Symbolic link перемещается как link, target не затрагивается; package и hard-link member получают отдельное предупреждение.

После system-confirmed успеха показывается статус **Moved to Trash — refreshing scan**. Старое дерево не мутируется и не пересчитывает totals: moved subtree явно dimmed/invalidated, весь selected root сканируется заново. До complete refresh следующая Trash запрещена. Failure не удаляет node из UI как будто операция прошла.

Batch Trash, in-app Restore/Undo и permanent deletion — non-goals до отдельного product/safety review.

## 11. Keyboard shortcuts

Предварительный набор, проверяемый на конфликт с macOS conventions:

| Действие | Shortcut |
|---|---|
| Choose Folder | `⌘O` |
| Start/Rescan | `⌘R` |
| Cancel Scan | `Esc` (когда scan активен) |
| Open selected in chart | `Return` |
| Back | `⌘[` |
| Forward (если история поддержана) | `⌘]` |
| Up to parent | `⌘↑` |
| Show in Finder | `⌥⌘R` |
| Move to Trash | `⌘⌫`, только с confirmation |
| Focus search/filter (future) | `⌘F` |

Все команды доступны через menu/toolbar, а не только с клавиатуры. `Delete` без Command не запускает filesystem mutation.

## 12. Drag and drop

Полезный минимальный inbound scenario: пользователь перетаскивает папку/volume на empty state или окно, чтобы выбрать scan root. Drop валидируется до старта.

Outbound drag файлов и drop-to-trash внутри приложения не входят в MVP: они усложняют security-scoped access, promise semantics и accidental actions. К ним возвращаемся после M4.

## 13. Ошибки и loading states

Ошибки классифицируются по действию пользователя:

- permission/TCC: объяснение и путь к разрешению;
- item disappeared: продолжить scan, записать recoverable issue;
- volume unavailable/ejected: остановить связанную работу, сохранить понятный context;
- network timeout/unresponsive volume: предложить cancel/retry без зависания UI;
- fatal scanner/model error: завершить scan и не показывать partial как complete;
- Finder/Trash failure: оставить state неизменным и показать конкретное сообщение.

Длинная операция всегда имеет visible status и Cancel. Loading overlay не должен блокировать навигацию по уже согласованному snapshot без причины.

## 14. Accessibility

Sunburst не может быть единственным способом получить данные. Для VoiceOver существует синхронизированный outline/list с теми же nodes, sizes и действиями.

Требования:

- каждый sector имеет accessibility label (имя, размер, доля, уровень) и action для selection/drill-down;
- порядок обхода следует понятной hierarchy, а не случайному geometry order;
- focus видим в light/dark mode и не кодируется только цветом;
- clickable targets имеют достаточный размер; микросегменты агрегируются;
- status/progress changes объявляются умеренно, без события на каждый item;
- `Other` объясняется как агрегат;
- keyboard-only flow покрывает выбор, навигацию, details и безопасные actions.

## 15. Reduced motion, light/dark mode и анимация

Используются системные appearance/material conventions и принятая semantic palette из [`DESIGN_SYSTEM.md`](DESIGN_SYSTEM.md). Цвета должны сохранять контраст и поддерживать selection/hover/focus не только оттенком. Текущая визуальная direction dark-first; полноценная light palette остаётся отдельным production gate и не должна получаться механической инверсией dark tokens.

Animation rules:

- анимировать изменения контекста, а не непрерывный поток scan events;
- M3 использует одну короткую transition всей chart, а не per-sector geometry morph; необходимость morph проверяется позже;
- progressive data обновляется порциями и с короткой стабилизацией;
- при Reduce Motion geometry transitions заменяются crossfade/немедленным обновлением;
- не анимировать сотни/тысячи независимых sectors;
- действия Trash никогда не маскируются optimistic disappearance до успеха.

## 16. Performance UX и лимиты Sunburst

Renderer получает ограниченное число segments. Initial M3 cap — 2048 nodes/segments budget включая virtual nodes; compact layouts используют меньшие caps. Числа остаются tunable по benchmark/UX evidence, а правила фиксированы:

- сегмент меньше минимального угла/экранной площади не получает отдельный target;
- маленькие siblings агрегируются в `Other` на соответствующем уровне;
- глубина ограничивается доступным radius и минимальной толщиной кольца;
- при resize projection/layout пересчитываются вне критического gesture path и coalesced;
- tooltip/hit testing работают по layout index, а не обходят весь `FileTree`;
- UI предпочитает стабильные top elements, избегая flicker около threshold (hysteresis допустим после измерений).
- resize внутри одного quantized budget class пересчитывает bounded geometry, но не обходит source tree;
- если выбранная metric даёт root size `0`, chart это объясняет и не переключает metric молча.

Не следует обещать пользователю отображение всех найденных файлов одновременно. Details/list позволяют исследовать объекты, скрытые geometry aggregation.

## 17. Форматирование размеров

- Все значения хранятся как integer bytes; округление только presentation-level.
- Интерфейс использует единый macOS-consistent formatter и явно сообщает единицы.
- Сортировка и проценты основаны на raw values, не на округлённой строке.
- Logical и allocated никогда не смешиваются в одной диаграмме без явного переключателя/label.
- Zero, unknown и unavailable — разные состояния.
- Значения provisional во время scan помечаются.
- Проценты показываются относительно текущего visual root; tooltip/details называют базу.

## 18. Вопросы для проверки прототипом

- нужна ли постоянно видимая hierarchy panel или достаточно переключаемого outline/largest list;
- какая size metric понятнее по умолчанию и как объяснить расхождение;
- single click против double click для drill-down при сохранении selection;
- оптимальные ring depth, segment budget и поведение `Other`;
- насколько полезны live progressive sectors по сравнению со стабильным top-level list;
- достаточно ли отдельных symlink/package/hard-link warnings и запрета current visual root в M4;
- какое поведение window restoration безопасно для security-scoped roots.

Эти вопросы не блокируют scanner core. Принятый Lustral Field design system не меняет их semantics и должен развиваться только вместе с UX/accessibility evidence.
