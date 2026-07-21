# Music Integration Design — Apple Music · Spotify · Pandora · ShazamKit (2026-07)

**Status: DESIGN ONLY (v1.1 blueprint).** No app code changes while 1.0 build 33 awaits Brian's
device QA + ASC submission. Scope confirmed with Brian 2026-07-21: **"Sync + Now Playing"** — lights
react to whatever's playing; ChromaGlow shows track/artist/artwork, derives palettes from album art,
offers transport control where the API allows. Not a full in-app music browser. **iOS-first**
(Android has no audio/entertainment stack yet — see §10).

Research base: three agent sweeps on 2026-07-21 — codebase recon, Spotify/Pandora API landscape,
Apple Music + adjacent services. Source URLs in §12.

---

## 0. Executive summary

- **The hard part is already built.** ChromaGlow has a mature on-device audio stack
  (`AudioAnalysisEngine` mic → FFT/onset/tempo → `AudioFeatures`), an app-wide tempo authority
  (`BeatClock`) designed for multiple drive sources, and a 25fps DTLS Entertainment loop. The
  Composer's `ReactionConfig.Source` already includes `.beat`/`.onset` — **a service-driven
  BeatClock makes all 66 built-in looks music-reactive with essentially zero renderer changes.**
- **What's genuinely new** is a *metadata layer*: know what track is playing, where in the track we
  are, what tempo it has, and what colors its artwork suggests. That is one protocol
  (`MusicSource`), one coordinator, per-service adapters, a tempo-lookup sidecar, and an artwork →
  palette extractor.
- **Apple Music (MusicKit) is Phase 1** — deepest sanctioned integration, low effort, App-Store-safe.
- **ShazamKit is Phase 2** and is the universal answer (including Pandora): it identifies whatever is
  audible in the room and reports the *current position within the track*.
- **Spotify is Phase 3, behind a dev flag.** The tech is buildable, but Spotify's 2025/2026 policy
  changes cap a new app at **5 allowlisted users** and reserve public access for registered
  businesses with **250k MAU**. Spotify's beat/tempo analysis endpoints are dead for all new apps.
- **Pandora has no API, full stop.** Partner-gated (SiriusXM), business-only. Pandora users are
  served honestly by mic mode (shipped) + ShazamKit.
- **No streaming service gives third parties raw audio.** Beat detection stays on-device (mic) or
  metadata-driven (position + BPM lookup). This matches the existing security rule: *raw audio never
  leaves the process*.

### Prior art check (Brian asked 2026-07-21)

**No Spotify code ever existed in this repo** — verified against the working tree, the full git
history on all branches (`git log --all --pickaxe-regex -S'[Ss]potify'` → only doc commits), and the
archived ChromaGlow docs in `~/Desktop/Projects/_archive/`. `DEVDOC.md` lists Spotify as unchecked
TODO #6 ("need Client ID/Secret from developer.spotify.com") and the Sync tab planned a
"WHAT source selector (Mic / Spotify)" — only Mic shipped. Greenfield; nothing to resurrect.

---

## 1. The July-2026 capability matrix

| Source | What's playing | Position in track | Tempo/beats | Raw audio | Artwork | Transport control | Public shipping | Effort |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Apple Music** (MusicKit) | ✅ | ✅ (`playbackTime`, polled) | ❌ (no BPM field; has ISRC) | ❌ (FairPlay) | ✅ | ✅ | ✅ App-Store-safe | Low |
| **ShazamKit** (mic) | ✅ (any audible source) | ✅ `predictedCurrentMatchOffset` | ❌ (has ISRC) | mic only | ✅ (URL) | ❌ | ✅ | Low |
| **Spotify** (App Remote + Web API) | ✅ | ✅ (event/poll) | ❌ (analysis dead for new apps) | ❌ | ✅ | ✅ (Premium) | ⚠️ **5 allowlisted users** until extended quota (business + 250k MAU) | Medium |
| **Pandora** | ❌ no API exists | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ partner-only | — |
| **Mic mode** (shipped) | ❌ | ❌ | ✅ on-device estimate | ✅ (on-device only) | ❌ | ❌ | ✅ shipped | Done |
| **Tempo sidecars** (TIDAL/Deezer/GetSongBPM by ISRC) | — | — | ✅ BPM/key lookup | — | — | — | ✅ (verify TIDAL; Deezer gray-zone) | Low |
| **Sonos cloud** | ✅ incl. "Pandora" as service | ⚠️ coarse | ❌ | ❌ | ✅ | ✅ | ⚠️ events need a webhook server → conflicts with no-backend rule | High |
| Skip: Deezer OAuth (closed), SoundCloud (paid key, wrong catalog), YouTube Music (no API), reading system now-playing (private MediaRemote — App Store rejection) | | | | | | | | |

