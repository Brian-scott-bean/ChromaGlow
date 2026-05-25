# Open Questions Status

This document converts Dallin's answered open questions into decisions, recommendations, and remaining unknowns.

## Locked / Mostly Decided

### Android timing

Android should live in the repo after Milestone 0, not before it.

Rationale: the team first needs to prove that both developers can work in the repo safely, build the current iOS app, and use a pull-request workflow before introducing a second app project.

### GitHub admin

Brian owns GitHub admin setup.

Milestone 0 should include a Brian-owned task to configure branch protection or rulesets on `main`.

### Android MVP scope

Android MVP should include:

- Bridge discovery and pairing.
- Demo mode.
- Dashboard / core UI parity.
- Bridge connection.
- Rooms / lights control.
- Scenes.

The target should be a releasable app, not a throwaway prototype.

### Widgets and Wear OS

Widgets and Wear OS are post-MVP, after general UI parity.

They should be designed together because they both represent lightweight external control surfaces.

### Studio / composer parity

Studio/composer parity is required before new product functionality is added to iOS, except for architectural restructuring and stability work.

### Web and Google Home

Web and other connectivity targets such as Google Home remain long-term goals.

They should not drive MVP scope, but architectural choices should avoid blocking them later.

## Needs Decision During Milestone 0

### GitHub branch protection availability

Brian needs to check what branch protection or ruleset options are available in the repo.

Minimum target:

- No direct pushes to `main`.
- Pull request required before merge.
- At least one approval before merge.
- No force pushes.
- No branch deletion for `main`.

### Release branch strategy

Recommendation for now:

- Use `main` as the protected integration branch.
- Use short-lived feature branches named by owner and task.
- Do not create long-lived developer branches named only `dallin` or `brian`.
- Add release branches later when Android and iOS both have formal release cycles.

Example branches:

```text
dallin/docs-ios-build-notes
brian/github-branch-protection
dallin/android-mvp-scope-doc
brian/fix-testflight-baseline-bug
```

## Needs Learning / Setup

### iOS local build

Dallin has not built or released the app through Swift/Xcode/TestFlight yet.

Milestone 0 must include a guided iOS build/setup task.

### Xcode version

Unknown.

Brian should provide the known-working Xcode version, macOS version, and current scheme.

### Signing/provisioning

Unknown to Dallin.

Milestone 0 should include a plain-English signing/provisioning primer and a setup session with Brian.

### TestFlight baseline

Current TestFlight build is believed to be around build 21, but it has bugs.

Recommendation: do not freeze build 21 as the migration baseline if it represents a known-buggy experience. Create a named baseline after the next critical bug-fix build.

Suggested baseline name:

```text
iOS Migration Baseline: post-build-21-stabilized
```

## Backend / Telemetry Needs Discussion

### Backend provider

No backend/cloud preference exists yet.

Recommendation: evaluate two options first:

- Firebase / Google Cloud.
- Supabase + Sentry.

### Accounts

Accounts are not required for Android MVP unless needed for future Marketplace scene sharing.

Recommendation: do not build account creation into Android MVP.

### Feature flags

Feature flags do not exist in iOS today.

Recommendation: start with a local/static feature flag interface during Milestone 1, then wire it to a backend later.

### Telemetry

Telemetry should be discussed before provider selection.

Recommendation: agree on what events are acceptable before choosing tooling.
