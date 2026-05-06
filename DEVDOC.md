# ChromaGlow (HueHome Pro) — Dev Notes

## Branding
- **App name:** ChromaGlow (rebranded from CastChroma / ChromaForge / LightShade / HueHome Pro)
- **Bundle ID:** `com.lightshade.app` (keep as-is, never user visible)
- **App Store Connect (ChromaGlow):** Apple ID `6766251782` — name locked, Prepare for Submission
- **App Store Connect (old):** https://appstoreconnect.apple.com/apps/6765770802
- **Developer:** Brian Bean (`brian.scott.bean@gmail.com`)
- **Team:** Brian Bean (paid Apple Developer Program)

## Project Location
- **Path:** `/Users/brianbean/Desktop/huehome-pro-v0.3.0/`
- **Xcode project:** `HueHome.xcodeproj`
- **Git tags:** v0.1.0 → v0.13.0-chromaglow → v0.15.1-studio-dj-ux → v0.15.3-studio-stable

## Target Structure
| Target | Bundle ID | Notes |
|---|---|---|
| HueHome | com.huehome.pro | Main iOS app |
| HueHomeWidgetExtension | com.huehome.pro.widget | Home screen widget |
| LightShadeWatchApp Watch App | com.huehome.pro.watchkitapp | watchOS app |
| LightShadeWatchExtension | com.huehome.pro.watchkitapp.watch | Watch complication (NOT embedded in iOS app — see known issues) |
| HueHomeTests | com.huehome.pro.tests | Unit tests |
| App Group | group.com.huehome.pro | Shared UserDefaults (widget ↔ main app) |

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
- **Current (v8):** Thin chromatic glass-tube C shape with horizontal power stem. Full hue gradient: gold → green → cyan → violet → magenta. Atmospheric aura glow on black background. Reads as both a C and a power-button-on-its-side.
- **Icon history:** stained-glass anvil → neon layered C (v1) → power button C (v2) → rainbow power button (v3) → neon power button symmetric (v4) → clown (v5, skipped) → flat cyan-violet C (v6) → 3D glass C (v7) → thin chromatic C final (v8)

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

---

## Session Log: 2026-05-04 — ChromaGlow Rebrand + Sync Engine Overhaul + Bundle ID Migration

### Rebrand: CastChroma / ChromaForge → ChromaGlow

- `AppBrand.swift`: `displayName` → `"ChromaGlow"`, `hueDeviceType` → `"chromaglow#ios"`
- `Info.plist`: `CFBundleDisplayName` → `"ChromaGlow"`
- **App Store Connect record created**: name `ChromaGlow`, Apple ID `6766251782`, bundle `com.huehome.pro`, SKU `ChromaGlow-001`

### Sync Engine Overhaul (`SyncModeEngine.swift`)

**Problem:** Lights were either staying stagnant at high brightness or lagging 5s behind audio input.

**Root Causes:**
1. Bridge command queue overload — REST calls piling up faster than bridge could process
2. No decay — lights held at whatever brightness level they reached
3. Redundant PUT requests — sending same brightness repeatedly

**Fix — Peak follower envelope with fast decay:**
- Fast attack: instant jump to peak brightness on loud audio
- Decay factor `0.50` per 150ms tick → lights near-off in ~450ms of silence
- 150ms rate limiter (one PUT per room per interval)
- Delta threshold 5% — skips sending if brightness change is negligible
- Generation counter prevents stale updates from in-flight requests reaching the bridge after `stop()`

**Behavior:** Loud sound → full brightness. Silence → dark in 450ms. Continuous speech keeps lights bright. Mirrors Hue Entertainment Area "fighting to go dark" feel.

### App Icon (v8 — final)

Iterated through 8 versions. Final: thin chromatic glass-tube C + horizontal power button stem. Full hue gradient gold→green→cyan→violet→magenta. Atmospheric aura glow on black background. Applied to iOS + Watch targets.

### Bundle ID Migration

All targets migrated from `com.lightshade.app.*` → `com.huehome.pro.*`:
- Provisioning profiles auto-created by Xcode via `-allowProvisioningUpdates`
- App Group migrated: `group.com.lightshade.app` → `group.com.huehome.pro`
- Entitlements updated across all targets
- Archives now route to ChromaGlow App Store Connect listing

### Git Tags
- `v0.13.0-chromaglow` — rebrand + sync engine + icon v8
- Next tag target: `v0.14.0-testflight` — first ChromaGlow TestFlight build

---

## Session Log: 2026-05-04 (night) — Architecture Overhaul + Studio Tab Rebuild (v0.14–v0.15.1)

### Accomplished

#### 1. Navigation Architecture (MainTabView)
- 4 tabs: **Home, Scenes, Studio, More** (replaced old Effects + Sync + Bridges layout)
- Custom floating glassmorphic capsule tab bar (`HueTabBar`) with `matchedGeometryEffect` animated indicator
- iPad layout: `NavigationSplitView` sidebar
- iPhone layout: opacity-based switcher (preserves NavigationStack state per tab, eliminates swipe-between-tabs)
- Tab bar height: 64pt — `.safeAreaInset(edge: .bottom, spacing: 0)` clears content
- `HapticManager.shared.light()` on every tab switch

