# ChromaForge — Developer Log

All session notes, architectural decisions, and roadmap context.
This file is the source of truth for "why we did it this way."

---

## Project Identity
- **App name:** ChromaForge (formerly LightShade → HueHome Pro)
- **Bundle ID:** `com.lightshade.app` (keep as-is, never user visible)
- **Developer:** Brian Bean (`brian.scott.bean@gmail.com`)
- **App Store Connect:** https://appstoreconnect.apple.com/apps/6765770802
- **Xcode project:** `HueHome.xcodeproj` (folder: `huehome-pro-v0.3.0/`)

---

## Architecture Overview

### Core Stack
- **iOS 17+**, SwiftUI, `@Observable`, NavigationStack per tab
- **Hue Bridge:** Philips Hue CLIP API v2 (REST + SSE)
- **Auth:** Keychain-stored bridge IP + application key
- **Real-time:** SSE event stream (`HueSSEService`) — one stream per bridge, shared via `UnifiedOrchestrator`
- **State:** `UnifiedOrchestrator` (@Observable) — single source of truth, injected via `.environment()`

### Key Files
| File | Purpose |
|---|---|
| `UnifiedOrchestrator.swift` | Central state + all async mutations |
| `HueAPIClient.swift` | All Hue V2 REST calls |
| `HueSSEService.swift` | SSE stream parser |
| `DashboardView.swift` | Home tab — rooms + zones grid |
| `RoomDetailView.swift` | Per-room lights + scenes + CRUD |
| `EditRoomSheet.swift` | Room/Zone rename + archetype picker sheet |
| `MicModeEngine.swift` | Audio reactive engine (to be upgraded to SyncModeEngine) |
| `MicModeView.swift` | Mic mode UI (to be replaced by SyncModeView) |
| `MainTabView.swift` | Custom glassmorphic tab bar |
| `RoomDisplayItem.swift` | Value-type display model for rooms/zones |

### Target Structure
| Target | Notes |
|---|---|
| HueHome | Main iOS app |
| HueHomeWidgetExtension | Home screen + lock screen widgets |
| LightShadeWatchApp Watch App | watchOS companion |
| HueHomeTests | Unit tests |

---

## Critical Patterns & Gotchas

### 1. Adding Swift Files to Xcode Project
**Never use the `xcodeproj` gem** — it creates filename-only paths that don't match the project convention.  
**Always use `sed` directly on `project.pbxproj`:**
```bash
# Find an existing file entry as reference (e.g. DashboardView.swift):
grep "DashboardView" HueHome.xcodeproj/project.pbxproj
# Result: path = HueHome/UI/Dashboard/DashboardView.swift

# Fix your new file to match the same full-path pattern:
sed -i '' 's|path = NewFile.swift|path = HueHome/UI/SubFolder/NewFile.swift|' \
  HueHome.xcodeproj/project.pbxproj
```
All files in this project use **full project-relative paths** (e.g. `HueHome/UI/Dashboard/Foo.swift`).

### 2. RoomCard Custom Init
`RoomCard` has a custom `init` to seed `@State localIsOn` and `@State localGlowColor` from `room` at initialization. **Swift suppresses the synthesized memberwise initializer when a custom init exists.** Any new `RoomCard` parameter MUST be explicitly added to:
```swift
init(room:onToggle:onBrightness:onEllipsisTap:)
```

### 3. confirmationDialog Binding
Using `Binding(get:set:)` inside `.confirmationDialog()` causes Swift type-checker timeouts in large files. Always use a plain `@State var showXxx: Bool` instead.

### 4. Optimistic Updates Pattern
```swift
// Rename: map over array, mutate matching item
allRooms = allRooms.map { r in
    var updated = r
    if r.id == item.id { updated.name = name }
    return updated
}
// Delete: removeAll + rollback on catch
withAnimation { allRooms.removeAll { $0.id == item.id } }
// On failure: withAnimation { allRooms.append(item) }
```

### 5. Safe Area / Tab Bar
The app uses a custom glassmorphic tab bar in a ZStack. Global `.safeAreaInset(edge: .bottom, 64pt)` on NavigationStack parents clears the tab bar. `RoomDetailView`'s ambient background uses `.ignoresSafeArea()` so its ZStack children need explicit `.padding(.bottom, 100)` for the BulkActionBar.

### 6. RoomDisplayItem Mutability
`name` and `archetype` are `var` (changed from `let`) to allow in-place optimistic mutation in `map` closures. `id` remains `let`.

---

## Version History

### v0.10.0-room-restructure *(2026-05-03)*
- **P1 Room Detail Restructuring — COMPLETE**
- **Room Brightness Header:** Full-width room-level brightness slider + power toggle via grouped_light API. Shows "X of Y on" status.
- **Horizontal Light Strip:** Lights now display in a horizontal scroll strip of compact cards (~110pt wide). Tap → LightControlView, long-press → multi-select mode. Replaced the vertical LazyVStack list.
- **Room-Scoped Automations:** Bridge automations filtered to this room (matches room ID, child resource IDs, and light IDs in automation configuration). Toggle on/off with optimistic update.
- **+ Toolbar Button:** New nav bar `+` button shows action sheet → "New Scene" / "New Automation".
- **Select/Done** moved from toolbar to LIGHTS section header (declutters nav bar).
- **CompactLightCard component:** New reusable card struct for horizontal layout — icon, name, brightness%, power button, glow sync.
- **RoomDetailViewModel additions:** `loadRoomState()`, `toggleRoom(on:)`, `setRoomBrightness(_:)`, `loadAutomations()`, `toggleAutomation(_:)`, `roomBrightness`, `roomIsOn`, `automations` properties.
- No new files — zero `project.pbxproj` changes.

