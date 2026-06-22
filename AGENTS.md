# AGENTS.md — ChromaGlow Coding Agent Instructions

**Purpose:** This file is the standalone coding-agent handoff for ChromaGlow. It is intended for Codex, automated coding agents, and agentic IDEs. It contains current project context, scope, guardrails, exclusions, and near-term implementation order without requiring a separate `cloud.md` file.

**Last synthesized:** 2026-06-21

**Current one-line state:** ChromaGlow is a mature native iOS Philips Hue app; the project is now stabilizing repo/process context and preparing a separate native Android Kotlin / Jetpack Compose MVP focused on bridge pairing, dashboard/room/light control, scenes, secure local storage, and internal testing.

---

## 1. Required Agent Startup Sequence

Before editing:

1. Read this file completely.
2. Read `DEVLOG.md` if it exists.
3. Read `DEVDOC.md`, `COMPOSER_SPEC.md`, `CURSOR_KICKOFF.md`, `.cursorrules`, and `.cursor/rules/*.mdc` when touching iOS, Studio, Composer, or Xcode project structure.
4. Read the task packet or issue/PR description for the current work.
5. Confirm the exact scope.
6. List the files you intend to modify.
7. Produce a small diff.
8. Run narrow validation.
9. Update `DEVLOG.md` after meaningful implementation changes.

Do not make broad refactors. Do not infer permission to touch unrelated files.

---

## 2. Current Project Decision

The current strategy is:

- Keep iOS native Swift / SwiftUI.
- Build Android as a standalone native Kotlin / Jetpack Compose app.
- Add a minimal backend later only for telemetry, feature flags, release cohorts, support diagnostics, optional identity, or optional non-sensitive metadata sync.
- Do not rewrite the product in Flutter, React Native, Capacitor, PWA, or another single shared UI stack.
- Do not route normal Hue control through cloud.
- Do not route local bridge discovery through cloud.
- Do not route Hue Entertainment / DTLS streaming through cloud.
- Keep Hue control local-first.

Historical note: an earlier report recommended Flutter. That is no longer the current plan. The active plan is **native iOS + standalone native Android + minimal backend, no Flutter**.

---

## 3. Product Identity

Use **ChromaGlow** for current project context.

Historical names still appear in code/docs/paths:

- HueHome Pro
- LightShade
- CastChroma
- ChromaForge
- ChromaGlow

Do not perform broad rename work unless explicitly assigned.

Known identity values from the uploaded repo snapshot:

- iOS app bundle ID: `com.huehome.pro`
- Widget extension bundle ID: `com.huehome.pro.widget`
- Watch app bundle ID: `com.huehome.pro.watchkitapp`
- Watch extension bundle ID: `com.huehome.pro.watchkitapp.watch`
- App Group entitlement: `group.com.huehome.pro`
- iOS deployment target: iOS 17.0
- Marketing version in project: `0.9.0`
- Build number in project: `1`
- App display name: `ChromaGlow`
- App Store Connect ChromaGlow Apple ID recorded in docs: `6766251782`

Some docs mention old identifiers such as `com.lightshade.app` or `group.com.lightshade.app`. Treat those as historical unless verified in the current repo.

---

## 4. Branch State Warning

Branch state must be verified before code work.

Known ambiguity:

- Some docs say `main` is the protected integration branch.
- A later handoff mentioned a merge into `prod`.

Run locally:

```bash
git status
git branch --show-current
git fetch --all --prune
git log --oneline --decorate --graph --all -n 20
```

Confirm:

- Current branch
- Default branch
- Integration branch
- Whether the previous passing PR merged
- Branch protection/ruleset status

Do not start new code work until this is clear.

---

## 5. Current Phase

The project is between:

- **Milestone 0: repo/context/process safety**
- **Milestone 1: Android foundation**

Near-term order:

1. Update root agent context files: `CLAUDE.md` and `AGENTS.md`.
2. Verify branch/default/protection state.
3. Confirm iOS build/TestFlight baseline.
4. Start first Android foundation PR.

The first Android PR should only add a native Kotlin / Jetpack Compose app shell that builds and launches to a placeholder screen.

