# CLAUDE.md — ChromaGlow Full Claude Code Context

**Purpose:** This file is the standalone Claude Code handoff for ChromaGlow. It must contain enough context for Claude Code to reopen the project in a new session and safely continue work without needing the prior ChatGPT conversation or a separate `cloud.md` file.

**Last synthesized:** 2026-06-21

**Current one-line state:** ChromaGlow is a mature native iOS Philips Hue app; the project is now stabilizing repo/process context and preparing a separate native Android Kotlin / Jetpack Compose MVP focused on bridge pairing, dashboard/room/light control, scenes, secure local storage, and internal testing.

---

## 1. First Instructions for Claude Code

Before editing files:

1. Read this file completely.
2. Read `DEVLOG.md` if it exists.
3. Read `DEVDOC.md`, `COMPOSER_SPEC.md`, `CURSOR_KICKOFF.md`, `.cursorrules`, and `.cursor/rules/*.mdc` when touching iOS, Studio, Composer, or Xcode project structure.
4. Read any task packet under `docs/`, `docs/migration/`, `docs/tasks/`, or similar directories.
5. Summarize the task in one paragraph.
6. List the files you intend to touch.
7. Make the smallest reviewable change.
8. Run the narrowest relevant validation.
9. Update `DEVLOG.md` after meaningful implementation work.

**Do not begin broad refactors. Do not infer missing scope. Ask for confirmation when branch, task, or release state is unclear.**

---

## 2. Current Strategy

The current project decision is locked unless a human explicitly changes it:

- Keep the existing iOS app native Swift / SwiftUI.
- Build Android as a standalone native Kotlin / Jetpack Compose app.
- Use a minimal backend later only for telemetry, feature flags, release cohorts, support diagnostics, optional identity, or optional non-sensitive metadata sync.
- Do **not** rewrite the product in Flutter, React Native, Capacitor, PWA, or another single shared UI stack.
- Do **not** route normal Hue control through a cloud relay.
- Do **not** route local bridge discovery through a backend.
- Do **not** route Hue Entertainment / DTLS streaming through a backend.
- Keep Hue control local-first.

Historical note: an earlier migration report considered Flutter and add-to-app. That recommendation is superseded by the current decision: **native iOS + standalone native Android + minimal backend, no Flutter**.

---

## 3. Product Identity and Naming

The product has used multiple names over time:

- HueHome Pro
- LightShade
- CastChroma
- ChromaForge
- ChromaGlow

Use **ChromaGlow** for current user-facing and planning context.

Do not perform broad renames. Older names still appear in repo paths, bundle IDs, target names, and docs. Treat old names as historical unless a task explicitly scopes a controlled rebrand cleanup.

Known app identity from the uploaded repo snapshot:

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

Known inconsistency: some docs mention `com.lightshade.app` or `group.com.lightshade.app`. The repo snapshot shows `com.huehome.pro` and `group.com.huehome.pro`. Verify before changing signing, entitlements, App Groups, or bundle IDs.

---

## 4. Branch and Repo State Warning

There is an unresolved branch-state ambiguity.

- Some migration/process docs say `main` is the protected integration branch.
- A later shared handoff mentioned a merge into `prod`.

Before creating or editing code branches, run:

```bash
git status
git branch --show-current
git fetch --all --prune
git log --oneline --decorate --graph --all -n 20
```

Then confirm:

- What is the actual default branch?
- Is the integration branch `main`, `prod`, or something else?
- Did the previously passing PR actually merge?
- Is branch protection/ruleset active?
- Are direct pushes blocked?

Do not start new code tasks until this is unambiguous.

---

## 5. Current Project Phase

The project is at the boundary between:

- **Milestone 0: repo/context/process safety**
- **Milestone 1: Android foundation**

Current near-term goal:

1. Commit/update root context files such as `CLAUDE.md` and `AGENTS.md` so coding agents can restart safely.
2. Verify branch/default/protection state.
3. Confirm iOS build/TestFlight baseline.
4. Start the first Android foundation PR: a native Kotlin / Jetpack Compose app shell that builds and launches to a placeholder screen.

Do not implement bridge discovery, pairing, TLS pinning, Hue control, Studio, Composer, DTLS entertainment, microphone sync, widgets, Wear OS, Marketplace, web, Google Home, or KMP in the first Android shell PR.

---

## 6. What Exists in the iOS Repo Today

The current production/TestFlight anchor is a native iOS app. It is feature-dense and Apple-platform native.

