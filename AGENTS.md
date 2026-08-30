# Hygieia Agent Contract

Этот файл — обязательный operating contract для всех агентов, меняющих репозиторий.

## Project principles

- Correctness прежде optimization; measurement прежде performance optimisation.
- Filesystem semantics нельзя угадывать: спорные случаи подтверждаются документацией, тестами на реальной файловой системе или явно помечаются как неизвестные.
- `FileTree` — источник истины. UI не сканирует filesystem напрямую; scanner не зависит от UI; Domain не зависит от SwiftUI/AppKit.
- Performance-sensitive изменения сопровождаются воспроизводимым benchmark и исходными измерениями.
- Опасные file operations требуют явного UX. Permanent delete запрещён; удаление означает только Move to Trash.
- Избегать ненужных зависимостей и предпочитать Apple platform APIs.

## Workflow

Перед изменениями агент обязан:

1. прочитать релевантные документы в `docs/` и ближайшие тесты;
2. определить затрагиваемые architectural boundaries;
3. проверить текущее состояние репозитория и не затереть чужую работу;
4. внести минимально достаточное изменение;
5. добавить или обновить тесты;
6. выполнить доступные проверки и честно назвать непроверенные уровни;
7. обновить документацию, если изменилось поведение или архитектура.

## Product design changes

Для любых изменений видимого UI обязательны [`docs/DESIGN_SYSTEM.md`](docs/DESIGN_SYSTEM.md) и [`docs/UI_CHANGE_CHECKLIST.md`](docs/UI_CHANGE_CHECKLIST.md). Принятая direction называется **Lustral Field**; новые экраны должны переиспользовать её tokens, assets и application-level components, а не создавать параллельный visual language.

Перед завершением UI-изменения агент обязан:

1. определить затронутые product states и semantic roles;
2. проверить экран с реальными длинными именами и фактическими значениями;
3. сохранить dark-first hierarchy, accessibility redundancy и Reduce Motion behavior;
4. сравнить итоговый render с принятой reference или предыдущим accepted state;
5. обновить design contract, если меняются tokens, components, composition или interaction semantics.

Нельзя добавлять новый цветовой язык, шрифт, UI dependency, отдельную diagram truth или декоративную per-filesystem-node animation без явно принятого решения. Визуальный эксперимент сначала фиксируется как reference и проходит сравнение; он не становится новым стандартом только потому, что уже написан в коде.

## Architectural changes

Если изменение нарушает или существенно меняет `docs/ARCHITECTURE.md`, нельзя просто менять код. Сначала создать ADR в `docs/adr/`, описать контекст, решение, альтернативы и последствия. После принятия решения обновить `ARCHITECTURE.md`.

## Safety

Особая осторожность обязательна для recursive delete, symlink traversal, filesystem/volume boundaries, root volume, permission escalation и любых destructive actions. Никогда не следовать по ссылкам и не пересекать границы томов по неявному предположению.

## Performance

Запрещены performance claims без measurement. В scanner hot path избегать unnecessary `URL`/`String` allocation, дублирования полных путей, unbounded `Task`, миллионов reference-type nodes и UI updates на каждый filesystem item.

## Scope discipline

Не добавлять функциональность «раз уж мы здесь». Не создавать speculative abstractions без ближайшего подтверждённого use case. Не добавлять dependency, build system или framework без явной необходимости и зафиксированного решения.
