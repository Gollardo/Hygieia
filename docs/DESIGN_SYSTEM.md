# Hygieia Design System — Lustral Field

Статус: **accepted visual direction and implementation contract**.

Visual reference: [`assets/lustral-field-reference.png`](assets/lustral-field-reference.png).
Production atmosphere asset: `App/Assets.xcassets/LustralNebula.imageset`.
Rendered accepted states:

- [`assets/lustral-field-empty-v2.jpeg`](assets/lustral-field-empty-v2.jpeg) — entry;
- [`assets/lustral-field-loading-v2.jpeg`](assets/lustral-field-loading-v2.jpeg) — initial scan;
- [`assets/lustral-field-implementation-v2.jpeg`](assets/lustral-field-implementation-v2.jpeg) — Explorer.

Этот документ — источник истины для визуального языка. [`DESIGN.md`](DESIGN.md) владеет поведением и UX semantics, milestone documents — engineering contracts, а [`UI_CHANGE_CHECKLIST.md`](UI_CHANGE_CHECKLIST.md) — процедурой проверки. При конфликте эстетического решения с correctness, accessibility, filesystem safety или data truth побеждает соответствующий engineering/behavior contract.

## 1. Identity

**Hygieia** названа в честь древнегреческой богини здоровья, чистоты и санитарии. Для продукта это не обещание «автоматически почистить Mac», а метафора ясности и осознанного ухода:

> **See clearly. Clear safely.**

Brand character:

- analytical serenity — сложное дерево выглядит спокойным и читаемым;
- transparent evidence — UI различает измеренные данные, агрегацию и неизвестное;
- controlled energy — акцент показывает выбранное действие, а не декорирует всё окно;
- safe stewardship — Trash всегда остаётся проверяемым и подтверждаемым действием.

Brand mark — открытое кольцо из частиц с небольшой «чашей» внутри. Кольцо означает полный обзор, верхний разрыв — возможность освободить пространство, чаша — очищение без медицинской или бытовой символики. Mark не использует крест, змею, щит, лист, метлу, sparkle или лепестковую геометрию DaisyDisk.

## 2. Lustral Field

Главная визуализация называется **Lustral Field**. Она не меняет data model Sunburst pipeline:

```text
FileTree
  -> bounded SunburstProjection
  -> deterministic SunburstLayout
  -> reversible perspective transform
  -> Lustral Field Canvas
```

Визуальное поле использует:

- эллиптическую перспективу вместо плоского круга;
- единые top-level территории и вложенные кольца одной цветовой семьи;
- ограниченные dotted contour lines только на первых двух уровнях;
- подписи только для достаточно крупных top-level сегментов;
- центральный readout текущего visual root и выбранной metric;
- coral selection, amber marked-for-Trash и muted stale states;
- `Other` как явно нейтральную агрегированную территорию.

Perspective transform обратим для pointer coordinates. Selection, hover и drill-down продолжают использовать renderer-independent `SunburstHitTester`; UI не создаёт отдельную filesystem или layout truth.

## 3. Palette

| Token | Role | Initial dark value |
|---|---|---|
| `canvas` | основная поверхность | `#060A0D` |
| `canvasRaised` | rails/context bars | `#0A0F13` |
| `panel` | inspector surface | `#0E1217` |
| `panelRaised` | control/status surface | `#13181E` |
| `textPrimary` | основной текст | white 94% |
| `textSecondary` | пояснения | white 58% |
| `glacier` | нейтральная field structure | `#85B3F5` |
| `aqua` | complete/verified status | `#57DED1` |
| `coral` | current selection/brand emphasis | `#FF6E5C` |
| `amber` | marked/warning | `#F5AD4A` |
| `destructive` | финальный Trash action | `#E04038` |

Правила:

- категории не кодируются rainbow palette;
- coral означает текущий selection, но всегда дублируется outline/label;
- amber означает review/warning, а не success;
- destructive red не используется для mark или навигации;
- состояния complete, selected, marked, stale и inaccessible различимы без одного цвета.

Light appearance и системные accessibility variants остаются обязательным follow-up до production release. Текущая реализация фиксирует принятую dark visual direction и не заявляет завершённую light palette.

## 4. Typography and spacing

- System San Francisco; внешние font dependencies не добавляются.
- Body baseline: 14–16 pt.
- Numbers используют `monospacedDigit()` только в sizes, percentages и counts.
- Type hierarchy: title2 → title3/headline → body/callout → caption.
- Spacing scale: 4, 8, 12, 16, 24 pt.
- Corner radii: 8 pt controls, 14 pt panels, 18 pt hero surfaces.
- Сначала grouping/alignment/spacing, затем divider; border/elevation используются только при необходимости.

## 5. Components

Sources: `Features/DesignSystem/HygieiaDesignSystem.swift` and `App/Assets.xcassets`.

