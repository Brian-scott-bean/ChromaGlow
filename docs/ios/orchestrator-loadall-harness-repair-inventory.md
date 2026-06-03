# Orchestrator loadAll Offline Harness Repair Inventory

## Purpose

Document the narrowest safe future implementation slice (**IOS-TEST-003B2**) for recovering exactly four orphaned `loadAll()` tests from `HueHomeTests/OrchestratorTests.swift` into a new bounded test file — without registering the full orphan suite, without production behavior changes beyond a single declaration edit, and without shared mutable URL stub races.

**Slice:** IOS-TEST-003B2A (documentation only). **Out of scope:** Swift edits, Xcode project edits, test implementation, access-level changes, orphan-file edits, scheme changes.

## Current Baseline

| Item | Value |
| --- | --- |
| Working branch | `ios-test/orchestrator-loadall-harness-inventory` |
| Starting SHA | `507e278` |
| `origin/main` at inventory time | `507e278` (0 ahead / 0 behind) |
| Xcode project | `HueHome.xcodeproj` |
| Scheme | `HueHome 1` |
| Full signed-simulator `HueHomeTests` | **122/122** pass |
| Recovered cache/demo suite | `OrchestratorCacheDemoTests.swift` → **4/4** pass (in target) |
| Orphan file | `HueHomeTests/OrchestratorTests.swift` (tracked, **not** in `project.pbxproj`) |
| Prior inventory | `docs/ios/orchestrator-tests-membership-repair-inventory.md` (IOS-TEST-003A) |
| IOS-TEST-003B merged | `OrchestratorCacheDemoTests` registered; 122/122 baseline validated |

## Recovered Cache + Demo Coverage

`HueHomeTests/OrchestratorCacheDemoTests.swift` (IOS-TEST-003B) covers four offline tests with no client injection:

| Test | Coverage |
| --- | --- |
| `testPreloadCached_populatesAllRooms` | Cache seed → `allRooms` |
| `testPreloadCached_sortsAlphabetically` | Alphabetical sort |
| `testPreloadCached_emptyInput_leavesAllRoomsEmpty` | Empty cache guard |
| `testDemoMode_loadAll_doesNotMakeNetworkRequests` | Demo-mode early return |

These tests do **not** exercise `injectForTesting`, `fetchAndMergeAllBridges`, or entertainment cleanup. The four deferred `loadAll()` tests remain in the orphan file only.

## Four Deferred loadAll Tests

| Test | Current orphan location | Dependencies | Compile blocker | Runtime blocker | Recovery recommendation |
| --- | --- | --- | --- | --- | --- |
| `testLoadAll_success_populatesRooms` | `OrchestratorTests.swift:179-190` | `injectForTesting`, `TestableBridgeAPIClient`, `Fixture.installLoadAll`, `StubURLProtocol` | **Yes** — `TestableBridgeAPIClient: BridgeAPIClient` illegal while `BridgeAPIClient` is `final` | **Yes** — missing `/clip/v2/resource/zone` stub; tuple `try await` fails entire fetch | Recover in new `OrchestratorLoadAllTests.swift` via typed spy (Strategy A) |
| `testLoadAll_lights_off` | `OrchestratorTests.swift:192-198` | Same | **Yes** | **Yes** — zone gap | Same |
| `testLoadAll_bridgeError_leavesRoomsEmpty` | `OrchestratorTests.swift:200-206` | `injectForTesting`, `TestableBridgeAPIClient` (no stubs) | **Yes** | **Medium** — unstubbed entertainment GET adds nondeterministic log noise; assertion valid on fresh orchestrator | Same — spy throws on all four fetch methods |
| `testLoadAll_setsLastLoadedAt` | `OrchestratorTests.swift:208-214` | Same as success | **Yes** | **Yes** — zone gap prevents success path today; assertion is completion-based not success-only | Same — rename/clarify assertion semantics in B2 |

## Current loadAll Production Flow

Source: `UnifiedOrchestrator.swift:575-684`, `3014-3042`.

