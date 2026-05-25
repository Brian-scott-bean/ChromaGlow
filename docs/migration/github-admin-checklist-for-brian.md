# GitHub Admin Checklist for Brian

Brian owns GitHub admin setup for the repo.

## Goal

Protect the repo so Dallin and Brian can work safely without accidentally breaking `main`.

## Minimum Settings

For `main`, configure either branch protection or a ruleset that enforces:

- Pull request required before merge.
- At least one approving review.
- No force pushes.
- No deletion of `main`.
- Require conversation resolution before merge, if available.
- Require branch to be up to date before merge, if practical.

## Nice-To-Have Later

- Required build checks once CI exists.
- Required test checks once tests are stable.
- Code owner review for sensitive files.
- Signed commits, only if it does not slow the team down too early.

## What Dallin Needs From Brian

Brian should provide:

- Repo URL.
- Whether Dallin has read/write/admin access.
- Current default branch name.
- Current TestFlight build number.
- Known-working Xcode version.
- Known-working macOS version.
- Whether signing/provisioning is handled by automatic signing.
- Which Apple Developer account/team is used.
- Whether Dallin should be added to App Store Connect.

## Suggested First Admin PR

Brian creates a small PR adding or updating:

- `docs/migration/github-admin-checklist-for-brian.md`
- current repo setup notes
- current branch protection status
