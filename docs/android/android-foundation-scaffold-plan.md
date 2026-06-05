# Android Foundation Scaffold Plan

## Purpose

**ANDROID-001A** inventories the repository and local Android toolchain, freezes durable foundation-scaffold decisions (or marks them open), and defines the boundary for **ANDROID-001B — Create standalone native Android foundation scaffold**.

This pass is **documentation-only**. No Android project files, Kotlin sources, Gradle files, SDK installs, iOS changes, builds, commits, or pushes were performed.

**No Android project files were created in ANDROID-001A.**

**ANDROID-001B must not begin until Brian approves `namespace` and `applicationId`.**

**Exact dependency versions (Android Gradle Plugin, Kotlin, Compose BOM, compile/target SDK pins) must be chosen from the installed toolchain and verified for compatibility during ANDROID-001B; do not guess versions from memory.**

## Readiness Gate

| Gate | Status |
| --- | --- |
| Repo path | `/Users/brianbean/Desktop/huehome-pro-v0.3.0` |
| Branch | `android/foundation-scaffold` |
| Starting SHA | `092fdd7` |
| Working tree at inventory start | Clean |
| `origin/main` ancestry | Yes (`0/0` vs `origin/main`) |
| Android MVP kickoff (repo docs) | **READY WITH DOCUMENTED FOLLOW-UPS** |
| Existing Android application scaffold | **None** (only `docs/android/`) |
| Local Android toolchain (this host) | **BLOCKED — TOOLCHAIN INSTALL REQUIRED** |

Android product kickoff is **READY WITH DOCUMENTED FOLLOW-UPS** per [`docs/ios/final-readiness-validation.md`](../ios/final-readiness-validation.md) and [`DEVLOG.md`](../../DEVLOG.md) (IOS-OPS-FINAL-C reconciliation). That readiness applies to **MVP contract and iOS evidence**; it does **not** mean this Mac can compile Android today without installing JDK, Android Studio, and the SDK.

Confirmed before writing:

- Greenfield **standalone native Android** scaffold (not Flutter, not Wear OS).
- **Kotlin + Jetpack Compose** required.
- Hue bridge control remains **local and on-device**; minimal backend is optional support infrastructure only.
- Current **iOS behavior is the parity anchor**, not a mandate to copy storage layout or architecture.
- Android must **not** copy the iOS `UnifiedOrchestrator` god-object shape blindly.

## Source-of-Truth Docs

| Document | Role |
| --- | --- |
| [`docs/android/android-mvp-contract-freeze.md`](android-mvp-contract-freeze.md) | Authoritative Android MVP scope and behavioral contracts |
| [`docs/ios/final-readiness-validation.md`](../ios/final-readiness-validation.md) | iOS ops pass; Android kickoff readiness |
| [`docs/ios/discovered-bridge-pairing-loop-inventory.md`](../ios/discovered-bridge-pairing-loop-inventory.md) | Discovery/pairing evidence; IOS-BUG-001B resolution |
| [`docs/ios/stabilization-map.md`](../ios/stabilization-map.md) | Stabilization goals; extraction seams |
| [`docs/ios/current-behavior-map.md`](../ios/current-behavior-map.md) | Shipped iOS behavior map |
| [`docs/ios/hue-contract-inventory.md`](../ios/hue-contract-inventory.md) | Hue REST/SSE inventory (note SSE path discrepancy) |
| [`docs/ios/persistence-and-credentials.md`](../ios/persistence-and-credentials.md) | Credential patterns (evidence, not Android blueprint) |
| [`DEVDOC.md`](../../DEVDOC.md) | Architecture history and constraints |
| [`DEVLOG.md`](../../DEVLOG.md) | Session handoff log |
| [`.cursorrules`](../../.cursorrules) | iOS non-negotiables (do not modify in ANDROID-001A) |
| [`CURSOR_KICKOFF.md`](../../CURSOR_KICKOFF.md) | Current iOS Composer focus (Android is separate track) |

## Existing Android Scaffold Inventory

**Phase 3 commands (2026-06-03):**

- `find` for Gradle/Kotlin/AndroidManifest: **no matches** (no `settings.gradle`, `build.gradle`, `*.kt`, `AndroidManifest.xml`, etc.).
- `find` depth-3 dirs named `android`, `app`, `gradle`, `.gradle`, `.idea`: **only** `./docs/android`.

