# Final iOS Readiness Validation

## Purpose

This document records the **IOS-OPS-FINAL-A** automated readiness pass and **IOS-OPS-FINAL-B** manual physical Hue smoke for native iOS ChromaGlow at anchor commit `5f7ec3a` on branch `ios-ops/final-readiness-validation`. It verifies repository hygiene, metadata shell tests, unsigned generic builds, the full signed-simulator `HueHomeTests` baseline, and Brian Bean’s physical regression run on 2026-06-03.

**Summary:** Automated validation passed. Physical regression testing completed. The blocking multi-bridge discovery-selection defect was repaired by IOS-BUG-001B and physically re-tested on two Hue v2 bridges. Android MVP kickoff is **READY WITH DOCUMENTED FOLLOW-UPS**.

## Validation State

| Layer | State |
| --- | --- |
| Automated validation | **Complete** — all gates passed |
| Manual physical-device Hue smoke | **Complete with documented follow-ups** |
| Android MVP kickoff | **READY WITH DOCUMENTED FOLLOW-UPS** |

## Anchor Commit

| Field | Value |
| --- | --- |
| Branch | `ios-ops/final-readiness-validation` |
| HEAD SHA | `5f7ec3a` |
| `origin/main` SHA | `5f7ec3a` |
| Ahead / behind `origin/main` | `0 / 0` |
| `origin/main` ancestor of HEAD | Yes |
| Working tree at validation start | Clean |
| Xcode project | `HueHome.xcodeproj` |
| Scheme | `HueHome 1` |

## Android Contract Reference

Authoritative freeze: [`docs/android/android-mvp-contract-freeze.md`](../android/android-mvp-contract-freeze.md) (merged; iOS anchor at freeze `b4fbb58`, current ops pass at `5f7ec3a` on `main`-equivalent branch).

Confirmed freeze statements:

- Native Android with Kotlin and Jetpack Compose — **not Flutter**.
- Required Hue bridge control stays **local**; no backend in the control path.
- Minimal backend is optional support infrastructure only.
- **Current native iOS behavior is the Android parity anchor.**
- **Hardware validation remains required** before Android parity signoff.

Android freeze hardware checklist (not executed in IOS-OPS-FINAL-A):

- Pair HTTP and HTTPS bridges after link button
- mDNS discovery
- NUPnP fallback
- Manual IP on HTTPS bridge
- Room toggle, brightness, all-off
- Room-detail per-light on, brightness, xy, mirek
- Scene list and activation
- SSE grouped_light update from switch or external app
- Wi-Fi drop and restore
- Two bridges with one powered off

## Automated Validation Environment

| Field | Value |
| --- | --- |
| Host | `brian's MacBook Pro` |
| macOS | 26.5 (Build 25F71) |
| Xcode | 26.4 (Build 17E192) |
| Workspace | `/Users/brianbean/Desktop/huehome-pro-v0.3.0` |
| Simulator destination | `platform=iOS Simulator,name=iPhone 17 Pro` (iOS 26.3.1 runtime) |
| Evidence logs | `/tmp/ios-ops-final-inject-metadata.log`, `/tmp/ios-ops-final-verify-metadata.log`, `/tmp/ios-ops-final-debug-build.log`, `/tmp/ios-ops-final-release-build.log`, `/tmp/ios-ops-final-full-simulator.log`, `/tmp/ios-ops-final-warning-inventory.txt` |

## Automated Validation Results

