# Discovered-Bridge Pairing Loop Inventory

## Purpose

**IOS-BUG-001A** documents source-inspected discovery and pairing endpoint construction for the Android-MVP kickoff blocker. **IOS-BUG-001A2** records physical DEBUG log evidence and corrects the diagnosis: the defect is **multi-bridge auto-selection**, not a confirmed port/scheme mismatch on tested Hue v2 hardware.

This inventory is **documentation-only**. **IOS-BUG-001B** implements the narrowest safe repair: discovered-bridge **selection** before pairing.

| Field | Value |
| --- | --- |
| Branch (inventory) | `ios-bug/discovered-bridge-pairing-loop-inventory` |
| Evidence capture (001A2) | `ios-bug/discovered-bridge-pairing-loop-log-capture` |
| Starting SHA | `88b71cb` |
| Readiness evidence | [`docs/ios/final-readiness-validation.md`](final-readiness-validation.md) |
| Android contract | [`docs/android/android-mvp-contract-freeze.md`](../android/android-mvp-contract-freeze.md) |

---

## Physical Regression Evidence

**Proven (IOS-OPS-FINAL-B, 2026-06-03):**

| ID | Result | Observation |
| --- | --- | --- |
| IOS-FINAL-PHYS-003 | PARTIAL | mDNS finds bridge; discovered handoff unreliable without correct bridge targeting |
| IOS-FINAL-PHYS-006 | FAIL | Pairing “loops” when wrong bridge auto-selected vs link button pressed |
| IOS-FINAL-COND-003 | PASS | Manual IP + link button pairs over HTTPS:443 |
| IOS-FINAL-PHYS-004 | PASS | Manual IP reaches bridge-found / pair UI |
| IOS-FINAL-PHYS-005 | PASS | Type **101** retryable when link button not pressed |
| IOS-FINAL-PHYS-007 | PASS | Credentials persist after relaunch when pairing completed |

**Proven (IOS-BUG-001A2 DEBUG capture, 2026-06-03, two Hue v2 bridges on LAN):**

| Bridge (mDNS name) | Resolved endpoint | Pairing transport |
| --- | --- | --- |
| Hue Bridge - 663C54 | `192.168.40.116:443` | `https://192.168.40.116:443/api` + cert trust delegate |
| Hue Bridge - 608DFC | `192.168.40.117:443` | `https://192.168.40.117:443/api` + cert trust delegate |

- Both discovered v2 bridges resolve to **port 443** and pair over **HTTPS** with `BridgeCertTrustDelegate`.
- Pairing **succeeds** when the physical link button pressed belongs to the bridge selected by the flow.
- Manual IP entry **succeeds** for explicitly targeting the other bridge.
- Credentials logged as `<REDACTED_APPLICATION_KEY>` / `<REDACTED_CLIENT_KEY>` only — no raw keys in this doc.

**Android MVP kickoff:** remains **blocked** until IOS-BUG-001B physical re-test passes (discovered multi-bridge selection without manual IP).

---

## Known and Unknown Runtime Facts

### Known (physical + source)

- Two Hue v2 bridges on LAN both mDNS-resolve to **HTTPS:443**.
- Discovered pairing POST uses `https://host:443/api` with certificate trust delegate on tested bridges.
- Automatic flow selects **`discoveredBridges.first`**, stops scan, presents **one** bridge — no chooser (`BridgeDiscoveryViewModel`, `BridgeSetupView`).
- User cannot pick the second discovered bridge without manual IP.
- Adding a second bridge may re-offer an **already-connected** first bridge.
- Manual IP workaround remains valid for explicit targeting.
- Type **101** returns to `.bridgeFound` when link button not pressed on the **selected** bridge.
- NUPnP fallback observed: `GET https://discovery.meethue.com/api/nupnp` → **404 page not found**; flow then restarted mDNS warm cache (separate issue).

### Unknown / out of scope for 001B

- HTTP:80 legacy bridge pairing on discovered path (COND-002 NOT TESTED; no legacy hardware).
- Whether NUPnP 404 is transient, endpoint drift, or account/network specific (**IOS-BUG-002A**).

---

## Ruled-Out Hypothesis

**Port / scheme mismatch (IOS-BUG-001A primary hypothesis) — ruled out for tested Hue v2 bridges.**

Physical DEBUG capture shows:

```text
Tested v2 mDNS results do NOT show port/scheme mismatch.
Both bridges: 192.168.40.116:443 and 192.168.40.117:443
Pairing: https://host:443/api with HTTPS certificate trust delegate
Pairing succeeds when link button matches selected bridge
```

Do **not** implement IOS-BUG-001B as transport normalization or HTTPS fallback for these bridges.

---

## Confirmed Defect (Source-Grounded Diagnosis)

**The defect is not a confirmed port/scheme mismatch.**

On a LAN with multiple Hue bridges, the automatic discovery flow:

1. Selects the **first** resolved bridge (`discoveredBridges.first`).
2. **Stops scanning** immediately.
3. Presents **only that bridge** for pairing — no list or picker.
4. Prevents explicitly targeting another discovered bridge without manual IP.
5. When adding a second bridge, may select bridge A again even if already connected.

