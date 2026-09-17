# M5a — Local volume coverage

Status: implemented single-root slice; full M5 and release acceptance remain open.
Decision: [ADR-0008](adr/ADR-0008-single-volume-coverage.md), approved implementation scope.

## Scope

One explicitly selected local root, one immutable FileTree and the existing
Explorer. App Sandbox and user-selected read-write entitlements are unchanged.
There is no database, backend service, migration, persistent bookmark, new dependency,
FSEvents monitor, FDA switch or multi-root Whole Mac command.

## User behavior

- Local browsable volumes remain entry points into NSOpenPanel. Clicking a disk
  rechecks its discovery identity and mount URL before opening the panel; the URL
  actually selected by the user determines the scan root, including a subfolder.
- Discovery failure is distinct from a successful empty list. A failed refresh
  preserves previous entries with a warning. Partial metadata failure explicitly
  marks the list incomplete. Refresh is available without blocking folder selection.
- Capacity is optional. Negative values are discarded; inconsistent available/total
  values show `Capacity unavailable`. A meter exists only for a known positive total
  and known available capacity within that total. Reported ordinary available
  capacity replaces the earlier important-usage capacity labelled as free space.
- A completed traversal with recorded issues or an incomplete root is labelled
  `Coverage incomplete`. Cancellation and stale results have their own labels.
- `Scope & Coverage` is available for every displayed snapshot. It shows the original
  root, snapshot device evidence, timestamps, fixed traversal policy, issue counts
  by category and at most 20 retained path examples. It never claims a coverage
  percentage, full Mac access or reclaimable bytes.
- Permission failure does not diagnose FDA status. Network roots are rejected;
  unknown locality is an availability error, not a claim that the root is networked.

## Backend and domain contract

`ScanRequest.expectedRootIdentity` is optional on explicit selection. Rescan and
post-action fallback scan pass the previous snapshot's `(device, inode)` identity.
An identity mismatch fails before directory enumeration; accepting a replacement
requires a new explicit selection. Existing snapshot IDs do not survive replacement.

Before normal publication, FoundationScanner performs one no-follow root identity
check on the filesystem adapter queue. Missing/replaced/unreadable root produces
`sourceUnavailable`; the coordinator retains collected evidence, marks the root
inaccessible/incomplete, and validates the immutable tree through the existing
builder. The feature publishes non-current freshness and disables Trash. Finder
still uses its existing per-action identity validation.

If cancellation is already requested, no additional final metadata call starts;
the existing partial-result contract applies. A check already in flight remains
cooperative. No absolute eject/cancellation latency is claimed.

`ScanResult.hasIncompleteCoverage` is derived from completion, issues and root
flags. `ScanCompletion.complete` describes traversal termination, not full coverage.
Source identity comes from the existing compact sidecar; there is no second tree
or persistent identity claim. Mount identity is not a permanent identifier across
boots or remounts.

Directory traversal still stops at a different `st_dev`. Symlinks are recorded,
never followed. Hard-link/accounting semantics and the visualization cap are unchanged.
No capacity value is used to fill gaps in the FileTree or estimate missing bytes.

Discovery/selection tasks are generation-checked at publication and after teardown.
A cancelled discovery clears its busy state; a failed discovery requires explicit
retry instead of an automatic loop. A queued picker cannot open after teardown.

## Tests and reproducible checks

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run hygieia-verify
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Hygieia.xcodeproj -scheme Hygieia \
  -destination 'platform=macOS,arch=arm64' test
python3 Tests/Integration/volume_boundary_smoke.py .build/debug/hygieia
```

The image smoke creates an owned temporary APFS disk image. It verifies a real
mount boundary, explicit mounted-root scanning and read-only mounted-root scanning.
It detaches only its fixture; failed detach prevents recursive fixture cleanup.
It does not simulate surprise physical eject.

Tests cover capacity unknown/zero/inconsistent states; discovery failure/retry,
cancellation and teardown; disappeared source before picker; selected subfolder
provenance; rescan identity; source-unavailable Trash denial; bounded issue samples;
foreign-device/no-follow traversal; directory replacement and disappearance on the
real filesystem; and independent traversal completion/coverage states.

## UI verification

Use [UI_CHANGE_CHECKLIST.md](UI_CHANGE_CHECKLIST.md) and Lustral Field tokens.
The test-only NSHostingView harness renders actual SwiftUI views with synthetic,
non-private long Cyrillic/English names and realistic capacity magnitudes. It
attaches PNGs to the xcresult and writes temporary copies for visual inspection.
It is not a production preview route or a substitute for VoiceOver testing.

Changed roles: measured capacity, unknown metadata, discovery warning/retry,
completed/incomplete/cancelled/stale/source-unavailable status and coverage detail.
Warnings use label/icon plus existing amber; healthy completion uses existing aqua.
No new animation is introduced. System Reduce Motion handling remains unchanged.

Verification results and retained renders: [M5_VERIFICATION.md](M5_VERIFICATION.md).

## Remaining gates and next step

- Physical removable surprise eject and slow/blocking local-device I/O.
- Developer ID signed distribution, production Powerbox paths, Finder/Trash and
  VoiceOver/keyboard/Reduce Motion acceptance on supported macOS versions.
- FDA denied/granted behavior, APFS System/Data/firmlink overlap and root coverage.
- Memory/lifecycle policy for retaining multiple large snapshots.
- An accepted multi-root design before implementing Whole Mac orchestration.

Root validation is point-in-time evidence, not continuous monitoring. A source may
change after publication; existing action validation is still required. No performance
improvement or persistent filesystem identity guarantee is claimed.

## Platform references

- [Apple: user-selected read-write entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)
- [Apple: accessing files from App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple: reported available capacity](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacitykey)

These references inform access/capacity boundaries; passing unit tests does not
prove all deployment/access scenarios. In particular, Xcode hosted tests inject
additional test entitlements and must not be used as production sandbox evidence.