```
loadAll(cacheContext:)
│
├─ isDemoMode? → loadDemoData(); return (no lastLoadedAt update)
│
├─ clients.isEmpty? → log + return (keep cached allRooms; no lastLoadedAt update)
│
├─ isLoading? → log + return (concurrent suppression; no lastLoadedAt update)
│
├─ isLoading = true; defer { isLoading = false }
│
├─ await withTaskGroup (parallel outer):
│   ├─ Task: deactivateStuckEntertainmentSessions()
│   │   └─ for each client: credentials() → GET /entertainment_configuration
│   │       → optional PUT stop per active session; errors swallowed
│   └─ Task: fetchAndMergeAllBridges()
│       └─ for each (bridgeID, client) in clients (parallel per-bridge):
│           ├─ async let fetchRooms, fetchZones, fetchLights, fetchGroupedLights
│           ├─ try await tuple → RoomAndZoneDisplayModelBuilder.makeDisplayModels(...)
│           ├─ success: connectionStatus[bridgeID] = .connected
│           └─ catch: connectionStatus[bridgeID] = .error(...); return (bridgeID, nil, nil, …)
│               → stale-while-revalidate (prior roomsByBridge/zonesByBridge preserved)
│
├─ await Task.yield()
├─ rebuildAllRooms() → allRooms + scheduleWidgetWrite() (500 ms delayed)
├─ rebuildAllZones() → allZones + scheduleWidgetWrite()
├─ lastLoadedAt = Date()          ← always on completion path
└─ optional writeCache(to:)
```

### Per-step inventory

| Step | Behavior | Source |
| --- | --- | --- |
| Demo-mode early return | `loadDemoData()`; no network, no `lastLoadedAt` | `:577-579` |
| Empty-client early return | Skip fetch; preserve `allRooms` | `:581-586` |
| Concurrent-load suppression | `guard !isLoading` returns early | `:592-594` |
| `isLoading` lifecycle | Set `true`; cleared in `defer` | `:599-601` |
| Parallel outer task group | Entertainment cleanup ∥ bridge fetches | `:605-607` |
| Four concurrent per-bridge fetches | `fetchRooms`, `fetchZones`, `fetchLights`, `fetchGroupedLights` | `:632-638` |
| `RoomAndZoneDisplayModelBuilder` delegation | Builds `RoomDisplayItem` + light maps | `RoomAndZoneDisplayModelBuilder.swift:4-64` |
| Per-bridge success status | `.connected` | `:653` |
| Per-bridge error status | `.error(localizedDescription)` | `:665` |
| Stale-while-revalidate | Failed fetch returns `nil` rooms/zones; existing maps kept | `:668`, `:674-681` |
| `rebuildAllRooms()` / `rebuildAllZones()` | Merge `roomsByBridge`/`zonesByBridge` → `allRooms`/`allZones` | `:1260-1278` |
| Widget/watch scheduling | `scheduleWidgetWrite()` — 500 ms cancel-and-reschedule | `:1283-1312` |
| `lastLoadedAt` assignment | `Date()` after outer group + rebuilds | `:616` |

## lastLoadedAt Semantic Note

**Production assigns `lastLoadedAt` on the completion path, not on fetch success.**

After the outer task group finishes — including when one or more per-bridge resource fetches fail and stale state is preserved — `loadAll()` always executes:

```swift
rebuildAllRooms()
rebuildAllZones()
lastLoadedAt = Date()
```

(`UnifiedOrchestrator.swift:614-616`)

**Implications:**

| Path | `lastLoadedAt` updated? |
| --- | --- |
| Demo mode | **No** (early return) |
| Empty clients | **No** (early return) |
| Concurrent suppression | **No** (early return) |
| All fetches succeed | **Yes** |
| One or more fetches fail (stale preserved) | **Yes** |
| All fetches fail on fresh orchestrator | **Yes** |

**Orphan test `testLoadAll_setsLastLoadedAt` assessment:** The assertion `XCTAssertGreaterThanOrEqual(orchestrator.lastLoadedAt, before)` documents **completion-based** semantics, not success-only. The test name does not explicitly say "on success," but the comment and fixture setup imply a happy path. The assertion would **also pass** on `testLoadAll_bridgeError_leavesRoomsEmpty` if that test checked `lastLoadedAt`. IOS-TEST-003B2 should either clarify the test name (e.g. `testLoadAll_setsLastLoadedAt_onCompletion`) or add a separate error-path assertion documenting completion-based behavior.

## Current Test Injection Boundary

| Item | Current state | Source |
| --- | --- | --- |
| `injectForTesting(clients:)` | `#if DEBUG`; accepts `[String: BridgeAPIClient]` | `UnifiedOrchestrator.swift:349-354` |
| `clients` storage | `[String: BridgeAPIClient]` | `:265` |
| `UnifiedOrchestrator.swift` modification needed for B2? | **No** — existing DEBUG hook sufficient |
| `HueAPIClient.swift` modification needed for B2? | **No** — override points live on subclass |

