# M4 — File Actions

Статус: **реализован в коде; manual acceptance gates остаются открыты**. Документ определяет точный M4 contract; signed sandbox Finder/Trash, symlink-race, read-only-volume, VoiceOver и performance gates не считаются закрытыми автоматическими тестами.

## 1. Результат milestone

M4 добавляет две намеренно узкие операции над реальным filesystem object:

- **Show in Finder**;
- **Move to Trash**.

Permanent delete, Empty Trash и автоматическая очистка не появляются ни в UI, ни в protocol surface. Marked Trash batches добавлены ADR-0006: они остаются window-local, sequential и identity-validated, а после terminal batch делают один full-root refresh.

```text
immutable FileTree + snapshot-local selection + original selected-root URL
    -> pure eligibility policy
    -> snapshot target with identity chain
    -> no-follow live filesystem validation
    -> Finder request
       or
       explicit Trash confirmation
           -> repeat no-follow validation
           -> macOS Trash service
           -> filesystem-confirmed receipt
           -> stale/invalidation presentation
           -> full selected-root rescan
```

`FileTree` остаётся source of truth для показанного snapshot. M4 не вырезает node из published tree после Trash и не создаёт частично мутированный snapshot.

## 2. Scope

В M4 входят:

- `HygieiaFileOperations` core product, зависящий от `HygieiaDomain` и Foundation/Darwin, но не от SwiftUI/AppKit;
- concrete AppKit Finder adapter;
- concrete macOS Trash adapter;
- compact per-node identity sidecar в `FileTree`;
- path reconstruction только от original selected-root `URL` по parent/name chain;
- no-follow validation root, ancestors и leaf;
- eligibility policy для real/virtual, fresh/stale/partial, root/visible-root и risky flags;
- confirmation flow и state machine для single operation / marked batch;
- in-memory action status без telemetry/persistent audit log;
- invalidated-subtree overlay и автоматический полный root rescan после успешного Trash;
- unit, feature, UI и bounded temporary/manual macOS integration tests.

## 3. Explicit non-goals

M4 не включает:

- permanent delete, secure erase или Empty Trash;
- restore/Undo from Trash внутри Hygieia;
- privilege escalation, Authorization Services, helper/XPC service, Full Disk Access;
- hardcoded «safe to delete» recommendations;
- Whole Mac/system-path cleanup policy (M5+);
- targeted immutable tree patching, rename reconciliation или FSEvents (M9);
- persistent bookmark или restoration выбранной папки;
- persistent action history, analytics или telemetry;
- reclaimable-space claims;
- atomic POSIX rename-to-Trash implementation вместо системного macOS service.

## 4. Почему одного пути недостаточно

Между scan и click filesystem может измениться:

- файл удалён и создан заново под тем же именем;
- ancestor заменён symbolic link;
- каталог переименован или перемещён;
- volume размонтирован/подменён;
- path теперь указывает на объект другого kind.

Сравнивать только path, name или displayed size недостаточно. Текущий scanner уже получает `(device, inode)` как `FileIdentity`, но `FileTree` сохраняет его только для hard-link groups. M4 сохраняет identity для каждого node в compact sidecar и проверяет всю цепочку непосредственно перед action.

Эта проверка существенно уменьшает stale-path/symlink risk, но не превращает path-based macOS Trash API в атомарную identity-bound операцию. Между последним `lstat` и системным move остаётся короткий TOCTOU window; он фиксируется как residual risk и получает race tests. Решение через directory descriptors/`openat` и platform Trash semantics относится к M7 research, если evidence покажет необходимость.

## 5. Domain identity sidecar

Stride `FileNode` не меняется. Identity хранится отдельно:

```swift
public struct NodeDeviceOverride: Hashable, Sendable {
    public let node: NodeID
    public let device: UInt64
}

public struct NodeIdentityStore: Sendable {
    public let primaryDevice: UInt64
    private let inodes: ContiguousArray<UInt64>
    private let knownWords: ContiguousArray<UInt64>
    private let deviceOverridesByNode: ContiguousArray<NodeDeviceOverride>

    public var count: Int { inodes.count }
    public func identity(for node: NodeID) -> FileIdentity?
}

public struct FileTree: Sendable {
    // existing storage
    private let identities: NodeIdentityStore

    public func identity(for node: NodeID) -> FileIdentity?
}
```

