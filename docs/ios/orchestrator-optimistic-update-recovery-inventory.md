# Orchestrator Optimistic-Update Recovery Inventory

## Purpose

Document the narrowest safe future implementation slice (**IOS-TEST-003B3B**) for recovering exactly three orphaned mutation tests from `HueHomeTests/OrchestratorTests.swift` into a new bounded test file — without registering the orphan suite, without `StubURLProtocol`, without production behavior changes, and without fixed sleeps.

**Slice:** IOS-TEST-003B3A (documentation only). **Out of scope:** Swift edits, Xcode project edits, test implementation, orphan-file edits, scheme changes, `BridgeAPIClient` edits.

## Current Baseline

| Item | Value |
| --- | --- |
| Working branch | `ios-test/orchestrator-optimistic-update-inventory` |
| Starting SHA | `a0f37be` |
| `origin/main` at inventory time | `a0f37be` (0 ahead / 0 behind; `origin/main` is ancestor of HEAD) |
| Xcode project | `HueHome.xcodeproj` |
| Scheme | `HueHome 1` |
| Full signed-simulator `HueHomeTests` | **126/126** pass |
| Recovered cache/demo suite | `OrchestratorCacheDemoTests.swift` → **4/4** pass (in target) |
| Recovered loadAll suite | `OrchestratorLoadAllTests.swift` → **4/4** pass (in target) |
| Orphan file | `HueHomeTests/OrchestratorTests.swift` (tracked, **not** in `project.pbxproj`) |
| Prior inventories | `docs/ios/orchestrator-tests-membership-repair-inventory.md`, `docs/ios/orchestrator-loadall-harness-repair-inventory.md` |
| IOS-TEST-003B2B merged | `BridgeAPIClient` is non-`final` (`BridgeAPIClient.swift:14` `class BridgeAPIClient`) |

## Three Deferred Orphan Tests

| Test | Intended contract | Stale assumptions | Compile blocker | Runtime risk | Recovery recommendation |
| --- | --- | --- | --- | --- | --- |
| `testSetRoom_optimisticUpdate_flipsIsOnImmediately` | `setRoom(_:isOn:)` applies `updateRoom` synchronously before `setGroupedLight` completes | Calls `Fixture.installLoadAll()` + `await loadAll()` only to obtain `groupedLightID`; orphan `makeLocalRoom` omits `cachedGroupedLightID` | **Yes** (file-level) — `TestableBridgeAPIClient` + whole orphan file; **not** needed if extracted | **High** — success-path `scheduleStateRefresh()` schedules delayed `loadAll()` at +1.5s; can outlive test if spy allows success | Recover as `testSetRoom_appliesOptimisticState_beforeAPICallCompletes` in `OrchestratorOptimisticUpdateTests.swift` via **Strategy A** + gated spy; **force API failure on teardown** to skip `scheduleStateRefresh` |
| `testSetRoom_rollback_onAPIError` | Optimistic OFF, then rollback to prior ON after PUT failure | `StubURLProtocol` stub removal; **`Task.sleep(300ms)`** | **Yes** (file-level) | **High** — fixed sleep nondeterministic; `showToast` spawns 3s clear task (benign to assertions) | Recover as `testSetRoom_rollsBack_afterAPIError` with **immediate-throw spy** + **bounded async eventual** rollback observation |
| `testTurnAllOff_setsAllRoomsOffBeforeAPICallsComplete` | `turnAllOff()` maps all rooms OFF before grouped-light PUTs finish | Assumes sync `turnAllOff()`; uses `loadAll` + URL stubs | **Yes** — calls `orchestrator.turnAllOff()` **without `await`** while production method is `async` (`UnifiedOrchestrator.swift:980`) | **Medium** — fire-and-forget `turnAllOff` task may not finish before assertions; concurrent PUT `Task`s in group | Recover as `testTurnAllOff_appliesOptimisticState_beforeAPICallsComplete` with `Task { await orchestrator.turnAllOff() }`, gated spy, assert OFF while gate suspended |

### Cross-cutting orphan issues (do not copy)

| Issue | Evidence | B3B stance |
| --- | --- | --- |
| Unnecessary `loadAll()` for fixture seed | Orphan optimistic test: `preloadCached` then `await loadAll()` (`OrchestratorTests.swift:220-231`) | **Reject** — seed via `preloadCached` + `cachedGroupedLightID` |
| Shared `StubURLProtocol` static stubs | `OrchestratorTests.swift:123-129`, `setUp`/`tearDown` reset | **Reject** — typed spy only |
| Fixed `Task.sleep(300ms)` on rollback | `OrchestratorTests.swift:257` | **Reject** — bounded eventual polling |
| Missing `await` on `turnAllOff` | `OrchestratorTests.swift:270` vs `:980` `func turnAllOff() async` | **Require `await`** via explicit `Task` |
| Success-path delayed refresh leakage | `setRoom` success calls `scheduleStateRefresh()` (`:732`) | **Avoid success path** in MUT-01 teardown; MUT-02 uses failure path (no refresh) |

