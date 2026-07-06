# Composer / Studio / Microphone Subsystem Audit — 2026-07-06

**Auditor:** Claude
**Scope:** iOS Composer (composition engine/store/models + orchestrator runtime), Studio tab, Effects tab, Sync tab (mic pipelines + DTLS entertainment transport).
**Purpose:** (1) verify these subsystems "work flawlessly" ahead of the DJ-grade dynamic-effects upgrade; (2) record the scrap-vs-salvage decision for the dynamic-effects customization system.
**Companion:** builds on `docs/audit/hardening-audit-2026-07-01.md` (finding IDs H-xx/M-xx/L-xx below refer to it). Phase-1 remediation landed on `ios-ref/hardening-p1-2026-07` — commits `c88409d..94d14e8`.

---

## 1. Verdict: SALVAGE

The dynamic-effects core is **worth keeping and building on**, not scrapping:

- **`CompositionEngine`** (`HueHome/UI/Studio/CompositionEngine.swift`) is a pure, stateless, I/O-free render function (Motion → Palette → Envelope → Reaction per frame → `[LightFrame]`) with PCA-based spatial projection. It is the single chokepoint for both transports — exactly the seam a DJ-grade upgrade needs.
- **`CompositionModels`** is all value types with migration-safe hand-written `init(from:)` (only `id` required); additive fields are safe across versions.
- **Persistence is solved (M-13 fixed):** per-element `FailableDecodable` load, timestamped `.bak` on decode failure, never overwrites the source on error.
- **The transport stack is freshly hardened and consistently applied:** RestSender latest-wins mailbox, `BridgeCommandGate` ~10 cmd/s pacing, generation counters, per-bridge client resolution (M-04, M-05, M-06, M-07, M-08, M-14, M-15 all verified fixed), DTLS `ContinuationGate` (M-09), bounded reconnect (M-10) and — new in Phase 1 — mid-session DTLS→REST failover.

What gets **rebuilt or added** (not salvaged) in the DJ phases: the audio analysis layer (no onset/BPM/beat-phase/AGC exists anywhere today), the Reaction layer's dead targets, unified mic capture (two disconnected pipelines today), and performance/sequencing primitives (no crossfade/timeline/layer-stack exists).

---

## 2. What Phase 1 fixed (this branch)

| Commit | Finding | Fix |
|---|---|---|
| `c88409d` | M-16 + L-44 | Gradual "Turn Off at End" timers are stored per-room and cancellable (activate/stop/deselect); post-sleep `isCancelled` guard; dead `reactivationTask` deleted. |
| `2eadf89` | M-17 (+H-05 guard) | "All Rooms" chip wired through `applyToAllRooms()` with per-bridge client + gate resolution; app-driven effects refused with guidance (single-slot engine). Also fixed a selection race: the `$selectedRoom` sink now respects `isActivating`, and nested `activate()` calls save/restore the flag. |
| `a47f185` | L-41 + L-54 | `EffectParamState.sanitized(from:for:)` clamps every restored preset param to its schema; trap sites (thunderstorm index, party/strobe intervals, K-formatter ÷value) self-clamp. |
| `ad080de` | L-19 class (Sync) | SyncModeEngine gained interruption + background/foreground observers with auto-resume; in-flight starts are now generation-guarded and stoppable (permission prompt, DTLS handshake windows). |
| `630b5ab` | L-19, L-22, L-23 | CompositionMicCapture on `AVAudioApplication` permission API + guard-after-await; "Open Settings" deep link in Sync's denied state; mic consent string reworded (on-device, never recorded). |
| `9c4040d` | L-20 + L-21 | `Core/Audio/AudioSpectrumProcessor`: cached FFT setup/window/scratch for both mic pipelines (was created/destroyed ~43×/sec on the audio thread); inclusive bar-peak count (top bin now participates). |
| `799573d` | M-10 follow-through | `HueEntertainmentClient.isTerminallyFailed` + `noteTerminalFailure()`; Composer loop breaks and fails the room over to the REST scheduler with the same live paramBox; Sync flips to REST with a visible message. |
| `94d14e8` | mailbox bypass | StudioViewModel `sendParam`/`sendColorParam` now route through the studio RestSender (new `enqueueStudioRestWrite`) instead of direct PUTs behind a debounce. |