Инварианты:

- `inodes.count == FileTree.count`;
- bit `known` различает настоящий inode `0` и unavailable identity; sentinel не угадывается;
- `primaryDevice` равен device root и покрывает обычный M1 snapshot, который не пересекает volume boundary;
- rare nodes другого device используют sorted override, binary-searched by `NodeID`;
- production scanner сохраняет known identity для каждого committed node, чьи metadata удалось прочитать; metadata-failure node остаётся в tree как inaccessible/incomplete и автоматически не eligible для Trash;
- synthetic/legacy fixture может создать unavailable store, но такие nodes автоматически не eligible для Trash;
- identity snapshot-local и не является persistent ID между rescans;
- hard-link side table пока не рефакторится: M4 не расширяет scope ради устранения небольшого дублирования.

Memory target: `8 bytes/node` для inode + `1 bit/node` known bitmap + fixed primary device + rare overrides, без изменения 40-byte `FileNode` stride. Это target, а не измеренный claim; M4 фиксирует actual capacity/RSS для 1M/5M fixtures.

### 5.1 Builder changes

`FileTreeBuilder` получает root identity при initialization и append-ит identity вместе с каждым node. Для production path metadata failure сохраняет node как inaccessible/incomplete с unavailable identity, а не превращает его в небезопасный target. Foundation backend уже извлекает `st_dev/st_ino`; scanner hot path не делает новый syscall ради M4.

Public fixture construction может явно передать `.unavailable(count:)`. Action tests обязаны строить реальные identities; visualization-only fixtures могут остаться identity-free.

## 6. Target contracts

### 6.1 Snapshot target

```swift
public enum FileActionKind: Hashable, Sendable {
    case revealInFinder
    case moveToTrash
}

public struct SnapshotPathComponent: Hashable, Sendable {
    public let node: NodeID
    public let name: String
    public let expectedIdentity: FileIdentity
    public let expectedKind: NodeKind
}

public struct SnapshotFileActionTarget: Sendable {
    public let node: NodeID
    public let rootURL: URL
    public let rootIdentity: FileIdentity
    public let componentsFromRootChild: ContiguousArray<SnapshotPathComponent>
    public let expectedKind: NodeKind
    public let snapshotFlags: NodeFlags
    public let logicalSize: UInt64
    public let reportedAllocatedSize: UInt64
}
```

`rootURL` — URL из текущего `ScanResult`, происходящий от `NSOpenPanel`. Его нельзя восстанавливать через абсолютную строку: string path не переносит sandbox access. Компоненты append-ятся по одному; joined relative/absolute path не становится authority.

`SnapshotFileActionTarget` создаётся только для `.node(NodeID)`. Virtual `Other` не имеет target contract.

### 6.2 Validated target

```swift
public struct ValidatedFileActionTarget: Sendable {
    public let snapshot: SnapshotFileActionTarget
    public let itemURL: URL
    public let validatedIdentity: FileIdentity
    public let validatedKind: NodeKind
    public let validatedAt: ContinuousClock.Instant
}

public protocol FileActionTargetValidating: Sendable {
    func validate(_ target: SnapshotFileActionTarget) async throws -> ValidatedFileActionTarget
}
```

`ValidatedFileActionTarget` короткоживущий. Его нельзя кэшировать между confirmation и execution: Trash adapter повторяет validation или получает freshly revalidated target непосредственно перед system call.

### 6.3 Service contracts

```swift
@MainActor
public protocol FinderService: Sendable {
    func reveal(_ target: ValidatedFileActionTarget)
}

public struct TrashReceipt: Sendable {
    public let originalURL: URL
    public let resultingURL: URL?
    public let movedIdentity: FileIdentity
    public let completedAt: ContinuousClock.Instant
}

public protocol TrashService: Sendable {
    func moveToTrash(_ target: SnapshotFileActionTarget) async throws -> TrashReceipt
}
```

