# Composer 2 — "Dream Studio" experiment

**Branch:** `experiment/composer-2-dream-studio` (off `main` @ `c2368c8`). **Isolated product prototype.** Not a PR, not merged, `main` untouched.
**Rollback:** `git switch main` — or delete the branch; tag `checkpoint/pre-composer2-dream-studio` marks the base.

## What it is

A one-shot prototype of the creative lighting instrument ChromaGlow should become: one screen where a normal person
composes dynamic light from six understandable dimensions (Palette, Motion, Rhythm, Space, Audio, Variation), and an
advanced user stacks behaviors with an event generator. Aurora Drift, Lava Lamp, Christmas Chase, Haunted House and
Thunderstorm are all values of the same model — there are no per-preset engines.

Entry point: Studio → composer deck → **"Try Composer 2 · Experimental"** (one card, one line in `StudioView.composerGrid`).

## Architecture in one picture

```
Composer2Composition  (Codable document: master controls + [Composer2Layer])
   └ Composer2Layer   mask · color (≤8 stops, OKLab) · motion · rhythm · audio · variation · events?
          │
   Composer2Engine.evaluate(composition, time, geometry, state, audio, beat) → [Composer2Frame]   (pure, seeded)
          │
   Composer2LiveOutput : CompositionFrameSource            ← the ONLY seam into the existing app
          │
   CompositionParamBox.frameSource  →  CompositionEngine.render(...)  (12-line hook, falls through on mismatch)
          │
   UnifiedOrchestrator.startCompositionMode / stopCompositionMode  (untouched: DTLS 25 fps or Room-mode REST,
   per-bridge sessions, third-party detection, realized-frame ≤3 Hz flash gate, failover, SSE suppression, mic demand)
```

The hero visualization and the lights read the same frames: while a live loop drives the runtime the hero mirrors
`lastFrames`; otherwise it evaluates the same runtime on its own clock. Every on-screen frame passes a preview-side
onset gate (`BeatMath.FlashSafety.OnsetGate`), so the picture obeys the same ≤3 flashes/second rule as the wire.

### Determinism

Every random value is a pure function of `(seed, layer id, slot, cell/opportunity index)` — SplitMix64 streams and
stateless hashes, never `Hasher`, never a clock. Events draw exactly twice per scheduling opportunity regardless of
frame rate or audio; audio only tilts thresholds and multipliers. The same seed reproduces the same sequence;
"Reseed" in the Variation editor gives a fresh take.

### Blend semantics (documented, deliberately simple)

Layers stack bottom-up over black. `replace` fades toward the layer; `add light` adds brightness with
contribution-weighted colour; `brighter wins` keeps the brighter layer per light (5 % soft band). Final brightness is
clamped 0…1 and chromaticity is clamped to gamut C; the orchestrator clamps again to the room's real gamut.

## Files

