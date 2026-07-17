# ChromaGlow Sequence Builder — Design Specification

**"Chapters" — step-programmed light sequences, from grandma to lighting designer**

- **Status:** DESIGN ONLY (2026-07-17). Brian approved producing this spec as a side deliverable
  of the world-class-polish program; implementation Phases 1–3 are explicitly deferred until his
  go-ahead. Open questions for Brian are in §11.
- **Author:** Claude (design agent pass grounded in source; every architectural claim cites the
  file it was verified against).
- **Related:** the polish program plan (builds 29–33); `COMPOSER_SPEC.md` (historical composer
  behavior); DEVLOG builds 18–28 durable facts.

---

## 1. Vision

ChromaGlow already has the best per-moment look engine in the category — four composable layers
rendered at 25fps with real spatial awareness — and it already has a *hidden* sequencer:
`CompositionSequence` steps driven by `SequencePlayer` through the Perform surface's A/B mixer
(`HueHome/Core/Composer/SequencePlayer.swift`, `HueHome/Core/Composer/CompositionMixer.swift`).
Sequence Builder promotes that buried DJ feature into the app's flagship: a step-timeline editor
where every step is a *complete captured look* (color + brightness + hold behavior), every
transition is a first-class object (cut, fade, spatial sweep, scatter, random — the sweep being
something no competitor can do because no competitor knows where your lights *are*), and every
sequence is honest about where it can run (bridge-stored and app-closed, app-driven REST, or
streamed at 25fps). A novice picks "Lava Lamp," drags one Speed slider, and taps play; an expert
opens any step into the full four-layer Composer mixer and edits its throb rate to the BPM. One
model, one player, one render chokepoint — no parallel systems. iConnectHue caps out at 8 bridge
steps with three fade types; we match that ceiling *on the bridge tier* and then blow past it
everywhere else, while a filmstrip scrubber lets you drag a playhead and watch the show on your
actual lights like scrubbing a video.

---

## 2. The one big architectural decision (read this first)

There must not be a second sequence system. The codebase already contains:

- `CompositionSequence` — steps holding all four layer configs inline, `bars` hold +
  `crossfadeBeats` fade, `loops` bool (`SequencePlayer.swift:16-77`), persisted as the additive
  `CompositionPreset.sequence` field (`CompositionModels.swift:679`, lenient decode at `:763`),
  already traveling in share QR payloads (`ScenePayloadCodec.swift:43`) and already compared by
  the seed migrator (`BuiltInSeedMigrator.swift:99`).
- `SequencePlayer` — hold → cue deck B → bar-aligned auto-fade → promote, driving the same
  `PerformanceMixBox` both orchestrator render loops already consult when
  `mix.deckA === paramBox` (`UnifiedOrchestrator.swift:2848-2856` DTLS, `:3054-3064` REST).

**Sequence Builder is the graduation of this system, not a sibling.** We extend
`CompositionSequence` with additive fields (a `seconds` timing mode, transition specs, loop
modes), extend `PerformanceMixBox`/`CompositionMixer` with per-light transition programs, extend
`SequencePlayer` with wall-clock holds, and build a real editor. The Perform surface's existing
bars-based sheet (`PerformanceView.swift:485-583`) becomes a thin client of the same editor
components in "musical time" mode. Steps stay self-contained captures — deleting a source preset
can never break a sequence, exactly as the Round 3 comment promises (`SequencePlayer.swift:4-6`).

The second key insight: **hold behaviors are not new engine features.** A step already carries
`EnvelopeConfig` and `MotionConfig`, so:

| Brian's words | What the step stores | Engine code that renders it |
|---|---|---|
| "hold that color" (steady) | `envelope.shape = .steady` | `EnvelopeConfig.value` (`CompositionModels.swift:452-453`) |
| "hold as a throb motion" | `envelope.shape = .breathe` (or `.pulse`) at rate N BPM | `:455-460` / `:471-477` |
| shimmer | `motion.pattern = .twinkle` | `MotionConfig.sample` (`:361-376`) |
| flicker (candle/fire) | `envelope.shape = .flicker` | `:479-487` |

The novice UI presents these as four "Hold style" chips plus one rate slider; a small pure
`HoldStyleMapper` reads/writes the underlying layer configs (same derived-never-stored philosophy
as `PresetSurfaceClassifier.swift:10-12`). Experts bypass the chips and edit the layers directly.
Nothing new to render, nothing new to migrate.

