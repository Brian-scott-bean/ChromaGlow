# Orchestrator SSE Recovery Inventory

## Purpose

Document the narrowest safe future implementation slice (**IOS-TEST-003B4B**) for recovering exactly three orphaned SSE reducer tests from `HueHomeTests/OrchestratorTests.swift` into a new bounded test file — without registering the orphan suite, without `StubURLProtocol`, without live `URLSession` SSE streams, without `startSSE()` / `runSSE(...)`, and without production SSE behavior changes.

**Slice:** IOS-TEST-003B4A (documentation only). **Out of scope:** Swift edits, Xcode project edits, test implementation, orphan-file edits, scheme changes, `HueSSEService` consolidation, IOS-TEST-003B4B implementation.

## Current Baseline

| Item | Value |
| --- | --- |
| Working branch | `ios-test/orchestrator-sse-inventory` |
| Starting SHA | `359a667` |
| `origin/main` at inventory time | `359a667` (0 ahead / 0 behind; `origin/main` is ancestor of HEAD) |
| Xcode project | `HueHome.xcodeproj` |
| Scheme | `HueHome 1` (`parallelizable = "YES"`) |
| Full signed-simulator `HueHomeTests` | **129/129** pass |
| Recovered bounded suites | `OrchestratorCacheDemoTests` → **4/4**; `OrchestratorLoadAllTests` → **4/4**; `OrchestratorOptimisticUpdateTests` → **3/3** |
| Orphan file | `HueHomeTests/OrchestratorTests.swift` (tracked, **not** in `project.pbxproj`) |
| Prior inventories | `docs/ios/orchestrator-tests-membership-repair-inventory.md`, `docs/ios/orchestrator-loadall-harness-repair-inventory.md`, `docs/ios/orchestrator-optimistic-update-recovery-inventory.md` |
| IOS-TEST-003B3B merged into `main` | Yes (per task brief; branch at `359a667`) |

## Three Deferred Orphan SSE Tests

| Test | Intended contract | Stale assumptions | Compile blocker | Runtime gap | Recovery recommendation |
| --- | --- | --- | --- | --- | --- |
| `testApplySSEEvent_groupedLight_updatesRoomState` | `grouped_light` SSE update for `gl-001` sets room OFF at brightness ~1 in dashboard-visible state | Comment claims `applySSEEvent` is private; uses `Fixture.installLoadAll()` + `await loadAll()` + `injectForTesting` + `TestableBridgeAPIClient` + `StubURLProtocol`; calls stale `testApplySSEEvent` shim; uses ad-hoc `JSONDecoder()` instead of `sseDecoder` | **Yes** (file-level) — `TestableBridgeAPIClient` illegal; shim `Bool` vs tuple; whole-file registration blocked | **High** — `applySSEEvent` mutates `roomsByBridge` only; orphan asserts `allRooms[0].isOn` without `rebuildAllRooms()` → would fail even if shim compiled | Recover as `testGroupedLightSSE_updatesVisibleRoomState` in `OrchestratorSSETests.swift` via **preloadCached** + **DEBUG `testApplySSEEventsAndRebuild`** (Strategy B) |
| `testApplySSEEvent_malformedJSON_doesNotCrash` | Malformed SSE payload does not decode and does not change room state | Does not call `applySSEEvent` or `runSSE`; local `JSONDecoder()` only; no orchestrator seed beyond empty `setUp` orchestrator | **Compile-ready in isolation** but file-bound | **Low** — does not exercise `data:` line parsing or `try?` swallow in `runSSE` | Recover as `testSSEDecoder_rejectsMalformedJSON_withoutMutatingState` using `UnifiedOrchestrator.sseDecoder` + **preloadCached** seed; document decoder-only boundary |
| `testApplySSEEvent_unknownType_doesNotMutateState` | Unknown resource type in SSE envelope is ignored | Unnecessary `loadAll()` + stubs + shim; could use preload only | **Yes** (file-level) — same as grouped-light file blockers | **Low** — direct `applySSEEvent` returns `(false, false)` and does not touch `roomsByBridge`; visible `allRooms` unchanged without rebuild | Recover as `testUnknownSSEType_doesNotMutateVisibleRoomState` via **preloadCached** + direct **`applySSEEvent`** (Strategy A sufficient — no rebuild) |

