# Security policy

## Reporting a vulnerability

Please use this repository's private GitHub Security Advisory flow. Do not open
a public issue containing an exploit, private filesystem listing, personal path,
credential, or destructive proof of concept. If the private advisory flow is
unavailable, open only a minimal non-exploitable issue asking the maintainer for
a private channel.

No dedicated security contact email is published. Hygieia has not undergone an
external security audit.

## Current safety boundary

Hygieia `0.2.0` is an early source preview, not a packaged or notarized release.
Its file-operation design reduces stale-path and symlink risks, but does not
make a path-based macOS Trash request atomic.

- Permanent delete, Empty Trash, privilege escalation, and hidden Full Disk
  Access workarounds are out of scope.
- Symbolic links are never traversed by the scanner or target validator.
- A Trash target must be eligible for the current complete snapshot and match
  the scanned root, ancestor, and leaf identity immediately before the request.
- Successful receipt-confirmed file actions invalidate the old snapshot and
  reconcile a new in-memory snapshot. If reconciliation cannot be proven safe,
  Hygieia falls back to one complete selected-root rescan.
- The short time-of-check/time-of-use window between final validation and the
  system Trash API remains a documented residual risk.
- Full Disk Access coverage, removable/read-only volumes, signed sandbox Trash,
  Finder integration, and symlink race scenarios still have manual gates.

Read the [M4 file-actions contract](docs/M4_FILE_ACTIONS.md) and
[identity-validation ADR](docs/adr/ADR-0005-identity-validated-trash-actions.md)
for the exact model and limitations.
