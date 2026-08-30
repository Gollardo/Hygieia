# Contributing

Hygieia is an early native macOS project built around explicit filesystem,
safety, architecture, and measurement contracts. Keep contributions focused on
the active milestone and proportionate to the evidence available.

## Environment

Use an Apple Silicon Mac with macOS 14 or newer and a current Xcode with Swift 6
support. The repository has no third-party runtime dependencies.

```bash
swift test
swift run hygieia-verify
```

Open `Hygieia.xcodeproj`, select the shared `Hygieia` scheme, and run the app
test plan for app and UI changes. Some signed sandbox, Powerbox, Finder, Trash,
VoiceOver, Full Disk Access, and performance scenarios are manual gates and
must not be inferred from a unit test or successful build.

## Before implementation

1. Read `AGENTS.md`, the relevant milestone document, the closest tests, and
   `docs/ARCHITECTURE.md`.
2. For visible UI changes, also read `docs/DESIGN_SYSTEM.md` and
   `docs/UI_CHANGE_CHECKLIST.md`.
3. Identify the affected dependency boundaries and current operational gates.
4. Check the worktree and preserve unrelated or uncommitted work.

## Changes and pull requests

Create a focused branch from `main`. Use Conventional Commits, for example
`feat: add scan coverage summary`, `fix: reject stale trash target`, or
`docs: clarify allocated size semantics`.

A pull request should explain:

- the problem and user-visible outcome;
- the chosen approach and architectural boundaries;
- tests, benchmarks, and manual checks performed;
- filesystem semantics or safety implications;
- known residual risks and checks that were not run.

Do not combine an unrelated refactor with a behavior change. Add dependencies,
frameworks, new visual language, or speculative abstractions only when an
accepted design and immediate use case require them.

## Correctness and safety

- `FileTree` remains the source of truth. UI code does not scan the filesystem.
- Never infer uncertain filesystem behavior. Confirm it with documentation,
  tests on a real filesystem, or mark it unknown.
- Never follow symbolic links or cross volume boundaries by assumption.
- Permanent delete is prohibited. File removal means Move to Trash only, with
  explicit confirmation and identity revalidation.
- Performance claims require reproducible measurements and baseline metadata.
- Use only synthetic or explicitly public data in screenshots, fixtures,
  issues, benchmark output, and test artifacts.

## Architecture decisions

If a change materially contradicts or replaces `docs/ARCHITECTURE.md`, propose
an ADR in `docs/adr/` before changing the implementation. Record context,
decision, alternatives, consequences, and open questions.
