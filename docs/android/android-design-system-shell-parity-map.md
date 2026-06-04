# Android Design-System Tokens and Screen-Shell Parity Map

## Purpose

**ANDROID-002A** establishes the authoritative design-system token map and screen-shell parity contract for the native Android ChromaGlow MVP. This document bridges iOS production UI evidence (`HueTokens.swift`, `HueTypography.swift`, setup/dashboard shells) with Material 3 implementation choices for Kotlin/Jetpack Compose.

This pass is **documentation-only**. No Kotlin, Gradle, theme code, navigation libraries, or iOS files are modified here. Implementation belongs to **ANDROID-002B** and later slices.

**Parity principle:** semantic UI parity with iOS production anchors — not pixel-identical cloning. Android uses Material 3 roles and Compose primitives; iOS uses SwiftUI and SF Pro.

## Source-of-Truth References

| Source | Role |
| --- | --- |
| [`HueHome/UI/Components/HueTokens.swift`](../../HueHome/UI/Components/HueTokens.swift) | Color, spacing, radius, shadow, gradient, motion tokens |
| [`HueHome/UI/Components/HueTypography.swift`](../../HueHome/UI/Components/HueTypography.swift) | Typography scale and section-header styling |
| [`HueHome/UI/BridgeSetup/BridgeSetupView.swift`](../../HueHome/UI/BridgeSetup/BridgeSetupView.swift) | Setup shell phases, gradient, glass-adjacent surfaces |
| [`HueHome/UI/Dashboard/DashboardView.swift`](../../HueHome/UI/Dashboard/DashboardView.swift) | Dashboard shell, room cards, loading/empty/toolbar |
| [`HueHome/UI/Navigation/MainTabView.swift`](../../HueHome/UI/Navigation/MainTabView.swift) | iOS tab shell (deferred on Android MVP shell slices) |
| [`docs/android/android-mvp-contract-freeze.md`](android-mvp-contract-freeze.md) | MVP scope, acceptance matrix, non-parity decisions |
| [`docs/android/android-foundation-scaffold-plan.md`](android-foundation-scaffold-plan.md) | Scaffold history (navigation note superseded below) |
| [`docs/ios/final-readiness-validation.md`](../ios/final-readiness-validation.md) | iOS readiness; Android kickoff follow-ups |
| Current Android scaffold | `android/app/.../ui/theme/{Color,Theme,Type}.kt`, `ChromaGlowApp.kt`, placeholder screens |

## Approved Product Decisions

| Decision | Status |
| --- | --- |
| `dynamicColor = false` for MVP | **Approved** — Material scheme is fixed ChromaGlow Noir; no wallpaper-derived colors |
| Dark-first **Luminous Noir** only for MVP | **Approved** — `ChromaGlowTheme` forces dark; no user-facing light theme |
| **Estate** light tokens | **Future reference only** — documented in token tables; not enabled in ANDROID-002B |
| No enabled Android light scheme in ANDROID-002B | **Approved** |
| Setup background | **Noir base (`#141414`) + subtle purple-tinted gradient token** — semantic match to iOS onboarding mood without copying iOS blur orbs |
| Parity style | **Semantic parity**, not pixel-identical iOS cloning |
| Navigation | **Keep** existing local `ChromaGlowDestination` enum + `when` in `ChromaGlowApp` — **no Navigation Compose** dependency in shell slices |
| Deferred tabs/features | Presets, now-playing, automations, Studio, More, favorite scenes, wide-card layout toggle, light theme |
| ANDROID-002B placeholders | **No** stub UI for deferred features |
| Glass treatment | **Alpha surface + subtle border + restrained shadow/glow** — no blur, no `RenderEffect`, no new dependency |
| Haptics | **Deferred** to later interaction-parity work |
| Wide-card layout toggle | **Deferred** from MVP shell |
| `core.ui` extraction | **Wait** until a second real caller exists; do not preempt in ANDROID-002B |
| Orchestrator shape | Android must **not** copy `UnifiedOrchestrator` god-object |

## Current Android Scaffold Baseline