## Current preloadCached Fixture Boundary

Source: `UnifiedOrchestrator.swift:505-537`, `HueDataModels.swift:80`.

| Behavior | Confirmed |
| --- | --- |
| Guard | Returns unless `allRooms.isEmpty` and `cachedRooms` non-empty (`:506`) |
| Maps `HueLocalRoom` → `RoomDisplayItem` | `groupedLightID` ← `local.cachedGroupedLightID` (`:517`) |
| Maps `bridgeID` | `local.bridgeID` (`:519`) |
| Populates `allRooms` | Sorted by cached name (`:508-524`) |
| Populates `roomsByBridge` | Groups by `item.bridgeID` (`:529-535`) — **required** for `setRoom` / `turnAllOff` / `updateRoom` sync |
| Network | None |
| `loadAll` / entertainment / resource fetch | Not invoked |
| `rebuildAllRooms` / `scheduleWidgetWrite` | Not invoked on preload path |

**Narrowest fixture-seeding path:** In-memory `HueLocalRoom` with `cachedName`, `bridgeID`, `cachedGroupedLightID`, `lastIsOn`, `lastBrightness` → `preloadCached(from:)` → `#if DEBUG` `injectForTesting(clients:)` (`:352-354`).

Orphan `makeLocalRoom` (`OrchestratorTests.swift:350-356`) does **not** set `cachedGroupedLightID`; that is why the orphan optimistic test incorrectly depended on `loadAll()`.

## Current setRoom Production Flow

Source: `UnifiedOrchestrator.swift:719-741`.

```
setRoom(item, isOn: desiredState)
│
├─ isDemoMode? → updateRoom(id, isOn: desiredState); return
│
├─ guard groupedLightID + clients[bridgeID] else { return }  // no mutation
│
├─ updateRoom(item.id, isOn: desiredState)     // SYNCHRONOUS optimistic
├─ pendingActionDeadlines[glID] = now + 1.5s
│
└─ Task (unstructured):
    ├─ try await client.setGroupedLight(id: glID, on: desiredState)
    │   ├─ success → scheduleStateRefresh()      // delayed loadAll (+1.5s)
    │   └─ catch → updateRoom(id, isOn: !desiredState)  // rollback
    │              + log + showToast(...)
    └─ pendingActionDeadlines.removeValue(forKey: glID)
```

| Property | Assessment |
| --- | --- |
| Optimistic mutation timing | **Synchronous** via `updateRoom` before `Task` body runs |
| SSE guard | `pendingActionDeadlines` 1.5s window |
| Rollback semantics | Reverts to `!desiredState` (not captured prior value) — correct when toggling explicit desired state |
| Production edits for tests | **Not required** |

## Current scheduleStateRefresh Behavior

Source: `UnifiedOrchestrator.swift:869-876`, called from `setRoom` / `setBrightness` success paths only (`:732`, `:761`).

```
scheduleStateRefresh()
├─ pendingStateRefreshTask?.cancel()
└─ Task:
    ├─ sleep 1.5 seconds
    └─ await loadAll()   // unless cancelled
```

| Question | Answer |
| --- | --- |
| Can success-path refresh outlive a unit test? | **Yes** — 1.5s sleep then full `loadAll()` (network via injected client if still present) |
| Does failure path schedule refresh? | **No** |
| Can tests cancel `pendingStateRefreshTask`? | **No** — `private`; no test accessor |
| B3B mitigation | Prefer **API failure** for MUT-01 gate release; MUT-02 naturally uses failure path; do not complete MUT-01 with successful PUT |

`turnAllOff()` does **not** call `scheduleStateRefresh()`.

## Current turnAllOff Production Flow

Source: `UnifiedOrchestrator.swift:980-1006`.

```
turnAllOff() async
├─ allRooms = map { isOn = false }              // SYNCHRONOUS
├─ roomsByBridge[*] = map { isOn = false }      // SYNCHRONOUS
├─ log
└─ await withTaskGroup:
    └─ per room with groupedLightID:
        addTask { try? await client.setGroupedLight(id, on: false) }
```