**Conclusion:** No existing tracked Android application scaffold. Safe to plan greenfield `android/` root in ANDROID-001B.

## Local Toolchain Inventory

Inventory date: **2026-06-03**. Read-only shell probes on Brian's Mac (full permissions; no installs).

| Tool | Result | Version / Path | Scaffold Impact |
| --- | --- | --- | --- |
| `JAVA_HOME` | Unset | — | ANDROID-001B needs explicit JDK (typically bundled with Android Studio) |
| `java` | Present at `/usr/bin/java` but **no JRE** | Error: *Unable to locate a Java Runtime* | Cannot run Gradle or `gradlew` until JDK installed |
| `/usr/libexec/java_home -V` | Failed | Same JRE error | No installed JDK candidates listed |
| `gradle` (system) | Not found | — | Use Gradle **wrapper** in repo after ANDROID-001B; do not rely on global Gradle |
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | Unset | — | ANDROID-001B should set via `local.properties` (gitignored) or shell profile |
| Android Studio | **Not found** | `/Applications/Android Studio.app` absent | Install Studio for template sync, SDK Manager, emulator |
| SDK root candidate | Missing | `$HOME/Library/Android/sdk` does not exist | No `platforms`, `build-tools`, `platform-tools`, `cmdline-tools`, or `emulator` to derive compile SDK |
| `adb` | Not found | — | Device deploy blocked until SDK `platform-tools` installed |
| `sdkmanager` | Not found | — | Cannot list or install SDK packages from CLI on this host |
| `emulator` | Not found | — | Compose UI / instrumented smoke on emulator deferred until SDK + AVD |

## Toolchain Classification

**BLOCKED — TOOLCHAIN INSTALL REQUIRED**

Minimum local setup before ANDROID-001B can verify builds (recommended order):

1. Install **Android Studio** (includes JDK and SDK Manager UI).
2. Install at least one **Android SDK Platform** (compile SDK — version chosen from Studio defaults at install time).
3. Install **Android SDK Build-Tools** matching AGP requirements (version pinned during ANDROID-001B compatibility check).
4. Install **Android SDK Platform-Tools** (`adb`).
5. Optional for MVP scaffold smoke: **emulator** system image + AVD.

Do **not** install components in ANDROID-001A (task prohibition). Brian or a follow-up session installs before or during ANDROID-001B.

After install, re-run the Phase 4 inventory and update compile SDK / JDK rows from **DERIVED FROM INSTALLED TOOLCHAIN**.

## Durable Project Decisions