It must not include bridge discovery, pairing, TLS pinning, Hue control, Studio, Composer, DTLS entertainment, microphone sync, widgets, Wear OS, Marketplace, web, Google Home, or KMP.

---

## 6. Repo Contents and Existing iOS App

Expected repo areas from the snapshot:

- `HueHome.xcodeproj` — native Xcode project
- `HueHome/` — main iOS app source
- `HueHomeWidget/` — widget extension
- `LightShadeWatch/` — watch widget/complication-like target
- `LightShadeWatchApp Watch App/` — Watch app
- `HueHomeTests/` — unit tests
- Watch tests/UI tests — mostly scaffolding
- `README.md`
- `DEVDOC.md`
- `DEVLOG.md`
- `COMPOSER_SPEC.md`
- `CURSOR_KICKOFF.md`
- `.cursorrules`
- `.cursor/rules/*.mdc`
- Ruby scripts that generate or mutate Xcode project state
- `run_tests.sh`
- Static docs under `docs/`

Approximate code size from the uploaded snapshot:

- Swift files: about 113
- Swift lines: about 36,627
- Largest files:
  - `HueHome/Core/Network/UnifiedOrchestrator.swift`: about 3,290 lines
  - `HueHome/UI/Studio/StudioView.swift`: about 2,816 lines
  - `HueHome/UI/Studio/StudioViewModel.swift`: about 1,702 lines
  - `HueHome/UI/Dashboard/DashboardView.swift`: about 1,438 lines
  - `HueHome/UI/RoomDetail/RoomDetailView.swift`: about 1,048 lines

These large files are high-risk. Do not modify them unless the task explicitly scopes the change.

---

## 7. Existing iOS Capabilities

The iOS app is the production/TestFlight anchor and already includes substantial functionality.

### Platform and Frameworks

- Swift
- SwiftUI
- SwiftData
- Observation framework / `@Observable`
- URLSession
- Apple Network framework / Bonjour-style discovery
- AVFoundation and Accelerate
- WidgetKit
- App Intents / Siri Shortcuts
- WatchConnectivity

### Hue Capabilities

- Bridge discovery via mDNS / Bonjour for `_hue._tcp`
- NUPnP fallback through Hue discovery endpoint
- Manual IP fallback
- CLIP API pairing
- Hue application key storage
- Optional entertainment client key handling
- Hue CLIP v2 REST client in `HueAPIClient.swift`
- Hue v1 client in `HueV1Client.swift`
- SSE event stream via `HueSSEService.swift`
- DTLS/UDP Entertainment transport via `HueEntertainmentClient.swift`
- Multi-bridge registry
- Room/light dashboard controls
- Per-light controls
- Scene list and activation
- Scene creation/capture
- Global scenes
- Devices view/model
- Local notification automations
- Demo mode
- Studio/effects engine
- Composer engine/store/model
- Sync/microphone-driven modes
- Widget surfaces
- Siri/App Intents
- Watch app/watch sync

### Important Studio / Composer / Sync Areas

- `StudioView.swift`
- `StudioViewModel.swift`
- `CompositionModels.swift`
- `CompositionEngine.swift`
- `CompositionStore.swift`
- `CompositionMicCapture.swift`
- `SyncModeEngine.swift`
- `VisualizerEngine.swift`
- `AmbientEngine.swift`
- `GamingEngine.swift`

Studio, Composer, DTLS, and microphone sync are advanced post-MVP Android items.

---

## 8. Persistence and Storage

### SwiftData Models

Expected local models include:

- `BridgeRecord`
- `HueLocalRoom`
- `HueLocalScene`
- `EffectPreset`
- `FavouriteColor`
- `ActivityEvent`
- `EnergySnapshot`
- `AppSettings`
- `AppAutomation`

### Keychain

Used for sensitive data such as:

- Bridge API tokens
- Bridge IP or connection metadata
- Entertainment keys

### App Group UserDefaults

Used for:

- Widget/watch snapshots
- Bridge-aware room metadata
- Bridge credential maps or references
- Legacy single-bridge fallback values

Security concern: audits flagged raw Hue credential sharing through unencrypted App Group UserDefaults as risky. Avoid expanding this on iOS. Never reproduce this on Android.

---

## 9. Apple Extension Surfaces

