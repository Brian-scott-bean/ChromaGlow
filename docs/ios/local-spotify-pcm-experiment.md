# Local Spotify PCM Sync — experiment record (LOCAL-ONLY)

> Never part of App Store / TestFlight builds. Branch `experiment/local-spotify-pcm-sync`
> (worktree `~/Developer/huehome-spotify-pcm`), based on `main` @ `c2368c8`, rollback tag
> `checkpoint/pre-local-spotify-pcm-sync`. Not merged, not pushed.

## What it is

ChromaGlow advertises itself as a Spotify Connect speaker named **ChromaGlow Sync**. When
Spotify plays to it, a pinned librespot (Rust) decodes the stream; the decoded PCM goes straight
into ChromaGlow's existing audio analyzer (the same one the microphone feeds), and every Live
look drives the lights from it exactly as it would from the mic — no microphone involved.

Phase 1 (this branch): Spotify Connect → librespot → PCM → analyzer → Hue. **Nothing plays out
of the phone** — the music is silent while the lights react. Phase 2 (playback through the phone
/ AirPlay + a lighting offset) is not started; the Rust side already has a dormant pull API and
the Swift router already has the delay/offset plumbing.

## Architecture

```
Spotify app ──zeroconf (Bonjour _spotify-connect._tcp)──► Rust receiver (libchromaglow_spotify.a)
                                                           librespot dev@939dc5e: Session, Spirc, Player
                                                           ChromaSink: f64→f32, 1024-frame chunks,
                                                           paced to real time, in memory only
                                  C callback (player thread) │
                                                             ▼
SpotifyPCMRouter (NSLock per chunk; receiver-generation gate) → InterleavedPCMHopper (stereo→mono, 1024 hops)
                                                             ▼
AudioPCMSink (activation-generation gate) → AudioFeatureExtractor → AudioAnalysisEngine.latestFeatures()
                                                             ▼
              unchanged: BeatClock / tempo, Studio Live looks, Composer reactions, Entertainment + room output
```

- **Audio-source boundary** (`HueHome/Core/Audio/AudioAnalysisSource.swift`): `AudioAnalysisSource`
  protocol; `MicrophoneAudioSource` (the shipped capture moved verbatim); `SpotifyPCMSource`
  (flag-only). `AudioAnalysisEngine.selectSource(_:)` switches; demand/lifecycle unchanged.
- **Real-time rules**: no MainActor hop or Task per buffer, no allocation once warm, bounded
  everything (fixed SPSC ring in Rust, fixed 512-slot delay line in Swift). Stop closes two gates
  synchronously (receiver generation, activation generation) before the blocking Rust stop runs.
- **Credentials**: only Spotify Connect's zeroconf hand-off. No username/password/token is
  entered, configured, stored or logged; librespot runs with no cache directory; the Rust logger
  is capped at Info (librespot TRACE prints client tokens) and redacts the account name.
- **Storage**: decoded PCM is never written. librespot streams the *encrypted* compressed file
  through an unlinked-on-drop temp file in `tmp/ChromaGlowSpotifyStream/`, which the app purges on
  every Start and Stop.

## librespot pin

`librespot-org/librespot` **dev @ `939dc5ee9d833e1980f9495241219d9d4868a061`** (2026-09-11), crates
core/discovery/connect/playback/metadata, `default-features = false`, `native-tls`,
discovery `with-dns-sd`. Pinned by `rev` in `Experimental/SpotifyReceiver/Cargo.toml` and
`Cargo.lock` (committed). Why not v0.8.0: it doesn't build from crates.io (vergen, upstream
#1760) and lacks the CDN-fallback fix (#1722). Upstream state checked 2026-10-01: #1771 (login5
503) was a Spotify outage on 2026-09-29 that recovered the same day; #1737 (INVALID_CREDENTIALS)
affects externally supplied access tokens only, not zeroconf. On iOS librespot announces
`PLATFORM_IPHONE_ARM64` + the iOS client id. `dns-sd` 0.1.3 is vendored under
`Experimental/SpotifyReceiver/patches/` with a one-line `build.rs` fix (it treated only
"darwin" as Apple).

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
5. **Install**: Xcode → open `~/Developer/huehome-spotify-pcm/HueHome.xcodeproj` → scheme
   *HueHome Spotify Experimental* → your iPhone → Run. CLI:
   `xcodebuild -project HueHome.xcodeproj -scheme "HueHome Spotify Experimental" -configuration Debug-SpotifyExperimental -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates build`
   then `xcrun devicectl device install app --device <id> <…>/Debug-SpotifyExperimental-iphoneos/HueHome.app`.
   Build number on this branch: **900** (never uploaded). The branch has **18**
   `CURRENT_PROJECT_VERSION` entries (12 + the new configuration on 6 targets).
6–8. See the test procedure below.

Console-only check (no UI): launch with
`xcrun devicectl device process launch --console --terminate-existing --device <id> -- com.huehome.pro -ChromaGlowSpotifyAutoStart`
— it selects the Spotify source, starts the receiver, holds an analysis demand, and prints a
1 Hz `[SpotifyPCM] state=… frames=… level=… bass=… mid=… treble=…` line.