| Item | Current state (ANDROID-001B) | ANDROID-002B target |
| --- | --- | --- |
| Theme entry | `MainActivity` → `ChromaGlowTheme` → `ChromaGlowApp` | Same wiring; replace scheme/typography |
| `ChromaGlowTheme` | `dynamicColor: Boolean = true` by default; uses `dynamicDarkColorScheme` / `dynamicLightColorScheme` on API 31+ | Set **`dynamicColor = false`**; fixed Noir `darkColorScheme` |
| `Color.kt` | Template **purple/pink** Material starter (`Purple80`, `Purple40`, etc.) | Replace with documented ChromaGlow tokens |
| `Type.kt` | Single overridden `bodyLarge`; defaults elsewhere | Expand mapping per typography table |
| Destinations | `ChromaGlowDestination.Setup` \| `Dashboard` only | **No new destinations** in 002B |
| Setup screen | `SetupPlaceholderScreen` — title, subtitle, **Enter Demo Mode** button | Apply Noir gradient background + amber demo CTA styling only |
| Dashboard screen | `DashboardPlaceholderScreen` — demo copy + **Back to Setup** | Themed shell only; **no** room grid |
| Navigation | `remember { mutableStateOf(destination) }` + `when` | Unchanged — **no** Navigation Compose |
| Demo boundary | `DemoModeBoundary` / `DemoModeSession` | Unchanged in 002B |

**Explicit today:** template purple colors and **dynamic color enabled by default** remain in the repo until ANDROID-002B replaces them.

## iOS Production UI Anchor Inventory

| Surface | iOS anchor | Android MVP shell relevance |
| --- | --- | --- |
| Design tokens | `HuePalette`, `HueSpacing`, `HueRadius`, `HueAnimation`, `HueFont` | Material 3 + custom extension colors |
| Setup onboarding | `BridgeSetupView` — phases, gradient, phase icon, CTAs, manual IP sheet, demo entry | Future setup slice; 002B themes placeholder only |
| Dashboard home | `DashboardView` — ambient background, summary, grid, zones, toolbar, toast | Future dashboard slice; 002B themes placeholder only |
| Room card | `RoomCard` + `BrightnessRow` in `DashboardView.swift` | Contract documented; not built in 002B |
| Tab shell | `MainTabView` — Home, Scenes, Studio, More | **Deferred** — Android MVP shell uses setup ↔ dashboard gate only |
| Orchestration | `UnifiedOrchestrator` | **Evidence only** — split Android modules per MVP contract |

## Material 3 Token Strategy

1. **Single dark `ColorScheme`** built from Noir semantic tokens; map amber to `primary` / `primaryContainer` as appropriate.
2. **`dynamicColor = false`** at `ChromaGlowTheme` call site and default parameter — never fall back to wallpaper colors in MVP.
3. **Custom colors** outside `ColorScheme` for glass borders, amber glow, setup gradient stops, and room-card glow (Compose `Color` constants in theme package).
4. **Typography:** map `HueFont` sizes/weights to Material `Typography` slots (`displayLarge`, `headlineMedium`, `titleLarge`, `bodyLarge`, `labelSmall`, etc.) using default/system sans — not SF Pro.
5. **Shapes:** `MaterialTheme.shapes` overridden from `HueRadius` (small/medium/large/extraLarge + pill for chips/buttons).
6. **Elevation:** prefer tonal elevation + custom shadow/glow tokens; avoid Material elevation that implies light-theme contrast.
7. **Motion:** spring-like `animate*AsState` / `AnimatedVisibility` durations derived from `HueAnimation` response/damping; honor **Reduce Motion** (instant transitions when system setting enabled).
8. **Glass:** `Surface` with `containerColor = surface.copy(alpha = …)`, `BorderStroke` from `surfaceBorder`, optional `shadow` with low alpha — **no** `BlurredEdgeTreatment`, **no** `RenderEffect`, **no** Accompanist blur.

## Token Tables

### Brand Colors

