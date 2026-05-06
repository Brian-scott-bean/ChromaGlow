# Cursor Kickoff — Composer Feature (v0.17.0)

## Step 1: Read These Files First (DO NOT SKIP)

Read these 3 files completely before writing any code:

1. **`.cursorrules`** — Critical architecture rules that MUST NOT be violated
2. **`DEVDOC.md`** — Full development history. Focus on:
   - "Session Log: 2026-05-05 (night)" — Multi-room concurrent effects (just built)
   - "Composer Feature — Complete Technical Design" — What we're building
   - "Critical Context for Cursor Migration" — Architecture rules, design tokens, key files
   - "Key Architecture Rules (DO NOT VIOLATE)" — 8 rules, memorize them
3. **`COMPOSER_SPEC.md`** — The complete Composer implementation plan with all 4 layers, data models, render engine, UI layout, starter presets, and build roadmap

## Step 2: Understand What Already Exists

Before creating anything new, read these existing files to understand the patterns:

| File | Why |
|------|-----|
| `HueHome/UI/Studio/StudioViewModel.swift` | Card catalog pattern, `RunningEffect` struct, `apply()`/`stopEffect()` — your new code plugs in here |
| `HueHome/UI/Studio/StudioView.swift` | Deck system, mixer tray, card grid — you're adding Deck 3 and extending the mixer |
| `HueHome/Core/Network/HueEntertainmentClient.swift` | DTLS streaming — `send(channels:)` is how CompositionEngine outputs frames |
| `HueHome/UI/Sync/SyncModeEngine.swift` | Render loop pattern — CADisplayLink + RestSender mailbox. Copy this pattern for CompositionEngine |
| `HueHome/UI/Studio/RoomPickerSheetView.swift` | How runningEffects are passed to sub-views |

## Step 3: Build Order (follow exactly)

### Phase 1 — Data Layer (no UI yet)
1. Create `HueHome/Core/Models/CompositionModels.swift`:
   - `PaletteConfig`, `MotionConfig`, `EnvelopeConfig`, `ReactionConfig` (all Codable)
   - `CompositionPreset` (Codable, Identifiable)
   - `PresetCategory` enum
   - `CodableColor` (CIE xy)

2. Create `HueHome/Core/Models/CompositionStore.swift`:
   - JSON persistence (load/save to Documents/compositions.json)
   - Built-in presets factory method

3. Add `StudioStrategy.composition(preset: CompositionPreset)` case to `StudioViewModel.swift`

### Phase 2 — Render Engine (no UI yet)
4. Create `HueHome/UI/Studio/CompositionEngine.swift`:
   - `render(time:lightCount:audioLevel:) -> [(x, y, brightness)]`
   - PaletteConfig.color(at phase:) — CIE xy output
   - MotionConfig.phase(lightIndex:total:time:) — 0.0–1.0 output
   - EnvelopeConfig.value(at time:) — brightness output
   - ReactionConfig.apply(baseBrightness:audioLevel:time:) — modified brightness

5. Wire into `UnifiedOrchestrator.swift`:
   - Handle `.composition` strategy in `startStudioMode()`
   - Create render loop (Timer or CADisplayLink at 25fps)
   - Route output to `HueEntertainmentClient.send()` or REST fallback

### Phase 3 — UI
6. Add Deck 3 to `StudioView.swift`:
   - Third page in TabView (deck dots go from `● ○` to `● ○ ○`)
   - `composerGrid()` method — "+ Create" button + saved composition cards
   - Category filter chips (All / Ambient / Energetic / Holiday / Mine)

7. Extend mixer tray in `StudioView.swift`:
   - Detect when running effect is `.composition` strategy
   - Show layer tabs: `[🎨 Palette] [🌊 Motion] [📈 Envelope] [🎤 React]`
   - Per-layer slider content (3-5 essential controls each)
   - Save button (💾) in mixer header

8. Create save flow:
   - Name input sheet
   - Icon picker (optional)
   - Persist via CompositionStore
   - New card appears on Deck 3

### Phase 4 — Starter Presets + Polish
9. 20 starter presets (5 ambient + 3 energetic + 12 holidays)
10. Seasonal auto-surfacing (month match → promote to top)
11. Long-press context menu on composition cards
12. Tab animations, haptics, waveform mini-preview

## Step 4: Key Patterns to Follow

### How existing cards work (copy this pattern):
```swift
// In StudioViewModel.apply():
case .bridgeNative(let effect):
    // 1. Set grouped light on+brightness
    // 2. Resolve light IDs from room
    // 3. Send per-light effect
    // 4. Store in runningEffects[room.id]

// For compositions, do:
case .composition(let preset):
    // 1. Create CompositionEngine with preset configs
    // 2. Start render loop (25fps entertainment or 5fps REST)
    // 3. Store in runningEffects[room.id] with isEntertainment based on transport
```

### How the mixer tray detects what to show:
```swift
// In StudioView.mixerTray:
let effect = vm.currentRoomEffect  // nil if nothing running on selected room
if let effect {
    let card = effect.card
    // Show card name, room name, LIVE indicator, stop button
    // Show param sliders based on card.params
    
    // NEW: if card.strategy is .composition:
    //   Show layer tabs instead of flat slider list
}
```

### How deck pages work:
```swift
// In StudioView.body → cardCarousel:
TabView(selection: $currentDeck) {
    deckGrid(cards: vm.effectCards, deckIndex: 0).tag(0)   // Effects
    deckGrid(cards: vm.liveModeCards, deckIndex: 1).tag(1)  // Live
    // ADD:
    composerGrid().tag(2)                                    // Composer
}
```

## Step 5: Verify After Each Phase

After each phase, run:
```bash
cd /Users/brianbean/Desktop/huehome-pro-v0.3.0
xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Commit after each successful phase build.

## Design Decisions Already Made (DO NOT RE-DECIDE)

1. ✅ Composer lives in mixer tray, NOT a separate full-screen sheet
2. ✅ Layer tabs (pill buttons), NOT collapsible sections
3. ✅ 20 starter presets with categories (ambient/energetic/holiday)
4. ✅ Auto-select Entertainment API when available, REST fallback
5. ✅ JSON file storage, NOT Core Data
6. ✅ Seasonal auto-surfacing based on `seasonMonths` field
7. ✅ Ship all 20 presets (not empty deck)
8. ✅ Sharing format designed now (Codable), sharing UI ships later (v0.18)