#### 2. Brightness Pill — Added Then Reverted
- Floating brightness pill overlay was implemented to replace in-card brightness control
- Placed in Dashboard ZStack, triggered by `onBrightnessDrag` callbacks from RoomCard + BrightnessRow
- **Reverted completely** — pill competed with iOS system home indicator gesture (user was accidentally switching apps instead of dragging brightness)
- **Decision:** Brightness stays inline on individual cards. Never fight iOS system gestures.
- Files cleaned: `DashboardView.swift`, `RoomCard`, `BrightnessRow` — all pill-related state and callbacks removed

#### 3. StudioView — Controls Migration (sheet → inline)

**Iteration 1:** Nested ZStack overlay inside StudioView ScrollView
- Problem: ZStack overlays inside a child view cannot escape the parent's z-ordering — HueTabBar always rendered above it

**Iteration 2:** `StudioControlsSheet` as native `.sheet()`
- Sheet correctly renders above entire view hierarchy including HueTabBar
- Select card → sheet slides up with sliders + Apply/Stop buttons
- Problem: still required 2 taps (select card → tap Apply inside sheet)

**Iteration 3 (current — v0.15.1):** Tap-to-apply + inline controls
- **Tapping a card fires the effect immediately** — no Apply button, no sheet
- **Tapping the running card stops it**
- **Inline controls** (sliders) animate in below the carousel while an effect is running
- LIVE indicator (green pulse dot) shows which card is active
- `StudioControlsSheet` and all sheet code removed from StudioView

#### 4. Room Picker — Menu → Wheel
- Old: `Menu { }` requiring a tap to open, then another tap to select — 2 taps minimum
- New: `Picker(pickerStyle: .wheel)` always visible, native iOS haptics on scroll, neighbors visible at all times
- Rooms listed first, zones prefixed with ⬡
- Headline label shows currently selected room name in amber
- Zero taps to see all options — just scroll

#### 5. Studio Layout (final v0.15.1)
```
StudioView
├── ROOM / ZONE wheel picker (always visible, 110pt height)
├── EFFECTS carousel
│     └── tap card = apply immediately (or stop if running)
├── Effects inline controls (appears when effect card is running)
├── LIVE MODES carousel
│     └── same tap-to-apply pattern
└── Live Modes inline controls
```

### Critical Patterns Established

**Tap-to-apply model:**
```swift
// In carouselSection card onTapGesture:
if vm.runningCardID == card.id {
    Task { await vm.stop(card) }
} else {
    Task { await vm.apply(card) }
}
```
- `isSelected` is now driven by `runningCardID`, not `selectedCard`
- `selectedCard` state and all sheet bindings removed

**Inline controls visibility:**
```swift
@ViewBuilder
private func inlineControls(for cards: [StudioCard]) -> some View {
    let running = cards.first { $0.id == vm.runningCardID }
    if let card = running, !card.params.isEmpty {
        // render sliders
    }
}
```
- Only shown when a card from THAT carousel is running AND it has params
- Cards with 0 params (colorloop etc.) skip the controls section entirely
- `.transition(.move(edge: .top).combined(with: .opacity))` + spring animation

**Wheel picker binding pattern:**
```swift
Picker("", selection: Binding(
    get: { vm.selectedRoom?.id ?? "" },
    set: { id in
        if let match = allPickerItems.first(where: { $0.id == id }) {
            vm.selectedRoom = match
        }
    }
))
.pickerStyle(.wheel)
```
- `allPickerItems` computed property: `orchestrator.allRooms + orchestrator.allZones`

### Known Issues (v0.15.1)
- Wheel picker shows rooms and zones in a flat list — no unselectable section header between them
- No room selected + card tap: silently does nothing (should pulse wheel + show toast)
- Studio card descriptions are technical names not sensory descriptions

### Git Tag
- `v0.15.1-studio-dj-ux` — Studio tap-to-apply + wheel picker + inline controls

---

## Competitive Landscape Research (2026-05-05)

### Apps Surveyed
| App | Focus | Notable |
|---|---|---|
| Philips Hue (official) | First-party | AI automations, SpatialAware (AR), multi-user geofencing |
| iConnectHue | Power users | Magic Scenes, animation editor, Discotainment, Bridge Pro support |
| Hue Party | Music/disco | BPM detection, audio sync |
| Huemote | Speed/minimal | Fast tap-to-scene, no complexity |
| All 4 Hue | Bridge management | Deep bridge API exposure, Android/Win/Mac |
| Govee | Govee ecosystem | AI Lighting Bot (text-to-effect, 12B param model), DaySync, Dreamview |
| Nanoleaf | Panel hardware | Community scene library (Discovery tab), Rhythm, Orchestrator (desktop) |
| LIFX | Hardware quality | High brightness, relies on third-party for music sync |

### Key Competitive Gaps ChromaGlow Must Close
| Feature | Status |
|---|---|
| Save custom scenes (basic table stakes) | ❌ Missing |
| Home screen + lock screen widgets | ❌ Missing |
| Geofencing (arrive/leave home) | ❌ Missing |
| Circadian / natural light schedule | ❌ Missing |
| Scene color preview swatches on cards | ❌ Missing |
| Siri Shortcuts integration | ❌ Missing |
| Onboarding / first-run flow | ❌ Missing |
| Tab bar labels (icon-only forces memorization) | ❌ Missing |
| Frequency-band mic (bass/mid/treble separate) | Partial |

