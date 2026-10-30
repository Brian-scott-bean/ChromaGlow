# Play Along: implementation design (2026-10-06)

> Status: **implemented on `experiment/play-along` (2026-10-07, build 908)** — P0.1–P0.3 and P1–P6; P0.4
> deferred. What landed, and what was decided while building, is in §13. Not yet verified on hardware.
> Base: `main` @ `9e0de1f` (Luminous + the Spotify experiment, TestFlight 907).
> Scope: the Play Along button, beat and tempo lock that holds, "On the One", song colors, automatic listening, and
> the groundwork for timing compensation. iOS only.

## 0. Decisions on one screen

1. **Predict, don't react.** Every light frame is rendered for the moment it will be seen:
   `evaluate(at: hostNow + lead)` on a predicted beat grid. Nothing waits for a "beat event". The external draft
   plan's `outputTime = beatTime + latencyOffset` makes lights late by construction, so it is reversed here.
2. **Stamp every analysis frame with the time it was captured.** Delivery speed matters less. iOS hands the mic tap
   about 100 ms of audio at a time, and that is fine if every 10 ms analysis frame inside the buffer carries its
   own capture time. The predictive clock absorbs the delivery delay.
3. **Replace the mic tempo tracker.** In the beat lab (§2) today's tracker:
   - picked the wrong tempo on clean synthetic 120/124/128/140 BPM beats;
   - was 79–256 ms off (median) when it did pick the right tempo;
   - claimed a confident beat in noise and speech.
   
   The proposed tracker:
   - picks the right tempo in every test case, except 174 BPM, where it chooses half time on purpose;
   - lands within ~1–4 ms (median);
   - finds "the one" in every rhythmic case;
   - never locks on noise or speech;
   - costs under 1 ms of CPU per second of audio.
4. **Learn each song's beat offset, then remember it.** The music-service drive puts beat 1 at track t=0. Real songs
   start their first beat anywhere, and the mic's corrections and the service's re-anchoring fight each other.
   - Measured: the service alone was up to 130 ms off. Even with the proposed mic tracker added, one case stayed
     ~70 ms off (p90 130 ms).
   - Fix: the mic learns each song's offset (and its downbeat), and `SongMemory` stores both per track.
   - On the second play the room is locked from the first beat.
5. **The clock reports three confidences: tempo, phase and bar.** Each gates its own behaviour:
   - tempo: cycles lock to it;
   - phase: punches and events fire on the beat;
   - bar: changes land on the one.
   
   A weak bar estimate snaps to half bars or beats instead of risking the wrong beat.
6. **Play Along and song colors are pure transforms applied at play time.**
   - None of the 49 looks or any saved look changes, and nothing needs migrating.
   - Preferences live at app level.
   - The transform is deterministic and tested over every preset.
7. **Two small engine additions.** Motion gets the beat lock rhythm already has, and events can start on predicted
   beats instead of trailing detected hits.
8. **Listening follows Play Along.**
   - Turning it on is the consent moment.
   - After that, any look that plays listens automatically, engages on the one when a beat locks, and glides when the
     music stops.
   - Listening is foreground only, as today.
9. **Safety stays upstream and unchanged.** Every derived period obeys the existing flash floors, and every frame
   still passes `Composer2FlashShaper` and the bridge's onset ledger.
10. **Out of scope from the draft plan:** Android, Node.js, REST/WebSocket event APIs, remote flags, staged %
    rollouts and telemetry (§10).

---

## 1. What the code does today (verified by reading `main`)

| Area | Fact | Where |
|---|---|---|
| Mic capture | `.playAndRecord` / `.measurement` / `[.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]`; tap asks for 1024 frames, iOS delivers ~100 ms (4800 @ 48 kHz) | `Core/Audio/MicrophoneAudioSource.swift:75-79, 97`; `AudioFeatureExtractor.swift:138-143` |
| Analysis hop | **One FFT per buffer**, at the largest power of two ≤ frame count. 4096 of 4800 samples are analysed; the last ~15 ms of every buffer never enters the flux | `AudioSpectrumProcessor.swift:77-80` |
| Onset envelope | One value per buffer (~10 Hz), 256-entry ring ≈ 25 s. The "~1 s" adaptive-threshold window is really ~4.3 s at 10 Hz | `AudioFeatureExtractor.swift:64-68, 216-227` |
| Tempo | Autocorrelation over lags 3…11 (60–180 BPM at 10 Hz). Each lag is summed with ±1 neighbours, so 120 BPM (lag 5) also counts 150 and 100 BPM. Phase resolution is one hop = **100 ms** | `TempoEstimator.swift:36-37, 58-79, 154-173` |
| Tempo cadence | Every 500 ms; the result feeds `BeatClock.ingest` | `AudioAnalysisEngine.swift:460-491` |
| Clock | Continuous grid (`bpm`, `beatEpoch`, `beatsPerBar` = 4) read lock-free by render loops. Phase nudges ≤ 30 ms; audio needs confidence ≥ 0.5 | `BeatClock.swift:25-61, 98-100` |
| Bar ("the one") | Never detected. An audio lock anchors the epoch to whatever beat was last; a service drive anchors to track t=0; only a manual `resyncDownbeat` sets the one | `BeatClock.swift:216-219, 288-296, 382-387` |
| Service drive | Puts beat 0 at track t=0; re-anchors on errors > 120 ms; **no confidence or origin gate**. Under a service hold the mic may only nudge phase | `BeatClock.swift:275-321, 341-364` |
| Live estimate as "service" | When no lookup answers, the resolver returns the mic's own guess (`.liveEstimate`). The coordinator then drives the clock with it as a service tempo, which freezes a possibly wrong tempo for the whole track. Because the clock now reads "service-driven", `.beat` looks also release the mic | `TrackTempoResolver.swift:170-172`; `MusicSessionCoordinator.swift:146-149`; `CompositionModels.swift:620-622`; `UnifiedOrchestrator.swift:6175-6194` |
| Engine clocks | `hostNow` (`CACurrentMediaTime`) drives beat maths; `time` (`CFAbsoluteTime` since start) drives motion and free rhythm | `Composer2Engine.swift:199-208, 258-284, 335-376`; `UnifiedOrchestrator.swift:6857-6902` |
| Beat lock | Rhythm has it (`quantizeBeats`, cycle doubling under the flash floor). **Motion does not** | `Composer2Rhythm.swift:41-42`; `Composer2Engine.swift:335-348`; `Composer2Motion.swift` |
| Mic demand gap | `usesBeatClock` counts only layers whose sound source is `.beat`. A beat-locked rhythm requests no mic and silently runs free | `Composer2Models.swift:257`; `Composer2LiveOutput.swift:195-199` |
| Render loop | DTLS: renders "now", then sleeps 40 ms after the work (≈ 23–25 fps, drifting). REST: one room per 120 ms tick, 200 ms transitions, 100 ms per command. **No output-latency lead anywhere** | `UnifiedOrchestrator.swift:6848-6940, 8088`; `BridgeCommandGate.swift:19` |
| Safety | `Composer2FlashShaper` slows rises to the 0.34 s onset budget before the ledger; it never adds light | `Composer2LiveOutput.swift:204-283`; `BeatBinding.swift:120-191` |
| Zero-length fades | `setLightEffect` omits `dynamics` when duration is 0, so per-light "instant" writes get the bridge default fade. Seven `EffectEngine` call sites pass 0 | `HueAPIClient.swift:659`; `EffectEngine.swift:104-273` |
| Album colors | RGB k-means → 3-colour v1 `PaletteConfig`, applied only to Studio Classic. The Composer tab's strip passes no `onUseAlbumColors`, so the art button there is disabled | `ArtworkPaletteExtractor.swift:39-65`; `NowPlayingBar.swift:198-237`; `ComposerLibraryHome.swift:279-285` |
| Looks that react | 2 of 49 (Beat Drop, Club Pulse). Tune has no sound control | `Composer2Presets+World.swift:275-305`; `Composer2TuneView.swift:24-31` |
| Auto-listen | None. The source is not persisted; the only activation is the picker | `AudioAnalysisEngine.swift:67-69`; `MusicSourcePicker.swift:271` |
| Telemetry, remote flags | None. Privacy manifest declares no data; flags are compile-time | `PrivacyInfo.xcprivacy`; `Core/FeatureFlags.swift` |
| Android | No Composer 2, audio or music code; no `RECORD_AUDIO` | `android/app/src/main/AndroidManifest.xml` |

## 2. What the beat lab measured

`docs/ios/play-along/beatlab/` compiles the app's own, unmodified `AudioSpectrumProcessor`,
`AudioFeatureExtractor`, `TempoEstimator`, `BeatClock` and `MusicSource` into a Mac command-line tool. It feeds them
the same 4800-frame buffers and the same 2 Hz tempo pass the device runs.

