# UnifiedOrchestrator Pure-Seam Inventory

## Purpose

This document inventories the current responsibilities, state surface, and side-effect boundaries of `UnifiedOrchestrator` and identifies bounded, substantially pure helper candidates suitable for future extraction. It is descriptive of the existing implementation and call graph; no Swift changes are part of IOS-REF-003A.

## Current Baseline

- **Repo**: ChromaGlow (`HueHome.xcodeproj`)
- **Target**: `HueHome`
- **Orchestrator file**: `HueHome/Core/Network/UnifiedOrchestrator.swift`
- **Approximate size**: 3,290 lines
- **Tests in-tree**:
  - `HueHomeTests/OrchestratorTests.swift` (state-management, optimistic updates, SSE decoding, demo mode)
  - `HueHomeTests/DashboardDisplayModelBuilderTests.swift` (pure room/zone list composition, IOS-REF-001R / IOS-REF-002)
- **Documented current behavior**: `docs/ios/large-file-map.md`, `docs/ios/current-behavior-map.md`, `docs/ios/hue-contract-inventory.md`, `docs/ios/persistence-and-credentials.md`, `docs/ios/regression-smoke-matrix.md`
- **Current automated baseline (from user brief)**:
  - `DashboardDisplayModelBuilderTests` → 14/14 passed
  - Full `HueHomeTests` suite → 68/68 passed

## Existing Extracted Seams

- **Dashboard display-model builder**:
  - File: `HueHome/Core/Dashboard/DashboardDisplayModelBuilder.swift`
  - Tests: `HueHomeTests/DashboardDisplayModelBuilderTests.swift`
  - Role: Pure, deterministic helpers for flattening and sorting rooms/zones across bridges, with de-duplication by ID and preservation of display-model fields.
  - Status: Already extracted and covered by unit tests (IOS-REF-001R / IOS-REF-002).

This inventory looks for similarly pure, bounded, display-model-style helpers that are still embedded inside `UnifiedOrchestrator`.

## Public State Surface

Key observable properties on `UnifiedOrchestrator` (subset, focused on externally-consumed state):

- **Rooms and zones**
  - `allRooms: [RoomDisplayItem]`
  - `allZones: [RoomDisplayItem]`
  - `rooms(for bridgeID: String) -> [RoomDisplayItem]`
- **Scenes**
  - `globalScenes: [GlobalSceneItem]`
  - `isLoadingScenes: Bool`
- **Bridge connection and loading**
  - `connectionStatus: [String: BridgeConnectionStatus]`
  - `isLoading: Bool`
  - `errorMessage: String?`
  - `lastLoadedAt: Date`
  - `groupByBridge: Bool`
- **User-facing feedback**
  - `toastMessage: String?`
- **Demo mode**
  - `isDemoMode: Bool`
- **All-day scenes**
  - `allDayScenesEnabled: Bool`
- **Studio / Composer related**
  - `activeEffectEntries: [ActiveEffectEntry]`
  - `activeEffectName: String?`
  - `activeEffectIcon: String?`
  - `activeEffectIsAppDriven: Bool`
  - `isBridgeStored: Bool`
  - `entertainmentConfigsByBridge: [String: EntertainmentConfig]`
- **Light-event subscription**
  - `subscribeToLightEvents() -> AsyncStream<[SSEResourceUpdate]>?`

## Private State Surface

Non-exhaustive but representative private state inside `UnifiedOrchestrator`:

- **Per-bridge clients and derived maps**
  - `clients: [String: BridgeAPIClient]`
  - `roomsByBridge: [String: [RoomDisplayItem]]`
  - `zonesByBridge: [String: [RoomDisplayItem]]`
  - `lightIDToRoomID: [String: String]`
  - `lightIDToZoneID: [String: String]`
- **SSE and navigation**
  - `sseTasks: [String: Task<Void, Never>]`
  - `pendingActionDeadlines: [String: Date]` (optimistic-update vs SSE guard)
  - `isNavigating: Bool`
  - `navigationResetTask: Task<Void, Never>?`
  - `sseRebuildPendingRooms: Bool`
  - `sseRebuildPendingZones: Bool`
  - `lightEventContinuation: AsyncStream<[SSEResourceUpdate]>.Continuation?`
