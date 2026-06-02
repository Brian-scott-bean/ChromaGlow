# OrchestratorTests Target-Membership Repair Inventory

## Purpose

Document the exact blockers, stale assumptions, concurrency risks, runtime risks, and minimum safe future repair slice required to register some or all of the orphaned `HueHomeTests/OrchestratorTests.swift` suite into the active `HueHomeTests` target.

**Slice:** IOS-TEST-003A (documentation only). **Out of scope:** Swift edits, Xcode project edits, target membership changes, test repairs, access-level changes, IOS-TEST-003B implementation.

## Current Baseline

| Item | Value |
| --- | --- |
| Working branch | `ios-test/orchestrator-tests-membership-inventory` |
| Starting SHA | `c1d5917` |
| `origin/main` at inventory time | `c1d5917` (0 ahead / 0 behind) |
| Xcode project | `HueHome.xcodeproj` |
| Scheme | `HueHome 1` |
| Signed-simulator `HueHomeTests` | **118/118** pass (10 member test files) |
| Orphan file | `HueHomeTests/OrchestratorTests.swift` (tracked on disk, **not** in `project.pbxproj`) |
| Prior related work | IOS-TEST-002B merged (`ComposerFetchPathParityTests` → 9/9); IOS-REF-006B merged |
| Generic unsigned Debug/Release app build | BUILD SUCCEEDED (per user brief) |

## Orphan Membership Confirmation

| Check | Result |
| --- | --- |
| `git ls-files HueHomeTests/OrchestratorTests.swift` | Tracked |
| `PBXFileReference` for `OrchestratorTests.swift` | **Absent** |
| `PBXBuildFile` for `OrchestratorTests.swift` | **Absent** |
| `HueHomeTests` Sources membership | **Absent** |
| `ChromaGlow.xcodeproj` tracked | **No** (`git ls-files` empty) |

Confirmed: the orphan suite is intentionally off-target. Registering the file as-is would not compile.

## Exact Orphan Test Count

| Metric | Count |
| --- | --- |
| **XCTest methods** (`OrchestratorTests` class, `func test…()`) | **14** |
| Earlier handoff / DEVLOG estimate | **15** (incorrect) |
| Non-test helper matching `func test*` pattern | 1 — `UnifiedOrchestrator.testApplySSEEvent(…)` extension at file bottom (not an XCTest method) |
| Header comment claiming “bridge deduplication” coverage | **Stale** — no such test method exists in the file |

**The earlier 15-test estimate was incorrect.** It likely counted the `testApplySSEEvent` forwarding helper or repeated a pre-removal count.

## Orphan Test Inventory