| Property | Assessment |
| --- | --- |
| Optimistic timing | **Synchronous** before `await withTaskGroup` |
| `scheduleStateRefresh` | **Not called** |
| `rebuildAllRooms` / widget write | **Not called** on this path |
| `turnAllOff` is async | **Yes** — orphan test missing `await` is **stale/invalid** |
| Individual PUT errors | Swallowed (`try?`) |

## updateRoom Side-Effect Assessment

Source: `UnifiedOrchestrator.swift:1400-1436`.

| Side effect | Triggered by `updateRoom`? |
| --- | --- |
| `allRooms` / `allZones` map assignment | **Yes** — direct `@Observable` notification |
| `roomsByBridge` / `zonesByBridge` sync | **Yes** — per-bridge index update |
| `rebuildAllRooms()` | **No** |
| `scheduleWidgetWrite()` | **No** |
| `scheduleStateRefresh()` | **No** |

**Leakage risk for B3B:** Low for mutation assertions. Widget/watch delayed writes are **not** started by `setRoom` / `turnAllOff` optimistic paths alone. Delayed risk is **`scheduleStateRefresh` → `loadAll` → `rebuildAllRooms` → `scheduleWidgetWrite`** on **setRoom success only**.

## Typed Spy Feasibility

| Check | Status | Evidence |
| --- | --- | --- |
| `BridgeAPIClient` subclassing | **Available** | `BridgeAPIClient.swift:14` `class BridgeAPIClient` (non-final since B2B) |
| `setGroupedLight` overridable | **Yes** | `HueAPIClient.swift:362` `func setGroupedLight` — non-final on `class HueAPIClient` |
| `injectForTesting(clients:)` | **Yes** (Debug) | `UnifiedOrchestrator.swift:349-354` `#if DEBUG` |
| URLProtocol required | **No** | LoadAll slice proved typed override path |
| Keychain required | **No** | Spy uses `super.init(ip:token:)` like `OrchestratorLoadAllSpyBridgeClient` |
| Production Swift changes | **Not required** for spy path |

Precedent: `OrchestratorLoadAllTests.swift` — `OrchestratorLoadAllSpyBridgeClient` overrides fetch methods + `get`/`put`; same pattern for `setGroupedLight` only.

## Actor Recorder and Gate Assessment

| Component | Viable? | Role |
| --- | --- | --- |
| `OrchestratorOptimisticUpdateRecorder` (actor) | **Yes** | Records `(id, on)` PUT intents; `waitForCallCount(_:)` replaces blind sleeps |
| `OrchestratorGroupedLightGate` (actor) | **Yes** | Suspends `setGroupedLight` until `releaseSuccess()` / `releaseFailure()` |
| Prove optimistic before API completion | **Yes** | Gate holds after first `record`; synchronous `allRooms` already mutated |
| Teardown / release | **Yes** | `releaseFailure()` completes `setRoom` `Task` without scheduling `scheduleStateRefresh` |
| Forced failure for rollback test | **Yes** | Spy `throws` immediately — no gate required |
| Bounded eventual polling for rollback | **Acceptable** | Poll `allRooms[0].isOn` until `true` with short timeout (e.g. 2s, 10ms steps) — no fixed 300ms sleep |
| Production hook | **Not required** |
| UnifiedOrchestrator edit | **Not required** |

If gate complexity is undesirable for MUT-02 only, **immediate-throw spy** alone is sufficient.

## Strategy Comparison

| Rank | Strategy | Production edits | Test edits | Offline determinism | Task cleanup | Risk | Recommendation |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | **A — `preloadCached` + `cachedGroupedLightID` + typed spy + gate** | None | New `OrchestratorOptimisticUpdateTests.swift` (~3 tests) | High | Failure-path / gate release + `await` turnAllOff task | Low | **Recommended** |
| 2 | **B — Reuse loadAll typed fixtures** | None | Heavier setup per test | Medium | Entertainment GET + `rebuildAllRooms` + 500ms widget task | Medium | **Reject** — broader than needed |
| 3 | **C — DEBUG-only fixture injection hook** | Orchestrator API | New hook + tests | High | Depends on hook design | Medium | **Reject** — Strategy A sufficient |
| 4 | **D — Register/repair orphan file** | None | Edit `OrchestratorTests.swift` + whole-file membership | Low | URLProtocol races, sleeps, SSE shim CB | High | **Reject** |

### Strategy A fixture helper (B3B)

```swift
HueLocalRoom(roomID: "room-001", bridgeID: "bridge-1")
  .cachedName = "Bedroom"
  .cachedGroupedLightID = "gl-001"
  .lastIsOn = /* per test */
  .lastBrightness = 80
```

Then: `orchestrator.preloadCached(from: [room])` + `injectForTesting(clients: ["bridge-1": spy])`.

