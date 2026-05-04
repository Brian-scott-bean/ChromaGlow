# ChromaForge (HueHome Pro) — Dev Notes

## Branding
- **App name:** ChromaForge (rebranded from LightShade / HueHome Pro)
- **Bundle ID:** `com.lightshade.app` (keep as-is, never user visible)
- **App Store Connect:** https://appstoreconnect.apple.com/apps/6765770802
- **Developer:** Brian Bean (`brian.scott.bean@gmail.com`)
- **Team:** Brian Bean (paid Apple Developer Program)

## Project Location
- **Path:** `/Users/brianbean/Desktop/huehome-pro-v0.3.0/`
- **Xcode project:** `HueHome.xcodeproj`
- **Git tags:** v0.1.0 → v0.13.0-sync-mode-phase1a

## v0.13.0 — Sync Mode Phase 1A (Priority 2)
- **Architecture:** Introduced `SyncEngine` protocol for pluggable reactive engines. One shared `AVAudioEngine` tap dispatches audio buffers to the active engine. New files in `HueHome/UI/Sync/`:
  - `SyncEngineProtocol.swift` — protocol, output struct, engine type enum, color modes
  - `VisualizerEngine.swift` — 1:1 port of FFT pipeline from MicModeEngine
  - `SyncModeEngine.swift` — shared audio session, engine dispatch, rate-limited light sender
  - `SyncModeView.swift` — premium glassmorphic UI with engine selector, controls card, visualizer
- **Tab Rename:** `.mic` → `.sync`, icon `waveform.and.mic` → `waveform`, label "Mic" → "Sync"
- **UI Overhaul:** SyncModeView matches CastChroma design language — `.ultraThinMaterial` cards, amber accents, time-aware ambient orb, gradient borders, `LinearGradient` start/stop button. New master intensity slider.
- **Deleted:** `MicModeEngine.swift`, `MicModeView.swift` — fully replaced by Sync/ directory.
- **Color modes** (Reactive, Pulse, Warm, Cool) preserved as sub-options within VisualizerEngine.


## v0.12.1 — Room Detail Polish (Priority 1)
- **Scene Edit Mode:** Per-section Select/Done on SCENES strip. Multi-select with animated checkmark overlays, dimmed unselected chips. New `SceneEditBar` floating toolbar: All/None toggle, Edit (single-select → opens SceneColorBuilder in edit mode), Delete (batch with confirmation alert). Full optimistic update + rollback.
- **Favorite Scenes:** Long-press any scene chip → Favorite/Unfavorite context menu. Favorited scenes show a ⭐ badge overlay. Favorites appear as capsule pills in the Dashboard presets bar (after built-in presets, separated by divider). Each pill shows scene icon, name, room label, and star badge. Tap → activates via `activateGlobalScene`. Long-press → Unfavorite. Order preserved from `@AppStorage("favoriteSceneIDs")`.
- **Edit Scene:** Context menu "Edit Scene" activates the scene to seed light colors, then opens `SceneColorBuilderView` in edit mode (passes `existingSceneID`). Save → updates scene on Bridge.
- **Bug Fix:** `SceneDisplayItem.hash(into:)` now includes `name` (was missing — same class of bug as the v0.12.0 ForEach blindness). `==` compares `id + isActive + name`; hash must match.
- **New File:** `SceneEditBar.swift` — added to `project.pbxproj` via `sed`.

## Target Structure
| Target | Bundle ID | Notes |
|---|---|---|
| HueHome | com.lightshade.app | Main iOS app |
| HueHomeWidgetExtension | com.lightshade.app.widget | Home screen widget |
| LightShadeWatchApp Watch App | com.lightshade.app.watchkitapp | watchOS app |
| LightShadeWatchExtension | com.lightshade.app.watchkitapp.watch | Watch complication (NOT embedded in iOS app — see known issues) |
| HueHomeTests | com.lightshade.app.tests | Unit tests |

## Key File Locations
- **Main app:** `HueHome/`
- **Mic Mode:** `HueHome/UI/Effects/MicModeEngine.swift` + `MicModeView.swift`
- **Bridge Discovery:** `HueHome/Core/ViewModels/BridgeDiscoveryViewModel.swift`
- **Bridge Setup UI:** `HueHome/UI/BridgeSetup/BridgeSetupView.swift`
- **Main Tab Nav:** `HueHome/UI/Navigation/MainTabView.swift`
- **Unified Orchestrator:** `HueHome/Core/Network/UnifiedOrchestrator.swift`
- **Hue API Client:** `HueHome/Core/Network/HueAPIClient.swift`
- **Watch App:** `LightShadeWatchApp Watch App/`
- **Watch Complication:** `LightShadeWatch/`
- **Widget:** `HueHomeWidget/`

