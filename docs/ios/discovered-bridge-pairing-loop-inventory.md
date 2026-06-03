# Discovered-Bridge Pairing Loop Inventory

## Purpose

**IOS-BUG-001A** documents source-inspected discovery and pairing endpoint construction for the Android-MVP kickoff blocker: mDNS finds a Hue v2 bridge, but pairing initiated from the discovered result does not reliably complete, while manual IP entry followed by link-button press succeeds over HTTPS:443.

This inventory is **documentation-only**. It does not change Swift, Xcode project files, pairing behavior, or tests. **IOS-BUG-001B** implements the narrowest safe repair after physical DEBUG log capture (or equivalent proof).

| Field | Value |
| --- | --- |
| Branch | `ios-bug/discovered-bridge-pairing-loop-inventory` |
| Starting SHA | `88b71cb` |
| Readiness evidence | [`docs/ios/final-readiness-validation.md`](final-readiness-validation.md) |
| Android contract | [`docs/android/android-mvp-contract-freeze.md`](../android/android-mvp-contract-freeze.md) |

---

## Physical Regression Evidence

**Proven (IOS-OPS-FINAL-B, 2026-06-03, two Hue v2 bridges):**

| ID | Result | Observation |
| --- | --- | --- |
| IOS-FINAL-PHYS-003 | PARTIAL | mDNS finds and displays the bridge; discovered-result handoff does not reliably complete pairing |
| IOS-FINAL-PHYS-006 | FAIL | Link-button pairing loops when initiated from the discovered result |
| IOS-FINAL-COND-003 | PASS | Manual IP + physical link button pairs over HTTPS:443 |
| IOS-FINAL-PHYS-004 | PASS | Manual IP path reaches bridge-found / pair UI |
| IOS-FINAL-PHYS-005 | PASS | Type **101** (link button not pressed) shows retryable state on manual path |
| IOS-FINAL-PHYS-007 | PASS | Credentials persist after force-close (when pairing completed via manual path) |

**Also proven (automated baseline, unchanged by this task):** metadata tests 21/21, verifier 17/17, unsigned Debug/Release builds, signed-simulator **132/132** `HueHomeTests`.

**Android MVP kickoff:** remains **blocked** until discovered-result pairing succeeds on physical Hue v2 hardware without manual IP entry.

---

## Known and Unknown Runtime Facts

### Known (physical + source)

- mDNS `_hue._tcp` discovery displays at least one Hue v2 bridge on LAN.
- Discovered-result pairing is unreliable / loops per PHYS-006.
- Manual IP hardcodes port **443** in `BridgeSetupView`; pairing uses HTTPS and `BridgeCertTrustDelegate` on that path (COND-003 PASS).
- Pairing scheme is selected strictly from `bridge.port == 443` → `https`, else `http` (`BridgeDiscoveryViewModel`).
- mDNS resolution preserves `port.rawValue` from `NWConnection.currentPath.remoteEndpoint` hostPort (no normalization to 443).
- Bridge IP is written to Keychain on mDNS resolve **before** pairing completes.
- Type **101** returns to `.bridgeFound` for retry; URLSession/network failures call `handleError` → `.error` (not a silent retry loop by themselves).
- Two Hue v2 bridges were available in the physical pass; legacy HTTP:80 bridge was not available (COND-002 NOT TESTED).

### Unknown (require DEBUG log capture — do not guess)

- Exact mDNS-resolved **port** for each failing discovered result.
- Exact pairing URL (`scheme://host:port/api`) used on the failing discovered flow.
- Whether failure is HTTP status, bridge JSON error (including 101), URLSession/TLS error, or UI/state oscillation users perceive as a “loop”.
- Whether both physical v2 bridges advertise the same mDNS SRV port.
- Whether NUPnP fallback was involved in failing runs (not isolated in FINAL-B).

---

## Discovery Endpoint Construction

**Source:** `HueHome/Core/Network/BridgeDiscoveryService.swift`

| Topic | Behavior |
| --- | --- |
| mDNS service type | `_hue._tcp` |
| Domain | `local.` |
| LAN-only | `NWParameters.includePeerToPeer = false` |
| IPv4 forcing | `NWProtocolIP.Options.version = .v4` on resolve `NWConnection` (avoids link-local IPv6 zone IDs in URLs) |
| Resolution mechanism | Per added browse result: `resolveEndpoint` → `NWConnection(to: endpoint, using: tcp+v4)` → on `.ready`, read `connection.currentPath?.remoteEndpoint` |
| Host normalization | `hostString(from:)` strips `%zone` suffix from NW host debug strings |
| Port source | `port.rawValue` from `.hostPort(let host, let port)` — **preserved as discovered**; no rewrite to 443 |
| Port normalization | **None** |
| Host persisted before pairing | **Yes** — `KeychainManager.shared.saveBridgeIP(hostString)` immediately after resolve |
| Endpoint equality / dedup | `guard !discoveredBridges.contains(bridge)` uses synthesized `Equatable` on `BridgeEndpoint` (includes `id`) |
| Duplicate accumulation | Same logical bridge resolved again creates a **new** `UUID()` → typically **not** equal to prior entry; duplicates possible; removal on mDNS `.removed` matches **name** only |

