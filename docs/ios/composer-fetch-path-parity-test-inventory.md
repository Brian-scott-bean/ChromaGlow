# Composer Fetch-Path Parity Test Inventory

## Purpose

Inventory the remaining **orchestration-level** I/O contracts for Composer child-resource resolution in `UnifiedOrchestrator` after IOS-REF-006B extracted deterministic matching into `CompositionLightResolver`. Determine the narrowest safe approach for **IOS-TEST-002B** to add regression coverage for **when** `api.fetchLights()` runs and **what** the orchestrator returns on success/failure—without changing runtime behavior, moving I/O, widening release API surface unnecessarily, or driving full `startCompositionMode` startup.

**Slice:** IOS-TEST-002A (documentation only). **Out of scope:** implementing tests, Swift edits, Xcode project edits, IOS-TEST-002B implementation.

## Current Baseline

| Item | Value |
| --- | --- |
| Working branch | `ios-test/composer-fetch-path-parity-inventory` |
| Starting SHA | `87432b3` |
| `origin/main` at inventory time | `87432b3` (0 ahead / 0 behind) |
| `UnifiedOrchestrator.swift` size | 3,197 lines |
| Pure resolver tests | `CompositionLightResolverTests` → 16/16 (in `HueHomeTests` target) |
| Related pure tests | `CompositionRoomPriorityScorerTests` 19/19, `RoomAndZoneDisplayModelBuilderTests` 6/6, `DashboardDisplayModelBuilderTests` 14/14 |
| Signed-simulator `HueHomeTests` | **109/109** (count matches **nine** test files in `HueHome.xcodeproj`; see membership note below) |
| IOS-REF-006B | Merged; physical-device Composer smoke pass recorded in `DEVLOG.md` |
| Prior pure-seam inventory | `docs/ios/composer-light-resolution-pure-seam-inventory.md` |

## Relevant Live Production Paths

### Call graph (Composer startup)

`startCompositionMode(room:paramBox:…)` (`UnifiedOrchestrator.swift` ~1674) is the sole production caller of both fetch-path helpers:

1. **Gamut** — `resolveCompositionGamut(for:api:)` (~1694–1699, ~2262–2277), unless `gamutOverride` is passed.
2. **Light IDs** — `resolveCompositionLightIDs(for:api:)` (~1713, ~2280–2298).
3. **Out of IOS-TEST-002B scope** — `resolveEntertainmentLightPositions(config:api:)` (~1725, ~2308+) performs parallel `api.get(…/entertainment)` + `api.fetchLights()`; not part of the parity matrix for this slice.

### Delegation boundary (IOS-REF-006B)

After fetch (when required), both helpers delegate child-resource matching to `CompositionLightResolver` (`HueHome/Core/Composer/CompositionLightResolver.swift`). Gamut **majority selection** and **implicit tie behavior** remain **inline** in `resolveCompositionGamut`.

## Existing Test Infrastructure

### Offline networking

| Component | Location | Role |
| --- | --- | --- |
| `StubURLProtocol` | `HueHomeTests/HueAPIClientTests.swift` | Path-keyed stub responses; 404 when unmatched |
| `TestableAPIClient` | same file | Subclasses `HueAPIClient`; overrides `credentials()`, `get`, `put`; uses stub session |
| `TestableBridgeAPIClient` | `HueHomeTests/OrchestratorTests.swift` | Subclasses `final class BridgeAPIClient`; overrides `credentials()`, `get`, `put` |

`HueAPIClient.fetchLights()` is **not** overridden by `TestableAPIClient`; it uses inherited implementation → `credentials()` + `get("/clip/v2/resource/light", …)`. Stubbing `/clip/v2/resource/light` exercises decode paths (`HueAPIClientTests.testFetchLightsDecodesCorrectly`).

### Orchestrator test hooks

| Hook | Access | Guard | Notes |
| --- | --- | --- | --- |
| `injectForTesting(clients:)` | `UnifiedOrchestrator` | `#if DEBUG` | Replaces `clients` map; used by orchestrator tests |
| `testApplySSEEvent(_:bridgeID:)` | extension in `OrchestratorTests.swift` | **None** (calls **internal** `applySSEEvent`) | Precedent for test-only forwarding; not applicable to **private** fetch helpers |
| `resolveCompositionGamut` / `resolveCompositionLightIDs` | `private` | — | **Not** callable via `@testable import` |

`HueAPIClient` is a non-`final` `class`; `fetchLights()` is overridable from the test module with `@testable import HueHome`.