---

## 2. Per-service reality (research detail)

### 2.1 Apple Music / MusicKit — Phase 1

- **Players:** `SystemMusicPlayer` remote-controls the Music app (playback survives ChromaGlow being
  killed, no background-audio capability needed) vs `ApplicationMusicPlayer` (ChromaGlow owns the
  queue, needs background audio mode). **Recommendation: `SystemMusicPlayer`** — it matches the
  "sync + now playing" scope: mirror and control what the user plays in Music, own nothing.
- **Data:** observable `state.playbackStatus` and `queue.currentEntry` (title/artist/artwork/`Song`);
  **`playbackTime` is a plain property — poll it** (1–2 Hz is plenty; extrapolate between polls).
  `Song.attributes` include `isrc` (the tempo-sidecar join key) and `artwork`. **No BPM/analysis
  fields exist** (full attribute list verified against the API docs).
- **Auth/plumbing:** `MusicAuthorization.request()` alert; `NSAppleMusicUsageDescription` in
  Info.plist; **MusicKit App Service checkbox on the App ID** (Certificates → Identifiers → App
  Services) — automatic developer-token generation, no JWT to manage. Full-track playback needs the
  user's Apple Music subscription (non-subscribers: 30s previews); `MusicSubscription.current` gates
  UI honestly.
- **Review:** guideline 4.5.2 — users initiate playback, standard transport controls, and Apple
  Music features must not be paywalled or indirectly monetized.

### 2.2 ShazamKit — Phase 2 (the universal / Pandora answer)

- Free Apple framework, iOS 15+ (we target 17). **`SHManagedSession`** (iOS 17+) handles mic capture
  and yields a continuous async stream of matches — no manual AVAudioEngine plumbing, though we may
  route it through `AudioAnalysisEngine`'s existing tap fan-out (`addBufferTap`) via `SHSession` so
  the mic stays single-owner (decide at implementation; see §5.4).