### Cross-cutting orphan issues (do not copy)

| Issue | Evidence | B4B stance |
| --- | --- | --- |
| Stale `testApplySSEEvent` shim | `OrchestratorTests.swift:363-368` returns `Bool` but `applySSEEvent` returns `(rooms: Bool, zones: Bool)` (`UnifiedOrchestrator.swift:1165`) | **Reject** — redundant; invalid return type |
| Comment “applySSEEvent is private” | `OrchestratorTests.swift:296-298` | **Stale** — method is `internal` |
| Unnecessary `loadAll()` for SSE fixtures | Grouped-light + unknown-type tests `:279-281`, `:316-318` | **Reject** — `preloadCached` + `cachedGroupedLightID` |
| Shared `StubURLProtocol` | Orphan `Fixture.installLoadAll` + `TestableBridgeAPIClient` | **Reject** |
| `allRooms` assertion after reducer only | Grouped-light test `:303` without rebuild | **Requires** production-equivalent conditional rebuild for SSE-01 |

## Current Orchestrator SSE Pipeline

Live path: `UnifiedOrchestrator.startSSE()` → per-bridge `Task` → `runSSE(bridgeID:client:)` (`UnifiedOrchestrator.swift:1034-1160`). **UnifiedOrchestrator owns SSE end-to-end**; `HueSSEService` is not called.

```
startSSE()
  └─ guard !isDemoMode
  └─ for each (bridgeID, client) in clients where sseTasks[bridgeID] == nil
       └─ sseTasks[bridgeID] = Task { await runSSE(bridgeID, client) }
  └─ observeAppLifecycle() once (background → stopSSE, foreground → startSSE)

runSSE(bridgeID, client)
  └─ guard let creds = try? client.credentials() else { return }
  └─ GET https://{ip}/eventstream/clip/v2
       hue-application-key: {token}
       Accept: text/event-stream
  └─ shared lazy sseSession.bytes(for: request)   // cert trust delegate retained
  └─ for try await line in bytes.lines
       └─ guard line.hasPrefix("data:") else { continue }
       └─ trim JSON after "data:"
       └─ try? Self.sseDecoder.decode([SSEEvent].self, from: data)   // malformed → silent skip
       └─ for event in events: applySSEEvent(event, bridgeID)
       └─ if roomsMutated → rebuildAllRooms()
       └─ if zonesMutated → rebuildAllZones()
       └─ flatMap event.data → lightEventContinuation?.yield(rawUpdates) when non-empty
  └─ on stream end or error: reconnect loop
       retryDelay: 5s → 10s → 20s → 40s → 60s (capped)
       sleep(retryDelay); retryDelay = min(retryDelay * 2, maxDelay)
```

| Retry step | Nanoseconds | Seconds |
| --- | ---: | ---: |
| Initial / reset on connect | `5_000_000_000` | 5 |
| ×2 | `10_000_000_000` | 10 |
| ×2 | `20_000_000_000` | 20 |
| ×2 | `40_000_000_000` | 40 |
| Capped | `60_000_000_000` | 60 |

`stopSSE()` cancels all `sseTasks` and clears the dictionary (`:1049-1051`). Tests must **not** invoke `startSSE()` / `runSSE(...)`.

## applySSEEvent Reducer Behavior

Source: `UnifiedOrchestrator.swift:1163-1240`. Visibility: **`internal`** (no `private` modifier). Return type: **`(rooms: Bool, zones: Bool)`**.

### `grouped_light`

| Step | Behavior |
| --- | --- |
| Room match | `roomsByBridge[bridgeID]` index where `groupedLightID == update.id` |
| Zone match | `zonesByBridge[bridgeID]` index where `groupedLightID == update.id` |
| Pending guard | Skip on/brightness if `pendingActionDeadlines[update.id]` active and `Date() < deadline` |
| Apply | `on?.on` → `isOn`; `dimming?.brightness` → `brightness` |
| Persist | Write back `roomsByBridge` / `zonesByBridge` |
| Flags | `roomsMutated` / `zonesMutated` per side touched |
| Public arrays | **Not** updated here |