### Target membership inconsistency (important)

| File on disk | In `HueHomeTests` `project.pbxproj` Sources? |
| --- | --- |
| `HueAPIClientTests.swift` | Yes |
| `CompositionLightResolverTests.swift` | Yes |
| `OrchestratorTests.swift` | **No** |

`OrchestratorTests.swift` defines 15 `test*` methods and `TestableBridgeAPIClient`, but has **no** `PBXBuildFile` / `PBXFileReference` entry. The validated **109/109** suite equals the sum of tests in the **nine** member files (124 total on disk − 15 orchestrator = 109). IOS-TEST-002B must add `ComposerFetchPathParityTests.swift` to the target explicitly; do not assume orchestrator tests are already running.

### Private helper access today

| Method | `@testable` access | Notes |
| --- | --- | --- |
| `resolveCompositionGamut(for:api:)` | **No** (`private`) | Requires DEBUG wrapper or `private` → `internal` widening |
| `resolveCompositionLightIDs(for:api:)` | **No** (`private`) | Same |
| `applySSEEvent` | **Yes** (`internal`) | Already used via `testApplySSEEvent` shim |

## Current Fetch-Path Contracts

| Path | Condition | `fetchLights` count | Success result | Failure result | Notes |
| --- | --- | ---: | --- | --- | --- |
| `resolveCompositionLightIDs` | `childResourceRefs` empty | **0** | `[]` | — | Early `guard !refs.isEmpty` (~2282) |
| `resolveCompositionLightIDs` | Any `rtype == "light"` (direct mode) | **0** | Ref-order light IDs; duplicates preserved; non-light refs ignored | — | Delegates with `lights: []` (~2285–2289) |
| `resolveCompositionLightIDs` | Mixed light + device refs | **0** | Direct-mode IDs only | — | `hasDirectLightReferences` short-circuit |
| `resolveCompositionLightIDs` | Device-owner path | **1** | IDs in **fetched** light-array order | `[]` | `try? await api.fetchLights()` (~2293–2297) |
| `resolveCompositionGamut` | Any room (including empty refs) | **1** always | Majority `HueColorUtils.Gamut` from resolved lights | `.c` | Always fetches first (~2263); no empty-ref early return at orchestrator |
| `resolveCompositionGamut` | Fetch succeeds, resolved lights empty | **1** | `.c` | — | e.g. non-matching refs (~2269) |
| `resolveCompositionGamut` | Fetch fails (`try?` nil) | **1** (attempted) | — | `.c` | (~2263) |
| `resolveCompositionGamut` | Resolved lights present, no valid `gamut_type` | **1** | Implicit tie among `.a`/`.b`/`.c` at count 0 | — | **Not** the empty-lights `.c` path; `counts.max(by:)` on zero counts (~2270–2276) |

**Gamut majority / tie (unchanged, inline):** Count per `HueColorUtils.Gamut` from `light.color?.gamut_type?.uppercased()`; skip invalid/missing. Return `counts.max(by: { $0.value < $1.value })?.key ?? .c`. Equal non-zero counts and all-zero counts depend on `Dictionary` iteration order—**implicit**, not domain-documented. IOS-TEST-002B should pin **fetch count + branch fallbacks**, not redefine tie policy.

## Strategy Comparison

| Rank | Strategy | Production edits | Test edits | Runtime fidelity | Risk | Recommendation |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | **DEBUG-only wrappers** delegating to existing `private` methods | Minimal: `#if DEBUG` forwards in `UnifiedOrchestrator` | New `ComposerFetchPathParityTests.swift` + spy `HueAPIClient` subclass | **High** — exercises real orchestrator branches | **Low** — wrappers compile out of Release; no logic change | **Recommended for IOS-TEST-002B** |
| 2 | **Spy `HueAPIClient`** (`override fetchLights`) + wrappers | Same as #1 | Spy in test file; optional `StubURLProtocol` only if testing real HTTP stack | **High** for I/O policy; resolver still tested elsewhere | Low | **Recommended** (pair with #1) |
| 3 | `private` → `internal` widening | Access change on two methods | `@testable` direct calls | High | Medium — exposes helpers module-wide in all configs | **Rejected** — DEBUG wrappers are narrower |
| 4 | `startCompositionMode` integration tests | None / heavy indirect | Inject client + call public API | Low for isolated fetch policy | **High** — generation, scheduler, entertainment, mic, tasks | **Rejected** for fetch-parity slice |
| 5 | New production fetch-policy helper | Refactor / move I/O | Easier tests | Medium | Medium — behavior drift risk | **Rejected** — not needed for parity |
| 6 | `StubURLProtocol` only (no spy) | None | Stub `/clip/v2/resource/light` | Medium — counts HTTP not method calls | Medium — indirect counting | **Optional**, not necessary if spy overrides `fetchLights` |
| 7 | Source-text / grep assertions | None | Fragile string tests | None | High | **Rejected** |