- **Widget / extension snapshot timing**
  - `widgetWriteTask: Task<Void, Never>?`
  - `pendingStateRefreshTask: Task<Void, Never>?`
- **All-day scenes**
  - `allDayTask: Task<Void, Never>?`
  - `allDayGeneration: Int`
  - `allDayRestSender: RestSender`
- **Persistence and credentials**
  - `keychain = KeychainManager.shared`
- **Studio / entertainment / composition runtime**
  - `activeParamBox: StudioParamBox?` (nonisolated, unchecked Sendable)
  - `activeStudioTask: Task<Void, Never>?`
  - `studioGeneration: Int`
  - `studioEntClients: [String: HueEntertainmentClient]`
  - `compositionRuntimes`, `compositionGenerations`, `compositionOrder`
  - `compositionTelemetryByRoom`, `activeRESTCadenceByRoom`, `activeRESTCadence`
  - `cadenceLastUIUpdateByRoom`
- **Bridge-stored animation**
  - `bridgeAnimationEngine: BridgeAnimationEngine`
  - `bridgeAnimationStore: BridgeAnimationStore`

## Responsibility Map

High-level responsibilities grouped by behavior area, with coarse classification and risk notes.

| Responsibility | Methods / properties | Callers | Side effects | Classification | Risk notes |
| --- | --- | --- | --- | --- | --- |
| Bridge registry & configuration | `configure(bridges:modelContext:)`, `addBridge(_:)`, `removeBridge(id:)`, `clients`, `roomsByBridge`, `zonesByBridge` | App startup, bridge manager, SwiftData bootstrap | Creates `BridgeAPIClient` instances, touches SwiftData, updates `connectionStatus`, cancels SSE, updates widget bridge credentials | **BRIDGE_ROUTING**, **PERSISTENCE**, **NETWORK_IO**, **EXTENSION_SNAPSHOT** | High risk: multi-bridge routing, widget credentials, and SSE lifecycle are all coupled here. |
| Widget bridge credential snapshot | `publishWidgetBridgeCredentials()`, use of `WidgetDataStore.shared.write(bridges:)` | `configure`, `addBridge`, `removeBridge` | App Group write for widgets/watch/intents | **EXTENSION_SNAPSHOT**, **PERSISTENCE** | High risk: changing shape or cadence can silently break widgets and watch. |
| Cache preload & writeback | `preloadCached(from:)`, `writeCache(to:)` | App launch, tests (`OrchestratorTests`) | Reads/writes SwiftData (`HueLocalRoom`), mutates `allRooms`, `roomsByBridge`, logging | **PERSISTENCE**, **STATE_MUTATION_ONLY** | Medium/high: needs SwiftData + bridge parity; already used by tests. |
| All-day scenes configuration | `allDayScenesEnabled`, `loadAllDayAnchor()`, `saveAllDayAnchor`, `startAllDayScenesIfNeeded`, `startAllDayScenes(anchor:)`, `stopAllDayScenes`, `tickAllDayScenes` | Future scheduler, automation layer | Uses `UserDefaults`, drives `RestSender`-backed REST loops, `Task` lifecycle | **PERSISTENCE**, **TASK_OR_TIMING**, **NETWORK_IO**, **MIXED_HIGH_RISK** | Involves timing, REST mailbox, and persisted config; not a good pure candidate. |
| Baseline state load | `loadAll(cacheContext:)`, `fetchAndMergeAllBridges()` | App launch, manual refresh, tests | Spawns `TaskGroup` per bridge, calls `BridgeAPIClient.fetch*`, builds `RoomDisplayItem`/`RoomDisplayItem` zones, mutates `roomsByBridge`, `zonesByBridge`, `lightIDToRoomID`, `lightIDToZoneID`, `connectionStatus`, `allRooms`, `allZones`, writes SwiftData cache | **NETWORK_IO**, **STATE_MUTATION_ONLY**, **PERSISTENCE**, **MIXED_HIGH_RISK** | Critical behavior: any extraction must not change hue-resource mapping or grouping semantics. Interior display-model composition is relatively pure and is the main candidate here. |
| Room on/off and brightness | `toggleRoom`, `setRoom(_:isOn:)`, `setBrightness(_:for:)`, `updateRoom(_:isOn:brightness:)`, `turnAllOff()` | Dashboard, RoomDetail, App Intents / widget actions | Optimistic updates to `allRooms`/`allZones`, guarded by `pendingActionDeadlines`, async calls to `BridgeAPIClient.setGroupedLight*`, error rollback, toast messages | **STATE_MUTATION_ONLY**, **NETWORK_IO**, **OPTIMISTIC_UPDATE**, **ROLLBACK_OR_ERROR**, **TASK_OR_TIMING** | High risk: intertwined with optimistic UI and SSE suppression window. |
| Room/zone CRUD | `renameRoom`, `deleteRoom`, `renameZone`, `deleteZone` | Room detail, settings / manage bridges | REST calls to Hue v2 scene/room/zone endpoints via `HueAPIClient`, optimistic local updates and rollback on error, demo-mode overrides | **NETWORK_IO**, **OPTIMISTIC_UPDATE**, **ROLLBACK_OR_ERROR**, **MIXED_HIGH_RISK** | Risky: API contracts, rollback, and UI copy all entangled. |
| Automations application | `applyAutomationPreset(id:)`, `applyAutomationEffect(id:)` | `AutomationHandler`, app notification handling | REST calls to grouped_light and per-light endpoints, uses `HueAPIClient`, interacts with automations registry, may touch UserDefaults buffers per DEVLOG | **NETWORK_IO**, **OPTIMISTIC_UPDATE**, **ROLLBACK_OR_ERROR**, **TASK_OR_TIMING** | High risk: time-based behavior plus background execution expectations. |
| SSE lifecycle | `subscribeToLightEvents()`, `startSSE()`, `stopSSE()`, `observeAppLifecycle()`, `runSSE(bridgeID:client:)`, `applySSEEvent(_:bridgeID:)`, `sseTasks`, `lightEventContinuation` | App lifecycle, `HueHomeApp`, RoomDetail view model, tests via `testApplySSEEvent` | Maintains long-lived SSE `URLSession`, decodes `SSEEvent`, updates rooms/zones via `updateRoom`, interacts with `pendingActionDeadlines` | **SSE_LIFECYCLE**, **NETWORK_IO**, **TASK_OR_TIMING**, **STATE_MUTATION_ONLY**, **MIXED_HIGH_RISK** | SSE coordination is explicitly out-of-scope for next pure seam. |
| Demo mode | `enterDemoMode()`, `exitDemoMode()`, `loadDemoData()`, demo branches inside room/zone methods and `loadAll` | Settings, onboarding, tests (`testDemoMode_loadAll_doesNotMakeNetworkRequests`) | In-memory mock data population, bypasses `clients`, short-circuits network calls | **DEMO_MODE**, **STATE_MUTATION_ONLY** | Semantically important to avoid accidental bridge I/O; behavior covered in tests. |
| Widget / extension state refresh | `scheduleWidgetWrite()`, `widgetWriteTask`, delayed `WidgetDataStore.shared` writes triggered from state changes | Dashboard, SSE / room mutations | Delayed App Group writes, deduplicated by a debounce-style task | **EXTENSION_SNAPSHOT**, **TASK_OR_TIMING**, **PERSISTENCE** | Coupled to widgets/watch; not a pure candidate. |
| State refresh scheduling | `scheduleStateRefresh()`, `pendingStateRefreshTask` | Room/zone mutations, Studio / composition | Delayed `loadAll`-style refresh to re-sync with bridge-confirmed state | **TASK_OR_TIMING**, **NETWORK_IO** | Tied to optimistic update correctness. |
| Studio legacy engine delegation | `StudioParamBox`, `activeParamBox`, `updateStudioParams`, `startStudioMode(...)`, `stopStudioMode()` | `StudioViewModel`, Studio cards | Manages mic sync via `NotificationCenter`, starts/stops DTLS entertainment sessions (`HueEntertainmentClient`), enqueues REST loops, uses generation counter | **ENTERTAINMENT OR SYNC TOUCHPOINT**, **TASK_OR_TIMING**, **NETWORK_IO**, **MIXED_HIGH_RISK** | Already well-factored and constrained by hue-bridge rules; not the next pure seam. |
| Composition engine orchestration | `anyCompositionNeedsMic`, `refreshCompositionMicDemand`, `startCompositionMode(...)`, `runCompositionEntertainment(...)`, `ensureCompositionSchedulerRunning`, `runCompositionScheduler`, `minimumComposer*` cadence helpers, `recordCompositionTelemetry`, `nextCompositionRoomPriority`, `resolveCompositionGamut`, `resolveCompositionLightIDs`, `resolveEntertainmentLightPositions`, `stopCompositionMode` | `StudioViewModel` via composition strategy | Coordinates DTLS vs REST transport, `CompositionEngine` math, mic capture demand, scheduler loop, and telemetry metrics; calls `HueAPIClient` for lights and entertainment configs | **ENTERTAINMENT OR SYNC TOUCHPOINT**, **TASK_OR_TIMING**, **NETWORK_IO**, **STATE_MUTATION_ONLY**, **MIXED_HIGH_RISK** (with some pure sub-helpers) | Contains several small pure math helpers (cadence functions) but is otherwise transport- and timing-heavy. |
| Scene operations | `loadAllScenes()`, `activateGlobalScene`, `setSceneSpeed`, `deleteGlobalScene`, `renameGlobalScene`, `createSceneFromRoom`, `updateScene` | Scenes tab, RoomDetail, automations | Calls `HueAPIClient` for scene list, activation, creation, and updates; mutates scene display models; logs errors | **NETWORK_IO**, **STATE_MUTATION_ONLY**, **MIXED_HIGH_RISK** | Tightly coupled to Hue scene payload contracts. |
| Bridge-stored animation (v1 API) | `bridgeAnimationEngine`, `bridgeAnimationStore`, `isBridgeStored`, integration inside composition paths | Composer / Studio | v1 REST interactions through dedicated engine, on-device persistence | **NETWORK_IO**, **PERSISTENCE**, **MIXED_HIGH_RISK** | Requires v1/v2 behavior inventory before any refactor. |

