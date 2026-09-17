# ADR-0008: Single-root volume coverage and availability

Status: Accepted
Date: 2026-09-17

## Context

M5a already offers local volumes as entry points into the selected-folder flow.
Discovery currently converts missing capacity to zero; completion copy can hide
coverage issues. There is no contract for a root disappearing or being replaced
before publication. The approved next slice completes single-root M5a; multi-root
Whole Mac and a new access model remain separate decisions.

## Decision

- Keep one explicitly selected Powerbox root, one immutable FileTree, no symlink
  traversal and no crossing of the root device. Discovery is not access authority.
- Separate volume discovery from the picker. Unknown/invalid capacity remains
  unknown. A discovery failure is distinct from an empty list; retry is explicit.
- Recheck a volume entry before opening its picker. The URL actually selected in
  the picker remains the scan root, including when the user selects a subfolder.
- Preserve root identity in the existing snapshot identity sidecar. A rescan with
  an existing snapshot must match that root identity. Explicit selection is how
  the user accepts a replacement root.
- Revalidate the root before normal scan publication (a cancelled scan starts no extra final I/O). If unavailable or replaced, retain
  collected evidence in a valid incomplete snapshot, mark the source unavailable,
  and disallow Trash from that snapshot. This is a point-in-time check, not monitoring.
- Derive coverage from completion, root flags and issues; never infer Full Disk
  Access status from a POSIX error or claim a measured coverage percentage.
- Show original root, device evidence, timestamps, fixed traversal policy, issue
  categories and bounded path samples in an on-demand coverage report.
- Keep sandbox entitlements, Finder/Trash validation, accounting, renderer and
  persistence boundaries unchanged. No database or migrations are introduced.

## Alternatives Considered

- Multi-root merged tree now: rejected; provenance, APFS overlap and memory policy
  need a separate accepted design and platform evidence.
- Treat absent capacity as zero: rejected; it incorrectly implies a measured value.
- Throw away all collected evidence after source loss: rejected; a visibly
  unavailable incomplete snapshot can still explain what was observed.
- FDA toggle/probes or privilege changes: deferred; ordinary permission failure
  does not establish the reason for denied access.

## Consequences

The existing explorer stays reusable and bounded. Discovery and source lifecycle
require cancellation/generation tests. Real signed Powerbox, physical eject,
APFS System/Data and FDA denied/granted remain explicit platform gates. Cooperative
cancellation cannot promise interruption of an in-flight blocking filesystem call.
