# iOS Large File Responsibility Map

## Purpose

This document maps the responsibilities and risk areas of the largest iOS files before any extraction work begins.

The goal is to identify safe future seams without rewriting the current TestFlight app prematurely.

## Rules for this map

- This file is descriptive first, prescriptive second.
- Do not split a large file just because it is large.
- Identify behavior, side effects, callers, and regression risk before moving code.
- Any extraction candidate must have a smoke-test path and, ideally, unit tests around pure logic.

## Summary

| File | Current role | Risk | First safe action |
|---|---|---:|---|
| `UnifiedOrchestrator.swift` | App-wide bridge/state/action coordinator | Very high | Responsibility inventory only |
| `StudioView.swift` | Large Studio/composer UI surface | High | UI section map only |
| `StudioViewModel.swift` | Studio/composer state and apply logic | High | Separate pure model/math candidates only after tests |
| `DashboardView.swift` | Main dashboard UI and room actions | High | Document view state and action routing |
| `RoomDetailView.swift` | Room/light detail UI | High | Document flows and UI states |
| `RoomDetailViewModel.swift` | Room detail state/actions | High | Document action methods and side effects |
| `HueAPIClient.swift` | Hue CLIP v2 REST client | High | Endpoint/payload inventory |
| `HueV1Client.swift` | Legacy Hue v1 client | Medium/high | Determine required v1 behavior |
| `HueEntertainmentClient.swift` | DTLS/UDP entertainment client | High | Document session lifecycle |

## `UnifiedOrchestrator.swift`

### Current responsibilities

- App-level bridge orchestration
- Bridge registry and multi-bridge routing
- Dashboard state loading and updates
- Room/zone/light state coordination
- Scene operations
- SSE connection handling
- Cache preload/writeback behavior
- Entertainment/sync routing
- Automation support touchpoints
- Widget/watch/intents support touchpoints where applicable

### Side effects to document

- Network calls to Hue bridges
- Keychain reads/writes through credential helpers
- SwiftData reads/writes
- App Group snapshot writes
- SSE connection lifecycle
- UI state mutation
- Rollback behavior after failed commands

### Do not touch yet

- Do not split this file in the first stabilization phase.
- Do not remove legacy single-bridge behavior.
- Do not change multi-bridge routing semantics.
- Do not change scene activation behavior.
- Do not change widget/watch data writes.

### Candidate future seams

| Seam | Candidate extraction | Prerequisite |
|---|---|---|
| Bridge registry | `BridgeRegistryService` | Build 21 baseline + multi-bridge smoke tests |
| Room/light state | `DashboardStateStore` or reducer | Dashboard behavior map |
| Scene actions | `SceneActionService` | Hue contract inventory with payload samples |
| SSE lifecycle | `BridgeEventStreamCoordinator` | Reconnect behavior documented |
| Widget/watch snapshots | `ExtensionSnapshotWriter` | Persistence/App Group map |
| Entertainment routing | `EntertainmentSessionCoordinator` | DTLS lifecycle map |

## `StudioView.swift`

### Current responsibilities

- Studio/composer screen layout
- Composition/palette/motion controls
- Room/target selection UI
- Preview/apply affordances
- Loading/error/empty states for Studio surface

### Do not touch yet

- Do not rewrite the view hierarchy.
- Do not change user-facing composer behavior.
- Do not move state ownership until `StudioViewModel.swift` responsibilities are mapped.

### Candidate future seams

- Smaller view components for palette selection
- Motion configuration panels
- Target room/bridge picker
- Preview canvas/card components
- Empty/error/loading state components

## `StudioViewModel.swift`

### Current responsibilities

- Studio state management
- Composition/palette selection
- Effect/motion configuration
- Apply/save behavior
- Bridge target handling
- Possible AI/availability-guarded composition generation behavior

### Do not touch yet

- Do not change apply/save behavior.
- Do not change transport selection logic.
- Do not change spatial/motion math before fixtures exist.

### Candidate future seams