---

## 3. UX walkthrough

### 3.1 Where it lives

- **No fourth deck.** Sequences are composition presets (they already are — `preset.sequence`),
  so they live on the existing Composer deck (`StudioView.swift:95`, decks paged at `:569-583`)
  and cross-file onto the Effects/Live decks by classifier exactly like other creations
  (`StudioViewModel.swift:1596-1604`). A sequence card gets a **`SEQ · 5 STEPS`** `StageBadge`
  and a step-dot strip on its canvas (extending the layer-activity row at `StudioView.swift:1655`).
- **Tapping a sequence card plays the sequence.** This is opinionated and correct: if you attached
  a program, the program *is* the preset. `StudioViewModel.apply` (composition branch,
  `StudioViewModel.swift:1219-1319`) starts the base composition as today, then auto-starts a
  `SequenceSession` when `preset.sequence?.steps.isEmpty == false`. Stop flows through the
  existing chokepoints untouched (`stopEffect` case `.composition` at `:1358-1368`,
  `explicitStop` `:1377`, `stopFromNowPlaying` `:626`).
- **Editing** opens **Sequence Studio**, a full-screen cover (Perform's presentation grammar,
  `StudioView.swift:112`), reached from:
  1. Mixer tray header — a new circle button (`timeline.selection` icon) beside the Perform
     button (`MixerTrayView.swift:133-163` is the pattern to clone);
  2. Composer card context menu — "Edit Sequence…" / "Add Sequence…" (inserted in the menu at
     `StudioView.swift:1339-1399`);
  3. Template gallery from `+ Create`.
- StudioView's body is at the type-checker ceiling, so all new presentation state wires through a
  new `StudioSequenceWiring: ViewModifier`, cloning the `StudioDrainWiring` pattern
  (`StudioView.swift:1788-1825`) — never new modifiers on the body itself.

### 3.2 Novice path — "grandma ships a light show in 90 seconds"

**Screen 1 — Template gallery** (first entry, and always available behind a "Templates" button).
A 2-column grid of template cards on `StagePalette.stage`, each with an *animated filmstrip
preview* (pure-math, 12fps `TimelineView`, paused by `\.isTabActive` and Reduce Motion — the
`PatternStripView` contract at `StageKit.swift:629-632`). Cards: Lava Lamp, Sunrise Alarm,
Thunderstorm, Party Loop, etc. (§7). Tap one → Screen 2.

**Screen 2 — Simple mode.** The template opens with exactly three controls above the filmstrip:

1. **Colors** — a `StageColorSwatchRow` of the template's key colors (`StageKit.swift:410-444`);
   tapping a swatch opens the shared gamut-clamped `HueSaturationPad` (`StageKit.swift:210`).
   Recoloring rewrites every step's palette through the template's color-role map (each template
   tags its steps with roles: "base", "accent", "flash").
2. **Speed** — one `StageSlider` (0.25×–4×) that scales *all* holds and transitions
   proportionally. Readout shows the honest total: "LOOP 48s".
3. **Mood** — Bright / Soft / Night chips scaling `envelope.maxBrightness` and depth across steps.

Below: a big amber **"Try it on [Living Room]"** play/stop button (the iConnectHue
start/stop-test move, but full-width and 54pt), and **Save** — which files it to My Creations via
the existing save-sheet flow (`StudioView.swift:1429+`). A quiet "All steps ▸" link at the bottom
is the single door to expert mode. Progressive disclosure, same doctrine as
`ComposerControlCatalog` (`ComposerLayerSheet.swift:21`).

**That is the whole novice surface.** Three controls, one play button, one save.

### 3.3 Expert path — Sequence Studio