## Side-Effect Boundaries

### Networking

- **REST v2 via `BridgeAPIClient` / `HueAPIClient`**:
  - `fetchAndMergeAllBridges` issues parallel `fetchRooms`, `fetchZones`, `fetchLights`, `fetchGroupedLights`.
  - Room/zone CRUD, scene operations, automation application, and many Studio/composer paths all call into `HueAPIClient`/`BridgeAPIClient`.
- **REST v1 via `BridgeAnimationEngine`**:
  - Bridge-stored compositions and animations use a v1 chain under the hood.
- **DTLS/UDP via `HueEntertainmentClient`**:
  - Used in Studio and Composer paths for high-frequency effects and compositions.

### SSE lifecycle

- SSE connection and decoding is centralized:
  - `startSSE`, `stopSSE`, `runSSE`, `applySSEEvent`, plus the `AsyncStream` for light events.
  - One SSE task per bridge, plus main-thread application of updates into `allRooms`/`allZones`.
  - SSE interacts closely with optimistic update guards (`pendingActionDeadlines`) and navigation state (`isNavigating`).

### Persistence and credentials

- **SwiftData**:
  - `preloadCached` and `writeCache` read/write `HueLocalRoom`.
  - `configure` receives `BridgeRecord` list from SwiftData and turns them into `BridgeAPIClient` instances.