| Token | Hex / value | iOS (`HuePalette`) | Android MVP usage |
| --- | --- | --- | --- |
| `amber` | `#FFC107` | `amber` | Primary accent, on-state, CTAs, tab active |
| `amberDeep` | `#FF9500` | `amberDeep` | Gradient end, pressed emphasis |
| `amberGlow` | `#FFC107` @ 18% | `amberGlow` | Icon halos, restrained card glow |
| `amberLight` | `#F5A623` | `amberLight` | **Estate reference only** |
| `amberLightDeep` | `#E8920D` | `amberLightDeep` | **Estate reference only** |
| `amberGlowLight` | `#F5A623` @ 15% | `amberGlowLight` | **Estate reference only** |

### Noir Semantic Colors

| Token | Hex / value | iOS (`HuePalette.Noir`) | Android MVP usage |
| --- | --- | --- | --- |
| `background` | `#141414` | `background` | `ColorScheme.background`, setup gradient base |
| `surface` | `#242424` | `surface` | Cards, sheets |
| `surfaceElevated` | `#2E2E2E` | `surfaceElevated` | Elevated panels, chooser cards |
| `surfaceBorder` | white @ 8% | `surfaceBorder` | Glass borders, dividers |
| `tabBar` | `#1C1C1C` | `tabBar` | **Deferred** (no tab bar in shell slices) |
| `textPrimary` | `#FFFFFF` | `textPrimary` | `onBackground` / `onSurface` |
| `textSecondary` | white @ 55% | `textSecondary` | Subtitles, hints |
| `textTertiary` | white @ 30% | `textTertiary` | Muted labels, empty state secondary |
| `toggleOn` | `#FFC107` | `toggleOn` | Switches, active controls |
| `toggleOff` | `#3A3A3A` | `toggleOff` | Off track |
| `sliderTrack` | white @ 12% | `sliderTrack` | Brightness track (future room card) |
| `tabActive` / `tabInactive` | amber / white @ 35% | tab tokens | **Deferred** |
| `ctaBackground` | `#FFC107` | `ctaBackground` | Primary buttons (e.g. demo CTA in 002B) |
| `ctaText` | `#000000` | `ctaText` | `onPrimary` for amber buttons |
| `destructive` | `#FF3B30` | `destructive` | Errors, stop actions |
| `success` | `#30D158` | `success` | Paired state, live indicators |
| `separator` | white @ 8% | `separator` | List/divider lines |

### Semantic Action Colors

| Role | Noir token | Notes |
| --- | --- | --- |
| Primary CTA | `ctaBackground` + `ctaText` | Amber fill, black label |
| Destructive | `destructive` | Pair with `onError` or custom `error` slot |
| Success | `success` | Paired bridge, confirmation |
| Secondary / ghost | `surface` + `surfaceBorder` | Outlined secondary buttons |

### Material 3 Role Mapping

| Material 3 role | ChromaGlow source | Notes |
| --- | --- | --- |
| `primary` | `amber` | Brand accent |
| `onPrimary` | `ctaText` (black) | Button labels on amber |
| `primaryContainer` | `amber` @ ~15% | Subtle chips, active step pills |
| `onPrimaryContainer` | `amber` | Text on container |
| `secondary` | `surfaceElevated` | Secondary surfaces |
| `onSecondary` | `textPrimary` | — |
| `background` | `Noir.background` | Screen root |
| `onBackground` | `textPrimary` | — |
| `surface` | `Noir.surface` | Cards, sheets |
| `onSurface` | `textPrimary` | — |
| `surfaceVariant` | `surfaceElevated` | Glass panels |
| `onSurfaceVariant` | `textSecondary` | — |
| `outline` | `surfaceBorder` | 1dp borders |
| `error` | `destructive` | Error phase |
| `onError` | white | Error content on destructive |

### Estate Future Light-Theme Reference

Documented for completeness only — **not enabled** in MVP or ANDROID-002B.