Full-screen, no scroll of the root (Perform's rule), three zones:

**Zone A — Header.** Sequence name; mono total-time readout (`LOOP 24.5s · 5 STEPS`);
transport-honesty badge (`BRIDGE ⚡` / `ENT AREA` / `ROOM · REST` — the exact grammar of
`MixerTrayView.swift:534-540`, which Round C's TransportVocabulary consolidation will rename
program-wide); Play/Stop test circle; Close.

**Zone B — The Filmstrip.** The signature element. A horizontal strip where each step is a color
block whose *width is proportional to hold time*, with transition wedges drawn between blocks (a
gradient ramp for fades; a slanted ramp for sweeps; stippled for scatter/random). During test
playback an amber playhead sweeps it with haptic ticks at step boundaries. **Drag the playhead to
scrub the show on the real lights** — renders `sequenceFrame(at: t)` through the live box using
`triggerRESTBurst()` pacing (`CompositionEngine.swift:86-89`), throttled to ≤3 changes/sec (§8).
Nobody else has this.

**Zone C — Step list.** A vertical `List` of step cards (drag `.onMove`, swipe `.onDelete` —
already proven in the Perform sheet at `PerformanceView.swift:522-523`). Each collapsed card, one
60pt row, all targets ≥44pt:

```
≡  [◉◉◉ swatches]  Step 2 · "Ember"        [2.0s ●]  [~1.5s ▸]
    throb 40 BPM · 65%                      hold      fade-next
```

- Swatch stack = the step's up-to-3 palette stops.
- Hold chip and transition chip are tappable; durations are `StageSlider`s in the expanded card
  with **tap-to-type exact values** via the existing readout-flip (`StageKit.swift:103-197`) —
  "3 seconds means 3.0, not somewhere around there."
- Tap a card → it expands inline to the novice per-step controls: color pad, Brightness slider,
  **Hold style** chips (Steady / Throb / Shimmer / Flicker + Rate slider when animated), Hold
  duration, **Transition** chips (Cut / Fade / Sweep / Scatter / Random) + Fade seconds + (for
  staggered kinds) Spread seconds + direction toggle.
- "Edit look in Mixer" inside the expanded card opens the full `CompositionEditorPanel` against a
  temporary `CompositionParamBox` seeded from the step — the *entire* Composer (harmony rules,
  motion patterns, reaction sources) becomes a per-step editor with zero new controls built.
- Footer row: **Add Step** (duplicates the last step — the dominant authoring gesture),
  **Capture Live Look** (visible when a composition is running; clone of `captureCurrentStep`,
  `PerformanceView.swift:170-177`), and **Loop** chips:
  `∞ · ×N · Ping-pong · Hold end · Off at end`.

Everything renders from StageKit atoms: `StageCard`, `StageSlider`, `StageBadge`,
`StageToggleRow`, `StageSheetScaffold` for sub-sheets. One-handed reach: all editing happens in
the bottom two-thirds; the filmstrip is display/scrub only.

### 3.4 Brian's script, as the user experiences it

> Pick Living Room on the rolodex → `+ Create` → "Start from scratch" → Step 1 appears (current
> room color). Tap it: drag pad to deep blue, Brightness 80, Hold style Steady, Hold 2.0s,
> Transition Fade 3.0s. Add Step → pad to magenta, Hold 2.0s, Transition Fade 1.0s. Add Step →
> pad to amber, Hold style **Throb**, Rate 45 BPM, Hold 5.0s, Transition Sweep 2.0s. Loop ∞. Tap
> "Try it on Living Room." The room fades 3s to blue, holds 2s, fades 1s to magenta, holds,
> sweeps left-to-right into a 5-second amber throb, loops. Save as "My First Sequence" — it lands
> on the Composer deck with a SEQ badge, Siri can start it by name tomorrow.

---

## 4. Data model

All additive on the existing types; every new field decodes with a fallback per the M-13
convention (`CompositionModels.swift:104-118`), so pre-sequencer libraries and old Perform-made
sequences load unchanged.

```swift
// SequencePlayer.swift — evolved CompositionSequence (all fields additive)
struct CompositionSequence: Codable, Equatable {

    enum TimingMode: String, Codable { case bars, seconds }
    // Decode fallback .bars — every existing Perform sequence keeps its meaning.

    enum LoopMode: String, Codable {
        case forever      // legacy loops == true
        case count        // loop N times, then holdEnd behavior
        case pingPong     // A→B→C→B→A→…
        case holdEnd      // legacy loops == false: play once, hold last step
        case offEnd       // play once, then fade the room off (fadeOffSeconds)
    }

    var steps: [Step] = []
    var loops = true                      // legacy field, kept encoded
    var timingMode: TimingMode = .bars    // Sequence Builder writes .seconds
    var loopMode: LoopMode = .forever     // decode fallback: loops ? .forever : .holdEnd
    var loopCount: Int = 2                // used by .count
    var fadeOffSeconds: Double = 3        // used by .offEnd

    struct Step: Codable, Equatable, Identifiable {
        // ── existing, unchanged ──
        var id: UUID; var name: String
        var palette: PaletteConfig; var motion: MotionConfig
        var envelope: EnvelopeConfig; var reaction: ReactionConfig
        var bars: Int; var crossfadeBeats: Int          // musical-time fields
        // ── new, additive ──
        var holdSeconds: Double = 4                     // wall-clock hold (timingMode .seconds)
        var transition: TransitionSpec = TransitionSpec()
    }

    /// How this step hands off to the NEXT step.
    struct TransitionSpec: Codable, Equatable {
        enum Kind: String, Codable {
            case cut        // instant
            case fade       // all lights together (iConnectHue "Normal")
            case sweep      // per-light start offset ordered by spatialPositions (beats "Progressive")
            case scatter    // per-light start offset by stable index order
            case random     // per-light start offset by deterministic hash (fire-style)
        }
        var kind: Kind = .fade
        var seconds: Double = 1.5          // per-light fade length (0…3600, slider 0–60s, tap-to-type beyond)
        var spreadSeconds: Double = 0      // total window over which per-light starts stagger
        var reverse: Bool = false          // sweep direction flip
    }

    // Derived, never stored (mirrors capabilityTier / PresetSurfaceClassifier):
    var totalLoopSeconds: Double { /* Σ hold + transition per step, timing-mode aware */ }
    var requiresMic: Bool { steps.contains { $0.reaction.requiresMic } }
}
```

```swift
// New pure helper — HoldStyleMapper.swift (derived from layers, never stored)
enum HoldStyle: String, CaseIterable { case steady, throb, shimmer, flicker }

enum HoldStyleMapper {
    static func style(of step: CompositionSequence.Step) -> HoldStyle
    /// Writes envelope/motion for the chosen style; `rateBPM` clamps ≤170 (§8).
    static func apply(_ style: HoldStyle, rateBPM: Double, to step: inout CompositionSequence.Step)
}
```

**Targets:** sequence-scoped, resolved at apply time — a sequence targets whatever room/zone it
is applied to, like every composition (rolodex + `roomOverride` at `StudioViewModel.swift:1009`).
Per-step *device* lists are rejected (they would break room-agnostic presets, sharing, and
templates); per-step *spatial masks* (All / Left / Right / Center / Edges, computed from
`spatialPositions`) are the portable answer, deferred to Phase 3 (§10).

**Brightness per step** is `envelope.maxBrightness` — no duplicate field, no sync bug.

**Serialization safety:** encode adds keys; decode falls back; `FailableDecodable` element-wise
reads (`CompositionStore.swift:200`) mean one bad step can never drop the library; the
create-only seed and migrator are untouched because no built-in preset IDs change — Phase 2
templates are *new* deterministic IDs (`0000000A-0001-…`, a block this design reserves) delivered
to existing users by `BuiltInSeedMigrator.migrate` (`CompositionStore.swift:211`), whose
`designMatches` already compares `sequence` (`BuiltInSeedMigrator.swift:99`).

---

## 5. Engine mapping

### 5.1 Playback = the existing mixer chokepoint

`SequencePlayer` grows a seconds mode; the run loop shape (`SequencePlayer.swift:122-167`) is
unchanged: hold → cue next on deck B → start transition → bounded wait (existing fade + 2s
manual-landing guard, `:144-159`) → `adopt` → promote. New per mode:

- `sleepBars` gains a sibling `sleepSeconds(holdSeconds)` (same 250ms-chunked cancellable wait,
  `:182-195`).
- Loop modes: `pingPong` iterates a mirrored index walk; `count` decrements; `offEnd` finishes
  with one grouped-light off PUT through the API the stop path already uses
  (`StudioViewModel.swift:1366`).
- Transition start calls a new wall-clock/per-light program instead of only
  `startAutoFade(beats:)`.

### 5.2 Per-light transitions (the one real engine extension)

`PerformanceMixBox` gains an additive slot beside `autoFade`:

```swift
// CompositionMixer.swift
struct ActiveTransition {                 // host-time derived each frame, never accumulated
    let kind: CompositionSequence.TransitionSpec.Kind
    let startHost: Double                 // CACurrentMediaTime timebase
    let fadeSeconds: Double
    let spreadSeconds: Double
    let reverse: Bool
}
var transition: ActiveTransition? = nil   // on PerformanceMixBox
```

`CompositionMixer.renderMixed` today lerps A→B with one global `xf`
(`CompositionMixer.swift:138-143`). The extension replaces that scalar with `xf_i` per channel
from a new pure enum:

```swift
// SequenceTransitionMath.swift — pure, unit-testable like StageStripMath
enum SequenceTransitionMath {
    /// delay_i = spread × order(kind, index, spatialPosition, hash01(index, seed))
    /// xf_i    = smoothstep(clamp((elapsed − delay_i) / fadeSeconds))
    static func progress(elapsed: Double, lightIndex: Int, spatialPosition: Double?,
                         spec: ActiveTransition) -> Double
}
```

- `sweep` orders by `mix.deckA.spatialPositions[index]` — already maintained per channel on the
  box (`CompositionEngine.swift:41`) and already computed for both transports at composition
  start (`UnifiedOrchestrator.swift:2585-2601` REST order, `:2618-2628` channel order). Reversed
  by `reverse`.
- `random` reuses the engine's deterministic hash (`CompositionEngine.hash01`,
  `CompositionEngine.swift:438`) — stable per light, honest "fire" feel.
