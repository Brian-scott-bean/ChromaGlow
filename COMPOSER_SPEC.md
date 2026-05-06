# Composer — Dynamic Scene Creation Engine

Build any dynamic light experience from scratch. Same one-tap flow as every other Studio card.

---

## The Core Principle

Studio's promise is **one tap, you're live**. Composer doesn't break that. You tap "+ Create" and your lights are already moving. The mixer tray becomes a layered editor. Every slider change hits the lights in real time. When you like what you made, tap save. It becomes a card. Next time, one tap.

---

## How It Feels — The Complete Flow

### Creating (first time)

```
1. Swipe to Deck 3 (Composer)
2. Tap [+ Create]
   → Lights turn on immediately in a default state (soft warm breathe)
   → Mixer tray slides up with layer tabs
3. Tap layer tabs to explore: 🎨 Palette → 🌊 Motion → 📈 Envelope → 🎤 React
4. Drag sliders — lights respond live (40ms via DTLS, 200ms via REST)
5. Tap 💾 → name it → appears as a card on Deck 3
```

**Total taps to create:** 1 (start) + 3-8 (adjust) + 2 (save + name) = **6-11 taps**
**Total taps to use again:** 1

### Applying (saved composition)

```
1. Swipe to Deck 3
2. Tap "My Sunset" card
   → Lights apply that composition immediately
   → Mixer tray shows layer tabs with saved settings loaded
   → Adjust anything live, or just enjoy
```

**Identical to tapping Candle or Fire.** One tap. Done.

### Editing (modify saved)

```
1. Long-press a saved composition card
2. Context menu: Edit / Rename / Duplicate / Delete
3. "Edit" → applies the composition live + mixer tray opens with layer tabs
4. Modify any parameter → live
5. Tap 💾 to overwrite, or "Save As New" for a variant
```

---

## Mixer Tray — The Creation Surface

The mixer tray already exists for every Studio card. For Composer, it extends with **layer tabs** — a horizontal row of 4 pill buttons that switch which controls are visible.

### Layout

```
┌──────────────────────────────────────────────────┐
│  ✨ Composer        ● LIVE   [💾 Save]  [■ Stop] │  ← Header
│  Living Room • 3 rooms                            │  ← Room + count badge
├──────────────────────────────────────────────────┤
│  [🎨 Palette]  [🌊 Motion]  [📈 Envelope]  [🎤]  │  ← Layer tabs
├──────────────────────────────────────────────────┤
│                                                   │
│  Content for selected layer (3-5 controls):       │
│                                                   │
│  Pattern:  [Cascade] [Wave] [Scatter] [Bounce]    │  ← Horizontal pill row
│  ── Speed ─────────────────────── 40% ──          │  ← Slider
│  ── Spread ────────────────────── 70% ──          │  ← Slider
│                                                   │
│                              +3 more ▾            │  ← Advanced expand
└──────────────────────────────────────────────────┘
```

### Behavior

- **Layer tabs** are always visible at the top of the mixer content
- Tapping a tab **cross-fades** to that layer's controls (0.2s animation)
- Selected tab has a filled background pill; others are outlined
- Each layer shows its **essential controls** inline (3-5 max)
- "+N more ▾" reveals advanced controls in a bottom sheet (same pattern as existing param sheets)
- The tray **auto-sizes** to fit the visible controls (same `computeMixerHeight()` pattern)

### Layer Tab Content

#### 🎨 Palette (visible by default on first open)

**Essential (inline):**
| Control | UI | Range |
|---------|-----|-------|
| Mode | Pill row | `Solid` / `Gradient` / `Spectrum` / `Temperature` |
| Color 1 | Color circle tap → picker | Full CIE gamut |
| Color 2 | Color circle tap → picker | Full CIE gamut (hidden in Solid mode) |

**Advanced (+N more):**
| Control | UI | Range |
|---------|-----|-------|
| Color 3 | Color circle | Third accent color |
| Hue Shift | Slider | -180° to +180° (rotates entire palette) |
| Saturation | Slider | 0–100% |
| Temperature | Slider | 153–500 mirek (only in Temperature mode) |
| Randomize | Toggle | Each light picks randomly from palette per cycle |

#### 🌊 Motion

**Essential (inline):**
| Control | UI | Range |
|---------|-----|-------|
| Pattern | Pill row | `Static` / `Cascade` / `Wave` / `Scatter` / `Bounce` |
| Speed | Slider | 0–100% (maps to 0.1–20s per cycle) |
| Direction | Toggle pill | `→ Forward` / `← Reverse` |

