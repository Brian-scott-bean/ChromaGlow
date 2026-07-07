# AGENTS.md - ChromaGlow Canonical Agent Context

This is the canonical project handoff for Codex, Claude, Cursor, and other coding agents. Do not duplicate this full context into tool-specific files. Tool-specific entry files, including `CLAUDE.md`, should point here.

Last consolidated: 2026-06-24 · re-consolidated 2026-06-28 (Android Batches 1-3 on `main`) · re-consolidated **2026-07-07** after the iOS hardening-P1 + Rounds 3-4 + two performance passes were fast-forwarded to `main` @ `6e8a34a` (build 9). The freshest operational detail always lives in the `DEVLOG.md` "Current Status Snapshot".

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

ChromaGlow is a native iOS Philips Hue app (production anchor, **`main` @ `6e8a34a`, 0.9.0 build 9** — hardening P0+P1 remediation complete, Rounds 3-4 Studio/Composer/Perform revamp shipped, warm-app + fresh-install performance passes merged; awaiting Brian's on-device fresh-install verification, after which the TEMP `⏱️PERF` prints get a cleanup commit) with a native Android Kotlin/Jetpack Compose MVP underway (demo flow + tested pairing foundations on `main`; Batch 4 live pairing integrated on `integration/parallel-batch-4`, physical link-button gate pending before promotion).

## Current Branch/Repo Facts

- Remote: `git@github.com:Brian-scott-bean/ChromaGlow.git`
- Default remote branch observed locally: `origin/main`
- Current integration branch should be treated as `main` unless GitHub rules say otherwise.
- **`main` is the branch Brian installs from** (Xcode → physical iPhone, scheme `HueHome 1`). Keep it
  releasable; fast-forward validated work to it rather than letting it drift. As of 2026-07-07,
  `ios-ref/hardening-p1-2026-07` == `main` @ `6e8a34a`.
- Brian's working conventions: create a `checkpoint/*` rollback tag before any multi-commit run; bump
  `CURRENT_PROJECT_VERSION` (all 12 pbxproj entries) each device-test round so stale installs are
  detectable; one independently shippable commit per fix.
- `main` has no GitHub branch protection (verified 2026-07-07 via API — returns 404).
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
- watchOS deployment target: `26.4` (`WATCHOS_DEPLOYMENT_TARGET` in every watch build config — this resolves the earlier "verify watchOS target" follow-up)
- Marketing version in project: `0.9.0`
- Build number in project: `9` (bumped every device-test round; do not reuse a number)
- App display name (main iOS target): `ChromaGlow`
- Widget/watch target display names: still `LightShade` / `LightShadeWatch` (`INFOPLIST_KEY_CFBundleDisplayName`) — pending an explicitly assigned rename; do not rename casually.
- iOS Keychain service identifier (`kSecAttrService`) **and** OSLog subsystem: `com.lightshade.app` — **LIVE, do NOT rename.** `KeychainManager.serviceName` uses this for every credential read/write; renaming it makes every existing user's stored app key + entertainment client key unreadable with no migration. (Audit L-35.)
- App Store Connect ChromaGlow Apple ID recorded in docs: `6766251782`
- Android namespace/applicationId (shipping tree): `com.chromaglow.app`
- Android Hue devicetype recorded in docs: `chromaglow#android`

Only `group.com.lightshade.app` (an App Group that no longer exists) is fully historical. Note that `com.lightshade.app` is NOT historical — it is the live iOS Keychain service + OSLog subsystem listed above and must not be renamed.

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

Round 4 (2026-07-06) durable facts — full record in `docs/ios/round4-execution-record-2026-07-06.md`:

- The Composer editor lives in `HueHome/UI/Composer/CompositionEditorPanel.swift` and the mixer
  tray in `HueHome/UI/Studio/MixerTrayView.swift` (extracted from StudioView, now ~1.5k lines).
- The stage design system is `HueHome/UI/Components/StageKit.swift` (StagePalette tokens,
  StageCard/StageSlider/StageBadge/PatternStripView) — new UI should consume it.
- The old Effects and Sync tab surfaces (`EffectsView`, `EffectControlsView`, `EffectsViewModel`,
  `SyncModeView`, `TabShells`) were DELETED — they had been unreachable since the 4-tab nav
  rework. Firmware effects (incl. effects_v2 params + coverage) live on Studio Deck 0.
  `EffectLibrary`/`HueEffect.swift` remains LIVE via automations; `SavedEffectPreset.swift` holds
  the relocated `EffectParamState`; RestSender still lives in `SyncModeEngine.swift`.

Performance passes (2026-07-07) durable facts — these are load-bearing contracts, do not undo casually:

- `UnifiedOrchestrator` caches raw per-bridge lights (`lightsByBridge`, filled by `loadAll`).
  Consumers: `cachedLightItems(for:)` seeds RoomDetail for instant render; `cachedRawLights(for:)`
  feeds Studio `refreshCoverage` when `lastLoadedAt` < 60s. RoomDetail additionally SKIPS its
  immediate `loadLights()` refetch when seeded and `lastLoadedAt` < 30s — SSE keeps it live.
- SSE-driven dashboard rebuilds are coalesced (~150ms trailing throttle, `scheduleSSERebuild`) and
  SSE echo of the app's own composition PUTs is suppressed for driven rooms (`appDrivenGroupIDs`);
  `stopCompositionMode` re-syncs via `scheduleStateRefresh()`.
- `\.isTabActive` (defined in `MainTabView.swift`, default `true`) pauses hidden-tab animation
  clocks: `PatternStripView`, `StudioCardCanvas`, `BeatStatusChip`, dashboard clock/banner timers.
  New always-on animations MUST consume it.
- `prewarmDeferredTabs` waits for the first `loadAll` to settle (3s cap, demo escape) and realizes
  studio → scenes → more one per main-thread pass. Tap-to-realize is independent and instant.
- `CompositionStore(loadsSynchronously: false)` (Studio's instance) loads off-main; mutations force
  a sync load first (`ensureLoadedForMutation`, M-13). First-launch seed writes CREATE-ONLY via
  `.withoutOverwriting` — NEVER combine it with `.atomic` in `Data.write`: that pair is a Swift
  assertion failure (uncatchable crash), which we shipped-and-caught once already.
- TLS pin acquisition is per-host inside each bridge's fetch task (not a global gate);
  stuck-entertainment cleanup is deferred + 60s-throttled (`scheduleEntertainmentCleanup`) with a
  DEBUG `testAwaitEntertainmentCleanup()` hook for LOAD-01.
- Splash routing is lifecycle-safe (`.task` + scenePhase net + `didRoute`); unpaired dwell is 0.7s.
  WCSession activates from AppRootView's `.task`, not App.init.
- TEMP `⏱️PERF` prints in `RoomDetailView.task` + `UnifiedOrchestrator.loadAll` are diagnostic;
  remove after Brian's on-device fresh-install verification (see DEVLOG snapshot).

## Android Current State

Android is a working Kotlin/Compose **demo MVP on `main` @ `f3380a7`**; both parallel-pipeline pilot
batches plus Batch 3 (tested, non-UI Hue pairing foundations under `core/hue/pairing/**` + bundled CA
roots, incl. the D-014 identity-continuity correction) are merged. Audit/detail:
`docs/coordination/parallel-agent-pipeline.md` (§7, §8, §9, §10 + Decision Log) and the `DEVLOG.md`
handoffs.

**Shipped on `main`** (`android/`, package `com.chromaglow.app`):

- Standalone Gradle/Kotlin/Jetpack Compose project; noir/dark Material theme; `MainActivity` →
  `ChromaGlowApp` lightweight `when(destination)` router (`ChromaGlowDestination`: Setup, Dashboard,
  RoomDetail, Scenes, Settings).
- **Setup** (`feature/setup`): mDNS bridge-discovery chooser via `NsdManager`, manual IP/hostname entry
  parser, NUPnP-deferral record, "Enter Demo Mode" entry. Pairing UI is not wired yet.
- **Demo domain** (`core/model`, `data/demo`): `RoomDisplayModel`, `LightDisplayModel`,
  `SceneDisplayModel` (all guard inputs in `init { require(...) }`); `DemoFixtures` (rooms + per-room
  lights + scenes) and `DemoModeBoundary`/`DemoModeSession`.
- **Dashboard** (`feature/dashboard`): per-room on/off `Switch` + brightness `Slider`, plus discrete
  open-room / Scenes / Settings entry points.
- **Room detail** (`feature/roomdetail`): per-light on/off + brightness controls.
- **Scenes** (`feature/scenes`): scene list with exclusive activation.
- **Settings** (`feature/settings`): demo-mode status, app version, "Exit Demo Mode".
- **App-owned demo state:** `ChromaGlowApp` holds room/light/scene state (seeded on demo-enter, cleared
  on exit), so all in-memory demo mutations survive navigation. No persistence/networking.
- **Security boundary:** Android Keystore-backed API-token credential store exists (no live pairing yet).

**Accepted Android pairing security contract (D-001/D-002/D-012, 2026-06-29):**

- Bundle the two human-supplied Hue CA roots verified at
  `/Users/brianbean/Desktop/chromaglow-hue-ca/`; accept only chains to those roots.
- Current SAN-less Hue bridge leaves are identified by a narrowly scoped, case-insensitive leaf-CN ==
  normalized `bridgeid` check after chain validation. Never use a trust-all manager, always-true hostname
  verifier, TOFU, blind certificate acceptance, or fabricated bridge ID.
- Canonical identity is uppercase 16-hex `bridgeid`; mDNS name/TXT, host, and port are discovery hints.
  A CA-validated leaf CN establishes identity; `/api/0/config.bridgeid` must then match it.
- MVP supports CA-signed bridges only. Legacy self-signed bridges fail closed with firmware-update
  guidance. Omit `generateclientkey`; do not persist `CLIENT_KEY`.
- D-001/D-002 acceptance authorizes the bounded Batch 3 foundation manifest only. Live setup UI,
  credential persistence wiring, and physical pairing remain out of scope until a later accepted batch.

**Durable code contracts (acceptance baseline — each enforced by a test; keep green for any change):**

- **Model guards:** ids/names non-blank; `brightness in 1..100` (0 throws). Sliders use
  `valueRange = 1f..100f` + `coerceIn(1, 100)` before any `copy(brightness = …)`.
- **Fixture light-count invariant:** every `RoomDisplayModel.lightCount` == `DemoFixtures.lightsByRoom[room.id].size`
  (test `rooms_lightCountMatchesLightsByRoomSize`). Current demo counts: Bedroom 4, Kitchen 8, Living 5,
  Office 2 — keep in sync when changing rooms/lights.
- **Scene bridge routing:** `SceneDisplayModel` carries a required non-blank `bridgeId`; demo scenes use
  `DEMO_BRIDGE_ID = "demo-bridge-main"`. Route scene actions by `bridgeId` (do not fabricate/omit it).
- **Fixture surface:** `DemoFixtures` exposes `rooms`, `lights`, `lightsByRoom` (grouped by room id),
  `scenes` (≥3). Do not mutate existing `rooms` values — connected tests assert their exact text.
- **State ownership + callbacks:** `ChromaGlowApp` is the single owner of in-memory demo state; feature
  screens take models by parameter and expose bridge-aware callbacks `(bridgeId, lightId|sceneId, value)`
  — only the app shell and tests read `DemoFixtures`. Scene activation is exclusive.
- **Nav + build:** keep the `when(destination)` router (not Navigation-Compose); `appVersion` is passed
  as a literal (BuildConfig is disabled — do not enable it). Single `Pixel_10` AVD ⇒ run
  `connectedDebugAndroidTest` serially.

**Pipeline status:** Batches 1, 2 & 3 complete (merged to `main`). D-001/D-002/D-011/D-012/D-013/D-014/
D-015 are ACCEPTED. Batch 3 (pairing foundations: deps + bundled CA roots, pure protocol contracts, TLS/identity
verification, HTTPS transport) is **MERGED to `main` @ `f3380a7`** (`--no-ff` from
`integration/parallel-batch-3` @ `c385616` on explicit human go-ahead), **including the D-014 GET→POST
identity-continuity correction** (the create-user POST leg pins its TLS verifier to the GET-authenticated
`bridgeid` and re-checks the POST handshake leaf, so a CA-valid identity change between legs fails closed;
a real dual-cert regression test proves it). Final gate green: unit 174/0 (transport 16/0), lint, assemble,
connected 37/0 on `Pixel_10`; Codex promotion review passed. Batch 3 added no Setup UI, app/nav, discovery,
credential write, token persistence, or live bridge traffic. Public APIs now on `main` for the follow-up
UI/persistence batch: `core/hue/pairing/protocol` (request/response/config parsers), `core/hue/pairing/tls`
(`HueRootCertificates`/`HueRootTrustManager`/`HueLeafHostnameVerifier`/`HueBridgeCommonName`), and
`core/hue/pairing/transport` (`HuePairingClient`/`OkHttpHuePairingClient.fromContext`). Details: pipeline
doc §10 "Batch 3 execution result" + "Batch 3 D-014 correction result". Raise additional proposals as
D-016+ in the pipeline doc.

**Batch 4 prepared contract (D-015):** one active bridge in Setup backed by list-ready non-secret metadata;
pairing success must carry authenticated `bridgeId` + `username`; selected endpoints pair over HTTPS 443;
the token is persisted only by `BridgeCredentialStore`; metadata lives in a Preferences DataStore under
`noBackupFilesDir`; startup requires record + readable token; Forget Bridge is local-only. Batch 4 ends at
"Bridge connected" on Setup — real Hue resource loading/dashboard control is Batch 5. Manifest: pipeline
§11. Launch prompt: `docs/coordination/prompts/parallel-batch-4-launch.md`.


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

The 2026-07-01 hardening audit (`docs/audit/hardening-audit-2026-07-01.md`) found the iOS app
currently **violates** two of these rules and lists the fixes (P0). Treat these as open until closed:

- **Trust-all TLS (rule "Never implement trust-all TLS"):** every iOS bridge surface (main app REST/SSE,
  widget, Siri intents, watch, and the pairing POST) returns `.useCredential` without acting on the
  certificate evaluation — H-01/H-02/M-01. Fix: one shared pinned-trust evaluator (Android model).
- **Secrets in logs (rule "Never log tokens/keys"):** the v1 client logs the app key in the URL at
  `privacy:.public` in release, and pairing logs the token + entertainment client key — H-03/H-04.

Known iOS security risk:

- Current widget/watch/App Intent surfaces use App Group UserDefaults with raw bridge IP/token for external controls. This is existing behavior, not a pattern to expand or copy to Android. The audit tracks the migration to a Keychain access group as M-02/L-30.

Known Android security decision:

- API token storage uses Android Keystore-backed AES-GCM blob storage under `noBackupFilesDir`.
- Pairing trust/identity contracts are accepted as documented above. Batch 3 implements foundations only;
  no live UI or credential write is authorized in that batch.

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
- Enforce the accepted Hue CA-signed-only certificate and canonical-identity policy.
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

Security hardening audit (2026-07-01) — full report: `docs/audit/hardening-audit-2026-07-01.md`
(0 Critical, 5 High, 19 Medium, 55 Low).

- **iOS P0 + P1 remediation: COMPLETE and merged to `main`** (2026-07 hardening-P1 run): per-bundle
  privacy manifests (M-03), secret log scrub (H-03/H-04/L-09), bridge TLS pinning D-016
  (H-01/H-02/M-01), Keychain access group D-018 (M-02/L-30), M-04..M-18 fixes, mic/session fixes
  (L-19..L-23), plus the two 2026-07-07 performance passes. Evidence: `docs/ios/*`, branch history.
- **P1 Android (still open):** designate a canonical Android source tree and add an Android CI gate
  (M-19, see "Canonical Android source tree" below).

iOS — active follow-ups (in order):

1. **Brian's on-device fresh-install verification of build 9** (`main` @ `6e8a34a`): ~0.7s to
   bridge-setup, no post-pairing hang, `⏱️PERF room-open … INSTANT`. This gates step 2.
2. Cleanup commit removing the TEMP `⏱️PERF` prints (RoomDetailView + loadAll) once confirmed.
3. Intermittent device crash reported on builds ≤8 — likely the AVAudioEngine route crash
   (`bc5b2ba` fix unconfirmed on device). If build 9 crashes: capture the device crash log first.
4. Deferred by explicit decision (don't resurrect without a driver): async/two-phase
   ModelContainer; dead Sync-engine stack deletion (extract the live `RestSender` from
   `SyncModeEngine.swift` first + pbxproj edits); `CompositionEngine.render` off main-actor
   (cheap per measurement; `CompositionParamBox` is MainActor-confined, audit I-10); MoreView
   `connectionStatus` re-render trimming; fix `run_tests.sh` stale `SCHEME="HueHome"`.

Process/docs:

- Keep `AGENTS.md` canonical and `CLAUDE.md` thin.
- Keep `DEVLOG.md` current snapshot accurate.
- `main` has no branch protection (verified 2026-07-07); keep it releasable anyway — it is the
  branch Brian installs from.

iOS standing rules:

- Avoid broad refactors in large Swift files.
- Respect the "Performance passes durable facts" contracts above (isTabActive, caches, coalescing,
  prewarm gating, CompositionStore seed semantics).
- Swift 6 concurrency warning surface should be reduced over time (known remaining:
  `RoomCard: Equatable` main-actor isolation warning in DashboardView).

Android:

- Batch 4 is executed/integrated on `integration/parallel-batch-4` @ `040fed7` (automated gate green);
  re-run the human-assisted link-button/relaunch/local-forget physical bridge gate with the correct
  worktree APK, then promote to `main`.
- Do not route a real paired bridge into the demo dashboard; real resource loading/control is Batch 5.
- Run Gradle validation only when JDK/Android toolchain is available.
- Continue MVP slices without copying iOS monolith patterns.
- Build/audit Android only from the canonical tree (see below), never the stale in-repo checkout.

### Canonical Android source tree (audit M-19)

There are two divergent Android trees. The validated pairing/TLS/credential hardening lives **only** on
`integration/parallel-batch-4` @ `040fed7` (Batch 3 foundations are on `main` @ `f3380a7`). The
`android/` module in a default checkout of a `docs/*` branch can be many commits behind and may contain
**none** of the pairing code or its dependencies (okhttp / kotlinx-serialization / datastore). Both trees
build `applicationId com.chromaglow.app` / `versionName 1.0`, so a stale APK is indistinguishable from a
hardened one without a sha256/dex inspection (a stale APK already shipped once — see the 2026-07-01
DEVLOG diagnosis). There is currently **no Android CI** (`.github/workflows/` has only
`ios-build-provenance.yml`). Required: pick one canonical/shippable Android branch, keep working
checkouts on it, and add an Android build + hardening-presence CI gate (fail if the
`core/hue/pairing` / `core/hue/pairing/tls` / `core/bridge` packages or `SetupViewModel` are absent, or
if the okhttp/serialization/datastore deps are missing) plus per-build `versionName`/`versionCode` bumps.
Tracked as D-020 in the pipeline Decision Log.

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
  `main`). Disjoint lanes merge onto the integration branch; the batch owner may perform the final
  merge to `main` only after the human collaborator's explicit go-ahead. The local SSH push identity
  can push `main`; any `gh` bot-account limitation applies only to that account.
- Lane lifecycle: claim (mark in registry) → work (edit only the lane's globs, run narrowest
  validation) → handoff (return structured text to the batch owner) → merge (onto integration
  branch). The batch owner serially updates `DEVLOG.md` and the registry; lane agents do not edit
  those shared files while a batch is running.

### Shared Decision Log (Claude ⇄ Codex back-and-forth)

The pipeline doc carries a **Decision Log**: the durable, git-backed channel where agents propose,
debate, and record agreements. Append dated, tagged turns (`YYYY-MM-DD [Claude|Codex]: …`); never
rewrite another agent's turn. `Status` records the agreed state
(`PROPOSED | DISCUSSING | ACCEPTED | REJECTED | DEFERRED`). Open, undecided items live under
"Open Questions". Commit and push so the other tool sees the log on fetch.