**Log lines (source):** `Bridge resolved! Name: '…' | IP: … | Port: …`

---

## Pairing Endpoint Construction

**Source:** `HueHome/Core/ViewModels/BridgeDiscoveryViewModel.swift`

| Step | Behavior |
| --- | --- |
| mDNS handoff | `discovery.$discoveredBridges` → first non-empty → `compactMap { $0.first }` → `.first()` publisher → stop scan → `phase = .bridgeFound(bridge)` (first list element only, once per scan) |
| Pairing URL | `\(scheme)://\(bridge.host):\(bridge.port)/api` |
| Scheme | `bridge.port == 443 ? "https" : "http"` (in both `pairWithBridge` and `performPairingRequest`) |
| Certificate delegate | Custom `URLSession` with `BridgeCertTrustDelegate` **only when** `bridge.port == 443`; else `URLSession.shared` |
| Timeout | 10 s `URLRequest` |
| Body | `devicetype` from `AppBrand.hueDeviceType`, `generateclientkey: true` |
| Success | Keychain token + bridge IP; `phase = .paired` |
| Error 101 | Log + `phase = .bridgeFound(bridge)` (retry) |
| Other bridge errors | Log + `phase = .bridgeFound(bridge)` for non-101 via same branch (returns to bridgeFound) |
| URLSession / decode errors | `handleError` → `phase = .error` |

**UI:** `BridgeSetupView` calls `vm.pairWithBridge(bridge)` from discovered and manual paths identically; manual path does not display port in the bridge-found pill (host + name only).

---

## mDNS vs NUPnP vs Manual-IP Comparison

| Path | Host source | Port source | Scheme selection | Certificate delegate | Physical result |
| --- | --- | --- | --- | --- | --- |
| mDNS discovered result | `NWConnection` `currentPath.remoteEndpoint` hostPort → `hostString` | SRV/A resolved `port.rawValue` (preserved) | `port == 443` → HTTPS, else HTTP | Only if port == 443 | PHYS-003 PARTIAL; PHYS-006 FAIL (discovered pairing unreliable / loops) |
| NUPnP fallback | `internalipaddress` from `https://discovery.meethue.com/api/nupnp` | `UInt16(first.port ?? 443)` | Same port rule | Same port rule | Not isolated in FINAL-B (COND-001 NOT TESTED) |
| Manual IP | User-entered IPv4 trim | **Hardcoded `443`** in `BridgeSetupView` | HTTPS | `BridgeCertTrustDelegate` | PHYS-004 PASS; COND-003 PASS; reliable workaround |

---

## Source-Grounded Primary Hypothesis

**Status: hypothesis only — not proven without runtime logs.**

Two construction paths may diverge on **port and transport** for the same Hue v2 bridge:

```text
mDNS:  resolve → BridgeEndpoint(host, port from Bonjour/SRV, often 80 on some bridges)
       → pairing may use http://host:80/api without cert delegate

Manual: BridgeEndpoint(host, port: 443)
        → pairing uses https://host:443/api with BridgeCertTrustDelegate
```

Source comment in `BridgeDiscoveryService` notes bridges may advertise port 80 / 443. `BridgeDiscoveryViewModel` treats non-443 as HTTP without self-signed cert trust. Manual-IP success on v2 hardware is consistent with this hypothesis but **does not confirm** discovered port was 80 until DEBUG logs show `Port:` and `POST scheme://…` lines.

**IOS-BUG-001B must not** normalize or rewrite discovered ports until log capture confirms the failing transport difference (or a safer boundary is proven by inspection alone).

---

## Secondary Findings

1. **First-bridge wins:** mDNS auto-handoff uses `discoveredBridges.first`, not user selection when multiple bridges resolve.
2. **Early Keychain IP write:** Resolved host is saved before pairing success; manual path saves IP again on success. Unlikely sole cause of loop but affects credential state during failed discovered attempts.
3. **Error-path asymmetry:** Type 101 → `.bridgeFound`; network failure → `.error`. User “loop” may combine 101 retries, scan again, or error → try again flows.
4. **NUPnP default port 443:** Cloud fallback aligns with manual IP; mDNS path alone may be the outlier.
5. **No port in UI:** Operators cannot see discovered port without DEBUG log.
6. **Removal dedup by name only:** Differs from append dedup semantics (UUID-based `contains`).