User-visible “pairing loop” on FINAL-B is consistent with **type 101** (link button on bridge B while UI paired to auto-selected bridge A) and retry, not TLS/HTTP transport failure on v2 hardware.

### Source evidence

`BridgeDiscoveryViewModel.init()`:

```swift
discovery.$discoveredBridges
  .filter { !$0.isEmpty }
  .compactMap { $0.first }
  .first()
  ...
  discovery.stopScan()
  phase = .bridgeFound(bridge)
```

`discoverViaNUPnP()` warm-cache retry:

```swift
if let bridge = discovery.discoveredBridges.first
...
phase = .bridgeFound(bridge)
```

`BridgeSetupView.bridgeFoundContent(...)`:

- Renders **one** bridge (name + host).
- Exposes **Pair with Bridge** and **Scan Again**.
- Does **not** expose a list or picker of discovered bridges.

---

## Separate Defect (Not IOS-BUG-001B)

**Philips cloud NUPnP fallback returned 404** during capture:

```text
GET https://discovery.meethue.com/api/nupnp
→ 404 page not found
→ flow restarted mDNS with warm cache
```

| Classification | Follow-up |
| --- | --- |
| Separate issue | **IOS-BUG-002A** — Inventory Philips cloud-discovery fallback 404 |
| Do not mix | Into multi-bridge selection repair (001B) |

---

## Discovery Endpoint Construction

**Source:** `HueHome/Core/Network/BridgeDiscoveryService.swift`

| Topic | Behavior |
| --- | --- |
| mDNS service type | `_hue._tcp` |
| Domain | `local.` |
| LAN-only | `includePeerToPeer = false` |
| IPv4 forcing | `NWProtocolIP.Options.version = .v4` on resolve |
| Resolution | `NWConnection` → `currentPath.remoteEndpoint` hostPort |
| Host normalization | `hostString` strips `%zone` |
| Port | `port.rawValue` preserved (tested v2: **443**) |
| Host persisted before pairing | Yes — Keychain IP on resolve |
| Dedup | `contains(bridge)` includes per-instance `UUID` — weak dedup |

---

## Pairing Endpoint Construction

**Source:** `BridgeDiscoveryViewModel` — **unchanged for 001B** (selection only).

| Step | Behavior |
| --- | --- |
| Pairing URL | `scheme://host:port/api` |
| Scheme | `port == 443` → `https`, else `http` |
| Certificate delegate | Custom session only when `port == 443` |
| Success | Keychain token + IP; `phase = .paired` |
| Error 101 | `phase = .bridgeFound(bridge)` — retry on **selected** bridge |

---

## mDNS vs NUPnP vs Manual-IP Comparison

| Path | Host source | Port source | Scheme selection | Certificate delegate | Physical result (tested) |
| --- | --- | --- | --- | --- | --- |
| mDNS discovered (auto-first) | Resolved host | Resolved port (**443** on v2) | HTTPS when 443 | Yes | **Fails UX** when wrong bridge auto-selected; **succeeds** when selected bridge matches link button |
| mDNS + manual IP | User IP | Hardcoded **443** | HTTPS | Yes | **PASS** — explicit second bridge |
| NUPnP fallback | Cloud `internalipaddress` | `port ?? 443` | Same rule | Same rule | **404 observed** in capture; warm mDNS retry — **IOS-BUG-002A** |

---

## Secondary Findings

1. **First-bridge wins** — root cause of multi-bridge failure mode.
2. **Scan stops on first resolve** — second bridge may never be offered in UI.
3. **NUPnP 404** — separate cloud-discovery follow-up (**IOS-BUG-002A**).
4. **Early Keychain IP write** on mDNS resolve — unchanged in 001B.
5. **UUID-based dedup** — list may hold multiple entries; UI still shows `.first` only.

---

## Duplicate-Endpoint Equality Assessment

`BridgeEndpoint` synthesized `Equatable` includes `id` (`UUID()` per resolve). Dedup by `contains` is ineffective; ordering in `discoveredBridges` affects which bridge becomes `.first`. Relevant to **which** bridge is auto-selected, not transport.

---

## Existing Test Coverage

No `BridgeDiscovery` / pairing / selection tests. `StubURLProtocol` covers CLIP v2 only. IOS-BUG-001B should add pure-unit selection state tests (see matrix below).

---

## Physical DEBUG Log-Capture Packet

**Status: COMPLETE (IOS-BUG-001A2).** Further pairing transport testing is not required for v2 bridges on this LAN.

Capture sequence and required log line types are documented in IOS-BUG-001A; evidence is summarized in **Log-Capture Table** below.

---

## Log-Capture Table

