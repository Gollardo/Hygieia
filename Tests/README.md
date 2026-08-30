# Verification fixtures

`swift run hygieia-verify` выполняет Core/integration checks на явно созданных temporary fixtures и удаляет только созданный fixture root. Он проверяет compact storage layout, hard-link accounting, no-follow symbolic links/root rejection и valid cancelled partial result. Полный performance baseline остаётся отдельным Release-mode operational gate.

`Tests/VisualizationTests` содержит pure SwiftPM contract tests и test-only builder для небольших точных `FileTree` fixtures. Он не импортирует UI framework и предназначен для следующих M3 projection/layout slices.

`Tests/FileOperationsTests` проверяет identity storage, eligibility и no-follow validation на owned temporary fixtures. `Tests/AppTests` покрывает feature state, navigation, projection, single/marked Trash orchestration и stale/full-rescan transitions. `Tests/AppUITests` остаётся тонким launch/empty-state smoke; Powerbox, signed sandbox Finder/Trash, VoiceOver и реальные filesystem races являются отдельными manual gates.