| Token | Hex / value | iOS (`HuePalette.Estate`) |
| --- | --- | --- |
| `background` | `#F2F2F7` | `background` |
| `surface` | `#FFFFFF` | `surface` |
| `surfaceElevated` | `#FFFFFF` | `surfaceElevated` |
| `surfaceBorder` | black @ 6% | `surfaceBorder` |
| `textPrimary` | `#1C1C1E` | `textPrimary` |
| `textSecondary` | black @ 50% | `textSecondary` |
| `textTertiary` | black @ 28% | `textTertiary` |
| `toggleOn` | `#F5A623` | `toggleOn` |
| `toggleOff` | `#D1D1D6` | `toggleOff` |
| `destructive` | `#FF3B30` | `destructive` |
| `success` | `#34C759` | `success` |

`HuePalette.Adaptive` pairs are **iOS-only** runtime resolution; Android MVP does not ship adaptive light/dark switching.

### Gradients

| Token | iOS definition | Android MVP implementation |
| --- | --- | --- |
| `hueAmberFill` | `#FFC107` → `#FF9500` horizontal | `Brush.horizontalGradient` for sliders/bars (future) |
| `hueAmberVertical` | `#FFC107` → `#FF7A00` vertical | Hero accents (future) |
| `hueRoomGlow` | Radial amber @ 20% (dark) | Room card on-state glow (future); use radial brush, no blur |
| **`setupBackgroundGradient`** | iOS uses deep blue-purple stops | **Approved:** Noir `#141414` base with subtle purple tint stops (e.g. `#0D0D1F` → `#141420` → `#141414`) — `Brush.linearGradient` topLeading→bottomTrailing |

iOS setup uses a blurred accent circle; Android MVP **must not** use blur — optional low-alpha radial **without** `RenderEffect`.

### Spacing

| Token | pt (iOS `HueSpacing`) | Android dp |
| --- | --- | --- |
| `xs` | 4 | 4.dp |
| `sm` | 8 | 8.dp |
| `md` | 12 | 12.dp |
| `lg` | 16 | 16.dp |
| `xl` | 20 | 20.dp |
| `xxl` | 24 | 24.dp |
| `section` | 32 | 32.dp |
| `cardPad` | 16 | 16.dp |
| `screenH` | 20 | 20.dp |
| `screenV` | 16 | 16.dp |

Dashboard iOS uses `horizontalInset = 20` — align with `screenH`.

### Shapes and Radii

| Token | pt (iOS `HueRadius`) | Android shape |
| --- | --- | --- |
| `sm` | 8 | `RoundedCornerShape(8.dp)` |
| `md` | 12 | 12.dp |
| `lg` | 16 | Cards |
| `xl` | 20 | Sheets, modals |
| `pill` | 999 | `CircleShape` / `RoundedCornerShape(50%)` |

Room cards on iOS use 18pt — map to `lg` + 2dp or dedicated `roomCard = 18.dp` in theme.

### Elevation and Glow

| Token | iOS (`HueShadows`) | Android MVP |
| --- | --- | --- |
| `card` | black @ 8%, r8, y2 | `Shadow` / `Modifier.shadow` — light use on dark |
| `elevated` | black @ 12%, r16, y4 | Elevated sheets |
| `modal` | black @ 16%, r32, y8 | Dialogs (future) |
| `amber` | amber @ 40%, r16, y4 | On-state CTA / room card glow |
| Glass glow | N/A (iOS uses material blur in places) | **Color-only** glow; **no blur** |

### Typography

| HueFont token | Size / weight | Material 3 slot (suggested) |
| --- | --- | --- |
| `displayLarge` | 34 Bold | `displayLarge` |
| `displayMedium` | 28 Bold | `displayMedium` |
| `displaySmall` | 22 Semibold | `displaySmall` |
| `numberHero` | 48 Bold Rounded | Custom `TextStyle` |
| `numberLarge` | 28 Bold Rounded | Custom |
| `numberMedium` | 20 Semibold Rounded | Custom |
| `headline` | 17 Semibold | `titleMedium` |
| `subheadline` | 15 Regular | `bodyMedium` |
| `body` | 15 Regular | `bodyLarge` |
| `bodyMedium` | 15 Medium | `bodyMedium` + Medium |
| `callout` | 13 Regular | `bodySmall` |
| `caption` | 12 Regular | `labelMedium` |
| `captionMedium` | 12 Medium | `labelMedium` + Medium |
| `micro` | 10 Medium | `labelSmall` |