- **Keychain**:
  - `keychain = KeychainManager.shared` underpins bridge credential lookup in `configure` and related flows.
- **App Group / Widget / Watch**:
  - `publishWidgetBridgeCredentials` and `scheduleWidgetWrite` coordinate writes to `WidgetDataStore.shared`.

### UserDefaults

- All-day scenes configuration:
  - `allDayScenesEnabled`, `loadAllDayAnchor`, `saveAllDayAnchor` read/write keys under `AllDayKeys` using `UserDefaults.standard`.

### App Group, widget, and watch writes

- `WidgetDataStore.shared.write(bridges:)` and other widget-related calls form the boundary for extension-side bridge credentials and dashboard data.
- `scheduleWidgetWrite` debounces these writes to avoid thrashing on rapid SSE or optimistic updates.

### Task and timing behavior

- Multiple long-lived or repeating tasks:
  - `allDayTask` for all-day scenes.
  - `sseTasks` per bridge for event streaming.
  - `widgetWriteTask` and `pendingStateRefreshTask` for debounced writes and refreshes.
  - Studio and composition tasks (`activeStudioTask`, composition scheduler, entertainment loops).
- Timing-sensitive logic:
  - Pending-action deadlines for optimistic updates.
  - Composition cadence helpers and room-priority selection.

