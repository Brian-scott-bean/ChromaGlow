# Composer Light-Resolution Pure-Seam Inventory

## Purpose

Inventory the live Composer light-resolution methods in `UnifiedOrchestrator` and determine whether IOS-REF-006B can extract one bounded, deterministic, value-only seam while preserving all existing network, credentials, JSON parsing, routing, transport, fallback, ordering, and duplicate behavior.

## Current Baseline

- Working branch: `ios-ref/composer-light-resolution-inventory`
- Starting SHA: `93a3584`
- Current validated baseline (provided): `CompositionRoomPriorityScorerTests` 19/19, `RoomAndZoneDisplayModelBuilderTests` 6/6, `DashboardDisplayModelBuilderTests` 14/14, signed-simulator `HueHomeTests` 93/93, IOS-REF-005B physical-device Composer smoke pass.
- Slice scope: documentation-only. No Swift or project-file changes.

## Existing Extracted Orchestrator Seams

- IOS-REF-001R: `DashboardDisplayModelBuilder.makeRooms(from:)`
- IOS-REF-002: `DashboardDisplayModelBuilder.makeZones(from:)`
- IOS-REF-003B: `RoomAndZoneDisplayModelBuilder.makeDisplayModels(...)`
- IOS-REF-005B: `CompositionRoomPriorityScorer.score(now:input:)`
- Prior IOS-REF-004A decision retained: cadence quartet remains pure but unwired and unchanged.

## Live Composer Setup Overview

- `startCompositionMode` in `UnifiedOrchestrator` is live and directly calls:
  - `resolveCompositionGamut(for:api:)`
  - `resolveCompositionLightIDs(for:api:)`
  - `resolveEntertainmentLightPositions(config:api:)`
- Current order inside startup path:
  1. Resolve gamut (with mic warmup overlap when needed).
  2. Resolve composition light IDs for REST and per-light fallback.
  3. If entertainment config exists, resolve light positions by bridging entertainment service IDs to light IDs.
- All three methods are production-path helpers, not dead code.

## Method Inventory

| Method | Current location | Live callers | Inputs | Outputs | I/O and side effects | Fallback behavior | Classification | Risk notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `resolveCompositionGamut(for:api:)` | `UnifiedOrchestrator` (~2262-2286) | `startCompositionMode` (~1694, ~1699) | `RoomDisplayItem`, `HueAPIClient` | `HueColorUtils.Gamut` | Calls `api.fetchLights()`, parses `HueLight.color.gamut_type`, local counting dictionary | `fetchLights` failure -> `.c`; empty resolved lights -> `.c`; no valid gamut_type values -> `.c` | `MIXED_HIGH_RISK` (network + pure interior) | Tie behavior depends on dictionary max over equal counts; extracting whole method would keep network in helper (not allowed). |
| `resolveCompositionLightIDs(for:api:)` | `UnifiedOrchestrator` (~2289-2307) | `startCompositionMode` (~1713) | `RoomDisplayItem`, `HueAPIClient` | `[String]` light IDs | Conditional `api.fetchLights()` only for device-owner path; no state mutation | Empty refs -> `[]`; fetch failure in owner path -> `[]`; direct-light path returns refs-derived list | `MIXED_HIGH_RISK` (network + pure interior) | Direct-light branch preserves order and duplicates; mixed ref types short-circuit to direct-light branch. |
| `resolveEntertainmentLightPositions(config:api:)` | `UnifiedOrchestrator` (~2317-2366) | `startCompositionMode` (~1725) | `EntertainmentConfig`, `HueAPIClient` | `[String: (x: Double, z: Double)]` | Reads `api.credentials()`, parallel fetches `api.get("/clip/v2/resource/entertainment")` + `api.fetchLights()`, parses raw JSON with `JSONSerialization`, logs result | Any credentials/fetch failure -> `[:]`; parse failure -> empty entService map then usually empty final map | `JSON_PAYLOAD_COUPLED` + `NETWORK_IO` + `CREDENTIALS` | Multiple overwrite points on duplicate keys; extraction must not move credential/network/json behavior out of orchestrator. |

## Shared Child-Resource Resolution Semantics

Live semantics shared between `resolveCompositionGamut` and `resolveCompositionLightIDs`:

- Input source: `room.childResourceRefs`.
- Branch rule: if **any** ref has `rtype == "light"`, use direct-light mode.
- Direct-light mode:
  - Match by `light.id` against light ref `rid`.
  - `resolveCompositionLightIDs` preserves reference order and duplicates (`filter/map` on refs).
  - `resolveCompositionGamut` uses a `Set` of IDs then filters `allLights`, so output light order follows bridge light-array order, not ref order.
  - Mixed refs (`light` + `device`) still use direct-light mode and ignore device refs.
- Device-owner mode (no `rtype == "light"` present):
  - Build `deviceIDs` from all refs.
  - Resolve lights where `light.owner?.rid` is in `deviceIDs`.
  - `resolveCompositionLightIDs` returns IDs in fetched light-array order.
  - `resolveCompositionGamut` evaluates gamut from the same resolved light set.

This is a live duplicated deterministic interior and is the strongest pure candidate area.