Available:

- `HueHomeWidget/`
  - interactive widgets
  - widget intents
  - room selection entities
- `HueHome/Intents/`
  - Siri/App Shortcuts
  - intent entities/actions
- `LightShadeWatchApp Watch App/`
  - Watch app and store
- `LightShadeWatch/`
  - watch widget/complication-like files

Recent devlog work added bridge-aware routing for widgets, Siri intents, and watch stores.

---

## 10. Design System / UI Parity

Current iOS design files/concepts:

- `HueTokens.swift`
- `HueTypography.swift`
- `HueComponents.swift`
- `HueColorUtils.swift`
- `GlassmorphicCard.swift`
- `ShimmerComponents.swift`
- `HueToastView.swift`
- `HapticManager.swift`

Current visual language:

- Dark-mode first
- Glassmorphic cards/materials
- Amber primary accent
- Success green for live/active states
- Red/destructive for stop/delete
- Custom tab bar
- Studio card decks
- Layered mixer tray

Android goal: UI parity, not pixel-perfect sameness.

Android MVP UI parity includes:

- Splash/setup
- Demo mode entry
- Bridge scan/pairing
- Dashboard cards
- Room detail
- Scene list
- Scene activation feedback
- Settings/sign-out
- Loading/empty/error/permission-denied states

---

## 11. Tests and Validation

Known tests include:

- `HueAPIClientTests.swift`
- `HueDataModelsTests.swift`
- `HueTokensTests.swift`
- `KeychainManagerTests.swift`
- `OrchestratorTests.swift`

Coverage is partial. There is no robust full UI/E2E suite in the snapshot.

Repo build command from existing rules:

```bash
PROJ=/Users/brianbean/Desktop/huehome-pro-v0.3.0
xcodebuild -project "$PROJ/HueHome.xcodeproj" -scheme HueHome -destination 'generic/platform=iOS' build 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Adapt the path to the local repo. Do not assume that path exists.

When adding Swift files, update Xcode project references correctly. The repo uses scripts that can mutate project state; do not run them casually.

---

## 12. What Is Not Implemented Yet

Do not assume these exist unless verified:

- Native Android app project
- Backend implementation
- GitHub Actions / `.github/workflows`
- Fastlane or formal release automation
- Production telemetry/crash reporting backend
- Remote feature flags
- User accounts
- Marketplace backend
- Web app
- Google Home integration
- Wear OS app
- Android widgets
- KMP shared module
- HomeKit integration
- CoreBluetooth integration
- APNs remote push
- True BGTaskScheduler implementation
- Full Mac Catalyst support
- Robust UI/E2E testing suite

---

## 13. Latest Known Devlog State

The uploaded repo snapshot’s `DEVLOG.md` ends on **2026-05-08**.

Most recent repo-recorded item:

### 2026-05-08 — Multi-Bridge Routing Foundation for Widget/Watch

Built:

- Extended `WidgetDataStore.swift` with `bridgeID` in room snapshots.
- Added `WidgetBridgeCredentials` and bridge map persistence.
- Updated `UnifiedOrchestrator.swift` to write bridge-aware snapshots and bridge credential maps.
- Updated watch sync payloads to include bridge map data.
- Updated widget intents to resolve credentials per room.
- Updated Siri intent entities/actions to carry `bridgeID`.
- Updated watch and watch widget stores to decode and resolve per-room bridge credentials.

Working:

- iOS app target compiled.
- watchOS app target compiled.
- Widget/intent/watch paths now have deterministic per-room bridge routing keys.
- Legacy single-bridge keys remain as fallback.

Left:

- Add interactive watch complication/widget toggle intent wiring.
- Validate Bridge 2 routing on physical watch under stale-cache conditions.
- Add explicit failure surfacing/telemetry for missing/stale room routing metadata.
- Optionally add groupedLightID-to-bridgeID fallback map.

Gotchas:

- Existing widget/watch data may be stale until app-driven sync refreshes payloads.
- Some external surfaces still depend on legacy fallback keys.
- Multi-bridge correctness depends on `bridgeID` being present in snapshots.

---

## 14. Additional Recent Engineering Context

### Multi-Bridge Concurrent Entertainment Sessions

Direction:

- Move Entertainment session state from global single-slot state to per-bridge dictionaries.
- Allow Bridge A and Bridge B to have independent entertainment sessions.
- Preserve single-bridge behavior.
- Make Studio mini-map/direction config use the selected room’s bridge.

### Spatial Motion Engine

Direction:

- Move Composer away from array-index sweeps.
- Use Hue physical layout data.
- Use PCA/covariance concepts to detect maximum spread axis.
- Project lights onto direction vectors for waves/cascades.

### Composer REST Transport Work

Recent work included:

- Wrong-room apply race fixes
- Startup `GET /light` request dedupe
- REST scheduler tuning
- Immediate REST burst window after color pad edits
- Composer color pad haptics
- Mic reaction support with Sync-safe exclusivity
- Lazy tab loading to reduce cold launch impact

### Bridge-Stored Animation / V1 Rule Chain

Root cause:

- Hue v1 rule/schedule action addresses must be relative paths like `/lights/1/state`.
- Full `/api/{token}/...` paths fail.

Approved next direction:

- Fix v1 relative paths for complex bridge-stored animation chains.
- Add v2 Dynamic Scene / Dynamic Palette fast path for simpler palette presets.

### Cold Launch

iOS had several-second cold launch / tab prewarming work. Android should avoid this through architecture, lazy rendering, background work, and clean data caches.

---

## 15. Current Workstreams

### A. Operating Model

- Establish durable human/tool workflow.
- Use repo docs as source of truth.
- Use small reviewable task packets.
- Avoid broad refactors.
- Current status: context files and branch protection/default branch need confirmation.

### B. iOS Stabilization and Baseline

- Keep iOS production/TestFlight stable.
- Fix critical bugs before freezing Android parity baseline.
- Avoid risky broad changes.
- Current status: needs physical-device QA on multi-bridge/widget/watch paths and named baseline TestFlight build.

### C. Native Android Buildout

- Build standalone Android app with Kotlin/Compose.
- Match MVP user promise.
- Avoid iOS monolith pattern.
- Current status: Android not confirmed in uploaded snapshot; first task should be shell/CI only.

### D. Design System / UI Parity

- Translate iOS visual language to Android.
- UI parity, not pixel-perfect sameness.
- Current status: iOS tokens/components exist; Android tokens not confirmed.

### E. AI Coding Guardrails

- Make Cursor, Claude, Codex, and other agents follow repo rules.
- Current status: `.cursorrules` exists; `CLAUDE.md` and `AGENTS.md` are root handoff files.

### F. Backend / Telemetry Research

- Minimal backend only.
- Start with interfaces.
- No backend implementation yet.

---

## 16. Android MVP Scope

### Include

- Native Android app shell
- Demo mode
- Bridge discovery
- Bridge pairing
- Secure local credential storage
- Dashboard
- Room/light control
- Scenes list
- Scene activation
- Basic settings
- Basic error/loading states
- Basic telemetry hooks or local telemetry interface
- Internal testing distribution

### Exclude

- Studio/composer full parity
- DTLS entertainment streaming
- Microphone sync
- Widgets
- Wear OS
- Marketplace
- User accounts
- Web
- Google Home
- KMP/shared logic extraction

### Post-MVP Order

1. Broader UI parity
2. Automations
3. Widgets and Wear OS
4. Studio/composer
5. DTLS entertainment / mic sync
6. Marketplace scene sharing
7. Web / Google Home / other integrations

---

## 17. Backend Rules

Backend may handle:

- Feature flags
- Crash/health telemetry
- Release cohorts
- Optional identity later
- Optional non-sensitive preset/scene marketplace metadata later
- Support diagnostics
- Short-lived pairing handoff tokens later

Backend must not handle:

- Raw Hue bridge credentials
- Required local light control
- High-frequency entertainment streaming
- Microphone/audio processing
- Required local bridge discovery

Start with interfaces:

- `FeatureFlagProvider`
- `TelemetrySink`
- `CrashReporter` or wrapper

Use no-op/local implementations first.

Never collect by default:

- Hue credentials
- Bridge tokens
- Raw audio
- Room names
- Light names
- Exact local IP addresses
- Personal user content

---

## 18. Hue API Rules

- Never send `effects` payloads to `grouped_light` endpoints.
- Native Hue effects are per-light only.
- Use `childResourceRefs` from `RoomDisplayItem` for room membership when available.
- REST loops must use a latest-wins mailbox pattern.
- Do not queue unlimited bridge writes.
- Per-light REST is rate-limited and should be batched/staggered.
- Grouped-light control is good for simple room on/off/brightness/color state.
- DTLS Entertainment is the correct tier for high-frequency spatial/mic sync.
- Hue v1 rule/schedule action addresses must be relative paths such as `/lights/1/state`.

---

## 19. iOS Rules

- Prefer `@Observable` / Observation framework.
- Do not introduce new `ObservableObject` / `@Published` patterns unless intentionally touching legacy code.
- Preserve generation-counter patterns around async effects.
- Avoid broad edits to:
  - `UnifiedOrchestrator.swift`
  - `StudioView.swift`
  - `StudioViewModel.swift`
  - `DashboardView.swift`
  - `RoomDetailView.swift`
- Do not touch signing/provisioning/bundle IDs/App Groups/entitlements casually.
- When creating Swift files, update Xcode project references correctly.
- Build after code changes.
- Append `DEVLOG.md` after meaningful implementation sessions.

---

## 20. Android Rules

- Use native Kotlin and Jetpack Compose.
- Do not build a giant `UnifiedOrchestrator` equivalent.
- Use clean architecture boundaries.
- Store credentials in Android Keystore / encrypted storage.
- Do not store credentials in plaintext preferences.
- Use defensive permission state machines for local network access.
- Do not use trust-all TLS managers.
- Do not blindly return `true` in a hostname verifier.
- Design for TOFU/certificate pinning with Hue self-signed bridge certificates.
- Expect Android local-network and foreground-service restrictions to evolve.
- Use Kotlin data classes for UI state where possible.
- Avoid custom equality/diff bugs.
- Do not implement Studio/composer/DTLS/mic/widgets/Wear OS before MVP.

Recommended Android structure:

```text
app/
  ui/compose screens
  ui/design tokens/components
  presentation/viewmodels
  domain/usecases
  domain/models
  data/repositories
  data/hue/rest
  data/hue/discovery
  data/hue/sse
  data/security
  data/storage
