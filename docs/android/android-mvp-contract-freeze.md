# Android MVP Contract Freeze

## Purpose

Freeze a single authoritative contract for the first standalone **native Android** ChromaGlow MVP, derived from stabilized iOS source and signed-simulator tests at commit `b4fbb58`. This document is the behavior anchor for Kotlin/Jetpack Compose implementation. It does **not** authorize implementation in this pass.

**Product constraints (approved):**

- Native Android with Kotlin and Jetpack Compose — **not Flutter**.
- Required local Hue bridge control stays **on-device**; no backend in the control path.
- Minimal/distributed backend is optional product infrastructure only.
- Current iOS mechanics are **evidence**, not a mandate to copy storage layout, `UnifiedOrchestrator` shape, or iOS-only surfaces.

## Freeze Date and iOS Anchor

| Item | Value |
| --- | --- |
| Freeze date | 2026-06-02 |
| Working branch | `docs/android-mvp-contract-freeze` |
| Starting / anchor SHA | `b4fbb58` |
| Xcode reference project | `HueHome.xcodeproj` (read-only reference) |
| iOS app target | `HueHome` |
| Orchestrator anchor | `HueHome/Core/Network/UnifiedOrchestrator.swift` |

## Approved Product Direction

- Keep the current native iOS app.
- Build a standalone native Android app (Kotlin + Jetpack Compose).
- Use a minimal backend only where it supports the product; **do not** route required local Hue control through it.
- Treat repo Markdown and this freeze as source of truth for Android MVP scope.

## Android MVP Scope

| Area | Android-MVP |
| --- | --- |
| Demo mode | Yes |
| Bridge discovery (mDNS → NUPnP → manual IP) | Yes |
| Link-button pairing + local credential persistence | Yes |
| Dashboard / core UI parity (rooms, zones, controls) | Yes |
| Room and zone display | Yes |
| Room/group (`grouped_light`) control | Yes |
| Individual light control | Yes |
| Scenes list + basic scene activation | Yes |
| Offline / stale-state behavior | Yes |
| SSE-driven visible-state updates | Yes |

## Explicitly Deferred Scope

| Area | Status |
| --- | --- |
| iOS widgets, App Intents / Siri, watchOS, Wear OS | Post-MVP / iOS-only |
| Studio / Composer, `BridgeAnimationEngine`, DTLS entertainment, mic sync, Spotify, Marketplace, web app | Post-MVP |
| Google Home integration | Post-MVP |
| Automations (unless a core MVP flow later proves dependency) | Post-MVP |
| Scene create / edit / delete (iOS has these; not required for Android MVP list+activate) | Post-MVP |
| Scene activation speed UI for dynamic scenes (optional product) | Post-MVP unless product promotes |
| Global scenes **CRUD**; cross-bridge scene **list + activate** mirrors iOS `ScenesTabView` core tap path | List/activate = Android-MVP; create/rename/delete = Post-MVP |
| Device browser tab | Post-MVP unless product promotes |
| Hue REST v1 (schedules/rules/bridge animation upload) | Post-MVP |
| Entertainment client key usage | Post-MVP (store optionally for forward compatibility) |

## Evidence Status Legend

| Status | Meaning |
| --- | --- |
| `Simulator-pinned` | Asserted by stabilized signed-simulator unit suite |
| `Code-inspected` | Present in current iOS source; not proven on physical Hue hardware in this pass |
| `Hardware-TODO` | Must be verified on physical bridge before Android parity signoff |
| `Android-MVP` | Required for first standalone Android release |
| `Post-MVP` | Intentionally deferred |
| `iOS-only` | Must not be copied into Android architecture |

Do not upgrade `Code-inspected` to hardware-verified. Use `TODO-HARDWARE`, `TODO-PRODUCT`, `TODO-SECURITY` where noted.

## Stabilized iOS Evidence Baseline

Recorded at freeze anchor `b4fbb58` (signed-simulator `HueHomeTests` on iPhone 17 Pro class simulator — **not** physical Hue hardware unless otherwise noted in repo docs).

| Suite | Result |
| --- | --- |
| `DashboardDisplayModelBuilderTests` | 14/14 pass |
| `RoomAndZoneDisplayModelBuilderTests` | 6/6 pass |
| `CompositionRoomPriorityScorerTests` | 19/19 pass |
| `CompositionLightResolverTests` | 16/16 pass |
| `ComposerFetchPathParityTests` | 9/9 pass |
| `OrchestratorCacheDemoTests` | 4/4 pass |
| `OrchestratorLoadAllTests` | 4/4 pass |
| `OrchestratorOptimisticUpdateTests` | 3/3 pass |
| `OrchestratorSSETests` | 3/3 pass |
| Full signed-simulator `HueHomeTests` | **132/132** pass |
| Metadata injector tests (`test_inject_build_metadata.sh`) | 21/21 pass |
| Metadata verifier tests (`test_verify_built_app_metadata.sh`) | 17/17 pass |

