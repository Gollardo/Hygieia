# Hygieia UI Change Checklist

Статус: **обязательная проверка для видимых изменений**.

Используется вместе с [`DESIGN_SYSTEM.md`](DESIGN_SYSTEM.md), [`DESIGN.md`](DESIGN.md) и релевантным milestone contract. Чек-лист не доказывает filesystem correctness, performance или release readiness — эти gates проверяются отдельно.

## 1. Scope and source

- [ ] Названы изменяемые states и пользовательская задача.
- [ ] Найдены существующие tokens, components и ближайший accepted экран.
- [ ] Визуальная цель основана на accepted reference или явно одобренном новом mock.
- [ ] Изменение не создаёт второй источник data/layout/filesystem truth.
- [ ] Чужие и несвязанные изменения в worktree сохранены.

## 2. Lustral Field consistency

- [ ] Используется dark-first charcoal/glacier palette и один controlled accent.
- [ ] Empty, loading и Explorer сохраняют material continuity.
- [ ] Toolbar и secondary chrome тише главного data field.
- [ ] Панели группируют evidence/actions, а не оборачивают каждый элемент.
- [ ] Утверждённые assets используются из `App/Assets.xcassets`; нет placeholder, emoji или приблизительной code drawing.
- [ ] Нет rainbow categories, случайных gradients, pervasive glow или DaisyDisk-копирования.

## 3. Content and states

- [ ] Реальные длинные имена, большие числа, zero/unknown/unavailable проверены.
- [ ] Logical и Allocated явно различены.
- [ ] Loading показывает честные измерения, а не выдуманный процент.
- [ ] Error/cancelled/stale/inaccessible состояния не выглядят completed.
- [ ] Copy не обещает reclaimable bytes, ускорение или автоматическую очистку.
- [ ] Destructive действие называется Move to Trash и отделено от reversible mark/review.

## 4. Interaction and accessibility

- [ ] Keyboard navigation, focus и minimum hit targets не ухудшены.
- [ ] Selection/status дублируются формой, outline, label или icon — не только цветом.
- [ ] Canvas сохраняет bounded synthetic accessibility representation и list alternative.
- [ ] Decorative atmosphere/particles скрыты от accessibility tree.
- [ ] Reduce Motion даёт полноценное статичное состояние.
- [ ] Hover/tooltip не являются единственным способом получить информацию.

## 5. Performance and safety boundaries

- [ ] Нет View/Task/animation на каждый filesystem node.
- [ ] Decorations имеют явный cap и детерминированное размещение.
- [ ] UI не сканирует filesystem и не реконструирует опасное действие только из path.
- [ ] Performance claim подтверждён measurement; иначе сформулирован как implementation bound.
- [ ] Новая dependency обоснована, проверены Apple APIs и при необходимости оформлен ADR.

## 6. Verification and documentation

- [ ] App build и релевантные unit/UI tests выполнены либо честно названы непроверенными.
- [ ] Render проверен минимум в empty/loading/content/error состояниях, затронутых change.
- [ ] Reference и implementation сравнены вместе при одинаковом state и сопоставимом viewport.
- [ ] Проверены crop, padding, truncation, contrast, borders/radii и destructive hierarchy.
- [ ] Существенный accepted render сохранён в `docs/assets`.
- [ ] При изменении системы обновлены `DESIGN_SYSTEM.md`, behavior docs и tests.

UI change готов к приёмке только когда нет известных P0/P1/P2 визуальных или accessibility дефектов, а оставшиеся P3 и непроверенные release gates перечислены явно.
