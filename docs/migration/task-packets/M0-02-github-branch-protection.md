# Task Packet: M0-02 GitHub Branch Protection

## Task ID

M0-02

## Title

Protect `main`.

## Owner

Brian.

## Goal

Configure GitHub so Dallin and Brian do not accidentally break `main`.

## Files Allowed To Change

- `docs/migration/github-admin-checklist-for-brian.md`
- optional repo setup notes under `docs/migration/`

## Files Forbidden To Change

- App code.
- Xcode project files.
- Android project files, if they exist.

## Steps

1. Open repository settings in GitHub.
2. Check whether branch protection or rulesets are available.
3. Protect `main`.
4. Require pull requests before merge.
5. Require at least one approval.
6. Disable force pushes and branch deletion for `main`.
7. Document the final settings.

## Acceptance Criteria

- [ ] `main` cannot be pushed to directly.
- [ ] PR is required.
- [ ] At least one review is required.
- [ ] Final settings are documented.

## Manual Test

Attempt to confirm that direct pushes to `main` are blocked or that GitHub shows protection/ruleset status.

## Rollback Plan

Brian can temporarily loosen rules if the team gets blocked, but changes should be documented.