- **Test audio:** deterministic synthetic room audio:
  - kick, snare and hats; bass on the beats; a chord change every bar;
  - Schroeder reverb, a phone-mic band-pass (120 Hz–9 kHz) and pink noise.
- **Comparison:** the prototype tracker of §5.2 runs on the identical audio.
- **Scoring:** at every true beat, the grid the lights would have used at that moment (no hindsight).
- **Reproduce:** `docs/ios/play-along/beatlab/run.sh`. Full output is in `results-2026-10-06.txt`.

| Case (first 10 s of each song excluded) | Today: tempo | Today: beat error (median) | Proposed: tempo | Proposed: error (median / p90) | Proposed: bar 1 right |
|---|---|---|---|---|---|
| 120 BPM rock | half (60) | — | right | 0.7 / 0.7 ms | 100 % |
| 128 BPM rock | wrong | — | right | 4.0 / 6.6 ms | 100 % |
| 100.5 BPM rock | right | 79 ms (lights late) | right | 1.2 / 3.7 ms | 100 % |
| 87 BPM rock | right | 202 ms | right | 2.1 / 3.4 ms | 100 % |
| 140 BPM rock | wrong | — | right | 3.7 / 8.5 ms | 100 % |
| 124 BPM house (four on the floor) | wrong | — | right | 1.9 / 5.0 ms | 100 % |
| 120 BPM, noise at −12 dB | half | — | right | 0.7 / 0.7 ms | 100 % |
| 96 BPM swung 8ths | 83 % right | 256 ms | right | 0.7 / 2.9 ms | 100 % |
| 112 BPM live drummer, ±2 % drift | 9 % right | 128 ms | follows | 10.4 / 46 ms | 100 % |
| Song change 128 → 96 | 28 % right | 133 ms | right | 1.7 / 5.7 ms | 100 % |
| 174 BPM DnB-style | half / wrong | — | half time (87), deliberate | — | — |

| Not music | Today claims a confident beat | Proposed claims a confident beat |
|---|---|---|
| Speech-like noise bursts | 99 % of the time | 0 % |
| Pink noise only | 64 % | 0 % |
| Ambient pad (one chord per bar, no drums) | 100 % | 43 % (bar-rate pulse; threshold to tune on device) |

**Music-service drive (Apple Music / Shazam) vs the mic.** Track position 0 = audio start, real BPM given. Rows are
phase error (median, lights late):

| Song's first beat at | Service only | Service + today's mic | Service + proposed mic |
|---|---|---|---|
| 0.37 s (120 BPM) | 130 ms | 95–110 ms | still ~70 ms (p90 130 ms): the two drives fight |
| 0.05 s (128 BPM) | 50 ms | 34 ms | 9 ms (p90 29 ms) |

- **Lock time:** proposed tracker, mic only, from a cold start: 5–7 s. A second song locked 10 s in, against a target
  of under 5 s; the change detector of §5.2 is what closes that gap.
- **CPU:** 0.8 ms per second of audio. That is the unoptimised prototype on an M-series Mac, so expect a few times
  more on iPhone, which is still a fraction of a percent.

**What this does and doesn't prove.**
- Synthetic audio is kinder than a real room, so the proposed tracker's numbers are a best case.
- The finding is the *gap*: today's tracker fails on the easiest material, and does so with a confident flag set.
- The 4.3 s threshold window, the 10 Hz envelope with ±1-lag smoothing, and the kick-weighted flux explain the
  failures. Kick dominance pulls rock toward half time.
- On-device numbers must come from the device plan in §8.

## 3. The design in one picture

```
mic tap (~100 ms buffers, AVAudioTime)
  ├─ legacy per-buffer features (unchanged: Sync tab, levels, punches)
  └─ OnsetFrameAnalyzer: 10 ms frames, each stamped with its capture time
        ├─ TempoInduction (2 Hz, last 8 s, comb + prior; SongMemory/metadata prior)
        ├─ PhaseTracker (comb phase at 2 ms, type-2 PLL)
        └─ BarTracker (kick-vs-snare + harmonic change, folded on the bar)
                 │  BeatObservation {period, lastBeat, tempoConf, phaseConf, barShift, barConf}
Music session ─► SongMemory (track → bpm, beat offset, downbeat, route) ─┐
                                                                         ▼
                        BeatClock v2: one predictive grid, three confidences, PLL correction
                                                                         │ BeatSnapshot (lock-free mirror)
                     OutputLatencyModel: lead = light latency + ½ frame + user offset (per transport, per bridge)
                                                                         ▼
Composer2LiveOutput.renderFrames(time, hostNow)
   ├─ PlayAlongDirector  (engage on the one, coast, release)
   ├─ Composer2PlayAlong.apply(look, feel, tempo)  ─┐  pure, cached
   ├─ Composer2AlbumPalette.apply(swatches)        ─┘
   ├─ pending transition (lands on the one)
   └─ Composer2Engine.evaluate(at hostNow + lead) → FlashShaper → ledger → DTLS / REST
```

## 4. The timing model

**Musical time.**
- `m(t) = (t − E) / P` is beats since an epoch `E` that is a downbeat, with period `P`.
- Beat k falls at `E + kP`; bar b starts at `E + 4bP`.
- Everything musical reads `m` at a time. Nothing counts events.

**Three latencies, one direction each.**

| Term | What | How it enters |
|---|---|---|
| `L_in` | Sound in the room → the capture stamp | Subtracted from each `OnsetFrame` stamp. Start from `AVAudioSession.inputLatency`; calibrate on device |
| `L_route` | A player's position → sound in the room (AirPlay ≈ seconds, Bluetooth ≈ 150–250 ms) | Only for service grids. **Learned** from mic-vs-service offsets per output route; never assumed |
| `L_out` | Frame emitted → photons. The bridge forwards to bulbs over Zigbee at 25 Hz, and bulb firmware smooths entertainment transitions | Added to render time: `lead = L_out + ½·(bridge period, 40 ms) − userOffset` |

- **Render-ahead.** The DTLS loop emits at `e` and the light shows that frame at `e + L_out`. Rendering musical time
  `m(e + lead)` makes the room show the beat when the room hears it.
- **Frame quantisation.** The half-period term centres the error at ±20 ms instead of always late.
  - The bridge's 25 Hz Zigbee output, not the app's send rate, sets the period.
  - Sending at 50 Hz still helps: it is what Hue recommends against UDP loss. It does not sharpen timing.

**Why not "beat + offset".**
- A mic onset is known ≥ 100–250 ms after it happens (buffer, threshold, tempo pass), and a light takes `L_out` more.
- Firing on detection is therefore always late by their sum, and no offset can fix that without prediction.
- With prediction, detection delay only slows *relocking*, never the *timing*.

**Perceptual target.**
- People notice sound arriving before the picture at about 45 ms and accept it up to about 90 ms. Sound after the
  picture is tolerated far longer (ITU-R BT.1359).
- Lights late = "sound early", the strict side. Aim lights at **0 to 25 ms early**; never late by more than 40 ms.

**Three confidences** (published in `BeatSnapshot`):

| Confidence | Comes from | Unlocks |
|---|---|---|
| tempo | Tempo induction, or a metadata/memory BPM | Cycles lock to bars (Glide) |
| phase | Mic phase coherence, or `SongMemory` offset for this track and route | Beat punches, beat events, palette steps |
| bar | Bar tracker, `SongMemory` downbeat, or a tap on "the one" | Changes land on the one. When it is low, snap to half bars, and below that to beats |

## 5. Components

Each one lists files (respecting `Composer2LabGuardTests`), the API and its tests. New files are registered with the
existing Ruby scripts (`add_composer2_files.rb`, `add_music_files.rb`; audio files alongside the existing
`Core/Audio` entries).

### 5.1 `OnsetFrameAnalyzer` (new, `Core/Audio/OnsetFrameAnalyzer.swift`)

- **Where it runs.** Inside `AudioPCMSink.deliver` on the audio thread, after the legacy extractor. The legacy
  features, and therefore the Sync tab, are untouched.
- **Capture path.**
  - `installTap` is deprecated in the iOS 27 SDK. Its documented range is 100–400 ms, and on AirPods' 24 kHz route
    the device really delivers 200 ms.
  - Plan the move to `AVAudioSinkNode` (iOS 13+, real-time, I/O-sized buffers of 5–20 ms) as its own commit after
    P1 lands. Because frames are stamped with their capture time, the tracker doesn't care which path feeds it.
  - The sink node does make relock and off-grid reactions faster.
  - It needs a real-time-safe publish: today `publish` takes an `NSLock`; use an SPSC ring or `os_unfair_lock`.
  - It also needs a preallocated `AVAudioPCMBuffer` view for the Shazam and Sync fan-out, because the sink node
    hands over raw `AudioBufferList`s.
