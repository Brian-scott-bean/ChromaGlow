# Parallel Batch 2 Preparation Prompt

## Status

- **State:** Ready after Batch 1 integration completes
- **Purpose:** Inspect the actual Batch 1 result and draft the Batch 2 manifest
- **Execution:** Planning/docs only; do not launch code lanes
- **Last reviewed:** 2026-06-28

## Prompt

```text
Read AGENTS.md, the Current Status Snapshot and latest parallel-pipeline entries in DEVLOG.md,
docs/coordination/parallel-agent-pipeline.md, and
docs/coordination/prompts/parallel-batch-1-launch.md.

Prepare Android parallel-batch-2 from the completed Batch 1 result. Do not launch code agents or
create Batch 2 worktrees in this session.

Preflight:
1. Fetch all remotes and inspect local branches/worktrees.
2. Require a completed integration/parallel-batch-1 branch with recorded lane SHAs and a consolidated
   green result for testDebugUnitTest, lintDebug, assembleDebug, and connectedDebugAndroidTest.
3. If Batch 1 is absent, incomplete, dirty, unvalidated, or differs from its recorded handoff, stop
   and report the exact missing prerequisite. Do not infer model contracts from the old draft.
4. Export:
   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   ANDROID_HOME="$HOME/Library/Android/sdk"
   ANDROID_SDK_ROOT="$ANDROID_HOME"

Using the actual integrated Batch 1 tree as evidence:
1. Inspect the final LightDisplayModel, SceneDisplayModel, demo fixtures/session, dashboard callback
   surface, routing enum, and ChromaGlowApp shell.
2. Draft a Batch 2 manifest in docs/coordination/parallel-agent-pipeline.md with an exact base SHA,
   lane branches, owners, ownership globs, acceptance criteria, forbidden files, dependencies, and
   validation commands.
3. Prefer a two-wave structure:
   - Wave 1: parallel feature packages for room detail, scenes, and settings only when each can compile
     and be behaviorally tested against the landed Batch 1 contracts.
   - Wave 2: one serialized integration lane owning the nav shell and any dashboard callback changes
     needed to make every Wave 1 screen reachable in the same batch.
4. Do not approve unwired UI as a final Batch 2 result. Feature packages may be built in Wave 1 only
   if Wave 2 wires and exercises them before the batch is considered complete.
5. Keep pairing, credential-persistence wiring, REST, SSE, NUPnP, Studio, Composer, DTLS, microphone,
   widgets, and Wear OS out of scope.
6. Account for the single shared Pixel_10 AVD: code lanes may run concurrently, but connected tests
   must be scheduled serially by the batch owner unless isolated emulator instances are provisioned.
7. Keep DEVLOG.md and the pipeline document batch-owner-only; sub-agents return handoff text.
8. Add a new Decision Log entry requesting Codex review. Mark the Batch 2 manifest DRAFT and not
   execution-approved.
9. Append one DEVLOG.md handoff, run git diff --check, commit, and push the docs branch so Codex can
   review it.

Report the proposed lane graph, exact base SHA, unresolved decisions, commit SHA, and remote branch.
Do not create parallel-batch-2 branches or modify Android source in this preparation session.
```
