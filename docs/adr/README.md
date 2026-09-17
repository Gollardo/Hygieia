# Architecture Decision Records

ADR фиксирует существенное архитектурное решение, которое меняет или уточняет правила из `docs/ARCHITECTURE.md`. ADR нужен для решений со значимыми альтернативами и последствиями; мелкий implementation detail ADR не требует.

Имя файла:

```text
ADR-XXXX-short-kebab-title.md
```

Номер последовательный, четыре цифры. После принятия ADR не переписывается задним числом для изменения решения: создаётся новый ADR, который supersedes предыдущий.

Шаблон:

```markdown
# ADR-XXXX: Title

Status: Proposed | Accepted | Superseded by ADR-XXXX | Rejected
Date: YYYY-MM-DD

## Context
Какая конкретная проблема и ограничения требуют решения.

## Decision
Что именно решено и где проходит граница решения.

## Alternatives Considered
Реальные альтернативы и причины отказа, без strawman.

## Consequences
Положительные, отрицательные последствия, migration/verification needs.
```

Workflow: создать `Proposed` ADR до нарушающего архитектуру кода; обсудить/принять; затем обновить `ARCHITECTURE.md` и реализацию. Первый ADR фиксирует исходный native stack.

M5 orchestration and APFS mount policy: [ADR-0009](ADR-0009-whole-mac-orchestration.md).