## App Icon
- **iPhone:** `HueHome/Assets.xcassets/AppIcon.appiconset/icon_1024.png`
- **Watch:** `LightShadeWatchApp Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- Both set to the stained-glass ChromaForge anvil/hammer icon

## Architecture
- **Hue API:** V2 REST + SSE (Server-Sent Events) for real-time state
- **Orchestrator:** `UnifiedOrchestrator` — central state manager, owns all bridges, rooms, lights
- **Bridge auth:** CLIP v2 API, credentials stored in Keychain via `KeychainManager`
- **Widget data:** Shared via App Group `group.com.lightshade.app`

## Bridge Discovery (3-layer)
1. **mDNS** — `BridgeDiscoveryService` scans local network, 12s timeout
2. **NUPnP cloud fallback** — `https://discovery.meethue.com` if mDNS finds nothing
3. **Manual IP** — user-entered IP override via `BridgeSetupView`
- **Critical bug fixed:** Guard clause in `BridgeDiscoveryViewModel.startScan()` was blocking re-scan after any prior failure

## Mic Mode (`HueHome/UI/Effects/`)
- **Engine:** `MicModeEngine` — AVAudioEngine → vDSP FFT → 20 frequency bars
- **Rate limiting:** 100ms (10fps, Hue bridge spec limit)
- **Light control:** `setGroupedLightEffect(id:on:brightness:xy:mirek:duration:)` — note parameter ORDER
- **Color modes:** Reactive (bass/high ratio → mirek), Pulse, Warm, Cool
- **Permission:** NSMicrophoneUsageDescription in Info.plist

## HueAPIClient — setGroupedLightEffect signature
```swift
func setGroupedLightEffect(
    id:         String,
    on:         Bool?,
    brightness: Double?,
    xy:         (Double, Double)?,
    mirek:      Int?,
    duration:   Int        // ← duration is LAST
) async throws
```

## Xcode File Sync Gotcha
- Xcode's "Add Files to HueHome" with "Copy files to destination" creates DUPLICATE files at the project root
- Always use "Create groups" action, or manually verify no root-level duplicates are created
- MicMode files MUST be in `HueHome/UI/Effects/` and referenced correctly in pbxproj

## TestFlight — Resolved Upload Errors
| Error Code | Description | Fix Applied |
|---|---|---|
| 90474 | Missing iPad orientation (PortraitUpsideDown) | Added to Info.plist |
| 90685 | CFBundleIdentifier collision | Removed rogue CopyFiles phase |
| 90347 | Bad bundle ID for watch extension in iOS PlugIns | Removed "Embed Watch Extension" phase from HueHome target |
| 90508 | Invalid DTPlatformName in watch extension | Fixed by removing from iOS app embed |
| 90092 | armv7 required | Side effect of above, cleared |

### Watch Extension Embedding (IMPORTANT)
- `LightShadeWatchExtension.appex` was being embedded in iOS `HueHome` app via "Embed Watch Extension" build phase → wrong
- Correct location: inside `LightShadeWatchApp Watch App.app/PlugIns/` (embedded in the watch app, not iOS app)
- **Current state:** Extension has `SKIP_INSTALL = YES` and is NOT embedded in iOS app — complications are not shipping in v0.9.0
- **TODO:** Properly embed `LightShadeWatchExtension` inside the `LightShadeWatchApp Watch App` target's embed phases

## TestFlight Status (v0.9.0 Build 1)
- **Uploaded:** 2026-05-01 at 4:31PM
- **Export Compliance:** None of the algorithms mentioned above (app uses Apple OS HTTPS/TLS only)
- **Internal Testing group:** "Internal Testers"
- **Testers:** brian.scott.bean@gmail.com, beanalicious@gmail.com (Dan Bean, Admin)
- **Tag:** `v0.9.1-testflight`

## Roadmap (as of v0.9.1)
1. ✅ Bridge discovery (mDNS + NUPnP + manual)
2. ✅ Mic Mode (FFT sound-reactive lighting)
3. ✅ ChromaForge rebrand
4. ✅ TestFlight upload
5. 🔲 Fix watch complication embedding (embed in watch app, not iOS app)
6. 🔲 Spotify integration (need Client ID/Secret from developer.spotify.com)
7. 🔲 Customizable navigation bar (settings-driven tab pinning/reordering)
8. 🔲 watchOS Smart Stack widget (interactive, not display-only)
9. 🔲 App Store public release

## Rebrand Reference
All user-visible "LightShade" replaced with "ChromaForge" via sed across:
- Info.plist (CFBundleDisplayName, NSLocalNetworkUsageDescription, NSMicrophoneUsageDescription)
- All Swift UI strings
- Widget configurationDisplayName
- Watch ContentView "Open ChromaForge on your iPhone to sync rooms"
- Bundle IDs intentionally NOT changed (com.lightshade.* stays)

---

## Session Log: 2026-05-03 — Tier 1 UX/UI Overhaul (CastChroma Rebrand Continuation)

### Goals
- Unify card design across Home, Scenes, Effects pages
- Fix nav bar black bar on home page
- Remove redundant color palette icon from light cards

