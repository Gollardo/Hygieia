# Инженерный roadmap Hygieia

Roadmap описывает последовательность доказательств, а не календарные сроки. Milestone считается завершённым только при выполненных acceptance criteria и названных operational gates. Поздний milestone не должен молча протаскиваться в ранний.

## M0 — Foundation

**Цель:** создать маленький и устойчивый фундамент проекта.

**Scope:** layout репозитория, operating contract, архитектура, UX-гипотеза, roadmap, ADR format, минимальные value types и service boundaries.

**Deliverables:** `AGENTS.md`, `README.md`, `docs/`, `.gitignore`, compact `FileTree` skeleton, scanner contract, Sunburst geometry contract, Finder/Trash protocols.

**Acceptance criteria:** документы непротиворечивы; dependency directions и non-goals явны; source stubs не импортируют SwiftUI/AppKit; нет build-system dependency, generated output или псевдо-реализации будущих subsystems.

**Tests/checks:** Swift typecheck доступных source stubs; repository/diff inspection; поиск случайных build/generated artifacts.

**Explicit non-goals:** Xcode UI target, работающий scanner, renderer, SQLite, FSEvents, performance claims.

## M1 — Scanner CLI/Core

Детальный принятый дизайн: [`M1_SCANNER_CORE.md`](M1_SCANNER_CORE.md), ADR-0002.

**Цель:** корректно построить `FileTree` одной явно выбранной директории и вывести top-N крупнейших элементов без UI.

**Scope:** FoundationScanner, ScanCoordinator, bounded directory queue, cancellation, coarse progress, recoverable issues, tree builder/aggregation, CLI/harness.

**Deliverables:** compilable core/CLI target; scan options с безопасными defaults; final и согласованные partial-result semantics; human/machine-readable top-N output; baseline measurements.

**Acceptance criteria:** выбранная temporary/fixture directory строится в валидное дерево; totals совпадают с зафиксированной M1 accounting semantics; symlinks никогда не traversed; hard links представлены всеми names, но учитываются один раз; scan отменяется в пределах одного активного shallow call на worker; worker/task/in-flight limits доказаны; permission/disappearing-item issues не превращаются молча в complete coverage.

**Tests:** node/link/path/aggregation invariants; wide/deep fixtures; unicode/long names; cancellation; permission errors; symlink no-follow; package policy; arithmetic overflow; integration tests только внутри temporary roots.

**Explicit non-goals:** whole Mac, production-grade hard-link/APFS clone accounting, UI, Darwin scanner, SQLite/FSEvents.

## M2 — Basic macOS App

Детальный принятый дизайн: [`M2_BASIC_MACOS_APP.md`](M2_BASIC_MACOS_APP.md), ADR-0003.

**Цель:** дать пользователю выбрать папку, запустить core scanner и понять результат без Sunburst.

**Scope:** Xcode app/test targets поверх local SwiftPM products, SwiftUI shell, composition root, sandboxed system folder picker, scan lifecycle/progress/cancel, bounded Largest Items table, basic details/errors.

**Deliverables:** runnable Apple Silicon macOS app; app/core/tests target graph; folder selection; list results; accessible scan status; documented entitlements/sandbox choice for this scope.

**Acceptance criteria:** UI не обращается к filesystem напрямую; app target не дублирует M1 sources; App Sandbox/read-only Powerbox access проверены; main thread остаётся responsive; start/cancel/retry state transitions детерминированы; complete/partial/incomplete/stale result visibly distinguished; Largest Items хранит максимум K=200 rows; app корректно обрабатывает закрытие/повторный выбор root.

**Tests:** feature state tests; core integration through test doubles; focused UI test folder-selection boundary where automatable; manual Apple Silicon smoke check; accessibility labels for list/progress/actions.

**Explicit non-goals:** Sunburst, whole Mac promise, Trash action, persistent index, visual brand system.

## M3 — Sunburst MVP

Точный реализуемый контракт: [`M3_SUNBURST_MVP.md`](M3_SUNBURST_MVP.md), архитектурное решение: ADR-0004.

**Цель:** исследовать snapshot через bounded, интерактивную radial partition visualization.

**Scope:** renderer-independent `HygieiaVisualization`; bounded flat projection; stable virtual `Other`; geometry budget classes; one-level-at-a-time application policy; layout/ring index; Canvas renderer; hit testing; shared real/virtual selection; drill-down; Back/Forward/Up; breadcrumbs; accessibility representation.

**Deliverables:** pure projection/layout/hit-test product; hard cap 2048 including virtual nodes; segment/ring indices; thin Canvas integration; synchronized subtree list/chart/details; keyboard/VoiceOver/Reduce Motion behavior; generated benchmark fixtures and recorded Apple Silicon baseline.