---

## Duplicate-Endpoint Equality Assessment

```swift
struct BridgeEndpoint: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let host: String
    let port: UInt16
}
```

Swift-synthesized `Equatable` includes **`id`**. The dedup guard `!discoveredBridges.contains(bridge)` therefore does **not** treat two endpoints with the same name/host/port as duplicates. Re-resolution can append multiple entries; handoff still uses `.first`.

**Relevance to pairing loop:** Low direct evidence, but can cause wrong bridge ordering with multiple LAN bridges. Not expanded as primary fix scope unless logs show multi-bridge confusion.

---

## Existing Test Coverage

| Area | Status |
| --- | --- |
| `BridgeDiscoveryService` / mDNS | **No** dedicated unit tests in `HueHomeTests` |
| `BridgeDiscoveryViewModel` / pairing | **No** dedicated tests |
| `BridgeEndpoint` / port-scheme selection | **Not** covered |
| `BridgeCertTrustDelegate` | **Not** covered |
| `URLProtocol` stub | **Yes** — `StubURLProtocol` in `HueHomeTests/HueAPIClientTests.swift`, `OrchestratorTests.swift` for **CLIP v2** `HueAPIClient` only |
| Pairing transport choice | **Testable in principle** via extracted helper + `URLProtocol`; **not** testable today without refactor — pairing is `private` in ViewModel, no existing pairing stub |
| Physical Hue pairing | Required for signoff; not automated |

---

## Physical DEBUG Log-Capture Packet

Run on **Debug** build on Brian’s iPhone before **IOS-BUG-001B** implementation.

1. Run Debug build; open bridge setup.
2. Expand **DEBUG** log panel (`BridgeSetupView`).
3. Start mDNS discovery (Scan for Bridge).
4. Select / wait for discovered Hue v2 bridge (bridge-found UI).
5. Tap **Pair** once **before** pressing link button.
6. Press physical link button.
7. Tap **Pair** again.
8. Copy discovered-flow log lines.
9. **Reset** setup (`resetToIdle` / Scan Again flow).
10. **Enter same bridge IP manually**; Connect.
11. Repeat pairing steps 5–7.
12. Copy manual-flow log lines.
13. Repeat discovered flow for second Hue v2 bridge if practical.

**Required log evidence lines:**

- `Bridge resolved! Name: … | IP: … | Port: …`
- `Bridge found via mDNS: … @ host:port`
- `Attempting pairing POST to scheme://host:port/api`
- `POST scheme://host:port/api`
- `HTTPS mode — using Bridge certificate trust delegate.` (if HTTPS)
- `HTTP {code}` / `Raw response:` / `Network error:` / type **101** / `Paired!` as applicable

---

## Log-Capture Table

| Capture | Bridge | Discovered host | Discovered port | Pairing URL | Result | Error / response | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| mDNS flow | v2 bridge A | | | | | | Fill from DEBUG log |
| manual-IP flow | v2 bridge A | (same IP) | `443` | | | | Expect HTTPS + cert delegate |
| mDNS flow | v2 bridge B | | | | | | If practical |
| manual-IP flow | v2 bridge B | (same IP) | `443` | | | | Regression check |

---

## Repair Strategy Comparison

| Rank | Strategy | Compatibility | Testability | Runtime risk | Recommendation |
| --- | --- | --- | --- | --- | --- |
| 1 | **Log capture first** (no code change) | N/A | Enables evidence-based fix | None | **Required before port/scheme changes** |
| 2 | **C — `pairingCandidates(for:)` policy helper** | Can try discovered then HTTPS:443; keep HTTP:80 for legacy | High if pure Swift + unit tests | Medium — ordering, duplicate POSTs, 101 semantics | **Preferred implementation shape after logs confirm transport mismatch** |
| 3 | **B — Ordered pairing attempts inline** | Same as C without extraction | Lower until extracted | Medium — duplicate requests during link window | Acceptable if C is deferred one commit |
| 4 | **E — UI-only handoff normalize to 443** | May fix v2; bypasses true discovered port | Low | Hides mDNS truth; NUPnP/mDNS inconsistency | Only if logs prove port-only issue and policy accepts hiding port |
| 5 | **A — Always normalize discovered to HTTPS:443** | Breaks HTTP:80 legacy if still on LAN | Medium | High without generation policy | **Not safe** as first repair |
| 6 | **D — Pre-probe transport before Pair UI** | Broad | Hard | High — new state machine | **Too broad** for first repair |

