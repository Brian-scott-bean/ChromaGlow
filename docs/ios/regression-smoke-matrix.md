# iOS Regression Smoke Matrix

## Purpose

This checklist protects the current TestFlight iOS app while documentation, bug fixes, and future refactor seams are introduced.

Use it before and after any iOS PR that changes runtime behavior. Documentation-only PRs do not need the full smoke run, but they should not claim behavior is verified unless someone actually tested it.

## Test result legend

| Result | Meaning |
|---|---|
| Pass | Works as expected |
| Fail | Regression or blocking issue found |
| Partial | Works with limitations |
| Not tested | Not run in this pass |
| Not applicable | Not part of this build/device setup |

## Required test context

| Field | Value |
|---|---|
| Tester | TODO |
| Date | TODO |
| Branch | TODO |
| Commit SHA | TODO |
| App version/build | TODO |
| Xcode version | TODO |
| Install type | TODO: clean / upgrade / TestFlight / local debug |
| iPhone model | TODO |
| iOS version | TODO |
| Hue bridge count | TODO |
| Lights/rooms tested | TODO |
| Apple Watch tested | TODO |
| Widget tested | TODO |

## Build and launch

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-001 | Clean build | Build app from current branch in Xcode | App builds without blocking errors | TODO |  |
| IOS-SMOKE-002 | Clean install launch | Install app with no existing local data | App launches and reaches setup/demo path | TODO |  |
| IOS-SMOKE-003 | Existing install launch | Launch app with existing paired bridge data | App launches to main app without losing state | TODO |  |
| IOS-SMOKE-004 | Relaunch | Force close and reopen app | App restores expected state | TODO |  |
| IOS-SMOKE-005 | Background/foreground | Send app to background, then foreground | UI and bridge state remain usable | TODO |  |

## Demo mode

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-010 | Demo entry | Enter demo mode from setup/onboarding path | Demo app state loads | TODO |  |
| IOS-SMOKE-011 | Demo dashboard | View dashboard in demo mode | Demo rooms/lights render | TODO |  |
| IOS-SMOKE-012 | Demo room action | Toggle/change a demo room or light | UI updates without real bridge dependency | TODO |  |
| IOS-SMOKE-013 | Exit demo | Exit or reset demo mode if supported | App returns to expected setup/main state | TODO |  |

## Bridge discovery and pairing

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-020 | Local network permission | Trigger discovery on a clean install | Permission/user education appears as expected | TODO |  |
| IOS-SMOKE-021 | mDNS discovery | Search for bridges on Wi-Fi | Bridge appears without manual entry | TODO |  |
| IOS-SMOKE-022 | Fallback discovery | Test when mDNS is unavailable, if practical | Fallback behavior is graceful | TODO |  |
| IOS-SMOKE-023 | Pair success | Press bridge button and pair | Bridge credential is stored and app enters main UI | TODO |  |
| IOS-SMOKE-024 | Pair failure | Attempt pair without pressing bridge button | Clear error/retry state appears | TODO |  |
| IOS-SMOKE-025 | Bridge offline | Turn bridge off/unreachable after pairing | App shows offline/error state without crash | TODO |  |

## Dashboard and room control

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-030 | Dashboard render | Open dashboard | Rooms/zones/lights render correctly | TODO |  |
| IOS-SMOKE-031 | Room toggle on/off | Toggle a room from dashboard | Physical lights and UI update | TODO |  |
| IOS-SMOKE-032 | Brightness change | Adjust room/light brightness | Physical lights and UI update | TODO |  |
| IOS-SMOKE-033 | Color change | Change light color | Physical light color and UI update | TODO |  |
| IOS-SMOKE-034 | Room detail open | Open a room detail screen | Room detail loads correct lights/scenes | TODO |  |
| IOS-SMOKE-035 | Bulk action | Use a bulk action if available | Selected lights update together | TODO |  |
| IOS-SMOKE-036 | Optimistic rollback | Cause a failed bridge action if practical | UI recovers without stale incorrect state | TODO |  |