## Device test procedure (Brian)

Prereqs: Spotify **Premium**, phone and bridge on the same Wi-Fi, an Entertainment area that
covers the test room.

1. Open ChromaGlow → **Studio** → tap the music bar at the bottom ("Nothing playing") → the
   **Music Source** sheet → section **LIGHT-SYNC AUDIO · EXPERIMENT**.
2. Tap **Spotify Connect — Experimental**, then **Start**. Expect: amber dot, *Waiting for Spotify*,
   diagnostics line shows a port.
3. Open the **Spotify** app → device picker (speaker icon on the mini-player) → **ChromaGlow
   Sync** (the list reorders while devices appear — check the name before tapping) → press
   **Play**. **Return to ChromaGlow within ~30 s** — iOS suspends it after that while it's in the
   background (Phase 1 has no background audio). If the hand-off times out, reopen ChromaGlow
   and pick the device again.
4. Back in the sheet expect: green dot, *Connected · Playing*, track/artist, "from <your phone>",
   **PCM 44.1 kHz · 2 ch → mono analysis** with a moving peak meter, and moving
   **All / Bass / Mid / High** bars. The phone is silent (Phase 1).
5. Close the sheet → pick a room → **Deck 1 (Live modes)** → start a Live card. The hint in the
   sheet changes to "A Live look is listening". Lights should follow the song (bass hits, drops,
   pauses), not the room's noise.
6. Pause in Spotify → bars and lights settle within ~0.4 s. Play → they come back.
7. Teardown checks: **Stop** (state *Receiver stopped*; *ChromaGlow Sync* disappears from Spotify's
   list within a few seconds); Start again; switch the sheet back to **Microphone** (receiver
   stops, mic path resumes); stop the Live card (Entertainment session ends as before).
8. Optional: toggle Wi-Fi off/on while connected (expect *Connection dropped — reconnecting*,
   then Connected again), and background/foreground ChromaGlow.
9. Afterwards pick **This iPhone** in Spotify's device list to get audio back.

Report: the state text at each step, the bottom diagnostics line (frames, hops, `play→PCM … ms`),
any red message verbatim (e.g. *Spotify refused the session: …*), and whether the lights tracked
the music.

## Verification status (2026-10-01)

| Check | Result |
| --- | --- |
| Rust crate builds (macOS, iOS device, iOS simulator) | PASS — LTO static lib ≈ 28 MB |
| Rust unit tests | PASS 10/10 |
| macOS harness: Bonjour Add/Rmv, getInfo 101 OK, 3 start/stop cycles, no temp files | PASS |
| iOS simulator: real receiver start→Waiting→stop ×3, controller start/stop | PASS |
| **Physical iPhone (build 900): receiver advertises "ChromaGlow Sync"** — Mac `dns-sd` resolves `brians-iPhone.local.:54345`, `getInfo` → status 101 OK, Speaker | **PASS** |
| **Physical iPhone: "ChromaGlow Sync" listed in the Spotify app's device picker** | **PASS** (seen on the phone) |
| Spotify credential hand-off → Connected on iPhone | **NOT YET RUN** (driving it over iPhone Mirroring hit the 30 s background window) |
| PCM reaches ChromaGlow from Spotify / analyzer responds / Hue reacts | **UNVERIFIED on hardware** (pipeline proven with synthetic PCM through the real router + sink) |
| End-to-end latency | **UNMEASURED.** Designed budget: chunk pacing lead 30 ms + 1024-frame hop 23 ms + render tick + Entertainment ≈ 100–150 ms (estimate, not a measurement). The panel reports play→first-PCM. |
| Phase 2 (playback / AirPlay / offset) | NOT STARTED (gated on Phase 1) |
| Mic sync unchanged with the experiment off | PASS — full suite 2088/2088 (Debug), bit-identical parity test |
| Release + normal Debug device builds free of the experiment | PASS — `Scripts/verify_spotify_experiment_absent.sh` (9 markers + Bonjour key) |
| Flag without DEBUG | PASS — `#error` |

## Known risks

- Unofficial client: librespot impersonates an iPhone Spotify client; Spotify can break or block
  it at any time and its terms don't allow this. Local personal experiment only.
- Phase 1 is silent and needs ChromaGlow in the foreground; the hand-off has a ~30 s window.
- The encrypted stream temp file is librespot-internal (purged by the app, deleted on drop).
- Analysis runs at full scale regardless of Spotify volume (by design); volume 0 in Spotify
  still drives lights.
- Built on `main` (pre-Luminous UI). Porting to `experiment/luminous-app-redesign` needs only the
  Music Source sheet mount point re-placed; everything else is self-contained.

## Rollback

- Drop the experiment: `git worktree remove ~/Developer/huehome-spotify-pcm && git branch -D experiment/local-spotify-pcm-sync` (main and every other branch are untouched; tag `checkpoint/pre-local-spotify-pcm-sync` = `c2368c8`).
- Phone: reinstall Luminous build 62 from TestFlight, or Run from `~/Developer/huehome-luminous-app`.
- Rust toolchain: `~/.cargo/bin/rustup self uninstall`.
