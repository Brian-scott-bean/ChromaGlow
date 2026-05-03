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

## Current Roadmap

### Priority 1 — Room Detail Restructuring *(next)*
- Layout: Scenes (grid) → Lights (horizontal strip) → Automations (per-room)
- Per-room brightness slider in detail header
- `+` button in nav bar for adding scenes/lights

### Priority 2 — Sync Mode (replaces Mic Mode tab)

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

### Priority 3 — Scene Color Builder
- Per-light orbital color picker
- Assign individual CIE xy colors to each light in a room
- Save as scene via existing `CreateSceneView`

### Priority 4 — Settings Expansion
- Account / Homes / Devices / App Preferences / Widgets / About sections

### Parking Lot
- Spotify SDK track-reactive sync
- BGTaskScheduler background automation
- Siri Shortcuts
- Bridge automation CRUD (PUT endpoint)
- Notification history log

---

## Design Principles
- **Button-driven CRUD** over hidden gestures — every action must be discoverable
- **Optimistic updates** — UI responds instantly, rolls back on failure with toast
- **60fps targets** — `RoomCard` uses local `@State` for brightness/on-state to avoid `@Observable` chain re-renders during gestures
- **SSE over polling** — one SSE stream per bridge, shared via orchestrator pub/sub
- **Demo mode** — all features work without a real bridge (App Review compliance)