**Acceptance criteria:** renderer никогда не получает больше requested cap; wide-root projection не materializes all children; boundary rules однозначны; drill/navigation не запускают scan; selection/breadcrumbs/subtree list согласованы; pixel resize внутри budget class не перестраивает projection; hover не обходит `FileTree` и не создаёт tasks; Reduce Motion и accessible alternative проверены.

**Tests:** golden numeric layout fixtures с tolerances; angle wrap/ring boundaries; `Other` totals/identity; zero/accounting/cancellation paths; depth/node budgets; reference hit testing; drill-down history/generation races; feature/UI accessibility tests; P/L/H/R/N performance suite из M3 specification.

**Explicit non-goals:** progressive live tree; Swift Charts/Metal/third-party renderer; отображение каждого file sector; browsable `Other`; in-sector labels; final palette/branding; file actions; advanced categories.

## M4 — File Actions

Точный реализуемый контракт: [`M4_FILE_ACTIONS.md`](M4_FILE_ACTIONS.md), архитектурные решения: ADR-0005, ADR-0006 и ADR-0007.

**Текущий статус:** реализация присутствует в Core/App: identity sidecar, eligibility, no-follow validation, Finder/Trash adapters, single и marked-list confirmation flows, stale invalidation и receipt-confirmed in-memory reconciliation с full-root fallback. Signed sandbox Finder/Trash, symlink-race, read-only-volume, VoiceOver и performance acceptance gates остаются открыты.

**Цель:** безопасно связать выбранный node с Finder и Move to Trash.

**Scope:** compact per-node identity sidecar; `HygieiaFileOperations`; identity-chain/no-follow path validation; concrete Finder/Trash adapters; eligibility/confirmation UX; single-action state; stale invalidation overlay; known-action immutable reconciliation after success with full selected-root refresh fallback; read-write Powerbox entitlement.

**Deliverables:** Show in Finder; confirmed Move to Trash; protected-node policy с typed denial; bounded in-memory status; signed sandbox entitlement evidence; identity memory baseline; documented stale/full-rescan strategy.

**Acceptance criteria:** permanent delete API отсутствует; path начинается от original selected-root URL; root/каждый ancestor/leaf совпадают по no-follow kind и `(device,inode)`; virtual/stale/partial/root/visible-root/incomplete targets защищены; failed operation не меняет snapshot как success; Trash success требует system URL mapping; old tree становится stale и заменяется только complete validated immutable reconciliation либо fallback full-root rescan; symlink target остаётся нетронутым.

**Tests:** identity sidecar/stride/memory; policy matrix; owned temporary resolver fixtures; ancestor/leaf replacement и symlink races; service fakes; stale/missing/denied; cancel confirmation; full-root action refresh; UI/accessibility; manual signed sandbox Finder/Trash/symlink/read-only-volume gates.

**Explicit non-goals:** permanent/secure delete; Empty Trash; Restore/Undo; batch cleanup; privilege escalation/FDA/helper; arbitrary targeted tree merge/FSEvents; persistent action log; automated recommendations.

## M5 — Whole Mac Scan

**Текущий статус:** single-root M5a реализован по [M5_LOCAL_VOLUME_COVERAGE.md](M5_LOCAL_VOLUME_COVERAGE.md) и ADR-0008: local-volume discovery с unknown/error/retry, picker, root identity validation, incomplete/unavailable coverage и отчёт Scope & Coverage. Автоматические проверки покрывают replacement/disappearance и APFS disk-image boundary/read-only scan. Whole Mac orchestration, APFS System/Data policy, FDA onboarding и физический eject/stalled I/O остаются открытыми; полный M5 не закрыт.

**Цель:** поддержать понятный scan local volumes/доступного Mac с честным coverage.

**Scope:** volume discovery/selection, mount boundaries, Full Disk Access onboarding/status, permission issue summaries, network/removable volume policy.

**Deliverables:** volume UI; Whole Mac orchestration; coverage report; settings/help for FDA; behavior for eject/unavailable volumes.

**Acceptance criteria:** «Whole Mac» не выдаёт неполный результат за полный; mount crossing является explicit option; FDA отсутствие объясняется без privilege escalation; ejected/network-stalled volume не замораживает app; каждый scan root/volume сохраняет provenance.

**Tests:** volume-policy unit tests; mocked permissions/mount changes; local volume integration; manual FDA denied/granted gates; removable/eject scenario; network volumes только если официально входят в scope.

**Explicit non-goals:** обход TCC/SIP, гарантированный доступ ко всем системным данным, FSEvents sync, remote filesystem optimization.

## M6 — Scanner Performance

**Цель:** улучшить throughput/RSS на основании воспроизводимых измерений при сохранении semantics.

**Scope:** benchmark harness, Instruments/signposts, Foundation hot-path optimisation, buffer/name/node memory analysis, экспериментальный Darwin `getattrlistbulk()` backend.

**Deliverables:** baseline report; representative datasets; profiles; backend parity suite; accepted optimisations; documented fallback/error behavior.

