# AGENTS.md - ChromaGlow Canonical Agent Context

This is the canonical project handoff for Codex, Claude, Cursor, and other coding agents. Do not duplicate this full context into tool-specific files. Tool-specific entry files, including `CLAUDE.md`, should point here.

Last consolidated: 2026-06-24 · Android parallel Batch 1 result + demo-model/fixture contracts added 2026-06-28 (see "Android Current State").

## Startup Order

Before editing:

1. Read this file completely.
2. Read the "Current Status Snapshot" at the top of `DEVLOG.md`.
3. Read the latest relevant entries in `DEVLOG.md`.
4. Read scoped evidence or task packets under `docs/ios/` or `docs/android/` for the work area.
5. Read `DEVDOC.md`, `COMPOSER_SPEC.md`, `CURSOR_KICKOFF.md`, `.cursorrules`, and `.cursor/rules/*.mdc` when touching iOS, Studio, Composer, Xcode project structure, or legacy Cursor-guided areas.
6. Confirm branch, scope, files to touch, and validation plan.
7. Make the smallest reviewable change.
8. Run narrow validation.
9. Append `DEVLOG.md` after meaningful implementation, validation, or handoff work.

Do not perform broad refactors or infer permission to touch unrelated files.

## Canonical Information Model

Use these files by volatility:

| Layer | File(s) | Purpose |
| --- | --- | --- |
| Stable agent context | `AGENTS.md` | Project strategy, guardrails, current status, source catalog |
| Tool entry point | `CLAUDE.md` | Short Claude-specific pointer to this file |
| Live handoff | `DEVLOG.md` | Append-only session ledger and current snapshot |
| Scoped evidence | `docs/ios/*`, `docs/android/*` | Task packets, audits, decision records, validation evidence |
| Historical/product notes | `DEVDOC.md`, `COMPOSER_SPEC.md`, `CURSOR_KICKOFF.md`, `.cursorrules`, `.cursor/rules/*.mdc` | Legacy architecture and workflow context |

Git is the transport between agents. Do not rely on uncommitted scratch files as shared memory.

## Current One-Line State

ChromaGlow is a native iOS Philips Hue app with a native Android Kotlin/Jetpack Compose MVP underway. iOS remains the production/TestFlight anchor. Android has a scaffold, theme, demo fixtures, credential boundary, mDNS chooser, manual-IP entry, and pairing is blocked until safe TLS bootstrap plus canonical bridge identity are decided. Parallel Batch 1 (demo domain models plus dashboard on/off + brightness controls, with the D-007 fixture/scene contracts below) is **merged to `main`** @ `a3fe54f`; Batch 2 (room-detail / scenes / settings feature packages + a serialized nav-integration wave) is **executed and integrated** on `integration/parallel-batch-2` @ `4c74beb` (gate green: unit 84/0, connected 33/0); not yet merged to `main` (awaits human go-ahead).

## Current Branch/Repo Facts

- Remote: `git@github.com:Brian-scott-bean/ChromaGlow.git`
- Default remote branch observed locally: `origin/main`
- Current integration branch should be treated as `main` unless GitHub rules say otherwise.
- Always run:

```bash
git status --short --branch
git branch --show-current
git fetch --all --prune
git log --oneline --decorate --graph --all -n 20
```

Confirm branch protection/rulesets in GitHub before release or integration work.

Branch naming in use: `android/*`, `ios-ref/*`, `ios-test/*`, `ios-bug/*`, `ios-ops/*`, `docs/*`, `cursor/*`. For the parallel pipeline (see "Parallel Agent Pipeline"), lane work uses `lane/<batch>-<slice>` and each batch integrates on `integration/parallel-batch-N`.

## Product Strategy

- Keep iOS native Swift / SwiftUI.
- Build Android as standalone native Kotlin / Jetpack Compose.
- Use a minimal backend later only for telemetry, feature flags, release cohorts, support diagnostics, optional identity, or optional non-sensitive metadata sync.
- Do not rewrite in Flutter, React Native, Capacitor, PWA, or another shared UI stack.
- Do not route normal Hue control through cloud.
- Do not route local bridge discovery through cloud as the required path.
- Do not route Hue Entertainment / DTLS streaming through cloud.
- Keep Hue control local-first.

