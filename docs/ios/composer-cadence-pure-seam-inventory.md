# Composer Cadence Pure-Seam Inventory

## Purpose

Inventory the next bounded, substantially pure extraction seam in `UnifiedOrchestrator` after IOS-REF-003B, with explicit focus on Composer cadence logic and nearby deterministic helpers.

## Current Baseline

- Product/repo: ChromaGlow (`HueHome.xcodeproj`)
- Working branch: `ios-ref/composer-cadence-seam-inventory`
- Starting SHA for this slice: `bc1cbbc`
- Documented prior extraction: IOS-REF-003B (`RoomAndZoneDisplayModelBuilder`)
- User-provided validated baseline for current mainline:
  - `RoomAndZoneDisplayModelBuilderTests` 6/6 pass
  - `DashboardDisplayModelBuilderTests` 14/14 pass
  - signed-simulator `HueHomeTests` 74/74 pass
  - IOS-REF-003B physical-device smoke pass

## Existing Extracted Orchestrator Seams

- IOS-REF-001R: rooms flatten/sort extraction into `DashboardDisplayModelBuilder.makeRooms(from:)`
- IOS-REF-002: zones flatten/sort extraction into `DashboardDisplayModelBuilder.makeZones(from:)`
- IOS-REF-003B: room+zone+light+grouped-light display-model extraction into `RoomAndZoneDisplayModelBuilder.makeDisplayModels(...)`

## Composer Scheduling Overview

Current Composer scheduling in `UnifiedOrchestrator` is split across:

- `startCompositionMode(...)` (~`1674-1919`): runtime setup, transport selection, priming, scheduler bootstrap.
- `runCompositionEntertainment(...)` (~`1922-1954`): DTLS loop at ~25fps (`Task.sleep` 40ms).
- `runCompositionScheduler()` (~`2019-2184`): REST scheduler loop using fixed `tickInterval = 120ms`, round-robin priority selection, mailbox enqueue.
- `nextCompositionRoomPriority(now:)` (~`2232-2262`): deterministic score function over in-memory runtime state.

Cadence helper quartet exists near scheduler internals:

- `minimumComposerRESTInterval(roomCount:tier:)` (~`2187-2189`)
- `minimumComposerBurstFloor(roomCount:tier:)` (~`2191-2193`)
- `preferredComposerIdleInterval(roomCount:tier:)` (~`2195-2197`)
- `lowPowerIdleInterval(roomCount:tier:)` (~`2199-2201`)

## Cadence Helper Inventory

| Helper | Current location | Inputs | Output | Callers | Side effects | Classification | Risk notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `minimumComposerRESTInterval(roomCount:tier:)` | `UnifiedOrchestrator.swift` ~`2187-2189` | `roomCount: Int`, `tier: CompositionTier` | `Double` | None (no call sites in repo) | None; no state read/mutation, no I/O | PURE | Returns `0.12 * max(1, roomCount)`; tier currently ignored. Negative/zero room count clamped to 1. |
| `minimumComposerBurstFloor(roomCount:tier:)` | `UnifiedOrchestrator.swift` ~`2191-2193` | `roomCount: Int`, `tier: CompositionTier` | `Double` | None | None | PURE | Same formula as minimum REST interval; identical clamp behavior. |
| `preferredComposerIdleInterval(roomCount:tier:)` | `UnifiedOrchestrator.swift` ~`2195-2197` | `roomCount: Int`, `tier: CompositionTier` | `Double` | None | None | PURE | Same formula; deterministic scalar helper only. |
| `lowPowerIdleInterval(roomCount:tier:)` | `UnifiedOrchestrator.swift` ~`2199-2201` | `roomCount: Int`, `tier: CompositionTier` | `Double` | None | None | PURE | Returns `0.25 * max(1, roomCount)`; tier currently ignored. |

Notes grounded in current source:

- `CompositionTier` cases are `bridgeOptimized`, `hybrid`, `runtimeOnly` (defined in `CompositionModels.swift`), but the four cadence helpers do not branch by tier yet.
- Helpers do not read orchestrator properties, do not mutate orchestrator state, and do not perform network/persistence/scheduler operations.
- Helpers touch timing semantics only indirectly if a caller uses returned values. At present, they are not consumed by the active scheduler.
- Active scheduler currently uses constant `tickInterval = 120ms` and writes `runtime.nextDueAt = now + 0.12` in `runCompositionScheduler()`.

## Remaining Pure Candidate Comparison

| Rank | Candidate | Inputs | Outputs | Side effects | Suggested tests | Risk | Recommendation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Composer cadence scalar quartet (`minimumComposerRESTInterval`, `minimumComposerBurstFloor`, `preferredComposerIdleInterval`, `lowPowerIdleInterval`) | `roomCount`, `tier` | `Double` cadence values | None | Optional cleanup-only tests if later deletion/extraction is approved | Low for behavior, low practical payoff | **Do not extract now (pure but unwired)** |
| 2 | `nextCompositionRoomPriority(now:)` score selection | `now`, `compositionOrder`, `compositionRuntimes` | `String?` room ID | Reads runtime state; no I/O | Priority/fairness fixture tests | Medium (scheduler behavior coupling) | Defer (explicitly out-of-scope for this extraction) |
| 3 | `recordCompositionTelemetry(...)` cadence reporting helper | room/time metrics + telemetry maps | telemetry map updates + exposed cadence vars | Mutates orchestrator state | state mutation tests + cadence window tests | Medium | Defer (STATE_MUTATION_ONLY, not pure) |

## IOS-REF-004B Decision

No production extraction is recommended for the cadence scalar quartet.

The helpers are pure but currently have no call sites. Extracting them into a new helper type would move unused code rather than isolate live runtime behavior.

A separate optional dead-code cleanup may evaluate deletion after explicit approval and a Composer smoke plan.

## Required Signed-Simulator Validation

For this IOS-REF-004A documentation-only slice:

- No simulator build/test run required.
- Preserve documented baseline only.

For any future approved dead-code cleanup of the cadence quartet:

- Run full signed-simulator `HueHomeTests` and compare against current baseline.
- Include focused Composer manual checks (see physical-device smoke scope).

## Required Physical-Device Smoke Scope

For any future approved dead-code cleanup PR (not this docs slice):

- Open Studio Composer deck.
- Apply a composition to one room and verify responsiveness remains unchanged.
- Run multi-room composition concurrently and verify no visible cadence regression.
- Confirm entertainment-vs-REST transport selection behavior remains unchanged.

This is precautionary coverage only; no behavior changes are made in IOS-REF-004A.

## Recommended Next Inventory

Recommend a new documentation-only slice:

`IOS-REF-005A — Inventory a live pure scoring sub-helper inside nextCompositionRoomPriority(now:)`

That inventory should determine whether room-priority scoring can be separated into a value-only helper without changing scheduler state reads, runtime mutation, transport routing, or timing behavior.

Do not implement that helper in this slice.

## Deferred High-Risk Composer Areas

- `runCompositionScheduler()` loop behavior and `Task.sleep` cadence.
- `runCompositionEntertainment(...)` DTLS frame loop.
- `nextCompositionRoomPriority(now:)` scheduler fairness logic.
- `compositionRuntimes` mutation lifecycle and generation guards.
- `studioRestSender` mailbox behavior.
- DTLS/REST routing, entertainment config resolution, bridge-stored animation routing.
- Mic demand synchronization and any SSE/network/persistence-adjacent orchestration.

## Open Questions

- Should cadence helpers remain as currently unwired internals until an explicit cleanup decision is approved?
- Should an approved cleanup remove the unwired quartet entirely rather than extracting it?
- Should Composer cadence constants (`0.12`, `0.25`) be centralized with explicit product tuning notes to reduce future drift?