- `fade` with `spread == 0` degenerates to the current global lerp; `cut` is `fade` with
  `seconds == 0`. When all `xf_i` reach 1, `renderMixed` clears `transition` and commits
  `crossfade = 1` so the player's existing landing logic fires unchanged.

Because this lives at the shared chokepoint, it works identically over DTLS 25fps and the 120ms
REST scheduler (which already routes through `renderMixed` when the mix's deck A is the running
box — `UnifiedOrchestrator.swift:3054`), with per-light REST PUTs batched 5-at-a-time by the
latest-wins mailbox exactly as today (`:3108-3149`; `RestSender` at `SyncModeEngine.swift:28-46`).
REST cadence honesty: a 1s sweep across 12 lights lands stepped, not smooth — the transport
status sentence already tells this truth (`MixerTrayView.swift:500-527`) and the same string
appears in Sequence Studio's badge popover.

### 5.3 Session ownership

New `SequenceSession` (MainActor, owned by `StudioViewModel`, keyed by roomID): wraps
`PerformanceMixBox(deckA: activeCompositionBoxes[room.id])` + `SequencePlayer`, sets
`orchestrator.activePerformanceMix` on start and clears on stop — the exact contract
`PerformanceViewModel.begin()/end()` already implements (`PerformanceView.swift:69-106`). One
session at a time (same singleton constraint as `activePerformanceMix`,
`UnifiedOrchestrator.swift:2227`). Opening Perform while a sequence runs hands the *same* mix and
player to `PerformanceViewModel` (init gains an optional `mix:`/`player:`), so Perform's
sequencer button shows it already playing — one mix per room, never two mixes on one box.

