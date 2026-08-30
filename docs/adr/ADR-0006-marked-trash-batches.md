# ADR-0006: Marked Trash batches with one refresh

Status: Accepted
Date: 2026-08-30

## Context

M4 Trash moves one selected snapshot node and starts a whole-root rescan after every successful move. This is safe, but it makes a deliberate cleanup of several independently selected objects slow and repeatedly interrupts the user.

The published `FileTree` remains immutable and is still the only source of truth for displayed sizes. A batch cannot safely patch it after each move. Each marked object can also change between marking, confirmation, and execution, and a parent/child pair cannot both be moved as independent targets.

## Decision

- A window-local marked set may contain multiple eligible real snapshot nodes from one current scan generation.
- Marking stores the identity-validated snapshot target, not a string path. Marks are cleared on a new root or completed full rescan.
- A parent and its descendant cannot be marked together. Marking a parent removes already marked descendants; marking a descendant of an already marked parent is denied.
- One explicit batch confirmation follows an async no-follow preflight of every marked target. The confirmation names the item count, aggregate displayed sizes, recovery semantics, and a bounded root-relative-path preview; each marked item remains individually inspectable before confirmation.
- After confirmation, `TrashService` processes targets sequentially. It repeats no-follow validation immediately before every `NSWorkspace.recycle` request and requires a receipt mapping for every success.
- The batch stops at the first failed target. Already confirmed moves remain explicitly invalidated; the UI reports partial completion and starts exactly one whole-root rescan. There is no rollback and no claim of atomicity.
- No second Trash batch can run in the same window while a batch is preparing, awaiting confirmation, moving, or refreshing. Finder may still validate/reveal an unaffected real node.
- A successful or partially successful batch invalidates all successfully moved roots, not the immutable tree. One full selected-root refresh runs only after the batch reaches its terminal state.
- Permanent delete, Empty Trash, background cleanup, undo, persistent mark/history state, and targeted reconciliation remain out of scope.

## Alternatives Considered

- **Rescan after every marked item:** rejected because it recreates the interruption the feature exists to avoid.
- **Move all marked URLs in one `NSWorkspace.recycle` call:** rejected because per-item identity validation, receipt accounting, partial failures, and user-visible recovery state would be ambiguous.
- **Skip validation after the first item:** rejected because every path can change independently while the batch is running.
- **Optimistically remove rows from the immutable tree:** rejected because ancestor totals, hard-link accounting, chart geometry, and concurrent filesystem state would become false.
- **Allow overlapping parent and child marks:** rejected because after the parent moves, the child target is no longer an independent object.

## Consequences

Positive:

- users can stage several deliberate Trash moves and wait for one full refresh;
- every physical move retains the M4 identity/no-follow/receipt checks;
- immutable snapshot and sandbox boundaries remain unchanged.

Negative/verification needs:

- a batch is not atomic; a later failure can leave an explicitly reported partial result;
- marked state needs feature, accessibility, and manual sandbox integration coverage;
- a large marked list needs bounded confirmation presentation; M4 still makes no performance claim without measurement.