Historical note: earlier materials considered Flutter. That is superseded. The active plan is native iOS plus standalone native Android plus minimal backend later.

## Product Identity

Use ChromaGlow for current product context.

Historical names still appear:

- HueHome Pro
- LightShade
- CastChroma
- ChromaForge
- ChromaGlow

Do not do broad rename work unless explicitly assigned.

Current verified identity values:

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
- Android namespace/applicationId currently in repo: `com.chromaglow.app`
- Android Hue devicetype recorded in docs: `chromaglow#android`

Some historical docs mention `com.lightshade.app` or `group.com.lightshade.app`. Treat those as historical unless current project files prove otherwise.

## Source Catalog

### Root Files

| File | Role |
| --- | --- |
| `AGENTS.md` | Canonical agent context |
| `CLAUDE.md` | Claude Code entry point that points here |
| `DEVLOG.md` | Current snapshot plus append-only session handoff |
| `DEVDOC.md` | Historical dev notes and architecture context |
| `COMPOSER_SPEC.md` | Composer behavior/spec history |
| `CURSOR_KICKOFF.md` | Legacy Cursor startup guidance; verify commands before use |
| `.cursorrules`, `.cursor/rules/*.mdc` | Cursor-era rules for iOS/Studio/Composer/build work |
| `README.md` | Public/project overview |
| `run_tests.sh` | Existing test helper, verify before relying on it |

### iOS Areas

| Path | Role |
| --- | --- |
| `HueHome.xcodeproj` | Xcode project |
| `HueHome/` | Main iOS app |
| `HueHomeWidget/` | Widget extension |
| `LightShadeWatch/` | watch widget/complication-like target |
| `LightShadeWatchApp Watch App/` | Watch app |
| `HueHomeTests/` | Unit tests |

### Android Areas

| Path | Role |
| --- | --- |
| `android/` | Standalone native Android project |
| `android/app/src/main/java/com/chromaglow/app/` | Kotlin app source |
| `android/app/src/test/` | JVM tests |
| `android/app/src/androidTest/` | Instrumented tests |
| `docs/android/` | Android MVP contracts, inventories, decisions |

### Documentation Index

Key iOS docs:

- `docs/ios/current-behavior-map.md`
- `docs/ios/final-readiness-validation.md`
- `docs/ios/hue-contract-inventory.md`
- `docs/ios/persistence-and-credentials.md`
- `docs/ios/regression-smoke-matrix.md`
- `docs/ios/stabilization-map.md`
- `docs/ios/large-file-map.md`
- `docs/ios/discovered-bridge-pairing-loop-inventory.md`
- `docs/ios/*orchestrator*`
- `docs/ios/*composer*`

Key Android docs:

- `docs/android/android-mvp-contract-freeze.md`
- `docs/android/android-foundation-scaffold-plan.md`
- `docs/android/android-design-system-shell-parity-map.md`
- `docs/android/android-nupnp-fallback-inventory.md`
- `docs/android/android-pairing-tls-identity-decision.md`

Coordination docs:

- `docs/coordination/parallel-agent-pipeline.md` — lane registry, collision hotspots, pilot, and the shared Claude⇄Codex Decision Log.

## iOS Current Capabilities

The iOS app is mature and feature dense:

- Swift, SwiftUI, SwiftData, Observation framework / `@Observable`
- URLSession, Apple Network framework / Bonjour-style discovery
- AVFoundation and Accelerate for audio-reactive modes
- WidgetKit, App Intents / Siri Shortcuts, WatchConnectivity
- Hue mDNS discovery for `_hue._tcp`
- NUPnP fallback and manual IP fallback
- CLIP API pairing
- Hue application key storage in Keychain
- Optional entertainment client key handling
- Hue CLIP v2 REST client in `HueAPIClient.swift`
- Hue v1 client in `HueV1Client.swift`
- SSE event stream via `HueSSEService.swift`
- DTLS/UDP Entertainment transport via `HueEntertainmentClient.swift`
- Multi-bridge registry
- Room/light dashboard controls
- Scene list, activation, creation/capture, and global scenes
- Devices view/model
- Local notification automations
- Demo mode
- Studio/effects engine
- Composer engine/store/model
- Sync/microphone-driven modes
- Widget, Siri/App Intents, watch app/watch sync

High-risk large iOS files:

- `HueHome/Core/Network/UnifiedOrchestrator.swift`
- `HueHome/UI/Studio/StudioView.swift`
- `HueHome/UI/Studio/StudioViewModel.swift`
- `HueHome/UI/Dashboard/DashboardView.swift`
- `HueHome/UI/RoomDetail/RoomDetailView.swift`

Do not modify these without explicit task scope.

## Android Current State

Android is no longer "not started." Current repo state includes:

- Standalone Gradle/Kotlin/Compose project under `android/`
- App namespace/applicationId `com.chromaglow.app`
- Compose app shell and setup/dashboard route boundary
- Noir/dark Material theme placeholders
- Demo-mode domain fixtures
- Android Keystore-backed API-token credential boundary
- mDNS bridge-discovery chooser through `NsdManager`
- Manual IP/hostname entry parser and setup UI path
- NUPnP fallback inventory with gated deferral
- Pairing TLS / stable-identity decision blocker

Current Android blocker:

- Do not add live pairing code until both are decided:
  - safe TLS bootstrap for Hue self-signed bridge HTTPS
  - canonical stable bridge identity for credential aliasing

Do not implement trust-all TLS managers, permissive hostname verifiers, blind certificate acceptance, or fabricated bridge IDs.

### Parallel Batch 1 result (merged to `main` @ `a3fe54f`)

Two-lane pilot landed and the D-007 contract corrections applied; **merged to `main` @ `a3fe54f` (2026-06-28)** via integration `0d7c218`. Gate green before merge (`testDebugUnitTest` 84/0, `lintDebug`, `assembleDebug`, `connectedDebugAndroidTest` 20/0 on the headless `Pixel_10`). Full record: `DEVLOG.md` and `docs/coordination/parallel-agent-pipeline.md` (§7 + Decision Log D-007). **Batch 2** is executed and integrated on `integration/parallel-batch-2` @ `4c74beb` (room-detail / scenes / settings feature screens + serialized nav integration wiring them into the `when`-router with a behavioral E2E); final gate green (`testDebugUnitTest` 84/0, `lintDebug`, `assembleDebug`, `connectedDebugAndroidTest` 33/0 on `Pixel_10`); pushed, **not** merged to `main` (awaits human go-ahead). Result: pipeline §8 "Batch 2 execution result".

- Demo display models in `core/model`: `RoomDisplayModel`, `LightDisplayModel`, `SceneDisplayModel`. All guard inputs in `init { require(...) }` (non-blank ids/names, `brightness in 1..100`).
- `feature/dashboard`: `DemoRoomRow` has an on/off `Switch` + brightness `Slider` that mutate in-memory demo session state (no persistence); `DashboardPlaceholderScreen`'s public signature is unchanged (the nav shell calls it).

Demo-model / fixture contracts Batch 2 must honor (each is enforced by a unit test — keep them green):

- **Fixture light-count invariant:** every `RoomDisplayModel.lightCount` MUST equal `DemoFixtures.lightsByRoom[room.id].size`. When adding/removing rooms or demo lights, keep both in sync (test `rooms_lightCountMatchesLightsByRoomSize`). Current demo counts: Bedroom 4, Kitchen 8, Living 5, Office 2.
- **Scene bridge routing:** `SceneDisplayModel` carries a required non-blank `bridgeId`; all demo scenes use `DemoFixtures.DEMO_BRIDGE_ID`. A scenes lane must select the correct bridge client via this `bridgeId` (do not fabricate or omit it).
- **Fixture surface:** `DemoFixtures` exposes `rooms`, `lights`, `lightsByRoom` (lights grouped by room id), and `scenes` (≥3); `DEMO_BRIDGE_ID = "demo-bridge-main"`. Do not mutate the existing `rooms` values — connected tests assert their exact text.

