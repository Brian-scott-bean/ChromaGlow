# Composer Priority-Scoring Pure-Seam Inventory

## Purpose

Inventory whether a bounded, live, value-only scoring helper can be safely extracted from `nextCompositionRoomPriority(now:)` without changing Composer scheduler behavior.

## Current Baseline

- Product/project: ChromaGlow / `HueHome.xcodeproj` (scheme `HueHome 1`)
- Branch: `ios-ref/composer-priority-scoring-inventory`
- Starting SHA: `cb01e11`
- Verified baseline carried forward from prior slices:
  - `RoomAndZoneDisplayModelBuilderTests` 6/6 pass
  - `DashboardDisplayModelBuilderTests` 14/14 pass
  - Full signed-simulator `HueHomeTests` 74/74 pass
  - IOS-REF-003B physical-device dashboard/room/zone smoke pass

## Existing Extracted Orchestrator Seams

- IOS-REF-001R: `DashboardDisplayModelBuilder.makeRooms(from:)`
- IOS-REF-002: `DashboardDisplayModelBuilder.makeZones(from:)`
- IOS-REF-003B: `RoomAndZoneDisplayModelBuilder.makeDisplayModels(...)`

## Prior Cadence No-Extraction Decision

IOS-REF-004A confirmed the cadence scalar quartet is pure but unwired (zero call sites):

- `minimumComposerRESTInterval(roomCount:tier:)`
- `minimumComposerBurstFloor(roomCount:tier:)`
- `preferredComposerIdleInterval(roomCount:tier:)`
- `lowPowerIdleInterval(roomCount:tier:)`

Decision held: no IOS-REF-004B production extraction.

## Live Composer Scheduler Overview

- `runCompositionScheduler()` in `UnifiedOrchestrator` is live and calls `nextCompositionRoomPriority(now:)` once per scheduler tick.
- Current scheduler behavior:
  - fixed `tickInterval = 120ms`
  - generation guard before enqueueing sends
  - REST mailbox (`studioRestSender`) latest-wins enqueue
  - runtime mutation after selection/send (`lastSent*`, `sendCount`, `nextDueAt`)
- Priority function is selection-only: chooses one `roomID` (or `nil`) from `compositionOrder`.

## nextCompositionRoomPriority(now:) Algorithm

- Location (approx): `UnifiedOrchestrator.swift` lines `2232-2262`
- Direct caller(s): `runCompositionScheduler()` (`2045`)
- Live status: confirmed live; no test-only or dead call path found.

Current algorithm (exact behavior):

1. Initialize:
   - `selectedRoomID = nil`
   - `selectedScore = -infinity`
2. Iterate `compositionOrder` in array order.
3. For each `roomID`:
   - Lookup runtime in `compositionRuntimes`; skip if missing.
   - Due gate: skip when `now + 0.004 < runtime.nextDueAt` (4ms near-due grace).
   - Compute:
     - `isInteracting = runtime.paramBox.isColorPadInteracting`
     - `burstActive = runtime.interactionBurstUntil.map { now < $0 } ?? false`
     - `overdue = max(0, now - runtime.nextDueAt)`
     - `sinceLastSend = now - (runtime.lastSentAt ?? runtime.startTime)`
   - Compute score:
     - `+1000` if interacting
     - `+500` if burst active
     - `+260` if `pendingSettle`
     - `+min(220, overdue * 120)`
     - `+min(160, max(0, sinceLastSend - 1.4) * 45)`
     - `-min(60, Double(runtime.sendCount % 120) * 0.35)` fairness nudge
   - If `score > selectedScore`, replace selected room/score.
4. Return selected room ID, else `nil`.

## State Read / Mutation Boundary

| Concern | Current behavior | Read or mutation | Location | Extraction risk |
| --- | --- | --- | --- | --- |
| Room iteration source | Uses `compositionOrder` sequence | Read | `nextCompositionRoomPriority` | Must preserve order |
| Runtime lookup | Reads `compositionRuntimes[roomID]` | Read | `nextCompositionRoomPriority` | None if loop stays in orchestrator |
| Due gating | Skips rooms not due (with 4ms grace) | Read | `nextCompositionRoomPriority` | High if threshold changes |
| Score calculation | Deterministic weighted scalar from runtime fields and `now` | Read | `nextCompositionRoomPriority` | Low if byte-for-byte preserved |
| Tie-breaking | Strict `>` keeps first equal-score room encountered | Read/selection | `nextCompositionRoomPriority` | High if changed to `>=` |
| Selection mutation | No runtime mutation inside selection method | None | `nextCompositionRoomPriority` | Low |
| Post-selection runtime updates | Mutates `lastSent*`, `sendCount`, `nextDueAt` after send enqueue | Mutation (outside scorer) | `runCompositionScheduler` | Must remain outside extracted scorer |

## Candidate Value-Only Score Contract

A bounded sub-helper is viable if it only scores one immutable runtime snapshot and returns score metadata.

Recommended contract shape:

- Input: immutable score snapshot + `now`
- Output: optional score result (`nil` when not due/eligible)

## Candidate Input Snapshot

Suggested immutable snapshot fields for a score helper:

- `nextDueAt: CFAbsoluteTime`
- `isColorPadInteracting: Bool`
- `interactionBurstUntil: CFAbsoluteTime?`
- `pendingSettle: Bool`
- `lastSentAt: CFAbsoluteTime?`
- `startTime: CFAbsoluteTime`
- `sendCount: Int`

All are value-only and already read by current scoring code.

## Candidate Output Contract

Narrowest behavior-preserving output:

- `CompositionPriorityScore?` where:
  - `score: Double`
  - optional metadata for diagnostics only (e.g., `overdue`, `sinceLastSend`) if desired

Reasoning:

- Returning plain `Double?` is minimal and enough.
- Returning eligibility tuple is equivalent but less clear.
- Struct is preferable only if scheduler/debug telemetry wants explicit due-state metadata.

## Tie-Breaking and Ordering Constraints

Behavior that must remain unchanged in any IOS-REF-005B extraction:

- Iterate `compositionOrder` exactly as today.
- Skip missing runtimes exactly as today.
- Keep due gate exactly: `now + 0.004 < nextDueAt`.
- Keep score term constants/weights exactly.
- Keep fairness modulo term exactly.
- Keep comparison operator exactly `>` (not `>=`) to preserve first-in-order tie winner.
- Keep default `nil` when no eligible room.

## Remaining Pure Candidate Comparison

| Rank | Candidate | Live call sites | Inputs | Outputs | Side effects | Suggested tests | Risk | Recommendation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Priority scoring sub-helper extracted from `nextCompositionRoomPriority(now:)` | 1 (`runCompositionScheduler`) | Immutable runtime snapshot + `now` | `Double?` or small score result | None | Due-gate, weighting, tie invariants, no-mutation tests | Low/medium | **Recommend for IOS-REF-005B** |
| 2 | `recordCompositionTelemetry(...)` decomposition | 1 (`runCompositionScheduler`) | Room IDs, due/sent timestamps, telemetry maps | map updates + cadence updates | Mutates orchestrator state | telemetry window/cadence update tests | Medium | Defer (STATE_MUTATION_ONLY) |
| 3 | `resolveCompositionLightIDs(for:api:)` helper extraction | live in `startCompositionMode` | room refs + API state | light ID list | May call network (`fetchLights`) | room/zone light resolution tests | Medium/high | Defer (MIXED: deterministic + NETWORK_IO) |

## IOS-REF-005B Decision

**Recommend IOS-REF-005B pure scoring helper extraction.**

Rationale:

- Live call path confirmed.
- Current score logic is value-only and deterministic.
- No network, no SSE, no `Task`, no persistence, no routing logic in score math.
- Runtime mutation remains outside scoring and can stay untouched.
- Small, reviewable production diff is feasible.

## Proposed IOS-REF-005B Helper Contract

- Proposed type name: `CompositionRoomPriorityScorer`
- Proposed path: `HueHome/Core/Composer/CompositionRoomPriorityScorer.swift`
- Proposed immutable input:
  - `struct ScoreInput { nextDueAt, isColorPadInteracting, interactionBurstUntil, pendingSettle, lastSentAt, startTime, sendCount }`
- Proposed output:
  - `static func score(now: CFAbsoluteTime, input: ScoreInput) -> Double?`
  - returns `nil` when not due (same 4ms grace gate), else weighted score.

## Required Unit Tests

Focused tests for IOS-REF-005B:

1. Not-due runtime returns `nil` with exact 4ms grace behavior.
2. Interacting room adds +1000.
3. Burst-active room adds +500.
4. Pending-settle adds +260.
5. Overdue term saturates at +220.
6. Since-last-send term starts only after 1.4s and saturates at +160.
7. Fairness term subtraction uses `sendCount % 120` with cap 60.
8. Selection loop tie behavior preserved by orchestrator (`>` keeps first equal-score room).
9. Selection method still mutates nothing.

## Required Signed-Simulator Validation

For IOS-REF-005B implementation PR (not this doc slice):

- Run full signed-simulator `HueHomeTests` and match/expand baseline from 74/74.
- Run targeted Composer scheduler unit tests for scoring parity.
- Confirm no regressions in existing orchestrator tests around composition start/stop paths.

## Required Physical-Device Composer Smoke Scope

For IOS-REF-005B implementation PR (not this doc slice):

1. Start Composer in one room; verify responsiveness unchanged.
2. Start Composer across multiple rooms; verify no starvation or oscillation regression.
3. Rapid slider interaction in one room while another is active; verify interaction priority feels unchanged.
4. Confirm entertainment/REST routing behavior unchanged (no transport selection regressions).

No physical-device testing is required for this documentation-only IOS-REF-005A slice.

## Deferred High-Risk Composer Areas

- `runCompositionScheduler()` tick cadence and sleep behavior.
- REST mailbox internals and enqueue semantics.
- Generation-guard lifecycle and teardown paths.
- Transport routing (bridge-stored vs entertainment vs REST).
- Mic-demand synchronization logic.
- Any SSE/persistence/credentials or extension snapshot surfaces.

## Open Questions

- Should the scorer output remain `Double?` (minimal) or include optional debug metadata in a small result struct?
- Should due-gate epsilon (`0.004`) be centralized as a named constant during extraction, or left inline to minimize churn?
