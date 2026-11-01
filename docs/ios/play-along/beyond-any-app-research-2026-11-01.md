# Beyond any app: what the next four pieces would take (research, 2026-11-01)

**Status: research only. Nothing is built, and no app code changed.**

Brian asked what it would take to build item 1 of the open list: the "beyond any other app" music work. It has four
pieces:

1. **A Sound control in Tune.** A quick win.
2. **Real songs for the beat lab.** The lab tests only on synthetic music today.
3. **The room is the band.** Bass in the floor lamps, vocals at eye height, drums on the ceiling.
4. **It knows what's coming.** Phrases, builds and drops, and songs it remembers.

**How this was researched:**
- Three code reviews of `experiment/play-along` @ `374afe8`. I re-checked their key claims myself.
- Three web researchers. Their URLs are in §9.
- Apple's Music Understanding, ShazamKit and SoundAnalysis were measured on an M4 Pro Mac. These are **not iPhone
  numbers**. The tests ran locally on two songs already on the Dev drive, and nothing was copied or kept.

Source records: the external plan behind README §10 ([`sources/chatgpt-play-along-plan-2026-10-06.md`](sources/chatgpt-play-along-plan-2026-10-06.md))
and the 2026-10-06 product deep dive ([`sources/deep-dive-2026-10-06.md`](sources/deep-dive-2026-10-06.md)).

Tags: **[code]** = read in the repo · **[V]** = primary source · **[M]** = measured on the Mac ·
**[I]** = inference.

---

## 0. The answer on one screen

| Piece | What it takes | Size | Biggest risk |
|---|---|---|---|
| Sound in Tune | One saved "Sound" amount per look that scales every layer's reaction at one point in the engine | 1 build | Low |
| Real songs for the lab | Read real audio files and their annotations into the lab; add standard scores; a licence-clean test set on `/Volumes/Dev`; optionally a Debug-only room recorder | 1–2 builds | Licences; the recorder needs Brian's OK |
| The room is the band | Kick/snare/hi-hat detectors, a "groove map" that predicts them on the beat grid, knowing which lights are low/middle/high, a band transform, and a shared flash budget | ~5 builds | Kick vs bass guitar through a phone mic; most rooms have no light heights set |
| It knows what's coming | Song position and phrase counting, a build/drop detector, a "Conductor" policy, remembered song maps (Apple's Music Understanding, iOS 27), and a song timeline | ~6 builds | Nobody can find sections *live*; real look-ahead starts on the second play |

**Total: roughly a dozen builds**, each the size of 909–912. Recommended order (§8): phone-check 911/912 → Sound in
Tune → real-song lab → the room is the band → it knows what's coming.

**Where ChromaGlow would lead:**
- No rival documents per-instrument mapping onto real light positions.
- No rival documents per-song maps learned by listening and replayed with look-ahead.
- SonicHue already claims live phrase-boundary drops ("Predictive Drop", v1.2.9) [V], so that alone is not a lead.

---

## 1. A Sound control in Tune (1 build, S–M)

**Today [code]:**
- Tune (`UI/Composer2/Composer2TuneView.swift`) has Feel (Brightness, Speed, Energy), Moments, Storm, Colours and
  Another take. It has no Sound control.
- Every Tune control writes the look through `document.edit`, so the change is saved with the look.
- The per-layer Sound tab (`Editors/Composer2AudioEditor.swift`) is about 8 taps deep.

**Design:**
- Add `master.soundAmount`, from 0 to 2, with **1 = as authored, or as Play Along derives it**.
- Apply it once, at `Composer2Engine.swift:250` (`let mod = layer.audio`), by scaling `mod.intensity`. Every use of
  sound reads that intensity: speed, palette, event chance, brightness, punches, the moving-hits dip and per-light
  hits. So the one change covers looks with their own sound and Play Along's derived sound alike.