### `light`

| Step | Behavior |
| --- | --- |
| OFF guard | `update.on?.on ?? true`; if OFF → `continue` (no dominant-color mutation) |
| Room routing | `lightIDToRoomID[update.id]` → room index |
| Zone routing | `lightIDToZoneID[update.id]` → zone index |
| Color | Prefer `color?.xy` (clears mirek); else `colorTemp?.mirek` (clears xy) |
| Flags | Set when room/zone dominant fields change |

### Unknown resource type

| Step | Behavior |
| --- | --- |
| `default` branch | `continue` — no mutation |
| Flags | Remain `false` unless another update in same event mutated state |

## Public Rebuild Gap

| Fact | Source |
| --- | --- |
| `applySSEEvent` mutates **`roomsByBridge` / `zonesByBridge` only** | `:1173-1233` |
| **`allRooms` / `allZones`** come from `DashboardDisplayModelBuilder` via **`rebuildAllRooms()` / `rebuildAllZones()`** | `:1260-1278` |
| Live `runSSE` calls conditional rebuilds after decode loop | `:1139-1142` |
| `preloadCached` sets both `allRooms` and `roomsByBridge` initially | `:505-535` |
| After grouped-light `applySSEEvent` alone, **`allRooms` stays at preload values** | Reducer does not call rebuild |

**Assessment:** Direct `applySSEEvent(...)` calls alone are **insufficient** for visible dashboard-state parity on grouped-light mutations. Unknown-type and malformed (no apply) tests can assert `allRooms` without rebuild. Grouped-light recovery **must** mirror the post-decode rebuild loop.

Navigation buffering: `rebuildAllRooms()` no-ops while `isNavigating` and sets `sseRebuildPendingRooms` (`:1261-1264`). Unit tests do not call `signalNavigationStarted()` — rebuild applies immediately in normal test conditions.

## Orphan Shim Assessment

```swift
// OrchestratorTests.swift:363-368 (invalid — do not copy)
func testApplySSEEvent(_ event: SSEEvent, bridgeID: String) -> Bool {
    applySSEEvent(event, bridgeID: bridgeID)
}
```

| Question | Answer |
| --- | --- |
| Is shim redundant? | **Yes** — `applySSEEvent` is already `internal`; `@testable import HueHome` can call it |
| Is shim return type valid? | **No** — production returns `(rooms: Bool, zones: Bool)`; shim declares `Bool` (**CB-2** in membership inventory) |
| Should B4B copy shim? | **No** |

## Malformed-Payload Coverage Assessment

| Layer | Live behavior | Orphan test | B4B recommendation |
| --- | --- | --- | --- |
| `runSSE` line loop | `try?` decode — malformed line skipped, stream continues | Not exercised | **Defer** live stream-line tests |
| `UnifiedOrchestrator.sseDecoder` | Same decoder as `runSSE` (`:3205`, `:1131`) | Orphan uses separate `JSONDecoder()` | Pin **`UnifiedOrchestrator.sseDecoder`** in SSE-02 |
| State mutation | No decode → no `applySSEEvent` → no rebuild | Asserts `allRooms.count` unchanged on empty orchestrator | Seed via **preloadCached**; assert visible room ON unchanged |

**Honest boundary:** SSE-02 validates **malformed JSON rejection at the shared decoder** without network. It does **not** prove `bytes.lines` / `data:` prefix trimming / `try?` swallow semantics in `runSSE`.

`HueSSEService` uses `do/catch` and logs parse warnings (`HueSSEService.swift:113-121`) — **different** from orchestrator `try?` silence. B4B does not test `HueSSEService`.

## HueSSEService Status