### Optimistic updates and rollback

- `setRoom`, `setBrightness`, `turnAllOff`, room/zone CRUD, and some automation paths all:
  - Mutate `allRooms`/`allZones` synchronously before REST completion.
  - Guard against SSE overwrites for a short window.
  - Roll back on REST failure and may emit user-visible toasts.

### Demo mode

- `enterDemoMode`, `exitDemoMode`, and `loadDemoData` plus inline `isDemoMode` checks:
  - Ensure demo flows populate `allRooms` without touching bridges, SwiftData, or Keychain.

### UI-facing observable state

- Public properties are consumed by:
  - `DashboardView` (rooms, zones, connection status, toasts).
  - `RoomDetailViewModel` (room mutations, light events).
  - `ScenesTabView` (global scenes).
  - `StudioView` / `StudioViewModel` (entertainment configs, active effects, composition state).
  - `AutomationsView`, `DevicesView`, and other shells that rely on orchestrator’s state as the single source of truth.

## Existing Safe Helpers

Inside `UnifiedOrchestrator`, several helpers already behave like pure or near-pure functions, even though they currently reside within the orchestrator:

- **Room and zone display-model composition** (lines ~606–751):
  - Builds `RoomDisplayItem` values and light-to-room/zone maps from `rooms`, `zones`, `lights`, and `groupedLights` fetched via `BridgeAPIClient`.
  - All transformation work is deterministic and in-memory: no additional bridge calls, no timing, no UserDefaults, no Keychain, no widget writes.
  - The only observable effects are via its return tuple, which the caller then applies to orchestrator state on the main actor.
- **Composition cadence helpers** (lines ~2269–2283):
  - `minimumComposerRESTInterval`, `minimumComposerBurstFloor`, `preferredComposerIdleInterval`, `lowPowerIdleInterval`.
  - Simple arithmetic based on `roomCount` and `CompositionTier`; purely functional and deterministic.
- **Composition room scheduling** (lines ~2314–2343):
  - `nextCompositionRoomPriority(now:)` computes the next room to serve based on a collection of in-memory runtime metrics (`overdue`, interaction flags, send counts).
  - No network I/O or external persistence; reads and writes only composition runtime state.

These helpers are candidates for future extraction into pure or state-focused helper types, provided their inputs and outputs are made explicit and tests are added.

## Candidate Pure Extraction Seams

| Rank | Candidate | Current location | Inputs | Outputs | Side effects | Suggested tests | Risk | Recommendation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Room and zone display-model composition | `UnifiedOrchestrator.fetchAndMergeAllBridges()` (lines ~606–751) | Per-bridge arrays: `rooms: [HueRoom]`, `zones: [HueZone]`, `lights: [HueLight]`, `groupedLights: [HueGroupedLight]`, plus `bridgeID: String` | `(rooms: [RoomDisplayItem], zones: [RoomDisplayItem], roomLightMap: [String: String], zoneLightMap: [String: String])` | **None** beyond returning values; no additional REST calls, no `Task` creation, no UserDefaults/Keychain/SwiftData/App Group interaction, no SSE, no optimistic updates or rollback | Unit tests mirroring `DashboardDisplayModelBuilderTests`: (1) verifies room/zone `isOn`/`brightness` are derived correctly from grouped lights; (2) verifies dominant color/mirek selection; (3) verifies child resource refs and `kind` for zones; (4) verifies light-to-room/zone maps for mixed room/zone topologies; (5) ensures demo-mode and existing orchestrator tests continue to pass unchanged | **Low/medium**: pure transformation logic with well-bounded inputs and no I/O; main risk is mis-copying existing mapping semantics (child refs, owner vs light resolution). | **Recommended next extraction (IOS-REF-003B)**: move this composition into a pure helper next to `DashboardDisplayModelBuilder`, with a thin delegation from `fetchAndMergeAllBridges`. |
| 2 | Composition cadence math helpers | `minimumComposerRESTInterval`, `minimumComposerBurstFloor`, `preferredComposerIdleInterval`, `lowPowerIdleInterval` (lines ~2269–2283) | `roomCount: Int`, `tier: CompositionTier` | `Double` cadence/interval values | **None**: pure math functions; all work is local; no state mutation or I/O | Direct unit tests asserting outputs for representative `(roomCount, tier)` combinations; tests can pin current behavior or formalize expected tier-specific differences if refactored | **Low** from a runtime-behavior perspective (pure math), but refactor value is also small; these helpers are already isolated and trivial | **Secondary candidate**: viable for future extraction into a `CompositionCadence` helper if/when composition transport tuning needs a clearer boundary. Not recommended as IOS-REF-003B because payoff is smaller than the room/zone builder extraction. |
| 3 | Composition room-priority selection | `nextCompositionRoomPriority(now:)` (lines ~2314–2343) | `now: CFAbsoluteTime`, `compositionOrder: [String]`, `compositionRuntimes: [String: CompositionRuntime]` (in-memory state including send counts, interaction flags, target times) | `roomID: String?` (next room to serve) | **State-only**: reads/writes in-memory runtime maps, no network or persistence; no Tasks created in this function, but it directly influences which room’s runtime is mutated next | Unit tests constructing small `compositionOrder` / `compositionRuntimes` fixtures and verifying: (1) interacting rooms are preferred; (2) overdue rooms climb in priority; (3) fairness nudges prevent starvation; (4) `nil` is returned when nothing is due | **Medium**: purely in-memory but tightly coupled to composition scheduler semantics; extraction risk is mainly around accidentally changing the scoring formula or its interaction with the scheduler loop | **Tertiary candidate**: possible future extraction into a `CompositionRoomScheduler` helper, but not ideal as the next pure seam due to behavioral subtlety and limited payoff for Android parity. |