**Section headers (iOS):** 12pt Semibold, uppercase, tracking 0.8, `textSecondary` — implement as `Text` style + `letterSpacing` in Compose.

### Motion and Reduce-Motion Policy

| Token | iOS (`HueAnimation`) | Android mapping |
| --- | --- | --- |
| `fast` | spring 0.25 / 0.75 | `spring(dampingRatio = 0.75f, stiffness = …)` ~250ms feel |
| `normal` | 0.35 / 0.80 | Default transitions |
| `slow` | 0.50 / 0.85 | Large layout changes |
| `toggle` | 0.30 / 0.70 | Switch/toggle |
| `card` | 0.40 / 0.78 | Room card on/off |
| `linear` | 0.15 linear | Quick fades |
| `adaptive` | nil when Reduce Motion | Centralize a reduced-motion policy; respect the applicable Android system accessibility / animation preference when implemented, and use instant transitions when motion reduction is requested. Exact Compose API selection is deferred to the implementation slice. |

### Accessibility

| Pattern | iOS (`HueAccessibility` / views) | Android MVP |
| --- | --- | --- |
| Room label | `"{name} {room\|zone}, {n} light(s)"` | `contentDescription` on room cards |
| Power toggle | "Turn {name} on/off" + hint | `semantics { role = Button }` |
| Slider | "{label}: {value}" | `stateDescription` on brightness (future) |
| Effect cards | Studio patterns | **Deferred** |
| Touch targets | ≥44pt effective | 48.dp minimum |
| Contrast | Light text on Noir | WCAG aim on primary/secondary text |
| Reduce motion | `HueAnimation.adaptive` | Skip animation specs when enabled |

### Deferred Haptics Inventory

| Interaction | iOS (`HapticManager`) | Android status |
| --- | --- | --- |
| Room power toggle | `light` | Deferred |
| Brightness drag start | `medium` | Deferred |
| All off | `heavy` | Deferred |
| Preset apply | light/medium | Deferred (presets deferred) |
| CTA taps | light | Deferred |

Use `HapticFeedback` / `LocalView` in a later **interaction-parity** slice — not ANDROID-002B.

## Setup Shell Parity Map

iOS: `BridgeSetupView` + `BridgeDiscoveryViewModel` phases. Android: placeholder today; full phases in post-002B setup slice.

| State | iOS production anchor | Android Material 3 target | ANDROID-002B |
| --- | --- | --- | --- |
| **idle** | Title, Wi-Fi hint, primary "Scan for Bridge", secondary "Enter IP Manually", optional demo | `setupBackgroundGradient`, `displayMedium` title, `textSecondary` body, amber primary + outlined secondary | Theme placeholder only |
| **scanning** | "Searching…", `scanningLabel`, discovery step rows, optional bridge chooser, manual IP | `LinearProgressIndicator` or stepped list in `surfaceElevated` glass panel | Not implemented |
| **bridge chooser** | List of `discoveredBridgeChoices`, select → `bridgeFound` | `LazyColumn` of glass rows, monospaced host:port | Not implemented |
| **bridge found** | "Bridge Found!", bridge pill, link-button card, Pair / Scan Again | Amber accent icon, instruction card with border | Not implemented |
| **pairing** | "Connecting…", spinner on icon | `CircularProgressIndicator` + `textSecondary` | Not implemented |
| **paired** | "You're all set!", IP pill, navigate CTA | `success` tint pill, amber primary CTA | Not implemented |
| **error** | "Something went wrong", message, retry/manual | `error` color, secondary actions | Not implemented |
| **manual IP sheet** | Sheet "Enter Bridge IP", decimal pad, Connect | `ModalBottomSheet` + `OutlinedTextField` | Not implemented |
| **demo entry** | Demo button on idle when `onDemo` provided | **Amber** demo CTA on `SetupPlaceholderScreen` | **Yes** — styling only |

## Dashboard Shell Parity Map

iOS: `DashboardView` inside `MainTabView` Home tab. Android: demo dashboard placeholder; full grid in later slices.