### 5.4 Whole-sequence rendering (previews and scrubbing)

A pure `SequenceRenderer.frame(at t: Double, sequence:, channelIDs:, boxes:)` computes which step
(and transition) time `t` falls in and returns blended `LightFrame`s — used by the filmstrip
painter, the scrub-to-lights path, and (Phase 3) the bridge compiler. It is
`CompositionEngine.render` + `SequenceTransitionMath` composed; no new rendering math.

---

## 6. Transport & capability honesty

Extend the derived-tier philosophy (`capabilityTier`, `CompositionModels.swift:794-805`) with a
sequence-aware ladder, surfaced as one badge + one sentence (never a matrix):

| Tier | Badge | Requirements (derived, never stored) | What runs it |
|---|---|---|---|
| **Bridge-stored** | `BRIDGE ⚡` | 2–8 steps; every hold `steady`; holds quantize to ≥3s; transitions `cut`/`fade` only; no mic steps; loop `forever` or `holdEnd` | v1 sensor+rules+schedule chain — app closed, lights keep going (`BridgeAnimationEngine`, `maxSteps = 8` at `:79`, min 3s at `:112`) |
| **Bridge dynamic (lite)** | `BRIDGE · APPROX` | color-only steps, fade transitions — palette ≤9 anchors | CLIP v2 dynamic scene via `BridgeDynamicSceneExporter` (`:27`); timing approximate, offered as "Save to Bridge (approximate)" |
| **App · Room** | `ROOM · REST` | anything | REST mailbox, cadence sentence shown |
| **App · Streamed** | `ENT AREA` | anything, entertainment area exists | DTLS 25fps, sweeps pixel-perfect |