### ChromaGlow Unique Differentiators (nobody else has)
1. Tap-to-apply Studio with live inline controls — DJ board UX
2. Entertainment API integration (GamingEngine, AmbientEngine)
3. Composition Workshop (roadmap — genuinely novel, see below)
4. Visual design — glassmorphic dark, best in class
5. Time-aware suggestions on Home tab
6. Optimistic UI with live SSE state sync

---

## UX/UI Audit Summary (2026-05-05)

### Home Tab (B+)
- ✅ Room card grid with SSE color glow
- ✅ In-card brightness, optimistic toggle
- ✅ Time-aware suggestion banner
- ❌ No "Now Playing" indicator for active Studio effect
- ❌ Presets bar applies globally with no room selector
- ❌ No per-light color dots on room cards
- ❌ No quick-scene long-press on room card (require navigating in)

### Scenes Tab (B)
- ✅ Cross-bridge scene browser, search, room filter chips
- ✅ Shimmer skeleton, rename/delete via long-press
- ❌ Scene cards have NO color preview — just names (critical)
- ❌ No active indicator across whole home
- ❌ Scene creation flow duplicated (global vs room-level)
- ❌ No scene sharing / deep links

### Studio Tab (A- post v0.15.1)
- ✅ Tap-to-apply one-tap effects
- ✅ Inline controls below carousel while running
- ✅ Wheel picker for rooms
- ❌ Wheel shows flat room+zone list (no visual group separator)
- ❌ No room selected → silent failure, should toast
- ❌ No animated effect previews on cards
- ❌ No "Save as Quick Access" for room+effect combo

### More Tab (C+)
- ✅ Glassmorphic card groups, live connection status dot
- ❌ "More" is a junk drawer name — rename to "Hub" or "Control"
- ❌ 3 dead "Coming Soon" rows (Accessories, Profiles, Share Invite)
- ❌ Automations buried here — should be accessible from Home
- ❌ No geofencing, no location triggers

### Room Detail (A-)
- ✅ Per-bulb brightness, bulk selection, scene builder
- ❌ "+ New Scene" chip not visible — only reachable via toolbar + button
- ❌ No way to navigate from Scenes tab → room without going back to Home
- ❌ Light cards don't reflect actual bulb color

### Global Issues
- ❌ No onboarding
- ❌ No widgets
- ❌ No Siri Shortcuts
- ❌ Tab bar labels missing (icon only)
- ❌ No global search

### Priority Order
```
CRITICAL:   1. Scene card color preview swatches
             2. Widgets
             3. Onboarding
             4. Tab bar labels
HIGH:        5. Room card quick-scene long-press
             6. Now Playing bar on Home
             7. Geofencing
             8. Siri Shortcuts
             9. Rename More → Hub
            10. Remove dead Coming Soon rows
DIFFERENTIATOR: 11. Animated effect previews on Studio cards
            12. Save Studio effect+room as Quick Access
            13. Scene sharing via deep link
            14. Compositions (v0.17)
            15. Community scene browser (v0.18)
```

---

## Composition Workshop — Full Technical Design (2026-05-05)

### What It Is (plain English)
The Composition Workshop lets you mix your own live light show in real time — no presets, no Apply button, no waiting. You layer four things together: the colors your lights use, how they move across the room, how the brightness pulses over time, and whether they react to sound. Drag any slider and your lights respond instantly, while they're already running. Point it at the bass frequencies and your lights punch on every beat. Set a heartbeat pulse and slow the cascade to match the mood of the room. When you find something you love, save it with a name and it's yours. Every other app gives you someone else's finished effect. This one lets you build your own — on the fly, for the exact moment you're in.

### Why It's Novel
- iConnectHue Magic Scenes: pre-defined color sets, no layering of independent dimensions
- Govee AI bot: text prompt → single baked output, not real-time compositable
- Nanoleaf community scenes: baked sequences, not live-tunable programs
- Professional stage software (Resolume, GrandMA2): has this concept but is desktop-only, $500-5000/yr, not Hue-connected
- **ChromaGlow: first consumer mobile app with real-time multi-layer effect compositing for smart home lights**

### The Four Layers
```
Palette  — what colors (solid, gradient, chromatic, temperature)
Motion   — how colors distribute spatially (cascade, wave, orbit, scatter)
Envelope — brightness over time (steady, breathe, heartbeat, pulse, flicker, swell)
Reaction — what drives dynamic changes (none, mic amplitude, mic bass, mic treble, time of day)
```

### Why No Apply Button — It's Genuinely Live
The Entertainment API (DTLS/UDP) is a continuous stream. The DTLS session is open and the render loop sends the bridge a packet every 40ms containing the current computed state of every light. When a user drags a slider, the @Observable property updates. The next frame (≤40ms) reads the new value and sends a new UDP packet. The bridge applies it immediately.

- **REST (how normal Hue works):** change → send HTTP request → bridge responds → light changes (~200-500ms, requires action)
- **Entertainment UDP (Compositions):** session is open → render loop ticks at 25fps → reads current layer configs → sends all light states in one packet → lights respond in ≤40ms. No button. No lag.

This enables true DJ mixing: drag cascade speed while effect is running, lights respond in real time. Adjust BPM to match a song. Shift palette hue mid-track.