**preloadCached can seed `groupedLightID` routing:** **Yes**, when `cachedGroupedLightID` is set.  
**loadAll can be avoided:** **Yes**, for all three tests.

## Recommended IOS-TEST-003B3B Slice

**Task ID:** `IOS-TEST-003B3B — Recover Orchestrator optimistic update and turnAllOff tests`

| Decision | B3B recommendation |
| --- | --- |
| Production Swift changes needed? | **No** |
| DEBUG-only hook needed? | **No** (existing `injectForTesting` suffices) |
| `preloadCached` sufficient? | **Yes** (with `cachedGroupedLightID`) |
| `loadAll` avoidable? | **Yes** |
| URLProtocol avoidable? | **Yes** |
| Keychain avoidable? | **Yes** |
| Actor recorder recommended? | **Yes** |
| Actor gate recommended? | **Yes** for MUT-01 and MUT-03; optional for MUT-02 |
| Fixed sleep rejected? | **Yes** |
| Bounded eventual polling acceptable? | **Yes** (MUT-02 rollback observation) |
| Avoid success-path `scheduleStateRefresh`? | **Yes** (MUT-01 teardown via gate `releaseFailure`) |
| `turnAllOff` must be awaited? | **Yes** |
| Physical-device testing required? | **No** |
| Expected focused count | **3/3** (`OrchestratorOptimisticUpdateTests`) |
| Expected full signed-simulator count | **129/129** (126 existing + 3 new) |

## Proposed Test-Only Spy Contract

```swift
private actor OrchestratorOptimisticUpdateRecorder {
    struct Call: Equatable { let id: String; let on: Bool }
    private(set) var calls: [Call] = []
    func record(_ call: Call) { calls.append(call) }
    func waitForCallCount(_ count: Int, timeout: Duration = .seconds(2)) async throws { /* poll */ }
}

private actor OrchestratorGroupedLightGate {
    enum Resolution { case succeed, case fail(Error) }
    func suspendUntilReleased() async throws { /* wait on continuation */ }
    func releaseFailure(_ error: Error = OrchestratorOptimisticUpdateTestError.forcedFailure) { /* resume throwing */ }
    func releaseSuccess() { /* resume void — avoid in MUT-01 unless refresh drain planned */ }
}

private final class OrchestratorOptimisticUpdateSpyBridgeClient: BridgeAPIClient, @unchecked Sendable {
    let recorder: OrchestratorOptimisticUpdateRecorder
    var gate: OrchestratorGroupedLightGate?  // nil = immediate throw for rollback test

    override func setGroupedLight(id: String, on: Bool) async throws {
        await recorder.record(.init(id: id, on: on))
        if let gate { try await gate.suspendUntilReleased() }
        else { throw OrchestratorOptimisticUpdateTestError.forcedFailure }
    }
}
```

SUT factory: per-test `@MainActor makeOrchestratorOptimisticUpdateSUT()` — fresh `UnifiedOrchestrator`, no shared `setUp`/`tearDown` (matches B2B hygiene).

## Proposed Cached-Room Fixture

| Field | Value |
| --- | --- |
| `roomID` | `"room-001"` |
| `bridgeID` | `"bridge-1"` |
| `cachedName` | `"Bedroom"` |
| `cachedGroupedLightID` | `"gl-001"` |
| `lastIsOn` | per test (`false` / `true`) |
| `lastBrightness` | `80` |
| `isHidden` | `false` (default) |

Client injection: `["bridge-1": spy]` with spy `init(bridgeID:bridgeName:ip:token:recorder:gate:)`.

## Three-Test Recovery Matrix

| Test | Seed state | API resolution | Synchronization | Expected result | Leakage risk | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| **MUT-01** `testSetRoom_appliesOptimisticState_beforeAPICallCompletes` | `preloadCached` OFF room + `gl-001` + inject gated spy | Gate holds after record; **releaseFailure** in cleanup | Sync assert `isOn == true`; `await recorder.waitForCallCount(1)`; assert gate still pending; release failure; await task completion via recorder | Optimistic ON before PUT completes; PUT recorded `(gl-001, true)` | Low if failure teardown — **no** `scheduleStateRefresh` | Do not assert final ON (rollback → OFF) |
| **MUT-02** `testSetRoom_rollsBack_afterAPIError` | `preloadCached` ON room + inject throw spy (no gate) | Immediate `throw` from `setGroupedLight` | Sync assert OFF; bounded poll until ON; assert spy call OFF | Rollback restores ON | Low — no refresh; `showToast` 3s task benign | Replaces 300ms sleep |
| **MUT-03** `testTurnAllOff_appliesOptimisticState_beforeAPICallsComplete` | `preloadCached` ON (+ optional second room) + gated spy | Gate holds on first PUT | `let task = Task { await orchestrator.turnAllOff() }`; await recorder + gate hold; assert all OFF; release success; `await task.value` | Optimistic OFF before PUT completes; PUT `(gl-001, false)` | Low — no `scheduleStateRefresh`; success OK for turnAllOff | **Must** `await` turnAllOff task |