| Decision | Status | Proposal | Reasoning | Approval Needed |
| --- | --- | --- | --- | --- |
| Android project root | **APPROVED** | `android/` at repo root | Matches approved standalone app layout; isolates Gradle from iOS tree; aligns with MVP contract package diagram | No |
| Gradle module layout | **APPROVED** | Single module `:app` initially | Smallest greenfield scaffold; feature packages inside `:app` until transport layers warrant extraction | No |
| App display name | **APPROVED** | `ChromaGlow` | Matches product branding across repo docs | No |
| Namespace (Kotlin package root) | **PROPOSED — NEEDS BRIAN APPROVAL** | `com.chromaglow.app` | Aligns with `chromaglow` Hue `devicetype` branding; distinct from iOS bundle `com.huehome.pro`; maps cleanly to `src/main/java/com/chromaglow/app/` | **Yes — blocks ANDROID-001B** |
| Play Store `applicationId` | **PROPOSED — NEEDS BRIAN APPROVAL** | `com.chromaglow.app` | New Android SKU; iOS ships `com.huehome.pro` — Play listing and cross-platform identity may prefer same or different ID | **Yes — blocks ANDROID-001B** |
| Package naming rule | **APPROVED** | Feature-oriented packages under namespace: `app`, `core.model`, `core.ui`, `feature.*`, `data.demo` | Mirrors [`android-mvp-contract-freeze.md`](android-mvp-contract-freeze.md) boundaries without premature Gradle modules | No |
| Minimum Android SDK (`minSdk`) | **PROPOSED — NEEDS BRIAN APPROVAL** | API **26** (Android 8.0) | Reasonable 2026 floor for Compose + local networking; not derived from installed SDK (none present). Alternative: API 24 if broader device support is required | **Yes** |
| Compile SDK | **DERIVED FROM INSTALLED TOOLCHAIN** (pending) | Resolve during ANDROID-001B | No SDK platforms on host; use highest stable platform installed via Android Studio | No (auto after install) |
| Target SDK | **PROPOSED — NEEDS BRIAN APPROVAL** | Match compile SDK at scaffold time unless Play policy requires otherwise | Target SDK affects behavior permissions and store policy; pin with compile SDK after toolchain inventory | **Yes** |
| JDK baseline | **DERIVED FROM INSTALLED TOOLCHAIN** (pending) | JDK **17** expected for current AGP/Kotlin stacks | No JRE on host today; Studio-bundled JDK is default source of truth | No (verify at 001B) |
| Gradle wrapper | **APPROVED** | Commit `gradlew`, `gradlew.bat`, `gradle/wrapper/*`, root `gradle.properties` in ANDROID-001B | Reproducible builds without global Gradle; standard Android practice | No |
| Android Gradle Plugin | **DEFERRED** | Resolve during ANDROID-001B using locally installed Android Studio template and compatibility checks. Do not guess. | No AGP/Kotlin compile on this host | No |
| Kotlin plugin | **DEFERRED** | Resolve during ANDROID-001B using locally installed Android Studio template and compatibility checks. Do not guess. | Same | No |
| Compose setup | **APPROVED** | Jetpack Compose with **Compose BOM** (or Studio template equivalent) for aligned artifact versions | Repo requires Compose; BOM avoids version skew across Compose libraries | Version pin at 001B |
| UI toolkit | **APPROVED** | Jetpack Compose | Frozen in MVP contract | No |
| Material baseline | **APPROVED** | Material 3 (`androidx.compose.material3`) | Matches modern Compose defaults; dark-first UI can follow iOS Noir/amber parity in ANDROID-002A | No |
| Navigation | **APPROVED** | Navigation Compose shell with placeholder routes | Minimal 001B shell; routes expand per MVP slices | No |
| Dependency injection | **APPROVED** | **Defer** DI framework (Hilt/Koin) in 001B | Avoid premature graph; manual construction or factories until feature modules stabilize | No |
| Persistence (non-secret) | **APPROVED** | **DataStore** for small prefs; **Room** when bridge routing metadata and cache entities land (ANDROID-004A / 007A) | MVP contract: Keystore for secrets; Room/DataStore for bridge metadata | No |
| Secret storage | **APPROVED** | **Android Keystore** (or EncryptedSharedPreferences with Keystore-backed master key) | MVP contract; never store API tokens in plain DataStore | No |
| HTTP client | **APPROVED** | Future isolated module/package `core.hue.rest` (not created in 001B) | OkHttp suggested in contract; implement in REST transport slice | No |
| SSE client | **APPROVED** | Future isolated module/package `core.hue.sse` (not created in 001B) | Live path on iOS is `UnifiedOrchestrator.runSSE` — Android splits SSE out | No |
| Testing | **APPROVED** | JUnit 4/5 unit smoke in `src/test`; Compose UI test in `src/androidTest` if emulator available | 001B: minimal placeholder tests only | No |
| CI | **DEFERRED** | Separate Android CI workflow in a later slice | No `.github` Android workflow in 001B | No |
| Hue `devicetype` string | **PROPOSED — NEEDS BRIAN APPROVAL** | `chromaglow#android` | iOS uses `chromaglow#ios` per `AppBrand`; distinct Android constant required by contract | **Yes** (product constant; not Gradle) |

## Proposed Project Layout

Greenfield tree for **ANDROID-001B** (not created in 001A):

```text
android/
  settings.gradle.kts
  build.gradle.kts
  gradle.properties
  gradlew
  gradlew.bat
  gradle/wrapper/
  app/
    build.gradle.kts
    src/main/AndroidManifest.xml
    src/main/java/com/chromaglow/app/    # pending namespace approval
    src/main/res/
    src/test/
    src/androidTest/
```

Recommended packages inside `:app` (namespace prefix `com.chromaglow.app` pending approval):

```text
com.chromaglow.app
  MainActivity / ChromaGlowApplication (minimal)
  navigation/          # Compose NavHost shell
  ui/theme/            # Material 3 placeholder theme
  core.model/          # empty or stub until ANDROID-003A
  core.ui/             # shared composables later (ANDROID-002A)
  feature.setup/       # placeholder route (pairing later)
  feature.dashboard/   # placeholder route
  feature.roomdetail/  # placeholder route
  feature.scenes/      # placeholder route
  data.demo/           # demo-mode entry boundary stub
```

