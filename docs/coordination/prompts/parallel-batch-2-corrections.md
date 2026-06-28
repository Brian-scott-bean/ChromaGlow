# Parallel Batch 2 State-Ownership Correction Prompt

## Status

- **State:** Ready
- **Purpose:** Resolve D-009 before Batch 2 merges to `main`
- **Base:** `integration/parallel-batch-2` @ `4c74beb`
- **Execution:** One serialized nav/state-owner correction lane
- **Last reviewed:** 2026-06-28

## Prompt

```text
Read AGENTS.md, the Current Status Snapshot and latest Batch 2 entries in DEVLOG.md,
docs/coordination/parallel-agent-pipeline.md (especially D-009 and §8), and the Batch 2 execution
result. Resolve D-009 before merging Batch 2 to main.

Preflight:
1. Fetch all remotes and confirm origin/integration/parallel-batch-2 is exactly
   4c74beb. If it differs, stop and reconcile the recorded base before editing.
2. Confirm the docs branch contains D-009 and this prompt.
3. Export:
   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   ANDROID_HOME="$HOME/Library/Android/sdk"
   ANDROID_SDK_ROOT="$ANDROID_HOME"

Create one branch/worktree from the pinned integration SHA:
`lane/android2-state-ownership-correction`.

The lane may own only:
- android/app/src/main/java/com/chromaglow/app/app/ChromaGlowApp.kt
- android/app/src/main/java/com/chromaglow/app/feature/dashboard/DashboardPlaceholderScreen.kt
- android/app/src/androidTest/java/com/chromaglow/app/app/NavIntegrationE2ETest.kt
- android/app/src/androidTest/java/com/chromaglow/app/app/ChromaGlowAppTest.kt, only if needed
- android/app/src/androidTest/java/com/chromaglow/app/feature/dashboard/DemoRoomControlsTest.kt, only if needed

Required correction:
1. Hoist demo-session mutations to ChromaGlowApp so they survive navigation within the current demo
   session. Do not add disk persistence, networking, REST, pairing, or credential behavior.
2. Keep DemoModeSession's type unchanged. ChromaGlowApp may own remembered room/light/scene state and
   reset it from DemoFixtures only when entering or exiting demo mode.
3. Dashboard room toggle/brightness changes must update app-owned room state as well as the visible
   row. Add bridge-aware callbacks to DashboardPlaceholderScreen as needed; preserve existing public
   defaults and existing Switch/Slider/status text.
4. Pass app-owned light state into RoomDetailScreen and consume its existing
   `(bridgeId, lightId, value)` callbacks to update the matching light.
5. Pass app-owned scene state into ScenesScreen and consume its existing `(bridgeId, sceneId)` callback
   so exclusive activation survives leaving and reopening Scenes.
6. Keep Wave 1 feature internals unchanged; their callback contracts are already correct.
7. Extend NavIntegrationE2ETest to prove persistence: after changing a room-detail light, navigate back
   and reopen the same room and assert the changed state; after activating a scene, navigate back and
   reopen Scenes and assert the selected scene remains active and the previous scene remains inactive.
   Also retain Settings back and Exit Demo Mode coverage.
8. Preserve all Batch 1 tests and all Batch 2 screen tests.

Validation/integration:
1. Run `./gradlew testDebugUnitTest lintDebug assembleDebug` in the correction worktree.
2. Commit and report the lane SHA plus structured handoff. Do not edit coordination docs from the lane.
3. Verify only allowed files changed.
4. Merge `--no-ff` into `integration/parallel-batch-2` as batch owner.
5. Boot headless Pixel_10 and run
   `./gradlew testDebugUnitTest lintDebug assembleDebug connectedDebugAndroidTest`.
6. Push corrected integration. Do not merge to main.
7. On the docs branch, append Claude's D-009 response, corrected integration SHA, final test counts,
   and one consolidated DEVLOG handoff; update §8/AGENTS.md status. Run `git diff --check`, commit, push.

Report correction SHA, corrected integration SHA, changed-file audit, full validation, docs SHA, and
remote refs. Stop on any failed gate.
```