**Advanced (+N more):**
| Control | UI | Range |
|---------|-----|-------|
| Spread | Slider | 0–100% (tight beam vs wide wash) |
| Offset | Slider | 0–100% (phase stagger between lights) |
| Mirror | Toggle | Pattern plays inward from both ends |

#### 📈 Envelope

**Essential (inline):**
| Control | UI | Range |
|---------|-----|-------|
| Shape | Pill row | `Steady` / `Breathe` / `Heartbeat` / `Pulse` / `Flicker` / `Swell` |
| BPM | Slider | 20–240 BPM |
| Depth | Slider | 0–100% (how deep brightness dips) |

**Advanced (+N more):**
| Control | UI | Range |
|---------|-----|-------|
| Attack | Slider | 0–100% (rise speed) |
| Decay | Slider | 0–100% (fall speed) |
| Duty Cycle | Slider | 10–90% (on-time ratio, for pulse/strobe shapes) |
| Min Brightness | Slider | 0–50% (floor) |
| Max Brightness | Slider | 50–100% (ceiling) |

#### 🎤 Reaction

**Essential (inline):**
| Control | UI | Range |
|---------|-----|-------|
| Source | Pill row | `None` / `Mic` / `Bass` / `Mid` / `Treble` / `Tap` |
| Sensitivity | Slider | 0–100% |
| Target | Multi-pill | `Brightness` / `Color` / `Speed` (which aspects react) |

**Advanced (+N more):**
| Control | UI | Range |
|---------|-----|-------|
| Smoothing | Slider | 0–100% (response lag) |
| Intensity | Slider | 0–100% (override strength) |
| Threshold | Slider | 0–100% (noise gate) |

---

## Deck 3: Composer Cards

### Layout

```
┌─────────────────────────────────────┐
│  [All] [Ambient] [Energetic] [Holiday] [Mine] │  ← Category filter chips
│                                     │
│  ┌──────────────────────────────┐   │
│  │          + Create            │   │  ← Prominent, full-width
│  │    Build your own effect     │   │     Gradient accent border
│  └──────────────────────────────┘   │
│                                     │
│  ┌──────────┐  ┌──────────┐         │
│  │ 🎄       │  │ 🎃       │         │  ← Cards show category emoji
│  │ Christmas│  │ Halloween│         │     or custom icon
│  │ Classic  │  │ Haunt    │         │
│  │ 🎨🌊📈  │  │ 🎨🌊📈  │         │
│  └──────────┘  └──────────┘         │
│                                     │
│  ┌──────────┐  ┌──────────┐         │
│  │ 🌅       │  │ 🎵       │         │
│  │ Sunset   │  │ Bass     │         │
│  │ Cascade  │  │ Drop     │         │
│  │ 🎨🌊📈  │  │ 🎨🌊🎤  │         │
│  └──────────┘  └──────────┘         │
│                                     │
└─────────────────────────────────────┘
```

- `+ Create` card is always first, spans full width, has a gradient shimmer border
- **Category filter chips** scroll horizontally above the grid: All / Ambient / Energetic / Holiday / My Creations
- "Holiday" chip automatically highlights when the current month matches a preset's `seasonMonths`
- Saved compositions render as normal `StudioCardView` (same size, style, animations)
- Layer activity icons (🎨🌊📈🎤) shown as small dots/icons at bottom of card
- Tap = apply. Long-press = Edit/Rename/Duplicate/Delete context menu
- Cards are room-scoped via multi-room effects (already built)

### Starter Presets (ship with app)

Organized into browsable categories. Filter chips at top of Deck 3 let users browse by mood.

#### 🌙 Ambient
| Name | Palette | Motion | Envelope | Reaction |
|------|---------|--------|----------|----------|
| Sunset Cascade | Amber → Deep Red gradient | Cascade, slow | Breathe, 40 BPM | None |
| Ocean Drift | Teal → Deep Blue gradient | Wave, medium | Swell, 30 BPM | None |
| Northern Lights | Green → Purple gradient | Wave, slow | Breathe, 20 BPM | None |
| Cozy Evening | Warm temp (400 mirek) | Static | Breathe, 24 BPM, 20% depth | None |
| Heartbeat | Warm white solid | Static | Heartbeat, 72 BPM | None |

#### ⚡ Energetic
| Name | Palette | Motion | Envelope | Reaction |
|------|---------|--------|----------|----------|
| Bass Drop | Purple → Cyan spectrum | Scatter, fast | Pulse, 128 BPM | Bass, high sensitivity |
| Club Mode | Full spectrum | Cascade, fast | Pulse, 140 BPM | Mic amplitude |
| Storm Chase | Cool white → Blue | Scatter, medium | Flicker | Mic treble |