### Transport Architecture
```
Composition Layer    → Transport        → Notes
─────────────────────────────────────────────────
Static palette       → REST (one-shot)  → Set once, bridge holds
Bridge-native effect → REST (one-shot)  → Persists without app
Real-time motion     → Entertainment UDP → Per-light, 25fps
Real-time envelope   → Entertainment UDP → Multiplied into each frame
Mic reaction         → Entertainment UDP → Modifies brightness per frame
```
Static layers = zero ongoing cost. Only dynamic layers use the UDP channel.

### Key Math
```swift
// Heartbeat envelope at 72 BPM:
let T = 60.0 / bpm           // 0.83s per cycle
let phase = t.truncatingRemainder(dividingBy: T) / T
let lub = exp(-pow((phase - 0.15) / 0.04, 2))    // sharp peak at 15%
let dub = exp(-pow((phase - 0.35) / 0.06, 2)) * 0.55  // soft peak at 35%
return min(1.0, lub + dub)

// Cascade motion across N lights:
let position = Double(lightIndex) / Double(total)
return (position + time * speed).truncatingRemainder(dividingBy: 1.0)
```

### What's Already Built
- `HueEntertainmentClient` — DTLS session, `send(channels:)` method ✅
- `SyncModeEngine` — CADisplayLink render loop at 25fps ✅
- `SyncEngineProtocol` — CompositionEngine just conforms to this ✅
- `RestSender` mailbox (latest-wins, prevents queue buildup) ✅
- Generation counter (zombie Task prevention) ✅
- `EntertainmentConfigManager` — reads existing entertainment groups ✅

### What Needs to Be Built
| Component | Est. Days |
|---|---|
| `CompositionEngine` (render loop + layer math) | 2 |
| `PaletteConfig + MotionConfig + EnvelopeConfig + ReactionConfig` | 1 |
| Entertainment group auto-creation (POST to bridge, no Hue app needed) | 1 |
| `CompositionBuilderView` (mixing board UI) | 2 |
| Save / Load / Share as deep link / QR | 1 |
| Wire into SyncModeEngine + Studio tab | 0.5 |
| Tuning (envelope presets feel right) | 0.5 |
| **Total** | **~8 days** |

### Performance Budget
- Render math for 10 lights × 4 layers: ~0.2ms/frame
- UDP serialize + send: ~0.5ms/frame
- Total: ~0.8ms per frame at 25fps = 24ms CPU/sec — well within iPhone budget
- Bridge load: 30 UDP packets/sec, 0 REST calls during composition

### Constraints
| Constraint | Mitigation |
|---|---|
| Entertainment API requires foreground | Fine for intentional workshop. Show "Keep app open" banner. |
| Max 10 lights per entertainment group | Auto-select top 10 by position. For >10, create 2 groups. |
| DTLS session setup ~200ms | Warm up session on `.onAppear` of workshop view, not on Play tap |
| Session drops | Auto-reconnect with backoff, fallback to REST for duration |
| Color space: need CIE xy | HueColorUtils already has conversion utilities |

### Roadmap Placement
```
v0.15.x  ← Current: Studio UX, wheel picker, tap-to-apply
v0.16.0  ← Save Scenes + Circadian schedule
v0.16.5  ← Widgets + Siri Shortcuts
v0.17.0  ← Composition Workshop (Palette + Motion + Envelope + Reaction)
v0.17.5  ← Community share + deep links
v0.18.0  ← Geofencing + conditional automations
v0.19.0  ← AI text-to-composition
```

### Git Tag
- `v0.15.1-studio-dj-ux` — pushed 2026-05-05

---

## Session Log: 2026-05-05 — Studio Engine Stability & Room-Scoped Effects (v0.15.3)

### Problem Statement
Studio lighting effects were "leaking" across rooms. Selecting a specific room (e.g. Kitchen) and tapping a card (e.g. Fire) would affect lights in other rooms or the entire house. Users also reported "stuck bulbs" that stayed in their effect state after switching.

### Root Cause Analysis (multi-attempt)

**Bug A — `fetchLightIDsForGroup` returned ALL lights (CRITICAL)**
- `HueAPIClient.fetchLightIDsForGroup(groupedLightID:)` completely ignored the `groupedLightID` parameter
- Implementation: `let lights = try await fetchLights(); return lights.map { $0.id }`
- This returned every light on the bridge (~16 lights) regardless of which room was selected
- Result: per-light effects sent to ALL lights, not just the target room's lights

**Bug B — `grouped_light` has NO effects field (SILENT FAILURE)**
- The `setGroupedLightNativeEffect()` and `setGroupedLightWithEffect()` methods sent `{"effects": {"effect": "candle"}}` to the `grouped_light` endpoint
- The bridge returned HTTP 200 but **silently ignored** the effects field — grouped_light only supports `on`, `dimming`, `color`, `color_temperature`
- This made it appear like effects were being applied when they weren't
- Effects must be set per-light via `PUT /clip/v2/resource/light/{id}` with `{"effects": {"effect": "candle"}}`

**Bug C — Stop path was a no-op for effects**
- `stop()` sent `setGroupedLightNativeEffect(id:, effect: "no_effect")` — but since grouped_light has no effects field, this did nothing
- Per-light cleanup via `lastPerLightIDs` was the only real cleanup, but if it failed or was incomplete, lights stayed stuck