## Validation Commands

### iOS

The app scheme is `HueHome 1`, not `HueHome`.

Generic build:

```bash
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' build
```

Filtered build output:

```bash
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' build 2>&1 | rg -e 'error:' -e 'warning:' -e 'BUILD SUCCEEDED' -e 'BUILD FAILED'
```

Simulator tests depend on installed runtimes. First list destinations:

```bash
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -showdestinations
```

Then run a real available destination, for example:

```bash
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' test
```

### Android

Android requires a working JDK/Android toolchain. If `/usr/bin/java` reports no runtime, Gradle validation is blocked.

From `android/`:

```bash
./gradlew testDebugUnitTest lintDebug
./gradlew assembleDebug
./gradlew connectedDebugAndroidTest
```

Use the narrowest relevant command for a docs-only or targeted code change.

## Security Rules

- Never log Hue bridge tokens, application keys, or entertainment client keys.
- Never send Hue bridge credentials to backend services.
- Never collect raw audio.
- Avoid collecting room names, light names, local IPs, or user content in telemetry unless explicitly reviewed.
- Android widgets must not reproduce the iOS App Group plaintext credential pattern.
- Do not expand iOS App Group credential sharing without explicit review.
- Never implement trust-all TLS.
- Never blindly accept all certificates.
- Treat bridge credentials as local-only secrets.

Known iOS security risk:

- Current widget/watch/App Intent surfaces use App Group UserDefaults with raw bridge IP/token for external controls. This is existing behavior, not a pattern to expand or copy to Android.

Known Android security decision:

- API token storage uses Android Keystore-backed AES-GCM blob storage under `noBackupFilesDir`.
- Live pairing remains blocked until TLS and bridge identity are decided.

## Hue API Rules

- Never send custom Composer/app-driven `effects` payloads to `grouped_light` endpoints.
- Native Hue firmware effects require special care; verify current code and docs before changing.
- Use `childResourceRefs` from `RoomDisplayItem` for room membership when available.
- REST loops must use a latest-wins mailbox pattern.
- Do not queue unlimited bridge writes.
- Per-light REST is rate-limited and should be batched/staggered.
- Grouped-light control is good for simple room on/off/brightness/color state.
- DTLS Entertainment is the correct tier for high-frequency spatial/mic sync.
- Hue v1 rule actions use relative paths such as `/lights/1/state`; schedule commands may differ. Verify current `HueV1Client.swift` and `BridgeAnimationEngine.swift` before changing v1 behavior.

## iOS Engineering Rules

- Prefer `@Observable` / Observation framework.
- Do not introduce new `ObservableObject` / `@Published` patterns unless intentionally touching legacy code.
- Preserve generation-counter patterns around async effects.
- Preserve REST latest-wins mailbox patterns.
- Do not touch signing/provisioning/bundle IDs/App Groups/entitlements casually.
- When creating Swift files, update Xcode project references correctly.
- Build after code changes.
- Append `DEVLOG.md` after meaningful implementation sessions.

## Android Engineering Rules

- Use native Kotlin and Jetpack Compose.
- Do not build a giant `UnifiedOrchestrator` equivalent.
- Use clean boundaries: UI, presentation, domain, data, security/storage.
- Store credentials in Android Keystore / encrypted storage.
- Do not store credentials in plaintext preferences.
- Use defensive permission/state machines for local network behavior.
- Do not use trust-all TLS managers.
- Do not blindly return `true` in hostname verification.
- Design for explicit Hue self-signed certificate policy.
- Use Kotlin data classes for UI state where possible.
- Avoid custom equality/diff bugs.
- Do not implement Studio/composer/DTLS/mic/widgets/Wear OS before MVP.