- `HygieiaBrandMark` — generated production image asset из принятого visual reference; SwiftUI не подменяет знак приблизительной code drawing.
- `HygieiaBrandLockup` — mark, wordmark и optional tagline.
- `HygieiaAtmosphere` — единый constellation/nebula asset для empty, loading и field underlay; animation отключается при Reduce Motion.
- `HygieiaPanel` — единая inspector surface.
- `HygieiaSectionTitle` — title/detail hierarchy.
- `HygieiaStatusPill` — compact complete/updating status.
- `HygieiaPalette`, `HygieiaSpacing`, `HygieiaRadius` — initial tokens.

Компоненты принадлежат application presentation layer. Domain, Scanner, Visualization и FileOperations не импортируют SwiftUI и не знают о brand tokens.

## 6. Explorer composition

Desktop hierarchy:

```text
native toolbar: navigation | brand | size metric
content:
  direct Contents rail
  field context + Lustral Field
  selected item | largest in field | cleanup review
```

Основное действие — исследование пространства. Cleanup review находится рядом с evidence, но не конкурирует с visual field. Mark for Trash остаётся reversible UI state. Move to Trash остаётся destructive, identity-validated и system-confirmed.

На меньшей ширине обязательны дальнейшие adaptive rules; production UI не должен просто масштабировать текст или диаграмму ниже minimum readable targets.

### Entry and loading scenes

Empty state не дублирует wordmark внутри content: native window title и один toolbar mark уже задают identity. Content строится как один Lustral Space, а не вертикальная стопка logo → icon → title → button. Primary copy и source chooser закреплены в левой зоне: локальные disks являются основными rows, а **Choose a Folder…** — вторичным точным ограничением root. Field preview показывает будущий результат до выбора источника.

Initial scan использует ту же spatial scene, но меняет задачу: показывает selected root, committed items, completed/queued folders, reported bytes, elapsed time, честный approximate ETA range после стабилизации, indeterminate progress и Cancel. Движущийся progress/sweep сохраняется, потому что заранее известного total нет. Footer progress скрыт, пока ещё нет предыдущего результата; при rescan он остаётся видимым поверх существующего Explorer.

## 7. Accessibility and motion

- Contents остаётся синхронизированным list alternative и показывает только direct children текущего visual root.
- Canvas сохраняет synthetic accessibility representation.
- Selection использует fill, outline, label и focus state.
- Dotted contours декоративны и скрыты от accessibility tree.
- Perspective transform применяется к drawing и обратно к pointer coordinates.
- Reduce Motion отключает geometry transition; контуры не получают независимую animation.
- Reduce Motion останавливает atmosphere pulse и moving scan beacon, оставляя статичную композицию и progress semantics.
- `Other` остаётся объяснённым aggregate, а не реальным filesystem object.

## 8. Performance boundary

Lustral Field не меняет projection node cap. Дополнительные contours:

- максимум 5 на segment depth 1;
- максимум 2 на segment depth 2;
- отсутствуют на более глубоких levels;
- не создают SwiftUI view или task на filesystem node.

Constellation treatment также bounded:

- один raster underlay независимо от числа filesystem nodes;
- максимум 38 декоративных particles на top-level represented segment;
- particle positions детерминированы projection identity и не меняют hit-testing;
- scanning beacon существует только в initial scan scene и обновляет один Canvas с частотой не выше 24 fps.

Это bounded implementation choice, а не performance claim. Instruments/Apple Silicon measurements и M3 benchmark gates остаются обязательными отдельно.

## 9. Dependencies

Сторонняя UI library не добавляется. SwiftUI, Canvas, SF Symbols и системная typography покрывают текущий accepted direction. Новая dependency допустима только для доказанного use case, после проверки Apple API и с отдельным архитектурным решением, если она меняет dependency boundaries.

## 10. Visual grammar

Lustral Field строится на контрасте спокойной системной оболочки и одного выразительного data field:

- **space, not cards** — большие области формируются alignment и negative space; панели появляются только вокруг связанного evidence или action group;
- **depth with evidence** — перспектива, туманность и контуры создают глубину, но никогда не меняют значение площади, порядка или selection;
- **one energy source** — coral или aqua концентрируются в текущем событии; одновременно светящиеся разноцветные зоны запрещены;
- **quiet chrome** — toolbar, rails и separators не конкурируют с данными;
- **material continuity** — empty, loading и Explorer ощущаются стадиями одного пространства, а не тремя несвязанными шаблонами;
- **native precision** — стандартные действия используют SF Symbols, system controls и macOS interaction conventions.

Запрещены: rainbow category palettes, постоянный neon glow вокруг каждого элемента, glassmorphism на всех поверхностях, декоративные 3D-объекты без data role, code-drawn замены утверждённых raster assets, emoji как product icons, случайные gradients и стилизация под DaisyDisk один-в-один.

## 11. State contract