| Capture | Bridge | Discovered host | Discovered port | Pairing URL | Result | Error / response | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| mDNS flow | Hue Bridge - 663C54 | `192.168.40.116` | `443` | `https://192.168.40.116:443/api` | Success when link button on **663C54** | Paired; keys `<REDACTED_*>` | Auto-first may show this bridge |
| mDNS flow | Hue Bridge - 608DFC | `192.168.40.117` | `443` | `https://192.168.40.117:443/api` | Success when link button on **608DFC** | Paired when explicitly targeted | Requires selection or manual IP today |
| manual-IP flow | Other bridge | User-entered IP | `443` | `https://host:443/api` | Success | — | Workaround for non-selected bridge |
| NUPnP | — | — | — | `GET …/api/nupnp` | Cloud error | `404 page not found` | **IOS-BUG-002A** — not 001B |

---

## Repair Strategy Comparison

| Rank | Strategy | Compatibility | Testability | Runtime risk | Recommendation |
| --- | --- | --- | --- | --- | --- |
| 1 | **Selection UI before pair** — collect bridges during scan; picker; explicit `pairWithBridge(selected)` | Fixes multi-bridge v2; preserves port/host/transport | High (pure unit + physical) | Low | **IOS-BUG-001B — recommended** |
| — | ~~A — Normalize all discovered to HTTPS:443~~ | — | — | — | **Ruled out** — v2 already 443 |
| — | ~~B/C — Transport candidate fallback~~ | — | — | — | **Ruled out** for tested v2 |
| — | ~~D — Pre-probe transport~~ | — | — | High | **Not needed** |
| — | **Fix NUPnP 404** | — | — | — | **IOS-BUG-002A** only |

---

## Recommended IOS-BUG-001B Boundary

**IOS-BUG-001B — Add discovered-bridge selection before pairing**

### Narrow repair

- Collect resolved bridges during the scan window (do not stop presenting after first resolve only).
- Present discovered bridges as **selectable choices**.
- Preserve **host** and **discovered port** on selection.
- Allow explicit selection before `pairWithBridge(...)`.
- Keep manual-IP fallback **unchanged**.
- Keep pairing request behavior **unchanged**.
- Keep HTTPS certificate delegate behavior **unchanged**.
- Keep legacy HTTP:80 compatibility **unchanged** (no port rewrite).
- Keep NUPnP fallback behavior **unchanged** in this slice.

### Explicit do-not-touch (001B)

- Do **not** normalize discovered ports.
- Do **not** rewrite transport selection.
- Do **not** change certificate trust behavior.
- Do **not** change `POST /api` pairing body.
- Do **not** change Keychain persistence.
- Do **not** fix NUPnP 404 in IOS-BUG-001B.
- Do **not** refactor unrelated onboarding UI.

---

## Proposed Automated Test Matrix (IOS-BUG-001B)

### Pure unit

- One discovered bridge remains selectable.
- Two discovered bridges remain available for explicit selection.
- Selecting bridge B passes bridge B into `pairWithBridge(...)`.
- Already-connected bridge A does not prevent selecting bridge B.
- Scan reset clears prior discovery-selection state.
- Discovered host and port are preserved on selection.

### Physical Hue bridge

- Discover two v2 bridges.
- Explicitly select bridge A and pair.
- Explicitly select bridge B and pair.
- Add second bridge **without** manual IP.
- Verify manual-IP fallback still works.
- Verify both bridges route room controls correctly.

Do not add tests during documentation-only tasks.

---

## Required Physical Re-Test

After IOS-BUG-001B:

| ID | Scenario |
| --- | --- |
| IOS-FINAL-PHYS-003 | mDNS discovery; **choose** correct bridge from list |
| IOS-FINAL-PHYS-005 | Link-button-not-pressed retry on **selected** discovered bridge |
| IOS-FINAL-PHYS-006 | Successful link-button pairing from **user-selected** discovered bridge |
| IOS-FINAL-PHYS-007 | Credential persistence after relaunch |
| IOS-FINAL-COND-003 | Manual-IP HTTPS:443 regression |
| IOS-FINAL-COND-004 | Two bridges registered via discovery (no manual IP for second) |

Android MVP kickoff remains blocked until the above pass without manual IP for the second bridge.

---

## Explicit Do-Not-Touch List (IOS-BUG-001B)

See **Recommended IOS-BUG-001B Boundary** do-not-touch bullets. Additionally unchanged: `UnifiedOrchestrator`, REST v2, SSE, cache, demo mode, Composer/Studio/widgets/watch, Android docs, Xcode/signing.

---

## Android-MVP Kickoff Impact

Discovered **multi-bridge selection** is required for Android first-run parity. **Blocked** until IOS-BUG-001B ships and physical re-test passes. NUPnP 404 is tracked separately as **IOS-BUG-002A** and does not unblock Android by itself.

---

## Open Questions

1. Should already-paired bridges be filtered from the discovered list?
2. Should scan continue after first resolve until timeout or user stops?
3. **IOS-BUG-002A:** Is `https://discovery.meethue.com/api/nupnp` still the correct Philips endpoint?
4. HTTP:80 legacy discovered port behavior — defer until legacy hardware available.

---

*Inventory updated — IOS-BUG-001A + IOS-BUG-001A2. No Swift or project changes.*
