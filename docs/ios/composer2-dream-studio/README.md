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
| Existing files touched | `HueHome/UI/Studio/CompositionEngine.swift` (protocol + field + 8-line hook) · `HueHome/Core/Audio/AudioAnalysisEngine.swift` (`case composer2Preview`) · `HueHome/UI/Studio/StudioView.swift` (one line) · `HueHome.xcodeproj/project.pbxproj` (registration via `add_composer2_files.rb`, build 53) · `DEVLOG.md` |
| Tests (`HueHomeTests/Composer2Lab*Tests.swift`) | Primitive · Layer · Event · Engine · Persistence · Preset · Lifecycle · Guard · Snapshot |

## Live, Apply, Preview, Save

- **Preview** runs the composition on screen only. The microphone is requested only when an audio-reactive layer is
  enabled *and* preview or live is running (`AudioDemand.composer2Preview`).
- **Live** is an audition: real output to the selected room, stopped when you leave the screen, change rooms, tap
  Stop, or the transport ends. The status line says "Live · Streaming" or "Live · Room mode".
- **Apply** keeps the composition playing after you leave; the Studio entry card then shows "Playing in ‹room› ·
  Stop".
- **Save** writes to Composer 2's own store. The legacy `compositions.json` is never read or written (test-proven).

Refusals are honest and never silent: Demo Mode ("Live isn't available in Demo Mode…"), no bridge, a third-party
controller ("Another app is controlling these lights. Take over from Studio, then try Live again."), several
Entertainment Areas (plays Room mode and says why).

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

## Verified vs not

**Compile / unit verified:** everything above builds; the nine Composer2Lab suites and the full registered suite pass;
`Scripts/hardening_guards.sh` passes; the review renders are in `screenshots/`.

**Hardware NOT verified:** real Streaming and Room-mode output, the flash gate on a bridge, replacement by a Studio
card while applied, Apply surviving dismissal on a phone, the third-party refusal, microphone-reactive layers live,
multi-bridge rooms. Nothing here claims hardware behavior.

## Known limitations

- The Dashboard's Now Playing bar does not know about Composer 2 playback (Studio's stop handler has no row for it,
  so registering one would be a Stop that doesn't stop). Stop from the Composer 2 screen or the entry card's pill.
- Third-party takeover is refused with a pointer to Studio; Composer 2 never asks the takeover question (Guard 11(c)).
- Streaming slot→light labels come from the cached area selection; if the orchestrator chooses a different area the
  labels can be off until the next start (geometry and motion stay correct — they come from the box).
- Room mode: a gradient strip's extra render slots share one light name; positions are estimated (labelled).
- Legacy Composer presets import into one layer (`Composer2LegacyImport`); Composer 2 compositions do not export back.
- The hero's estimated layout also drives the on-screen preview geometry (so motion reads spatially on screen); the
  live loop always uses the orchestrator's own slot order.

## Removing the experiment

Delete `HueHome/Core/Composer2/`, `HueHome/UI/Composer2/`, the nine `HueHomeTests/Composer2Lab*Tests.swift`,
`add_composer2_files.rb`, this folder; revert the hook in `CompositionEngine.swift`, the `composer2Preview` case, the
one line in `StudioView.swift`, and the pbxproj entries. Nothing else references the lab (guard-tested).
