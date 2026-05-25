# ChromaGlow Operating Model

## Purpose

This document defines how Dallin, Brian, ChatGPT, Cursor, GitHub, and Miro stay aligned while building ChromaGlow.

The goal is to avoid losing decisions in chat history, avoid oversized handoffs, and make it safe for Dallin and Brian to work independently.

## Core Rule

GitHub `main` is the source of truth.

ChatGPT, Cursor, Miro, and human conversations can help create ideas and drafts, but accepted decisions and active implementation instructions belong in the repo.

## Current Locked Direction

- Existing iOS app remains native Swift / SwiftUI.
- New Android app will be native Kotlin / Jetpack Compose.
- Backend will be minimal and distributed.
- Flutter is not part of the migration path.
- Kotlin Multiplatform may be considered later only for logic that is genuinely portable.
- Standard Hue control remains local-first and should not depend on the backend.

## Source of Truth Order

When sources disagree, use this order:

1. Current repo docs on `main`.
2. Accepted migration decision records.
3. Current task packet.
4. Current code on `main`.
5. Current active branch.
6. Miro board.
7. ChatGPT conversation history.
8. Older generated files, zip bundles, or drafts.

Old zip files and prior chat drafts are not authoritative once their content has been committed or superseded.

## Repo Documentation Structure

Recommended documentation areas:

```text
docs/
  migration/
    README.md
    operating-model.md
    open-questions-status.md
    android-mvp-scope.md
    backend-boundaries.md
    telemetry-primer.md
    decisions/
    task-packets/
  developer-setup-ios.md
  developer-setup-android.md
```

## Decision Records

Use decision records for major decisions that should not be re-litigated every chat.

Decision records should live here:

```text
docs/migration/decisions/
```

Examples:

```text
0001-native-android-no-flutter.md
0002-android-minimum-sdk.md
0003-backend-provider.md
0004-telemetry-policy.md
```

A decision record should include:

- Status.
- Decision.
- Why.
- Consequences.
- What this rules out.
- When to revisit.

## Task Packets

Task packets are the unit of work for Cursor and developer implementation.

Task packets should live here:

```text
docs/migration/task-packets/
```

A task packet should define:

- Goal.
- Owner.
- Files allowed to change.
- Files forbidden to change.
- Steps.
- Acceptance criteria.
- Build/test command.
- Manual test.
- Rollback plan.
- Notes for Cursor.

Do not ask Cursor to do implementation work without a task packet unless the change is tiny and documentation-only.

## ChatGPT Usage

Use ChatGPT for:

- Strategy discussion.
- Decision framing.
- Architecture explanation.
- Repo-ready Markdown drafts.
- Task packet creation.
- Cursor prompt drafting.
- Review checklists.
- Plain-language explanations.

Do not treat ChatGPT chat history as the source of truth.

When a ChatGPT discussion produces an accepted decision, convert it into a repo doc or patch.

## Chat Organization

Use separate ChatGPT project chats for separate workstreams.

Recommended chats:

```text
Operating Model
Milestone 0 iOS Setup
Android MVP Architecture
Backend and Telemetry
Product Scope and Parity
GitHub / CI / Release Workflow
iOS Stabilization and Refactor Planning
```

Each chat should begin with a short handoff:

```text
We are in the ChromaGlow project. Use the repo docs on main as source of truth. Current decision: native iOS + standalone native Android + minimal backend, no Flutter. This chat is for [WORKSTREAM NAME]. Produce delta-only Markdown docs, patches, or task packets unless I ask otherwise.
```

## ChatGPT Output Format

Prefer delta-only output.

For a new file:

```text
File:
docs/migration/example.md

Action:
Create

Content:
<full file>
```

For an existing file:

```text
File:
docs/migration/example.md

Action:
Update section

Replace:
<old section>

With:
<new section>
```

Avoid generating full doc packs or zip bundles unless explicitly requested.

## Cursor Usage

Cursor should read the repo docs before implementing work.

For implementation tasks, Cursor should be given:

- The relevant task packet.
- The relevant decision records.
- The exact allowed files.
- The exact forbidden files.
- A reminder to make the smallest safe change.

Good Cursor prompt shape:

```text
You are working in the ChromaGlow repo.

Use the repo docs on main as the source of truth.

Task packet:
[paste or reference task packet]

Allowed files:
...

Forbidden files:
...

Make the smallest safe change. Do not refactor unrelated code. After changes, summarize files changed, how to test, and any risks.
```

Avoid broad Cursor prompts like:

```text
Refactor the app.
Make Android match iOS.
Clean up this file.
Implement the migration.
Fix all issues.
```

## GitHub Workflow

Use GitHub for collaboration and review.

Rules:

- `main` should be protected.
- No direct commits to `main`.
- Every change should use a branch.
- Every meaningful change should use a pull request.
- PRs should be small enough to review.
- Documentation-only PRs are acceptable and encouraged.
- App code and docs should not be mixed unless the task requires both.

Branch naming pattern:

```text
<owner>/<area>-<short-task-name>
```

Examples:

```text
dallin/docs-operating-model
brian/github-branch-protection
dallin/ios-build-notes
brian/android-skeleton
```

## Human Communication

Dallin owns product direction and planning clarity.

Brian owns initial GitHub admin setup and current repo operations until Dallin is fully onboarded.

For each task, both people should know:

- What is being changed.
- Why it is being changed.
- Who owns it.
- What files are safe to touch.
- How to verify it.
- How to roll it back.

## Miro Usage

Miro is for visual planning, not canonical implementation detail.

Use Miro for:

- Architecture diagrams.
- Workstream mapping.
- Milestone planning.
- Dependency mapping.
- Product flow discussion.

Do not use Miro as the only place for:

- Accepted technical decisions.
- Task instructions.
- Security rules.
- Build instructions.
- API contracts.

If something on Miro becomes an accepted implementation decision, capture it in a repo doc.

## Project Sources

Project Sources should be stable, cross-chat context.

Good candidates for Project Sources:

```text
docs/migration/README.md
docs/migration/operating-model.md
docs/migration/decisions/0001-native-android-no-flutter.md
docs/migration/android-mvp-scope.md
docs/migration/backend-boundaries.md
docs/migration/open-questions-status.md
```

Do not upload every small task packet or minor patch as a Project Source.

Create or refresh a Project Source when:

- A major decision set is accepted.
- A milestone plan is complete.
- Repo docs have changed enough that old chat context is stale.
- A new workstream needs a clean starting point.
- Brian or Dallin needs a current onboarding snapshot.

## Milestone 0 Working Mode

During Milestone 0, Dallin may not yet be fully set up for GitHub, Xcode, signing, or TestFlight.

That means:

- Brian may perform early repo updates.
- Dallin can still review docs and decisions.
- Dallin's first hands-on GitHub task should be documentation-only.
- App code changes should wait until setup and workflow are safe.

Recommended Milestone 0 order:

1. Commit migration docs.
2. Protect `main`.
3. Confirm Brian's known-working iOS setup.
4. Get Dallin repo access.
5. Have Dallin review a documentation PR.
6. Have Dallin make one small Markdown PR.
7. Teach Dallin Xcode build/signing basics.
8. Confirm local iOS build path.
9. Identify the stabilized iOS/TestFlight baseline.
10. Only then begin Android scaffolding.

## Baseline Rule

Do not treat a known-buggy TestFlight build as the behavioral baseline if a near-term stabilization build is expected.

Preferred baseline approach:

1. Fix critical current iOS bugs.
2. Ship a stabilized TestFlight build.
3. Name that build as the migration baseline.
4. Use that baseline to define Android parity.

## Backend Rule

The backend supports the product. It does not replace local Hue control.

Backend may own:

- Feature flags.
- Telemetry.
- Crash/health events.
- Release cohorts.
- Optional user identity.
- Non-sensitive metadata sync.
- Future marketplace support.
- Short-lived pairing handoff.

Backend must not own:

- Raw Hue bridge credentials.
- Required local light control.
- High-frequency entertainment streaming.
- Microphone/audio processing.
- Required local bridge discovery.

## When To Create A New Repo Doc

Create or update a repo doc when:

- A decision is accepted.
- A task is ready for implementation.
- A workflow needs to be repeated.
- A new developer needs the context.
- Cursor needs durable instructions.
- ChatGPT context should not be trusted as the only record.

Do not create a repo doc for every passing idea.

## When To Open A New Chat

Open a new ChatGPT project chat when the topic becomes a separate workstream.

Examples:

- Android architecture.
- Backend provider selection.
- Telemetry policy.
- iOS setup.
- Product parity.
- CI/CD.
- Release strategy.

Do not mix unrelated implementation planning into one long chat if it creates confusion.

## Maintenance

This document should be updated whenever the team changes how it works.

The goal is not to make the process heavy. The goal is to make the process repeatable enough that Dallin, Brian, ChatGPT, and Cursor can all stay aligned without relying on memory.
