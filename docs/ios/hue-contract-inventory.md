# Hue Contract Inventory

## Purpose

This document inventories the current iOS Hue bridge contracts so the team can preserve iOS behavior and define Android parity without relying on memory or chat history.

This is not a refactor plan by itself. It is a contract map. Changes to Hue endpoints, payloads, target resource types, retry behavior, local discovery, SSE, or DTLS should update this file.

## Contract status legend

| Status | Meaning |
|---|---|
| Verified | Confirmed against code and/or hardware |
| Code-inspected | Found in code but not hardware-verified in this pass |
| TODO | Needs verification |
| Not Android MVP | May exist on iOS, but not required for Android MVP |

## Primary files

| File | Role | Android MVP relevance | Status | Notes |
|---|---|---:|---|---|
| `HueHome/Core/Network/BridgeDiscoveryService.swift` | Bridge discovery via local network and fallback discovery | Yes | Code-inspected | Needs exact timeout/error mapping |
| `HueHome/Core/ViewModels/BridgeDiscoveryViewModel.swift` | Pairing/setup UI state | Yes | Code-inspected | Capture user-facing error states |
| `HueHome/Core/Network/HueAPIClient.swift` | Hue CLIP v2 REST client | Yes | Code-inspected | Core Android parity source |
| `HueHome/Core/Network/HueV1Client.swift` | Legacy Hue v1 calls | Maybe | Code-inspected | Identify which v1 calls are still required |
| `HueHome/Core/Network/HueSSEService.swift` | Hue eventstream/SSE state updates | Yes | Code-inspected | Android should plan parity after core REST flows |
| `HueHome/Core/Network/HueEntertainmentClient.swift` | DTLS/UDP entertainment streaming | Later | Code-inspected | Not Android MVP unless Studio/sync moves earlier |
| `HueHome/Core/Network/BridgeAnimationEngine.swift` | Bridge animation/effect transport logic | Later | Code-inspected | Important for future Studio parity |
| `HueHome/Core/Models/CreateSceneRequest.swift` | Scene create/update payload model | Yes | Code-inspected | Android scene activation/create parity depends on this |
| `HueHome/Core/Network/WidgetDataStore.swift` | Widget snapshot and action-supporting data | iOS-only, contract reference | Code-inspected | Do not change casually |
| `HueHome/Intents/HueIntentAPIClient.swift` | App Intent bridge actions | iOS-only, contract reference | Code-inspected | May duplicate REST behavior |

## Discovery and pairing

| Contract | Current iOS behavior | Primary file(s) | Android target | Status | Notes |
|---|---|---|---|---|---|
| Local discovery | Discovers Hue bridges on LAN | `BridgeDiscoveryService.swift` | Android `NsdManager` / platform network discovery | TODO | Document service type, timeout, and permission behavior |
| Fallback discovery | Uses Hue fallback discovery when LAN discovery is unavailable | `BridgeDiscoveryService.swift` | Android fallback equivalent | TODO | Confirm endpoint, response mapping, retry behavior |
| Pairing | Creates Hue app key after link button press | `BridgeDiscoveryViewModel.swift`, `HueAPIClient.swift` | Android pairing flow | TODO | Document exact endpoint/payload/error handling |
| Credential storage | Stores bridge credentials locally | `KeychainManager.swift` | Android Keystore/DataStore boundary | TODO | See `persistence-and-credentials.md` |
| Entertainment key | Stores/uses entertainment client key if available | `EntertainmentConfigManager.swift`, `HueEntertainmentClient.swift` | Later Android Studio/sync parity | TODO | Not required for Android MVP unless sync/Studio moves in scope |

## REST v2 contracts

| Domain | Current iOS behavior | Primary file(s) | Android MVP? | Status | Notes |
|---|---|---|---:|---|---|
| Rooms/zones | Reads and displays grouped resources | `HueAPIClient.swift`, `HueDataModels.swift`, `HueRoom.swift`, `HueZone.swift` | Yes | TODO | Capture resource mapping and aggregation behavior |
| Lights | Reads and controls light resources | `HueAPIClient.swift`, `HueLight.swift`, `LightDisplayItem.swift` | Yes | TODO | Capture on/off, brightness, color payloads |
| Grouped light | Controls room/zone on/off/brightness behavior | `HueAPIClient.swift`, `HueGroupedLight.swift`, `UnifiedOrchestrator.swift` | Yes | TODO | Verify which payloads target grouped_light |
| Scenes | Lists/activates/creates scenes | `HueAPIClient.swift`, `CreateSceneRequest.swift`, `SceneDisplayItem.swift` | Yes | TODO | Critical Android MVP parity area |
| Devices | Lists devices/resources | `HueAPIClient.swift`, `DevicesViewModel.swift` | Maybe | TODO | Android MVP may only need enough for dashboard/rooms |
| Effects/native effects | Applies Hue effects where supported | `HueAPIClient.swift`, `EffectsViewModel.swift` | Later | TODO | Verify prohibited grouped_light/effects behavior before porting |
| Errors | Maps network/API errors to UI | `HueAPIClient.swift`, calling view models | Yes | TODO | Needs stable error taxonomy |

