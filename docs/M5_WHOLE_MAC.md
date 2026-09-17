# M5 — Scan This Mac

Implementation contract: [ADR-0009](adr/ADR-0009-whole-mac-orchestration.md).
This extends [M5a](M5_LOCAL_VOLUME_COVERAGE.md); platform acceptance is tracked in
[M5 verification](M5_VERIFICATION.md). Implementation is not a claim that every Mac
file can be read or that the unsigned distribution is production-ready.

## User flow

1. Choose **Scan This Mac…** in the toolbar. Read access/coverage help.
2. Review local roots. Internal, non-removable disks default on. External/removable
   disks require explicit selection; network storage and hidden service mounts are
   excluded. System `/` and Data `/System/Volumes/Data` are separate scopes.
   Foundation may omit Data from its mounted-volume list; a no-follow descriptor
   confirms the exact local mount before adding that candidate explicitly.
3. Start **Scan Selected Roots…**. For each root, confirm that exact disk in the
   native selection panel. Use the native confirmation button; Cancel grants no
   selection. Choosing a subfolder reports that disk as not authorized; a folder
   scan remains available through **Choose Folder**.
4. Inspect per-root outcomes: not selected, queued, authorizing, scanning, no issues
   observed, incomplete, unavailable, failed, not authorized, cancelled. Sizes are
   absent until evidence exists; zero is never substituted for unknown.
5. Stop prevents further roots and requests cooperative cancellation. A blocked OS
   call can delay completion, but the UI remains usable and another scan cannot
   accumulate additional workers. The report can be closed and reopened while busy.
6. **Rescan Selected Roots** rechecks availability/access. **Rescan in Explorer**
   opens normal single-root selection and creates a fresh tree. Reports do not
   retain all volume trees. **Refresh Disks & Reset Report** explicitly discards
   report history and rebuilds the list/default selection.

## Access

FDA is labelled **not verified**. Permission denied is evidence of incomplete
coverage, not a diagnosis of TCC, sandbox, ACL or SIP state. Help always includes
System Settings → Privacy & Security → Full Disk Access, adding Hygieia, restarting
and rescanning. The button uses a best-effort Settings deep link; manual instructions
remain available if the link fails or macOS changes its destination.

Only the user changes system privacy settings. No TCC database probes, privilege
escalation, helper, persistent bookmarks or additional entitlements are added. FDA
and Powerbox selection are separate requirements; limited scans remain allowed.

## Filesystem and accounting invariants

- `FileTree` remains the sole source of root sizes, issues and identity. No merged
  synthetic tree, cross-root NodeID, global size total or reclaimable-space estimate.
- Parent/child directory filesystem IDs come from `fstatfs` on `O_NOFOLLOW |
  O_DIRECTORY | O_EVTONLY` descriptors, checked with `fstat` against observed
  device/inode. Different filesystems are recorded as boundary nodes, not queued.
  The old device check remains as an additional guard. Lookup failure records an
  issue and does not traverse that directory. These are point-in-time checks, not
  a transactional filesystem snapshot or a solution to all ancestor races.
- This matters on the observed APFS boot pair: `st_dev` was equal for `/` and Data,
  and `/Users` and Data/Users had equal device/inode, while `statfs` distinguished
  the filesystems. The no-crossing policy therefore also stops firmlink traversal
  from System into Data. Data must be selected as its own root.
- Device IDs preserve the unsigned bit pattern of signed Darwin `dev_t`, including
  negative system-device values. Scanner and file-action validation agree.
- APFS capacities share container space; logical and allocated values across roots
  must not be added. Exact shared-block accounting remains M7.
- Rediscovery before and after the picker checks volume ID/path. Root metadata must
  be known; the scanner receives expected device/inode and performs final source
  validation. Disappearance/replacement never silently becomes a different root.
- At most 64 root reports and 20 issue samples per report. One active scanner uses
  the existing bounded worker pool. Completed trees are released; only compact
  reports persist in memory. An existing single-root Explorer tree may remain
  beside the one active scanner tree. No new per-node work is scheduled in UI.

## Scope and validation

Modules: App platform discovery/picker; Scan feature orchestration/view; Foundation
scanner and coordinator boundary handling; FileOperations device conversion; tests.
Domain layout, renderer, accounting, existing Trash UX and entitlements are preserved.
No database or migration: persistence is M8. No web backend/frontend: this is a native
application; the vertical slice runs from platform/scanner to SwiftUI and tests.

Tests cover root planning/defaults/dedup/limits, discovery error/retry, serial work,
permission/missing/replaced roots, cancellation/stalled I/O, teardown/late results,
lease release, per-root provenance/unknown sizes, native selection, real System/Data
metadata, APFS boundary/read-only mounts and deterministic detach before publication.
The owned-fixture benchmark records the extra directory checks without claiming an
improvement or extrapolating to millions of files.
