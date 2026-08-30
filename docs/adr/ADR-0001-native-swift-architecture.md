# ADR-0001: Native Swift architecture for macOS

Status: Accepted
Date: 2026-08-30

## Context

Hygieia должна сканировать большие деревья macOS, работать с platform permissions, Finder, Trash, FSEvents и эффективно рисовать интерактивную Sunburst-диаграмму. Основная платформа — Apple Silicon Mac; кроссплатформенность не является продуктовой целью. Раннее добавление отдельного backend runtime увеличило бы build, packaging, concurrency и interop complexity до появления benchmark evidence.

## Decision

Приложение строится нативно на Swift 6.x. SwiftUI является основным UI framework, AppKit используется точечно для macOS-интеграции. Scan core использует Foundation сначала и допускает будущий Darwin backend на `getattrlistbulk()` за общим scanner contract. Visualization реализуется собственным layout/hit-testing и SwiftUI Canvas renderer.

Electron, Tauri, Rust/C++ backend и кроссплатформенные UI frameworks не входят в исходную архитектуру. Изменение этого решения требует нового ADR с correctness/performance measurements и operational consequences.

## Alternatives Considered

- **Electron**: быстрый web UI, но повышенные memory/runtime costs и более слабая естественная интеграция с filesystem permissions и macOS behavior.
- **Tauri + Rust backend**: потенциально эффективный scanner, но ранняя сложность FFI, двойной toolchain и ownership/cancellation boundary без измерений Swift implementation.
- **Swift UI + Rust/C++ scanner**: может быть пересмотрено только если Swift/Darwin implementation не достигает измеримых целей; сейчас преждевременно.
- **Swift Charts**: не рассчитан быть основой radial partition с нужным aggregation, geometry transitions и custom hit testing.

## Consequences

Положительные:

- один language/runtime и прямой доступ к Apple APIs;
- проще concurrency ownership и packaging;
- platform-consistent permissions, Finder и Trash integration;
- меньше зависимостей в критическом фундаменте.

Отрицательные/риски:

- high-throughput scanner потребует аккуратной работы с низкоуровневыми Darwin APIs;
- Swift value/container overhead нужно измерять на миллионах nodes;
- часть SwiftUI behavior потребует точечного AppKit bridge;
- решение не оптимизирует перенос приложения на другие OS.