If additional pure seams are desired later, they should be discovered by first adding fixtures/tests around these candidates and then exploring smaller math-only helpers inside the composition and entertainment areas.

## Recommended Next Extraction

This inventory recommends **exactly one** next extraction task.

- **Proposed task ID**: `IOS-REF-003B`
- **Candidate**: Room and zone display-model composition helper
- **Rationale**:
  - The logic that builds `RoomDisplayItem`/`RoomDisplayItem` (zones) and `lightIDToRoomID`/`lightIDToZoneID` in `fetchAndMergeAllBridges()` is:
    - Deterministic.
    - Purely in-memory.
    - Already naturally grouped and commented as a display-model builder.
  - It mirrors the role of `DashboardDisplayModelBuilder` but operates on Hue v2 resource arrays instead of pre-built `RoomDisplayItem` collections.
  - It is a clear, testable, and Android-relevant boundary: Android will need the same mapping semantics from rooms/zones/lights/grouped_lights into display items.

## Proposed Helper Type and File Path

- **Helper type name** (proposed): `RoomAndZoneDisplayModelBuilder`
  - Static, namespace-style enum or struct, similar to `DashboardDisplayModelBuilder`.
- **Proposed file path**:
  - `HueHome/Core/Dashboard/RoomAndZoneDisplayModelBuilder.swift`
  - Co-located with `DashboardDisplayModelBuilder` for cohesion; both would represent pure builders of dashboard-facing display models.

## Exact Orchestrator Delegation Point

The recommended delegation point is the builder section inside `fetchAndMergeAllBridges()`:

- **Current behavior** (described, not altered here):
  - After `async let`-based fetches, `fetchAndMergeAllBridges()` computes:
    - `glByID` from `groupedLights`.
    - `roomItems` and `roomLightMap` by iterating `rooms` and computing:
      - `isOn` / `brightness` from grouped lights.
      - `roomLights` membership via `children` refs and `light.owner.rid`.
      - Dominant color or mirek from the brightest ON light.
    - `zoneItems` and `zoneLightMap` by iterating `zones` and computing:
      - `isOn` / `brightness` from grouped lights.
      - `zoneLights` via direct `children` refs.
      - Dominant color or mirek in the same way.
  - It then logs counts per bridge and returns the per-bridge result tuple into the outer `TaskGroup` loop, where `roomsByBridge`, `zonesByBridge`, `lightIDToRoomID`, and `lightIDToZoneID` are updated.

