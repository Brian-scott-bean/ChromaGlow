# Android Live Capability Convergence — P2 Frozen Contracts (2026-09-02)

Binding for the writer lanes of `feat/android-live-capability-convergence`. Changing a frozen
signature is a Decision-Log event, not a lane edit. Plan of record: the approved rev-2 synthesis
(Brian, 2026-09-02); architecture: `AppSession → LiveHome → BridgeSession[BridgeId]`.

## Frozen types (package `com.chromaglow.app`)

| Area | File | Types |
|---|---|---|
| Identity | `core/identity/BridgeId.kt` | `BridgeId` (value class, `^[0-9A-F]{16}$`, `parseOrNull`) |
| | `core/identity/ResourceId.kt`, `ResourceType.kt`, `ResourceKey.kt` | `ResourceId`, `ResourceType(wireName)`, `ResourceKey(bridgeId, type, id)` + `composeKey` |
| | `core/identity/DemoTargetId.kt`, `TargetRef.kt` | `DemoTargetId` (must NOT match a physical id), `TargetRef = Live(ResourceKey) \| Demo(DemoTargetId)` |
| Capability | `core/hue/capability/Evidence.kt` | `Evidence {KNOWN, ABSENT, UNSUPPORTED, UNREADABLE, UNKNOWN}`, `Capability<T>` (`isInteractive` = KNOWN only; `isChecking`; `isHidden`) |
| | `MirekRange.kt`, `Gamut.kt`, `CieXy.kt` | `MirekRange` (lamp schema; protocol 153–500 is a body clamp), `Gamut(source: BRIDGE \| SPEC_DERIVED)`, `GamutType A/B/C`, `CieXy` |
| | `LightCapabilities.kt` | `LightCapabilities` (colour, CT, effectsV1/V2, timed, gradient, signaling decode-only, dynamics), `GradientCapability`, `effectValues` (v2 shadows v1) |
| | `ControlRouting.kt`, `EffectRouting.kt` | `RoutingClass`, `ControlKind`, pinned `ControlRouting.classOf`; `EffectRouting = Run \| Unsupported \| RunUnverified` (`permitsUserMutation` true only for non-empty `Run`), `Coverage` |
| Transport | `core/hue/rest/HueClipClient.kt`, `ClipError.kt` | `HueClipClient` (one bridge; `getResources`, `getResource`, `putResource` = the ONLY outbound primitive), `ClipDocument`, `ClipWriteBody`, `ClipResult`, `ClipError` (`Unauthorized` is the only revocation trigger; `Timeout(afterTransmission)`) |
| Stream | `core/hue/sse/EventStreamSource.kt` | `EventStreamSource.open(): Flow<SseFrame>`, `SseFrame = Connected \| Data(payload)` |
| Session | `core/session/ConnectionState.kt` | `Connecting, Connected, Stale(since), Offline, Revoked, Error(reason)` |
| | `core/session/BridgeSnapshot.kt` | `BridgeSnapshot` (bridge-qualified by construction; `Freshness`, `GroupState`, `GroupedLightState`, `LightState`, `SceneState`) |
| | `core/session/BridgeSnapshotCache.kt` | per-bridge, versioned (`FORMAT_VERSION = 1`), `read(): Hit \| Miss \| Discarded`, `write`, `clear` |
| | `core/session/LiveMutation.kt` | `LiveMutation` (10 variants, no signaling), `FieldGroup`, `EffectParameters`, `TimedEffect`, `MutationOutcome = Accepted(token) \| Refused(reason)`, `RefusalReason` |
| | `core/session/MutationCoordinator.kt` | `submit(LiveMutation): MutationOutcome` — the single outbound authority |
| | `core/session/safety/*` | `FlashSafetyConstants` (340 ms, 0.10, red 0.02), `FlashSafety`, `LuminanceFrame`, `RiseLedger` (`admit`/`settle`, `DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION` = delivered), `EffectSafetyRegister` + `DefaultEffectSafetyRegister` (empty deny set) |
| | `core/session/HomeCommands.kt` | `HomeCommands` (every target is a `TargetRef`), `SessionShellCommands` (`forgetBridge(BridgeId)`, `exitToSetup`), `RefreshReason` |
| | `core/session/LiveHome.kt` | `BridgeSession` (snapshot, connection, requestRefresh, submit, close), `HomeSnapshot`, `LiveHome` (compose/route/lifecycle only) |
| Shell | `app/AppSession.kt` | `AppSession = None \| Demo(DemoModeSession) \| Live(LiveHome)` |

Enforced by `ArchitectureBoundaryTest`: only `core/session/**` and `core/hue/rest/**` may reference
`HueClipClient`; `feature/**`, `ui/**`, `app/**` never import `core.hue.rest`/`core.hue.sse`;
production `core/session/**` has no `Thread.sleep`/`runBlocking`/`GlobalScope`.

## Writer ownership (exact globs, no file has two writers)

**Charles — `lane/alcc-core`**
`core/identity/**`, `core/hue/tls/**`, `core/hue/rest/**`, `core/hue/capability/**`, `core/hue/sse/**`,
`core/session/**`, additive fields only in `core/model/**`, `core/hue/pairing/workflow/LivePairingWorkflow.kt`
(`restoreAll` addition), additive `core/bridge/**`, and the matching `src/test/java/com/chromaglow/app/{core,testing}/**`.

**Elmo — `lane/alcc-ui`**
`feature/home/**`, `feature/roomdetail/**`, `feature/lightdetail/**`, `feature/scenes/**`, `feature/settings/**`,
`ui/components/**`, `feature/setup/SetupScreen.kt` (visual composables only, if required), and the matching
`src/androidTest/java/com/chromaglow/app/feature/**` + `src/androidTest/.../ui/**`.

**Adam — integration branch only**
`app/ChromaGlowApp.kt`, `app/ChromaGlowDestination.kt`, `app/AppSession.kt`, `MainActivity.kt`,
`feature/setup/SetupViewModel.kt`, `feature/setup/SetupUiState.kt`, `feature/setup/SetupPlaceholderScreen.kt`,
`feature/dashboard/**` (legacy demo screen until retired), `ui/theme/**`, `res/**`, `AndroidManifest.xml`,
`build.gradle.kts`, `settings.gradle.kts`, `gradle.properties`, `gradle/**`, `.github/**`, `DEVLOG.md`,
`docs/**`, `AGENTS.md`, and all integration merges.

Rules: writers start only from the committed P2 HEAD; Elmo builds against fakes of the frozen
interfaces until Charles's implementations land; a needed change to a frozen type is raised to Adam,
never edited in a lane; lane claims are posted to CNVS memory before the first edit.