Major repo areas expected from the snapshot:

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

**Primary risk:** important behavior is concentrated in a few very large Swift files. Do not perform broad refactors without a task packet.

---

## 7. Existing iOS Capabilities

Implemented or materially present in the iOS repo:

### Core App Platform

- Swift
- SwiftUI
- SwiftData
- Observation framework / `@Observable`
- URLSession
- Apple Network framework / Bonjour-style discovery
- AVFoundation and Accelerate for audio-reactive modes
- WidgetKit
- App Intents / Siri Shortcuts
- WatchConnectivity

### Hue Bridge Discovery and Pairing

- mDNS / Bonjour discovery for `_hue._tcp`
- NUPnP fallback through Hue discovery endpoint
- Manual IP fallback
- CLIP API pairing
- Hue application key storage
- Optional Hue Entertainment client key handling

### Hue Networking

- Hue CLIP v2 client in `HueAPIClient.swift`
- Hue v1 client in `HueV1Client.swift` for legacy schedules/rules/sensors/resourcelinks/scenes as needed
- SSE event stream via `HueSSEService.swift`
- Hue Entertainment transport via `HueEntertainmentClient.swift`
- DTLS/UDP streaming path
- Recent direction toward per-bridge concurrent entertainment sessions

### Product Features

- Multi-bridge registry
- Dashboard room cards
- Room/group on/off and brightness
- Per-light controls
- Scene list
- Scene activation
- Scene creation/capture
- Global scenes flow
- Devices view/model
- Local notification automations
- Demo mode via `DemoDataProvider.swift`
- Studio/effects engine
- Composer model/engine/store
- Sync/microphone-driven modes
- Widget surfaces
- Siri/App Intents
- Watch app and watch sync

### Studio / Composer / Sync Files and Concepts

Important files/concepts include:

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

Studio and Composer are advanced features. They are **not** part of the first Android MVP.

---

## 8. Apple Extension Surfaces

Available Apple-specific surfaces:

- `HueHomeWidget/`
  - interactive widget surfaces
  - widget intents
  - room selection entities
- `HueHome/Intents/`
  - Siri/App Shortcuts
  - intent entities/actions
- `LightShadeWatchApp Watch App/`
  - Watch app and store
- `LightShadeWatch/`
  - watch widget/complication-like files

Recent work added bridge-aware routing data for widgets, Siri intents, and watch stores.

Important: Android should not copy the iOS pattern of sharing raw Hue credentials through plaintext shared preferences. Android widgets later should rely on secure app-owned storage boundaries.

---

## 9. Persistence and Storage

Main iOS persistence is split across:

### SwiftData

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
- Bridge IPs or bridge connection metadata
- Entertainment keys

### App Group UserDefaults

Used for widget/watch snapshots and legacy compatibility:

- Room snapshots
- bridge-aware room metadata
- bridge credential maps or credential references
- legacy single-bridge fallback values

Security warning: audits flagged raw Hue credential sharing through unencrypted App Group UserDefaults as a concern. Avoid expanding that pattern on iOS and never reproduce it on Android.

---

## 10. Design System and UI Parity

Current iOS design system files/concepts include:

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
- Card decks for Studio
- Layered mixer tray

Android UI goal: achieve product parity, not pixel-perfect sameness.

Android MVP UI parity should cover:

- Splash/setup
- Demo mode entry
- Bridge scan/pairing
- Dashboard room cards
- Room detail
- Scene list
- Scene activation feedback
- Settings/sign-out
- Loading, empty, error, and denied-permission states

Post-MVP UI parity can cover Studio, Composer, widgets, and Wear OS.

---

## 11. Tests and Build Posture

Known test files include:

- `HueAPIClientTests.swift`
- `HueDataModelsTests.swift`
- `HueTokensTests.swift`
- `KeychainManagerTests.swift`
- `OrchestratorTests.swift`

The repo has partial unit coverage but no robust full UI/E2E suite in the snapshot.

The repo includes Ruby scripts that mutate or generate Xcode project structure. This is fragile. When creating new Swift files, follow Xcode project rules and add files in all required project sections.

Build verification command from repo rules:

```bash
PROJ=/Users/brianbean/Desktop/huehome-pro-v0.3.0
xcodebuild -project "$PROJ/HueHome.xcodeproj" -scheme HueHome -destination 'generic/platform=iOS' build 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Do not assume the path is valid on another machine. Adapt only the local project root path.

---

## 12. What Does Not Exist Yet

Do not assume these are implemented unless the current repo proves otherwise:

- Native Android app project
- Backend implementation
- `.github/workflows` CI/CD workflows
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

## 14. Recent Engineering Context Before 2026-05-08

### Multi-Bridge Concurrent Entertainment Sessions

The entertainment layer moved from global single-slot state toward per-bridge dictionaries.

Intent:

- Bridge A and Bridge B can each have their own entertainment session.
- Single-bridge behavior remains unchanged.
- Studio mini-map and direction config read from the selected room’s bridge.

### Spatial Motion Engine

Composer moved away from array-index sweeps toward physical light coordinates.

Core behavior:

- Uses Hue physical layout data.
- Uses PCA/covariance matrix concepts to detect the axis of maximum spread.
- Projects lights onto direction vectors for waves/cascades.

### Composer and REST Transport Work

Recent sessions focused on making Composer usable over both DTLS and REST fallback:

- Fixed wrong-room apply race.
- Deduped startup `GET /light` calls.
- Added REST scheduler tuning.
- Added immediate REST burst window after color pad edits.
- Added haptics to Composer color pad.
- Added mic reaction support with Sync-safe exclusivity.
- Added lazy tab loading to reduce cold launch impact.

### Bridge-Stored Animation / V1 Rule Chain Investigation

Root cause found:

- Hue v1 rule/schedule action addresses must be relative paths like `/lights/1/state`.
- Full `/api/{token}/...` paths fail.

Approved directions:

- Fix v1 relative paths for complex bridge-stored animation chains.
- Add v2 Dynamic Scene / Dynamic Palette fast path for simpler palette presets.

### Cold Launch Optimization

The app had several-second cold launch / initial tab work. Recent work deferred heavy tabs and improved loading parallelism.

Android should avoid this by architecture rather than copying the iOS workaround.

---

## 15. Current Workstreams

### A. Operating Model

Purpose:

- Establish how Brian, Dallin, ChatGPT, Claude Code, Codex, Cursor, and GitHub should work together.
- Use repo docs as source of truth.
- Produce small reviewable changes.
- Avoid broad refactors.

Current status:

- Migration docs delta exists.
- Branch/default/protection state needs confirmation.
- Root handoff files should be committed so future tools can restart cleanly.

### B. iOS Stabilization and Baseline

Purpose:

- Keep iOS production/TestFlight stable.
- Fix critical bugs before treating iOS as Android parity baseline.
- Avoid risky broad changes to the biggest Swift files.

Current status:

- iOS is feature-rich but has known technical debt.
- Needs physical-device QA on latest multi-bridge/watch/widget routing.
- Needs named baseline TestFlight build after critical fixes.

### C. Native Android Buildout

Purpose:

- Build standalone native Android app using Kotlin and Jetpack Compose.
- Match core iOS user promise for MVP.
- Avoid recreating the iOS monolith.

Current status:

- Android has not been confirmed as started in the uploaded repo snapshot.
- Next code task should be Android app shell and CI lane, after branch state is verified.

### D. Design System / UI Parity

Purpose:

- Translate iOS UI into an Android design system.
- Achieve UI parity, not pixel-perfect sameness.
- Build reusable tokens/components/states for both platforms.

Current status:

- iOS tokens/components exist.
- Android tokens/components have not been confirmed as implemented.
- Figma or Figma-like component inventory is likely useful.

### E. AI Coding Guardrails

Purpose:

- Make Cursor/Claude/Codex consistently follow project architecture.
- Store durable rules in repo.
- Force tools to read decision records and task packets before changing code.

Current status:

- `.cursorrules` and `.cursor/rules/*.mdc` exist for iOS/Cursor.
- This `CLAUDE.md` and `AGENTS.md` should serve as root restart files for non-Cursor tools.

### F. Backend / Telemetry Research

Purpose:

- Decide minimal backend shape.
- Add telemetry/feature flag capability without compromising local-first Hue control.

Current status:

- No backend implementation yet.
- Docs compare Firebase/Google Cloud vs Supabase + Sentry.
- Recommendation: start with local/static feature flag and telemetry interfaces first; choose provider later.

---

## 16. Locked Scope Decisions

### Android MVP Includes

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

### Android MVP Excludes

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

### Post-MVP Android Order

1. Broader UI parity
2. Automations
3. Widgets and Wear OS
4. Studio/composer
5. DTLS entertainment / mic sync
6. Marketplace scene sharing
7. Web / Google Home / other integrations

---

## 17. Backend Boundary

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

Start with interfaces, not provider lock-in:

- `FeatureFlagProvider`
- `TelemetrySink`
- `CrashReporter` or wrapper

Use no-op/local implementations initially.

Never collect by default:

- Hue credentials
- Bridge tokens
- Raw audio
- Room names
- Light names
- Exact local IP addresses
- Personal user content

---

## 18. Critical Hue API Rules

- Never send `effects` payloads to `grouped_light` endpoints.
- Native Hue effects are per-light only.
- Use `childResourceRefs` from `RoomDisplayItem` for room membership when available.
- REST loops must use a latest-wins mailbox pattern; do not queue unlimited bridge writes.
- Per-light REST is rate-limited and should be batched/staggered.
- Grouped-light control is appropriate for simple room on/off/brightness/color state.
- DTLS Entertainment is the right tier for high-frequency spatial/mic sync.
- Hue v1 rule/schedule action addresses must be relative paths such as `/lights/1/state`.

---

## 19. iOS Engineering Guardrails

- Prefer `@Observable` / Observation framework. Do not introduce new `ObservableObject` / `@Published` patterns unless intentionally touching legacy code.
- Preserve generation-counter patterns around async effects.
- Avoid broad edits to:
  - `UnifiedOrchestrator.swift`
  - `StudioView.swift`
  - `StudioViewModel.swift`
  - `DashboardView.swift`
  - `RoomDetailView.swift`
- Do not casually touch signing, provisioning, bundle IDs, App Groups, or entitlements.
- When creating Swift files, update the Xcode project correctly.
- Build after code changes.
- Append `DEVLOG.md` after meaningful implementation sessions.

---

## 20. Android Engineering Guardrails

- Use native Kotlin and Jetpack Compose.
- Do not build a God-object equivalent of `UnifiedOrchestrator.swift`.
- Use clean boundaries: discovery, pairing, credentials, Hue REST, SSE, repositories, use cases, UI state, Compose screens.
- Store credentials in Android Keystore / encrypted storage, not plaintext preferences.
- Use defensive permission state machines for local network access.
- Do not use trust-all TLS managers.
- Design for TOFU/certificate pinning with Hue self-signed bridge certificates.
- Expect Android local-network and foreground-service restrictions to evolve.
- Use Kotlin data classes for UI state where possible.
- Avoid custom equality/diff bugs.
- Do not implement Studio/composer/DTLS/mic/widgets/Wear OS before MVP.

Recommended Android layer shape:

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

Likely Android concepts:

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

## 21. Security Guardrails

- Never put Hue bridge tokens in logs.
- Never send Hue bridge credentials to a backend.
- Never collect raw audio.
- Avoid collecting room names, light names, local IPs, or user content in telemetry unless explicitly reviewed.
- Android widgets must not reproduce the iOS App Group plaintext credential pattern.
- Never implement trust-all TLS.
- Never blindly return `true` in a hostname verifier.
- Treat bridge credentials as local-only secrets.

---

## 22. Known Risks and Technical Debt

### Large iOS Files

Risky files:

- `UnifiedOrchestrator.swift`
- `StudioView.swift`
- `StudioViewModel.swift`
- `DashboardView.swift`
- `RoomDetailView.swift`

Use small, surgical task packets.

### Credential Sharing to Extensions

The iOS App Group approach may expose raw bridge credentials in shared UserDefaults. Stabilize carefully and do not copy to Android.

### Hashable / Equality Mismatch

`RoomDisplayItem` reportedly compares more fields in `==` than it combines in `hash(into:)`, creating possible SwiftUI diff/update bugs. This is a targeted iOS stabilization task.

### Dynamic Palette Not Fully Wired

`CreateSceneRequest` in the snapshot says speed/dynamics are valid in PUT recall, not POST create. The richer v2 Dynamic Palette path remains planned/partially investigated, not fully productized.

### Bridge-Stored Animation Path Needs Finalization

The v1 relative path bug was root-caused. Verify whether the actual current repo has the fix before assuming completion.

### Watch Widget/Complication Interactivity Not Done

Latest devlog says interactive watch complication/widget toggle intent wiring remains.

### No CI/CD

The snapshot does not include GitHub Actions or Fastlane.

### Tests Are Incomplete

Unit tests exist. Full UI/E2E, device matrix, network lab, and extension smoke tests are not robust yet.

### Suspicious watchOS Deployment Target

The Xcode project reportedly shows watchOS deployment target `26.4` in the uploaded snapshot. Verify in Xcode before release assumptions.

---

## 23. Milestone Plan

### Milestone 0 — Repo and Context Safety

Goal: make the project safe for multiple humans/tools.

Tasks:

- M0-01: commit migration docs
- M0-02: configure branch protection/ruleset
- M0-03: document iOS local build/signing setup
- M0-04: add/update root tool handoff files: `CLAUDE.md` and `AGENTS.md`
- M0-05: resolve `main` vs `prod` branch ambiguity
- M0-06: document current TestFlight/iOS baseline status

### Milestone 1 — Android Foundation

Goal: Android app exists and builds.

Tasks:

- M1-01: Android app shell
- M1-02: Gradle/Kotlin/Compose baseline
- M1-03: Android CI build lane
- M1-04: Android design tokens and placeholder UI shell
- M1-05: local feature flag interface
- M1-06: demo mode data model and first screen

### Milestone 2 — Android Hue Pairing Foundation

Goal: Android can find/pair with a Hue Bridge safely.

Tasks:

- M2-01: local-network permission UX/state model
- M2-02: mDNS discovery via Android NSD
- M2-03: NUPnP fallback
- M2-04: manual IP entry
- M2-05: pairing flow
- M2-06: secure credential storage design and implementation
- M2-07: TLS trust / TOFU design spike before productionizing

### Milestone 3 — Android Core Control MVP

Goal: user can control rooms/lights and scenes.

Tasks:

- M3-01: Hue v2 REST client
- M3-02: bridge repository and local cache
- M3-03: dashboard screen
- M3-04: room detail screen
- M3-05: light controls
- M3-06: scenes list
- M3-07: scene activation
- M3-08: basic settings and sign-out

### Milestone 4 — Internal Test Readiness

Goal: Android MVP can be distributed internally.

Tasks:

- M4-01: Play internal testing setup
- M4-02: privacy-safe telemetry interface or local stubs
- M4-03: crash reporting decision
- M4-04: device matrix QA
- M4-05: network failure QA
- M4-06: release checklist

### Milestone 5 — Post-MVP Parity

Order:

1. Automations
2. Widgets + Wear OS design
3. Studio/composer parity
4. DTLS entertainment
5. Microphone sync
6. Marketplace
7. Web / Google Home

---

## 24. Immediate Next Steps for Claude Code

When asked to work now, prefer this sequence:

1. Confirm repo branch/default/protection state.
2. Commit/update only `CLAUDE.md` and `AGENTS.md` if context handoff is the task.
3. Do not add `cloud.md`, `CHATGPT_CONTEXT.md`, or other root files unless explicitly requested.
4. Open a docs-only PR for handoff file updates.
5. After merge, create Android app shell task branch.

Suggested branch for this docs-only task:

```bash
git switch <confirmed-integration-branch>
git pull
git switch -c docs/update-agent-context
```

Suggested commit message:

```text
docs: update Claude and agent context
```

Suggested PR title:

```text
Update Claude and agent handoff context
```

Acceptance criteria:

- Only `CLAUDE.md` and `AGENTS.md` are changed.
- Files are standalone and contain current project context.
- No runtime code changed.
- No Xcode project files changed.
- No signing/provisioning changed.
- A new Claude Code/Codex session can understand current strategy, exclusions, current phase, risks, and next steps by reading root context files.

---

## 25. Safe and Unsafe Changes

### Safe First PRs

- Docs-only handoff/context PR
- Branch protection/setup docs PR
- iOS build notes PR
- Android app shell PR
- Android CI build lane PR
- Design token inventory docs PR

### Unsafe Without Explicit Scope

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

---

## 26. Human Questions Still Needed

Ask Brian/Dallin to confirm:

- What is the actual GitHub repo URL?
- What is the default branch: `main`, `prod`, or something else?
- Is branch protection/ruleset active?
- Did the previous passing PR finish merging?
- What is the known-working Xcode version?
- What is the known-working macOS version?
- What is the latest TestFlight build number?
- Is the current TestFlight build acceptable as baseline, or does it have known bugs?
- Is automatic signing enabled and working?
- Should Dallin be added to App Store Connect?
- Which Android package name should be reserved?
- Which backend/telemetry provider should be evaluated first, if any?

---

## 27. Final Rule

When uncertain, preserve the current iOS app, keep Hue control local-first, avoid broad refactors, and make the smallest docs/code change that advances the current milestone.
