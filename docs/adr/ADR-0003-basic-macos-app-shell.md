# ADR-0003: Basic sandboxed macOS app shell

Status: Accepted
Date: 2026-08-30

## Context

M1 now provides local SwiftPM library products, a bounded scanner, progress and complete/cancelled `ScanResult`. M2 must expose this core through a real macOS app without duplicating scanner sources, weakening filesystem boundaries or prematurely implementing Sunburst/file operations/Whole Mac.

SwiftPM alone builds executables and libraries but does not replace the Xcode-owned app bundle, signing, entitlements, resources and UI test configuration required for a native sandboxed Mac app.

## Decision

- Create a macOS 14+ SwiftUI application target with Xcode's normal project workflow; do not hand-author `project.pbxproj` and do not add a project generator.
- Keep M1 as the root local Swift package. App target links `HygieiaDomain`, `HygieiaScannerCore` and `HygieiaFoundationScanner` products; source files are not duplicated into app targets.
- Enable App Sandbox with `com.apple.security.files.user-selected.read-only`. No persistent bookmarks in M2.
- Select exactly one folder through a MainActor AppKit `NSOpenPanel` adapter and retain one balanced folder-access lease for scan/result/rescan lifetime.
- Use one `@MainActor @Observable` feature model per window. It owns presentation state and scan-scoped tasks; scanner owns filesystem concurrency.
- Do not publish or copy a live tree during scan. M2 shows coalesced progress and renders only complete/cancelled immutable results.
- Present at most 200 Largest Items using an off-main `O(N log K)` bounded projection; UI never creates per-node view models for the full tree.
- Default to reported allocated metric with explicit non-reclaimable wording and allow an in-memory switch to logical size.
- Use native SwiftUI `Table`, toolbar/commands and a simple details pane. Sunburst, Finder/Trash, Whole Mac and settings are absent.

The exact specification is `docs/M2_BASIC_MACOS_APP.md`.

## Alternatives Considered

- **SwiftPM executable as the shipping app:** rejected because M2 needs a normal `.app` bundle, entitlements, signing, scenes/resources and XCUITest integration.
- **Compile Domain/Scanner sources directly into the app target:** rejected because it duplicates the target graph and can produce divergent build settings/behavior.
- **Add XcodeGen/Tuist:** rejected; the project is small and no generator dependency is justified.
- **No App Sandbox until release:** rejected because filesystem access behavior should be validated under the actual security boundary from the first UI milestone.
- **Read-write user-selected entitlement now:** rejected by least privilege; M2 only reads. M4 must explicitly revisit entitlement consequences for Trash.
- **Persistent security-scoped bookmark now:** rejected because M2 does not reopen folders across launches.
- **View directly owns/awaits scanner:** rejected because lifecycle, stale callbacks and testability require one feature-state owner.
- **Full hierarchy object model or all-node sorted rows:** rejected because memory/UI work would scale with millions of nodes.
- **Progressive `FileTree` snapshots:** rejected until a design avoids large COW copies/shared mutation.
- **Show disabled future controls:** rejected; M2 exposes only working folder-scan behavior.

## Consequences

Positive:

- app permissions are least-privilege and testable early;
- M1 remains usable independently from CLI and app;
- state transitions/cancellation can be unit tested without filesystem access;
- table memory is bounded independently of tree size;
- MainActor is isolated from scanning and projection work;
- M2 remains small and does not pre-implement later milestones.

Negative/limitations:

- implementation introduces a versioned Xcode project in addition to `Package.swift`;
- signing team and final bundle identifier require owner/release configuration;
- users reselect the folder after each launch;
- M4 will need an explicit entitlement change from read-only to read-write or a revised file-operation design;
- no result rows appear until complete/cancelled `FileTree` exists;
- one app window and K=200 Largest Items are deliberate M2 constraints, not final information architecture.