## BridgeAPIClient Finality Assessment

```swift
final class BridgeAPIClient: HueAPIClient, @unchecked Sendable
```

(`BridgeAPIClient.swift:14`)

| Question | Answer |
| --- | --- |
| Must `final` change for typed spy subclass? | **Yes** — `TestableBridgeAPIClient: BridgeAPIClient` in orphan file is a compile error today |
| Is the production edit declaration-only? | **Yes** — remove `final` keyword only; no method-body changes |
| Are resource fetch methods overridable? | **Yes** — `fetchRooms`, `fetchZones`, `fetchLights`, `fetchGroupedLights` are non-`final` on `HueAPIClient` |
| Are `get`/`put` overridable? | **Yes** — `HueAPIClient.swift:625,630` |
| Is `credentials()` overridable? | **Yes** — `:73`; explicit-init path avoids Keychain |

## Shared URLProtocol Risk Assessment

| Risk | Evidence | Assessment |
| --- | --- | --- |
| Shared static stubs | `StubURLProtocol.stubs` in `HueAPIClientTests.swift:16` | **Not parallel-safe** across test classes |
| Scheme parallelization | `HueHome 1.xcscheme:35` `parallelizable = "YES"` | Concurrent stub-using suites would race |
| Orphan `Fixture.installLoadAll` | Missing zone stub; malformed first key (line 125) | Runtime blocker + redundant key |
| Orphan approach | `TestableBridgeAPIClient` overrides `get`/`put` via shared `StubURLProtocol` | **Avoid for B2** — use typed spy instead |
| Suite-local URLProtocol fallback | Possible but adds harness surface | **Fallback only** if typed spy blocked |

**Recommendation:** Avoid `StubURLProtocol` entirely in IOS-TEST-003B2. Typed spy overrides eliminate shared mutable stub state and parallel-test races with `HueAPIClientTests`.

## Typed Spy Feasibility

### Conceptual shape (not implemented in B2A)

```swift
final class OrchestratorLoadAllSpyBridgeClient: BridgeAPIClient, @unchecked Sendable {
    var stubRooms: [HueRoom] = []
    var stubZones: [HueZone] = []
    var stubLights: [HueLight] = []
    var stubGroupedLights: [HueGroupedLight] = []

    var fetchRoomsError: Error?
    // ... per-method error injectors ...

    private(set) var entertainmentCleanupGetCount = 0

    override func fetchRooms() async throws -> [HueRoom] { ... }
    override func fetchZones() async throws -> [HueZone] { ... }
    override func fetchLights() async throws -> [HueLight] { ... }
    override func fetchGroupedLights() async throws -> [HueGroupedLight] { ... }

    override func get(path: String, ip: String, token: String) async throws -> Data {
        if path == "/clip/v2/resource/entertainment_configuration" {
            entertainmentCleanupGetCount += 1
            return Data(#"{"errors":[],"data":[]}"#.utf8)
        }
        throw HueAPIError.httpError(404)
    }
}
```

### Feasibility checklist

| Question | Answer |
| --- | --- |
| Is removing `final` sufficient? | **Yes** for subclass legality; spy must also restate `@unchecked Sendable` (likely required, matches orphan pattern) |
| Can URLProtocol be avoided? | **Yes** — override typed `fetch*` methods bypasses `get()` for resource fetches |
| Can real Keychain be avoided? | **Yes** — `BridgeAPIClient(bridgeID:bridgeName:ip:token:)` uses explicit credentials |
| Can real network be avoided? | **Yes** — typed overrides + cleanup GET override |
| Must cleanup GET be handled explicitly? | **Yes** — `deactivateStuckEntertainmentSessions()` calls `client.get(path: "/clip/v2/resource/entertainment_configuration", ...)` directly |
| Can cleanup PUT be avoided? | **Yes** — return empty `data: []` from cleanup GET; no active sessions → no PUT |
| Are typed fixtures feasible? | **Yes** — resource structs are `Decodable` with synthesized memberwise inits accessible via `@testable import` |
| Are JSON fixtures preferable? | **Optional** — JSON decode mirrors `HueAPIClientTests` and matches orphan fixture shape; memberwise init is simpler for spy returns |
| Compile-safe without production method edits? | **Yes** |