### v0.9.7-room-crud
- Room + Zone rename, archetype picker, delete
- Room CRUD flows via ··· button + action sheets

### v0.9.6-ui-polish *(current)*
- Room & Zone CRUD: rename + archetype picker + delete
- UX: `···` button moved to RoomDetailView nav bar (top-right)
- Flow: Room Detail → `···` → Edit/Delete action sheet → EditRoomSheet
- Fixed: BulkActionBar hidden behind custom tab bar
- Fixed: Settings Done button for fullScreenCover dismissal

### v0.9.5-gesture-stability
- Long-press CRUD on My Schedules automations
- Portrait lock fixes
- Bridge automation tap handling

### v0.9.4-ux-crud
- Scene rename/delete via context menu
- Automation enable/disable toggle

### v0.1.0 *(initial)*
- Bridge mDNS discovery + HTTPS pairing
- Glassmorphic dashboard with SSE real-time updates
- Room toggle + brightness
- Scene viewer/creator/deleter
- Automations viewer
- Widgets (small/medium/large + lock screen)
- Custom app icon

---

## Current Roadmap (updated 2026-05-03 post-feature review)

### Priority 1 — Room Detail Restructuring ✅ *(done — v0.10.0)*
- Layout: Scenes (horizontal strip) → Lights (horizontal strip) → Automations (per-room)
- Per-room brightness slider in detail header
- `+` button in nav bar for adding scenes/automations
- Haptic feedback on brightness sliders (already had since v0.9.x)

### Priority 2 — Scene Color Builder *(upgraded)*
Absorbs **XY Pad** + **Harmonic Color Scaling** from feature review.
- **2D XY Color Pad** — drag puck across CIE xy / HSB field for per-light color assignment (replaces separate sliders)
- **Harmonic Color Scaling** — pick root color + harmony rule (complementary, triad, analogous, split-comp, tetradic); system derives colors for all lights in room. Root hue slider rotates entire palette in harmonic sync.
- Per-light assignment: tap light in horizontal strip → set its color via XY pad or harmony
- Save as scene via existing `CreateSceneView`

### Priority 3 — Sync Mode (replaces Mic Mode tab)

**Phase 1 — Pure Signal Processing** (no external AI/API)
| Engine | Tech | Description |
|---|---|---|
| FFT Visualizer | `AVAudioEngine` + `Accelerate vDSP` | Bass → red, mids → warm, highs → white/blue |
| Transient/Gaming | Amplitude delta analysis | Spike detection → flash effect (explosions, gunshots) |
| Pitch → Hue | FFT peak bin → Hz → hue angle | "Play" lights with voice/instrument |
| Ambient Breather | Noise floor baseline | Presence detection → gentle brightness breathing |
| Decibel Threshold | dB metering | "Inside voices" visual indicator |

**Phase 2 — Smart Environment** (iOS-native, no paid API)
| Engine | Tech | Description |
|---|---|---|
| 🌩️ Thunderstorm detection | `SoundAnalysis` + CoreML | On-device sound classifier → lightning show |
| Weather reactive | `WeatherKit` (free) | Current conditions → color palette |
| Context rules | Time + weather + sound | Combined smart scene suggestions |

**Phase 3 — Spatial** (longer term)
- CoreLocation geofence → auto on/off
- BLE beacons → room-level presence detection
- UWB / RSSI fingerprinting for room routing

**Sync Mode UI:**
```
SyncModeView
├── Mode selector: Visualizer | Ambient | Gaming | Weather | Smart
├── Per-mode controls (band sliders, sensitivity, color pickers)
├── WHERE: Room picker
├── INTENSITY: Master slider
└── [Start / Stop] pill button + live waveform strip
```

**Files:**
- `MicModeEngine.swift` → rename to `SyncModeEngine.swift`
- NEW: `SoundAnalysisManager.swift`
- NEW: `WeatherSyncManager.swift`
- NEW: `SyncModeView.swift`
- NEW: `SyncModeRuleEngine.swift`

### Priority 4 — Settings Expansion
- Account / Homes / Devices / App Preferences / Widgets / About sections

### Priority 5 — Animated Scenes *(new — from feature review)*
Builds on P2 Scene Color Builder. Scenes become timelines, not snapshots.
- **LFO Modulators** — assign waveform (sine, square, saw) to brightness/color per light; configurable rate (0.1–2Hz) + depth. Room "breathes" on sine, pulses on square.
- **Temporal Playhead** — scene = keyframe sequence over time; scrubber UI to drag through timeline, loop a section. Start with 2–3 keyframe transitions (e.g. sunrise over 30 min).
- Rate-limited to 10Hz (Hue bridge spec). Sine works smooth; fast square will be steppy — acceptable tradeoff.
- Full DAW-style scrubber is a v1.1 premium feature; P5 scope = basic keyframes + single LFO per light.

### Parking Lot
- Spotify SDK track-reactive sync
- BGTaskScheduler background automation
- Siri Shortcuts
- Bridge automation CRUD (PUT endpoint)
- Notification history log
- ~~Webhook event listeners~~ — rejected: iOS background limits kill local HTTP servers; Siri Shortcuts serves same "external trigger" need natively

---

## Design Principles
- **Button-driven CRUD** over hidden gestures — every action must be discoverable
- **Optimistic updates** — UI responds instantly, rolls back on failure with toast
- **60fps targets** — `RoomCard` uses local `@State` for brightness/on-state to avoid `@Observable` chain re-renders during gestures
- **SSE over polling** — one SSE stream per bridge, shared via orchestrator pub/sub
- **Demo mode** — all features work without a real bridge (App Review compliance)
