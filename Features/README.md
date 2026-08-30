# Features

Presentation state и SwiftUI flows организованы по пользовательским сценариям: `Scan`, `Explorer`, `FileDetails`, `Settings`. `DesignSystem` содержит только application-level visual tokens и reusable SwiftUI components из [`docs/DESIGN_SYSTEM.md`](../docs/DESIGN_SYSTEM.md). Любое видимое изменение проходит [`UI_CHANGE_CHECKLIST.md`](../docs/UI_CHANGE_CHECKLIST.md). Features зависят от contracts, а не от concrete filesystem implementation; brand layer не импортируется в Domain, Scanner, Visualization или FileOperations.