| Test | Category | Dependencies | Compile status | Runtime risk | Recovery recommendation |
| --- | --- | --- | --- | --- | --- |
| `testPreloadCached_populatesAllRooms` | CACHE_ONLY | `UnifiedOrchestrator`, `HueLocalRoom` (`@Model`), SwiftData import | **Compile-ready in isolation** | Low — no network, no shared stubs, no widget path (`preloadCached` sets `allRooms` directly) | **Enable in IOS-TEST-003B first slice** (new file) |
| `testPreloadCached_sortsAlphabetically` | CACHE_ONLY | Same as above | **Compile-ready in isolation** | Low | **Enable in IOS-TEST-003B first slice** |
| `testPreloadCached_emptyInput_leavesAllRoomsEmpty` | CACHE_ONLY | Same as above | **Compile-ready in isolation** | Low | **Enable in IOS-TEST-003B first slice** |
| `testLoadAll_success_populatesRooms` | LOAD_ALL | `TestableBridgeAPIClient`, `StubURLProtocol`, `injectForTesting` | **Blocked** — `TestableBridgeAPIClient` illegal; zone stub missing | High — missing `/clip/v2/resource/zone` stub causes tuple `try await` to throw → stale-while-revalidate keeps empty `allRooms` | Defer to IOS-TEST-003B2 after compile + fixture repair |
| `testLoadAll_lights_off` | LOAD_ALL | Same | **Blocked** | High — same zone gap | Defer to IOS-TEST-003B2 |
| `testLoadAll_bridgeError_leavesRoomsEmpty` | LOAD_ALL | `injectForTesting`, `StubURLProtocol` (empty stubs) | **Blocked** — subclass illegal | Medium — assertion still valid on fresh orchestrator (empty stays empty); entertainment cleanup adds unstubbed GET | Defer to IOS-TEST-003B2 |
| `testLoadAll_setsLastLoadedAt` | LOAD_ALL | Same as success | **Blocked** | High — zone gap prevents success path | Defer to IOS-TEST-003B2 |
| `testSetRoom_optimisticUpdate_flipsIsOnImmediately` | OPTIMISTIC_UPDATE | Subclass + stubs + `loadAll` precondition | **Blocked** | Medium — `setRoom` spawns background `Task`; `scheduleStateRefresh()` may schedule delayed `loadAll` after success | Defer to IOS-TEST-003B3 |
| `testSetRoom_rollback_onAPIError` | ROLLBACK | Subclass + stubs + `Task.sleep(300ms)` | **Blocked** | High — fixed sleep fragile; rollback `Task` + `showToast` + `scheduleStateRefresh` may outlive assertion | Defer to IOS-TEST-003B3; replace sleep with deterministic drain |
| `testTurnAllOff_setsAllRoomsOffBeforeAPICallsComplete` | TURN_ALL_OFF | Subclass + stubs + `loadAll` | **Blocked** — `turnAllOff()` is `async` but test calls without `await` | Medium — spawns concurrent PUT tasks; no teardown | Defer to IOS-TEST-003B3 |
| `testApplySSEEvent_groupedLight_updatesRoomState` | SSE | Subclass, stubs, `testApplySSEEvent` shim | **Blocked** — shim return type mismatch; subclass illegal | Low–medium — calls `applySSEEvent` directly path; `loadAll` triggers widget scheduling | Defer to IOS-TEST-003B4 |
| `testApplySSEEvent_malformedJSON_doesNotCrash` | SSE | None (local JSON decode only) | **Compile-ready in isolation** | Low | Could enable early, but bundled file prevents registration; defer or extract |
| `testApplySSEEvent_unknownType_doesNotMutateState` | SSE | Subclass, stubs, shim | **Blocked** | Medium — depends on repaired `loadAll` | Defer to IOS-TEST-003B4 |
| `testDemoMode_loadAll_doesNotMakeNetworkRequests` | DEMO_MODE | `enterDemoMode`, `loadAll` | **Compile-ready in isolation** | Low — demo early-return, no client injection, no stubs | **Enable in IOS-TEST-003B first slice** |

### Category summary

| Category | Count | Immediate recovery |
| --- | ---: | --- |
| CACHE_ONLY | 3 | Yes (subset, new file) |
| DEMO_MODE | 1 | Yes (subset, new file) |
| LOAD_ALL | 4 | No — compile + fixture repair |
| OPTIMISTIC_UPDATE | 1 | No |
| ROLLBACK | 1 | No |
| TURN_ALL_OFF | 1 | No |
| SSE | 3 | No (1 compile-ready alone, but file-bound) |

## Confirmed Compile Blockers

| ID | Blocker | Evidence | Classification |
| --- | --- | --- | --- |
| CB-1 | **`BridgeAPIClient` is `final`** — `TestableBridgeAPIClient: BridgeAPIClient` is illegal | `BridgeAPIClient.swift:14` `final class BridgeAPIClient`; `OrchestratorTests.swift:27` | **CONFIRMED_COMPILE_BLOCKER** |
| CB-2 | **`testApplySSEEvent` shim return type mismatch** — production returns `(rooms: Bool, zones: Bool)`, shim declares `-> Bool` | `UnifiedOrchestrator.swift:1165`; `OrchestratorTests.swift:366-367` | **CONFIRMED_COMPILE_BLOCKER** |
| CB-3 | **`turnAllOff()` is `async`** — test calls `orchestrator.turnAllOff()` without `await` | `UnifiedOrchestrator.swift:980`; `OrchestratorTests.swift:270` | **CONFIRMED_COMPILE_BLOCKER** |
| CB-4 | **Whole-file registration** — even compile-ready tests share a file with `TestableBridgeAPIClient` | File structure | **CONFIRMED_COMPILE_BLOCKER** for registering `OrchestratorTests.swift` intact |

Removing `final` from `BridgeAPIClient` alone is **necessary but not sufficient** for full-file recovery (CB-2, CB-3, fixture drift remain).

## Likely Warnings and Redundant Code