Recommended Android shape:

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

## Android MVP Scope

Include:

- Native Android shell
- Demo mode
- Bridge discovery
- Manual IP entry
- Bridge pairing after TLS/identity decisions
- Secure local credential storage
- Dashboard
- Room/light control
- Scene list and activation
- Basic settings/sign-out
- Basic loading/empty/error states
- Internal testing distribution

Exclude from Android MVP:

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

## Backend Rules

Backend may handle later:

- Feature flags
- Crash/health telemetry
- Release cohorts
- Optional identity
- Optional non-sensitive preset/scene marketplace metadata
- Support diagnostics
- Short-lived pairing handoff tokens, only after review

Backend must not handle:

- Raw Hue bridge credentials
- Required local light control
- High-frequency entertainment streaming
- Microphone/audio processing
- Required local bridge discovery

Start with no-op/local interfaces first:

- `FeatureFlagProvider`
- `TelemetrySink`
- `CrashReporter`

## Current High-Priority Follow-Ups

Process/docs:

- Keep `AGENTS.md` canonical and `CLAUDE.md` thin.
- Keep `DEVLOG.md` current snapshot accurate.
- Verify GitHub branch protection/ruleset status.

iOS:

- Avoid broad refactors in large Swift files.
- Credential-sharing risk remains for App Group widget/watch paths.
- Pairing logs should not expose full tokens/client keys.
- watchOS deployment target should be verified before release work.
- Swift 6 concurrency warning surface should be reduced over time.

Android:

- Resolve pairing TLS bootstrap policy.
- Resolve canonical bridge identity contract.
- Run Gradle validation only when JDK/Android toolchain is available.
- Continue MVP slices without copying iOS monolith patterns.

## Handoff Discipline

Each meaningful session should append to `DEVLOG.md` with:

```markdown
## YYYY-MM-DD - [Codex|Claude|Cursor] Short title

### Branch
- `branch-name`

### Did
- ...

### Working
- ...

### Left
- ...

### Validation
- ...

### Gotchas
- ...
```

Commit and push handoff updates when another agent needs to read them in a different tool or checkout.

## Parallel Agent Pipeline

Multiple agents can work concurrently, each in its own git worktree on a **disjoint set of files**, so
their branches merge together without conflict. Operational registry and decision log:
`docs/coordination/parallel-agent-pipeline.md`.

Core rules:

- A **lane** is a disjoint glob of files one agent owns for a batch. No two active lanes share a glob.
- **Collision-hotspot** files (the iOS monolith `UnifiedOrchestrator.swift` and other gate files; the
  Android `build.gradle.kts`/manifest/theme resources — full list in the pipeline doc) may be touched
  by at most one lane per batch. Feature lanes request changes to them via the Decision Log, not by
  editing directly.
- iOS is mostly **not** parallel-safe because most features funnel through the gate files; run iOS
  lanes one or two at a time. Android's modular layout parallelizes cleanly.
- Lane branches: `lane/<batch>-<slice>`. Integration branch: `integration/parallel-batch-N` (off
  `main`). Disjoint lanes merge onto the integration branch; a human collaborator does the final merge
  to `main` (the agent `gh` account is not a collaborator).
- Lane lifecycle: claim (mark in registry) → work (edit only the lane's globs, run narrowest
  validation) → handoff (append `DEVLOG.md` entry) → merge (onto integration branch).

### Shared Decision Log (Claude ⇄ Codex back-and-forth)

The pipeline doc carries a **Decision Log**: the durable, git-backed channel where agents propose,
debate, and record agreements. Append dated, tagged turns (`YYYY-MM-DD [Claude|Codex]: …`); never
rewrite another agent's turn. `Status` records the agreed state
(`PROPOSED | DISCUSSING | ACCEPTED | REJECTED | DEFERRED`). Open, undecided items live under
"Open Questions". Commit and push so the other tool sees the log on fetch.