## Expected IOS-TEST-003B3B Changed Files

```text
DEVLOG.md
HueHome.xcodeproj/project.pbxproj
HueHomeTests/OrchestratorOptimisticUpdateTests.swift
```

No changes to `HueHome/Core/**`, `BridgeAPIClient`, or orphan `OrchestratorTests.swift`.

## Required Focused Validation

```bash
xcodebuild test \
  -project HueHome.xcodeproj \
  -scheme "HueHome 1" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HueHomeTests/OrchestratorOptimisticUpdateTests
```

**Expected:** `OrchestratorOptimisticUpdateTests` → **3/3** pass.

## Required Full Signed-Simulator Validation

Full `HueHomeTests` on signed simulator — **expected 129/129** after B3B (not claimed during B3A).

## Generic Build Requirement

After B3B implementation:

```bash
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" \
  -destination 'generic/platform=iOS' build
```

Debug + Release — **BUILD SUCCEEDED** (no production diff anticipated).

## Physical-Device Requirement Assessment

**Not required.** All three contracts are offline state-management behaviors provable with injected spies on simulator, consistent with IOS-TEST-003B / B2B.

## Warning-Hygiene Note

| File | Status |
| --- | --- |
| `OrchestratorCacheDemoTests.swift` | Preexisting `setUp()`/`tearDown()` + shared `orchestrator` → MainActor lifecycle warnings — **deferred** |
| `OrchestratorLoadAllTests.swift` | B2B fixed — per-test SUT factory, no lifecycle warnings from that slice |
| `OrchestratorOptimisticUpdateTests.swift` (future) | **Must** use per-test `@MainActor` SUT construction; **no** synchronous `setUp()`/`tearDown()` |

Warning debt cleanup remains a separate follow-up.

## Explicit Do-Not-Touch List

```text
HueHomeTests/OrchestratorTests.swift          # orphan — no membership, no repair
StubURLProtocol / shared static URL stubs
UnifiedOrchestrator / HueAPIClient / BridgeAPIClient behavior
scheme parallelization / signing / deployment targets
OrchestratorCacheDemoTests warning debt (this slice)
IOS-TEST-003B4 SSE orphan tests (separate slice)
```

## Deferred Recovery Work

| Slice | Scope |
| --- | --- |
| **IOS-TEST-003B4** (recommended name) | 3 SSE orphan tests + `testApplySSEEvent` shim removal / direct `applySSEEvent` access |
| Warning hygiene | `OrchestratorCacheDemoTests` lifecycle pattern alignment |
| DEVLOG B3 note | Prior entry listed “6 tests” for B3 — **correct B3B count is 3 mutation tests**; SSE is B4 |

## Open Questions

| Question | Resolution |
| --- | --- |
| Safe B3B without production edits? | **Yes** — typed spy + preloadCached |
| Must MUT-01 avoid success PUT? | **Yes** — or accept 1.5s `loadAll` refresh with no public cancel API |
| Multi-bridge turnAllOff coverage? | Single-room seed sufficient; optional second room low cost |
| `showToast` Task leakage? | Acceptable; does not affect `isOn` assertions |

---

### B3A explicit checklist (grounded claims)

| Claim | Answer |
| --- | --- |
| `preloadCached` seeds `groupedLightID` routing | **Yes**, via `cachedGroupedLightID` |
| `loadAll` avoidable | **Yes** |
| `BridgeAPIClient` subclassing available | **Yes** (non-final) |
| `setGroupedLight` overridable | **Yes** |
| URLProtocol should be avoided | **Yes** |
| Fixed sleeps rejected | **Yes** |
| Actor-backed gate viable | **Yes** |
| Rollback needs bounded eventual polling | **Yes** (unless test runs on MainActor with cooperative drain only — polling safer) |
| `scheduleStateRefresh` can leak from success paths | **Yes** (+1.5s → `loadAll`) |
| `turnAllOff` is async | **Yes** |
| Orphan `turnAllOff` test missing `await` | **Yes** |
| Production Swift edits required | **No** |
| DEBUG-only hook required | **No** |
| Physical-device testing required | **No** |
| Expected focused count (B3B) | **3/3** |
| Expected full-suite count (B3B) | **129/129** |