| Item | Assessment | Classification |
| --- | --- | --- |
| `TestableBridgeAPIClient` `@unchecked Sendable` restatement | Subclass may need explicit `@unchecked Sendable` restatement when `final` is removed; inherited from `HueAPIClient` chain | **LIKELY_COMPILE_WARNING** |
| `credentials()`, `get()`, `put()` overrides | All remain non-`final` on `HueAPIClient` (`HueAPIClient.swift:73,625,630`); overridable once subclassing is legal | **REDUNDANT_BUT_COMPILE_SAFE** (after CB-1 fix) |
| `StubURLProtocol` cross-file visibility | `internal` class in same `HueHomeTests` target — visible to `OrchestratorTests.swift` without import | **REDUNDANT_BUT_COMPILE_SAFE** |
| `injectForTesting(clients:)` | `#if DEBUG` on `UnifiedOrchestrator` (`UnifiedOrchestrator.swift:349-354`); accessible in Debug test builds | **REDUNDANT_BUT_COMPILE_SAFE** |
| `testApplySSEEvent` extension | `applySSEEvent` is already **`internal`** (`UnifiedOrchestrator.swift:1165`), callable via `@testable import HueHome`; shim adds wrong return type | **REDUNDANT_BUT_COMPILE_SAFE** after removal; **invalid as written** |
| `HueLocalRoom` construction in tests | `@Model` class in `HueDataModels.swift:57`; orphan `makeLocalRoom` pattern matches existing `HueDataModelsTests` usage | **REDUNDANT_BUT_COMPILE_SAFE** |
| Header “bridge deduplication” bullet | No corresponding test method | **REDUNDANT** (stale comment) |
| Orphan `Fixture.installLoadAll` first stub key | Line 125 builds a malformed key via `replacingOccurrences`; path-keyed stubs rely on `/clip/v2/resource/…` entries | **RUNTIME_RISK** (benign if path keys suffice) |

## loadAll Fixture Drift

### Current production `loadAll()` behavior

| Step | Production behavior | Source |
| --- | --- | --- |
| Demo-mode early return | `loadDemoData()`; no network | `UnifiedOrchestrator.swift:577-579` |
| Empty-client early return | Skip fetch; keep cached `allRooms` | `581-586` |
| Concurrent-load suppression | `guard !isLoading` returns early | `592-594` |
| `isLoading` lifecycle | Set `true`, cleared in `defer` | `599-601` |
| Parallel outer group | `deactivateStuckEntertainmentSessions()` ∥ `fetchAndMergeAllBridges()` | `605-607` |
| Per-bridge fetches | `fetchRooms`, `fetchZones`, `fetchLights`, `fetchGroupedLights` in parallel | `632-638` |
| Error handling | Catch → `(bridgeID, nil, nil, …)` stale-while-revalidate | `663-668` |
| Post-fetch | `rebuildAllRooms()`, `rebuildAllZones()`, `lastLoadedAt = Date()` | `614-616` |
| Widget/watch side effects | `rebuildAllRooms/Zones` → `scheduleWidgetWrite()` → `WidgetDataStore` + `WatchSessionManager.push` after 500 ms | `1260-1312` |
| Entertainment cleanup | GET `/clip/v2/resource/entertainment_configuration`; optional PUT stop per active session | `3014-3042` |

### Fixture coverage vs production

| Production dependency | Current production behavior | Orphan fixture coverage | Gap | Proposed repair |
| --- | --- | --- | --- | --- |
| GET `/clip/v2/resource/room` | Required in `fetchAndMergeAllBridges` | Stubbed in `Fixture.installLoadAll` | None for happy path | Keep |
| GET `/clip/v2/resource/zone` | Required — part of tuple `try await` | **Not stubbed** | **Yes — runtime blocker for success tests** | Add empty-zone JSON stub (`{"errors":[],"data":[]}`) in IOS-TEST-003B2 |
| GET `/clip/v2/resource/light` | Required | Stubbed | None | Keep |
| GET `/clip/v2/resource/grouped_light` | Required | Stubbed | None | Keep |
| GET `/clip/v2/resource/entertainment_configuration` | Runs concurrently during every `loadAll` | **Not stubbed** | **Yes — broadens test surface** | Stub empty list or `[]` data response; errors are swallowed but add noise |
| PUT `/clip/v2/resource/entertainment_configuration/{id}` | Only if active sessions found | Not stubbed | Latent | Return empty entertainment list in stub to avoid PUT branch |
| PUT `/clip/v2/resource/grouped_light/{id}` | `setRoom`, `turnAllOff` | Stubbed for optimistic tests | None once compile fixed | Keep |
| `rebuildAllRooms` / `scheduleWidgetWrite` | After every successful `loadAll` | Not isolated | Side-effect leakage | Accept for offline sim (writes to shared singletons) or drain/cancel in tearDown (003B3+) |
| Stale-while-revalidate | Failed fetch keeps prior `roomsByBridge` | Orphan error test assumes empty stays empty | Assertion OK on fresh orchestrator only | Document; add explicit empty precondition |

