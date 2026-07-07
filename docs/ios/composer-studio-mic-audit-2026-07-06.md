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

- **Phase 2:** unified `AudioAnalysisEngine` (single capture owner, kills the exclusivity handshake) + `AudioFeatureExtractor` (AGC, spectral-flux onset) + `TempoEstimator` (BPM) + `BeatClock`; `CompositionEngine.render` gains `AudioFeatures` + `BeatSnapshot`; dead reaction knobs become real; envelope sliders exposed. **[SHIPPED 2026-07-06 — see §4b]**
- **Phase 3:** DJ performance surface — `CompositionMixer` (A/B frame-lerp crossfade, punch pads with ≤3 Hz strobe clamp, master fader), full-screen `PerformanceView`, queue. **[Re-sequenced: now lands after Round 3 A+B below, and inherits punchBurst + Tap Dial.]**
- **Phase 4:** step sequencer (`CompositionSequence` + `SequencePlayer` reusing the mixer), new motion patterns (chase/pulseCenter/spiral), richer palettes. **[Motion patterns shipped early in Phase 2.]**

Full plan: session plan file (deep-dazzling-prism) — architecture, file map, per-phase validation.

---

## 6. Round 3 (2026-07-06): Hue capability deep-dive + approved "One Clock, Full Bridge, Two Taps" design

> **STATUS: FULLY EXECUTED same day** — R3-0 docs → R3-A beat panel (7 commits) → R3-B Hue
> power A–G (7 commits) → R3-C Perform → R3-D sequencer, plus DEVLOG entries per milestone.
> Suite 305/305 green. Remaining work is the on-device checklist in §6.3 (physical bridge).

> **Handoff note:** this section + the DEVLOG entry of the same date are sufficient for a fresh
> context window to continue. Approved plan lives in the session plan file (deep-dazzling-prism);
> the design spec artifact (mockups) is published at
> https://claude.ai/code/artifact/52839d43-4209-403f-98d3-b16f073b1ad0.
> Rollback tag for this round: `checkpoint/pre-round3-2026-07-06`.

### 6.1 Capability matrix — what the bridge can do that the app never uses (verified)

1. **`effects_v2`** — current firmware-effect API: per-effect params (`speed` 0–1, `color.xy`, `mirek`) + per-light `effect_values` capability discovery. App sends only the deprecated `effects.effect` enum; Effects-tab param sliders are partly cosmetic (only brightness lands). Four firmware effects entirely absent: **cosmos, enchant, sunbeam, underwater**.
2. **`gradient.points`** — gradient lights (Play gradient strip, Signe, gradient lightstrip) take ≤5 CIE points via plain REST; app treats them as flat single-color bulbs. Entertainment v2 configs can expose gradient SEGMENTS as channels; our config builder makes one channel per light and never segments.
3. **`timed_effects`** — native bridge-side sunrise/sunset with duration; app fakes them with `dynamics.duration` ramps that die with the app.
4. **`signaling`** — alert/on_off/2-color alternating/timed: unmodeled. Free "flash to identify", notification blinks, and a REST-tier punch-pad primitive (**punchBurst**).
5. **Dynamic scene authoring** — scene `palette` (colors/dimming/effects/speed) never written; native dynamic scenes loop on the bridge with zero app involvement.
6. **Sensor/input ecosystem** — `button`, `relative_rotary` (Tap Dial), motion, light_level, temperature, battery: SSE handler filters to light/grouped_light only. Tap Dial = physical DJ controller (rotate → BPM nudge, press → tap tempo, buttons → punch pads).
7. **Dead client code** — `setGroupedLightWithEffect`, `stopLightEffects` (0 callers); `HueLight` decodes no effects/effects_v2/timed_effects/gradient fields.

**Beat/flow gaps (verified):** six timing loops never read BeatClock (Effects-tab strobe/party/thunderstorm + Studio strobe/party/ambient/thunderstorm); beat panel is Composer-only, 3 taps deep; `setBPM`/`nudgePhase` have no UI; pattern/source pickers are 2-tap `.menu`s; transport confirmation dialog fires on every composition apply; deck navigation is swipe-only; no global clock presence.

### 6.2 Approved design (user-confirmed order: Beat panel → Hue power → Perform; Tap Dial IN)

- **R3-A · Universal Beat Panel (7 commits):** new `Core/Audio/BeatBinding.swift` (`BeatBinding{mode, beatsPerCycle ∈ ¼…8, phaseOffsetBeats}` + pure `BeatMath` incl. `wcagSafeBeatsPerCycle` loop-side ≤3 Hz clamp) → new `UI/Components/BeatPanelView.swift` (capability-driven single panel + `BeatStatusChip` + `ChipPickerRow`) → six loops consume `BeatSnapshot` (DTLS per-beat, REST bar-boundary; `bpm==0` → legacy slider math) → chip in Dashboard NowPlaying/Studio mixer header/Effects banner (popover) → two-tap flow fixes (pill pickers, remembered transport dialog, tappable deck header, React auto-anchor). Storage: `EffectParamState.beat` + `SavedEffectPreset.beat?` (nil-additive); Studio via `StudioParamBox` keys; Composer keeps `ReactionConfig`. Rule: never accumulate phase — derive from `BeatClock.snapshot()` per frame.
- **R3-B · Full Hue power (A–G):** A capability foundation (`HueLight` additive decode + `HueAPIClient+Effects/+Signaling/+Gradient` pure body builders + `EffectCapabilityResolver`; delete dead methods) → B effects_v2 cards/real params/coverage badges/400→v1 fallback → C `TimedEffectRouting` (native when all lights support, else app ramp) → D `SignalingService` (identify, AppAutomation blink, punchBurst) → E dynamic scene authoring (`CreateSceneRequest.palette/speed/auto_dynamic`, "Save as Hue dynamic scene" from Composer) → F gradient (**highest risk, last REST feature**: `GradientChannelMap` ≤5 virtual channels/strip, budget 20; builder two-position `service_locations` + refetch-after-create) → G Tap Dial (SSE `button`/`relative_rotary` decode, `subscribeToControlEvents` second stream, pure `ControlMappingEngine` 100 ms rotary accumulator, `PhysicalControlsView` "DJ Mode" template).
- **R3-C · Perform** (per spec artifact; punch pads REST-tier via punchBurst, Tap Dial mappings, `.global` beat panel) → **R3-D · sequencer**.
- **Invariants:** RestSender mailbox + BridgeCommandGate for every REST write; generation counters; WCAG ≤3 Hz loop-side; no app-driven effects payloads to grouped_light; additive Codable only; new logic in new files, orchestrator diffs surgical; build + full suite green per commit.

### 6.3 Round-3 verification plan

Unit: `BeatMathTests` (cycle phase/boundary/WCAG clamp incl. 174 BPM × ½), golden-JSON tests per body builder, spy-client routing tests (v2→v1 fallback, native-vs-ramp, gradient budget), pre-R3 migration fixtures (`beat == nil`), `ControlMappingEngine` accumulator tests.

On-device additions:
- [ ] Beat-locked strobe holds the grid at 128 BPM for 5 min (DTLS room).
- [ ] Effects-tab v2 effect shows a real speed change (not cosmetic).
- [ ] Native sunrise completes with the app force-quit mid-ramp.
- [ ] punchBurst flashes a REST-only room from the Perform pads.
- [ ] Gradient strip runs a chase along its own length.
- [ ] "Save as Hue dynamic scene" keeps looping with the app killed.
- [ ] Tap Dial rotate nudges BPM live; press×4 pins tap tempo.
