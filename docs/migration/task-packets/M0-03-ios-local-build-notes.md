# Task Packet: M0-03 iOS Local Build Notes

## Task ID

M0-03

## Title

Confirm local iOS build setup.

## Owner

Dallin and Brian.

## Goal

Document how to build and run the existing iOS app locally.

## Files Allowed To Change

- `docs/developer-setup-ios.md`
- `docs/migration/ios-testflight-and-signing-primer.md`

## Files Forbidden To Change

- App code.
- Xcode project files unless explicitly required and reviewed.

## Steps

1. Brian documents his known-working setup.
2. Dallin installs the matching Xcode version if needed.
3. Dallin opens the project.
4. Dallin attempts simulator build.
5. Dallin documents errors.
6. Brian helps resolve setup/signing questions.
7. Update docs with final setup instructions.

## Acceptance Criteria

- [ ] Known-working Xcode version documented.
- [ ] Known-working scheme documented.
- [ ] Simulator/device target documented.
- [ ] Signing/provisioning notes documented in plain language.
- [ ] Dallin has either built successfully or documented the blocker.

## Manual Test

Build and run the app locally, or document the exact failure.

## Rollback Plan

Documentation-only task. Revert if the notes are wrong.