- **Framing.** 10 ms hop (480 @ 48 kHz; `round(fs·0.01)` generally), 1024-point Hann window, ring history (no
  per-sample shifting), `vDSP` FFT.
- **Bands.** The lab used 18 log-spaced bands (30 Hz–16 kHz), `log1p(γ·E)` and half-wave-rectified flux.
  - Production moves the onset function to the semitone filterbank with a max filter (§5.2, front end).
  - The 18-band vectors stay for the bar tracker's chord-change cue.
  - Low / mid / high band fluxes are kept alongside.
- **Stamp.** `bufferStart (AVAudioTime.hostTime) + (sampleIndex − window/2)/fs − L_in`. This is the per-frame
  version of what `captureMidpoint` does per buffer (`AudioFeatureExtractor.swift:232-243`).
- **Output.** A preallocated single-writer ring of `OnsetFrame {t, flux, low, mid, high, bands[18]}` holding about
  12 s, copied out under `os_unfair_lock` exactly like `onsetEnvelopeSnapshot()`.
- **Constraints.** No allocation once warm, the same real-time contract as the extractor, and raw audio never stored.
- **Tests.**
  - Click at a known sample gives a frame stamp within ±2 ms.
  - Sample-rate changes (44.1/48 kHz, HFP 16 kHz) keep stamps exact.
  - No allocations in steady state.

### 5.2 `BeatTracker` (new, `Core/Audio/BeatTracker.swift`, pure)

The beat lab's prototype (`beatlab/TrackerV2.swift`), productionised. The literature (§12) says the onset front end
matters more than the tracker behind it, so the front end is upgraded before tuning anything else.