#### 🎄 Holidays
| Name | Palette | Motion | Envelope | Season |
|------|---------|--------|----------|--------|
| Christmas Classic | Red + Green gradient | Cascade, slow | Breathe, 30 BPM | Dec |
| Winter Wonderland | Ice Blue + White gradient | Wave, slow | Swell, 24 BPM, 15% depth | Dec-Feb |
| Halloween Haunt | Orange + Purple gradient | Scatter, medium | Flicker, deep | Oct |
| Valentine's Glow | Red + Pink gradient | Static | Heartbeat, 60 BPM | Feb |
| 4th of July | Red + White + Blue spectrum | Cascade, fast | Pulse, 120 BPM | Jul |
| St. Patrick's | Green shades gradient | Wave, medium | Breathe, 40 BPM | Mar |
| Easter Pastels | Pastel pink + lavender + mint spectrum | Wave, slow | Breathe, 30 BPM | Apr |
| Hanukkah | Blue + White gradient | Cascade, slow | Swell, 30 BPM | Dec |
| Diwali | Gold + Deep Orange gradient | Scatter, medium | Flicker, warm | Oct-Nov |
| New Year's Eve | Gold + Silver spectrum | Cascade, fast | Pulse, 140 BPM | Dec 31 |
| Thanksgiving | Warm Amber + Deep Red gradient | Static | Breathe, 24 BPM, 20% depth | Nov |
| Mardi Gras | Purple + Gold + Green spectrum | Cascade, fast | Pulse, 120 BPM | Feb-Mar |

**Total: 20 starter presets** (5 ambient + 3 energetic + 12 holidays)

All marked with `isBuiltIn: true`. Users can modify (creates a copy), duplicate, or "Reset to Default" — never permanently delete.

> [!TIP]
> The app could surface seasonal presets automatically — show "Halloween Haunt" prominently in October, "Christmas Classic" in December. A simple `season` field on the preset enables this with zero runtime cost.

---

## Data Model

### CompositionPreset

```swift
struct CompositionPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var icon: String              // SF Symbol name
    var accentColorHex: String    // Card accent color
    var isBuiltIn: Bool           // Starter presets can't be fully deleted
    var category: PresetCategory  // For browsing/filtering
    var seasonMonths: [Int]?      // e.g. [10] for October, [12, 1, 2] for winter
    
    var palette: PaletteConfig
    var motion: MotionConfig
    var envelope: EnvelopeConfig
    var reaction: ReactionConfig
    
    var createdAt: Date
    var updatedAt: Date
}

enum PresetCategory: String, Codable, CaseIterable {
    case all        // Virtual — shows everything (filter chip only)
    case myCreations = "My Creations"
    case ambient    = "Ambient"
    case energetic  = "Energetic"
    case holiday    = "Holiday"
}
```

### Layer Configs

```swift
struct PaletteConfig: Codable {
    enum Mode: String, Codable { case solid, gradient, spectrum, temperature }
    var mode: Mode = .solid
    var color1: CodableColor = .init(x: 0.45, y: 0.41)  // warm white
    var color2: CodableColor = .init(x: 0.31, y: 0.33)  // cool white
    var color3: CodableColor?
    var hueShift: Double = 0       // -180 to 180
    var saturation: Double = 100   // 0-100
    var temperature: Int = 366     // 153-500 mirek
    var randomize: Bool = false
}

struct MotionConfig: Codable {
    enum Pattern: String, Codable, CaseIterable {
        case `static`, cascade, wave, scatter, bounce
    }
    var pattern: Pattern = .static
    var speed: Double = 40         // 0-100
    var forward: Bool = true
    var spread: Double = 70        // 0-100
    var offset: Double = 50        // 0-100
    var mirror: Bool = false
}

struct EnvelopeConfig: Codable {
    enum Shape: String, Codable, CaseIterable {
        case steady, breathe, heartbeat, pulse, flicker, swell
    }
    var shape: Shape = .breathe
    var bpm: Double = 60           // 20-240
    var depth: Double = 50         // 0-100
    var attack: Double = 50        // 0-100
    var decay: Double = 50         // 0-100
    var dutyCycle: Double = 50     // 10-90
    var minBrightness: Double = 10 // 0-50
    var maxBrightness: Double = 100 // 50-100
}

struct ReactionConfig: Codable {
    enum Source: String, Codable, CaseIterable {
        case none, micAmplitude, micBass, micMid, micTreble, tapTempo
    }
    enum Target: String, Codable { case brightness, color, speed }
    var source: Source = .none
    var sensitivity: Double = 70   // 0-100
    var targets: Set<Target> = [.brightness]
    var smoothing: Double = 30     // 0-100
    var intensity: Double = 70     // 0-100
    var threshold: Double = 10     // 0-100
}

struct CodableColor: Codable {
    var x: Double  // CIE 1931
    var y: Double
}
```