| Check | Result | Evidence | Notes |
| --- | --- | --- | --- |
| Git safety (branch, SHA, clean tree, main ancestry) | PASS | Phase 1 commands | Branch `ios-ops/final-readiness-validation`, HEAD `5f7ec3a`, clean tree, `0/0` vs `origin/main`, main is ancestor |
| Required repo files present | PASS | Phase 1 `test -f` | DEVLOG, DEVDOC, `.cursorrules`, CURSOR_KICKOFF, HueHome.xcodeproj, scheme, Android freeze, smoke matrix, HueHomeTests suites |
| No tracked `ChromaGlow.xcodeproj` | PASS | `git ls-files ChromaGlow.xcodeproj` | Empty output |
| `git diff --check` before report | PASS | Phase 3 | No output |
| Metadata injector tests | PASS | `/tmp/ios-ops-final-inject-metadata.log` | **21/21** pass (`Tests run: 21, failed: 0`) |
| Metadata verifier tests | PASS | `/tmp/ios-ops-final-verify-metadata.log` | **17/17** pass (`Tests run: 17, failed: 0`) |
| Unsigned generic Debug build | PASS | `/tmp/ios-ops-final-debug-build.log` | `** BUILD SUCCEEDED **` (`CODE_SIGNING_ALLOWED=NO`, `generic/platform=iOS`) |
| Unsigned generic Release build | PASS | `/tmp/ios-ops-final-release-build.log` | `** BUILD SUCCEEDED **` |
| Full signed-simulator `HueHomeTests` | PASS | `/tmp/ios-ops-final-full-simulator.log` | `** TEST SUCCEEDED **` — **132/132** pass, **0** fail |
| Warning inventory (non-fix) | PASS | Build/test logs | No blocking metadata, membership, or signing regressions detected; see Warning Inventory |
| Connected-device inventory (read-only) | PASS | `xcrun xctrace list devices`, `xcrun devicectl list devices` | Physical iPhone and Apple Watch listed; no install/launch/pair performed |
| Manual physical Hue smoke | PASS (with exceptions) | This document § matrices | IOS-OPS-FINAL-B complete 2026-06-03 |
| Android MVP implementation start | READY WITH DOCUMENTED FOLLOW-UPS | IOS-BUG-001B repair + physical re-test | Multi-bridge discovery-selection blocker resolved; IOS-BUG-001C and IOS-BUG-002A tracked as non-blocking follow-ups |

## Full Signed-Simulator Test Summary

| Field | Value |
| --- | --- |
| Destination | `platform=iOS Simulator,name=iPhone 17 Pro` |
| Configuration | Debug |
| Target filter | `-only-testing:HueHomeTests` |
| xcodebuild result | `** TEST SUCCEEDED **` |
| Total test cases executed | **132** |
| Passed | **132** |
| Failed | **0** |
| Baseline match | Matches stabilized **132/132** expectation |

Per-suite baseline (simulator-pinned; all exercised in full run):

| Suite | Expected | Observed |
| --- | --- | --- |
| `DashboardDisplayModelBuilderTests` | 14/14 | Included in 132/132 pass |
| `RoomAndZoneDisplayModelBuilderTests` | 6/6 | Included |
| `CompositionRoomPriorityScorerTests` | 19/19 | Included |
| `CompositionLightResolverTests` | 16/16 | Included |
| `ComposerFetchPathParityTests` | 9/9 | Included |
| `OrchestratorCacheDemoTests` | 4/4 | Included |
| `OrchestratorLoadAllTests` | 4/4 | Included |
| `OrchestratorOptimisticUpdateTests` | 3/3 | Included |
| `OrchestratorSSETests` | 3/3 | Included |
| Other `HueHomeTests` (tokens, etc.) | Remainder to 132 | Included |

## Warning Inventory

Filtered search (`rg` pattern for `warning:`, MainActor, Sendable, AppIcon, Watch*, Studio*, Dashboard*, UnifiedOrchestrator, SyncModeEngine, BridgeAnimationStore) across build/test logs produced **no unique filtered lines** in `/tmp/ios-ops-final-warning-inventory.txt` (pattern-line format). Direct `warning:` counts in raw logs: Debug **60**, Release **55**, simulator test build **70** (includes compile warnings during test host build).