## REST v1 contracts

| Domain | Current iOS behavior | Primary file(s) | Android MVP? | Status | Notes |
|---|---|---|---:|---|---|
| Schedules/rules/sensors/resourcelinks | Legacy support paths where v2 may be incomplete | `HueV1Client.swift` | Maybe | TODO | Determine whether any Android MVP flow depends on v1 |
| Legacy bridge support | TODO | `HueV1Client.swift`, `UnifiedOrchestrator.swift` | Maybe | TODO | Do not remove iOS v1 behavior until usage is known |

## SSE/eventstream contracts

| Contract | Current iOS behavior | Primary file(s) | Android target | Status | Notes |
|---|---|---|---|---|---|
| Eventstream connection | Connects to Hue event stream | `HueSSEService.swift` | OkHttp/EventSource or equivalent | TODO | Capture reconnect/backoff behavior |
| State updates | Applies bridge state events into app state | `HueSSEService.swift`, `UnifiedOrchestrator.swift` | Android reducer/state layer | TODO | Critical to avoid stale UI |
| Disconnection | Handles bridge unreachable/network changes | `HueSSEService.swift`, `UnifiedOrchestrator.swift` | Android connectivity state | TODO | Capture user-facing behavior |

## Entertainment/DTLS contracts

| Contract | Current iOS behavior | Primary file(s) | Android target | Status | Notes |
|---|---|---|---|---|---|
| DTLS connection | Streams Hue Entertainment payloads over DTLS/UDP | `HueEntertainmentClient.swift` | BouncyCastle/Android UDP socket layer | Later | Not MVP unless Studio/sync is included |
| Entertainment configuration | Reads/builds entertainment configuration | `EntertainmentConfigManager.swift`, `EntertainmentConfigBuilderView.swift` | Later | TODO |  |
| Multi-bridge entertainment | Supports routing sessions by bridge where implemented | `UnifiedOrchestrator.swift`, `HueEntertainmentClient.swift` | Later | TODO | Requires real hardware validation |
| Session teardown | Stops streams and releases resources | `HueEntertainmentClient.swift`, `SyncModeEngine.swift` | Later | TODO | Android must avoid socket leaks |

## Scene payload contracts

| Contract | Current iOS behavior | Primary file(s) | Android MVP? | Status | Notes |
|---|---|---|---:|---|---|
| Create scene request | Encodes scene creation payload | `CreateSceneRequest.swift` | Yes | TODO | Capture sample payloads before Android implementation |
| Activate scene | Sends activation command to bridge | `HueAPIClient.swift`, `ScenesTabView.swift`, `RoomDetailView.swift` | Yes | TODO | Verify target resource and payload |
| Global scene behavior | Applies scene behavior across rooms/bridges where supported | `ScenesTabView.swift`, `UnifiedOrchestrator.swift` | Maybe | TODO | Likely post-MVP unless simple activation only |

## Contract change checklist

Use this checklist before changing Hue bridge behavior:

- [ ] Does this change affect iOS Build 21 behavior?
- [ ] Does this change affect Android MVP parity assumptions?
- [ ] Is the endpoint/resource type documented here?
- [ ] Is the payload shape documented or linked to a sample?
- [ ] Is error/retry behavior documented?
- [ ] Are widget/watch/App Intent callers affected?
- [ ] Is the regression smoke matrix updated?
- [ ] Is the behavior change intentional and reviewed?

## Open questions

- Which v1 APIs are still required for current iOS behavior?
- Which REST v2 endpoints are required for Android MVP?
- Does iOS currently send any payloads to grouped_light that should be corrected before Android parity?
- What is the accepted behavior when Hue SSE disconnects?
- What is the accepted behavior when a bridge certificate/trust path fails?
- Which scene creation payloads should become shared contract fixtures?