### Storage

```swift
// Simple JSON file in app documents directory
// ~/Documents/compositions.json
// Array of CompositionPreset
// Load on app launch, save on every create/edit/delete
```

No Core Data. Compositions are ~500 bytes each. Even 100 compositions = 50KB.

---

## Render Engine

### CompositionEngine

```swift
/// Conforms to the same pattern as SyncModeEngine's render loop.
/// Called at 25fps (entertainment) or 5fps (REST fallback).
final class CompositionEngine {
    
    var palette: PaletteConfig
    var motion: MotionConfig
    var envelope: EnvelopeConfig
    var reaction: ReactionConfig
    
    /// Compute the output for all lights at the given time.
    func render(time: Double, lightCount: Int, audioLevel: Float) 
        -> [(x: Double, y: Double, brightness: Double)] 
    {
        (0..<lightCount).map { index in
            // 1. Motion: where is this light in the cycle?
            let phase = motion.phase(lightIndex: index, total: lightCount, time: time)
            
            // 2. Palette: what color at this phase position?
            let (x, y) = palette.color(at: phase)
            
            // 3. Envelope: what brightness at this time?
            var bri = envelope.value(at: time)
            
            // 4. Reaction: modify based on audio/input
            bri = reaction.apply(baseBrightness: bri, audioLevel: audioLevel, time: time)
            
            return (x: x, y: y, brightness: bri)
        }
    }
}
```

### Transport Wiring

```
CompositionEngine.render()
        │
        ▼
   ┌────────────────┐
   │ Has DTLS?      │
   │                │
   ├─ Yes ──────────┼──→ HueEntertainmentClient.send(channels:)
   │                │     25fps, per-light color+brightness
   │                │
   └─ No ───────────┼──→ RestSender.enqueue { setGroupedLightEffect() }
                    │     5fps, group-level brightness only
                    │     Color set once at start (not per-frame)
```

### Integration with StudioViewModel

```swift
// New strategy case:
enum StudioStrategy {
    case bridgeNative(effect: String)
    case appDriven(engineKey: String)
    case composition(preset: CompositionPreset)  // NEW
}
```

When a composition card is tapped:
1. `apply()` detects `.composition` strategy
2. Creates `CompositionEngine` with the preset's 4 layer configs
3. Starts render loop (same pattern as `runStrobeEntertainment`)
4. Stores in `runningEffects[room.id]` (multi-room compatible)
5. Mixer tray shows layer tabs instead of standard sliders

When a slider is dragged:
1. Layer config property updated in memory
2. Next render frame (≤40ms) reads the new value
3. Lights respond immediately
4. No bridge command needed — the render loop IS the command

---

## Integration with Existing StudioView

### What Changes

| Component | Current | With Composer |
|-----------|---------|---------------|
| Deck count | 2 (Effects, Live) | 3 (Effects, Live, Composer) |
| Deck dots | `● ○` | `● ○ ○` |
| Mixer tray header | Card name + LIVE + Stop | Same + Save button (for compositions) |
| Mixer tray content | Flat slider list | Layer tabs → per-layer sliders |
| Card grid (Deck 3) | N/A | `+ Create` button + saved composition cards |
| `StudioCard` model | `strategy: bridgeNative/appDriven` | + `composition(preset:)` |
| `StudioCardView` | Icon + name + tagline | Same + layer activity dots for compositions |

### What Doesn't Change

- Room picker (swipeable nav title)
- Multi-room effects system
- Animation tokens, spacing, design language
- Card tap/apply/stop flow
- Param value storage pattern
- Entertainment area badges

---

## Constraints & Edge Cases

