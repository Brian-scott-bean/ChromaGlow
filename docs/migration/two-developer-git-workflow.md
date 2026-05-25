# Two-Developer Git Workflow

This workflow is designed for Dallin and Brian working in the same codebase with Cursor assistance.

## Branch Rules

- `main` is protected.
- Nobody commits directly to `main`.
- Every change gets a branch.
- Every branch gets a pull request.
- Pull requests should be small enough to review.

## Branch Naming

Use this pattern:

```text
<owner>/<area>-<short-task-name>
```

Examples:

```text
dallin/docs-migration-decision
brian/android-project-skeleton
dallin/ios-build-notes
brian/discovery-contract-notes
```

## Review Rules

Before merging:

- The branch builds, or the PR clearly says why it cannot yet build.
- The PR description explains what changed.
- The PR names the files touched.
- The PR includes manual test steps.
- The other developer reviews before merge.

## Cursor Safety Rules

- Do not ask Cursor to broadly refactor large files without a task packet.
- Do not accept large generated changes blindly.
- Do not let Cursor edit iOS and Android code in the same task unless the task is only documentation.
- Avoid two people editing `UnifiedOrchestrator.swift`, `StudioView.swift`, or `StudioViewModel.swift` at the same time.
- Commit after small working steps.

## Large File Ownership

Large files are conflict magnets. Assign one active owner at a time for:

- `UnifiedOrchestrator.swift`
- `StudioView.swift`
- `StudioViewModel.swift`
- `DashboardView.swift`
- `RoomDetailView.swift`

## Suggested PR Template

```md
## Goal

## Files Changed

## What Changed

## How I Tested

## Screenshots / Notes

## Rollback Plan

## Follow-Up Tasks
```