**Bug D — Entertainment configs are bridge-wide**
- appDriven effects (Strobe, Party, Thunderstorm) used the Entertainment API (DTLS/UDP)
- `tryStartEntertainment()` opened the first entertainment config on the bridge
- Entertainment configs include lights from ALL rooms, not just the selected room
- Result: Strobe/Party/Thunderstorm always controlled the entire entertainment area regardless of room picker

### Hue CLIP v2 API — Key Constraints Learned

| Resource | Supports `effects` field? | Supports `on`/`dimming`? | Rate Limit |
|---|---|---|---|
| `/light/{id}` | ✅ Yes (candle, fire, sparkle, etc.) | ✅ Yes | ~10 PUT/sec aggregate |
| `/grouped_light/{id}` | ❌ No (silently ignored) | ✅ Yes | ~1 PUT/sec per group |
| `/scene/{id}` | Via `recall.action` | N/A | Atomic, room-scoped |
| Entertainment DTLS | Per-channel color/bri at 50fps | N/A | Bridge-wide entertainment area |

**Room vs Zone children:**
- Room `children[]` → `rtype: "device"` — lights matched via `light.owner.rid == device.id`
- Zone `children[]` → `rtype: "light"` — direct match on `light.id` (no indirection)
- The "Home" zone contains ALL lights on the bridge

**How the official Hue app does it:**
- Uses scenes (`PUT /scene/{id}` with `{"recall": {"action": "active"}}`) — inherently room-scoped
- Effects set per-light to the scene's known light list
- Never queries the bridge to "find" which lights belong to a room at apply time

### Solution Architecture (v0.15.3)

#### 1. `resolveLightIDs(for:api:)` — New helper in StudioViewModel
```swift
// Zone: zero API calls — child refs ARE light IDs
let ids = refs.filter { $0.rtype == "light" }.map { $0.rid }

// Room: one fetchLights() call — match light.owner.rid to device IDs
let deviceIDs = Set(refs.map { $0.rid })
let roomLightIDs = allLights
    .filter { deviceIDs.contains($0.owner?.rid ?? "") }
    .map { $0.id }
```
Uses `RoomDisplayItem.childResourceRefs` (already in memory from initial room load). Eliminates the 3-GET-per-apply `fetchLightIDsForGroup` call entirely.

#### 2. Apply flow (bridgeNative):
```
1. setGroupedLightState(on: true, brightness: X)  ← on+brightness ONLY, no effects field
2. resolveLightIDs(for: room, api: api)            ← in-memory child refs
3. sendPerLightBatched(effect: "fire")             ← only room's lights
4. Store: runningCardID, runningRoom, lastPerLightIDs
```

#### 3. Stop flow:
```
1. Per-light batched: no_effect to lastPerLightIDs  ← ONLY way to clear effects
2. If explicit stop: setGroupedLight(on: false)     ← just on/off, no effects
3. Clear: runningCardID, runningRoom, lastPerLightIDs
```

#### 4. Entertainment area scoping (appDriven):
- Strobe, Party, Thunderstorm use entertainment API → always bridge-wide
- Decision: accept entertainment-area scoping, communicate it clearly in UI
- Added `isEntertainmentScoped` property to `StudioCard`
- Added `⚡ Entertainment Area` badge on those 3 cards
- Room picker swaps to show `⚡ Entertainment Area` in card accent color when running
- Room picker tap/swipe disabled during entertainment mode
- Future: user toggle to choose REST (room-scoped) vs Entertainment (area-wide)

### Files Changed

| File | Changes |
|---|---|
| `StudioViewModel.swift` | Added `resolveLightIDs()` helper, `isEntertainmentScoped` on StudioCard, fixed apply to use `setGroupedLightState` (no effects), fixed stop to remove dead `setGroupedLightNativeEffect` call |
| `StudioView.swift` | Added `⚡ Entertainment Area` badge on cards, room picker swaps to entertainment indicator, disabled picker during entertainment mode |
| `HueAPIClient.swift` | Fixed `fetchLightIDsForGroup` to resolve grouped_light→room/zone→lights chain (fallback, no longer primary path) |

### Card Scoping Summary

| Card | Type | Scoping | Transport |
|---|---|---|---|
| Candle | bridgeNative | Room-scoped ✅ | Per-light REST |
| Fire | bridgeNative | Room-scoped ✅ | Per-light REST |
| Sparkle | bridgeNative | Room-scoped ✅ | Per-light REST |
| Prism | bridgeNative | Room-scoped ✅ | Per-light REST |
| Opal | bridgeNative | Room-scoped ✅ | Per-light REST |
| Glisten | bridgeNative | Room-scoped ✅ | Per-light REST |
| Color Loop | bridgeNative | Room-scoped ✅ | Per-light REST |
| Strobe | appDriven | Entertainment area ⚡ | DTLS/UDP (50fps) |
| Party | appDriven | Entertainment area ⚡ | DTLS/UDP (50fps) |
| Thunderstorm | appDriven | Entertainment area ⚡ | DTLS/UDP (50fps) |
| Music Sync | appDriven | Via SyncModeEngine | Notification + REST |
| Gaming | appDriven | Via SyncModeEngine | Notification + REST |
| Ambient | appDriven | Room-scoped ✅ | REST (groupedLightID) |