| Classification | Source | Summary | Blocking? | Follow-up |
| --- | --- | --- | --- | --- |
| PREEXISTING_NONBLOCKING | Debug/Release build | `AppIcon.appiconset` unassigned child | No | Asset catalog cleanup (iOS-only) |
| PREEXISTING_NONBLOCKING | Debug/Release build | `WatchStore` / `WatchWidgetStore` MainActor and Codable warnings | No | watchOS surface; not Android-MVP gate |
| PREEXISTING_NONBLOCKING | Debug/Release build | `DashboardView` `RoomCard` Equatable crosses MainActor (Swift 6 future error) | No | IOS-TEST-003B6 class debt |
| PREEXISTING_NONBLOCKING | Debug/Release build | `StudioView` / `StudioViewModel` concurrency and `nonisolated(unsafe)` notes | No | Post-MVP Studio surface |
| PREEXISTING_NONBLOCKING | Debug/Release build | `SyncModeEngine` MainActor/Sendable warnings | No | Post-MVP mic sync |
| PREEXISTING_NONBLOCKING | Debug/Release build | `UnifiedOrchestrator` / `BridgeAnimationStore` concurrency warnings | No | Documented stabilization debt |
| NEW_OR_UNEXPECTED | — | None identified vs known IOS-TEST-003B6 debt | No | — |
| BLOCKING | — | None (no metadata, test membership, or capability/signing regression warnings) | No | — |

## Connected Physical-Device Inventory

Read-only inventory only. **No app install, launch, bridge pairing, or UI automation was performed.**

| Source | Physical iPhone | Model | iOS / OS | Connection |
| --- | --- | --- | --- | --- |
| `xcrun xctrace list devices` | Yes (`brian's iPhone`) | Not detailed in xctrace offline list | **26.5** (offline section) | Listed under **Devices Offline** |
| `xcrun devicectl list devices` | Yes (`brian's iPhone`) | **iPhone 17 Pro Max (iPhone18,2)** | Not shown separately | **available (paired)** |
| `xcrun devicectl list devices` | Apple Watch | Apple Watch Series 10 (Watch7,9) | paired | available (paired) — not in Android-MVP critical matrix |

Brian should use the **paired, available** iPhone reported by `devicectl` for IOS-OPS-FINAL-B unless a different device is intentionally chosen.

## Manual Physical Hue Smoke Status

**Status:** `Complete with documented follow-ups` (2026-06-03)

Physical regression testing on real Hue v2 hardware is complete. The original IOS-OPS-FINAL-B matrix below records the pre–IOS-BUG-001B findings (**17/20** PASS, **1** PARTIAL, **1** FAIL, **1** NOT AVAILABLE). Post-repair physical re-test results are recorded in **Post-IOS-BUG-001B Readiness Reconciliation** below.

## Manual Test Context

| Field | Value |
| --- | --- |
| Tester | Brian Bean |
| Date | 2026-06-03 |
| Branch | `ios-ops/final-readiness-validation` |
| Commit SHA | `5f7ec3a` |
| Physical iPhone | `brian's iPhone` — iPhone 17 Pro Max |
| iOS version | 26.5 |
| App launched from Xcode | Yes |
| Local-network permission | Granted |
| Hue bridge count | 2 |
| Hue bridge generation | Two Hue v2 bridges |
| Demo environment note | Demo mode launches without a real bridge dependency, but the demo environment is not caught up to the complete current feature set |
| Xcode version | 26.4 (17E192) — automated pass host |
| Apple Watch tested | No — not Android-MVP gate |
| Widget tested | No — not Android-MVP gate |

## Android-MVP Critical Physical Smoke Matrix