## Bridge Discovery Contract

### Discovery ladder (current iOS)

| Layer | Behavior | Evidence | Android-MVP |
| --- | --- | --- | --- |
| **1 — mDNS** | `NWBrowser` for Bonjour type `_hue._tcp` in domain `local.`; `includePeerToPeer = false` (LAN only). On resolve: `NWConnection` TCP with **IPv4 forced** (avoids link-local IPv6 zone IDs invalid in URLs). Dedupes `BridgeEndpoint` equality. On success: appends to `discoveredBridges`, logs, **`KeychainManager.saveBridgeIP(host)`** (legacy `hue_bridge_ip` key). | Code-inspected | Yes |
| **1 — UI handoff** | `BridgeDiscoveryViewModel` observes first mDNS bridge while `phase == .scanning`, stops scan, sets `phase = .bridgeFound(bridge)`. | Code-inspected | Yes |
| **2 — NUPnP** | After **12 s** still scanning: `GET https://discovery.meethue.com/api/nupnp`. Decodes `[{ id, internalipaddress, port? }]`. Uses **first** result; `port = UInt16(first.port ?? 443)`; name `"Philips Hue Bridge"`. Empty array → error message suggesting manual IP. | Code-inspected | Yes |
| **2 — UI label** | `scanningLabel` → `"Trying cloud discovery..."` during layer 2. | Code-inspected | Yes |
| **3 — Manual IP** | See Manual IP Contract. | Code-inspected | Yes (see TODO-PRODUCT) |
| **Retry** | On NUPnP **network/decode failure** (not empty list): if `mdnsRetryDone == false`, set flag, stop scan, **300 ms** pause, restart mDNS, poll **0.5 s × 20 = 10 s** for first bridge; else error with manual IP hint. | Code-inspected | Yes |
| **Scan start guard** | `startScan()` only from `.idle` or `.error`. | Code-inspected | Yes |

**Android implementation suggestion:** `NsdManager` / Connectivity APIs for layer 1; OkHttp for layer 2; Compose sheet for layer 3. Do not copy `ObservableObject`/`@Observable` patterns.

**Open validation:** `TODO-HARDWARE` — mDNS on Android OEMs/routers; `TODO-HARDWARE` — NUPnP reachability; `TODO-PRODUCT` — whether manual IP ships in v1 Android UI (iOS ships it today).

### iOS source map

- `HueHome/Core/Network/BridgeDiscoveryService.swift`
- `HueHome/Core/ViewModels/BridgeDiscoveryViewModel.swift`
- `HueHome/UI/BridgeSetup/BridgeSetupView.swift`

## Manual IP Contract

| Item | Current iOS | Android-MVP parity | Evidence |
| --- | --- | --- | --- |
| UI path | Idle: **"Enter IP Manually"**; Scanning: same secondary button (resets to idle + sheet); Error: same. Sheet title **"Enter Bridge IP"**. | Equivalent entry points | Code-inspected |
| Input | `TextField` placeholder `192.168.1.100`, `decimalPad`, trim whitespace | Same | Code-inspected |
| Validation | Non-empty trimmed IP only (no regex/CIDR check) | Same minimum | Code-inspected |
| Port | **`BridgeEndpoint(..., port: 443)`** always — no port field | HTTPS pairing path | Code-inspected |
| Flow | Sets `vm.phase = .bridgeFound(bridge)`; user must press link button + Pair | Same | Code-inspected |
| Persistence on manual path | No IP Keychain write until pairing success (unlike mDNS resolve path) | Acceptable divergence if documented | Code-inspected |

**TODO-HARDWARE:** Manual IP on HTTP:80-only legacy bridges (iOS forces 443 here).

## Pairing Contract

| Item | Current iOS | Android-MVP | Evidence |
| --- | --- | --- | --- |
| Endpoint | `POST {scheme}://{host}:{port}/api` | Same | Code-inspected |
| Scheme | `https` if `port == 443`, else `http` | Same | Code-inspected |
| Timeout | `URLRequest.timeoutInterval = 10` | 10 s | Code-inspected |
| Headers | `Content-Type: application/json` | Same | Code-inspected |
| Body | `devicetype`: `AppBrand.hueDeviceType` → **`"chromaglow#ios"`**; `generateclientkey`: **true** | Android must use **distinct** `devicetype` string (e.g. `chromaglow#android`) — product constant | Code-inspected |
| Response shape | JSON **array** of `{ success?, error? }`; first element wins | Same | Code-inspected |
| Success | `success.username` → API token; optional `success.clientkey` | Persist token; optional client key for Post-MVP entertainment | Code-inspected |
| Error type **101** | Message: link button not pressed; **`phase = .bridgeFound(bridge)`** (retry) | Same UX | Code-inspected |
| Error type **7** | Invalid body / devicetype message (logged); returns to `.bridgeFound` without generic `.error` phase in switch | Map clearly | Code-inspected |
| Other errors | `handleError` → `.error(message)` | Same | Code-inspected |
| HTTPS trust | `BridgeCertTrustDelegate` accepts server trust for local pairing only | **TODO-SECURITY** — do not copy blindly | Code-inspected |
| Persistence on success | `saveAPIToken`, `saveBridgeIP`, optional `hue_client_key` (legacy keys) | Android Keystore + non-secret metadata store | Code-inspected |