| State | Composition | Required evidence | Primary action |
|---|---|---|---|
| Empty | full Lustral atmosphere, editorial copy + local disk chooser слева | read-only promise, user control, capacity per disk | Scan disk / Choose a Folder |
| Preparing | тот же spatial context без ложного progress | выбранный root или системная проверка | Cancel, если операция началась |
| Initial scanning | animated atmosphere + один status panel | root, items, completed/queued folders, reported bytes, elapsed, approximate ETA when stable, indeterminate progress | Cancel Scan |
| Rescanning | существующий Explorer остаётся видимым | previous result явно stale/updating, footer progress | Cancel |
| Completed | rail + Lustral Field + evidence/review band | metric, root, completion status, selected object | Explore / review |
| Completed with issues | completed composition с явным coverage warning | skipped/inaccessible evidence | Review issues |
| Cancelled | partial result только если snapshot согласован | cancelled и incomplete не смешиваются с complete | Resume/new scan, если поддерживается |
| Failed | атмосфера остаётся фоном, error становится главным content | понятная причина без ложной точности | Retry / choose another folder |

Новый product state нельзя представлять только spinner, цветом или toast. Он должен иметь ясную задачу, evidence и доступное следующее действие.

## 12. Component usage

- Brand mark в toolbar показывается без повторного wordmark: native window title уже называет продукт.
- Полный `HygieiaBrandLockup` допустим в About, onboarding/editorial material и share assets, но не дублируется внутри каждого рабочего экрана.
- `HygieiaAtmosphere` — shared background/underlay. Feature не хранит собственную копию, фильтр или случайную генерацию nebula.
- `HygieiaPanel` группирует evidence/actions; она не используется как универсальная обёртка каждого текста.
- `HygieiaStatusPill` сообщает компактный terminal/updating status, но не заменяет подробное progress evidence.
- Semantic colors берутся из `HygieiaPalette`; feature-level literal допустим только для локальной вычисляемой визуализации и после объяснения в code comment или contract.
- Spacing/radius берутся из tokens. Новое значение добавляется только при повторяющемся use case, а не ради одного pixel tweak.

Reusable component появляется после второго подтверждённого use case или когда он инкапсулирует обязательную semantics/accessibility. Одноразовая композиция может оставаться внутри feature; speculative component library запрещена.

## 13. Copy and product voice

Voice — спокойный, точный и контролируемый:

- сначала сообщать, что Hygieia увидела или делает, затем объяснять действие;
- не использовать fear language: «опасность», «катастрофа», «срочно очистить» без реального system error;
- не называть reported allocated bytes гарантированно reclaimable space;
- не обещать автоматическую очистку, ускорение Mac или исправление системы;
- destructive copy всегда говорит **Move to Trash**, не Delete/Clean Now;
- короткие English labels допустимы в текущем продукте, но один screen не смешивает языки случайно;
- sentence case предпочтительнее ALL CAPS; uppercase разрешён только для короткого eyebrow/status marker.

## 14. Assets and iconography

Утверждённые brand/atmosphere assets живут только в `App/Assets.xcassets`. Исходный визуальный reference и accepted renders живут в `docs/assets` и не используются приложением как runtime resources.

Для нового visible asset обязательны:

1. конкретный slot и ожидаемый crop/aspect ratio;
2. raster/vector source подходящего разрешения, без растягивания screenshot;
3. проверка alpha, color space и dark-background edges;
4. понятное имя imageset без версии в runtime identifier;
5. visual comparison в состоянии, где asset реально используется.

SF Symbols используются для стандартных macOS действий. Собственный icon нужен только для brand/data concept, которого нет в системной библиотеке. Иконка не должна быть единственным носителем смысла destructive или inaccessible state.

## 15. Adaptive layout

- Accepted desktop reference задаёт hierarchy, но не фиксированный pixel canvas.
- При уменьшении ширины сначала сокращаются вторичные подписи и число field labels, затем перестраиваются evidence panels; текст и hit targets не масштабируются пропорционально вниз.
- Contents сохраняет доступную direct-children list alternative даже если временно скрыта за disclosure/navigation.
- Bottom evidence/review band может перейти в последовательные panels, но порядок остаётся: selection → evidence → cleanup review.
- Primary CTA, Cancel и destructive confirmation всегда остаются в видимой/keyboard reachable области.
- Minimum window sizes и breakpoints подтверждаются реальным render, длинными именами и accessibility text size; числа не объявляются стабильными без такой проверки.

## 16. Change governance

Обычное feature-развитие переиспользует этот contract. Изменение считается **design-system change**, если оно добавляет/меняет semantic token, brand asset, typography scale, spacing/radius scale, shared component, state composition или значение visual status.

Для design-system change обязательно:

1. обновить этот документ и затронутые behavior docs в том же change;
2. сохранить before/after или source/implementation evidence в `docs/assets`, если изменение визуально существенно;
3. пройти [`UI_CHANGE_CHECKLIST.md`](UI_CHANGE_CHECKLIST.md);
4. проверить соседние состояния, а не только happy path;
5. оформить ADR, только если решение меняет architectural/dependency boundaries.

Экспериментальная ветка или mock не меняет accepted direction. Новый стиль становится принятым только после явного owner approval; до этого он маркируется как exploration и не заменяет reference assets.