```

Likely Android components:

- `BridgeDiscoveryRepository`
- `BridgePairingRepository`
- `BridgeCredentialStore`
- `HueRestClient`
- `RoomRepository`
- `SceneRepository`
- `DashboardUseCase`
- `ActivateSceneUseCase`
- `DemoModeRepository`
- `FeatureFlagProvider`
- `TelemetrySink`

---

## 21. Security Rules

- Never log Hue bridge tokens.
- Never send Hue bridge credentials to backend.
- Never collect raw audio.
- Avoid collecting room names, light names, local IPs, or user content in telemetry unless explicitly reviewed.
- Android widgets must not reproduce the iOS App Group plaintext credential pattern.
- Never implement trust-all TLS.
- Never blindly accept all certificates.
- Treat bridge credentials as local-only secrets.

---

## 22. Known Risks

### Large iOS Files

High-risk files:

- `UnifiedOrchestrator.swift`
- `StudioView.swift`
- `StudioViewModel.swift`
- `DashboardView.swift`
- `RoomDetailView.swift`

Use small task packets only.

### Credential Sharing

The iOS App Group approach may expose raw bridge credentials in shared UserDefaults. Do not expand it and do not copy it to Android.

### Hashable / Equality Mismatch

`RoomDisplayItem` reportedly compares more fields in `==` than it combines in `hash(into:)`. This can cause SwiftUI diff/update issues. Treat as targeted iOS stabilization only.

### Dynamic Palette

Richer v2 Dynamic Palette transport remains planned/partially investigated, not fully productized.

### Bridge-Stored Animation

The v1 relative path bug was root-caused. Verify whether current repo has the actual fix.

### Watch Interactivity

Interactive watch complication/widget toggle intent wiring remains.

### CI/CD

No robust GitHub Actions/Fastlane setup is confirmed.

### Tests

Unit tests exist, but E2E/device/network-lab testing is incomplete.

### watchOS Deployment Target

watchOS deployment target may be suspicious in the snapshot. Verify before release work.

---

## 23. Milestones

### Milestone 0 — Repo and Context Safety

- M0-01: commit migration docs
- M0-02: configure branch protection/ruleset
- M0-03: document iOS local build/signing setup
- M0-04: update `CLAUDE.md` and `AGENTS.md`
- M0-05: resolve `main` vs `prod` ambiguity
- M0-06: document current TestFlight/iOS baseline status

### Milestone 1 — Android Foundation

- M1-01: Android app shell
- M1-02: Gradle/Kotlin/Compose baseline
- M1-03: Android CI build lane
- M1-04: Android design tokens and placeholder UI shell
- M1-05: local feature flag interface
- M1-06: demo mode data model and first screen

### Milestone 2 — Android Hue Pairing Foundation

- M2-01: local-network permission UX/state model
- M2-02: mDNS discovery via Android NSD
- M2-03: NUPnP fallback
- M2-04: manual IP entry
- M2-05: pairing flow
- M2-06: secure credential storage
- M2-07: TLS trust / TOFU design spike

### Milestone 3 — Android Core Control MVP

- M3-01: Hue v2 REST client
- M3-02: bridge repository and local cache
- M3-03: dashboard screen
- M3-04: room detail screen
- M3-05: light controls
- M3-06: scenes list
- M3-07: scene activation
- M3-08: basic settings and sign-out

### Milestone 4 — Internal Test Readiness

- M4-01: Play internal testing setup
- M4-02: privacy-safe telemetry interface or local stubs
- M4-03: crash reporting decision
- M4-04: device matrix QA
- M4-05: network failure QA
- M4-06: release checklist

### Milestone 5 — Post-MVP Parity

1. Automations
2. Widgets + Wear OS design
3. Studio/composer parity
4. DTLS entertainment
5. Microphone sync
6. Marketplace
7. Web / Google Home

---

## 24. Immediate Docs-Only Task

If the user asks to update agent context locally, only update:

- `CLAUDE.md`
- `AGENTS.md`

Do not add:

- `cloud.md`
- `CHATGPT_CONTEXT.md`
- extra docs
- runtime code

Suggested branch:

```bash
git switch <confirmed-integration-branch>
git pull
git switch -c docs/update-agent-context
```

Suggested commit:

```bash
git add CLAUDE.md AGENTS.md
git commit -m "docs: update Claude and agent context"
```

Suggested PR title:

```text
Update Claude and agent handoff context
```

Acceptance criteria:

- Only `CLAUDE.md` and `AGENTS.md` changed.
- Files are standalone.
- No runtime code changed.
- No Xcode project files changed.
- No signing/provisioning changed.
- Future Claude/Codex sessions can understand project status, scope, exclusions, risks, and next steps from these root files.

---

## 25. Safe Changes

Safe with proper task scope:

- Docs-only handoff/context updates
- Branch protection/setup docs
- iOS build notes
- Android app shell
- Android CI build lane
- Design token inventory docs
- Small targeted bug fixes with tests/build validation

---

## 26. Unsafe Changes Without Explicit Scope

Do not do these unless explicitly assigned:

- Broad iOS refactors
- Large edits to major Swift files
- Signing/provisioning changes
- Xcode project regeneration
- Backend implementation
- Credential storage changes
- Android Studio/composer work
- Android DTLS/mic sync work
- Widgets/Wear OS before MVP
- Product-wide rebrand
- Flutter/RN/PWA rewrite

---

## 27. Human Questions Still Needed

Ask Brian/Dallin to confirm:

- Actual GitHub repo URL
- Default branch: `main`, `prod`, or other
- Branch protection/ruleset status
- Whether the previous passing PR merged
- Known-working Xcode version
- Known-working macOS version
- Latest TestFlight build number
- Whether current TestFlight build is acceptable as baseline
- Automatic signing status
- Whether Dallin should be added to App Store Connect
- Android package name
- Backend/telemetry provider evaluation priority

---

## 28. Final Agent Rule

When uncertain, preserve the native iOS app, keep Hue control local-first, avoid broad refactors, and make the smallest reviewable change that advances the current milestone.
