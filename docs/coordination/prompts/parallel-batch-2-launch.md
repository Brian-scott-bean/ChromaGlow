# Parallel Batch 2 Launch Prompt

## Status

- **State:** DRAFT — **not execution-approved.** Blocked on Decision Log **D-008** (Codex adversarial
  review of the §8 manifest). Do not run until D-008 is ACCEPTED and this prompt is flipped to `Ready`.
- **Batch:** `parallel-batch-2`
- **Manifest:** `docs/coordination/parallel-agent-pipeline.md` §8 (two-wave feature + nav integration)
- **Pinned base:** `main` @ `a3fe54f978c3a5a78d7f35605b1c3ff37c23edca` (corrected Batch 1 landed on `main`)
- **Last reviewed:** 2026-06-28 (Claude internal 3-lens review folded into §8; Codex review pending)

## Prompt

```text
Read AGENTS.md, the Current Status Snapshot and latest parallel-pipeline entries in DEVLOG.md, and
§1–§3, §6 (D-008 + Q6–Q9), and §8 of docs/coordination/parallel-agent-pipeline.md.

Execute the approved Android Batch 2 two-wave pilot (Wave 1: parallel feature packages; Wave 2: one
serialized nav-integration lane). Honor the landed Batch 1 contracts in AGENTS.md "Android Current State".

Before launching:
1. Fetch all remotes.
2. Confirm D-008 is ACCEPTED by Codex (manifest reviewed). If still PROPOSED/DISCUSSING, stop.
3. Confirm origin/main is still a3fe54f978c3a5a78d7f35605b1c3ff37c23edca. If it advanced, stop and
   revalidate/re-pin the manifest and this prompt.
4. Export:
   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   ANDROID_HOME="$HOME/Library/Android/sdk"
   ANDROID_SDK_ROOT="$ANDROID_HOME"
5. Create integration/parallel-batch-2 from the pinned origin/main commit.
6. The batch owner alone may edit DEVLOG.md or docs/coordination/parallel-agent-pipeline.md.

Shared-device rule: there is ONE Pixel_10 AVD. Lanes may develop concurrently, but the batch owner runs
each lane's connectedDebugAndroidTest SERIALLY on the shared emulator (or provisions isolated emulators).

=== Wave 1 (parallel; create one isolated worktree + branch per lane from the pinned base) ===

Agent A: lane/android2-roomdetail (registry android-roomdetail)
- Own only: android/app/src/main/java/com/chromaglow/app/feature/roomdetail/**
            android/app/src/androidTest/java/com/chromaglow/app/feature/roomdetail/**
- Implement the Lane R deliverable + acceptance from §8 (RoomDetailScreen; remembered state seeded from
  lights; slider valueRange 1f..100f + coerceIn(1,100); forwards callbacks). Read-only import core/model
  and DemoFixtures.
- Validate: connectedDebugAndroidTest (the owner schedules it serially). Commit and return SHA + handoff.

Agent B: lane/android2-scenes (registry android-scenes)
- Own only: android/app/src/main/java/com/chromaglow/app/feature/scenes/**
            android/app/src/androidTest/java/com/chromaglow/app/feature/scenes/**
- Implement the Lane S deliverable + acceptance from §8 (ScenesScreen; exclusive activation; target room
  via roomNames[scene.roomId] ?: scene.roomId). Read-only import core/model and DemoFixtures.
- Validate: connectedDebugAndroidTest (serialized). Commit and return SHA + handoff.

Agent C: lane/android2-settings (registry android-settings)
- Own only: android/app/src/main/java/com/chromaglow/app/feature/settings/**
            android/app/src/androidTest/java/com/chromaglow/app/feature/settings/**
- Implement the Lane T deliverable + acceptance from §8 (SettingsScreen; appVersion is a passed-in
  literal — do NOT use or enable BuildConfig). 
- Validate: connectedDebugAndroidTest (serialized). Commit and return SHA + handoff.

After Wave 1: verify each branch changed only its permitted files, merge all three into
integration/parallel-batch-2, and run a serialized connected gate on the integrated result.

=== Wave 2 (serialized; runs AFTER all Wave 1 lanes are merged) ===

Agent D: lane/android2-nav-integration (registry android-nav-shell; reclaims android-dashboard this batch)
- Branch from integration/parallel-batch-2 (post Wave-1 merge).
- Own only: android/app/src/main/java/com/chromaglow/app/app/ChromaGlowApp.kt
            android/app/src/main/java/com/chromaglow/app/app/ChromaGlowDestination.kt
            android/app/src/main/java/com/chromaglow/app/feature/dashboard/**   (additive entry points only)
            android/app/src/androidTest/java/com/chromaglow/app/feature/dashboard/**  (owns DemoRoomControlsTest)
            android/app/src/androidTest/java/com/chromaglow/app/app/NavIntegrationE2ETest.kt  (new)
            android/app/src/androidTest/java/com/chromaglow/app/app/ChromaGlowAppTest.kt  (may edit; keep green)
- Implement the Lane N deliverable + acceptance from §8: extend ChromaGlowDestination; route ChromaGlowApp
  to each Wave 1 screen with demo data; add ADDITIVE entry points (discrete onOpenRoom affordance with its
  own testTag; explicit Scenes/Settings buttons) without altering the Switch/Slider or the exact
  status-line text. Do not edit Wave 1 feature internals.
- Validate: full gate testDebugUnitTest lintDebug assembleDebug connectedDebugAndroidTest, with the new
  E2E reaching + exercising every Wave 1 screen. Commit and return SHA + handoff.

After Wave 2:
1. Verify Lane N changed only its permitted files.
2. Merge Lane N into integration/parallel-batch-2.
3. Run the full integrated gate (testDebugUnitTest, lintDebug, assembleDebug, connectedDebugAndroidTest).
4. Promotion gate: integration/parallel-batch-2 is eligible for the final merge to main ONLY if Lane N's
   connected E2E is green (no unwired UI). Push the integration branch. Do not merge to main without the
   human collaborator's go-ahead.
5. As batch owner, update the registry (lanes merged), §8 result, and append one consolidated DEVLOG.md
   handoff.
6. Report all lane SHAs, the integration SHA, validation results, and any deviations.
```
