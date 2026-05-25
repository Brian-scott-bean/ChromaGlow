# ChromaGlow Migration Documentation

This folder is the working source of truth for the ChromaGlow / HueHome Pro migration effort.

## Locked Direction

We are moving forward with a native-platform plan:

- Existing iOS app remains native Swift / SwiftUI.
- New Android app will be native Kotlin / Jetpack Compose.
- Backend will be minimal and distributed, supporting coordination but not replacing local Hue bridge control.
- Flutter is not part of the migration strategy.
- Kotlin Multiplatform may be considered later only for logic that is genuinely portable.

## Documentation Rules

- Project documentation should live as Markdown files in this repo.
- Major architecture decisions should be recorded as Migration Decision Records under `docs/migration/decisions/`.
- Task packets should be written as Markdown before Cursor or a developer starts implementation.
- Documentation should be practical, plain-language, and directly useful to Dallin and Brian.
- Do not hide important rules only in chat history. If it matters to implementation, it belongs in the repo.

## Starting Documents

- `decisions/0001-native-android-no-flutter.md`
- `repo-structure-proposal.md`
- `two-developer-git-workflow.md`
- `android-architecture-baseline.md`
- `backend-boundaries.md`
- `cursor-working-rules.md`
- `milestone-0-stabilization.md`
- `task-packet-template.md`
- `open-questions.md`

## Added From Dallin's Open Questions

- `open-questions-status.md` — decisions and recommendations from answered questions
- `github-admin-checklist-for-brian.md`
- `ios-testflight-and-signing-primer.md`
- `backend-options-brief.md`
- `telemetry-primer.md`
- `android-mvp-scope.md`
- `task-packets/M0-01-commit-migration-docs.md`
- `task-packets/M0-02-github-branch-protection.md`
- `task-packets/M0-03-ios-local-build-notes.md`
