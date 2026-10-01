# Local Spotify PCM Sync — experiment record (LOCAL-ONLY)

> Never part of App Store / TestFlight builds. Not merged, not pushed.
>
> - **Current: Luminous + Phase 2** — branch `experiment/luminous-spotify-pcm` (worktree
>   `~/Developer/huehome-luminous-spotify`), based on `experiment/luminous-app-redesign` @ `b5f466d`
>   (build 62), rollback tag `checkpoint/pre-luminous-spotify-pcm`. Device build **902**.
> - Phase 1 on the old UI: branch `experiment/local-spotify-pcm-sync` (worktree
>   `~/Developer/huehome-spotify-pcm`), based on `main` @ `c2368c8`, tag
>   `checkpoint/pre-local-spotify-pcm-sync`, device builds 900/901. Superseded; kept for reference.

## What it is

ChromaGlow advertises itself as a Spotify Connect speaker named **ChromaGlow Sync**. When
Spotify plays to it, a pinned librespot (Rust) decodes the stream; the decoded PCM goes straight
into ChromaGlow's existing audio analyzer (the same one the microphone feeds), and every Live
look drives the lights from it exactly as it would from the mic — no microphone involved.

- **Phase 1** — Spotify Connect → librespot → PCM → analyzer → Hue. Silent: nothing plays out of
  the phone. Proven on Brian's iPhone (build 901: Spotify connects to "ChromaGlow Sync").
