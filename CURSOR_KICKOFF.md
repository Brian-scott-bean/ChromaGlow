# Cursor Kickoff — Composer Feature (v0.17.0)

> **Phase 1+2 are DONE. Phase 3+4 are YOUR job.**
> The data models, render engine, preset store, and orchestrator integration are built, compiled, and committed. You only need to build the UI.

## Step 1: Read These Files First (DO NOT SKIP)

Read these 3 files completely before writing any code:

1. **`.cursorrules`** — Critical architecture rules that MUST NOT be violated
2. **`DEVDOC.md`** — Full development history. Focus on:
   - "Session Log: 2026-05-05 (night)" — Multi-room concurrent effects + Composer engine
   - "Composer Feature — Complete Technical Design" — The full spec
   - "Key Architecture Rules (DO NOT VIOLATE)" — 8 rules, memorize them
3. **`COMPOSER_SPEC.md`** — The complete implementation plan

## Step 2: Understand What's ALREADY BUILT (Do NOT recreate)

These files exist and are fully working. **Read them, don't rewrite them:**

| File | What It Does | Status |
|------|-------------|--------|
| `HueHome/Core/Models/CompositionModels.swift` | `PaletteConfig`, `MotionConfig`, `EnvelopeConfig`, `ReactionConfig`, `CodableColor`, `CompositionPreset`, `PresetCategory` — all Codable with full render math | ✅ DONE |
| `HueHome/Core/Models/CompositionStore.swift` | JSON persistence, 20 built-in presets (5 ambient + 3 energetic + 12 holidays), seasonal auto-surfacing, CRUD operations | ✅ DONE |
| `HueHome/UI/Studio/CompositionEngine.swift` | Pure render engine: `CompositionEngine.render(time:channelIDs:params:audioLevel:)` → `[LightFrame]`. `CompositionParamBox` for live slider updates | ✅ DONE |
| `HueHome/UI/Studio/StudioViewModel.swift` | `StudioStrategy.composition(presetID:)`, `composerStudioCards` computed property, `compositionStore`, `activeCompositionBox`, composition apply/stop in `apply()` and `stopEffect()` | ✅ DONE |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | `startCompositionMode(room:paramBox:)` with dual-transport render loops: Entertainment DTLS at 25fps or REST fallback at 5fps | ✅ DONE |

## Step 3: What YOU Need to Build (UI Only)

### Phase 3 — UI (this is your starting point)

**3A. Add Deck 3 to `StudioView.swift`:**
- Third page in the existing deck TabView
- Deck dots go from `● ○` to `● ○ ○`
- `composerGrid()` method with:
  - Category filter chips at top (All / Ambient / Energetic / Holiday / My Creations) — use `PresetCategory.allCases`
  - "+ Create" button — full-width, gradient shimmer border
  - Saved composition cards from `vm.composerStudioCards` — same card style as Deck 1+2
  - Seasonal presets promoted to top when in season (`preset.isInSeason`)
- Long-press on composition cards → Edit / Rename / Duplicate / Delete context menu

**3B. Extend mixer tray for compositions:**
- Detect composition: `if case .composition = effect.card.strategy { ... }`
- Show 4 layer tabs as horizontal pills: `[🎨 Palette] [🌊 Motion] [📈 Envelope] [🎤 React]`
- Each tab shows 3-5 essential sliders for that layer
- Sliders write directly to `vm.activeCompositionBox` — lights respond next frame (≤40ms)
- Save button (💾) in mixer header → name input → `vm.compositionStore.save(preset)`

**3C. Layer tab controls (what sliders to show per tab):**
```
🎨 Palette:  Mode picker (solid/gradient/spectrum/temperature)
             Color 1 picker, Color 2 picker
             Hue Shift slider (spectrum mode only)
             Saturation slider

🌊 Motion:   Pattern picker (static/cascade/wave/scatter/bounce)
             Speed slider (0-100)
             Direction toggle (forward/reverse)
             Offset slider (0-100)

📈 Envelope: Shape picker (steady/breathe/heartbeat/pulse/flicker/swell)
             BPM slider (20-240)
             Depth slider (0-100)
             Min Brightness slider (0-50)
             Max Brightness slider (50-100)

🎤 React:    Source picker (none/mic/bass/mid/treble/tap)
             Sensitivity slider (0-100)
             Threshold slider (0-100)
             Intensity slider (0-100)
```

**3D. Save flow:**
- Tap 💾 → sheet with name text field + optional icon picker (SF Symbol grid)
- Create `CompositionPreset` from current `activeCompositionBox` values
- `vm.compositionStore.save(preset)` → new card appears on Deck 3
- Category defaults to `.myCreations`

### Phase 4 — Polish
- Tab switch animations (cross-fade between layer controls)
- Haptic feedback on tab tap (`HapticManager.shared.light()`)
- Seasonal banner at top of Deck 3 when holiday presets are in season
- Layer activity dots on composition cards (show which layers are non-default)

## Key Code Patterns

### How to write to the live composition box (sliders → lights):
```swift
// When user drags a slider:
vm.activeCompositionBox?.palette.saturation = newValue
// That's it. The render loop reads the box each frame (25fps or 5fps).
// No debounce, no API call, no param update method needed.
```

### How to detect composition strategy in mixer:
```swift
if case .composition(let presetID) = effect.card.strategy {
    // Show layer tabs
    let preset = vm.compositionStore.presets.first { $0.id == presetID }
    // ...
}
```

### How deck pages currently work (add Deck 3 here):
```swift
// In StudioView.body → cardCarousel:
TabView(selection: $currentDeck) {
    deckGrid(cards: vm.effectCards, deckIndex: 0).tag(0)   // Effects
    deckGrid(cards: vm.liveModeCards, deckIndex: 1).tag(1)  // Live
    // ADD:
    composerGrid().tag(2)                                    // Composer
}
```

## Verify After Each Change

```bash
PROJ=/Users/brianbean/Desktop/huehome-pro-v0.3.0
xcodebuild -project "$PROJ/HueHome.xcodeproj" -scheme HueHome -destination 'generic/platform=iOS' build 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

## Design Decisions Already Made (DO NOT RE-DECIDE)

1. ✅ Composer lives in mixer tray, NOT a separate full-screen sheet
2. ✅ Layer tabs (pill buttons), NOT collapsible sections
3. ✅ 20 starter presets with categories — already built and shipping
4. ✅ Auto-select Entertainment API when available, REST fallback — already wired
5. ✅ JSON file storage, NOT Core Data — already implemented
6. ✅ Seasonal auto-surfacing based on `seasonMonths` field — already in model
7. ✅ Sharing format designed (Codable), sharing UI ships later (v0.18)
8. ✅ Slider writes go directly to `CompositionParamBox` — NO debounce, NO API calls