### Critical Design Principles Established

1. **Never send `effects` to `grouped_light`** — the bridge silently ignores it. Effects are per-light ONLY.
2. **Use `childResourceRefs` from RoomDisplayItem** — already in memory, no runtime API calls needed for room membership.
3. **Entertainment configs are bridge-wide** — don't pretend they're room-scoped. Communicate clearly in UI.
4. **`runningRoom` tracks where the effect was started** — stop() always targets runningRoom, not selectedRoom (which may have changed).
5. **Per-light `no_effect` is the ONLY way to clear effects** — grouped_light cannot clear them.

### Future: User-Controlled Transport Selection
- Add a toggle on entertainment-scoped cards: "Room Only" (REST) vs "Entertainment Area" (DTLS)
- REST Strobe uses per-light calls at ~10 PUT/sec — workable for rooms with ≤5 lights
- Gives power users full control, eliminates ambiguity

### Git Tag
- `v0.15.3-studio-stable` — stable room-scoped effects + entertainment area UI

---

## Session Log: 2026-05-05 (night) — Multi-Room Concurrent Effects + Composer Design (v0.16.0)

### Multi-Room Concurrent Effects — Built & Committed

#### Problem
Studio only allowed one effect to run at a time across the entire bridge. Users wanted independent effects in different rooms simultaneously (e.g., Sparkle on Kitchen + Fire on Bedroom).

#### Root Cause
`StudioViewModel` maintained single-instance state (`runningCardID`, `runningRoom`, `lastPerLightIDs`). Calling `apply()` implicitly `stop()`'d any existing effect.

#### Solution — Per-Room Effect Dictionary

**New data model:**
```swift
struct RunningEffect {
    let cardID: String
    let card: StudioCard
    let room: RoomDisplayItem
    let lightIDs: [String]
    let isEntertainment: Bool
}

// Replaced:
//   @Published var runningCardID: String?
//   @Published var runningRoom: RoomDisplayItem?
//   @Published var lastPerLightIDs: [String]
// With:
@Published var runningEffects: [String: RunningEffect] = [:]  // keyed by roomID
```

**Key computed properties:**
```swift
var currentRoomEffect: RunningEffect? {
    guard let room = selectedRoom else { return nil }
    return runningEffects[room.id]
}

var runningCardID: String? {  // backward-compat for card grid
    currentRoomEffect?.cardID
}
```

#### Apply Logic (room-scoped)
1. `apply(card)` targets `selectedRoom`
2. If same card already running on that room → toggle off (stop)
3. If different card running on that room → replace (stop old, start new)
4. If card running on OTHER rooms → those continue undisturbed

#### Light Overlap Detection
Before applying to a new room, checks if any of its lights are already owned by another running effect:
```swift
let newLightSet = Set(lightIDs)
for (existingRoomID, effect) in runningEffects {
    let overlap = Set(effect.lightIDs).intersection(newLightSet)
    if !overlap.isEmpty {
        await stopEffect(on: existingRoomID)
    }
}
```
Critical for the "Home" zone which contains ALL lights — applying to Home correctly stops any individual room effects first.

#### Entertainment Mutual Exclusion
- Only 1 DTLS session allowed by bridge hardware
- If new card is entertainment-scoped AND an existing entertainment effect is running → stop the existing one
- Entertainment + bridgeNative CAN coexist (different API paths)
- Two entertainment effects CANNOT coexist

#### UI Changes (StudioView + RoomPickerSheetView)

**Mixer tray:**
- Header now shows `card.name` + room name subtitle
- `"3 rooms"` amber badge when multiple rooms have active effects
- Mixer keyed by `currentRoomEffect?.cardID ?? selectedRoom?.id` — swaps content when switching rooms

**Room picker sheet:**
- New `runningEffects` parameter passed through
- Each room row shows colored dot + effect name if that room has an active effect
- Users can see at-a-glance which rooms are "alive"

**Card grid:**
- `isRunning` now checks against `currentRoomEffect?.cardID` (not global `runningCardID`)
- Cards show running state relative to the SELECTED room

#### Files Changed
| File | Changes |
|---|---|
| `StudioViewModel.swift` | Added `RunningEffect` struct, replaced global state with `runningEffects` dictionary, added `currentRoomEffect` computed property, `stopEffect(on:)`, `stopAll()`, overlap detection in `apply()`, entertainment mutual exclusion |
| `StudioView.swift` | Mixer visibility driven by `currentRoomEffect`, mixer header shows room name + multi-room badge, card running state per-room, entertainment label uses `currentRoomEffect`, `runningEffects` passed to room picker |
| `RoomPickerSheetView.swift` | Added `runningEffects` parameter, room rows show colored dot + effect name for active rooms |