| State / region | iOS production anchor | Android Material 3 target | ANDROID-002B |
| --- | --- | --- | --- |
| **ambient background** | `DashboardAmbientBackground(hour:)` on ScrollView background | Time-of-day gradient token (future); Noir base for 002B | Themed root background on placeholder |
| **title** | Navigation title / large greeting via `summaryHeader` | `TopAppBar` or in-content `displaySmall` (future) | Placeholder headline styles only |
| **summary** | `timeGreeting` + "N of M on" + status dot | `headline` + `caption` + amber dot | Not implemented |
| **shimmer** | `ShimmerCard` ×4 while `isLoading` && empty | `placeholder` shimmer modifiers | Not implemented |
| **empty state** | Icon + "No rooms found" + pull-to-refresh hint | Centered column, `textTertiary` | Not implemented |
| **top error feedback** | `HueToastView` overlay on orchestrator message | `Snackbar` / custom top banner | Not implemented |
| **room grid** | `LazyVGrid`, `RoomCard`, min width 170 | `LazyVerticalGrid` + card composable | **Not in 002B** |
| **zones section** | Collapsible "Zones" + badge + grid | `zonesExpanded` equivalent later | Deferred |
| **toolbar loading** | Trailing `ProgressView` when loading | `TopAppBar` actions slot | Not implemented |
| **all off** | Power toolbar when any room on | Icon button + progress | Not implemented |
| **room-detail navigation** | `NavigationLink(value: room)` | Click row → detail route (future); shell has no stack | Not implemented |

**Deferred dashboard features (no stubs in 002B):** presets bar, now-playing bar, automations banners, favorite scenes, wide-card toggle, Studio/More tabs.

## Room-Card Interaction Contract

Canonical iOS: `RoomCard` + `BrightnessRow` in `DashboardView.swift`. Android composable(s) must honor the same **semantics** when built (post-002B).

| Rule | Requirement |
| --- | --- |
| Optimistic on/off | Local state flips immediately on power tap; callback requests desired state |
| Bridge-truth resync | When bridge/SSE/model confirms `isOn`, resync local state if different (rollback support) |
| Glow derivation | Derive card glow from dominant xy or mirek; amber fallback |
| Off-state dimming | Reduced opacity (~0.72) and slight scale down when off |
| Power vs navigation | Power control is separate hit target; card body navigates to detail |
| Optional overflow | Ellipsis action only when callback provided |
| Brightness visibility | Slider row visible **only while on** |
| Brightness commit | Call upstream **once** at drag end — **no** ViewModel/orchestrator writes during drag |
| External brightness resync | Update local slider from bridge only when **not** dragging |
| Accessibility | Room label, power toggle label/hint, slider value announcements |

Android state layer must **not** mirror `UnifiedOrchestrator`; use split feature/state modules per [`android-mvp-contract-freeze.md`](android-mvp-contract-freeze.md).

## Loading, Empty, Error, Dialog, Toast, and Snackbar Patterns

| Pattern | iOS anchor | Android MVP |
| --- | --- | --- |
| Loading (rooms) | Shimmer cards | Pulsing placeholder surfaces using Compose animation primitives; do not add a shimmer dependency for the MVP shell. Exact implementation is deferred. |
| Empty | Centered icon + copy | `EmptyState` composable |
| Error (setup) | Inline phase message | Text + retry in content |
| Error (dashboard) | Toast overlay top | `Snackbar` / top `Surface` banner |
| Dialog | `confirmationDialog` for effects | `AlertDialog` (when effects exist) |
| Sheet | Manual IP | `ModalBottomSheet` |
| Pull-to-refresh | `.refreshable` | Pull-to-refresh callback slot; select the applicable Material 3 Compose API during the dashboard implementation slice based on the pinned Compose version. |

Glass styling for banners: alpha surface + border — no blur.

## Navigation Pattern Map

| Concern | iOS | Android MVP shell |
| --- | --- | --- |
| Post-pairing main shell | `MainTabView` — 4 tabs | **Deferred** |
| First-run gate | Setup → paired → tabs | `ChromaGlowDestination` Setup → Dashboard (demo) |
| In-feature navigation | `NavigationStack` per tab | Future: typed routes or nested state — **not** Navigation Compose in 002B |
| Room detail | Push from `RoomCard` | Future slice |
| Dependency | SwiftUI native | **No** `androidx.navigation:navigation-compose` artifact in shell slices |