**Android implementation suggestion:** OkHttp + explicit certificate policy type; pairing module isolated from dashboard.

**Runtime pairing BLOCKED (ANDROID-006A):** Runtime link-button pairing is blocked pending an approved safe TLS-bootstrap policy and a canonical stable bridge-ID contract. The known `POST /api` contract above remains documented evidence only. The landed **API-token-only** credential store (ANDROID-004A) remains unchanged. Do **not** fabricate bridge ID values. See [`android-pairing-tls-identity-decision.md`](android-pairing-tls-identity-decision.md).

## Certificate Trust Boundary

| Surface | Current iOS | Android guidance |
| --- | --- | --- |
| Pairing (HTTPS) | Unconditional local server-trust via `BridgeCertTrustDelegate` | **TODO-SECURITY:** pin/TOFU/network-security-config review |
| REST v2 (`HueAPIClient`) | `HueCertTrustDelegate` on session **and** task delegate (iOS 15+ task challenges) | Same review; likely needed for `https://{bridgeIP}` |
| SSE (`UnifiedOrchestrator.runSSE`) | Shared `sseSession` with cert delegate | Same review |

**Explicit:** iOS behavior is evidence, not an approved Android security decision. Do **not** copy unconditional iOS trust behavior into Android. Android first-contact TLS trust is an open blocker — see [`android-pairing-tls-identity-decision.md`](android-pairing-tls-identity-decision.md).

## Credential Storage Contract

### Current iOS (evidence only)

| Item | Value |
| --- | --- |
| Keychain service | `com.lightshade.app` |
| Legacy token key | `hue_api_token` |
| Legacy IP key | `hue_bridge_ip` |
| Legacy entertainment key | `hue_client_key` (non-namespaced) |
| Multi-bridge IP | `hue_bridge_{bridgeID}_ip` |
| Multi-bridge token | `hue_bridge_{bridgeID}_token` |
| Multi-bridge client key | `hue_bridge_{bridgeID}_clientkey` |
| Accessibility | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Upsert | Delete-then-add per account key |

### Bridge record (SwiftData — routing metadata)

`BridgeRecord`: `id` (UUID), `name`, `host`, `port` (default 443), `sortOrder`, `isActive`, etc. Credentials live in Keychain keyed by `id`.

### Orchestrator routing

| Behavior | Detail | Evidence |
| --- | --- | --- |
| `configure(bridges:)` | Empty list → one-time `migrateLegacyCredentials` into new UUID `BridgeRecord` | Code-inspected |
| Active bridges | `loadCredentials(for: id)`; missing → `connectionStatus[id] = .error("No credentials found")`, skip client | Code-inspected |
| Duplicate host IP | `seenHostIPs` — second `BridgeRecord` with same IP **skipped** (no second client/SSE) | Code-inspected |
| Disabled bridge | `isActive == false` → `connectionStatus = .disabled` | Code-inspected |
| `addBridge` | Requires credentials; adds client + widget cred publish | Code-inspected |
| `removeBridge` | Cancel SSE, drop client/maps, `deleteCredentials`, rebuild rooms | Code-inspected |
| Widget cred publish | `WidgetDataStore.write` with IP+token per bridge | **iOS-only** — not Android-MVP |

**Important:** Current iOS mechanics are **not** an Android storage blueprint.

### Android target boundaries

| Data | Store |
| --- | --- |
| API application token | **Android Keystore** (or EncryptedSharedPreferences with Keystore-backed master key) |
| Entertainment client key (if retained) | Keystore |
| Bridge ID, display name, host, port, active flag, sort order | **Room or DataStore** |
| Do **not** store raw tokens in plain DataStore/SharedPreferences | Required |

## Legacy Credential Migration Note

On first launch with **zero** `BridgeRecord` rows, iOS reads legacy `hue_bridge_ip` + `hue_api_token`, writes namespaced keys for a new UUID, deletes legacy keys (+ migrates `hue_client_key` if present), inserts `BridgeRecord`, re-calls `configure`. Android should implement an explicit one-time migration if importing iOS data is ever required; greenfield Android uses namespaced keys from first pair.

## Multi-Bridge Routing Contract

- One `BridgeAPIClient` (extends `HueAPIClient`) per active bridge ID.
- Dashboard flattens `roomsByBridge` / `zonesByBridge` with bridge ID on each `RoomDisplayItem`.
- Controls resolve `clients[item.bridgeID]`.
- SSE: one task per bridge in `sseTasks`.
- **Android-MVP:** Same routing semantics; avoid duplicate IP clients.