### Option 1 detail — why `startCompositionMode` is too broad

Calling `startCompositionMode` for fetch parity would also trigger, among other effects: `compositionGenerations` mutation, `findEntertainmentConfig`, possible `resolveEntertainmentLightPositions` (extra `fetchLights` + `get`), transport selection (DTLS / bridge-stored / REST), `compositionEntTasks` / `compositionRuntimes`, prime frames, `CompositionMicCapture`, and mailbox/scheduler activity. Teardown would be required to avoid test pollution. **Unsuitable** for a narrow fetch-count matrix.

### Option 2 detail — DEBUG wrappers vs `testApplySSEEvent`

`injectForTesting` is already `#if DEBUG` in production (~349–355). A matching pattern for fetch helpers:

```swift
#if DEBUG
func testResolveCompositionGamut(
    for room: RoomDisplayItem,
    api: HueAPIClient
) async -> HueColorUtils.Gamut {
    await resolveCompositionGamut(for: room, api: api)
}

func testResolveCompositionLightIDs(
    for room: RoomDisplayItem,
    api: HueAPIClient
) async -> [String] {
    await resolveCompositionLightIDs(for: room, api: api)
}
#endif
```

Place adjacent to `injectForTesting`. **Release behavior:** compiled out; **no** runtime change in App Store builds. **Not added in IOS-TEST-002A.**

## Recommended IOS-TEST-002B Slice

**Proceed with IOS-TEST-002B** — one bounded slice:

1. Add the two `#if DEBUG` wrappers above to `UnifiedOrchestrator.swift` (forward-only; no body changes).
2. Add `HueHomeTests/ComposerFetchPathParityTests.swift` with a **test-only** `HueAPIClient` subclass that overrides `fetchLights()` to increment a counter and return fixtures or throw.
3. Register the new test file in `HueHome.xcodeproj/project.pbxproj`.
4. Append `DEVLOG.md` entry after validation.

**Do not:** call `startCompositionMode`, change `CompositionLightResolver`, change `HueAPIClient`/`BridgeAPIClient`, widen `private` methods, add production abstractions, or require a physical bridge.

**URLProtocol:** **Not necessary** if the spy overrides `fetchLights()` directly.

**Physical device:** **Not required** for IOS-TEST-002B (offline unit tests).

## Proposed DEBUG-Only Test Hooks