| Constraint | Impact | Mitigation |
|------------|--------|------------|
| Max 10 lights per entertainment area | Composer via DTLS limited to 10 | Show light count. REST fallback for overflow. |
| Entertainment requires foreground | Composition stops when backgrounded | "Keep app open" toast. Save state for quick resume on return. |
| DTLS session setup ~200ms | Slight delay on first Play | Warm up session on Deck 3 appear, not on tap. |
| Only 1 DTLS session at a time | Can't compose + Strobe simultaneously | Auto-stop other entertainment effects (existing logic). |
| REST fallback = lower fidelity | No per-light color via REST, brightness-only | Show "🔌 REST mode" indicator. Motion layer degrades to uniform. |
| Mic permission required for Reaction | User must approve mic access | Show permission prompt only when Reaction source ≠ none. Tap Tempo needs no mic. |
| Bridge-native effects are black boxes | Can't use candle/fire/sparkle inside Composer | Composer always renders its own math. Equivalent results via Envelope flicker shape. |
| Color gamut varies by bulb | Some bulbs can't display all colors | Clamp to reported gamut triangle (data available in light resource). |

---

## Open Questions

> [!IMPORTANT]
> **Starter presets — ship 20 or trim?** Recommendation: Ship all 20. Categories + filter chips keep it organized. The Holiday section alone is a marketing differentiator that no competitor has.

> [!IMPORTANT]  
> **Transport auto-select or user choice?** Recommendation: Auto-select Entertainment when available. Show small indicator (`⚡ Streaming` vs `🔌 REST`) so the user knows. No manual toggle needed for v1.

> [!IMPORTANT]
> **Sharing format — build now or later?** Recommendation: Design `CompositionPreset` as Codable now (already done above). Sharing UI (export as link/QR) ships in v0.18. Zero extra work needed now, clean extension point later.

> [!IMPORTANT]
> **Seasonal auto-surfacing — auto-promote holiday presets?** Recommendation: Yes. When the current month matches a preset's `seasonMonths`, surface it at the top of the grid with a subtle seasonal banner (e.g., "🎄 'Tis the Season"). Low effort, high delight.

---

## Build Roadmap

| # | Component | Days | Depends On |
|---|-----------|------|------------|
| 1 | Config models (`PaletteConfig`, `MotionConfig`, `EnvelopeConfig`, `ReactionConfig`) | 0.5 | — |
| 2 | `CompositionEngine` (render loop + layer math) | 2 | #1 |
| 3 | `CompositionPreset` + `PresetCategory` + JSON persistence | 0.5 | #1 |
| 4 | `StudioStrategy.composition` + apply/stop wiring | 1 | #2, #3 |
| 5 | Deck 3 grid (+ Create card + saved cards + category chips) | 1.5 | #3 |
| 6 | Layer tabs in mixer tray | 1.5 | #4 |
| 7 | Per-layer slider content (Palette, Motion, Envelope, Reaction) | 1.5 | #6 |
| 8 | Save flow (name + icon + category picker + persist) | 0.5 | #3, #7 |
| 9 | Audio reactivity wiring (mic tap → Reaction layer) | 1 | #2 |
| 10 | 20 starter presets (5 ambient + 3 energetic + 12 holidays) | 1 | #3 |
| 11 | Seasonal auto-surfacing (month match → promote to top) | 0.5 | #10 |
| 12 | Long-press context menu (Edit, Rename, Duplicate, Delete) | 0.5 | #5, #8 |
| 13 | Polish: tab animations, haptics, waveform mini-preview | 1 | #7 |
| **Total** | | **~12.5 days** | |

### Phase 1 (MVP — usable): Items 1-8 = ~9 days
Create, tune, save, apply compositions. Entertainment + REST transport. Category filter.

### Phase 2 (Complete): Items 9-13 = ~3.5 days
Audio reactivity, 20 starter presets, holiday themes, seasonal surfacing, edit flow, polish.

---

## Verification Plan

### Manual Testing
1. Tap "+ Create" → verify lights turn on in default state immediately
2. Switch all 4 layer tabs → verify controls swap smoothly
3. Drag every slider type → verify live light response
4. All 5 motion patterns → verify spatial distribution across lights
5. All 6 envelope shapes → verify brightness animation
6. Mic reaction → verify lights respond to sound
7. Save → verify card appears on Deck 3
8. Tap saved card → verify identical behavior to original
9. Long-press → Edit → modify → Save → verify update persists
10. Multi-room: composition on Kitchen + Candle on Bedroom → both run
11. Background app → verify graceful stop + state save
12. Kill app → relaunch → verify saved compositions persist
13. REST fallback (no entertainment config) → verify degraded-but-working

### Automated
- `xcodebuild build` — clean compile
- JSON round-trip: encode → decode `CompositionPreset` → assert field equality
- Performance: Instruments → verify <2ms/frame render cost
