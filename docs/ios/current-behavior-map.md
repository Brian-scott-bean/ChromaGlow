# Current iOS Behavior Map

## Purpose

This document records what the current native iOS app actually does. It is a behavior map, not a redesign proposal.

Use this file to protect the TestFlight app during stabilization and to give Android parity work a concrete reference point.

## Documentation rules

- Describe current behavior before proposing changes.
- Mark unknowns as `TODO` instead of guessing.
- Link behavior back to primary files where possible.
- Separate shipped behavior from planned behavior.
- Preserve known quirks until they are intentionally changed.

## Behavior status legend

| Status | Meaning |
|---|---|
| Documented | Behavior has been verified and written down |
| Partial | Some behavior is known, but gaps remain |
| TODO | Needs verification |
| Not in baseline | Not part of the current accepted TestFlight baseline |

## App launch and shell

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| App entry | Initializes app-level state and injects orchestration into SwiftUI environment | `HueHomeApp.swift`, `MainTabView.swift` | Partial | Confirm exact launch gate behavior against Build 21 |
| Auth/pairing gate | Determines whether the app opens into pairing/setup or main app UI | `HueHomeApp.swift`, `BridgeSetupView.swift`, `UnifiedOrchestrator.swift` | TODO | Document clean install vs existing install behavior |
| Main navigation | Tab-based SwiftUI shell | `MainTabView.swift`, `TabShells.swift` | TODO | Confirm tab order and deferred/prewarmed tabs |
| Splash/loading | Shows launch/loading experience | `SplashView.swift` | TODO | Capture expected duration and error states |

## Demo mode

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Demo data | Provides local demo rooms/lights/scenes without a real bridge | `DemoDataProvider.swift` | TODO | Confirm how user enters/exits demo mode |
| Demo dashboard | Renders dashboard from demo state | `DashboardView.swift`, `UnifiedOrchestrator.swift` | TODO | Verify actions are simulated safely |
| Demo room detail | Allows room/light exploration without bridge calls | `RoomDetailView.swift`, `RoomDetailViewModel.swift` | TODO |  |
| Demo scenes | Shows demo scenes | `ScenesTabView.swift`, `SceneDisplayItem.swift` | TODO |  |

## Bridge discovery and pairing

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| mDNS/Bonjour discovery | Discovers Hue bridges on local network | `BridgeDiscoveryService.swift` | Partial | Document local network permission behavior |
| NUPnP fallback | Uses Hue discovery fallback when local discovery is unavailable | `BridgeDiscoveryService.swift` | Partial | Confirm endpoint and timeout behavior |
| Manual IP entry | TODO | `BridgeSetupView.swift`, `BridgeDiscoveryViewModel.swift` | TODO | Verify whether supported |
| Link button pairing | Pairs against bridge and stores app key | `BridgeDiscoveryViewModel.swift`, `HueAPIClient.swift`, `KeychainManager.swift` | TODO | Document user-facing errors |
| Entertainment client key | Captures/stores entertainment key where available | `EntertainmentConfigManager.swift`, `HueEntertainmentClient.swift`, `KeychainManager.swift` | TODO | Needed for Studio/sync parity |

## Dashboard

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Room list | Displays rooms/zones/lights summary | `DashboardView.swift`, `RoomDisplayItem.swift`, `LightDisplayItem.swift` | TODO | Confirm sorting/grouping |
| Room on/off | Toggles room/group state | `DashboardView.swift`, `UnifiedOrchestrator.swift` | TODO | Capture optimistic UI and rollback behavior |
| Brightness summary | Shows current or derived brightness | `DashboardView.swift`, `RoomDisplayItem.swift` | TODO | Confirm aggregation behavior |
| Offline state | Handles unavailable bridge/room/light state | `DashboardView.swift`, `UnifiedOrchestrator.swift` | TODO |  |
| Multi-bridge state | Shows rooms across one or more bridges | `BridgeRecord`, `UnifiedOrchestrator.swift`, `DashboardView.swift` | TODO | Confirm display/routing rules |

## Room detail and light control

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Room detail open | Opens room detail from dashboard | `RoomDetailView.swift`, `RoomDetailViewModel.swift` | TODO |  |
| Individual light control | Controls on/off, brightness, and color | `LightControlView.swift`, `RoomDetailViewModel.swift` | TODO |  |
| Bulk actions | Applies actions to multiple lights | `BulkActionBar.swift`, `RoomDetailView.swift` | TODO |  |
| Scene chips | Displays and activates room scenes | `SceneChip.swift`, `SceneEditBar.swift`, `RoomDetailView.swift` | TODO |  |
| Create scene from room | Creates scenes from selected lights/colors | `CreateSceneView.swift`, `CreateSceneRequest.swift`, `HueAPIClient.swift` | TODO |  |