Finder adapter использует `NSWorkspace.activateFileViewerSelecting([URL])`. API не возвращает подтверждение выбора; успехом feature считает только выполненный validation и отправленный Finder request, а не доказанное visual selection.

Initial Trash adapter использует single-item `NSWorkspace.recycle` и требует mapping original URL → Trash URL. Nil error без mapping не считается success. Adapter внутри повторяет full no-follow validation, затем вызывает system service. Альтернатива `FileManager.trashItem` остаётся допустимой только через ADR/spec update с sandbox/integration evidence; `removeItem` запрещён.

Resulting Trash URL не используется для собственного Undo, не persist-ится и не превращается в новую scan root.

## 7. No-follow path validation

Validation выполняется off-main и не вызывает SwiftUI.

1. Проверить `rootURL.isFileURL`, непустую chain и validity node IDs.
2. `lstat` original root URL; сравнить kind `.directory` и exact `(device, inode)` root identity.
3. Для каждого component проверить, что name — ровно один filesystem component: не empty, не `.`/`..`, без `/` и NUL.
4. Append component к security-scoped root URL с правильным directory hint; не использовать `resolvingSymlinksInPath()`.
5. `lstat` каждого полученного URL. Для ancestor требуется directory, не symlink, и exact expected identity/kind.
6. Для leaf сравнить identity и kind; symbolic-link leaf остаётся symlink и target не читается.
7. Проверить, что volume/device evidence совпало с snapshot, включая explicit device overrides.
8. Вернуть typed validated target или fail closed.

Validation всей chain нужна даже при совпадении leaf inode: ancestor symlink/replacement не должен silently изменить filesystem boundary. `stat` не заменяет `lstat`, поскольку следует symbolic links.

Перед Trash flow validation выполняется дважды:

- preflight до показа confirmation;
- повторно после user confirmation непосредственно внутри Trash adapter.

Если между ними объект изменился, операция не выполняется, snapshot помечается stale и предлагается Rescan.

## 8. Eligibility policy

Pure policy возвращает не Bool, а решение с причиной:

```swift
public enum FileActionDenial: Hashable, Sendable {
    case noRealSelection
    case snapshotNotCurrent
    case scanOrRefreshActive
    case identityUnavailable
    case scanRootProtected
    case visibleRootProtected
    case incompleteSubtree
    case inaccessible
    case volumeBoundary
    case unsupportedKind
    case actionAlreadyInProgress
    case invalidatedByEarlierAction
}

public enum FileActionEligibility: Hashable, Sendable {
    case allowed
    case denied(FileActionDenial)
}
```

### 8.1 Show in Finder

Разрешён для любого real node, включая scan root, symlink, package и hard-link member, если:

- snapshot всё ещё displayed и generation совпадает;
- identity chain доступна;
- нет executing Trash для этого subtree.

Finder может быть доступен на `staleWhileScanning`/`previousAfterFailedRescan`, потому что операция не изменяет filesystem, но live validation обязательна. Missing/changed item даёт stale error и Rescan affordance. Virtual `Other` недоступен.

### 8.2 Move to Trash

Разрешён только когда:

- selection — real node текущего snapshot;
- freshness `.current`;
- scan/refresh не активен;
- selected node не scan root и не current visual root;
- identity каждого chain component известна;
- selected subtree не имеет `.incompleteSubtree`, `.inaccessible` или `.volumeBoundary`;
- node не invalidated предыдущей action;
- другая Trash action/confirmation не активна.

`completedWithIssues` snapshot сам по себе не запрещает Trash: решение локально выбранному subtree. Но propagated `.incompleteSubtree` запрещает действие.

Special kinds:

- symbolic link разрешён; confirmation явно говорит «будет перемещена ссылка, target не затрагивается»;
- package разрешён как единый directory item с package warning;
- hard-link member разрешён, но UI предупреждает, что перемещается только одна directory entry и displayed size не является обещанием освобождённого места;
- filesystem kind `.other` в M4 запрещён до отдельной policy по device/FIFO/socket semantics;
- current visual root сначала требует **Up**, затем его можно выбрать как child и повторить action.

M4 не вводит неподтверждённый список macOS «системных путей». Scan root и volume boundary защищены всегда; Whole Mac/volume-root/critical-path policy проектируется в M5 до расширения selection scope.

## 9. Confirmation UX

Show in Finder не требует confirmation.

Trash confirmation появляется только после успешного preflight. Она содержит:

- точное display name;
- scan-root-relative path, с возможностью раскрыть полный path;
- kind: file/folder/symbolic link/package;
- logical и reported allocated sizes с текущими accounting labels;
- предупреждение, что размер не равен гарантированно освобождаемому пространству;
- relevant incomplete/hard-link/symlink/package warnings;
- recovery statement: объект перемещается в системную корзину, permanent delete не выполняется.

Кнопки: **Cancel** и destructive-role **Move to Trash**. Cancel/default focus безопасен. Нет «Don’t ask again» и удержания Option для bypass.

`⌘⌫` открывает ту же confirmation и никогда не вызывает service напрямую. Command активен только из focused Hygieia window и не перехватывает удаление текста в editor/control. Context menu и details button используют один feature action.

Confirmation привязана к `(scanGeneration, NodeID, expectedIdentity)`. Смена snapshot/root selection или начало scan закрывает её; stale confirmation нельзя подтвердить.

## 10. Ownership и concurrency

Один `@MainActor @Observable ScanFeatureModel` остаётся window state owner. Services injected через composition root.

```swift
enum FileActionPhase: Sendable {
    case idle
    case preparing(kind: FileActionKind, node: NodeID, generation: UInt64)
    case awaitingTrashConfirmation(TrashConfirmation)
    case movingToTrash(node: NodeID, generation: UInt64)
    case refreshingAfterTrash(InvalidatedSubtree)
    case failed(FileActionPresentation)
}

struct InvalidatedSubtree: Sendable {
    let root: NodeID
    let generation: UInt64
    let reason: InvalidationReason // .movedToTrash
}
```

Rules:

- только одна mutation operation на window;
- validation/Trash выполняются async off-main; AppKit hop скрыт adapter-ом;
- feature task захватывает generation/node/action nonce;
- late result игнорируется, если window/snapshot/selection authority сменились;
- confirmation cancel — нормальный no-op, не error;
- закрытие window отменяет feature task где возможно и освобождает UI state, но уже переданный macOS Trash request нельзя объявлять отменённым без system result;
- кнопка Cancel Scan не отменяет executing Trash;
- MainActor не делает `lstat`, path-chain IO или synchronous Trash work;
- URL/paths не записываются в telemetry/logs; M4 telemetry отсутствует.

## 11. Success, failure и snapshot refresh

### 11.1 Finder

После successful validation adapter отправляет Finder request. Snapshot не меняется и rescan не запускается. Если validation возвращает missing/changed, UI показывает scoped error и предлагает Rescan.

### 11.2 Trash success

Success существует только после системного receipt/mapping. Затем:

1. Добавить `InvalidatedSubtree` overlay к old snapshot.
2. Перевести freshness в `.staleAfterFileAction`.
3. Перенести selection на parent moved node; navigation root не меняется, поскольку current visual root protected.
4. Dim/disable moved subtree в chart/list/details, но не удалять его из `FileTree` и не перераспределять old totals.
5. Показать status «Moved to Trash — refreshing scan» без claim о freed bytes.
6. Автоматически запустить полный rescan original selected root, сохраняя folder access lease.
7. Перед публикацией complete new snapshot UI атомарно отбрасывает old selection, navigation history, rows, chart projection/layout, marked items и invalidation; только затем новый tree получает собственные snapshot-local IDs и снова разрешает Trash. UI entry points дополнительно fail closed для ID, отсутствующего в текущем tree.