#### Scenario Matrix
| # | State | Action | Result |
|---|---|---|---|
| 1 | No effects | Kitchen → tap Candle | Candle starts on Kitchen |
| 2 | Kitchen=Candle | Kitchen → tap Candle again | Candle stops on Kitchen |
| 3 | Kitchen=Fire | Switch to Bathroom → tap Sparkle | Both run. Kitchen=Fire, Bath=Sparkle |
| 4 | Kitchen=Fire, Bath=Sparkle | Switch to Kitchen | Mixer shows Fire. Bath continues. |
| 5 | Kitchen=Fire | Kitchen → tap Sparkle | Fire stops → Sparkle starts (same-room replace) |
| 6 | Kitchen=Fire | Switch to Home zone → tap Sparkle | Fire stops (overlap). Sparkle on all lights. |
| 7 | Kitchen=Strobe(ent) | Bathroom → tap Sparkle | Both run (ent + bridgeNative coexist) |
| 8 | Kitchen=Strobe(ent) | Bathroom → tap Party(ent) | Strobe stops. Party starts (ent mutual exclusion) |

### Hue Dynamic Scenes vs Studio Effects — Distinction

**Hue "Dynamic Scenes"** = bridge-native animated effects (candle, fire, sparkle, prism, opal, glisten). The bridge runs the animation algorithm internally. App just sets the effect field and forgets. Persists when app closes.

**App-driven effects** = Strobe, Party, Thunderstorm, Music Sync, Gaming, Ambient. App renders frames and sends commands. Requires app to be running (foreground for DTLS, background-capable for REST-only).

**All Studio cards produce animated, living light.** The bridgeNative ones ARE Hue's dynamic scenes with a DJ-style UI. The appDriven ones are original effects Hue doesn't offer.

### Composer Feature — Complete Technical Design

The Composer is a **dynamic scene creation engine** integrated into Studio as Deck 3. Users build any lighting experience from scratch by composing four independent layers in real time.

> Status update (2026-05-06): Core Composer implementation is now shipped in-tree (engine, Deck 3, mixer layer tabs, save flow, and preset CRUD). Additional polish shipped same day: inline AI generation entry inside the `+ Create` pill, Composer layer-activity chips on cards, and seasonal deck banner affordance. Treat this section as architectural reference plus intent; remaining work is mainly cross-device QA, transport UX validation, and provider-backed AI generation.

**Core UX principle:** Same one-tap flow as every other Studio card. Tap "+ Create" → lights respond instantly in a default state → mixer tray shows layer tabs → drag any slider → lights respond live → save.

#### The Four Layers
1. **Palette** 🎨 — what colors (solid/gradient/spectrum/temperature, 3 color pickers, hue shift, saturation)
2. **Motion** 🌊 — spatial distribution (static/cascade/wave/scatter/bounce, speed, direction, spread, offset, mirror)
3. **Envelope** 📈 — brightness over time (steady/breathe/heartbeat/pulse/flicker/swell, BPM, depth, attack/decay, duty cycle, min/max brightness)
4. **Reaction** 🎤 — input-driven modulation (none/mic amp/bass/mid/treble/tap tempo, sensitivity, targets, smoothing, threshold)

#### UI: Mixer Tray with Layer Tabs
- 4 horizontal pill buttons at top of mixer: `[🎨 Palette] [🌊 Motion] [📈 Envelope] [🎤 React]`
- Tapping a tab cross-fades to that layer's controls (3-5 essential sliders each)
- "+N more ▾" reveals advanced controls (same pattern as existing param sheets)
- Save button (💾) in mixer header → name → becomes a card on Deck 3

#### Deck 3 Layout
- **Category filter chips** at top: All / Ambient / Energetic / Holiday / My Creations
- **"+ Create" button** — full-width, gradient shimmer border
- **Saved compositions** — rendered as normal StudioCards, layer activity dots at bottom
- Long-press → Edit / Rename / Duplicate / Delete context menu

#### 20 Starter Presets (3 categories)

**Ambient (5):** Sunset Cascade, Ocean Drift, Northern Lights, Cozy Evening, Heartbeat
**Energetic (3):** Bass Drop, Club Mode, Storm Chase
**Holiday (12):** Christmas Classic, Winter Wonderland, Halloween Haunt, Valentine's Glow, 4th of July, St. Patrick's, Easter Pastels, Hanukkah, Diwali, New Year's Eve, Thanksgiving, Mardi Gras

Each holiday preset has a `seasonMonths` field — the app auto-surfaces seasonal presets when the current month matches (e.g., Halloween Haunt promoted in October).

#### Data Model
```swift
struct CompositionPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var icon: String              // SF Symbol name
    var accentColorHex: String
    var isBuiltIn: Bool
    var category: PresetCategory  // ambient / energetic / holiday / myCreations
    var seasonMonths: [Int]?      // e.g. [10] for October, [12, 1, 2] for winter
    
    var palette: PaletteConfig
    var motion: MotionConfig
    var envelope: EnvelopeConfig
    var reaction: ReactionConfig
    
    var createdAt: Date
    var updatedAt: Date
}

enum PresetCategory: String, Codable, CaseIterable {
    case all, myCreations, ambient, energetic, holiday
}
```

Storage: JSON file in app documents (~500 bytes per preset, no Core Data needed).

#### Render Engine
```swift
final class CompositionEngine {
    func render(time: Double, lightCount: Int, audioLevel: Float) 
        -> [(x: Double, y: Double, brightness: Double)]
    {
        (0..<lightCount).map { index in
            let phase = motion.phase(lightIndex: index, total: lightCount, time: time)
            let (x, y) = palette.color(at: phase)
            var bri = envelope.value(at: time)
            bri = reaction.apply(baseBrightness: bri, audioLevel: audioLevel, time: time)
            return (x: x, y: y, brightness: bri)
        }
    }
}
```