- `PresetSurfaceClassifier` gains one line ahead of the scene check: a preset with a non-empty
  sequence is never `.scene` (it moves by definition) — `.live` if any step reacts, else
  `.effect` (`PresetSurfaceClassifier.swift:31-35`). Sequence presets therefore file onto the
  right decks automatically (`StudioViewModel.swift:1596-1604`) and stay off the Scenes tab shelf
  (`ScenesTabView.swift:325`).
- `canRunOnBridge` semantics extend naturally: `!sequence.requiresMic && bridgeTierEligible`
  (`CompositionModels.swift:811` is the precedent).
- The mixer tray's transport menu and status sentences are reused verbatim — bridge-stored
  sequences produce the existing "Running on bridge — close the app, lights keep going" line
  (`MixerTrayView.swift:516-518`).
- **Phase 3 bridge compilation:** `SequenceBridgeCompiler` maps steps → the v1 chain by injecting
  per-step light states at the exact seam `BridgeAnimationEngine.upload` already builds them
  (`perStepLightStates`, `BridgeAnimationEngine.swift:156-173`): hold = step interval (≥3s), fade
  seconds = `transitiontime` deciseconds per light action, 8-action rule chunking preserved
  (`:197`), schedule interval = Σ holds (`:266-283`). The eligibility function *rounds and
  reports*: "On the bridge this runs as: 6 steps, holds rounded to 3s, throb becomes steady" — an
  explicit preview diff before upload, never silent degradation.

---

## 7. Template catalog (Phase 2 built-ins; deterministic IDs `0000000A-0001-0001-0001-…`)

Every template passes the built-in photosensitivity test (extended to render sequences, §8).
Color roles in brackets recolor via the novice Colors control.

1. **First Light** — Brian's script verbatim: blue [base] fade-in 3s → hold 2s → fade 1s to
   magenta [accent] → hold 2s → sweep 2s to amber [glow] **throb 45 BPM** hold 5s → loop ∞.
   Ships first in the gallery; it teaches the whole model in one loop.
2. **Lava Lamp** — deep orange/red blob (`pulseCenter` motion, `swell` envelope) hold 18s →
   **random** transition 8s spread 6s to magenta/purple → hold 18s → random 8s to ember red →
   loop ∞. The OnSwitch album, beaten by real per-light randomization.
3. **Sunrise Alarm** — night indigo 1% hold 10s → fade **10 min** (tap-to-type range) to horizon
   rose 20% → fade 8 min to amber 60% → fade 5 min to daylight white 100% → **hold end**. The
   long-fade showcase.
4. **Sunset Wind-Down** — inverse ramp, `offEnd` with 30s fade-off.
5. **Thunderstorm** — slate blue shimmer hold 12s → **cut** to white 100% (`flicker` hold 0.8s) →
   cut back → random 4s to deep blue hold 15s → loop; strobe-adjacent steps spaced ≥1s (§8).
6. **Fireplace Evening** — three ember steps, all `flicker` holds, random transitions 5s — proof
   that "hold style" carries the whole fire feel.
7. **Ocean Tide** — teal→deep blue **sweep 6s** forward, hold 10s; sweep 6s **reverse**, hold
   10s; **ping-pong**. The spatial flex.
8. **Party Loop** — 6 saturated steps, hold 2s each, sweep 0.8s, loop ∞; `bars` twin included so
   Perform beat-locks it.
9. **Aurora Night** — green/purple `wave` holds 20s, sweep 10s spread 8s, Night mood default.
10. **Candlelit Dinner** — warm white steady 70% hold 30 min → fade 5 min to 40% flicker → hold
    end. Long-form elegance.
11. **Focus Sprint** — cool white steady hold **25 min** → fade 30s to amber 40% hold **5 min** →
    **loop ×4** → off at end. A pomodoro made of light; loop-count showcase.
12. **Holiday Chase** — red/green alternating steps, `chase` motion holds, cut transitions ≥1s
    cadence; seasonal months `[12]`.
13. **Deep Sleep Fade** — single step, current color → fade 20 min to 1% red → off. The simplest
    possible sequence; also the accessibility-safest.

---

## 8. Guardrails & accessibility

Grounded in the existing safety stack: the 3Hz strobe cap (`CompositionMixer.swift:94`), Reduce
Motion strobe block (`StudioViewModel.swift:1193-1196`), Dim Flashing Lights 30% cap
(`:1201-1203` via `MADimFlashingLightsEnabled`, `:531-533`), the acknowledged-strobe-warning flow
(`:516-538`), the built-in flash-rate test (`PresetCatalogTests.swift:212-254`), and the
first-entry photosensitivity notice (`StudioView.swift:1794-1823`).