## Shared REST v2 Transport Contract

| Item | Value | Evidence |
| --- | --- | --- |
| Base URL | `https://{ip}{path}` — always HTTPS in `HueAPIClient` (IP from credentials) | Code-inspected |
| Auth header | `hue-application-key: {token}` | Code-inspected |
| Content-Type | `application/json` on mutating requests | Code-inspected |
| Timeout | **10 s** per request (`URLRequest.timeoutInterval: 10`) | Code-inspected |
| Certificate | `HueCertTrustDelegate` session + task | Code-inspected |
| Non-2xx | `HueAPIError.httpError(status)` after logging body | Code-inspected |
| Decode failure | `HueAPIError.decodingFailed` | Code-inspected |
| Missing credentials | `HueAPIError.missingCredentials` | Code-inspected |
| Multi-bridge client | `HueAPIClient(ip:token:)` explicit init bypasses Keychain | Code-inspected |

Pairing uses HTTP on port 80; **ongoing v2 API uses HTTPS to IP** regardless of bridge HTTP discovery port.

## Android MVP Resource Reads

| Domain | HTTP method | Endpoint | Auth | iOS source | Evidence | Android requirement |
| --- | --- | --- | --- | --- | --- | --- |
| Rooms | GET | `/clip/v2/resource/room` | `hue-application-key` | `HueAPIClient.fetchRooms` | Code-inspected | Android-MVP |
| Zones | GET | `/clip/v2/resource/zone` | same | `fetchZones` | Code-inspected | Android-MVP |
| Lights | GET | `/clip/v2/resource/light` | same | `fetchLights` | Code-inspected | Android-MVP |
| Grouped lights | GET | `/clip/v2/resource/grouped_light` | same | `fetchGroupedLights` | Code-inspected | Android-MVP |
| Scenes | GET | `/clip/v2/resource/scene` | same | `fetchScenes` | Code-inspected | Android-MVP |
| Single grouped light | GET | `/clip/v2/resource/grouped_light/{id}` | same | `fetchGroupedLight` | Code-inspected | Post-MVP unless needed |
| Devices | GET | `/clip/v2/resource/device` | same | `fetchDevicesRaw` | Code-inspected | Post-MVP |
| Automations | GET | `/clip/v2/resource/behavior_instance` | same | `fetchAutomations` | Code-inspected | Post-MVP |

`loadAll` fetches rooms, zones, lights, grouped lights **in parallel per bridge** (`UnifiedOrchestrator.fetchAndMergeAllBridges`).

## Android MVP Mutations

| Domain | HTTP method | Endpoint | Payload shape | Clamping / quirks | Evidence | Android requirement |
| --- | --- | --- | --- | --- | --- | --- |
| Grouped on/off | PUT | `/clip/v2/resource/grouped_light/{id}` | `{"on":{"on":bool}}` | — | Code-inspected | Android-MVP |
| Grouped brightness | PUT | same | `{"dimming":{"brightness":n}}` | **1–100**, rounded | Code-inspected | Android-MVP |
| Grouped atomic state | PUT | same | `on` + `dimming` together | brightness **1–100** rounded | Code-inspected | Android-MVP (room brightness slider uses this) |
| Light on/off | PUT | `/clip/v2/resource/light/{id}` | `{"on":{"on":bool}}` | — | Code-inspected | Android-MVP |
| Light brightness | PUT | same | `{"dimming":{"brightness":n}}` | **1–100** (not rounded in code) | Code-inspected | Android-MVP |
| Light atomic state | PUT | same | `on` + `dimming` | brightness **1–100** | Code-inspected | Android-MVP |
| Light xy color | PUT | same | `{"color":{"xy":{"x","y"}}}` | No clamp in client | Code-inspected | Android-MVP |
| Light mirek | PUT | same | `{"color_temperature":{"mirek":n}}` | **No clamp** on per-light (grouped mirek clamps 153–500) | Code-inspected | Android-MVP |
| Scene activation | PUT | `/clip/v2/resource/scene/{id}` | `{"recall":{"action":"active"}}` optional `{"dynamics":{"speed":0..1}}` | speed clamped **0.0–1.0** when provided | Code-inspected | Android-MVP |
| Grouped mirek | PUT | grouped_light | `color_temperature.mirek` | 153–500 | Code-inspected | Post-MVP unless UI exposes |
| Native effects | PUT | light/grouped_light | `effects.effect` | Studio/Effects — Post-MVP | Code-inspected | Post-MVP |

**Live callers (MVP-critical):** `UnifiedOrchestrator.setRoom` / `setBrightness` → grouped_light; `RoomDetailViewModel` → per-light controls; `activateGlobalScene` → scene recall.

## Dashboard List Composition Contract

