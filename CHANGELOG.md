# Changelog

All notable changes to Hygieia are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-08-31

### Added

- Native macOS explorer shell with bounded Lustral Field visualization.
- Identity-validated Show in Finder and Move to Trash flows.
- Receipt-confirmed in-memory reconciliation after known Trash moves, with a
  fail-closed full-root rescan fallback.
- Release metadata, app icon, and reproducible release checklist.

### Security

- Release builds enable Hardened Runtime.
- Trash actions never perform permanent deletion and retain documented
  time-of-check/time-of-use limits.

[0.2.0]: https://github.com/Gollardo/Hygieia/releases/tag/v0.2.0
