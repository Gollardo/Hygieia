# M5a verification — 2026-09-17

Scope: [single-root local volume coverage](M5_LOCAL_VOLUME_COVERAGE.md).
Environment: Apple Silicon arm64, macOS 26.6.2 (25G83), full Xcode toolchain selected
per command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Automated checks

| Check | Result |
|---|---|
| `swift test` | 24 passed, 0 failures; 6 new volume/coverage tests |
| `swift run hygieia-verify` | Existing 9 Core/integration checks passed |
| Xcode `Hygieia` test plan, macOS arm64 | 34 App tests + 1 UI smoke passed; 13 new App tests |
| Xcode Release build | Passed |
| APFS disk-image integration script | Passed: real mount boundary, explicit mounted-root scan, read-only mounted-root scan |
| `git diff --check` | Passed |

Initial sandboxed build attempts could not write compiler caches. Checks were rerun
with approved build/test permissions and the full Xcode toolchain. Compile mistakes
in the initial new test harness were corrected before the final passing runs.
No test operation targets user files or the user's Trash.

## Render review

Actual SwiftUI renders, not mockups, using owned synthetic data:

- [Compact source chooser](assets/m5a/empty-compact.png), 980 × 680 points:
  long English/Cyrillic disk names, unknown capacity and 120 GB available of 1 TB.
- [Coverage report](assets/m5a/coverage.png), 520 × 480 points:
  unavailable source, original root, timestamps, policy and access-denied evidence.
  The report scrolls to bounded relative path examples below the initial viewport.
- [Unavailable Explorer](assets/m5a/unavailable-content.png), 1440 × 1024 points:
  retained 4 KB observed data, consistent warning labels, Trash disabled.

Also reviewed the 1440 × 1024 source chooser and discovery-failure/retry render;
these are reproducible XCTest attachments rather than duplicate repository assets.
Compared the entry composition with `assets/lustral-field-empty-v2.jpeg` and existing
source chooser code. The previous reference has different window chrome and an older
folder-only chooser, so the comparison is of visual hierarchy and material, not a
pixel-perfect baseline. No palette, font, asset or geometry language changes.

Review found and corrected a misleading zero-byte header while projection was
pending and truncation of the unavailable footer label. Sizes now come directly
from the current FileTree node. Unknown capacity has no fabricated meter. Warning
states use text and icons as well as color. No new animation was introduced.

These renders do not prove VoiceOver, keyboard scrolling or system Reduce Motion
acceptance; those remain manual gates. Long example paths were also inspected in
the earlier report render before the added unavailable-source explanation moved
them below the initial viewport.

## Sandbox/platform evidence and limits

The separate Release app built and launched. Its signature is ad-hoc with Hardened
Runtime; entitlements include App Sandbox and user-selected read-write (plus the
existing development `get-task-allow`). Unlike XCTest hosting, it has no injected
absolute-path read exception. This is not Developer ID/notarized release evidence.

The native automation clicked Choose a Folder. Runtime logging showed
`beginServicePanel`, but the tool exposed only the main window, not the separate
Powerbox panel. Successful folder acceptance/scanning through that panel could not
be verified. The test app was closed; no FDA setting or access entitlement changed.
A pre-existing accessory fitting-width warning was also observed; it is not proven
to be the cause. Production Powerbox acceptance remains OPEN.

Real owned APFS image tests establish same-device traversal and readable read-only
root behavior for that fixture. They do not establish physical surprise-eject
latency, APFS System/Data/firmlink coverage, network behavior, FDA denied/granted,
Finder/Trash or signed distribution support.

## Remaining risks / next step

- Root validation observes a moment in time; later source changes still require
  existing action identity validation. Snapshot device/inode is not persistent identity.
- Blocking filesystem calls and physical eject may outlast cooperative cancellation.
- Discovery is refreshed on request; this slice does not continuously monitor mounts.
- Complete the ordinary signed Powerbox/accessibility and removable-device matrix,
  then accept the separate multi-root/APFS/FDA design before Whole Mac orchestration.

No DB migrations, dependencies, permanent-delete APIs, source-tree schema changes,
performance claims or multi-root features were added.