| Rule | Behavior | Evidence |
| --- | --- | --- |
| Separate lists | Rooms (`allRooms`) and zones (`allZones`) are distinct | Code-inspected |
| Flatten | `DashboardDisplayModelBuilder` flatMaps `roomsByBridge` / `zonesByBridge` values | Code-inspected |
| Sort | `localizedCompare` ascending on `name` | Simulator-pinned (builder tests) + Code-inspected |
| Dedup | `Set` on resource `id` — first wins after sort | Code-inspected |
| Bridge routing | Each `RoomDisplayItem` retains `bridgeID` | Code-inspected |

## Room Display Contract

Built by `RoomAndZoneDisplayModelBuilder` after per-bridge fetch:

| Rule | Behavior | Evidence |
| --- | --- | --- |
| On/off | From matching `grouped_light` by `room.groupedLightID` | Code-inspected |
| Brightness | From grouped_light dimming; **`max(1, …)`**; default 100 if missing GL | Code-inspected |
| Missing grouped_light | `isOn = false`, brightness 100 | Code-inspected |
| Light membership | Child `rid` matches `light.id` **or** `light.owner?.rid` | Code-inspected |
| Dominant xy | While group on: brightest on-light with `color` | Code-inspected |
| Dominant mirek | Else brightest on-light with `color_temperature` | Code-inspected |
| Dominant when off | No dominant color computed | Code-inspected |
| lightCount | Count of resolved room lights | Code-inspected |
| childResourceRefs | Stored from room children | Code-inspected |

## Zone Display Contract

| Rule | Behavior | Evidence |
| --- | --- | --- |
| Kind | `item.kind = .zone` | Code-inspected |
| Lights | Zone children match `light.id` directly (not owner chain) | Code-inspected |
| Grouped light / brightness | Same rules as rooms | Code-inspected |
| Dominant color | Same brightest-on-light logic as rooms | Code-inspected |

## Cache and Stale-State Contract

| Behavior | Detail | Evidence |
| --- | --- | --- |
| `preloadCached` | Sync; only if `allRooms.isEmpty` and cache non-empty; sorts by cached name; clamps brightness `max(1, …)`; fills **`roomsByBridge`** | Simulator-pinned + Code-inspected |
| No clients `loadAll` | Skips fetch; **does not clear** visible rooms | Code-inspected |
| Concurrent `loadAll` | Second call returns early while `isLoading` | Code-inspected |
| Per-bridge fetch fail | Returns `nil` rooms/zones — **keeps prior** `roomsByBridge` entry (stale-while-revalidate) | Simulator-pinned (`OrchestratorLoadAllTests`) + Code-inspected |
| Success path | Rebuilds `allRooms`/`allZones`, sets `lastLoadedAt = Date()` **even after errors on other bridges** (completion-based) | Code-inspected |
| `writeCache` | Persists `allRooms` snapshot to SwiftData `HueLocalRoom` | Code-inspected |
| Connection status | `.connecting` → `.connected` or `.error(message)` per bridge | Code-inspected |

## Optimistic Mutation and Rollback Contract

| Flow | Behavior | Evidence |
| --- | --- | --- |
| `setRoom` | `updateRoom` **before** PUT; `pendingActionDeadlines[glID] = now+1.5s`; success → `scheduleStateRefresh()` (debounced `loadAll` after 1.5s); failure → rollback to `!desiredState` + toast | Simulator-pinned + Code-inspected |
| `setBrightness` | Optimistic on + brightness; atomic `setGroupedLightState`; rollback to prior `isOn`/`brightness` on failure | Code-inspected |
| SSE during pending | Skips grouped_light on/brightness apply while deadline active | Code-inspected |
| `turnAllOff` | Optimistic OFF all rooms + `roomsByBridge`; per-room PUT with **`try?`** (failures swallowed) | Simulator-pinned + Code-inspected |
| Demo mode | Local-only mutations; `loadAll` → `loadDemoData` no network | Simulator-pinned + Code-inspected |

## Demo Mode Contract

| Item | Behavior | Evidence |
| --- | --- | --- |
| Enter | `isDemoMode = true`; `loadDemoData()` | Code-inspected |
| Data | `DemoDataProvider.rooms`, multi-bridge `roomsByBridge`, mock `connectionStatus` | Code-inspected |
| Network | No bridge clients required; SSE not started | Code-inspected |
| Exit | Clears rooms, clients, SSE tasks | Code-inspected |

## Scene MVP Contract

### Android-MVP (required)

| Capability | iOS path | Contract |
| --- | --- | --- |
| List scenes | `loadAllScenes()` parallel per bridge; merge to `globalScenes` | GET `/clip/v2/resource/scene` |
| Activate | `activateGlobalScene` → `activateScene(id:speed:)` | PUT `/clip/v2/resource/scene/{id}` with `recall.action = "active"`; optional `recall.dynamics.speed` clamped 0–1 for **dynamic** scenes only |

### Post-MVP (present on iOS, exclude from Android MVP)

