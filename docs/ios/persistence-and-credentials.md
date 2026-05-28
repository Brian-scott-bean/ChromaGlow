# iOS Persistence and Credential Map

## Purpose

This document maps where ChromaGlow iOS stores local state, bridge credentials, widget/watch snapshots, and legacy compatibility data.

The goal is to prevent accidental breakage while preserving the current TestFlight app and preparing Android parity. This document should be updated before changing Keychain, SwiftData, App Group, widget, watch, or App Intent behavior.

## Storage boundaries

| Boundary | Current role | Primary files | Risk level | Notes |
|---|---|---|---:|---|
| SwiftData | App-local persisted domain/cache state | `HueHomeApp.swift`, model files under `HueHome/Core/Models/` | Medium | Document exact model list before schema changes |
| Keychain | Sensitive bridge credentials and tokens | `KeychainManager.swift` | High | Do not change without migration plan |
| App Group UserDefaults | Shared snapshots/data for widgets/watch/intents | `WidgetDataStore.swift`, widget/watch files | High | Current contract must be documented before cleanup |
| Local notification schedule | Automation trigger support | `AutomationScheduler.swift`, `AutomationHandler.swift` | Medium | Verify behavior before Android parity decisions |
| Watch stores | Watch-side payload persistence/cache | `WatchStore.swift`, `WatchWidgetStore.swift` | Medium | Apple-only but behavior still affects iOS baseline |

## SwiftData model inventory

| Model/file | Current role | Android parity relevance | Status | Notes |
|---|---|---:|---|---|
| `BridgeRecord` | Paired bridge record and routing metadata | Yes | TODO | Confirm fields and multi-bridge identifiers |
| `HueLocalRoom` | Local room/cache model | Yes | TODO |  |
| `HueLocalScene` | Local scene/cache model | Yes | TODO |  |
| `EffectPreset` / `SavedEffectPreset` | Saved effect/composer state | Later | TODO | Studio parity |
| `FavouriteColor` | User color preference/favorite | Later | TODO |  |
| `ActivityEvent` | App activity/history | Maybe | TODO |  |
| `EnergySnapshot` | Energy/usage style state | Maybe | TODO |  |
| `AppSettings` | Local settings | Yes | TODO | Android should mirror relevant settings |
| `AppAutomation` | Local automation definition | Later | TODO | Android MVP may exclude automations |
| `CompositionModels` | Composer/studio state | Later | TODO |  |
| `CompositionStore` | Composition persistence | Later | TODO |  |

## Credential inventory

| Credential/data | Expected storage | Primary files | Shared outside app? | Status | Notes |
|---|---|---|---:|---|---|
| Hue application key | Keychain | `KeychainManager.swift`, `HueAPIClient.swift` | TODO | TODO | Required for bridge REST control |
| Hue entertainment client key | Keychain | `KeychainManager.swift`, `EntertainmentConfigManager.swift`, `HueEntertainmentClient.swift` | TODO | TODO | Required for DTLS entertainment |
| Bridge ID / IP / name | SwiftData and/or App Group snapshot | `BridgeRecord`, `WidgetDataStore.swift` | Yes | TODO | Needed for routing |
| Widget room snapshot | App Group UserDefaults | `WidgetDataStore.swift`, `HueHomeWidget.swift` | Yes | TODO | Do not change shape without widget test |
| Watch room payload | WatchConnectivity/watch store | `WatchStore.swift`, `WatchWidgetStore.swift` | Yes | TODO | Apple-only but baseline critical |
| Legacy single-bridge fallback keys | App Group/UserDefaults or compatibility layer | `WidgetDataStore.swift`, `UnifiedOrchestrator.swift` | TODO | TODO | Document before removal |

## Current risks

- Credential and routing data may be used by the main app, widgets, App Intents, and watch targets through different paths.
- Legacy single-bridge behavior may coexist with newer multi-bridge behavior.
- App Group data shape changes can silently break widgets or App Intents even if the main app still works.
- A safer future state should avoid exposing raw credentials anywhere that does not need them, but that cleanup should not be attempted before the current contract is known.

## Do-not-change areas until mapped

Do not change these until the relevant contract is documented and smoke-tested:

- Keychain key names
- Bridge credential migration behavior
- App Group suite name
- App Group key names
- Widget snapshot payload shape
- App Intent entity identifiers
- Watch payload shape
- Legacy fallback keys
- Multi-bridge routing metadata

## Future safer target state

Candidate direction only; not approved for immediate implementation:

- Main app owns bridge credentials in Keychain.
- Widget/watch/intents receive the minimum routing and display state needed.
- Raw bridge credentials are not copied into broad shared preference storage.
- Widget/watch actions route through a clearly documented action boundary.
- Legacy single-bridge fallback data is migrated or retired only after usage is verified.
- Android uses Keystore/DataStore/Room boundaries rather than copying iOS storage mechanics directly.

## Persistence change checklist

Before changing storage behavior:

- [ ] Does this affect a current TestFlight user upgrading from Build 21?
- [ ] Does this affect widgets?
- [ ] Does this affect App Intents/Siri?
- [ ] Does this affect watch?
- [ ] Does this affect multi-bridge routing?
- [ ] Is there a rollback/migration plan?
- [ ] Is the regression smoke matrix updated?
- [ ] Is Android parity affected?

## Open questions

- Which exact Keychain keys are used today?
- Which exact App Group suite and key names are in use?
- Which widget/watch payloads include bridge credentials vs display-only snapshots?
- Which legacy single-bridge fallback keys are still required?
- Does Build 21 include any migration logic for older installs?
- What is the safe migration path to reduce credential exposure without breaking widgets/watch?
