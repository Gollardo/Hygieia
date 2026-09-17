# M5 verification — 2026-09-17

Scope: [M5a](M5_LOCAL_VOLUME_COVERAGE.md), [Whole Mac](M5_WHOLE_MAC.md),
[ADR-0009](adr/ADR-0009-whole-mac-orchestration.md).
Environment: Apple Silicon arm64, macOS 26.6.2 (25G83), Xcode 26.6 (17F113).
Full toolchain selected with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

**Status: implementation complete; milestone acceptance remains open for the FDA
configuration matrix and physical removable-device acceptance.** Do not equate
successful build/tests with access to every Mac file or distribution readiness.

## Automated evidence

| Check | Result |
|---|---|
| `HYGIEIA_APFS_INTEGRATION=1 swift test` | 27 passed, 0 failures, including real System/Data and owned APFS detach |
| `swift run hygieia-verify` | 9 Core/integration checks passed |
| Xcode App/UI test plan | 48 App tests + 3 UI tests passed, 0 failures |
| Separate Xcode Release build | Passed, app launched and used in native smoke |
| `volume_boundary_smoke.py` | Passed: real mount boundary, direct root, read-only mount |
| `mount_boundary_benchmark.py` | Before/after recorded, correctness totals asserted in every run |
| `git diff --check` | Passed |

New tests cover discovery errors/unknown/limits, explicit external opt-in,
deduplicated roots, native acceptance vs Cancel, System/Data policy, serial queue,
source replacement/disappearance, permission/incomplete results, bounded samples,
provenance, stopping blocked I/O without accumulating sessions, picker cancellation,
teardown/late result/lease release, and exclusion of concurrent single-root work.

Real APFS integration deterministically detaches an owned image between directory
read and final publication. The result retains evidence, becomes unavailable and
incomplete, and a rescan rejects the host directory now occupying the old mount path.
This proves the controlled detach transition, not physical hardware stall latency.

The System/Data test performs only shallow metadata enumeration of `/` and Data,
never scans Users or reads user-file contents. It proves `/Users` is a boundary from
System and an ordinary same-filesystem directory from Data. The first real test
exposed a signed `dev_t` conversion crash on a system mount; scanner/action validator
now preserve its unsigned bit pattern. Final tests passed after that correction.

## Native Release acceptance

A separately built, ad-hoc signed Release app was launched from
`/tmp/hygieia-m5-release/Build/Products/Release/Hygieia.app`; process path and
entitlements were checked. It has App Sandbox + user-selected read-write and the
existing development `get-task-allow`, **no XCTest absolute-path read exception**.
No entitlement, FDA/TCC or system protection was changed for these checks.

Verified through the actual system panel and app UI:

1. Select an owned `/private/tmp/hygieia-m5-native-*` folder using the native **Choose**
   button. Explorer displayed its `M5-native-evidence.txt`, Logical 26 bytes and
   Allocated (reported) 4 KB. This is real Powerbox OK → scanner → FileTree → UI.
2. Create an owned 64 MB APFS image and attach it as a browsable local volume.
   Refresh Whole Mac: **Hygieia M5 Native** appears unchecked. A `-nobrowse` mount
   is intentionally absent from the browsable list, not silently added to scope.
3. Uncheck Boot/Data, check only that fixture, start, accept **Scan Disk** in native
   NSOpenPanel. Report shows **No issues observed in this root**, root path,
   device/inode, timestamps, Logical 57 bytes / Allocated 8 KB (including system
   image entries); overall status remains **Scan ended · limited coverage**.
4. **Open Full Disk Access Settings** opens the actual macOS **Доступ к диску** pane.
   Hygieia was not present in the visible FDA list. No switches were changed; this
   observation is not a substitute for the denied/granted configuration matrix.
5. Close the app, detach only the owned image, then remove its owned temporary tree.

An attempted keyboard-only XCTest selection harness failed under the active input
layout (letters/paste shortcuts did not reach the Go to Folder field). No passing
Powerbox claim is based on that harness; it was replaced by a stable native Cancel
UI test and the successful separate-Release native verification above. No production
test backdoor, permissive entitlement or fake panel grant was introduced.

## UI review

Actual SwiftUI renders with existing Lustral Field tokens:

- [Scope planning](assets/m5b/plan.png): internal checked/external unchecked, long
  Cyrillic/English names, explicit access help, scrollable content and fixed controls.
- [Incomplete report](assets/m5b/incomplete.png): observed values, timestamps,
  permission issue count, bounded samples, rescan action and limited overall status.

Planning, incomplete and discovery-error renders were inspected; native Release
additionally covered real volume values, panel authorization and completed limited
report. Compared with the prior [M5a compact entry](assets/m5a/empty-compact.png)
and accepted Lustral Field direction. No palette/font/dependency or animation added.
Existing warning states remain textual as well as visual; long names wrap. No
per-filesystem-node UI work was added. VoiceOver user acceptance is not established
by static renders/XCTest; prior cross-milestone accessibility gates remain open.

## Measurement

The new `fstatfs` correctness checks add open/fstat/fstatfs/close for directories.
Reproduce with `python3 Tests/Integration/mount_boundary_benchmark.py .build/debug/hygieia`.
Fixture: 401 directories, 4,000 files, 512,000 logical bytes, zero issues; one warmup
plus five measured CLI runs. [Raw measurements](assets/m5b/mount-boundary-measurements.json):
median before 0.2196 s, after 0.1775 s. The ranges overlap, cache/background build
activity differed, and this small Debug dataset **does not establish an improvement**
or a large-tree regression bound. Representative throughput/RSS profiling stays M6.

## Remaining acceptance and risks

- FDA denied/granted: **OPEN**. Enabling FDA expands access to protected data and
  requires explicit confirmation/user authentication. The app never guesses FDA
  status. Unit tests cover denied permissions independently of any presumed cause.
- Physical external/removable surprise-eject/stalled hardware: **OPEN**. Controlled
  APFS-image detach, unavailable source and mocked blocked I/O passed; no physical
  device was supplied for the remaining hardware matrix.
- Filesystem checks are point-in-time. This is not atomic namespace traversal and
  does not solve all ancestor replacement races. Existing per-action validation
  remains mandatory. Blocking OS calls can outlast cooperative cancellation.
- Developer ID, notarization, final signing, M4 Finder/Trash and full accessibility
  are existing release gates; this task does not claim to close them.
- Network volumes are explicitly excluded. SQLite/migrations, FSEvents, exact APFS
  shared-block accounting, privileged helpers and M6 optimization remain out of scope.

Next step: complete the two M5 platform rows above, record actual evidence, then
mark M5 closed in the roadmap. The automated implementation is ready for that review.