| Question | Answer | Evidence |
| --- | --- | --- |
| Live Swift call sites in `HueHome/`? | **None** (definition only) | `rg HueSSEService` → `HueSSEService.swift` only |
| Does `UnifiedOrchestrator` use `HueSSEService`? | **No** — inline `runSSE` | `UnifiedOrchestrator.swift:1097-1160` |
| Wired / unwired / legacy? | **Unwired legacy parallel implementation** | Comments reference Dashboard/RoomDetail; production dashboard SSE is orchestrator `runSSE` |
| Decoder difference | Orchestrator: `[SSEEvent]` + `try?`; Service: `[SSEEnvelope]` + filter `type == "update"` + logged `catch` | `HueSSEService.swift:114-117` vs `UnifiedOrchestrator.swift:1131` |
| Touch in B4B? | **No** | Architecture debt only; no consolidation in bounded slice |
| Room detail SSE | Subscribes to orchestrator `subscribeToLightEvents()` bus — not `HueSSEService` | `RoomDetailViewModel.swift:817-833`, `RoomDetailView.swift:227` |

## preloadCached Fixture Boundary

Source: `UnifiedOrchestrator.swift:505-537`, `HueDataModels.swift:75-80`.

**Proposed cached room (Strategy A seed):**

| Field | Value |
| --- | --- |
| `roomID` | `room-001` |
| `bridgeID` | `bridge-1` |
| `cachedName` | `Bedroom` |
| `cachedGroupedLightID` | `gl-001` |
| `lastIsOn` | `true` |
| `lastBrightness` | `80` |

| Seeds | Confirmed |
| --- | --- |
| `allRooms` | Yes — one `RoomDisplayItem` with `groupedLightID` |
| `roomsByBridge["bridge-1"]` | Yes — required for `applySSEEvent` grouped_light lookup |
| `bridgeID` routing | Yes — `item.bridgeID` on display item |
| `groupedLightID` routing | Yes — **only if** `cachedGroupedLightID` set (orphan `makeLocalRoom` omits this) |

| Avoided | Confirmed |
| --- | --- |
| `loadAll()` | Yes |
| `BridgeAPIClient` / network | Yes — no `injectForTesting` required for bounded SSE tests |
| `StubURLProtocol` | Yes |
| Keychain | Yes |
| Entertainment cleanup | Yes |

**Strategy B (loadAll harness)** is broader than necessary for these three tests — **reject** for B4B.

**Strategy C (register orphan file)** — blocked by CB-1/CB-2/CB-4 and stale harness — **reject**.

## SSE Testability Strategy Comparison

| Rank | Strategy | Production edits | Visible-state parity | Offline determinism | Task cleanup | Risk | Recommendation |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | **B — DEBUG `testApplySSEEventsAndRebuild`** | **Yes — DEBUG-only** wrapper duplicating post-decode rebuild loop | **Full** for grouped-light | **High** — no SSE tasks | Low — per-test SUT release; optional 500 ms widget debounce benign | Low — mirrors `runSSE` `:1132-1142` | **Recommended for IOS-TEST-003B4B** |
| 2 | **A — Direct `applySSEEvent` only** | None | **Partial** — unknown-type OK; grouped-light **fails** `allRooms` | High | None | Low | Use for SSE-03 only; insufficient alone for full slice |
| 3 | **C — Extract `processDecodedSSEEvents` shared with `runSSE`** | **Yes — Release-visible refactor** | Full | High | Low | Medium — touches live `runSSE` body | Cleaner long-term; **too broad** for bounded orphan recovery |
| 4 | **D — DEBUG `testDecodeAndApplySSEData`** | DEBUG-only | Full if wraps decode+apply+rebuild | High | Low | Low–medium | Optional sugar; **unnecessary** if tests build `[SSEEvent]` directly |
| 5 | **E — URLProtocol / mock `sseSession` stream** | Test + possibly production hooks | Could be full | **Low** — reconnect/backoff/cancellation | **High** | **High** | **Reject** |
| 6 | **F — Copy orphan `testApplySSEEvent` shim** | None | Broken / invalid | — | — | Compile failure | **Reject** |

**Wrapper duplication acceptable?** **Yes** — ~15 lines in `#if DEBUG`, mirrors existing `injectForTesting` / `testResolveComposition*` pattern (`:349-361`).

## Recommended IOS-TEST-003B4B Slice

**Task:** `IOS-TEST-003B4B — Recover bounded Orchestrator SSE offline tests`