- **Phase 2** (this branch) — the phone also **plays the music**: on its speaker, Bluetooth, or an
  AirPlay speaker picked with the system route picker. The lights are delayed to match what is
  heard (playback queue + the route's output latency), with a **Light timing** slider for the rest.

## Architecture

```
Spotify app ──zeroconf (Bonjour _spotify-connect._tcp)──► Rust receiver (libchromaglow_spotify.a)
                                                           librespot dev@939dc5e: Session, Spirc, Player
                                                           ChromaSink: f64→f32, 1024-frame chunks,
                                                           in memory only
                     ┌──── playback on: bounded SPSC ring (target 0.25 s, hand-off only)
                     │     SpotifyPlaybackFeeder (serial queue, 10 ms tick + requestMediaDataWhenReady)
                     │       cg_spotify_read_playback → CMSampleBuffer (≤4096 frames, contiguous PTS)
                     │       → AVSampleBufferAudioRenderer ⇄ AVSampleBufferRenderSynchronizer
                     │       session .playback + routeSharingPolicy .longFormAudio → speaker / BT /
                     │       one or more AirPlay 2 speakers
                     │     playback off: paced to wall clock
            C callback (player thread, queued_frames = ring depth ahead of this chunk)
                                                             ▼
SpotifyPCMRouter (NSLock per chunk; receiver-generation gate) → InterleavedPCMHopper (stereo→mono, 1024 hops)
   presentation time = host time the synchronizer plays frame (nextFrame + queued) + light offset
   (playback off: now + light offset)
                                                             ▼
AudioPCMSink (activation-generation gate) → AudioFeatureExtractor → delay line → latestFeatures()
                                                             ▼
              unchanged: BeatClock / tempo, Composer Live looks, Entertainment + room output
```

- **Audio-source boundary** (`HueHome/Core/Audio/AudioAnalysisSource.swift`): `AudioAnalysisSource`
  protocol; `MicrophoneAudioSource` (Luminous's capture moved out of the engine, every Luminous fix
  kept — A2DP, capture-time stamping, configuration-change rebuild via `onSystemStop`, no
  background recovery, capture-failed notice); `SpotifyPCMSource` (flag-only).
  `AudioAnalysisEngine.selectSource(_:)` switches; demand/lifecycle unchanged.
- **Playback** (`SpotifyPlaybackOutput.swift`, AirPlay 2 lane): `AVAudioSession` `.playback` /
  `.default` / `routeSharingPolicy: .longFormAudio` (no options — long-form allows none) — the
  route policy that gives the system picker its multi-speaker AirPlay 2 UI. Long-form apps are
  expected to publish Now Playing + remote commands (`SpotifyNowPlaying.swift`, other lane).
  `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer` fed by
  `SpotifyPlaybackFeeder` on one serial queue: a 10 ms timer pulls only what the ring HAS (status
  `playback_queued_frames`; whole 4096-frame chunks unless the renderer runs low) up to a bounded
  lookahead, builds one CMSampleBuffer per chunk with contiguous timeline PTS, and waits on
  `requestMediaDataWhenReady` when the renderer is full. No silence is ever enqueued.
  - **Start**: the first audio schedules the timeline (`setRate(1, time:, atHostTime: now +
    startDelay)`, `delaysRateChangeUntilHasSufficientMediaData = false` — AirPlay's "sufficient"
    threshold can exceed what a live stream ever queues).
  - **Lookahead / preroll**: local 1.0 s / 0.2 s; AirPlay 3.0 s / 1.0 s (follows route changes).
    The lookahead bounds how late a Spotify **skip or seek** is heard (≤ lookahead + 0.25 s ring);
    track changes are not flushed, so gapless transitions stay intact.
  - **Underrun**: ring dry and < 30 ms enqueued → the timeline is *parked* (rate 0) where it is
    and rescheduled when audio returns — it never runs ahead of real data.
  - **Pause** (status Paused/Idle): renderer flushed + timeline parked → silence at once; light
    hops already scheduled are dropped. Play continues the same timeline.
  - **Keep-alive**: Rust counts its consumer dead after 300 ms without a pull, so an empty ring is
    still pulled every 100 ms.
  - **Route change** (AirPlay, Bluetooth): no rebuild; when the renderer auto-flushes
    (`WasFlushedAutomatically`) the feeder re-enqueues from a bounded in-memory history (4 s) at
    the flush time. Media-services reset / renderer failure / interruption-resume rebuild the
    renderer + synchronizer; interruptions resume only on `.shouldResume` (else a *Resume* row).
    Stop is synchronous: timer cancelled, request block removed, rate 0, renderer flushed.
- **Light timing**: `SpotifyPlaybackClock` (shared with the router) maps a chunk with
  `queued_frames` ahead of it to timeline frame `nextFrame + queued` (`nextFrame` is published
  right after each ring pop) and converts it to host time through the synchronizer's timebase
  (or the scheduled start while parked). Per WWDC17 509 the synchronizer's timeline is the HEARD
  one — a local video layer on it stays in sync with audio on an AirPlay speaker — so the route's
  reported latency is no longer added (it is display-only in the *… ms behind* row). **Light
  timing** (−500…+3000 ms, persisted) adds on top; total delay never goes below 0.
- **Background**: `UIBackgroundModes audio` is injected into the *built* Info.plist only in
  `Debug-SpotifyExperimental`, so the music keeps playing with the screen locked or Spotify in
  front, and the Spotify hand-off no longer has a 30 s window while playback is on. The analyzer
  (and so the lights) still pauses while ChromaGlow is in the background, exactly as the mic does.
- **Real-time rules**: no MainActor hop or Task per buffer, no allocation once warm, bounded
  everything (fixed SPSC ring in Rust, fixed 512-slot delay line in Swift). Stop closes two gates
  synchronously (receiver generation, activation generation) before the blocking Rust stop runs.
- **Credentials**: only Spotify Connect's zeroconf hand-off. No username/password/token is
  entered, configured, stored or logged; librespot runs with no cache directory; the Rust logger
  redacts the account name, the zeroconf request params and access tokens.
- **Storage**: decoded PCM is never written. librespot streams the *encrypted* compressed file
  through an unlinked-on-drop temp file in `tmp/ChromaGlowSpotifyStream/`, which the app purges on
  every Start and Stop. Nothing is recorded, exported or saved.

## librespot pin

`librespot-org/librespot` **dev @ `939dc5ee9d833e1980f9495241219d9d4868a061`** (2026-09-11), crates
core/discovery/connect/playback/metadata, `default-features = false`, `native-tls`,
discovery `with-dns-sd`. Pinned by `rev` in `Experimental/SpotifyReceiver/Cargo.toml` and
`Cargo.lock` (committed). Why not v0.8.0: it doesn't build from crates.io (vergen, upstream
#1760) and lacks the CDN-fallback fix (#1722). Two vendored patches under
`Experimental/SpotifyReceiver/patches/`: `dns-sd` 0.1.3 (one-line `build.rs` fix — it treated only
"darwin" as Apple) and `librespot-core` at the same rev (a runtime platform persona: by default the
receiver introduces itself as librespot's desktop-Linux speaker, the identity every Raspberry Pi
install uses; "iPhone app" is librespot's native iOS identity).

## Build & install

1. **Rust toolchain** (once):
   `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal`
   then `~/.cargo/bin/rustup target add aarch64-apple-ios aarch64-apple-ios-sim`.
2. **Build the receiver**: `Scripts/build_spotify_receiver.sh` (runs the Rust tests, builds LTO'd
   device + simulator static libs into the git-ignored `Experimental/SpotifyReceiver/build/`,
   plus an XCFramework).
3. **Link**: already wired — the `Debug-SpotifyExperimental` configuration sets
   `SWIFT_INCLUDE_PATHS`, `LIBRARY_SEARCH_PATHS` (`build/$(PLATFORM_NAME)`) and `OTHER_LDFLAGS`.
   `ruby add_spotify_experiment.rb` (idempotent) re-applies the wiring if needed.
4. **Flag**: pick the scheme **HueHome Spotify Experimental** (Run/Test/Analyze use
   `Debug-SpotifyExperimental`, which alone defines `CHROMAGLOW_EXPERIMENTAL_SPOTIFY`).
5. **Install**: Xcode → open `~/Developer/huehome-luminous-spotify/HueHome.xcodeproj` → scheme
   *HueHome Spotify Experimental* → your iPhone → Run. CLI:
   `xcodebuild -project HueHome.xcodeproj -scheme "HueHome Spotify Experimental" -configuration Debug-SpotifyExperimental -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates build`
   then `xcrun devicectl device install app --device <id> <…>/Debug-SpotifyExperimental-iphoneos/HueHome.app`.
   Build number on this branch: **902** (never uploaded). The branch has **18**
   `CURRENT_PROJECT_VERSION` entries (12 + the new configuration on 6 targets).

Console-only check (no UI): launch with
`xcrun devicectl device process launch --console --terminate-existing --device <id> -- com.huehome.pro -ChromaGlowSpotifyAutoStart`
— it selects the Spotify source, starts the receiver (and the playback output), holds an analysis
demand, and prints a 1 Hz `[SpotifyPCM] state=… out=… route=… lat=… queue=… level=…` line.

## Device test procedure (Brian)

Prereqs: Spotify **Premium**, phone and bridge on the same Wi-Fi, an Entertainment area that
covers the test room. For AirPlay: an AirPlay speaker or Apple TV on the same network.

1. ChromaGlow → **Composer** tab → the **Music** strip under the header ("Nothing playing") →
   the **Music Source** sheet → scroll to **LIGHT-SYNC AUDIO · EXPERIMENT**. (Home shows the same
   strip once a music session exists.)
2. Tap **Spotify Connect — Experimental**, then **Start**. Expect *Waiting for Spotify*, a port in
   Diagnostics, and under **Sound**: *Play the music on this iPhone* on, *Playing on: iPhone
   Speaker* (or your headphones).
3. Open **Spotify** (on this phone or another device) → speaker icon → **ChromaGlow Sync** →
   **Play**. With playback on, ChromaGlow keeps running in the background — no 30 s rush.
4. **You should now HEAR the song from the phone.** Back in the sheet: *Connected · Playing*,
   track/artist, **PCM 44.1 kHz · 2 ch → mono analysis**, moving **All / Bass / Mid / High** bars,
   and in Diagnostics `queue ~250 ms · lights +~1.2 s` (renderer lookahead + ring). Spotify's own
   volume slider controls the loudness.
5. **AirPlay / Bluetooth**: tap the speaker icon on the *Playing on* row → pick one speaker, or
   tick **several AirPlay 2 speakers** (long-form routing shows the multi-speaker list). The music
   moves there (a brief gap while the renderer re-routes is expected); `lights +…` grows to
   ~3–4 s on AirPlay. "… ms behind" is iOS's reported route latency, now display-only.
6. Close the sheet → **Composer** → **Party** → open a look that dances to music → **Go Live**.
   The sheet's hint changes to "A Live look is listening". Lights should hit with the beats you
   hear — on the AirPlay speaker too.
7. If the lights lead or trail the beat, move **Light timing** (later if the lights flash before
   the beat you hear, earlier if after) — try ±50–100 ms steps; it applies instantly and is
   remembered.
8. Pause in Spotify → music stops, lights settle. Play → both come back. Lock the phone → the
   music continues (the lights pause until ChromaGlow is back in front, as with the mic).
9. Interruptions: take a call / trigger Siri → music pauses; after a call it resumes on its own,
   otherwise tap *Audio was interrupted — Tap to resume*.
10. Teardown: **Stop** (music stops, *ChromaGlow Sync* disappears from Spotify within a few
    seconds); switch back to **Microphone** (receiver + music stop, mic path resumes). Afterwards
    pick **This iPhone** in Spotify's device list.

Report: the state text at each step, whether you heard the music (phone / AirPlay / Bluetooth),
the *Playing on* subtitle, the Diagnostics line (`queue`, `underruns`, `lights +…`), the Light
timing value that looked right, and any red message verbatim. **Copy diagnostics** puts a
sanitised report on the clipboard.

## Verification status (2026-10-01)

| Check | Result |
| --- | --- |
| Rust crate builds (macOS, iOS device, iOS simulator) | PASS — LTO static lib ≈ 28 MB |
| Rust unit tests | PASS 14/14 |
| Physical iPhone, Phase 1 (build 901): advertised, listed in Spotify, **Spotify connects** | **PASS** (Brian, 2026-10-01) |
| Simulator: real receiver start→Waiting→stop ×3, controller start/stop **with the playback output** (`.playback` session, AVAudioEngine running) | PASS |
| Simulator: render pull deinterleaves + zero-fills across a >4096-frame request; playback toggle live; light offset clamp/persist; route latency counted on an empty queue | PASS |
| Audio-source boundary on Luminous's engine (16 tests, incl. configuration-change rebuild without a session bounce, background-deferred recovery, route-change rebuild) | PASS |
| Experimental build carries the experiment + `UIBackgroundModes audio` | PASS (`verify_spotify_experiment_absent.sh --expect-present`) |
| **Phase 2 on hardware: music audible on phone / Bluetooth / AirPlay, lights in step** | **NOT YET RUN** — Brian's device round |
| End-to-end latency | **UNMEASURED.** Lights are scheduled at ring depth + reported route latency + offset; how well iOS's reported AirPlay latency matches reality is exactly what step 5–7 measure. |
| Mic sync unchanged with the experiment off | see DEVLOG entry (full Debug suite) |
| Release + normal Debug builds free of the experiment | see DEVLOG entry (`verify_spotify_experiment_absent.sh`, now also checks background audio) |
| Flag without DEBUG | PASS — `#error` |

## Known risks

- Unofficial client: librespot is not a Spotify-sanctioned receiver; Spotify can break or block it
  at any time and its terms don't allow this. Local personal experiment only.
- AirPlay 2 multi-room through the long-form renderer is **unverified on hardware**: whether a
  3 s lookahead / 1 s preroll is enough for a group (Apple: on AirPlay 2 the renderer "asks for
  minutes"), and how closely the synchronizer's time matches what the speakers play — the Light
  timing slider absorbs the rest. Echo/Alexa speakers aren't AirPlay targets (one Echo works over
  Bluetooth); joining an Alexa multi-room group is out of scope by design.
- With playback on, ChromaGlow stays alive in the background while the receiver is on (it is an
  active audio app). Press **Stop** when done.
- The lights still need ChromaGlow in the foreground (the analyzer pauses in the background, as it
  does for the mic).
- The encrypted stream temp file is librespot-internal (purged by the app, deleted on drop).
- Analysis runs at full scale regardless of Spotify volume (by design); volume 0 in Spotify still
  drives the lights.

## Rollback

- Drop the Luminous experiment: `git worktree remove ~/Developer/huehome-luminous-spotify && git branch -D experiment/luminous-spotify-pcm` (Luminous and every other branch are untouched; tag `checkpoint/pre-luminous-spotify-pcm` = `b5f466d`).
- Drop Phase 1: `git worktree remove ~/Developer/huehome-spotify-pcm && git branch -D experiment/local-spotify-pcm-sync` (tag `checkpoint/pre-local-spotify-pcm-sync` = `c2368c8`).
- Phone: reinstall Luminous build 62 from TestFlight, or Run from `~/Developer/huehome-luminous-app`.
- Rust toolchain: `~/.cargo/bin/rustup self uninstall`.
