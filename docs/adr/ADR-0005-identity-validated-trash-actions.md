# ADR-0005: Identity-validated macOS file actions

Status: Accepted
Date: 2026-08-30

## Context

M4 adds Show in Finder and Move to Trash for nodes selected from an immutable snapshot. A reconstructed path can become stale between scan and action, and an ancestor can be replaced by a symbolic link. The current `FileTree` retains `(device, inode)` only for hard-link groups, so it cannot prove that a general selected path still resolves through the scanned objects.

The M2 app is sandboxed with user-selected read-only access. Trash requires an explicit permission decision. The scanner publishes whole-root immutable snapshots and has no safe subtree merge/reconciliation contract yet.

## Decision

- Add a compact `NodeIdentityStore` sidecar to `FileTree`: one inode per node, a known bitmap, one primary device and rare sorted device overrides. Keep the 40-byte `FileNode` stride unchanged.
- Require production scanner-built nodes to have identity evidence. Identity-free synthetic fixtures remain possible but are ineligible for Trash.
- Build action targets only for real `NodeID` selections from the original selected-root URL and the snapshot parent/name/identity chain.
- Validate root, every ancestor and leaf with no-follow `lstat`, exact kind and `(device, inode)`. Never resolve symlink targets or treat a joined string path as authority.
- Repeat full validation after Trash confirmation, immediately before requesting the system move. Document the remaining non-atomic TOCTOU window.
- Add `HygieiaFileOperations` depending on Domain/Foundation/Darwin but not SwiftUI/AppKit. Keep AppKit adapters in the app layer.
- Use `NSWorkspace.activateFileViewerSelecting` for Finder and single-item `NSWorkspace.recycle` for Trash. Require the returned original-to-Trash URL mapping before treating Trash as successful. Permanent-delete APIs remain absent.
- Replace the M2 user-selected read-only entitlement with user-selected read-write. Keep App Sandbox; add no all-files, privileged helper, bookmarks or Full Disk Access entitlement.
- Permit Trash only for current real non-root/non-visible-root nodes with known identity and without incomplete/inaccessible/volume-boundary flags. Symlink/package/hard-link members have explicit warning semantics; virtual `Other` and filesystem kind `other` are denied.
- Keep one mutation in flight per window and require explicit confirmation every time.
- Do not mutate the published tree after success. Mark the moved subtree invalid/stale and run a full selected-root rescan. Targeted immutable reconciliation is deferred to M9.
- If the action refresh fails or is cancelled, retain the old snapshot as stale-after-action and disable further Trash until a complete rescan or new root selection.

The exact contracts, UX, tests and gates are specified in `docs/M4_FILE_ACTIONS.md`.

## Alternatives Considered

- **Trust reconstructed path/name:** rejected because it can target a replacement object or traverse a replaced ancestor.
- **Validate only leaf metadata:** rejected because an ancestor can be replaced by a symlink or different directory.
- **Compare kind/size instead of identity:** rejected because these values are not unique and directory subtree totals do not match `lstat` size.
- **Store full `(device, inode)` in every `FileNode`:** rejected because it increases the hot node stride; a sidecar exploits the single-device M1 boundary.
- **Store identity only for currently visible/actionable nodes:** rejected because future selection is unknown and rescanning merely to obtain identity creates inconsistent action semantics.
- **Use string-prefix containment:** rejected as a security boundary; Unicode, symlinks, mount changes and path normalization make it insufficient.
- **Use `stat`/resolve symlinks:** rejected because Trash must move a selected symlink itself, never its target.
- **Use `FileManager.removeItem`, `unlink`, shell `rm` or privileged helper:** rejected because permanent deletion and privilege escalation are explicit non-goals.
- **Use a custom `.Trash` destination:** rejected because macOS owns Trash location, naming, volume and UI semantics.
- **Optimistically delete the node from `FileTree`:** rejected because ancestor totals, hard-link accounting, sibling chains, visualization and concurrent filesystem changes would no longer be authoritative.
- **Implement targeted subtree merge in M4:** rejected because the scanner has no immutable reconciliation contract; this belongs with M9/FSEvents design.
- **Keep read-only entitlement and ask user to reselect every item for write:** rejected as confusing and incompatible with actions on descendants of the explicitly selected scan root.
- **Persistent action log:** rejected; it adds privacy/storage policy without a product requirement.

## Consequences

Positive:

- destructive intent is bound to snapshot identity evidence rather than path text alone;
- symlink targets and replaced ancestors fail closed;
- node hot layout remains unchanged;
- Finder/Trash remain platform-native and independently testable;
- success/failure and stale snapshot semantics are explicit;
- M4 does not pre-implement a fragile reconciliation engine.

Negative/limitations:

- identity storage adds approximately 8.125 bytes per ordinary node before collection overhead and must be measured;
- every action performs filesystem IO along the full parent chain;
- `(device, inode)` is snapshot-local and inode reuse remains a residual edge case for M7 research;
- validation and `NSWorkspace.recycle` are not one atomic operation;
- changing to read-write entitlement expands authority over the selected root and requires signed sandbox tests;
- a successful Trash triggers a potentially expensive whole-root rescan;
- Trash is unavailable for partial/stale/incomplete nodes and current visual root in M4;
- no in-app Undo exists.

M5 must define volume/critical-path policy before Whole Mac actions. M9 may supersede the full-root refresh with atomic targeted reconciliation while preserving identity validation and failure semantics.