Transport: DTLS/UDP when entertainment config available (per-light, 25fps). REST fallback via RestSender mailbox (group-level, 5fps). Auto-selected, not user-toggled.

#### Integration with Existing Code
- `StudioStrategy.composition(presetID:)` case (current implementation)
- Compositions stored in `runningEffects[room.id]` — full multi-room support
- Existing `HueEntertainmentClient.send(channels:)` is the output
- Existing `RestSender` handles REST fallback
- Existing `paramValues` namespace stores per-card param overrides
- 90% of infrastructure already production code

#### Build Estimate
~12.5 days total (9 days for MVP, 3.5 days for audio reactivity + presets + polish)

### Git Tags
- `832b457` → `Studio: multi-room concurrent effects` (HEAD)
- `v0.15.3-studio-stable` → last known stable point before multi-room

### Updated Roadmap
```
v0.15.3  ← DONE: Room-scoped effects, entertainment area badges
v0.16.0  ← DONE: Multi-room concurrent effects
v0.17.0  ← DONE: Composer core (engine + UI + save/load + categories + presets)
v0.17.x  ← CURRENT: Composer polish + cross-device QA + transport UX hardening
v0.17.5  ← Community share + deep links (export/import compositions)
v0.18.0  ← Widgets + Siri Shortcuts + Geofencing
v0.19.0  ← AI text-to-composition
```

### Critical Context for Cursor Migration

#### Project Structure
```
/Users/brianbean/Desktop/huehome-pro-v0.3.0/
├── HueHome.xcodeproj
├── HueHome/
│   ├── Core/
│   │   ├── Network/
│   │   │   ├── UnifiedOrchestrator.swift    ← Central state manager (2182 lines)
│   │   │   ├── HueAPIClient.swift            ← REST API client
│   │   │   ├── HueEntertainmentClient.swift  ← DTLS/UDP streaming (383 lines)
│   │   │   └── EntertainmentConfigManager.swift
│   │   ├── Models/
│   │   │   └── RoomDisplayItem.swift         ← Room/zone data model
│   │   └── ViewModels/
│   ├── UI/
│   │   ├── Studio/
│   │   │   ├── StudioView.swift              ← Studio tab UI (748 lines)
│   │   │   ├── StudioViewModel.swift         ← Studio state + apply/stop (769 lines)
│   │   │   ├── RoomPickerSheetView.swift     ← Room selection sheet
│   │   │   ├── StudioCardCanvas.swift        ← Card background animations
│   │   │   └── StudioCardButtonStyle.swift
│   │   ├── Sync/
│   │   │   ├── SyncModeEngine.swift          ← Audio render loop (609 lines)
│   │   │   ├── VisualizerEngine.swift
│   │   │   ├── GamingEngine.swift
│   │   │   └── AmbientEngine.swift
│   │   ├── Components/
│   │   │   ├── HueColorUtils.swift           ← CIE xy ↔ RGB conversion
│   │   │   └── HapticManager.swift
│   │   └── Navigation/
│   │       └── MainTabView.swift             ← 4 tabs: Home, Scenes, Studio, More
│   └── DesignSystem/
│       ├── HuePalette.swift                  ← Color tokens
│       ├── HueAnimation.swift                ← Animation tokens
│       └── HueSpacing.swift                  ← Layout tokens
```

#### Key Architecture Rules (DO NOT VIOLATE)
1. **Never send `effects` to `grouped_light`** — bridge silently ignores it. Effects are per-light ONLY.
2. **Use `childResourceRefs` from RoomDisplayItem** — in-memory, no API calls for room membership.
3. **Entertainment configs are bridge-wide** — only 1 DTLS session at a time.
4. **All display items must hash ALL volatile fields** — not just `id`. SwiftUI ForEach depends on this.
5. **Generation counter pattern** — all async Tasks capture `generation` at launch, bail if it changes.
6. **RestSender mailbox** — latest-wins, max 1 in-flight REST request. Never queue.
7. **`@Observable` on ViewModels** — NOT `@ObservableObject`. The entire app uses the Observation framework.
8. **Per-light rate limit ~10 PUT/sec** — batch and stagger. Bridge silently drops excess.

#### Design System Tokens
- `HuePalette.amber` — primary accent (amber gold)
- `HuePalette.Noir.success` — green (live indicators)
- `HuePalette.Noir.destructive` — red (stop/delete)
- `HueAnimation.fast` / `.card` / `.slow` — spring animations
- `HueSpacing.screenH` / `.md` / `.sm` — consistent padding
- `HueRadius.xl` — rounded rectangle corners
- Dark mode only, glassmorphic material backgrounds

#### Key API Patterns
```swift
// Apply bridge-native effect to a room:
for lightID in roomLightIDs {
    try await api.setLightEffect(id: lightID, effect: "fire")
}

// Stop bridge-native effect:
for lightID in lastPerLightIDs {
    try await api.setLightEffect(id: lightID, effect: "no_effect")
}

// Entertainment streaming (50fps):
await entClient.send(channels: [
    (id: 0, x: 0.45, y: 0.41, brightness: 0.8),
    (id: 1, x: 0.31, y: 0.33, brightness: 0.6)
])
```