| Capability | iOS evidence |
| --- | --- |
| Create scene | `createScene`, `createSceneFromRoom`, `RoomDetailViewModel.createScene`, `ScenesTabView` create sheet |
| Edit / rename | `renameScene`, `updateScene`, `renameGlobalScene` |
| Delete | `deleteScene`, `deleteGlobalScene` |
| Dynamic palette activation | `activateDynamicScene` (`recall.action = dynamic_palette`) — Composer/bridge animation |
| Scene builder / harmony | `SceneColorBuilderView` |

**TODO-PRODUCT:** Android scenes tab — room-scoped list only vs iOS global cross-bridge grid with filters.

**TODO-HARDWARE:** Scene list + activation on physical bridge(s).

## SSE Eventstream Contract

### Live implementation

**`UnifiedOrchestrator.runSSE(bridgeID:client:)`** is the **only wired** SSE path. **`HueSSEService.swift` is not referenced** elsewhere under `HueHome/` (architecture debt / alternate implementation).

| Item | Value | Evidence |
| --- | --- | --- |
| Endpoint | `GET https://{ip}/eventstream/clip/v2` | Code-inspected |
| Headers | `hue-application-key`, `Accept: text/event-stream` | Code-inspected |
| Transport | `sseSession.bytes(for:)` → `bytes.lines` | Code-inspected |
| Line filter | Only lines with prefix `data:`; JSON after prefix trimmed | Code-inspected |
| Decode | `try? sseDecoder.decode([SSEEvent].self)` — malformed **silently skipped** | Simulator-pinned (decoder test) + Code-inspected |
| Reconnect | Loop with backoff **5 → 10 → 20 → 40 → 60 s** (cap); reset to 5s on connect | Code-inspected |
| Lifecycle | Background → `stopSSE`; foreground → `startSSE` | Code-inspected |
| Demo | No SSE when `isDemoMode` | Code-inspected |
| Per bridge | One `Task` per `clients` entry | Code-inspected |

### Android target (behavioral, not library-specific)

- One SSE connection per active bridge.
- Lifecycle-owned cancellation.
- Visible-state reducer equivalent to `applySSEEvent` + conditional rebuild.
- Optimistic suppression via pending deadlines.
- Bounded retry with capped backoff.
- Offline/error surfaced via `connectionStatus` analogue.

**TODO-HARDWARE:** SSE lifecycle, Wi-Fi drop, reconnect.

## SSE Reducer Contract

`applySSEEvent(_:bridgeID:)` → `(roomsMutated, zonesMutated)`:

| `type` | Behavior | Evidence |
| --- | --- | --- |
| `grouped_light` | Match `groupedLightID`; unless pending deadline: apply `on`, `dimming.brightness` to room/zone in `roomsByBridge`/`zonesByBridge` | Simulator-pinned (grouped_light + rebuild) + Code-inspected |
| `light` | If `on == false` skip; else update dominant xy or mirek on room/zone via light maps | Code-inspected |
| unknown | `default: continue` — no mutation | Simulator-pinned + Code-inspected |
| Visible arrays | Caller runs `rebuildAllRooms` / `rebuildAllZones` when flags true | Simulator-pinned + Code-inspected |
| Light fan-out | `lightEventContinuation?.yield(rawUpdates)` for room detail subscriber | Code-inspected |

Navigation guard: while `isNavigating`, rebuilds deferred up to **450 ms** then flushed.

## REST v1 Relevance Assessment

**Verdict: Not required by Android MVP.**

| iOS usage | Purpose |
| --- | --- |
| `UnifiedOrchestrator` + `BridgeAnimationEngine` | Composer bridge-stored animations (Post-MVP) |
| `SettingsView` | Resource cleanup |
| `BridgeAnimationEngine` | v1 scene/rule upload and purge |

Android MVP must not pull v1 in solely because iOS retains it.

## Recommended Native Android Boundaries

**Recommended Android boundary** (documentation only — no Gradle modules created):

```text
app/
  navigation and Compose shell

core/model/
  bridge, room, zone, light, grouped-light, scene display models

core/hue/discovery/
  LAN discovery
  NUPnP fallback
  manual IP validation

core/hue/pairing/
  link-button pairing
  local certificate policy boundary

core/hue/rest/
  Hue v2 request builder
  typed resource reads
  typed control mutations
  scene activation

core/hue/sse/
  eventstream connection
  retry/backoff
  reducer
  lifecycle cancellation

core/credentials/
  Android Keystore secret storage
  Room/DataStore bridge routing metadata

feature/demo/
  local demo provider

feature/dashboard/
  room and zone visible-state composition
  optimistic mutation and rollback

feature/roomdetail/
  grouped and individual light controls

feature/scenes/
  list and activate
```

Do **not** implement a single Android god-object mirroring `UnifiedOrchestrator`; split discovery, REST, SSE, and feature state.

## Android MVP Acceptance Matrix