### Changes Made

**Nav Bar (all 9 views):**
- Changed `.toolbarBackground(.ultraThinMaterial)` → `.toolbarBackground(.hidden)` across all UI views
- Files: DashboardView, ScenesTabView, RoomDetailView, EffectsView, SettingsView, AutomationsView, LightControlView, DevicesView, CreateSceneView

**Card Design System:**
- `GlassmorphicCard` default cornerRadius: 24 → 20
- `SceneMoodCard` completely rewritten to match `EffectCard` exactly:
  - Dark `Color.white.opacity(0.06)` fill (replaces solid colored gradient)
  - 44pt colored circle icon top-left
  - Name (15pt bold) + room name subtitle (11pt dimmed)
  - Active state: accent color tint + colored border + glow shadow
- `RoomCard` rewritten to match `EffectCard`:
  - Same dark fill + border treatment
  - Same 44pt circle icon with archetype symbol
  - Power button kept as overlay (NavigationLink tap target)
  - Brightness slider preserved for active rooms

**Home Page Layout:**
- Changed from 1-column (full-width) to 2-column grid — matches Effects and Scenes
- Zones section also updated to 2-column

**Ambient Background Fix (black bar at top):**
- Root cause: orb1 center was at y=246 from top; nav bar area is y=0–150
- Fix: moved orb1 from offset `(-80, -180)` → `(-60, -320)` so center lands at y≈106 (in the nav bar area)
- Enlarged orb1 frame: 360px → 480px for broader coverage
- Removed `.drawingGroup()` which could prevent proper safe area rendering
- Increased night orb opacity: 0.22 → 0.32, more vivid indigo

**Redundant Palette Icon:**
- Removed `paintpalette.fill` and `thermometer.medium` from `LightCard` header in RoomDetailView

**Time-Aware Suggestion Banner (Tier 2 Item 4):**
- Added `TimeSuggestion` struct and `timeSuggestion` computed property to `DashboardView`
- Shows contextual prompt + one-tap preset button based on current hour
- Only visible when all lights are off (avoids interrupting active scenes)
- Banner disappears automatically when tapped (lights turn on → condition no longer met)
- Time mapping:
  - 5–9am: "Rise and shine ☀️" → Energize
  - 9am–12pm: "Time to focus 🎯" → Energize
  - 12–2pm: "Afternoon reading? 📖" → Read
  - 2–5pm: "Afternoon boost ⚡" → Energize
  - 5–8pm: "Time to wind down 🌙" → Relax
  - 8–11pm: "Ready for sleep? 😴" → Sleep
  - 11pm–5am: "Still up late? 🌃" → Sleep

### Git Tags This Session
- `v0.9.3-tier1-complete` — All Tier 1 visual cohesion items complete

### Known Issues / Future Tweaks
- Brightness slider has slight lag (sensitivity: 2.0 + minimumDistance: 4). Tighten when ready.
- 2-column grid brightness slider is narrower — may need layout adjustment for very long room names

---

## Session Log: 2026-05-03 — UX Stability & CRUD Completeness (v0.9.4)

### Context
Focused bug-fix + CRUD completeness sprint. No new features beyond the automation
banner dropdown. All changes targeted UX polish and functional correctness.

### Bug Fixes

**Tap Areas:**
- `CreateAutomationView` option cards (preset + effect pickers): added
  `.contentShape(RoundedRectangle(cornerRadius: 12))` — was only tappable on text
- `SettingsView` all tappable rows (Automations, Devices, Manage Bridges, Forget All,
  both Demo Mode buttons): added `.contentShape(Rectangle())` to every label HStack
- My Schedules automation rows: added `.contentShape(Rectangle())` so full card area
  triggers context menu (was only firing on Toggle control)

**Automation Execution:**
- `AutomationHandler.handle(userInfo:)` was ignoring `actionType` key and returning
  immediately when `presetID` was empty (always true for `.effect` type automations)
- Fix: reads `actionType` first, routes to preset or effect path
- `AppRootView.onReceive(.automationShouldExecute)` updated to dispatch both types
- `UnifiedOrchestrator.applyAutomationEffect(id:)` added — applies bridge-native effect
  per-light across all rooms; falls back to brightness for non-native effects
- `UserDefaults` cold-start buffer extended to cover `pendingAutomationEffectID`
- Foreground automations now execute silently (banner suppressed via `completionHandler([])`)
- Notification body updated: "Tap to apply X" → "X is now active — tap to open the app"

**Automation Banner Countdown:**
- `NextAutomationBanner.timeLabel` used `Date()` at render time; parent clockTimer
  fired every 60s so countdown was effectively frozen between refreshes
- Fix: `@State var now: Date` + `Timer.publish(every: 1)` inside banner struct

