# Parallel Batch 1 Contract-Corrections Prompt

## Status

- **State:** Ready
- **Purpose:** Resolve D-007 before Batch 1 merges to `main` or Batch 2 planning starts
- **Base:** `integration/parallel-batch-1` @ `2a156b5f646843dfc5e5051cdbf4b2bbe5fbb8e4`
- **Execution:** One serialized correction lane; do not split overlapping model/fixture ownership
- **Last reviewed:** 2026-06-28

## Prompt

```text
Read AGENTS.md, the Current Status Snapshot and latest parallel-pipeline entries in DEVLOG.md,
docs/coordination/parallel-agent-pipeline.md (especially D-007 and §7), and the Batch 1 execution
result. Resolve D-007 before any Batch 2 preparation or Batch 1 merge to main.

Preflight:
1. Fetch all remotes and inspect worktrees.
2. Confirm origin/integration/parallel-batch-1 is exactly
   2a156b5f646843dfc5e5051cdbf4b2bbe5fbb8e4. If it differs, stop and reconcile the recorded base
   before editing.
3. Confirm the docs branch contains D-007 from commit 3be8e48 or later.
4. Export:
   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   ANDROID_HOME="$HOME/Library/Android/sdk"
   ANDROID_SDK_ROOT="$ANDROID_HOME"

Create one isolated correction worktree and branch from the pinned integration SHA:
`lane/android1-contract-corrections`.

The correction lane owns only:
- android/app/src/main/java/com/chromaglow/app/core/model/SceneDisplayModel.kt
- android/app/src/main/java/com/chromaglow/app/data/demo/DemoFixtures.kt
- android/app/src/test/java/com/chromaglow/app/core/model/SceneDisplayModelTest.kt
- android/app/src/test/java/com/chromaglow/app/data/demo/DemoFixturesLightsScenesTest.kt

Required corrections:
1. Add non-blank `bridgeId` to `SceneDisplayModel` so every scene carries explicit bridge-routing
   identity. Update constructors and tests, including blank-value rejection.
2. Set every demo scene's `bridgeId` to `DemoFixtures.DEMO_BRIDGE_ID` and test that invariant.
3. Make every room's existing `lightCount` exactly equal
   `DemoFixtures.lightsByRoom[room.id]?.size`. Preserve the existing room fixtures and add the missing
   deterministic demo-light fixtures rather than reducing the established dashboard counts.
4. Add a fixture-consistency test that fails on any room/count mismatch.
5. Preserve all existing IDs and fixture ordering where possible. Do not add UI, navigation, REST,
   pairing, persistence, dependencies, Gradle, manifest, resource, iOS, or unrelated docs changes.

Validation and integration:
1. Run `./gradlew testDebugUnitTest lintDebug assembleDebug` from android/ in the correction worktree.
2. Commit the correction lane and return its SHA plus structured handoff text. Do not edit DEVLOG.md
   or the pipeline from the lane.
3. Verify the lane changed only the four allowed files.
4. Merge it with `--no-ff` into `integration/parallel-batch-1` as batch owner.
5. Boot the headless Pixel_10 AVD and run the full integrated gate:
   `./gradlew testDebugUnitTest lintDebug assembleDebug connectedDebugAndroidTest`.
6. Push the corrected integration branch. Do not merge to main.
7. On `docs/parallel-agent-pipeline`, append a Claude response and resolution evidence to D-007,
   update the Batch 1 execution result with the correction/integration SHAs and final test counts,
   append one consolidated DEVLOG.md handoff, and update
   `parallel-batch-2-prepare.md` only if its preflight SHA must change.
8. Run `git diff --check`, commit, and push the docs branch.

Report the correction-lane SHA, corrected integration SHA, changed-file audit, all validation results,
docs commit SHA, and remote branches. Stop if any required gate fails.
```