M4 намеренно не делает targeted tree surgery. Текущий scanner умеет строить whole-root immutable snapshot; безопасный subtree merge/reconciliation относится к M9. Это дороже, но сохраняет source-of-truth и не притворяется инкрементальным update.

Если post-action rescan failed/cancelled:

- old tree остаётся `.staleAfterFileAction` с invalidation overlay;
- cancelled partial result не заменяет его автоматически;
- Trash остаётся disabled до successful full rescan или выбора другой root;
- Finder для unaffected real node может работать через live validation;
- UI предлагает **Rescan** и честно сообщает, что displayed sizes устарели.

До завершения refresh нельзя запускать вторую Trash action. M4 не пытается переносить old `visibleRoot`, history или selection raw IDs в new snapshot.

### 11.3 Trash failure

Failure не добавляет invalidation и не меняет sizes/tree. UI сохраняет selection и показывает actionable category. Если failure — identity/path mismatch, snapshot переводится в stale state; permission/read-only/Trash unavailable не изображаются как успешное перемещение.

## 12. Error model

```swift
public enum FileActionError: Error, Equatable, Sendable {
    case invalidTarget
    case invalidPathComponent(node: NodeID)
    case rootMissing
    case rootChanged
    case ancestorMissing(node: NodeID)
    case ancestorChanged(node: NodeID)
    case symbolicLinkInAncestor(node: NodeID)
    case targetMissing
    case targetChanged
    case permissionDenied(code: Int32)
    case readOnlyFileSystem(code: Int32)
    case volumeUnavailable(code: Int32)
    case trashUnavailable(code: Int32?)
    case system(domain: String, code: Int)
}
```

Presentation categories:

- **Item changed or moved:** rescan required, no mutation attempted;
- **Permission denied:** explain selected-root/read-write limitation, no escalation button;
- **Read-only volume / Trash unavailable:** item remains, use Finder/manual system handling;
- **Volume unavailable:** retain stale context, choose/rescan after remount;
- **Unexpected system failure:** item presumed unchanged unless receipt proves otherwise.

No error handler falls back to `removeItem`, shell `rm`, elevated helper or direct `.Trash` path.

## 13. Sandbox и permissions

M4 replaces:

```text
com.apple.security.files.user-selected.read-only = true
```

with:

```text
com.apple.security.files.user-selected.read-write = true
```

Оба entitlement одновременно не нужны. App Sandbox остаётся enabled. Не добавляются all-files, privileged-file-operations, bookmarks или Full Disk Access entitlement.

Read-write entitlement означает только возможность читать/писать явно выбранные через Open/Save dialog files/folders. M4 продолжает использовать Powerbox URL текущего `NSOpenPanel` selection. Поскольку persistent bookmark не разрешается, M4 не вызывает `startAccessingSecurityScopedResource()` по предположению и не создаёт URL заново из String.

Operational gates:

- проверить signed entitlements через `codesign`;
- manual sandboxed Trash для regular file, directory, package и symlink внутри выбранной folder;
- проверить home/APFS и removable local volume, если Trash доступна;
- отдельно проверить read-only volume и permission denial;
- подтвердить, что symlink target не перемещён;
- подтвердить поведение collision имени в Trash по resulting URL;
- проверить Finder reveal under sandbox.

Успешный unsigned build не доказывает эти gates.

## 14. Accessibility и status

- Finder/Trash actions доступны в details, context menu и application menu;
- labels называют объект и действие, не используют generic «Delete»;
- disabled action имеет discoverable explanation в details;
- confirmation читается VoiceOver в порядке name → path → kind/sizes → warnings → buttons;
- mutation progress объявляется один раз при start и один раз при success/failure;
- stale-after-action banner доступен keyboard/VoiceOver и содержит Rescan action;
- focus после Cancel возвращается к action; после success — к parent/details/status;
- color/dimming invalidated subtree не является единственным сигналом.

## 15. In-memory action status

Roadmap phrase «action audit/status» в M4 означает только bounded presentation state:

```swift
struct LastFileActionStatus: Sendable {
    let kind: FileActionKind
    let outcome: Outcome
    let displayName: String
    let completedAt: Date
}
```

Хранится максимум last status текущего window/session. Absolute path, Trash URL, inode/device и error payload не persist-ятся и не отправляются наружу. Это не compliance audit log.

## 16. Testing strategy

### 16.1 Domain/identity tests

- identity store count/known bitmap/device overrides;
- inode `0` не путается с unavailable;
- primary-device lookup и sorted override binary search;
- scanner-built nodes имеют identity, включая root/symlink/volume boundary;
- hard-link members имеют одинаковую identity;
- `FileNode` stride остаётся 40 bytes;
- fixture without identities не crash-ит, но Trash denied;
- memory bytes/node измеряются, а не выводятся из source declaration.

### 16.2 Policy tests

Table-driven matrix для Finder/Trash:

- real/Other/no selection;
- current/stale/partial/stale-after-action;
- scan root/current visual root/ordinary child;
- incomplete/inaccessible/volume boundary/package/symlink/hard link/other kind;
- active scan/action/invalidation;
- identity known/unavailable.

Каждый denial reason проверяется, чтобы UI не дублировал policy собственными Bool conditions.

### 16.3 Resolver tests in owned temporary root

- root/file/directory identity success;
- unicode, spaces, leading dot и long valid component;
- reject empty, `.`, `..`, slash/NUL component;
- missing/renamed/replaced root, ancestor и leaf;
- ancestor replaced by symlink pointing inside и outside root;
- leaf symlink validation не следует target;
- hard-link identity;
- device mismatch/volume override;
- race: replace leaf after preflight, before execution validation;
- path depth up to configured scanner limit;
- permission failure where reproducible without changing external data.

Fixtures создаются и удаляются только внутри owned temporary directory. Resolver tests не вызывают real Trash.

### 16.4 Service/feature tests

- Finder fake receives validated URL once; missing target receives zero calls;
- Trash fake success/failure/mapping-missing/late callback;
- confirmation Cancel performs zero service calls;
- command/context/details share one confirmation path;
- marked batch excludes parent/descendant overlap, validates every target again in the service, stops at the first failure and starts one refresh only after its terminal state;
- snapshot generation change invalidates confirmation/result;
- one mutation at a time;
- success creates invalidation, selects parent and starts exactly one action refresh;
- failure leaves tree/totals unchanged;
- action refresh complete replaces snapshot;
- action refresh failed/cancelled preserves stale old snapshot and disables Trash;
- no scanner invocation for Finder;
- no permanent-delete symbol/API in production source (`removeItem`, `unlink`, `rmdir`, shell delete checked by repository guard scoped to FileOperations/App actions).

### 16.5 UI/manual integration

- VoiceOver and Full Keyboard Access confirmation/status flow;
- `⌘⌫` does not bypass confirmation or interfere with text editing;
- Finder selects exact file/symlink/package;
- sandboxed `NSWorkspace.recycle` returns mapping and item appears in Trash;
- name collision, permission denial, read-only volume, removable volume;
- symlink target survives;
- app close while request is in flight;
- actual signed entitlement inspection.

Automated CI does not place artifacts into the user's real Trash. Concrete Trash smoke uses a uniquely named manual fixture and cleanup/restoration through Finder; it is an operational gate, not a broad destructive test.

## 17. Benchmarks and measurements

M4 performance work is limited to changes introduced by action safety:

| ID | Dataset | Measure |
|---|---|---|
| I01 | identity store 1M nodes, one device | allocated bytes, bytes/node, construction time |
| I02 | identity store 5M nodes + 0.1% device overrides | peak RSS, lookup p50/p95 |
| V01 | path depths 1/16/128/1024 in temporary tree | validation latency/syscalls |
| V02 | 100k in-memory identity lookups | binary-search/bitmap overhead |
| F01 | refresh-after-action on existing M1 benchmark roots | duration/status responsiveness, not an optimization claim |