- **Delegation sketch** (for IOS-REF-003B, not implemented here):
  - Replace the interior room/zone loops with a call such as:
    - `let (roomItems, roomLightMap, zoneItems, zoneLightMap) = RoomAndZoneDisplayModelBuilder.makeDisplayModels(rooms: rooms, zones: zones, lights: lights, groupedLights: groupedLights, bridgeID: bridgeID)`
  - Keep the outer `TaskGroup` structure, per-bridge error handling, and `roomsByBridge` / `zonesByBridge` / `lightIDToRoomID` / `lightIDToZoneID` mutation exactly as-is.

## Required Unit-Test Plan

For IOS-REF-003B, the following tests are expected:

- **New pure-helper tests** (likely `HueHomeTests/RoomAndZoneDisplayModelBuilderTests.swift`):
  - **Topology mapping**:
    - Given a room with one grouped_light and one light whose `owner.rid` matches the room’s device child, verify:
      - `isOn` and `brightness` match the grouped_light state.
      - `lightCount` equals the number of associated lights.
      - `childResourceRefs` include both light and device refs where applicable.
  - **Zone mapping**:
    - For a zone whose `children` are direct `rtype: "light"` entries:
      - Verify light membership, `isOn`/`brightness`, and dominant color/mirek behavior match current orchestration.
      - Verify `kind == .zone` and `bridgeID` are set correctly.
  - **Dominant color / mirek selection**:
    - When at least one ON light has color data, ensure dominant color (xy) is chosen from the brightest such light.
    - When no ON light has color data but some have mirek, ensure dominant mirek comes from the brightest such light.
    - When `isOn == false`, ensure dominant fields are `nil`, matching current behavior.
  - **Light-to-room/zone maps**:
    - Verify that each `light.id` included in `roomLights` or `zoneLights` appears in the respective `roomLightMap` / `zoneLightMap` with the correct `room.id` / `zone.id`.
  - **Error cases and edge conditions**:
    - Empty input arrays should produce empty outputs and empty maps.
    - Mixed room/zone configurations with overlapping lights should produce consistent maps.

- **Existing orchestrator tests to re-run (no expected behavior change)**:
  - `OrchestratorTests`:
    - `testLoadAll_success_populatesRooms`
    - `testLoadAll_lights_off`
    - `testLoadAll_bridgeError_leavesRoomsEmpty`
    - `testLoadAll_setsLastLoadedAt`
  - These tests should remain unchanged and continue to pass, validating that the refactor preserves loadAll behavior.

## Required Signed Simulator-Test Plan for IOS-REF-003B

Although IOS-REF-003B is a refactor, it touches room/zone display-model composition that is user-visible on the dashboard and room detail surfaces. A signed simulator run is recommended:

- **Build and run**:
  - Run `HueHomeTests` target:
    - Confirm `DashboardDisplayModelBuilderTests` → 14/14 pass.
    - Confirm `HueHomeTests` → 68/68 pass (or updated count if new tests are added).
- **Smoke subset (simulator)**:
  - `IOS-SMOKE-030` Dashboard render.
  - `IOS-SMOKE-031` Room toggle on/off.
  - `IOS-SMOKE-032` Brightness change all the way from dashboard.
  - `IOS-SMOKE-034` Room detail open.
  - `IOS-SMOKE-036` Optimistic rollback (if practical with stubs).

No physical-device run is strictly required for the inventory itself (IOS-REF-003A), but the above simulator tests should be re-run as part of the IOS-REF-003B refactor.

## Physical-Device Smoke Scope for IOS-REF-003B

For the eventual production refactor implementing IOS-REF-003B, the following real-bridge checks are recommended:

- **Bridge + dashboard**:
  - Launch with an existing paired Hue bridge and verify:
    - Dashboard rooms and zones render as before (names, archetypes, on/off badges, brightness strips, dominant colors).
    - No missing or duplicated rooms/zones.
  - Toggle a representative room on/off and adjust brightness:
    - Physical lights and app UI stay in sync.
    - No obvious regression in SSE or refresh behavior.
- **Zone behavior**:
  - Verify a multi-room zone behaves as before:
    - On/off and brightness control affect the same physical lights as baseline.
    - Dominant color/mirek visualization remains consistent.
- **Multi-bridge (if available)**:
  - When multiple bridges are configured:
    - Rooms and zones from each bridge appear correctly.
    - No cross-bridge leakage or missing items.