- Dial stops: **Still** (0), **Lightly** (≈0.5), **Dances** (1–1.5).
- At 0 the look stops holding the mic. Change `usesMicrophoneBands`/`usesBeatClock` (`Composer2Models.swift:256-263`).
- If the look has no sound and Play Along is off, there is nothing to scale. Then Tune shows the Play Along switch
  inline, consent sheet included.

**Why not write per-layer sound settings from Tune:**
- Play Along treats a layer with its own sound as "already listens" and stops applying Groove/Hit to it
  (`Composer2PlayAlong.swift:84, :91`), so the Feel choice would silently stop working.
- It would also overwrite Beat Drop's and Club Pulse's tuning.

**Safety:**
- The amount applies before the existing caps (Dim Flashing Lights 0.3, then the flash shaper). Nothing new is
  needed.
- Add a test that Dances never needs more flash shaping than 1.
- Save the key only when it isn't 1, so older looks stay byte-identical (the `travel` pattern).

**Decision for Brian:** per look (recommended: it's saved with the look, like Energy) or app-wide.

---

## 2. Real songs for the beat lab (1–2 builds, M)

**Today [code]:**
- The lab (`beatlab/run.sh`) compiles the app's own tracker files and scores 14 synthetic cases: tempo class, phase
  error, bar-1 and lock time.
- The synth has one reverb, a phone-mic band and pink noise. It has no small speakers, intros without drums,
  breakdowns, non-4/4 music or real speech.
- Nothing in the app or the lab reads or writes audio files (no `AVAudioFile` anywhere).

**Build:**
1. **A corpus loader** (`beatlab/Corpus.swift`). `AVAudioFile` and `AVAudioConverter` convert each file to 48 kHz
   mono. It parses `.beats` (time and beat-in-bar), `.lab` sections (`start end label`, using EDM labels intro, build,
   drop, break, outro) and per-drum onset lists. A manifest lists file, source, licence, condition (line or room) and
   SHA-256.
2. **Standard scores**, mir_eval style:
   - beat F-measure within ±70 ms, CMLt and AMLt, and downbeat F;
   - relock time after each section boundary;
   - kick/snare/hi-hat precision and recall;
   - section boundary hit rate within ±0.5 s and ±3 s;
   - drop warning time.
3. **Audio stays off git.** The corpus lives at `/Volumes/Dev/Datasets/chromaglow-beat-corpus/`, and `.gitignore`
   gains audio patterns. The repo is public, and README §8 already rules that recordings never go into it. Commit
   only result tables and manifests.
4. **A room simulation** first: convolve the test files with licence-clean room impulse responses (BUT ReverbDB,
   CC BY). Published numbers show a real room cut beat F from 0.92 to 0.65 for one classic tracker, because early
   reflections cause false onsets [V].
5. **Optional: a Debug-only room recorder.** It would hang off the `AudioPCMSink` path, write files away from the
   real-time thread, sit behind a compile flag, and have a `verify_*_absent.sh` script keeping it out of Release and
   TestFlight. Recordings get a sweep and clicks at both ends so they can be aligned to the file's annotations. ⚠
   This contradicts the app's "never recorded" copy (`Info.plist:67`, `privacy.html`, `AGENTS.md:680` "Never collect
   raw audio") in any build that contains it, so **it needs Brian's explicit OK.**
6. **A tiny Debug probe for Music Understanding on Brian's iPhone.** §4's "Remembers" depends on how fast it runs
   there, and nobody has published iPhone numbers.

**A licence-clean starter set** (licences verified on each dataset's page; my judgement, not legal advice):

| Need | Set | Licence | Note |
|---|---|---|---|
| Beats, downbeats, sections, vocals in pop | RWC-Pop (100 songs, Zenodo since Feb 2026) | CC BY-NC 4.0 | The authors say it covers "corporate research"; **email AIST to confirm** |
| EDM drops and builds | Yadati SSME (402 CC EDM tracks, MP3s included, 435 drops labelled) | Per track (CC) | Drop tracks marked NC; pre-annotate beats with Beat This! (MIT) |
| Kick/snare/hi-hat | E-GMD, StemGMD | CC BY 4.0 | Real drumming |
| Bass and instruments in a mix | Slakh2100 or AAM | CC BY 4.0 | Synthetic stems |
| Real acoustic checks | Candombe, GuitarSet | CC BY 4.0 | Niche, but real |
| Our own ground truth | 20–40 CC BY/CC0 tracks from FMA or ccMixter, annotated in Sonic Visualiser | Per track | |

**Avoid:**
- Datasets that forbid commercial use: ENST, IDMT, MDB Drums, ADTOF, MUSDB18, MedleyDB, MoisesDB, MTG-Jamendo.
- Datasets with no known audio source: GTZAN, Ballroom.
- **iTunes purchases.** The Apple Media Services Terms (updated 2026-09-14) ban using software to "perform
  measurement, analysis, or monitoring of" content, and using it to "improve any… software".
- CDs carry the lowest contract risk. Harmonix, SALAMI and Isophonics annotations are free to use (MIT, CC0, free),
  but each lab supplies its own audio.

---

## 3. The room is the band (~5 builds)

**Mapping, as lighting designers do it** [V/S]:

| Part | Lights | Look |
|---|---|---|
| Kick | Floor lamps | Bumps |
| Bass | Floor lamps | Colour and level (slow) |
| Snare | Ceiling and lightstrips | Flashes |
| Hi-hat | Ceiling and lightstrips | A low shimmer or chase, **never a flash on every hat** |
| Vocals | Eye height | A warm, held wash |

Strobing is rationed.

### 3.1 What the app can hear today [code]
- `OnsetFrameAnalyzer`: 10 ms frames, 18 log-spaced bands from 30 Hz to 16 kHz, flux over three groups, and a 12 s
  ring stamped with capture time.
- Only the beat tracker reads it, every 0.5 s. It already uses "low minus high flux" as a kick proxy to find the
  one.
- The looks see `AudioFeatures` only: level, bass/mid/treble levels and one whole-spectrum onset.
- Composer 2 sources are `off, amplitude, bass, mid, treble, beat, onset`. A layer can follow a band's *level*, but
  there is no per-drum onset.
- Adding fields to `AudioFeatures` (a value type) reaches every render loop with no other plumbing.

### 3.2 What's realistic [V]
- **Drum hits in full mixes**, published state of the art with no look-ahead:
  - kick ≈ 0.75–0.85 F, snare ≈ 0.6–0.7, closed hi-hat ≈ 0.6–0.7;
  - electronic kicks ≈ 10 points lower;
  - lower again through a phone mic in a room [I].
  - The only real-time neural model found (Fraunhofer 2024) runs with 32–54 ms delay.
  - Classic band-split plus an adaptive threshold (Dittmar & Gärtner) runs at about 6 ms.
- **Vocal/bass/drum activity** needs roughly 0.5–1 s decisions. That suits washes, not hits.
- **Apple's Music Understanding** [M]:
  - It gives vocal/drum/bass/other activity 20 times a second, works on windows as short as 1 s, and costs about
    0.1 s per window on the Mac.
  - Agreement with whole-song analysis at 4 s windows: drums 0.96, vocals 0.98, **bass only 0.62**.
  - It is iOS 27+ only, and needs a new session per window.
- **Apple's SoundAnalysis** has drum, bass and singing labels, but on a real mix "drum" passed 0.5 in 6 of 240
  windows [M]. **Not useful.**
- **Stem separation:**
  - There is no Apple API.
  - Core ML ports are 200–470 MB and not live.
  - Demucs weights are research-only.
  - **Skip it.**

### 3.3 The two hard problems
1. **On time.** Frames render about 0.1 s ahead so the bulbs light on the beat (`OutputLatencyModel`), but detected
   hits are "now", so a reacting hit lands at least 0.1 s late.
   - **Fix: a groove map.** Learn where kick, snare and hats fall in the bar over the last few bars, fire them
     *predicted* on the beat grid as the beat punch already is, and let the detectors confirm or cancel. Fills and
     breaks fall back to the plain beat.
2. **Which light is low, middle or high.**
   - Hue stores each light's height as z (−1 floor to +1 ceiling), set in the Hue app's Entertainment-area editor
     [V/C].
   - **ChromaGlow's own area builder writes z = 0 for every light** (`EntertainmentConfigBuilderView.swift:385`,
     verified).
   - Composer 2 only uses z as a stand-in for depth (`Composer2Space.swift:160-185`, verified), so height never
     reaches a look.
   - Light type (archetype) is a user-chosen icon, not a fact.
   - **Fix:** read z when the user has set it. Otherwise ask once per room ("which lights are low, middle, high"),
     write the answer back to the bridge as z, and fall back to product type. Scan Your Room is the deluxe version
     later.

### 3.4 Builds
1. **Drum lanes (M).** Kick (~40–150 Hz), snare (150–400 Hz body *and* 2–5 kHz noise together) and hi-hat (6–16 kHz)
   from the existing frames, with Dittmar's adaptive threshold and a per-drum refractory. New `AudioFeatures` fields
   and `Source` cases `.kick/.snare/.hat`. Tuned on §2's drum sets.
2. **Groove map (M–L).** Per-bar-position patterns, predicted on the grid and confirmed by the lanes. Published beside
   `BeatSnapshot`.
3. **Where each light is (M).** z and archetype on render slots, roles on `Composer2SlotGeometry`, a `.role` mask, the
   one-time room question, and writing z to the bridge.
4. **The band transform and a shared budget (M + M).**
   - Map each look's base, accent and event layers onto roles. Clone single-layer looks into masked copies.
   - All roles share the whole-room ≤3 flashes/s budget, so kick and snare get priority, hi-hats stay under the
     flash threshold, and a per-light refractory works *across* layers (today it is per layer).
   - Extend the per-look gate report test to band looks.
5. **Slow lanes (M).** Vocal, bass and drum activity from our own DSP first, so it works on every iOS version. Music
   Understanding on rolling 4 s windows is an iOS 27 upgrade if iPhone timing allows.

### 3.5 Limits
- **Room mode can't do it.** Per-light REST is too slow.
- **≤10 lights per Entertainment area** leaves 2–4 lights per role. In small rooms the band drops to two roles, low
  and high.
- **Bluetooth headset mics** (16/24 kHz) lose the hi-hat band.
- **Kick vs bass guitar** is 1–2 FFT bins below 150 Hz. It may need a longer low-band window. Measure it on §2's set.

---

## 4. It knows what's coming (~6 builds)

**What exists [code]:**
- `BeatSnapshot` has bpm, epoch, beats per bar, and phase and bar confidence. There is **no phrase, section or drop
  anywhere** in the app.
- On mic alone, "bar 0" is arbitrary and moves when the one is re-labelled. Under an Apple Music drive, bars count
  from the song's start.
- The quantizer lands at most one bar ahead and can't aim at a chosen time.
- Nothing switches looks on a schedule.
- The Sequence Builder exists only as a design (`docs/ios/sequence-builder-design-2026-07.md`).

**What's realistic [V]:**
- **No published method finds song sections live.**
  - The best offline models reach a boundary hit rate (±0.5 s) of about 0.70.
  - "All-In-One" needs Demucs stems and the whole song.
  - Online downbeat tracking is weak: BeatNet+ F 0.565 at 20 ms.
- **Phrase priors are strong in pop and dance:**
  - 81 % of Harmonix sections start on a downbeat.
  - More than half of RWC-Pop sections are 8 bars long.
  - An 8-bar novelty kernel plus a 4-bar periodicity prior found DJ cue points with 86 % precision.
- **Drops:**
  - The only drop detector (Yadati 2014) scores F 0.61 within ±3 s, offline.
  - A build plus its drop runs 15–20 s.
  - Build cues: the low end filtered away, risers (noise rising), snare rolls doubling in rate, a loudness ramp, and
    a gap or fill just before the drop.
  - **No paper measures how early a drop can be predicted.**
- **Apple's Music Understanding on a whole song** [M]:
  - About 2–4 s on the Mac for a 2–3 minute song. The 2026-10-06 note's "~10 s" was slow disk reads.
  - Results: beats, bars, **unlabelled** sections, segments and phrases, instrument activity, pace, key and loudness,
    all `Codable`, with no confidence values.
  - Windows of 15 s or less return one section, and window boundaries don't match whole-song ones. **Structure only
    works on a whole song.**
  - It **cannot read Apple Music or other apps' audio** (DRM throws `hasProtectedContent`), so for Apple Music the
    song has to be heard through the mic.
- **Finding the place on replay:**
  - **ShazamKit:** `matchOffset` was within ±7 ms on clean audio [M]. `predictedCurrentMatchOffset` is a wall-clock
    extrapolation that misses pauses and seeks, so the app must match again every so often. It returns ISRC, Apple
    Music ID and Shazam ID.
  - **Apple Music:** `SystemMusicPlayer.playbackTime` is polled (once a second today, `AppleMusicSource.swift:166`).
    Its precision is undocumented, and MusicKit has no seek event; detect seeks from jumps.

### 4.1 Three levels, built in this order
- **Listens** (every song, first play, all iOS versions). A phrase counter on the beat grid plus a live energy state:
  calm, build, peak or breakdown. The drop is staged on the next 8- or 16-bar line and confirmed when the kick and
  sub-bass return. If it doesn't come, the lights ease back over a bar.
  - Rivals already ship this much.
  - Good in EDM and four-on-the-floor pop, weak in rock, ballads and live music.
- **Remembers** (the lead, iOS 27).
  1. The first time a song plays, the app keeps the audio it hears *in memory* while the song plays (about 11 MB for
     3 minutes at 16 kHz mono).
  2. At the end it runs Music Understanding once, then throws the audio away.
  3. It keeps only the map: beats, bars, phrases, sections, drops, an energy curve and instrument re-entries.
  4. The map is anchored to song time with Shazam's `matchOffset`, or Apple Music's position, and keyed by a salted
     song ID.
  5. On the next play the app knows what's coming: a real countdown to the drop, and sections it can name from energy
     and instruments (Apple's sections are unlabelled).
  6. Partial listens merge.
- **Knows** (audio ChromaGlow plays itself). **Deferred.**
  - The app plays no files today, and an importer, player and Now Playing would be an L.
  - The personal Spotify build looks ahead at most 3.2 s, less than one 8-bar phrase.

### 4.2 Builds
1. **Song position and phrases (M).** A bar count that survives corrections, a `PhraseTracker`, and a
   `SongStructureSnapshot` mirror kept apart from the widely used `BeatSnapshot`. A per-bar feature history: raw
   energy (not the auto-levelled `level`, which flattens a build), low and high flux, onset density, flatness and
   spectral change.
2. **Energy states and build/drop (M).** The state machine and build cues, with drop prediction on the phrase grid
   and ease-back.
3. **The Conductor (M).** A pure `Composer2Conductor` policy:
   - punch strength ramps through the build, and hits tighten from every 4 beats to every 2, then every beat;
   - the lights dim half a beat before the drop, *only at high confidence* (a wrong blackout is worse than a missed
     one);
   - Hit lands on the one.

   It runs before the flash shaper. The quantizer gains "land at time T".
4. **Fix B9, then add song maps (S + M–L).**
   - B9: a salted key with the salt in the Keychain, writes off the main thread, file protection.
   - Song maps: one file per song, kept apart from `SongMemory` (whose per-speaker offset stays where it is).
   - The first-listen buffer and the Music Understanding pass, Shazam/Apple Music anchoring, and seek detection.
5. **The song timeline (S–M).** A strip under the hero: section blocks, a playhead read through
   `currentPositionEstimate` in a `TimelineView`, and "drop in 4… 3…" (wire up the unused
   `Composer2LandingSource.remaining(at:)`).
6. **Later:** Song Show (pin a look per section, share it; L), and Knows for imported files (L).

---

## 5. Safety

- Everything new goes through the existing whole-room flash gate (≤3 flashes/s, ≥0.34 s apart, a 0.10 rise counts),
  the flash shaper, and the Dim Flashing Lights 0.3 cap.
- **New for the band:** one budget shared by every role, with kick and snare first, and a per-light refractory across
  layers. Two layers lighting one lamp are not coordinated today.
- **New for the Conductor:** the dark-to-full drop slam is one flash, and the gate admits it. Pre-drop dimming isn't a
  flash. False drops are a *quality* risk, not a safety one.
- Known from build 912: small rooms with one-light sparkle looks already lean on the shaper. Band looks must join the
  per-look gate report before they ship.

## 6. Privacy and licences: decisions for Brian

1. **Debug-only room recorder.** It is needed for honest real-room numbers, but it contradicts "never recorded" in
   any build that contains it. Options: Debug-only with a verify-absent script, or no recorder (simulated rooms only).
2. **Remembers' first listen** keeps a song's audio in memory while it plays, then discards it. The privacy wording
   would change to something like: *"Listens to the whole song on your phone to learn its shape. The sound is never
   saved or sent."*
3. **iOS 27-only parts.** Remembers and Music Understanding lanes would be iOS 27+. Listens and the drum lanes work
   on iOS 17+.
4. **Test music:** email AIST about RWC, and use no iTunes purchases.
5. **No shipped third-party models.**
   - Not shippable: madmom models, Demucs and All-In-One weights, Essentia, ADTOF and UMXL. Their licences are
     non-commercial or research-only.
   - Use our own DSP live, and Apple's Music Understanding (free, on-device) offline.
   - Beat This! (MIT) is fine for *pre-annotating test data* on the Mac.

## 7. What only a phone can answer

1. Music Understanding on Brian's iPhone: time per window and per song, heat, and whether it runs in the background.
2. Its activity quality from the mic in a real room, especially bass.
3. Shazam over the mic: time to the first match, and the offset error against Apple Music's own timeline for the same
   ISRC.
4. `SystemMusicPlayer.playbackTime`: step, jitter, lag over AirPlay/Bluetooth, behaviour in the background, and
   whether scrubbing in the Music app shows up.
5. The real z values in Brian's areas: has he set heights in the Hue app? Does the bridge merge channels?
6. Kick/snare/hi-hat detection through the phone mic in his room, and how hi-hats read through the bridge's 25 Hz
   radio.
7. Builds 911 (Sync Check) and 912 (moving hits). Everything above stands on their timing.

## 8. Recommended order

0. **Phone-check 911 and 912.**
1. **Sound in Tune.** One build.
2. **The real-song lab,** plus the Music Understanding probe on the iPhone. 1–2 builds.
3. **The room is the band:** drum lanes → groove map → light roles → band transform and budget → slow lanes. About 5
   builds. It goes first because it uses well-understood signal processing and pays off on every song's first play.
4. **It knows what's coming:** song position and phrases → build/drop → Conductor → B9 and song maps → timeline.
   About 6 builds.
   - If drops matter more to Brian than per-instrument light, steps 1–3 of this item can go before item 3. After the
     lab, the two are independent.

## 9. Sources (fetched 2026-11-01)

**Apple:**
- Music Understanding: https://developer.apple.com/documentation/musicunderstanding
- WWDC26 session 253: https://developer.apple.com/videos/play/wwdc2026/253/
- ShazamKit (WWDC21 10045, WWDC22 10028, WWDC23 10051):
  - https://developer.apple.com/videos/play/wwdc2021/10045/
  - https://developer.apple.com/videos/play/wwdc2022/10028/
  - https://developer.apple.com/videos/play/wwdc2023/10051/
- SoundAnalysis (WWDC21 10036): https://developer.apple.com/videos/play/wwdc2021/10036/
- `predictedCurrentMatchOffset`:
  https://developer.apple.com/documentation/shazamkit/shmatchedmediaitem/predictedcurrentmatchoffset
- The local iOS 27.1 SDK interfaces.

**Hue:**
- Entertainment limits: https://www.philips-hue.com/en-us/support/topic/entertainment/100085
- New API: https://developers.meethue.com/new-hue-api/ (the reference pages need a login)
- Schema mirrors [C]: https://github.com/home-assistant-libs/aiohue and https://github.com/aregis/EDK-master

**Drum transcription:**
- Wu et al. 2018 review:
  https://musicinformatics.gatech.edu/wp-content_nondefault/uploads/2018/05/Wu-et-al.-2018-A-review-of-automatic-drum-transcription.pdf
- Dittmar & Gärtner 2014: https://dafx14.fau.de/papers/dafx14_christian_dittmar_real_time_transcription_a.pdf
- Vogl et al. 2017: https://archives.ismir.net/ismir2017/paper/000123.pdf
- Weber et al. 2024 (real-time):
  https://www.audiolabs-erlangen.de/content/05_fau/professor/00_mueller/03_publications/2024_WeberUML_DrumFewShot_IoS.pdf
- STAR Drums: https://transactions.ismir.net/articles/244

**Structure:**
- Nieto et al. 2020: https://transactions.ismir.net/articles/10.5334/tismir.54
- All-In-One: https://github.com/mir-aidj/all-in-one
- Harmonix: http://archives.ismir.net/ismir2019/paper/000068.pdf
- Zehren 2020 (DJ cue points): arXiv 2007.08411
- BeatNet+: https://doi.org/10.5334/tismir.198

**Drops:**
- Yadati et al. 2014: https://archives.ismir.net/ismir2014/paper/000297.pdf
- Yadati et al. 2018: https://records.sigmm.org/2018/03/07/socially-significant-music-events/

**Licences:**
- madmom: https://github.com/CPJKU/madmom/blob/main/LICENSE
- Beat This!: https://github.com/CPJKU/beat_this
- BeatNet: https://github.com/mjhydri/BeatNet
- Demucs weights: https://github.com/facebookresearch/demucs/issues/327
- Open-Unmix UMX-HQ weights: https://zenodo.org/records/3370489
- Essentia: https://essentia.upf.edu/licensing_information.html

**Rivals:**
- SonicHue: https://apps.apple.com/app/id6759938225
- iLightShow: https://ilightshow.net
- Lumina: https://apps.apple.com/app/id6760628430
- hueDynamic: https://apps.apple.com/ph/app/id1405195207
- rekordbox Lighting: https://cdn.rekordbox.com/files/20210602085902/rekordbox6.5.2_lighting_operation_guide_EN.pdf
- MaestroDMX: https://www.maestrodmx.com/
- Lightjams: https://www.lightjams.com/
- WLED sound-reactive: https://mm.kno.wled.ge/WLEDSR/Reactive-Animations/

**Datasets:**
- RWC 2.0: https://zenodo.org/records/17177919
- Yadati SSME: https://osf.io/eydxk/
- E-GMD: https://magenta.tensorflow.org/datasets/e-gmd
- StemGMD: https://zenodo.org/records/7860223
- Slakh2100: https://zenodo.org/records/4599666
- Candombe: https://zenodo.org/records/6533068
- GuitarSet: https://zenodo.org/records/3371780
- FMA: https://github.com/mdeff/fma
- Harmonix Set: https://github.com/urinieto/harmonixset
- SALAMI: https://github.com/DDMAL/salami-data-public
- BUT ReverbDB: https://speech.fit.vut.cz/software/but-speech-fit-reverb-database
- Apple Media Services Terms: https://www.apple.com/legal/internet-services/itunes/us/terms.html