**Scene UUID Names:**
- Third-party Hue scenes store internal UUID as metadata.name
- Fix: `String.isHueUUID` (regex: 8-4-4-4-12 hex) + `.sanitizedSceneName` extension
- Applied in `UnifiedOrchestrator` at scene build time
- `ScenesTabView` room chip "Unknown" → "Other" for orphan scenes

**Build Fix:**
- `SceneDisplayItem.name` was `let` — caused compile error in `renameScene()`
  (copy-mutate-assign pattern requires `var`). Changed to `var`.

**Swipe Conflict:**
- Leading swipe-right on automation rows conflicted with NavigationStack back gesture
- Replaced both swipe actions with `.contextMenu { Edit, Delete }` matching rest of app

### Features Added

**Automation Banner Dropdown:**
- `allUpcomingAutomations` computed property in `DashboardView` — all enabled automations
  sorted by next fire date
- `NextAutomationBanner` gains `moreCount: Int` — shows amber `+N` badge + chevron when
  multiple automations scheduled
- Tap banner → `UpcomingAutomationsSheet` (sorted list with live relative countdown)

**CRUD Completeness:**
- My Schedules: long-press row → Edit (opens `CreateAutomationView(editing:)`) / Delete
- Room-level Scene chips: long-press → Rename (alert with pre-filled name) / Delete
  - `RoomDetailViewModel.renameScene(_:to:)` added (optimistic + API + rollback)
- Bridge Automation rows: long-press → Enable / Disable context menu

### Interaction Pattern Standardised
All editable entities now use long-press → `.contextMenu` throughout the app:
- My Schedules: Edit + Delete
- Bridge Automations: Enable/Disable
- Global Scenes: Rename + Speed + Delete
- Room Scenes: Rename + Delete
- Effect Presets: Rename + Delete
- Bridges: Rename + Delete

### Architecture Notes
- `AutomationScheduler` already encoded `actionType` in `userInfo` — handler was just
  ignoring it. Full pipeline was wired end-to-end for both preset and effect types.
- Background auto-execution (no user tap required) requires `BGTaskScheduler` — added
  to roadmap below.

### Git Tags This Session
- `v0.9.4-ux-crud` — UX stability + full CRUD completeness

---

## Tier 2–4 Roadmap (updated 2026-05-03 v0.9.4)

### Tier 2 — Smart Intelligence
- ✅ Time-aware home page suggestion banner
- ✅ Next automation banner with countdown + dropdown for multiple schedules
- 🔲 BGTaskScheduler background auto-execution (fire automation without user tapping notification)
- 🔲 Bell/alerts icon — notification history log

### Tier 3 — Architecture
- 🔲 Move Bridges to Settings sub-menu (remove as top-level tab)
- 🔲 Favorite scenes per room → pins to home page presets bar
- 🔲 Clarify "Automations" naming: My Schedules (app-side) vs Bridge Routines (hardware)
- 🔲 Bridge Automation CRUD — Edit + Delete via long-press (currently Toggle-only)

### Tier 4 — Customization
- 🔲 Customizable bottom tab bar (long-press to edit, 4-icon layout)
- 🔲 Effect preset parameter depth — richer per-effect controls (speed, colors, patterns, palettes)
  so saved presets feel meaningfully different from the base library effect