**Acceptance criteria:** каждое принятое изменение имеет before/after на одном dataset/config; correctness parity проверена или различия явно документированы; concurrency остаётся bounded; regression thresholds автоматизированы там, где стабильны; Darwin backend можно заменить Foundation без Domain/UI changes.

**Tests:** cross-backend tree/issue equivalence; cancellation/load; peak RSS/bytes-per-node; throughput; syscalls; long-running stress; release-build Apple Silicon measurements.

**Explicit non-goals:** переписывание на Rust/C++ без нового ADR и evidence; micro-optimisation вне measured hot path; изменение filesystem meaning ради скорости.

## M7 — Filesystem Correctness

**Цель:** определить и реализовать честную semantics сложных filesystem/APFS cases.

**Scope:** hard links, symlinks, packages, sparse/compressed files, file IDs, allocated/logical sizes, APFS clones/shared blocks research, race behavior.

**Deliverables:** semantics specification; fixtures/tools для создания cases; scanner metadata extensions; UI labels/warnings; platform-support matrix; ADR для спорных accounting choices.

**Acceptance criteria:** hard-link double-counting policy доказана тестами; symlink traversal не образует loops/escape по умолчанию; logical/allocated явно различаются; package behavior consistent; clone/shared-block claims ограничены тем, что подтверждено Apple API/docs/experiments; unknown не отображается как zero/exact.

**Tests:** APFS integration fixtures; sparse/compressed creation checks; hard-link/symlink graphs; package fixtures; concurrent mutation; cross-backend parity; manual verification на поддерживаемых volume types.

**Explicit non-goals:** обещание точного reclaimable space без системного evidence; поддержка каждой сторонней filesystem; destructive deduplication.

## M8 — Persistent Index

**Цель:** загружать versioned snapshot между запусками и уменьшить time-to-useful-result.

**Scope:** SQLite adapter, schema/versioning, atomic snapshot publication, corruption handling, stale status, cold/warm load measurements.

**Deliverables:** Persistence protocol/implementation; migrations policy; snapshot provenance/options; atomic write/read; purge/rebuild path; storage budget.

**Acceptance criteria:** Domain не зависит от SQLite rows; incompatible/corrupt DB fails safe и rebuilds without data loss beyond cache; stale snapshot visibly marked; interrupted write не публикует partial snapshot; NodeID/persistent identity distinction соблюдён.

**Tests:** round-trip large trees; schema migration; corruption/truncation; interrupted transaction; concurrent reader/publication; cold/warm benchmarks; cache cleanup.

**Explicit non-goals:** cloud sync, multi-device database, user document storage, FSEvents reconciliation (следующий milestone).

## M9 — Incremental Updates

**Цель:** поддерживать persistent snapshot актуальным через FSEvents и bounded partial rescans.

**Scope:** event stream lifecycle/cursor, coalescing, dropped-event handling, dirty subtree planning, rescan/reconciliation, snapshot version publication.

**Deliverables:** Monitoring adapter; reconciliation engine; event diagnostics; fallback-to-rescan policy; UI updating/stale states.

**Acceptance criteria:** FSEvents не трактуется как полный audit log; dropped/ambiguous/root-changed events расширяют rescan; reconciliation атомарна; app restart/cursor persistence корректны; event storm bounded; UI никогда не получает half-applied tree.

**Tests:** synthetic event sequences; coalescing; dropped events; rename/move/delete; volume detach; restart cursor; race between action and event; end-to-end mutation fixtures; stress/backpressure.

**Explicit non-goals:** real-time guarantee, distributed sync, изменение system files, silent trust stale cache.

## M10 — Advanced Insights

**Цель:** добавить полезные производные views поверх стабильного `FileTree`, не превращая heuristics в filesystem truth.

**Scope:** categories, Largest Files, Developer Storage, Caches, Downloads, Applications и другие подтверждённые insights.

**Deliverables:** projection/query APIs; explainable category rules; user-visible provenance/limitations; bounded computation/cache; navigation обратно к реальным nodes.

**Acceptance criteria:** insights являются projections, а не вторым mutable source; каждый result объясним и связан с node/path; heuristics/versioning документированы; категории не инициируют destructive cleanup автоматически; performance budgets соблюдены.

**Tests:** rule fixtures; overlap/unknown category behavior; localization/accessibility; projection performance; navigation/action safety; regression corpus без пользовательских данных.

**Explicit non-goals:** «one-click cleaner», автоматическое удаление, telemetry-driven profiling, cloud recommendations, неподтверждённые claims о безопасности удаления.

## Cross-milestone release gates

Для любого milestone отдельно называются:

- code/unit checks;
- macOS integration checks;
- performance evidence, если заявляется performance;
- permission/FDA/manual gates;
- known unsupported filesystem semantics.

Успешный build не доказывает filesystem correctness, Full Disk Access, Finder/Trash behavior или performance на миллионах узлов.