`ChromaGlowApp` remains:

```text
remember destination → when (Setup | Dashboard) → placeholder screens
```

## Reusable Component-State Inventory

| Component | States / inputs | Notes |
| --- | --- | --- |
| `ChromaGlowPrimaryButton` | default, pressed, disabled | Amber fill, black text |
| `ChromaGlowSecondaryButton` | outlined ghost | `surfaceBorder` |
| `GlassPanel` | elevated, bordered | No blur |
| `SetupPhaseContent` | idle…error | Future |
| `DiscoveryStepRow` | active, muted | Future |
| `BridgeChoiceRow` | default | Future |
| `RoomCard` | on/off, dragging brightness | See contract |
| `BrightnessSlider` | dragging, idle | Local state only while dragging |
| `DashboardEmptyState` | — | Future |
| `ShimmerRoomCard` | — | Future |
| `HueToast` / snackbar | message, visible | Future |

Extract to `core.ui` only when **two** feature call sites exist.

## Traceability to Android MVP Acceptance Matrix

| Matrix ID | Shell / UI relevance |
| --- | --- |
| ANDROID-MVP-001 | Demo entry styling on setup placeholder |
| ANDROID-MVP-004 | Manual IP sheet (setup map) |
| ANDROID-MVP-005–006 | Pairing phases (setup map) |
| ANDROID-MVP-008 | Shimmer vs empty (dashboard map) |
| ANDROID-MVP-009 | Room grid + zones (dashboard map) |
| ANDROID-MVP-011–012 | Room-card optimistic contract |
| ANDROID-MVP-013 | Brightness commit contract |
| ANDROID-MVP-020–022 | Toast/resync behaviors |

Full matrix: [`android-mvp-contract-freeze.md` § Android MVP Acceptance Matrix](android-mvp-contract-freeze.md).

## ANDROID-002B Implementation Boundary

ANDROID-002B is a **narrow theme + placeholder styling** slice only:

```text
Replace template Material colors with documented ChromaGlow dark Material 3 tokens.
Disable dynamic color by default.
Expand typography mapping.
Apply the themed background and amber demo CTA to the two existing placeholders only.
No new destinations.
No fake rooms.
No dashboard grid.
No setup phase state.
No shared core.ui extraction unless duplication proves necessary during implementation.
```

Files expected to change in 002B (not in 002A): `Color.kt`, `Theme.kt`, `Type.kt`, `SetupPlaceholderScreen.kt`, `DashboardPlaceholderScreen.kt` — subject to implementation task guardrails.

## Explicit Non-Goals

- Kotlin/Gradle/Manifest changes in ANDROID-002A
- Navigation Compose dependency
- Blur, `RenderEffect`, or new graphics dependencies
- Light theme enablement or Estate adaptive scheme
- Setup phase machine, discovery, pairing, networking, Keystore, DataStore, Room
- Dashboard room grid, fake data, or `UnifiedOrchestrator`-shaped Android god object
- Placeholder stubs for presets, now-playing, automations, Studio, More, favorite scenes, wide-card toggle
- Haptics implementation
- `core.ui` module extraction (unless duplication forced during 002B)
- Commits, pushes, iOS edits, or `.cursorrules` changes in this slice

## Non-Blocking iOS Follow-Ups

Do **not** reopen in Android shell work; track separately:

| ID | Summary |
| --- | --- |
| **IOS-BUG-001C** | Clarify selected-bridge pairing retry feedback when user must press link button on a different bridge than UI implies |
| **IOS-BUG-002A** | Inventory Philips cloud-discovery fallback (`GET https://discovery.meethue.com/api/nupnp` → 404 observed) |

See [`docs/ios/final-readiness-validation.md`](../ios/final-readiness-validation.md) and [`DEVLOG.md`](../../DEVLOG.md) for context. These do not block ANDROID-002B.