All of these checks should be treated as comparing against the existing production/TestFlight behavior; IOS-REF-003B must not change semantics.

## Deferred High-Risk Areas

The following areas were explicitly evaluated and are **not** recommended for the next extraction:

- **SSE connection coordination and event application**:
  - `startSSE`, `stopSSE`, `runSSE`, `applySSEEvent`, and the `AsyncStream` light events pipeline.
  - Rationale: tightly coupled to bridge behavior, optimistic-update windows, and navigation state.
- **Pending-action deadline and optimistic mutation logic**:
  - `pendingActionDeadlines`, room on/off/brightness methods, and related rollback paths.
  - Rationale: small timing changes can cause stale UI or flicker; needs dedicated behavior fixtures first.
- **All-day scenes scheduler**:
  - All-day REST loops and `UserDefaults`-backed anchor configuration.
  - Rationale: touches REST cadence, scheduling, and persisted configuration.
- **Widget/watch scheduling and App Group snapshot writing**:
  - `publishWidgetBridgeCredentials`, `scheduleWidgetWrite`, `WidgetDataStore` usage.
  - Rationale: high risk for silent widget/watch regressions.
- **Bridge registry lifecycle and multi-bridge routing**:
  - `configure`, `addBridge`, `removeBridge`, and related client creation logic.
  - Rationale: critical for multi-bridge correctness and Android parity; requires more contract fixtures.
- **All-day scene Task lifecycle, Studio entertainment routing, and bridge-stored animation**:
  - `startAllDayScenes*`, `stopAllDayScenes`, Studio/Composer entertainment start/stop paths, `bridgeAnimationEngine`.
  - Rationale: entangled with DTLS constraints, v1/v2 contracts, and mic capture; not yet supported with dedicated tests.
- **Keychain, SwiftData, App Group, widget/watch, and App Intent behavior**:
  - Any helpers that touch `KeychainManager`, `ModelContext`, `WidgetDataStore`, or watch/widget payloads.
  - Rationale: governed by `docs/ios/persistence-and-credentials.md`; must not be altered without a dedicated migration and smoke-matrix plan.

## Proposed IOS-REF-003B Test Plan

For the eventual implementation of IOS-REF-003B, the following test plan is proposed:

- **Unit tests**:
  - Add `RoomAndZoneDisplayModelBuilderTests` mirroring the style and coverage of `DashboardDisplayModelBuilderTests`.
  - Extend `OrchestratorTests` only if necessary to pin additional invariants around `loadAll` results.
- **Signed simulator tests**:
  - Run the full `HueHomeTests` suite on a signed simulator build (68/68 + new tests).
  - Manually exercise dashboard room/zone rendering and basic actions.
- **Regression smoke matrix entries** (subset):
  - `IOS-SMOKE-030` Dashboard render.
  - `IOS-SMOKE-031` Room toggle on/off.
  - `IOS-SMOKE-032` Brightness change.
  - `IOS-SMOKE-034` Room detail open.
  - `IOS-SMOKE-036` Optimistic rollback (if feasible with controlled failure).

## Physical-Device Smoke Scope for IOS-REF-003B

On real hardware with at least one Hue bridge:

- Confirm that:
  - Existing paired-bridge launch path still lands on a correctly populated dashboard.
  - Room toggles, brightness changes, and basic scene activation behave identically to the pre-refactor baseline.
- Preferred:
  - Run a small subset of Studio and Composer flows to confirm that the new helper has not changed room/zone membership or dominant-color derivation in a way that would affect these surfaces.

No physical-device tests are required for IOS-REF-003A itself; these checks apply to the future behavior-changing refactor IOS-REF-003B.

## Open Questions

- Do we want a shared display-model builder abstraction between `DashboardDisplayModelBuilder` and the proposed `RoomAndZoneDisplayModelBuilder`, or is it better to keep them separate and focused?
- Should the composition cadence helpers eventually move into a transport-specific helper (e.g., `CompositionCadence`) to make DTLS vs REST tuning more explicit for Android parity?
- Are additional unit tests desired around `loadAll` results (e.g., for `allZones`) before IOS-REF-003B is implemented?
- How much of the Orchestrator’s room/zone mapping semantics should be shared directly with the Android implementation versus re-derived from a shared contract document?

