# Milestone 0: Two-Developer Stabilization

## Purpose

Before migration coding begins, Dallin and Brian need a safe way to work in the same repo.

This milestone is complete when both developers can build the current app, make a small branch, open a pull request, review each other, and merge without breaking the project.

## Exit Criteria

- Both developers have the repo cloned.
- Both developers can open the project locally.
- Both developers know the current build command / Xcode scheme.
- Main branch is protected.
- PR review is required.
- A first documentation-only PR has been merged.
- Migration docs live under `docs/migration/`.
- First Android decision record is merged.
- First Android skeleton task packet is ready.
- No production/TestFlight behavior has been changed.

## Tasks

### M0-01: Add migration docs folder

Add this folder and starter docs:

- `docs/migration/README.md`
- `docs/migration/decisions/0001-native-android-no-flutter.md`
- `docs/migration/two-developer-git-workflow.md`

### M0-02: Protect main branch

In GitHub:

- Require pull request before merge.
- Require at least one approval.
- Require branch to be up to date before merge if practical.
- Disable direct pushes to main.

### M0-03: Confirm iOS build

Each developer documents:

- macOS version.
- Xcode version.
- scheme used.
- simulator/device used.
- build result.
- any signing issues.

### M0-04: Create developer setup notes

Add a Markdown file later:

- `docs/developer-setup-ios.md`
- `docs/developer-setup-android.md` once Android exists.

### M0-05: First safe PR

Each developer opens one documentation-only PR to prove the workflow.

## Non-Goals

- Do not start Android app scaffolding until repo workflow is proven.
- Do not refactor `UnifiedOrchestrator.swift`.
- Do not touch signing, provisioning, or TestFlight settings unless the task is specifically about build setup.