## ANDROID-001B Boundary

**In scope for ANDROID-001B:**

- Create `android/` Gradle project with **`:app` only**.
- Wrapper scripts and properties committed.
- `AndroidManifest.xml` with application label **ChromaGlow**.
- Minimal Compose `MainActivity`: theme placeholder, top-level `NavHost` with placeholder routes (setup, dashboard, room detail, scenes, demo entry stub).
- Unit-test smoke (e.g. trivial assertion).
- Compose UI smoke **if** local emulator/toolchain supports it after install.
- `.gitignore` entries for Android build artifacts **only if** required as part of scaffold generation (prefer standard Studio template defaults).

**Out of scope — do not implement in ANDROID-001B:**

- mDNS, NUPnP, manual IP discovery
- Link-button pairing
- Credential / Keystore persistence
- REST transport, SSE transport, certificate trust policy
- Dashboard API models, Room database, demo data provider logic
- Hue networking of any kind
- Backend integration
- Android CI workflow
- iOS code or doc changes outside allowed files

** Preconditions:**

1. Brian approves **namespace** and **applicationId**.
2. Local toolchain at least **READY WITH LOCAL SETUP STEPS** (Studio + SDK + JDK installed).
3. Re-run toolchain inventory; pin AGP/Kotlin/Compose BOM/compile SDK from installed template.

## Explicitly Deferred from ANDROID-001B

See boundary above. Additionally deferred to MVP roadmap slices: design tokens (002A), demo models (003A), credentials (004A), discovery (005A–005C), pairing (006A), dashboard state (007A), controls (008A–009A), scenes (010A), SSE (011A), physical parity packet (012A).

## Proposed Android MVP Iteration Roadmap

**Status: PROPOSED** — not final until scaffold decisions (namespace, `applicationId`, SDK floors, toolchain) are approved and ANDROID-001B lands.

| ID | Slice |
| --- | --- |
| ANDROID-001B | Create standalone native Android foundation scaffold |
| ANDROID-002A | Establish Android design-system tokens and screen-shell parity map |
| ANDROID-003A | Add demo-mode domain models and dashboard fixtures |
| ANDROID-004A | Inventory and implement local credential-storage boundary |
| ANDROID-005A | Inventory and implement mDNS bridge discovery chooser |
| ANDROID-005B | Add manual-IP bridge entry |
| ANDROID-005C | Inventory NUPnP fallback behavior after IOS-BUG-002A — **inventory/decision complete; deferred** ([record](android-nupnp-fallback-inventory.md)) |
| ANDROID-006A | Implement link-button pairing |
| ANDROID-007A | Add dashboard room / zone models and local stale-state store |
| ANDROID-008A | Add room and grouped-light control |
| ANDROID-009A | Add room-detail individual-light control |
| ANDROID-010A | Add scenes list and activation |
| ANDROID-011A | Add SSE visible-state updates and reconnect behavior |
| ANDROID-012A | Run Android physical bridge parity packet |

**ANDROID-005C status (2026-06-04):** Inventory / decision pass complete. Decision: **defer implementation until IOS-BUG-002A resolves the cloud N-UPnP endpoint contract** (observed `404 page not found`, root cause unresolved). Android proceeds with **ANDROID-005A mDNS chooser + ANDROID-005B manual entry** as the active onboarding baseline. Any cloud-assisted fallback is a future gated follow-up and must feed the existing chooser (never silently auto-select). See [`android-nupnp-fallback-inventory.md`](android-nupnp-fallback-inventory.md).

## iOS Evidence That Android Must Not Copy Blindly

| iOS pattern | Why Android should differ |
| --- | --- |
| `UnifiedOrchestrator` singleton | God-object mixing discovery, REST, SSE, cache, optimistic updates, entertainment — split into `core.hue.*` + feature ViewModels/state |
| Unwired `HueSSEService.swift` | Live SSE is `UnifiedOrchestrator.runSSE` — do not port dead code path |
| `ObservableObject` / legacy Combine patterns | Use Kotlin coroutines + `@Composable` + recommended Android state holders |
| SwiftData + Keychain hybrid as blueprint | Android: Keystore secrets + Room/DataStore metadata per MVP contract |
| `WidgetDataStore` / App Group credential publish | **iOS-only** — not Android-MVP |
| `BridgeCertTrustDelegate` unconditional trust | **TODO-SECURITY** — evidence only; explicit Android network security / TOFU decision |
| Studio / Composer / DTLS / mic sync | Explicitly Post-MVP on Android |
| Effects on `grouped_light` | Bridge ignores — per-light effects only (parity rule from `.cursorrules`) |
| REST v1 schedules/rules/animation upload | Not required for Android MVP |