- **Front end.** Use log-filtered spectral flux: semitone filterbank, log magnitude, half-wave-rectified difference.
  - Böck et al. 2012 measured it best among online onset functions, 80.3 F vs 74.5 for plain flux.
  - Add SuperFlux's 3-bin max filter across frequency, which suppresses vibrato and reverb tails.
  - Keep a separate kick band below 150 Hz.
  - Keep the onset function continuous all the way through. Reverb hurts trackers that pick discrete onset peaks
    much more (Mauch & Ewert's "live recording" degradation).
- **A challenger in the lab.** Port real-time PLP (Meier, Chiu & Müller, TISMIR 2024, MIT) into the beat lab next to
  the comb-phase tracker below.
  - It is causal, zero-latency, and comes with a stability value that is a natural phase confidence.
  - Predicting ahead with it costs almost nothing (116 ms of lookahead costs 0.41 F points).
  - Ship whichever wins on Brian's in-room recordings.

- **Tempo induction** (every 0.5 s, last 8 s):
  - Detrend with a 0.5 s moving average, then rectify.
  - Autocorrelate, then score a 4-harmonic comb on a 0.25 BPM grid with fractional lags.
  - Apply a log-Gaussian prior (centre ~115 BPM, σ 0.9 octave). It prefers the "lighting tempo" 80–160, so a
    174 BPM track locks at 87 on purpose.
  - When `SongMemory` or a lookup knows the BPM, the prior becomes narrow Gaussians at that BPM and its ×½ and ×2.
  - Hysteresis: a metric flip (×2, ×½, ×1.5, ×⅔) needs 8 consecutive wins; anything else needs 3.
- **Phase.**
  - Comb phase search at 2 ms resolution over the last 12 beats, with 0.85ᵏ recency weights and the *exact*
    fractional period.
  - `phaseConfidence` is the normalised autocorrelation at the period, gated by the circular coherence of recent
    onsets.
- **PLL.** A type-2 correction: phase gain ~0.3 per pass, still capped at 30 ms so lights never jump. The period
  integrates phase error, which follows a live drummer between induction passes. The lab's naive version did not yet
  improve the drift case; tune this first.
- **Bar.**
  - Fold the last 16 beats onto 4 slots and score `H + 0.8·K`:
    - `K` = low-band minus high-band flux at each beat. Kick vs snare separates {1,3} from {2,4}.
    - `H` = cosine distance between consecutive level-normalised beat-synchronous band vectors in 281 Hz–2.8 kHz.
      Chord and texture changes mark bar lines and separate 1 from 3.
  - A bar re-label shifts the epoch by **whole beats only** and needs the same shift on 3 passes in a row.
  - The first version, raw rising flux, picked the snare. The cosine form fixed it: lab 0–47 % → 100 %.
  - **Expect less in real rooms.** Causal downbeat tracking scores only 46–57 F even with neural networks, against 78
    offline. Goto's chord-change cue placed the bar correctly in 66 of 73 songs, but only once the beats were
    already right, and after 18–22 s.
  - That is why "On the One" falls back to half bars and beats, why "Tap the one" exists, and why `SongMemory` keeps
    the answer.
- **Change detection.**
  - Silence of 0.8 s or more, by RMS gate, resets the induction window.
  - So does a different tempo winning 4 passes with good confidence.
  - Target relock: under 5 s.
- **Tests.** Port the lab into XCTest (`BeatTrackerTests`) with the deterministic synth. Assert:
  - tempo within 2 %, octave-equivalent allowed above 160;
  - median phase ≤ 10 ms and p90 ≤ 25 ms;
  - bar ≥ 90 % on the bar-changing synth;
  - ≤ 5 % confident passes on noise or bursts;
  - lock ≤ 7 s.

### 5.3 `BeatClock` v2 (modify `Core/Audio/BeatClock.swift`)

- **`BeatSnapshot`** gains `tempoConfidence`, `phaseConfidence` and `barConfidence`. The change is additive, so every
  render loop keeps compiling.
- **`ingest(_ observation: BeatObservation)`** replaces the `TempoEstimate` path:
  - same pin and tap rules;
  - the type-2 correction law;
  - whole-beat bar shifts.
- **The service drive becomes two-dimensional:**
  - `driveFromTrack(bpm:origin:position:beatOffset:downbeat:)`.
  - Only metadata origins (hint, provider, cached, memory) may take the service hold. **`.liveEstimate` never
    does.** This alone fixes the frozen-wrong-tempo bug.
  - The anchor is `trackZero + beatOffset`, from `SongMemory` or learned live, not t=0.
  - While the offset is unknown, the service owns tempo and the mic owns phase, so nothing fights.
- **The mic stays wanted** while Play Along is on, even when a service drives. The phase needs it until the song's
  offset is known.
- **Tests.**
  - Extend `BeatClockServiceDriveTests`:
    - a live estimate never takes the hold;
    - a memory offset anchors the grid exactly;
    - the lab's "tug of war" case ends within 10 ms.
  - Add PLL convergence tests on the drift synth.

### 5.4 `SongMemory` (new, `Core/Music/SongMemory.swift`)

- **Key.** `TempoQuery.cacheKey` (ISRC, then Apple Music ID, then title and artist) plus an output-route
  fingerprint.
- **Value.** `bpm`, `beatOffset` (beat 0 relative to track t=0, in `[0, P)`, acoustic domain), `downbeatSlot`
  (0–3), confidences, observation count and `updatedAt`.
- **Learning.**
  - Only while a service position is live and the mic is phase-locked.
  - A circular mean over observations, weighted by phase confidence.
  - Stored after 8 consistent bars.
- **Persistence.** The `tempo-cache.json` idiom: tolerant decode, `.atomic`, bounded (oldest out at 1000).
  Derived numbers only; no audio.
- **Keys are hashed.** Store SHA-256 of the cache key, so the file holds no readable listening history. Apple's Media
  Player guidance: "Don't gather information about the user's audio content for any other purpose." This memory
  serves only the sync it was learned for.
- **Why the route is in the key.**
  - iOS does not tell this app the latency of another app's AirPlay route; this session's `outputLatency` describes
    *our* route.
  - So the learned offset is "track + route". The same song on the same speakers is instant; new speakers relearn in
    seconds.
  - Verify on device whether `currentRoute` reflects the Music app's AirPlay route while our session is active.
- **Tests.** Learn, persist and apply; tolerant decode; route mismatch triggers relearn, not reuse.

### 5.5 `OutputLatencyModel` (new, `Core/Audio/OutputLatencyModel.swift`)

- **`lead(transport:bridgeID:) = L_out(transport) + ½·bridgePeriod − userOffset(bridgeID)`.** `bridgePeriod` is
  40 ms for Entertainment's 25 Hz Zigbee output.
- **Defaults** (calibrate in the device plan):
  - Entertainment `lead` starts at **100 ms**: about 80 ms of light latency plus 20 ms for the bridge's 25 Hz output.
    - Signify publishes no latency figure. The 80 ms is community-measured "video-to-light" and may already include
      part of the Zigbee step.
    - Treat 100 ms as a starting point; the slo-mo measurement in §8.1 replaces it.
    - For comparison, SonicHue's slider defaults to 110 ms and Music Assistant's to 20 ms.
  - REST: not beat-accurate (§5.9).
- **User offset.** Per bridge, in `UserDefaults` (`playAlong.lightTimingMs.<bridgeID>`). The UI says "Light timing:
  earlier ↔ later"; negative is earlier (a longer lead), range −300…+150 ms. Build 908 added the offset, so
  "earlier" made the lights later; build 909 subtracts it.
  - Every serious rival has one: the Hue app's Latency setting, Hue Sync's configurable delay, SonicHue's slider, and
    iLightShow's and Lumina's automatic calibration.
  - Calibration ("Sync Check") is the next campaign; the slider and the storage are this one.
  - Sync Check measures the *light* path with the camera (§8.1, automated), which no rival documents.
- **Wiring.**
  - The orchestrator already knows the transport. It sets `paramBox.outputLead` when a composition starts.
  - `Composer2LiveOutput.renderFrames` renders at `hostNow + lead` and `time + lead`.
  - `Core/Composer2` never reads a clock (guard 53-63); it receives `hostNow`.
- **Pacing.**
  - Switch the DTLS composition loop to deadline pacing with `ContinuousClock` (`next += interval; sleep(until:)`).
    Sleeping 40 ms *after* the work drifts.
  - Allow 50 fps while Play Along is engaged, for loss resilience (Hue recommends 50–60 Hz). Studio's flash loops
    already run on the 20 ms grid.
- **Preview.** The hero card mirrors live frames. Delay the mirror by `lead` so the screen matches the sound.

### 5.6 Play Along transform (new, `Core/Composer2/Composer2PlayAlong.swift`, pure)

`Composer2PlayAlong.apply(_ look: Composer2Composition, feel: Feel, bpm: Double, beatsPerBar: Int) -> Composer2Composition`
- **Identity.** Same layer IDs, so engine state realigns without resets.
- **Caching.** Cached in `Composer2LiveOutput` per (revision, feel, bpm at engage). The bpm is re-picked only on song
  change, so cycles never re-quantise mid-song.
- **Helper.** `beatsFor(seconds)` is the nearest power of two, in log space, of `seconds × bpm / 60`, within 1…64
  beats.
- **Locking rule** (it protects each look's character):
  - **Groove and Hit:** lock every cycle up to 64 beats (16 bars) to `beatsFor(period)`. The period may move by up
    to a factor of √2; these feels are meant to become musical.
  - **Glide:** lock a cycle only when a musical length lies within ±20 % of the authored period. Otherwise it stays
    free.
  - **Calm looks** (the Calm category): no locking at all, only the loudness swell. The preset lab showed ±20 % would
    still turn Breathing Calm's 10 s breath into 8 s at 120 BPM: "six breaths a minute" becoming 7.5.
  - **Any feel:** cycles longer than 64 beats stay free. A 60–120 s ambient drift is not felt as a tempo, and
    compressing it would only make it busier.
  - **Measured on the 49 built-in looks** (73 rhythm and motion cycles), compiled from `Core/Composer2` with a
    colour-clamp stub:

    | Tempo | Stay free (> 16 bars) | Groove / Hit lock | Largest speed change | Glide locks |
    |---|---|---|---|---|
    | 96 BPM | 14 | 59 | ×1.40 | 40 |
    | 120 BPM | 20 | 53 | ×1.38 | 33 |
    | 128 BPM | 20 | 53 | ×1.36 | 27 |

| Rule | Glide | Groove (default) | Hit |
|---|---|---|---|
| Rhythm cycle (breathe, swell, pulse, heartbeat, burst) → `quantizeBeats = beatsFor(period)` | ✓ | ✓ | ✓ |
| Motion cycle → new `motion.quantizeBeats` (march: one light step per beat; Glide: per 2 beats) | ✓ | ✓ | ✓ |
| Flicker, candle and twinkle stay free (texture, not tempo) | ✓ | ✓ | ✓ |
| Base layer swells with loudness (amplitude, slow smoothing, gentle) | ✓ | ✓ | ✓ |
| Accent layers punch on the beat (`.beat`, decay ≈ 0.35 beat) | — | ✓ | ✓ |
| Palette steps | — | every bar | every 2 beats |
| Base layer punches on every beat | — | — | ✓ |
| Event layers fire on predicted beats (fireworks and lightning on downbeats), chance × energy | — | — | ✓ |

**Guards.**
- **Authored sound stays.** A layer that already reacts to sound (Beat Drop, Club Pulse) keeps its sound settings;
  only cycles lock.
- **Slow looks clamp to Glide.** That means every period ≥ 8 s and no events. Calm-category looks go further:
  loudness swell only, no locking (see the locking rule above).
- **Fast songs punch every 2 beats.** Above 170 BPM, per-beat punches drop to every 2 beats, in the spirit of
  `wcagSafeBeatsPerCycle`. The engine's period doubling, the shaper and the ledger stay authoritative.

**Engine changes (two, both additive, tolerant decoding like every other field).**
1. **`Composer2Motion.quantizeBeats: Double = 0`.**
   - When it is locked and the clock runs, motion time comes from beats: `nt = beats / lockedBeats`, doubled until
     the period clears the motion floor.
   - Speed jitter and sound-driven speed warp are ignored for a locked motion; phase jitter (spatial variety) stays.
2. **`Composer2EventSpec.beatSync: Double = 0`** (beats; 4 = downbeats).
   - When the clock's beat index (at the rendered `hostNow`) crosses a multiple, the schedule gets a forced
     opportunity.
   - That is the existing `forceOpportunity` path, with chance = authored probability × energy and the same seeded
     draws.
   - Events then *start* on the beat instead of trailing a detected hit by 100–250 ms. The existing
     `triggerEventsOnOnset` stays for off-grid hits.

**Tests.** For all 49 presets and every feel:
- periods are legal;
- colors are unchanged;
- the transform is deterministic and idempotent;
- slow looks stay Glide and Calm looks are never re-timed;
- frames pass the shaper with zero holds at 60–180 BPM;
- `Composer2LabPresetTests` still holds ≤ 3 Hz.

### 5.7 On the One (new: `Core/Composer2/Composer2Quantizer.swift` and `Core/Composer2/Composer2LandingSource.swift`)

- **Boundary.**
  - `Composer2Quantizer.boundary(after: hostNow + lead + preroll, snapshot:)` returns the next bar.
  - When bar confidence is low it returns the next half bar (1 or 3); when that is low too, the next beat.
  - The wait is at most one bar. A second tap means "now".
- **What lands on it.**
  - switching looks while one plays;
  - Play Along on/off;
  - Feel changes;
  - the song-colors swap on a track change.
- **How, for a look switch.**
  - Today `Composer2PlaybackCenter.adopt` swaps the *whole* frame source at once: `box.frameSource = newOutput`, and
    each document owns its own `Composer2LiveOutput` (`Composer2PlaybackCenter.swift:318-341`).
  - So the switch installs a `Composer2LandingSource: CompositionFrameSource` that wraps both outputs.
  - On its first `renderFrames` it computes the boundary from the `hostNow` and snapshot it is handed. Core keeps
    reading no clocks.
  - It renders the outgoing look until the preroll, then crossfades over `min(⅛ bar, 250 ms)` ending exactly on the
    boundary, then delegates to the incoming output.
  - The playback center's heartbeat replaces it with the plain incoming output afterwards. It also defers
    `releaseLiveGeometry()` on the outgoing output until then.
- **How, inside one look.** For Play Along on/off, Feel and song colors, `Composer2LiveOutput` holds the same kind of
  pending transition between its plain and derived compositions.
- **UI.**
  - Beat dots in the hero badge row, using the `barMeterRow` pattern from `BeatPanelView.swift:237-261`.
  - A light haptic on each counted beat, fired at the predicted beat time.
  - **"Tap the one"**: a tap on the dots when the room's one is wrong. It shifts the bar by whole beats and writes
    the downbeat to `SongMemory`.
- **Tests.**
  - Boundary maths with half-bar and beat fallbacks.
  - Maximum wait.
  - The crossfade ends on the boundary to within 1 ms of render time.

### 5.8 Song colors (modify `ArtworkPaletteExtractor`; new `Core/Composer2/Composer2AlbumPalette.swift`)

**Extraction v2.**
- k-means in OKLab, k = 6 on 48×48, weighting = population × (0.2 + chroma).
- Merge clusters closer than ΔE_ok 0.06.
- Roles:
  - `dominant`: largest chromatic cluster;
  - `accent`: chroma × √population, at least 30° from the dominant;
  - `support`: the rest.
- Near-greyscale covers become tinted whites (warm or cool from mean b*), instead of grey light.
- The v1 `PaletteConfig` output stays for Studio Classic.

**Transform.**
- Each layer keeps its stop count and its own hue ordering. Stops are re-assigned from the swatches by role:
  - base layers get dominant → support;
  - accent and event colors get the accent.
- Near-white stops (chroma < 0.04) stay white, so the mirror ball and lightning keep their character.
- Saturation, warmth, distribution and interpolation are untouched.

**Delivery.**
- Fires on a track change, landing on the one.
- **Sources.**
  - Apple Music: MusicKit's `Artwork.backgroundColor` and text colours are a free fast path when present. They are
    often nil in practice, in which case the artwork URL is extracted.
  - Shazam: `artworkURL`. Demo art is generated in-process.
  - **Never Spotify.** Its terms forbid analysing content and making derivative works of cover art.
- **Apple 4.5.2(ii):** cover art may be used "only in connection with music playback". Song colors exist only while
  that track plays; no gallery of past covers.
- The Composer tab's strip finally passes `onUseAlbumColors`, which toggles song colors. The closure lives in
  `UI/Composer2` (guard 152-164).

**Tests.**
- Synthetic images:
  - a solid colour;
  - a two-colour split;
  - a small vivid accent on a dull field (the accent must win a role);
  - greyscale (tinted whites).
- The transform preserves structure.

### 5.9 The REST path (honest scope)

Per-light REST cannot be beat-accurate: 100 ms per command, 200 ms transitions, rooms swept in rotation.

- **Play Along on REST runs Glide only.** Cycles are bar-locked and there are no punches. Each bar's state is sent
  early by `transition + L_rest`, so the fade *completes* on the bar line.
- **Fix the zero-duration write.** Send `dynamics.duration: 0` explicitly. This makes `EffectEngine` flashes really
  instant, so re-check them against the flash rules in the same commit.

### 5.10 Listening that starts on its own

- **New demand.** `AudioAnalysisEngine.AudioDemand.playAlong`, held while Play Along is on and a look plays.
- **Consent.** The first Play Along tap is the consent moment.
  - A short sheet comes first: "Play Along listens for the beat. Nothing is recorded or leaves your phone."
  - Then the system prompt.
  - If denied, Play Along still works from Apple Music, Shazam or tapped tempo, and says so.
- **Preferences** (app-level, `@AppStorage` in `UI/Composer2`): `playAlong.enabled`, `playAlong.feel`,
  `playAlong.songColors` and `playAlong.onTheOne` (default on).
- **Lifecycle** (`PlayAlongDirector`, pure, ticked by `hostNow`):

  | Stage | Behaviour |
  |---|---|
  | Waiting | Plain look; the chip says "Listening…" |
  | Engage | When tempo and phase lock, on the one |
  | Coast | After a dropout: grid holds for up to 8 bars, accents fade within a beat |
  | Release | After 20 s with no beat, back to the plain look on the one |
  | Re-engage | When music returns |

- **Music awareness without the mic.**
  - `secondaryAudioShouldBeSilencedHint`, and its notification, says another app with a *non-mixable* session (music
    apps) is playing. It is delivered only while we are foreground with an active session.
  - That is a better "music started on this phone" signal than `isOtherAudioPlaying`, which also counts ambient
    sounds.
  - For Apple Music, the active MusicKit source's playing state does the same. iLightShow auto-starts exactly this
    way.
  - **Recording can never start from the background** (a privacy block since iOS 12.4, re-confirmed by Apple DTS in
    2026). Every auto-start begins in the foreground.
- **Background.** Capture stops as it does today.
  - A session started in the foreground *may* continue in the background with the `audio` mode.
  - SonicHue and Lumina Pro advertise locked-screen sync, so App Review appears to accept it.
  - Guideline 2.5.4 lists "audio playback" as the purpose, though, so this stays its own decision, not part of
    this campaign.
  - Build 907 (Debug-SpotifyExperimental) already carries `audio`; Release does not.
- **Fix the existing gap.** A beat-locked rhythm or motion counts as "uses the beat clock", so mic demand follows
  (`Composer2Models.swift:257`).

## 6. The experience (Luminous)

- **One button.** "Play Along" goes in the Composer library hero's button row (`ComposerLibraryHome.swift:240-256`),
  the instrument's performance bar (`Composer2PerformanceBar.swift:53-76`) and the room page's playing card
  (`ComposerRoomLooks.swift:150-159`).
  - Tap toggles it.
  - Long-press opens the sheet: Feel (Glide · Groove · Hit), Song colors, On the One, Light timing.
- **States, in plain words.**
  - "Listening…"
  - "♩ 124": locked, with beat dots.
  - "Lands on the one ●●●○"
  - "Following Apple Music"
  - "Remembered": instant lock from `SongMemory`.
  - The jargon guards apply: no "onset", "channel", "REST" or "DTLS".
- **Calm by default.** Groove is the default feel. Slow looks clamp to Glide, and Calm looks only swell. Hit is
  opt-in.
- **Screen vs room.** The screen pulses at `hostNow`, which matches the sound. The lights render at `hostNow + lead`,
  so they also land on the sound.

## 7. Safety and privacy

- **Flash rules are unchanged and still authoritative.** That covers the shaper, the ledger, the system Dim Flashing
  Lights cap, and fast tempos dropping to every 2 beats.
- **Nothing new leaves the phone.**
  - Analysis stays on the device.
  - `SongMemory` stores derived numbers per track ID.
  - Song colors use artwork the source already fetches.
  - Shazam identification remains an explicit choice; song colors does not silently turn it on.
- **Guideline 2.5.14** needs explicit consent and a clear indication while recording. The consent sheet, the
  system orange dot and the "Listening…" chip cover it.
- **ShazamKit:** displaying matched metadata requires an Apple Music link. Check that the now-playing strip's
  "Heard nearby" row carries one (§11). The issue already exists today and is not new with this work.
- **No telemetry.** The Debug-only Beat HUD (bpm, three confidences, lead, phase error against tapped beats) replaces
  the draft plan's analytics.

## 8. Testing

- **Unit (XCTest):**
  - `OnsetFrameAnalyzerTests`, `BeatTrackerTests` (lab cases plus the noise and burst false-lock cases)
  - `BeatClockServiceDriveTests` (extended), `SongMemoryTests`
  - `Composer2PlayAlongTests` (all presets × feels), `Composer2QuantizerTests`, `Composer2AlbumPaletteTests`
  - `PlayAlongDirectorTests`
- **Beat lab:** run in place before and after every tracker change. Its table is the regression record.
- **Real-room scoring.** Use mir_eval-style beat F-measure, CMLt and AMLt on Brian's own phone-in-room recordings,
  with `min_beat_time = 0`.
  - Published benchmarks drop the first 5 s, so they hide lock time; this keeps it.
  - The recordings stay on the Mac and never go into this public repo.
- **Device** (Brian's iPhone, test room Main bathroom, mirroring recipe):
  1. **Latency.** Play a 120 BPM click from a speaker. Film one bulb and the speaker in 240 fps slo-mo (4 ms per
     frame) and read the light-vs-click offset. Set the Entertainment default from it.
  2. **Real songs.** Pop, hip-hop, house, rock, a ballad, DnB, swing, plus talking over music and TV dialogue alone.
  3. **Pass criteria:**
     - lock ≤ 8 s;
     - lights between 25 ms early and 40 ms late;
     - no punches on speech or TV;
     - On the One on bar 1 in ≥ 80 % of pop and dance, and never worse than half-bar elsewhere;
     - a second play of a song locks within one bar.

## 9. Build plan

**Process.**
- Branch `experiment/play-along` off `main`, checkpoint tag `checkpoint/pre-play-along`.
- One commit per item, with its tests.
- Build numbers > 907; DEVLOG entry per round; internal TestFlight.

| # | Commit | Size |
|---|---|---|
| P0.1 | `fix(beat)`: a live mic estimate never takes the music-service hold | S |
| P0.2 | `fix(composer2)`: beat-locked rhythm requests the beat clock (mic demand) | S |
| P0.3 | `fix(output)`: the DTLS composition loop paces to deadlines | S |
| P0.4 | `fix(api)`: zero-duration per-light writes are instant (with the flash re-check) | S |
| P1 | `OnsetFrameAnalyzer` + `BeatTracker` + `BeatClock` v2 (three confidences, PLL) + lab tests | L |
| P2 | `OutputLatencyModel` + render-ahead in `Composer2LiveOutput` + Light timing + Beat HUD | M |
| P3 | Motion beat lock + `Composer2PlayAlong` + `PlayAlongDirector` + button and sheet + `.playAlong` demand + consent | L |
| P4 | Bar tracker + `Composer2Quantizer` + transitions + beat dots + "Tap the one" | M |
| P5 | `SongMemory` + two-dimensional service drive | M |
| P6 | Extraction v2 + `Composer2AlbumPalette` + Composer-tab album button | M |
| Next | Sync Check (camera-measured light latency); a REST bar scheduler; a "groove map" (kick, snare and hat positions drive separate layers, predicted, on time); iOS 27 Music Understanding on rolling windows for sections and drops | — |

**Ordering.**
- P0 ships value on its own.
- P1 before anything that trusts the grid.
- P2 before anything that should land on a beat.
- P5 can move ahead of P3 if Apple Music is the main way Brian plays music.

## 10. From the external draft plan (shared 2026-10-06): kept, changed, dropped

| Plan item | Verdict | Why |
|---|---|---|
| Play Along, On the One, album colors, auto-start, offset groundwork | **Kept** | Same goals; designed against the real code |
| `outputTime = detectedBeatTime + latencyOffset` | **Reversed** | Late by construction; render at `hostNow + lead` on a predicted grid (§4) |
| Engine advances on each beat event | **Replaced** | Continuous musical time sampled at render; already `BeatClock`'s rule ("beat position is never sampled") |
| Onset + offline DP (Ellis / BeatRoot) | **Replaced** | DP needs the future; causal induction + comb phase + PLL, measured in §2 |
| `.ambient` session / capturing system audio | **Wrong** | `.ambient` cannot record and iOS has no system-audio capture; the shipped `.playAndRecord` / `.measurement` / `.mixWithOthers` session is right |
| Background audio mode | **Not now** | Capture stops in the background on purpose; App Review 2.5.4 is its own decision |
| Store `snapToBars` / `useAlbumColors` per look, bump the schema | **Dropped** | Derived transforms plus app-level preferences; no migration |
| UIImageColors / Android Palette | **Replaced** | The app has its own extractor; it needs OKLab and chroma weighting for light |
| "25 fps Entertainment" | **Corrected** | Compositions run ~25 fps with drift; Studio flash loops run 50 fps; deadline pacing, and 50 fps while Play Along is engaged |
| Kotlin / Android | **Dropped** | `android/` has no Composer 2 or audio code |
| Node.js harness and CI scripts | **Dropped** | The DSP is pure Swift; XCTest plus the beat lab compile the app's own files |
| REST/WebSocket endpoints, `BeatDetected` JSON | **Dropped** | Everything is in-process; the lock-free snapshot and pure functions are the house pattern |
| Remote flags, 10 % → 50 % rollout, telemetry | **Dropped** | No remote config or analytics by design; internal TestFlight plus device rounds |
| 15–20 person-weeks, 4–5 engineers | **n/a** | Sized as commits above |

## 11. Open questions for the device

1. The real Entertainment light latency in Brian's home (§8.1), and whether 50 fps helps on his bridge.
2. Whether input-buffer `AVAudioTime` stamps already include `inputLatency`, which changes the `L_in` sign.
3. Whether `AVAudioSession.currentRoute` shows the Music app's AirPlay route while our session is active, which
   decides the `SongMemory` route key.
4. The confidence thresholds in real rooms (the lab's 0.3 lock and 0.05 bar margins).
5. Whether "the one" from harmonic change holds up on songs that keep one chord for 2–4 bars. If not, it falls back
   to half bars and the tap.
6. The CLIP v2 default `dynamics.duration` when it is omitted. The v1 docs say 400 ms; the v2 docs are login-only.
   This sets how soft today's "instant" `EffectEngine` flashes really are.
7. Whether the "Heard nearby" strip meets ShazamKit's attribution rule (an Apple Music link).

## 12. Platform facts and sources

**Beat tracking** (research pass, 2026-10-06; [P] = primary source):

| System | Causal | GTZAN beat F (causal) | Code / weights licence | In an App Store app |
|---|---|---|---|---|
| Real-time PLP (Meier, Chiu & Müller, TISMIR 2024) | yes, zero latency | 74.7 with an LSTM front end; 91.9 with perfect input | MIT | **yes** (the lab challenger) |
| BeatNet (2021) | yes (particle filter) | 75.4; downbeat 46.5 | CC BY 4.0 | grey area: CC's own wiki says App Store DRM may breach it |
| BTrack, aubio, IBT | yes | ~55–69 | GPL-3 / GPL-3 / GPL-2 | no; implement from the papers |
| madmom online | yes | 74.2 | BSD-2 code, **CC BY-NC-SA models** | code only |
| Beat This! (2024) | no (offline) | 89.1; downbeat 78.3 | MIT (code and weights) | offline only: owned files, or as a teacher |

Supporting results:
- **Onset front end.** Log-filtered flux scores 80.3 F, against 74.5 for plain flux, 75.7 with adaptive whitening
  and 76.1 with log magnitude (Böck et al., ISMIR 2012). SuperFlux adds the max filter.
- **Room audio.** A large-hall impulse response plus pink noise drops median beat F from 0.94 to 0.77 for a tracker
  fed a continuous onset function. A tracker that picks discrete onset peaks drops from 0.92 to 0.65 (Audio
  Degradation Toolbox, ISMIR 2013).
- **Lock times.** Trackers take ~5–6 s to a first lock and more than 10 s to settle. Goto 2001: 11–14 s for beats,
  18–22 s for bars.
- **Products ask the user for "the one".** Resolume says "click Resync on the first beat"; Ableton Link sets bar
  length but detects no downbeat.

Sources:
- PLP: https://transactions.ismir.net/articles/10.5334/tismir.189 · https://github.com/groupmm/real_time_plp
- BeatNet: https://arxiv.org/abs/2108.03576
- BeatNet+: https://transactions.ismir.net/articles/10.5334/tismir.198
- BEAST: https://arxiv.org/abs/2312.17156
- Beat This!: https://arxiv.org/abs/2407.21658
- madmom LICENSE: https://github.com/CPJKU/madmom/blob/main/LICENSE
- Böck 2012: https://archives.ismir.net/ismir2012/paper/000049.pdf
- SuperFlux: https://www.dafx.de/paper-archive/2013/papers/09.dafx2013_submission_12.pdf
- Degradation Toolbox: https://archives.ismir.net/ismir2013/paper/000145.pdf
- Goto 2001: https://staff.aist.go.jp/m.goto/PAPER/JNMR2001goto.pdf
- Ellis 2007: https://www.ee.columbia.edu/~dpwe/pubs/Ellis07-beattrack.pdf
- mir_eval: https://github.com/mir-evaluation/mir_eval/blob/main/mir_eval/beat.py
- CC and App Store DRM: https://wiki.creativecommons.org/wiki/4.0/ETM
- FSF on GPL and the App Store: https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement
- Resolume: https://resolume.com/article/38
- Ableton Link: https://ableton.github.io/link/

**Perception.** ITU-R BT.1359: sound before the picture is detectable at about 45 ms and acceptable up to about
90 ms. Sound after the picture is detectable at about 125 ms and acceptable up to about 185 ms.

**Hue, iOS and music platforms** (research pass, 2026-10-06; P = primary, C = community):

| Fact | Source |
|---|---|
| Entertainment: send at 50–60 Hz (duplicates against UDP loss); the bridge drives bulbs over Zigbee at 25 Hz | C, quoting the login-only Hue docs |
| No official end-to-end latency. About 80 ms video-to-light (Harmonize); a hard black-to-white step completes in ~150 ms with client easing (LumaSync) | C |
| Bulb firmware 1.46.13 (2018): "smoothening of light transitions in entertainment mode" | P |
| REST: about 10 commands/s to lights, 1/s to groups; default transition 400 ms. This is v1 wording; v2 is login-only | P |
| `installTap` buffer: "supported range is [100, 400] ms"; requests under 4800 frames are ignored (200 ms on AirPods' 24 kHz route); deprecated in the iOS 27 SDK | P; C |
| Tap time: "the time the system captures the buffer". Whether that includes input latency is unstated | P |
| `AVAudioSinkNode`: iOS 13+, real-time, input chain only, hardware format | P (WWDC19 510) |
| I/O buffer: minimum ≥ 5 ms, default ~20 ms; AirPlay output "can result in a 2-second delay" | P |
| `.measurement`: minimal system processing, no automatic gain. Voice processing removes the phone's own playback from the mic, so avoid it | P |
| Recording can't start in the background (privacy block since iOS 12.4, DTS 2025–26). With the `audio` mode, a session started in the foreground may continue | P |
| App Review 2.5.4 (background services for intended purposes) and 2.5.14 (explicit consent plus a clear indication while recording) | P |
| `secondaryAudioShouldBeSilencedHint` means a non-mixable app is playing; `isOtherAudioPlaying` also counts ambient audio | P |
| Other apps' now-playing is unreadable; the system player covers the Music app only. Media Player: "Don't gather information about the user's audio content for any other purpose" | P |
| MusicKit `Artwork`: `url(width:height:)`, `backgroundColor` and text colours, often nil in practice | P; C |
| ShazamKit: `artworkURL` and `predictedCurrentMatchOffset`; showing matched metadata requires an Apple Music link | P |
| App Review 4.5.2(ii): cover art "only in connection with music playback or playlists" | P |
| Spotify: the currently-playing endpoint is capped at 5 users in development mode; extended access needs 250k MAU; policy III.6 / III.13 and the terms forbid analysis and derivative works of cover art | P |

**Rivals** (claims from their own pages):

| App | Starts on its own | Delay / calibration | Snaps to beats | Album colours |
|---|---|---|---|---|
| iLightShow | yes, when Apple Music plays | mic auto-calibration + manual | beats, drops, build-ups | yes |
| Lumina – Spatial Light DJ | — | automatic calibration (Pro) | beat-based sequences | yes |
| SonicHue | — | slider, 110 ms default | "land cleanly on downbeats" | — |
| hueDynamic | via Shortcuts | — | DJ pads to the beat | — |
| Hue app + Spotify | — | Latency setting | pre-made scripts from Spotify metadata | — |
| Hue Sync desktop | on app open | configurable delay | listens to the beat | — |
| WiZ, Govee | no; the page must stay open | — (sensitivity) | reacts | — |

Auto-start, a delay control, downbeat snapping and album palettes are therefore table stakes. ChromaGlow's edge in
this design:
- any of its looks, built-in or the user's own, becomes musical with one button;
- prediction instead of reaction;
- songs remembered after one play;
- the light path measured, not guessed (Sync Check, next campaign).

URLs:
- Hue:
  - https://developers.meethue.com/support/
  - https://iotech.blog/posts/philips-hue-entertainment-api/
  - https://www.philips-hue.com/en-us/support/release-notes/lamps
  - https://www.philips-hue.com/en-us/support/release-notes/hue-sync
  - https://www.philips-hue.com/en-us/support/topic/spotify/100023
- Community latency:
  - https://github.com/mcpcapital/harmonizeproject
  - https://github.com/voyvodka/LumaSync/pull/466
  - https://www.music-assistant.io/plugins/hue-entertainment/
- Apple audio:
  - https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)
  - https://developer.apple.com/forums/thread/797033
  - https://developer.apple.com/documentation/avfaudio/avaudiosinknode
  - https://developer.apple.com/videos/play/wwdc2019/510/
  - https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferrediobufferduration(_:)
  - https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement
- Background recording:
  - https://developer.apple.com/forums/thread/770556
  - https://developer.apple.com/forums/thread/816408
- Apple guidelines, playback state and metadata:
  - https://developer.apple.com/app-store/review/guidelines/
  - https://developer.apple.com/documentation/avfaudio/avaudiosession/secondaryaudioshouldbesilencedhint
  - https://developer.apple.com/documentation/mediaplayer
  - https://developer.apple.com/documentation/musickit/artwork
  - https://developer.apple.com/documentation/shazamkit/shmediaitem/artworkurl
- Spotify:
  - https://developer.spotify.com/policy
  - https://developer.spotify.com/terms
  - https://developer.spotify.com/documentation/web-api/concepts/quota-modes
- Rivals:
  - https://ilightshow.net/effects/generic-options/
  - https://apps.apple.com/au/app/lumina-spatial-light-dj/id6760628430
  - https://apps.apple.com/app/id6759938225
  - https://apps.apple.com/us/app/huedynamic-for-philips-hue/id1405195207

## 13. Implementation record (2026-10-07)

Branch `experiment/play-along` off `main` @ `9e0de1f`, rollback tag `checkpoint/pre-play-along`, build 908. One
commit per item, in the §9 order (P3 and P4 share one commit: the director lands on the quantizer's boundaries).

| # | What landed | Where |
|---|---|---|
| P0.1 | A live mic estimate never takes the music-service hold | `MusicSessionCoordinator.driveClockIfReady` |
| P0.2 | A beat-locked rhythm counts as using the beat clock, so mic demand follows | `Composer2Composition.usesBeatClock` |
| P0.3 | The DTLS composition loop sleeps to 40 ms deadlines instead of 40 ms after its work | `FrameDeadlinePacer`, `UnifiedOrchestrator` |
| P0.4 | **Deferred.** Instant zero-duration REST writes would also sharpen `EffectEngine` strobes (up to 8 Hz); it needs its own photosensitivity pass | — |
| P1 | 10 ms onset frames stamped at capture; ACF + comb tempo with a metadata prior; comb phase; bar from low-band flux and harmonic change; BeatClock v2 (phase and bar confidences, whole-beat bar re-labels, the track's learned offset, "Tap the one") | `OnsetFrameAnalyzer`, `BeatTracker`, `BeatClock`, `AudioAnalysisEngine` (old tracker behind `audio.legacyBeatTracker`) |
| P2 | Render ahead by the light path: Entertainment 80 ms + ½ × 40 ms + the bridge's Light timing; REST 250 ms. The screen shows the frame that is due now | `OutputLatencyModel`, `CompositionParamBox.outputLead`, `Composer2LiveOutput`, `Composer2PreviewFeed` |
| P3 | Play Along: motion beat-lock, beat-synced events, the transform (Glide · Groove · Hit; Calm never re-timed; authored sound kept), the director (engage on the one, coast, release after 20 s), the button, sheet and consent | `Composer2Motion.quantizeBeats`, `Composer2EventSpec.beatSync`, `Composer2Engine`, `Composer2PlayAlong`, `Composer2PlayAlongDirector`, `Composer2PlayAlongControls` |
| P4 | On the One: bar, half-bar or beat landings, never more than a bar away; look switches crossfade onto the bar line; beat dots | `Composer2Quantizer`, `Composer2LandingSource`, `Composer2PlaybackCenter` |
| P5 | Song memory: hashed track + route key; learned only while the mic confirms the offset; stored after 8 agreeing bars. The drive trusts a remembered grid at once (with the one when it was known), and keeps the mic's phase when a service tempo arrives | `SongMemory`, `BeatClock.driveFromTrack(beatOffset:barKnown:)`, `MusicSessionCoordinator` |
| P6 | Song colors: OKLab, chroma-weighted swatches by role; the transform; colours land on the one; the Composer tab's album art toggles it | `ArtworkPaletteExtractor.swatches`, `Composer2AlbumPalette`, `Composer2LiveOutput.songSwatches` |

**Decided while building (not in the sections above):**
- Song colors apply only while Play Along is on. The sheet has the toggle; the album art on the Composer tab's music
  strip toggles it too. Spotify's art is never used.
- Room mode (REST) plays along as Glide whatever the chosen feel (§5.9), including a stream that fails over to it.
- Play Along listens through the existing reaction-source mirror (`.micAmplitude` while it is on) rather than a new
  `AudioDemand` case.
- No audio-session call on the main thread from the new code: iOS 27 reports them as hang risks. The microphone
  source reads the input latency while it configures the session; the song memory's route is read on a utility
  queue and cached, refreshed on route changes.
- "Remembered" shows only when the song memory set the grid at the start of a track.

**Not built yet:** the Debug Beat HUD; 50 fps while engaged; coast's "accents fade within a beat" (the director
coasts at full weight until it releases); the per-beat haptic; the "Following Apple Music" readout; Sync Check.

**Verified:** on the iOS 27 simulator (counts in the DEVLOG entry). **Not verified on hardware:** all of §8's
device plan, and §11's open questions.

## 14. Fixes before merge (2026-10-19, build 909)

From the 2026-10-19 audit of build 908 (the B-numbers below). Same branch, rollback tag
`checkpoint/pre-build-909-first-chunk` (= `a0b7cb8`). One commit each.

| Bug | What was wrong | Fix |
|---|---|---|
| B6 | Dim Flashing Lights capped events only; Groove/Hit punches lit the whole room at full strength on every beat | Every sound punch is scaled by the same 0.3 cap (`Composer2Engine`) |
| B1 | The Light timing slider worked backwards: the lead *added* the offset, so "earlier" made the lights later | `lead = base − offset`; range −300…+150 ms (§5.5) |
| B2 | Confidences never decayed (silent passes never reached the clock; low passes returned first; nothing called `clear()`): a ghost grid, a stuck BPM readout, the 20 s release never fired, the next session engaged on the old grid | Passes with no trusted beat fade phase/tempo/bar confidence (half-life 1.5 s after a 1 s grace); a stopped mic zeroes a mic-owned grid; the tempo coasts. Pins, taps and service drives never fade |
| B3 | A song change crept the phase 30 ms per pass (~5 s off the beat) while claiming a lock | A new tempo (>3 %) locks afresh; a large error (>70 ms or ⅙ beat) is held one pass (reported 0.4) and snapped on a second agreeing pass; after 3 s with no drive the first confident beat corrects at once |
| B5 | The song-colour crossfade re-armed the event schedule every frame, cutting events in flight | Specs that differ only in colour keep the schedule (`hasSameSchedule(as:)`) |
| lab | Scoring skipped each song's first 10 s, hiding B3 | A `p@0` row scores the shipping tracker from the first beat and counts claimed-but-wrong beats; song change 128→96: 9 of 28 → 3 of 24, second song locks 7.5 → 6.3 s (`beatlab/results-2026-10-19.txt`) |

Still open from the audit: B4 (a service prior floors tempo confidence at 0.72), B7 (an untrusted service offset
pulls back to t=0 once the mic is 2 s stale), B8 (the render loop is on the main actor), B9 (SongMemory key unsalted,
file rewritten on main), B10–B12. The lab is still synthetic audio only.

## 15. Chunk 2: a faster ear and a steadier hand (2026-10-27, build 910)

The audit's second chunk, items 1 and 2. Same branch, rollback tag `checkpoint/pre-build-910-chunk2` (= `3b8a015`).

| | Before | After |
|---|---|---|
| Mic capture | `installTap`, which iOS serves in ~100 ms buffers whatever it asks for; the published level/onset features changed ~10 times a second | The session asks for ~5 ms I/O cycles; an `AVAudioSinkNode` copies channel 0 into `MicrophoneHopRelay` on the real-time thread, and the relay's own thread delivers 1024-frame hops (~21 ms at 48 kHz) stamped at capture. Falls back to the tap if the sink cannot start; the launch argument `-audio.legacyMicTap YES` (Xcode → Edit Scheme → Run → Arguments) forces the tap |
| How late a sound punch starts (lab, `run.sh -onset`) | median ~80 ms, p90 ~120 ms; at 120 BPM the buffers alias with the beat (every kick 134 ms late, 15 of 96 missed) | median ~16 ms, p90 ~26 ms, every kick caught |
| Beat grid (lab) | — | Unchanged within 0.4 ms: the tracker already used 10 ms frames stamped at capture (§13). Chunk 2 helps what reacts to *sound*, not the grid |
| Composition Entertainment loop | On the main actor at 25 fps: a busy screen delayed frames (B8) | `@concurrent` at 50 fps (the 20 ms grid the flash ledger is stated on). Composer 2 looks render on the loop's executor — `Composer2LiveOutput` / `Composer2LandingSource` are lock-guarded and render from a `CompositionLiveLayout` value; legacy compositions and a Perform deck A still render on the main actor. Frames keep flowing while the main actor is blocked (test: 400 ms block) |
| Render ahead | Already done in P2 (`OutputLatencyModel`) | Unchanged |

Tested on the iOS 27 simulator; the loop, concurrency and relay tests are clean under the Thread Sanitizer. **Not
verified:** live capture (the simulator has no mic input — the old tap fails there the same way), the I/O buffer
iOS actually grants with other audio playing, and the frame timing on a real bridge.

Device check for build 910 (adds to §8):
1. Play music from the phone, Play Along on, a beat look (Club Pulse). Punches should hit with the kick, not after
   it. Then add the launch argument `-audio.legacyMicTap YES` in Xcode (Edit Scheme → Run → Arguments), run
   again and compare: the punches should trail the kick.
2. Scroll the Composer library and open sheets while a look streams: the room should not stutter.
3. Console: no "Low-latency capture failed … falling back to the tap" line.
4. AirPods / Bluetooth speaker route change mid-show: capture comes back (the rebuild path is unchanged).

## 16. Sync Check: the camera times the lights (2026-10-30, build 911)

Chunk 2, item 3. Same branch, rollback tag `checkpoint/pre-build-911-sync-check` (= `e4df8b2`). This automates
the slo-mo measurement in §8.1.

**What the user does:** long-press Play Along → Sync Check (under Light timing) → point the camera at one of the
room's lights → Start. The look steps aside, the room settles bright for 1.5 s, then blinks 14 times about once a
second (~18 s in all), and the look comes back. The screen says "Your lights respond in N ms"; Play Along renders
N ms ahead on that bridge from then on, and the Light timing slider resets to "On time" (a trim on top).

| Piece | What it does |
|---|---|
| Plan (`Core/Audio/SyncCheck.swift`) | 14 blinks of 0.35 s, starts jittered 0.9–1.3 s apart (seeded), so the blink frames meet the bridge's radio at different phases. Every rise is ≥ 0.9 s from the last: far under the flash limit, and the onset ledger (0.34 s) never holds one. Dim Flashing Lights → 0.06→0.45 instead of 0.06→1.0. Warm white |
| Pattern | A `ConcurrentCompositionFrameSource` the playback center installs on the live box. It wraps the playing look and keeps rendering it unseen (the heartbeat watches `lastLiveRenderAt`), renders blinks for the moment they are SENT (no lead — the point is to measure it), and stamps each blink's first frame. After the plan it shows the look again |
| Camera (`SyncCheckCamera.swift`) | Back wide camera at its fastest 4:2:0 format, capped at 240 fps, smallest such size; stabilization and video HDR off; exposure biased −1.5 EV, then exposure and white balance locked 0.15 s before the settle ends. Each frame → a 16×9 grid of mean luma (every 5th pixel), stamped with its presentation time converted to the host clock + half the exposure. Nothing is recorded |
| Analyzer | (1) The (cell, delay) whose predicted on-times split the cell's samples into the most different means, per unit of its spread — a 10 ms-bin search with running totals (~0.1 s even in Debug). (2) Per blink, its own dark level (just before) and lit level (second half of the on time); a blink counts when lit − dark ≥ max(6, 5 × noise). (3) The half-way crossing, interpolated between the two frames around it; a crossing across a dropped-frame gap (> 35 ms) is skipped. Result = the mean of the middle half of the delays: the 20 ms stream frames meet the 40 ms radio at only two phases, so delays can split into two groups 20 ms apart, and beats ride on both. Refuses: nothing blinked (or < ¼ of blinks timed), too few blinks (< 60 %), or an interquartile spread > 60 ms |
| Lead (`OutputLatencyModel`) | `lead(.entertainment) = measured ?? 100 ms − user offset`. Measured is per bridge, persisted (`playAlong.measuredLightLatencyMs.<bridge>`, with a date), cached for the render loop, clamped 20–600 ms. Room mode is not measured (not beat-accurate) |
| Session (`Composer2PlaybackCenter`) | `canSyncCheck` (live, streaming, this bridge), `beginSyncCheck`, `endSyncCheck`. A look switch or stop during the check wins; unbinding always puts the look (not the blinks) back on a runtime that stays bound |

The camera permission text now mentions Sync Check. What it measures: the time from the app SENDING a frame to
the light reaching half way (as the camera sees it, i.e. in gamma-encoded brightness — close to when the eye calls
it "on"). That is the whole output path a rendered beat pays. The input side is already compensated: onset frames
are stamped at capture minus the session's `inputLatency` (§13).

Tested on the simulator only (it has no camera): the plan, the pattern, the analyzer against synthetic footage at
240/120/60 fps with distractors (a clipped window, a TV, a lamp on its own rhythm), dropped frames, a slow bridge,
a gentle blink, and a bridge model with Wi-Fi and pacer jitter where every blink is timed within 3 ms of the truth;
the lead storage; the center hand-off; and a blink on the live stream loop (stub transport). **Not verified:**
anything with a real camera or bridge — the frame rate the phone grants, whether exposure locking behaves, the
presentation-time convention (start vs middle of exposure: ≤ 2 ms either way at 240 fps), and the real delay.

Device check for build 911 (adds to §15):
1. Start a look in a room that streams (Play Along on or off). Long-press Play Along → Sync Check → allow the
   camera → aim at a bulb or a lit shade → Start. Expect the room to go bright, then 14 slow blinks, then the look
   back. Result screen: a number, most likely 60–150 ms.
2. Run it twice more, aimed at a different light: the numbers should agree within ~15 ms.
3. Cross-check one result with the §8.1 slo-mo method if you can (240 fps video of the bulb and a click).
4. Play music with Play Along on: punches should now land with the kick. If they still lead or trail, the Light
   timing slider trims on top of the measurement — note which way and how far.
5. Try to break it: aim at a dark wall (expect "Couldn't see the lights blink"), move the phone around during the
   check, switch the look mid-check (expect "The look changed or stopped"), and lock the phone mid-check (the look
   should come back).