New/extended regression tests: `MultiBridgeRoutingTests` (All-Rooms two-bridge fan-out, app-driven refusal), `HueDataModelsTests` (4 sanitizer cases), `EntertainmentRobustnessTests` (terminal-failure teardown/flag/reset). All suites green on iPhone 15 / iOS 17.0.

---

## 3. Known dead wires (documented, deliberately not fixed in Phase 1)

- **`.studioStartMicSync` has no observer.** `UnifiedOrchestrator.startStudioMode` posts it (UnifiedOrchestrator.swift ~:1739/:1749) for the Studio "mic"/"gaming" cards, but nothing listens — those Studio cards currently do nothing. Wire to SyncModeEngine or remove the cards; owned by the Phase-2 unified-audio work (the notification hand-off disappears when one engine owns capture).
- **`.compositionMicPermissionDenied` has no observer.** CompositionMicCapture posts it on denial (3 sites), so a Composer user who denies mic gets silent failure. Surface a status line in Studio during Phase 2.
- **`ReactionConfig.targets` `.color` / `.speed`** are user-visible toggles that do nothing (`apply()` only modulates brightness); `smoothing` is never read; `EnvelopeConfig.attack/decay/dutyCycle` have no UI sliders. All become real in Phase 2 (beat-locked reactions).
- **`tapTempo`** is a synthesized LFO at `envelope.bpm`, not a real tap or audio-derived tempo. Replaced by the shared BeatClock in Phase 2.

Structural liabilities (tracked for the DJ phases, not Phase 1): `UnifiedOrchestrator.swift` 3.4k lines hosts all composition runtime; Composer UI has no module boundary (Deck 3 inside 2.7k-line `StudioView.swift`); three parallel effect subsystems (Studio decks / Effects tab / Sync tab) with two duplicated effect catalogs — binding rule from Phase 2 on: no new effect logic outside the Composer stack.

---

## 4. On-device validation checklist (M-10 + failover + lifecycle)

Unit tests cannot open a live DTLS socket; these need a physical bridge run:

- [ ] **DTLS bounded reconnect (M-10):** start a Composer entertainment session; cut bridge Wi-Fi/AP for ~5 s; restore. Expect ≤3 reconnect attempts (300/600/900 ms backoff) and frames resuming.
- [ ] **Composer DTLS→REST failover:** same, but keep Wi-Fi down >30 s with the phone still on the LAN segment. Expect the room to switch to the REST scheduler (slower cadence, composition still animating) — no frozen lights.
- [ ] **Sync DTLS→REST failover:** Sync tab streaming to an entertainment area; kill the bridge link. Expect the transport badge to flip Streaming → REST and "Streaming connection lost — switched to REST".
- [ ] **Phone-call interruption:** during Sync visualizer AND during a Composer mic-reactive preset, receive a call, end it. Both must resume without touching the UI.
- [ ] **Background/foreground:** background the app during each mic mode; foreground. Auto-resume; no orange-dot-with-no-consumer state.
- [ ] **Stop-during-interruption:** while a call has Sync paused, tap Stop, end the call. Sync must NOT auto-resume.
- [ ] **Permission round-trip:** deny mic in Settings → Sync start shows denied banner → "Open Settings" deep-links → grant → return → start works.
- [ ] **All Rooms (multi-bridge):** with two bridges, tap All Rooms + a one-shot/bridge-native effect; every room on both bridges changes; app-driven effects show the pick-a-room toast.
- [ ] **Slider scrub:** run a bridge-native Studio card, scrub Brightness rapidly — lights track the final position without multi-second stale replay.
- [ ] **Turn-off timer:** Sunset (short duration, Turn Off ON) → re-apply with Turn Off OFF → lights must NOT switch off at the original deadline.
- [ ] **Visualizer parity:** bars/levels respond as before the FFT caching (bar 20 may read slightly higher — corrected L-21 behavior).

