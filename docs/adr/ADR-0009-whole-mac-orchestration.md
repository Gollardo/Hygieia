# ADR-0009 — Explicit local roots for Scan This Mac

Status: accepted for M5 implementation, 2026-09-17, under the request to complete M5.

## Context

M5a scans one Powerbox-selected root. Whole Mac needs orchestration without a
synthetic FileTree, silent mount traversal, unbounded retained snapshots, or an
unsupported claim of full filesystem access. App Sandbox and TCC are separate.

## Decision

- Present discovered local volumes as an explicit checklist. Internal volumes
  default on; removable/external volumes require opt-in. Network volumes are out
  of scope. Discovery failure/omission is visible, never equivalent to no disks.
- Expose the boot System `/` and mounted Data `/System/Volumes/Data` separately.
  Exclude other private `/System/Volumes` mounts. Never sum volume results or
  capacities: firmlinks, aliases, APFS shared containers and blocks preclude a
  proven unique physical total. Same standardized root paths are deduplicated.
- Run one root at a time using the existing scanner. A mount boundary is always
  skipped inside a tree; selecting another volume explicitly adds a separate scan.
- Real System/Data inspection on this host found equal `st_dev` despite different
  `statfs` filesystems. Foundation therefore compares `f_fsid` for parent/child
  directories using no-follow descriptors and identity validation, in addition to
  the existing device check. Unknown filesystem identity fails closed with an issue.
  A real shallow System/Data test and reproducible before/after fixture measurement
  accompany this correctness change; no performance improvement is claimed.
- Before every root, rediscover its volume; require native NSOpenPanel OK and the
  exact requested root, then rediscover again and pass observed device/inode to
  the scanner. Cancelled selection, replacement, unreadable metadata and subfolder
  selection are explicit report outcomes, not successful whole-volume coverage.
- Retain compact reports (up to 64 roots, 20 issue samples per root), not every
  tree. A report can start a fresh single-root Explorer scan. Existing Explorer
  snapshot and one active scanner tree are the only concurrently retained trees.
- Cancellation stops the queue immediately but awaits the active OS call. UI and
  help remain responsive; no new run may accumulate behind a blocked operation.
- FDA status is **not verified**. Explain System Settings, sandbox selection,
  protected system data and restart/rescan. Never read private databases to infer
  FDA, modify TCC, add entitlements, or silently escalate permissions.
- Whole Mac reports are always labelled limited to selected accessible roots.
  Even a root with no observed issues is not a claim that all Mac data was read.

## Alternatives

A merged virtual root complicates node identity, file actions, overlap accounting
and memory. Retaining all FileTrees multiplies RAM. Disabling App Sandbox or adding
a helper expands authority. All are unnecessary for M5 and rejected here.

## Consequences and verification

Opening an older volume report requires a rescan. No persistence/migration, server
or new dependency is introduced. APFS exact physical accounting remains M7.
Automated orchestration/policy/error tests and owned APFS integration fixtures are
required. Native Powerbox, FDA denied/granted and eject acceptance are recorded
separately; hosted XCTest entitlements cannot establish shipping-app access.

Sources: [Apple sandbox access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox),
[NSOpenPanel](https://developer.apple.com/documentation/AppKit/NSOpenPanel),
[macOS file access controls](https://support.apple.com/en-ca/guide/security/secddd1d86a6/web),
[APFS roles](https://support.apple.com/en-ca/guide/security/seca6147599e/web).