| ID | Scenario | Manual steps | Expected result | Gate | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| IOS-FINAL-PHYS-001 | Existing paired app launch | On the test iPhone, ensure ChromaGlow was previously paired to a real bridge. Force-close the app from the app switcher, then tap the app icon to cold-launch. | Dashboard (or last main tab) appears without bridge setup or re-pair prompt; rooms/zones visible for the paired bridge. | REQUIRED | PASS | Existing paired app launches to dashboard without re-pair prompt. |
| IOS-FINAL-PHYS-002 | Demo-mode launch without bridge dependency | From a state where demo is reachable (clean install path or explicit demo entry), enter demo mode without pairing a bridge. Navigate to the dashboard. | Demo rooms/zones render; toggles update UI without live bridge network calls. | REQUIRED | PASS | Demo mode launches without bridge dependency. Demo environment is not in parity with the complete current app feature set. |
| IOS-FINAL-PHYS-003 | mDNS bridge discovery | On Wi-Fi with a powered Hue bridge, open bridge setup and start discovery. Wait through scanning (do not enter manual IP). | At least one bridge appears via LAN discovery (`_hue._tcp` path) without manual IP. | REQUIRED | PARTIAL | mDNS discovery finds and displays the bridge, but selecting the discovered bridge does not reliably complete the pairing flow. Manual IP entry is currently required. |
| IOS-FINAL-PHYS-004 | Manual IP entry path | From bridge setup, tap **Enter IP Manually**, enter the bridge’s LAN IPv4 (e.g. `192.168.x.x`), confirm. Proceed to pair screen. | App reaches **bridge found / pair** UI for the entered IP (HTTPS port 443 path per iOS contract). | REQUIRED | PASS | Manual IP entry is the reliable bridge-pairing path in the tested environment. |
| IOS-FINAL-PHYS-005 | Pair attempt without pressing link button | On the pair screen for a reachable bridge, tap Pair **without** pressing the physical link button. | Error type **101** (link button not pressed) or equivalent retry messaging; app stays in retryable pair state (not hard fatal error). | REQUIRED | PASS | Pairing without pressing the physical link button shows the expected retry state. |
| IOS-FINAL-PHYS-006 | Successful link-button pairing | Press the bridge link button, then tap Pair within the window. Complete pairing. | Pair succeeds; app enters main UI; credentials stored. | REQUIRED | FAIL | Link-button pairing loops when initiated from the discovered bridge result. Pairing succeeds after manual IP entry. |
| IOS-FINAL-PHYS-007 | Credential persistence after force-close and relaunch | After successful pair, force-close ChromaGlow, relaunch from home screen. | No re-pair required; dashboard loads prior bridge session. | REQUIRED | PASS | Credentials persist after force-close and relaunch. |
| IOS-FINAL-PHYS-008 | Dashboard rooms and zones render | Open dashboard on a paired bridge with known rooms and zones. | Separate room and zone lists render with plausible on/off/brightness; no crash or empty state for a healthy bridge. | REQUIRED | PASS | Dashboard rooms and zones render correctly. |
| IOS-FINAL-PHYS-009 | Room toggle on/off | Pick one known room on the dashboard. Toggle **OFF**, wait until lamps respond, then toggle **ON**. | Physical lamps and room card on/off state agree in both directions. | REQUIRED | PASS | Room toggle updates physical lamps and UI. |
| IOS-FINAL-PHYS-010 | Room/group brightness | Select a room that is ON. Move brightness slider to a clearly different value (e.g. very low then mid). | Physical grouped lights and UI brightness agree. | REQUIRED | PASS | Room / grouped-light brightness updates physical lamps and UI. |
| IOS-FINAL-PHYS-011 | Turn all off | Use dashboard **turn all off** (or equivalent bulk off). | All targeted room/group lights turn off; UI reflects off state. | REQUIRED | PASS | Turn-all-off updates visible cards and physical lamps. |
| IOS-FINAL-PHYS-012 | Room-detail individual-light toggle | Open a room with multiple lights. Toggle one light **OFF**, then **ON**. | Only that light changes physically; UI matches. | REQUIRED | PASS | Individual-light toggle updates the expected lamp and UI. |
| IOS-FINAL-PHYS-013 | Room-detail individual-light brightness | With one light ON, adjust its brightness slider to a clearly different level. | That lamp’s brightness matches UI. | REQUIRED | PASS | Individual-light brightness updates the expected lamp and UI. |
| IOS-FINAL-PHYS-014 | Room-detail individual-light xy color | With a color-capable lamp ON, pick a visibly different color in room detail. | Lamp color changes to match UI xy selection. | REQUIRED | PASS | Individual-light XY color updates the expected lamp and UI remains usable. |
| IOS-FINAL-PHYS-015 | Room-detail individual-light mirek temperature | With a white-spectrum lamp ON, set a clearly warmer/cooler mirek (color temperature). | Lamp CCT changes to match UI. | REQUIRED | NOT AVAILABLE | No mirek-capable temperature lamp was available in the physical test environment. |
| IOS-FINAL-PHYS-016 | Scene list | Open scenes surface (tab or room/global per build). Pull to refresh if needed. | Scene list loads without crash; scenes visible for paired bridge(s). | REQUIRED | PASS | Scene list renders. |
| IOS-FINAL-PHYS-017 | Basic scene activation | Activate one static scene from the list. Observe lights. | Scene applies on bridge; UI remains stable and reflects active lighting. | REQUIRED | PASS | Basic scene activation updates physical lamps and app remains responsive. |
| IOS-FINAL-PHYS-018 | External grouped-light SSE visible-state update | With ChromaGlow on dashboard, change a room’s grouped light using the official Hue app or a physical Hue switch/dimmer. Do not pull-to-refresh. | ChromaGlow room card updates on/off/brightness to match external change within SSE reconnect window. | REQUIRED | PASS | External grouped-light change updates ChromaGlow without pull-to-refresh. |
| IOS-FINAL-PHYS-019 | Bridge offline stale-state behavior | With dashboard showing rooms, power off the bridge or disconnect it from LAN. Observe UI for ≥30s. | App shows offline/error indication; prior room list remains visible (stale-while-revalidate); no crash. | REQUIRED | PASS | With one bridge temporarily unreachable, visible stale state remains available and the app does not crash. |
| IOS-FINAL-PHYS-020 | Wi-Fi interruption and SSE reconnect | With app foreground on dashboard, disable Wi-Fi briefly (10–30s), observe stale state, re-enable Wi-Fi. Then change a light externally. | App recovers connectivity; later external grouped_light changes arrive without manual refresh. | REQUIRED | PASS | After Wi-Fi interruption and restore, later external room changes arrive without app restart. |