## Scenes

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Scenes tab | Displays available scenes/global scenes | `ScenesTabView.swift`, `GlobalSceneItem`, `SceneDisplayItem.swift` | TODO |  |
| Scene activation | Activates Hue scene/group behavior | `HueAPIClient.swift`, `UnifiedOrchestrator.swift` | TODO | Document resource target rules |
| Global scene creation | Creates or composes scenes across rooms/bridges | `CreateGlobalSceneView.swift`, `ScenesTabView.swift` | TODO | Confirm Build 21 scope |
| Scene color builder | Builds scene palettes/colors | `SceneColorBuilderView.swift`, `ColorPadView.swift`, `HarmonyEngine.swift` | TODO |  |

## Studio/composer

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Studio launch | Opens Studio tab/surface | `StudioView.swift`, `StudioViewModel.swift` | TODO | Capture performance expectations |
| Composition model | Stores/edits compositions | `CompositionModels.swift`, `CompositionStore.swift`, `CompositionEngine.swift` | TODO |  |
| Palette behavior | Applies or previews color palettes | `StudioView.swift`, `StudioViewModel.swift`, `BridgeAnimationEngine.swift` | TODO |  |
| Motion/spatial behavior | Applies motion patterns/effects | `StudioViewModel.swift`, `BridgeAnimationEngine.swift` | TODO | Document current math/transport rules |
| Apply to bridge | Sends composition/effect to Hue bridge | `StudioViewModel.swift`, `HueAPIClient.swift`, `HueEntertainmentClient.swift` | TODO | Distinguish REST vs DTLS behavior |
| Save preset/composition | Persists reusable composition/effect state | `CompositionStore.swift`, `SavedEffectPreset.swift` | TODO |  |

## Sync/music modes

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Sync mode view | Opens sync/music mode UI | `SyncModeView.swift` | TODO |  |
| Microphone capture | Captures audio for reactive effects | `CompositionMicCapture.swift`, `SyncModeEngine.swift` | TODO | Confirm permission prompts |
| Visualizer engine | Converts input into visual/light behavior | `VisualizerEngine.swift` | TODO |  |
| Ambient engine | Ambient-style sync/effects | `AmbientEngine.swift` | TODO |  |
| Gaming engine | Gaming-style sync/effects | `GamingEngine.swift` | TODO |  |
| Entertainment transport | Uses DTLS/UDP entertainment path | `HueEntertainmentClient.swift`, `EntertainmentConfigManager.swift` | TODO |  |

## Devices and bridge management

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Devices tab | Displays Hue devices/lights/resources | `DevicesView.swift`, `DevicesViewModel.swift` | TODO |  |
| Bridge manager | Shows/manages paired bridge records | `BridgeManagerView.swift`, `BridgeRecord`, `UnifiedOrchestrator.swift` | TODO |  |
| Multi-bridge routing | Routes actions to the correct bridge | `UnifiedOrchestrator.swift`, `BridgeRecord` | TODO | Critical for Android parity |

## Automations and notifications

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Automation list | Shows user automations | `AutomationsView.swift`, `AutomationsViewModel.swift` | TODO |  |
| Create automation | Creates local automation rules | `CreateAutomationView.swift`, `AppAutomation.swift` | TODO |  |
| Scheduling | Schedules local notifications/actions | `AutomationScheduler.swift` | TODO | Distinguish local notification vs background execution |
| Handling | Handles automation trigger | `AutomationHandler.swift` | TODO |  |

## Widgets, App Intents, and watch

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Widget rendering | Shows room/control widgets | `HueHomeWidget.swift`, `WidgetDataStore.swift` | TODO |  |
| Widget action | Runs room/widget intents | `WidgetIntents.swift`, `SelectRoomIntent.swift`, `RoomAppEntity.swift` | TODO |  |
| App shortcuts | Exposes App Intents/Siri shortcuts | `HueAppShortcuts.swift`, `HueIntents.swift`, `HueIntentAPIClient.swift` | TODO |  |
| Watch app | Provides watch UI/actions | `LightShadeWatch.swift`, `WatchStore.swift`, watch app files | TODO |  |
| Watch sync | Syncs room state/payloads | `WatchConnectivity` usage, `WatchWidgetStore.swift`, `WatchStore.swift` | TODO |  |

## Settings and more

| Item | Current behavior | Primary files | Status | Notes |
|---|---|---|---|---|
| Settings | App settings surface | `SettingsView.swift` | TODO |  |
| More tab | Secondary actions/info | `MoreView.swift` | TODO |  |
| Privacy manifest | Declares platform privacy usage | `PrivacyInfo.xcprivacy` | TODO | Verify before release changes |

## Open behavior questions

- What exact behavior shipped in TestFlight Build 21?
- Which Studio/composer features are considered stable vs experimental?
- Which widget/watch/App Intent behaviors are required for current iOS parity?
- Which multi-bridge flows have been tested with real hardware?
- Which current bugs are accepted into the baseline?
- Which planned features are documented but not implemented?