Targets:

- `FileNode` remains 40-byte stride;
- one-device identity sidecar capacity approximates 8.125 bytes/node before collection overhead, verified by measurement;
- lookup is `O(1)` for inode/known/primary device and `O(log overrides)` only for rare device override;
- UI/MainActor has zero blocking filesystem calls;
- no absolute latency promise for network/read-only/removable volumes (M4 actions are local selected roots; M5 decides broader policy).

After first accepted baseline, >10% memory or >20% validation regression on the same hardware/dataset needs explanation or correction. Performance targets never weaken identity comparison or symlink policy.

## 18. Implementation slices

1. Identity sidecar contracts/builder plumbing, invariants, tests and I01/I02 measurement.
2. `HygieiaFileOperations` target, action types, policy and no-follow resolver tests.
3. AppKit Finder adapter, feature state and Finder UI/commands.
4. Trash adapter with repeated validation, confirmation and fakes.
5. Invalidation overlay and distinct full-root action-refresh flow.
6. Entitlement change, signed sandbox integration gates and accessibility/UI tests.
7. Documentation reconciliation and accepted M4 evidence report.

Каждый slice сохраняет рабочими M1 CLI/scanner, M2 app flow и M3 visualization. M5 не начинается внутри M4.

## 19. Acceptance criteria

M4 принят, когда:

- production app не содержит permanent-delete API/path;
- `FileTree` предоставляет compact per-node identity evidence без изменения node stride;
- target reconstruction начинается от original selected-root URL и валидирует всю chain через `lstat`;
- ancestor/leaf identity change и symlink replacement fail closed;
- Finder/Trash не работают для virtual `Other`;
- Trash eligibility/confirmation соответствует policy, включая root/visible-root/incomplete protections;
- symlink Trash перемещает link, target остаётся;
- success существует только после system mapping/receipt;
- failed Trash не меняет tree/totals как success;
- successful Trash создаёт stale invalidation и ровно один full-root refresh;
- failed/cancelled action refresh остаётся честно stale и блокирует следующую Trash;
- read-write sandbox entitlement проверен в signed app;
- unit/app/UI checks и manual Finder/Trash/symlink gates выполнены;
- identity memory baseline записан;
- generated/build artifacts не добавлены в git.

## 20. Намеренно открытые вопросы

- можно ли уменьшить residual TOCTOU через descriptor-relative APIs, не ломая system Trash behavior;
- достаточно ли `NSWorkspace.recycle` для всех будущих local volume classes;
- какой critical-path policy нужен перед Whole Mac M5;
- нужен ли Restore/Undo UX после product/safety review;
- как M9 atomic reconciliation заменит M4 full-root refresh;
- сохранять ли visual root/selection между snapshots по identity chain;
- нужны ли birthtime/file-resource-identifier evidence сверх `(device, inode)` в M7;
- разрешать ли Trash current visual root в более зрелом UX.

Они не блокируют conservative M4 implementation.

## 21. Platform references

- Apple определяет `com.apple.security.files.user-selected.read-write` как read-write access к явно выбранным через Open/Save dialog files: [user-selected read-write entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write).
- `NSWorkspace.activateFileViewerSelecting` открывает Finder и выбирает переданные URLs: [Finder selection](https://developer.apple.com/documentation/appkit/nsworkspace/activatefileviewerselecting%28_%3A%29).
- `NSWorkspace.recycle` перемещает URLs в Trash в манере Finder и возвращает mapping исходных и новых URLs: [NSWorkspace recycle](https://developer.apple.com/documentation/appkit/nsworkspace/recycle%28_%3Acompletionhandler%3A%29).
- Apple manual page фиксирует, что `lstat` возвращает metadata самой symbolic link, тогда как `stat` следует target: [lstat(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/lstat.2.html).
- Security-scoped URL нельзя безопасно заменять строковым path; resolved scopes требуют balanced start/stop access: [NSURL security-scoped URLs](https://developer.apple.com/documentation/foundation/nsurl).