| Seam | Candidate extraction | Prerequisite |
|---|---|---|
| Pure composition state | `CompositionEditorState` | Snapshot fixtures |
| Palette logic | `PaletteBuilder` | Unit tests |
| Motion/spatial math | `SpatialMotionEngine` | Input/output examples |
| Apply orchestration | `CompositionApplyService` | Hue transport contract docs |
| Persistence | `CompositionRepository` | Persistence map |

## `DashboardView.swift`

### Current responsibilities

- Main room/dashboard layout
- Room cards and summary rendering
- Dashboard actions such as room toggle/brightness where present
- Navigation into room detail
- Loading/offline/error states

### Do not touch yet

- Do not restyle or restructure dashboard as part of stabilization.
- Do not alter action routing.
- Do not alter room ordering/grouping until documented.

### Candidate future seams

- Room card component extraction
- Dashboard empty/offline state component
- Room action dispatcher boundary
- Dashboard display model builder

## `RoomDetailView.swift`

### Current responsibilities

- Room detail layout
- Individual light controls
- Scene chips/editor affordances
- Bulk action UI
- Navigation to create scene/light controls

### Do not touch yet

- Do not change scene chip behavior.
- Do not change bulk action behavior.
- Do not change light selection/control behavior.

### Candidate future seams

- Light row/card components
- Scene chip strip
- Bulk action bar ownership review
- Room detail state renderer

## `RoomDetailViewModel.swift`

### Current responsibilities

- Room detail state
- Individual light updates
- Bulk light actions
- Scene interactions
- Bridge action side effects
- Error/rollback behavior

### Do not touch yet

- Do not alter rollback behavior without tests.
- Do not change light update payloads without Hue contract update.

### Candidate future seams

- Light action service
- Room detail reducer/state builder
- Scene action helper
- Rollback/error strategy object

## `HueAPIClient.swift`

### Current responsibilities

- Hue CLIP v2 REST requests
- Request construction
- Response decoding
- Scene/light/grouped_light operations
- Error mapping where implemented
- TLS/session behavior where implemented

### Do not touch yet

- Do not change endpoint targets casually.
- Do not change grouped_light/native effects behavior until verified.
- Do not change request payloads without adding fixtures.

### Candidate future seams

- Endpoint-specific clients
- Request/response fixtures
- Error taxonomy
- Scene payload encoder
- Light/grouped_light command encoder

## `HueV1Client.swift`

### Current responsibilities

- Legacy Hue v1 operations
- Schedules/rules/sensors/resourcelinks where present
- Backward compatibility behavior

### Do not touch yet

- Do not remove v1 code until current usage is verified.
- Do not assume v2 fully replaces v1 for this app.

### Candidate future seams

- Legacy feature registry
- v1-only endpoint inventory
- Compatibility tests for any still-used v1 behavior

## `HueEntertainmentClient.swift`

### Current responsibilities

- Hue Entertainment DTLS/UDP connection
- PSK/client key usage
- Entertainment streaming payloads
- Session start/stop lifecycle

### Do not touch yet

- Do not change socket/session lifecycle without real hardware testing.
- Do not change credential access until persistence map is complete.
- Do not change multi-bridge behavior until tested.

### Candidate future seams

- Entertainment session model
- DTLS transport adapter
- Payload encoder
- Session lifecycle manager
- Multi-bridge session registry

## Refactor readiness checklist

A file or seam is ready for extraction only when:

- [ ] Current behavior is documented.
- [ ] Relevant smoke tests exist.
- [ ] Pure logic has fixtures or unit tests where practical.
- [ ] Callers are known.
- [ ] Side effects are known.
- [ ] Rollback plan exists.
- [ ] Android parity impact is documented.
- [ ] PR can be reviewed as a small, bounded change.

## First safe refactor candidates after documentation

These are not approved yet, but are likely safer than moving orchestration code:

1. Extract pure display-model builders with no network/storage side effects.
2. Add request/response fixtures for Hue scene and light payloads.
3. Add unit tests for pure model equality/serialization.
4. Extract small SwiftUI subviews from large views only when behavior and state ownership do not change.
5. Add comments or docstrings around non-obvious bridge behavior without changing code.
