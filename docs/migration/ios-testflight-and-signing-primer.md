# iOS TestFlight and Signing Primer

This is a plain-language primer for Dallin.

## What Xcode Is Doing

Xcode is the Apple tool used to build, run, archive, and upload the iOS app.

For local development, Xcode needs to know:

- Which project or workspace to open.
- Which scheme to build.
- Which simulator or physical device to run on.
- Which Apple Developer Team signs the app.

## What Signing Means

Apple requires iOS apps to be signed before they can run on real devices or be distributed through TestFlight.

Think of signing as Apple asking:

- Who built this app?
- Is this developer/team allowed to build this app?
- Is this app allowed to run on this device or through TestFlight?
- Does the bundle identifier match the App Store/TestFlight app?

## What Provisioning Means

Provisioning connects the app, the developer team, the device/distribution method, and app capabilities.

For ChromaGlow, provisioning may matter for:

- App Groups.
- Widgets.
- Watch app.
- Local network permission.
- Keychain access groups.
- Push notifications if added later.
- Other entitlements.

## What TestFlight Is

TestFlight is Apple's beta distribution system.

A simplified flow:

```text
Xcode archive
  -> upload build to App Store Connect
  -> Apple processes build
  -> build becomes available to internal/external testers
  -> testers install through TestFlight
```

## Milestone 0 Learning Goals

Dallin should learn:

- How to clone/open the repo.
- Which Xcode version to use.
- Which scheme to build.
- How to run on a simulator.
- How to run on a physical iPhone, if needed.
- What signing team is selected.
- What errors appear if signing is not configured.
- Who controls TestFlight upload permissions.

## Baseline Recommendation

Do not use a known-buggy TestFlight build as the migration baseline unless there is no alternative.

Preferred approach:

1. Fix the known critical bugs in the current iOS app.
2. Ship a new TestFlight build.
3. Label that build as the migration behavior baseline.
4. Use that baseline to define Android MVP parity.