| Decision | Value |
| --- | --- |
| Production Swift changes needed? | **Yes — one DEBUG-only method** |
| DEBUG-only? | **Yes** (`#if DEBUG` block adjacent to existing test injection) |
| Release behavior unchanged? | **Yes** — wrapper not compiled in Release |
| `preloadCached` sufficient? | **Yes** (with `cachedGroupedLightID`) |
| `loadAll` avoidable? | **Yes** |
| URLProtocol avoidable? | **Yes** |
| Keychain avoidable? | **Yes** |
| Real networking avoidable? | **Yes** |
| Orphan shim copied? | **No** |
| Widget debounce cleanup required? | **No** — `scheduleWidgetWrite` uses `[weak self]`; per-test orchestrator deallocation sufficient; tests do not assert widget payloads |
| Generic Debug build required? | **Yes** (after B4B — DEBUG wrapper + tests) |
| Generic Release build required? | **Yes** (confirm no DEBUG symbol leakage) |
| Physical-device testing required? | **No** |

### Conceptual DEBUG wrapper (do not implement in B4A)

```swift
#if DEBUG
@discardableResult
func testApplySSEEventsAndRebuild(
    _ events: [SSEEvent],
    bridgeID: String
) -> (rooms: Bool, zones: Bool) {
    var roomsMutated = false
    var zonesMutated = false
    for event in events {
        let result = applySSEEvent(event, bridgeID: bridgeID)
        if result.rooms { roomsMutated = true }
        if result.zones { zonesMutated = true }
    }
    if roomsMutated { rebuildAllRooms() }
    if zonesMutated { rebuildAllZones() }
    return (rooms: roomsMutated, zones: zonesMutated)
}
#endif
```

## Proposed Test Boundary

New file: `HueHomeTests/OrchestratorSSETests.swift` — **3 tests**, per-test `@MainActor` SUT factory (match `OrchestratorLoadAllTests` / `OrchestratorOptimisticUpdateTests`). **No** `setUp()`/`tearDown()`. **No** `startSSE()` / `runSSE` / `injectForTesting` unless a future test adds clients (not needed here).

## Proposed Cached-Room Fixture

```swift
func makeOrchestratorSSECachedRoom(isOn: Bool = true) -> HueLocalRoom {
    let room = HueLocalRoom(roomID: "room-001", bridgeID: "bridge-1")
    room.cachedName = "Bedroom"
    room.cachedGroupedLightID = "gl-001"
    room.lastIsOn = isOn
    room.lastBrightness = 80
    return room
}
```

SUT factory: `UnifiedOrchestrator()` → `preloadCached(from: [makeOrchestratorSSECachedRoom()])` → return orchestrator.

## Three-Test Recovery Matrix

| Test | Fixture | Decoder boundary | Apply boundary | Expected flags | Expected visible state | Cleanup notes |
| --- | --- | --- | --- | --- | --- | --- |
| **SSE-01** `testGroupedLightSSE_updatesVisibleRoomState` | `preloadCached` ON @ 80 | `JSONDecoder` or `sseDecoder` → `[SSEEvent]` from orphan JSON fixture | **`testApplySSEEventsAndRebuild`** | `rooms == true`, `zones == false` | `allRooms.count == 1`, `isOn == false`, `brightness == 1 ± 0.1` | Local `orchestrator` release; no SSE task; widget debounce OK to outlive |
| **SSE-02** `testSSEDecoder_rejectsMalformedJSON_withoutMutatingState` | `preloadCached` ON | **`UnifiedOrchestrator.sseDecoder`** + `Data("{not valid json".utf8)` | **None** (decode fails before apply) | N/A | Room remains ON @ 80 | No production wrapper needed |
| **SSE-03** `testUnknownSSEType_doesNotMutateVisibleRoomState` | `preloadCached` ON @ 80 | `sseDecoder` → `[SSEEvent]` with `type: "unknown_resource"` | **Direct `applySSEEvent`** (no rebuild needed) | `rooms == false`, `zones == false` | Unchanged ON @ 80 | Same as SSE-01 |

### SSE-01 fixture JSON (from orphan, validated shape)