**Missing zone stub is a confirmed runtime blocker** for all `loadAll` success-path tests: any single failed fetch fails the whole `(roomsFetch, zonesFetch, lightsFetch, glFetch)` tuple, the catch path returns `nil`, and a fresh orchestrator’s `allRooms` remains empty.

**Entertainment cleanup broadens `loadAll` tests** but is non-fatal today (errors caught and logged). It still issues real stub-routed GETs that should be explicitly stubbed for deterministic offline behavior.

## Concurrency and Isolation Risks

| Risk | Assessment |
| --- | --- |
| Scheme parallelization | `HueHome 1.xcscheme` line 35: `parallelizable = "YES"` for `HueHomeTests` |
| Shared `StubURLProtocol.stubs` | Static mutable dictionary (`HueAPIClientTests.swift:16`); reset in per-class `setUp`/`tearDown` only within each class — **not safe across parallel test classes** |
| `HueAPIClientTests` + orphan suite concurrent execution | Would race on `StubURLProtocol.stubs` if both registered without isolation | **Shared StubURLProtocol reuse is NOT safe under current parallel settings** |
| Narrower fix | Suite-local stub type, actor-isolated stub registry, or `parallelizable = "NO"` on a dedicated test class only — **prefer suite-local stub**; avoid global scheme change |
| `Task.sleep(300_000_000)` in rollback test | Non-deterministic under load; may flake if API mock slow | Replace with task drain / expectation in IOS-TEST-003B3 |
| `setRoom` background tasks | Spawns `Task` for PUT + `scheduleStateRefresh()` (1.5 s delayed `loadAll`) + possible toast | **Task cleanup required** before parallel-safe registration |
| `turnAllOff` | `async`; fires concurrent PUT `TaskGroup`; test omits `await` | Fix signature usage + optional drain in IOS-TEST-003B3 |
| Widget/watch scheduling | `loadAll` → `rebuildAllRooms` → 500 ms delayed widget + watch push | Offline-safe but leaves background work; low flake risk if tests exit before delay |
| Cache/demo tests | No stubs, no injected clients, no `loadAll` network path (demo) | **Safe under parallelization** |

## Strategy Comparison

| Rank | Strategy | Production edits | Test edits | Membership edits | Risk | Recommendation |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | **B — Recover cache + demo only (new file)** | None | New small file (~4 tests), copy helpers | Add new file to target | **Low** | **Recommended IOS-TEST-003B slice** |
| 2 | **C — Staged recovery (B1→B4)** | B2 may need `BridgeAPIClient` non-`final` or alternate injection | Progressive repair of orphan file or split files | Incremental | Medium | Safer than full-file enable; follow after B1 |
| 3 | **A — Register existing orphan file + minimum compile repairs** | Likely `BridgeAPIClient` de-finalize | Fix shim, `await turnAllOff`, zone/entertainment stubs, sleeps, stub isolation | Add `OrchestratorTests.swift` | **High** — large diff, parallel stub races, production touch | Defer |
| 4 | **D — Defer all registration** | None | None | None | None (no progress) | Reject — bounded B1 slice exists |

**Staged recovery is safer than recovering the full orphan suite in one slice.** The full orphan file should **not** be recovered in one PR.

## Recommended IOS-TEST-003B Slice

**IOS-TEST-003B — Orchestrator cache + demo offline recovery (4 tests)**

| Decision | Choice |
| --- | --- |
| Recover full orphan suite? | **No** — subset only |
| Tests to enable | `testPreloadCached_populatesAllRooms`, `testPreloadCached_sortsAlphabetically`, `testPreloadCached_emptyInput_leavesAllRoomsEmpty`, `testDemoMode_loadAll_doesNotMakeNetworkRequests` |
| Tests to defer | All 10 network/SSE/mutation tests remaining in orphan file |
| Edit or replace orphan file? | **New file** — do not register `OrchestratorTests.swift` yet |
| Suggested new file | `HueHomeTests/OrchestratorCacheDemoTests.swift` |
| `BridgeAPIClient` finality change? | **No** |
| `StubURLProtocol` reuse? | **Not needed** for this slice |
| Suite-local stub preferred? | N/A for B1; **Yes** for B2+ when shared parallel risk matters |
| Scheme parallelization change? | **No** — remain `parallelizable = "YES"` |
| DEBUG-only production hook? | **No** |
| Physical-device test? | **No** |

## Expected IOS-TEST-003B Changed Files