**Why orphan URLProtocol approach is not compile-safe today:** `BridgeAPIClient` is `final` (`BridgeAPIClient.swift:14`); orphan `TestableBridgeAPIClient: BridgeAPIClient` (`OrchestratorTests.swift:27`) cannot compile.

## Strategy Comparison

| Rank | Strategy | Production edits | Test edits | Offline determinism | Parallel safety | Risk | Recommendation |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | **A — Remove `final` + typed test-only spy** | 1 declaration edit (`BridgeAPIClient.swift`) | New `OrchestratorLoadAllTests.swift` (4 tests + spy) | **High** — no shared stubs | **High** — no URLProtocol | **Low** | **Recommended IOS-TEST-003B2** |
| 2 | **B — Remove `final` + suite-local URLProtocol** | 1 declaration edit | New file + local stub type + zone/entertainment JSON | Medium — isolated stubs | Medium — if local stub only | Medium — larger harness | Fallback if spy blocked |
| 3 | **C — Preserve finality + DEBUG injection abstraction** | Widen `clients` type or add protocol/map in orchestrator | Test doubles via new production seam | High | High | **High** — duplicates orchestration routing | **Reject** — widens production solely to avoid `final` removal |
| 4 | **D — Preserve finality + real client URLProtocol interception** | None | Intercept `HueAPIClient.session` (private lazy) | Low — cert delegate, lazy session | Low — process-global | **High** | **Reject** — fragile, infeasible without production edits |
| 5 | **E — Register and repair full orphan suite** | `final` removal + multiple compile fixes | Edit orphan file (shim, `await turnAllOff`, stubs, sleeps) | Low — shared stubs | Low | **High** — 14 tests, CB-2/CB-3 remain | **Reject** — scope exceeds bounded slice |
| 6 | **F — Defer recovery** | None | None | N/A | N/A | None (no progress) | **Reject** — Strategy A is bounded and safe |

### Strategy notes

**Strategy A** reuses existing `#if DEBUG injectForTesting(clients:)` without orchestrator changes. Typed spy overrides four fetch methods plus cleanup GET. No URLProtocol, no shared mutable state, no scheme change.

**Strategy B** adds useful coverage beyond `HueAPIClientTests` only at the orchestration-merge level; decoding is already covered in `HueAPIClientTests`. The extra harness surface (zone stub, entertainment stub, parallel isolation) is unnecessary when typed spy achieves the same orchestration assertions with less code.

**Strategy C** would require changing `clients: [String: BridgeAPIClient]` or adding a parallel protocol-typed map — production orchestrator edits beyond declaration-only scope.

**Strategy D** cannot intercept `private lazy var session` on `HueAPIClient` without production changes; cert-trust delegate complicates global URLProtocol registration.

**Strategy E** cannot be repaired in one small PR: orphan file has compile blockers CB-2 (`testApplySSEEvent` return mismatch), CB-3 (`turnAllOff()` async), plus 10 non-loadAll tests.

## Recommended IOS-TEST-003B2 Slice

**IOS-TEST-003B2 — Orchestrator loadAll offline harness recovery (4 tests)**

| Decision | Choice |
| --- | --- |
| Strategy | **A — Remove `final` from `BridgeAPIClient` + typed test-only spy** |
| Production edits | **Declaration-only** — remove `final` from `BridgeAPIClient.swift:14` |
| `UnifiedOrchestrator.swift` changes | **No** |
| `HueAPIClient.swift` changes | **No** |
| Orphan file | **Remain untouched** — do not register `OrchestratorTests.swift` |
| New test file | `HueHomeTests/OrchestratorLoadAllTests.swift` |
| Tests to recover | 4 LOAD_ALL tests (copy assertions, new harness) |
| URLProtocol | **Avoid** |
| Scheme parallelization | **Unchanged** (`parallelizable = "YES"`) |
| Cleanup GET | **Handle explicitly** in spy `get()` override |
| Cleanup PUT | **Avoid** via empty entertainment list |
| Widget/watch delayed work | Accept 500 ms task; no teardown wait required for B2 |
| Physical-device test | **Not required** (declaration-only production edit) |

## Proposed Test-Only Spy Contract

