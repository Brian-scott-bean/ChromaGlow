# iOS Stabilization Map

## Purpose

This document defines how we stabilize the existing native iOS ChromaGlow app before meaningful refactor work.

The current iOS app is the production/TestFlight anchor. The goal is not to rewrite it immediately. The goal is to preserve shipped behavior, document what the app currently does, stabilize known issues, and identify safe future extraction seams that also help Android parity.

## Current project decision

- Keep the current native iOS app.
- Build a standalone native Android app.
- Use a minimal/distributed backend only where it supports the product.
- Do not use Flutter.
- Do not route required local Hue control through a backend.
- Treat repo Markdown docs and decision logs as the source of truth.

## Stabilization principles

1. Preserve current TestFlight behavior first.
2. Prefer documentation-only PRs before Swift code PRs.
3. Do not split large Swift files until their responsibilities and regression risks are mapped.
4. Do not change Hue bridge behavior casually.
5. Do not change credential, App Group, widget, or watch behavior until the current contracts are documented.
6. Every behavior-changing PR needs a smoke-test checklist.
7. Refactor seams should be identified before they are extracted.

## Immediate documentation sequence

### 1. Build 21 baseline

Create or maintain:

`docs/ios/baselines/build-21.md`

Capture:

- App Store Connect app name
- Bundle ID
- Marketing version
- Build number
- Git commit SHA
- Git tag
- Xcode version
- iOS version tested
- Physical device tested
- Hue bridge setup tested
- Known issues
- Smoke-test result

The stabilized baseline is not just `main`. It is the exact build/commit/device-tested state that future changes compare against.

### 2. Current behavior map

Create or maintain:

`docs/ios/current-behavior-map.md`

Document current behavior for:

- Demo mode
- Bridge discovery
- Pairing
- Dashboard
- Room detail
- Light control
- Scenes
- Studio/composer
- Sync/music modes
- Widgets
- App Intents/Siri
- Watch app/watch widget
- Settings
- Automations
- Multi-bridge behavior

### 3. Hue contract inventory

Create or maintain:

`docs/ios/hue-contract-inventory.md`

Inventory:

- `BridgeDiscoveryService.swift`
- `HueAPIClient.swift`
- `HueV1Client.swift`
- `HueSSEService.swift`
- `HueEntertainmentClient.swift`
- `BridgeAnimationEngine.swift`
- `CreateSceneRequest.swift`

For each, document:

- API version used
- Endpoint/resource type
- Payload shape
- Auth requirement
- Error behavior
- Retry behavior
- Whether Android MVP needs parity

### 4. Persistence and credential map

Create or maintain:

`docs/ios/persistence-and-credentials.md`

Document:

- SwiftData models
- Keychain usage
- App Group UserDefaults usage
- Widget snapshot contracts
- Watch payload contracts
- Legacy single-bridge fallback keys
- Multi-bridge credential routing
- Known security risks
- Future safer target state

### 5. Large-file responsibility map

Create or maintain:

`docs/ios/large-file-map.md`

Start with:

- `UnifiedOrchestrator.swift`
- `StudioView.swift`
- `StudioViewModel.swift`
- `DashboardView.swift`
- `RoomDetailView.swift`
- `RoomDetailViewModel.swift`
- `HueAPIClient.swift`
- `HueV1Client.swift`
- `HueEntertainmentClient.swift`

For each file, document:

- Current responsibilities
- Public state exposed
- Methods called by UI
- Methods called by extensions/watch/intents
- Side effects
- Dependencies
- Candidate extraction seams
- Do-not-touch areas

### 6. Regression smoke matrix

Create or maintain:

`docs/ios/regression-smoke-matrix.md`

Include:

- Clean build
- Demo mode launch
- Existing paired bridge launch
- Bridge discovery
- Pairing
- Dashboard room render
- Room toggle
- Brightness update
- Color update
- Scene activation
- Studio open
- Composer apply
- Sync/music mode start/stop
- Widget action
- Siri/App Intent action
- Watch sync
- Multi-bridge routing
- App relaunch
- Offline bridge behavior

## Do not touch yet

Do not begin with:

- Splitting `UnifiedOrchestrator.swift`
- Rewriting Studio
- Rewriting Dashboard
- Rewriting Room Detail
- Changing bridge credential storage
- Removing legacy single-bridge fallback behavior
- Changing App Group payloads
- Changing widget/watch routing
- Changing Hue transport cadence
- Changing v1/v2 scene behavior
- Regenerating the Xcode project
- Adding backend dependency to required local control

## Safe early work

Safe early PRs:

1. Add iOS stabilization docs.
2. Add build/run instructions based on the current repo.
3. Add a manual smoke-test checklist.
4. Add comments around risky behavior only where they clarify existing behavior.
5. Add non-invasive unit tests for pure model/serialization behavior.
6. Add documentation for known bugs without fixing them yet.

## Candidate future refactor seams

These are candidates only. Do not extract until behavior and tests are in place.

### Hue transport boundary

Possible future seam:

- Discovery
- REST v2
- REST v1
- SSE
- DTLS entertainment
- Bridge-stored animation
- Transport fallback rules

### Dashboard state boundary

Possible future seam:

- Room display models
- Light display models
- Brightness/color updates
- Optimistic UI state
- Rollback behavior

### Studio/composer core boundary

Possible future seam:

- Composition model
- Palette model
- Motion model
- Spatial math
- Transport selection
- Preview vs apply behavior

### Extension contract boundary

Possible future seam:

- Widget snapshots
- App Intent entities
- Watch payloads
- Multi-bridge routing metadata
- Legacy fallback keys

### Credential access boundary

Possible future seam:

- Keychain access
- App Group access
- Widget/watch read behavior
- Legacy single-bridge fallback
- Future safer credential handoff

## Definition of stabilized baseline

The iOS baseline is stabilized when:

- The exact TestFlight build is tied to a git commit SHA.
- The baseline commit is tagged.
- Clean build instructions are documented.
- Manual smoke test passes or exceptions are documented.
- Known issues are written down.
- Android parity planning can point to the baseline docs instead of chat history.
- Future iOS PRs can be compared against this baseline.

## First milestone

Milestone 0 for this workstream is complete when these files exist:

- `docs/ios/stabilization-map.md`
- `docs/ios/baselines/build-21.md`
- `docs/ios/current-behavior-map.md`
- `docs/ios/regression-smoke-matrix.md`

No Swift behavior changes are required for this milestone.