See snippet in **Strategy Comparison** (#1). Signatures accept injected `HueAPIClient` so tests pass a spy without `injectForTesting` or bridge configuration.

## Proposed Test-Only Spy Client

Live entirely in `ComposerFetchPathParityTests.swift` (name illustrative):

```swift
final class ComposerFetchCountingAPIClient: HueAPIClient {
    private(set) var fetchLightsCallCount = 0
    var stubLights: [HueLight] = []
    var shouldThrow = false

    override func fetchLights() async throws -> [HueLight] {
        fetchLightsCallCount += 1
        if shouldThrow { throw HueAPIError.httpError(500) }
        return stubLights
    }
}
```

**Fixture helpers** (same file): `makeRoom(childResourceRefs:…)`, `makeLight(id:ownerRID:gamutType:)` mirroring `CompositionLightResolverTests` patterns; include `LightColor(xy: CIExy(x: 0.3, y: 0.3), gamut_type:)` for gamut cases.

**Failure simulation:** `shouldThrow = true` → `try?` in orchestrator → gamut `.c` / IDs `[]` without stubbing HTTP.

## Required Parity Matrix

| Test | Refs | Spy response | Expected fetch count | Expected result | Hook required |
| --- | --- | --- | ---: | --- | --- |
| ID-01 empty refs | `[]` | (n/a) | **0** | `[]` | Yes |
| ID-02 direct refs | `[("L2","light"),("L1","light"),("L2","light")]` | default | **0** | `["L2","L1","L2"]` | Yes |
| ID-03 mixed refs | light + device | default | **0** | direct IDs only | Yes |
| ID-04 owner success | device refs | lights with matching `owner.rid` | **1** | IDs in stub array order | Yes |
| ID-05 owner failure | device refs | `shouldThrow = true` | **1** | `[]` | Yes |
| GAM-01 direct + majority | light refs | lights with gamut A/B mix | **1** | majority gamut (e.g. two A, one B → `.a`) | Yes |
| GAM-02 owner + majority | device refs | owner-matched lights + gamuts | **1** | majority gamut | Yes |
| GAM-03 fetch failure | any non-empty | throw | **1** | `.c` | Yes |
| GAM-04 empty resolved | non-matching refs | `stubLights: []` or no matches | **1** | `.c` | Yes |

**Optional grounded edge (document only unless pinning tie policy later):**

| Test | Refs | Spy | Count | Result | Notes |
| --- | --- | --- | ---: | --- | --- |
| GAM-05 invalid gamut types | light refs | lights with `color: nil` | **1** | one of `.a`/`.b`/`.c` via zero-count max | Implicit tie; defer explicit assert unless product pins policy |

**Per-case requirements:**

- **Room fixture:** `RoomDisplayItem` with `childResourceRefs` set; `bridgeID` / `groupedLightID` arbitrary (wrappers do not read them).
- **Hook:** DEBUG wrappers required (private methods).
- **URLProtocol:** No.
- **Task teardown:** No (no Composer scheduler).
- **`injectForTesting`:** Not required.

## Expected IOS-TEST-002B Changed Files

| File | Change |
| --- | --- |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | `#if DEBUG` test wrappers only |
| `HueHomeTests/ComposerFetchPathParityTests.swift` | New parity tests + spy client |
| `HueHome.xcodeproj/project.pbxproj` | Add test file to `HueHomeTests` Sources |
| `DEVLOG.md` | Post-validation entry |

**Not expected:** `CompositionLightResolver.swift`, `HueAPIClient.swift`, `OrchestratorTests.swift` (unless separately deciding to register orphaned orchestrator tests—out of scope for fetch parity).

## Required Focused Test Validation

```bash
xcodebuild test \
  -project HueHome.xcodeproj \
  -scheme "HueHome 1" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HueHomeTests/ComposerFetchPathParityTests
```

Expect **8** core cases (matrix above) passing; counter assertions on `fetchLightsCallCount`.

## Required Full Signed-Simulator Validation

```bash
xcodebuild test \
  -project HueHome.xcodeproj \
  -scheme "HueHome 1" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HueHomeTests
```

Expect **109 + N** tests passing (N = new parity tests, likely 8 → **117/117** if orchestrator file remains unlinked).

## Physical-Device Requirement Assessment

| Slice | Physical device |
| --- | --- |
| IOS-TEST-002A (this inventory) | **Not required** |
| IOS-TEST-002B (proposed unit tests) | **Not required** — offline spy + DEBUG wrappers |
| Composer regression generally | IOS-REF-006B smoke already recorded; repeat only when changing transport/runtime, not fetch-count policy |

## Explicit Do-Not-Touch List

- `CompositionLightResolver` behavior
- Gamut majority / tie logic inline in `resolveCompositionGamut`
- `resolveEntertainmentLightPositions` (separate fetch contract)
- `startCompositionMode` transport, scheduler, mailbox, generation guards
- `fetchLights()` implementation in `HueAPIClient`
- Cadence quartet (`minimumComposerRESTInterval`, etc.) — IOS-REF-004A unwired
- SSE, Keychain, DTLS, bridge-stored animation, Studio/Composer UI

## Deferred Areas

- Entertainment position mapping (`resolveEntertainmentLightPositions`) — parallel `get` + `fetchLights`
- Gamut tie-break policy extraction / explicit domain rules
- Registering `OrchestratorTests.swift` in Xcode (15 tests currently orphaned on disk)
- `StudioViewModel` parallel `resolveLightIDs` / gamut paths (duplicate policy, not orchestrator)
- Physical-device Composer smoke for fetch-parity-only changes

## Open Questions

1. **Orphan `OrchestratorTests.swift`:** Should a separate hygiene slice add it to `HueHomeTests` (109 → 124), or leave it out intentionally?
2. **GAM-05:** Assert implicit zero-count gamut tie in IOS-TEST-002B, or defer until gamut policy is pinned (per IOS-REF-006B DEVLOG)?
3. **Simulator name:** CI/local may use a different destination than `iPhone 16`; adjust destination string only at test run time.