| ID | Flow | iOS evidence | Android acceptance criterion | Validation type | Open dependency |
| --- | --- | --- | --- | --- | --- |
| ANDROID-MVP-001 | Demo launch | Demo mode + cache tests | Demo shows rooms without network | Unit + UI smoke | — |
| ANDROID-MVP-002 | mDNS discovery | `BridgeDiscoveryService` | Finds bridge on LAN with `_hue._tcp` | Physical Hue bridge | TODO-HARDWARE |
| ANDROID-MVP-003 | NUPnP fallback | `BridgeDiscoveryViewModel` 12s path | Cloud discovery returns bridge when mDNS blocked | Physical Hue bridge | TODO-HARDWARE |
| ANDROID-MVP-004 | Manual IP | `BridgeSetupView` sheet | User can enter IP and reach pair screen | Integration + Product | TODO-PRODUCT |
| ANDROID-MVP-005 | Pairing success | Pairing POST | Token persisted; dashboard reachable | Physical Hue bridge | TODO-SECURITY, TODO-HARDWARE |
| ANDROID-MVP-006 | Link button retry | Error 101 → `bridgeFound` | Retry without hard error state | Integration | TODO-HARDWARE |
| ANDROID-MVP-007 | Credential persistence | Keychain + `BridgeRecord` | Relaunch restores bridge session | Integration | — |
| ANDROID-MVP-008 | Cached dashboard | `preloadCached` tests | Stale cache visible before refresh | Unit | — |
| ANDROID-MVP-009 | Rooms and zones | Display builders + loadAll | Separate sorted lists, correct aggregation | Unit | — |
| ANDROID-MVP-010 | Multi-bridge routing | `configure` dedup | Two bridges route independently; duplicate IP deduped | Physical Hue bridge | TODO-HARDWARE |
| ANDROID-MVP-011 | Room optimistic toggle | `OrchestratorOptimisticUpdateTests` MUT-01 | UI toggles before PUT completes | Unit | — |
| ANDROID-MVP-012 | Failed room toggle rollback | MUT-02 | Reverts on PUT failure | Unit | — |
| ANDROID-MVP-013 | Room brightness | `setGroupedLightState` | Atomic on+brightness PUT | Integration | TODO-HARDWARE |
| ANDROID-MVP-014 | Light toggle | `RoomDetailViewModel.setLight` | Per-light on/off | Integration | TODO-HARDWARE |
| ANDROID-MVP-015 | Light brightness | `setLightState` | Per-light brightness | Integration | TODO-HARDWARE |
| ANDROID-MVP-016 | Light xy | `setLightColor` | Color PUT | Integration | TODO-HARDWARE |
| ANDROID-MVP-017 | Light mirek | `setLightColorTemp` | CCT PUT | Integration | TODO-HARDWARE |
| ANDROID-MVP-018 | Scene list | `loadAllScenes` | Scenes load per bridge | Integration | TODO-HARDWARE |
| ANDROID-MVP-019 | Scene activation | `activateGlobalScene` | PUT recall active | Integration | TODO-HARDWARE |
| ANDROID-MVP-020 | SSE grouped_light | `OrchestratorSSETests` SSE-01 | Visible room card updates | Unit (+ Hardware for stream) | TODO-HARDWARE |
| ANDROID-MVP-021 | SSE unknown ignored | SSE-03 | Unknown types no-op | Unit | — |
| ANDROID-MVP-022 | Offline stale state | `OrchestratorLoadAllTests` | Failed bridge keeps prior rooms | Unit | TODO-HARDWARE |
| ANDROID-MVP-023 | SSE reconnect/backoff | `runSSE` loop | Backoff capped at 60s | Integration | TODO-HARDWARE |

## Explicit Android Non-Parity Decisions

- Do not copy SwiftUI architecture or single-window assumptions blindly.
- Do not copy `UnifiedOrchestrator` as one Android god object.
- Do not route required local Hue control through a backend.
- Do not store bridge API tokens in ordinary preferences.
- Do not copy iOS App Group / widget credential publication (`WidgetDataStore`, `WidgetBridgeCredentials`).
- Do not build widget / watch / App Intent behavior into Android MVP.
- Do not port Studio / Composer / DTLS / microphone sync into Android MVP.
- Do not copy the unwired `HueSSEService` as if it were the live SSE source.
- Do not silently normalize current iOS quirks (e.g. `lastLoadedAt` on partial failure, `turnAllOff` swallowing errors, manual IP always port 443) without product review.

## Open Questions Before Android MVP Signoff

### TODO-SECURITY

- Android certificate trust strategy for Hue self-signed HTTPS to LAN IP (pairing + REST + SSE).
- Whether to use network security config, custom trust manager, or per-bridge TOFU store.
- ProGuard/R8 rules for TLS delegate classes.

### TODO-HARDWARE

- mDNS on representative Android phones and home routers.
- NUPnP fallback when cloud reachable but LAN isolated.
- Manual IP with HTTP:80 vs HTTPS:443 bridges.
- Pairing on older square bridges vs newer HTTPS bridges.
- SSE connection stability and reconnect after Wi-Fi change.
- Multi-bridge with two physical bridges; one offline while other works.
- Scene list and activation against real firmware.
- Per-light color/mirek on real lamps.

