# Cursor Working Rules

These rules are for Dallin and Brian when using Cursor against the ChromaGlow repo.

## Start Every Coding Session With

Read:

- `docs/migration/README.md`
- the relevant task packet
- the relevant architecture or decision document
- `.cursorrules`
- `.cursor/rules/*.mdc` if working in the current iOS project

## Task Packet Required

Do not start implementation work without a task packet that says:

- Goal
- Files allowed to change
- Files forbidden to change
- Steps
- Build command
- Manual test
- Rollback plan

## Prompting Cursor

Good prompt shape:

```text
You are working in the ChromaGlow repo.

Follow docs/migration/README.md and this task packet.

Goal:
...

Allowed files:
...

Forbidden files:
...

Make the smallest safe change. Do not refactor unrelated code.
After changes, summarize files changed and how to test.
```

## Avoid

- "Clean up this whole file."
- "Refactor the architecture."
- "Make Android match iOS."
- "Fix all warnings."
- "Implement the whole migration."

## Prefer

- "Create the empty Android app skeleton."
- "Add the Bridge data model only."
- "Document the Hue v2 endpoints currently used."
- "Create a repository interface without implementation."
- "Add one unit test for this pure function."

## Commit Discipline

- Commit small.
- Commit after a passing build or a known documentation-only change.
- Do not mix documentation, iOS refactor, and Android implementation in one commit.
- Pull latest main before starting new work.
- Stop and ask for review when Cursor proposes broad edits.