- **Model-level flash audit.** Pure `SequenceSafety.audit(sequence) -> [Finding]` computes
  worst-case flashes/sec: throb/pulse BPM ÷ 60 at depth; step cadence for `cut` transitions
  between high-contrast steps; combined worst case. The editor *clamps* the novice Rate slider to
  ≤170 BPM (2.83Hz at full depth) and *blocks* saving any configuration whose audit exceeds 3Hz
  unless the user confirms the same strobe warning dialog the Studio already uses — a cut-chain
  faster than 333ms/step is a strobe and is treated as one. `PresetCatalogTests` extends to
  render every template's sequence timeline and enforce ≤3Hz, so shipped templates are proven
  safe, not assumed.
- **Dim Flashing Lights:** when `MADimFlashingLightsEnabled()`, `SequenceSession` caps
  `mix.masterIntensity` (post-blend scalar, `CompositionMixer.swift:154-159`) for any sequence
  whose audit finds ≥1Hz luminance swings — the strobe precedent generalized.
- **Scrubbing** the filmstrip to lights is throttled to ≥333ms between sends (latest-wins mailbox
  absorbs the rest).
- **Reduce Motion** stills the filmstrip animation and template previews (existing
  `PatternStripView` contract); it does not stop light playback (lights are the product), but the
  strobe-class findings above still block.
- **VoiceOver:** each step row announces position and content: "Step 2 of 5. Ember. Deep red.
  Hold 2 seconds, throb at 40 beats per minute. Fades 1.5 seconds into step 3." Reorder via the
  standard accessibility rotor actions on `List`. The filmstrip is `accessibilityHidden`
  decorative (as `PatternStripView` at `StageKit.swift:645`) with the total-time readout carrying
  the information.
- **Reachability:** 44pt minimum targets throughout (StageKit already enforces on
  toggles/swatches, `StageKit.swift:387,435`); duration entry is tap-to-type
  (`StageSlider.parseDraft` clamping, `:129-142`) so long values never require pixel-precise
  dragging; all interactive editing in the lower two-thirds of the screen.

---

## 9. Cross-surface integration

- **Cards:** SEQ badge + step-dot mini-strip; animated card previews follow the
  tab-active/reduce-motion pause contract (and, after build 29, the KeyboardState pause).
- **Siri:** free on day one — sequence presets are `CompositionEntity`s, so "Start *Lava Lamp* in
  the *Bedroom*" already routes through `StartCompositionIntent` → deep-link → `apply`
  (`StudioIntents.swift:137-162`), and `apply` auto-starts the session (§3.1). Saving re-donates
  shortcuts automatically via `CompositionStore.onPersist` (`CompositionStore.swift:27-32`).
- **Sharing:** `SharedScene` already carries `sequence` (`ScenePayloadCodec.swift:43`);
  `SceneQRRenderer` already reports capacity overflow instead of silently dropping it. Long
  sequences fall back to link-sharing; the QR sheet says so.
- **Scenes tab:** classifier change keeps sequences off the still-scene shelf; bridge-exported
  sequences appear there as native scenes like today's exports.
- **Automations (Phase 3):** `AutomationAction` gains `.composition(UUID)`
  (`AppAutomation.swift:88-93`); honesty rule — an automation can only *fire* an app-driven
  sequence while the app runs; scheduled sequences otherwise offer the bridge-stored export path.
- **Widgets:** a "Start sequence" widget intent lands with the automation work (same open-app
  pattern as `StartCompositionIntent`, `openAppWhenRun: true`).
- **Now Playing:** free — sessions run inside a composition effect, so the Dashboard bar and
  Tap-Dial stop routing already work (`publishNowPlaying`, `StudioViewModel.swift:611-621`).

---

## 10. Phased build plan (each phase independently shippable)

**Phase 1 — Model + engine + minimal editor (feature-flagged `sequenceBuilderEnabled`, Debug
toggle in More).**
1. `HueHome/Core/Composer/SequencePlayer.swift` — additive model fields (TimingMode, LoopMode,
   TransitionSpec, holdSeconds); seconds-mode holds; loop modes; transition dispatch. Decode
   round-trip tests.
2. `HueHome/Core/Composer/CompositionMixer.swift` + new
   `HueHome/Core/Composer/SequenceTransitionMath.swift` — `ActiveTransition`, per-light `xf_i`
   blending; unit tests (order correctness per kind, degeneration to global fade, landing commit).