### Required physical matrix totals

| Result | Count |
| --- | --- |
| PASS | 17 / 20 |
| PARTIAL | 1 / 20 |
| FAIL | 1 / 20 |
| NOT AVAILABLE | 1 / 20 |

## Conditional Hardware Matrix

| ID | Scenario | Manual steps | Expected result | Availability | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| IOS-FINAL-COND-001 | NUPnP fallback with mDNS unavailable | Block or disable mDNS/LAN discovery if practical (guest network, firewall, or wait ≥12s on scanning). | Cloud NUPnP path discovers bridge or shows graceful manual-IP hint. | NOT PRACTICAL TODAY | NOT TESTED | NUPnP fallback with mDNS unavailable was not isolated during this pass. |
| IOS-FINAL-COND-002 | Pair HTTP:80 legacy bridge | Pair a legacy HTTP bridge (port 80) using link button flow. | Token persisted; dashboard reachable over ongoing HTTPS v2 to IP per iOS contract. | NOT AVAILABLE | NOT TESTED | Test environment contains Hue v2 bridges only; no HTTP:80 legacy bridge available. |
| IOS-FINAL-COND-003 | Pair HTTPS:443 bridge | Pair a modern HTTPS bridge on 443. | Pair succeeds; REST/SSE operate. | AVAILABLE | PASS | Manual IP entry followed by physical link-button press successfully paired a Hue v2 bridge over the HTTPS:443 path. |
| IOS-FINAL-COND-004 | Two bridges registered | Pair/register two distinct bridges in app settings. | Both appear; rooms tagged by bridge; no duplicate-IP client merge for same host. | AVAILABLE | PASS | Two bridges registered and visible; bridge-specific room control routes correctly. |
| IOS-FINAL-COND-005 | One bridge offline while another remains usable | With two bridges configured, power off or disconnect bridge A only. Control a room on bridge B. | Bridge B remains usable; bridge A shows offline/stale without blocking B. | AVAILABLE | PASS | One bridge can be offline while the other remains usable. |
| IOS-FINAL-COND-006 | Dynamic scene activation if available | If a dynamic scene exists, activate with speed UI if shown. | Scene activates with expected motion/speed behavior. | AVAILABLE | PASS | Dynamic scene activation works in the tested environment. |
| IOS-FINAL-COND-007 | Local-network permission on clean install if practical | Delete app or use clean install; trigger discovery. | iOS local network permission prompt/education appears as expected. | AVAILABLE | PASS | Local-network permission flow works. |