- 🔲 Hex code color input in Scene Builder — type a hex value (e.g. #FF6B35) and Harmony engine
  auto-generates complementary/analogous/triadic palette across remaining lights
- 🔲 Copy/paste color between light cards in Scene Builder:
  - Long-press a **selected** light card → "Copy Color" context menu
  - Toast: "Color copied from [Light Name]"
  - Tap any other light card → auto-pastes the copied color + brightness
  - Paste highlight: target cards show subtle pulsing border while clipboard is active
  - Clear clipboard on scene save or dismiss
- 🔲 Responsive layout audit — ensure all views render correctly across all iPhone sizes (SE → Pro Max)

### Performance / Responsiveness
- ✅ SSE instant state updates — ForEach hash fix (v0.12.0)
- ✅ RoomCard/LightCard/CompactLightCard live color + on/off updates (v0.12.0)
- ✅ Optimistic UI for room toggle + brightness (v0.12.0)
- 🔲 Tighten brightness slider sensitivity (reduce lag on drag)
- 🔲 Mic Mode latency (audio buffer/FFT tuning)

---

## Session Log — 2026-05-03 (night) — Live State Sync Overhaul (v0.12.0)

### Problem
All light, room, and zone cards in RoomDetailView (the "submenu" when tapping into a room/zone) failed to update in real-time when state changed — scene activation, on/off toggle, brightness, and color changes were invisible until navigating away and back.

The home page (DashboardView) updated correctly.

### Root Cause Analysis

**1. Hashable / Equatable Mismatch (PRIMARY CAUSE)**
- `LightDisplayItem`, `RoomDisplayItem`, `SceneDisplayItem`, `GlobalSceneItem` all had `hash(into:)` that only used `id`
- `==` compared all fields (synthesized or custom memberwise)
- SwiftUI's `ForEach` uses the **collection hash** as a fast-path to decide whether to re-diff. With ID-only hashing, `[LightDisplayItem].hashValue` was identical before and after color/brightness changes → ForEach skipped re-evaluation entirely
- **Fix:** hash now includes all volatile fields: `isOn`, `brightness`, `colorX`, `colorY`, `colorTempMirek`, `isActive`

**2. @State localGlowColor + onChange pipeline failure**
- `CompactLightCard` and `LightCard` stored glow color as `@State localGlowColor`, initialized once at view creation
- Color updates relied on `onChange(of: light.colorX)` etc. to sync — but with the hash bug above, these never fired
- Also: `LightCard` was missing `onChange(of: light.colorY)` entirely
- **Fix:** Removed `@State localGlowColor` from both card types. Replaced with computed `var glowColor: Color { resolveGlowColor(for: light) }` — always reads current value, no sync needed

**3. Room toggle didn't update light cards**
- `toggleRoom(on:)` set `roomIsOn = on` but never updated the `lights` array
- The demo mode path had `lights = lights.map { l.isOn = on }` but the real path skipped it
- Same bug in `setRoomBrightness()`
- **Fix:** Moved optimistic `lights` update before the demo-mode check so it runs for all paths. Added rollback on API failure.

**4. Room brightness header hardcoded amber**
- `roomBrightnessHeader` used `Color(red: 1.0, green: 0.76, blue: 0.20)` everywhere
- **Fix:** Computes `dominantGlow` from the brightest ON light using `resolveGlowColor()`

**5. Scene activation didn't sync roomIsOn/roomBrightness**
- `activateScene()` → `refreshLightColors()` updated `lights` but never set `roomIsOn` or `roomBrightness`
- After turning lights off then activating a scene, brightness header stayed "off"
- **Fix:** After `refreshLightColors()`, derive `roomIsOn` from `lights.contains { $0.isOn }` and `roomBrightness` from average brightness of on-lights

**6. Zone state not propagated**
- `updateRoom()` in `UnifiedOrchestrator` only updated `allRooms` and `roomsByBridge`
- Zones are also `RoomDisplayItem` stored in `allZones` / `zonesByBridge` — completely ignored
- **Fix:** Mirror mutations to zone arrays in `updateRoom()`

### Key Technical Insight
The home page worked because `@Environment(UnifiedOrchestrator.self)` creates direct observation tracking. When `allRooms` is accessed in `body`, `@Observable` registers the access. When `allRooms` is reassigned, SwiftUI knows to re-render.

The detail view's `@State var vm: RoomDetailViewModel` (also `@Observable`) should work the same way — and it does, BUT only if ForEach actually re-diffs the collection. The ID-only hash was the bottleneck: ForEach saw the same hash and short-circuited.

### Design Principle Established
**All `Hashable` display item models must hash ALL fields that `==` compares.** SwiftUI's ForEach relies on collection hashing to optimize diffing. ID-only hashing makes ForEach blind to property changes.

### Commits (chronological)
| Hash | Summary |
|------|---------|
| 126f7bc | Equatable fix — synthesized memberwise == |
| 5a6529d | Off-state opacity 0.72 → 0.55 |
| 73cd522 | Room/zone cards sync on/off, brightness, color |
| 705815e | Zone cards reflect toggle/brightness |
| cde361c | Unified onChange(of: light/room) |
| 64b98ed | Remove @State localGlowColor → computed |
| 06e5df5 | Hash ALL volatile fields + room header live color |
| ee75332 | Room toggle updates all light cards |
| c9fda9c | Brightness header syncs after scene activation |

### Git Tag
- `v0.12.0-live-state-sync`

### Remaining Known Issues
- Mic Mode latency (audio buffer/FFT tuning) — deferred
- Bridge pairing UX: needs "Press button now" instructional text during 30s polling
- Brightness slider drag sensitivity could be tighter


### My Schedules Long-Press (Edit / Delete) — Multi-attempt fix

**Attempt 1:** `.contextMenu` on HStack + Toggle inside → UISwitch internal
gesture recognisers blocked UIContextMenuInteraction long-press. Added
`.contentShape(Rectangle())` — only fired on Toggle area.

**Attempt 2:** Moved Toggle to `.overlay` outside contextMenu container →
contextMenu still failed; UIContextMenuInteraction couldn't register even
with the overlay separation.

**Attempt 3:** Switched to `onLongPressGesture` + `confirmationDialog` →
still failed. ScrollView pan recogniser was cancelling the long-press
gesture before the 0.5s threshold completed.

**Final fix (working):**
- `simultaneousGesture(LongPressGesture(minimumDuration: 0.5))` — runs
  in parallel with ScrollView pan recogniser, both can complete
- Toggle stays in `.overlay` above gesture layer — handles short taps
  independently without interfering
- `confirmationDialog` on `AutomationsView` body presents Edit + Delete

**Root cause summary:** Three separate layered problems —
1. UISwitch blocks UIContextMenuInteraction
2. `onLongPressGesture` is cancelled by ScrollView pan
3. `contentShape` alone doesn't help when gesture recogniser loses

### Settings Rotation → Kick to Home

**Cause:** `.sheet(isPresented: $showSettings)` can be dismissed by SwiftUI
when the presenting view's geometry changes on device rotation.

**Fix:** Changed to `.fullScreenCover(isPresented: $showSettings)`.
`fullScreenCover` owns the entire window frame and is immune to
geometry-induced dismissal.

**Also reverted:** An earlier erroneous portrait-only orientation lock
(`AppDelegate.supportedInterfaceOrientationsFor` returning `.portrait`)
which blocked rotation entirely.

### Bridge Automation Rows

- Removed whole-card `.onTapGesture { onToggle() }` — was swallowing all
  touches, preventing any gesture recognition. Toggle-only interaction.
- Removed redundant Enable/Disable `.contextMenu` — tap already handles it.
- Long-press CRUD deferred to roadmap (requires bridge API work).

### Interaction Pattern (corrected from v0.9.4 notes)
- My Schedules: long-press → `confirmationDialog` (Edit / Delete) ✅
- Bridge Automations: Toggle switch only; long-press CRUD on roadmap
- Global Scenes, Room Scenes, Effect Presets, Bridges: long-press → `.contextMenu`

### Git Tags This Session
- `v0.9.5-gesture-stability` — gesture fixes + Settings rotation stability

---

## Session Log: 2026-05-03 (afternoon) — UI Polish & Roadmap Expansion (v0.9.6)

### Settings Done Button
`fullScreenCover` does not support swipe-to-dismiss (sheet-only behavior).
Added amber **Done** button to SettingsView trailing nav bar calling `dismiss()`.
Also updated stale comment that referenced `.sheet` presentation.

### BulkActionBar — Root Cause & Fix (multi-attempt)

**What BulkActionBar does:** Long-press any light in RoomDetailView to
enter multi-select mode. Bar slides up from bottom showing:
- Row 1: "X lights selected" + All/None toggle
- Row 2: On · Off · Brightness (compact sheet) · Create Scene

**Attempt 1:** `.safeAreaInset(edge: .bottom)` on ScrollView inside
lightScrollView — removed from ScrollView, tried as ZStack overlay.
Build broke: dropped ScrollView closing brace, causing all `private var`s
to be parsed as non-local scope (7 compile errors). Fixed brace structure.

**Attempt 2:** `.safeAreaInset(edge: .bottom, 64pt)` on NavigationStack
in MainTabView. Calculated tab bar height: icon(32) + padding.vertical
(12×2) + padding.bottom(8) = 64pt. Appeared correct in theory.

**Root cause (final):** `RoomDetailAmbientBackground` uses `.ignoresSafeArea()`
which forces the ZStack to expand to FULL SCREEN HEIGHT including behind
home indicator. `Spacer()` in `VStack { Spacer(); BulkActionBar }` inside
that ZStack pushes to the raw screen bottom — NOT the safe area bottom.
So any safeAreaInset on parent NavigationStack is irrelevant for ZStack
overlay children.

**Fix:**
- `MainTabView.iPhoneLayout`: `.safeAreaInset(edge: .bottom, 64pt)` on
  each tab NavigationStack — correctly adjusts ScrollView content insets
  so light cards never hide behind the tab bar.
- `RoomDetailView` BulkActionBar: `.padding(.bottom, 100)` — explicit
  value clearing home indicator (~34pt) + tab bar bottom pad (8pt) +
  capsule height (56pt) = 98pt + 2pt breathing room.

**Key lesson:** ZStack children of a view that uses `.ignoresSafeArea()`
inherit the expanded frame and cannot rely on parent safe area insets
for overlay positioning. Must use explicit bottom padding.

### Interaction Model Update — Buttons > Gestures
User reference: Philips Hue app uses explicit `...` buttons and action
sheets for all CRUD rather than gesture-only discovery. Decision:
- Keep long-press as a convenience shortcut
- Add explicit `...` / action buttons as the primary CRUD path
- New creations use `+` button → picker sheet (not gesture-triggered)

---

## Roadmap — Updated 2026-05-03 (post Hue app reference review)

### Priority 1 — Room/Zone CRUD (buttons-first)
- Home page room cards: `...` button → action sheet (Edit Room / Delete Room)
- Edit Room sheet: rename text field + room archetype/icon picker (grid)
- Room detail nav bar: `+` (Add picker: scene/lights/automation) + `...` (Edit/Delete)
- Zone: same pattern, identical UX

### Priority 2 — Room Detail Restructure
- Section layout: MY SCENES (grid) → LIGHTS (horizontal scroll strip) → AUTOMATIONS
- Full-width room brightness slider pinned below nav bar
- Automations section scoped per-room (not just global Automations tab)
- Edit mode: SELECT ALL per section, multi-select with blue border,
  bottom toolbar EDIT + DELETE

### Priority 3 — Scene Color Builder
- Orbital gradient color picker (large circle, warm→cool / bright→dim)
- Per-light color assignment: tap light in horizontal strip → set its color
- Cycle through all lights → SAVE creates multi-color scene on bridge
- Controls: color wheel / color temp / effects mode toggle

### Priority 4 — Mic Mode → Sync Mode Upgrade
- Rename MicMode tab to Sync
- STYLE (visualization type) / INTENSITY / COLOR (gradient) / BRIGHTNESS knobs
- WHAT source selector (Mic / Spotify) + WHERE room routing
- Future: Spotify SDK for currently-playing track reactive sync

### Priority 5 — Settings Expansion
- Section: Account (user profile/email)
- Section: Homes (multi-bridge/home support)
- Section: Devices (expand beyond Bridges)
- Section: App preferences (theme, defaults)
- Section: Widgets config
- Section: About + Software update

### Parking Lot (requires backend/bridge work)
- Bridge Automation CRUD (Edit/Delete via long-press — needs bridge PUT)
- BGTaskScheduler background auto-execution
- Notification history log
- Spotify SDK integration
- Siri Shortcuts

### Performance
- SSE instant state updates (no flicker on light cards)
- Brightness slider sensitivity
- UnifiedOrchestrator re-render audit

### Git Tags This Session
- `v0.9.6-ui-polish` — Settings Done button + BulkActionBar tab bar fix

---

## Session Log — 2026-05-03 (Room CRUD + UX Refactor + Sync Mode Plan)

### Accomplished
1. **Room & Zone CRUD — full stack**
   - `HueAPIClient`: added `renameRoom`, `deleteRoom`, `renameZone`, `deleteZone` (PUT + DELETE to Hue V2 API)
   - `UnifiedOrchestrator`: added matching async methods with optimistic updates + rollback + toast
   - `RoomDisplayItem`: changed `name` and `archetype` from `let` to `var` (required for in-place optimistic mutation)
   - `EditRoomSheet.swift`: new file — large archetype icon preview, name text field, scrollable archetype grid (37 types: Traditional / Outdoor / Other), animated selection, amber Save button
   - Added to Xcode project via direct `sed` on `project.pbxproj` (path = `HueHome/UI/Dashboard/EditRoomSheet.swift`)

2. **UX Flow Refactor — CRUD moved to Room Detail**
   - Removed `···` button from dashboard `RoomCard` — it was hidden when lights were on (brightness slider overlaps bottom-right)
   - New flow: Dashboard → tap room → Room Detail → `···` (ellipsis) nav bar button (top-right) → action sheet: Edit Room / Delete Room → EditRoomSheet
   - `RoomDetailView`: added `showRoomMenu` + `showEditSheet` state, `···` toolbar item (hidden during Select mode), `confirmationDialog`, `EditRoomSheet` sheet, `dismiss()` after delete to pop nav stack
   - `room.kind` (`.room` / `.zone`) auto-labels action sheet

3. **Build Fixes (lessons learned)**
   - `xcodeproj` gem `new_file()` adds filename-only path; must use `sed` on `.pbxproj` directly
   - `RoomCard` has a **custom `init`** (needed to seed `@State` from room at init time) — custom init **suppresses Swift's synthesized memberwise initializer entirely**, so `onEllipsisTap` had to be added as explicit parameter in custom init
   - Complex `Binding(get:set:)` in `confirmationDialog` causes type-checker timeout; use plain `@State Bool` instead

### Critical Patterns — Do Not Forget
- **Adding files to Xcode project**: use `sed` to set `path = HueHome/UI/SubFolder/File.swift` in `.pbxproj`. All files in this project use full project-relative paths (NOT just filename). The `xcodeproj` gem `new_file()` / `new_reference()` is unreliable.
- **RoomCard custom init**: any new `RoomCard` parameter MUST be added to the custom `init(room:onToggle:onBrightness:onEllipsisTap:)` — Swift will NOT auto-include it.
- **Optimistic updates**: use `allRooms = allRooms.map { ... }` pattern; for deletes use `withAnimation { allRooms.removeAll { ... } }` with rollback `.append(item)` on catch.

---

## Sync Mode Upgrade Plan (Priority 4 — detailed)

### Concept
Upgrade the existing `MicMode` tab to a full **Sync Mode** with multiple reactive engines. The differentiator: no external hardware, no paid AI API — all iOS-native.

### Sync Mode Engines (Phase 1 — Pure Signal Processing)

#### 1. FFT Frequency Visualizer
- **Tech**: `AVAudioEngine.installTap()` → `Accelerate vDSP_fft_zrip()`
- **Mapping**: sub-bass (20-60Hz) → floor lights deep red/orange; mids → mid rooms; highs (>4kHz) → accent lights white/blue
- **Rate**: 10 updates/sec max (Hue bridge rate limit ~10Hz)
- **File**: Upgrade `MicModeEngine.swift` to `SyncModeEngine.swift`

#### 2. Transient Spike Detection (Gaming Mode)
- **Tech**: Amplitude delta analysis — compare current frame peak to rolling average; if delta > threshold → transient
- **Behavior**: Ambient blue/green baseline → white/orange flash on spike → decay back
- **Configurable**: Sensitivity slider + base color picker

#### 3. Pitch → Hue Mapping
- **Tech**: `AVAudioEngine` with `AVAudioUnitTimePitch` or FFT peak bin → Hz → note → hue angle
- **Mapping**: Low pitch (bass hum, deep voice) → purple; High pitch (whistle, synth) → yellow/green
- **Use case**: Plays lights like a color instrument

#### 4. Ambient Floor Breather
- **Tech**: Rolling noise floor baseline; detect occupancy (sound > floor+threshold)
- **Behavior**: Silence → static lights; presence detected → gentle ±10% brightness breathing animation

#### 5. Decibel Threshold Triggers
- **Tech**: dB metering (already in MicModeEngine), configurable thresholds
- **Behavior**: 0–40dB = cool white; 40–70dB = warm; 70dB+ = red over time
- **Use case**: "Inside voices" indicator for kids / hearing protection for studio

### Sync Mode Engines (Phase 2 — Smart Environment)

#### 6. 🌩️ Thunderstorm Detection (SoundAnalysis)
- **Tech**: `import SoundAnalysis` — `SNAudioStreamAnalyzer` + `SNClassifySoundRequest()`
- **Zero cost**: Apple's built-in CoreML sound classifier, runs fully on-device, iOS 15+
- **Detects**: thunder, rain, music genre, speech, applause, and 300+ other sound events
- **Behavior**: Thunder confidence > 0.7 → trigger lightning show (random white flash, 50-150ms, randomized per light, cool blue ambient between strikes)
- **Architecture**: Add `SoundAnalysisManager.swift` alongside `SyncModeEngine.swift`

#### 7. WeatherKit Integration
- **Tech**: `import WeatherKit` — `WeatherService.shared.weather(for: location)`
- **Entitlement**: `com.apple.developer.weatherkit` (free with Apple Developer account, add in Xcode Signing & Capabilities)
- **Palette mapping**:
  - ☀️ Clear/Sunny → warm gold (2700K, 90% brightness)
  - 🌧️ Rain → deep blue (CIE 0.16/0.15, 60% brightness)
  - ⛈️ Thunderstorm → dark blue pulse baseline (SoundAnalysis takes over live)
  - ❄️ Snow → cool white (6500K, 70%)
  - 🌫️ Fog → desaturated lavender, 40%
  - 🌬️ Wind/Cloudy → neutral grey-white
- **Triggered**: on app foreground + every 30 min background task

#### 8. Context-Aware Smart Scenes (Phase 2B)
- Combine: Time of day + WeatherKit condition + SoundAnalysis classification
- e.g. 8pm + raining + music detected → "Rainy Evening" scene auto-suggestion
- No AI API needed — pure rule engine

### Sync Mode (Phase 3 — Spatial)

#### 9. Location-Based Auto Control
- CoreLocation: detect home SSID/geofence → auto-on at arrival
- CoreMotion: device facing direction → shift light "source" direction (if multi-light rooms)

#### 10. BLE Beacon Room Presence
- Pair cheap iBeacons to rooms → phone detects which room → only sync lights in that room
- Alternative: ML classifier on WiFi signal strength (RSSI) fingerprinting

### Sync Mode UI Plan
```
SyncModeView (replaces MicModeView)
├── Top: Mode Selector (segmented or horizontal pill scroll)
│   Visualizer | Ambient | Gaming | Weather | Smart
├── Middle: Mode-specific controls (varies per mode)
│   - Visualizer: Band sliders (Bass/Mid/High color pickers)
│   - Gaming: Sensitivity + Base color + Flash color
│   - Weather: Live condition card + "Apply to room" button
│   - Smart: Active rules list + add rule
├── Bottom: Global controls
│   - WHERE: Room picker (which rooms react)
│   - INTENSITY: Master intensity slider
│   - [Start / Stop] pill button
└── Persistent: Live waveform/VU visualizer strip
```

### Files to Create/Modify
- `MicModeEngine.swift` → **rename to** `SyncModeEngine.swift`
- **NEW** `SoundAnalysisManager.swift` — SNAudioStreamAnalyzer wrapper
- **NEW** `WeatherSyncManager.swift` — WeatherKit wrapper
- **NEW** `SyncModeView.swift` — replaces MicModeView
- **NEW** `SyncModeRuleEngine.swift` — context-aware rule matching
- `MainTabView.swift` — update tab label from "Mic" to "Sync"