```swift
// HueHomeTests/OrchestratorLoadAllTests.swift (proposed, not implemented)

final class OrchestratorLoadAllSpyBridgeClient: BridgeAPIClient, @unchecked Sendable {

    // Fixture outputs (memberwise-constructed or JSON-decoded)
    var stubRooms: [HueRoom] = []
    var stubZones: [HueZone] = []
    var stubLights: [HueLight] = []
    var stubGroupedLights: [HueGroupedLight] = []

    // Per-method error injection (nil = success)
    var fetchRoomsError: Error?
    var fetchZonesError: Error?
    var fetchLightsError: Error?
    var fetchGroupedLightsError: Error?

    private(set) var fetchRoomsCallCount = 0
    private(set) var fetchZonesCallCount = 0
    private(set) var fetchLightsCallCount = 0
    private(set) var fetchGroupedLightsCallCount = 0
    private(set) var entertainmentCleanupGetCount = 0

    init(bridgeID: String = "bridge-1", bridgeName: String = "Test Bridge",
         ip: String = "192.168.1.1", token: String = "test-token") {
        super.init(bridgeID: bridgeID, bridgeName: bridgeName, ip: ip, token: token)
    }

    override func fetchRooms() async throws -> [HueRoom] {
        fetchRoomsCallCount += 1
        if let fetchRoomsError { throw fetchRoomsError }
        return stubRooms
    }
    // ... mirror for zones, lights, grouped lights ...

    override func get(path: String, ip: String, token: String) async throws -> Data {
        if path == "/clip/v2/resource/entertainment_configuration" {
            entertainmentCleanupGetCount += 1
            return Data(#"{"errors":[],"data":[]}"#.utf8)
        }
        throw HueAPIError.httpError(404)
    }
}
```

**Setup pattern:**

```swift
@MainActor
final class OrchestratorLoadAllTests: XCTestCase {
    var orchestrator: UnifiedOrchestrator!
    var spy: OrchestratorLoadAllSpyBridgeClient!

    override func setUp() {
        orchestrator = UnifiedOrchestrator()
        spy = OrchestratorLoadAllSpyBridgeClient(bridgeID: "bridge-1")
    }
}
```

## Four-Test Recovery Matrix

| Test | Fixtures | Forced error | Expected result | Cleanup behavior | Notes |
| --- | --- | --- | --- | --- | --- |
| **LOAD-01** `testLoadAll_success_populatesRooms` | 1 room (Bedroom), 0 zones, 1 light, 1 grouped_light ON @ 80% | None | `allRooms.count == 1`; id/name/gl-001; `isOn == true`; brightness ≈ 80; `connectionStatus["bridge-1"] == .connected` | GET count ≥ 1; empty list; no PUT | Match orphan assertions `:179-190` |
| **LOAD-02** `testLoadAll_lights_off` | Same room/light; grouped_light OFF | None | `allRooms.count == 1`; `isOn == false` | Same cleanup | Match orphan `:192-198` |
| **LOAD-03** `testLoadAll_bridgeError_leavesRoomsEmpty` | Defaults (empty stubs) | All four `fetch*` throw (e.g. `HueAPIError.httpError(404)`) | `allRooms.isEmpty`; `connectionStatus["bridge-1"]` is `.error` | GET still runs; errors swallowed in cleanup; fetch errors propagate to status | Fresh orchestrator — stale-while-revalidate N/A; **`lastLoadedAt` still updates** (not asserted in orphan) |
| **LOAD-04** `testLoadAll_setsLastLoadedAt` | Same as LOAD-01 | None | `lastLoadedAt >= before` (where `before = Date()` pre-call) | Same cleanup | Completion-based semantics; consider rename for clarity |

### Per-test detail

| Test | Required spy fixture | Fetch throws | Expected call counts | Widget/watch | Teardown |
| --- | --- | --- | --- | --- | --- |
| LOAD-01 | Bedroom room + light + gl ON | — | 1× each fetch*; 1× cleanup GET | `scheduleWidgetWrite` fires 500 ms task | Release orchestrator; no wait |
| LOAD-02 | Same; gl OFF | — | Same | Same | Same |
| LOAD-03 | Empty arrays (unused) | All four fetch* | 1× each (throw); 1× cleanup GET | Rebuild on empty maps | Same |
| LOAD-04 | Same as LOAD-01 | — | Same | Same | Same |

**Task leakage:** Acceptable for B2 — no background `loadAll` retry, no `setRoom` tasks. Widget 500 ms task may outlive test; offline-safe.

**Assertion naming:** LOAD-04 should document completion-based `lastLoadedAt` semantics explicitly.

## Expected IOS-TEST-003B2 Changed Files

