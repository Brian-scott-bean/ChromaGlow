# Parallel Batch 1 Launch Prompt

## Status

- **State:** Ready
- **Batch:** `parallel-batch-1`
- **Manifest:** `docs/coordination/parallel-agent-pipeline.md` §7
- **Pinned base:** `origin/main` @ `defe8691345623adac347862cf271320f5d4610d`
- **Last reviewed:** 2026-06-28

## Prompt

```text
Read AGENTS.md, the Current Status Snapshot in DEVLOG.md, and §1–§7 of
docs/coordination/parallel-agent-pipeline.md.

Execute the approved Android Batch 1 two-lane pilot.

Before launching:
1. Fetch all remotes.
2. Confirm origin/main is still defe8691345623adac347862cf271320f5d4610d. If it advanced, stop and revalidate/re-pin the manifest and this prompt.
3. Export:
   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   ANDROID_HOME="$HOME/Library/Android/sdk"
   ANDROID_SDK_ROOT="$ANDROID_HOME"
4. Create integration/parallel-batch-1 from the pinned origin/main commit.
5. Create isolated worktrees and branches for both lanes.
6. The batch owner alone may edit DEVLOG.md or docs/coordination/parallel-agent-pipeline.md.

Launch these two agents concurrently:

Agent A: lane/android1-domain-models
- Own only:
  android/app/src/main/java/com/chromaglow/app/core/model/**
  android/app/src/main/java/com/chromaglow/app/data/demo/**
  android/app/src/test/java/com/chromaglow/app/core/model/**
  android/app/src/test/java/com/chromaglow/app/data/demo/**
- Implement the Lane 1 deliverable and acceptance criteria from §7.
- Run ./gradlew testDebugUnitTest from android/.
- Commit the lane and return its SHA, validation summary, and structured handoff.
- Do not edit coordination docs or files outside the lane.

Agent B: lane/android1-dashboard-controls
- Own only:
  android/app/src/main/java/com/chromaglow/app/feature/dashboard/**
  android/app/src/androidTest/java/com/chromaglow/app/feature/dashboard/**
- Implement the Lane 2 deliverable and acceptance criteria from §7.
- Boot Pixel_10 headlessly and run ./gradlew connectedDebugAndroidTest.
- Commit the lane and return its SHA, validation summary, and structured handoff.
- Do not edit coordination docs or files outside the lane.

After both agents finish:
1. Verify each branch changed only its permitted files.
2. Merge both into integration/parallel-batch-1.
3. Run testDebugUnitTest, lintDebug, assembleDebug, and connectedDebugAndroidTest on the integrated result.
4. Do not merge to main.
5. As batch owner, update the registry and append one consolidated DEVLOG.md handoff.
6. Report lane SHAs, integration SHA, validation results, and any deviations.
```