### Conditional hardware matrix totals

| Result / availability | Count |
| --- | --- |
| PASS | 5 / 7 |
| NOT TESTED | 2 / 7 |
| NOT PRACTICAL TODAY | 1 / 7 |
| NOT AVAILABLE | 1 / 7 |

## Post-IOS-BUG-001B Readiness Reconciliation

Reconciliation recorded at anchor commit `72ee5ab` on branch `docs/ios-readiness-reconcile-after-001b` (IOS-OPS-FINAL-C, 2026-06-03). IOS-BUG-001B merged to `main` at `72ee5ab`.

### Repair Summary

IOS-BUG-001B added explicit discovered-bridge selection before pairing.

The setup flow now:

- continues collecting resolved Hue bridges during scanning
- presents explicit selectable bridge choices
- preserves each bridge host and resolved port
- deduplicates chooser rows by host + port
- pairs only the bridge explicitly selected by the user
- preserves the existing manual-IP fallback
- preserves pairing transport behavior
- preserves certificate-trust behavior
- preserves legacy HTTP:80 compatibility

### Physical Re-Test Results

| Test | Result | Notes |
| --- | --- | --- |
| Chooser contents | `PASS` | Both Hue v2 bridges appear as explicit selectable choices; no duplicates; no silent auto-target. |
| Pair Bridge A (`192.168.40.116:443`) | `PASS` | Explicit discovered selection pairs successfully after pressing the matching bridge button. |
| Pair Bridge B (`192.168.40.117:443`) | `PASS` | Explicit discovered selection pairs successfully without manual IP. |
| Type-101 retry | `PASS WITH UX FOLLOW-UP` | Retry remains functional; selected-vs-pressed bridge mismatch feedback is not sufficiently clear. |
| Manual-IP HTTPS:443 regression | `PASS` | Existing manual-IP path remains functional. |
| Two-bridge routing regression | `PASS` | Room controls route to the intended physical bridge. |

Previously blocking rows:

- `IOS-FINAL-PHYS-003` → resolved by IOS-BUG-001B physical re-test
- `IOS-FINAL-PHYS-006` → resolved by IOS-BUG-001B physical re-test

### Remaining Documented Follow-Ups

**IOS-BUG-001C — Clarify selected-bridge pairing retry feedback**
Status: non-blocking UX follow-up

**IOS-BUG-002A — Inventory Philips cloud-discovery fallback 404**
Status: non-blocking fallback-discovery follow-up

**Credential rotation**
Status: required before release signoff because DEBUG logs exposed bridge credentials

### Updated Android-MVP Kickoff State

Android MVP kickoff: **READY WITH DOCUMENTED FOLLOW-UPS**

Reason: The Android-MVP-critical multi-bridge discovery-selection blocker is repaired and physically verified. The remaining IOS-BUG-001C and IOS-BUG-002A items are tracked, bounded follow-ups and do not block Android foundation work.

## iOS-Only Nonblocking Smoke Notes

Broader regression coverage lives in [`docs/ios/regression-smoke-matrix.md`](regression-smoke-matrix.md). The following surfaces remain **iOS regression surfaces** but are **not Android-MVP kickoff gates** unless a blocking launch regression appears:

- Studio / Composer
- Microphone sync
- Widgets
- App Intents / Siri
- watchOS
- Automations
- Scene CRUD (create/rename/delete)

**IOS-OPS-FINAL-A did not run or claim validation of these surfaces.** IOS-OPS-FINAL-B did not re-test them.

## Overall Manual Notes

**UI mismatch:**  
None observed during tested flows.

**Bridge behavior issue:**  
Discovered bridge appears through mDNS, but the discovered-result handoff does not reliably complete link-button pairing. Manual IP entry is currently required.

**Stale-state or SSE issue:**  
No issue observed during tested stale-state, external SSE update, or Wi-Fi reconnect flows.

**Pairing issue:**  
Yes. Link-button pairing loops when initiated from the discovered bridge result. Manual IP entry followed by the physical link-button press succeeds as a workaround.

**Demo-mode note:**  
Demo mode launches without a bridge dependency, but the demo environment is not caught up to the full current feature set.

**Other regressions:**  
None observed during tested flows.

## Readiness Blockers

| Blocker | Status |
| --- | --- |
| Automated git/build/test gates | **None** at `72ee5ab` |
| Manual Android-MVP critical smoke | **Complete with documented follow-ups** — see historical matrix and Post-IOS-BUG-001B reconciliation |
| Android Gradle / Kotlin implementation | **Ready with documented follow-ups** |

### RESOLVED — Discovered-bridge multi-bridge selection (IOS-BUG-001B)

**Historical behavior (IOS-OPS-FINAL-B):** mDNS discovery found bridges, but the flow auto-selected the first discovered bridge with no chooser; selecting a discovered result did not reliably complete pairing for a second bridge without manual IP.

**Repair (IOS-BUG-001B):** explicit discovered-bridge selection before pairing; host+port deduplication; user-selected bridge drives pairing.

**Physical re-test (2026-06-03):** both Hue v2 bridges pair via explicit discovered selection; manual-IP path remains verified.

**Remaining non-blocking follow-ups:** IOS-BUG-001C (retry UX clarity), IOS-BUG-002A (NUPnP 404 inventory), credential rotation before release signoff.

## Signoff State

| Item | State |
| --- | --- |
| Automated readiness checks | **PASS** |
| Physical hardware regression run | **COMPLETE WITH DOCUMENTED FOLLOW-UPS** |
| Multi-bridge discovery-selection blocker | **RESOLVED** |
| Manual-IP pairing regression | **VERIFIED** |
| Two-bridge routing regression | **VERIFIED** |
| Android-MVP kickoff | **READY WITH DOCUMENTED FOLLOW-UPS** |
| Remaining follow-ups | IOS-BUG-001C, IOS-BUG-002A, credential rotation before release |

## IOS-OPS-FINAL-B Handoff

**Completed (historical):**

- IOS-OPS-FINAL-A automated checks passed.
- IOS-OPS-FINAL-B physical smoke completed (pre–IOS-BUG-001B matrix preserved above).
- IOS-BUG-001A inventory and IOS-BUG-001B repair completed; physical re-test passed 2026-06-03.
- IOS-OPS-FINAL-C reconciled readiness at `72ee5ab`.

**Recommended next work:**

```text
Android MVP foundation (per docs/android/android-mvp-contract-freeze.md)
```

**Non-blocking iOS follow-ups:**

```text
IOS-BUG-001C — Clarify selected-bridge pairing retry feedback
IOS-BUG-002A — Inventory Philips cloud-discovery fallback 404
Credential rotation before release signoff
```

---

*IOS-OPS-FINAL-A: 2026-06-02 (automated only). IOS-OPS-FINAL-B: 2026-06-03 (manual smoke recorded by Brian Bean; historical matrix preserved). IOS-OPS-FINAL-C: 2026-06-03 (readiness reconciliation after IOS-BUG-001B). Docs-only in FINAL-B/FINAL-C; no Swift, Xcode project, workflow, or script changes in those passes. Cursor did not re-run builds, simulator tests, or physical-device tests in FINAL-C.*