| Area | Files |
|---|---|
| Core (`HueHome/Core/Composer2/`) | `Composer2Random` (math, SplitMix64, hashing, value noise) · `Composer2Palette` (OKLab, stops, compiled palette) · `Composer2Space` (slot geometry from the orchestrator's radial/angular arrays, masks) · `Composer2Motion` · `Composer2Rhythm` · `Composer2Modulation` (audio + variation) · `Composer2Events` (spec, active event, seeded generator) · `Composer2Models` (blend, layer, composition) · `Composer2Engine` (state, plans, evaluate) · `Composer2LiveOutput` (the frame source) · `Composer2PresetLibrary` · `Composer2Store` (`Documents/composer2-compositions.json`) · `Composer2LegacyImport` |
| UI (`HueHome/UI/Composer2/`) | `Composer2View` (cover root) · `Composer2Header` (+ title block) · `Composer2HeroCard` (canvas painter) · `Composer2ModeSelector` · `Composer2QuickPanel` · `Composer2CustomizeGrid` + `Composer2LayerCard` + `Composer2MiniPreviews` · `Composer2AdvancedPanel` · `Composer2ExpertStack` · `Composer2PerformanceBar` · `Composer2EntryCard` · `Composer2Document` · `Composer2SlotLayout` · `Composer2PreviewFeed` (+ heartbeat verdict) · `Composer2LiveGateway` (+ orchestrator adapter) · `Composer2PlaybackCenter` · `Composer2Theme` (tokens + all copy) · `Editors/` (scaffold, Palette, Motion, Rhythm, Space, Audio, Variation, Events) |
| Existing files touched | `HueHome/UI/Studio/CompositionEngine.swift` (protocol + field + 8-line hook; v2.1 adds `CompositionRenderSlot` + `renderSlots`) · `HueHome/Core/Network/UnifiedOrchestrator.swift` (v2.1: publishes exact render slots at both start branches, capability-honest per-light sends, `composer2StopHandler`, `startCompositionModeAttended`) · `HueHome/Core/Audio/AudioAnalysisEngine.swift` (`case composer2Preview`) · `HueHome/UI/Studio/StudioView.swift` (one line) · `HueHome.xcodeproj/project.pbxproj` (registration via `add_composer2_files.rb`, build 54) · `DEVLOG.md` |
| Tests (`HueHomeTests/Composer2Lab*Tests.swift`) | Primitive · Layer · Event · Engine · Persistence · Preset · Lifecycle · Guard · Snapshot · **v2.1:** Slot · Integration · Recovery · Performance |

## Live, Apply, Preview, Save

- **Preview** runs the composition on screen only. The microphone is requested only when an audio-reactive layer is
  enabled *and* preview or live is running (`AudioDemand.composer2Preview`).
- **Live** is an audition: real output to the selected room, stopped when you leave the screen, change rooms, tap
  Stop, or the transport ends. The status line says "Live · Streaming" or "Live · Room mode".
- **Apply** keeps the composition playing after you leave, while ChromaGlow stays open. The Studio entry card shows
  "Playing in ‹room› · ‹look› · Stop", and the Dashboard's Now Playing row shows the same session: its Stop stops the
  real Composer 2 transport (v2.1). Apply does not survive process death: a cold launch claims nothing, auto-starts
  nothing, and holds no stale ownership — the saved compositions are the only thing that persists.
- **Save** overwrites a composition you own; **Save as new…** always creates one (built-ins and imports can only save
  as new). Saved looks appear on the Studio card as one-tap looks (tap = applied playback in the selected room;
  long-press = Open in Composer 2 / Rename / Delete). Composer 2's own store is used; the legacy `compositions.json`
  is never read or written (test-proven). **Import from Composer** (Quick mode) brings a legacy preset in as one
  behavior; the original is untouched.

Refusals are honest and never silent: Demo Mode ("Live isn't available in Demo Mode…"), no bridge, several
Entertainment Areas (plays Room mode and says why). A third-party controller is now **asked about** (v2.1): the
orchestrator's own preflight finds it, Composer 2 shows the standard takeover prompt, "Keep existing" leaves the
other app's show untouched ("Kept the other app's show. Nothing was changed."), "Take over" runs the orchestrator's
consented takeover, and a controller that changes mid-flight fails honestly.

## The five presets

| Preset | Layers |
|---|---|
| Aurora Drift | organic flow along the room's principal axis, 4-stop hue-arc palette, 14 s breathe, organic variation with slow evolve |
| Lava Lamp | organic base with evolving per-light timing + an add-light "blobs" layer on another axis |
| Christmas Chase | stepped red/green/white chase (3 steps) + a fixed-interval single-light sparkle event layer |
| Haunted House | dim base · candle flicker on a random half · slow violet pulse (brighter wins) · rare spatially-biased eerie flashes |
| Thunderstorm | dark sky breathe · lightning event layer (random 6–18 s, 80 % chance, 1–3 flashes, spacing ≥ the flash budget, 15 % major strikes) |

## How to run

```bash
git switch experiment/composer-2-dream-studio
ruby add_composer2_files.rb                      # idempotent; already applied on the branch
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' build 2>&1 | grep -E 'error:|BUILD'
./Scripts/hardening_guards.sh
xcodebuild test -project HueHome.xcodeproj -scheme "HueHome 1" \
  -destination 'platform=iOS Simulator,id=76B14B66-1234-495A-B352-4BD35B785131' \
  -only-testing:HueHomeTests/Composer2LabPrimitiveTests -only-testing:HueHomeTests/Composer2LabLayerTests \
  -only-testing:HueHomeTests/Composer2LabEventTests -only-testing:HueHomeTests/Composer2LabEngineTests \
  -only-testing:HueHomeTests/Composer2LabPersistenceTests -only-testing:HueHomeTests/Composer2LabPresetTests \
  -only-testing:HueHomeTests/Composer2LabLifecycleTests -only-testing:HueHomeTests/Composer2LabGuardTests \
  -only-testing:HueHomeTests/Composer2LabSnapshotTests -resultBundlePath /tmp/c2.xcresult
./run_tests.sh                                   # full registered suite
xcrun xcresulttool export attachments --path /tmp/c2.xcresult --output-path /tmp/c2-shots   # the review renders
```

On a phone: Studio → composer deck → Try Composer 2 → pick a room → Live. In the Simulator use Demo Mode
(Splash → "Explore Demo"): Preview works, Live explains that it needs a paired bridge.

## v2.1 — hardening and integration pass (2026-09-16, build 54)

What changed, by the brief's numbering:

- **P0.1 Exact render slots.** `CompositionRenderSlot` (bridge id, light id, DTLS channel id, segment k/n, real
  position, capability, white range) is published by the orchestrator on `paramBox.renderSlots` at BOTH start
  paths — streaming (one slot per channel, plan order) and Room mode (resolver order with gradient strips expanded;
  segments share the light's position, never an invented one). `Composer2LiveOutput` adopts the slots for geometry
  and identity (light-id masks resolve through them), the hero relabels from them ("TV Strip · 2/2"), and a count
  mismatch still falls through to index geometry / legacy math.
- **P0.2 Dashboard Stop.** The session publishes a Now Playing row (`effectID: "composer2"`) through the gateway and
  installs `composer2StopHandler`, consulted before Studio's handler. It returns true only when the target is our
  session, so a replacement Studio look is never stopped by us and a repeated Stop is a no-op.
- **P0.3 Apply lifecycle truth.** Nothing is persisted about playback; `Composer2PlaybackCenter` starts idle,
  claims nothing, auto-starts nothing (tested).
- **P0.4 Stability.** All center operations run on one serialized chain (rapid Live/Stop, close-while-starting,
  room switch while starting); the screen attaches/detaches so an audition nobody is watching stops on arrival; the
  heartbeat ignores silence while the app is inactive and re-arms on return; an `ended` verdict retires the row but
  never unbinds the frame source or sends a stop.
- **P1.5 Attended takeover** via `UnifiedOrchestrator.startCompositionModeAttended` (the guarded takeover API stays
  inside the orchestrator file); approve / keep / failure paths tested.
- **P1.6 Capability honesty.** Room-mode per-light sends follow the slot capability: colour → xy, tunable white →
  mirek within the light's range, dimmable → brightness only. The hero marks brightness-only lights with a dashed
  ring and a "N lights show brightness only" badge.
- **P1.7 Studio integration.** Saved compositions are one-tap looks on the Studio card through the same playback
  owner. Siri was NOT wired: the App Shortcuts registry is at its 10-shortcut cap and adding one would evict an
  existing shortcut — out of scope for an experiment.
- **P1.8 Performance** — measured in `Composer2LabPerformanceTests` (numbers in the DEVLOG entry and the xcresult
  attachments): six layers over 100 slots with events, masks and audio at 25 fps.
- **P1.9 Gradient identity** — segments carry k/n and the channel id; Room-mode fanning on screen is labelled
  "Positions: estimated".
- **P2 polish:** drag-to-reorder behaviors (Expert, up/down kept), harmony presets in the Palette editor
  (`HarmonyEngine`), Collapse all / Expand all (Advanced), Save vs Save as new, legacy import sheet, non-destructive
  Quick Energy (maps to master energy/variation only), audio brightness "Adding light" (punch) vs "Dimming when
  quiet" (legacy imports keep the legacy behaviour), accessibility-size renders and VoiceOver labels/hints on the new
  controls.

## v2.2 — real lightning, 49 looks, and the luminous Composer (2026-09-22, build 56)

Branches: fixes on `experiment/composer-2-v2.2-bugfixes` (build 55, ~120 defects across the app — see the DEVLOG
entry); this build-out on `experiment/composer-2-v2.2-ui-ux` (build 56), on top of it.

**New primitives (pure, seeded, draw-for-draw compatible with v2.0 flashes):**
- Event **shapes**: `flash` (as before), `lightning`, `firework`, `twinkle`, `glow` (`Composer2EventSpec.shape`).
  `Composer2Lightning` models a real strike — stepped leader, 1–4 return strokes spaced ≥ a flash budget, restrokes
  rising from the channel's glow, the sky lit around the bolt, a snap then a long afterglow. `distance` makes strikes
  dimmer/softer/wider/warmer and lets them roll (`propagation`); `activityPeriod`/`activityDepth` make a storm roll
  in and pass. Fireworks pick a colour from `colors`, burn white-hot and bloom outward.
- Motion `march` (string-light chase by light ORDER; one flash budget per step), rhythms `twinkle` and `candle`,
  colour distribution `brightness` (colour follows brightness), master `eventRate` / `eventStrength`.
- `Composer2FlashShaper` in the live output: runs the wire's own gate on every frame and, instead of letting a rise
  be held (a stutter), emits the largest step the gate accepts. The wire gate stays the authority.

**Library:** `Composer2ThemeCatalog` files 49 built-ins (ids 1…49, `0000000C-0002-0002-0002-…`) in eight
categories — Halloween, Christmas & Winter, Holidays, Weather, Nature, Fire & Candle, Party, Calm — defined in
`Composer2Presets+Seasons.swift` / `+World.swift`. `Composer2BehaviorLibrary` offers 24 ready-made behaviors to stack
(lightning, fireworks, fireflies, string chase, candle, rain, beat pulse…). `Composer2LabThemeTests` pins gamut C,
legal/deterministic frames at 1/5/20 lights, and plays every look through the real wire gate (the gate holds
nothing; the shaper's share is bounded).

**The screen:** Looks · Tune · Layers replace Quick/Customize/Advanced/Expert (those five files are deleted).
- *Looks* — live library: every card plays its look on a mini stage; For you / categories / Yours; rename,
  duplicate, delete saved looks in place.
- *Tune* — Brightness, Speed, Energy; Frequency and Strength for moments; for storms Distance, Random vs Regular
  (periodic) strikes with an interval, and "The storm passes"; colours; "Another take" (reseed).
- *Layers* — the stack top-first with live per-layer strips, blend modes, the behavior picker, and a tabbed editor
  (Colour · Motion · Rhythm · Space · Moments · Sound · Variation · Layer).
- A luminous hero (orbs that pool light on the floor, additive), an ambient background tinted by the look, a dock
  with one big Go Live, undo/redo, an EDITED marker, and a Studio entry card that plays the current look.

**Hardware NOT verified** — as for v2.1, plus: how lightning/fireworks/marches read on real bulbs (Room mode sends
at ~8 Hz and will soften fast strokes; streaming shows them in full), and the flash shaper against a real gate.

## Verified vs not

**Compile / unit verified:** everything above builds; the thirteen Composer2Lab suites and the full registered suite
pass; `Scripts/hardening_guards.sh` passes; the review renders are in `screenshots/`.

**Hardware NOT verified:** real Streaming and Room-mode output, exact slot labels against a real Entertainment area,
the flash gate on a bridge, the Dashboard Stop against a real transport, replacement by a Studio card while applied,
Apply surviving dismissal on a phone, the takeover prompt against a real third-party controller, tunable-white and
dimmable sends on real lights, microphone-reactive layers live, multi-bridge rooms. Nothing here claims hardware
behavior.

## Known limitations

- Applied playback ends when ChromaGlow quits; there is no background or bridge-stored continuation (by design —
  nothing about playback is persisted).
- Siri / App Shortcuts are not wired for Composer 2 looks (registry cap; see v2.1 notes).
- Room mode: a gradient strip's segments share the light's real position (Hue exposes none per segment outside an
  Entertainment area); the hero fans them apart for tapping and labels the positions as estimated.
- Stop — from the Composer 2 screen, the Studio card or the Dashboard row — ends the composition and leaves the lights
  at their last frame; it does not turn the room off (Studio's own looks do). The handler ignores the row's
  `turnOffLights` flag on purpose: an experiment should never turn your room off on its way out.
- Legacy Composer presets import into one layer (`Composer2LegacyImport`); Composer 2 compositions do not export back.
- The hero's estimated layout also drives the on-screen preview geometry (so motion reads spatially on screen); the
  live loop always uses the orchestrator's own slot order.

## Removing the experiment

Delete `HueHome/Core/Composer2/`, `HueHome/UI/Composer2/`, the nine `HueHomeTests/Composer2Lab*Tests.swift`,
`add_composer2_files.rb`, this folder; revert the hook in `CompositionEngine.swift`, the `composer2Preview` case, the
one line in `StudioView.swift`, and the pbxproj entries. Nothing else references the lab (guard-tested).