| File | Change |
| --- | --- |
| `HueHomeTests/OrchestratorCacheDemoTests.swift` | **New** — 4 tests + private `makeLocalRoom` helper |
| `HueHome.xcodeproj/project.pbxproj` | Add file reference + Sources membership |
| `DEVLOG.md` | Implementation entry |

**Not changed in IOS-TEST-003B:** `BridgeAPIClient.swift`, `OrchestratorTests.swift`, scheme, parallelization, production orchestrator code.

## Required Focused Validation

| Check | Expected |
| --- | --- |
| `OrchestratorCacheDemoTests` | **4/4 pass** |
| No regression in existing member suites | All prior tests still pass |

## Required Full Signed-Simulator Validation

| Check | Expected |
| --- | --- |
| Full `HueHomeTests` (signed simulator) | **122/122 pass** (118 baseline + 4 new) |

## Generic Build Requirement

Unsigned generic Debug + Release app builds must remain **BUILD SUCCEEDED** (no production edits expected in B1).

## Physical-Device Requirement Assessment

**Not required** for IOS-TEST-003B. Cache preload and demo-mode `loadAll` are fully offline unit tests with no bridge, widget, or watch hardware dependency.

## Explicit Do-Not-Touch List

Same as IOS-TEST-003A prohibition list: no production behavior changes, no scheme churn, no broad access widening, no orphan file registration without compile repair, no `ChromaGlow.xcodeproj`, no Composer cadence quartet relocation, no parallelization disable unless a future slice proves unavoidable.

## Deferred Recovery Work

| Future slice | Scope |
| --- | --- |
| **IOS-TEST-003B2** | `loadAll` offline harness — zone + entertainment stubs; resolve `BridgeAPIClient` subclass vs composition injection; 4 LOAD_ALL tests |
| **IOS-TEST-003B3** | Optimistic update, rollback, `turnAllOff` — fix `async` usage, replace fixed sleep, task drain, widget/refresh isolation; 3 tests |
| **IOS-TEST-003B4** | SSE — remove redundant shim, call `applySSEEvent` directly, repair fixtures; 3 tests |
| **IOS-TEST-003B5 (optional)** | Retire or merge orphan `OrchestratorTests.swift` after all tests migrated |

## Open Questions

1. **Injection without de-finalizing `BridgeAPIClient`:** Could `injectForTesting` accept a protocol typed to `HueAPIClient` + bridge metadata instead of requiring `BridgeAPIClient` subclass? Would avoid production `final` removal but widens API surface — needs explicit decision in B2.
2. **Widget/watch side effects in offline tests:** Is writing to `WidgetDataStore.shared` during `loadAll` tests acceptable, or should B2 add test doubles / cancellation hooks?
3. **Gamut tie-break / bridge deduplication:** Orphan header references deduplication test that no longer exists — delete stale comment when orphan file is next edited?
4. **Malformed SSE test extraction:** `testApplySSEEvent_malformedJSON_doesNotCrash` is compile-ready alone — include in B1 as 5th test or keep bundled with SSE slice?

---

### Hypothesis verification summary (IOS-TEST-003A)

| # | Hypothesis | Verdict |
| ---: | --- | --- |
| 1 | Tracked on disk, absent from pbxproj | **Confirmed** |
| 2 | Declares `TestableBridgeAPIClient: BridgeAPIClient` | **Confirmed** |
| 3 | Production `final class BridgeAPIClient: HueAPIClient, @unchecked Sendable` | **Confirmed** |
| 4 | Cannot compile while `BridgeAPIClient` remains `final` | **Confirmed** |
| 5 | Contains 14 XCTest methods, not 15 | **Confirmed** (15 estimate incorrect) |
| 6 | Depends on `StubURLProtocol` in `HueAPIClientTests.swift` | **Confirmed** |
| 7 | `StubURLProtocol` uses shared mutable `static var stubs` | **Confirmed** |
| 8 | Scheme marks `HueHomeTests` parallelizable | **Confirmed** |
| 9 | `loadAll` fetches rooms, zones, lights, grouped lights | **Confirmed** |
| 10 | `loadAll` runs `deactivateStuckEntertainmentSessions()` concurrently with bridge loading | **Confirmed** |
| 11 | Fixtures stale — missing zones, entertainment, new fetches | **Confirmed** |
| 12 | Orphan adds `testApplySSEEvent` extension | **Confirmed** |
| 13 | Production `applySSEEvent` already internal — shim redundant | **Confirmed** (shim also has wrong return type) |
| 14 | Background tasks / fixed sleeps — parallel concerns | **Confirmed** |
| 15 | Widget/watch scheduling via rebuild paths | **Confirmed** |