---

## Recommended IOS-BUG-001B Boundary

1. **Execute physical DEBUG log-capture packet** (this document). Compare discovered vs manual `Port:` and `POST` URLs for both v2 bridges.
2. **If logs confirm** discovered port ≠ 443 while manual uses HTTPS:443 → implement **Strategy C** (minimal `pairingCandidates(for:)` or equivalent) in `BridgeDiscoveryViewModel` only:
   - Try discovered endpoint first (preserve legacy HTTP:80 behavior).
   - On transport-appropriate failure, try **HTTPS:443** for same host (local Hue v2 policy).
   - Do **not** change Keychain, REST, SSE, or `BridgeDiscoveryService` mDNS resolution in the first commit unless logs require it.
3. **If logs contradict** port/scheme hypothesis → re-inventory failure mode (101 loop vs `.error` vs TLS) before any normalization.
4. **Do not** ship Strategy A (blanket 443 normalize) without legacy-bridge policy and COND-002 hardware.

**Log-capture-first conclusion:** IOS-BUG-001B should start with Brian’s DEBUG log table filled; implementation boundary above applies once transport difference is confirmed.

---

## Proposed Automated Test Matrix (IOS-BUG-001B)

| Test | Class |
| --- | --- |
| Discovered endpoint port 443 → scheme HTTPS | Pure unit (helper or package-visible seam) |
| Port 443 → pairing uses cert-delegate session path (mock delegate flag or injected factory) | Pure unit / small integration |
| Port 80 → scheme HTTP, shared session (no delegate) | Pure unit |
| Manual IP remains port 443 / HTTPS | Pure unit (construct `BridgeEndpoint` as UI does) |
| Type 101 → returns to retryable `bridgeFound` | Pure unit on state transition helper |
| Successful pairing persists token and host (mock Keychain) | Offline integration |
| `pairingCandidates` ordering: discovered then 443 fallback | Pure unit |
| Candidate fallback does not double-success POST | Unit / URLProtocol if extracted |

**Physical Hue:** PHYS-003, PHYS-006, COND-003 after fix.

Broad UI automation is **not** required unless extraction blocks unit testing.

---

## Required Physical Re-Test

After IOS-BUG-001B fix, re-run:

| ID | Scenario |
| --- | --- |
| IOS-FINAL-PHYS-003 | mDNS discovery and discovered-result handoff |
| IOS-FINAL-PHYS-005 | Link-button-not-pressed retry (discovered path) |
| IOS-FINAL-PHYS-006 | Successful link-button pairing **from discovered result** |
| IOS-FINAL-PHYS-007 | Credential persistence after relaunch |
| IOS-FINAL-COND-003 | Manual-IP HTTPS:443 regression |
| IOS-FINAL-COND-004 | Two bridges registered |

Android MVP kickoff remains blocked until discovered-result pairing succeeds without manual IP.

---

## Explicit Do-Not-Touch List (IOS-BUG-001B unless explicitly scoped)

- `UnifiedOrchestrator`, REST v2 client, SSE, cache, demo mode, optimistic updates
- Keychain schema / multi-bridge migration behavior (except if pairing success path bug found)
- `BridgeDiscoveryService` mDNS browser (unless logs require resolution change)
- Xcode project, signing, entitlements, bundle ID, deployment targets
- Android docs / Kotlin
- Composer, Studio, widgets, watch

---

## Android-MVP Kickoff Impact

Per [`docs/android/android-mvp-contract-freeze.md`](../android/android-mvp-contract-freeze.md), Android copies **current native iOS behavior** as parity anchor. Discovered-bridge pairing is a required first-run flow in the freeze hardware checklist. **Kotlin/Gradle MVP start remains blocked** until IOS-BUG-001B repair and PHYS-003 / PHYS-006 physical PASS without manual IP workaround.

---

## Open Questions

1. What mDNS SRV port do Brian’s two v2 bridges advertise on LAN?
2. Does discovered pairing fail with HTTP 4xx/bridge JSON, TLS error, or repeated 101?
3. Is the user-visible “loop” `.bridgeFound` ↔ `.pairing` with 101, or `.error` ↔ retry?
4. Does NUPnP path (port default 443) pair successfully when mDNS is slow-blocked?
5. Should UI show host:port in bridge-found pill for supportability?
6. Should Keychain IP write wait until pairing success?

---

*Inventory complete — IOS-BUG-001A. No Swift or project changes.*