### TODO-PRODUCT

- Zones first-class in Android MVP UI (iOS shows zones separately).
- Manual IP in first Android release (iOS already ships).
- Dynamic scene speed UI in MVP (iOS has speed sheet for dynamic scenes).
- Device list tab in MVP.
- Global cross-bridge scenes browser vs room-only scene list.
- Android `devicetype` string branding on bridge.

## Hardware Validation Checklist

- [ ] Pair HTTP and HTTPS bridges after link button.
- [ ] mDNS discovery on primary test router.
- [ ] NUPnP fallback with mDNS blocked.
- [ ] Manual IP entry on HTTPS bridge.
- [ ] Room toggle, brightness, all-off.
- [ ] Room detail per-light on, brightness, xy, mirek.
- [ ] Scene list and activate (static + dynamic if in scope).
- [ ] SSE updates grouped_light from physical switch/app.
- [ ] Wi-Fi drop / restore SSE.
- [ ] Two bridges registered; one powered off.

## Source Files Inspected

- `HueHome/Core/Network/BridgeDiscoveryService.swift`
- `HueHome/Core/ViewModels/BridgeDiscoveryViewModel.swift`
- `HueHome/UI/BridgeSetup/BridgeSetupView.swift`
- `HueHome/Core/Keychain/KeychainManager.swift`
- `HueHome/Core/Models/HueDataModels.swift` (`BridgeRecord`)
- `HueHome/Core/Network/HueAPIClient.swift`
- `HueHome/Core/Network/HueV1Client.swift`
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
- `HueHome/Core/Network/HueSSEService.swift`
- `HueHome/Core/Dashboard/DashboardDisplayModelBuilder.swift`
- `HueHome/Core/Dashboard/RoomAndZoneDisplayModelBuilder.swift`
- `HueHome/Core/ViewModels/RoomDetailViewModel.swift`
- `HueHome/UI/Scenes/ScenesTabView.swift`
- `HueHome/Core/AppBrand.swift`
- `HueHomeTests/OrchestratorCacheDemoTests.swift`
- `HueHomeTests/OrchestratorLoadAllTests.swift`
- `HueHomeTests/OrchestratorOptimisticUpdateTests.swift`
- `HueHomeTests/OrchestratorSSETests.swift`

## Existing Repo Docs Consulted

- `DEVDOC.md`, `DEVLOG.md`, `.cursorrules`, `CURSOR_KICKOFF.md`
- `docs/ios/stabilization-map.md`
- `docs/ios/current-behavior-map.md`
- `docs/ios/hue-contract-inventory.md`
- `docs/ios/persistence-and-credentials.md`
- `docs/ios/regression-smoke-matrix.md`
- `docs/ios/orchestrator-tests-membership-repair-inventory.md`
- `docs/ios/orchestrator-loadall-harness-repair-inventory.md`
- `docs/ios/orchestrator-optimistic-update-recovery-inventory.md`
- `docs/ios/orchestrator-sse-recovery-inventory.md`
- `.cursor/rules/*.mdc` (architecture, hue-bridge, session-log, build-verify, etc.)

## Known Source-Doc Discrepancies

| Topic | Older doc statement | Current source truth |
| --- | --- | --- |
| SSE primary path | `docs/ios/hue-contract-inventory.md` lists `HueSSEService.swift` as eventstream owner | **`UnifiedOrchestrator.runSSE`** is live; `HueSSEService` unwired |
| Credential map | `docs/ios/persistence-and-credentials.md` many TODOs | Key patterns and migration now defined in `KeychainManager` + `configure` |
| Manual IP | Partially documented in iOS maps | Full path in `BridgeSetupView` — port **443 fixed**, minimal validation |
| REST v1 Android relevance | Listed "Maybe" in hue-contract-inventory | **Not required** for Android MVP (Composer/Settings only) |
| Global scenes | Product brief defers "global scenes" | iOS MVP UI uses **`globalScenes`** for list/activate; Android MVP includes **list+activate**, not CRUD |
| DEVLOG next step | Prior entries recommend IOS-TEST-003B6 warnings | This freeze adds **ANDROID-CONTRACT-001** as next platform step |

Recommend a **narrow docs/ios reconciliation PR** later (SSE path, credential table, v1 relevance) without blocking Android work.

## Follow-Up Recommendation

1. **Do not** start Android Gradle project until product signs TODO-SECURITY / critical TODO-PRODUCT items.
2. Run deferred **iOS physical-device smoke** (dashboard, room, zone, scene, SSE) after this docs PR merges — not required to author this contract.
3. Next implementation tranche: Android `core/hue/discovery` + `pairing` + `credentials` with HARDWARE checklist gate.
4. Optional: IOS-TEST-003B6 warning triage on iOS remains independent.