| File | Change |
| --- | --- |
| `HueHome/Core/Network/BridgeAPIClient.swift` | Remove `final` (declaration-only) |
| `HueHomeTests/OrchestratorLoadAllTests.swift` | **New** — 4 tests + spy + private fixtures |
| `HueHome.xcodeproj/project.pbxproj` | Add new test file to Sources |
| `DEVLOG.md` | Implementation entry |

**Not changed:** `UnifiedOrchestrator.swift`, `HueAPIClient.swift`, `OrchestratorTests.swift`, scheme, parallelization settings, existing test membership.

## Required Focused Validation

| Check | Expected |
| --- | --- |
| Focused signed-simulator `OrchestratorLoadAllTests` | **4/4 pass** |
| No regression in `OrchestratorCacheDemoTests` | **4/4 pass** |

## Required Full Signed-Simulator Validation

| Check | Expected |
| --- | --- |
| Full `HueHomeTests` (signed simulator) | **126/126 pass** (122 baseline + 4 new) |

## Generic Build Requirement

Unsigned generic Debug + Release app builds must remain **BUILD SUCCEEDED** after declaration-only `BridgeAPIClient` edit.

## Physical-Device Requirement Assessment

**Not required for IOS-TEST-003B2.**

The only production edit is removing `final` from `BridgeAPIClient`. All method bodies, runtime routing, credential resolution, and network behavior remain unchanged. Subclassing is test-target-only; no app code instantiates subclasses. Same reasoning applies to this docs-only slice — no device test required.

## Explicit Do-Not-Touch List

- `UnifiedOrchestrator.swift` behavior (including `lastLoadedAt` semantics)
- `HueAPIClient.swift` method bodies
- `OrchestratorTests.swift` registration or edits
- Scheme parallelization settings
- Shared `StubURLProtocol` reuse in new suite
- Optimistic update, rollback, `turnAllOff`, SSE tests (IOS-TEST-003B3/B4)
- Composer cadence quartet
- `ChromaGlow.xcodeproj`
- Production networking, Keychain, SSE, widget/watch payload behavior

## Deferred Recovery Work

| Future slice | Scope |
| --- | --- |
| **IOS-TEST-003B3** | Optimistic update, rollback, `turnAllOff` — 3 orphan tests; fix `await turnAllOff`, replace `Task.sleep`, task drain |
| **IOS-TEST-003B4** | SSE — 3 orphan tests; remove invalid `testApplySSEEvent` shim; call internal `applySSEEvent` directly |
| **IOS-TEST-003B5 (optional)** | Retire orphan `OrchestratorTests.swift` after all tests migrated |

## Open Questions

1. **Spy fixture construction:** Prefer JSON-decode helpers (consistent with `HueAPIClientTests`) or memberwise struct literals in test file? Both compile via `@testable import`; JSON mirrors production decode path.
2. **LOAD-04 naming:** Rename to `testLoadAll_setsLastLoadedAt_onCompletion` and optionally add error-path `lastLoadedAt` assertion in same test or separate test?
3. **Call-count assertions:** Should B2 assert exact fetch/cleanup counts for regression detection, or keep orphan-level behavioral assertions only?
4. **Widget side effects:** Is writing to `WidgetDataStore.shared` during loadAll tests acceptable without cancellation hooks? Prior inventory accepted for offline sim.

---

### Explicit inventory answers

| Question | Answer |
| --- | --- |
| Must `BridgeAPIClient` finality change? | **Yes** |
| Is production edit declaration-only? | **Yes** |
| Does `UnifiedOrchestrator.swift` need modification? | **No** |
| Does `HueAPIClient.swift` need modification? | **No** |
| Should orphan file remain untouched? | **Yes** |
| Are typed fixtures feasible? | **Yes** |
| Are JSON fixtures preferable? | Optional; JSON safer for decode parity |
| Should URLProtocol be avoided? | **Yes** |
| Does suite-local URLProtocol remain fallback? | **Yes** (Strategy B) |
| Does scheme parallelization remain unchanged? | **Yes** |
| Must cleanup GET be handled explicitly? | **Yes** |
| Can cleanup PUT be avoided? | **Yes** (empty entertainment list) |
| Does widget/watch delayed work need teardown? | **No** for B2 |
| Is `lastLoadedAt` success-only or completion-based? | **Completion-based** |
| Is physical-device test required? | **No** |
| Expected focused simulator count | **4/4** |
| Expected full signed-simulator count | **126/126** (future B2 target) |
