# Task Packet: M0-01 Commit Migration Docs

## Task ID

M0-01

## Title

Commit migration documentation pack.

## Owner

Dallin or Brian.

## Goal

Add the initial migration documentation folder to the repo.

## Files Allowed To Change

- `docs/migration/**`

## Files Forbidden To Change

- `HueHome/**`
- `HueHomeWidget/**`
- `LightShadeWatch/**`
- `LightShadeWatchApp Watch App/**`
- Xcode project files
- signing/provisioning files

## Steps

1. Create a new branch.
2. Add the `docs/migration/` folder.
3. Commit only Markdown files.
4. Open a pull request.
5. Have the other developer review it.
6. Merge after approval.

## Acceptance Criteria

- [ ] `docs/migration/README.md` exists.
- [ ] Native Android / no Flutter decision record exists.
- [ ] Dallin's answered open questions are captured.
- [ ] No app code changed.
- [ ] PR reviewed before merge.

## Manual Test

- Open docs in GitHub and confirm Markdown renders.

## Rollback Plan

Revert the documentation PR.

## Notes For Cursor

Do not edit app code.