## Gamut Resolution Semantics

Observed behavior in `resolveCompositionGamut`:

- Always calls `api.fetchLights()` first.
- Resolves `roomLights` using the child-resource semantics above.
- If resolved list is empty -> returns `.c`.
- Initializes counts as `[.a: 0, .b: 0, .c: 0]`.
- For each resolved light:
  - Reads `light.color?.gamut_type?.uppercased()`.
  - Converts via `HueColorUtils.Gamut(rawValue:)`.
  - Unsupported/missing values are skipped.
- Returns `counts.max(by: { $0.value < $1.value })?.key ?? .c`.

Tie notes:

- Equal-count tie behavior is not explicitly encoded as domain logic.
- Result currently depends on dictionary iteration/max selection behavior when counts tie.
- Extraction that rewrites selection mechanics could alter observable behavior.
- Recommendation: keep gamut majority selection inline for IOS-REF-006B unless tie policy is explicitly pinned first.

## Entertainment Position-Mapping Semantics

Observed behavior in `resolveEntertainmentLightPositions`:

- Reads credentials via `api.credentials()`; failure returns `[:]`.
- Starts parallel fetches:
  - `api.get(path: "/clip/v2/resource/entertainment", ip:token:)`
  - `api.fetchLights()`
- If either fetch fails, returns `[:]`.
- Parses entertainment payload using `JSONSerialization` and `[String: Any]` traversal.
- Builds `entServiceToDevice`:
  - key: entertainment service `"id"`
  - value: owner `"rid"` (device ID)
  - duplicate `id` entries overwrite previous values (last write wins by payload order).
- Builds `deviceToLightID` from lights:
  - key: `light.owner?.rid`
  - value: `light.id`
  - duplicate device owners overwrite prior values (last write wins by lights-array order).
- Iterates `config.channels` in order, then each `channel.lightServiceIDs` in order:
  - ent service ID -> device ID -> light ID
  - writes `result[lightID] = (channel.position.x, channel.position.z)`
  - repeated light IDs overwrite earlier positions (later channel/member iteration wins).
- Logs resolved count via `print`.

## State, Network, and Routing Boundaries

| Concern | Current owner | Keep in orchestrator? | Reason |
| --- | --- | --- | --- |
| Bridge fetch (`fetchLights`) | `UnifiedOrchestrator` via `HueAPIClient` | Yes | Network I/O boundary must remain orchestrator-owned. |
| Credentials (`api.credentials()`) | `UnifiedOrchestrator` helper path | Yes | Credentials access is explicitly out of scope for pure extraction. |
| Raw JSON fetch/parse (`/resource/entertainment`) | `UnifiedOrchestrator` | Yes | JSON payload coupling is bridge-contract logic; do not move for IOS-REF-006B. |
| Child-resource light matching | Deterministic interior in helper methods | No (for pure interior) | Value-only transformation can be extracted safely when inputs are pre-fetched values. |
| Gamut majority selection | Deterministic but tie-sensitive interior | Prefer stay inline now | Tie semantics are not explicit; extracting now risks accidental behavioral drift. |
| Transport routing decision | `startCompositionMode` | Yes | DTLS/REST routing must remain unchanged and centralized. |

## Candidate Pure Extraction Seams

| Rank | Candidate | Live call sites | Inputs | Outputs | Side effects | Suggested tests | Risk | Recommendation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Shared child-resource light resolution helper | `resolveCompositionGamut`, `resolveCompositionLightIDs` | `childResourceRefs`, pre-fetched `[HueLight]` | `[HueLight]` and/or `[String]` | None (value-only) | direct-light refs, owner refs, mixed refs, empty refs, duplicate refs/order invariants | Low/medium | **Recommend for IOS-REF-006B** (narrow extraction). |
| 2 | Gamut majority selector | `resolveCompositionGamut` | Resolved `[HueLight]` | `HueColorUtils.Gamut` | None | valid/invalid gamut_type normalization, empty list fallback, tie snapshots | Medium | Defer from 006B; tie policy should be pinned before extraction. |
| 3 | Entertainment mapping interior (post-fetch) | `resolveEntertainmentLightPositions` | `EntertainmentConfig`, entertainment payload data, `[HueLight]` | `[String: (x,z)]` | None if fetch/parse remain external | duplicate overwrite tests for each map layer and iteration order | Medium/high | Defer from 006B due JSON-coupled shape and overwrite sensitivity. |
| 4 | Whole-method extraction: `resolveCompositionGamut` | `startCompositionMode` | room + api | gamut | Includes `fetchLights` | same as current | High | Not recommended (moves network into helper). |
| 5 | Whole-method extraction: `resolveCompositionLightIDs` | `startCompositionMode` | room + api | id list | Includes conditional `fetchLights` | same as current | High | Not recommended (moves network into helper). |
| 6 | Whole-method extraction: `resolveEntertainmentLightPositions` | `startCompositionMode` | config + api | position map | Includes credentials + network + JSON | same as current | High | Not recommended. |

## Ordering, Duplicate, and Tie Constraints