3. New `HueHome/Core/Composer/HoldStyleMapper.swift`, `SequenceSafety.swift` — pure, tested.
4. `HueHome/UI/Studio/StudioViewModel.swift` — `SequenceSession`, auto-start in `apply`, stop
   wiring in `stopEffect`.
5. New `HueHome/UI/Sequencer/SequenceStudioView.swift` + `SequenceStepEditorSheet.swift`
   (StageKit only); entry via `MixerTrayView` button and card context menu through new
   `StudioSequenceWiring` modifier in `StudioView.swift`.
6. Tests: `SequenceTransitionMathTests`, `SequencePlayerTests` (timing, loop modes,
   cancellation), `SequenceSafetyTests`, store round-trip.

**Phase 2 — Templates, previews, cross-surface polish.**
1. Template catalog in `HueHome/Core/Models/CompositionStore.swift` built-ins (new deterministic
   IDs; migrator delivers to existing users); extend `HueHomeTests/PresetCatalogTests.swift` 3Hz
   sweep to sequence timelines.
2. New `SequenceFilmstripView.swift` + `SequenceRenderer` (pure) — filmstrip, playhead,
   scrub-to-lights; template gallery + novice 3-knob mode with color-role maps.
3. Card SEQ badge/strip (`StudioView.swift` card view + `StudioViewModel.studioCard(for:)`
   tagline); classifier update (`PresetSurfaceClassifier.swift`); Perform's sequence sheet
   re-hosted on the shared editor components in bars mode (`PerformanceView.swift`).
4. Flag removed; photosensitivity notice text reviewed to mention sequences.

**Phase 3 — Bridge export, Siri/automations, spatial masks.**
1. New `HueHome/Core/Composer/SequenceBridgeCompiler.swift` feeding the `BridgeAnimationEngine`
   chain (factor `upload` to accept injected per-step states at `BridgeAnimationEngine.swift:156`);
   eligibility + rounding-preview UI; teardown via existing manifest store.
2. "Save to Bridge (approximate)" dynamic-scene recipe (`BridgeDynamicSceneExporter.swift`
   extension).
3. `AutomationAction.composition`, widget intent, Siri phrase donation polish.
4. Per-step spatial masks (All/Left/Right/Center/Edges from `spatialPositions`) if validation
   demands them.

---

## 11. Open questions (for Brian)

1. **Should tapping a sequence card *always* auto-play the sequence,** or should the mixer tray
   offer "look only" (base layers, sequence paused)? Spec says auto-play; a pause control in the
   tray costs one badge slot.
2. **Perform + Sequence session unification timing** — Phase 1 ships the shared-mix handoff or
   the simpler "entering Perform adopts the session's player" rule? (Spec recommends the shared
   mix; it is a 3-line init change.)
3. **Cap on app-driven step count** — soft 24? The model is unbounded; QR capacity and editor
   ergonomics argue for a soft cap with type-in override.
4. **Gradient strips** — transitions operate per *channel* (strips expand via
   `GradientChannelMap`, `UnifiedOrchestrator.swift:2744-2755`), so sweeps travel *along* a
   strip; confirm this is desired (it is delightful) vs. per-fixture staggering.
5. **`bars`-mode display in Sequence Studio** — show musical steps converted to seconds at
   current BPM, or hide Sequence Studio for bars sequences and keep them Perform-only until
   edited?
6. **Sequence-in-sequence templates** (a step referencing another preset id) — rejected for now
   (breaks self-containment); revisit if users ask for "chapters of chapters."

---

## Critical files for implementation

- `HueHome/Core/Composer/SequencePlayer.swift` — the model (`CompositionSequence`) and player
  this feature evolves; all additive fields land here
- `HueHome/Core/Composer/CompositionMixer.swift` — `PerformanceMixBox` + `renderMixed`, the
  render chokepoint gaining per-light transitions
- `HueHome/UI/Studio/StudioViewModel.swift` — apply/stop chokepoints, `SequenceSession`
  ownership, auto-start wiring
- `HueHome/Core/Network/UnifiedOrchestrator.swift` — both render loops' mixer seam (lines
  2848/3054), `activePerformanceMix`, transport bookkeeping
- `HueHome/UI/Components/StageKit.swift` — every editor control (StageSlider tap-to-type,
  HueSaturationPad, StageCard/Badge) the new UI is composed from