- **`SHMatchedMediaItem`** gives title/artist/artwork URL/Apple Music ID/**ISRC**, plus
  `matchOffset`, **`predictedCurrentMatchOffset`** (predicted current position in the track),
  `frequencySkew`, `confidence`. Position + sidecar BPM = beat-grid sync for *anything audible*,
  Pandora included.
- Needs the **ShazamKit App Service checkbox** on the App ID; physical device only (no Simulator —
  same class of trap as the CIDetector/VisionKit rule already in AGENTS.md).
- Known fragility: background continuous matching stalls (~20s) on iOS 18-era builds — design it as
  a **foreground feature** (which the Entertainment streaming UX already is).

### 2.3 Spotify — Phase 3, behind a dev flag

- **iOS SDK (App Remote) v5.0.1** (last release Aug 2024, alive but low-touch): connects to the
  installed Spotify app, subscribes to player state (track/artist/album/URI/duration/position,
  play state), fetches album art, issues transport commands. Auth piggybacks the Spotify app
  (app-switch + callback URL scheme). Premium required for on-demand play-by-URI; state-reading
  works for free accounts. Connection drops when ChromaGlow backgrounds; reconnect on foreground.
  Position is event-based, not streamed — extrapolate like Apple Music.
- **Web API:** Authorization Code + **PKCE** (no client secret on device), scopes
  `user-read-playback-state` / `user-read-currently-playing` / `user-modify-playback-state`
  (modify = Premium). Poll `/v1/me/player/currently-playing` every 3–5s + on events; `progress_ms`
  supports client-side extrapolation. Rate limits unpublished (rolling 30s window, 429 +
  `Retry-After`).
- **The blockers (why this is flag-gated):**
  - **Audio Features/Analysis endpoints are DEAD for new apps** since 2024-11-27; enforcement
    confirmed active through 2026; no replacement, no waitlist. Only pre-Nov-2024 extended-mode apps
    (e.g., Signify's Hue partnership) retain beat-grid data. We bring our own tempo (§5.5).
  - **Feb 2026 dev-mode crackdown:** new apps get **5 allowlisted test users** (down from 25), app
    owner must hold Premium, 1 Client ID per developer, several endpoints removed from dev mode
    (player endpoints survive).
  - **May 2025 extended-quota criteria:** legally registered business, launched service,
    **≥250k MAU**, ~6-week review. Individuals can no longer apply.
  - **Policy caution:** developer policy forbids "synchroniz[ing] any sound recordings with any
    visual media" — aimed at sync licensing, but a light show driven by Spotify data sits near it;
    the Hue precedent being a formal partnership is telling. Get a legal read before any *public*
    Spotify marketing; a personal dev-flag build for Brian is the pragmatic v1.1 posture.
- **Net:** build `SpotifySource` cleanly behind `FeatureFlags.spotifySource` (DEBUG/allowlist), keep
  the public UX for Spotify listeners = mic + ShazamKit, and revisit extended quota if/when
  ChromaGlow's numbers qualify.

### 2.4 Pandora — no path

`developer.pandora.com` is partner-gated (company questionnaire, sales projections — the
Sonos/device-maker "Music Partners API"). No consumer OAuth, no SDK, no now-playing endpoint, and
iOS cannot read another app's now-playing (MediaRemote is private API → rejection; re-confirmed by a
Dec 2025 Apple DTS response). The unofficial JSON API is ToS-violating and App-Store-nonviable.
**Product answer:** mic mode (shipped) + ShazamKit identify — honest copy: "Pandora doesn't let
apps connect directly — ChromaGlow listens along instead."

### 2.5 Tempo sidecars (BPM by ISRC)

Priority order for `TrackTempoResolver` (§5.5):
1. **TIDAL Developer Platform** — open self-serve registration, OAuth client-credentials, catalog
   track objects expose **`bpm`, `key`, `keyScale`**; ISRC lookup. ⚠️ *Verify the `bpm` field
   against the live `openapi.tidal.com/v2` spec before building — confidence is medium-high
   (secondary sources).*
2. **GetSongBPM** — free with attribution link.
3. **Deezer public endpoint** (`api.deezer.com/track/isrc:{isrc}` → `bpm`, `gain`) — keyless
   gray-zone; fallback only, never load-bearing.
4. **On-device estimate** — the shipped `TempoEstimator` via mic keeps working with no network at
   all; the sidecar only *sharpens* it. Offline/declined-consent ⇒ mic tempo, feature still works.

Cache results (track ID/ISRC → BPM) persistently; a song's tempo doesn't change.

### 2.6 Sonos + Last.fm — documented, deferred

- **Sonos Control API** (free, OAuth): `metadataStatus` reports track + **`service.name` incl.
  "Pandora"** for whatever the user's Sonos is playing; position is coarse (on state changes).
  BUT real-time events push only to a **registered HTTPS webhook → requires a relay server**,
  conflicting with the "minimal backend later" rule. Park it as the P4 option that would finally
  give sanctioned Pandora *metadata* (device-side polling degrade is possible but ugly).
- **Last.fm** `user.getRecentTracks` (`nowplaying="true"`) — trivial, cross-service, but
  seconds-latency, no position, requires the user to scrobble, and Pandora doesn't scrobble. Skip
  unless users ask.

---

## 3. Architecture

Two decoupled layers; the integration adds only layer 2:

```
┌────────────────────────── layer 2: METADATA (new) ─────────────────────────┐
│  AppleMusicSource   ShazamSource   SpotifySource (flagged)                 │
│         └──────────────┬──────────────┘                                    │
│              MusicSessionCoordinator (@Observable, @MainActor)             │
│   NowPlayingTrack ──► TrackTempoResolver ──► BeatClock drive .service      │
│        │                     │                                             │
│        ▼                     ▼                                             │
│  ArtworkPaletteExtractor   beat phase = f(position, BPM, anchor)           │
│        │                                                                   │
└────────┼───────────────────────────────────────────────────────────────────┘
         ▼                              (existing, unchanged)
┌────────────────────────── layer 1: SIGNAL (shipped) ───────────────────────┐
│  AudioAnalysisEngine (mic) ─► AudioFeatures ─┐                             │
│  BeatClock.shared  ◄─ tap / manual / audio / │ NEW .service                │
│                                              ▼                             │
│  CompositionEngine.render(features:, beat:) ─► 25fps DTLS send(channels:)  │
│  (ReactionConfig.Source .beat/.onset already consume BeatClock)            │
└────────────────────────────────────────────────────────────────────────────┘
```

Key properties:
- **The renderer never learns about music services.** `CompositionEngine.render` keeps its exact
  signature; services only influence `BeatClock` and (optionally) palettes. All 66 looks + user
  creations become track-locked via the existing `.beat`/`.onset` reaction sources and
  `quantizeBeats`.
- **Mic remains the universal signal.** Service adapters *sharpen* sync (exact track phase, real
  BPM) but their absence degrades gracefully to today's shipped behavior.
- **`BeatClock` gains one drive case** (`DriveSource.service`), same pattern as the existing
  audio-follow drive: coordinator computes beat phase from `(positionMillis at timestamp, BPM)` and
  re-anchors on seek/track-change; render loops keep extrapolating via `BeatClock.snapshot()`.
  Priority rule: an explicit tap/manual override always beats `.service`, `.service` beats
  `.audio` while a track with known BPM is playing.
- **Privacy unchanged:** raw audio still never leaves the process. New network egress is only:
  MusicKit calls (Apple), optional ISRC → tempo lookups, and (flagged) Spotify API calls — all
  user-initiated features, disclosed in §9.

---

## 4. Component specs (layer 2)

### 4.1 `MusicSource` protocol + `NowPlayingTrack` (`Core/Music/MusicSource.swift`)

```swift
struct NowPlayingTrack: Equatable, Sendable {
    let service: MusicService            // .appleMusic, .shazamDetected, .spotify
    let title: String
    let artist: String
    let isrc: String?                    // tempo-sidecar join key
    let appleMusicID: String?
    let durationMs: Int?
    let artworkURL: URL?                 // or MusicKit Artwork handled by the adapter
}

struct PlaybackPosition: Sendable {      // enough to extrapolate beat phase
    let positionMs: Int
    let capturedAt: TimeInterval         // CACurrentMediaTime() domain, like BeatClock
    let isPlaying: Bool
}

@MainActor protocol MusicSource: AnyObject {
    var service: MusicService { get }
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)? { get set }
    func start() async throws            // auth + begin observing
    func stop()
    func transport(_ action: TransportAction) async  // play/pause/skip; no-op where unsupported
}
```

### 4.2 `MusicSessionCoordinator` (`Core/Music/MusicSessionCoordinator.swift`)

`@Observable @MainActor final class`, owned by `UnifiedOrchestrator` (one property + wiring — a
small, contained touch to the god object, same pattern as the composer scheduler). Responsibilities:
- Owns at most one active `MusicSource`; exposes `nowPlaying`, `activeService`, `tempo` for UI.
- On track change: kick `TrackTempoResolver` (async, cached), kick `ArtworkPaletteExtractor`.
- On position/tempo: drive `BeatClock` `.service` (re-anchor, don't fight the extrapolator).
- Publishes into the existing Now-Playing surface alongside `activeEffectEntries` (the b20f0ef
  registry contract) — the music strip and the effect registry are siblings, not merged.
- Respects `AudioDemand` semantics: ShazamSource holds a demand on `AudioAnalysisEngine` exactly
  like Perform holds `.performance` (AGENTS.md build-23 facts).

### 4.3 `BeatClock` change (`Core/Audio/BeatClock.swift` — small, additive)

Add `case service` to `DriveSource`; add
`func driveFromTrack(bpm: Double, position: PlaybackPosition)` that sets tempo + phase anchor.
Existing `BeatMath` 3Hz WCAG cap keeps applying — **photosensitivity guarantees survive untouched**
(`PresetCatalogTests` bar unchanged). Unit tests: phase math vs seek/pause/resume, drive priority.

### 4.4 Source adapters (`Core/Music/`)

- **`AppleMusicSource.swift`** — `SystemMusicPlayer` state + `queue.currentEntry` observation, 1–2Hz
  `playbackTime` polling while a sync is active, `MusicAuthorization` flow, subscription gate.
- **`ShazamSource.swift`** — continuous matching; emits `NowPlayingTrack(service: .shazamDetected)` +
  `PlaybackPosition(predictedCurrentMatchOffset)`. Implementation choice to resolve at build time:
  `SHManagedSession` (own mic session — simplest) vs `SHSession` fed by
  `AudioAnalysisEngine.addBufferTap` (single mic owner — cleaner with the demand system).
  **Default: the buffer-tap route**, keeping `AudioAnalysisEngine` the sole `AVAudioSession` owner
  (its header declares exactly that contract).
- **`SpotifySource.swift`** + **`SpotifyAuthService.swift`** (PKCE via `ASWebAuthenticationSession` —
  net-new pattern, tokens in `KeychainManager` under service `com.lightshade.app`, accounts
  `spotify_access_token` / `spotify_refresh_token`) + **`SpotifyAPIClient.swift`** (URLSession,
  mirrors `HueAPIClient` conventions; 429/`Retry-After` backoff). App Remote SDK is an optional
  second step (adds an SPM/xcframework dependency + `LSApplicationQueriesSchemes: spotify` +
  callback URL scheme); the Web-API-only path has no SDK dependency and may be enough for
  flag-gated use. Entire source compiled but gated by `FeatureFlags.spotifySource`.

### 4.5 `TrackTempoResolver` (`Core/Music/TrackTempoResolver.swift`)

Pure-logic core (testable) + pluggable providers: `TIDALTempoProvider`, `GetSongBPMProvider`,
`DeezerTempoProvider` (ordered, first-hit wins), backed by a persistent `TempoCache` (small JSON in
Application Support, same file-store idiom as `CompositionStore` — **not** SwiftData, to keep it
trivially shared/testable). Falls back to `TempoEstimator`'s live estimate (confidence-tagged).
Provider keys live in build config, never in source.

### 4.6 `ArtworkPaletteExtractor` (`Core/Music/ArtworkPaletteExtractor.swift`)

Pure + tested, mirroring the catalog rules: downsample artwork (CoreImage `CIAreaAverage` on a
k-region grid or simple k-means on a 32×32 thumbnail), pick 2–4 dominant colors, run through
`HueColorUtils.xyFrom + clampXYToGamut(.c)` (the `SiriColorTable` precedent — including its 1e-9
re-clamp-stability test idiom), emit a `PaletteConfig` (gradient/spectrum). UI: "Use album colors"
action on the Now Playing strip applies it to the active composition via the existing editor-binding
path (`activeCompositionBoxes`), never a parallel write path.

### 4.7 Now Playing UI (`UI/Music/NowPlayingBar.swift`, `UI/Music/MusicSourcePicker.swift`)

- A compact strip (StageKit components — `StageCard`/`StageBadge`, consume `\.isTabActive` for any
  animation) showing artwork, title/artist, beat-lock indicator (BPM + source), transport buttons
  when the source supports them, and "Use album colors".
- Placement proposal: Studio tab above the mixer tray (primary), with the Dashboard now-playing
  registry untouched. **Do not add modifiers to `StudioView.body`** — it is at the type-checker
  ceiling; extend via the `StudioDrainWiring`-style modifier pattern (AGENTS.md build-25 fact).
- Source picker: Mic (default) · Apple Music · Auto-detect (Shazam) · Spotify (flag). Honest Pandora
  copy lives here.

---

## 5. Project plumbing

- **New files** register via a new idempotent `add_music_files.rb` (xcodeproj gem — same train as
  `add_siri_intent_files.rb` etc.). Main app target only; nothing for widget/watch in v1.1.
- **Info.plist:** add `NSAppleMusicUsageDescription`. (Mic string already shipped.) Phase 3 adds
  `LSApplicationQueriesSchemes: [spotify]` + a callback URL scheme if App Remote is adopted.
- **App ID services (ASC portal, Brian's manual step):** enable **MusicKit** (P1) and **ShazamKit**
  (P2) checkboxes on `com.huehome.pro`. No entitlement-file changes → no provisioning churn beyond
  the portal toggle.
- **No new third-party dependencies in P1/P2.** P3 optionally adds the Spotify iOS SDK.
- **Tests** (`HueHomeTests/`): `BeatClockServiceDriveTests` (phase/seek/priority math),
  `TrackTempoResolverTests` (provider order, cache, offline fallback — mocked providers),
  `ArtworkPaletteTests` (gamut-C membership, re-clamp stability, degenerate images),
  `MusicSourceContractTests` (coordinator state machine on track change/stop/auth-revoke),
  plus a `NowPlayingTrack` codec test if anything persists.

---

## 6. Phasing + effort

| Phase | Contents | Est. effort | Ships |
| --- | --- | --- | --- |
| **P1 — Apple Music core** | `MusicSource`/coordinator, `AppleMusicSource`, BeatClock `.service`, `TrackTempoResolver` (TIDAL+cache+mic fallback), `ArtworkPaletteExtractor`, Now Playing strip + picker, tests, plumbing | ~4–6 dev-days | v1.1 |
| **P2 — Auto-detect (ShazamKit)** | `ShazamSource` via buffer tap, "listening along" UX, Pandora honesty copy | ~2–3 dev-days | v1.1 or v1.1.x |
| **P3 — Spotify (flagged)** | PKCE auth + Web API client + `SpotifySource`; optional App Remote SDK; dashboard setup (Brian: create the app at developer.spotify.com, allowlist his account) | ~4–5 dev-days | dev-flag only |
| **P4 — deferred** | Sonos relay (needs backend decision), Last.fm, Android | — | on demand |

Sequencing note: P1's `predictedCurrentMatchOffset`-style track-position clock is exactly what the
**Sequence Builder** design (`docs/ios/sequence-builder-design-2026-07.md`) needs for timeline-locked
shows — these two features compound; build P1 first.

---

## 7. Compliance & risk register

- **Security rules (AGENTS.md) — all preserved:** raw audio never collected (mic DSP unchanged;
  Shazam matching is on-device signature generation); no Hue credentials involved; Spotify/TIDAL
  tokens are local-only Keychain secrets, never logged (extend `SecretLogScrubTests` to the new
  token accounts — same H-03/H-04 discipline).
- **Privacy label:** currently "Data Not Collected." Tempo lookups send an ISRC/track ID to a third
  party (TIDAL etc.) and Spotify linking shares account data with Spotify — when P1/P3 ship,
  re-review the ASC privacy label + the hosted privacy policy (the build-27 runbook's label section
  is the checklist). Make tempo lookup skippable (Settings toggle, default on, honest one-liner).
- **App Review:** 4.5.2 (don't paywall Apple Music features); mic/Shazam is foreground-only (no new
  `UIBackgroundModes`); photosensitivity: 3Hz cap already enforced in `BeatMath` + preset tests —
  music-reactive output inherits it.
- **Legal caution (Spotify):** the "no synchronizing recordings with visual media" policy clause —
  low risk for a personal dev-flag build; get a legal read before public Spotify marketing.
- **Technical risks:** TIDAL `bpm` unverified against live spec (verify first — it gates the
  sidecar's top provider); MusicKit `playbackTime` drift (mitigate: re-poll + re-anchor, tolerance
  window in BeatClock tests); Shazam needs audible room volume (set UX expectations); Spotify SDK
  staleness (Web-API-only path avoids it).

---

## 8. Android forward-compatibility (design-only note)

Android has pairing foundations only — no audio capture, no Entertainment streaming, no effects
engine (`RECORD_AUDIO` not even in the manifest). Music sync is iOS-only until Android Batch 5+
lands dashboard control and, later, an entertainment/audio stack. When it does: Android *can*
capture other apps' audio via `AudioPlaybackCapture` (API 29+, apps can opt out — Spotify allows it,
some don't), which is a *better* universal signal than iOS mic mode; the `MusicSource` model above
ports cleanly. No Android work is authorized by this doc (MVP exclusions in AGENTS.md stand).

---

## 9. Open questions for Brian

1. **Spotify dev-flag posture OK?** (Build it for your own 5-user allowlist, no public marketing
   until extended quota is realistic.) Alternative: skip Spotify entirely in v1.1; mic+Shazam
   already serve Spotify listeners.
2. **Now Playing strip placement:** Studio tab (proposed) vs Dashboard vs both?
3. **Tempo sidecar consent default:** on with a Settings toggle + honest copy (proposed), or opt-in?
4. **TIDAL developer registration:** self-serve — do at P1 start (needed to verify `bpm` and get
   keys). GetSongBPM attribution link is a small Settings/About addition.
5. **ASC portal toggles** (MusicKit, ShazamKit App Services) are manual owner steps at P1/P2 start.

---

## 10. Sources (verified 2026-07-21)

Spotify: developer.spotify.com — iOS SDK docs + GitHub releases; Web API authorization/scopes/
rate-limits docs; blog 2024-11-27 "Changes to the Web API"; blog 2025-04-15 "Updating the Criteria
for Web API Extended Access"; February-2026 migration guide; developer policy. Hue×Spotify:
signify.com press 2021-09-01. Pandora: developer.pandora.com partner-access docs;
siriusxm-api-docs.pandora.com. Apple: WWDC26 session 254 (MusicKit); Songs.Attributes API doc;
forums threads 726626/729046 (no PCM/BPM), 809554 + DTS Dec-2025 (no system now-playing read);
SHMatchedMediaItem docs; App Review Guidelines 4.5.2/2.5.4. TIDAL: developer.tidal.com +
tidal-music/tidal-sdk-ios (v0.11.28, 2026-07-17) + OpenAPI-derived collections (bpm/key — verify).
Deezer: developers.deezer.com + community closure threads. Sonos: docs.sonos.com control/
metadatastatus/subscribe. Last.fm: user.getRecentTracks API page.