- `resolveCompositionLightIDs` direct-light branch must preserve ref order and duplicate refs.
- Mixed refs (`light` + others) must continue to use direct-light semantics.
- Owner-path ID order currently follows bridge `fetchLights()` response order.
- `resolveCompositionGamut` currently resolves direct-light matches using ID set membership, not ref order.
- `resolveEntertainmentLightPositions` currently has last-write-wins semantics in:
  - entertainment service ID -> device map
  - device ID -> light ID map
  - light ID -> position result map
- Gamut tie outcomes are currently implicit; no explicit domain tie-break policy exists in method code.

## IOS-REF-006B Decision

**Recommend IOS-REF-006B pure helper extraction.**

Scope it to one bounded shared value-only seam: child-resource light resolution used by both `resolveCompositionGamut` and `resolveCompositionLightIDs`.

Do **not** include network fetches, credentials, raw JSON parsing, transport routing, or runtime state mutation in the helper.

## Proposed IOS-REF-006B Helper Contract

Proposed helper type (name can vary, behavior must not):

- `CompositionLightResolver`
- Proposed path: `HueHome/Core/Composer/CompositionLightResolver.swift`

Recommended signatures:

- `static func resolveLights(childResourceRefs: [(rid: String, rtype: String)], lights: [HueLight]) -> [HueLight]`
- `static func resolveLightIDs(childResourceRefs: [(rid: String, rtype: String)], lights: [HueLight]) -> [String]`

Contract constraints:

- Direct light-ref semantics preserved exactly.
- Device-owner fallback preserved exactly.
- Mixed-ref semantics preserved exactly (presence of any `rtype == "light"` chooses direct path).
- Input/output ordering and duplicate behavior preserved exactly:
  - ID method preserves ref-order duplicates in direct path.
  - owner-path order follows provided `lights` order.
- Empty refs -> empty output.
- Fetch failures remain handled in orchestrator before helper invocation.

## Exact Orchestrator Delegation Points

- In `resolveCompositionGamut(for:api:)`:
  - Keep `api.fetchLights()` and fallback returns in orchestrator.
  - Delegate only the deterministic child-resource -> `[HueLight]` resolution.
- In `resolveCompositionLightIDs(for:api:)`:
  - Keep empty-ref guard and `api.fetchLights()` fallback handling in orchestrator.
  - Delegate only deterministic resolution/id derivation to helper.
- Do not delegate `resolveEntertainmentLightPositions` in IOS-REF-006B.

## Expected IOS-REF-006B Changed Files

- `HueHome/Core/Composer/CompositionLightResolver.swift` (new)
- `HueHome/Core/Network/UnifiedOrchestrator.swift` (minimal delegation only)
- `HueHomeTests/CompositionLightResolverTests.swift` (new focused tests)
- Optional: `HueHomeTests/OrchestratorTests.swift` only if existing test scaffolding needs tiny assertions for delegation parity.

## Required Unit Tests

- Direct refs:
  - preserves ref order and duplicates in ID output.
  - resolves matching `HueLight` values by `light.id`.
- Owner fallback:
  - no direct light refs -> resolves by `light.owner?.rid`.
  - preserves supplied light-array order for owner-path IDs.
- Mixed refs:
  - any direct light ref triggers direct branch and ignores device refs.
- Empty refs:
  - returns empty lights/ids.
- Non-matching refs:
  - returns empty outputs.
- Parity checks:
  - targeted orchestrator tests proving no change in fallback behavior on fetch failure.

## Required Signed-Simulator Validation

For IOS-REF-006B implementation (not this docs slice):

- Run focused resolver tests (new).
- Run existing pure seam suites:
  - `CompositionRoomPriorityScorerTests`
  - `RoomAndZoneDisplayModelBuilderTests`
  - `DashboardDisplayModelBuilderTests`
- Run full signed-simulator `HueHomeTests` and compare to latest baseline target (`93/93` as provided).

## Required Physical-Device Composer Smoke Scope

For IOS-REF-006B implementation (not this docs slice):

1. Start Composer on a room with device-owner refs and verify light targeting parity.
2. Start Composer on a zone/direct-light refs and verify per-light behavior parity.
3. Verify mixed reference edge room (if available) preserves current direct-light precedence.
4. Verify no routing changes in entertainment vs REST startup behavior.
5. Verify stop/start across room switches does not regress resolved light targeting.

No physical-device run required for IOS-REF-006A documentation-only slice.

## Deferred High-Risk Areas

- Any extraction that moves `api.fetchLights()` out of orchestrator ownership.
- Any extraction that moves `api.credentials()` or `/resource/entertainment` fetch/parsing.
- Any change to transport routing, scheduler cadence, generation guards, mailbox behavior, or runtime mutation.
- Any attempt to redefine gamut tie behavior during IOS-REF-006B.
- Whole-method extraction of entertainment position mapping.

## Open Questions

- Should gamut tie behavior be formalized (explicit deterministic tie-break) in a future dedicated slice before any gamut helper extraction?
- Is there any production topology where mixed refs are expected and intentional (direct+device), or is that defensive compatibility behavior only?
- Should a later slice add explicit fixtures for entertainment duplicate-key overwrite behavior to lock current semantics?