---

## 4b. Phase 2 addendum (2026-07-06, same session)

Phase 2 (DJ foundation) landed in four commits after Phase 1:

- `5aa391b` **Audio core:** `AudioFeatureExtractor` (AGC-normalized bands, spectral-flux onsets), `TempoEstimator` (60–180 BPM, subharmonic-safe smallest-strong-lag selection, hysteresis), `BeatClock` (tap/manual/audio-follow with ≤30 ms phase corrections) — 20 unit tests on synthetic click tracks.
- `ff97e9c` **Motion + reactions:** `MotionConfig.sample()` returns phase + per-light intensity weight → **`spread` is functional** (beam↔wash; spread=100 preserves legacy look). **Five new patterns:** chase, comet, pulseCenter, spiral, twinkle (radial/angular geometry from entertainment positions). **`randomize` is functional.** All three reaction targets implemented: brightness (per-beat punch), color (quantized palette stepping), speed (warped time + `motionBeatsPerCycle` beat lock). **`smoothing` is functional.** New sources `.beat`/`.onset`; all fields additive/migration-safe. 16 new tests.
- `1484b3f` **Unified capture:** `AudioAnalysisEngine` owns the one AVAudioSession/engine; `CompositionMicCapture` and the `.composerMicExclusiveBegan` handshake are deleted; Sync tab is a buffer-tap consumer; L-05 closed properly. Session no longer ducks music (`.mixWithOthers`) — required for DJ use.
- (this commit) **Editor + presets:** Spread slider (Motion), Randomize toggle (Palette), Attack/Decay/Duty-Cycle sliders (Envelope, shape-contextual), beat controls (live BPM readout, Tap/Auto/Sync-1, punch decay, quantize + color step, beats-per-cycle lock); `.compositionMicPermissionDenied` surfaced as a Studio status toast (dead wire closed). Holiday presets upgraded to the new math: Christmas→chase, Winter Wonderland→twinkle, Halloween→comet, Diwali→twinkle, NYE→beat-locked multi-head chase (new-install seeds; existing libraries untouched by design).

Remaining dead wire: `.studioStartMicSync` (Studio mic/gaming cards) — owned by Phase 3, where the performance surface replaces those cards' intent.

On-device additions to the §4 checklist:
- [ ] Play 120–128 BPM music near the phone with a `.beat` composition → BPM readout locks within ~8 s; lights pulse on the beat over DTLS.
- [ ] Tap Tempo 4× → clock pins; "Auto" unpins and re-follows audio.
- [ ] Chase/comet/twinkle/pulseCenter/spiral patterns on the entertainment area — verify spatial character matches the room layout.
- [ ] Spread slider live-morphs cascade from full wash to a tight traveling beam.
- [ ] Sync tab: music from this phone keeps playing un-ducked while sync runs.

## 5. Next phases (approved plan)

- **Phase 2:** unified `AudioAnalysisEngine` (single capture owner, kills the exclusivity handshake) + `AudioFeatureExtractor` (AGC, spectral-flux onset) + `TempoEstimator` (BPM) + `BeatClock`; `CompositionEngine.render` gains `AudioFeatures` + `BeatSnapshot`; dead reaction knobs become real; envelope sliders exposed.
- **Phase 3:** DJ performance surface — `CompositionMixer` (A/B frame-lerp crossfade, punch pads with ≤3 Hz strobe clamp, master fader), full-screen `PerformanceView`, queue.
- **Phase 4:** step sequencer (`CompositionSequence` + `SequencePlayer` reusing the mixer), new motion patterns (chase/pulseCenter/spiral), richer palettes.

Full plan: session plan file (deep-dazzling-prism) — architecture, file map, per-phase validation.