**Non-blocking iOS follow-ups (record only):**

- **IOS-BUG-001C** — Clarify selected-bridge pairing retry feedback
- **IOS-BUG-002A** — Inventory Philips cloud-discovery fallback 404
- Credential rotation before iOS release signoff (DEBUG log exposure)

These do **not** block Android foundation scaffolding.

## Open Decisions for Brian

1. **Namespace:** `com.chromaglow.app` vs align with iOS `com.huehome.pro` package style?
2. **applicationId:** `com.chromaglow.app` vs `com.huehome.pro` for Play Store / brand continuity?
3. **minSdk:** API 26 vs lower (e.g. 24)?
4. **targetSdk:** Match compile SDK at scaffold time or target older for phased migration?
5. **Hue `devicetype`:** Confirm `chromaglow#android` string?
6. **Toolchain:** Install Android Studio + SDK on this Mac (or designate another build host) before ANDROID-001B?

## Stop Conditions for ANDROID-001B

Stop and report (do not scaffold) if:

- Active branch is not `android/foundation-scaffold` (or agreed integration branch).
- Working tree dirty with unrelated changes.
- Branch behind `origin/main` or main not ancestor of HEAD.
- **Namespace** or **applicationId** not approved by Brian.
- An Android scaffold already exists (duplicate project).
- Toolchain remains **BLOCKED** and Brian has not authorized scaffold-without-local-build (not recommended).
- Task scope expands beyond allowed files or implements Hue networking in 001B.

When dependency versions are not grounded in installed toolchain, record the open item — **do not guess**.

---

## Post-Install Toolchain and ANDROID-001B Scaffold Record (2026-06-03)

**Status:** ANDROID-001B scaffold boundary implemented on branch `android/foundation-scaffold-implementation` (starting SHA `f2cb14a`). Preserves ANDROID-001A inventory history above.

| Item | Value |
| --- | --- |
| Android Studio | Installed |
| Bundled JBR | OpenJDK **21.0.10** |
| SDK root | `/Users/brianbean/Library/Android/sdk` |
| Installed API platforms | **36.1** and **37** |
| Installed build tools | **36.1.0** and **37.0.0** |
| `adb` | Available |
| `sdkmanager` | Available |
| `emulator` | Available |
| AVD | **Pixel_10** |
| Emulator launch | Verified |
| Namespace (approved) | `com.chromaglow.app` |
| `applicationId` (approved) | `com.chromaglow.app` |
| Hue `devicetype` (approved) | `chromaglow#android` |
| `minSdk` (approved) | **26** |
| `compileSdk` (selected) | **37** (Compose BOM metadata failed against API 36.1; build verified against installed API 37) |
| `targetSdk` (selected) | **36** |
| Generated Compose template | Validated (Gradle sync, debug build, unit test, connected test, APK install, launcher) |
| ANDROID-001B boundary | Portable Gradle wrapper; machine-local Studio paths gitignored; ChromaGlow shell with setup + dashboard placeholders; demo-mode entry boundary; JVM + Compose smoke tests; no Hue networking |

**Pinned dependency versions (from generated template, not bumped in 001B):**

| Component | Version |
| --- | --- |
| Gradle wrapper | **9.4.1** |
| Android Gradle Plugin | **9.2.1** |
| Kotlin | **2.2.10** |
| Compose BOM | **2026.02.01** |

**001B portable scaffold packages (inside `:app` only):**

```text
com.chromaglow.app
com.chromaglow.app.app
com.chromaglow.app.data.demo
com.chromaglow.app.feature.setup
com.chromaglow.app.feature.dashboard
```

**Still deferred:** mDNS, NUPnP, manual IP, pairing, credentials, Keystore, DataStore, Room, REST/SSE, real dashboard UI, backend, extra Gradle modules, Navigation Compose dependency (local Compose state used for first shell).