```json
[{"creationtime":"2024-01-01T00:00:00Z","data":[{
  "id":"gl-001","id_v1":null,"type":"grouped_light",
  "on":{"on":false},"dimming":{"brightness":1},"owner":null
}],"id":"evt-1","type":"update"}]
```

## Expected IOS-TEST-003B4B Changed Files

```text
DEVLOG.md
HueHome.xcodeproj/project.pbxproj
HueHome/Core/Network/UnifiedOrchestrator.swift   # DEBUG-only testApplySSEEventsAndRebuild
HueHomeTests/OrchestratorSSETests.swift         # new — 3 tests
```

**Not changed:** `HueHomeTests/OrchestratorTests.swift`, `HueSSEService.swift`, scheme, `BridgeAPIClient`, networking/SSE runtime paths.

## Required Focused Validation

```text
xcodebuild test -only-testing:HueHomeTests/OrchestratorSSETests
```

Expected: **OrchestratorSSETests → 3/3 pass**

## Required Full Signed-Simulator Validation

Expected after B4B (not claimed during B4A):

```text
HueHomeTests → 132/132 pass  (129 existing + 3 new)
```

## Generic Build Requirement

After B4B implementation:

| Build | Required |
| --- | --- |
| Generic unsigned Debug | **Yes** — DEBUG wrapper + tests compile |
| Generic unsigned Release | **Yes** — confirm Release excludes DEBUG wrapper |

Not required for B4A (docs-only).

## Physical-Device Requirement Assessment

| Slice | Physical device |
| --- | --- |
| IOS-TEST-003B4A (this inventory) | **Not required** |
| IOS-TEST-003B4B | **Not required** — offline reducer + decoder only |

## Warning-Hygiene Note

| File | Status |
| --- | --- |
| `OrchestratorCacheDemoTests.swift` | Preexisting `setUp()`/`tearDown()` MainActor lifecycle warnings — **deferred** |
| `OrchestratorLoadAllTests.swift` | Per-test SUT factory — **no** lifecycle warnings |
| `OrchestratorOptimisticUpdateTests.swift` | Per-test SUT factory — **no** lifecycle warnings |
| `OrchestratorSSETests.swift` (future) | **Must** use per-test `@MainActor` SUT construction; **no** synchronous `setUp()`/`tearDown()` |

## Explicit Do-Not-Touch List

```text
HueHomeTests/OrchestratorTests.swift          # no registration
HueHome/Core/Network/HueSSEService.swift      # no edits
runSSE / startSSE / stopSSE behavior
sseDecoder / line parsing / backoff
pendingActionDeadlines semantics
navigation rebuild buffering
lightEventContinuation
StubURLProtocol / URLProtocol SSE mocking
scheme parallelization / signing / MARKETING_VERSION
orphan testApplySSEEvent shim
OrchestratorCacheDemoTests warning debt (this slice)
```

## Deferred SSE Coverage

Intentionally **out of scope** for IOS-TEST-003B4B:

```text
zone grouped_light SSE mutation
individual-light dominant xy / mirek mutation
individual-light OFF ignored behavior
pending optimistic-action suppression during SSE grouped_light
lightEventContinuation yields
navigation rebuild buffering (isNavigating)
live URLSession line streaming (data: prefix, empty lines, keepalives)
reconnect after disconnect
backoff progression (5→10→20→40→60)
certificate trust / sseSession delegate behavior
background stopSSE / foreground resume startSSE
HueSSEService architecture consolidation
SSEEnvelope vs SSEEvent decode path parity
malformed line handling inside runSSE try? (vs decoder-only test)
```

## Open Questions

| # | Question | B4A resolution |
| --- | --- | --- |
| 1 | Is DEBUG wrapper naming `testApplySSEEventsAndRebuild` acceptable vs extracting shared production helper? | Prefer DEBUG wrapper for smallest Release-neutral diff; revisit Strategy C only if more SSE tests land later |
| 2 | Should SSE-01 use `sseDecoder` for fixture decode? | **Yes** — pins same decoder instance as `runSSE` |
| 3 | Any need to cancel `widgetWriteTask` in tearDown? | **No** for current assertions — follow B3B precedent |
| 4 | Safe bounded slice exists? | **Yes** — Strategy B + preloadCached + new bounded file |