## Scenes

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-040 | Scene list | Open scenes surface | Scenes render without crash | TODO |  |
| IOS-SMOKE-041 | Activate room scene | Activate a room scene | Bridge applies scene and UI remains accurate | TODO |  |
| IOS-SMOKE-042 | Create scene | Create a basic scene if supported | Scene persists and can be activated | TODO |  |
| IOS-SMOKE-043 | Edit/delete scene | Edit or delete if supported | Changes persist or clear error is shown | TODO |  |
| IOS-SMOKE-044 | Global scene | Use global scene if in baseline | Expected multi-room behavior occurs | TODO |  |

## Studio/composer and sync

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-050 | Studio open | Open Studio | Studio opens without blocking launch/app crash | TODO |  |
| IOS-SMOKE-051 | Select target room | Pick a room/bridge target | Correct lights/rooms are available | TODO |  |
| IOS-SMOKE-052 | Apply composition | Apply a simple composition/effect | Bridge updates as expected | TODO |  |
| IOS-SMOKE-053 | Save/load composition | Save and reload if supported | State persists correctly | TODO |  |
| IOS-SMOKE-054 | Sync mode open | Open sync/music mode | Permission/ready state appears | TODO |  |
| IOS-SMOKE-055 | Microphone permission | Start mic-driven sync if in baseline | Permission prompt and failure states are correct | TODO |  |
| IOS-SMOKE-056 | Stop sync | Stop an active sync/entertainment session | Lights/session stop cleanly | TODO |  |

## Widgets, App Intents, and watch

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-060 | Widget render | Add/view widget | Widget shows expected rooms/state | TODO |  |
| IOS-SMOKE-061 | Widget action | Use widget room/light action | Action reaches correct bridge/room | TODO |  |
| IOS-SMOKE-062 | App Intent/Siri action | Run available app shortcut | Action completes or fails gracefully | TODO |  |
| IOS-SMOKE-063 | Watch app launch | Open watch app | Watch UI loads expected state | TODO |  |
| IOS-SMOKE-064 | Watch action | Trigger room/light action from watch | Action reaches correct target | TODO |  |
| IOS-SMOKE-065 | Watch sync | Change phone state, observe watch | Watch data updates or known limitations documented | TODO |  |

## Multi-bridge

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-070 | Multiple bridges listed | Pair/load multiple bridges | App shows both without merged/duplicated state | TODO |  |
| IOS-SMOKE-071 | Bridge-specific room action | Toggle room on bridge A while bridge B exists | Action routes only to bridge A | TODO |  |
| IOS-SMOKE-072 | Bridge switch | Switch target bridge/context if supported | UI and actions use selected bridge | TODO |  |
| IOS-SMOKE-073 | One bridge offline | Take one bridge offline | Other bridge remains usable | TODO |  |

## Settings, automations, and persistence

| ID | Scenario | Steps | Expected result | Result | Notes |
|---|---|---|---|---:|---|
| IOS-SMOKE-080 | Settings open | Open settings/more | UI loads without crash | TODO |  |
| IOS-SMOKE-081 | Automation list | Open automations | Existing automations render | TODO |  |
| IOS-SMOKE-082 | Create automation | Create a simple automation if supported | Automation saves/schedules | TODO |  |
| IOS-SMOKE-083 | Restart persistence | Relaunch after changes | Rooms/scenes/settings persist as expected | TODO |  |
| IOS-SMOKE-084 | Token persistence | Relaunch after pairing | Bridge remains paired; no re-pair required | TODO |  |

## PR signoff

Before merging behavior-changing iOS PRs, fill this out:

| Field | Value |
|---|---|
| PR link | TODO |
| Smoke matrix run? | TODO |
| Required failures accepted? | TODO |
| Baseline docs updated? | TODO |
| Android parity docs affected? | TODO |
| Reviewer | TODO |
| Merge decision | TODO |
