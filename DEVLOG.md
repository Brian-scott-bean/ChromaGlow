# ChromaGlow Development Log

> **AI assistants: Append to this file after every session. Read it at the start of every session.**

---

## Current Status Snapshot (updated 2026-08-01)

### Pointers
- Canonical agent context: `AGENTS.md`. Claude Code entry point: `CLAUDE.md` points there.
- Live shared handoff: append-only entries in this `DEVLOG.md`. Git is the shared memory between tools.

### iOS — where we are RIGHT NOW
- **`main` is the current production anchor and the branch Brian installs from**
  (Xcode → physical iPhone, scheme **`HueHome 1`**, marketing version **1.0.0**, build **46**).
- **COMPOSER 2 / PHASE 0 / PACKET 7 (2026-08-03): ChromaGlow now YIELDS to third-party
  Entertainment sessions.** Branch `fix/third-party-entertainment-consent`, rollback tag
  `checkpoint/pre-composer-packet-7` (at `446fd49`), PR open and **unmerged**. Automatic
  cleanup used to `action=stop` every active configuration this process had not registered —
  on every launch, foreground, and refresh — silently evicting a Sync Box or another Hue app.
  Ownership is now keyed by exact bridge + configuration and **persisted** (non-secret: bridge
  id, configuration id, timestamp), so cleanup stops only ChromaGlow's own orphaned sessions,
  and a third party is replaced only after an explicit playback action **and** an explicit
  "Take Over". Only the final process owner may send a stop; cleanup takes an exclusive claim
  before it destroys anything; and playback starts as a prepare/start/commit transaction, so a
  controller arriving mid-start costs the user nothing. Suite 1172/1172 green (xcresulttool). No new source file, no pbxproj change, no build bump. **Needs Brian's
  two-controller device pass** — the packet-7 section of
  `docs/ios/master-on-device-checklist.md`. Entry below.
- **BUILD 46 (2026-08-01): mixer tray reclaims the ~200pt dead band above the Now Playing
  card** — the R8c double-count, finally closed for the tray. Rollback tag
  `checkpoint/mixer-tray-reclaim-band`. Entry below.
- **BUILD 45 (2026-07-22): ROUND 4b — Brian's two deferred product calls, decided + shipped.**
  (1) A deep link/Siri command arriving MID-TOUR now dismisses the tour (no seen-stamp — it
  returns next clean launch) and routes after the cover's dismissal animation
  (`DeepLinkCoordinator.tourSurfaceUp`, retry guards keyed on `openToken == 0`).
  (2) Minimal staleness honesty: stale widget snapshots dim on every face + the paired-empty
  small face says "Open ChromaGlow to refresh" instead of asserting "All lights off"; the
  watch rooms list shows "Updated Xm ago" past 30 min (`WatchStore.lastSyncedAt` — the
  timestamp was always written, never read). Entry below.
- **BUILD 44 (2026-07-22): FULL-APP AUDIT ROUND — 30 shippable commits, awaiting Brian's
  on-device check** (rollback tag `checkpoint/full-audit-2026-07-22`). The §8.4 deferred-LOW
  ledger is closed for every software-only item (L-02/L-28 2xx errors surfaced, L-03, L-04,
  L-12, L-13, L-16-software, L-29, L-47; L-05 died with the deleted dead Sync stack —
  RestSender extracted to Core/Network; L-06/L-11 verified already-fixed; L-43 documented
  dead code), plus a 4-lane fresh sweep's confirmed findings: music-session lifecycle
  (unpair/guest-flip/demo-leak + paired demo-exit dead app), automation notification
  replay/double-fire + launch re-registration + honest copy, All Day Scenes timezone
  inversion, watch/widget optimistic writes now acknowledgment-gated, favorites order
  scramble, RoomDetail delete hygiene, widget publish diff-gate + revocation timeline
  reload, Spotify pause-tier/single-flight/dead-grant, BeatClock pin-vs-service-hold +
  high-BPM re-anchor, Shazam idempotent stop, audio stale-tempo guards, LookPreviewStrip
  idle tier, harmony-clear sentinel (`Optional.none` bug). **THE TOUR IS 13 PAGES** —
  new owner-only `tour.music` + copy refresh (66 looks, previews, Brightness Shape) + a
  versioned "What's New" (`castchroma.seenTourVersion`) so v1.0-tour completers meet the
  music page once. run_tests.sh finally targets `HueHome 1` with a simulator default.
  Audit ledger: `docs/audit/hardening-audit-2026-07-01.md` §9. Full entry below
  (2026-07-22). Suite 833/833 green per batch (xcresulttool-verified).
- **MUSIC INTEGRATION (builds 34–43, 2026-07-21) is dev-complete** — sources (Apple Music /
  Auto-Detect Song / sample track / DEBUG-flagged Spotify), beat-locked looks, album-color
  painting, Dashboard strip; R9 audited it end-to-end (11 findings, 8 fixed). v1.1-only:
  the 1.0 ASC archive cuts from the build-33 commit `0318516`. See the MUSIC R1–R9 entries.
- **WORLD-CLASS POLISH PROGRAM IN FLIGHT (2026-07-17, Brian-approved):** six rollback-safe
  rounds → builds 29–33 (A visible UX: tour-overlap/keyboard/44pt · B previews-everywhere +
  envelope/mic visuals · C terminology/one-transport-vocabulary · D new-effects pack incl.
  Lava Lamp · E security round 3). Round 0 shipped: **`docs/ios/master-on-device-checklist.md`**
  (THE consolidated builds-18–28 + agent-backlog test pass — start here for device QA),
  **`docs/ios/sequence-builder-design-2026-07.md`** (design-only spec, §11 open questions for
  Brian), Decision-Log D-016..D-019 status-synced (implemented; D-020 still open).
  **ROUND A SHIPPED = BUILD 29 (2026-07-17):** tour library-of-looks overlap fixed, KeyboardState
  editing-pauses-the-stage, scroll-to-dismiss + fixed AI-prompt height, form focus/keyboard
  types, 44pt tap targets class-wide (chips, mixer transport 40pt circles + repaid metrics,
  dashboard/room/swatch scatter), plus a latent same-second backup-name data-loss fix in
  CompositionStore (rollback: `checkpoint/ux-polish-A`).
  **ROUND B SHIPPED = BUILD 30 (2026-07-17):** previews everywhere — all 56 Composer cards (+
  user creations) render their REAL palette/motion at rest via the new data-driven LookPreview
  (spec/math/strip/canvas, preview-only ≤1.33Hz photosensitivity floor), engine deck cards show
  per-effect signature motion, scene cards show real recall-speed strips with TRUE bridge palette
  colors (tolerant list decode), shelf chips + automation rows get static strips, the Brightness
  Shape finally has a live waveform (EnvelopeStripView + curve chips) and mic sources a live
  level meter with threshold tick (rollback: `checkpoint/ux-polish-B`).
  **ROUND C SHIPPED = BUILD 31 (2026-07-17):** one TransportVocabulary (REST/transport jargon
  gone from every user surface — executes the deferred Phase C), the grandma copy pass
  (Warmth, Brightness Shape, ADVANCED settings, sample home, …), and a jargon regression guard
  (hardening_guards.sh Guard 6 + a vocabulary unit test) which also surfaced + fixed two
  pre-existing guard failures (stale M-03 manifest path, one H-03-class log line) (rollback:
  `checkpoint/terminology-C`).
  **ROUND D SHIPPED = BUILD 32 (2026-07-17):** the lava-lamp-class organic pack — 10 new
  built-ins (56→66): Lava Lamp, Retro Lava, Aurora Curtain, Ocean Storm, Fireflies, Candle
  Cathedral, Neon Rain, Deep Space Drift, Jellyfish, Zen Garden — all palettes are
  catalog-proven gamut-C points/convex blends, all passed the full PresetCatalogTests bar;
  BuiltInSeedMigrator delivers them to existing installs without touching user edits
  (rollback: `checkpoint/effects-D`).
  **ROUND E SHIPPED = BUILD 33 (2026-07-17) — PROGRAM COMPLETE:** hardening Round 3 — nine
  verified-open P2 findings fixed (L-01/07/08/10/24/25/26/45/46/52), the audit's Round-3
  ledger recorded (fixed-since / moot / still-open-with-reasons, audit doc §8), and the
  builds-18–28 new surfaces swept clean under existing scrub coverage (rollback:
  `checkpoint/hardening-E`). All six program rounds (0, A–E) are on `main` and pushed; device
  QA runs from `docs/ios/master-on-device-checklist.md` + each round's adds. Full program
  record in the 2026-07-17 ROUND 0 entry.
- **BUILD 28 (2026-07-15): FINAL AUDIT + WELCOME TOUR — AWAITING BRIAN'S ON-DEVICE CHECK.**
  Fifteen shippable commits (rollback tag `checkpoint/tour-audit-2026-07-15`): the audit's one
  real gap closed (35 MORE ungated Release prints — StudioViewModel 28 / CompositionStore 6 /
  watch WatchStore 1 — behind per-file `debugLog`; sweep now zero across all 4 targets), the
  **12-page replayable Welcome Tour** (auto-presents once on first arrival post-pairing/join/
  demo; guests see 9 pages; replay in More → APP; zero image assets — live StageKit/SF-Symbol
  illustrations ≤1.33Hz, Reduce-Motion stills, Dynamic Type + VoiceOver; catalog locked by 16
  `TutorialCatalogTests`), and a REAL pre-existing bug fix found by Simulator smoke: **the
  build-27 photosensitivity notice never actually appeared on fresh installs** (fired from the
  prewarm-hidden Studio tab, silently dropped by UIKit AND poisoning the next presentation —
  now gated on `\.isTabActive`). Also: orphan duplicate `HueHome/PrivacyInfo.xcprivacy` deleted
  (the ROOT file is the live manifest), stray watch entitlements deleted, copyright strings set,
  Xcode pbxproj normalization accepted. Suite 683/683 green per commit. Full entry + Brian's
  on-device checklist below (the 2026-07-15 BUILD 28 entry).
- **BUILD 27 (2026-07-11): APP-STORE-PREP RUN — READY FOR BRIAN'S ASC PASS.** Ten shippable
  commits (rollback tag `checkpoint/appstore-prep-2026-07-11`): trademark/naming fixes ("Hue
  Home" Siri alt-name removed, Lock-Screen widget label "HueHome"→"ChromaGlow"), Signify
  non-affiliation disclaimer (More + Settings footers + hosted privacy policy), one-time
  photosensitivity notice on first Studio entry (via StudioDrainWiring — body untouched),
  31 raw Composer/Handoff/Studio prints DEBUG-gated behind a `debugLog` autoclosure helper,
  the TEMP ⏱️PERF loadAll/room-open diagnostics finally removed (the `__seed` fast path kept),
  two empty placeholder appiconsets deleted, explicit `CODE_SIGN_STYLE=Automatic` on the main
  target, **1.0.0 (27)** across all 12+12 pbxproj entries + the provenance-CI assertions,
  hosted privacy/support pages reconciled (camera+location coverage added, beta wording out,
  renamed-repo links). NEW: `docs/ios/app-store-submission-runbook.md` — Brian's step-by-step
  ASC guide (age rating, privacy label = Data Not Collected, DSA trader options, metadata
  drafts, screenshot specs incl. iPad+watch, review notes + demo-video draft, risk register).
  **⚠️ False positive on record:** widget/watch Resources phases are EMPTY BY DESIGN
  (objectVersion-70 synchronized folder groups) — privacy manifests + watch AppIcon verified
  present in built Release products; do NOT add explicit Resources-phase entries (duplicate
  membership breaks the build). Suite green per commit (667/667).
- **BUILD 26 (2026-07-10): FAMILY SHARING COMPLETE — INVITE PHASES 2–4 IN ONE ROUND —
  AWAITING BRIAN'S ON-DEVICE CHECK.** Twelve shippable commits (`f3eac6b..`, rollback tag
  `checkpoint/family-sharing-2026-07-10`), implementing all of
  `docs/ios/profiles-access-share-invite-design-2026-07.md`. **Phase 2 (per-guest keys):**
  `ApplicationKeyMinter` extracted verbatim from the pairing POST (the untouched
  SecretLogScrubTests H-04 pair is the preservation proof); second envelope kind `"invite"`
  carries {bid, host, port, name, pinPK, token, allowedGroups, features, expiresAt} —
  structurally NO clientkey field; the owner mints per bridge in `GuestInviteMintSheet`
  (devicetype `chromaglow#g-<slug>-<4hex>`, `generateclientkey:false`, one link-button press,
  display-only QR — NO ShareLink — 15-min countdown, "New Code" re-encodes the STORED key);
  the guest joins with NO button press (`GuestInviteAcceptor`: expiry ±5 min grace →
  no-downgrade guard (an owned full credential is never replaced; a granted record updates in
  place = the re-scan update path) → live TOFU + `/api/0/config` cross-check → pin gate
  (verified-against, never ingested, never overwrites a differing stored pin) → token
  liveness probe (explicit type-1/401/403 = revoked-before-accept; transport failure persists
  NOTHING) → registrar dedup → grant write BEFORE addBridge/loadAll, so first paint is
  filtered). **Phase 3 (profiles + enforcement):** additive SwiftData `GuestProfile` +
  `GuestAccessGrant`; "Profiles & Access" is LIVE (More → PEOPLE): create profiles, pick
  rooms/zones per bridge (`RoomAccessPicker`), feature toggles with honest one-liners,
  Generate Invite per profile; enforcement lives at ONE choke point —
  `applyGuestAccessFilter()` prunes `roomsByBridge`/`zonesByBridge` inside the rebuilds so
  dashboard, widgets, watch, Siri entities, and deep links inherit for free (scenes have
  their own filter at `loadAllScenes`; SSE mutates existing entries only, so pruned rooms
  can't resurrect); guest shell = dashboard banner with the §5 honesty copy, Studio tab
  hidden guest-only (swipe indexes into visibleTabs), per-bridge feature gates
  (onOff/brightness+color/scene-recall; create/delete/rename/copy/move never on granted
  bridges, orchestrator backstops refuse with a toast), fail-closed zero-rooms empty state.
  **Phase 4 (revocation honesty):** the whitelist hardware spike SHIPPED as a runtime probe —
  Profiles & Access → "Keys on your bridges" → `BridgeKeysView` (`fetchWhitelist()` nil =
  firmware omits it; "Try Remove" = best-effort DELETE trusted only via verify-by-re-read;
  H-03 masking added for whitelist elements incl. the PRE-EXISTING raw-path pre-logs in
  HueV1Client's four verbs); owner "Revoke Access" = best-effort bridge delete + ALWAYS the
  local key wipe + `revokedAt` (mint sheet refuses revoked specs); guest-side cooperative
  wipe fires ONLY on an explicit 401/403 over pinned TLS (L-30 — 0/404/408/429/5xx/timeouts
  pinned as never-wipe by test), owned bridges get re-pair advice, never an auto-wipe. Also:
  KeychainManagerTests no longer leaks the legacy keychain slots (pre-existing cross-test
  pollution surfaced by clone redistribution). Full suite green per commit (667 tests; two
  consecutive green runs at the end). On-device checklist in the 2026-07-10 BUILD 26 entry
  below.
- **BUILD 25 (2026-07-10): WIDGET-SCENES FIX, AUDIT FIXES, WATCH SCENES FACE, SHARE INVITE
  PHASE 1 — AWAITING BRIAN'S ON-DEVICE CHECK.** Twelve shippable commits (`d5f0ade..`,
  rollback tag `checkpoint/scenes-stop-invite-2026-07-10`), from the full builds-18–24
  audit + the "scenes vanished from widgets" report. **The headline bug:** on every launch
  `scheduleWidgetWrite` published `globalScenes == []` (scenes load lazily AFTER the
  publish) and clobbered the stored snapshot — blanking the phone widget scene strip, the
  Control Center scene control, the watch app's scene rows, and Siri scene donations;
  scene mutations never republished either. Fixed with a preserve-until-first-load rule
  (`scenesForPublish`), republish from `loadAllScenes` + delete/rename, and a detached
  one-time scene fetch after `loadAll` (cold-start path untouched). **Audit fixes:** Siri
  "stop the lights" now actually leaves lights ON (`requestNowPlayingStop(roomID:turnOffLights:)`
  — Dashboard Stop keeps its off); stopping one room's strobe no longer tears down every
  room's composition + the whole Now-Playing bar (`stopAppDrivenStudioEffect`, room-scoped);
  removeBridge/deleteRoom/deleteZone stop running effects first (+ removeBridge finally
  clears zones — stale zones lingered forever after removing the last bridge); moving a
  scene carries its ★ favorite + usage history (and undo carries them back); Siri whole-home
  fan-outs dedupe zones-vs-rooms and pace per bridge (150ms gaps); SSE color-only updates
  invalidate stale mirek (Copy Color no longer grabs warm white after an outside-app color
  change); StudioView's Siri-drain wiring extracted off the type-checker-ceiling body;
  welcome-home single-sourced in `LightingPreset`. **NEW: watch face scenes widget**
  ("ChromaGlow Scenes", second kind — display-only, tap deep-links the watch app to the
  room via `lightshade://group/{id}`). **NEW: Share Invite Phase 1** (More → Share Invite is
  live): a ZERO-SECRET "home-join" QR — carries bridge identity + expected TLS pin, never a
  key; guest scans (or taps the link), presses the link button once, pairs through the
  existing audited flow with a new `expectedIdentity` refusal check (QR pins are
  verified-against, never ingested). Onboarding gains "Join a Shared Home". Full design for
  Phases 2–4 (per-guest keys, profiles, revocation honesty):
  `docs/ios/profiles-access-share-invite-design-2026-07.md`. Full suite green per commit
  (two consecutive runs at end). On-device checklist in the 2026-07-10 BUILD 25 entry below.
- **BUILD 24 (2026-07-10): COPY/PASTE COLOR + FULL SIRI INTEGRATION — AWAITING BRIAN'S
  ON-DEVICE CHECK.** Thirteen shippable commits (rollback tag
  `checkpoint/copycolor-siri-2026-07-09`). **Light cards:** long-press → context menu (Copy
  Color / Paste Color / Save to My Colors / Identify / Select Lights); copy arms a **sticky
  paint mode** (tap lights to paste, "Painting · Done" pill in the LIGHTS header; My Colors
  swatch arming is sticky now too); the clipboard (`ColorClipboard`) is app-wide, so menu
  Paste works across rooms; CT-mode copies mirek (bridge nulls mirek in color mode — that's
  the mode signal), dimmable-only lights hide Copy/Save. **Siri:** discovered
  `HueHome/Intents/` was NEVER in any target — the app shipped ZERO working Siri commands;
  registered + rewrote it (two latent bugs: Bool-bound "turn off" phrases would turn lights
  ON; rooms-only entities). Now 10 App Shortcuts: on/off (rooms AND zones, Room/Zone
  disambiguation), brightness, 22 named colors + 5 whites (gamut-C-safe via the Composer's
  pipeline), scene recall, Energize/Read/Relax/Sleep (room-scoped or home), all lights
  on ("welcome home" 80%/mirek 350)/off, **open-app "Start ⟨composition⟩/⟨effect⟩ in
  ⟨room⟩"** (pendingStudioAction handoff → StudioView drains through vm.apply, cold-launch
  retries via one task(id:)), and a hybrid "stop the lights" (registry-routed in-app stop +
  background no_effect fan-out). Donation freshness hooks in scheduleWidgetWrite +
  CompositionStore.onPersist; INAlternativeAppNames. All phrases require "in ChromaGlow" —
  bare "turn on kitchen" routes to HomeKit by design. Full checklist in the 2026-07-10
  BUILD 24 entry below. Full suite green (two consecutive runs).
- **BUILD 23 (2026-07-09): ENGINE COHERENCE RUN 1 — NOW-PLAYING BAR REVIVED, PERFORM LISTENS,
  PUNCH UNIFIED, PER-ROOM TRANSPORT TRUTH — AWAITING BRIAN'S ON-DEVICE CHECK.** Eight shippable
  commits (rollback tag `checkpoint/coherence-run1-2026-07-09`), from the Studio/DJ/live-FX
  coherence deep-dive: the Dashboard **Now-Playing bar renders for the first time** (Studio now
  feeds the orchestrator's shared registry — `addActiveEffect` had ZERO callers — and Stop
  routes through Studio's own teardown instead of a bare grouped-light PUT that left the loop
  running); **opening Perform actually starts mic capture** (`AudioDemand.performance` was
  declared but never set — the beat panel said "Listening…" over a dead mic; deck-B cues raise
  demand too); **Tap-Dial pads = on-screen pads** while Perform is open (same room/semantics/
  3 Hz clamp, release-on-lift), and the REST STROBE burst alternates (was white→white); **per-
  room transport truth** (`compositionTransportByRoom` replaces the global `isBridgeStored` +
  Perform's snapshotted `isStreaming` — badges flip live on DTLS→REST failover, no wrong-room
  "BRIDGE" labels); the **mixer tray edits the room on screen** (per-room param boxes; stopping
  one room no longer clears another's editor); **bridge-optimized one-shots** drop the dead
  editor/Revert/Save/Perform buttons for an honest notice, and SequencePlayer bounds its fade
  wait (no more forever-hang when no render loop consumes the mix); unmapped Tap-Dial buttons
  no-op (no more phantom tap-tempo); the iOS **"Dim Flashing Lights" strobe cap works** (was
  hardcoded `false`); coverage badges clear on room switch. Full checklist in the 2026-07-09
  BUILD 23 entry below. Full suite green per commit.
- **BUILD 22 (2026-07-09): STUDIO ROUND 2 — AUDIT FIXES, ROOM-SCOPED PRESETS, CHROMAGLOW RENAME,
  CATEGORIES, PARITY, ROOM COLOR POPUP, CROSS-SURFACING — AWAITING BRIAN'S ON-DEVICE CHECK.**
  Nine shippable commits (rollback tag `checkpoint/studio-round2-2026-07-09`): renamed-built-in
  delete bug fixed (reset now keys on id), unsupported effects restore a dark room, one brand
  (ChromaGlow) on watch/widget/Siri surfaces, Energize/Read/Relax/Sleep scope to the room you're
  in (iOS RoomDetail row NEW, watch room detail fixed, room-pinned widget face), Composer deck
  category sections + category on save, tap-to-type on every slider, engine cards get the
  hue/sat pad + My Colors, thunderstorm's six hidden tunables became params (both engine paths),
  long-press a room card → color wheel + harmony popup, and Composer creations now surface on
  the deck (or Scenes shelf) matching what they are. Full checklist in the 2026-07-09 BUILD 22
  entry below. Full suite green.
- **BUILD 21 (2026-07-09): SCENES EXCELLENCE — QR SHARING, 56 BUILT-INS, ENGINE HONESTY —
  AWAITING BRIAN'S ON-DEVICE CHECK.** Eight shippable commits (rollback tag
  `checkpoint/scenes-excellence-2026-07-09`): three-row mixer-tray header (no more mid-word
  wrapping), rolodex compacted 194pt → ~134pt, **QR/link scene sharing** (`lightshade://share`,
  no backend), transport menu now refuses what the bridge can't do, bridge-native dynamic-scene
  export promoted to a first-class engine **and fixed** (spectrum/temperature exported the wrong
  colours), six built-in scenes had out-of-gamut stops, **+36 new built-ins across five new
  categories (20 → 56)**, `BuiltInSeedMigrator` so new presets reach existing installs, and a
  firmware effect that no light can run no longer reports success. Full checklist in the
  2026-07-09 BUILD 21 entry below. Full suite green (two consecutive runs).
- **BUILD 20 (2026-07-09): ADJUSTMENT-SETTINGS REVAMP + LIVE-UPDATE FIXES — AWAITING BRIAN'S
  ON-DEVICE CHECK.** Twelve shippable commits (rollback `checkpoint/pre-adjustrevamp-2026-07-09`):
  DJ-stage mixer tray (flat surface, Perform header grammar, derived heights), composer
  progressive disclosure per COMPOSER_SPEC (essentials inline, `ComposerLayerSheet` advanced,
  drag-up = all inline), param truth pass (dead thunderstorm Brightness / party+prism Saturation /
  ambient Color removed; Kelvin/Hz readouts; transition→chips), gap fixes (composer Warmth /
  Smoothing / spectrum Saturation sliders), engine upgrades (candle/fire/sparkle speed — VERIFY
  FIRMWARE HONORS IT; per-light warmth via `EffectsV2Body(mirek:)`; party Flash Color tint),
  per-card last-used persistence (`StudioParamStore`) + Reset/Revert, save-sheet accent colors,
  **room/zone master-bar live fix** (`RoomAggregate` + grouped_light SSE consumption + echo
  guard), **scene ACTIVE badges live via scene SSE**, Scenes grid↔full-bar toolbar toggle.
  Full checklist in the 2026-07-09 BUILD 20 entry below. Full suite green.
- **BUILD 19 (2026-07-09): SCENES OVERHAUL — AWAITING BRIAN'S ON-DEVICE CHECK.** Seven
  shippable commits (same rollback tag as build 18): grouped-by-room collapsible Scenes tab
  with ★ Favorites shelf + sort menu (Group by Room / A–Z / Recently Used / Most Used, backed
  by new `SceneUsageStore`); **saved color palette** ("My Colors" — capture in LightControl or
  the scene builder, tap-to-apply OR drag a swatch onto any light card in RoomDetail, with
  per-capability fallback); **scene copy/move between rooms** (context menu "Copy/Move to
  Room…" AND drag a scene card onto a room section/chip → `CopySceneSheet` with live remap
  preview + 5s undo toast; pure `SceneCopyEngine`, cross-bridge capable). Also fixed: zone
  scenes displayed as "Other" (name lookup skipped zones). On-device checklist in the
  2026-07-09 Scenes entry below. Cross-bridge copy needs Brian's two-bridge check.
  Feature roadmap (R1–R4 + differentiators): `docs/ios/feature-roadmap-2026-07.md`.
- **BUILD 18 (2026-07-09): card-parity + Composer live-update bug fixes — AWAITING BRIAN'S
  ON-DEVICE CHECK.** Five shippable fixes (rollback `checkpoint/pre-scenesrun-2026-07-09` @
  `72669f1`): ① Composer layers panel updates live (`CompositionParamBox` is now `@Observable`;
  runtime fields `@ObservationIgnored` — LOAD-BEARING, see the 2026-07-09 entry); ② dashboard
  room/zone cards trust member lights when `grouped_light` lags (builder cross-check, mirrors
  RoomDetail's); ③ SSE light-on events flip room/zone cards on (ON-direction only); ④ SSE keeps
  `lightsByBridge` live so RoomDetail's <30s instant-render seed is always truthful; ⑤ light-event
  bus token guard (rapid room A→B switch no longer kills room B's SSE updates). On-device
  checklist in the 2026-07-09 entry below.
- **BUILD 17 (2026-07-08):** added an **All Lights** master-switch Control (one Lock Screen corner
  slot, on ↔ off). Turning on applies a "welcome home" 80% / mirek 350, not a bare `on: true`.
- **BUILD 16 (2026-07-08):** iPhone Lock Screen *widgets* are status-only — taps always open the
  app; the interactive surface is a **Control** in the bottom corners. Fixed the accessory gauge
  never drawing its icon (`.accessoryCircularCapacity` ignores a Gauge's `label`), removed
  accessory buttons that could never fire, and wired the widget deep link so a tap opens the
  **tapped room**, not just the dashboard (`pendingGroupID` had zero readers).
- **BUILD 15 (2026-07-08):** widget audit. iOS 18 Control Center / Lock Screen **Controls**
  (room toggle, scene, preset, all-off) — the real fix for "the Lock Screen widget doesn't
  work", since accessory-widget taps fall through to launching the app. Plus enlarged Home
  Screen tap targets, interactive unpinned accessory widgets, watch brightness at 10%/tap with
  press-and-hold ramp, and a **latest-wins mailbox** that stops the watch flooding the bridge
  (~99 PUTs per Crown sweep). Awaiting device verification. See the build-15 entry below.
- **BUILD 14 (2026-07-08):** fixed the DJ Perform surface presenting a black full-screen page on
  first open (`.fullScreenCover(isPresented:)` + `if let performVM` → `item:`). Awaiting Brian's
  on-device confirmation. See the build-14 entry below.
- Everything below is MERGED TO MAIN and full-suite green:
  1. **2026-07 hardening P0+P1 audit remediation COMPLETE** — per-bundle privacy manifests (M-03),
     secret log scrub (H-03/H-04/L-09, `SecretLogScrubTests`), bridge TLS pinning (D-016,
     `Trust/BridgePinnedTrustDelegate` + `BridgePinStore`), shared Keychain access group (D-018,
     M-02/L-30), per-bridge client routing sweep (M-07/H-05/M-18), RestSender mailbox routing
     (M-08/M-14/M-15), DTLS failover (M-09/M-10), non-destructive composition persistence (M-13),
     M-04/M-05/M-06/M-11/M-12/M-16/M-17, mic-permission/interruption fixes (L-19..L-23), and more.
  2. **Rounds 3–4** — DJ Perform surface, step sequencer, Stage redesign (`StageKit`), Composer
     extraction (`CompositionEditorPanel`, `MixerTrayView`), Effects port to Studio Deck 0,
     deletion of the dead Effects/Sync tab surfaces.
  3. **Warm-app perf pass** (9 commits, `b454095..2d4f739`) — RoomDetail instant render from the
     loadAll cache, CompositionStore off-main load, SSE rebuild coalescing (~150ms), composition
     self-echo guard, `\.isTabActive` env key pausing hidden-tab animation clocks, beat/dashboard
     timer gating, per-host TLS pin acquisition, deferred entertainment cleanup, mic-demand cache.
  4. **Fresh-install perf pass** (8 commits, `36d8f20..e2108fe`, build 9) — cached App Group
     UserDefaults, dead discovery Keychain writes removed, WCSession off App.init, 0.7s splash for
     unpaired, Studio coverage from cache, RoomDetail skip-refetch when seeded fresh, first-launch
     seed written off-main (create-only), prewarm gated on loadAll settling + one tab per pass.
  5. **AVAudioEngine tap crash fix + CoreData store-dir noise fix** (`bc5b2ba`) — on-device repro
     still unconfirmed (route-dependent, not reproducible in Simulator).
  6. **Diagnostics build + Swift 6 zero-warning pass** (16 commits, `0f329b5..a447953`, build 10)
     — live startup timeline (`StartupTimeline`, `⏱️TL` marks across the whole cold-start path),
     `MainThreadWatchdog` (🧵HANG lines labeling every main-thread stall >250ms with its phase),
     🌐 per-request log in `HueAPIClient.execute`, NUPnP 10s timeout (was 60s default),
     bounded mDNS resolve, and the full Swift 6 concurrency-warning cleanup
     (clean build = 0 errors / 0 warnings across app+widget+watch). The old `⏱️PERF` prints were
     CONVERTED to `StartupTimeline` marks, not removed.
- **BUILD-12 DEVICE RESULT (2026-07-07) — THE STACKS NAMED THE BLOCKERS:** the 22.7s monster
  is `swift_conformsToProtocol2` scanning conformance tables during SwiftUI construction of
  BridgeSetup{View,Content} — every stack bottoms at `__debug_main_executable_dylib_entry_point`
  (Xcode 16+ **debug-dylib** execution; a debug-tethered tax that grew with app size, not a
  regression). Plus ~4.7s CoreGraphics rasterization (the setup screen's 60pt `.blur` glow),
  ~1.3s TextInput `_sl_dlopen`, ~1.8s NSClassFromString/UIAccessibility (platform/first-launch
  tax). Nothing in builds 10–12 made it slower — diagnostics made existing cost visible.
- **BUILD-13 DEVICE RESULT (2026-07-07) — MYSTERY SOLVED:** debug dylib confirmed gone
  (stacks bottom at `HueHome main`); the conformance-scan signature shrank to one sample.
  Remaining tethered hangs are **Xcode-attach machinery**: `libBacktraceRecording.dylib
  gcd_queue_item_dequeue_hook` (scheme queue-debugging — now disabled in the shared scheme),
  `libAXSafeCategoryBundle class_replaceMethodsBulk` (debug accessibility swizzling), plus
  one-time first-launch system work (FontParser glyph paths, vImage/CG color-space caches,
  CFPreferences, TextInput dlopen). **Brian's untethered relaunch: "definitely faster."**
- **IMMEDIATE NEXT STEP:** Brian pushes a TestFlight (Release) build and evaluates the real
  ship experience — expect seconds of one-time first-launch work, not the tethered minute.
  NOTE: the ⏱️TL/🧵HANG diagnostics are DEBUG-only and won't print on TestFlight (by design).
  If TestFlight still feels slow anywhere, tell Claude WHERE (which screen/action) — the
  debug-build sampler can then be pointed at that exact flow. Once TestFlight is confirmed
  smooth, the diagnostics trim to essentials in a cleanup commit.
- **BUILD-11 DEVICE RESULT (2026-07-07):** stacks were captured but Brian's console filter hid
  the frame lines (tooling bug, fixed in 12). Hard findings anyway: `discovery.vm-init.done`
  fired 6+ times (VM churn — `@State` initial value re-evaluated per parent re-render, fixed
  in 12); NUPnP `/api/nupnp` is a hard 404 (endpoint retired — fixed in 12 to site root);
  first tab-switch hang now ~981ms (below old first sample offset); the 18.4s monster is
  bracketed to AFTER `setup.appear`. "Booted back to discovery" = most likely delayed taps on
  a frozen UI hitting "Pair Another Bridge" (gesture-gate timeouts prove input lag).
- **BUILD-10 DEVICE RESULT (2026-07-07):** the timeline WORKED and ruled out the network — the
  minute is **pure main-thread blockage**: after `splash.route → setup`, `🧵HANG` chunks of
  3.6s / **18.5s** / 4.6s / 3.8s / 2.8s (~35s total) with ZERO `discovery.*` marks and ZERO 🌐
  lines (the scan is button-triggered and never started). Studio first-swipe lag = same pattern
  (`🧵HANG ~1997ms (phase: prewarm.more)` + gesture-gate timeout). Secondary, Xcode-inflated:
  +9.5s pre-main/debugger attach, `didFinishLaunching Δ2478ms`, `first-frame Δ1175ms`.
- **IMMEDIATE NEXT STEP:** Brian installs **build 12** (fresh install: delete app first), runs
  from Xcode, console filter `⏱️TL|🧵HANG|🌐` (any filter matching the header now keeps the
  whole stack — it's ONE multi-line entry). Expect: `discovery.vm-init.done` exactly once,
  visible `🧵HANG-STACK` frames naming the remaining blocker(s) (samples at ~0.65/2.2/6.2/14.2s
  into each hang), setup screen meaningfully less janky (VM churn eliminated). The named
  function becomes the next targeted fix. Diagnostics stay in until cold start is smooth.
- **Open device issue:** Brian reported intermittent crashes launching from Xcode on builds ≤8.
  Likely the audio-route crash `bc5b2ba` targets. If build 10 crashes on device: get the crash log
  (Xcode → Window → Devices and Simulators → View Device Logs) before changing anything.
- **Deferred iOS work (explicit decisions, do not resurrect without need):** async/two-phase
  ModelContainer (fresh-store creation on main in App.init, ~1-2s once per install — wide
  regression surface vs one-time cost); dead Sync-engine stack deletion (`SyncModeEngine`/
  `VisualizerEngine`/`GamingEngine`/`AmbientEngine` are never instantiated, but the live
  `RestSender` actor is defined inside `SyncModeEngine.swift` and must be extracted first, plus
  pbxproj edits); CompositionEngine.render off main-actor (measured cheap; mutates MainActor-
  confined `CompositionParamBox`, audit I-10); MoreView connectionStatus re-render trimming;
  `run_tests.sh` still has stale `SCHEME="HueHome"` — always pass `-scheme "HueHome 1"` manually.
- **Rollback tags (all pushed):** `checkpoint/pre-diagnostics-2026-07-07` @ `6b5c6ba`,
  `checkpoint/pre-freshfix-2026-07-08` @ `245dd5f`,
  `checkpoint/pre-perf-2026-07-06` @ `c01b814`, plus earlier round checkpoints.
- Working conventions Brian expects: create a rollback tag before any multi-commit run; keep
  `main` as the branch he builds from; bump `CURRENT_PROJECT_VERSION` (all 12 pbxproj entries)
  every device-test round so stale binaries are detectable; one independently shippable commit
  per fix; validate with
  `xcodebuild test -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.

### Android — unchanged since 2026-07-01
- Kotlin/Compose demo MVP on `main` (originally landed @ `f3380a7`): Setup (mDNS/manual-IP/demo),
  Dashboard, RoomDetail, Scenes, Settings; Android Keystore credential boundary; tested non-UI Hue
  pairing foundations under `core/hue/pairing/**` + bundled CA roots (Batch 3, incl. D-014).
  Full inventory + durable contracts: `AGENTS.md` → "Android Current State".
- Batch 4 live pairing onboarding is executed/integrated on `integration/parallel-batch-4` @
  `040fed7` (automated gate green; physical H0 link-button gate pending re-run with the correct
  worktree APK — see the 2026-07-01 stale-APK diagnosis below); **not yet merged to `main`**.
- Parallel pipeline docs (lane registry, Decision Log): `docs/coordination/parallel-agent-pipeline.md`.

### Audit
- 2026-07-01 cross-platform hardening audit: `docs/audit/hardening-audit-2026-07-01.md`
  (0 Critical / 5 High / 19 Medium / 55 Low). **iOS P0+P1 remediation is COMPLETE and on `main`**
  (see iOS section above). Remaining audit follow-ups are Android-side (M-19 canonical tree/CI)
  and the deferred items listed above.

### Handoff Entry Template

```markdown
## YYYY-MM-DD - [Codex|Claude|Cursor] Short title

### Branch
- `branch-name`

### Did
- ...

### Working
- ...

### Left
- ...

### Validation
- ...

### Gotchas
- ...
```

---

## 2026-08-03 - [Claude] Composer 2 / Phase 0 / Packet 7 — third-party Entertainment consent

### Branch
- `fix/third-party-entertainment-consent`, cut from `main` (`446fd49`, the Packet 6 merge, PR #56).
- Worktree: `~/Desktop/chromaglow-p7`.
- Rollback tag: `checkpoint/pre-composer-packet-7` (at `446fd49`).
- **No source file added, no `project.pbxproj` change, no version or build bump.** Two commits.
  PR opened, not merged.
- One new persisted key is written (`castchroma.entertainmentOwnership.v1`, non-secret), so a
  rollback should also clear it — see "Persisted ownership" below.

### The defect (review decision K1, risk N4)
`deactivateStuckEntertainmentSessions` treated **every** active Entertainment configuration
that this process had not registered as "stuck" and sent `action=stop`. That pass runs from
`loadAll` → `scheduleEntertainmentCleanup` on launch, on every foreground, and on every state
refresh. A Hue Sync Box, another Hue app, or any other controller streaming on the bridge was
therefore silently evicted although the ChromaGlow user had not asked for playback at all —
the most direct kind of trust failure the app can commit, and an App Store liability.

### Why the process-only refcount could not fix it
`HueEntertainmentClient` kept ownership in a static `[configID: Int]` guarded by a lock. Two
independent things were missing, and neither could be added to that shape:

1. **No bridge identity.** The key was the configuration UUID alone. A configuration recorded
   while streaming on bridge A authorized stopping the same UUID on bridge B — a different
   session entirely, quite possibly a stranger's.
2. **No survival.** A refcount dies with the process. After a force-quit mid-show the bridge
   still reported *our* configuration active, with nothing left to say it was ours. The
   cleanup pass could not distinguish that from a third party's session, so it had to choose
   between evicting strangers (what it did) and leaking its own sessions forever.

### Persisted ownership
`EntertainmentSessionOwnership` (in `HueEntertainmentClient.swift`, no new file) holds two
layers, both keyed by **exact bridge + configuration**:

- **A — current process:** reference-counted. Two ChromaGlow clients can legitimately hold the
  same bridge + configuration (a Studio card and a composition).
- **B — persisted:** `{bridgeID, configID, startedAt}` as JSON under
  `castchroma.entertainmentOwnership.v1`, injectable `UserDefaults`, load-in-init, `try?`-tolerant,
  bounded to 32 records (oldest dropped). **No token, client key, username, IP, or light data.**

Lifecycle:

| Event | Process | Persisted |
| --- | --- | --- |
| `startSession`, before `action=start` | register | record |
| activation refused by the bridge (typed `HueAPIError`) | release | forget (final owner only) |
| activation failed at transport (outcome unknown) | release | **keep** — a later launch retries |
| DTLS open failed | release | compensating stop; forget only if that stop succeeded |
| `stopSession` / terminal failure, final owner | release | forget only on a confirmed stop |
| `stopSession`, **not** the final owner | release | **keep** — another live client needs it |
| automatic cleanup stopped a stale session | — | forget only on a confirmed stop |
| bridge proves the configuration inactive/absent | — | prune, no stop sent |

**Final-owner stop semantics.** `releaseProcess` returns `(wasFinalOwner, remaining)` and only
the final owner sends `action=stop`. An earlier release that stopped the session would black
out a stream whose owner still believed it was running — including as a failed-open "rollback",
which is how a second client's DTLS failure could have killed the first client's live show.
Failure classification is by **type**, never by error text.

**Cleanup takes a claim, not a reading.** A bridge read suspends, so a start can complete
between the classifying read and the stop that read authorized. Re-asking "still recorded?" and
"no owner yet?" as two separate questions and *then* awaiting a PUT is not an authorization
either — it is two facts that were briefly true with a suspension in between.
`beginStaleCleanup(bridgeID:configID:)` verifies both under one lock and returns an exclusive
claim; while it is held, `registerProcess` for that exact key returns `.blockedByCleanup` and
`startSession` refuses rather than racing the stop. The claim is released whether the stop
succeeds or fails, and the lock is never held across an await. Other bridges and other
configurations are unaffected.

### Automatic cleanup vs. explicit takeover — the distinction that matters
These are now completely different code paths with different rights:

- **Automatic cleanup** (`deactivateStuckEntertainmentSessions`, unattended, from `loadAll`)
  builds an `EntertainmentActivitySnapshot` per bridge partitioning every active configuration
  into `processOwned` / `persistedOwned` / `foreign`. It skips process-owned, best-effort stops
  each persisted stale id **independently** (one failure does not skip the next), and leaves
  foreign entries completely untouched — no stop, no prompt, and not even a "stuck" warning,
  because they are not stuck. An unreadable bridge keeps all its records and never affects
  another bridge's classification.
- **Explicit takeover** is the only path that ever stops a third party, and only after the user
  says so.

### Explicit user takeover
`tryStartEntertainment` no longer returns `HueEntertainmentClient?`. An optional could not tell
"streaming is impossible here, use room mode" apart from "another controller owns this bridge",
so a foreign conflict silently became a REST fallback — which plays over the other app's show,
just more quietly. It now returns `.started` / `.needsForeignConsent` / `.unavailable` / `.failed`,
and **no path starts a fallback while a foreign conflict is unresolved**.

Playback now starts as a **prepare / start / commit** transaction. `prepareEntertainment`
resolves the plan, runs the choke-point foreign check, and opens the session — returning a
`PreparedEntertainment` candidate that is deliberately **not** installed into `studioEntClients`.
Only after that succeeds does a caller cancel the old task, stop the old client, clear scopes,
advance the composition generation, open telemetry, move microphone demand, rewrite spatial
data, or publish a running effect. `startStudioMode`'s room guard was hoisted above its teardown
too, so an unresolvable room no longer stops the previous look and then fails.

The consequence is the one that matters: a third party claiming the bridge between the
ViewModel's preflight and the acquisition surfaces as a **question**, with the previous look
still playing and every piece of bookkeeping untouched — and never as a quiet REST fallback,
which would play over the other app's show instead of asking about it.

**Refusals come first, and the transaction rolls back.** Preparing opens a REAL session: live on
the bridge, process-owned *and* persisted. A refusal that happened after preparing therefore
left a session nothing pointed at — and because it looked owned, the app's own cleanup would
skip it forever. Strobe under Reduce Motion was exactly that: it refused inside the `.appDriven`
branch, well below the preflight, the prepare, and `stopEffect`. The refusal moved to the top of
`apply`, above every mutation. Beyond it, a candidate is now either committed exactly once or
stopped: `commitEntertainment` is what marks it no longer outstanding, and a `defer`-driven
`rollbackUncommittedEntertainment()` in `apply`, `startStudioMode`, and `startCompositionMode`
stops anything that never got there — a defer rather than a return-by-return audit, because
enumerating today's early exits would not protect the next one added.

Candidate ownership is **transaction-scoped**. `apply` and both start paths are `@MainActor`
async and suspend on every bridge read, which makes them reentrant: a second tap prepares while
the first is still parked. A single "currently pending" slot let the second candidate overwrite
the first, after which the first transaction's commit cleared the second's entry — leaving a
live session with nothing tracking it, which cleanup then skipped forever because it looked
owned. Every `PreparedEntertainment` now carries its own id, the registry is keyed by that id,
`commitEntertainment` removes and installs only that candidate, and
`rollbackUncommittedEntertainment(candidateID:)` claims by removal so it is exactly-once and
inert against a candidate that was already committed or rolled back. Each `defer` names the
candidate its own transaction prepared.

`foreignTakeoverPreflight` returns a **typed** result — `notRequested` / `noStreamableArea` /
`clear` / `conflict` / `ambiguous` / `unreadable`. The first version answered with an optional,
which collapsed "nowhere to stream", "bridge is free", "several controllers at once", and "we
could not read the bridge" into one `nil`; `apply` then treated the honest failures as
permission to continue and tore down whatever was playing. Ambiguous and unreadable now stop
with an honest status and **preserve any effect already running**.

The preflight resolves the target through the **production selection**
(`warmEntertainmentCaches` + `entertainmentStartPlan`) and freezes it whole as an
`EntertainmentTakeoverPlan`: bridge, room, target configuration, the **ordered validated channel
ids**, and every channel's **members and position**. Ids alone would let the same area drive
different lights, or drive them in a different place in the room — invisible to an id
comparison, very visible on the wall. Confirmation revalidates every one of those fields
**before** sending any stop and refuses without touching anything if it no longer holds.

After consent the frozen plan is authoritative: it is passed intact into
`prepareEntertainment` / `startStudioMode` / `startCompositionMode`, never reduced to a
configuration id. The captured configuration is rebuilt for `startSession` and for the render
loop, so a cache refresh or a re-ordered configuration arriving between the stop and the replay
cannot redirect the stream or silently drop it to room mode. A room with no safely matching
streamable area never prompts — it was heading for room mode regardless.

Consent is a single-use token bound to `{requestID, bridgeID, targetConfigID, foreignConfigID}`.
**One owner resolves the takeover:** `confirmForeignTakeover` re-reads the bridge and performs
the exact stop, then the choke point accepts the token only when the foreign set is now empty —
the one state that can follow a resolved takeover, whether we stopped the session or it had
already ended. The two layers can never both stop it. The token is spent when the start actually
succeeds.

### Exact user-visible behavior
- Launch / foreground / pull-to-refresh with another app streaming: **nothing happens**. The
  other show continues; no prompt.
- Explicitly starting a streaming look on that bridge: an alert,
  **"Another app was controlling these lights — take over?"** with **Keep Existing** / **Take Over**.
- **Keep Existing** (or swipe-away): zero network writes, the other app keeps playing, the
  requested look does not start.
- **Take Over**: the consented session is stopped first, then the requested look starts.
- Foreign session already ended: starts with no redundant stop.
- A *different* controller appeared while the prompt was open: nothing is stopped and a fresh
  question is asked with a new identity.
- Two or more foreign sessions, or an unreadable bridge: fail closed, stop nothing, say so.
- Stop failed: "Couldn't take over these lights. The other app is still in control." — and
  ChromaGlow does not start. Success is never claimed before playback actually begins.
- Copy carries no REST/DTLS/API/configuration-id/registry vocabulary, and never names the other
  app: the bridge does not tell us who it is, so any name would be a guess.

### Tests
All deterministic — recorded PUTs, ordering, and registry state; no `Task.sleep`, `XCTWaiter`,
`wait(for:)`, or elapsed-time assertion anywhere. Isolated `UserDefaults` suites throughout.

- `HueHomeTests/EntertainmentRobustnessTests.swift` — new `EntertainmentOwnershipTests`:
  P7-01…P7-14, P7-26, final-owner semantics P7-29…P7-32, independent-stale-handling P7-38, and
  and the cleanup-claim set P7-39/39b/39c/39d and P7-40/40b — the gate opens INSIDE the stop
  PUT, i.e. while the claim is actually held, which is the only window in which the race can
  happen.
- `HueHomeTests/MultiBridgeRoutingTests.swift` — new packet-7 section: P7-15…P7-25, P7-27,
  P7-33 (no streamable area → no prompt), P7-34 (one selection start to finish),
  P7-36 (token single-use + bridge/target binding), P7-37 (multiple foreign → fail closed),
  P7-35 (a foreign owner arriving after the preflight destroys nothing and does not fall back
  to REST), P7-41 / P7-42 (ambiguous and unreadable preserve an already-running effect),
  P7-43 (cancel after a late prompt is zero mutation), and the frozen-plan set P7-44…P7-47
  (target deleted / no longer matching the room / channels unusable → stop nothing; the happy
  path streams exactly the captured area and channel map).
  P7-48 / P7-49 (a foreign owner arriving after a COMPLETED preflight leaves app-driven Studio
  and composition bookkeeping — generation, telemetry, transport, ownership, Now-Playing —
  entirely untouched, raises the prompt once, starts no REST fallback, and cancel leaves the
  prior effect running), and the frozen-plan fidelity set P7-50…P7-53 (changed positions or
  members refuse the takeover; a post-stop refresh cannot redirect the replay; order, positions,
  and members all reach the render loop), plus the rollback set P7-54…P7-56 (a Strobe refused
  for Reduce Motion sends no entertainment action at all, installs no client, creates no
  ownership, and leaves the running effect and Now Playing untouched; an abandoned candidate is
  stopped and balances both ownership layers; a committed candidate is never stopped by the
  rollback), and the interleaving set P7-57…P7-59 (committing one transaction leaves another's
  candidate outstanding and unstopped; the inverse ordering; and rollback is exactly-once and
  inert after commit). P7-54 and P7-57 were each verified to FAIL against the defect they guard
  before the fix landed.
  The spy models a real bridge deactivating a configuration when `action=stop` lands, rather
  than staging the post-stop state by hand at a guessed point in the read sequence, and a
  read COUNTER arms the late-conflict gate — "the next read" is only well-defined if you
  already know the read sequence, and it fires inside the preflight rather than after it.
- P7-28: the packet-6 All-Day sections are unchanged and re-run green.
- `Scripts/hardening_guards.sh` Guard 9: bans the configID-only registry symbols in the two
  ownership files, bans protocol jargon in user-facing strings in the two Studio UI files
  (diagnostics excluded), and bans timing waits in the ownership tests.

Suite, xcresulttool-verified on iPhone 17 Pro:
- after commit 1 — **1133 passed, 0 failed, 0 skipped**
- after commit 2 — **1172 passed, 0 failed, 0 skipped**
- `Scripts/hardening_guards.sh`: all guards passed, both commits.

### Limitations and non-goals
- **Not** the full `BridgeSessionArbiter` — this is a surgical Phase 0 fix. Studio-vs-Composer
  ownership still lives in `compositionEntRoomByBridge` / `studioEntClients`, unchanged.
- No SSE-based external-owner arbitration: a third party taking over *mid-stream* is still not
  detected. Only start-time conflicts are covered.
- No third-party application identification — the bridge exposes no trustworthy name, so the
  copy says "another app".
- Packet 8 (launch-time bridge-stored manifest reconciliation) is untouched.
- The persisted registry is per-install and local; nothing is synced.
- The consent prompt presents only in `StudioView`. Every production start path routes through
  `StudioViewModel.apply` (verified by grep: `HueHome/Intents/`, widgets, watch, and automations
  never reach `startStudioMode`/`startCompositionMode`), and any future non-interactive caller
  receives `.needsForeignConsent` and must refuse honestly rather than treating its own
  invocation as consent.
- `foreignTakeoverPreflight` costs one extra `entertainment_configuration` GET per explicit
  streaming start. That is the "re-check immediately before takeover" requirement, accepted.

### Gotchas
- `warmEntertainmentCaches` refuses to run for a bridge with no Keychain client key, so any test
  exercising area selection must save credentials first (a non-hex key is enough — `decodePSK`
  refuses before a socket exists).
- A ChromaGlow start whose DTLS open fails sends its own compensating stop for its own area
  (L-11). Assertions about "what did the takeover stop" must filter to the consented id.
- `EntertainmentConsentCopy` is the single home for the takeover words; the alert references it
  rather than duplicating the strings, and Guard 9 plus P7-27 keep it that way. The alert has
  **no message body**: the bridge reports THAT a configuration is streaming, not which room the
  other controller is lighting, so any sentence naming a room would assert something unknowable.
- A REST look that is already running keeps writing on its own task, so assertions about
  grouped/per-light write COUNTS are races, not facts. The packet-7 tests assert on
  entertainment-level actions and on which effect survives instead.

---

## 2026-08-03 - [Claude] Composer 2 / Phase 0 / Packet 6 — All-Day playback ownership

### Branch
- `fix/all-day-playback-ownership`, cut from `main` (`c316e15`, the Packet 5 merge, PR #55).
- Rollback tag: `checkpoint/pre-composer-packet-6` (at `c316e15`). No data-format or
  persistence change, so `git reset --hard checkpoint/pre-composer-packet-6` is a total rollback.
- **No version or build bump** — not an install build. Two commits. PR opened, not merged.

### The defect (review fix #8, risk N5)
`tickAllDayScenes` wrote CT + brightness to *every* room every 5 minutes with no
check against any playback registry, and SSE echo is suppressed for app-driven
rooms — so a Composer or Studio look was stomped invisibly. Packet 3 recorded a
second defect in-source and deferred it here: All-Day owned ONE `RestSender` and
ONE sentinel scope (`RestScope(roomID: "__allDay__", owner: .allDay)`), so every
room in a tick overwrote the previous room's pending slot. With N rooms, N-2 were
typically dropped without a trace. The closure also discarded the
`ValidityProbe`, and **no** teardown path — `removeBridge`, `forgetAllBridges`,
`stopStudioMode` — could reach the mailbox at all.

### The design — delivery first, then ownership
One sender **per bridge**, one scope **per room**. Latest-wins is per scope, so
rooms stop erasing each other; `order` (FIFO across scopes) guarantees every
eligible room is dispatched; identical room ids on two bridges land in two sender
instances that never meet. The tick now carries `room.id` through — the key every
ownership table already uses, and which the old target tuple threw away.

Suppression is one centralized predicate, `isAllDayWriteAllowed(bridgeID:roomID:)`,
called at target selection **and again inside the enqueued closure** immediately
before the write. Five arms, each keyed on BOTH bridge and room:

1. `composerTelemetrySessions` — the only record covering REST, Entertainment and
   bridge-stored under one exact key, because `startCompositionMode` opens it
   *before* the transport decision.
2. `compositionEntRoomByBridge` — Entertainment ownership.
3. `activeStudioRestScope` — Studio's app-driven engine, comparing both halves.
4. `BridgeAnimationStore` manifests, matched on roomID **and bridge IP**.
5. The new bridge-native ownership registry (below).

Deliberately NOT `compositionTransportByRoom`: its roomID-only key cannot tell
identical room ids on different bridges apart, and the scheduler already refuses
to trust it for exactly that reason. Deliberately NOT `activeEffectEntries` or
`runningEffects`: view-model mirrors with no bridge identity, whose `isAppDriven`
flag is false for BOTH firmware effects and one-shots.

Bridge eligibility (`isAllDayBridgeEligible`) is kept SEPARATE from room
ownership. Folding them together would let a later edit to the ownership rule
silently reopen the sender-recreation race below.

### Sender retirement — why detachment is synchronous
`stopAllDayScenes` cannot become async (a SwiftUI Toggle setter cannot await)
while `clearAll()` is, and `startAllDayScenes` calls stop and then *immediately*
starts the next generation. So the sender map is **detached synchronously before
any cleanup is spawned**: a retired `clearAll()` landing on a sender the new
generation had reused would erase that generation's pending work, and no
generation guard can catch it — `clearAll` bumps epochs on whatever sender it
holds, regardless of which generation queued the closures. Generation bump +
map detachment are the correctness boundary; `clearAll` is mailbox hygiene.

### Blocked bridges and the teardown gate — why detachment alone is not enough
Detaching is a point-in-time act, and the suspension window is open afterwards.
While `removeBridge` is parked in `stopEffectsForRemovedGroups`, `clients[id]`
and the bridge's `allRooms` entries both still exist, so a concurrent tick would
lazily *rebuild* the mailbox that was just detached. A per-bridge tombstone is
therefore inserted before that first `await` and **outlives the removal** — a
tick captured earlier can dispatch long afterwards. `allDayRestSender(for:)`
returns an `Optional` so the refusal is structural rather than a rule every
caller must remember.

Both legitimate registration paths lift the tombstone through one helper:
`configure(bridges:modelContext:)` as well as `addBridge(_:)`. Clearing only in
`addBridge` would leave a re-paired bridge blocked from All-Day forever after the
next relaunch, because `configure` is the launch path and `HueHomeApp` calls it
immediately before `startAllDayScenesIfNeeded`. A source guard pins both.

`forgetAllBridges` has the global form of the same race — its first statement is
`await stopStudioMode()` — so it sets a teardown gate, disables, bumps the
generation, cancels the task and detaches every sender **above** that line.
Starts are refused while the gate is up, and All-Day is deliberately **not**
auto-restarted afterwards.

### Bridge-native ownership begins before the first write, not at registration
Studio's `.bridgeNative` cards are long-running firmware effects that left no
orchestrator state at all. They now claim the room through an exact-keyed,
generation-tokened registry that lives in `UnifiedOrchestrator` — not behind an
optional view-installed callback whose nil value would read as "not owned", and
so it survives `StudioView` being dismissed.

The claim is taken **immediately before the first mutating request**, not when
the `RunningEffect` is finally stored ~60 lines later: in between, the startup
turns the group on, writes per-light firmware effects, runs the effects_v2
upgrade and resolves capability. Registering at the end would leave that whole
window open to an All-Day overwrite of a half-started look. A `defer` releases
the provisional claim on every path that exits before registration (no lights
resolved, unsupported routing, and any future early return by construction); on
acceptance the token is transferred into the `RunningEffect` and the defer stands
down.

### The Studio stop path — why the guard was narrowed
`stopEffect` opened with a four-way guard that also required a resolvable bridge
client AND a `groupedLightID`, returning if either was missing — before the
strategy switch and before its own cleanup. That left `runningEffects` populated
and the Now-Playing row stuck, and would have stranded the ownership claim
forever, skipping that room from All-Day permanently. It now guards only on what
teardown actually needs; `api` and `groupedLightID` are optional and every
network step is best-effort, with the claim released via `defer` on every
terminal path.

Removal is also identity-matched now. `stopEffect` and `stopFromNowPlaying`
suspend several times, so a stop that began before a replacement can finish after
it; the old unconditional removal would erase the *replacement's* entry and its
Now-Playing row. Both now clear only what the stop actually owned.

### What is deliberately NOT claimed
- **The roomID-keyed limitation is pre-existing and NOT solved here.**
  `compositionRuntimes`, `compositionTransportByRoom`, `compositionOrder`,
  `runningEffects` and `activeEffectEntries` remain roomID-keyed. Packet 6 routes
  *around* them by choosing arms that already carry bridge identity.
- **The `""` vs `"legacy"` bridgeless split persists.** Each arm reads its own
  subsystem's convention; unifying them is a wider migration.
- **Zones are still never targeted.** The tick reads `allRooms` only.
- **No relaunch restoration.** A firmware effect running across a force-quit has
  no local record, so All-Day may overwrite it on the next tick. That is
  launch-time reconciliation (Phase 0 fix #10), not this packet.
- **A leaked claim is conservative, not destructive.** If the Studio view model
  is destroyed mid-effect, the claim persists until Studio stop-all, bridge
  removal or forget-all — All-Day skips rather than stomps, and the firmware
  effect genuinely is still running.
- **Identity matching falls back to `cardID` for non-`.bridgeNative` strategies**
  (their token is nil), so re-applying the *same* card to the *same* room is not
  distinguishable by identity alone. `apply` awaits `stopEffect` before
  re-registering, so that sequence is ordered.
- **No wall-clock delivery guarantee and no catch-up write.** A freed room
  resumes on the next normal tick, up to 5 minutes later.
- All-Day still swallows every REST error at `try?` and still writes `on: true`,
  turning deliberately-off unowned rooms back on. Both pre-existing.

### Files changed
| File | Change |
| --- | --- |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | per-bridge All-Day senders + per-room scopes; tombstones and teardown gate; six-step retirement; bridge-native ownership registry; `isAllDayWriteAllowed`; DEBUG seams |
| `HueHome/UI/Studio/StudioViewModel.swift` | `RunningEffect.bridgeNativeOwnership`; provisional claim before the first mutating write with `defer` release and transfer; narrowed `stopEffect` guard with best-effort network steps; identity-matched removal in `stopEffect` and `stopFromNowPlaying` |
| `HueHome/UI/Settings/SettingsView.swift` | one copy correction — the toggle no longer claims it applies to "all rooms" |
| `HueHomeTests/MultiBridgeRoutingTests.swift` | 46 tests across two new packet-6 sections, plus spy gates for grouped-state, per-light firmware, and staged lights |
| `DEVLOG.md`, `docs/ios/master-on-device-checklist.md` | this entry; new checklist §T |

**No new source file, no `.pbxproj` edit, no version bump.**

### Tests
`xcodebuild test … -scheme "HueHome 1"`, read via `xcresulttool` (a piped tail
loses TEST SUCCEEDED; the post-success simulator launch error is teardown noise):
- Commit 1 narrow (`MultiBridgeRoutingTests`): **116/116 passed, 0 failed.**
- Commit 1 full suite: **1077/1077 passed, 0 failed.**
- Commit 2 narrow (`MultiBridgeRoutingTests`): **142/142 passed, 0 failed.**
- Commit 2 full suite: **1103/1103 passed, 0 failed.**
- `hardening_guards.sh`: all guards passed.

No `Task.sleep` as proof, no timing waiters, no elapsed-time assertions. Four
source guards carry the claims behavior cannot reach: that the sentinel scope
stays gone, that the sender accessor stays refusal-capable and is never
force-unwrapped, that every invalidating step precedes its function's first
`await`, that both registration paths lift the tombstone, and that the ownership
check appears on both sides of the enqueue.

One test bug was found and fixed during the run rather than worked around: an
early `drainAllDay` helper enqueued a sentinel *after* a stop, and the stop's own
retirement cleanup could drop that sentinel — hanging the suite instead of
failing it. The barrier is now a `clearAll()` the test awaits, which is
idempotent and cannot be swallowed.

### What still needs hardware
Simulator tests prove the decisions; only a physical bridge proves which bulbs
get overwritten and when. The 14-item pass is §T of
`docs/ios/master-on-device-checklist.md` — headline items: both rooms updating in
one tick; a Composer or Studio room not being stomped while its neighbour still
updates; the off/on-twice restart still delivering; re-pairing a removed bridge
restoring All-Day (including across a relaunch, which exercises the other
registration path); forget-all refusing a racing re-enable; and a failed firmware
card not suppressing its room forever.

### Gotchas
- `allDayRestSender(for:)` is `Optional` on purpose. A non-optional
  lazily-creating accessor cannot express "this bridge is being removed", and a
  caller that forgot the tombstone check would recreate the mailbox mid-removal.
- The tombstone deliberately outlives `removeBridge`. Clearing it at the end of
  removal would reopen the race for any tick captured before it started.
- `defer` is legal in the `.bridgeNative` branch only because
  `endBridgeNativeOwnership` is synchronous.
- A drain sentinel enqueued after an All-Day stop can be swallowed by that stop's
  own cleanup. Use an awaited `clearAll()` as the barrier instead.

---

## 2026-08-02 - [Claude] Composer 2 / Phase 0 / Packet 5 — honest light limits

### Branch
- `fix/composer-honest-light-limits`, cut from `main` (`b0337fb`, the Packet 4 merge, PR #54).
- Rollback tag: `checkpoint/pre-composer-packet-5` (at `b0337fb`). No data-format or
  persistence change, so `git reset --hard checkpoint/pre-composer-packet-5` is a total rollback.
- **No version or build bump** — not an install build. Two commits.

### The defect — one literal, three copies, none of them Entertainment
The "20-light limit" was never a Hue constraint. Its root is
`LightFrame.channelID: UInt8` — a HueStream wire detail that leaked into the
shared pure renderer. Because `render` took `[UInt8]`, every non-DTLS caller had
to synthesize UInt8 indices, and to keep the trapping `UInt8(_:)` initialiser
safe each clamped with `min(…, 20)`:

- `UnifiedOrchestrator:4309/4311` (REST per-light and gradient)
- `BridgeAnimationEngine:121` (bridge-stored v1 rules chain)
- `GradientChannelMap:36/43` (`channelBudget`, self-documented as existing only
  to "match the render loop's channel cap")

The user-visible result was not a graceful cap but a **silent black hole**:
lights 21+ were `continue`d past before `addTask`, so they were never written,
never counted in `attemptedOperations`, never logged, and never mentioned in the
UI. A 30-light room had ten bulbs frozen for the entire life of the composition
while the tray reported a healthy cadence.

Four constraint domains were being conflated. Separated for the record:

| Domain | Real limit | Verdict |
|---|---|---|
| Entertainment / DTLS | bridge-side; `channel_id` is one byte (255), and an area is capped at 10 lights by the bridge | **no 20 in our code at all** — `validatedChannelIDs` already validates the whole ordered set all-or-nothing |
| REST | ~10 cmd/s pacing; nothing caps light COUNT | 20 was accidental |
| Gradient channels | `points_capable` per strip (≤5) | the global budget was accidental |
| Bridge-stored v1 | 8 actions/rule; per-resource capacity the bridge reports | 20 was accidental |

### Commit 1 — remove the caps, roll REST delivery fairly
- `LightFrame.channelID` and `render`/`renderMixed` now take **Int** render
  indices. The DTLS boundary zips the already-validated `[UInt8]` positionally
  and sends **nothing** rather than a partial or misaligned frame; wire ids are
  never reconstructed from render output, so the retype adds no failure mode.
- `GradientChannelMap.channelBudget` deleted. Every light keeps an entry and a
  strip expands to its own `points_capable`. Previously an 18-bulb room left a
  5-point strip 2 points, and at 19 bulbs it fell to 1, `hasGradient` went false
  and the strip silently rendered one flat colour.
- **Rolling subsets.** Rooms with more eligible operations than one sweep can
  dispatch now rotate. Partitions are contiguous and **non-wrapping**, so each
  rotation is an exact ordered partition — 21 lights go 20 then 1, 64 go
  20/20/20/4 — and every eligible operation is served exactly once per rotation.
  The eligible list is one entry per PHYSICAL LIGHT (a five-point strip is one
  slot costing one PUT), never a flattened channel index.
- **The cursor advances from actual attempt evidence** — `outcomes.count` after
  each task group returns, the same array Packet 4's telemetry reads. One
  source, three consumers (telemetry, cursor, failure taint), so they cannot
  disagree about what was dispatched. Failed attempts advance; probe-cancelled
  and superseded work advance nothing.
- **Quiescence requires DELIVERY, not attempt.** A rotation containing any
  failure leaves `hasCompletedInitialSuccessfulRotation` false, so the delta gate
  stays open and the room re-rotates. Without this, completion-only bookkeeping
  (which correctly withholds `lastSentX/Y/Bri` for a partially failed sweep)
  would have been overruled by a gate told the rotation was "complete", and a
  transiently failed light could have been stranded on a static look.
- **Gradient metadata re-indexed.** `spatialPositions`/`radialPositions`/
  `angularPositions` were built per physical light but indexed by render
  channel. They coincide only while every light owns one channel; once a strip
  expands, every light after it read a neighbour's geometry. Masked before only
  because the deleted budget kept totals small.
- Per-sweep bridge load is **unchanged**: the budget is
  `restBatchSize (5) × maxBatchesPerSweep (4) = 20` **operations**, derived so
  rooms of 1–20 behave byte-identically to build 28.

### Commit 2 — measure bridge capacity, refuse honestly
- Requirement computed from the arithmetic the uploader executes, in **integer**
  arithmetic, and in **aggregate**:
  `rules = steps × ceilDiv(lights,7)`, `conditions = rules × 2`,
  `actions = (steps × lights) + max(0, steps − 1)`.
  20×8 → 24/48/**167**; 25×8 → 32/64/**207**; 6×8 → 8/16/**55**.
  Conditions and actions are bridge-wide resources, not per-rule maxima —
  reading the nested capability numbers as per-rule limits would have compared
  8 against 8 and always passed, missing a bridge with free rules but no free
  actions. The per-rule 8-action guard is a separate shape check and stays.
- Availability now comes from the **bridge**: one `GET /capabilities` replaces
  five GETs and, more importantly, replaces four hard-coded totals
  (250/250/100/200). The old `canFitOneAnimation` asked for a flat 12 free
  rules — half what a 20-light 8-step look needs — so a bridge with 13 free
  slots passed and then threw partway through the rule loop, leaving orphans.
- **Fail closed on unknown.** Any required figure missing or undecodable is
  UNKNOWN, never zero, never a default, and never a fallback to the deleted
  constants. Unknown refuses bridge-stored **before any resource is created**.
- **Preflight is a point-in-time check, not a reservation.** Nothing in v1 can
  hold capacity, so a creation failure after a passing preflight is never
  re-labelled a capacity problem.
- v1's HTTP-200 error envelope now throws a typed
  `HueV1ClientError.apiError(type:address:description:)` instead of surfacing as
  `decodingFailed("Cannot extract v1 resource ID…")`.

### What is deliberately NOT claimed
- **No wall-clock guarantee.** The fairness bound is `⌈n/20⌉` *started sweep
  opportunities*, not milliseconds. The scheduler is best-effort (120 ms tick,
  one room per tick, one item in flight per bridge, supersession under load) and
  the code provides nothing stronger to build on.
- **A persistently failing light keeps a static large room rotating.** No
  quiescence is claimed in that case. Bounding the retry with backoff is later
  scheduler work.
- **Residual:** a transient failure appearing *after* an initial fully
  successful rotation is not retried, because the delta gate is a `frames[0]`
  colour/brightness proxy, not a per-light delivery ledger. Packet 5 guarantees
  a room never *reaches* quiescence until it has been fully delivered once,
  which is the case that strands lights today.
- **Residual:** no compensating rollback on partial upload. Preflight removes the
  predictable capacity class of failure; a race or a network drop mid-upload
  still leaks resources with no manifest recording them.
- **No verified v1 capacity discriminator exists**, so every creation error
  surfaces the generic "couldn't be stored on the bridge" sentence and the
  "bridge is almost full" wording is reserved for the MEASURED verdict alone.
  Classification from the English `description` was explicitly rejected as
  brittle and possibly localized. The conditional verified-envelope test was
  therefore not written; §S items 10–11 capture what would justify it.
- **The roomID-keyed limitation is pre-existing and NOT solved here.**
  `compositionRuntimes`, `compositionGenerations`, `compositionOrder` and
  `compositionTransportByRoom` are still keyed by roomID alone. Packet 5
  guarantees only that its OWN new state (rotation, degradation) is keyed by the
  exact `(bridgeKey, scope)` identity Packet 4 established.

### The bridge-stored branch is currently unreachable
`startCompositionMode` has two production callers: the DTLS→REST failover
(passes `preset: nil`) and `StudioViewModel:1368`, which sits in the **else** of
`if tier == .bridgeOptimized` — that branch fires a grouped one-shot and returns
without calling the orchestrator. So `preset.capabilityTier == .bridgeOptimized`
at `:3423` can never be true in the shipping app, and `.bridgeStored` is set only
by tests. Commit 2 is therefore **correctness-in-waiting**, tested at engine
level. Packet 5 deliberately does **not** re-enable the route — that is a product
change.

### Transport honesty
- `TransportVocabulary.roomModeStatus(fallback:largeRoom:liveSeconds:)` is pure
  and **total** over both facts. A single enum was insufficient: a capacity
  refusal into a 60-light room is *both* "couldn't store this" and "lights take
  turns", and whichever write landed second would have erased a true statement.
  Fallback cause and rolling delivery are stored as independent fields with
  merge-not-replace mutators.
- `bridgeCapacityInsufficient` and `bridgeCapacityUnknown` stay distinct —
  unknown capacity never says "this bridge doesn't have room".
- Insufficiency copy names rule slots **only** when rules alone fell short; the
  other four shortages, and any multi-field shortage, get an accurate general
  sentence. All five required-vs-reported figures always go to sanitized
  diagnostics.
- Degradation state is **observable** (not `@ObservationIgnored`) so the tray
  refreshes when only the reason changes; the accessor returns the immutable
  `CompositionDegradationSnapshot`, never the private mutable state.
- Two user-facing "REST" leaks fixed: `StudioParamControls` (known) and
  **"🔌 REST" in the Perform header** — found by the source-inspection guard
  added here, which both existing guards had missed.

### Files changed
| File | Change |
|---|---|
| `HueHome/UI/Studio/CompositionEngine.swift` | `channelID`/`render` → Int; `expandToRenderChannels` |
| `HueHome/Core/Composer/CompositionMixer.swift` | `renderMixed` → Int channels |
| `HueHome/Core/Composer/CompositionRoomPriorityScorer.swift` | `CompositionRotationPlan`, `CompositionFallbackReason`, `CompositionDegradationSnapshot` appended (no new file, no pbxproj edit — the packet-4 precedent) |
| `HueHome/Core/Composer/GradientChannelMap.swift` | `channelBudget` deleted |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | rotation + degradation state, subset selection, per-batch advance, delta gate, metadata expansion, DTLS boundary, fallback recording |
| `HueHome/Core/Network/HueV1Client.swift` | requirement/capacity/verdict types, `/capabilities`, typed `apiError` |
| `HueHome/Core/Network/BridgeAnimationEngine.swift` | cap removed, aggregate preflight, shortage-aware copy, no-truncation assertion |
| `HueHome/UI/Components/TransportVocabulary.swift` | `roomModeStatus`; F1/F2 rewrites |
| `HueHome/UI/Studio/MixerTrayView.swift`, `StudioParamControls.swift`, `HueHome/UI/Performance/PerformanceView.swift` | exact-bridge status wiring; jargon fixes |
| `Scripts/hardening_guards.sh` | Guard 8 |
| `HueHomeTests/…` | rotation arithmetic ×15, orchestrator integration ×16, bridge-stored ×21, copy guards ×3, plus rewrites of the two characterization-of-bug gradient tests |

**No new source file, no `.pbxproj` edit, no version bump.**

### Tests
`xcodebuild test … -scheme "HueHome 1"`, read via `xcresulttool`:
- Commit 1 full suite: **1033/1033 passed, 0 failed.**
- Commit 2 full suite: **1054/1054 passed, 0 failed.**
- `hardening_guards.sh`: all guards passed, including new Guard 8 — which was
  verified against a deliberate regression (re-adding `channelBudget` fails the
  build) rather than assumed to work.

Two existing tests were rewritten rather than repaired, because they pinned the
bug: `testGradientMapBudgetNeverStarvesLaterLights` asserted that a 20-light room
with a strip produced a **nil** map, and `testGradientMapBudgetTrimsStrip`
asserted a 5-point strip was trimmed to 3. `testAttemptedOperationsCountOnlyDispatchedRequests`
kept its invariant but changed scenario — it proved the point with frameless
entries, a path that is now unreachable by construction and an `assertionFailure`
if it recurs, since a batch dispatching fewer operations than its slice would pin
the cursor and stall the rotation.

No `Task.sleep` as proof, no `XCTWaiter`, no `wait(for:timeout:)`, no
elapsed-time assertions anywhere in the new tests. One assertion was corrected
during the run: an initial version demanded a fixed dispatch ORDER across a
rotation, which is wrong — operations within a batch run concurrently, so only
coverage and partitioning are guaranteed, not intra-batch sequence.

### What still needs hardware
§S of `docs/ios/master-on-device-checklist.md` — headline items: a 30-light room
animating **every** bulb; the rotation sentence on a large room and its absence
on a 20-light one; a static 21-light room going quiet after one pass; an
unplugged bulb keeping the room rotating rather than going quiet; a gradient
strip in a large room keeping its points while its neighbours keep their own
motion. Plus two captures (§S 10–11) that would let the capability decoder and
the v1 error classifier be tightened from documented to verified.

### Review amendment (2026-08-02, pre-merge)
PR #55 review found one defect in the new delta gate: rotation state is armed
for EVERY REST session, including the grouped fallback, whose eligible count is
0 — and nothing can ever complete a zero-count rotation (the grouped closure
reports no rotation advance, and `composerRotationAdvanced` guards on a
positive count). `rotationIncomplete` was therefore permanently true for
grouped rooms, and a static grouped room re-sent an identical PUT every 120 ms
tick forever instead of delta-gating to quiet. Fixed by extracting the gate
predicate into `CompositionRotationPlan.deliveryIncomplete`, which treats an
empty eligible set as trivially complete; covered by two pure predicate tests
plus P5-17 (`testAGroupedSessionNeverHoldsTheDeltaGateOpen`) against the
production-staged grouped shape. Suite after amendment: **1057 passed, 0
failed**; all guards pass.

---

## 2026-08-02 - [Claude] Composer 2 / Phase 0 / Packet 4 — honest completion-based REST telemetry

### Branch
- `fix/composer-honest-telemetry`, cut from `main` (`1a9fb21`, the Packet 3 merge, PR #53).
- Rollback tag: `checkpoint/pre-composer-packet-4` (at `1a9fb21`). No data-format or
  persistence change, so `git reset --hard checkpoint/pre-composer-packet-4` is a total rollback.
- **No version or build bump** — not an install build. PR opened, not merged.

### The defect (review risk row #17, arch N11 — noted here, review file NOT edited)
The mixer tray's Room-mode cadence was structurally dishonest. `recordCompositionTelemetry`
was called with `dueAt: now, sentAt: now` — the same variable — immediately after `enqueue`,
before any HTTP request was issued. So: lag was identically `0.0` forever; "sends" counted
enqueues, including work the latest-wins mailbox discarded and closures whose every operation
threw (`try?`-swallowed); the FIRST record published cadence `0.001 s` → *"updates about every
0.0s"* at the start of every composition; the published value saw-toothed (cumulative mean,
5 s reset, 1.5 s throttle) with an interval off-by-one; and the global `activeRESTCadence`
was clobbered by whichever room recorded last, with `StudioViewModel`'s fallback showing
another room's number under this room's card. Zero test coverage on any of it.
Arch-review row N11's four dead cadence functions sat alongside, callerless. Row #17
(telemetry honesty) is addressed by this packet; the review file itself is deliberately
untouched.

### One bug this surfaced: the `""`-vs-`"legacy"` bridge identity split
`startCompositionMode` computed `room.bridgeID ?? ""` into the NONOPTIONAL
`CompositionRuntime.bridgeID`, while `restSender(for:)` normalizes nil → `"legacy"`. `""` is
not nil — so a bridgeless room's Composer ran on a private `""` sender while All-Day and
Studio shared `"legacy"`: two mailboxes for one conceptual bridge. Enqueue and clear were
consistently wrong TOGETHER, so packet 3's cancellation still functioned — but any identity
built on the runtime's `bridgeID` would have split them. The runtime now carries
`restBridgeIdentity` (the room's ORIGINAL optional); the scheduler's sender resolution, the
stop-side clear, token identity, publication, the accessor, and teardown ALL key on it. A
bridgeless room is `"legacy"` everywhere; no `""` sender or telemetry bucket can exist.

### The model — five events, evidence only
`CompositionSendLedger` (pure value type, appended below `CompositionRoomPriorityScorer` in
the same file — the HueHome target is not file-system-synchronized, so no new .swift file).
Every timestamp is a parameter; the ledger knows nothing about publication or RestSender.

- `Token = (bridgeKey, scope, generation, sequence)` where bridgeKey is
  `restBridgeIdentity ?? "legacy"` — token identity can never disagree with the mailbox.
- Events: `enqueued` / `started` / `completed` / `cancelled` / `superseded`, plus the
  lifecycle pair `beginSession` / `deactivateSession`. No separate `failed` event: a
  gradient/per-light closure is a BATCH with partial outcomes, so terminals carry
  `attemptedOperations` + `failures`; `successfulOperations = max(0, attempted − failures)`.
- STRICT token-state transitions: enqueued → started → completed; cancelled from enqueued
  (pending, NORMALIZED to 0/0 — never-started work cannot have dispatched operations) or from
  started (cooperative cancellation, carrying what ran); superseded from enqueued only.
  Absent tokens, stale generations, duplicates, and out-of-order terminals are ignored, and
  the terminal methods RETURN acceptance so callers can gate on the verdict.
- `beginSession` always starts from a blank slate — even for a repeated generation value —
  because generation equality alone cannot fence a new transport window from an old executing
  completion; the wiped token state can. `deactivateSession` acts only when the supplied
  generation is active; after it, every report from that generation dies and the snapshot is
  empty.
- Cadence = `(latest − oldest) / (n − 1)` over CONTRIBUTING completions (terminal items with
  ≥1 successful operation) in a rolling 5 s horizon; nil under two items. **successfulItems
  and cancelledItems are intentionally NOT mutually exclusive**: a sweep that landed a batch
  and then honored its probe both succeeded (those writes lit real bulbs) and was cancelled.
- Bounded memory: only non-terminal tokens retained; newest-32 completion timestamps pruned
  past the horizon; counters and duration totals are scalars.

### Orchestrator: sessions, evidence, expiry
- Retained telemetry sessions are keyed by the EXACT `(bridgeKey, scope)` — never roomID
  alone (identical room IDs on different bridges are different sessions) — with value
  `{generation, isRESTActive}`, held INDEPENDENTLY of `compositionRuntimes` so stop works
  when the transport is Entertainment or bridge-stored and no REST runtime ever existed.
- `stopCompositionMode` now takes `(roomID:bridgeID:)` — the CALLER states the room's
  original optional identity (Studio passes `effect.room.bridgeID`; the Entertainment
  handoff prompt retains `owningBridgeID` from creation). Stop LOOKS UP the sender
  (`restSendersByBridge[key]`) and never creates one — stopping an Entertainment-only
  session must not conjure a mailbox.
- Pending replacement and pending cancellation come ONLY from RestSender's own word:
  `enqueue → RestEnqueueResult.replacedPending` supersedes the previously captured token;
  `clear → Bool` / `clearAll → Set<RestScope>` drive 0/0 pending cancellations. Nothing is
  inferred — `flush()` dequeues before dispatch, so "enqueued but not started" proves
  nothing. The pending tracker is installed BEFORE awaiting `enqueue` (a fast dispatch's
  started report must find it), removed only by equality-checked reports the ledger ACCEPTED
  or by sender-evidence teardown, and a rejected terminal cannot touch it.
- Teardown order everywhere (stop / bridge removal / stopStudioMode / forget-all): consume
  the sender's pending-removal evidence → record 0/0 pending cancellations for exactly the
  reported scopes → deactivate the ledger session → drop retained identity, tracker, and
  publication. Global paths iterate `restSendersByBridge` ENTRIES (the dictionary key is the
  authoritative bridge identity) and then sweep every remaining exact session key — including
  senderless Entertainment bridges. Executing closures stay governed by their probes; their
  later reports die in the deactivated ledger.
- CADENCE EXPIRES WITHOUT A NEW COMPLETION: every `runCompositionScheduler` pass refreshes
  publication for EVERY retained REST-active session (eligibility from the retained
  `isRESTActive`, never `compositionTransportByRoom`) — so a hung bridge's number leaves the
  screen within the 5 s horizon instead of freezing. No new timer; the 120 ms pass is reused.
  Publication lives in `activeRESTCadenceByBridgeRoom[bridgeKey][roomID]`, read only through
  `activeRESTCadence(roomID:bridgeID:)`; `StudioViewModel` passes the selected room's bridge
  and has no global fallback.
- COMPLETION-ONLY RUNTIME BOOKKEEPING (the one intentional behavior change):
  `lastSentX/Y/Bri`, `lastSentAt`, `sendCount` advance only on an ACCEPTED `completed` with
  attempted > 0, failures == 0, a live runtime, and matching generation + bridge identity —
  at the SAME `terminalAt` the ledger recorded. Failed, partial, and CANCELLED items leave
  the frame eligible for re-send (device check 11 covers the recovery this buys). The
  scheduler re-reads the runtime after the enqueue await and advances only `nextDueAt`, so a
  fast completion's bookkeeping can't be erased by a stale struct write. The startup prime
  (still a direct API call, outside RestSender and cadence) moved its bookkeeping inside the
  success path, gated on the issuing generation — a thrown prime records nothing and a stale
  prime cannot mutate a newer runtime.
- The three composer closures count ACTUAL dispatched operations: task-group children return
  their own outcomes, aggregated after the await; frameless gradient entries and lights
  beyond the frame array count nothing. `started` is reported before the first probe.
  Packet 3's `stillCurrent` guard positions are byte-identical in intent and pinned by the
  (extended) source-shape test; the closures now live in `makeComposer*Work` factories so
  the scheduler and the DEBUG seams build the identical closure.

### RestSender: return values only
`RestEnqueueResult.replacedPending`, `clear -> Bool`, `clearAll -> Set<RestScope>` — each
computed from a line packet 3 already executed, all `@discardableResult` so every existing
caller compiles unchanged. Actor semantics, epochs, FIFO order, probes, `isFlushing`, and
flush sequencing are UNCHANGED.

### Deleted rather than repaired
`CompositionTelemetry`, `recordCompositionTelemetry`, the four dead cadence functions
(`minimumComposerRESTInterval` / `minimumComposerBurstFloor` / `preferredComposerIdleInterval`
/ `lowPowerIdleInterval`, arch N11), the global `activeRESTCadence`, the roomID-only
`activeRESTCadenceByRoom`, `cadenceLastUIUpdateByRoom`, `compositionTelemetryByRoom`, the
DEBUG lag print, and `StudioViewModel`'s global fallback.

### Files changed
| File | Change |
|---|---|
| `HueHome/Core/Composer/CompositionRoomPriorityScorer.swift` | `CompositionSendLedger` appended (pure; no publication knowledge) |
| `HueHome/Core/Network/RestSender.swift` | return-value observability only |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | bridge-identity correction, sessions, evidence plumbing, clock seam, closure factories, per-pass refresh, exact-key teardown, deletions, DEBUG seams |
| `HueHome/UI/Studio/StudioViewModel.swift` | `activeRESTCadence(roomID:bridgeID:)` accessor; handoff prompt retains `owningBridgeID`; stop passes explicit identity |
| `Scripts/hardening_guards.sh` | Guard 7: no timing waits in the pure ledger/scorer tests |
| `HueHomeTests/…` | 58 net new deterministic tests (pure ledger ×21, sender return values ×6, orchestrator integration ×29 net, prime gates ×2) |

**No new source file, no `.pbxproj` edit, no version bump.**

### Tests
`xcodebuild test … -scheme "HueHome 1"`, read via `xcresulttool` (a piped tail loses
TEST SUCCEEDED; the post-success simulator launch error is teardown noise):
- Narrow (scorer/ledger + gated + multi-bridge + entertainment): **144/144 passed, 0 failed.**
- Full suite: **997/997 passed, 0 failed.**
- `hardening_guards.sh`: all guards passed (incl. new Guard 7).

### What still needs hardware (the remaining gate)
Simulator tests prove the decisions; only a physical bridge proves what the tray shows while
real requests fly. The 11-item Packet 4 pass is §R of
`docs/ios/master-on-device-checklist.md` — headline items: no "0.0s" flash at Room-mode
start; per-room-per-bridge numbers; the cadence DISAPPEARING within ~5 s when a bridge drops
off the network; stop/restart carrying nothing over; and a mid-composition unplugged light
not freezing the delta gate.

---

## 2026-08-02 - [Claude] Composer 2 / Phase 0 / Packet 3 — scoped REST mailboxes + cooperative cancellation

### Branch
- `fix/composer-scoped-rest-mailbox`, cut from `main` (`ee9064e`, the Packet 2 merge, PR #52).
- Rollback tag: `checkpoint/pre-composer-packet-3` (at `ee9064e`). No data-format or
  persistence change, so `git reset --hard checkpoint/pre-composer-packet-3` is a total rollback.
- **No version or build bump** — not an install build. PR opened, not merged.

### The defect
Phase 0 item 5 / review risk rows #3, #4, #5. `RestSender` was a single-slot,
single-in-flight latest-wins mailbox, and **one instance** (`studioRestSender`) served every
Composer room, every Studio app-driven engine loop, and every Studio live-param write, across
every bridge. Four consequences, all live on `main` before this packet:

1. **`clear()` was global.** `stopCompositionMode(roomID:)` discarded other rooms' and other
   bridges' queued frames. Worse than a dropped frame: the scheduler had *already* recorded
   `lastSentX/Y/Bri` for the frame `clear()` threw away, so the delta gate then skipped the
   re-render — **a stopped room could freeze a RUNNING room's colour.**
2. **`clear()` could not stop work that was already executing.** The gradient and per-light
   Composer closures loop over 5-light batches with 80 ms sleeps between them and contained
   zero cancellation checks — 300–500 ms of stale writes that could land *after* the
   replacement look's prime frame.
3. **`Task.isCancelled` was useless as a fix.** The flush task is unstructured, unowned and
   never cancelled, so `Task.isCancelled` is *permanently false* inside an enqueued closure.
   Any guard built on it there is a silent no-op. This also makes `BridgeCommandGate`'s own
   cancellation guards inert when it is driven from inside a mailbox closure — which is
   exactly what the Studio per-light loops do.
4. **The one-in-flight guarantee had a scheduling race.** The in-flight flag was set inside
   the separately spawned flush task, so two enqueues arriving before the first flush was
   scheduled spawned two flush tasks; the second found `pending` empty, fell through, and
   cleared the flag while the first was still awaiting work — permitting the concurrent
   execution and bridge backlog the mailbox exists to prevent.

### The design — why the scope key looks like this
`RestScope` is `(roomID, owner)` where owner is `.composer` / `.studio` / `.allDay`.
**`bridgeID` is deliberately NOT in the scope.** Bridge identity lives in the owning
dictionary — `UnifiedOrchestrator.restSendersByBridge`, keyed exactly like `commandGates`
(`"legacy"` for the nil-bridge fallback). Duplicating the bridge in the value would let the
dictionary key and the scope disagree, and a `clear()` aimed at the wrong sender fails
*silently*. Owner is part of the key because Composer and Studio can legitimately target the
same room at once (a Studio slider while a composition runs) — one must not cancel the other.

Cancellation is epoch-based, not `Task.isCancelled` (see defect 3). Every scope carries a
monotonic epoch; each enqueued closure receives a `ValidityProbe` bound to the epoch it was
stored under; `clear(scope:)` bumps that epoch. `enqueue` seeds `epochs[scope]` without
bumping it — otherwise a scope whose work is *currently executing* would be in neither
`pending` (flush removed it) nor `epochs`, and `clearAll()` would miss exactly the closure
still writing to the bridge. (A unit test caught that; it is now test 4.)

One lifecycle flag, `isFlushing`, set **synchronously inside `enqueue` before** the flush
task is spawned — that closes defect 4. There is deliberately no second authoritative flag.

### What `clear(scope:)` guarantees — and what it does not
**GUARANTEED:** pending work for that scope is removed (it never starts); the epoch is
invalidated *before* `clear` returns; an executing closure stops before entering its **next**
batch or next light; at most the already-dispatched batch or request remains; every other
scope — other rooms, the other owner on the same room, every other bridge — is untouched.

**NOT GUARANTEED:** that an HTTP request already in flight completes before the replacement
prime, or that the prime is the final write to those lights. Stated precisely: *the old scope
is invalidated before the replacement prime; an already-dispatched batch may still complete,
but no later batch may begin.*

### Cooperative cancellation covers BOTH loops
- **Composer five-light batches** — `stillCurrent` is probed at the top of every batch
  iteration, including batch 1, in both the gradient-aware and flat per-light paths.
- **Studio paced per-light parameter writes** — warmth, speed and base colour. The probe is
  checked immediately before **every** `gate.send`, including the first light. Checking once
  before the loop is not sufficient; that is what left a ~`lightCount × 100 ms` (~2 s on a
  20-light room) uncancellable sweep.

**Both carry the SAME bound: no more than the currently dispatched batch or individual light
request can survive scope invalidation.** Neither aborts an in-flight HTTP request.

### Composer bridge identity comes from the runtime, and nowhere else
`stopCompositionMode` reads `compositionRuntimes[roomID]?.bridgeID`, captured before the
dictionary is mutated (the runtime is still present at the clear point; it is removed later
in the same function). Never from `allRooms`, manifests, selected-room state, or dictionary
order — `CompositionRuntime.bridgeID` exists precisely because the `allRooms` snapshot goes
stale mid-composition, and a stale lookup would clear the wrong bridge's mailbox in both
directions. **No REST runtime → nothing is cleared and no sender is conjured.** Guessing a
bridge cancels an innocent room; test 10 pins that the stop does not even lazily create a
sender.

### The previous-Studio-scope ownership fix
`activeStudioTask` is one global slot, so starting Studio in room B silently replaces room A's
loop. `startStudioMode` therefore clears the **previously recorded** scope (tracked in
`activeStudioRestScope`, bridge key included), not the incoming room's — clearing only the new
room would leave room A's epoch valid and its queued batches legal, i.e. cross-room crossfire.
Order is: cancel prior task → clear previous scope → forget it → resolve new room → record the
new scope **before** its first enqueue.

### Sender lifecycle on bridge removal — a deliberate divergence
- `forgetAllBridges()`: `clearAll()` every sender, *then* drop `restSendersByBridge` and
  `activeStudioRestScope`.
- `removeBridge(id:)`: clears and removes **only** that bridge's sender, and clears
  `activeStudioRestScope` iff it belonged to that bridge.
- `stopStudioMode()`: `clearAll()` on every sender — this is the stop-everything path, so
  global is correct here, unlike the two room-scoped stops.

**Divergence recorded on purpose:** `removeBridge` does *not* clean `commandGates` today, so
that dictionary leaks an idle gate per removed bridge. Senders do not reproduce that — a
leaked sender would also hold live epochs for a bridge that no longer exists.

### Kept as-is, deliberately
- **The three 150 ms settle sleeps stay.** They are practical bridge-firmware settle windows,
  not formal drains. `clear` already guarantees no *later* batch begins; a true bounded
  in-flight drain belongs to the later ownership/scheduler work, not to Packet 3.
- **Both 80 ms inter-batch sleeps stay** — cadence unchanged.
- **The Composer startup prime stays a DIRECT API call.** Routing it through the mailbox would
  alter startup latency and ordering beyond this packet's scope. Stated so nobody "fixes" it.

### Also cleaned up
- `studioGeneration` was incremented on every Studio start/stop and **never read** — dead
  state that looked like a working staleness guard. Deleted; Studio staleness is now the scope
  epoch (which closures actually consult) plus `activeStudioTask` cancellation.
- The three comments claiming *"Staleness is handled solely by `RestSender.clear()`
  (latest-wins)"* were false once the batches could outlive the clear. Replaced with what is
  now true.

### All-Day — known limitation, deferred to Packet 6
All-Day keeps its **own dedicated sender** and one sentinel scope; it is *not* routed through
`restSendersByBridge` and is *not* keyed by room. Per-tick behavior is unchanged, and the
limitation is now recorded in-source verbatim:

> The single pending slot does not guarantee delivery to every room in one All-Day tick;
> later room enqueues may overwrite earlier pending work.

Per-room delivery and playback suppression are Packet 6's remit.

### Files changed
| File | Change |
|---|---|
| `HueHome/Core/Network/RestSender.swift` | rewritten in place — `RestScope`, `RestScopeOwner`, `RestEpoch`, `ValidityProbe`, scoped `enqueue`/`clear`/`clearAll`/`isCurrent`, FIFO `order`, single `isFlushing` |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | `restSendersByBridge` + `restSender(for:)`, runtime-sourced Composer stop, `activeStudioRestScope`, scoped `enqueueStudioRestWrite(roomID:bridgeID:)`, batch probes, engine-loop scoping, lifecycle, All-Day sentinel, `studioGeneration` removed, DEBUG seams |
| `HueHome/UI/Studio/StudioViewModel.swift` | six call sites scoped; three paced per-light loops made cancellable |
| `HueHomeTests/GatedBulkWriteTests.swift` | 7 pure-sender tests + shared `RestGate`/`RestEventLog`/`RestProbeBox` support |
| `HueHomeTests/MultiBridgeRoutingTests.swift` | packet 3 section: 13 orchestrator/integration tests + the source-shape guard |

**No new source file and no `.pbxproj` edit** — the project file is hand-maintained, and a new
file is avoidable build-breakage risk. No completion callback and no Packet 4 telemetry API:
Packet 4 adapts this sender contract after it merges.

### Tests
`xcodebuild test … -scheme "HueHome 1"`, read via `xcresulttool` (a piped tail loses
TEST SUCCEEDED; the post-success simulator launch error is teardown noise):
- Narrow (`MultiBridgeRoutingTests` + `GatedBulkWriteTests`): **60/60 passed, 0 failed.**
- Full suite: **939/939 passed, 0 failed.**

Every assertion is on recorded event **order** and presence, driven by continuations —
`Task.sleep` is never used as proof of anything. Packet 1a/1b/2 tests pass unmodified.

Two source-shape guards ride along, because behavior tests alone would still pass if a later
edit hoisted a probe out of a loop: every enqueued closure in both production files is checked
for (a) no `Task.isCancelled`, (b) a `stillCurrent` guard immediately before every `gate.send`
in all three per-light Studio loops, and (c) a probe before every Composer batch dispatch.
(The fourth `gate.send`, in `applyEffectsV2Parameters`, is the initial apply — it is not
inside a mailbox closure and has no probe to consult, so it is correctly outside that set.)

### Gotchas
- `RestSender.Work` takes `@escaping ValidityProbe` so a closure may hold the probe past its
  own call — production calls it inline; tests capture it to observe what a *running* closure
  would see.
- `clearAll()` must bump every epoch **before** clearing `pending`/`order`. The other order
  leaves a window where a running closure's probe still reports "current".
- The `enqueue` epoch seed (above) is load-bearing, not cosmetic.

---

## 2026-08-02 - [Claude] Composer 2 / Phase 0 / Packet 2 — scoped bridge-stored resource cleanup

### Branch
- `fix/composer-scoped-bridge-cleanup`, cut from `main` (`b00bfa0`, the Packet 1b merge, PR #51).
- Rollback tag: `checkpoint/pre-composer-packet-2` (at `b00bfa0`).
- **No version or build bump** — not an install build. PR opened, not merged.
- Commits: `95dec4f` (fix + all tests), then this docs commit.

### Defect fixed
Phase 0 item 4 / review defect 4 / risk-register row 10. Every bridge-stored composition
start ran, after its per-room cleanup loop:

```swift
await bridgeAnimationEngine.purgeAllChromaGlowResources(v1Client: v1Client)
```

That purge enumerates `/schedules`, `/rules`, `/sensors`, `/scenes`, `/resourcelinks` and
deletes **every** resource whose name begins `CG_`. `CG_` is a prefix *every* ChromaGlow
room's resources share, so:

- Room A is running a bridge-stored animation; manifest A records its sensor, rules,
  schedule, resourcelink.
- The user starts a bridge-optimized look in Room B on the same bridge.
- Room B's start purges the bridge. Room A's resources are deleted.
- Room A stops or half-stops — and manifest A is still persisted, now pointing at
  resources that no longer exist.

The per-room loop above it carried a quieter second bug: it filtered on `roomID` **alone**
(`allManifests() where oldManifest.roomID == roomID`) and then stopped each match through
the *current* room's `v1Client`. A manifest recorded against a different bridge was
therefore "stopped" by issuing its deletes at a bridge that never held those resources —
while the manifest, the only record of the live ones, was dropped.

### Before / after

| | Before | After |
| --- | --- | --- |
| Manifest selection | `roomID` only | `roomID` **and** `bridgeIP` |
| Bridge identity source | caller's `v1Client`, unchecked against the manifest | derived from `v1Client.bridgeIP`, matched against `manifest.bridgeIP` |
| Bridge enumeration on start | all five inventories, every start | none |
| Prefix-based deletes on start | yes, all `CG_*` | none |
| Sibling room on the same bridge | destroyed | untouched |
| Same room id on another bridge | deletes misrouted, manifest dropped | untouched, manifest kept |

### Exact normal-playback cleanup rule
`cleanupBridgeStoredAnimationForReplacement(roomID:v1Client:)` (private, `UnifiedOrchestrator`):

1. `bridgeIP = v1Client.bridgeIP`.
2. `bridgeAnimationStore.ownedManifests(roomID:bridgeIP:)` — the new store query, matching
   `manifest.roomID == roomID && manifest.bridgeIP == bridgeIP`.
3. For each: `bridgeAnimationEngine.stop(manifest:v1Client:)` (the manifest's own recorded
   IDs, in the existing dependency-safe order: schedule → rules → sensor → scenes →
   resourcelink), then `bridgeAnimationStore.remove(presetID:roomID:)`.
4. No `fetchSchedules` / `fetchRules` / `fetchSensors` / `fetchScenes` /
   `fetchResourcelinks`. No name-prefix matching. **The manifest's recorded IDs are the
   ownership boundary.**

### Approved signature deviation
The packet proposed `(roomID:bridgeIP:v1Client:)`. Shipped as `(roomID:v1Client:)` with
`bridgeIP` derived from `v1Client.bridgeIP`. Same semantics, and it makes cleaning one
bridge's manifests against another bridge's client *structurally impossible* rather than
merely correct-by-convention — which is precisely the failure this packet exists to
prevent. Confirmed approved in the Lane A continuation.

### Global purge: removed from playback, kept for maintenance
`BridgeAnimationEngine.purgeAllChromaGlowResources` is **unchanged** — same five
inventories, same `CG_`-only filter, same behavior. Only its wiring changed.

- Callers **before**: `SettingsView.swift:554` (explicit maintenance) **and**
  `UnifiedOrchestrator.swift:3003` (every bridge-stored start).
- Callers **after**: `SettingsView.swift:554` only.

It is not called from `startCompositionMode`, `stopCompositionMode`, `startStudioMode`, app
launch, foreground refresh, area refresh, automatic recovery, or card replacement. The
Settings → Clean Bridge Resources maintenance action is untouched, and no Settings UI was
redesigned.

`stopCompositionMode(roomID:)` was deliberately **not** modified: it already resolves each
manifest's own bridge via `hueClient(forBridgeIP:)` (M-07) and filters by room, so it never
reaches a sibling room's resources.

### Tests added — 11, all in `HueHomeTests/MultiBridgeRoutingTests.swift`
No new test file, no pbxproj churn. `RoutingSpyV1Client` gained `fetchCalls` recording,
settable stub inventories, and overrides for all five `fetch*` methods — which both makes
"normal playback never enumerates the bridge" assertable and stops an un-overridden fetch
from attempting a real request against the TEST-NET-1 spy addresses. One narrow DEBUG seam,
`testCleanupBridgeStoredForReplacement(roomID:v1Client:)`, modeled on the packet 1a/1b
seams: it exposes the decision, never mutable ownership state.

1. `testStartingARoomPreservesASiblingRoomsBridgeAnimation` — first start in room B deletes
   nothing of room A's, enumerates nothing, leaves A's manifest in the store.
2. `testReplacingARoomDeletesOnlyThatRoomsKnownResources` — exactly B's recorded set,
   disjoint from A's; B's manifest gone, A's kept.
3. `testEveryOldManifestForTheTargetRoomIsCleaned` — two manifests for the target room,
   both fully cleaned, sibling untouched.
4. `testSameRoomIDOnAnotherBridgeIsNotTreatedAsOwned` — the guard against roomID-only
   filtering. Distinct preset IDs, because the store key is `presetID_roomID`.
5. `testCleanupOnOneBridgeSendsZeroTrafficToTheOther` — bridge B sees no deletes *and* no
   reads.
6. `testNormalReplacementNeverEnumeratesBridgeResources` — zero `fetch*` calls, while the
   manifest-specific deletes still happen.
7. `testExplicitMaintenancePurgeDeletesOnlyChromaGlowResources` — drives the purge directly
   with inventories mixing `CG_*` and ordinary Hue/third-party entries; every `CG_` goes,
   no other resource is touched.
8. `testManifestCleanupDeletesInDependencySafeOrder` — schedule → rules → sensor → scenes →
   resourcelink, **within a single manifest**, by index. No sleeps, no wall-clock.
9. `testManifestWithoutAResourcelinkCleansSafely` — `resourcelinkID == nil`.
10. `testManifestWithEmptyRuleAndSceneArraysCleansSafely` — empty `ruleIDs` / `sceneIDs`.
11. `testGlobalBridgeAnimationPurgeIsWiredOnlyToExplicitMaintenance` — **architectural
    guard, not a behavior test.** Tests 1–10 all exercise the helper, and the helper
    genuinely enumerates nothing — but every one of them would still pass if a later edit
    called the global purge from `startCompositionMode` right *after* the helper, which is
    exactly the shape the defect had. It derives the repo root from `#filePath`, strips
    comment-only lines (the orchestrator now carries a doc comment naming the purge, and
    documentation is not a call site), and asserts: no `purgeAllChromaGlowResources` in
    `UnifiedOrchestrator.swift`; the maintenance call still in `SettingsView.swift`; the
    definition still in `BridgeAnimationEngine.swift`. Production sources only.

**Ordering discipline:** `BridgeAnimationStore` holds manifests in a dictionary, so the
order two manifests are cleaned in is not a contract. Multi-manifest tests compare **sets**;
delete order is asserted only *within* one manifest. Production cleanup was not sorted to
satisfy a test. Test hygiene: fresh `UUID()` preset IDs, unique room ids per test, staged
manifests removed in `tearDown`, no `removeAll()`, no order dependence.

### Validation
- Narrow: `-only-testing:HueHomeTests/MultiBridgeRoutingTests` → **33 passed, 0 failed,
  0 skipped** (22 pre-existing + 11 new), verified via `xcresulttool` on
  `/tmp/Packet2Narrow.xcresult`.
- Full suite: `/tmp/ComposerPacket2.xcresult` → `xcrun xcresulttool get test-results
  summary` reports **918 passed, 0 failed, 0 skipped, result "Passed"**. Packet 1b's merged
  baseline was 907 — delta is exactly the 11 new tests, no unrelated count change.
- `scripts/hardening_guards.sh` → all guards passed.
- `git diff --check` → clean.
- **Simulator only.** Nothing here is physical-Hue validation; §P of the master on-device
  checklist is the hardware gate.

### Files touched
- `HueHome/Core/Network/UnifiedOrchestrator.swift` — new private helper, new DEBUG seam,
  the dangerous start sequence replaced by one call.
- `HueHome/Core/Persistence/BridgeAnimationStore.swift` — `ownedManifests(roomID:bridgeIP:)`
  only. **No format change, no migration, `BridgeAnimationManifest.key` untouched,
  `bridge_animations.json` not migrated.**
- `HueHomeTests/MultiBridgeRoutingTests.swift` — spy extension + 11 tests.
- `DEVLOG.md`, `docs/ios/master-on-device-checklist.md` (this docs commit).

### Pending hardware checks
§P of `docs/ios/master-on-device-checklist.md` — seven checks: two bridge-stored rooms on
one bridge, replace room B, stop room B, stop room A, multi-bridge isolation, the explicit
maintenance action, relaunch observation. **Packet 1a's and packet 1b's hardware checks stay
open and are not superseded.**

### Non-goals (not implemented)
Scoped `RestSender` mailboxes; per-bridge REST scheduling; cooperative cancellation in REST
batches; telemetry; the >20-light rolling subsets; All-Day arbitration; third-party
Entertainment consent; `BridgeSessionArbiter`; `activeStudioTask` redesign; Entertainment
ownership or area-selection changes; `studioEntClients` restructuring; schema or
persistence-envelope changes; render-state extraction; OKLab/mirek/blackout; compiler or
patch editing; Composer UX; Android; any version or build bump. The four optional packet 1b
review findings (dead `findEntertainmentConfig` cleanup, `needsLights` warm-guard refactor,
`preferredConfigID` behavior, Studio force-warm optimization) are **not** part of packet 2.

### Explicitly deferred
- **Upload rollback remains deferred.** A partially-failed upload is not compensated; its
  orphaned `CG_` resources stay on the bridge until the explicit maintenance action runs.
  Accepted by design (packet §7) — belongs to later ownership/transport hardening.
- **Launch-time manifest reconciliation remains Phase 0 item 10.** Relaunching while a
  bridge-stored animation runs still does not restore in-app state. Not a packet 2 failure.
- **Packet 1a and packet 1b behavior is unchanged.** The per-bridge Entertainment gate, the
  Studio↔Composer handoff prompt, room-aware area selection, honest availability and the
  multi-bridge routing guarantees are untouched; their tests pass unmodified.

### Adjacent risks found, left open
- `SettingsView.cleanBridgeResources` builds its client from the legacy shared
  `HueAPIClient.shared`, so the maintenance action purges **one** bridge. It is not a
  complete multi-bridge maintenance UI. Packet 2 explicitly does not redesign it.
- `BridgeAnimationManifest.key` is `presetID_roomID` and omits bridge identity: the same
  preset in the same room on two bridges collides in the store, and one manifest silently
  overwrites the other. The new query filters correctly on what *is* stored; the key itself
  is out of scope (the packet forbids changing it).
- `stopCompositionMode(roomID:)` takes no bridge argument and so can affect every manifest
  sharing that room id. It routes each one to its own bridge correctly (M-07), so it is not
  the destruction defect — but the API cannot express "stop this room on this bridge".
  Packet 2 fixes the normal replacement path only.

### Rollback
```bash
git reset --hard checkpoint/pre-composer-packet-2   # = b00bfa0, the Packet 1b merge
```
Or revert `95dec4f` alone to restore the old start sequence (which reinstates the
cross-room destruction defect). The branch is not merged; closing the PR is also sufficient.

---

## 2026-08-02 - [Claude] Composer 2 / Phase 0 / Packet 1b — room-aware Entertainment Area selection

### Branch
- `fix/composer-entertainment-area-selection`, cut from `main` (`260c54f`, the Packet 1a merge).
- Rollback tag: `checkpoint/pre-composer-packet-1b` (at `260c54f`).
- **No version or build bump** — not an install build. PR opened, not merged.

### Defect fixed
`findEntertainmentConfig(bridgeID:preferredConfigID:)` fetched every
`entertainment_configuration` on a bridge and returned `configs.first`. Selection was scoped
to the **bridge**, never the **room**:

- A Bedroom composition could open a DTLS session on the Living Room's Entertainment Area.
- `entertainmentAvailability(for:)` reported "available" for rooms with zero lights in any
  area, because *some* area existed on their bridge.
- `startStudioMode` selected **twice** per start — once to open the session, once more to read
  channel IDs — two independent `configs.first` picks that agreed only by accident.

The trap underneath it (the reason Packet 1a split this out):
`EntertainmentChannel.lightServiceIDs` holds **entertainment service** rids, not light rids —
`parseChannel` fills it from `members[].service.rid`. Comparing them with room light IDs
matches nothing on any bridge, so a selector built that way returns nil always and disables
Entertainment app-wide, silently, while every test written against the same assumption passes.

### Mapping extraction
The correct join already existed inside `resolveEntertainmentLightPositions`:

```
entertainment service --owner.rid--> device <--owner.rid-- light service
```

It is now `EntertainmentAreaSelector` (appended to `EntertainmentConfigManager.swift` — no new
file, no pbxproj churn, same call Packet 1a made), cached per bridge, and consumed by
selection, channel IDs, spatial positions and availability alike.
`resolveEntertainmentLightPositions` was **deleted, not wrapped** — two names for one join is
exactly how the rid confusion survived this long. It also removes a duplicate
`/resource/entertainment` + `fetchLights` round trip from every composition start.

`deviceToLightID` resolves a multi-light device to its **lowest** light ID rather than
last-writer-wins, so a reordered `/resource/light` response cannot change the map. (Such an
area then maps to a strict subset of the room and is selected by stage B instead of stage A —
still safe, just not an exact match. Known limitation, documented in the type.)

### Exact selection contract
Pure, deterministic, order-independent. Eligibility first: a config must resolve to ≥1 real
light **and** yield usable channel IDs — an unstreamable area may never be selected, or
availability promises a stream startup then refuses. Configs resolving to the *same* light set
are grouped as equivalents.

1. **Exact** — the group equal to the room's light set wins.
2. **Contained** — else the unique largest strict subset wins; equal-size different subsets are
   ambiguous → nil. (This is what lets an area deliberately cover part of a larger room.)
3. **Dominant overlap** — else, and **only when ≥2 groups have distinct non-empty overlaps**,
   the group whose overlap strictly contains every other's wins.

Array order, area name and `configs.first` are never tie-breakers; the only tie-break is the
stable config ID, inside a group of equivalents. A `preferredConfigID` is honoured only inside
the winning group (or its unstreamable twin), else nil — an explicit ID cannot buy its way past
room safety.

**Two agreed deviations from the packet's literal wording** (Brian's calls, both amendments to
the approved plan):

- *§6A "multiple exact matches → nil"* would have disabled Entertainment for anyone holding
  both a Hue-app area and a ChromaGlow-built one over the same room (our own builder POSTs
  `configuration_type: "music"`). Equivalent light sets are normalized at **selection time**
  only; nothing is deleted or merged on the bridge.
- *§6C "strict superset of every other overlap"* is vacuously true with one candidate, so a
  lone whole-house area would have been selected for a Bedroom composition — the exact defect
  1b fixes. Stage C now requires a real contest.

### Cache before/after
| | before | after |
|---|---|---|
| configs | `[String: EntertainmentConfig]` — one per bridge, whichever was listed first | `[String: [EntertainmentConfig]]` — the whole inventory |
| membership | *(none — recomputed by two fetches on every start)* | `[String: [String: String]]`, entertainment service → light |
| fetched marker | inserted unconditionally | inserted **only on a successful configs GET** |

Key absent = unknown or failed. Empty value = successfully computed and genuinely empty. That
distinction is what separates `.unknown` from `.noArea` from `.noMatchingArea`.

**Warming is component-aware.** Configs, membership and raw lights complete independently, so
`force: false` fetches only what is missing — a bridge whose configs arrived but whose
membership request failed is retried by an ordinary warm instead of stranding on `.unknown`
forever. `force: true` refreshes all three, but each component keeps its own last-known-good if
its refresh fails: a blip never replaces valid configs with `[]` nor removes a valid map.
Lights fetched during a warm are written back into the raw-light cache, so bridges whose
`loadAll` failed become answerable instead of silently unstreamable.

### Honest availability
New case `.noMatchingArea` (a definite no, `canStream == false`):
*"No Entertainment Area can safely stream to this room. Create or update an area for this
room."* — worded to stay true for both causes (no membership match, and a matching area whose
channels are unusable). Precedence:

```
noBridge → noClientKey
→ configs never fetched / first fetch failed   .unknown
→ configs fetched and empty                    .noArea
→ membership absent (a fetch failed)           .unknown
→ room lights unresolvable (cold or empty)     .unknown
→ selector returns nil                         .noMatchingArea
→ otherwise                    .available(areaName: the SELECTED area)
```

`.noArea` is never used for a bridge that has areas belonging to other rooms.

### Consumers migrated
`findEntertainmentConfig` (room-shaped; the bridge-only convenience is **gone**),
`refreshEntertainmentConfigs`, `activeEntertainmentConfig(for:)`, `entertainmentAvailability`,
Composer start (`startCompositionMode`), all three Studio Entertainment starts (strobe / party /
thunderstorm — each warms its own cache rather than trusting a UI surface to have done it),
spatial-position resolution, `tryStartEntertainment` (now takes the already-selected config),
the Composer directional gate, the spatial minimap, `recomputeSpatialPositions`, and the
area-builder callback in `ComposerLayerSheet`.

`entertainmentStartPlan(for:)` is the single selection per start attempt: the config ID handed
to `startSession`, the channel IDs driving the render loop and the spatial positions now
provably describe the same area.

### Three enabling correctness fixes (Brian approved; scope-bounded, no other adjacent cleanup)
1. **Network failure ≠ "no area."** A configs fetch that throws or fails to decode no longer
   marks the bridge fetched. `EntertainmentConfigManager.fetchConfigs` now **throws** on a
   decode failure instead of returning `[]`, so network failure / decode failure / a genuinely
   empty response stay distinguishable.
2. **Unstreamable configs open no session.** Selection and channel validation happen *before*
   any client is created. The old order opened the session and checked `channelIDs.isEmpty`
   afterwards, leaving a live client parked in `studioEntClients` and the configuration left
   `action=start` on the bridge.
3. **`UInt8(channel.id)` no longer traps.** `validatedChannelIDs` uses `UInt8(exactly:)` and
   refuses the whole config rather than streaming it partially — a partial stream would light
   half an area and would also break the index alignment
   `computeSpatialPositionsForEntertainment` relies on. All four conversion sites migrated.

### Tests added (57, all shipped in the same commit as the fix)
Existing files extended — no new test file, no pbxproj churn.

- `HueHomeTests/EntertainmentAvailabilityTests.swift` → new `EntertainmentAreaSelectorTests`
  (41 with the existing enum tests): the mandatory positive exact match; wrong-first-config;
  order independence; unique largest subset; equal-subset ambiguity; dominant overlap;
  competing incomparable overlaps; equal overlaps cancelling; **lone whole-house area refused**;
  lone contained partial area selected; no overlap; empty room set; the
  service→device→light join built from raw `/resource/entertainment` JSON + `HueLight.owner`
  (never a pre-resolved fake map); entertainment rids proven not to be light rids; stale member
  ignored; multi-light device determinism; malformed payload; duplicate-equivalent areas
  streaming, agreeing in either order and not manufacturing a contest; repeated config ID;
  `validatedChannelIDs` for 0/255/−1/256/empty/duplicate/one-bad-channel; unstreamable area
  never selected; a valid duplicate beating an unusable lower-ID twin; preferred ID inside the
  group honoured, for another room rejected, naming nothing rejected, unstreamable falling back
  to its usable equivalent; two rooms one bridge; positions resolving through the same map.
- `HueHomeTests/EntertainmentRobustnessTests.swift` → new `EntertainmentRoomSelectionTests`
  (21): the four availability states incl. `.noMatchingArea` and unusable-channel areas;
  first-fetch failure staying `.unknown`; transient failure preserving last-known-good; a
  failure on one bridge not disturbing another; **membership retried by an ordinary non-forced
  warm**, and the inverse for configs; a successfully-empty membership treated as a verdict;
  availability and selection issuing zero GETs warm *and* cold; each room on a shared bridge
  selecting its own area; a single correctly-mapped area still streaming; caches staying
  bridge-scoped under identical room/config IDs; **one selection per start** (the activated
  config ID equals the plan's, and the other room's area is never touched); the **cold-cache
  Studio path** (bridge lists the wrong room's area first, card tapped with no Composer or
  transport menu opened); an unstreamable area opening no session, parking no client, claiming
  no ownership; and Packet 1a's same-bridge REST block still refusing.

DEBUG seams added alongside Packet 1a's: `testSeedEntertainmentCaches`,
`testEntertainmentMembership`, `testEntertainmentStartPlan`, `testHasEntertainmentClient`.
`EntertainmentSpyClient` gained `stubEntertainmentJSON`, `stubLights`, a `fetchLights()`
override, per-endpoint failure switches and GET/fetch recorders. No mutable ownership or cache
state is exposed publicly in production for tests.

### Validation
- Narrow: `EntertainmentAreaSelectorTests` + `EntertainmentAvailabilityTests` → 41 passed;
  `EntertainmentRoomSelectionTests` → 21 passed.
- Full suite: **907 passed, 0 failed, 0 skipped** — `xcodebuild test -project HueHome.xcodeproj
  -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  -resultBundlePath /tmp/ComposerPacket1B.xcresult`, verified with
  `xcrun xcresulttool get test-results summary` (`"result": "Passed"`), not inferred from exit
  text. Packet 1a's baseline was 850; the 57 new tests account for the delta.
- `scripts/hardening_guards.sh`: all guards passed. `git diff --check`: clean.
- Files touched: `EntertainmentConfigManager.swift`, `UnifiedOrchestrator.swift`,
  `ComposerLayerSheet.swift`, `EntertainmentAvailabilityTests.swift`,
  `EntertainmentRobustnessTests.swift`. No pbxproj, no version bump, no unrelated files.
- **No hardware validation.** Simulator unit tests only — nothing here proves anything about
  physical Hue behaviour.

### Gotchas
- **REST compositions in rooms with no safe area match now lose entertainment-derived spatial
  positions** and fall back to index order. Previously they borrowed whichever config the bridge
  listed first — the same defect, on the REST path. Correct, but visible: do not mistake it for
  a regression.
- Session teardown still drops the bridge's inventory + fetched marker (and now the membership
  map). That is deliberate: it is what makes an area edited in the Hue app take effect on the
  next start rather than only after a relaunch.
- The Composer advanced-controls sheet now warms on `vm.selectedRoom?.id`. Without it the
  directional gate answers from a cold cache and tells a user with an area to create one.
- `EntertainmentAreasView`'s rename/delete still do not invalidate the orchestrator caches. The
  forced warm on every start covers it in practice; a stale name can briefly show in the
  transport menu. Not in this packet's scope.
- Packet 1a's gotchas all still stand (global `activeStudioTask`; compositions storing their
  client in `studioEntClients`; Entertainment compositions never writing `compositionRuntimes`).

### Hardware checks still pending (Brian)
Appended to `docs/ios/master-on-device-checklist.md` as section **O**. Packet 1a's seven checks
remain open and are **not** superseded.

### Non-goals (explicitly not in this branch)
Light-overlap REST/Entertainment coexistence; any relaxation of Packet 1a's same-bridge REST
block; `canAcquireEntertainment` changes; BridgeSessionArbiter; per-bridge REST scheduler;
global `activeStudioTask` redesign; `studioEntClients` rename; third-party Entertainment
takeover; All-Day arbitration; bridge-stored cleanup; Composer schema/version envelope;
compiler; render-state extraction; OKLab/mirek; unified Create + Advanced editor; new effects,
layers, modulation or timelines; Android; telemetry; build/marketing-version changes.

- **Packet 1a's same-bridge REST block is unchanged.** `canAcquireEntertainment` was not
  touched; a REST composition on a bridge still refuses Entertainment on that bridge, and
  `testARESTCompositionOnTheSameBridgeStillBlocksEntertainment` pins it.
- **Overlap-aware REST/Entertainment coexistence remains deferred.** Packet 1b makes membership
  selection trustworthy; it does not yet spend that trust on letting the two transports share a
  bridge.

### Rollback
```bash
git checkout main                                       # never merged; main is untouched
git branch -D fix/composer-entertainment-area-selection # discard the work entirely
# or, to inspect the pre-packet tree:
git checkout checkpoint/pre-composer-packet-1b
```
No data-format changes; nothing persisted changed shape.

---

## 2026-08-02 - [Claude] Composer 2 / Phase 0 / Packet 1a — Entertainment ownership correctness

### Branch
- `fix/composer-entertainment-ownership`, cut from `main` (79b5e9b, build 46).
- Rollback tag: `checkpoint/pre-composer-packet-1a`.
- **No version or build bump** — not an install build. PR opened, not merged.

### Why this shape (packet split)
Brian asked for a review of the Packet 1 implementation prompt before it was handed to an
implementing agent. Two claims in it did not survive verification against current `main`:

1. The prompt told the agent to stop if the architecture review was absent from `main` — but
   the review only ever existed on `docs/composer2-architecture-review` (PR #49). Taken
   literally, the packet would have halted having done nothing.
2. The prompt specified matching room **light service rids** against each Entertainment
   config's `channel.lightServiceIDs`. That field is misnamed: `EntertainmentConfigManager`
   fills it from `members[].service.rid`, which is an **`entertainment` service rid**
   (`EntertainmentConfigBuilderView` POSTs `"rtype": "entertainment"`, and
   `resolveEntertainmentLightPositions` already maps entertainment-rid → owner device →
   light rid via two fetches). Matching them directly yields the empty set for every room on
   every bridge — the selector would have returned nil always, disabling Entertainment
   app-wide, silently. Every test the prompt mandated would still have passed, because they
   were specified against the same wrong assumption.

Brian's calls: split the packet (1a = corrections 1 + 3 now; 1b = area selection, once the
membership mapping exists), and for 1a block Entertainment whenever any REST composition is
live on the **same bridge** — remove only the global cross-bridge lockout.

### Did
- **Per-bridge Entertainment gate** (`UnifiedOrchestrator.swift`). The acquisition condition
  read `compositionEntRoomByBridge[bridgeID] == nil && compositionRuntimes.isEmpty`. The
  second conjunct was global, so one REST composition anywhere demoted every later
  Entertainment start on every bridge to REST — directly under a comment claiming "one
  session per bridge — multiple bridges can run simultaneously". Both conjuncts are now
  bridge-scoped behind `canAcquireEntertainment(onBridge:)`. `CompositionRuntime` gained a
  `bridgeID` recorded at start: `runtime.api` is a `HueAPIClient` and carries no bridge
  identity, and re-deriving from `allRooms` at read time can go stale mid-composition.
- **User-confirmed Studio handoff** (`UnifiedOrchestrator`, `StudioViewModel`, `StudioView`).
  `startStudioMode` stopped whatever Entertainment client sat on the target bridge without
  checking ownership and cleared no composition bookkeeping, so a composition's 25 fps loop
  kept rendering into a disconnected client — `send` no-ops, `isTerminallyFailed` never
  trips, so the REST failover never fired either. Silent, permanent, relaunch-only recovery.
  Now: the orchestrator answers `compositionOwningEntertainment(onBridge:)` (ownership maps
  stay private); `StudioViewModel` raises `entertainmentHandoffPrompt` **above all of
  `apply()`'s teardown** and owns the copy; `StudioView` mounts one
  `EntertainmentHandoffAlert` modifier following the `StudioMusicWiring` precedent (body is
  at the type-checker ceiling — extend the modifier, never the chain).
- Confirm stops through the official path (`stopEffect` → `stopCompositionMode`, or
  `stopCompositionMode` directly when Studio holds no registry entry) and only then replays
  the original request. The prompt is consumed before the first `await`, so repeat taps
  cannot double-start or double-stop. Cancel has nothing to undo by construction.
- Composition → composition stays promptless; other-bridge and free-bridge taps start
  normally.

### Tests added (14, all shipped in the same commit as their fix)
`HueHomeTests/MultiBridgeRoutingTests.swift` — extended rather than a new file, to avoid
pbxproj churn (the main target uses explicit file references; only widget/watch use
synchronized groups).

- Gate (6): cross-bridge independence; same-bridge REST block; same-bridge Entertainment
  exclusivity; idle bridge acquirable; teardown isolation (stopping A leaves B's ownership);
  per-runtime bridge identity.
- Handoff (8): conflict raised before any mutation (asserted against ownership, transport,
  Studio registry **and** bridge traffic); mutation-free cancel; confirm ordering with
  ownership genuinely released and Studio started after; repeat confirm/cancel idempotence;
  stray-dismissal safety; promptless same-surface replacement; promptless other-bridge start;
  promptless free-bridge start.

DEBUG seams added alongside `injectForTesting`: `testStageRESTComposition`,
`testStageEntertainmentOwner`, `testCanAcquireEntertainment`, `testCompositionRuntimeBridges`.

### Validation
- Full suite: **850 passed, 0 failed, 0 skipped** — `xcodebuild test -project
  HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17
  Pro'`, verified with `xcresulttool get test-results summary` (not inferred from exit text).
- `scripts/hardening_guards.sh`: all guards passed. `git diff --check`: clean.
- Files touched: `UnifiedOrchestrator.swift`, `StudioViewModel.swift`, `StudioView.swift`,
  `MultiBridgeRoutingTests.swift`. No pbxproj, no version bump, no unrelated files.
- **No hardware validation.** Simulator unit tests only.

### Hardware checks still pending (Brian)
1. Two bridges: REST composition on A, then an Entertainment composition on B → B must stay
   Entertainment (this is the lockout fix).
2. Same bridge: REST composition running → a second room's Entertainment start must demote
   to REST cleanly (this is the deliberate 1a block, not a bug).
3. Studio over a running composition → prompt appears **before** any light changes.
4. Cancel → composition continues with no visible hiccup.
5. Confirm → composition stops cleanly, Studio starts, no frozen UI or orphaned light motion.
6. Rapid alternating cancel/confirm across cards → no double starts, stuck sessions, or
   stale ownership.
7. Record bridge firmware, app build, rooms involved, and Entertainment Area membership.

### Gotchas
- `startStudioMode` still cancels a single global `activeStudioTask`, so starting Studio on
  bridge B stops Studio on bridge A. Pre-existing, out of scope, **not** caused by this
  packet — flagged so it is not mistaken for a regression.
- Compositions store their DTLS client in `studioEntClients` — the same dict Studio tears
  down from. That aliasing is the mechanism of the freeze; 1a fixes it by ownership check
  only, deliberately leaving the naming/structure alone to keep the diff auditable.
- An Entertainment composition never writes `compositionRuntimes` (the start path returns
  before the runtime insert), so `compositionRuntimes` is REST-only. The same-bridge block
  therefore reads exactly as intended.
- DEVLOG adjacency: PR #49 (`docs/composer2-architecture-review`) inserts its entry at the
  same position. Whichever merges second will conflict here — keep both entries.

### Deviations from the packet
- Correction 2 (Entertainment-area selection) is **not** in this branch; deferred to packet
  1b for the reason above. Before 1b is handed off, its prompt must (a) match on light rids
  resolved through the entertainment→device→light map, (b) include a positive "a correct
  config matches" test guarding against an always-nil selector, and (c) decide the cache
  shape — `entertainmentAvailability` is synchronous and reads a single-config-per-bridge
  cache, so room-aware selection needs `[String: [EntertainmentConfig]]` plus the ent→light
  map cached during the existing warm, with the selector extracted as a pure function shared
  by startup and availability.

### Rollback
```bash
git checkout main                                  # never merged; main is untouched
git branch -D fix/composer-entertainment-ownership # discard the work entirely
# or, to inspect the pre-packet tree:
git checkout checkpoint/pre-composer-packet-1a
```

---

## 2026-08-02 - [Claude] Composer 2 review round 2 — ChatGPT cross-review amendments + PR 49 scope cleanup (docs only)

### Branch
- `docs/composer2-architecture-review` (PR #49) — docs only, no source changes, no version
  bump, nothing to install.

### Did
- Reviewed PR #49 for cohesion at Brian's request, against six requirements ChatGPT sent
  back from its cross-review. The document held up internally (all D/N/K/risk/phase
  cross-references resolve); four of the six requirements were unmet or ambiguous.
- Cleaned PR scope: `origin/main` was still at build 45, so the validated build-46
  mixer-tray commit (79b5e9b) rode along in the PR diff — contradicting the PR's own
  "docs only" claim. Fast-forward pushed `origin/main` to 79b5e9b (Brian's install-branch
  convention); the PR is now genuinely two doc files.
- Amended `docs/ios/composer2-architecture-review-2026-08-01.md` on all six points:
  1. Ent-config selection now requires an exact/unambiguous best match (subset preferred,
     unique max-overlap else, tie/near-tie → nil → REST) — not mere channel intersection
     (Part L, Phase 0-3, Part H).
  2. Studio-over-composition is a user-confirmed handoff — confirmation prompt naming the
     running look *before* teardown, never a silent stop or after-the-fact toast (Part L,
     Phase 0-2, Part H; the same-surface card swap stays promptless as the one deliberate
     exception).
  3. Explicit rule: every Phase 0 fix lands with its regression test in the same commit.
  4. Unified creation experience added explicitly: Create + Advanced settings become one
     continuous editor via `ComposerControlCatalog` progressive disclosure, no separate
     modals (Part F new bullet + named Phase 7 slice).
  5. Third-party sessions yielded to by default: launch/foreground cleanup never touches or
     prompts about foreign sessions; the K1 take-over prompt fires only on an explicit
     playback action that conflicts (Phase 0-9, K1).
  6. Rolling >20-light REST strategy got its defined contract: round-robin fairness within
     one bounded rotation, frame-age limit (older than one rotation → dropped, never sent
     late), generation-checked cancellation between subsets, `TransportVocabulary`
     degradation copy (K6, Phase 2).

### Working
- Suite untouched (no source changes).

### Left
- Brian: Part K decisions (K1–K6) still open — unchanged ask from round 1.
- Feed the amended doc back to ChatGPT; merging PR #49 remains Brian's call.

### Validation
- N/A (docs only). `gh pr view 49 --json files` now lists only DEVLOG.md + the review doc.

### Gotchas
- The PR-scope confusion was purely a stale-remote artifact: the branch was cut from local
  main. Push main before opening docs-only PRs, or GitHub charges the branch with every
  unpushed main commit.

---

## 2026-08-01 - [Claude] Composer 2 architecture review — ChatGPT baseline verified against main (docs only)

### Branch
- `main` — docs only, no source changes, no version bump, nothing to install.

### Did
- Brian brought a "Composer 2" architecture/delivery plan authored by ChatGPT (document →
  compiler → planner → arbiter → scheduler, 21 slices, ~41 candidate risks) and asked for an
  independent deep-dive to compare against it. Ran three exhaustive audits of main @ 79b5e9b
  (Composer core; transport/orchestration; docs/UI/tests) and hand-re-verified the four most
  load-bearing findings in source.
- Wrote `docs/ios/composer2-architecture-review-2026-08-01.md`: 16 deltas from the baseline +
  full A–L response (verified risk table with file:line evidence, new-risk list N1–N16,
  revised phase plan, edge-case matrix, first implementation packet).
- Headline verdicts: the baseline's end-state architecture is endorsed, but ~9 of its risks
  are already fixed and test-locked on main (tap tempo, "dead" controls, persistence data
  loss, built-in reset, generation tautology, per-source audio…), so the right shape is a
  strangler hardening of the existing engine, NOT a parallel second engine behind a flag.
  The live emergencies are ownership bugs the baseline sequences last: wrong-room streaming
  (`findEntertainmentConfig` returns `configs.first`, no room filter), `startStudioMode`
  orphaning a Composer DTLS stream (silent permanent freeze), the global
  `compositionRuntimes.isEmpty` Entertainment lockout, the `CG_` purge nuking sibling rooms,
  one global latest-wins RestSender across all bridges, unconsented eviction of third-party
  Entertainment sessions, All-Day scenes stomping running compositions, and bridge-stored
  animations being unstoppable after a relaunch.

### Working
- Suite untouched (no source changes); review doc is self-contained with file:line cites.

### Left
- Brian: read Part K of the review — six product decisions (third-party session eviction
  consent, local diagnostics vs privacy label, true blackout on REST, the bridge-stored
  dead-slider editor call, external-controller yield policy, >20-light REST strategy).
- Feed the review to ChatGPT for the planned second-reviewer comparison.
- If approved, the first implementation packet is Part L: three surgical entertainment-
  ownership fixes in UnifiedOrchestrator only (per-bridge gate, arbitrated startStudioMode,
  room-filtered ent-config selection) + MultiBridgeRoutingTests-style units.

### Validation
- N/A (docs only). Every risk status in the review cites current file:line; spot-check rows
  against source to audit.

### Gotchas
- ChatGPT's prompt names files that don't exist on main (CompositionMicCapture.swift,
  ComposerViewModel) — its snapshot predates the audio-engine split and the Round-4 revamp;
  treat its §6 risk list as historical, the review's Part B table as current.
- The composition REST path never uses BridgeCommandGate — the ~10 cmd/s budget documented in
  that file applies app-wide but is only enforced on bulk/Studio paths. Worth remembering
  before trusting any cadence number printed by the mixer tray (telemetry currently stamps
  dueAt == sentAt, lag is always 0 by construction).

---

## 2026-07-22 - [Claude] ROUND 4b — tour×deep-link dismissal + minimal staleness honesty (build 45)

### Branch
- `main` (continues the build-44 round; same rollback tag `checkpoint/full-audit-2026-07-22`)

### Did
- **Tour × deep link (Brian's call: user intent wins).** `DeepLinkCoordinator.tourSurfaceUp`
  (mirrored by the cover's onAppear/onDisappear); `WelcomeTourWiring` dismisses the tour on
  any `openToken` bump WITHOUT stamping (kill-mid-tour rule — full tour returns next clean
  launch), and both dropped-cover retry guards now require `openToken == 0` (presentation
  only ever begins at token 0, so non-zero means a link arrived since — the retry can never
  re-present over a link). `MainTabView.consumeDeepLink` waits ~650ms when the tour surface
  is up so invite/share sheets never present into a still-dismissing fullScreenCover (the
  drop-and-poison class).
- **Staleness honesty (Brian's call: minimal text-only).** `HueHomeWidgetEntryView` (the
  single all-faces dispatch root) dims stale entries to 0.72; the small face's
  paired-but-empty state shows "Open ChromaGlow to refresh" instead of asserting
  "0 on / All lights off" over no data (medium/large assert nothing — root dimming covers
  them; complications untouched by decision). Watch: `WatchStore.lastSyncedAt` (@Published,
  loaded from `hue_widget_updated_at`, stamped on cache save + applicationContext receipt)
  drives one "Updated Xm ago" footer line past 30 minutes.

### Working
- Suite green (xcresulttool-verified), hardening guards green. No new files, no pbxproj edits.

### Left
- Brian device checks (added to his gate list): Siri command mid-tour → tour dismisses,
  Studio opens, effect starts, tour re-presents next clean launch; unreachable-bridge widget
  dims + empty state reads "Open ChromaGlow to refresh"; watch shows "Updated Xm ago" after
  >30 min without phone contact and clears on next sync.
- Remaining report-only items unchanged: notification 64-cap warning, scene-move breaking
  system-persisted Siri/Control-Center configs, Shazam wall-clock clear, Spotify keychain
  poll-read cache, full staleness design (v1.2 candidate per decision).

### Validation
- Full suite via `-resultBundlePath` + xcresulttool (no piped verdicts); guards pass.

### Gotchas
- The tour retry's `openToken == 0` guards are load-bearing — without them the 500ms retry
  window could re-present the tour on top of a routed deep link.
- Widget staleness dimming lives at the ONE dispatch root; per-face styling would re-open
  the full-design option Brian explicitly deferred.

## 2026-07-22 - [Claude] FULL-APP AUDIT ROUND — deferred-LOW ledger closed, 4-lane fresh sweep, 13-page tour + What's New (build 44)

### Branch
- `main` (rollback tag `checkpoint/full-audit-2026-07-22`; 30 shippable commits)

### Did
- **Part A — the §8.4 deferred-LOW round** (per-finding designs re-verified against build 43):
  L-02/L-28 (pure `bridgeBodyVerdict` + `decodeV2`; fatal 2xx bodies throw `bridgeError` so
  optimistic rollbacks fire, partial log-only, fixtures at BOTH choke points because
  TestableAPIClient bypasses execute()); L-03 eager sessions; L-04 scene-capacity gate dropped;
  L-12 `decodePSK` 32-hex guard; L-13 dead `HueSSEService` class deleted (models kept, NO
  pbxproj edit — the audit's assumption was wrong) + AGENTS.md corrected; L-16 software half
  (`validatedManualHost`: strict IPv4 — Darwin inet_pton accepts leading zeros, we guard —
  IPv6, RFC-1123; inline sheet error; NO private-range block, VPN/CGNAT homes are real);
  L-29 ghost-ref pruning against the light cache (ref order = M-04; zero fetches pinned by
  ComposerFetchPathParityTests — the first design fetched and the suite caught it); L-47
  full-array toggle + observation test; the dead Sync-engine stack DELETED with `RestSender`
  extracted verbatim to `Core/Network/` (closes L-05 by deletion; `add_full_audit_files.rb`
  registers/prunes idempotently). L-06/L-11 verified ALREADY FIXED (ledgered); L-43 WONT-FIX
  (EffectEngine actor is dead code — deletion candidate; `EffectLoops.setAll` must survive).
  run_tests.sh: real scheme, simulator default, xcresult verdict (grep-on-piped-logs killed).
- **Part B — Welcome Tour**: page 13 `tour.music` (ownerOnly — guests have zero music entry
  points; copy dodges "Shazam"/"Spotify"/any "hue" substring), MusicArt illustration (8s
  story, ≥0.75s periods, Reduce-Motion still at t=4.6), copy refresh (scenes previews /
  66 looks on studio / Brightness Shape on composer), and the versioned **What's New**:
  `addedInVersion` (defaulted var!), `catalogVersion = 2`, `whatsNewPages` +
  `shouldPresentWhatsNew` (`max(1,·)` legacy fold), `castchroma.seenTourVersion` stamped on
  both finishes, guest-empty presents-and-stamps NOTHING, deep-link parity, same
  dropped-cover retry. `shouldAutoPresent` + its truth table byte-identical.
- **Part C — 4-lane fresh sweep** (cross-feature seams / state machines / optimization /
  never-audited seams), every finding re-verified in code before fixing:
  · **Music lifecycle**: session survived Forget-All (mic hot on the pairing splash), the
    guest-only flip, and demo exit (Sample Track's phantom BPM grid suppressed the mic for
    every `.beat` look on real lights); paired demo-exit also left a DEAD APP until relaunch
    (`.hueDemoExited` never reconfigured) — receiver now rebuilds configure/loadAll/SSE.
  · **Automations**: willPresent/didReceive each got ONE delivery channel (stale pending key
    replayed last night's Sleep at 7am; tap-while-backgrounded double-fired); `scheduleAll`
    at launch (restore/migration + late permission left schedules silently dead); honest
    "runs when you tap it or while the app is open" copy in the create sheet.
  · **All Day Scenes**: solar base was device-calendar startOfDay + anchor offset — errors
    cancel only at home; traveling INVERTED day/night (NY home viewed from Tokyo), DST days
    ±1h. Now UTC-midnight-of-anchor-day + UT seconds; `AllDayCurve` internal for the
    NOAA-referenced NYC-solstice regression test.
  · **Watch/widget honesty**: all four widget intents + watch toggle/recall gate their
    optimistic writes on a 2xx (BridgeWriter stays fire-and-forget, now returns Bool);
    watch bridge-targeted commands no longer fall back to ANOTHER bridge's credentials;
    empty-rooms pickup loop exits on cancellation.
  · **Widget publish**: diff-gated (SSE quiet-gaps re-published byte-identical snapshots +
    watch push + Siri re-donation for hours during bridge-side dynamic scenes); STRUCTURAL
    changes reload timelines (a revocation-pruned room list sat stale for hours); reload is
    main-app-only (the widget extension shares the write path — refresh-loop hazard).
  · **Music/audio edges**: BeatClock pin no longer starves the service hold (mic spun up
    during any pin >10s; unpin fell to .audio) + high-BPM seeks re-anchor (threshold now
    scales with interval); Shazam `stop()` idempotent (the double-stop rail defeat — F3
    deafness resurrected); Spotify paused-poll tier (the 10s tier keyed on a condition that
    could never be true), dead-grant stops the loop, single-flight token refresh (rotation
    made concurrent refreshes unlink a HEALTHY grant); audio tempo task can't publish stale
    over stopEngine's zeros + estimator reset chains behind its predecessor.
  · **Scenes/colors**: RoomDetail starring used the order-destroying Set round-trip
    (Dashboard pills scrambled); RoomDetail deletes now scrub favorites/usage/provenance
    like ScenesTab; SavedColorStore capped at 200 + clamps at the application boundary
    (Transferable payloads bypass the clamping init via Codable).
  · **Previews**: LookPreviewStrip got its missing idle tier (12fps at rest on every deck
    card → 4fps; running cards keep 12); EnvelopeStrip curve hoisted out of the tick;
    Create-hero border sweep now consumes `\.isTabActive`; Apple Music artwork request
    600→128px (sole consumer is a 32×32 k-means).
  · **Deep links**: a route to a deleted room cleared `pendingGroupID` never — it suppressed
    the Welcome Tour on every launch.
  · **Harmony**: `vm.restoredHarmonyRule = .none` assigned `Optional.none` (nil), not the
    sentinel CASE — from an already-nil state the chip-clear onChange never fired and pad
    drags re-imposed the rule over album colors (the compiler warning was pointing at it).
- **Part D**: DEVLOG snapshot un-staled (was 2026-07-17/build 33); CHANGELOG gets a 1.0.0
  summary + "DEVLOG is canonical" pointer; audit doc §9 Round-4 ledger; `.gitignore` covers
  the local `ChromaGlow/` + `ChromaGlow.xcodeproj/` husks (untracked xcuserdata-only relics
  of a rename experiment — NOT deleted, Brian's call); build 43→44 (all 12 entries).

### Working
- Suite green per batch, 833/833 at final state, verified via xcresulttool on the .xcresult
  every time (one run's piped exit code lied — tail swallowed a 3-failure result; the
  xcresult caught it, and two of those failures were MY L-29 design violating the
  zero-fetch contract, redesigned against the cache).
- `Scripts/hardening_guards.sh` green after every copy-adjacent change.

### Left
- **Report-only findings** (deliberate, need Brian/product calls): mid-tour Siri/deep-link
  arrival can start lights behind the tour cover + the photosensitivity-alert covered-tab
  variant (needs a small design: defer routing while the cover is up); widget/watch
  staleness plumbing exists but is unrendered (`isStale`, `updatedAt` — needs a designed
  badge across faces); notification 64-request cap (~9 daily automations) unwarned;
  Shazam wall-clock track-clear (frozen Now Playing if the engine dies silently);
  Spotify keychain read per poll (cache-in-memory nicety); scene-move breaks Siri/Control
  Center scene configurations (system-persisted ids — needs name+room re-resolution);
  BeatClock 2Hz bpm observability (inherent); LookPreviewCanvas 4Hz idle tick is the
  designed "living cards" ambience (leave). The `meta:` cache-key separator WONT-FIX.
- L-14/L-15/L-17 pairing bundle + L-48..L-51/L-53 + Android items — unchanged owners.
- Brian's device gates: below.

### Validation
- Full suite per batch (build 809 → 833 tests across the round), xcresulttool-verified;
  hardening guards; copy bounds verified against all 16 TutorialCatalogTests invariants
  before the suite ever ran.

### Gotchas
- `ComposerFetchPathParityTests` pins zone resolution to ZERO fetches — any L-29-style
  pruning must ride `cachedRawLights`, never a fetch.
- The tour's trademark test is substring-based ("hues" fails); What's-New must stamp
  NOTHING when the filtered page set is empty or the state machine wedges for guests.
- `TutorialPage.addedInVersion` must stay a defaulted `var` — a defaulted `let` drops out
  of the memberwise init and every v1 page literal stops compiling.
- Widget-extension code paths must never call `WidgetCenter.reloadAllTimelines()` — the
  shared `WidgetDataStore.write` takes `reloadOnStructureChange:` and only the main app
  passes true.

## 2026-07-21 - [Claude] MUSIC R9 — full audit of the music integration: 11 findings, 8 fix commits (build 43)

### Branch
- `main` (rollback tag: `checkpoint/music-audit-2026-07-21`, pushed — revert =
  `git reset --hard checkpoint/music-audit-2026-07-21`)

### Did
Brian asked for a world-expert audit of the whole music surface (sources, tempo lookup,
BeatClock drive, Now Playing UI, album colors, Composer apply/unapply edges) — fix what's
found. Every music-layer file read end-to-end + three parallel exploration sweeps,
cross-verified. **The apply/Revert/Save/Stop box lifecycle is structurally sound**; the
defects were lifecycle races, clock-authority edges, and "apply does nothing / apply
clobbers" holes. 11 findings, 8 fix commits (each suite-green):

1. **BeatClock (F1/F5):** `isServiceDriven` is now stale-aware (a dead drive stops
   claiming the clock after 10s — before, the stale flag suppressed the very mic demand
   whose `ingest` self-heal was the only release path: a deadlock); the serviceHold
   phase nudge now respects a pin; `unpin()` is stale-aware.
2. **Coordinator (F1/F4):** track change now calls `endServiceDrive()` when it nils
   tempo (the old track's grid drove FOREVER if the new track's tempo never resolved);
   `activate()` gained liveness guards — a failed start no longer tears down a NEWER
   session, a superseded start unwinds instead of running as a zombie.
3. **Shazam (F3):** demand handoff serialized via a static release rail (the Set-not-
   refcount `.shazamID` release landed AFTER a re-activation's acquire → deterministic
   deafness on re-pick); stop-during-start no longer installs the tap/session.
4. **AppleMusic/Spotify (F9):** block-based NC observers now removed by token —
   `removeObserver(self)` was a no-op for them, leaking one pair per activation.
5. **REST burst (F2 — the big one):** `forceRESTBurstUntil` had 8 writers and ZERO
   readers since birth (commit `6d4e105`'s doc describes the scheduler read; it never
   shipped — pickaxe-proven). The frame[0] delta gate could skip a palette edit forever
   on a static look. `runCompositionScheduler` now sends during the burst window.
6. **Album colors (F6/F7/F10):** clamps to the ROOM gamut (was raw gamut-C); clears the
   harmony chip via a `.none` sentinel + one-shot echo guard (a lit rule re-imposed
   itself on the next pad drag, overwriting album color2/3 — and the chip's `.none`
   onChange branch is destructive, hence the guard); the restore onChange is symmetric
   now (rule-less presets clear the stale chip too); paint badge hidden on
   bridge-stored transport (no live loop reads the box there).
7. **Spotify auth (F8):** 401 retry FORCES a refresh (was re-serving the same cached
   token → guaranteed second 401); a definitively-rejected refresh grant unlinks + one
   interactive retry in start() (was: permanently un-pickable); interactive login gated
   out of background polls; PKCE `state` param + callback verification; web-auth
   session retained; picker long-press → "Unlink Spotify".
8. **Picker/Dashboard (F11):** one activation at a time (double-tap fed the C2/C3
   races); the Dashboard strip's whole-bar tap now opens the picker (was inert).

### Working
- Suite **807/807** per commit (xcresulttool-verified; 799 → +4 clock, +3 coordinator,
  +1 Spotify state); `Scripts/hardening_guards.sh` green; build 43 across all 12
  pbxproj entries.

### Left — Brian device gate (build 43)
- The standing build-40/41/42 music checklist PLUS: album colors on a non-gamut-C room
  land correctly; album tap then pad-drag KEEPS the album colors (chip cleared); album
  tap on a static look repaints within ~1s over Room mode; tap-pin during a track, then
  unpin → returns to Music; pick Auto-Detect, re-pick it fast → still hears (the old
  deterministic deafness); play a track, then change to an obscure/unknown song →
  lights drop to audio-follow instead of pulsing the old grid forever; Spotify:
  long-press row → Unlink, relink works.
- GetSongBPM key rotation still open (pre-existing).

### Gotchas
- The audit's report-only items (no code): bridge-stored transport shows the whole live
  editor whose sliders are equally dead (product call needed); the bar (and album
  apply) is suppressed on ≤700pt while an effect runs (R2 design choice); album palette
  is one-shot by design; no GetSongBPM negative caching/429 backoff (bounded by
  forever-cache); no Revert on starter drafts; Shazam advertises `.artwork` but serves
  URL-only.
- `git log -S` (pickaxe) on a symbol with writers-but-no-reader is the fastest way to
  prove a consumer never existed vs was refactored away.
- Block-based `addObserver(forName:)` tokens MUST be stored and removed by token;
  `removeObserver(self)` silently no-ops. Third occurrence of this class in the repo —
  grep for it when auditing new observers.

---

## 2026-08-01 - [Claude] The mixer tray's ~200pt dead band — R8c's double-count, closed for the tray (build 46)

### Branch
- `main` (rollback tag `checkpoint/mixer-tray-reclaim-band`)

### Did
- **Brian's report:** tapping Composer's **+ Create** brings up the mixer tray, but it stops
  well short of the "Nothing playing" card — deck cards show through the gap and the tray's
  own controls are cramped. Annotated screenshot: *"have the menu take up this space as well"*,
  ask = **same position, just larger** (top edge fixed, grow downward).
- **Root cause: the exact double-count R8c fixed for the deck spacer, missed on the tray.**
  The music bar rides a bottom `safeAreaInset` on all of `StudioView`
  (`StudioMusicWiring`), which already floors Studio's content at the bar's top edge and
  already clears the floating `HueTabBar` via the bar's own `.padding(.bottom, 70)`. The tray
  was then padded *again* by `studioTabBarClearance(bottomInset: geo.safeAreaInsets.bottom)` —
  and that `bottomInset` is the whole music-bar band plus the home indicator, so
  `max(72, 56 + inset)` resolved to ~200pt of padding pushing the tray off a floor it was
  already sitting on. Measured from Brian's screenshots at ~200–240pt (scale pinned by
  Candle's derived tray height, 362pt → 550px).
- **Fix:** `MixerTrayMetrics.bottomClearance(bottomInset:barMounted:)` — `HueSpacing.sm` (8pt,
  matching the tray's own side inset) when the bar is mounted, the full `tabBarClearance` when
  it is suppressed. `studioTabBarClearance` moved off `StudioView` onto `MixerTrayMetrics` so
  it is finally testable.
- **Keeping the top edge fixed:** `resolvedMixerHeight` adds `reclaimed` (= old clearance −
  new clearance) **after** both existing caps rather than rewriting them. Those caps are
  known-good on device, so leaving them alone and appending the reclaim makes the top edge
  provably invariant in both the half and dragged-up states while the bottom lands 8pt above
  the music card — and needs no new assumption about what `proxy.size.height` means under a
  safeAreaInset. Candle's tray ~362 → ~570pt; the composition tray ~492 → ~700pt.
- **De-duplicated the suppression predicate:** `StudioMusicWiring.barSuppressed(currentRoomEffect:)`
  is now the single source of truth; `suppressedForCompactMixer`, `studioBottomClearance`, and
  the new clearance all read it. Retires the "keep this in lockstep" comment that was guarding
  two hand-copied copies (a third was about to be added).
- New wiring stayed out of `StudioView.body` (type-checker ceiling, AGENTS.md): the padding
  call site reads a `mixerBarMounted` computed property, not an inline ternary.

### Working
- Suite 836/836 (xcresulttool-verified, `result: Passed`, 0 failures); build 46.
- 3 new `MixerTrayMetricsTests`: the 72pt floor survives the move; a mounted bar reclaims the
  band; a suppressed bar owes the full figure at every inset (so `reclaimed` is exactly 0 and
  ≤700pt geometry is unchanged).

### Left
- **Brian device gate build 46:** Composer → + Create (top edge unmoved, bottom now at the
  music card, Hue+Saturation pad and the rows under it visible); Effects → Candle (Brightness /
  Flicker Rate / Base Color / `+2 MORE` all visible); drag the tray up; **with the tray up, tap
  the Now Playing card's play/pause and artwork** — they should respond, not collapse the tray.
- ≤700pt phones deliberately untouched (bar suppresses there, `reclaimed` = 0). If Brian sees
  the same gap on an SE, that path's floor is `MainTabView`'s 64pt clear inset — which R8b
  recorded as *not* reaching Studio's own `safeAreaInset` — so it needs measuring, not guessing.

### Gotchas
- The R8c rule applies to EVERY bottom-anchored Studio surface, not just spacers in the deck
  VStack: while the music bar is mounted, clearance is the bar's job. Anything that reads
  `safeAreaInsets.bottom` and adds it back as padding is double-counting the bar's whole band.
- When growing a bottom-anchored panel that must keep its top edge, add the delta *after* the
  existing caps. Rewriting the caps re-opens the question of what the proxy's size means under
  a safeAreaInset; appending the delta does not.

---

## 2026-07-21 - [Claude] MUSIC R8c — Composer "jumps back to Ambient" root-caused + the dead band above the bar (build 42)

### Branch
- `main` (continues under `checkpoint/music-picker-spotify-scroll`)

### Did
- **Brian's precise repro cracked the scroll bug:** it lives in the Composer deck's sectioned
  "All" view only — stacked PER-SECTION `LazyVGrid`s inside the non-lazy VStack each
  under-estimate their unmaterialized rows, the ScrollView believes a far shorter content
  height, and dragging past that phantom bottom clamps the offset back up — landing at
  ~Ambient every time. Collapsing chevrons hid it because header-only content estimates
  exactly. Fix: ONE `LazyVGrid` hosting every category as a `Section` (headers span the grid,
  collapse logic unchanged, laziness preserved). Rig-verified: deep-scroll through all demo
  sections holds, true bottom reachable and stable.
- **Dead band above the Now Playing bar:** the R2-era 80pt `Color.clear` tab-bar spacer
  double-counted once the bar's safeAreaInset (R8b) began clearing the tab bar itself.
  Replaced with `studioBottomClearance` — present ONLY while the bar is suppressed
  (≤700pt + running effect; condition in lockstep with
  `StudioMusicWiring.suppressedForCompactMixer`). Rig-verified: dots → bar → tab bar stack
  tight, extra row of deck real estate back.
- Also this round (pre-R8c): restored `GuestAccessModels.swift` after a stray `x` keystroke
  at char 0 broke Brian's device build (working-tree only, `git checkout --`).

### Working
- Suite 799/799 (xcresulttool-verified); guards green; build 42.

### Left
- **Brian device gate build 42:** Composer → All with every chevron OPEN → scroll to the very
  bottom (the exact repro that failed on 41); the tightened bottom stack; then the standing
  build-40/41 music checklist.
- GetSongBPM key rotation still open.

### Gotchas
- NEVER stack multiple lazy containers in one ScrollView pass — a lazy grid's height estimate
  for unmaterialized rows is wrong until visited, and the scroll clamps to the sum of wrong
  estimates. One lazy container, `Section`s inside.
- Any bottom-of-tab-page spacer must now account for the music bar's inset — clearance is the
  bar's job unless the bar is suppressed.

---

## 2026-07-21 - [Claude] MUSIC R8b — the bar was UNDER the tab bar: simulator-rig evidence round (build 41)

### Branch
- `main` (continues under the `checkpoint/music-picker-spotify-scroll` tag)

### Did
- **Brian reported R8's bar "not showing" + scroll "still skipping". Built a reproduction rig
  instead of guessing:** booted the iPhone 17 Pro sim, drove the REAL Debug app with a CGEvent
  injection tool (scratchpad `simtap` — click/drag/scroll at screen coords mapped from
  `simctl` screenshots), and pixel-verified every claim.
- **Bar root cause (CONFIRMED):** `StudioMusicWiring`'s `safeAreaInset` bar rendered INSIDE
  the floating HueTabBar capsule's band — MainTabView's 64pt clear inset never reaches the
  inner inset ("the system safe area has no knowledge of it"). The bar existed on every build
  but was hidden behind the tab bar. Fix: explicit `.padding(.bottom, 70)` on the inset
  content, the same hardcoded-clearance discipline as `studioTabBarClearance`. Rig-verified:
  bar renders above the capsule; tapping it opens the Music Source picker showing
  Microphone / Auto-Detect / Sample Track / Apple Music / **Spotify** (local ID active) +
  the tempo-lookup toggle.
- **Scroll verdict on build 40 (rig, 7+ instrumented drags with mid-drag screenshots):**
  Scenes list, Effects deck, and the full Composer deck (66 looks, deep into ENERGETIC)
  all track the finger and HOLD position — no snap-back in the idle app. The R7-era symptom
  is not reproducible on 40/41 while idle; remaining untested configuration = scrolling WHILE
  a look runs (see Left).
- Harness: `StudioScrollStabilityTests` (new file, registered in pbxproj refs
  `C0F1C0DE…04/05`) pins the bar-renders contract with a pixel probe + attached render.
  In-process offset tests were REMOVED — iOS 26 SwiftUI scrolling is not UIKit-backed
  (no UIScrollView to introspect); the rig is the scroll-reproduction tool of record.

### Working
- Suite 799/799 (xcresulttool-verified; +1 bar-contract test); guards green; build 41.

### Left
- **Brian device gate build 41:** all build-40 items PLUS — the bar sits above the tab bar
  and opens the picker; scroll the Composer deck top-to-bottom WITH a look running (the one
  configuration the rig couldn't drive — the transport popover resists synthetic clicks);
  if it still skips there, capture which page + whether a look/music was running.
- If Brian's device still lacks the bar on build 41 → check More → APP build number first.

### Gotchas
- A `safeAreaInset` inside tab content does NOT stack on MainTabView's per-tab clear inset —
  anything mounted at a tab page's bottom edge needs explicit HueTabBar clearance.
- Simulator injection rig: ALWAYS `osascript activate` Simulator before each CGEvent batch
  (background test runs steal focus and events go nowhere); calibrate y-mapping from two
  known-good tap anchors, not the title-bar guess. Popover/confirmationDialog buttons do not
  respond to synthetic mouse clicks — plan flows around them.

---

## 2026-07-21 - [Claude] MUSIC R8 — the picker is findable, Spotify ID wired, composer scroll-jump fixed (build 40)

### Branch
- `main` (rollback tag: `checkpoint/music-picker-spotify-scroll`, pushed)

### Did
- **`847cdd8` composer scroll-jump:** two causes, one symptom ("scroll to the bottom skips back
  up"). `MicLevelMeterView` flipped its caption row in/out at 12fps from inside its
  TimelineView as live features crossed silent/active — height thrash under a drag yanks the
  scroll offset (row is now a fixed slot, text fades). Both vertical mixer-tray ScrollViews
  dropped `.scrollBounceBehavior(.basedOnSize)` — its fit-evaluation goes stale when the
  `.id()`-swapped tab content changes height and the drag rubber-bands before the bottom.
  The horizontal chip-row keeps `.basedOnSize` (axis never changes size).
- **`803cd09` picker findability (Brian's report: "can't see the music picker"):** the
  no-session Studio state showed only the slim muted "Sync to music" capsule. Now the full
  `MusicNowPlayingBar` always mounts — idle it reads "Nothing playing — Pick a source to sync
  your lights", tap anywhere opens the picker. Pill deleted.
- **`ef9d6be` Spotify client ID via local xcconfig:** `SPOTIFY_CLIENT_ID` joins
  `GETSONGBPM_API_KEY` in the same flow (ignored `Config/Secrets.xcconfig` → Base.xcconfig
  default → Info.plist → `SpotifyKeys.clientID` computed through the shared
  `TempoProviderKeys.key(named:in:)` sanitizer). Keyless = inert at every gate; Release stays
  Spotify-free via `FeatureFlags`. New `SpotifyKeysTests` (sanitizer + `.notConfigured` gate).

### Working
- Suite 798/798 on iPhone 17 Pro sim (xcresulttool-verified; +2 Spotify key tests);
  guards green; Spotify ID round-trip verified in the built plist REDACTED (32 chars, value
  never printed). Build 40.

### Left
- **Brian's device gate is now build 40:** the build-36/37/38/39 combined music checklist
  PLUS — picker reachable from Studio's always-present bottom bar; composer panel scrolls to
  the true bottom on every tab (Palette/Motion/Brightness/React, half and expanded tray);
  Spotify row appears (Debug build, allowlisted account), login → currently-playing →
  play/pause/next.
- GetSongBPM key rotation still pending (screenshot leak) — one value line in
  `Config/Secrets.xcconfig`, then rebuild.
- Scroll-physics fixes are not unit-testable — they are the device gate's first item.

### Gotchas
- Never insert/remove layout-affecting children from inside a `TimelineView` tick — reserve
  the space and fade. Same class as the R2 "96 must never compress" fixedSize rule.
- `.scrollBounceBehavior(.basedOnSize)` + `.id()`-swapped variable-height content = stale
  scrollability. Use it only where content size is static per mount.

---

## 2026-07-21 - [Claude] GetSongBPM key moves to an ignored local xcconfig (public-repo safety)

### Branch
- `main` (single commit, no checkpoint tag)

### Did
- **Config layer:** tracked `Config/Base.xcconfig` (empty `GETSONGBPM_API_KEY =` default +
  `#include? "Secrets.xcconfig"`) wired as `baseConfigurationReference` on the HueHome app
  target's Debug AND Release configs (pbxproj refs `C0F1C0DE…01/02/03`); tracked template
  `Config/Secrets.xcconfig.example`; git-ignored local `Config/Secrets.xcconfig` (explicit
  .gitignore line beside the old lowercase `secrets.xcconfig` pattern — case-sensitive
  checkouts).
- **Flow:** local xcconfig → build setting → `HueHome/Info.plist` `$(GETSONGBPM_API_KEY)` →
  `TempoProviderKeys.getSongBPMKey` now reads `Bundle.main.infoDictionary`; trims whitespace,
  collapses missing/non-string/unresolved-`$(...)` values to "" — same failable-init gate, so
  keyless = provider inactive, unchanged. Key never logged.
- 7 new `TempoProviderKeysTests` (nil dict, missing entry, non-string, empty, whitespace,
  unresolved placeholder, configured+trimmed, empty-key→provider-nil).

### Working
- Fake-value round trip proven: value in local Secrets.xcconfig appeared in Debug+Release
  `-showBuildSettings` and in the built app's Info.plist (PlistBuddy), then reset to empty.
- Keyless is the committed state — fresh clones/CI build without the local file
  (`#include?` is optional).

### Left
- Brian: paste the real key into `Config/Secrets.xcconfig` as `GETSONGBPM_API_KEY = <key>`
  once the GetSongBPM signup (ios-app:// App-ID format) exists. Plain rebuild picks it up.
- `SpotifyKeys.clientID` is still a hardcoded-empty in source — same xcconfig treatment
  whenever it's wanted.
- No CURRENT_PROJECT_VERSION bump (not a device round) — rides with the next release commit.

### Validation
- Suite 796/796 green on iPhone 17 Pro sim (xcresulttool-verified; 789 + 7 new).
  `hardening_guards.sh` all pass. `git check-ignore Config/Secrets.xcconfig` confirms ignored;
  tracked diff grepped clean of anything credential-shaped.

### Gotchas
- `xcodebuild -showBuildSettings` OMITS empty custom settings — an empty
  `GETSONGBPM_API_KEY =` is invisible there yet still substitutes as "" into Info.plist.
  Verify wiring with a throwaway fake value, never by grepping for the empty setting.
- Don't name a stored property `name` inside an `XCTestCase` subclass — it collides with
  XCTest's inherited `name` and the target won't compile.
- The pbxproj wiring is hand-edited; rerunning legacy `generate_xcodeproj.rb` would drop the
  `baseConfigurationReference` entries.

---

## 2026-07-21 - [Claude] Support page: GetSongBPM attribution backlink (docs only)

### Branch
- `main` (single docs commit, no app code touched)

### Did
- Added the visible "Tempo data provided by GetSongBPM" attribution to the GitHub Pages
  support page (`docs/index.html`), directly above the Privacy Policy link — satisfies
  GetSongBPM's required backlink for the tempo API used by `GetSongBPMProvider` (MUSIC R3).
- Backlink URL for the GetSongBPM form: `https://brian-scott-bean.github.io/ChromaGlow/`
  (Pages serves `main` `/docs`; confirmed via the Pages API — HTTPS enforced, public).

### Validation
- HTML validity checked after the edit; no iOS build/test impact (no Swift/pbxproj changes).

### Gotchas
- The support page is `docs/index.html`, NOT a root-level `index.html` — Pages build source
  is `main` + `/docs` (legacy build type).

---

## 2026-07-21 - [Claude] MUSIC R7 — external-review remediation: phase honesty, mic-demand split, TIDAL removed (build 39)

### Branch
- `main` (rollback tag: `checkpoint/music-R7`, pushed)

### Did
Brian received an external review of the music DESIGN DOC (written against `3f9b51a` — unaware
builds 34–38 shipped). Verdicts against the ACTUAL code, all verified:

| Review point | Verdict | Action |
| --- | --- | --- |
| #1 BPM+position ≠ beat phase | VALID | `7b66859` mic phase-assist: while serviceHold, confident mic estimates apply PHASE-ONLY ≤30ms corrections (tempo/source/confidence stay the service's; mic never demanded, assists when already running) + 10s stale-drive self-heal |
| #2 TIDAL terms | CONFIRMED worse than claimed (v3.0: NO indefinite metadata storage, cross-service/visual-sync/analysis need written approval, NON-COMMERCIAL only) | `6a70820` provider deleted; do-not-reintroduce note in TempoProviders.swift |
| #3 Spotify policy > quota | VALID fact ("Do not synchronize any sound recordings with any visual media", no dev-mode carve-out; enforcement review gated at extended-quota) | Brian decided: KEEP dev-flagged (Release-inert; personal dashboard risk accepted) |
| #4 Apple artwork rights | PARTIALLY — 4.5.2(ii) verbatim permits artwork "in connection with music playback"; only marketing/advertising needs authorization | Brian decided: KEEP "Use album colors"; disclose in v1.1 App Review notes |
| #5 BeatClock authority missing | STALE — quoted pre-R1 code; serviceHold + 14 tests already enforce pin > service > audio | Only residue adopted: the self-heal above |
| #6 `.beat` wrongly holds mic | VALID | `ebe31cf` demand split: requiresMicFeatures vs needsMicNow(serviceDriven:) at all 4 demand sites; per-frame refresh flips within a frame; canRunOnBridge untouched |
| #7 coordinator out of orchestrator | ALREADY BUILT THAT WAY | none |

Also from the terms research: **GetSongBPM base URL corrected to `api.getsong.co`** (test-pinned;
the documented host is legacy) and the REQUIRED attribution backlink added (More → APP "Song
Tempo Data — Powered by GetSongBPM.com"; also put it in the ASC description). Auto-Detect copy:
"locks" → "matches". Terms extracts saved in the session scratchpad; quotes in the commit
messages.

### Working
- Suite **789/789** (+8 new, −5 TIDAL); guards green; build 39.

### Left
- **Brian's device gate is now build 39** (same combined checklist as the build-36/37/38 entries)
  PLUS: no mic prompt when a `.beat` look runs under Apple Music/Auto-Detect-driven clock; beat
  feel tightens when a mic layer runs alongside.
- **1.0 ASC submission: archive from the build-33 commit `0318516`** — music never touches that
  review. v1.1 = builds 34–39 + label updates (tempo lookups + Spotify linking) per runbook.
- Brian to-dos: TIDAL signup is DEAD (skip it); GetSongBPM signup uses the `ios-app://` App-ID
  format; MusicKit+ShazamKit checkboxes; Spotify dashboard (kept, dev-only).

### Gotchas
- TIDAL's docs are a client-rendered SPA — the terms live in the site's JS bundles
  (`developer.tidal.com/assets/developer-terms-3_0-*.js`); WebFetch of the page shows nothing.
- The review's BeatClock quote was from pre-build-34 code — always check WHICH commit an external
  review read before acting on its code claims.

## 2026-07-21 - [Claude] MUSIC R5+R6 — Spotify (dev-flag) + program close-out (build 38) — ALL BUILD ROUNDS COMPLETE, ONE DEVICE GATE LEFT

### Branch
- `main` (rollback tag: `checkpoint/music-R5`, pushed)

### Did
- **R5 feature commit `d67cd9c`:** `SpotifyAuthService` (PKCE, RFC-7636 vector-tested, verifier
  never in a URL, ASWebAuthenticationSession on `chromaglow://spotify-callback`, tokens in
  Keychain accounts `spotify_access_token`/`spotify_refresh_token`, refresh→interactive
  fallback), `SpotifyAPIClient` (currently-playing 200/204/one-401-retry, ~600px artwork, ISRC;
  Premium-tolerant transport), `SpotifySource` (3s foreground poll, 204=idle vs error=keep-state).
  Picker row requires DEBUG flag AND a clientID — **Release ships without Spotify by
  construction.** Suite **786/786** (10 new); guards green.
- **R6 close-out:** AGENTS.md gains the "Music integration durable facts" block (two-layer
  contract, BeatClock priority, source specs, tempo chain, palette rules, UI mounts, privacy-label
  note); build 38. Marketing stays 1.0.0 until the v1.1 submission (provenance-CI rule).
- **Program totals (builds 34–38, one day):** 5 rounds, 10 feature/test commits, 20 new Swift
  files, 83 new tests (703 → 786), zero UnifiedOrchestrator lines, one StudioView line.

### Left — THE ONE REMAINING GATE (Brian, build 38 on device)
1. Portal: MusicKit + ShazamKit checkboxes on `com.huehome.pro`.
2. Keys → `TempoProviderKeys.swift` (TIDAL id/secret, GetSongBPM); Spotify dashboard app
   (Premium, allowlist self, redirect URI `chromaglow://spotify-callback` VERBATIM) → clientID
   into `SpotifyKeys.swift`. Hand keys to Claude to paste+commit if preferred.
3. Combined device pass: R3 Apple Music checklist (build-36 entry) + R4 Auto-Detect/Pandora
   checklist (build-37 entry) + Spotify: picker row appears (Debug install) → login sheet →
   allowlisted account → bar follows Spotify ≤5s → transport works (Premium).
4. v1.1 submission prep (LATER, on Brian's go): marketing 1.0.0→1.1.0 + the three
   `ios-build-provenance.yml` assertions in ONE commit; ASC privacy-label + hosted-policy update
   for tempo lookups + Spotify linking (runbook §label).

### Gotchas
- `@MainActor` classes are implicitly Sendable — no boxing needed to hand `SpotifyAuthService`
  into a `@Sendable` token closure.
- `try? await client.currentlyPlaying()` double-optional conflates 204-idle with network error —
  the source uses do/catch so transient errors KEEP state and only an explicit 204 clears the bar.

## 2026-07-21 - [Claude] MUSIC R4 — Shazam Auto-Detect: the universal/Pandora source (build 37) — GATE C JOINS GATE B

### Branch
- `main` (rollback tag: `checkpoint/music-R4`, pushed)

### Did
- **R4 feature commit `35e3be2`:** `Core/Music/ShazamSource.swift` — continuous SHSession
  identification fed from `AudioAnalysisEngine.addBufferTap` (engine stays the single
  AVAudioSession owner; additive `AudioDemand.shazamID`). `predictedCurrentMatchOffset` → the
  in-track `PlaybackPosition`, so ANY audible source (Pandora included) gets a beat-locked grid;
  ISRC rides along for the tempo sidecar. Pure seams pinned: `ShazamMatchSnapshot` mapping and
  `ShazamMissPolicy` (6 consecutive no-matches before the bar clears). Picker: always-on
  "Auto-Detect Song" row, generalized activation alerts, Pandora footer updated.
- Suite **776/776** (5 new); guards green; build 37.

### Working
- Everything Simulator-testable green. Shazam matching itself is device-only (no Simulator
  inference — VisionKit/CIDetector trap class).

### Left — GATES B+C are ONE device pass now (Brian, build 37)
1. Portal (one visit): **MusicKit + ShazamKit checkboxes** on `com.huehome.pro`.
2. Keys into `TempoProviderKeys` (TIDAL id/secret, GetSongBPM) — or hand to Claude.
3. Device pass: the R3 Apple Music checklist (build-36 DEVLOG entry) PLUS: picker → Auto-Detect
   Song → mic grant → play Pandora on a speaker → track named ≤10s → beat-locked look → pause
   music → bar survives brief gaps, clears after ~30s of silence → mic indicator visible while
   auto-detect runs (expected, honest).
4. R5 (Spotify, dev-flag) next: Brian's dashboard app (Premium; allowlist self; redirect URI
   comes with R5).

### Gotchas
- ShazamKit delegate callbacks are nonisolated — all state hops to MainActor via Task; the
  audio-thread tap calls ONLY the documented-thread-safe `matchStreamingBuffer`.
- `SHSession` isn't Sendable — the tap captures it through an `@unchecked Sendable` box; keep
  the tap body to that single call.

## 2026-07-21 - [Claude] MUSIC R3 — Apple Music (MusicKit) + live TIDAL/GetSongBPM tempo providers (build 36) — GATE B OPEN

### Branch
- `main` (rollback tag: `checkpoint/music-R3`, pushed). Gate A passed (design approved as-is;
  Brian doing the account batch in parallel).

### Did
- **R3 feature commit `7e5b938`:** `Core/Music/AppleMusicSource.swift` (SystemMusicPlayer mirror:
  Combine sinks, pure `AppleMusicEntrySnapshot` seam, 1Hz poll gated by the pinned
  `shouldPoll(isPlaying:isBackgrounded:)` table, MusicAuthorization flow → typed denied error →
  picker alert with Settings deep link); `NSAppleMusicUsageDescription` in `HueHome/Info.plist`;
  picker's Apple Music row live. `Core/Music/TempoProviders.swift`: TIDAL (client-credentials
  token cached, `filter[isrc]` per the verified spec, optional-bpm tolerant, ISRC-only) +
  GetSongBPM (two-step, object-shaped-no-result tolerant) — **both keyless-inactive**
  (`TempoProviderKeys` empty strings committed; `liveProviders()` drops them until keys land) —
  wired as the coordinator's default resolver chain. 14 new fixture tests; suite **771/771**;
  guards green.

### Working
- Everything Simulator-testable is green. Live Apple Music + lookups need Brian's device.

### Left — GATE B (Brian, in order)
1. **MusicKit checkbox** on App ID `com.huehome.pro` (Certificates → Identifiers → App Services)
   — BEFORE installing build 36 on the phone, or authorization fails.
2. **Paste keys** into `Core/Music/TempoProviderKeys` (TIDAL client ID/secret, GetSongBPM key)
   when the signups are done — or hand them to Claude to paste + commit.
3. **On-device pass** (Apple Music sub active): picker → Apple Music → authorize → play a song in
   Music → bar shows track+artwork ≤2s → BPM badge (lookup with keys / mic estimate without) →
   run a `.beat`-reactive look → beat-locks → seek in Music → re-locks without a visible light
   jump → pause → look keeps running at last tempo → transport buttons control Music → tap album
   thumb → running look repaints with album colors → Dashboard shows the compact strip.
4. R4 (Shazam auto-detect) needs the **ShazamKit checkbox** — can be ticked in the same portal visit.

### Validation
- Full suite via xcresulttool; hardening_guards; build 36 across all 12 pbxproj entries.

### Gotchas
- `TrackTempoResolver` is @MainActor so extension statics inherit isolation — `liveProviders()`
  is explicitly `nonisolated` (constructs Sendable providers, touches no state).
- TIDAL rate limits are UNPUBLISHED — providers throw on any non-200 (incl. 429) and the
  resolver falls through; no retry loop by design. Community practice ~500ms spacing; the
  per-track-change single lookup + forever-cache stays far under any plausible limit.

## 2026-07-21 - [Claude] MUSIC R2 — Now Playing UI: Studio bar, Dashboard strip, source picker (build 35) — GATE A OPEN

### Branch
- `main` (rollback tag: `checkpoint/music-R2`, pushed)

### Did
- **R2 feature commit `c7250fe`:** `UI/Music/NowPlayingBar.swift` (MusicNowPlayingBar .full/.compact
  + `StudioMusicWiring`) and `UI/Music/MusicSourcePicker.swift` (pure `MusicSourceCatalog` + sheet).
  Studio mount = exactly ONE StudioView line (`.modifier(StudioMusicWiring(vm: vm))` after
  StudioDrainWiring); Dashboard compact strip inserted as a SIBLING of the effects now-playing bar;
  `MusicSessionCoordinator` env-injected in HueHomeApp (2 lines); BeatPanelView label swaps to new
  `DriveSource.displayName` ("Music" — "service" never reaches users).
- **Design rules baked in:** album-art thumb previews the extracted palette AND is the
  "Use album colors" control (amber paint badge; writes ONLY via `vm.activeCompositionBox` +
  `triggerRESTBurst`); BeatStatusChip `.fixedSize()`; whole-bar tap opens the picker (a dedicated
  button starved the title width); slim "Sync to music" pill when no session; bar hidden while the
  mixer is up on ≤700pt screens; no dead picker rows (Apple Music appears in R3, Spotify in R5);
  honest tempo-lookup toggle (`music.tempoLookupEnabled`) + Pandora truth footer.
- **`MusicUISnapshotTests`** renders all three surfaces to xcresult attachments (render-crash smoke
  + human review artifact). Gate-A copies at `~/Desktop/ChromaGlow-GateA/`. Snapshots drive
  `BeatClock.shared` (BeatStatusChip reads the shared instance — tearDown clears it).

### Working
- Suite **757/757** (11 new); `hardening_guards.sh` green (Guard 6 scans the new UI copy);
  build 35 across all 12 pbxproj entries.

### Left
- **GATE A (Brian):** screenshot sign-off (`~/Desktop/ChromaGlow-GateA/`) + account batch —
  TIDAL dev app (keys), GetSongBPM key, MusicKit checkbox on `com.huehome.pro`, Apple Music sub
  on the test phone, Spotify dashboard app (Premium; allowlist self). R3 coding can proceed in
  parallel; keys/checkbox gate only the live-lookup wiring and on-device QA.
- R3 next: `AppleMusicSource` + real `TIDALTempoProvider`/`GetSongBPMProvider`
  (TIDAL `bpm` VERIFIED in live spec — R1 entry).

### Validation
- Full suite via xcresulttool; guards script; simulator render review (title truncation and a
  BPM-chip compression found and fixed via layout priorities before commit).

### Gotchas
- A ternary producing an optional closure inside `safeAreaInset` content put StudioMusicWiring
  over the type-checker cliff ("failed to produce diagnostic") — split into small computed
  properties (`bottomInset`, `paletteAction`). Same budget discipline as StudioView.body.
- `BeatStatusChip` reads `BeatClock.shared`, NOT an injected clock — any surface pairing the chip
  with a coordinator must drive the shared clock (production does; test fixtures must too).

## 2026-07-21 - [Claude] MUSIC R1 — core music layer: MusicSource, BeatClock service drive, tempo resolver, artwork palettes (build 34)

### Branch
- `main` (rollback tag: `checkpoint/music-R1`, pushed — revert = `git reset --hard checkpoint/music-R1`)

### Did
- **The full music-integration R1 core layer** per the approved build plan (design doc
  `docs/ios/music-integration-design-2026-07.md`), five shippable commits, suite green per commit:
  - **C1 `38382bf`** — `Core/Music/MusicSource.swift` (protocol + `NowPlayingTrack`/
    `PlaybackPosition` in the CACurrentMediaTime timebase + capabilities/transport),
    `Core/FeatureFlags.swift` (first flag surface; `spotifySource` DEBUG-only), and
    `MockMusicSource` (3 demo tracks, 96/120/128 BPM hints, generated gradient artwork — the
    Simulator/demo path). `add_music_files.rb` registers the whole R1–R5 train (idempotent).
  - **C2 `4243ff7`** — **BeatClock `DriveSource.service`** + `driveFromTrack` /
    `endServiceDrive`: grid anchored at track t=0, stale samples extrapolated, ≤30ms gentle
    corrections, >120ms error (seek) re-anchors outright. Priority pinned by 14 tests:
    tap/manual pin > service > audio; `serviceHold` blocks the ~2Hz mic tempo pass (AND its
    confidence-display write) while a track drives; `unpin()` returns to `.service` mid-session;
    session end falls back to audio-follow keeping the last tempo. Out-of-range BPM rejected.
  - **C3 `623f801`** — `TrackTempoResolver`: hint → cache → providers → live TempoEstimator.
    Providers gated by `music.tempoLookupEnabled` (absent = ON, Brian-approved); queries carry
    only ISRC/catalog-ID/title|artist; Application Support JSON cache (tolerant decode,
    `.atomic`-only, 500-entry oldest-out).
  - **C4 `4fe7c99`** — `ArtworkPaletteExtractor` (deterministic fixed-seed k-means, 32×32
    nearest-neighbor sampling, gamut-C clamp) + additive `HueColorUtils.xyFrom(red:green:blue:)`
    (single D65 source; HSB path now routes through it) + `MusicSessionCoordinator`
    (DeepLinkCoordinator pattern; **zero UnifiedOrchestrator lines**; generation-counter
    stale-drop; `lastPosition` `@ObservationIgnored`).
  - **C5 `692182a`** — coordinator contract tests incl. both observation directions (position
    tick fires NOTHING; track change fires).
- **TIDAL `bpm` VERIFIED in the live v2 OpenAPI spec** (spec 1.10.69): `Tracks_Attributes.bpm`
  (float, optional) + `key`/`keyScale`, ISRC lookup via `GET /tracks?filter[isrc]=`, THIRD_PARTY
  self-serve tier, client-credentials for catalog reads. R3's top provider is real. Rate limits
  unpublished — implement 429 backoff.

### Working
- Suite **746/746** (43 new tests across 5 files); app + test targets build clean; no new warnings.

### Left
- **R2 (next): Now Playing UI** — `MusicNowPlayingBar` + picker (StageKit), Studio mount via
  one `.modifier(StudioMusicWiring(vm:))` line, Dashboard compact strip (Brian chose both),
  `DriveSource.displayName` ("Music") for BeatPanelView/BeatStatusChip, Settings tempo-lookup
  toggle. Ends at **GATE A**: Brian's screenshot sign-off + account batch (TIDAL keys,
  GetSongBPM, MusicKit checkbox, Apple Music sub, Spotify dashboard app).
- R3 Apple Music (MusicKit) → R4 Shazam → R5 Spotify (dev-flag) per plan.

### Validation
- Full suite via xcresulttool per commit (703→746); `ruby add_music_files.rb` idempotent-verified;
  build 34 across all 12 pbxproj entries (CI overrides build numbers — marketing stays 1.0.0).

### Gotchas
- **`CGColor(red:g:b:alpha:)` builds GENERIC RGB, not sRGB** — filling a context with it shifts
  components on conversion (blue's xy moved 0.03). Tests draw with `CGColor(srgbRed:...)`; the
  extractor's sampling context pins EXPLICIT sRGB so P3 artwork converts to what
  `HueColorUtils.linearise()` assumes. Same trap class as any future color sampling.
- `xcodebuild … generic/platform=iOS build` does NOT compile the test target — a test-file
  compile error only surfaces in the `test` action (cost one suite cycle in C5).
- MockMusicSource's `stop()` fires `onUpdate?(nil, nil)` — the coordinator nils the callback
  BEFORE calling stop() in `deactivate()`; keep that order.

## 2026-07-21 - [Claude] Music integration deep-dive: design doc for Apple Music / Spotify / Pandora / ShazamKit (docs only)

### Branch
- `main` (docs-only commit; no version bump, no checkpoint tag)

### Did
- **NEW: `docs/ios/music-integration-design-2026-07.md`** — the v1.1 "Sync + Now Playing" blueprint
  (scope confirmed with Brian: lights react to whatever's playing + track/artwork UI + transport
  where allowed; iOS-first; design-only while build 33 awaits device QA/ASC). Based on three
  research sweeps (codebase recon + July-2026 API landscape for Spotify/Pandora and Apple
  Music/adjacent services).
- **Answered Brian's "we had Spotify before" question: no Spotify code ever existed** — working
  tree, full git history on all branches (pickaxe), and the `~/Desktop/Projects/_archive/`
  ChromaGlow docs all show it was only a DEVDOC roadmap TODO ("WHAT source selector (Mic /
  Spotify)"); only Mic shipped. Greenfield.
- **Key research verdicts baked into the doc:** Apple Music/MusicKit is Phase 1 (deepest sanctioned
  path; no BPM field — ISRC joins to tempo sidecars); ShazamKit is Phase 2 and the universal/
  Pandora answer (`predictedCurrentMatchOffset` = position in ANY audible track); Spotify is
  Phase 3 behind a dev flag (Feb-2026 policy: 5 allowlisted users; extended quota needs a business
  with 250k MAU; audio-analysis endpoints dead for new apps since 2024-11-27 — Hue's own Spotify
  sync is a Signify partnership); Pandora has NO public API at all (partner-gated) — mic + Shazam
  serve it honestly. Tempo sidecars: TIDAL bpm/key by ISRC (verify against live spec), GetSongBPM,
  Deezer gray-zone fallback, shipped `TempoEstimator` as offline floor.
- **Architecture:** a new metadata layer (`MusicSource` protocol → `MusicSessionCoordinator`) over
  the existing signal layer — one new `BeatClock` `DriveSource.service` case makes all 66 looks
  track-locked via the existing `ReactionConfig` `.beat`/`.onset` sources with ~zero renderer
  change; artwork → gamut-C `PaletteConfig` extraction reuses the `SiriColorTable` clamp idiom.

### Working
- Docs-only; no build/suite run (narrowest validation per AGENTS.md). App code untouched.

### Left
- Brian's §9 open questions in the doc: Spotify dev-flag posture, Now Playing strip placement,
  tempo-lookup consent default, TIDAL developer registration, ASC App-Service toggles
  (MusicKit/ShazamKit) at phase starts.
- First implementation task when v1.1 opens: verify TIDAL `bpm` in the live `openapi.tidal.com/v2`
  spec (gates the sidecar's top provider), then Phase 1 per doc §6.

### Validation
- Read-only research + two markdown files; `git status` clean apart from the two docs.

### Gotchas
- iOS cannot read other apps' now-playing (MediaRemote is private → rejection; re-confirmed
  Dec 2025 by Apple DTS) — never plan a "what's playing in Pandora" feature around it.
- Spotify's Nov-2024 audio-analysis shutdown is permanent for new apps; any beat-grid plan must
  bring its own tempo source.
- ShazamKit needs a physical device (no Simulator inference) — same test-trap class as the
  VisionKit/CIDetector rule.

## 2026-07-17 - [Claude] BUILD 33 — POLISH ROUND E: hardening round 3 — verify-and-close + new-surface sweep

### Branch
- `main` (rollback tag: `checkpoint/hardening-E`, pushed)

### Did
- **Triage against CURRENT main first, fixes second** — the audit doc gains §8 "Round 3":
  every remaining open finding re-verified (builds 9→32 moved a lot of code) and ledgered as
  FIXED-THIS-ROUND / FIXED-SINCE / MOOT / STILL-OPEN-with-reasons.
- **fix(hardening): nine verified-open P2 findings closed** — L-01 (deadline natural expiry —
  stale-SSE flicker window), L-07 (backoff ceiling was a no-op), L-08 (tautological generation
  guards deleted + documented), L-10 (log caps ×2 view models), L-24 (per-render SwiftData
  fetch → @Query), L-25 (kelvin mirek-0 trap), L-26 (glByID uniquing), L-45/L-46 (GamingEngine
  locking), L-52 (32-char name caps ×2 builders).
- **Fixed-since verified:** L-18 died with the D-016 pairing rework; EffectLoops has backoff
  (M-14 class); the Effects-tab deletion mooted H-05/M-15..17/L-41/42/44/54.
- **Still-open is deliberate and homed** (§8.4): L-02/L-28 need response fixtures; pairing-flow
  items (L-14..17) belong in a dedicated round with the physical-bridge checklist; L-13
  (HueSSEService deletion) is a cleanup commit with pbxproj + AGENTS list corrections; Android
  items ride Batch-4/D-020.
- **New-surface sweep CLEAN** (§8.5): invite QR (secret-bearing kind 3), guest key mint,
  whitelist masking, share codecs — zero token-logging hits; already pinned by
  SecretLogScrubTests (incl. the build-26 guest-mint test) + WhitelistRedactionTests + Guard 2.
- Decision-Log note appended (pipeline doc Open Questions).

### Working
- 703/703 green twice at round end; `./Scripts/hardening_guards.sh` green.

### Left
- **THE PROGRAM IS COMPLETE** (Rounds 0 + A–E = builds 29–33, all pushed). Remaining owners:
  Brian's device pass (`docs/ios/master-on-device-checklist.md` + each round's adds), the ASC
  runbook, the sequencer design-doc questions (§11), the build-26 whitelist-probe RECORD, and
  the Android Batch-4/D-020 loop with Codex. Deferred engineering backlog: audit §8.4 items,
  Baylee Phase B, Elmo's test-target warnings, Sequence Builder Phases 1–3 on Brian's go.

### Validation
- Suite per commit via xcresulttool; guards script green; build 33 across all 12 pbxproj
  entries.

### Gotchas
- L-08's guards were load-bearing-LOOKING but inert — staleness is (and was) entirely
  `RestSender.clear()`; don't reintroduce snapshot-vs-snapshot generation guards in enqueue
  closures.
- The L-01 deadlines now always run their full 1.5s — any future tuning must keep the SSE
  suppression window ≥ the PUT round-trip or the flicker returns.

---

## 2026-07-17 - [Claude] BUILD 32 — POLISH ROUND D: the lava-lamp pack — 10 new built-in looks (56→66)

### Branch
- `main` (rollback tag: `checkpoint/effects-D`, pushed)

### Did
- **feat(composer): 10 new built-ins, id block `00000009-0001-0001-0001-…`** (block A stays
  reserved for the Sequence Builder's future templates): **Lava Lamp** (the signature ask —
  molten red/orange/magma-magenta, pulseCenter at speed 8, swell envelope: the slow blob
  morph no catalog entry had), **Retro Lava** (70s amber/olive scatter), **Aurora Curtain**
  (green/violet/teal wave with heavy stagger — drapes), **Ocean Storm** (deep blue/teal/white-
  crest comet + flicker), **Fireflies** (near-dark warm-green twinkle, min brightness 4),
  **Candle Cathedral** (many-point amber/ember scatter + flicker), **Neon Rain** (cyan/magenta
  cascade, 90bpm pulse = 1.5Hz, well under the 3Hz bar), **Deep Space Drift** (indigo/teal/
  purple spiral), **Jellyfish** (bioluminescent teal/violet pulseCenter swell), **Zen Garden**
  (sage/sand static gradient + slow breathe). Category spread: Ambient +2, Nature +3, Cozy +1,
  Energetic +1, Cosmic +1, Cinematic +1, Focus +1.
- **Pruned from the plan's draft:** "Sunrise Alarm" (redundant with the existing Sunrise Wake).
- **Gamut discipline:** every xy is a catalog-proven gamut-C point or a CONVEX BLEND of two
  (triangle interiors are convex), so exact gamut-membership holds by construction.
- **The quality bar did its job twice:** first run failed `testEveryFieldIsInsideItsSliderRange`
  — three presets breathed below the envelope slider's 20-BPM floor (18/16/12) — clamped to 20.
  All 15 PresetCatalogTests then green (gamut, 3Hz flash sweep, motion-differs-across-lights at
  1/5/20 lights, no low-speed jumping, uniqueness).
- BuiltInSeedMigrator reaches existing installs by id (adds newcomers, never touches user
  edits) — no migration code needed, by design.

### Working
- Full suite green twice at round end (see Validation).

### Left
- Round E next (build 33, `checkpoint/hardening-E`): security hardening round 3.
- **Brian's Round D on-device checks:** Composer deck shows 66 presets (the b21 checklist item
  said 56 — superseded); run Lava Lamp on a real room side-by-side vs Opal and Enchant — it
  must read as slow drifting blobs, clearly distinct; Fireflies in a dark room (near-dark
  background with warm green sparkles); Aurora Curtain vs Northern Lights (curtain has the
  hanging-drape stagger); each new look's name matches its feel; existing user-edited presets
  untouched after the update.

### Validation
- PresetCatalogTests 15/15 + full suite via xcresulttool; build 32 across all 12 pbxproj
  entries; AGENTS.md durable-fact line updated (56→66).

### Gotchas
- The envelope BPM slider floor is 20 — a built-in may not ship values the editor can't
  reproduce (`testEveryFieldIsInsideItsSliderRange` enforces; my 18/16/12 drafts failed it).
- Id block `0000000A-…` remains RESERVED for Sequence Builder templates (design doc §7) — the
  next preset pack continues in block 9 (`…-000000000011`+) or opens block B.

---

## 2026-07-17 - [Claude] BUILD 31 — POLISH ROUND C: terminology — one transport vocabulary, grandma copy pass

### Branch
- `main` (rollback tag: `checkpoint/terminology-C`, pushed)

### Did
Three shippable commits, suite green per commit (702→703 tests):
1. **feat(studio) TransportVocabulary** — new
   `HueHome/UI/Components/TransportVocabulary.swift` is THE single source of play-mode words;
   the four transport-wording surfaces (mixer badge + menu + status sentences, save-sheet
   picker + footer, first-run dialog, preset overflow menus) and StudioViewModel toasts all
   read it — executes the deferred build-23 Phase C. Renames: "REST"→"Room mode"/"Room Only";
   raw `[REST_ONE_SHOT]`/`[ENTERTAINMENT]` toast tags→human copy; "Transport"→"Play mode";
   "ENT AREA" badge→"AREA"; "Runtime-only REST is rate-capped"→"Playing in Room mode — updates
   a little slower"; tier badges "Hybrid"/"App Driven"→"Phone + Bridge"/"Plays from phone";
   "grouped light" toast→"room control". KEPT: Entertainment Area (official Hue vocabulary).
2. **fix(copy) grandma pass** — Envelope→"Brightness Shape" (tab "Brightness"), Onset→"Hits",
   Color Temp/CT→"Warmth" everywhere, Settings DEVELOPER→ADVANCED with humanized rows ("API
   Token"→"Bridge Connection Key"; clip/v2 row→"Connection: Philips Hue Bridge") — DELIBERATE
   DEVIATION from the plan's #if DEBUG idea: the section holds the demo toggle + the
   clean-bridge recovery tool, so it stays user-reachable, renamed and de-jargoned instead;
   "Devices & Firmware"→"Devices & Updates"; firmware→"bridge software"/plain phrasing;
   low-latency copy plainized; "mock data"/"sandbox"→"sample home"; "Wi-Fi scan
   (mDNS)"→"Scanning your Wi-Fi"; Beat "Phase"→"Timing offset"; Perform "XF"→"Fade", "beat
   grid"→"right on the beat". Perform's DJ deck theme + photosensitivity/privacy notices
   untouched by design.
3. **test(copy) jargon regression guard** — `Scripts/hardening_guards.sh` Guard 6 greps the
   display-string surfaces for banned fixed literals (REST variants, ENT AREA, rate-capped,
   mock data, low-latency, mDNS, CT APPROX, …); `testTransportVocabularyStaysJargonFree` runs
   the same contract over the vocabulary in every suite run. Guard 6 immediately caught two
   leftovers (StageKit preview badge + Settings demo subtitle — fixed), and running the full
   script surfaced two PRE-EXISTING failures on main: the M-03 guard still expected the
   pre-build-28 `HueHome/PrivacyInfo.xcprivacy` path (guard updated to the live ROOT
   manifest), and a post-P1 `HueAPIClient` error log line carried `privacy: .public` alongside
   `error.localizedDescription` (H-03 class — split into a public method/path line + a private
   detail line).

### Working
- 703/703 green twice at round end; `./Scripts/hardening_guards.sh` fully green again.

### Left
- Round D next (build 32, `checkpoint/effects-D`): the new-effects pack incl. Lava Lamp.
- **Brian's Round C on-device checks:** read every changed surface cold — mixer badge/menu/
  status, apply toasts, save sheet, first-run play-mode dialog, Settings (ADVANCED group),
  More rows, light editor "Warmth", Composer "Brightness Shape" tab + "Hits" chip, key/revoke
  dialogs — would a first-time user understand every label? Same words for the same concept
  everywhere?

### Validation
- Suite per commit via xcresulttool (703/703 at close); guards script green; build 31 across
  all 12 pbxproj entries.

### Gotchas
- TransportVocabulary is now the ONLY place play-mode words live — new surfaces must read it
  (Guard 6 + the unit test enforce).
- The H-03 guard rule is line-level: `.public` may never share a line with error text/URL/name
  identifiers — split log statements instead of annotating around it.

---

## 2026-07-17 - [Claude] BUILD 30 — POLISH ROUND B: previews everywhere + envelope/mic visualization

### Branch
- `main` (rollback tag: `checkpoint/ux-polish-B`, pushed)

### Did
Six shippable commits, suite green per commit (688→702 tests):
1. **feat(preview) LookPreview** — `HueHome/UI/Components/LookPreview.swift`: LookPreviewSpec
   (Equatable value of real palette/pattern/speed/envelope; init(preset:), accent-only init,
   .starter), pure LookPreviewMath sampling through the ACTUAL engine configs
   (PaletteConfig.color(at:) / MotionConfig.sample / EnvelopeConfig.value) with a PREVIEW-ONLY
   0.75s period floor ≈ ≤1.33Hz (twinkle floored 8× harder — its sparkle cadence is period/8
   and escaped the plain clamp; caught by the new flash-cap test), LookPreviewStrip (12fps
   multi-color strip) + LookPreviewCanvas (drifting-blob card background, idle 4fps). All pause
   on Reduce Motion / isTabActive / KeyboardState. LookPreviewMathTests: bounds across every
   pattern×shape×extremes, 60fps 8s flash-count sweep, clamp behavior, static fallback.
2. **feat(studio)** — StudioCardView gains optional previewSpec: all Composer preset cards
   (flat grid + "From Composer" shelves) render their real look at rest (canvas + always-on
   strip); "+ Create" hero gets a faint starter canvas; engine deck cards trade generic .bounce
   for a per-effect signature map (`StudioCardCanvas.signaturePattern(forCardID:)`, co-located
   with the artwork switch) shown at rest too.
3. **feat(scenes)** — every scene card shows a signature strip (still bar for static scenes;
   active dynamic scenes animate at their REAL 0-1 recall speed); Studio scenes-shelf chips get
   static real-palette mini strips; automation rows with dynamic effects get static signature
   strips (calm surface — static by design).
4. **feat(composer) EnvelopeStripView** — the six brightness-shape curves are visible at last:
   live waveform of the user's configured shape/BPM/depth/attack/decay/duty with sweeping
   playhead, mounted in the editor + layer sheet; ChipPickerRow.Item gains curveSamples (18×12
   canonical per-shape thumbnails on the chips). EnvelopeStripMathTests.
5. **feat(composer) MicLevelMeterView** — live level+bass/mid/treble bars polling the
   lock-guarded AudioAnalysisEngine.latestFeatures(); NEVER calls setDemand (honest "MIC
   LISTENS WHEN THE LOOK RUNS" idle state); reaction.threshold drawn as a tick on the level bar.
6. **feat(scenes) true-color previews** — HueScene's list decode gains a TOLERANT `palette`
   field (custom init(from:): only id/metadata/group can fail an element — the load-bearing
   listing rule now enforced by HueScenePaletteDecodeTests incl. a garbage-palette fixture);
   ≤3 xy points thread through GlobalSceneItem.paletteXY (defaulted; ==/hash untouched) into
   SceneMoodCard's strip.

### Working
- 702/702 green twice at round end.

### Left
- Round C next (build 31, `checkpoint/terminology-C`): one transport vocabulary + grandma copy
  pass + jargon regression guard per the program plan.
- **Brian's Round B on-device checks:**
  1. Composer deck at rest: all 56 cards visibly drift/breathe their OWN colors; strips show
     real motion; scroll stays smooth; hidden tabs still pause (perf contract).
  2. Deck 0/1: each card's strip motion matches its personality (candle twinkles, prism
     cascades, strobe chases); canvases unchanged.
  3. Scenes tab: static scenes show still color bars (true palette colors on dynamic scenes
     where the bridge supplies them); an ACTIVE dynamic scene's strip speed matches its recall
     speed (compare a slow vs fast dynamic scene).
  4. Composer → Envelope: the waveform matches what lights do; dragging BPM/Depth/Attack/Decay/
     Duty reshapes it live; each shape chip shows its curve icon.
  5. Composer → React with a mic source: meter bars move with sound while a mic-reactive look
     runs; threshold tick moves with the slider; idle state reads honestly when nothing runs.
  6. Reduce Motion: everything stills (curves stay visible as static).
  7. Typing anywhere: previews freeze while the keyboard is up (Round A contract extended).

### Validation
- Suite per commit via xcresulttool (702/702 at close); build 30 across all 12 pbxproj entries.

### Gotchas
- LookPreview's flash clamp is PREVIEW-ONLY — engine timing untouched. Twinkle needed an 8×
  period floor (sparkle cadence = period/8, 0.15s floor); any new pattern with sub-period
  events needs the same review (the flash-cap test will catch it).
- HueScene now decodes via custom init(from:): status/speed/type/palette are all tolerant
  (`try?`) — only id/metadata/group fail an element. Do not "simplify" back to synthesized
  Decodable; the garbage-palette test pins this.
- Scene move/copy paths that rebuild GlobalSceneItem show [] paletteXY until the next scene
  load (defaulted field) — cosmetic, self-heals on refresh.

---

## 2026-07-17 - [Claude] BUILD 29 — POLISH ROUND A: tour overlap, keyboard smoothness, 44pt tap targets

### Branch
- `main` (rollback tag: `checkpoint/ux-polish-A`, pushed)

### Did
Eight shippable commits, suite green per commit (683→688 tests):
1. **fix(tour)** — the "A library of looks" ScenesArt overlap: both columns now reserve a row-2
   landing slot sized by a hidden copy of the traveling card (slot height can never drift);
   overlay y 64→52. TourMotionMath untouched.
2. **feat(perf) KeyboardState** — new `@MainActor @Observable` singleton driven by UIKit keyboard
   notifications (willShow = the pre-rise jank window; didHide clears). Zero per-field wiring.
   Consumers: `PatternStripView.isLive`, `StudioCardCanvas`'s animate gate, `BeatPanelView`'s
   bar meter (+ gained the missing `isTabActive` pause), and the composer hero border — its
   60fps `repeatForever` angular-gradient drive DIRECTLY behind the AI-prompt TextField is now
   a pausable 20fps wall-clock TimelineView honoring Reduce Motion. New idempotent
   `add_ux_polish_files.rb` registers Round A+B files. `KeyboardStateTests` added.
3. **fix(studio) keyboard mechanics** — `.scrollDismissesKeyboard(.interactively)` on the deck
   grid, composer grid, BOTH mixer editor ScrollViews, and Scenes content; AI prompt
   `.lineLimit(2, reservesSpace: true)` (a growing field re-laid-out the deck grid per wrap).
4. **fix(forms)** — EditRoomSheet @FocusState; manual bridge IP off `.decimalPad` (no Return
   key) → `.numbersAndPunctuation` + Go/onSubmit sharing Connect + autofocus.
5. **feat(a11y) HueHit + stageTapTarget** — `HueHit.min = 44` token + modifier; `ChipPickerRow`
   44pt min hit height in ONE edit covering all call sites (the primary Composer selectors were
   ~25pt); composer layer tabs, harmony-rule pills, Studio category chips same. Floor pinned in
   HueTokensTests.
6. **fix(mixer)** — transport cluster 34→40pt visuals / 44pt hits (Revert/Perform/Save/Stop +
   icon), grab bar 28→36 (44 effective), badge-lane menu real padding + expanded hit;
   `MixerTrayMetrics` repaid (grabBar 36 / header 66 / badgeLane 28 / compact cap 406) and the
   rows-pay-for-themselves contract is now `MixerTrayMetricsTests`, not a comment. Perform's
   header circles mirrored.
7. **fix(a11y) scatter** — harmony swatches 28pt-in-44pt hit frames (+ real contentShape),
   RoomDetail light power 32→44, Dashboard power 40→44 + ellipsis 36→44, saved-color/
   light-control swatches expanded hits, clear-x buttons 44pt.
8. **fix(store) BONUS (found by the suite)** — `backUpCompositionsFile` used second-granular
   names with `copyItem` (throws if destination exists): two recovery events in one second
   silently lost the second backup. Real (narrow) production data-loss window; names now
   uniquify `-N`. Surfaced as a NonDestructivePersistence failure when adding tests shifted
   clone redistribution — the same latency class as the build-26 KeychainManagerTests find.

### Working
- 688/688 green twice at round end (per-commit runs + the final build-29 validation).

### Left
- Round B next (build 30, `checkpoint/ux-polish-B`): LookPreview everywhere + EnvelopeStripView
  + mic meter per the program plan.
- **Brian's Round A on-device checks (append to the master checklist pass):**
  1. Tour page 3: the traveling card lands in an empty slot at BOTH ends — never covers a card.
  2. Studio: tap a mixer readout (BPM etc.) and the AI prompt — keyboard rises smoothly, deck
     canvases/strips FREEZE while typing, resume on dismiss; scroll dismisses the keyboard.
  3. Scenes search: type fast — no shimmer/jank behind the keyboard.
  4. Mixer transport buttons + composer chips + harmony swatches: comfortably thumbable; grab
     bar easier to hit; nothing clips in the tray (compact phone + Dynamic Type XL).
  5. Manual bridge IP: keyboard has a Go key that connects; field autofocuses.
  6. Rename a room: field is focused on open; Done saves.

### Validation
- `xcodebuild test` scheme "HueHome 1", iPhone 17 Pro sim, per commit; results verified via
  xcresulttool on each .xcresult (688/688 at close). Build number 29 across all 12 pbxproj
  entries; BuildMetadataTests uses a fixture (no edit needed); provenance CI derives the build
  number dynamically.

### Gotchas
- One mid-round process slip: a commit was chained onto a verification in a single call and
  landed against a red suite (the NonDestructivePersistence flake). The failing test exposed a
  REAL product bug (fixed as commit 8) and verification/commit are now strictly separate calls
  — exactly what the "verify suite before committing" rule exists for.
- `stageTapTarget(visual:)`'s negative-inset contentShape relies on the parent not clipping
  hit-tests — true for the HStack/overlay hosts it's applied in; verify when reusing elsewhere.

---

## 2026-07-17 - [Claude] POLISH PROGRAM ROUND 0: master test checklist, Sequence Builder design, Decision-Log sync

### Branch
- `main` (docs-only round; no build bump)

### Did
- **Program kickoff.** Brian approved the six-round "world-class polish program" (plan file:
  `~/.claude/plans/ok-do-the-best-luminous-hinton.md`): Round 0 docs (this entry), then builds
  29–33 = A visible UX (tour ScenesArt overlap fix, KeyboardState editing-pauses-the-stage,
  44pt tap-target normalization incl. the 34×34 mixer transport cluster), B previews everywhere
  (data-driven LookPreview for all 56 composer cards/scenes/shelf/automations + EnvelopeStripView
  + mic level meter), C terminology sweep (ONE transport vocabulary + TransportBadge — executes
  the deferred build-23 Phase C — plus the grandma glossary: REST→Room mode, Envelope→Brightness
  Shape, CT→Warmth, Settings DEVELOPER behind #if DEBUG, etc.), D new-effects pack (~11 built-ins
  incl. the missing lava-lamp class), E security hardening round 3 (verify-and-close remaining
  audit P2/Round-2 items + fresh leak sweep over the builds-18–28 surfaces).
- **`docs/ios/master-on-device-checklist.md`** — the consolidated "discography": builds 18–28
  on-device checklists merged into one de-duplicated, surface-ordered pass (supersession-aware:
  b18§1-5→b20§8; b24 Siri stop→b25 semantics; b25§11→b26 two-phone flow), + the parked-agent
  "Left" register (Adam/Charles/Baylee/Darwin/Elmo/Frank/Helena), the build-26 whitelist-probe
  RECORD item, and Brian-manual program items (ASC runbook, Android Batch-4 physical gate).
- **`docs/ios/sequence-builder-design-2026-07.md`** — the design-only Sequence Builder spec
  Brian asked for ("interested what you come up with"). Core decision: NO second sequence
  system — graduate the existing hidden `CompositionSequence`/`SequencePlayer`/
  `PerformanceMixBox` stack (additive model fields, per-light SequenceTransitionMath at the
  renderMixed chokepoint, wall-clock holds). Filmstrip editor with drag-to-scrub-on-real-lights,
  spatial sweep transitions (competitors can't — they have no light positions), hold styles
  mapped onto existing envelope/motion shapes, 4-tier transport honesty ladder (bridge-stored
  2–8-step compile via BridgeAnimationEngine ≙ iConnectHue's ceiling; unlimited app-driven +
  streamed above it), 13 templates (First Light = Brian's script verbatim; Lava Lamp), pure
  SequenceSafety 3Hz audit. §11 = open questions for Brian.
- **Decision-Log status sync** (`docs/coordination/parallel-agent-pipeline.md`): D-016/D-017/
  D-018/D-019 marked IMPLEMENTED on `main` with dated evidence turns (the shipped hardening-P1
  run; prior turns untouched); the stale "all PROPOSED" Open-Questions bullet corrected; D-020
  (canonical Android tree + CI gate) left open for the Brian+Codex loop.

### Working
- n/a (docs only).

### Left
- Round A next (build 29, checkpoint/ux-polish-A): 7 commits per the approved plan.
- Brian: run the master checklist top-to-bottom when convenient; answer the sequencer §11
  questions; ASC runbook pass; record the build-26 whitelist-probe outcome.

### Validation
- Docs-only; no build run. Decision statuses verified against AGENTS.md "Current High-Priority
  Follow-Ups" + the build-27/28 DEVLOG records before syncing.

### Gotchas
- The checklist's DEVLOG line refs are as-of-2026-07-17; they drift as entries are added — the
  per-build entry headings are the stable anchors.
- Pipeline-doc decision statuses had drifted from reality (the audit's own L-34 class). Synced
  via appended dated turns only — no prior agent turns rewritten, per the doc's rules.

---

## 2026-07-15 - [Claude] BUILD 28: final App-Store audit + the Welcome Tour

**Scope (Brian):** "complete audit — make sure it's App Store ready" + "a full tutorial for the
first time someone logs in, replayable, pristine, showcasing everything."

**Rollback:** `git reset --hard checkpoint/tour-audit-2026-07-15` (tag pushed with this run).
Fifteen commits, suite green per commit (667→683 tests), build 27→28 (all 12 entries).

### Audit verdict — the app IS App-Store ready; one real code gap found and closed
- **Verified DONE (no action):** usage strings cover every capability the code actually uses
  (camera/mic/local-network/Bonjour/location — nothing else used); privacy manifests in all 4
  bundles, and a required-reason-API sweep over all four source roots returned ZERO hits beyond
  the declared UserDefaults/CA92.1 (grep in this entry's Validation); entitlements correct; icons
  + launch screen valid; zero TODO/trademark/test-IP leakage; no dev UI reachable in Release; TLS
  pinning wired on all 4 surfaces (`BridgePinnedTrustDelegate` in HueAPIClient/HueSSEService/
  HueIntentAPIClient/WidgetIntents/WatchStore); `SecretLogScrubTests` present; ⏱️PERF gone.
- **The gap:** 35 ungated `print()` still shipped in Release — the build-27 run gated
  UnifiedOrchestrator's 31 sites but missed **StudioViewModel (28**, incl. `[AI]` sites gated
  only by `canImport(FoundationModels)`, one printing the raw model response**)**,
  **CompositionStore (6)**, **watch WatchStore (1)**. All now behind per-file `fileprivate
  debugLog(@autoclosure)` (the house pattern). An awk sweep (below) proves zero ungated prints
  outside `#if DEBUG` across all four targets.
- **Cleanups:** stray unreferenced `LightShadeWatchApp.entitlements` deleted; orphan duplicate
  `HueHome/PrivacyInfo.xcprivacy` deleted — **the LIVE app manifest is the repo-root
  `PrivacyInfo.xcprivacy`** (pbxproj Resources phase), do not "clean" the root one;
  `NSHumanReadableCopyright = "© 2026 Brian Bean"` on the 4 extension/watch configs; accepted
  Xcode 26's pbxproj comment/format normalization as its own commit.
- Remaining submission work is **Brian's manual ASC Part B only** (metadata, screenshots, demo
  video, archive/upload — runbook).

### NEW: the Welcome Tour (first-launch tutorial, replayable)
- **12 swipeable full-screen pages** in the StageKit dark-stage look: Welcome → Rooms → Moods →
  Room detail (copy/paste color, Paint, My Colors) → Scenes → Studio → Composer → Perform →
  Automations → Family sharing → Siri/widgets/watch → privacy/photosensitivity wrap. Guests see
  9 (the Studio suite drops, mirroring `visibleTabs`). Copy is trademark-clean by test.
- **Zero image assets:** every illustration is live SwiftUI (SF Symbols + StageKit, incl. real
  `PatternStripView`s), a pure function of wall time via one TimelineView (15fps, paused
  off-page); Reduce Motion renders a curated frozen frame (t=4.6s); nothing cycles faster than
  `TourMotionMath.fastestAllowedPeriod` (0.75s ≈ 1.33Hz — pinned by test against the 3-flash
  promise in the wrap page's copy).
- **Auto-presents once** on first arrival in the main shell (post-pairing, post-join, or demo):
  `WelcomeTourWiring` on `MainTabView` in AppRootView (StudioDrainWiring pattern);
  `@AppStorage("castchroma.hasSeenWelcomeTour")` set ONLY by Skip/Done (kill mid-tour = shows
  again); a cold-start deep link (`DeepLinkCoordinator.hasPendingRoute || openToken != 0`)
  suppresses WITHOUT marking seen; presentation waits for loadAll settle (3s cap, demo-exempt)
  so the guest filter snapshots truthfully. **Replay:** More → APP → "Replay the Tour".
- **Files:** `HueHome/Core/Models/TutorialCatalog.swift` (pure catalog — copy/order/audience,
  locked by `TutorialCatalogTests`, 16 tests), `HueHome/UI/Tutorial/{WelcomeTourView,
  TutorialIllustrationView,WelcomeTourWiring}.swift`, registered via `add_tutorial_files.rb`
  (idempotent); + `HueFont.tourTitle/.tourBody` (Dynamic Type), MoreView replay row,
  `DeepLinkCoordinator.hasPendingRoute`.

### Bugs found & fixed by end-to-end Simulator smoke (fresh install → Explore Demo → tour)
1. **The build-27 photosensitivity notice NEVER actually appeared on fresh installs.**
   `prewarmDeferredTabs` realizes StudioView opacity-hidden; StudioDrainWiring's `.onAppear`
   fired the alert from the hidden tab; UIKit silently dropped it — and the dangling
   presentation swallowed the NEXT presentation app-wide (it ate the tour cover; that's how it
   was caught). Fix: gate on `\.isTabActive` (fire on appear only if visible, else on the first
   flip). Verified: alert now presents on first VISIBLE Studio entry, once.
2. **`fullScreenCover(isPresented:)` + separate page state built an EMPTY tour** (the build-14
   Perform black-page bug, same fix): now `fullScreenCover(item: TourPresentation)` so the page
   snapshot rides the presentation; the wiring also verifies the cover actually appeared and
   re-requests once if a racing presentation swallowed it.
3. **Next button wrapped to "Ne/xt"** when the 12-dot row squeezed it (Brian's catch):
   `lineLimit(1) + fixedSize` + compact dot metrics (fits 375pt).

### Review pass (multi-agent, adversarial verify)
12 confirmed findings; all closed except two that were this run's own remaining steps (bump,
this entry). Highlights: trademark test made case-insensitive (uppercase eyebrows made "HUE …"
invisible to it); exact page order pinned; guest-visible copy may never mention
Studio/Composer/Perform (test); accents pinned to the four identity hexes; `TourMotionMath.segment`
joined the hostile-input bounds tests; page-1 back chevron hidden from VoiceOver; inactive-dot
contrast raised; MoreView replay switched to the item-based cover. Known accepted edge: if
loadAll hasn't settled after the 3s cap, a guest-keyed shell could briefly be classified as
owner and see the 3 Studio pages once — harmless copy, deliberate trade against delaying the
tour indefinitely.

### Validation
- Suite green per commit via xcresult (`xcrun xcresulttool get test-results summary`), 667 →
  **683 tests** (16 TutorialCatalogTests + 2 motion-math + review additions); two consecutive
  green runs at the final tree.
- No-ungated-prints sweep (awk over `#if DEBUG` depth, all 4 source roots): empty.
- Required-reason sweep: `grep -rnE 'creationDate|modificationDate|fileModificationDate|contentModificationDateKey|creationDateKey|getattrlist|fstat\(|lstat\(|systemUptime|mach_absolute_time|volumeAvailableCapacity|systemFreeSize'` → zero hits.
- Simulator end-to-end (iPhone 17 Pro, fresh installs): tour auto-presents post-demo-entry with
  all 12 pages animating; Done persists the flag (container plist verified) and never re-shows;
  Skip works; replay row works; photosensitivity alert appears on first visible Studio entry;
  deep-link/cold-start suppression logic exercised via DEBUG prints.

### Left for Brian (build 28 on-device QA)
1. Fresh install → pair → tour auto-appears after the dashboard paints; swipe all 12; Done.
2. Reinstall → "Explore Demo" → same, then Studio tab → photosensitivity notice appears once.
3. Skip on page 2 → relaunch → no tour. Kill mid-tour → relaunch → tour returns.
4. More → Replay the Tour; guest phone (family-sharing invite) shows 9 pages, no Studio suite.
5. Widget/Siri cold launch → NO tour over the deep link; next normal launch → tour.
6. Reduce Motion, Dynamic Type XXL, VoiceOver page-turn announcements, iPad cover.
7. Then the runbook Part B (ASC metadata/screenshots/demo video/upload) — unchanged.

### Gotchas
- The root `/PrivacyInfo.xcprivacy` is the app's LIVE manifest; the `HueHome/`-folder copy was
  the orphan. Deleting the wrong one strips the manifest from the bundle (ITMS-91053).
- Alerts/covers fired from opacity-hidden tabs are silently dropped by UIKit AND poison the
  next presentation — gate any new auto-presenting surface on `\.isTabActive` (or verify+retry
  like `WelcomeTourWiring`).
- `simctl spawn defaults write` hits a device-domain plist that SURVIVES app uninstall and is
  not the app container's plist — verify app prefs via
  `xcrun simctl get_app_container … data` + `plutil -p …/Library/Preferences/com.huehome.pro.plist`.
- StudioView.body remains untouched (type-checker ceiling) — the alert fix lives entirely in
  `StudioDrainWiring`, the sanctioned extension point.

---

## 2026-07-09 - [Claude] BUILD 20: adjustment-settings revamp + live-update fixes + scenes layout

**Scope (Brian, Ultraplan-refined):** complete revamp of the adjustment settings for all four
Studio card families (Effects Deck 0, Live Deck 1, Composer cards + "+ Create") styled on the
DJ Perform grammar; customization audit (add what matters, remove what doesn't, everything must
work); room/zone master-bar live-update bug; all-cards liveness audit; Scenes grid↔bar option.
Decisions: full package (incl. device-gated engine upgrades), flat DJ-stage tray, remember+reset.

**Rollback:** `git reset --hard checkpoint/pre-adjustrevamp-2026-07-09`. Twelve commits
(09daf7b…e499d20 + this one), full suite green per commit, build 19→20 (all 12 entries).

### What shipped
1. **StageKit primitives** — StageToggleRow, StageColorSwatchRow (44pt targets), StageMoreButton,
   StageSheetScaffold (unified sheet chrome, background interaction at medium so lights stay
   visible), StageSlider `onEditingChanged`, StageSwatchMath; HueFont stage tokens
   (text-style-relative → Dynamic Type works).
2. **Param controls rebuilt** (`StudioParamControls.swift`, extracted from StudioView): row-local
   @State sliders (resolves the old Phase-3 perf note), color swatches wired to `sendColorParam`
   — **fixed dead wire: swatch taps never re-tinted running bridge-native effects** (zero UI
   callers before), segmented chip renderer, Hz/Kelvin formatters.
3. **Param truth pass** (audit-verified against engine loops): REMOVED dead controls —
   thunderstorm Brightness (never read; `flash_intensity` promoted to essential "Flash
   Brightness"), party + prism Saturation, ambient Color picker (engine is CT-only). Transition
   0–6000ms sliders → INSTANT/SMOOTH/SLOW chips (value only glides later PUTs). Honest renames
   (Fade Floor, Ambient Level) + ENT-only hints on strobe speed/flash_color/duty_cycle.
4. **Mixer tray = flat DJ stage** — StagePalette.surface + hairline (no `.ultraThinMaterial`
   blur over the animating grid), Perform header (34pt circles, mono tags, StageBadges), color
   row promoted into the compact tray, `MixerTrayMetrics` derived heights (390/420 constants dead),
   drag-up shows ADVANCED inline.
5. **Composer progressive disclosure** (COMPOSER_SPEC finally implemented) — 3–5 essentials per
   layer tab; `ComposerLayerSheet` behind "+N more" (direction cluster moved wholesale);
   engine-honest gating (static/steady/mic-vs-beat no-ops hidden); contextual Heads/Density
   labels; ChipPickerRow everywhere. Gap fixes: **Warmth slider in temperature mode** (pad was a
   dead surface there), **Smoothing slider** (mic), **spectrum Saturation slider**.
6. **Remember + reset** — `StudioParamStore` (UserDefaults JSON, clamp-on-load, unknown ids
   dropped); Reset-to-Defaults in the sheet; composer Revert-to-saved (undo button, saved
   presets only); save-sheet accent-color swatches (user cards no longer all `#FFB340`).
7. **Engine upgrades (DEVICE-GATED)** — candle/fire Flicker Rate + sparkle Twinkle Rate
   (generic v2 plumbing; 400s harmless on non-supporting firmware); warmth re-parameterizes the
   RUNNING effect per-light (`EffectsV2Body(mirek:)` — grouped PUT used to fight the effect);
   party Flash Color finally read (50% xy palette tint, live).
8. **Master-bar live fix (rooms AND zones)** — root cause: `roomIsOn/roomBrightness` snapshot;
   SSE handler never recomputed the aggregate and dropped grouped_light events. Now:
   `RoomAggregate.derive` at the `mutateLight` seam + after SSE batches; own-group grouped_light
   consumed (OFF bridge-authoritative unless a member disagrees); 1.5s master-write echo guard.
9. **Scene ACTIVE badges live** — new `scene` SSE case (status.active) updates `globalScenes` +
   RoomDetail chips, deactivating room-mates; shape-tolerant status decode (zigbee_connectivity
   sends a string — strict decode would drop whole batches).
10. **Scenes layout toggle** — `castchroma.sceneWideCards` toolbar button, 2-up grid ↔ full bars
    (one `gridColumns` lever; SceneMoodCard is already a bar internally).

New files (registered via `add_adjustrevamp_files.rb`, idempotent): StudioParamControls,
ComposerLayerSheet, StudioParamStore, RoomAggregate + four test files. New test suites:
StudioParamCatalogTests, ComposerControlCatalogTests, StudioParamStoreTests, RoomAggregateTests,
plus scene-SSE tests in OrchestratorSSETests. Legacy `EffectLibrary` (Automations) untouched;
CompositionEngine/Mixer/transports/BeatClock/RestSender untouched; Perform typography deferred.

### On-device checklist (build 20)
1. Deck 0 cards: brightness ≤~200ms; speed re-params while running; **candle/fire/sparkle new
   rate sliders — verify firmware actually honors them** (if not: drop those params, one-line
   revert); base-color swatch re-tints the RUNNING effect (new); warmth slides smoothly during
   candle/fire with no restart flicker; Kelvin readouts sane; Smoothness chips glide later PUTs.
2. Strobe ≤3Hz at max (Hz readout matches flash rate); ENT-only hints appear only over REST.
3. Thunderstorm: Flash Brightness visibly scales strikes; no dead sliders on Deck 1.
4. Party: Flash Color tints the palette live; Smoothness (essential) changes hold/fade feel.
5. Composer: essentials per tab; "+N more" sheet (Motion → dial/mini-map, drag lerps lights);
   drag tray up → ADVANCED inline; temperature mode = Warmth slider, no pad; Smoothing audibly
   lags mic; static/steady gating; beat quick-toggle still auto-scrolls to beat panel.
6. "+ Create" opens the same editor; save sheet: accent swatches land on the saved card.
7. Relaunch: Deck 0/1 sliders reopen at last-used values; Reset restores defaults live;
   composer Revert (undo button) snaps back to the saved preset.
8. **Master bar:** turn every light off one-by-one → bar flips with the LAST light, no
   leave/return; one on → bar on; per-light brightness moves the average; official-Hue-app
   toggle follows; master slider drag doesn't fight SSE; toggle-then-watch: no bounce-back.
   Repeat once in a ZONE.
9. **Scenes:** activate a scene from the official Hue app → ACTIVE badge flips here (scene SSE);
   in-app tap still deactivates room-mates. Layout toggle: grid ↔ full bars across grouped/
   favorites/search + skeleton; persists relaunch; drag-scene-to-room copy works in both.
10. Tray drag up/half/collapse + Live Controls pill; pad/dial drags don't move the tray;
    Dynamic Type XL: tray scrolls, nothing clipped; tab away/back pauses strips.

---

## 2026-07-09 - [Claude] BUILD 19: Scenes overhaul — grouped IA, saved colors, scene copy/move

### Branch
- `main` directly (rollback `checkpoint/pre-scenesrun-2026-07-09` @ `72669f1`)

### Did
- **Roadmap (`073c638`):** `docs/ios/feature-roadmap-2026-07.md` — verified capability
  inventory, gap table, prioritized phases R1 Automation / R2 Sensors & switches / R3 Presence
  & away / R4 Media & gradient, plus 8 differentiators (Live Activity effects, Focus-mode
  lighting, ShazamKit palette, RoomPlan 3D placement, composition share, knock-flash
  accessibility, energy insights, countdown lighting). Suggested next run: R1.0 scheduling
  spike → scene scheduling; quick win D2 (Focus).
- **Phase 0 (`28febad`):** decomposed ScenesTabView (809→~410 lines) — SceneMoodCard/
  SceneShimmerCard, SceneSpeedSheet, RenameSceneSheet extracted verbatim. New idempotent
  `add_scenes_overhaul_files.rb` registers this run's files in the pbxproj.
- **Phase 1 (`733f207`):** grouped-by-room Scenes IA — ★ Favorites shelf (CSV order), one
  collapsible section per room/zone (`SceneRoomSectionView`, collapse persisted via
  `castchroma.collapsedSceneRoomIDs` CSV), toolbar sort menu replaces the wide-card toggle,
  chips only in flat modes, search flattens. Pure tested `SceneGrouping` model. **Fixed: zone
  scenes showed as "Other"** (roomName lookup searched allRooms only).
- **Phase 2 (`03d7c5d`):** `SceneUsageStore` (UserDefaults JSON, LRU cap 500, keyed by raw
  bridgeSceneID) recorded from both activation paths → Recently Used / Most Used sorts. Also
  feeds roadmap R3.2 (vacation mimic) later.
- **Phase 3 (`a08dad9`):** "My Colors" saved palette — `SavedColor(Store)` (xy or mirek +
  brightness), `SavedColorStrip` shared component; save from LightControlView (color row +
  CT-only row) and SceneColorBuilderView; RoomDetail strip arms a swatch → tap a light to
  apply; capability fallback (color→xy, CT-only→clamped mirek, dimmable→brightness) unit-tested.
- **Phase 4 (`ce65ea0`):** swatches `.draggable`; light cards `.dropDestination` with amber
  targeting ring. `UTExportedTypeDeclarations` added to Info.plist (savedcolor + scene-ref).
- **Phase 5 (`0a31e26`):** scene copy/move — new on-demand `HueSceneDetail` decode +
  `fetchSceneDetail(id:)` (list decode UNTOUCHED by design: odd firmware action blocks must
  never break scene listing), `HueColorUtils.mirek(fromX:y:)` (McCamy), pure `SceneCopyEngine`
  (recipe extraction sorted color-hue→CT-warm→cool; round-robin/evenly-spaced distribution;
  gamut clamp / CT approximation / brightness-only downgrades; dynamic palette passthrough),
  orchestrator `roomLights(for:)` extraction + `copyScene` (~50 narrow lines), `CopySceneSheet`
  (bridge-grouped picker, live per-light remap preview with downgrade badges, 32-char name),
  `HueActionToast` 5s undo (copy-undo deletes; move-undo re-POSTs the retained original).
- **Phase 6 (`67934c2`):** scene cards `.draggable`; room sections (grouped) / filter chips
  (flat) are drop targets → CopySceneSheet opens pre-targeted. Never a blind copy.
- Bumped `CURRENT_PROJECT_VERSION` 18 → 19 (all 12 entries).

### Working
- Full suite green after every commit (incl. new SceneGroupingTests, SceneUsageStoreTests,
  SavedColorStoreTests, SceneCopyEngineTests — 26 new tests).

### Left — Brian's on-device checklist (build 19, after the build-18 items)
1. Scenes tab: rooms appear as collapsible sections; collapse survives relaunch; Favorites
   shelf on top; sort menu switches to flat modes and brings chips back; search flattens.
2. Zone scenes now show their zone name (previously "Other").
3. LightControl: save a color via ＋ in MY COLORS; RoomDetail: tap swatch → tap light applies;
   drag swatch onto a light card → applies with ring highlight; CT-only + dimmable lights get
   sensible fallbacks.
4. Scene context menu → Copy to Room…: preview shows target lights tinted with remapped
   colors; confirm creates the scene in the target room; Undo removes it. Move restores on Undo.
5. Drag a scene card onto another room's section header → sheet opens pre-targeted.
6. Dynamic scene copy keeps its palette + speed (preview shows the palette strip).
7. **Two-bridge check:** copy a scene to a room on the OTHER bridge; verify colors land.
8. Demo mode: no Copy/Move menu items; drops rejected.

### Gotchas
- `fetchScenes()` list decode must stay actions-free — all action decoding lives in
  `HueSceneDetail` (see Phase 5 rationale).
- SceneCopyEngine is pure; the orchestrator gained only I/O plumbing. Keep it that way.
- Favorites CSV + SceneUsageStore both key on RAW `bridgeSceneID` (shared identity contract).
- `add_scenes_overhaul_files.rb` is the pbxproj registrar for this run's files (idempotent).

---

## 2026-07-09 - [Claude] BUILD 18: card state parity + Composer live-update fixes

### Branch
- `main` directly (rollback `checkpoint/pre-scenesrun-2026-07-09` @ `72669f1`)

### Did
- **Composer fix (`8c7f351`):** `CompositionParamBox` (CompositionEngine.swift) is now
  `@Observable` — the layers panel (Motion/Envelope/React chips, direction dial, mini-map)
  updates live instead of requiring a tab round-trip. Every runtime field render() writes at
  25fps is `@ObservationIgnored`; that annotation is **LOAD-BEARING** (observing them would
  invalidate the Studio tab at frame rate and break the `\.isTabActive` pause contract). Two
  observation-contract tests lock in both directions.
- **Dashboard builder (`4e87a64`):** room/zone `isOn` now ORs in member-light state when
  `grouped_light` reports off (the bridge lags after scene recall / per-light control).
  Brightness = average of lit members; dominant glow follows. One-directional: lights prove ON,
  never off. LOAD-02 fixture corrected (its member light was hardcoded on in the all-off case).
- **SSE on-state (`d540615`):** an explicit `on:true` light event flips its room/zone card on —
  gated on `pendingActionDeadlines` (no pre-PUT echo flips) and `appDrivenGroupIDs` (composition
  echo suppression intact). Rebuilds still flow only through the coalesced `scheduleSSERebuild`.
- **Seed freshness (`72480c7`):** `applySSEEvent` now patches `lightsByBridge` in place via new
  `HueLight.applying(sseUpdate:)` (OFF events included; composition-driven rooms excluded), so
  RoomDetail's <30s skip-refetch seed and Studio's `cachedRawLights` coverage source are accurate
  at any age. This STRENGTHENS the instant-render contract, no rebuilds added.
- **Subscriber race (`72f13fe`):** `subscribeToLightEvents` continuations carry a UUID token;
  a popped room's deferred onTermination can no longer nil a newer room's continuation (which
  froze all in-room SSE updates until re-open). Stale streams are proactively `finish()`ed.
- Test seams added (DEBUG): `testSeedLightIndex`, `testSeedLightCache`, `testYieldLightEvents`.
- Bumped `CURRENT_PROJECT_VERSION` 17 → 18 (all 12 entries).

### Working
- Full suite green after every commit
  (`xcodebuild test -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`).

### Left — Brian's on-device checklist (build 18)
1. Toggle a light from the official Hue app → dashboard card lights up ≤2s without opening the room.
2. Within 30s of an external toggle, open that room → cards correct instantly AND the fast-path
   still engages (no spinner).
3. Open room A → back → immediately open room B → toggle a B light externally → B updates live.
4. Activate a scene → dashboard card + room header show on despite grouped_light lag.
5. Run a composition → dashboard card does NOT flicker at frame rate; stop → state settles.
6. Composer: with a composition running, tap a new Motion pattern / Envelope shape / React source,
   drag the direction dial → panel reflects it immediately, no tab-switch; sliders don't hitch;
   leaving the tab still pauses animations.
7. Regressions: card power toggle instant, All Off, pull-to-refresh, widget snapshots correct.

### Deferred (documented, intentionally not fixed)
- 1.5s pending-window SSE suppression can drop legit external changes (self-corrects).
- 120s dashboard refresh debounce (SSE now carries liveness).
- Optimistic `localIsOn` no-rollback when `setRoom`/`setLight` early-returns (broken-pairing only).
- Dead `LightCard` in RoomDetailView (L776–920) — never instantiated; cleanup candidate.

### Gotchas
- `@ObservationIgnored` on CompositionParamBox runtime fields is load-bearing (see above).
- The LOAD-02 fixture light now follows the scenario's on state — an "all off" test must
  actually turn its lights off or the builder cross-check correctly flips the room on.

---

## 2026-07-08 - [Claude] BUILD 17: "All Lights" master-switch Control

### Branch
- `main` directly (rollback `checkpoint/pre-widgets-2026-07-08` @ `15c0435`)

### Why
Brian: "we need an all lights on lock screen widget." Two constraints reshaped the ask —
Lock Screen *widgets* can't run intents (build 16), so it must be a **Control**; and the Lock
Screen has only **two corner slots**, so a separate On button beside the existing All Off
button would consume both.

### Did (`932f60a`, build 17)
- **`AllLightsControl`** — a single `ControlWidgetToggle`: everything on when off, off when on,
  rendering the current state. One slot, not two. `AllOffControl` stays for Control Center
  (no slot limit) and for anyone wanting a one-way kill switch.
- **`SetAllLightsPowerIntent: SetValueIntent`** (iOS 18+) — same `withTaskGroup` fan-out as
  `AllOffIntent`, same `BridgeWriter` pinned-trust session (D-016).
  **Turning ON is not a bare `on: true`.** That restores each group's last level, so after a
  Sleep preset the house returns at 6%. It applies a "welcome home" state instead:
  **80% brightness, mirek 350** (warm-neutral), 800ms dynamics. Both are named constants
  (`onBrightness`, `onMirek`) — retune freely.
- **`AllLightsValueProvider`** reports on when **any** group is lit, so the toggle reads on with
  a single lamp on and one tap kills the house. Master-switch model. App Group read only —
  a control's `currentValue()` must never touch the network.
- `WidgetDataStore.markAllGroupsOff()` → **`markAllGroups(on:brightness:)`**. Sole caller
  (`AllOffIntent`) updated. Shared source: app + widget targets both rebuilt.

### Validation
- Clean build 0 errors / 0 warnings: `HueHomeWidgetExtension` and the app (which also compiles
  the renamed `WidgetDataStore` helper). `** TEST SUCCEEDED **` on iPhone 17 Pro.
- Registration proven, not just compilation: `Metadata.appintents` carries
  `SetAllLightsPowerIntent`, and `com.lightshade.app.AllLightsControl` is in
  `HueHomeWidgetExtension.debug.dylib` alongside the other four kinds.

### Left (Brian, device)
1. Lock Screen → Customize → tap a bottom corner → Controls → ChromaGlow → **All Lights**.
2. Lights off, tap it **while locked**: everything comes up ~80%, warm, over ~0.8s.
3. Tap again: everything off. The label tracks state.
4. Judge the 80% / mirek 350 "welcome home" state — say the word and I'll retune the constants.

### Gotchas
- Toggle state is "any group on", not "all groups on". Deliberate.
- Turning on **overwrites** each room's remembered brightness. That is the cost of the
  predictable 80%; the alternative (bare `on: true`) was rejected because Sleep leaves 6%.
- `currentValue()` reads the App Group snapshot, so the rendered state can lag a change made
  in-app until the next timeline refresh. The write is always immediate.
- Controls need **iOS 18+**; on 17 the bundle loads and they simply don't appear.

---

## 2026-07-08 - [Claude] BUILD 16: Lock-Screen widget reality check — icons, deep link, dead buttons

### Branch
- `main` directly (rollback `checkpoint/pre-widgets-2026-07-08` @ `15c0435`)

### Why
Brian put both Lock Screen widgets in the widget bar: "they have no pictures or icons and
when tapped they just bring me into the app… doesn't even bring me to a room. I don't know
what these are supposed to do."

### The framing that was missing
**iPhone Lock Screen widgets (the accessory families, in the bar around the clock) are NOT
interactive.** A tap anywhere follows `.widgetURL` into the app. They are glanceable status
only. The interactive Lock Screen surface is a **Control** in the two bottom corner slots
(iOS 18, `HueHomeWidgetControl.swift`, shipped in build 15) — Brian had not added one.

### Did (`4ada3d8..`, build 16)
- `4ada3d8` **icons**: both `AccessoryCircularView` (iOS) and `CircularView` (watch) passed the
  room icon as the Gauge's `label`. `.accessoryCircularCapacity` renders the ring and the
  `currentValueLabel` **only** — `label` is never drawn, so the icon had NEVER appeared. Icon +
  value now share `currentValueLabel`; `label` keeps the room name for VoiceOver.
- `4ada3d8` **dead buttons**: the accessory views rendered power and −/+ `Button(intent:)`s that
  can never fire. Removed all of them — including the ones added the same day in `c9a1870`,
  which had also cost the rectangular widget a room row (restored to 3). Keeping the
  pre-existing pinned buttons while deleting the identical unpinned ones would have been
  incoherent. `AccessoryWidgetBackground()` stays.
- `ba07d73` **deep link**: `DeepLinkCoordinator.pendingGroupID` was written and read by
  **zero code** — every widget tap landed on the dashboard. Home's `NavigationStack` now takes
  a `[RoomDisplayItem]` path owned by `MainTabView`, and `openToken` pushes the resolved room.
  A cold launch resolves nothing (loadAll hasn't returned), so the id stays pending and
  MainTabView retries on `allRooms`/`allZones` arrival. `DashboardView` untouched — it already
  declares the `.navigationDestination(for:)`, and AGENTS.md protects it.

### Validation
- Clean build 0 errors / 0 warnings: app, `HueHomeWidgetExtension`, watch app (which embeds the
  complication). `** TEST SUCCEEDED **` on iPhone 17 Pro.
- Simulator: installed, launched, and sent `lightshade://room/{unresolvable-id}` and
  `lightshade://dashboard` via `simctl openurl` — same PID throughout, no crash, pending id
  correctly parked.

### Left (Brian, device)
1. **Add a Control**: Lock Screen → Customize → tap a bottom corner → Controls gallery →
   ChromaGlow → *Room Lights* / *Activate Scene* / *Lighting Preset* / *All Lights Off*.
   These run with the phone locked. Same four appear in Control Center.
2. Lock Screen widget: the circular gauge should now show a room icon above its number.
3. Tap a pinned widget → the app should open **that room's detail**, not the dashboard.
4. **Regression to watch for:** Home's NavigationStack is now path-bound. Confirm the tab bar's
   re-tap-to-pop and the interactive back-swipe still behave (they drive the
   `UINavigationController` directly via `TabNavRegistry.popOne`).

### Gotchas
- Don't re-add `Button(intent:)` to accessory widgets. It cannot fire on the iPhone Lock Screen
  and it renders a control that lies. Put it in a Control instead.
- `.accessoryCircularCapacity` never draws a Gauge's `label`. Anything that must be visible
  belongs in `currentValueLabel`.
- Controls need **iOS 18+**. If Brian's phone is on 17 they won't appear at all.

---

## 2026-07-08 - [Claude] BUILD 15: widget audit — Lock Screen Controls, tap targets, watch brightness

### Branch
- `main` directly (rollback `checkpoint/pre-widgets-2026-07-08` @ `15c0435`)

### Why
Brian's on-device audit of all three widget surfaces: Home Screen widget works but its
buttons are too small to hit; the Lock Screen widget "doesn't function at all"; the Watch
moves brightness 1% per tap and has no press-and-hold.

### Root causes
1. **Lock Screen inert by construction.** `selectedRoomID` comes from the widget's config
   intent. Until a room is pinned via *Edit Widget* it is nil — and that branch of
   `AccessoryCircularView` / `AccessoryRectangularView` rendered **zero Buttons**. Separately,
   iOS Lock Screen *accessory* widgets don't reliably run `Button(intent:)` at all; the tap
   falls through and launches the app. The sanctioned interactive Lock Screen surface is an
   **iOS 18 Control Widget** — stubbed in `HueHomeWidgetControl.swift` since v0.1.0, never built.
2. **Tap targets.** Large −/+ 20×20, Focused-Small 22×22, Focused-Medium 26×26, chips ~17pt
   tall, three power toggles with no frame at all.
3. **Watch had no ± buttons.** What Brian tapped was the native watchOS `Slider`, which draws
   its own −/+ and was declared `step: 1`; the Crown was `by: 1`.
4. **Watch flooded the bridge (bug, found en route).** `setBrightness` awaited one PUT per
   value change with no debounce, and `.onChange` fires per step — a Crown sweep issued ~99
   sequential PUTs, each also running `saveToLocalCache()` + `reloadAllTimelines()`. Violated
   AGENTS.md's "latest-wins mailbox" and "do not queue unlimited bridge writes".

### Did (`4c359a0..`, build 15) — one shippable commit per fix
- `4c359a0` **watch mailbox**: `setBrightness` is now synchronous — optimistic @Published
  update, then a per-grouped_light latest-wins mailbox drained by one writer task that PUTs
  the newest value and spaces writes 250ms. Persistence + timeline reload once, on drain.
- `8e19195` **watch UX**: ⊖/readout/⊕ row. Tap ±10%, press-and-hold (0.35s) ramps every 150ms
  with a `.click` haptic; a progress bar carries the Crown at 1% for fine trim.
- `5b1e474` **tap targets**: new `tapTarget(_:)` / `tapTarget(width:height:)` /
  `tapTargetHeight(_:)` grow the hit region via `.contentShape(Rectangle())` around unchanged
  glyphs. Sizes are the largest each family's fixed canvas allows (see Gotchas).
- `c9a1870` **accessory widgets**: unpinned circular gauge is now an `AllOffIntent` button;
  unpinned rectangular gains an All-Off header control + per-row power toggles (3 rows → 2).
  Added `AccessoryWidgetBackground()`, absent everywhere despite being HIG-recommended.
- `f1e22ea` **Controls (iOS 18+)**: `RoomToggleControl` (ControlWidgetToggle),
  `SceneControl`, `PresetControl`, `AllOffControl`. New `SetRoomPowerIntent: SetValueIntent`
  (absolute set, unlike `ToggleRoomIntent`'s invert-a-stale-snapshot), `SceneAppEntity` +
  query, `PresetChoice: AppEnum` (now the single source for the brightness/mirek table).
  Registered behind `if #available(iOSApplicationExtension 18.0, *)`.

### Validation
- Clean build **0 errors / 0 warnings**: app (`generic/platform=iOS`), `HueHomeWidgetExtension`,
  and `LightShadeWatchApp Watch App` (`generic/platform=watchOS`) built separately — the watch
  target does NOT compile `WidgetDataStore.swift`, so an iOS build won't catch watch breakage.
- `xcodebuild test -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`:
  ** TEST SUCCEEDED **.
- Verified the Controls really register: `HueHomeWidgetExtension.appex/Metadata.appintents`
  contains `SetRoomPowerIntent`, `SelectRoom/Scene/PresetControlIntent`, `SceneAppEntity`,
  `PresetChoice`; all four `com.lightshade.app.*Control` kinds are in the extension binary.
- **NOT exercised on device.** Controls can't be proven from a build.

### Left (Brian, device)
1. Lock Screen → Customize → add a ChromaGlow control to a bottom slot. Tap it **locked**;
   the light must toggle without unlocking. Same controls in Control Center + Action button.
2. Home Screen widget: −/+/power/chips comfortably hittable.
3. Watch: tap ⊕ → +10%. Hold ⊕ → smooth ramp, lights track it. Crown → fine 1%.

### Gotchas
- **Controls need iOS 18+.** On iOS 17 the bundle still loads; the controls just don't appear.
- A widget's canvas is fixed, so a uniform 44pt is unreachable. Actual sizes: Focused-Medium
  power **44** (the only true 44pt target), Focused-Medium −/+ 40, Large row −/+/power **30**,
  Focused-Small 30, page chevrons 44×28, scene chips 32 tall, preset chips 26, "All Off" 34.
  **Raising the Large row past ~30pt requires lowering `HueWidgetEntry.largePageSize` (6) first**
  — 6 rows + page bar + preset strip already fill its ~326pt.
- `SetValueIntent`'s `value` parameter name is fixed by the protocol; do not rename.
- Control value providers must never do network I/O — they read the App Group snapshot, so a
  toggle's rendered state can lag until the next timeline refresh. The write itself is immediate.
- The **widget extension still builds with `ENABLE_DEBUG_DYLIB`** (build 13 disabled it for the
  app target only). Its code lives in `HueHomeWidgetExtension.debug.dylib`. Not a startup-path
  cost, but that is why `strings` on the `.appex` executable finds nothing.
- Still dead, still untouched: `HueHome/Intents/` (`HueIntents.swift`, `HueIntentAPIClient.swift`,
  `HueRoomEntity.swift`, `HueAppShortcuts.swift`) is compiled into **no target**. It holds a
  second, orphaned `ToggleRoomIntent`/`SetBrightnessIntent`. Wire up or delete — needs a decision.
- Cosmetic, unfixed (AGENTS.md forbids casual renames): widget `configurationDisplayName` says
  "CastChroma" while `HueHomeWidget/Info.plist`'s `NSLocalNetworkUsageDescription` says
  "ChromaGlow" — a user-visible inconsistency in the local-network permission prompt.

---

## 2026-07-08 - [Claude] BUILD 14: fix black-on-first-open DJ Perform cover

### Branch
- `main` directly (single commit)

### Why
Brian: opening the Perform (DJ) surface the first time showed a completely black
full-screen page with no dismiss affordance; backgrounding the app and returning
made it appear.

### Root cause
`StudioView` presented Perform with `.fullScreenCover(isPresented: $showPerform)` whose
content was `if let performVM { … }` — presentation keyed off a **Bool** while the content
depended on **separate** state. Both were written through `@Binding`s from `MixerTrayView`'s
button. SwiftUI captures the cover's content closure against the view value it holds when
`isPresented` flips, which still had `performVM == nil` ⇒ the `if let` failed, the cover
committed `EmptyView` (a black full-screen with no chrome to dismiss). Backgrounding forced a
StudioView body re-evaluation, the closure re-ran with a non-nil VM, and the deck appeared.
Nothing inside `PerformanceView` was ever at fault — its `stageBG` base layer always draws.

### Did (build 14)
- `PerformanceViewModel: Identifiable` + `nonisolated let id = UUID()`.
- `StudioView`: `.fullScreenCover(item: $performVM) { performer in … }` — presentation is now
  keyed off the data itself, so there is no nil window and no `if let`. Dismissal nils the
  item automatically (dropped the manual `onDismiss`).
- Deleted the now-redundant `showPerform` `@State` + its `@Binding` in `MixerTrayView`;
  assigning `performVM` is what presents the cover.
- Bumped `CURRENT_PROJECT_VERSION` 13 → 14 (all 12 pbxproj entries).

### Validation
- `xcodebuild build -destination 'generic/platform=iOS'`: BUILD SUCCEEDED, 0 errors / 0 warnings.
- `xcodebuild test -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`:
  ** TEST SUCCEEDED **.
- NOT yet exercised on device — Brian to confirm first-open of the Perform surface paints
  immediately from a cold launch.

### Gotchas
- Do not reintroduce a separate `isPresented` Bool for Perform. `item:` is load-bearing here.
  Same trap applies to any cover/sheet whose content unwraps a different `@State` than the one
  driving presentation (`editingSwatch` already uses the `item:` form correctly).
- `PerformanceViewModel` is `@MainActor`; its `id` must stay `nonisolated` to satisfy
  `Identifiable` without a Swift 6 isolation warning.

---

## 2026-07-07 - [Claude] BUILD 13: debug-dylib OFF + getting-ready frame + gradient glow

### Branch
- `main` directly (rollback `checkpoint/pre-round4-2026-07-07`)

### Why
Build 12's now-visible stacks named the blockers (see snapshot). The dominant one is
configuration, not code: debug-dylib execution makes Swift conformance scans pathologically
slow while SwiftUI builds the setup screen's tree on device.

### Did (`00eb121..3dbf81a`, build 13)
- `ENABLE_DEBUG_DYLIB = NO` — app target Debug config only (pbxproj block `A11DB52F…`).
  Verified the built app no longer contains `HueHome.debug.dylib`. Revert this single
  setting if SwiftUI Previews misbehave.
- BridgeSetupView shim: static "Getting things ready…" frame paints BEFORE the heavy
  BridgeSetupContent construction (VM creation moved `.onAppear` → `.task` so the frame
  commits first). No animation on purpose — nothing can animate during a main-thread hang.
- Ambient glow: 60pt gaussian `.blur` on a 320pt circle → RadialGradient (the ~4.7s
  CGDisplayListDrawInContextDelegate stack; re-paid per accent-color change).

### Validation
- Simulator fresh install: launch→setup 1.4s, `discovery.vm-init.done` ×1, ZERO hangs.
- Full suite green; clean build 0 errors/0 warnings.

### Left
- Brian: build 13 fresh install + experiments A (untethered relaunch) and B (Release run) —
  these size how much of the remaining slowness is debug-run tax vs real app work.

### Gotchas
- If Previews break for the app target: revert `ENABLE_DEBUG_DYLIB = NO` (one line).
- The placeholder branch must stay animation-free — it exists to be a good STILL frame.

---

## 2026-07-07 - [Claude] BUILD 12: filter-proof stacks + VM-churn fix + dead-NUPnP fix

### Branch
- `main` directly (rollback `checkpoint/pre-round3-2026-07-07`)

### Why
Build 11's device run: stacks captured but INVISIBLE (frame lines printed separately →
console filter kept only headers). Plus two evidence-backed defects found via the timeline:
`BridgeDiscoveryViewModel` constructed 6+ times on the setup screen (`@State` initial-value
churn, inside the 18.4s hang window) and the NUPnP cloud fallback hitting a retired endpoint
(hard 404 for every user).

### Did (`698c855..13e7c4b`, build 12)
- `MainThreadWatchdog`: HANG-STACK header + frames emitted as ONE multi-line entry (no filter
  can decapitate it); sample offsets → [0.4, 1.5, 4.0, 8.0] (≈0.65/2.2/6.2/14.2s into a hang)
  so ~1s tab-switch hangs get sampled too (device showed 981ms, just under the old 1s offset).
- `BridgeSetupView` → thin shim owning `@State vm: BridgeDiscoveryViewModel?` created once in
  `.onAppear`, injecting into `BridgeSetupContent` (the old body, untouched, `let vm`).
  Simulator-verified: `discovery.vm-init.done` fires exactly once (was 6+ on device).
- NUPnP URL: `discovery.meethue.com/api/nupnp` → `discovery.meethue.com/` (curl-verified:
  old = hard 404; root = live, 429 when rate-limited → existing catch → warm mDNS retry).

### Validation
- Simulator smoke: single multi-line 🧵HANG-STACK block with symbolicated frames; vm-init ×1.
- Full suite green (see run below); clean build 0 errors/0 warnings.

### Left
- Brian: fresh install build 12 → paste the now-visible 🧵HANG-STACK blocks. They name the
  remaining blocker(s); the VM-churn fix may already shrink the setup-screen jank.

### Gotchas
- BridgeSetupView's public API unchanged (SplashView + BridgeManagerView construct it);
  the content struct is `BridgeSetupContent` — put new setup-screen code there.

---

## 2026-07-07 - [Claude] BUILD 11: in-hang stack sampler — the watchdog now NAMES the blocker

### Branch
- `main` directly (rollback `checkpoint/pre-stacksampler-2026-07-07`)

### Why
Build 10's device run proved the fresh-install minute is main-thread blockage (~35s of hangs
in the `splash.route`→BridgeSetupView window, 18.5s in one chunk; scan never started, zero
network lines) — but the watchdog could only say WHEN, not WHAT. Build 11 adds in-hang stack
sampling so the next run prints the guilty function by name.

### Did (`44d5b2b..ba9fcc3`, build 11)
- `MainThreadWatchdog`: while main is blocked, sample its stack at ~1s/~3s/~8s into the hang —
  `thread_suspend` → `ARM_THREAD_STATE64` pc/lr → frame-pointer walk via `vm_read_overwrite`
  (crash-safe) → `thread_resume` → `dladdr` symbolication strictly after resume. Prints
  `🧵HANG-STACK main blocked ~Nms so far (phase: …) — main thread is in:` + one line per frame.
  DEBUG-only, arm64-gated.
- Narrowing marks: `discovery.vm-init.done` (end of `BridgeDiscoveryViewModel.init`),
  `setup.appear` (`BridgeSetupView.onAppear`).

### Validation
- Simulator smoke test with a deliberate 3s `Thread.sleep` on main: sampler printed the full
  symbolicated stack (`+[NSThread sleepForTimeInterval:]` ← AppDelegate closure ← dispatch ←
  run loop). Temp sleep removed before commit.
- Full suite re-run for build 11 (see below); clean build no new warnings.

### Left
- Brian: fresh install build 11, console filter `⏱️TL|🧵HANG|🌐`, paste the `🧵HANG-STACK`
  blocks. Frames name the 18.5s setup blocker + the ~2s Studio-swipe blocker → targeted fix.

### Gotchas
- Symbolication must NEVER run while main is suspended (dyld locks) — keep the
  capture/symbolicate split if editing the sampler.
- Console shows each diagnostic line twice under Xcode (stdout + OSLog mirror) — cosmetic.

---

## 2026-07-07 - [Claude] DIAGNOSTICS BUILD 10: live startup timeline + hang watchdog + Swift 6 zero warnings — ON MAIN

### Branch
- `main` directly (rollback `checkpoint/pre-diagnostics-2026-07-07` @ `6b5c6ba`;
  revert = `git reset --hard checkpoint/pre-diagnostics-2026-07-07`)

### Why
Brian reports a fresh install still takes ~1 minute to become usable and first entry is
sticky — worse than expected after the build-9 pass. He wants to SEE what the app is doing
live. Verification of prior assumptions found one subagent claim wrong (REST clients DO have
a 10s per-request timeout via `HueAPIClient.buildRequest` — no 60s REST stall exists) and one
right (NUPnP had the bare-`URLSession.shared` 60s default). New prime suspect for the
fresh-install minute: the iOS **Local Network permission** reset — until Allow is tapped,
mDNS and direct LAN requests fail/stall, and nothing logged this. So this build makes the
cold start fully observable instead of guessing further.

### Did (16 commits, `0f329b5..a447953`)
- `HueHome/Core/Diagnostics/StartupTimeline.swift` — `mark()` emits `⏱️TL +<ms-since-process-
  start>  phase  (Δ ms)  detail` to console (DEBUG), OSLog `com.lightshade.app/Startup`, and an
  os_signpost event. True process start via `sysctl kinfo_proc`.
- `HueHome/Core/Diagnostics/MainThreadWatchdog.swift` (DEBUG only) — 100ms main-queue pings;
  stalls >250ms print `🧵HANG main thread blocked ~Nms (phase: <last mark>)` on recovery.
  Started from AppDelegate.didFinishLaunching.
- Probes wired: app-init/modelcontainer, first-frame, pairing-gate(+source), splash.route,
  discovery.{scan-start,mdns-found,mdns-timeout,resolve-waiting,nupnp-*}, pairing.{begin,success},
  tabs.task, configure/preload, loadAll.{begin,bridge-fetch.ok/FAIL(URLError code),fetch-done,
  total}, cache.write ms, sse.{connected,retry}, prewarm.{wait-begin,released(reason),per-tab},
  room-open. Old `⏱️PERF` prints converted to marks. `HueAPIClient.execute` logs one 🌐 line
  per request (method/path/status/ms/bytes; FAIL: URLError code). **Console filter:
  `⏱️TL|🧵HANG|🌐`.** `loadAll.bridge-fetch.FAIL code=-1009` = Local Network denial signature.
- Fixes: NUPnP explicit 10s timeout (was 60s default); `resolveEndpoint` NWConnection bounded
  at 10s (used to dangle forever on advertised-but-unreachable endpoints).
- Swift 6 cleanup, ALL of Brian's pasted warnings: unused values; allowBluetoothHFP;
  WatchWidgetStore CodingKeys (NOT `var` — that would silently start decoding bridgeID);
  nonisolated audio locks; RestSender mailbox typed `@Sendable @MainActor () async -> Void`
  (closures already ran on main; kills the 12 sending-closure warnings); assumeIsolated in
  queue:.main observers (Task{@MainActor} would defer .began past audio teardown);
  @ObservationIgnored+nonisolated(unsafe) activeParamBox; nonisolated Equatable ==;
  @MainActor TabNavRegistry/BridgeAnimationStore; nonisolated(unsafe) sessionOverride seam;
  nonisolated SharedKeychainStore/BridgePinStore/CacheKey (watch MainActor default);
  class-level @MainActor StudioViewModel (18 per-method annotations removed); orphan
  AppIcon.png removed from the appiconset.

### Validation
- Full suite green: 327 test cases passed (`xcodebuild test`, scheme `HueHome 1`).
- Clean build: **0 errors, 0 warnings**.
- Build bumped to 10 (all 12 pbxproj entries).

### Left
- Brian: fresh install of build 10 on device, console filtered `⏱️TL|🧵HANG|🌐`, capture the
  first-minute timeline. The phase that owns the minute becomes the next fix.
- Diagnostics stay in until cold start is confirmed smooth; then trim to essentials.

### Gotchas
- StudioViewModel is now class-level @MainActor — the ONE change with an executor delta
  (helper between-await bodies moved to main; struct filters, measured negligible). If Studio
  apply/stop ever feels heavier, look here first.
- The old `⏱️PERF` grep string is gone — grep `⏱️TL` now.

---

## 2026-07-07 - [Claude] FRESH-INSTALL PERF PASS: launch + pairing + post-pairing storm — MERGED TO MAIN

### Branch
- `ios-ref/hardening-p1-2026-07` → fast-forwarded to `main` (rollback
  `checkpoint/pre-freshfix-2026-07-08` @ `245dd5f`; revert = `git reset --hard` to it)

### Why
The earlier 9-stage perf pass fixed the WARM app but not fresh installs. Build-8 device
logs showed loadAll fast (444ms) but two `Gesture: System gesture gate timed out` events —
two real main-thread hangs (launch window; ~440ms post-pairing). Three exploration passes +
one design pass traced both; 8 staged fixes landed (build 9):

- `36d8f20` WidgetDataStore: cache the App Group UserDefaults instance (was a new instance
  per access; amplified by fresh-install cfprefsd domain detach).
- `6fb8616` Discovery: removed dead per-resolution legacy `hue_bridge_ip` Keychain write
  (SecItemDelete+Add on main per endpoint per scan round; modern pairing never reads it).
- `080fe93` WCSession activation moved out of App.init to AppRootView `.task` (was stacking
  an XPC handshake onto the pre-first-frame window with ModelContainer creation).
- `8728b58` Splash: keychain check before the dwell; unpaired users reach BridgeSetupView in
  ~0.7s instead of a fixed 2.1s (view only renders for unpaired/legacy users).
- `1db18f9` Studio `refreshCoverage` reuses `lightsByBridge` via new
  `UnifiedOrchestrator.cachedRawLights(for:)` when `lastLoadedAt` < 60s (was a fresh
  GET /light at tab prewarm, mid-storm, and on every rolodex change).
- `eeda214` RoomDetail skips the immediate `loadLights` refetch when seeded and
  `lastLoadedAt` < 30s (SSE keeps the open room live; stale/empty seed still refetches).
- `1209d94` CompositionStore first-launch seed written inside the detached task
  (was encode-20-presets + atomic write ON MAIN via MainActor.run). **Gotcha caught in
  testing:** `Data.write` ASSERTS (untrappable by `try?`) when `.atomic` and
  `.withoutOverwriting` are combined — the first cut crashed 100% of fresh installs at
  launch (7 crash logs, `persistSeed` frame). Fixed to `.withoutOverwriting` alone
  (create-only O_EXCL semantics preserve the M-13 no-clobber race guarantee; partial-file
  crash recovery already handled by readPresets). Verified by full suite on a freshly
  uninstalled app container — zero new crash logs.
- `e2108fe` Prewarm gated on first loadAll settling (isLoading false + lastLoadedAt set;
  demo escape; 3s cap) and realizes studio → scenes → more ONE per main-thread pass
  (was scenes+more in one transaction at 440ms = three cold tab compiles in one pass,
  the second gesture-gate hang). Tap-to-realize + iPad paths untouched.
- `a1d6df0` Build number → 9.

### Validation
- Per-stage targeted suites + FULL HueHomeTests suite green on a fresh app container
  (iPhone 17 Pro sim, scheme `HueHome 1`).
- TEMP `⏱️PERF` prints (loadAll + room-open) intentionally KEPT for Brian's on-device
  verification; remove in a cleanup commit once fresh-install smoothness is confirmed.

### Left
- On-device fresh-install verification (Brian): expect ~0.7s to bridge-setup page, no
  post-pairing hang, `⏱️PERF room-open … INSTANT`.
- Deferred by design: async/two-phase ModelContainer (fresh-store creation on main in
  App.init, ~1-2s once per install — wide regression surface vs one-time cost); dead
  Sync-engine stack removal; MoreView connectionStatus re-render trimming.

---

## 2026-07-07 - [Claude] Fix fatal AVAudioEngine crash + CoreData store-dir noise — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (rollback `checkpoint/pre-audio-coredata-fix-2026-07-07` @ `fc117d3`;
  revert = `git reset --hard checkpoint/pre-audio-coredata-fix-2026-07-07`)

### Did
Triaged a device log dump (CoreData error wall + a hard termination). Two real fixes:
- **P0 crash — `HueHome/Core/Audio/AudioAnalysisEngine.swift`.** The mic tap for the
  music-reactive/sync feature was installed *before* the `AVAudioSession` was set to
  `.playAndRecord` and activated, with no format validation. On a background→foreground
  restart the input route isn't ready, so `inputNode.outputFormat(forBus:0)` returns a null
  `0 Hz / 0 ch` format and `installTap` throws the uncatchable
  `IsFormatSampleRateAndChannelCountValid` assertion → `com.apple.coreaudio.avfaudio`
  termination (the "black screen you can't come back from"). Fix in `startEngineIfNeeded()`:
  configure + `setActive(true)` the session FIRST, then read the format, then a
  `guard format.sampleRate > 0, format.channelCount > 0` that defers (deactivates + returns
  false) instead of ever reaching a crashing `installTap`. Added `routeChangeNotification` +
  `mediaServicesWereResetNotification` observers so deferred/torn-down capture auto-recovers
  once the route is back (also covers the previously-unhandled Bluetooth/headphone hand-off).
- **P1 noise — `HueHome/HueHomeApp.swift`.** SwiftData's `default.store` lives in the App
  Group container (Core Data's `defaultDirectoryURL()` resolves there when an app-group
  entitlement exists — `group.com.huehome.pro`). The `Library/Application Support/` subdir
  isn't pre-created, so first launch spams `NSCocoaError 512 / errno 2` then self-recovers.
  Now pre-create that dir and pin `ModelConfiguration(url:)` to the EXACT existing path
  (`default.store`) — no data moves, noise gone. Confirmed `groupContainer` exists in no
  branch/stash/file, so this was default behavior, not a regression.

### Working
- Both changes compile: Debug build green, scheme `HueHome 1`, iPhone 17 Pro sim.

### Left
- **On-device verification (required, can't repro on Simulator):** enter sync/mic mode, churn
  background↔foreground + Bluetooth connect/disconnect 10+ times → app must not terminate;
  expect a benign `Input format not ready … deferring tap` log then auto-recovery.
- Upgrade-install check: existing local SwiftData (rooms/scenes/favorites/settings) still loads
  (proves the store URL still resolves to the same file).
- Not committed — awaiting user go / checkpoint tag per their rollback preference.

### Validation
- Debug build **green** and full **HueHomeTests suite green** (`** TEST SUCCEEDED **`,
  iPhone 17 Pro sim, scheme `HueHome 1`). On-device crash repro still required (route-dependent;
  can't be reproduced on Simulator).

### Gotchas
- `installTap` with an invalid format is a C++ assertion — NOT catchable by Swift `try`; the
  format guard is the only thing that prevents the crash. Do not remove it.
- The store filename/subpath must stay exactly `Library/Application Support/default.store`;
  renaming would orphan existing beta users' data.
- Benign log lines left as-is (documented): pre-pairing `hue_api_token` keychain miss, cfprefs
  app-group warning, TLS/TCP RST, UIAlertController width constraint, WCSession-not-installed.

## 2026-07-07 - [Claude] PERF PASS: launch + navigation smoothness — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (rollback `checkpoint/pre-perf-2026-07-06` @ `c01b814`;
  revert = `git reset --hard checkpoint/pre-perf-2026-07-06`, commits unpushed)

### Did
9 commits, each independently buildable + relevant tests green per commit; full HueHomeTests
suite green at the end (scheme `HueHome 1`, iPhone 17 Pro sim). Deep-dive triggered by report of
slow cold launch + ~4s page transitions. Root causes traced by 3 exploration passes, fixes
designed by 2 plan passes, then implemented:

- `b454095` **RoomDetail instant render** — RoomDetailView blocked on a fresh `fetchLights()`
  (10s timeout ceiling) behind a spinner on every push, ignoring data loadAll already had.
  Cache raw lights per bridge (`lightsByBridge`) + `cachedLightItems(for:)`; seed the VM so
  the room paints immediately, background refresh still runs. Cold/miss/demo keep the spinner.
- `065a23b` **CompositionStore off-main** — StudioViewModel's eager `@State` init (re-runs on
  every tab switch) synchronously read + JSON-decoded the whole composition library on main.
  Added `loadsSynchronously` flag (default true keeps all test constructions unchanged); Studio
  loads off-main via a pure `nonisolated static readPresets`. `ensureLoadedForMutation()` guard
  preserves the M-13 non-destructive contract; store is `@unchecked Sendable` (main-confined).
- `6ca9d8b` **SSE rebuild coalescing** — each SSE line triggered a full `allRooms`
  flatMap+sort+reassign. `scheduleSSERebuild` throttles to one trailing ~150ms rebuild;
  composes with the existing `isNavigating` deferral. loadAll/optimistic rebuilds stay sync.
- `3bda60e` **Self-echo guard** — a composition's own ~8Hz REST PUTs echo back as SSE and
  rebuilt the dashboard at frame rate. `appDrivenGroupIDs` suppresses those rooms' SSE
  mutations; `stopCompositionMode` calls `scheduleStateRefresh()` to re-sync after.
- `01979ce` **Tab-visibility env key** — opacity switcher keeps all 4 tabs mounted, so scene
  PatternStrips (12fps) + Studio canvases (up to 60fps, gated on deck not tab) animated behind
  the visible tab. New `\.isTabActive` (default true) pauses them when off-screen.
- `7eb84dd` **Beat + dashboard timers** — BeatStatusChip (20fps even at bpm 0), dashboard
  clock, and NextAutomationBanner ticker (1s, allocating a formatter per tick) gated on
  `isTabActive`/idle; ticker 1s→10s; shared cached `RelativeDateTimeFormatter`.
- `db76ddc` **Per-host TLS pins** — loadAll awaited `ensurePins` for ALL hosts up front, so one
  offline unpinned bridge stalled every bridge's first fetch ≤10s. Moved per-host into each
  fetch task. Security posture unchanged (no Trust/ edits).
- `75393ba` **Defer entertainment cleanup** — stuck-session GET ran inside loadAll's await on
  every launch/foreground AND ~1.5s after every toggle. Now fire-and-forget `.utility`,
  throttled 60s. DEBUG `testAwaitEntertainmentCleanup()` hook keeps LOAD-01 deterministic.
- `2d4f739` **Mic-demand cache** — composition loops called `refreshCompositionMicDemand`
  (actor hop) every frame; cache last value, early-return when unchanged.

### Left / Deferred (deliberately NOT done)
- **Dead Sync-engine stack removal** (`SyncModeEngine`/`VisualizerEngine`/`GamingEngine`/
  `AmbientEngine`) — verified never instantiated, but removal needs pbxproj surgery + careful
  extraction of the live `RestSender` actor (defined in `SyncModeEngine.swift`, used by the
  orchestrator). Zero runtime gain; skipped this pass per Brian. Separate cleanup PR.
- **CompositionEngine.render off main-actor** — deferred by design: it's O(≤20 channels) at
  8–25Hz (µs) and mutates the MainActor-confined `CompositionParamBox` (audit I-10); moving it
  off-main risks data races for negligible gain. Revisit only if os_signpost shows it matters.
- Optional follow-up: keep `lightsByBridge` fresh from SSE (Stage 1 seed can be seconds stale
  until the background `loadLights()` returns — sub-second in practice).

### Validation
- Per-commit: targeted `xcodebuild test -only-testing:...` (Orchestrator SSE/LoadAll/Optimistic/
  CacheDemo, MultiBridgeRouting, NonDestructivePersistence, BeatMath/CompositionMixer,
  StageKit, EntertainmentRobustness, BridgeTrustEvaluator, CompositionReaction, AudioFeatureCore).
- Final: full `HueHomeTests` suite green. Only pre-existing warning is `RoomCard: Equatable`
  main-actor isolation (not introduced here).
- NOT yet done: on-device manual smoke (tap a room <2s after launch → instant lights; rapid tab
  switching; run a Studio effect then sit on Home → CPU gauge; toggle → no entertainment GET in
  60s). Recommend before TestFlight.

### Gotchas
- `run_tests.sh` still has a stale `SCHEME="HueHome"`; use `-scheme "HueHome 1"`.
- CompositionStore `@unchecked Sendable` invariant: `presets`/`isLoaded` mutated only on main
  (sync load on the constructing main context; async path applies inside `MainActor.run`).

---

## 2026-07-06 - [Claude] ROUND 4 COMPLETE: Stage redesign + Effects port + Scenes library — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` @ `72147dd` (rollback `checkpoint/pre-round4-2026-07-06`;
  revert = `git reset --hard checkpoint/pre-round4-2026-07-06`, branch unpushed)

### Did
13 commits, each independently shippable, build + full suite green per commit:
- `622ece3` **R4-1 extract:** Composer editor (33 members, ~1,300 lines) → new
  `UI/Composer/CompositionEditorPanel.swift` (new pbxproj UI/Composer group). Pure move; panel
  owns transient state incl. the five @State the plan's input list missed (hue-pad quartet +
  entertainment-builder flag). `applyHarmonyToComposition` deliberately stayed in StudioView —
  its only caller is the body-level harmony-restore onChange, which must fire while the tray is
  closed. StudioView 3,160 → 1,868 lines.
- `fa1a39b` **R4-2 extract:** mixer tray → `UI/Studio/MixerTrayView.swift` (header, content
  switch, drag gesture, badge helpers, studioBeatBinding). Save-sheet presentation hoisted to a
  StudioView body-level .sheet; collapse/expand + height math stayed (Live Controls pill + card
  taps use them). StudioView → 1,503 lines (plan's <1,400 assumed save sheet/height math moved).
- `379fc3e` **R4-3 StageKit:** StageCard/StageSlider/PatternStripView/StageBadge + StagePalette
  tokens in `UI/Components/StageKit.swift`. Strip = pure `StageStripMath.opacity(index:pattern:time:)`
  under TimelineView(1/12), distinct signatures for all 10 patterns, Reduce Motion → static 0.6.
  New StageKitTests (7): bounds, determinism, periodicity, pairwise distinctness, hot-cell travel.
- `5559818` **R4-4 Composer reskin:** four layer StageCards, 16 sliders → StageSlider, live
  Motion strip, stage tab pills. Presentation only.
- `57152c2` **R4-5 beat unification:** BeatPanelView gains `reaction:` binding rendering punch
  decay / quantized color step / motion lock via the R3-A capability flags (first `.composer`
  consumer); bespoke reactionBeatControls deleted; segmented pickers → ChipPickerRow pills;
  auto-scroll anchor intact.
- `889a843` **R4-6 deck reskin:** running cards show PatternStripView (composition = preset's
  pattern, engine = decorative bounce), stage deck pills, mixer-header badges.
- `20bb780`+`b69e926` **Effects port (approved scope change):** discovered the Effects + Sync
  tabs left navigation in v0.15.0 — EffectsView/EffectsViewModel/SyncModeView were UNREACHABLE
  dead UI, and R3-B's effects_v2 work had landed only there, invisible to users. Ported to
  Studio Deck 0: 4 new cards (Cosmos/Enchant/Sunbeam/Underwater) + speed on Opal/Glisten;
  per-light v1 blanket THEN gate-paced per-light effects_v2 upgrade (KEPT Studio's per-light
  blanket — the dead code's grouped_light effects blanket contradicts
  StudioStrategy.groupedLightOnlyEffects); live speed/tint sliders re-parameterize the running
  effect per-light via mailbox+gate; coverage badges ("N OF M LIGHTS") on cards + mixer header
  via EffectCapabilityResolver with demo guard. THEN deleted the five dead files (~3,000 lines;
  EffectParamState → SavedEffectPreset.swift, Array[safeIndex:] → AppAutomation.swift first),
  removed the dead Music Sync/Gaming cards + `.studioStartMicSync` (zero observers), migrated
  MultiBridgeRoutingTests 3-for-3 (H-05 → StudioViewModel.apply; M-17 fan-out +
  app-driven-fallback → applyAutomationEffect). New StudioEffectsV2Tests (4).
- `1ab27b1` **R4-7 sequence persistence:** PerformanceViewModel presetID + store; preload on
  open; "Save with composition" in the sequence sheet (disabled for unsaved; the "+ Create"
  draft SENTINEL `composerStarterDraftPresetID` counts as unsaved — never nil as the plan
  assumed). CompositionStore.fileURL test-injectable; store round-trip test.
- `84835b5`+`27f6a74`+`72147dd` **Scenes library (approved scope):** SceneProvenanceStore
  (STUDIO badges on Composer-exported dynamic scenes via createSceneReturningID; key ==
  GlobalSceneItem.id, test-locked) + favorites on the tab (RAW bridgeSceneID CSV contract,
  order-preserving FavoriteSceneCSV helpers) + full StageKit reskin (zero Color(red literals,
  VoiceOver labels, Reduce Motion) + unified creation: toolbar + menu → Capture Room Look /
  Build Colors… (new SceneBuilderLauncherView room picker → existing SceneColorBuilderView;
  LightDisplayItem(from: HueLight) shared mapping). SceneProvenanceStoreTests (9) + mapping test.

### Working
- Full suite **327/327** green (305 → 327; count never dropped). Build gate green per commit.
- One visual system across Composer editor, Studio decks, mixer, Perform, and Scenes.

### Left
- **On-device (Brian):** Round-3 checklist (audit doc §4/§4b/§6.3) still pending, plus new:
  cosmos/enchant/sunbeam/underwater run + speed slider visibly changes a v2 light; per-light
  v1 `no_effect` on stop clears a v2-parameterized effect; colorloop card now honestly shows
  "NOT SUPPORTED" on modern firmware (colorloop is not an effects_v2 value — expected); 10-min
  composition + Perform soak for editor-refactor regressions; sequence save → force-quit →
  reopen Perform; Scenes export → STUDIO badge; favorites Scenes↔Dashboard↔RoomDetail.
- **Follow-ups:** Dashboard Now-Playing bar + Tap-Dial punchBurst read `activeEffectEntries`,
  whose only writer died with EffectsViewModel — wire StudioViewModel in or remove the bar.
  `.studioStopAll` posts with zero observers (same dead-wire class). EffectEngine.swift +
  SyncModeEngine engines are production-orphaned but keep RestSender + gate-pacing tests —
  candidates for a later cleanup. All-Rooms one-tap UI dropped with the dead surface
  (automations + Home-zone selection cover it).
- **Test flake (pre-existing):** KeychainSharingTests.testForgetAllClearsSharedCredentialSurface
  intermittently races KeychainManagerTests' legacy keychain writes through WidgetDataStore's
  legacy-credential fallback under parallel scheduling (seen twice, passes in isolation and on
  re-run). Fix = keychain test isolation; out of R4 scope.

### Validation
- Per commit: `xcodebuild … "HueHome 1" … build` gate + full suite on iPhone 15 / iOS 17.0.
- Extraction commits verified by rg (no moved symbol left behind) + diff symmetry.
- New tests: StageKitTests 7, StudioEffectsV2Tests 4, SceneProvenanceStoreTests 9, sequence
  store round-trip 1, LightDisplayItem mapping 1, MultiBridgeRoutingTests 3 migrated.

### Gotchas
- pbxproj: Studio UI files live under a group literally named "Scenes"; the only pre-R4
  "Composer" group is Core's (and holds PerformanceView.swift). New UI/Composer group is
  C0DEC0DE0138…; indexes now consumed through 013F.
- setLightEffectV2 is an HueAPIClient EXTENSION method — spies must override the
  `put(path:body:ip:token:)` class seam, not the extension.
- EffectCapabilityResolver is v2-first: a light exposing any effects_v2 list is judged only by
  it (its v1 list is ignored) — the honest reason colorloop shows NOT SUPPORTED.
- StageStripMath must stay a pure function of (index, pattern, time) — StageKitTests locks
  bounds/periodicity/distinctness; don't add state.
- Favorites CSV = RAW bridgeSceneID (never "bridgeID:sceneID"); provenance keys = the composite
  GlobalSceneItem.id. Both formats are test-locked.

## 2026-07-06 - [Claude] ROUND 3 COMPLETE: Perform surface + step sequencer (R3-C/D) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` @ `fff1451` (rollback `checkpoint/pre-round3-2026-07-06`)

### Did
- `fbb533e` **R3-C Perform:** Core/Composer/CompositionMixer — PerformanceMixBox (deck A = the
  LIVE composition's param box, mix keyed by IDENTITY; deck B cues presets) + renderMixed at
  the render chokepoint: frame-lerp blend, punch pads post-blend (strobe ≤3 Hz hard cap, rides
  the beat under 180 BPM; blackout; white burst; 200 ms release ramps), master fader,
  beat-exact bar auto-fade DERIVED per frame. Orchestrator seam = one activePerformanceMix
  property consulted by both DTLS + REST loops. UI/Performance/PerformanceView full-screen
  cover from the running Composer deck's amber button: crossfader + FADE 4/8/16,
  hold-to-engage pads (REST tier also fires signaling punchBurst), queue with
  promote-and-advance (deck B layers copied INTO the live box — loop identity never breaks),
  shared .global beat panel, idle timer off.
- `fff1451` **R3-D sequencer:** CompositionSequence (self-contained step snapshots, hold-bars +
  crossfade-beats, M-13-grade decode) + optional preset.sequence (nil-additive, round-trip
  tested) + SequencePlayer driving the same mix (hold → cue → beat-exact fade → promote; loop
  or once; startAutoFade(beats:) added, no-clock fades land instantly). Sequence sheet in
  Perform: reorderable step cards, per-step bars/XF menus, capture-current-look, Loop, Play/Stop.

### Working
- Full suite 305/305 green on iPhone 15 / iOS 17.0. **Round 3 fully executed:**
  R3-0 docs → R3-A beat panel (7) → R3-B Hue power (A–G) → R3-C Perform → R3-D sequencer.
  25 commits ahead of the checkpoint tag, all local/unpushed.

### Left
- **NEXT: Round 4 — Studio & Composer UX/UI revamp.** Build-ready, per-commit plan (verified
  member inventory, extraction map, StageKit component specs, acceptance criteria) is in
  `docs/ios/round4-studio-composer-revamp-plan.md` — written explicitly so a fresh context
  window can execute it from the docs alone. Summary: R4-1/2 extract Composer +
  mixer tray out of the 3,160-line StudioView (pure moves) → R4-3 StageKit (cards, sliders,
  animated pattern strips, badges) → R4-4/5/6 reskin Composer editor (incl. BeatPanelView
  .composer unification, deleting bespoke reactionBeatControls), Studio decks, Effects cards
  → R4-7 sequence-persistence UI (preset.sequence model already shipped) → R4-8 docs.
- On-device validation (audit doc §4/§4b/§6.3) — needs a physical bridge + lights.
- Backlog (unchanged): Effects/Sync-tab consolidation, keyframe timeline (rejected), ML downbeat.

### Gotchas
- The Perform mix is keyed to its composition by deckA IDENTITY — promotion must COPY layer
  structs into deckA (never replace the box reference) or the render loop goes stale.
- PerformanceViewModel is created at button tap, NOT inside the fullScreenCover closure
  (SwiftUI re-evaluates cover content; inline creation would rebuild the VM mid-performance).
- Strobe punch clamps at 3 Hz free-run above 180 BPM; below it, flashes ride beatPhase.

## 2026-07-06 - [Claude] R3-B Hue power COMPLETE — phases A–G (7 commits) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` @ `c59f1b4` (rollback `checkpoint/pre-round3-2026-07-06`)

### Did
- `06146e7` **A foundation:** HueLight decodes effects/effects_v2/timed_effects/gradient
  (additive); pure golden-JSON body builders (EffectsV2Body/TimedEffectsBody/SignalingBody/
  GradientBody) in HueAPIClient+Effects/+Signaling/+Gradient; EffectCapabilityResolver
  (v2-first coverage, never model-ID guessing); dead setGroupedLightWithEffect/stopLightEffects
  deleted.
- `9e6ba2e` **B effects_v2:** Cosmos/Enchant/Sunbeam/Underwater/Opal/Glisten cards; v1 grouped
  blanket THEN per-light v2 parameter upgrade (speed/color now REAL); "4 of 6 lights" coverage
  badges + coverage-aware status.
- `fa65824` **C timed_effects:** TimedEffectRouting — native bridge sunrise/sunset when all
  lights support + card at defaults (survives force-quit); else app ramp; failed native starts
  cancelled. clearFirmwareEffect merges effects:no_effect into the same PUT (effects outrank
  timed_effects).
- `5b7243f` **E dynamic scenes:** CreateSceneRequest.palette/speed/auto_dynamic (nil-additive,
  wire-compat locked by test) + dynamicScene builder; Composer Color tab → "Save as Hue dynamic
  scene" (bridge loops it forever, app closed).
- `3451e20` **D signaling:** SignalingService (identifyLight/identifyRoom/punchBurst — the
  REST-tier Perform punch primitive); beacon button in light detail toolbar.
- `d8b1c4b` **G Tap Dial:** SSE button/relative_rotary decode; pure ControlMappingEngine
  (100 ms leading-edge rotary accumulator; DJ button map); orchestrator executes actions
  (tap/resync/nudge/punchBurst on the playing room); PhysicalControlsView in More with DJ Mode
  toggle (UserDefaults chromaglow.djModeEnabled).

- `c59f1b4` **F gradient (was highest-risk, landed last):** pure GradientChannelMap (strip →
  ≤5 virtual render channels, budget 20, every light keeps 1 channel first, nil map = flat
  path byte-identical); REST composition scheduler gradient-aware branch (strip channels =
  ONE gradient.points PUT with dimming/on/dynamics); entertainment builder two-position
  service_locations for strips + refetch-after-create (fabricated-channel bug fixed).

### Working
- Full suite 294/294 green on iPhone 15 / iOS 17.0; build gated per commit.

### Left
- Perform surface (R3-C, per published spec artifact: crossfader/pads/queue; punch pads use
  punchBurst on REST tier, Tap Dial drives tempo, .global beat panel) + sequencer (R3-D).
- On-device checklist: audit doc §6.3.

### Gotchas
- bridgeNative order matters: v1 grouped blanket FIRST, then per-light v2 upgrades — reversed
  order would let the grouped call clobber v2 parameters.
- effects outrank timed_effects on the bridge — always clear in the same PUT.
- Static scene POST bodies must stay byte-identical (test-locked) — palette/speed/auto_dynamic
  are encodeIfPresent.
- Tap Dial: use initial_press (not short_release) for tap tempo/punch latency.

## 2026-07-06 - [Claude] R3-A Universal Beat Panel shipped (7 commits) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` @ `fba63a2` (rollback tag `checkpoint/pre-round3-2026-07-06`)

### Did
- `b2cc84a` Core/Audio/BeatBinding.swift: BeatBinding (off/beatLocked, ¼…8 beats/cycle, phase
  offset; self-sanitizing decode) + pure BeatMath (cyclePhase/cycleIndex/nextCycleBoundary,
  wcagSafeBeatsPerCycle ≤3 Hz clamp); EffectParamState.beat + SavedEffectPreset.beat? (nil-
  additive); BeatClock.setBeatsPerBar. 21 tests (BeatMathTests).
- `908b265` UI/Components/BeatPanelView.swift: capability-driven shared panel
  (BeatPanelCapabilities .global/.composer), BeatStatusChip (pulsing), ChipPickerRow (one-tap
  pills), manual BPM stepper + ±10 ms nudge UI.
- `d9601f6` Six beat-blind loops consume BeatSnapshot: EffectLoops strobe/party/thunderstorm
  (boundary-locked; box-based live binding) + Studio strobe/party DTLS (pure phase-derived
  per-frame), REST variants bar-boundary synced (maxHz floors 1/0.9 & 1.0), ambient breathes
  with the bar. BeatMath.liveLock + chunked sleepUntilNextCycle + BeatBinding.fromStudioValues.
- `debf7b4` BeatChipButton (chip+popover) on Dashboard NowPlaying, Studio mixer header (binding
  routed through setParamValue → live box), Effects running banner (EffectsViewModel.beatBinding
  + BeatBindingBox so edits land mid-run without restart).
- `197fd76` Pattern/Shape/Source .menu pickers → one-tap icon pill rows.
- `f702f2e` Transport dialog remembers first choice; deck dots → named tappable pills.
- `fba63a2` "Beat" quick-toggle in mixer header (1-tap beat-reactive composition) + auto-anchor
  scroll to beat controls.

### Working
- Full suite 262/262 green on iPhone 15 / iOS 17.0; build gated per commit.

### Left
- R3-B Hue power phases A–G (capability foundation → effects_v2 → timed_effects → signaling →
  dynamic scenes → gradient LAST → Tap Dial), then Perform (R3-C), sequencer (R3-D). Design +
  matrix: audit doc §6.

### Gotchas
- Studio beat binding MUST go through StudioViewModel.setParamValue (writing activeParamBox
  directly gets clobbered by the next slider push).
- EffectsViewModel.beatBinding suppresses the 350 ms $paramState re-apply debounce (500 ms
  delayed reset pattern) — without it every panel tweak restarts the running loop.
- REST loops beat-sync at boundaries with a cadence floor via wcagSafeBeatsPerCycle(maxHz:) —
  1/0.9 Hz (grouped-light strobe), 1.0 Hz (party/ambient); DTLS loops derive phase per frame.

## 2026-07-06 - [Claude] Round 3 kickoff: Hue capability deep-dive + approved design (docs handoff) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (rollback tag for this round: `checkpoint/pre-round3-2026-07-06`;
  revert = `git reset --hard checkpoint/pre-round3-2026-07-06` — branch is unpushed)

### Did
- Deep-dive into unused Hue capability (verified by code inventory + API research) → capability
  matrix recorded in `docs/ios/composer-studio-mic-audit-2026-07-06.md` §6: effects_v2 (real
  params + 4 absent effects), gradient.points/segments, native timed_effects, signaling
  (incl. punchBurst), dynamic scene authoring, Tap Dial `relative_rotary`/`button` SSE events,
  dead client methods. Plus beat/flow gap audit (six beat-blind loops, 3-tap beat panel, 2-tap
  menus, per-apply transport dialog).
- Design approved by Brian: **"One Clock, Full Bridge, Two Taps"** — user-confirmed order
  **Beat panel → Hue power (A–G, Tap Dial IN) → Perform → Sequencer**. Full design + phasing in
  audit doc §6.2 and the session plan file (deep-dazzling-prism).
- Refreshed the published design-spec artifact (mockups for beat panel, two-tap flow, A–G
  capability cards, Perform, sequencer): https://claude.ai/code/artifact/52839d43-4209-403f-98d3-b16f073b1ad0

### Working
- Nothing code-side yet this round — this entry is the docs handoff so any fresh context window
  can continue from §6 of the audit doc alone. Suite remains 241/241 green at `4658a00`.

### Left
- R3-A commits 1–7 (BeatBinding/BeatMath → BeatPanelView → loop consumption → global chips →
  flow fixes), then R3-B phases A–G, then Perform (R3-C) and sequencer (R3-D).

### Gotchas
- REST tier must beat-sync at BAR boundaries only (BridgeCommandGate ~10 cmd/s); per-beat locking
  is DTLS-only.
- `wcagSafeBeatsPerCycle` clamp is loop-side and mandatory (174 BPM × ½-beat → ×1).
- Gradient work (R3-B F) is highest-risk and deliberately last REST feature; entertainment-config
  builder needs refetch-after-create to stop fabricating channels.
- Never accumulate beat phase in loops — always derive from `BeatClock.snapshot()` per tick.

## 2026-07-06 - [Claude] Phase 2: DJ-grade audio core + world-class motion engine (4 commits) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (continues the Phase-1 session below)

### Did
- `5aa391b` Core/Audio pure trio: AudioFeatureExtractor (AGC bands, spectral-flux onsets, 6 s onset
  ring), TempoEstimator (windowed autocorr + comb, smallest-strong-lag beats the subharmonic trap,
  hysteresis, beat phase), BeatClock (tap/manual/audio-follow, ≤30 ms phase nudges, BeatSnapshot
  mirror for render threads). 20 synthetic-signal tests.
- `ff97e9c` Motion/reaction engine: MotionConfig.sample() → (phase, weight); **spread + randomize +
  smoothing + color/speed targets all functional** (were dead knobs); 5 new patterns (chase, comet,
  pulseCenter, spiral, twinkle) with real radial/angular room geometry; beat-locked cycles
  (motionBeatsPerCycle), quantized color stepping, per-beat brightness punch. All Codable additions
  migration-safe. 16 new tests.
- `1484b3f` AudioAnalysisEngine: single capture owner (demand refcounts, interruption recovery,
  buffer fan-out, ~2 Hz tempo pass → BeatClock). CompositionMicCapture + the exclusivity handshake
  DELETED; Sync engines consume a tap; audit L-05 closed. Session stops ducking music (DJ req).
- Editor: Spread/Randomize/Attack/Decay/DutyCycle controls; beat panel (live BPM, Tap/Auto/Sync-1,
  punch decay, quantize, beats-per-cycle); mic-denied toast (dead wire closed). Holiday presets
  now use the new math (chase/twinkle/comet; NYE is beat-locked).

### Working
- Full suite 241/241 green on iPhone 15 / iOS 17.0 after every commit; builds gated per commit.

### Left
- On-device: BPM lock on real music, new-pattern spatial character, un-ducked playback (audit doc §4b).
- Phase 3 (performance surface: crossfader/pads/queue — also resolves the .studioStartMicSync dead
  wire), Phase 4 (step sequencer, richer palettes) per approved plan.

### Gotchas
- TempoEstimator MUST use windowed autocorrelation + smallest-strong-lag: fractional beat periods
  split energy across adjacent integer lags and a plain argmax picks the half-tempo subharmonic.
- spread=100 must keep motion weight ≡ 1 — that is what preserves every existing preset's look.
- AudioAnalysisEngine buffer-tap closures are @Sendable and run on the audio thread: no MainActor
  property reads (use nonisolated(unsafe) snapshots à la tapEngineType).

## 2026-07-06 - [Claude] Composer/Studio/mic audit + Phase-1 reliability hardening (8 commits) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (checkpoint tag `checkpoint/pre-phase1-composer-2026-07-06` at `83e8ab4` for rollback)

### Did
- Full Composer/Studio/Effects/Sync/mic subsystem audit → `docs/ios/composer-studio-mic-audit-2026-07-06.md`.
  **Scrap-vs-salvage decision: SALVAGE** — pure `CompositionEngine` render core, migration-safe models,
  fixed M-13 persistence, and freshly hardened transports stay; audio analysis + reaction layer +
  performance primitives get rebuilt in the DJ phases (plan approved by Brian).
- Phase-1 fixes, one commit each, all build-gated on scheme `HueHome 1`:
  - `c88409d` M-16+L-44: stored/cancellable per-room Turn-Off-at-End timers.
  - `2eadf89` M-17: "All Rooms" wired via applyToAllRooms (per-bridge routing; app-driven refused);
    fixed a `$selectedRoom`-sink race that could abort fan-outs mid-flight.
  - `a47f185` L-41+L-54: preset params clamped to schema on restore; trap sites self-clamp.
  - `ad080de` Sync interruption/background auto-resume; in-flight starts generation-guarded (L-19 class).
  - `630b5ab` L-19/L-22/L-23: Composer mic guard-after-await + AVAudioApplication API; Open Settings
    deep link; mic consent copy.
  - `9c4040d` L-20/L-21: new `Core/Audio/AudioSpectrumProcessor` (cached FFT for both mic pipelines;
    only pbxproj edit of the phase); inclusive bar-peak count.
  - `799573d` M-10 follow-through: `isTerminallyFailed` on the entertainment client; Composer loop
    fails over to the REST scheduler (same live paramBox); Sync flips to REST visibly.
  - `94d14e8` Studio sendParam/sendColorParam routed through the studio RestSender mailbox.

### Working
- Builds green after every commit; test suites green on iPhone 15 / iOS 17.0:
  MultiBridgeRoutingTests 7/7 (new All-Rooms fan-out + app-driven refusal),
  HueDataModelsTests (+4 sanitizer cases), EntertainmentRobustnessTests 7/7 (new terminal-failure case).

### Left
- On-device checklist (M-10 reconnect, DTLS→REST failover, call-interruption resume, All-Rooms
  multi-bridge, slider scrub) — §4 of the audit doc.
- Dead wires documented, deliberately deferred to Phase 2: unobserved `.studioStartMicSync`
  (Studio mic/gaming cards no-op) and `.compositionMicPermissionDenied` (silent Composer denial);
  ReactionConfig `.color`/`.speed` targets still inert until the beat-clock work.
- DJ phases 2–4 (unified audio engine + BeatClock, performance surface, sequencer) per approved plan.

### Validation
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' build`
  after every commit; targeted `-only-testing:` runs on `platform=iOS Simulator,name=iPhone 15,OS=17.0`.

### Gotchas
- EffectsViewModel's Combine sinks deliver asynchronously — anything that mutates selection state must
  respect `isActivating`, and nested `activate()` calls must save/restore (not set/clear) that flag.
- `AudioSpectrumProcessor` is single-writer-per-tap-thread BY CONTRACT (no hot-path locks); the composer
  exclusivity handshake is what makes the ComposerMicLevels static instance safe.
- `stop()` in SyncModeEngine must clear `resumeAfterInterruption` BEFORE its early-return guard, or a
  user stop during a phone call zombie-resumes.

## 2026-07-02 - [Claude] Widgets round-4 — paginated Large widget + interactive Lock Screen (build 5) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07`

### Did
On-device (TestFlight build 4) feedback: user sees rooms/zones from **both bridges in the app**, but
**not all appear on the Home-Screen widget**; wants the Large widget to "handle as many devices as
people have," be fully functional (on/off, edit, effects, brightness), and wants **Lock-Screen
control** of lights.
- **Hard platform constraint stated up front:** WidgetKit widgets **cannot scroll** (Home Screen or
  Lock Screen). Delivered the underlying goal via **pagination** instead — the native iOS pattern.
- **Verified the data source is complete:** `scheduleWidgetWrite()` publishes **all** `allRooms` +
  `allZones` across every bridge (no cap/filter). So the snapshot already contained every device; the
  old `prefix(...)`/per-bridge-section caps were the *only* reason bridge-2 devices were hidden.
- **Large widget → paginated.** New shared page index (`hue_widget_large_page` in the App Group) +
  `WidgetPageIntent(direction:pageSize:)`. Entry gained `orderedGroups` (bridge-clustered: rooms then
  zones per bridge, sorted by bridge name), `largePageSize = 6`, `largePageCount`, `clampedLargePage`,
  `largePageGroups`, `bridgeLabel(_:)`. Provider clamps the stored page as device count changes
  (`clampedPage`). New `LargePageBar` (◀ / "Page X of Y · N lights" / ▶, buttons disabled at ends).
  Rows keep toggle + −/+ brightness; a slim bridge header marks each bridge boundary within a page;
  preset "effects" strip retained. **Every room + zone across every bridge is now reachable.**
- **Per-row deep link:** each Large row's icon/name is now a `Link(lightshade://room|zone/{id})` →
  taps open that specific room/zone in the app ("go into an edit"). Scheme + `onOpenURL` already wired.
- **Lock Screen is now interactive** (iOS 17+): pinned **circular** tap **toggles** the room (gauge
  shows brightness / "off"); pinned **rectangular** gained **−/+ brightness** buttons alongside the
  existing power toggle. Unpinned accessories stay glanceable (tap opens app).
- Build number 4 → 5.

### Validation
- `HueHome 1` Debug (simulator) + Release (generic device) builds green.
- `WidgetTimelineRobustnessTests` pass (store change is additive — new key + accessor only).

### Left
- Confirm on TestFlight (build 5): Large widget paging reaches **every** device on both bridges; row
  tap opens the room; Lock-Screen circular toggles a pinned room and rectangular −/+ dims it.
- Widgets genuinely can't scroll — if the user still wants "one screen, all devices," the only lever
  left is smaller rows / more per page (legibility tradeoff) or multiple pinned widgets.

---

## 2026-07-02 - [Claude] Widgets follow-up — Large widget per-bridge sections (build 4) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07`

### Did
On-device (TestFlight build 3) feedback: **watch complication works**, but the Home-Screen widget
"only shows one bridge" and felt limited (user mainly uses the **Large** widget).
- **Root cause:** `allRooms` is sorted **alphabetically across all bridges**
  (`DashboardDisplayModelBuilder.makeRooms`), and the widget views capped with `prefix(4/6)`. If the
  first bridge's rooms sort first, the second bridge's rooms fell off the cap → "bridge 2 missing."
  (Credentials + snapshot already include every bridge — it was purely a display cap.)
- Added `bridgeName` to `WidgetRoomSnapshot`, populated in `scheduleWidgetWrite()` via the
  orchestrator's existing `bridgeName(for:)`.
- Entry gained `bridgeSections` (rooms+zones bucketed per bridge, sorted by bridge name),
  `isMultiBridge`, and `balancedRooms(max:)` (round-robin across bridges).
- **Large widget**: when multi-bridge, renders **one section per bridge** (bridge name header +
  on/total + that bridge's rooms + a zone), so **every bridge is guaranteed a slot**; single-bridge
  layout shows more rows (up to 7). **Medium widget**: 2×2 grid now uses `balancedRooms` so both
  bridges appear instead of the alphabetical first four.
- Build number 3 → 4.

### Validation
- `HueHome 1` Debug + Release builds green.

### Left
- Confirm on TestFlight (build 4) that both bridges now show on the Large widget with per-bridge
  headers. If bridge 2 is *still* absent, the snapshot itself lacks it → app-side load issue for that
  bridge (not the widget), which would be the next thing to chase.

---

## 2026-07-02 - [Claude] Widgets — robust multi-bridge Home/Lock/Watch (zones + scenes + brightness) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07`

### Did
Beefed up all three widget surfaces to control **all rooms AND zones across every bridge**, extending
the already-shipping direct-control model (shared Keychain creds + App-Group snapshots + shared
`BridgePinnedTrustDelegate`). Robustness-first for a TestFlight-only ("perfect in one go") ship.
- **Shared stores** (`WidgetDataStore.swift`): added `kind` (room/zone) to `WidgetRoomSnapshot`,
  new `WidgetSceneSnapshot`, `write(rooms:zones:scenes:)`, `zones`/`scenes`/`groups` accessors,
  `applyOptimistic`/`markAllGroupsOff`. `scheduleWidgetWrite()` (`UnifiedOrchestrator.swift`) now
  publishes zones (were computed but only sent to the watch) + scenes (from `globalScenes`);
  `WatchSessionManager.push` carries `wc_scenes_v1`.
- **iOS widget** (`HueHomeWidget/`): intents generalized to groups (`ToggleRoomIntent`), new
  `AdjustBrightnessIntent` (±) and `ActivateSceneIntent` (scene recall); `ApplyPreset`/`AllOff` now
  cover rooms+zones. Views: Large shows a Zones section + per-row −/+; Focused Medium is fully
  interactive (toggle + −/+ + scene chips); Focused Small got a toggle + −/+; Medium cells are
  toggles; Lock-Screen rectangular got one toggle. Config entity is now room-OR-zone (+ `showScenes`).
  **Timeline refresh fans out one bounded fetch PER bridge concurrently** (was primary-bridge only).
- **Deep-link**: registered `lightshade` URL scheme (`HueHome/Info.plist`) + `DeepLinkCoordinator`
  + `onOpenURL` (`HueHomeApp.swift`); `MainTabView` switches to Home on a widget tap; `widgetURL`
  is now per-group (`lightshade://room|zone/{id}`), previously inert.
- **Watch app** (`LightShadeWatchApp Watch App/`): presets/All-Off + toggle/brightness now handle
  zones; scenes decoded/persisted/mirrored; `recallScene`; **bounded multi-bridge GET refresh on
  foreground** (was drift-until-phone-pushes); RoomDetail shows a Scenes section.
- **Watch complication** (`LightShadeWatch/`): reads zones; pin-a-zone config; entry resolves
  pinned zones.
- **Ships the watch complication (the big blocker):** it was built but embedded nowhere and unsigned.
  Via the `xcodeproj` Ruby gem: added an **Embed App Extensions** copy phase to the Watch App
  (embeds `LightShadeWatchExtension.appex` in its PlugIns), added the target dependency, set
  `CODE_SIGN_ENTITLEMENTS = LightShadeWatch/LightShadeWatch.entitlements` (App Group).
- **Clean-install ATS**: `NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription` on the widget
  Info.plist; `INFOPLIST_KEY_NSLocalNetworkUsageDescription` on the Watch App (the likely on-device
  LAN-permission gap).

### Working / Validation
- **BUILD SUCCEEDED** for `HueHome 1` (Debug + Release, iOS sim), `LightShadeWatchApp Watch App`, and
  `LightShadeWatchExtension` (watchOS sim).
- **Proved both extensions embed**: `HueHome.app/PlugIns/HueHomeWidgetExtension.appex` AND
  `HueHome.app/Watch/…/PlugIns/LightShadeWatchExtension.appex`. Complication `-Simulated.xcent`
  carries `application-groups → group.com.huehome.pro`.
- Existing `WidgetTimelineRobustnessTests` + `KeychainSharingTests` **all pass** (no store/keychain regressions).

### Left (on-device, TestFlight only)
- Interactive control on real bridges; the local-network permission prompt on a clean install
  (grant it before relying on widgets — extensions can't present it); confirm the shipped watch
  complication appears in the gallery; confirm brightness/scene/deep-link end-to-end.

### Gotchas / decisions
- `RoomDisplayItem.id` == Hue resource UUID == `GlobalSceneItem.roomID`, so scenes attach to a group
  by `ownerGroupID == group.id && bridgeID`.
- Summary on-counts stay **room-based** (zones overlap rooms → avoid double-counting).
- Deep-link routes to the Home tab reliably; room-detail *push* was intentionally NOT wired (would
  need NavigationPath plumbing that risks the tab back-navigation feature) — `pendingGroupID` is
  captured for a future follow-up.
- Model structs are still duplicated across targets (widget/watch/watch-cx); kept field-parity
  instead of a 4-target shared-file refactor (blind-ship risk). Future consolidation noted.
- `xcodeproj` gem used for the `.pbxproj` edits (safe re-serialization vs hand-editing); backup at
  scratchpad `project.pbxproj.bak`.
- Out of scope (per plan): Control Center widget, `systemExtraLarge`, Live Activities, wiring the
  orphaned Siri intents (`HueHome/Intents/*`).

---

## 2026-07-02 - [Claude] Nav — swipe-between-tabs + re-tap-to-back-one-page — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07`

### Did
- All in `HueHome/UI/Navigation/MainTabView.swift` (iPhone layout only; iPad keeps its split view).
- **Swipe left/right to change bottom tabs.** Added `tabSwipeGesture` (a low-priority
  `.gesture(DragGesture)`) on the tab container. Low priority = inner horizontal scrollers and
  Studio's `.page` deck pager still win their own drags; only "unclaimed" horizontal swipes on the
  page body change tab. Guards: ignores left-edge starts (`startLocation.x > 24`) so the system
  interactive back-swipe survives; requires a decisive, predominantly horizontal swipe
  (`|dx| > |dy|·1.3` and `|dx|>60 || |predictedX|>120`). Swipe left → next tab, right → previous,
  clamped to `[home…more]` (no wrap). Commit-on-`onEnded` (no live follow) to minimise interference.
- **Re-tap the active tab icon → back out one page.** The custom tab bar keeps all four tab
  `NavigationStack`s alive in a ZStack, so there's no system "tap active tab" behaviour. Added a
  `TabNavRegistry` (`@Observable`, weak `UINavigationController` per `HueTab`) + a tiny invisible
  `NavControllerResolver: UIViewControllerRepresentable` placed as a `.background` inside each tab's
  stack root to capture that stack's nav controller. On re-tapping the already-selected tab,
  `navRegistry.popOne(tab)` pops one page (`popViewController`) if `viewControllers.count > 1`; at
  root it does nothing. Tapping a *different* tab still just switches (unchanged).
- **Why UIKit pop, not a bound NavigationPath:** the tabs mix value-based
  (`NavigationLink(value:)`, Home: Room→Light), boolean (`.navigationDestination(isPresented:)`,
  More: Automations/Devices/Entertainment Areas), and view-based (`NavigationLink(destination:)`,
  More: Bridge Manager) navigation, with no path binding anywhere. `popViewController` is the same
  path the interactive edge-swipe-back already uses, so SwiftUI reconciles its own nav state across
  all three link types — no rewiring required. (Scenes only uses `.sheet`, so it has no push depth.)

### Working
- Full app build **succeeded** (`HueHome 1`, Debug, iPhone 17 Pro sim); reinstall + relaunch clean,
  no crash markers.

### Left
- On-device confirmation of feel: (1) swipe doesn't fight horizontal chip rows / Studio deck in
  practice; (2) re-tap-back correctly pops **boolean-based** More destinations without the
  `isPresented` binding bouncing them back (expected to reconcile like edge-back, but verify).
  Not automatable here (no idb/XCUITest; blind global clicks leaked into another app, so GUI
  automation was abandoned).

### Gotchas
- `tabSwipeGesture` is a **low-priority** `.gesture` on purpose — using `.highPriorityGesture` would
  steal horizontal chip-row scrolls; `.simultaneousGesture` would double-fire (scroll AND switch).
- New nav types live at the bottom of `MainTabView.swift` (no new file → no `.pbxproj` surgery).
- Left-edge swipes never change tabs (reserved for system back); tab-swipe is right-of-edge only.

---

## 2026-07-02 - [Claude] Studio — expandable Mixer Tray (drag-up to full-screen, tap-to-close) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07`

### Did
- **Problem:** the Studio Mixer Tray (the panel that springs up on **+ Create** or when any effect
  runs) was locked to a fixed height (~390–420pt for compositions ≈ half-screen). The full
  Palette/Motion/Envelope/Reaction editor lives in an inner `ScrollView` but the small window felt
  cramped, and there was no way to drag the panel up. Only tap-the-tiny-capsule collapsed it.
- Added `@State isMixerExpanded`. `resolvedMixerHeight(proxy:)` now returns a near-full-screen height
  when expanded (`geo.height − safeTop − tabBarClearance − 24`, clamped to `[half … 0.92·geo.height]`).
  The inner `GeometryReader`+`ScrollView` auto-enlarges its viewport, so no content changes.
- Reworked `mixerDismissDragGesture` into a bidirectional state machine (same `startLocation.y ≤ 64`
  guard so the hue/sat pad + sliders keep their own drags): drag **up** → expand; drag **down** while
  expanded → collapse to half; drag **down** while half → dismiss to the "Live Controls" pill. Upward
  drags get a small clamped rubber-band hint via `mixerDragOffset`.
- Enlarged the grab-bar tap target to a full-width ~28pt strip → tap anywhere on the top bar =
  `collapseMixer()` (**non-destructive**: hides controls, effect/lights keep running, pill reopens).
- Reset `isMixerExpanded = false` in `collapseMixer()` and the room-change / running-card-cleared
  `onChange` handlers so the panel always reopens at half.
- Bonus: `compositionSaveSheet` was stuck at `.presentationDetents([.medium])` (literally "only comes
  halfway up") → now `[.medium, .large]`.

### Working
- Full app build **succeeded** (`HueHome 1`, Debug, iPhone 17 Pro sim); app launches/runs, no crash.

### Left
- Tactile on-device confirmation of the drag/tap feel (thresholds `-60/-120` expand, `100/160`
  dismiss; expand animation). Not automatable here without XCUITest — blind global clicks leaked into
  another foreground app, so UI automation was abandoned to avoid touching the user's real windows.

### Validation
- `xcodebuild ... -scheme 'HueHome 1' ... build` → **BUILD SUCCEEDED**; install + launch on sim OK.

### Gotchas
- All changes are in `HueHome/UI/Studio/StudioView.swift`. The tray is a **custom** bottom panel, not
  a `.sheet` — deliberately extended (not converted) to preserve background interaction, placement
  above the floating tab bar, transitions, and the `.id()` reset.
- Tap-vs-drag on the grab bar is disambiguated by the drag gesture's `minimumDistance: 8`.

---

## 2026-07-02 - [Claude] Studio — compact inline two-axis wheel rolodex room picker — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07`

### Update (same session, round 2 after on-device feedback)
- **Zones wouldn't scroll left/right.** Root cause: two overlapping native `ScrollView`s (full-stage
  vertical rooms + a horizontal zone band) fought over the pan and the vertical one swallowed the
  horizontal drag. Rebuilt both wheels as **hand-rendered cylinders driven by ONE axis-locked
  `DragGesture`** (horizontal → zones, vertical → rooms) with flick momentum (`predictedEndTranslation`)
  + spring snap + per-detent haptics. Single gesture = zero conflict, both axes reliably work. Curvature
  is now a `Cylinder` ViewModifier (`rotation3DEffect` + scale + opacity from center distance).
- **Floating / transparent look.** Dropped the solid card background and the frosted `.ultraThinMaterial`
  lens; the lens is now just a translucent amber ring + soft glow (`amber.opacity(0.05)` fill) so the
  centered wheel cell shows through and the whole module floats over the Studio ambient background.
- Registered file already in `project.pbxproj`; whole-module typecheck still **0 errors**.

### Did
- Replaced the Studio room picker (previously a text-swap nav-title swiper + a searchable `List`
  sheet) with a genuine Apple-time-picker-style **two-axis wheel**, sized as a **compact inline
  module** that sits at the top of the Studio content — NOT a full-screen sheet.
  New `HueHome/UI/Studio/RoomRolodexView.swift`.
  - Vertical wheel = **rooms** (spin up/down); horizontal wheel = **zones** (spin left/right); the two
    cross at a glowing amber "selection lens" that always frames the live pick. ~138pt wheel stage
    inside a bordered card.
  - Native iOS 17 scroll APIs so momentum/rubber-banding/snap detents match the system picker:
    `ScrollView` + `.scrollTargetLayout()` + `.scrollTargetBehavior(.viewAligned)` +
    `.scrollPosition(id:)`, center-snapped via symmetric `.contentMargins(_:_:for: .scrollContent)`.
  - Cylinder curvature via `.scrollTransition(.interactive, axis:)` → opacity + scale +
    `rotation3DEffect` (about X for rooms, Y for zones). Honors Reduce Motion (angle → 0).
  - "Apparent by design" chrome: header legend ("⇅ ROOMS · ⇄ ZONES", active axis lit amber), faint
    amber **+ cross rails**, edge-fade vignette masks, per-axis brightening of the active wheel, and a
    magnifying-glass button that reveals the searchable `RoomPickerSheetView` as a large-library /
    a11y fallback (reused, untouched). Selecting there also re-syncs the wheels.
  - Haptic `.selection()` detent tick each time a new item centers; live `onSelect` updates the Studio
    as you spin. `onChange(of: selectedRoom?.id)` re-syncs the wheels if selection changes elsewhere
    (guarded by an `isSyncing` flag so it never loops or double-haptics). `#Preview` with mock data.
- `StudioView`:
  - Embedded `roomRolodex` at the top of the content `VStack` (Zone A), shown when not
    entertainment-running; the inline card sits above the card grid with `HueSpacing.lg` insets.
  - Removed the old nav-title swiper (`swipeableRoomTitle`, `sidePeekNames`, `showRoomSheet`,
    `dragAxisLocked`/`dragRoomSteps`/`slideDirection`) and the full-screen sheet; the toolbar now
    shows a compact `studioNavTitle` ("Studio", or the Entertainment-Area badge when streaming).
- **Registered `RoomRolodexView.swift` in `project.pbxproj`** (PBXBuildFile + PBXFileReference +
  Studio group + HueHome Sources phase). The earlier "Cannot find 'RoomRolodexView' in scope" build
  errors were solely the missing target membership — the Swift itself always compiled.

### Working
- Whole-module `swiftc -typecheck` over all 106 app sources (incl. DEBUG preview) → **0 errors**
  against `arm64-apple-ios17.0-simulator`. `plutil -lint` on the pbxproj → OK; new IDs unique.

### Left
- Full command-line `xcodebuild` of the `HueHome 1` scheme is still blocked by a **pre-existing,
  unrelated** failure: `LightShadeWatchApp Watch App/Assets.xcassets` AppIcon "did not have any
  applicable content" (reproduces identically on a clean tree with my files removed; the strict
  iPhoneSimulator 26.x `actool` rejects the single-1024 watch icon). Xcode/device builds appear to
  get past it. Not touched — flag for a watch owner.
- Needs on-device look/feel validation: lens sits exactly on the centered detent on SE + Pro Max;
  compact stage height (138pt) feels right above the card grid.

### Gotchas
- The room wheel is full-width/full-height inside the module; the zone wheel is a ~42pt band
  composited on top at center. Vertical drags inside that band scroll zones (not rooms) — expected,
  and the header legend communicates it. Center-snap depends on `contentMargins` inset =
  `(stageHeight − rowHeight)/2`.

---

## 2026-07-02 - [Claude] iOS P1 — round-2 checkpoint fixes (Items 1–4) — LOCAL, awaiting round-3

### Branch
- `ios-ref/hardening-p1-2026-07` — 4 new commits on top of `c560323`
  (`2059b7f` Item 1 · `05e3a09` Item 2 · `8e25483` Item 3 · `f050379` Item 4).
  **NOT pushed** — checkpoint discipline; waiting on Brian's round-3 on-device pass.

### Did
- **Item 1 (HIGH, L-15/L-17) — first-paired bridge lost after pairing two in one session.**
  Root cause exactly as the audit predicted: the pairing POST saved to the LEGACY
  single-bridge Keychain slots; per-bridge migration ran only on the "Add to ChromaGlow"
  tap (result discarded) and NEVER on the first-bridge path, so pairing B overwrote A's
  slots, `migrateLegacyCredentials(to: B)` moved B's values and deleted the slots — A had
  no record and no credentials at relaunch. Fix: `BridgeDiscoveryViewModel` mints a
  BridgeRecord id on pairing success and writes ip/token/clientKey straight to its
  namespaced slots (legacy slots never written); canonical bridgeid captured from the
  D-016 identity verification; new **`BridgePairingRegistrar`** commits the record the
  moment the phase hits `.paired` (atomic with credentials — no more stranded keys on
  sheet dismissal), dedups by canonical bridgeid with a guarded host fallback (L-17:
  won't merge a different bridgeid squatting on the same DHCP ip), moves credentials
  onto a reused record, and THROWS so `BridgeSetupView` surfaces failures. `BridgeRecord`
  gained an additive-optional `bridgeIdentifier` field (SwiftData lightweight migration).
  `configure()`'s `bridges.isEmpty` legacy migration is retained for true app upgrades.
- **Item 2 — "Pair Another Bridge" in onboarding.** The paired screen now offers
  "Continue to App" + "Pair Another Bridge" (returns to scanning; the just-paired record
  is already persisted). Only the very first record is named "My Bridge". The
  add-additional sheet keeps its single "Add to ChromaGlow" action.
- **Item 3 (HIGH) — widget renders blurry (WidgetKit redacted/placeholder).** Four
  provider defects each capable of producing that state: (1) the grouped_light refresh
  awaited the transport's full 8s timeout on every timeline build (off-Wi-Fi = every
  refresh stalls into WidgetKit's throttle) — new `fetchGroupedLightsBounded` races a
  hard 4s budget and falls back to the cached snapshot; (2) `Dictionary(uniqueKeysWithValues:)`
  traps on duplicate grouped-light ids → extension crash → redacted snapshot — now
  `uniquingKeysWith`; (3) a PAIRED user whose shared-Keychain read transiently failed
  (before first unlock) was served the UNPAIRED entry with `.never` — frozen on wrong
  content until an external reload; now cached rooms + stale flag + 15-min retry;
  (4) the genuinely-unpaired branch trades `.never` for a 60-min backstop (the round-1
  blob-change reload stays the fast path). The round-1 `write(bridges:)` blob-compare was
  re-verified deterministic (String-only payload, sortedKeys) — it was NOT the thrash source.
- **Item 4 — entertainment-area builder undiscoverable.** Two-part finding. (a) The
  "Sync tab" trigger everyone pointed at lives in `SyncModeView` — which is ORPHANED:
  the v0.15.0 nav rework (Home/Scenes/Studio/More) removed the Sync tab and no code
  references `SyncModeView` anymore. Its trigger was also a low-contrast inline text
  link; upgraded to a prominent row anyway in case the view returns. (b) The only
  REACHABLE entry point was Studio's conditional prompt (spatial motion pattern + no
  existing area for the room) — effectively invisible. Real fix: a permanent
  **"New Entertainment Area"** row in the More tab's CONTROL group presenting
  `EntertainmentConfigBuilderView` (builder POSTs to the bridge, so no callback wiring
  needed; Studio/Sync enumerate configs from the bridge). The M-18 bridge picker shows
  when `allBridgeIDs.count > 1` — true once Item 1 restores both clients. Round-3
  follow-up from Brian ("no way to view or edit what's been created"): the More row now
  opens a new **`EntertainmentAreasView`** management screen — lists every area on every
  bridge (grouped by bridge name, light/channel counts), rename + delete via the ⋯ menu
  (new `EntertainmentConfigManager.rename/delete` + generic `HueAPIClient.delete(path:)`),
  pull-to-refresh, and a + toolbar button presenting the builder. Editing light
  membership stays delete-and-recreate for now.
- **Item 5 — round-1 fixes re-verified.** Forget-all remains total under the new pairing
  flow (it wipes per-record namespaced creds — exactly where pairing now writes — plus
  legacy slots, pins, shared surface, SwiftData cache, in-memory teardown); stale-bridge
  pruning and widget-revival code paths untouched.

### Validation
- Device build green · **full `HueHomeTests` green (200 test cases passed)** ·
  `./Scripts/hardening_guards.sh` 5/5 after EVERY item.
- New tests: `PairingPersistenceTests` (6 — two-session pairing survival, legacy slots
  never written, same-VM pair-another, configure() builds two clients, bridgeid dedup,
  no-merge-on-host-collision) · `WidgetTimelineRobustnessTests` (2 — hanging transport
  resolves nil within budget, responding transport decodes).

### Left
- **STOP.** Brian's round-3 on-device pass, then on "tested locally, go ahead": push over
  SSH, build+test the merged tree, `--no-ff` merge to `main` (ask merge vs PR; `gh` is a
  non-collaborator on this machine).

### Gotchas
- pbxproj synthetic ids used through `C0DEC0DE0112…` — **next free prefix `C0DEC0DE0113…`**.
- If the widget is STILL blurry in round 3, the remaining suspects need device evidence:
  Settings → Privacy & Security → Analytics Data, filter "HueHomeWidget" (crash logs).

---

## 2026-07-02 - [Claude] iOS P1 — on-device checkpoint ROUND 2 results + session handoff — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` @ `03e2902` (+ this docs commit; local only — NOT pushed).

### Did
- Recorded Brian's round-2 on-device results and prepared the continuation launch prompt for a
  fresh agent: **`docs/coordination/prompts/ios-hardening-p1-continuation.md`** (the prior
  conversation hit its context ceiling). That file is the complete state transfer — new session
  starts there.

### Round-2 results
- **Working now:** cross-bridge preset sync (energize/read/relax/sleep apply across BOTH bridges
  — "good job there"); location flow; forget-all improvements from round 1.
- **NEW issue (HIGH):** pairing two bridges in one session — the FIRST-paired bridge is forgotten
  after app relaunch (worked in-session; re-pair fixed). Likely audit **L-15** (pairing persists
  to legacy single-bridge Keychain slots; per-bridge migration only on the "Add" tap; second
  pairing clobbers the slots). Continuation Item 1.
- **NEW regression (HIGH):** the widget now renders BLURRY (WidgetKit redacted/placeholder) —
  worse than round 1's missing widget. Suspect timeline-provider crash/hang or reload thrash.
  Continuation Item 3.
- **UX (MEDIUM):** Brian cannot FIND the "New Entertainment Area" UI at all, so the M-18 bridge
  picker was never reachable. Continuation Item 4.
- **Feature request:** onboarding should offer "Pair another bridge" / "Continue to app" after a
  successful pair. Continuation Item 2.
- **CLOSED:** lost compositions (#8) — Brian attributes it to an earlier app delete/reinstall
  (Documents wiped) and only needs forward-saving to work; P1's lenient decode + .bak +
  no-reseed-overwrite covers that.

### Left
- Execute continuation Items 1–4, re-verify round-1 fixes, then STOP for round-3 on-device.
  Push/merge only after Brian's explicit go-ahead.

---

## 2026-07-02 - [Claude] iOS P1 — fixes from the human on-device checkpoint — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (local only — not pushed).

### Did (root causes found from Brian's on-device test results)
- **Forget-all wasn't total (checkpoint #3):** it cleared the Keychain but left the in-memory
  clients (tokens in RAM) fully working until relaunch, and the More-tab presentation path never
  navigated away. New `orchestrator.forgetAllBridges()` (stops Studio/Composer sessions + SSE,
  clears clients/gates/snapshots), SettingsView purges the SwiftData room/scene cache and posts
  `.hueBridgeUnpaired` itself so every presentation path exits to the splash immediately.
- **Bridge-1 rooms dead after forget→re-pair (checkpoint #4/#5) — root cause:** re-pairing mints
  NEW BridgeRecord UUIDs, but `roomsByBridge` kept entries under the OLD ids (seeded by the
  SwiftData preload / previous session). The merge produced each room twice — one live, one dead —
  and dictionary order picked the stale copy for bridge 1 and the fresh one for bridge 2. Zones
  weren't cached, so bridge-1's zone kept working — exactly the observed asymmetry (All Off also
  worked because it iterates the live snapshot underneath). Fix: `pruneStaleBridgeSnapshots()` at
  the rebuild chokepoint (drops any bridge id with no live client; demo mode exempt) + the
  forget-all cache purge above.
- **Large widget never came back after forget-all:** the unpaired timeline uses `policy: .never`
  and nothing ever reloaded it after a re-pair. `WidgetDataStore.write(bridges:)` now calls
  `WidgetCenter.reloadAllTimelines()` whenever the credential blob actually changes (and on the
  empty/unpair write).
- **Bridge-stored demotion (checkpoint #6):** the pre-upload `fetchLights` (id_v1 mapping) gets
  one retry + an explicit "running app-driven (stops when the app closes)" log on failure.
  NOTE: only `bridgeOptimized`-tier presets (static motion + steady envelope) ever upload to the
  bridge — dynamic compositions are app-driven BY DESIGN and stop when iOS suspends the app
  (lock/close); native effects (Candle) persist because the BRIDGE runs them. Checkpoint #7
  (stops when locked) is the same iOS-suspension behavior for DTLS — expected; M-10's reconnect
  covers transient errors while foregrounded, not process suspension.
- **Lost compositions (checkpoint #8):** the old (pre-P1) build's destructive reseed is the exact
  M-13 bug — compositions written by an older schema were overwritten with built-ins by a previous
  launch BEFORE this branch; P1 prevents recurrence but cannot resurrect data the old code already
  overwrote (no `.bak` existed then). Defensively, `CompositionPreset` now hard-requires ONLY `id`
  — every other top-level field decodes with a default, so no schema drift can drop a preset again.

### Working
- Build SUCCEEDED; full HueHomeTests green incl. new tests (stale-bridge snapshot pruning,
  id-only preset decode). Guards pass.

### Left
- Human retest of: forget-all (immediate unpair + exit), bridge-1 rooms after re-pair, the
  large-widget revival, and the entertainment-builder bridge picker (code path looks correct —
  `allBridgeIDs.count > 1` gates it; likely a casualty of the same stale-client state, retest
  after these fixes and screenshot if still missing).

---

## 2026-07-02 - [Claude] iOS P1 hardening — multi-agent code review + fixes — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (local only — not pushed).

### Did
Ran an 8-angle multi-agent review over the whole P1 diff (line-by-line, removed-behavior,
cross-file tracer, reuse, simplification, efficiency, altitude, conventions — 33 candidates,
deduped + verified). Fixed everything that survived:

- **Watch-wipe protocol flaw (severe, mine):** an empty `wc_bridges_v1` map was the watch's
  forget-all signal, but "empty" is indistinguishable from a transient Keychain read failure or
  legacy single-bridge mode — a routine refresh could wipe the watch's credentials AND TLS pins.
  Forget-all is now an **explicit `wc_unpaired` flag**; an empty map never clobbers stored watch
  credentials; the phone additionally refuses to publish an all-bridges-failed credential map
  (`setupClients`/`publishWidgetBridgeCredentials` keep the previous snapshot and log).
- **Widget upgrade gap:** app updated but not yet launched → shared-Keychain blob absent → the
  widget of a paired user froze on "unpaired" (`policy: .never`). Added a READ-ONLY upgrade-window
  fallback to the pre-D-018 App Group copies; the app's first launch writes the blob and scrubs
  them, killing the fallback path.
- **Watch migration:** now copy-first/delete-only-on-success (a background pre-first-unlock launch
  could destroy the only credential copy).
- **Session registry (M-06 follow-ups):** register **before** the REST `action=start` (a
  concurrent loadAll cleanup could kill our own session during the ≤10s DTLS handshake);
  registry is now **refcounted** (two clients on one config — Sync + Studio — no longer expose
  each other); reconnect **abandonment tears the session down** (unregister + best-effort stop)
  instead of leaving a dead-but-protected config the cleanup skips forever.
- **`hueClient(for: nil)`:** legacy pre-multi-bridge rooms (nil bridgeID from the SwiftData cache
  window) resolve to the sole registered client in single-bridge homes — the P1 sweep had made
  All-Off/All-Day/Effects silently skip them where `primaryAPIClient` used to work.
- **BridgeCommandGate:** cancellation-aware (a cancelled effect-loop task used to busy-spin the
  pacing loop and still fire one frame after Stop); effect loops now use `retry: false` (the next
  frame supersedes a failed one — retrying stale frames wasted 400ms of budget).
- **Keychain migration:** attributes-only fast scan (steady state no longer decrypts every item
  every launch); a stale private-group duplicate can no longer overwrite a newer shared-group
  item (shared copy wins; leftover is deleted).
- **Dashboard bulk paths (flagged by 3 angles):** All Off + preset chips now delegate to the
  orchestrator's paced, failure-surfacing paths (ids/values match AutomationPreset exactly);
  stop-effect paths are gate-paced. The duplicate unthrottled `withTaskGroup` bursts are gone.
- **Reuse:** one `gatedBulkWrite` scaffold for the three orchestrator bulk paths;
  `BridgePinStore` keychain I/O delegates to `SharedKeychainStore` (ONE copy of the D-018
  attribute contract) and scrubs its UserDefaults mirrors only after a **verified** write;
  EffectsViewModel resolves its gate once (dead `?? BridgeCommandGate()` fallback removed);
  entertainment teardown shares one `sendBestEffortStop`.
- **WidgetDataStore.write(bridges:):** deterministic (sortedKeys) encode + skip when unchanged —
  removes the non-atomic Keychain delete/add window from every foreground.

### Accepted trade-offs (documented, NOT fixed — P2 candidates)
- Transient `fetchLights` failure before a bridge-stored upload demotes to app-driven rendering
  silently (graceful degrade, console-logged); also a 4th light-inventory fetch per activation.
- Undecodable presets are dropped to a timestamped `.bak` with no restore UI.
- Strobe above ~300 BPM degrades gracefully under the 10 cmd/sec gate (bridge physics); the
  grouped_light collapse is audit-prescribed — on-device checkpoint validates real-world behavior.
- `CompositionStore` maps an empty decoded library to built-ins (unreachable via UI: deleting a
  built-in restores it by name).

### Working
- Build SUCCEEDED (generic/platform=iOS); full HueHomeTests green incl. new tests (registry
  refcount + register-balance, hueClient(for: nil) both modes, upgrade-window widget fallback
  with real-credential snapshot/restore). Guards pass.
- **/security-review (focused on the credential-storage + DTLS changes): zero findings met the
  exploitability bar.** Verified: `.useCredential` still only in the Trust module; no discarded
  trust evaluation; no token/key/PSK in any new log line; entitlements add exactly
  `$(AppIdentifierPrefix)com.huehome.pro.shared` on app+widget+watch; the widget upgrade-window
  fallback is read-only; `wc_unpaired` is settable only by the Apple-paired phone; PSK handling
  unchanged. Residual notes (hardcoded team-ID constant, unqualified keychain reads during the
  migration window, non-atomic delete/add upsert) are availability/config-management notes, not
  vulnerabilities.
- **/verify caveat:** the end-to-end pass for these changes requires a physical Hue bridge
  (ideally two) — that is exactly the §6 human checkpoint below; no runtime claim is made beyond
  build + unit suite + guards.

---

## 2026-07-02 - [Claude] iOS P1 hardening — Group 7: pairing/UX correctness (M-11/M-12) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (local only — not pushed).

### Did
- **M-11:** the NUPnP cloud fallback is now guarded on `discoveredBridgeChoices.isEmpty` at
  three points — the 12s timeout task, `discoverViaNUPnP()` entry, after the cloud GET returns,
  and before the silent mDNS retry (which restarts the browser and would wipe the chooser). An
  empty cloud reply can no longer bounce the user to an error screen while local bridges are on
  screen, and a non-empty one can no longer force-select and hide the bridge the user wanted.
  `discoverViaNUPnP` made internal for the offline guard test.
- **M-12:** `OneShotLocation.request()` now retains the `CLLocationManager` + delegate in a
  static `activeRequest` for the request lifetime (delegate is weak; both were function locals
  that an optimized build could free at the first suspension point → continuation never resumed,
  "Set location" spun forever) and bounds the request with a **15s timeout**; the delegate
  resumes exactly once via the Group-6 `ContinuationGate` (timeout races callbacks).

### Working
- Build SUCCEEDED (generic/platform=iOS); HueHomeTests green incl. new `DiscoveryFallbackTests`
  (chooser survives the fallback window; phase stays .scanning). Guards pass.

### Left
- M-12 needs on-device confirmation (CLLocationManager can't be driven in unit tests):
  Settings → All Day → "Set" must complete or fail within ~15s, never spin forever.
- The "fallback still runs with an empty chooser" direction hits the real
  discovery.meethue.com endpoint (no URLSession seam) — covered on-device, not unit-tested.

---

## 2026-07-02 - [Claude] iOS P1 hardening — Group 6: entertainment/DTLS robustness (M-06/M-09/M-10/L-11) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (local only — not pushed).

### Did
- **M-06:** `HueEntertainmentClient` gained a process-wide **app-owned session registry**
  (register on successful `startSession`, unregister on `stopSession`/failed open);
  `deactivateStuckEntertainmentSessions` now SKIPS any active config the app owns — an everyday
  lock/unlock or room toggle can no longer kill a running Studio/Composer/Sync show. Covers all
  three session owners because they all stream through `HueEntertainmentClient`.
- **M-09:** the DTLS handshake continuation is guarded by a new `ContinuationGate`
  (NSLock resume-exactly-once); the handshake-complete/timeout race on two queues can no longer
  double-resume (`SWIFT TASK CONTINUATION MISUSE` trap). `nonisolated(unsafe) var resumed` gone.
- **M-10:** `handleSendError` now cancels + nils the dead connection and drives a **bounded
  reconnect** (3 attempts, 300ms×n backoff, cancelled by `stopSession`); frames resume
  automatically once streaming again instead of silently no-oping at 25–50fps forever.
- **L-11:** a failed DTLS open sends a best-effort compensating `action=stop` (and resets
  configID + unregisters) so the entertainment configuration is not left activated on the bridge.

### Working
- Build SUCCEEDED (generic/platform=iOS); HueHomeTests green incl. new
  `EntertainmentRobustnessTests` (gate resumes exactly once across 16-way races ×50; failed open
  → REST start,stop pair recorded + not registered; stuck cleanup stops the stale config and
  skips the app-owned one; registry register/unregister). Guards pass.
- Fixed a cross-suite flake: `applyAutomationPreset` tests now drain the orchestrator's 500ms
  debounced widget write in tearDown so it can't land inside KeychainSharingTests' App Group scan.

### Left
- M-10 live reconnect behavior needs the on-device checkpoint (requires a real DTLS socket).

---

## 2026-07-02 - [Claude] iOS P1 hardening — Group 5: non-destructive persistence (M-13/L-27) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (local only — not pushed).

### Did
- **M-13 `CompositionStore.load()`:** decodes elements leniently via a new
  `FailableDecodable<T>` wrapper (one malformed preset is dropped, the rest survive); on ANY
  decode problem it writes a timestamped `compositions-<ts>.bak` FIRST and **never calls
  `persist()` from the read path** — the destructive reseed-and-overwrite is gone. Total
  decode failure runs on built-ins in memory with the source file untouched.
- **M-13 sub-config Codable:** `PaletteConfig` / `MotionConfig` / `EnvelopeConfig` /
  `ReactionConfig` / `CodableColor` got explicit migration-safe `init(from:)` — every field
  `(try? decode) ?? default` (covers missing keys AND unknown enum raw values) — plus explicit
  memberwise inits (a custom decoder suppresses the synthesized ones the built-in preset
  catalog uses). Encoding stays synthesized; round-trip tested.
- **L-27 `HueV2Response`:** `data` decodes through `FailableDecodable` (a single out-of-spec
  resource no longer blanks the whole rooms/lights/scenes fetch); a missing `errors` key is
  tolerated.

### Working
- Build SUCCEEDED (generic/platform=iOS); HueHomeTests green incl. new
  `NonDestructivePersistenceTests` (malformed element preserves rest + .bak + source
  byte-identical; garbage file backs up without persisting defaults; old-schema JSON missing
  `motionAngle`/`randomize`/`harmonyRule` loads with defaults and does NOT reseed; sub-config
  round-trips; HueV2Response skips a malformed light and tolerates missing errors). Guards pass.

---

## 2026-07-02 - [Claude] iOS P1 hardening — Group 4: paced bulk + effect writes (M-08/M-14/M-15) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (local only — not pushed).

### Did
- **New `BridgeCommandGate` actor** (per-bridge, ~10 cmd/sec spacing, one retry with 400ms
  backoff, returns the final error instead of swallowing it). Orchestrator keeps one gate per
  bridge (`commandGate(for:)`). This is deliberately NOT the latest-wins `RestSender` — bulk
  operations must deliver EVERY command; the mailbox stays untouched on the Sync/Studio paths.
- **M-08:** `turnAllOff` / `applyAutomationPreset` / `applyAutomationEffect` route every
  grouped_light PUT through the bridge's gate, collect per-room failures, and surface them via
  the new `lastBulkFailure` (`BulkWriteFailure`) — DashboardView shows a "⚠ … failed for …"
  toast. No more silent partial application.
- **M-14:** `EffectLoops.setAll` collapses a same-color frame (strobe on/off, party sync,
  thunderstorm flash/calm — all setAll calls are same-color by construction) into a **single
  grouped_light PUT** through the gate when the room's groupedLightID is available; per-light
  fallback is gate-paced. `setAll`/`setOne` return success; loops sleep an extra 500ms after a
  failed frame instead of hammering a throttled bridge. Party's non-sync per-light branch is
  gate-paced.
- **M-15:** the Effects one-shot per-light color fan-out and the gradual native-effect clear
  fan-out are gate-paced; one-shot counts failures and shows "⚠ applied — N light(s) failed"
  instead of unconditional success.

### Working
- Build SUCCEEDED (generic/platform=iOS); HueHomeTests green incl. new `GatedBulkWriteTests`
  (gate retry/pacing semantics; All-Off attempts every room, retries the failed one, surfaces
  it; automation preset ditto; 10-light same-color frame = exactly one grouped PUT, zero
  per-light PUTs). Guards pass.

### Gotchas
- Strobe above ~300 BPM now degrades gracefully (frames delayed by pacing) instead of flooding
  the bridge and desyncing — the bridge cap (~10 cmd/sec) is physics, not a tunable.
- The §4 verified-good per-light batching (RoomDetail bulk path) and the RestSender mailbox
  paths were not modified.

---

## 2026-07-02 - [Claude] iOS P1 hardening — Group 3: bridge-stored animation correctness (M-04/M-05) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (local only — not pushed).

### Did
- **M-04:** `resolveV1LightIDs` now maps v2 UUIDs → v1 numeric ids by **`id_v1` identity**
  (`HueLight` gained the `id_v1` field; the resolver takes the v2 light objects; output[i] is the
  same bulb as input[i]). Deleted the dead `uniqueIDToV1ID` block and the positional
  lowest-N-lights-on-the-bridge guessing. Unresolvable lights **fail closed**
  (`HueV1ClientError.unresolvedLightID`) → caller falls back to app-driven rendering instead of
  animating the wrong bulbs. `BridgeAnimationEngine.upload` gained a `v2Lights:` parameter; the
  orchestrator fetches lights at the upload site.
- **M-05:** step rules are **chunked to ≤7 light actions per rule** (v1 caps rules at 8 actions);
  chunks share the same sensor-trigger condition so the bridge fires them together; only the last
  chunk carries the sensor-advance action; action count is validated before POSTing
  (`uploadFailed` instead of a mid-upload abort). 8+ light rooms now upload instead of aborting
  to app-driven silently.

### Working
- Build SUCCEEDED (generic/platform=iOS); HueHomeTests green incl. new
  `BridgeAnimationCorrectnessTests` (identity mapping with scrambled numeric order; numeric
  passthrough; fail-closed on unmappable; 9-light upload with every rule ≤8 actions, full
  per-step coverage, exactly one advance per step). Guards pass.

### Gotchas
- Chunking multiplies the rule count per animation (stepCount × ceil(N/7)); the
  `canFitOneAnimation` capacity heuristic (rules ≥ 12) still assumes one rule per step — L-04
  (P2) also notes its scene requirement is wrong; both deferred to P2.

---

## 2026-07-02 - [Claude] iOS P1 hardening — Group 2: primaryAPIClient wrong-bridge sweep (M-07/H-05/M-18) — LOCAL

### Branch
- `ios-ref/hardening-p1-2026-07` (local only — not pushed).

### Did
- **Swept every `primaryAPIClient` call site to per-bridge resolution** (the audit's wrong-bridge
  class: `clients.values.first` is nondeterministic):
  - **M-07** `stopCompositionMode`: teardown now resolves the client from the manifest's own
    bridge via new `hueClient(forBridgeIP:)`; if the manifest's bridge is no longer registered the
    manifest is dropped with a log (bridge-side `CG_` leftovers age out via purge).
  - **H-05** `EffectsViewModel`: removed the cached `api` property entirely; `activate()` resolves
    `hueClient(for: room.bridgeID)` per activation AFTER the target room is known; all four
    strategy branches now hit the room's bridge.
  - **M-18** `EntertainmentConfigBuilderView`: `loadLights()`/`createConfig()` use a
    `selectedBridgeID` threaded through the sheet; auto-selected for single-bridge homes, a
    Bridge picker section appears when several bridges are registered (light selection resets on
    switch). New `bridgeName(for:)` orchestrator helper for the picker.
  - **Same class, also fixed:** DashboardView `stopEffect`/`stopAllEffects`/`applyPreset`/
    `turnAllOff` and the All-Day scenes tick (`tickAllDayScenes`) — each grouped_light PUT now
    routes to its room's own bridge.
- **Guard 5** added to `Scripts/hardening_guards.sh`: any `primaryAPIClient` reference outside its
  declaration (or a comment) fails the guard — the wrong-bridge class cannot silently re-enter.

### Working
- Build SUCCEEDED (generic/platform=iOS); HueHomeTests green incl. new
  `MultiBridgeRoutingTests` (hueClient(forBridgeIP:) resolution; M-07 teardown deletes land only
  on the manifest's bridge + manifest removed; H-05 effect PUT lands only on the selected room's
  bridge). Guards pass.

### Left
- Groups 3–7. M-16/M-17 (Effects turn-off timer, dead "All Rooms") are NOT in the P1 launch-prompt
  scope — deferred, noted for the handoff.

### Gotchas
- `primaryAPIClient` property still exists (legacy single-bridge fallback semantics) but has zero
  call sites; Guard 5 forces a conscious guard edit before any new use.

---

## 2026-07-02 - [Claude] iOS P1 hardening — Group 1: Keychain access group (M-02/L-30, D-018) — LOCAL, in progress

### Branch
- `ios-ref/hardening-p1-2026-07` (based on `main` @ `d023b1f`; **local only — not pushed**).

### Did
- **Group 1 (M-02/L-30, implements D-018):** moved every shared bridge secret out of
  UserDefaults into a **Keychain access group** (`$(AppIdentifierPrefix)com.huehome.pro.shared`,
  entitlement added to app + widget extension + watch app; service stays the LIVE
  `com.lightshade.app`).
  - New `HueHome/Core/Keychain/SharedKeychainStore.swift` (app+widget+watch targets):
    AfterFirstUnlockThisDeviceOnly, non-synchronizable, explicit access group on writes,
    group-unqualified reads for migration tolerance.
  - `WidgetDataStore`: credentials map now lives at Keychain account
    `hue_shared_bridge_credentials_v1`; App Group carries only non-secret routing metadata
    (`hue_widget_routing_v1` bridgeID+ip, `hue_widget_bridge_ip`); legacy plaintext keys
    (`hue_widget_token`, `hue_widget_bridges_v1`) scrubbed on every publish; widget timeline
    resolves creds via `primaryCredentials()` (deterministic sorted-first bridge).
  - **Watch:** token/credential map now in the watch Keychain; phone stopped sending the raw
    legacy `wc_token` WCSession key (token travels only inside `wc_bridges_v1`); watch App Group
    mirror carries display data only; complication (`LightShadeWatchExtension`) lost its dead
    token/credentials accessors (display-only — it never networked).
  - **Forget-all (L-30):** Settings forget-all now wipes the shared Keychain blob + App Group
    surface + pins and pushes an explicit EMPTY `wc_bridges_v1` map; the watch treats a
    well-formed empty map as the unpaired signal and wipes Keychain/defaults/App Group mirrors.
  - **Migration (critical):** `KeychainManager.migrateToSharedAccessGroupIfNeeded()` re-homes all
    `com.lightshade.app` items copy-first/delete-after and upgrades accessibility
    WhenUnlocked→AfterFirstUnlock (deliberate D-018 change so lock-screen widget/Siri/watch work;
    still ThisDeviceOnly + non-sync). Watch migrates UD creds→Keychain at store init. P0 TLS-pin
    mirrors (D-016) folded into the same group; pin UD mirrors are fallback-read + scrubbed.
  - Guard 4 added to `Scripts/hardening_guards.sh`: no UserDefaults write of a plaintext-token
    key or `.token` value anywhere in the iOS tree.

### Working
- Build SUCCEEDED (scheme `HueHome 1`, generic/platform=iOS — app + widget + both watch targets).
- HueHomeTests green on iPhone 15 / iOS 17.0, incl. new `KeychainSharingTests` (accessibility +
  non-sync class, migration value-safety, token-never-in-App-Group scan, no clientKey in
  `WidgetBridgeCredentials`, forget-all clears surface + `credentials(for:)` nil, pin mirrors
  scrubbed). `Scripts/hardening_guards.sh` all guards pass.

### Left
- P1 Groups 2–7 (wrong-bridge sweep, animation correctness, mailbox routing, persistence,
  DTLS robustness, pairing/UX) — in progress on this branch.
- STOP at the §6 local-first checkpoint before any push (on-device: upgrade keeps credentials;
  widget+watch still control; forget-all leaves no secret at rest).

### Validation
- `xcodebuild … generic/platform=iOS build` → BUILD SUCCEEDED; `… -only-testing:HueHomeTests test`
  → TEST SUCCEEDED; `./Scripts/hardening_guards.sh` → pass.

### Gotchas
- Widget/watch cannot read credentials until the main app has run once post-upgrade (migration is
  app-side) — same fail-closed window as the P0 pin migration; open the app once after install.
- `LightShadeWatchExtension` (watch complication) target has **no entitlements file wired**
  (`CODE_SIGN_ENTITLEMENTS` unset) yet reads App Group UserDefaults — pre-existing, display-only;
  flagged for a later decision, not touched in P1.
- The two orphaned entitlements files (`LightShadeWatch/LightShadeWatch.entitlements`,
  `LightShadeWatchApp Watch App/LightShadeWatchApp.entitlements`) are not referenced by any target
  and were intentionally left unmodified.

---

## 2026-07-01 - [Claude] iOS P0 hardening remediation (privacy manifests, log scrub, TLS pinning) — LOCAL, awaiting on-device checkpoint

### Branch
- `ios-ref/hardening-2026-07` (based on `docs/hardening-audit-2026-07-01`; **local only — not pushed**).

### Did
- **M-03 (App Store blocker):** added per-bundle `PrivacyInfo.xcprivacy` (UserDefaults, CA92.1) to the
  widget extension, watch app, and watch extension. The three targets are file-system-synchronized
  groups, so folder presence = membership; verified present in all six built bundle paths.
- **H-03/H-04/L-09 (secrets/PII in logs):** v1 client now logs only token-free resource paths
  (`redactedPath(fromV1URLPath:)`) and sanitizes error bodies (`sanitizedForLog`); pairing no longer
  logs the raw response or interpolates token/clientKey into `appendLog` (lengths/byte counts only);
  dropped `privacy: .public` from every URL/IP/error-text/name interpolation across the network
  clients + view models; discovery `print` is now `#if DEBUG`.
- **H-01/H-02/M-01/H-06 (trust-all TLS → pinned evaluator, D-016):** new `HueHome/Core/Network/Trust/`
  module compiled into app + widget + watch app targets:
  - `BridgeTrustEvaluator` — canonical uppercase-16-hex bridgeid identity from the leaf CN;
    data-plane verdict = successful `SecTrustEvaluateWithError` (anchors-only: bundled Hue roots +
    pinned leaf) AND CN==pinned bridgeid AND public-key pin match; a key change is accepted only via
    a chain that validates against the bundled Signify roots alone (CA-attested rotation → re-pin).
  - `HueBridgeTrustRoots` — the two Hue roots embedded as DER (byte-identical to Android Batch-3),
    fingerprints asserted by a regression test.
  - `BridgePinStore` — pins in Keychain (authoritative) + App Group mirror (widget/Siri) + standard
    defaults (watch); pins are public key material, not secrets.
  - `BridgePinnedTrustDelegate` (data plane, fail closed) replaced ALL five trust-all delegates:
    HueAPIClient/HueV1Client/HueSSEService/orchestrator-SSE `HueCertTrustDelegate`, pairing
    `BridgeCertTrustDelegate`, widget `TrustDelegate`/`TrustAll`, Siri `TrustDelegate`, watch `TrustAll`.
  - `BridgePairingTrustDelegate` (pairing TOFU) — validates chain + bridgeid-CN, captures the leaf,
    and enforces same-leaf continuity across the pairing session (Android D-014 parity). Pairing now
    fetches `/api/0/config` over the SAME session, requires `bridgeid == leaf CN`, pins, and only then
    persists credentials; failure aborts pairing with nothing stored. Pairing session is invalidated
    after use (closes L-18 early).
  - `BridgePinAcquirer` — one-time upgrade migration: at the top of `loadAll()`, any configured host
    without a pin gets a TOFU config-GET + CN cross-check + pin (60s retry throttle; disabled in
    XCTest processes). Watch receives pins via WCSession (`hue_bridge_tls_pins_v1`) pushed alongside
    credentials.
- **Guards:** `Scripts/hardening_guards.sh` — (1) per-bundle privacy manifests; (2) bans
  `privacy: .public` on URL/IP/token/name-derived interpolations + token/clientKey in `appendLog` +
  v1 URL logging; (3) bans `.useCredential` outside the Trust module and discarded
  `SecTrustEvaluateWithError` results.
- **D-016:** appended the concrete design turn to the pipeline Decision Log before implementing.
- **Multi-agent code review (8 angles) + fixes:** extracted one shared persist gate
  (`BridgePinAcquirer.validateAndPersist`) used by BOTH pairing and migration — an existing pin can
  never be overwritten by a different key unless the chain is CA-attested (the pairing path previously
  lacked this guard; regression test added); pin migration now probes hosts concurrently (an offline
  bridge no longer stalls `loadAll` serially) with a 15s retry throttle; the pairing config-GET
  retries 3× before discarding a just-issued key; forget-bridge/forget-all now remove TLS pins
  (which is also the recovery path for a legitimately changed bridge certificate); `BridgePin`
  dropped its write-only `certDER` (~1KB per pin per sink); bridgeid validation no longer compiles a
  regex per TLS challenge; CA-rotation re-pin moved off the TLS callback thread. (A shared delegate
  base class was tried and reverted: subclass overrides hit default-actor-isolation mismatches
  across the mixed-toolchain targets — the ~30 duplicated plumbing lines are the cheaper trade,
  noted in the file.)
- **Finding while reviewing:** `HueHome/Intents/` (HueIntentAPIClient/HueIntents/HueAppShortcuts/
  HueRoomEntity) has NO pbxproj target membership — the "Siri intents" trust-all surface in audit
  M-01 was dead code; the live Siri/AppIntents surface is the widget extension. The file was still
  rewired to the pinned delegate so it is correct if ever added to a target.
- **Security review (/security-review, adversarially verified, confidence 8/10):** the unattended
  upgrade migration (`ensurePins`) originally accepted a self-signed leaf as a *first* pin with no
  user present — a LAN MITM at the first post-upgrade `loadAll` could silently ghost-pin an
  attacker cert and capture the app key. Fixed: `validateAndPersist(…, unattended:)` now refuses a
  first pin for a non-CA-attested (self-signed) leaf on the silent migration path; only interactive
  pairing (physical link-button presence) may pin a self-signed bridge. Modern Signify-CA-signed
  bridges (the common case; both physical test bridges chain to the bundled `root-bridge` CA) still
  migrate silently. Regression test: `testUnattendedMigrationRefusesSelfSignedFirstPin`. **Consequence
  for the human:** a *legacy self-signed* bridge paired before D-016 will NOT auto-migrate — it stays
  fail-closed until the user forgets + re-pairs it (link button). Flag if you want an in-app
  "re-pair to secure" prompt instead of silent fail-closed.

### Working
- Build SUCCEEDED (`HueHome 1`, generic/platform=iOS — includes widget + both watch targets).
- HueHomeTests green on iPhone 15 / iOS 17.0 sim, including new `SecretLogScrubTests` (post-pairing
  log scrape: no token/clientKey substring) and `BridgeTrustEvaluatorTests` (delegate never returns
  `.useCredential` without successful evaluation; rejects unpinned leaf, mismatched CN, and
  same-CN/different-key impersonator; CA-only rotation; root fingerprints; D-014-style continuity).

### Left
- **STOP: human on-device checkpoint before any push** — pair to a real bridge (both bridges ideally),
  confirm normal control + widget/watch still work after the app runs once (pin migration), and
  optionally verify a MITM'd/mismatched cert is rejected. Exact steps in the session handoff.
- P1 next: M-02/L-30 Keychain access group (pins currently mirror to App Group UD by design — move with
  the credential migration); M-06/M-07/H-05/M-18 multi-bridge fixes; M-04/M-05; M-08/M-14/M-15 mailbox;
  M-09/M-10/L-11 DTLS; M-13/L-27 persistence; M-16/M-17; M-11/M-12.
- Review items deferred to P1 (documented trade-offs, not regressions): watch pin distribution rides
  the debounced room push (add a store-triggered sync); cross-process pin-cache staleness reconciles
  with the D-018 shared Keychain access group; the grep-based log lint is a tripwire, not proof —
  consider a typed redaction wrapper; surface a visible error state when widget/watch writes fail
  closed instead of `try?`-swallowing.

### Validation
- `xcodebuild -scheme "HueHome 1" -destination generic/platform=iOS build` → BUILD SUCCEEDED.
- `xcodebuild … -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' -only-testing:HueHomeTests test` → TEST SUCCEEDED.
- `Scripts/hardening_guards.sh` → all guards pass.

### Gotchas
- Existing paired bridges have no pin until the main app runs `loadAll()` once (TOFU migration);
  widget/watch/Siri fail closed until then. Open the app once after install.
- "Forget all bridges" does not yet remove pins (harmless — public material, overwritten on re-pair);
  fold into the P1 M-02/L-30 credential-surface work.
- Legacy HTTP (port-80) pairing now requires the bridge to present a valid HTTPS identity to complete
  (the data plane is HTTPS-only, so such bridges never worked past pairing anyway).
- `run_tests.sh` still targets a hardcoded physical device and the `HueHome` scheme; use the
  simulator command above instead.

---

## 2026-07-01 - [Claude] Cross-platform hardening audit (iOS + Android)

### Branch
- `docs/hardening-audit-2026-07-01` (docs-only; no source edits). iOS audited on the working tree
  (≡ `main`); Android audited on the Batch-4 worktree `integration/parallel-batch-4` @ `040fed7`
  so the full pairing stack (Batch 3 on `main` + pending Batch 4) was covered.

### Did
- Ran a two-round multi-agent read-only audit (16 dimensions + 6 gap-closure dimensions), with every
  finding passed through an adversarial verifier (40 false positives discarded).
- Recorded the full report at `docs/audit/hardening-audit-2026-07-01.md`: 0 Critical, 5 High,
  19 Medium, 55 Low, plus verified-good hardening to preserve.
- **High (all iOS):** H-01 systemic trust-all TLS on the data plane (`HueAPIClient.swift:722`
  evaluates the cert then discards the result); H-02 trust-all TLS during pairing
  (`BridgeDiscoveryViewModel.swift:78`); H-03 v1 app key logged in cleartext via URL at
  `privacy:.public` in release (`HueV1Client.swift:439`); H-04 pairing token + entertainment key
  logged (`BridgeDiscoveryViewModel.swift:332`); H-05 Effects tab uses `primaryAPIClient` so effects
  on non-primary bridges silently fail (`EffectsViewModel.swift:85`). (H-06 = H-01 re-confirmed on the
  scene/automation write path — not a separate item.)
- **Top reliability risks:** M-06 background `loadAll` can stop the app's own active DTLS session;
  M-13 `CompositionStore.load()` reseeds + overwrites `compositions.json` on any decode error
  (composition data-loss); M-08/M-14/M-15 unbounded bulk/effect PUTs bypass the `RestSender` mailbox;
  M-03 widget/watch bundles ship without `PrivacyInfo.xcprivacy` (ITMS-91053 upload blocker).
- **Android:** the pairing/TLS/credential stack verified as reference-quality (pinned Signify roots,
  strict bridgeid-CN identity, D-014 GET→POST continuity, no secret logging, Keystore + `noBackupFilesDir`).
  Net-new: M-19 — the default checkout builds the *unhardened* pre-pairing `android/` tree, there is no
  Android CI, and both trees are `versionName 1.0` (stale APK indistinguishable). See D-020 in the
  pipeline Decision Log.

### Working
- No Critical and no remotely-exploitable findings. The dominant themes are iOS transport
  authentication + credential-in-logs hygiene, and reliability of the flagship real-time features.

### Left
- Remediation is not started (audit-only). P0: M-03 privacy manifests; H-03/H-04 log scrub;
  H-01/H-02/M-01 iOS bridge TLS pinning (route through the deferred D-001 TLS-bootstrap decision).
  P1: M-02 Keychain access group; M-06/M-07/H-05/M-18 multi-bridge + entertainment fixes;
  M-05/M-04 bridge-animation correctness; M-08/M-14/M-15 mailbox for bulk/effect writes;
  M-09/M-10 DTLS robustness; M-13 non-destructive persistence; M-19 canonical Android tree + CI gate.
- Fold Android polish (L-31/L-32/L-33, I-01/I-13) into Batch 4 before it merges.

### Validation
- Read-only audit; no code executed against a bridge. Findings are grounded in source with file:line;
  each was adversarially verified. Docs-only change to this repo.

### Gotchas
- The default repo checkout's `android/` is 31 commits behind `main` (pre-Batch-1) — do NOT audit or
  build Android from it. The validated stack lives on `integration/parallel-batch-4`.

---

## 2026-07-01 - [Claude] Diagnose Batch 4 physical pairing FAIL: stale pre-Batch-4 APK

### Branch
- `docs/parallel-agent-pipeline` (diagnosis only; no source edits). Batch 4 code inspected on
  `integration/parallel-batch-4` @ `040fed7`.

### Did
- Investigated the redacted physical-bridge test report (discovery PASS, pairing FAIL from both
  discovered selection and manual IP).
- Audited the full Batch 4 pairing path on `integration/parallel-batch-4` (workflow, transport,
  TLS trust/verifier, CN contract, config parser, ViewModel wiring, manifest, navigation): no
  code-level defect found; production wiring is real (OkHttp + pinned roots + Keystore + DataStore).
- Validated the D-015 contract against BOTH physical bridges from the same LAN (macOS, openssl/curl):
  mDNS advertises port 443; both leaf certs chain to the bundled `root-bridge` CA (`openssl verify` OK);
  leaf CNs are valid 16-hex bridge ids (one lowercase, one UPPERCASE — both accepted, compared
  case-insensitively); TLS 1.2 ECDHE-ECDSA-AES128-GCM-SHA256 (OkHttp MODERN_TLS compatible);
  `/api/0/config` parses and `bridgeid` matches the leaf CN on both; pre-button `POST /api` returns
  the expected type-101 "link button not pressed".
- Root cause (high confidence): the installable APK in the main checkout
  (`android/app/build/outputs/apk/debug/app-debug.apk`, built 2026-06-28 09:53, sha256 `c0a1cdda…`)
  predates all Batch 4 commits (2026-06-29) and contains NO pairing classes (`SetupViewModel`,
  `LivePairingWorkflow`, `DataStoreBridgeRegistry` absent from dex). On that build the selected-bridge
  card is the Batch 2 placeholder ("Pairing will be added in a later step.") — a designed dead end
  from both the discovered and manual paths, matching the reported symptoms exactly.
- Confirmed the correct APK already exists: `/Users/brianbean/Desktop/huehome-batch4-wt/android/app/
  build/outputs/apk/debug/app-debug.apk` (2026-06-29 15:58, sha256 `c8c2d92b…`) contains all Batch 4
  classes, and `:app:assembleDebug` at tip `040fed7` reports all 36 tasks UP-TO-DATE — that APK matches
  branch-tip source including the bridge-registry singleton fix (committed 15:59, in-tree at build time).

### Working
- Batch 4 pairing contract verified compatible with both physical bridges (BSB002, swversion
  1977138000 / apiversion 1.77.0) at the TLS, identity, and protocol layers.

### Left
- Re-run the §11 human gate with the WORKTREE APK (sha256 `c8c2d92b…`). Quick identity check on-device:
  the Batch 4 build shows a "Pair" button on the selected-bridge card; the stale build shows
  "Pairing will be added in a later step." with no Pair button.
- If the retest still fails on the correct APK, capture the exact on-screen recovery message (the
  copy is user-safe/redaction-friendly and maps 1:1 to `PairingErrorReason`) — that pinpoints the
  failing layer without raw logs.

### Validation
- `openssl verify -CAfile <bundled roots>` OK for both bridge leafs; live `/api/0/config` and
  pre-button `POST /api` behavior confirmed; dex string-scan of both APKs; gradle up-to-date check
  at `040fed7`. Docs-only change to this repo.

### Gotchas
- Gradle in the worktree needs `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`
  (no system JVM installed).
- The repo-root APK and the worktree APK share applicationId/versionName (`com.chromaglow.app` / 1.0),
  so an installed build is NOT distinguishable by version — check the Pair button or the APK sha256.

---

## 2026-06-29 - [Codex] Prepare Batch 4 Claude handoff for live pairing

### Branch
- `docs/parallel-agent-pipeline` (planning from `origin/main` @ `f3380a7`).

### Did
- Reviewed the landed Setup, discovery, credential, app-shell, and Batch 3 pairing APIs.
- Identified two required integration contracts: successful pairing must return authenticated `bridgeId`
  with `username`, and service-advertised discovery ports must map to accepted HTTPS pairing port 443.
- Accepted D-015, wrote `docs/android/android-live-pairing-workflow-contract.md`, drafted the disjoint §11
  five-lane manifest, and created the READY Claude prompt
  `docs/coordination/prompts/parallel-batch-4-launch.md`.

### Working
- Claude can execute dependency bootstrap, parallel result/registry contracts, transactional workflow,
  and Setup UI without further product input.

### Left
- After Claude's automated gate, the human selects a bridge, tests pre-button type 101, presses the link
  button, verifies pairing and relaunch restoration, then tests local Forget Bridge and unpaired relaunch.
- Batch 4 does not load Hue resources or enter a real dashboard; that is Batch 5.

### Validation
- Docs-only: `git diff --check`. Dependency planning used current resolved Lifecycle 2.9.4 plus stable
  Google Maven DataStore 1.2.1; no Android source was edited.

### Gotchas
- Local Forget Bridge does not revoke the bridge-side application key. The physical tester must know that
  one test key may remain on the selected bridge until remote revocation is implemented.

---

## 2026-06-29 - [Codex] Accept corrected Batch 3 for human-approved promotion

### Branch
- `docs/parallel-agent-pipeline` (reviewing `integration/parallel-batch-3` @ `c385616`).

### Did
- Reviewed correction lane `352a42e`, the merged production code, dual-cert regression test, full branch
  boundary, and Claude's corrected-integration handoff.
- Confirmed from pinned OkHttp 5.4.0 bytecode that `hostnameVerifier` participates in `Address` equality,
  so the distinct POST verifier forces a new connection in the shipped dependency.
- Accepted D-014 and marked Batch 3 eligible for `main` after explicit human go-ahead.

### Working
- No remaining code findings. A CA-valid identity change between config GET and create-user POST is
  rejected during the POST TLS handshake, and the response leaf is checked again before parsing.

### Left
- Human merge approval only. Setup UI, credential persistence, and physical pairing remain a later batch.
- Keep the cross-identity transport regression mandatory when upgrading OkHttp.

### Validation
- Focused transport JVM suite 16/0; full `testDebugUnitTest` 174/0; `lintDebug` and `assembleDebug` green;
  29 changed paths all in scope; `git diff --check` clean. Connected 37/0 was batch-owner validated on
  `Pixel_10`; Codex did not restart the emulator.

### Gotchas
- The pre-send guarantee uses pinned OkHttp 5.4.0 address equality plus the regression test; the explicit
  response-leaf check is defense in depth but occurs after the POST has been sent.

---

## 2026-06-29 - [Claude] Merge Batch 3 (pairing foundations + D-014) to main

### Branch
- `main` (pushed) + this `docs/parallel-agent-pipeline` handoff.

### Did
- On explicit human go-ahead, merged `integration/parallel-batch-3` @ `c385616` into `main` `--no-ff`.
  Preflight confirmed `origin/main` was still the pinned `7ed6468` (an ancestor of `c385616`) → a
  conflict-free merge of 10 commits (Batch 3 W0/W1/W2 + the D-014 correction).
- New `main` @ `f3380a7`; the merge commit's tree is byte-identical to `c385616` (no content introduced
  by the merge). Pushed `7ed6468..f3380a7`.

### Working
- `main` now carries the tested, non-UI Hue pairing foundation: `core/hue/pairing/{protocol,tls,transport}`
  + bundled CA roots, with the D-014 fail-closed GET→POST identity continuity.

### Left
- Nothing for Batch 3. Follow-up batch (separately scoped): Setup UI + credential persistence + physical
  pairing on the merged APIs. Lane/integration branches retained on origin; local `cg-b3-wt` worktrees
  removed post-merge.

### Validation
- Sanity build on the merged `main`: `testDebugUnitTest` 174/0, `lintDebug`, `assembleDebug` green;
  `git diff --check` clean. The full gate (incl. `connectedDebugAndroidTest` 37/0 on `Pixel_10`) was green
  on the identical tree at `c385616`; the connected run was not repeated on the byte-identical merge tree.

### Gotchas
- The `--no-ff` merge preserves the Batch 3 boundary in history (consistent with Batches 1 & 2). `main`
  advanced `7ed6468` → `f3380a7`; update any doc/snapshot that still pins the old SHA.

---

## 2026-06-29 - [Claude] Correct Batch 3 D-014 identity continuity (integrated, not on main)

### Branch
- `integration/parallel-batch-3` (corrected, pushed) + this `docs/parallel-agent-pipeline` handoff.

### Did
- Executed the accepted D-014 correction prompt as batch owner from the exact pushed integration head
  `142ca71`. Single serialized two-file lane `lane/android3-pairing-identity-continuity-correction` @
  `352a42e` (edited only `transport/OkHttpHuePairingClient.kt` + its test).
- Fixed the GET→POST identity-continuity defect: `pair()` now builds a SEPARATE create-user client whose
  `HueLeafHostnameVerifier` is pinned to the GET-authenticated `bridgeid` even when the caller hint was
  null (forcing a fresh, pinned TLS connection for the POST), and re-checks the POST response handshake
  leaf CN == authenticated id before parsing/returning any outcome. A different CA-valid Hue leaf on a
  re-established connection is now rejected at the TLS handshake — create-user can never reach a different
  bridge. Public `HuePairingClient` API unchanged.
- Added a real dual-cert HTTPS regression test (null hint; leaf A on GET, distinct leaf B on POST via a
  per-connection switching `SSLSocketFactory`) asserting fail-closed + `requestCount == 1`.
- Merged `--no-ff` → `integration/parallel-batch-3` @ `c385616` (pushed).

### Working
- The accepted D-001/D-002 fail-closed identity contract now holds across BOTH pairing legs.

### Left
- NOT merged to `main` — awaits Codex review of `c385616` + explicit human go-ahead. No Setup UI,
  discovery, credential write, persistence, or live bridge traffic added.

### Validation
- Full gate on `c385616`: `testDebugUnitTest` 174/0 (transport 16/0, +1 regression), `lintDebug`,
  `assembleDebug`, `connectedDebugAndroidTest` 37/0 on `Pixel_10`; `git diff --check` clean.
- Boundary: correction commit = exactly the 2 transport files; full diff vs `main` = 29 paths, all
  in-glob; prohibited-pattern scan clean (no trust-all, blanket-true verifier, `generateclientkey`,
  `clientkey`/persistence, secret logging).

### Gotchas
- The fix relies on `HueLeafHostnameVerifier` not overriding `equals`: the GET-leg and POST-leg verifier
  instances differ, so OkHttp treats them as distinct `Address`es and always re-handshakes for the POST —
  combined with the explicit post-leg CN re-check, the property holds even if connection-pool semantics
  change. `142ca71` is superseded by `c385616`.

---

## 2026-06-29 - [Codex] Block Batch 3 promotion on pairing identity continuity

### Branch
- `docs/parallel-agent-pipeline` (reviewing `integration/parallel-batch-3` @ `142ca71`).

### Did
- Reviewed the complete Batch 3 diff, transport/TLS/protocol implementation, tests, lane graph, and
  execution report. Verified the CA resources and all 29 changed files remain within authorized globs.
- Added accepted D-014 and prepared the single-lane READY correction prompt at
  `docs/coordination/prompts/parallel-batch-3-identity-continuity-correction.md`.
- Corrected the execution-report audit count: 29 changed files, not 28.

### Working
- Batch 3 builds and its existing unit suite is green. CA-only trust, SAN-less CN validation, protocol
  parsing, request bounds, redirect refusal, and no-clientkey/no-persistence boundaries remain intact.

### Left
- `142ca71` must not merge to `main`. With a null caller hint, the POST client still accepts any CA-valid
  Hue CN rather than the specific bridge identity authenticated by GET. Claude should run the D-014 prompt,
  merge the correction to `integration/parallel-batch-3`, and return the corrected SHA for review.

### Validation
- On the integration worktree: `./gradlew testDebugUnitTest --rerun-tasks` -> BUILD SUCCESSFUL, 173/0;
  `./gradlew lintDebug assembleDebug` -> BUILD SUCCESSFUL; `git diff --check origin/main...HEAD` clean.

### Gotchas
- Existing transport tests use one MockWebServer leaf for both requests, so their green result does not
  prove identity continuity across a TLS reconnect or routing change.

---

## 2026-06-29 - [Claude] Execute Batch 3 pairing foundations (integrated, not merged to main)

### Branch
- `integration/parallel-batch-3` (code, pushed) + this `docs/parallel-agent-pipeline` handoff.

### Did
- Executed the READY §10 Batch 3 manifest end-to-end as batch owner from pinned `origin/main` @ `7ed6468`.
  Preflight gates all passed (origin/main SHA exact; both CA source files SHA-256-verified; clean slate;
  JDK 21 + SDK + `Pixel_10` AVD).
- **W0** `lane/android3-pairing-bootstrap` @ `0334d2a`: pinned OkHttp `5.4.0`, `kotlinx-serialization-json`
  `1.11.0` (no compiler plugin), test-only `mockwebserver3` + `okhttp-tls` `5.4.0`; bundled both accepted
  Hue CA roots to `res/raw/` (SHA-256 re-verified). → integration post-W0 `2c0178c2`.
- **W1** parallel from `2c0178c2`: `lane/android3-pairing-protocol` @ `ea9610c` (pure JSON
  request/response/config contracts via kotlinx `JsonElement`; +39 tests) and `lane/android3-pairing-tls`
  @ `0a01b32` (pinned-CA trust manager, RFC 2253 leaf-CN identity, SAN-less `HostnameVerifier`; +35 unit
  + 1 instrumented fingerprint test). Merged both `--no-ff` → integration post-W1 `ea212db7`.
- **W2** from `ea212db7`: `lane/android3-pairing-transport` @ `c829b92` (`HuePairingClient` +
  `OkHttpHuePairingClient`: HTTPS-only, no redirects, no POST retry, 64 KiB-bounded bodies, 10 s timeout,
  `HttpUrl`; config→identity check before POST; typed outcomes; MockWebServer3 + test-cert tests, +15).
  Merged `--no-ff` → integration final `142ca71`.

### Working
- Public, tested, non-UI pairing foundation under `core/hue/pairing/{protocol,tls,transport}` consumable
  by a later Setup/persistence batch via `OkHttpHuePairingClient.fromContext(context)`.

### Left
- NOT merged to `main` — awaiting explicit human go-ahead. No Setup UI, app/nav, discovery, credential
  write, token persistence, or live bridge traffic was added (deliberately out of Batch 3 scope).

### Validation
- Integrated gate on `142ca71`: `./gradlew testDebugUnitTest lintDebug assembleDebug` → BUILD SUCCESSFUL,
  unit **173/0**; `connectedDebugAndroidTest` on the single `Pixel_10` (serial) → **37/0** (34 pre-existing
  + 3 new `HueRootCertificatesTest` methods that verify the bundled roots' subjects + SHA-256 fingerprints
  on-device); `git diff --check` clean.
- Boundary audit: all 28 changed files within Batch 3 globs; zero edits outside (no Setup/app/discovery/
  credentials/manifest/theme). Prohibited-pattern scan clean (no trust-all, no blanket-true verifier, no
  emitted `generateclientkey`, no `clientkey`/credential persistence, no secret logging). No deviations;
  no new decision required.

### Gotchas
- `javax.naming`/`LdapName` is absent on Android — the TLS lane uses a self-contained RFC 2253 DN
  tokenizer for structured CN extraction (not `split(",")`).
- OkHttp 5.4.0 exposes `Response.body`/`code`/`handshake` + `Handshake.peerCertificates` as `val`
  properties (the `fun` forms are deprecated). MockWebServer3 5.4.0 is builder-based, `useHttps(ssf)` takes
  one arg, `MockWebServer` is `Closeable` (`close()`, no `shutdown()`), `RecordedRequest` uses
  `.method`/`.target`/`.url`/`.body` (no `.path`).
- Lane worktrees live under `/Users/brianbean/Desktop/cg-b3-wt/` (kept for the human's review; remove with
  `git worktree remove` after merge/abandon). The `Pixel_10` AVD was booted headless for the connected run.

---

## 2026-06-29 - [Codex] Accept pairing contract and prepare Batch 3 foundations

### Branch
- `docs/parallel-agent-pipeline`.

### Did
- Recorded the human's explicit D-001/D-002/D-012 acceptance and marked D-001/D-002/D-011/D-012
  ACCEPTED. Added the accepted pairing security contract to `AGENTS.md`.
- Reviewed current `origin/main` @ `7ed6468` and prepared the READY three-wave Batch 3 manifest plus
  `docs/coordination/prompts/parallel-batch-3-launch.md` under D-013.

### Working
- Batch 3 serializes dependency/CA bootstrap, parallelizes protocol and TLS/identity foundations, then
  serially integrates an HTTPS transport. It uses the two locally verified CA files and structured JSON.

### Left
- Batch 3 is ready but not launched. Claude may execute the launch prompt; final integration-to-main
  merge still requires explicit human go-ahead. Setup UI/persistence/physical pairing are not in Batch 3.

### Validation
- Docs-only; manifest reviewed against `origin/main` @ `7ed6468`; dependency versions verified against
  official release repositories; `git diff --check` clean. No Android source or certificate bytes changed.

### Gotchas
- The docs branch does not contain Batch 2 source, so all Batch 3 source/path review used Git objects from
  `origin/main`, not the docs-branch working tree.

## 2026-06-29 - [Codex] Store and verify supplied Hue CA bundle

### Branch
- `docs/parallel-agent-pipeline`; certificate files remain outside Git.

### Did
- Created `/Users/brianbean/Desktop/chromaglow-hue-ca/` with the exact supplied two-certificate bundle,
  individually split CA files, and `VERIFICATION.md`.
- Verified two certificates, file/fingerprint hashes, validity, EC keys, critical `CA:TRUE` constraints,
  certificate-signing usage, and self-signatures. Recorded non-secret metadata in the decision log.

### Working
- `root-bridge` exactly matches the issuer profile observed on the current Hue bridge leaves. The bundle
  also contains the newer self-signed `Hue Root CA 01` through 2050.

### Left
- Explicit human/Codex acceptance of the recorded CA-signed-only TLS/identity contract. D-001/D-002 stay
  DEFERRED and no Batch 3 prompt exists until acceptance.

### Validation
- OpenSSL parsing and self-signature verification passed for both CA certificates; `git diff --check`
  clean. Certificate bytes were not added to Git.

### Gotchas
- The app will eventually need the CA bytes as a runtime trust resource, but committing/bundling them is
  an implementation action after acceptance, not part of this evidence step.

## 2026-06-28 - [Codex] Review gated pairing evidence closure

### Branch
- `docs/parallel-agent-pipeline`.

### Did
- Reviewed Claude's gated D-012 result at `46d9cda`, marked the closure prompt completed, and updated
  canonical next-step pointers. Recorded that the actual official CA file, not metadata alone, is needed.

### Working
- The CA-signed-only/fail-closed legacy policy is the recommended MVP stance. Omitting
  `generateclientkey` is acceptable for the non-Entertainment MVP; `CLIENT_KEY` persistence stays out.

### Left
- Human downloads the official `root-bridge` CA `.pem` through an authenticated Hue developer session
  and makes the actual file available locally outside Git. Then Claude verifies only that artifact and
  returns for explicit acceptance. D-001/D-002 remain DEFERRED; no Batch 3 prompt exists.

### Validation
- Docs-only review; `git diff --check` clean. No portal credentials, certificate bytes, source, or device
  access.

### Gotchas
- A hash and certificate summary cannot substitute for the trust-anchor bytes the app must eventually
  bundle; do not close D-001 without the official file.

## 2026-06-28 - [Claude] Android pairing official-evidence closure (gated; blockers stay DEFERRED)

### Branch
- `docs/parallel-agent-pipeline`. Docs/evidence only — no source, tests, Gradle, manifest, deps, probe,
  pairing, tokens, or Batch-3 work.

### Did
- Executed `docs/coordination/prompts/android-pairing-evidence-close.md`. Preflight passed (`origin/main`
  @ `7ed6468`; docs base `a92fa6c` in history; tree clean; committed probe evidence still redacted).
- Attempted the official root-CA byte-verification. The authoritative Hue "Using HTTPS" page (which holds
  the downloadable Signify `root-bridge` CA `.pem`) is **login-gated** — fetched it and got only a login
  form. No authenticated Hue developer session is available; per the prompt I did not request/automate
  portal credentials, and community transcriptions are disallowed as the source of truth.
- Appended an "Official evidence closure" section to `docs/android/android-pairing-tls-identity-decision.md`
  (gated-access result, the exact root-CA verification procedure to run once the file is supplied, the
  evidence already closed, the final proposed TLS/identity contracts, the CA-signed-only legacy policy, the
  non-circular manual-endpoint identity rule, the `generateclientkey`=omit decision, recovery behavior, and
  the one remaining gate). Appended Claude turns under D-001/D-002/D-011/D-012.

### Working
- Everything closable without the portal is closed (public official Get Started + the prior approved
  probe). The proposal is coherent and primary-source-grounded.

### Left
- **NOT marked READY FOR ACCEPTANCE.** D-001/D-002 stay DEFERRED; D-011/D-012 DISCUSSING. **One exact next
  action:** a human with a Hue developer session downloads the official root-CA `.pem` from
  `develop/application-design-guidance/using-https/` and provides it (file, or its SHA-256 +
  subject/issuer/serial/validity/key fields). Then I complete the recorded verification (confirm
  subject == probed leaf issuer `CN=root-bridge`), Codex + human accept, and a Batch 3 manifest may be
  drafted. No code authorized until then.

### Validation
- Docs-only; `git diff --check` clean; AGENTS.md unchanged (no stated fact disproven). No credentials
  requested, stored, or committed.

### Gotchas
- The official `.pem` is only behind the Hue developer login; there is no public official download, and the
  bridge does not serve its root in the TLS handshake — so the CA must come from the authenticated portal
  (or a human-provided file), not from the device or a community mirror.

## 2026-06-28 - [Codex] Prepare final Android pairing evidence-closure prompt

### Branch
- `docs/parallel-agent-pipeline`.

### Did
- Added `docs/coordination/prompts/android-pairing-evidence-close.md`, recorded D-012, and updated the
  canonical current-state pointers. Marked the completed D-011 preparation prompt historical.

### Working
- Claude can now run one bounded docs-only packet to verify the official `root-bridge` CA and Hue
  contracts through an existing authenticated portal session, then return an acceptance proposal.
- The packet proposes CA-signed-only MVP support with fail-closed firmware-update guidance for legacy
  self-signed bridges; it forbids TOFU, permissive fallback, source edits, and Batch 3 preparation.

### Left
- Claude evidence closure, then explicit Codex/human acceptance. D-001/D-002 remain DEFERRED and D-011 /
  D-012 remain DISCUSSING; no pairing code is authorized.

### Validation
- Docs-only; `git diff --check` clean. No bridge probe, credentials, source, or runtime changes.

### Gotchas
- Portal credentials/session data and the temporary CA file must stay outside Git. If authenticated
  access is unavailable, Claude must stop with the exact missing access rather than use a community CA.

## 2026-06-28 - [Claude] Android pairing read-only bridge probe (D-001/D-002 evidence)

### Branch
- `docs/parallel-agent-pipeline`. Docs-only; no source/Gradle/manifest/deps; no pairing, tokens, state
  change, or reboot. Device IPs / MACs / bridge IDs kept out of git (scratchpad only).

### Did
- With explicit human approval (read-only LAN discovery + `openssl s_client` + unauthenticated
  `/api/0/config` only), probed **two** real `BSB002` bridges (apiversion 1.77.0) to close the deferred
  D-001/D-002 evidence. Appended a redacted "Empirical probe addendum" to
  `docs/android/android-pairing-tls-identity-decision.md` and probe turns under D-001/D-002/D-011.

### Working
- Confirmed on real hardware: current bridges are **CA-signed by the Signify `root-bridge` CA** (not
  self-signed); **leaf CN == bridgeid (case-insensitive)**; **leaf has NO SAN** (so Android's default
  SAN-only verifier fails → a custom CN==bridgeid check + bundled Signify root CA is required); **TLS 1.2**;
  leaf valid to 2038; only the leaf is served. `bridgeid` is 16-hex, MAC-derived (EUI-64 `FFFE`),
  UPPERCASE in `/api/0/config`, agreeing across cert CN / config / mDNS TXT / IPv6 link-local → stable
  across DHCP by construction. `/api/0/config` is unauthenticated (200), non-secret subset only.

### Left
- **D-001/D-002 stay DEFERRED; D-011 stays DISCUSSING.** Remaining before acceptance: (1) byte-verify the
  official Signify root-CA `.pem` (issuer DN `CN=root-bridge` now known; page login-gated); (2) legacy
  self-signed support stance; (3) explicit human/Codex acceptance. Reboot/factory-reset stability not
  exercised (reboot out of scope; inferred stable from MAC-derivation). Batch 3 only after acceptance.

### Validation
- Read-only probe; no credentials, no state change. `git diff --check` clean; committed files scanned to
  ensure no IP/MAC/bridge-id leaked.

### Gotchas
- Cert CN case is NOT consistent across bridges (one upper, one lower) while `/api/0/config.bridgeid` is
  uppercase → the identity comparison MUST be case-insensitive (normalize both to uppercase).
- The bridge serves only its leaf in the TLS handshake (no chain) → the Signify root CA must be bundled
  out-of-band; cannot be scraped from the handshake.

## 2026-06-28 - [Codex] Review Android pairing decision proposal

### Branch
- `docs/parallel-agent-pipeline`.

### Did
- Reviewed Claude's D-001/D-002 proposal at `02c7271`, rechecked the accessible official Hue and
  Android security sources, and appended the Codex review to the decision doc and Decision Log.
- Clarified that the link button authorizes application-key creation but does not authenticate TLS,
  and that a `bridgeid` learned only through the connection under test cannot independently bootstrap
  that connection's identity. Added direct primary-source links missing from the proposal.

### Working
- The proposed Signify-chain + bridge-identity direction remains a candidate. The docs now distinguish
  authorization, server authentication, and durable bridge identity as separate guarantees.

### Left
- D-001/D-002 remain DEFERRED and D-011 remains DISCUSSING. Closing evidence still requires the
  login-gated official Hue certificate/configuration material and/or a human-approved redacted bridge
  certificate/config probe. `generateclientkey` also remains proposed pending official evidence.

### Validation
- Docs-only; `git diff --check` clean. No application source, credentials, or network probes.

### Gotchas
- A real Hue bridge certificate can validate to a trusted Signify root yet still require an independent
  rule binding the selected physical bridge to the certificate identity; do not derive both sides of
  that comparison solely from the same untrusted first connection.

## 2026-06-28 - [Claude] Android pairing decision packet (D-001/D-002 proposal)

### Branch
- `docs/parallel-agent-pipeline`. Docs-only; no Android/iOS source, Gradle, manifest, deps, or network
  changes; no bridge probe; no Batch 3 branches.

### Did
- Executed `docs/coordination/prompts/android-pairing-decisions-prepare.md` (planning/research only) against
  `origin/main` @ `7ed6468`. Preflight: SHA pinned, D-011 + prompt present, and re-verified from source that
  `BridgeEndpoint` is name/host/port only (`endpointKey` = host:port, routing-only) and
  `BridgeCredentialAlias` requires a stable `bridgeId` matching `^[A-Za-z0-9_-]+$`.
- Ran a primary-source research workflow (4 researchers — Hue TLS, bridge identity, pairing/`clientkey`,
  Android TLS — + 1 adversarial evidence reviewer). The reviewer confirmed a safe proposal is possible but
  downgraded the Hue-TLS specifics because the official "Using HTTPS"/Configuration-API pages are
  login-gated and unreadable here.
- Wrote the coupled D-001/D-002 proposal + C (`generateclientkey`) recommendation into
  `docs/android/android-pairing-tls-identity-decision.md` → "Resolution proposal" (evidence table with
  fact/community/inference labels, threat model, proposed contracts, alternatives rejected, recovery,
  validation matrix, unresolved-evidence + how-to-close). Appended Claude turns under D-001 and D-002 and a
  review turn under D-011; prior turns left intact.

### Working
- Proposal direction is primary-source-grounded: first contact via the physical link-button flow; trust by
  Signify-CA chain + cert-identity == `bridgeid`, never trust-all/blanket-true; canonical identity = the
  bridge-reported `bridgeid` (16-hex already fits the alias charset — no alias change); `clientkey` is
  Entertainment-only, so omit `generateclientkey` for the MVP.

### Left
- **D-001/D-002 remain DEFERRED; D-011 remains DISCUSSING** — proposal awaits Codex/human review. To close:
  (1) read the login-gated official pages with a Hue developer account + byte-verify the root-CA `.pem`;
  (2) human-approved real-bridge probe (`openssl s_client` for chain/CN/**SAN**/validity; `/api/0/config`
  for `bridgeid` format; reboot/DHCP change for `bridgeid` stability). A Batch 3 implementation
  manifest/launch comes only after both blockers are explicitly accepted.

### Validation
- Docs-only; `git diff --check` clean. No code, no tests, no probe.

### Gotchas
- The decisive Android wrinkle: default Android hostname verification follows RFC 6125 (matches SAN,
  ignores CN), but Hue's identity is reportedly in the cert CN (== `bridgeid`). Whether the leaf carries a
  usable SAN decides Network-Security-Config-CA-pinning vs a custom verifier — unconfirmed, so DEFERRED.
- `bridgeid` durability across DHCP/reboot/factory-reset is the core D-002 premise but is currently
  inference (MAC-derived EUI-64), not confirmed from official docs.

## 2026-06-28 - [Codex] Prepare Android pairing decision-resolution packet

### Branch
- `docs/parallel-agent-pipeline`.

### Did
- Added a Claude-ready, planning-only prompt for the next critical-path work: resolve D-001 safe TLS
  bootstrap and D-002 canonical bridge identity from primary evidence before defining Batch 3.
- Recorded D-011 and linked the prompt from the canonical agent and pipeline current-state sections.

### Working
- Claude Code can execute `docs/coordination/prompts/android-pairing-decisions-prepare.md` directly.
  The packet produces a reviewable docs proposal and explicitly forbids runtime code or live bridge
  probes without human approval.

### Left
- Claude evidence pass, then Codex/human review. Pairing and credential-persistence remain blocked;
  no Batch 3 manifest or launch prompt exists yet.

### Validation
- Docs-only; `git diff --check` clean. Current endpoint/credential contracts re-read from `main`.

### Gotchas
- D-001 and D-002 are coupled: identity evidence may participate in TLS authentication, so resolving
  or implementing them in independent parallel lanes would create an unsafe contract gap.

## 2026-06-28 - [Codex] Verify and reconcile consolidated pipeline docs

### Branch
- `docs/parallel-agent-pipeline`.

### Did
- Verified the consolidated agent context against `origin/main` @ `7ed6468` and the Batch 1/2 Git
  history. Recorded D-010 and corrected the remaining summary-only inconsistencies: the canonical
  merge/shared-file ownership rules, the generic `integration/parallel-batch-N` lifecycle target, and
  the Batch 2 launch/correction prompt headers that still said the batch had not landed.

### Working
- Agent-facing current-state summaries now agree that Batch 2's corrected integration `9411d81` is on
  `main` @ `7ed6468`; lane agents return handoffs while the batch owner serially owns shared docs.

### Left
- No batch is in flight. D-001 and D-002 remain the only active blockers.

### Validation
- Docs-only review; `git diff --check` clean. No source or historical Decision Log turn changed.

### Gotchas
- Historical prompt bodies retain their pinned execution bases by design; only their status headers
  were updated to show the final landing.

## 2026-06-28 - [Claude] Consolidate coordination docs (prune historical batch detail)

### Branch
- `docs/parallel-agent-pipeline`.

### Did
- Re-consolidated the agent-facing docs so Codex reads the full current scope with no stale content,
  now that Batches 1 & 2 are on `main` @ `7ed6468`:
  - `AGENTS.md` → "Android Current State" rewritten as the single authoritative inventory of what's
    shipped on `main` (Setup/Dashboard/RoomDetail/Scenes/Settings + app-owned demo state) plus the full
    durable code-contract list (model guards, lightCount invariant, scene `bridgeId`, fixture surface,
    state ownership + bridge-aware callbacks, `when`-router, `appVersion` literal, single-AVD serial).
  - `docs/coordination/parallel-agent-pipeline.md`: removed the obsolete §4 "Original Pilot Draft";
    pruned the resolved Open Questions (Q1–Q9); condensed the executed §7/§8 manifests to compact
    COMPLETE records (keeping the execution-result evidence); refreshed §1 registry statuses to
    `merged → main`; generalized §3 to `batch-N`; added a current-state line to the Status header and a
    new §9 "Current Pipeline State & Next Steps" with explicit hooks for Codex to verify and to propose
    D-010+ adjustments / a Batch 3. Decision Log turns (D-001–D-009) were preserved verbatim.
  - `DEVLOG.md` snapshot consolidated; dropped the superseded pre-pilot "17 connected tests" baseline.

### Working
- Docs reflect the current `main` (both batches merged); historical/planning scaffolding pruned; the
  Decision Log audit trail and per-batch result records are intact.

### Left
- No code change. Next substantive work is Codex review / a Batch 3 proposal as a new Decision Log entry
  (see pipeline §9). D-001/D-002 remain the active blockers.

### Validation
- Docs-only; `git diff --check` clean. No Android source touched.

### Gotchas
- The pipeline Decision Log is append-only ("never rewrite another agent's turn"); consolidation pruned
  only the operational scaffolding (manifests/draft/resolved questions), never the dated decision turns.

## 2026-06-28 - [Claude] Merge parallel Batch 2 to main

### Branch
- `main` @ `7ed6468` (merged `--no-ff` from `integration/parallel-batch-2` @ `9411d81`; pushed).

### Did
- On the human collaborator's go-ahead, fetched the latest docs branch (`3b63d52`, Codex's "verify
  corrected Batch 2") and merged the D-009-corrected Batch 2 integration into `main`. `main` was an
  ancestor of the integration branch, so the merge was clean (no conflicts). Pushed `origin/main`
  `a3fe54f..7ed6468`. Confirmed the room-detail/scenes/settings sources are present on `main`.
- Recorded the landing: pipeline §8 + §1 registry context, AGENTS.md one-line state + Android Current
  State, and the DEVLOG snapshot now read "merged to `main` @ `7ed6468`".

### Working
- Batch 2 (room-detail / scenes / settings feature screens, nav integration, and the D-009
  persist-across-navigation fix) is on `main`. Pre-merge gate was green (unit 84/0, connected 34/0 on
  `Pixel_10`) and independently verified by Codex; not re-run at merge time (clean fast-forwardable merge
  of already-validated, twice-verified commits).

### Left
- Both Android pilot batches are on `main`. Next: Batch 3 scoping when desired (the pipeline can fan out
  further feature packages + a serialized nav wave, same as Batch 2). Pairing/persistence remain blocked
  by D-001/D-002.

### Validation
- Pre-merge: `origin/integration/parallel-batch-2` confirmed `9411d81`; `main` `a3fe54f`; ancestor check
  clean. Post-merge: Batch 2 sources verified present on `main` @ `7ed6468`.

### Gotchas
- The SSH identity can push `main` directly (the documented "agent gh account not a collaborator" limit
  applies only to the `gh` bot, not the local SSH key); both Batch 1 and Batch 2 final merges were pushed
  this way after explicit user go-ahead.

## 2026-06-28 - [Codex] Verify corrected Batch 2 for final merge

### Branch
- Docs review: `docs/parallel-agent-pipeline`
- Reviewed integration: `integration/parallel-batch-2` @ `9411d81`

### Did
- Reviewed the D-009 correction and confirmed app-owned room/light/scene state survives destination disposal and reopening.
- Confirmed the correction changed only the three allowed files and the persistence E2E covers room, light, and scene continuity.
- Added final Codex verification evidence to D-009 and §8.

### Working
- Batch 2 is merge-ready; `main` remains unchanged pending explicit authorization.

### Left
- Merge `integration/parallel-batch-2` @ `9411d81` to `main` when authorized.

### Validation
- `testDebugUnitTest` passed 84/84; `lintDebug` and `assembleDebug` passed.
- `connectedDebugAndroidTest` passed 34/34 on headless `Pixel_10`.
- `git diff --check 4c74beb..9411d81` passed.

### Gotchas
- Demo callback matching currently relies on globally unique resource IDs; include `bridgeId` in lookup predicates before introducing multi-bridge demo fixtures.

## 2026-06-28 - [Claude] Resolve D-009 — hoist Batch 2 demo state across navigation

### Branch
- Correction lane: `lane/android2-state-ownership-correction` @ `16810a1` (off `integration/parallel-batch-2` @ `4c74beb`).
- Corrected integration: `integration/parallel-batch-2` @ `9411d81` (pushed).
- Not merged to `main` — eligible (D-009 resolved); awaits the human collaborator's go-ahead.

### Did
- Ran `parallel-batch-2-corrections.md` after preflight (origin integration still `4c74beb`; D-009 +
  prompt on the docs branch). One serialized correction lane resolved D-009 (demo mutations were lost on
  navigation because the `when`-router disposes inactive destinations and screen-local `remember{}` state
  reseeded from immutable `DemoFixtures`):
  - Hoisted demo room/light/scene state into `ChromaGlowApp` as `mutableStateListOf`, seeded from
    `DemoFixtures` only on entering demo mode and cleared on every return-to-Setup (Dashboard back +
    Settings `onExitDemo`).
  - Consumed the existing bridge-aware callbacks: added `onRoomToggle`/`onRoomBrightnessChange` to
    `DashboardPlaceholderScreen` (removed its screen-local reseed; preserved public params + Switch/Slider/
    status text), and wired `RoomDetailScreen`'s `(bridgeId, lightId, value)` and `ScenesScreen`'s
    `(bridgeId, sceneId)` exclusive-activation callbacks into the app-owned state.
  - Extended `NavIntegrationE2ETest` to prove persistence: change a light → back → reopen room → assert it
    survived; activate a scene → back → reopen Scenes → assert still active + previous inactive; plus a
    dashboard-toggle-survives-reopen test. `DemoModeSession`/`DemoFixtures` and all Wave 1 internals
    unchanged; in-memory only.
- An independent adversarial verifier confirmed all D-009 acceptance checks. Verified only the 3 allowed
  files changed, merged `--no-ff` into `integration/parallel-batch-2`, re-ran the full gate, pushed.

### Working
- Corrected gate all green: `testDebugUnitTest` **84/0** · `lintDebug` clean · `assembleDebug` ok ·
  `connectedDebugAndroidTest` **34/0** on the headless `Pixel_10`.

### Left
- Human collaborator: final merge of `integration/parallel-batch-2` @ `9411d81` → `main` (promotion gate
  met; D-009 resolved). Lane/integration branches retained; worktrees cleaned up.

### Validation
- Preflight: `origin/integration/parallel-batch-2` confirmed `4c74beb`; D-009 present.
- Lane self-validated the full gate on-device; batch owner re-ran `testDebugUnitTest lintDebug
  assembleDebug connectedDebugAndroidTest` on the merged result. `git diff --check` clean.

### Gotchas
- `ChromaGlowApp` is the single owner of in-memory demo state; feature screens keep their own internal
  `remember{}` for in-screen feedback but re-seed from app-owned state on reopen (the `when`-router
  disposes them), so the app shell drives persistence.
- Bridge-aware callbacks pass `bridgeId` but matching is by `roomId`/`lightId`/`sceneId` (demo ids are
  unique); a future multi-bridge fixture would need bridge-scoped matching.

## 2026-06-28 - [Codex] Batch 2 post-execution review

### Branch
- Docs review: `docs/parallel-agent-pipeline`
- Reviewed integration: `integration/parallel-batch-2` @ `4c74beb`

### Did
- Verified all four lane boundaries and inspected the integrated Android source/tests.
- Independently reran unit tests, lint, assembly, and all 33 connected tests successfully.
- Added D-009: screen-local demo mutations reset when navigation removes Dashboard, RoomDetail, or Scenes from composition because the app shell ignores their state callbacks.
- Added a focused serialized correction prompt requiring app-owned in-memory state and reopen-after-navigation E2E assertions.

### Working
- Batch 2 remains pushed and otherwise green; no correction has been merged yet.

### Left
- Run `docs/coordination/prompts/parallel-batch-2-corrections.md`.
- Review corrected integration evidence before merging Batch 2 to `main`.

### Validation
- Detached review of `4c74beb`: `testDebugUnitTest lintDebug assembleDebug` passed.
- `connectedDebugAndroidTest` passed 33/33 on headless `Pixel_10`.
- `git diff --check a3fe54f..4c74beb` passed.

### Gotchas
- The existing E2E exercises mutations only while each destination remains composed; green tests do not currently prove session-state continuity across navigation.

## 2026-06-28 - [Claude] Execute parallel Batch 2 — two-wave feature + nav integration

### Branch
- Integration: `integration/parallel-batch-2` @ `4c74beb` (forked from `main` @ `a3fe54f`; pushed).
- Wave 1 lanes: `lane/android2-roomdetail` @ `a3cd34a`, `lane/android2-scenes` @ `fbf8a71`,
  `lane/android2-settings` @ `174ddaa`. Wave 2: `lane/android2-nav-integration` @ `1a419d2`.
- Not merged to `main` — promotion gate satisfied; awaits the human collaborator's go-ahead.

### Did
- Executed `parallel-batch-2-launch.md` exactly as written after confirming the preflight gates
  (origin/main still `a3fe54f`; D-008 ACCEPTED; clean slate).
- Wave 1 (3 concurrent sub-agents, disjoint feature packages, no nav edits): `RoomDetailScreen`
  (per-light Switch/Slider, bridge-aware `(bridgeId, lightId, …)` callbacks, slider clamped 1..100),
  `ScenesScreen`/`SceneRow` (exclusive activation, `(bridgeId, sceneId)` callback), `SettingsScreen`
  (`onExitDemo`, `appVersion` literal — no BuildConfig). Each compile/unit/lint-checked in isolation.
- Merged Wave 1 into `integration/parallel-batch-2` and ran the serialized connected gate on the shared
  `Pixel_10`. It caught a real on-device failure isolated to Lane S (active-indicator assertion against
  a merged `Surface` semantics node); re-dispatched the scenes lane, which fixed it in-lane with
  `useUnmergedTree = true` (source untouched) and re-validated connected green.
- Wave 2 (serialized): extended `ChromaGlowDestination` + the `when`-router to reach all three screens
  with demo data; added additive dashboard entry points (a discrete tappable room-name affordance and
  Scenes/Settings buttons) that left `DemoRoomRow`'s Switch/Slider/status-line text intact; wrote
  `NavIntegrationE2ETest` exercising behavior (toggle a light, change brightness, exclusive scene
  activation, exit demo → Setup). Merged into integration.

### Working
- Final integrated gate all green: `testDebugUnitTest` **84/0** · `lintDebug` clean · `assembleDebug`
  ok · `connectedDebugAndroidTest` **33/0** on the headless `Pixel_10` (incl. the Batch 1
  `ChromaGlowAppTest`/`DemoRoomControlsTest`, kept green by additive-only dashboard changes).

### Left
- Human collaborator: final merge of `integration/parallel-batch-2` → `main` (promotion gate met —
  Lane N E2E green, no unwired UI). Lane/integration branches retained; worktrees cleaned up.

### Validation
- Per-lane (Wave 1): `testDebugUnitTest lintDebug assembleDebugAndroidTest` (compile/unit/lint, no
  emulator). Connected validation run serially by the batch owner on the integrated result.
- Wave 2 + integrated: full gate `testDebugUnitTest lintDebug assembleDebug connectedDebugAndroidTest`.
- Boundary audit: every lane changed only its allowed globs; Wave 1 disjoint; only Wave 2 touched the
  §2 nav hotspots.

### Gotchas
- `Surface(onClick = …)` sets `MergeDescendants = true`, so a child's `testTag` is only an independently
  "displayed" node in the UNMERGED semantics tree — connected Compose tests on such children must use
  `onNodeWithTag(tag, useUnmergedTree = true)`.
- Per the single-AVD rule, Wave 1 lanes only compile-checked their androidTest; the batch owner ran all
  connected validation serially on `emulator-5554`. The workflow-agent emulator is reaped at run end, so
  the owner re-boots `Pixel_10` for each owner-run gate.

## 2026-06-28 - [Codex] Approve Batch 2 manifest and launch prompt

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Adversarially reviewed the Batch 2 two-wave manifest against `main` @ `a3fe54f` and accepted D-008.
- Required bridge-aware room-light and scene-activation callbacks so future multi-bridge callers can route correctly.
- Resolved Q6–Q9: parameter-injected feature models, existing `when(destination)` router, explicit Exit Demo Mode semantics, and serialized connected tests on the shared AVD.
- Tightened the Wave 2 E2E to exercise light controls, exclusive scene activation, Settings back, and Exit Demo Mode rather than navigation alone.
- Marked §8 and `parallel-batch-2-launch.md` execution-ready and synchronized canonical status files.

### Working
- Claude can execute Batch 2 from the ready launch prompt while `origin/main` remains pinned at `a3fe54f`.

### Left
- Run `docs/coordination/prompts/parallel-batch-2-launch.md`.
- Stop and re-pin if `origin/main` advances before launch.

### Validation
- Docs-only review; `git diff --check` passed before publication.
- No Android runtime tests were needed because no Android source changed.

### Gotchas
- Wave 1 code may run concurrently, but the batch owner must serialize connected tests on the single `Pixel_10` AVD.

## 2026-06-28 - [Claude] Merge Batch 1 to main + draft Batch 2 manifest

### Branch
- `main` @ `a3fe54f` (corrected Batch 1 merged `--no-ff`; pushed).
- `docs/parallel-agent-pipeline` (this handoff + §8 Batch 2 manifest + D-008 + Batch 2 launch prompt).

### Did
- Merged corrected Batch 1 (`integration/parallel-batch-1` @ `0d7c218`) into `main` `--no-ff` and pushed
  → `main` @ `a3fe54f`. (The SSH identity has write access; only the `gh` bot account does not.)
- Ran the prepare prompt `parallel-batch-2-prepare.md` against the actual landed tree and drafted the
  **Batch 2 manifest** in pipeline §8: base `main` @ `a3fe54f`; two waves — Wave 1 parallel feature
  packages `lane/android2-roomdetail` / `-scenes` / `-settings` (each Compose-UI-tested against the Batch 1
  contracts, no nav edits), Wave 2 serialized `lane/android2-nav-integration` owning the §2 nav hotspots +
  dashboard entry points, wiring + exercising every Wave 1 screen via a connected E2E.
- Ran an internal 3-lens adversarial review (disjointness/hotspots, real-tree testability, prepare-prompt
  compliance) and folded the fixes into §8: added §1 registry rows (`android-roomdetail|scenes|settings|
  nav-shell`) + reconciled `android-dashboard`; pinned `appVersion` off `BuildConfig` (disabled on main);
  gave Lane N the dashboard androidTest + an additive-only nav/dashboard constraint; fixed the
  stateless-screen state pattern, slider 1..100 floor, nullable `lightsByRoom[id]` get, and exclusive
  scene activation. Added Decision Log **D-008** requesting Codex review and Open Questions **Q6–Q9**.
- Created `docs/coordination/prompts/parallel-batch-2-launch.md` (DRAFT, gated on D-008).
- Pruned stale status across AGENTS.md, the DEVLOG snapshot, and the batch-1/batch-2 prompt headers
  (Batch 1 now "merged to main"; Batch 2 "DRAFT pending Codex").

### Working
- Batch 1 is on `main`. Batch 2 manifest + launch prompt are DRAFT and internally review-clean; awaiting
  Codex's D-008 adversarial review before any launch.

### Left
- Codex: review §8 + D-008 + Q6–Q9. Once D-008 is ACCEPTED, flip `parallel-batch-2-launch.md` to `Ready`
  and execute the two-wave batch.
- Per §8 promotion gate, `integration/parallel-batch-2` may merge to `main` only after Lane N's connected
  E2E is green (no unwired UI).

### Validation
- Batch 1 merge: fast-forwarded local `main` to `origin/main`, merged `--no-ff`, pushed `origin/main`
  (`defe869..a3fe54f`); Batch 1 files confirmed present on `main`.
- Batch 2 prep is docs-only (no Android source changed); manifest reviewed by 3 independent agents against
  the landed `main` tree. `git diff --check` clean before commit.

### Gotchas
- `BuildConfig` is disabled on `main` (`app/build.gradle.kts` has no `buildConfig = true`); a Settings
  screen must take `appVersion` as a passed-in string — enabling BuildConfig would be an out-of-scope
  §2 hotspot edit.
- Wave 2's dashboard entry points must be additive (discrete `onOpenRoom` affordance; explicit
  Scenes/Settings buttons) to keep `ChromaGlowAppTest` + `DemoRoomControlsTest` green.

## 2026-06-28 - [Claude] Resolve D-007 — Batch 1 contract corrections

### Branch
- Correction lane: `lane/android1-contract-corrections` @ `eaa0f49` (off integration `2a156b5`).
- Corrected integration: `integration/parallel-batch-1` @ `0d7c218` (pushed to origin).
- Not merged to `main` — awaits the human collaborator's final merge.

### Did
- Resolved D-007 (Codex's Batch 1 adversarial review) with one serialized correction lane owning only
  `SceneDisplayModel.kt`, `DemoFixtures.kt`, and their two test files:
  - Added a non-blank `bridgeId` to `SceneDisplayModel` (`require(bridgeId.isNotBlank())` + a
    blank/whitespace rejection test) and set every demo scene's `bridgeId = DEMO_BRIDGE_ID`, asserted
    by a new invariant test — gives scenes explicit cross-bridge routing identity.
  - Added the missing deterministic demo lights so each room's `lightCount` exactly equals
    `lightsByRoom[room.id].size` (Bedroom 4, Kitchen 8, Living 5, Office 2) — by ADDING lights, not
    lowering the established dashboard counts; `rooms` / `DEMO_BRIDGE_ID` left byte-identical.
  - Added `rooms_lightCountMatchesLightsByRoomSize`, a fixture-consistency test that fails on any
    room/count mismatch (including a room with no backing fixtures).
- Ran two independent adversarial verifiers (contract+rigor and build+boundary lenses) before merge —
  both passed every check. Verified only the four allowed files changed, then merged `--no-ff` into
  `integration/parallel-batch-1` and pushed it. Marked D-007 RESOLVED and updated §7.

### Working
- Re-validated integrated gate all green: `testDebugUnitTest` **84/0** failures · `lintDebug` clean ·
  `assembleDebug` ok · `connectedDebugAndroidTest` **20/0** on the headless `Pixel_10`.

### Left
- Batch 2 is now unblocked — run `docs/coordination/prompts/parallel-batch-2-prepare.md` (planning
  only). No Batch 2 manifest/launch prompt exists yet.
- Human collaborator still performs the final merge of `integration/parallel-batch-1` → `main`.

### Validation
- Preflight: `origin/integration/parallel-batch-1` confirmed `2a156b5` before correction; D-007 commit
  `3be8e48` present on the docs branch; toolchain exported.
- Correction lane: `./gradlew testDebugUnitTest lintDebug assembleDebug` green (84/0).
- Integrated (post-merge @ `0d7c218`): `testDebugUnitTest lintDebug assembleDebug
  connectedDebugAndroidTest` all green; `git diff --check` clean.

### Gotchas
- A whole-file grep of `roomId = "demo-room-*"` shows +1 per room beyond the light count — those are
  the four scene `roomId` references, not extra lights. Per-light-id counts are exactly 4/8/5/2.
- `SceneDisplayModel.bridgeId` is required (non-blank); all in-repo callers are the demo fixtures +
  test (model is otherwise unconsumed), so adding the field broke nothing outside the lane.

## 2026-06-28 - [Codex] Add Batch 1 contract-corrections prompt

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Added `docs/coordination/prompts/parallel-batch-1-corrections.md` to resolve D-007 in one serialized ownership lane.
- Required explicit scene `bridgeId`, exact room/light fixture-count consistency, focused tests, full integrated Android validation, and corrected integration evidence.
- Updated the prompt sequence and gated Batch 2 preparation on D-007 resolution.

### Working
- Claude has a ready-to-run correction prompt based on `integration/parallel-batch-1` @ `2a156b5`.

### Left
- Run the correction prompt and review Claude's D-007 response.
- Run Batch 2 preparation only after the corrected integration gate is green.

### Validation
- Docs-only; `git diff --check` passed before publication.

### Gotchas
- Both corrections touch the same model/fixture ownership area, so they must remain one lane rather than parallel sub-lanes.

## 2026-06-28 - [Codex] Batch 1 adversarial review

### Branch
- Docs review: `docs/parallel-agent-pipeline`
- Reviewed integration: `integration/parallel-batch-1` @ `2a156b5`

### Did
- Confirmed Batch 1 lane branches are disjoint and the integration handoff records a fully green gate.
- Added D-007 for two pre-Batch-2 contract gaps: room `lightCount` values disagree with per-room demo fixtures, and `SceneDisplayModel` lacks explicit bridge routing required for cross-bridge activation.
- Confirmed no Batch 2 manifest or launch prompt exists yet; only the planning prompt is present.

### Working
- Batch 1 integration remains available on origin for correction and revalidation.

### Left
- Resolve D-007 on the Batch 1 integration branch and rerun the full Android gate.
- Then run `parallel-batch-2-prepare.md`, review its draft manifest, and create the Batch 2 launch prompt.

### Validation
- `git diff --check` passed for the docs review before publication.
- Runtime tests were not rerun; Claude's integrated handoff records 81 unit tests and 20 connected tests passing.

### Gotchas
- Do not merge Batch 1 to `main` merely because tests are green; the fixture and routing contracts become user-visible dependencies in Batch 2.

## 2026-06-28 - [Claude] Execute parallel Batch 1 two-lane Android pilot

### Branch
- Integration: `integration/parallel-batch-1` @ `2a156b5` (forked from `origin/main` @ `defe8691`).
- Lanes: `lane/android1-domain-models` @ `be51edd`, `lane/android1-dashboard-controls` @ `c25b9ac`.
- Not merged to `main` — awaits the human collaborator's final merge.

### Did
- Ran the first real parallel-pipeline batch end to end as batch owner. Re-fetched and re-verified the
  pinned base `defe8691…`, confirmed the local Android toolchain (JDK 21 / SDK / `Pixel_10` AVD),
  created `integration/parallel-batch-1` and two isolated lane worktrees off the base.
- Launched both lanes concurrently (Claude Workflow, one sub-agent per lane, disjoint globs):
  - L1 `android-models`: added `LightDisplayModel` + `SceneDisplayModel` and additive
    `DemoFixtures.lights` / `lightsByRoom` / `scenes` with JVM unit tests; kept `rooms` /
    `DEMO_BRIDGE_ID` byte-identical.
  - L2 `android-dashboard`: added an on/off `Switch` + brightness `Slider` to `DemoRoomRow` (in-memory
    session state, no persistence) with a Compose UI test; preserved the status-line text and the
    `DashboardPlaceholderScreen` public signature so the nav-shell caller still compiles.
- Independently verified each branch changed only its permitted globs (lanes disjoint, zero §2-hotspot
  edits), then merged both into the integration branch with `--no-ff` (no conflicts).
- Marked both registry lanes `merged` and recorded the result in pipeline-doc §7.

### Working
- Integrated gate all green: `testDebugUnitTest` 81/0 failures · `lintDebug` clean · `assembleDebug` ok ·
  `connectedDebugAndroidTest` 20/0 failures on the headless `Pixel_10`.

### Left
- Human collaborator performs the final merge of `integration/parallel-batch-1` → `main` (agent `gh`
  account is not a repo collaborator). Lane/integration branches and worktrees are retained for review.
- L1 fixtures (`lights` / `lightsByRoom` / `scenes`) are intentionally unconsumed this batch — Batch 2
  (room-detail / scenes) is their first consumer; see `parallel-batch-2-prepare.md`.

### Validation
- Pre-launch: base SHA re-pinned and unchanged; toolchain present; baseline already validated (D-005).
- Per lane: L1 `./gradlew testDebugUnitTest` green; L2 `./gradlew connectedDebugAndroidTest` green.
- Integrated: `testDebugUnitTest lintDebug assembleDebug` + `connectedDebugAndroidTest` all green with
  the manifest toolchain exports.

### Gotchas
- The workflow sub-agents' background emulator is reaped when the run ends; the batch owner re-boots
  `Pixel_10` for the integrated connected gate.
- `LightDisplayModel.brightness` and the L2 `Slider` stay in `1..100` even when a light/room is off
  (stored level), matching `RoomDisplayModel`'s `require(...)`; a 0 would crash `room.copy(...)`.
- Two concurrent Gradle builds in separate worktrees share `~/.gradle` cleanly (no corruption); only
  Lane 2 needs the emulator, so there was no device contention.

## 2026-06-28 - [Codex] Add Batch 2 preparation prompt

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Added `docs/coordination/prompts/parallel-batch-2-prepare.md` as the second orchestration prompt.
- Made it planning-only and gated on a completed, fully validated Batch 1 integration result.
- Directed Batch 2 planning toward parallel feature packages followed by one serialized navigation-integration wave.

### Working
- The prompt is ready to run after Batch 1 completes; it drafts Batch 2 for review without modifying Android source.

### Left
- Run the Batch 1 launch prompt first.
- After Batch 1 integration, run the preparation prompt and review its manifest before creating a Batch 2 launch prompt.

### Validation
- Docs-only; `git diff --check` passed before publication.

### Gotchas
- Batch 2 cannot be pinned safely until the actual Batch 1 integration SHA and landed model APIs exist.

## 2026-06-28 - [Codex] Add canonical Batch 1 launch prompt

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Added `docs/coordination/prompts/parallel-batch-1-launch.md` as the single ready-to-run Claude orchestration prompt.
- Linked the prompt from the Batch 1 manifest.

### Working
- Stable policy remains in `AGENTS.md`; batch-specific prompts can be revised or retired independently.

### Left
- Feed the prompt file to Claude Code when ready to launch Batch 1.

### Validation
- Docs-only; `git diff --check` passed before publication.

### Gotchas
- If `origin/main` advances, re-pin both the manifest and prompt before execution.

## 2026-06-28 - [Codex] Resolve local Android toolchain gate

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Found Android Studio's bundled JDK at `/Applications/Android Studio.app/Contents/jbr/Contents/Home`, the SDK at `~/Library/Android/sdk`, and the existing `Pixel_10` AVD.
- Updated D-005 from a blocker to a locally resolved validation prerequisite with explicit environment exports.
- Marked the narrowed two-lane Batch 1 manifest execution-ready and recorded baseline validation evidence.
- Made coordination files batch-owner-only during execution; lane agents return handoff text instead of concurrently editing `DEVLOG.md` or the manifest.

### Working
- Batch 1 can launch as two disjoint Claude lanes: domain models/fixtures and dashboard controls.
- Android CI remains recommended defense in depth but does not block the local pilot.

### Left
- Create the integration branch and two lane worktrees from the manifest's pinned `origin/main` SHA.
- Require each lane's listed validation to pass before integration.

### Validation
- `./gradlew testDebugUnitTest lintDebug assembleDebug` passed with the explicit JDK/SDK environment.
- `./gradlew connectedDebugAndroidTest` passed all 17 tests on the headless `Pixel_10` AVD.
- `git diff --check` passed before publication.

### Gotchas
- `/usr/bin/java` still reports no runtime; lane shells must use the explicit Android Studio `JAVA_HOME`.

## 2026-06-28 - [Claude] Apply Codex review to pipeline doc

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Conceded D-005: withdrew option (c); `testDebugUnitTest` is an AGP task so pure-Kotlin models in the `app` module still need JDK 17 + Android SDK. Recommended option (b): an Android Gradle CI job to gate the integration branch.
- Accepted D-006 (set ACCEPTED): narrowed Batch 1 to two lanes — L1 `android-models` (domain models + fixtures) and L2 `android-dashboard` (controls on the wired dashboard). Dropped standalone Settings + generic state composables (unwired dead UI).
- Fixed §2: added `ChromaGlowDestination.kt` and Kotlin `ui/theme/**` as Android collision hotspots; manifest terminology now matches §2.
- Reconciled §1 registry: `android-models-theme` → `android-models` (theme removed, now a hotspot); mapped both pilot lanes to registry entries with proposed owners.
- Rewrote §7 to the narrowed two-lane manifest with named lane owners; answered Q4/Q5.

### Working
- Doc is internally consistent: manifest lanes ↔ registry entries ↔ §2 hotspots all aligned.

### Left
- Codex to review this updated doc.
- Human decision on D-005 (provision local JDK 17 + Android SDK, or stand up Android CI). Nothing executes until then.

### Validation
- Docs-only; `git diff --check` clean.

### Gotchas
- L1 is unconsumed this batch — justified only as independently unit-tested foundation Batch 2 needs; two lanes is the minimum to actually rehearse a parallel merge.

## 2026-06-28 - [Codex] Batch 1 manifest review for Claude

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Appended a Codex response to D-005: pure Kotlin in the Android Gradle module still requires a JDK and Android SDK, while Compose instrumentation validation additionally requires an emulator/device runner.
- Added D-006 proposing a two-lane first pilot: domain models/fixtures plus controls on the already-wired dashboard.
- Responded to Q4/Q5: hold code lanes until equivalent validation exists and defer unwired Settings/state-component work until it has real callers.
- Requested Claude review of missing per-lane owners, registry mapping, and inconsistent collision-hotspot terminology.

### Working
- Claude's four-lane manifest remains a non-approved draft; no worktree should be created from it.
- D-005 and D-006 are `DISCUSSING` pending Claude/human response.

### Left
- Claude to weigh in on the narrower pilot and manifest corrections in the shared Decision Log.
- Provision a local Android toolchain or equivalent CI before approving code-writing lanes.

### Validation
- Docs-only review; `git diff --check` passed before publication.

### Gotchas
- A basic Android Gradle CI job does not exercise `connectedDebugAndroidTest`; Compose behavior tests need an emulator/device runner or a deliberately revised test strategy.

## 2026-06-28 - [Claude] Batch 1 manifest draft (for Codex review)

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Investigated current Android tree at `origin/main` @ `defe869`: dashboard is read-only, nav has only Setup/Dashboard, no Light/Scene model, no Settings/room-detail/state components → identified genuine unlanded, non-blocked work.
- Appended §7 "Batch 1 Manifest — DRAFT" to `docs/coordination/parallel-agent-pipeline.md`: 4 fully-parallel Android lanes (domain-models, dashboard-controls, settings, ui-states) with exact globs, acceptance criteria, forbidden files, and a §5 gate self-check. Zero collision-hotspot edits; nav wiring + room-detail/scenes explicitly deferred to Batch 2.
- Surfaced new blocker D-005 (no local JDK/Android toolchain, no Android CI → code can't be compiled/tested before merge) and Open Questions Q4/Q5.

### Working
- Manifest is review-ready and pinned to a named base commit.

### Left
- Codex to adversarially review the manifest + D-005/Q4/Q5 before any worktree is created.
- Resolve D-005 (toolchain/CI) — manifest is NOT execution-ready until then.

### Validation
- Docs-only; `git diff --check` clean. Confirmed `origin/main` @ `defe869`, android tree identical, `/usr/bin/java` reports no runtime.

### Gotchas
- The manifest deliberately builds new screens as standalone (non-nav-wired) composables to keep lanes disjoint; nav wiring is a single serialized Batch 2 lane that owns `ChromaGlowApp.kt` + `ChromaGlowDestination.kt`.

## 2026-06-28 - [Codex] Re-scope parallel pipeline pilot

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Marked the original Android Batch 1 table as historical and non-executable because its named work has landed.
- Added an execution-readiness gate requiring a current base SHA, exact disjoint globs, owner/branch, acceptance criteria, dependencies, forbidden files, and narrow validation for every lane.
- Added the `unscoped` registry state and applied it to Android ownership classes so landed work cannot be claimed as a new deliverable.
- Recorded D-004 and an independent Claude CLI review; Claude agreed and requested the D-003/registry consistency corrections now reflected in the document.

### Working
- Android remains the recommended first real parallel run, but no replacement Batch 1 lanes are scoped yet.
- Pairing and credential-persistence wiring remain blocked by D-001/D-002.

### Left
- Draft replacement Android lanes from the fetched current `origin/main` tree before creating worktrees.
- Land the stacked docs branches so the pipeline becomes canonical on `main`.

### Validation
- `git diff --check` passed.
- Claude CLI independently reviewed the proposal and agreed after identifying the registry/status consistency correction.

### Gotchas
- The branch remains stacked on `docs/consolidate-agent-handoff`; merge order still matters.

## 2026-06-24 - [Claude] Parallel agent pipeline + shared decision log

### Branch
- `docs/parallel-agent-pipeline` (stacked on `docs/consolidate-agent-handoff`)

### Did
- Added `docs/coordination/parallel-agent-pipeline.md`: lane registry (Android + iOS + cross-cutting), collision-hotspot list, branch/worktree/merge model, Android-only Batch 1 pilot, and a shared Claude⇄Codex Decision Log (seeded D-001 TLS blocker, D-002 identity blocker, D-003 Batch 1 scope, + Open Questions).
- Added "Parallel Agent Pipeline" section to `AGENTS.md` (canonical rules) plus branch-naming note and a Documentation Index entry for the new doc.
- Added a pointer line in `CLAUDE.md` and a snapshot line here in `DEVLOG.md`.

### Working
- Disjoint-lane model is documented and ready: agents own non-overlapping globs; gate files are single-owner per batch; merges land on `integration/parallel-batch-N` with a human final merge to `main`.
- Decision Log is the durable, git-backed back-and-forth channel between Claude and Codex.

### Left
- Codex to review and append to the Decision Log (especially D-001/D-002 and Open Questions Q1–Q3).
- Run the Android Batch 1 pilot via Claude Workflow + worktree isolation once scope is confirmed.
- Human collaborator to open/merge the PR (agent `gh` account is not a collaborator).

### Validation
- Docs-only change; `git diff --check` clean. No runtime/code/Xcode/Gradle files touched.

### Gotchas
- This branch is stacked on `docs/consolidate-agent-handoff`, which is not yet merged to `main`. Land that first (or merge both together) so the canonical `AGENTS.md`/`CLAUDE.md` and this pipeline doc arrive on `main` consistently.

## 2026-06-24 - [Codex] Agent handoff consolidation

### Branch
- `docs/consolidate-agent-handoff`

### Did
- Made `AGENTS.md` the canonical shared context and source catalog.
- Replaced `CLAUDE.md` with a thin Claude Code entry point that immediately directs Claude to `AGENTS.md` and `DEVLOG.md`.
- Added this current snapshot and handoff template to the top of `DEVLOG.md`.

### Working
- Root handoff now follows one-source-of-truth rules instead of maintaining two large duplicated context files.
- Current iOS scheme and Android status are reflected in the root handoff.

### Left
- Open/merge PR from GitHub with a collaborator account if repository policy requires review.

### Validation
- `git diff --check` passed.
- Scanned root handoff files for stale `HueHome` scheme and old Android-not-started language.
- Branch push succeeded.
- Draft PR creation via `gh pr create` was blocked because the authenticated GitHub account is not a collaborator.

### Gotchas
- `CURSOR_KICKOFF.md` and older historical devlog entries still contain stale `HueHome` scheme references; agents should follow `AGENTS.md` for current validation commands.
- Pushed branch is available at `origin/docs/consolidate-agent-handoff`; Claude can read it immediately after fetching/checking out that branch.

## 2026-05-07 — Multi-Bridge Concurrent Entertainment Sessions (Antigravity)

### What was built

Upgraded the entertainment transport layer from a single-session global to a **per-bridge dictionary**, enabling concurrent DTLS sessions across multiple Hue bridges simultaneously.

#### Root cause
The old guard `compositionEntRoomID == nil` was global — starting entertainment on Bridge A blocked Bridge B from ever using DTLS, silently falling back to choppy REST.

#### Changes
All single-slot state replaced with `[bridgeID: ...]` dictionaries:

| Old | New |
|---|---|
| `compositionEntTask: Task?` | `compositionEntTasks: [String: Task]` |
| `compositionEntRoomID: String?` | `compositionEntRoomByBridge: [String: String]` |
| `compositionEntertainmentParamBox` (weak) | `compositionEntParamBoxes: [String: CompositionParamBox]` |
| `studioEntClient: HueEntertainmentClient?` | `studioEntClients: [String: HueEntertainmentClient]` |
| `activeEntertainmentConfig: EntertainmentConfig?` (stored var) | `entertainmentConfigsByBridge: [String: EntertainmentConfig]` + `activeEntertainmentConfig(for: RoomDisplayItem?)` method |

#### Impact
- **2 bridges = 2 simultaneous DTLS sessions = 20 smooth channels**
- Single-bridge behavior unchanged (dictionary has one entry)
- StudioView mini-map and direction dial now read config for the **currently selected room's bridge** — correct when switching between bridge rooms
- Mic demand check updated to `anyOf` across all active param boxes
- Stop path looks up bridgeID from roomID → cleans only that bridge's session

### Files changed
| File | Change |
|---|---|
| `UnifiedOrchestrator.swift` | Dictionary state, per-bridge guard, start/stop/cleanup paths |
| `StudioView.swift` | `activeEntertainmentConfig(for:)` at 4 call sites |
| `StudioViewModel.swift` | `studioEntClients[bridgeID]` at 2 call sites |

### Git state
- Commit: `f2f360b` on `main`
- BUILD SUCCEEDED

### How to test
1. **Single-bridge regression:** Start entertainment composition → verify `⚡ Entertainment transport active` log → stop → verify no crash
2. **Multi-bridge:** Pair two bridges, both with entertainment areas → start composition on each → both should log `⚡` with different bridgeIDs → mini-map switches correctly when navigating between rooms

---

## 2026-05-07 — Transport Architecture Research (Antigravity)

### What was investigated

Deep dive into why 16-light REST compositions show "room by room" sequential updates.

#### Root cause
REST per-light mode batches 5 PUTs with 80ms gaps → ~1.1s to cycle all 16 lights per frame. Not a code bug — a fundamental HTTP rate-limit constraint.

#### Transport tiers (current architecture)
```
Entertainment (DTLS)   → 25fps, all lights simultaneously, 10 channel limit, 1 session/bridge
REST per-light         → ~10 PUTs/sec, batches of 5, choppy on 8+ lights
Bridge v1 rules chain  → 3s min step interval, app-free, bridgeOptimized presets only
V2 Dynamic Palette     → bridge firmware cycles palette, unlimited lights, smooth, app-free
```

#### V2 Dynamic Palette — key findings
- Create scene with `palette.color[]` array + `speed` + `auto_dynamic: true`
- Recall with `action: "dynamic_palette"`
- **Bridge firmware handles cycling on the light itself** — zero ongoing network traffic
- Unlimited lights (whole room via grouped_light), persists after app close
- Trade-off: no directional patterns (wave/cascade/mirror), no envelope shapes, no mic
- `BridgeAnimationEngine.uploadV2DynamicScene()` already exists but is **not wired to the composer flow** and missing the `palette` property on `CreateSceneRequest`

#### What's not yet built
- [ ] `CreateSceneRequest` needs `palette` property (`color[]`, `color_temperature[]`, `speed`, `auto_dynamic`)
- [ ] `uploadV2DynamicScene` should use composer palette colors (not single t=0 snapshot)
- [ ] Wire into `startCompositionMode` as a transport tier between DTLS and REST
- [ ] "Persist on Bridge ⚡" toggle in mixer tray
- [ ] Cleanup on stop (delete dynamic scene from bridge)

### What's next
- [ ] Implement V2 Dynamic Palette as a composer transport tier
- [ ] Map `motion.speed` (0–100) → Hue `speed` (0.0–1.0)
- [ ] Badge on room card when bridge-powered effect is active

---

## 2026-05-07 — Codebase Audit: Architecture, Risks, Follow-ups (Cursor)

### What was reviewed
Thorough pass over critical paths (no line-by-line coverage of every file): `UnifiedOrchestrator`, `HueAPIClient`, Studio/Composer wiring, `RoomDisplayItem`, SSE/optimistic merge, `MainTabView` shell, cold-launch changes, logging patterns.

### Positive findings (keep)
- `pendingActionDeadlines` for SSE vs optimistic grouped_light updates reduces toggle flicker.
- Direct `allRooms` mutation in `updateRoom` with documented `@Observable` rationale.
- Composer generation guards, RestSender mailbox, entertainment vs REST split align with bridge reality.
- `RoomDisplayItem` uses full-field `==` (not id-only) so SwiftUI sees on/brightness/dominant color changes.
- Hue self-signed cert handling documented for session + task delegate (iOS 15+).

### Issues / edge cases (prioritized)
**High — reconcile docs vs code**
- `.cursorrules` says never send `effects` to `grouped_light`; `HueAPIClient` + `EffectsViewModel` intentionally use `setGroupedLightNativeEffect` for bridge-native effects. Clarify rule (Composer/custom vs firmware native) in `.cursorrules` / `DEVDOC.md` to avoid wrong “fixes.”

**High — correctness**
- Deprecated `toggleRoom`: rollback uses captured `item.isOn` on failure — stale if state moved; prefer removal or rollback by reading current room by id (`UnifiedOrchestrator`).
- `RoomDisplayItem`: `hash(into:)` mixes fewer fields than `==` uses — `Hashable` contract risk if identity-related fields change without hash updates.

**Medium**
- `StudioViewModel`: many `print(...)` calls on apply/handoff/AI paths — migrate to `Logger` + `#if DEBUG` or privacy-redacted `os_log` for release.
- Concurrent `loadAll`: second caller hits guard and returns early — confirm refresh UX is acceptable.
- Parallel `loadAll`: `deactivateStuckEntertainmentSessions` + fetch overlap — brief window where data loads before stuck session cleared; monitor if odd throttle on cold launch.
- SwiftData: `fatalError` on container init — no recovery path (acceptable for corrupt DB but worth knowing).

**Lower**
- MainTabView tab prewarm: trades idle memory for snappy first switch; optional tuning on low-memory devices.
- Legacy branding strings (“CastChroma”) still in some file headers — cosmetic.

### What's left
- [ ] Update `.cursorrules` / `DEVDOC` for grouped_light native effects vs Composer effects.
- [ ] Fix `RoomDisplayItem` hashing to align with `Equatable`, or document exception.
- [ ] Remove/fix deprecated `toggleRoom` rollback or delete call sites.
- [ ] Replace Studio `print` with structured logging for release builds.

### Gotchas
- Audit did not include full Keychain/remote OAuth review or device QA against a live bridge.

### Current state
No code changes from this audit entry alone — documentation and small correctness fixes deferred to follow-up tasks.

---

## 2026-05-07 — Cold-Launch First Tab Switch: Prewarm + Parallel loadAll (Cursor)

### What was built

**MainTabView — deferred-tab prewarm**
- After Home paints, stagger inserting `.studio`, then `.scenes` / `.more` into `realizedTabs` (~280ms + ~160ms) so heavy roots (`StudioView`, etc.) compile off the first-tab-tap critical path.
- `.task { await prewarmDeferredTabs() }` on the shell `Group` (iPhone + iPad).

**UnifiedOrchestrator — loadAll**
- `deactivateStuckEntertainmentSessions()` and bridge fetch/merge now run **in parallel** via outer `withTaskGroup` (cleanup no longer gates room data).
- Extracted `fetchAndMergeAllBridges()` (previous inner task-group body).
- `await Task.yield()` before `rebuildAllRooms()` / `rebuildAllZones()` so pending UI work can run before large `allRooms` / `allZones` observable updates.

### What's working
- ✅ `xcodebuild` HueHome — BUILD SUCCEEDED

### What's left
- [ ] Device QA: confirm first Studio tap feels instant; watch memory with all tabs realized.
- [ ] Instruments (Time Profiler + SwiftUI) if any hitch remains — optional further split of `StudioView`.

### Gotchas
- Tapping Studio within ~280ms of launch may still pay cold-build cost (edge case).
- Prewarm realizes all lazy tabs → higher idle memory; trade for snappy navigation.

### Current state
Cold-launch tab responsiveness addressed by idle prewarm + shorter loadAll critical path; ready for on-device timing validation.

---

## 2026-05-07 — Audit Bugfixes: 3 Bugs in Spatial Engine (Antigravity)

### What was changed

Post-implementation audit found 3 bugs in the Spatial Motion Engine. All fixed and verified with clean build.

#### Bug #1 — REST Spatial Positions Never Worked (Critical)
- **Root cause:** `computeSpatialPositions()` used `channel.lightServiceIDs` as map keys, but these are **entertainment** service IDs (from `/clip/v2/resource/entertainment_configuration` → `members[].service.rid`), NOT `light` service IDs. REST `compositionLightIDs` come from `fetchLights().map { $0.id }` — different UUID namespace. Lookup always returned nil → silent fallback to index-based.
- **Fix:** Added `resolveEntertainmentLightPositions()` to `UnifiedOrchestrator`. Fetches `/clip/v2/resource/entertainment` services in parallel with lights, builds the bridge: `entertainment_service_id → device_id → light_id`. Changed `computeSpatialPositions()` to accept pre-built `lightPositions: [String: (x: Double, z: Double)]` map instead of raw `EntertainmentConfig`.

#### Bug #2 — Mirror Toggle Did Nothing on Index Path
- **Root cause:** `phase(lightIndex:total:time:)` never read the `mirror` field. Only the spatial overload `phase(spatialPosition:time:)` applied `abs(position - 0.5) * 2.0`.
- **Fix:** Added `if mirror { position = abs(p - 0.5) * 2.0 }` to the index-based function.

#### Bug #3 — PCA Overrides User's 0° Angle
- **Root cause:** `motionAngle` defaulted to `0`. Orchestrator checked `== 0` to decide whether to auto-detect. But 0° (→ rightward) is a valid user choice.
- **Fix:** Changed default to `-1` (sentinel = "auto-detect"). Check changed to `< 0`. UI clamps display to `max(0, angle)`.

### Files changed
| File | Change |
|---|---|
| `CompositionEngine.swift` | `computeSpatialPositions` now takes `lightPositions` map, not `config` |
| `UnifiedOrchestrator.swift` | +`resolveEntertainmentLightPositions()` (~60 lines), PCA check `< 0` |
| `CompositionModels.swift` | `motionAngle` default `-1`, mirror in index `phase()` |
| `StudioView.swift` | `max(0, angle)` at 4 UI read points |

### Git state
- All work merged to `main` (commit `6c8eb87`)
- Feature branch `feature/harmony-spatial-engine` deleted locally, still on remote
- Safe revert point: `7db5c1e` (pre-harmony/spatial, settings cleanup only)

### Known performance issue (not yet fixed)
- **First tab switch takes ~4-5 seconds** after cold launch. Likely causes:
  1. `StudioView` is ~2800 lines — first SwiftUI build is expensive
  2. Synchronous `rebuildAllRooms()` / `rebuildAllZones()` on `@MainActor` blocks UI during large `@Observable` diffs
  3. `deactivateStuckEntertainmentSessions()` runs sequentially before data load
- **NOT caused by** `await` blocking the main thread (Swift concurrency yields on `await`)
- Needs Instruments profiling (Time Profiler + SwiftUI) to confirm bottleneck split

### What's next
- [ ] Performance optimization: move heavy work off `@MainActor`, investigate StudioView cold build cost
- [ ] Test harmony + spatial features on device with bridge
- [ ] Test entertainment area creation flow end-to-end

---

## 2026-05-07 — Spatial Motion Engine (Antigravity)

### What was changed

Upgraded the Composer Motion Layer from array-index-based patterns to physical spatial coordinates. Wave, Cascade, and Bounce patterns now sweep across lights based on their actual positions in the room, not their arbitrary discovery order.

#### Spatial Math (`CompositionEngine.swift`)
- Added `computeSpatialPositions(config:orderedLightIDs:motionAngle:)` — projects entertainment channel positions onto a 2D direction vector via dot product, returns positions ordered to match REST lightIDs (fixes ordering mismatch between entertainment channels and REST resolution order).
- Added `computeSpatialPositionsForEntertainment(channels:motionAngle:)` — same math but returns in channel order for DTLS transport.
- Added `principalAngle(channels:)` — PCA via 2×2 covariance matrix eigenvector to auto-detect the axis of maximum light spread. Used as default `motionAngle` when user hasn't set one.
- Added lerp system (`targetSpatialPositions` + `spatialLerpProgress`) for smooth 0.3s transitions when angle changes.
- Render loop updated: uses spatial `phase()` when positions available, falls back to index for scatter pattern (which needs pseudo-random seeding by index).

#### Model (`CompositionModels.swift`)
- Added `motionAngle: Double = 0` to `MotionConfig` (migration-safe Codable default).
- Added `phase(spatialPosition:time:)` overload — same switch/case logic as index-based version, replaces `lightIndex/total` with pre-computed 0–1 position. Mirror support: `abs(spatialPosition - 0.5) * 2.0`.

#### Orchestrator Wiring (`UnifiedOrchestrator.swift`)
- Fetches entertainment config BEFORE transport decision — both REST and DTLS paths get spatial positions.
- Moved `resolveCompositionLightIDs` earlier to feed the REST-ordered position computation.
- Added `activeEntertainmentConfig: EntertainmentConfig?` (public, @Observable) — exposed for Studio UI mini-map and direction dial.
- Auto-detects principal angle on first launch.
- Clears `activeEntertainmentConfig` on composition stop.

#### Direction UI (`StudioView.swift`, ~280 lines)
- **Direction presets**: 8 arrow chips (→ ↗ ↑ ↖ ← ↙ ↓ ↘), amber-highlighted when selected.
- **Angle dial**: 80pt glassmorphic circle with drag-to-rotate, amber indicator line, 5° snap, haptic ticks at 45° boundaries.
- **Spatial mini-map**: 80pt rounded rect showing light dots at physical (x,z) positions with palette-derived colors + dashed amber direction arrow.
- **Entertainment area prompt**: When no entertainment config exists, shows a styled button that opens `EntertainmentConfigBuilderView` as a sheet. On creation, spatial positions are computed immediately.
- **recomputeSpatialPositions()**: Called from Binding setters (NOT onChange — CompositionParamBox is not @Observable). Triggers smooth lerp + REST burst.
- **Mirror toggle** added to motion controls.
- Direction UI hidden for scatter pattern (non-directional).

### Bugs prevented by audit (6 found before implementation)

| # | Bug | Prevention |
|---|---|---|
| 1 | Scatter breaks with spatial positions (becomes smooth wave) | Render loop skips spatial for `.scatter` |
| 2 | `onChange` on motionAngle never fires | Use Binding setters, not onChange |
| 3 | Entertainment config only fetched on DTLS path | Fetch before transport decision |
| 4 | REST light ordering mismatch (wrong position per light) | lightID→position lookup map |
| 5 | "L → R" direction labels misleading | Arrow symbols + mini-map |
| 6 | Static pattern excluded from dial | Show for all except scatter |

### Files changed
| File | Change |
|---|---|
| `HueHome/Core/Models/CompositionModels.swift` | +`motionAngle`, +spatial `phase()` overload |
| `HueHome/UI/Studio/CompositionEngine.swift` | +spatial fields on ParamBox, +4 static helpers, +lerp in render loop |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | +`activeEntertainmentConfig`, spatial wiring, moved lightID resolution |
| `HueHome/UI/Studio/StudioView.swift` | +direction presets, +angle dial, +mini-map, +entertainment prompt |
| `HueHome/UI/Studio/StudioViewModel.swift` | Cleanup (moved property to orchestrator) |

### What's next
- [ ] Test spatial sweep in simulator with multi-light entertainment area
- [ ] Consider expanding to 3D direction (include Y/height axis)
- [ ] Auto-suggest optimal direction based on pattern + light layout

---

## 2026-05-07 — Harmony Engine → Studio Composer (Antigravity)

### What was changed

Integrated the existing `HarmonyEngine` (from SceneBuilder) into the Studio Composer Palette tab. Users can select a harmony rule (Analogous, Triadic, Complementary, Split Complementary, Monochromatic) and drag the 2D hue/saturation pad to generate mathematically harmonious 3-color palettes in real-time.

#### Features
- **Conditional harmony UI**: Chips only appear in `.solid` or `.gradient` modes and only when the current room/zone contains at least one color-capable bulb.
- **Mode awareness**: Auto-clears `activeHarmonyRule` when switching to non-color modes (Spectrum/Temp).
- **Swatch editing**: Tappable preview row → ColorWheelView popover for fine-tuning individual harmony colors.
- **Persistence**: `harmonyRule: String?` on `PaletteConfig` (migration-safe optional).
- **User guidance**: Contextual hint ("Try Cascade or Wave…") when harmony is selected with static motion.

### Files changed
| File | Change |
|---|---|
| `HueHome/UI/Components/HueColorUtils.swift` | +`codableColor(from:gamut:)` helper |
| `HueHome/Core/Models/CompositionModels.swift` | +`harmonyRule: String?` to `PaletteConfig` |
| `HueHome/UI/Studio/StudioViewModel.swift` | +`roomHasColorLights`, +`restoredHarmonyRule` |
| `HueHome/UI/Studio/StudioView.swift` | +chip row, +swatch preview, +editing popover, +harmony-aware drag |

---

## 2026-05-07 — Settings Consolidation + Navigation Cleanup (Antigravity)

### What was changed

#### Settings is now exclusively in More
- Removed the gear (⚙) toolbar button and its associated `showSettings` sheet from **5 tabs**: Dashboard, Studio, Scenes, Effects, Sync.
- Settings is now accessed from **More → Settings** only — consistent with the iOS Settings app convention.
- `MoreView` is the single owner of `showSettings` state. No other tab manages it.

#### Duplicate content removed from SettingsView
- Removed the `exploreSection` (Automations + Devices navigation links) from `SettingsView`.
- These already exist in `MoreView`'s CONTROL section linking to the same destination views (`AutomationsView`, `DevicesView`). Having them in both places caused confusion.
- **Settings now contains:** Bridges, All Day Scenes, Account (API Token), Developer (Demo Mode + Clean Bridge), App info.
- **More now contains:** Automations, Devices & Firmware, Accessories, Profiles & Access, Share Invite, Bridge Manager, Connection status, Settings (link), Demo Mode, App version.

#### SyncModeView toolbar cleanup
- The `toolbarItems` `@ToolbarContentBuilder` was left empty after removing the gear button. Removed the property and the `.toolbar { toolbarItems }` call entirely rather than leaving a dead no-op.

### Files changed
| File | Change |
|---|---|
| `HueHome/UI/Dashboard/DashboardView.swift` | Removed `showSettings` state, `.fullScreenCover`, gear `ToolbarItem` |
| `HueHome/UI/Studio/StudioView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` |
| `HueHome/UI/Scenes/ScenesTabView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` |
| `HueHome/UI/Effects/EffectsView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` (bookmark + stop toolbar items untouched) |
| `HueHome/UI/Sync/SyncModeView.swift` | Removed `showSettings` state, `.sheet`, entire `toolbarItems` property + `.toolbar` call |
| `HueHome/UI/Settings/SettingsView.swift` | Removed `exploreSection` property and its call in body |

### What's working
- Settings is reachable from one place (More tab) — no more gear icon on every tab
- No duplicate Automations/Devices entries between More and Settings
- Sync tab toolbar is clean (no leftover empty builder)

### What's next
- [ ] Harmony engine integration into Studio card color pickers (hue strip + rule chip row)
- [ ] "Run on Bridge" opt-in button in mixer tray for `runtimeOnly` presets
- [ ] Manual "Clean Bridge" button already in Settings/Developer — needs soak test

---

## 2026-05-07 — Bridge Animation Fixes + Composer Dynamic Effects Restored (Antigravity)

### Problems fixed (4 bugs, 1 session)

#### 1. Schedule creation failing — error type 6 `"parameter, autoDelete, not available"`
- `HueV1Client.createRecurringSchedule()` was sending `"autodelete": autoDelete` in the POST body.
- Bridge firmware rejects this key with error type 6. Removed it — omitting defaults to `false` (schedule persists).

#### 2. Schedule command using wrong address format
- `sensorIncrementCommand()` returns a **relative** path (`/sensors/{id}/state`), correct for **rule actions**.
- Schedule `command.address` must be the **full** path `/api/{token}/sensors/{id}/state` — the bridge does NOT append user context for schedule commands (unlike rule actions).
- **Fix:** Added `sensorIncrementScheduleCommand()` that builds the full path; swapped the call site in `BridgeAnimationEngine`.

#### 3. Composer cards not turning lights on after bridge upload
- Bridge upload succeeded (rules, sensor, schedule created), but the first rule only fires when the schedule next ticks (~3–18s away). Lights stayed dark after card tap.
- **Fix:** Added an **immediate prime frame** after `bridgeAnimationStore.save(manifest)` — renders step 0 of the composition and pushes it via `setGroupedLightEffect(on: true)` so the room lights up within ~1s of the tap.

#### 4. Dynamic composer cards (cascade/wave/breathe) frozen — REST scheduler suppressed
- `canRunOnBridge` was `true` for ALL non-mic presets, so every composition went through bridge upload.
- Bridge upload returned early without starting the REST scheduler.
- Bridge rule chains have a **3-second minimum step interval** (bridge firmware limit), making cascade/wave/breathe presets look completely frozen.
- **Fix:** Gated bridge upload on `preset.capabilityTier == .bridgeOptimized` only. Dynamic presets fall through to REST/Entertainment as before.

### Files changed
| File | Change |
|---|---|
| `HueHome/Core/Network/HueV1Client.swift` | Removed `autodelete` from schedule body; added `sensorIncrementScheduleCommand()` with full address |
| `HueHome/Core/Network/BridgeAnimationEngine.swift` | Swapped `sensorIncrementCommand` → `sensorIncrementScheduleCommand` for schedule |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | Added prime frame after bridge upload; gated bridge path on `.bridgeOptimized` tier |

### Architecture: bridge transport tiers
```
bridgeOptimized  (static motion + steady envelope)
  → Bridge upload automatically: lights persist after app close, prime frame turns on immediately

runtimeOnly  (any motion or non-steady envelope — cascade/wave/breathe/etc.)
  → REST/Entertainment: continuous 120ms updates, smooth animation
  → Bridge: NOT auto-uploaded (3s/step would freeze the effect)

hybrid  (mic-reactive)
  → REST/Entertainment only (bridge has no mic)
```

### What's working
- ✅ Schedule creates successfully (no more type 6 errors)
- ✅ `bridgeOptimized` presets upload, persist after app close, turn on immediately
- ✅ `runtimeOnly` compositions produce smooth continuous animation via REST

### What's next
- [ ] "Run on Bridge ⚡" explicit opt-in button in mixer tray for `runtimeOnly` presets
- [ ] Manual "Clean Bridge" button in Settings
- [ ] On-device soak test: bridgeOptimized preset, close app, verify lights keep cycling

---

## 2026-05-06 — Home Layout Rebuild + All Day Scenes (Cursor)

### What was built
- **Home rebuild (`DashboardView.swift`)** — Threw out the per-section ad-hoc padding model entirely and rebuilt Home with the canonical SwiftUI dashboard pattern. The visual design is **identical** — every section component (TimeSuggestionBanner, NextAutomationBanner, presetsBar, RoomCard, summaryHeader, zonesSectionHeader, nowPlayingBar) is unchanged. Only the wrapper layout was rewritten.
- **New body shape**:
  - Root: `ScrollView` (no ZStack, no GeometryReader, no custom layout profile).
  - Content: a single `VStack(alignment: .leading, spacing: 14)` containing every section in order.
  - Horizontal inset: `.padding(.horizontal, 20)` applied **once** at the ScrollView's content. Sections never set their own horizontal padding.
  - Background: `DashboardAmbientBackground.ignoresSafeArea()` lives on the `.background { ... }` modifier, not as a ZStack sibling. This decouples its safe-area behavior from content sizing.
  - Toast: `.overlay(alignment: .top)` for the orchestrator toast and `.overlay(alignment: .bottom)` for the preset toast.
  - Grid: `[GridItem(.adaptive(minimum: 170))]` — auto-balances to 1 column on iPhone SE (335pt content < 2*170+spacing) and 2+ columns on every larger device with no breakpoint logic. The `useWideCards` AppStorage flag forces 1-column when desired.
- **Presets row bleed** — `.padding(.horizontal, -20)` then `.padding(.leading, 20)` so the first chip aligns with the rail and the trailing chips scroll under the screen edge (Apple Music / App Store pattern).
- **Removed dead code** — `HomeLayoutProfile` struct, `homeLayout` computed property, `homeContentRail` wrapper, `roomScrollView`, `roomsGrid`, `zonesGrid`, the unused `sizeClass` and `dynamicTypeSize` environment reads, and the debug HUD in `MainTabView`.
- **All Day Scenes (Circadian Auto-Pilot)** — One-time location permission, local solar curve (sunrise/sunset), throttled grouped_light updates via `allDayRestSender`, persisted via `UserDefaults`. Settings UI in `AllDayScenesView` (toggle, set/refresh location, anchor summary).

### Functionality preserved (no regressions)
- ✅ Ambient time-of-day gradient background
- ✅ Greeting, on/off counter, status dot
- ✅ Time-aware suggestion banner with one-tap CTA
- ✅ Next-automation banner with countdown chip + multi-automation sheet
- ✅ Horizontal preset rail (Energize/Read/Relax/Sleep + favorited room scenes)
- ✅ Now-playing strip with multi-effect dropdown and "Stop"/"Stop All"
- ✅ Room cards: glow color, brightness slider, power toggle, ellipsis, scale animations, equatable diffing, SSE-driven optimistic state
- ✅ Collapsible Zones section, persisted via @AppStorage
- ✅ Pull-to-refresh, NavigationLink to RoomDetail, simultaneousGesture for SSE suppression
- ✅ Toast notifications, demo-mode title decoration
- ✅ Toolbar items (settings, power-all, layout toggle)
- ✅ Empty state and shimmer state

### What's working
- ✅ Linter clean (`DashboardView`, `MainTabView`).
- ✅ All Day Scenes feature compiles, persists state, and respects the latest-wins `RestSender` mailbox.

### What's left
- [x] User QA pass on iPhone SE (3rd gen) portrait completed via screenshot validation.
- [ ] User QA pass on iPhone mini / standard / Max + iPad (screenshot matrix).
- [ ] AI Scene Generation (next differentiator after Home QA).

### Gotchas
- `.adaptive(minimum:)` is the responsive grid contract — do not replace with custom screen-width math.
- The presets row bleed uses `.padding(.horizontal, -20)` followed by `.padding(.leading, 20)` — both modifiers are required; removing either breaks leading alignment or collapses the bleed.
- The ambient background MUST be applied via `.background { … }` modifier (not a ZStack sibling). A sibling with `.ignoresSafeArea()` propagates safe-area behavior to siblings via the ZStack's coordinate space, which is what caused the original SE clipping.
- Sections that produce intrinsic-width content (e.g. a plain `Text`) will leave whitespace on the right inside the leading-aligned VStack. Every section in `content` either uses HStack+Spacer or a LazyVGrid, both of which fill the proposed width.

### Current state
SE portrait validation is complete and looks correct. Home layout rebuild is stable; remaining step is cross-device matrix validation (13/14, Pro Max, iPad) before tagging a checkpoint.

---

## 2026-05-05 — Composer Engine Built (Antigravity/Gemini)

### What was built
- `CompositionModels.swift` — 4 layer configs (Palette, Motion, Envelope, Reaction) with full render math
- `CompositionEngine.swift` — Pure render engine, outputs CIE xy + brightness per light per frame
- `CompositionStore.swift` — JSON persistence + 20 built-in presets (5 ambient, 3 energetic, 12 holidays)
- `StudioViewModel.swift` — Added `.composition(presetID:)` strategy, `composerStudioCards`, apply/stop
- `UnifiedOrchestrator.swift` — Added `startCompositionMode()` with dual-transport (DTLS 25fps / REST 5fps)

### What's working
- ✅ All engine code compiles (BUILD SUCCEEDED)
- ✅ Existing Studio effects (Deck 1+2) unchanged and functional
- ✅ Multi-room concurrent effects still working
- ✅ 20 presets seed on first launch via JSON

### What's left (for next session)
- [ ] Phase 3A: Add Deck 3 to StudioView card carousel
- [ ] Phase 3B: Mixer tray layer tabs for compositions
- [ ] Phase 3C: Layer-specific slider controls
- [ ] Phase 3D: Save flow (name input → persist → new card)
- [ ] Phase 4: Polish (animations, haptics, seasonal banner)

### Gotchas
- `StudioStrategy` now requires `Equatable` conformance (added)
- `composerStudioCards` is a computed property, not a stored let (updates when store changes)
- Slider values write directly to `activeCompositionBox` — no debounce or API call needed
- The `sendColorParam` method searches `composerStudioCards` array too (line ~483)

### Current tag
`v0.17.0-cursor-ready`

---

## 2026-05-05 — Composer Phase 3A: Deck 3 UI (Cursor)

### What was built
- **`StudioView.swift`** — Third carousel page (Composer): category chips (`PresetCategory.allCases`), animated gradient-border **+ Create** hero, filtered preset grid with same `StudioCardView` as other decks, three deck dots, rename alert. Long-press context menu: Edit, Rename, Duplicate, Delete. In-season presets sort to the top; Holiday chip gets extra border emphasis when any preset `isInSeason`.
- **`StudioViewModel.swift`** — Hidden starter template preset (`composerStarterDraftPresetID`) excluded from grid; `applyStarterComposition()`, `ensureComposerStarterDraft()`, `studioCard(for:)`, `composerPresets(for:)`, `renameCompositionPreset`, `duplicateCompositionPreset`, `deleteCompositionPreset`; `sendParam` lookup includes starter card.

### What's working
- ✅ `xcodebuild` generic iOS **BUILD SUCCEEDED**

### What's left
- [ ] Phase 3B: Mixer layer tabs for compositions
- [ ] Phase 3C: Layer sliders
- [ ] Phase 3D: Save sheet

### Gotchas
- Starter draft is persisted on first **+ Create** (not one of the 20 built-ins). Grid omits it by ID so it never appears as a card.
- `+ Create` title includes a leading “+” and a `plus.circle.fill` icon (slight redundancy).

### Current state
Phase 3A complete; ready for 3B.

---

## 2026-05-05 — Composer Routing + Queue Race Fixes (Cursor)

### What was built
- **`UnifiedOrchestrator.swift`** — Composer entertainment selection now matches room light refs to config lights (no blind `.first` config). Added Studio generation counter + `studioRestSender.clear()` on start/stop, and generation guards in Composer REST loop/enqueued closures to block stale delayed sends after stop/switch.
- **`SyncModeEngine.swift`** — `RestSender` gained `clear()` to drop pending mailbox work safely.
- **`StudioViewModel.swift`** — Added single-engine guard for `.appDriven`/`.composition` cards (stop other engine-based room effects before starting a new one). Added `apply(_:roomOverride:)` so the tapped room snapshot is used.
- **`StudioView.swift`** — Card taps now capture room snapshot and pass override into `apply`, removing selection race. Mixer header now shows explicit scope/transport badges (`ENT AREA`, `ROOM`, `COMPOSER: ...`).

### What's working
- ✅ `xcodebuild` generic iOS **BUILD SUCCEEDED** after each fix batch
- ✅ Room-target logs match user taps (`Hallway → Kitchen → Hallway → Main bedroom`)
- ✅ No delayed ghost re-activation observed after stop in retest

### What's left
- [ ] Phase 3B: Mixer layer tabs for compositions
- [ ] Phase 3C: Layer sliders
- [ ] Phase 3D: Save sheet
- [ ] Built-in preset UX: hide/unhide instead of delete

### Gotchas
- Studio engine in orchestrator is singleton (`activeStudioTask`); UI must enforce this to avoid conflicting room expectations.
- Room-selection race can occur if swipe/pick changes around tap time; using room snapshot at tap eliminates this.
- REST mailbox can still have one in-flight request; generation guards are required so stale closures no-op after stop.

### Current state
Composer room routing and delayed-send race appear stable in manual tests. Ready for Phase 3B implementation.

---

## 2026-05-05 — Composer REST backlog fix (Cursor)

### What was wrong
- `runCompositionREST` sent grouped_light PUTs every **200 ms (~5 Hz)**.
- `HueAPIClient` documents grouped_light at **~1 PUT/sec** — excess traffic queues on the bridge → **30–60 s lag** as stale commands drain.

### Fix
- Throttle Composer REST loop to **~1 Hz** (1.05 s spacing), dynamics ≈ **900 ms**. Logs/docs updated from “~5fps”.

### Current state
**BUILD SUCCEEDED**. Entertainment path unchanged (25 fps).

---

## 2026-05-05 — Composer Mixer UI (3B/3C) + Save (3D), Multi-room Notes (Cursor)

### What was built
- **`StudioView.swift`** — For `.composition` cards: mixer shows four layer tabs (Palette / Motion / Envelope / Reaction), tabbed controls bound directly to `vm.activeCompositionBox` (live sliders, pickers, toggles). Increased composer mixer tray height. Header save button (`square.and.arrow.down`) opens save sheet (name + SF Symbol grid).
- **`StudioViewModel.swift`** — `saveActiveComposition(name:icon:)` builds a `CompositionPreset` from `activeCompositionBox` and `compositionStore.save` (category `.myCreations`).

### Product / architecture notes (current behavior)
- **Multi-room:** Bridge-native effects (Deck 1) can still run in multiple rooms. **Composer and other `.appDriven` Studio engines are intentionally single-active globally** — applying in room B stops Composer/Live in room A (see earlier `StudioViewModel` guard). Matches one orchestrator Studio task + one Entertainment session per bridge.
- **Composer REST:** After grouped_light throttle fix, room-scoped REST Composer updates ~**1×/second**; smooth motion requires Entertainment path when config matches.

### What's left
- [ ] Phase 4 polish: tab cross-fade refinement, stronger haptics, seasonal banner, optional per-light REST path for smoother Composer without Entertainment

### Current state
Phase 3B–D composer mixer + save shipped in tree; verify on device with Entertainment vs REST badges.

---

<!-- NEXT SESSION: Append below this line -->

## 2026-05-06 — SE Portrait Layout Spike (Cursor)

### What was built
- Investigated compact-device clipping reports using iPhone SE (3rd gen) simulator screenshots across Home / Scenes / Studio.
- Ran multiple adaptive layout experiments on Home and tab-shell sizing (`DashboardView`, `MainTabView`, `HueHomeApp`) to test whether width clamping originated from section padding, grid strategy, or root container sizing.
- Reverted non-improving runtime layout experiments after validation so no unstable SE workaround remains in shipped UI code.
- Added roadmap context in `DEVDOC.md` for post-Composer differentiators (AI scene generation first, then sharing, weather-reactive, and Tier 2 items).

### What's working
- ✅ Build passes after cleanup (`xcodebuild` BUILD SUCCEEDED).
- ✅ Studio still renders cleanly on SE (useful baseline for Home refactor target).
- ✅ Existing Composer 3B/3C/3D + routing/queue fixes remain intact.

### What's left
- [ ] Refactor Home layout architecture to match Studio's deterministic container model.
- [ ] Introduce one Home content rail + breakpoint profile (compact/standard/large) instead of per-section ad-hoc sizing.
- [ ] Validate SE portrait first, then iPhone standard/Max and iPad, with screenshot matrix before release.

### Gotchas
- SE issue appears architectural (root/intrinsic width interactions across mixed sections), not a simple padding tweak.
- Landscape can look acceptable while compact portrait fails, so portrait-on-small-device must be the primary acceptance gate.

### Current state
SE portrait Home still needs a structural refactor; experimental quick fixes were rolled back. Next step is a focused Home layout-system pass while preserving current visual style.

---

## 2026-05-06 — AI Scene Generation Architecture Artifact + UX Decisions (Cursor)

### What was built
- Created a new canvas artifact at `canvases/ai-scene-gen-and-composer-revamp.canvas.tsx` describing:
  - AI Scene Generation architecture (`prompt -> provider -> validate -> CompositionPreset -> Composer engine -> lights`)
  - Provider strategy (FoundationModels-first, optional cloud fallback, local curated fallback)
  - Data contract constraints for generated `CompositionPreset` values
  - Progressive disclosure rules for Composer tools (essential vs advanced controls)
  - Visual flow mockups for top bar, AI generation states, and 2-axis hue control concept
- Iteratively rewrote the artifact to incorporate product decisions from live review feedback.

### Product/UX decisions captured
- Keep **room picker** as the primary navigation anchor in Studio (explicitly prioritized).
- Remove top deck-name labels if there is a conflict with room-picker clarity.
- Keep AI entry as a **pill**.
- Keep visible **AI badge** on generated cards.
- Default AI apply scope = **current room**.
- Regenerate flow clarified with simple UX framing (live regenerate + card-level regenerate).

### Follow-up decision (latest)
- User requested to **keep room picker exactly as-is** for now (no immediate room-picker redesign implementation).

### What's left
- [ ] Choose first implementation slice (recommended: AI pill shell + state handling, or HueRail prototype behind flag).
- [ ] Convert selected parts of artifact into concrete StudioView/StudioViewModel tickets.

### Current state
Architecture and UX artifact is complete and updated with current decisions. No production Studio code changes were applied in this session.

---

## 2026-05-06 — Documentation Refresh (Cursor)

### What was built
- Updated `CURSOR_KICKOFF.md` from a Composer build-instruction doc to a current-state kickoff.
- Reframed kickoff around what is already shipped vs what remains (polish, QA, transport/stability checks).
- Updated `COMPOSER_SPEC.md` with a top-level implementation status section and historical-plan clarifications.
- Corrected stale strategy references in `COMPOSER_SPEC.md` from `composition(preset:)` to `composition(presetID:)`.

### What's working
- ✅ Session onboarding docs now align with current implementation state.
- ✅ Future sessions can start from active priorities instead of already-completed phases.

### What's left
- [ ] Run cross-device screenshot QA matrix and record outcomes.
- [ ] Complete remaining Composer polish items (transitions, haptics, seasonal affordances).
- [ ] Begin first AI Scene Generation implementation slice once UI QA is green.

### Gotchas
- Large planning docs can quickly become stale after rapid implementation phases; add explicit status headers to prevent accidental rework.

### Current state
Documentation is now synchronized for current v0.17.x direction; no runtime code paths changed in this session.

---

## 2026-05-06 — DEVDOC Consistency Pass (Cursor)

### What was built
- Updated `DEVDOC.md` Composer section to include a 2026-05-06 status note clarifying it is mostly implemented and now serves as architecture reference.
- Corrected stale strategy notation in `DEVDOC.md` from `StudioStrategy.composition(preset:)` to `StudioStrategy.composition(presetID:)`.
- Updated the roadmap block in `DEVDOC.md` to mark Composer core as done and set `v0.17.x` focus to polish + QA + transport UX hardening.

### What's working
- ✅ `DEVDOC.md`, `CURSOR_KICKOFF.md`, and `COMPOSER_SPEC.md` now align on Composer status.

### What's left
- [ ] Cross-device screenshot matrix pass (Home + Studio Deck 3).
- [ ] Remaining Composer polish items and transport UX validation.

### Gotchas
- Historical design sections are still useful but need explicit status annotations to prevent duplicate implementation work.

### Current state
Primary documentation is synchronized with current implementation state; no production code changes in this pass.

---

## 2026-05-06 — Composer AI Pill + Prompt Generation v1 (Cursor)

### What was built
- Updated `StudioView.swift` Composer `+ Create` hero to support inline AI mode:
  - Added a small `wand.and.stars` affordance on the create pill.
  - Tapping AI expands the same pill into prompt input with `Generate` and `Cancel`.
  - Added inline loading state and error messaging beneath the hero.
- Added AI generation pipeline in `StudioViewModel.swift`:
  - Introduced a local-first `AICompositionGenerator` abstraction (`AICompositionDraft` + error type).
  - Added `generateCompositionFromPrompt(_:)` with input trimming, prompt-length validation, generation lock, and user-facing error/status messages.
  - Generated outputs map directly to valid `CompositionPreset` objects and save into `CompositionStore` as `.myCreations`.
- On successful generation, Studio now auto-applies the generated preset to the captured room snapshot and opens live mixer flow.

### What's working
- ✅ `xcodebuild` generic iOS build succeeds after changes.
- ✅ AI flow uses the same creation surface (no modal detour) and keeps one-tap Composer mental model intact.
- ✅ Guardrails in place for empty prompts, duplicate taps while generating, and recoverable generation failures.

### What's left
- [ ] Swap local heuristic generator to FoundationModels-backed provider behind the same abstraction.
- [ ] Add persisted AI badge metadata for generated presets (model field + migration-safe decode path).
- [ ] Tune prompt UX copy and optional suggested prompt chips.

### Gotchas
- Nested button interactions in the create hero can cause accidental trigger overlap; implementation avoids this by separating create and AI actions into explicit independent buttons.
- Generation is currently deterministic/local by design to keep UX stable while backend provider is integrated.

### Current state
AI entry is now integrated into Deck 3 creation pill and is production-safe for local generation. Foundation model provider wiring is the next implementation slice.

---

## 2026-05-06 — Composer Polish: Layer Activity + Seasonal Banner (Cursor)

### What was built
- Added Composer layer-activity metadata to `StudioCard` via new `compositionLayerActivity` payload.
- Implemented preset-derived layer activity detection in `StudioViewModel` to flag active/customized layers (`palette`, `motion`, `envelope`, `reaction`).
- Updated `StudioCardView` to render compact layer chips (`🎨 🌊 📈 🎤`) with active vs inactive styling for Composer cards.
- Added a lightweight seasonal banner in Deck 3 when seasonal presets are currently active.
- Refined composition tab content transition with a subtle fade+scale identity swap for cleaner layer switching feel.

### What's working
- ✅ Build succeeds after polish updates.
- ✅ Composer cards now show at-a-glance layer activity affordance.
- ✅ Seasonal context appears without changing existing deck flow.

### What's left
- [ ] FoundationModels provider integration behind current AI generator abstraction.
- [ ] Cross-device screenshot matrix validation for Home + Studio Deck 3.
- [ ] Final transport UX hardening checks for ENT vs REST labels/behavior.

### Gotchas
- Adding fields to `StudioCard` required updating every catalog card constructor to keep init sites compiling.

### Current state
Composer polish advanced with visual layer activity cues and seasonal deck affordance; compile status remains green.

---

## 2026-05-06 — AI Provider + Preset Metadata Migration (Cursor)

### What was built
- Updated `CompositionPreset` in `CompositionModels.swift` with migration-safe AI metadata:
  - Added optional `aiPrompt` and `providerModel`.
  - Implemented custom `init(from:)` to decode both fields with graceful `nil` fallback for legacy JSON.
  - Implemented explicit `encode(to:)` for forward-compatible persistence.
- Replaced local heuristic generation path in `StudioViewModel.swift` with FoundationModels-backed generation:
  - Added `LanguageModelSession` request path (guarded by `canImport(FoundationModels)` and availability).
  - Added JSON extraction + decode pipeline for structured model output.
  - Added validation clamp step for all returned numeric fields (palette/motion/envelope/reaction ranges).
- Added AI-card visual affordance in `StudioCardView` (inside `StudioView.swift`):
  - Shows compact `wand.and.stars` badge for AI-generated composition cards.
  - Badge sits alongside layer activity chips and remains compact-layout safe.

### What's working
- ✅ Generic iOS build succeeds after provider integration and metadata migration.
- ✅ Existing composition JSON remains readable due decoder fallback behavior.
- ✅ New AI-generated presets persist prompt/model metadata and show AI badge.

### What's left
- [ ] Cross-device QA snapshot pass (SE/mini/standard/Max/iPad) for badge/chip density.
- [ ] Optional: transition from text-JSON parsing to strict guided structured output (`@Generable`) for stronger model guarantees.

### Gotchas
- FoundationModels can be unavailable per-device/runtime; generator now fails gracefully with clear user-facing message.

### Current state
AI generation now uses FoundationModels with clamp validation, and preset metadata is migration-safe for older saved compositions.

---

## 2026-05-06 — Composer UX Stabilization + Gamut-Aware Color Pipeline (Cursor)

### What was built
- Hardened AI generation reliability in `StudioViewModel.swift`:
  - Added markdown-fence sanitization before JSON decoding.
  - Added detailed decode failure logging (raw JSON candidate + decode error details).
  - Added tolerant decode path for variant provider payloads (including missing palette fields / `colors` array fallback mapping).
  - Added local fallback draft generator when FoundationModels fails/unavailable (notably simulator/runtime generation failures).
- Replaced fragmented Palette controls with a unified 2D Hue/Saturation pad in `StudioView.swift`:
  - Removed separate hue slider, saturation slider, and color-dot row.
  - Added 2D drag pad with thumb, clamp-safe drag math, and compact-layout-safe sizing.
  - Added live thumb tracking while dragging to eliminate perceived input lag.
- Improved Composer mixer tray interactions/lifecycle:
  - Added tap-outside dismissal overlay.
  - Added swipe-down-to-dismiss for inline mixer with threshold/predicted-end handling.
  - Added header drag-indicator tap dismiss.
  - Added keyboard dismissal utility (`hideKeyboard()`) and applied it to relevant tap backgrounds.
  - Re-anchored tray as a bottom overlay to reduce lock/unlock geometry glitches.
- Fixed hue pad visual consistency:
  - Corrected saturation axis orientation.
  - Added selected-color thumb fill + color preview dot to better reflect selected values.
  - Lifted tray above tab bar to avoid lower-edge clipping on compact devices.
- Implemented gamut-aware color accuracy improvements (Step 1 + 2):
  - Added Hue gamut triangles (A/B/C) and `clampXYToGamut` in `HueColorUtils.swift`.
  - Added room-dominant gamut resolution in `StudioViewModel` and `UnifiedOrchestrator`.
  - Clamped Composer color output to resolved gamut in both Entertainment and REST render paths.
  - Refactored hue pad to canonical clamp-first flow so displayed thumb/readout track post-clamp output (not pre-clamp gesture values).
- Tuned REST fallback responsiveness during color scrubbing:
  - Added interaction-aware cadence in `runCompositionREST`:
    - drag: faster interval + shorter transition
    - idle: conservative interval + smoother transition
  - Added post-drag settle write for cleaner final color landing.

### What's working
- ✅ AI generation succeeds more consistently across phone + simulator with graceful fallback path.
- ✅ 2D hue pad interaction is smoother (live tracking, clamp-safe drag, consistent thumb/readout).
- ✅ Mixer dismissal is easier and more native-feeling (tap-outside, swipe-down, header tap).
- ✅ Composer color output is now gamut-clamped end-to-end, reducing unreachable-color mismatch.
- ✅ Build and lint checks passed after each major slice.

### What's left
- [ ] Optional follow-up: switch Composer pad to full xy-native editing surface for even tighter perceptual parity.
- [ ] Optional follow-up: tune drag REST profile further (e.g., 0.7s/140ms) based on bridge/device QA.
- [ ] Product decision pending: enforce portrait-only orientation to avoid landscape UI regressions.

### Gotchas
- Hue bridge grouped_light path remains rate-limited; REST fallback will never feel as fluid as Entertainment streaming.
- Mixed-gamut rooms still require compromise mapping; dominant-gamut strategy is a practical middle ground.

### Current state
Composer UX is significantly more stable and color handling is now gamut-aware from picker input through transport output, with improved simulator resilience for AI generation.

---

## 2026-05-06 — Composer Multi-Room Runtime + Scheduler Tuning (Cursor)

### What was built
- Implemented non-destructive mixer dismissal in `StudioView.swift`:
  - Dismiss gestures (tap outside / swipe down / header tap) now collapse controls instead of stopping the running composition.
  - Added `Live Controls` quick chip to reopen the mixer while effect continues.
- Enabled multi-room concurrent compositions:
  - Refactored Composer orchestration from single global task semantics to room-scoped runtime state in `UnifiedOrchestrator`.
  - Updated `StudioViewModel` apply/stop logic so composition no longer force-stops other composition rooms.
- Replaced per-room composition REST loops with a global fair scheduler:
  - Added round-robin scheduler over active composition rooms to prevent one room from monopolizing bridge updates.
  - Added room-scoped start/stop generation guards and lifecycle cleanup.
- Added debug telemetry for Composer scheduler:
  - Per-room effective send rate (`hz`), average lag (`avgLagMs`), max lag (`maxLagMs`) logged in DEBUG builds.
- Improved startup responsiveness and pacing:
  - Added immediate prime write when a composition starts so newly selected rooms visibly turn on immediately.
  - Reduced smoothing/transition durations for faster visual response.
  - Passed pre-resolved gamut from `StudioViewModel` into `startCompositionMode` to avoid redundant fetch overhead at start.

### What's working
- ✅ Composition cards can now run concurrently across multiple rooms (REST path).
- ✅ Mixer can be hidden/reopened without canceling live composition playback.
- ✅ Scheduler fairness improved vs independent per-room loops.
- ✅ New composition start feels more immediate due to prime write.
- ✅ Build and lint checks passed after each slice.

### What's left
- [ ] Final scheduler calibration from fresh telemetry after latest transition/tick tuning.
- [ ] Decide whether to introduce "Bridge Optimized" vs "Custom Live Engine" mode badges.
- [ ] Optional: portrait-only lock decision if landscape regression costs remain high.

### Gotchas
- Native Hue dynamic effects remain smoother because they execute in bridge firmware; Composer remains app-driven for custom behavior.
- Multi-room Composer on grouped_light is bounded by bridge rate limits; scheduling can optimize fairness but not fully bypass hardware limits.

### Current state
Composer now supports practical multi-room concurrency with fair scheduling, faster start behavior, and a cleaner non-destructive mixer UX, while preserving custom composition flexibility.

---

## 2026-05-06 — Composer Responsiveness Investigation + Final Tuning Pass (Cursor)

### What was built
- Ran iterative tuning on Composer runtime behavior with repeated full build verification.
- Added and used DEBUG scheduler telemetry (`hz`, `avgLagMs`, `maxLagMs`) to validate runtime pacing and fairness.
- Tuned composition transition durations and startup behavior:
  - Shorter live transitions for Composer REST writes.
  - Immediate prime write on composition start so newly activated rooms visibly respond right away.
- Optimized startup path:
  - Reused `StudioViewModel`-resolved gamut by passing a `gamutOverride` into `startCompositionMode(...)` to avoid redundant fetches during room activation.
- Refined scheduler pacing strategy:
  - Maintained round-robin fairness and interaction-aware behavior.
  - Reduced burst-like write behavior in follow-up tuning attempts.

### What was verified
- ✅ Full iOS build succeeds after all tuning passes.
- ✅ Multi-room composition concurrency remains functional.
- ✅ Startup responsiveness improved via prime write.
- ✅ Native dynamic effects remain noticeably smoother than Composer under equivalent conditions.

### Findings from logs/telemetry
- Composer can show low scheduler lag (`avgLagMs` near 0) while still feeling visually laggy.
- This indicates the main bottleneck is not app-side queue backlog, but grouped_light REST animation granularity/cadence limits vs bridge-native dynamic effects.
- Native dynamic effects feel smoother because they execute in bridge firmware after one-shot effect commands.
- Composer (custom 4-layer runtime) still requires continuous grouped_light updates in REST mode, which has a lower smoothness ceiling.

### What's left
- [ ] Decide/implement Bridge-optimized composition identifiers and tiers (bridgeOptimized/hybrid/runtimeOnly) for each preset.
- [ ] Add clear user-facing capability badge so saveability/smoothness expectations are explicit.
- [ ] Evaluate transport strategy for best smoothness:
  - prioritized active-room cadence,
  - adaptive per-room degradation,
  - optional bridge-optimized compile path where possible.

### Current state
Composer is materially improved and instrumented, but logs confirm that REST grouped_light remains the limiting factor for “native-like” smoothness; next milestone is capability-tiering and bridge-optimized pathways.

---

## 2026-05-06 — Composition Optimization Tier Metadata + UI Badge (Cursor)

### What was built
- Added composition optimization identifiers directly to preset metadata in `CompositionModels.swift`:
  - `optimizationTier: bridgeOptimized | hybrid | runtimeOnly`
  - `bridgeOptimizationFlags: [BridgeOptimizationFlag]`
  - `bridgeOptimizationReason` computed string for UI/debug visibility.
- Implemented migration-safe decoding for existing saved presets:
  - if new fields are missing, flags are inferred from layer configs and tier is auto-derived.
- Added tier/reason propagation into Studio cards in `StudioViewModel.swift`:
  - `StudioCard` now carries `compositionOptimizationTier` + `bridgeOptimizationReason` for Composer presets.
- Added compact Composer card badge UI in `StudioView.swift`:
  - Tier capsule (`Bridge Optimized`, `Hybrid`, `Runtime Only`)
  - concise reason hint sourced from optimization flags.

### What’s working
- ✅ Every composition preset now stores optimization metadata on the model.
- ✅ Existing stored JSON presets remain compatible via decode-time inference.
- ✅ Composer cards show a compact optimization tier badge.
- ✅ Reason flags are visible in a compact, user-facing hint line.

### What’s left
- [ ] Optional: tune inference heuristics per preset family if product wants stricter tier semantics.
- [ ] Optional: surface full reason list in detail UI (e.g., context menu/details sheet) instead of compact hint truncation.

### Gotchas
- Existing presets in user storage did not contain new keys, so migration-safe defaults were required to avoid breaking decode.
- Tiering here is intentionally deterministic and model-based (layer config analysis), not runtime transport performance telemetry.

### Current state
Composer presets now have persisted bridge optimization identifiers and reason flags, and Studio displays a compact badge for immediate user clarity about bridge optimization capability level.

---

## 2026-05-06 — Composer Transport Hardening (Cursor)

### What was built
- Hardened Composer transport/scheduler behavior in `UnifiedOrchestrator`:
  - Added per-room due-time pacing using `nextDueAt` (instead of high-frequency global sleep clamp).
  - Set steady-state target to ~1Hz per room for grouped_light REST sends.
  - Added bounded interaction burst mode (short faster window) with automatic decay.
  - Added optional Entertainment-first path in `startCompositionMode(..., preferEntertainment:)` with REST fallback.
- Improved overlap safety in `StudioViewModel`:
  - Apply path now resolves room light IDs for composition/app-driven cards too.
  - Overlap detection now prevents competing effects across overlapping room/zone scopes beyond bridge-native-only cases.
- Added panic-stop affordance in `StudioView`:
  - New `stop.circle.fill` toolbar action appears while anything is running and calls `vm.stopAll()`.

### What’s working
- ✅ Full iOS build succeeds after transport hardening.
- ✅ Composer REST cadence is now significantly less burst-prone and closer to bridge limits.
- ✅ Quick slider interaction gets temporary responsiveness boost, then auto-returns to stable pacing.
- ✅ Overlapping room/zone runs are reduced by broader overlap checks.
- ✅ One-tap panic stop now available at top nav while effects are active.

### What’s left
- [ ] On-device validation pass for Entertainment-first composition route with multiple bridge layouts.
- [ ] Tune burst window/interval based on real bridge telemetry in live household scenarios.
- [ ] Optional: add explicit UI transport indicator per running composition room (REST vs Entertainment).

### Gotchas
- Entertainment API remains bridge-wide/single-session; composer entertainment preference must still gracefully fall back when unavailable.
- REST grouped_light smoothness remains bounded by bridge behavior even with improved scheduler pacing.

### Current state
Composer now uses a safer pacing model, broader overlap protection, bounded burst behavior, and optional entertainment-preferred transport, with a global panic-stop control for runaway room effects.

---

## 2026-05-06 — Composer Tier Guardrails + Runtime Hint (Cursor)

### What was built
- Added strict per-tier Composer REST cadence guardrails in `UnifiedOrchestrator`:
  - `CompositionRuntime` now tracks `tier`.
  - Scheduler enforces minimum interval by tier via `minIntervalForCompositionTier(_)`.
  - Current policy: `bridgeOptimized`, `hybrid`, and `runtimeOnly` all clamp to **>= 1.0s** per room/zone when on REST.
- Added debug clamp diagnostics:
  - When interaction burst requests faster updates than allowed, DEBUG builds log `[Composer][Guardrail] clamped cadence ...` with requested vs allowed interval.
- Wired tier into orchestrator start path:
  - `StudioViewModel` now passes `tier` into `startCompositionMode(..., tier:)` so cadence policy is centrally enforced.
- Added runtime-only expectation cue in mixer UI (`StudioView`):
  - For composition cards running on REST with `runtimeOnly` tier, mixer shows: `Runtime-only REST is rate-capped`.

### What’s working
- ✅ Full iOS build succeeds after guardrail/hint changes.
- ✅ REST cadence now respects the explicit 1.0s policy regardless of temporary burst requests.
- ✅ Users now get a visible smoothness expectation hint during runtime-only REST playback.

### What’s left
- [ ] Optional: expose active effective cadence value (e.g., `1.00s`) in mixer for QA visibility.
- [ ] Optional: differentiate future tier policy (e.g., slower bridgeOptimized cadence if needed).

### Gotchas
- The clamp is intentionally conservative and will trade responsiveness for reliability on grouped_light REST.
- Entertainment path remains preferred for high-motion smoothness; REST guardrails reduce lag/fighting but cannot match DTLS fluidity.

### Current state
Composer now has a centralized tier-aware REST safety policy, debug observability for cadence clamping, and a user-facing runtime-only rate-limit hint, improving predictability and reducing bridge overload behavior.

---

## 2026-05-06 — Composer Transport Choice + QA Cadence Visibility + AI Prompt Chips (Cursor)

### What was built
- Added explicit Composer transport choice UX in `StudioView`:
  - For non-bridgeOptimized composition cards, applying now prompts:
    - `Room Only (REST)`
    - `Entertainment Area (Streaming)`
    - `Always Room Only`
    - `Always Entertainment Area`
  - Persisted preference and prompt behavior are stored via `UserDefaults`.
- Added transport preference model in `StudioViewModel`:
  - `CompositionTransportPreference` enum (`auto`, `roomOnly`, `entertainmentArea`)
  - `compositionTransportPreference` + `isCompositionTransportPromptEnabled`
  - apply path now supports `preferEntertainmentOverride` and routes preference into `startCompositionMode(...)`.
- Added real-time REST cadence exposure in `UnifiedOrchestrator`:
  - `activeRESTCadence: Double?`
  - `activeRESTCadenceByRoom: [String: Double]`
  - cadence UI updates throttled (~1.5s) to avoid observation churn.
- Wired cadence into Studio UI:
  - Runtime-only mixer hint now appends live cadence when available, e.g.:
    - `Runtime-only REST is rate-capped (Live: ~1.0s)`.
- Added AI suggested prompt chips for Composer generation in expanded AI panel:
  - `Static Warm Sunset`
  - `Cozy Reading Corner`
  - `Energetic Club Pulse`
  - `Blinking Christmas Lights`
  - Tapping a chip fills prompt and immediately triggers generate+apply flow.

### What’s working
- ✅ Full iOS build succeeds after all changes.
- ✅ Composer transport is now user-selectable with optional persisted default.
- ✅ Runtime-only REST cadence is visible in mixer for QA.
- ✅ AI chip affordance works and triggers generation quickly.

### What’s left
- [ ] Optional: add a lightweight reset action for transport preference in settings/studio overflow.
- [ ] Optional: show active transport scope tag directly on card before apply (not only in mixer).

### Gotchas
- Entertainment remains bridge-wide/single-session; selection still depends on config/session availability and may fall back to REST.
- Runtime-only compositions on REST are intentionally capped for bridge safety; cadence visibility clarifies this but cannot make REST as smooth as DTLS.

### Current state
Composer now has explicit user-controlled transport scope, observable REST cadence for QA validation, and stronger AI prompt affordances to steer generation quality while preserving bridge-safe scheduling constraints.

---

## 2026-05-06 — Field QA Observation: Composer Start Order Contention (Cursor)

### What was observed
- In live testing, effect stacking behavior depends on apply order:
  - If Composer card is applied **last**, multi-effect behavior appears smooth and stable.
  - If Composer card is applied **first**, later effects feel laggy / delayed.
- User hypothesis (likely correct): Composer path is still competing for transport/state ownership when started first.

### Evidence pattern
- Symptoms look like transport contention rather than bridge rejection:
  - Composer telemetry still reports near-target cadence (~1 Hz REST in tested cases).
  - Other effects degrade primarily when Composer owns early lifecycle.
- This points to orchestration/order arbitration rather than pure rate limit failure.

### Likely root-cause area (next debugging slice)
- Cross-mode coordination between Composer runtime and subsequent effect engines:
  - ownership handoff sequencing,
  - overlap arbitration timing,
  - shared resource/session release timing (REST/Entertainment),
  - residual grouped_light transition/state settling from Composer startup.

### What to do next
- Add explicit “mode ownership handoff” instrumentation:
  - log per-room owner transitions (Composer ↔ bridgeNative/appDriven),
  - log overlap-stop decisions with timestamps,
  - log transport/session active state before/after each apply.
- Reproduce with deterministic sequence tests:
  1) Composer first → native/appDriven cards
  2) native/appDriven first → Composer
  3) same sequence with/without entertainment selection.
- If confirmed, add a small guarded handoff delay or hard ownership barrier when transitioning away from Composer-first starts.

### Current state
- Transport controls, cadence guardrails, and UI diagnostics are materially improved.
- A reproducible sequencing edge case remains: **Composer-first startup can still degrade subsequent effect smoothness**.

---

## 2026-05-06 — Composer Handoff Barrier + Sequencing Instrumentation (Cursor)

### What was built
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Added `[Handoff]` lifecycle logs in `stopCompositionMode(roomID:)` for:
    - stop requested,
    - `studioRestSender.clear()` moment,
    - post-clear settle complete,
    - teardown complete.
  - Added `try await Task.sleep(for: .milliseconds(150))` immediately after `studioRestSender.clear()` in `stopCompositionMode(roomID:)`.
  - Added matching `[Handoff]` lifecycle logs in `stopStudioMode()` and a 150ms settle delay right after `studioRestSender.clear()`.
- `HueHome/UI/Studio/StudioViewModel.swift`
  - In overlap arbitration inside `apply(_:roomOverride:preferEntertainmentOverride:)`, added `[Handoff]` logs around `await stopEffect(on:)` to make the barrier observable.
  - Added explicit `[Handoff]` startup log right before new effect startup sequence begins.
  - In `stopEffect(on:)` bridge-native cleanup path, added:
    - `[Handoff]` log before per-light `no_effect`,
    - 150ms settle delay after batched `no_effect`,
    - `[Handoff]` completion log after settle.

### What’s working
- ✅ Hard async barrier already present in overlap flow remains intact (`await stopEffect(on:)`).
- ✅ New startup is now instrumented to begin only after overlap cleanup + settle barrier.
- ✅ Teardown paths now include explicit bridge settle windows after REST sender clear / `no_effect` cleanup.
- ✅ Project builds successfully with:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What’s left
- [ ] Run on-device/simulator sequencing QA and confirm `[Handoff]` logs appear in strict order during rapid override scenarios.
- [ ] Validate no perceptible regression in perceived responsiveness when quickly swapping cards (150ms barrier tradeoff).

### Gotchas
- `xcodebuild` in sandbox failed due to host permission/simulator service constraints; non-sandbox build succeeded.
- Handoff delay is intentionally short (150ms) to avoid bridge queue flooding while minimizing UX lag.
- Entertainment remains bridge-wide and single-session; sequencing barriers do not change that hardware constraint.

### What to test
- 1) **Composer -> Native immediate override**
  - Select room A, start a Composer card, immediately tap a bridge-native card.
  - Expect `[Handoff]` teardown logs to complete before startup log appears.
- 2) **Composer -> appDriven immediate override**
  - Start Composer, immediately tap Strobe/Party/Thunderstorm.
  - Expect same strict ordering and no interleaved startup before teardown completion.
- 3) **Overlap path (Home zone vs room)**
  - Run effect in room A, switch to Home zone and start another card.
  - Expect overlap detection log, awaited stop barrier, then startup barrier-clear log.
- 4) **Rapid repeated taps**
  - Repeatedly switch between two cards in same room.
  - Confirm no stuck effect state and no bridge command flood behavior.
- 5) **Cross-room non-overlap sanity**
  - Run room A effect, then room B effect with no shared lights.
  - Confirm independent behavior remains unchanged.

### Current state
Composer handoff now has explicit teardown instrumentation and guarded settle barriers at ownership boundaries. Build is green; remaining work is runtime QA to verify strict log ordering and user-perceived smoothness under rapid card switching.

---

## 2026-05-06 — Portrait Lock + Studio SE Mixer Fit + Title Picker Cleanup (Cursor)

### What was built
- `HueHome/Info.plist`
  - Locked app orientation to portrait by reducing `UISupportedInterfaceOrientations` to:
    - `UIInterfaceOrientationPortrait`
- `HueHome/Core/Services/AutomationHandler.swift`
  - Added AppDelegate runtime orientation lock:
    - `application(_:supportedInterfaceOrientationsFor:) -> .portrait`
- `HueHome/UI/Studio/StudioView.swift`
  - Kept the original rolodex room/zone title interaction (swipe L/R rooms, U/D zones, tap for search sheet).
  - Removed the room/zone chevron icon from the Studio title row.
  - Added accessibility traits/hint so the title still reads as tappable control for the room/zone sheet.
  - Reworked mixer sizing for compact devices:
    - wrapped root in `GeometryReader`
    - dynamic tray cap based on available viewport (`resolvedMixerHeight(proxy:)`)
    - tab-bar/home-indicator aware bottom clearance
  - Reworked mixer scroll behavior:
    - composition controls now use a fill-height scroll region (`GeometryReader` + `ScrollView`)
    - essential parameter controls use same pattern
    - prevents bottom content from being clipped on iPhone SE-sized screens.

### What’s working
- ✅ Build succeeds:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`
- ✅ Studio title remains tappable for room/zone search without visual chevron clutter.
- ✅ Mixer can grow taller on compact devices and keeps content scrollable to reach bottom controls.
- ✅ Orientation is portrait-only at plist and runtime delegate levels.

### What’s left
- [ ] Validate on real iPhone SE that all composition controls (including lower controls) are reachable without clipping.
- [ ] Verify no unexpected layout regressions on larger phones after dynamic tray cap changes.

### Gotchas
- Portrait lock is now enforced in two places (plist + AppDelegate delegate callback) intentionally for consistency.
- Mixer tray now consumes more vertical space on compact devices; this is deliberate to preserve control visibility.

### What to test
- 1) **Portrait lock**
  - Launch app and rotate device/simulator to landscape.
  - Expect UI to remain portrait with no layout rotation.
- 2) **Studio title row interaction**
  - In Studio, tap the room/zone title (no chevron now).
  - Expect Room/Zone search sheet to open exactly as before.
- 3) **Rolodex navigation still intact**
  - Swipe title left/right to cycle rooms; up/down to cycle zones.
  - Confirm transitions remain smooth and selection updates correctly.
- 4) **iPhone SE mixer fit (critical)**
  - On Composer card, open mixer and scroll through controls.
  - Confirm bottom controls are reachable and not hidden behind tab bar/home indicator.
- 5) **Non-composer mixer fit**
  - Use bridge-native and app-driven cards with several sliders.
  - Confirm lower rows remain reachable via scroll on compact height.
- 6) **Regression sanity**
  - Verify card grid remains visible when mixer is expanded/collapsed.
  - Verify stop/save buttons remain visible and tappable.

### Current state
App is now portrait-locked and Studio mixer layout is hardened for compact screens (including SE) with viewport-aware tray sizing and scrollable content regions. Next step is focused SE device QA for final visual tuning.

---

## 2026-05-06 — App Store Orientation Compliance + Runtime Rotation Toggle (Cursor)

### What was built
- `HueHome/Info.plist`
  - Restored full iPhone orientation set required for App Store upload validation:
    - `UIInterfaceOrientationPortrait`
    - `UIInterfaceOrientationPortraitUpsideDown`
    - `UIInterfaceOrientationLandscapeLeft`
    - `UIInterfaceOrientationLandscapeRight`
- `HueHome/Core/Services/AutomationHandler.swift`
  - Updated `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` to be user-preference-driven:
    - default behavior remains portrait-only,
    - optional landscape via user setting.
  - Added `OrientationPrefs.allowLandscape` (`"app.allowLandscapeRotation"`) UserDefaults key.
- `HueHome/UI/Settings/SettingsView.swift`
  - Added new `APP` section toggle:
    - `Allow Landscape Rotation`
    - Backed by `@AppStorage("app.allowLandscapeRotation")`
    - Default is `false` (portrait lock remains default behavior).

### What’s working
- ✅ Upload-blocking orientation metadata issue is addressed by plist orientation restoration.
- ✅ Runtime behavior still defaults to portrait lock for normal users.
- ✅ Landscape can be explicitly enabled by testers/power users from Settings.
- ✅ Build succeeds:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What’s left
- [ ] Verify App Store upload path no longer returns error 90474.
- [ ] Validate that toggling landscape in Settings updates runtime behavior as expected across major app screens.

### Gotchas
- App Store validation checks declared plist orientations, not only runtime locks.
- Runtime orientation changes can appear delayed until next screen transition in some UIKit/SwiftUI stacks.

### What to test
- 1) **Upload compliance**
  - Archive + upload; confirm no orientation validation error (90474).
- 2) **Default lock behavior**
  - Fresh install / default settings: rotate device.
  - Expect portrait lock.
- 3) **Landscape opt-in**
  - Settings -> App -> enable `Allow Landscape Rotation`.
  - Rotate on Studio/Home/Settings; expect landscape support.
- 4) **Toggle off regression**
  - Disable toggle and retest rotation.
  - Expect portrait lock restored.

### Current state
Orientation handling is now split correctly between App Store compliance (full plist support) and product UX preference (portrait-first runtime lock with optional tester override). Build is green; next checkpoint is successful archive upload and quick on-device rotation QA.

---

## 2026-05-06 — Composer Mic + REST Snappiness + Tab Lazy-Load + Perf (Cursor)

### What was built

**Composer microphone (reaction layer)**  
- New `HueHome/UI/Studio/CompositionMicCapture.swift` — FFT band splits aligned with `VisualizerEngine`, lock-protected levels, `syncDemand(_:)` lifecycle.  
- `UnifiedOrchestrator` wires `CompositionMicCapture.reactionAudioLevel(for:)` into all `CompositionEngine.render` paths (REST scheduler, ENT loop, prime frame); `refreshCompositionMicDemand()` tied to composition lifecycle; weak `compositionEntertainmentParamBox` for mic-demand when ENT transport is active.  
- `HueHome/HueHomeApp.swift` — `Notification.Name` extensions: `composerMicExclusiveBegan`, `compositionMicPermissionDenied`.  
- `SyncModeEngine` observes `composerMicExclusiveBegan` and calls `stop()` if Sync is running (avoid dual `AVAudioEngine`).  
- `CompositionEngine` — **tap tempo** uses envelope BPM sine wave (no mic); mic sources still use passed `audioLevel`.  
- Exclusive handoff delay after posting mic notification: **35ms** (was 60ms).  
- **Parallel warmup**: When gamut must be fetched and reaction uses mic, mic `syncDemand(true)` runs **concurrently** with `resolveCompositionGamut` / `resolveDominantGamut`, and mic completion is **awaited before** blocking on gamut result (`StudioViewModel` + `UnifiedOrchestrator`).  
- ENT path: `tryStartEntertainment` and `findEntertainmentConfig` run **in parallel** when choosing streaming transport.

**REST Composer cadence (Sync-aligned)**  
- Scheduler uses **`0.15s × active composition room count`** as baseline (matches `SyncModeEngine` REST visualizer spacing model).  
- Separate **burst floors** for color-pad interaction vs idle tier guardrails (`bridgeOptimized` remains more conservative).  
- Idle/settle transition durations tightened slightly for grouped_light; post-send scheduler yield **40ms → 20ms**.

**Shell performance**  
- `MainTabView` — **lazy tab realization** (`realizedTabs`): Scenes / Studio / More roots not constructed until first visit; tab bar inserts current tab on tap; `onAppear`/`onChange` register selection for restoration.  
- `StudioView` — removed `.animation(..., value: currentDeck)` on deck `TabView` to reduce paging hitch.

### Files touched (high level)
- `CompositionMicCapture.swift` (new), `UnifiedOrchestrator.swift`, `CompositionEngine.swift`, `HueHomeApp.swift`, `SyncModeEngine.swift`, `StudioViewModel.swift`, `StudioView.swift`, `MainTabView.swift`, `HueHome.xcodeproj/project.pbxproj`

### What’s working
- ✅ `xcodebuild` HueHome scheme — BUILD SUCCEEDED (`generic/platform=iOS`)

### Gotchas
- Hue does not stream “voice” over the bridge — mic only improves **client-derived** levels fed into Composer; bridge latency unchanged.  
- `grouped_light` REST remains throughput-sensitive; burst paths must not defeat tier guardrails on weak bridges.  
- Lazy tabs: first open of Studio still pays full `StudioView` cost once.

### What to test (QA checklist)

**A — Composer mic**  
1. **Permission** — Fresh install or revoke mic: apply a composition with reaction source **Mic** (amplitude / bass / mid / treble). Expect system prompt once; if denied, capture still fails gracefully (optional toast pipeline not wired — verify no crash).  
2. **Reaction vs tap tempo** — Preset with **Tap tempo**: lights should pulse to **envelope BPM**, not room noise. Switch to **Mic amplitude**: verify motion follows voice/claps.  
3. **Sync exclusivity** — Start **Music Sync** (or any Sync mode using mic), then start **Composer** with mic reaction. Expect Sync to stop and Composer mic to work (no stuck dual-engine state).  
4. **ENT vs REST Composer + mic** — Same mic preset: room with entertainment area (streaming) and force **Room only (REST)** via transport prompt; verify both paths show reactive brightness (REST will be lower cadence).  
5. **Background** — Composer + mic running: send app to background; verify capture stops / no runaway session (resume foreground).

**B — REST Composer snappiness**  
6. **Single room** — Runtime composition on **one** room: updates should feel closer to **Sync visualizer** pacing (~150ms scale), not 1 Hz slideshow.  
7. **Multi-room** — Two+ rooms with compositions: verify fair rotation and **no** bridge lag storm (no 30–60s drain — back off if observed).  
8. **Interaction burst** — Drag color pad / interact: expect snappier bursts than idle (within reason).  
9. **bridgeOptimized tier** — Still more conservative cadence; confirm acceptable on real bridge.

**C — Startup / Studio shell**  
10. **Cold launch** — From quit: land on **Home**; first tap **Studio** — should avoid building Studio until then (may feel faster than when all tabs eager-loaded).  
11. **Deck paging** — Swipe Effects → Live → Composer; confirm no extra animation jank on deck switch.  
12. **iPad** — Sidebar tab switch still realizes tabs and shows content.

**D — Regressions**  
13. Apply **bridge-native** cards (candle, fire, …) — unchanged path.  
14. **Stop composition / handoff** — Stop Composer then apply another Studio card; no stuck lights or duplicate sessions.

### Current state
Composer reactions can use real microphone levels with Sync-safe exclusivity; REST Composer pacing matches the app’s Sync REST model for dynamic tiers; main shell defers heavy tabs until first visit. Ready for **device QA** (mic + multi-room + bridge load).

---

## 2026-05-06 — Studio Room Target Race + Composer REST Efficiency Pass (Cursor)

### Problem observed
- Composer apply could target the wrong room under rapid UI interaction.
- Logs showed mismatches like `selectedRoom: Main bedroom` while `groupedLightID` resolved to Bathroom.
- Composer REST mode still generated heavy traffic (frequent `PUT /grouped_light/...`) and startup duplicated `GET /light` work.

### What was fixed

**1) Room-targeting race in Studio UI**
- `HueHome/UI/Studio/StudioView.swift`
  - Removed render-time `roomSnapshot` captures from card/grid/menu paths.
  - Room is now captured at action time inside apply helpers, so apply always uses current selection.
  - Updated helper signatures:
    - `applyCardWithTransportPrompt(_:)`
    - `applyCompositionQuick(_:mode:)`
    - `composerPresetOverflowActions(preset:card:)`

**2) Startup GET dedupe in apply flow**
- `HueHome/UI/Studio/StudioViewModel.swift`
  - Added cached-light overloads:
    - `resolveLightIDs(for:api:cachedLights:)`
    - `resolveDominantGamut(for:api:cachedLights:)`
  - Apply now fetches bridge light inventory once (only when needed for device-backed rooms) and reuses it for:
    - overlap detection / room light resolution
    - dominant gamut resolution
  - Eliminates redundant back-to-back `GET /light` calls at composition startup.

**3) Balanced scheduler efficiency tightening**
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Added extra balanced-profile skip gate for tiny deltas sent too recently.
  - Increased balanced idle / low-power intervals for `.hybrid` and `.runtimeOnly` tiers.
  - Goal: preserve interaction responsiveness while reducing sustained REST chatter in non-interacting periods.

### Verification
- ✅ Lints clean on edited files.
- ✅ Build succeeded:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What to test
- 1) **Room correctness under fast interaction**
  - Rapidly change room/zone and immediately tap composer cards / overflow actions.
  - Confirm `selectedRoom` and `groupedLightID` always map to the same target room.
- 2) **Composer startup traffic**
  - Start a composition and confirm reduced duplicate `GET /light` bursts.
- 3) **REST efficiency in Balanced**
  - Let a composition run idle for 30-60s; expect fewer PUTs than prior runs.
  - During active slider/pad interaction, responsiveness should remain acceptable.

### Current state
Wrong-room apply race is closed at the Studio action layer, startup light fetches are deduplicated, and Balanced REST cadence is more conservative when visual deltas are small. Ready for on-device validation focused on room-target integrity and perceived smoothness vs call volume.

---

## 2026-05-06 — Composer Color Edit Immediate Flush (REST burst override)

### Problem observed
- In Composer REST mode, user hue/saturation pad edits could be treated as "not meaningful" by balanced low-power gating, causing delayed/no visible color response immediately after drag.
- Logs showed low-power skips right after pad interaction (`Δxy` near zero after gamut clamp), even though user expected instant feedback.

### What was built

**User-edit forced burst path**
- `HueHome/UI/Studio/CompositionEngine.swift`
  - `CompositionParamBox` now includes:
    - `forceRESTBurstUntil: TimeInterval`
    - `triggerRESTBurst(seconds: 0.55)`
  - Purpose: mark a short post-edit window where REST scheduler should prioritize sending.

- `HueHome/UI/Studio/StudioView.swift`
  - Hue/saturation pad now calls `triggerRESTBurst()`:
    - on drag change
    - on drag end
  - Keeps existing `isColorPadInteracting` semantics.

- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Scheduler reads `userEditBurstActive = runtime.paramBox.forceRESTBurstUntil > now`.
  - During this window:
    - bypass low-power + efficiency skip gates
    - use burst cadence/floor path (same responsiveness class as interaction burst)

### Why this works
- Even if gamut clamp results in tiny `Δxy`, a direct UI edit now forces near-term sends so the bridge gets an immediate state update.
- Balanced mode remains efficient outside the short user-edit burst window.

### Verification
- ✅ Lints clean on edited files.
- ✅ Build succeeded:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What to test
- 1) Start Composer in Bathroom (REST transport).
- 2) Drag hue/saturation pad briefly and release.
- 3) Confirm visible color response occurs immediately after drag (no perceived dead period).
- 4) Let composition idle for 20-30s; verify cadence still backs off in balanced mode.

---

## 2026-05-06 — Composer Color Pad Haptics + Ultra-Low REST Cadence Constants (Cursor)

### What was built
- `HueHome/UI/Studio/StudioView.swift`
  - Added continuous, throttled haptic feedback while dragging the Composer hue/saturation pad:
    - New state: `lastHuePadHapticAt`
    - During `DragGesture.onChanged`, fires `HapticManager.shared.selection()` at most once every ~80ms.
    - Resets haptic timer on drag end; existing end-of-drag haptic remains.
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Aggressively lowered Composer REST scheduler interval constants for fast-response testing:
    - Lowered idle baseline (`preferredComposerIdleInterval`) and all tier minimums.
    - Lowered non-burst floors (`minimumComposerRESTInterval`) and burst floors (`minimumComposerBurstFloor`).
    - Tightened burst interval calculation (`max(0.03, syncRestInterval * 0.25)`).
    - Lowered low-power idle intervals to keep cadence high even during small-delta periods.

### What's working
- ✅ Lints clean on edited files (`StudioView.swift`, `UnifiedOrchestrator.swift`).
- ✅ Build succeeded:
  - `xcodebuild -project /Users/brianbean/Desktop/huehome-pro-v0.3.0/HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`
- ✅ Composer color pad now provides tactile feedback during drag (not only on drag end).

### What's left
- [ ] On-device bridge QA for overload/lag behavior with the new ultra-low intervals (single room + multi-room).
- [ ] Confirm no command-flood side effects (dropped updates, delayed bridge recovery, or perceived jitter).
- [ ] Decide final production cadence policy after telemetry review (`hz`, `avgLagMs`, `maxLagMs`).

### Gotchas
- REST grouped_light still has practical bridge throughput limits; very low interval constants can reduce stability even if app-side scheduler lag remains near zero.
- Haptic feedback is intentionally throttled to avoid excessive vibration spam during continuous drags.

### Current state
Composer editor responsiveness is now aggressively biased toward immediacy: the color pad gives live haptic pulses during drag, and REST cadence guardrails are significantly lowered for stress/perf validation. Build is green; next step is focused real-bridge QA before locking production values.

---

## 2026-05-07 — Bridge-Stored Animation Engine: Root Cause + Fix (Antigravity/Gemini)

### Problem
Compositions applied from Studio did not persist when the app was closed. The bridge-stored v1 animation chain (rules + CLIP sensor + schedule) was failing silently at rule creation with error 608/6.

### Root cause (after 4 iterations of debugging)
**v1 rule/schedule action addresses must be relative paths** — NOT the full `/api/{token}/...` path.

```diff
# WRONG (what we were sending):
- "address": "/api/ZVcY.../lights/1/state"

# CORRECT (what the bridge expects):
+ "address": "/lights/1/state"
```

The bridge internally resolves the user context for rule/schedule actions. Including the token made the address malformed, causing:
- Error 608: "Rule actions contain errors or an action on an unsupported resource"
- Error 6: "parameter, transitiontime/on/address/method, not available" (bridge couldn't parse the action at all)

Additional bugs found and fixed during the debugging process:
1. **v1/v2 light ID mismatch** — v2 uses UUIDs, v1 uses numeric IDs ("1", "2"). Added `resolveV1LightIDs()`.
2. **Double rule creation** — Code created rules twice (scene-only, then deleted and recreated with sensor advance). Collapsed to single-pass.
3. **Scene activation in rules** — v1 rules don't reliably support `{"scene": "id"}` on group actions. Switched to direct per-light state commands (`PUT /lights/{id}/state`).
4. **Sensor kickoff** — Sensor started at 0; setting to 0 didn't trigger the `dx` condition. Now starts at 99.
5. **Orphaned resources** — Multiple test runs left 18+ scenes and 3+ sensors on the bridge. Added `purgeAllChromaGlowResources()` and auto-cleanup before upload.

### What was built
- **`HueV1Client.swift`** — v1 REST client for rules, scenes, CLIP sensors, schedules, resourcelinks. Includes `resolveV1LightIDs()`, fetch methods for all resource types, and `token` exposed for rule action construction.
- **`BridgeAnimationEngine.swift`** — Pre-renders compositions into v1 rule chains. Direct per-light state commands (no scene activation). Sensor-based step counter with schedule-driven cycling. `purgeAllChromaGlowResources()` for cleanup.
- **`UnifiedOrchestrator.swift`** — Bridge-stored upload integration with auto-cleanup, `isBridgeStored` state flag, transport priority: Bridge-Stored > Entertainment > Per-light REST > Grouped REST.

### Two implementation paths identified

**Option A: Fix v1 relative paths (3-line fix)** — Change addresses in `sceneActivationCommand()`, `sensorIncrementCommand()`, and direct light actions from `/api/{token}/...` to `/...`. Gets the full v1 rule chain working for ALL composition patterns.

**Option B: v2 Dynamic Scene** — Create v2 scene with `POST /clip/v2/resource/scene`, recall with `{"recall": {"action": "dynamic_palette", "duration": 5000}}`. Bridge autonomously cycles colors. Zero rules/sensors/schedules. Already have `CreateSceneRequest`, `activateScene(id:speed:)`, and `HueScene.isDynamic` in the codebase.

**Decision: Implement both.** Option A for complex motion (cascade/wave/scatter), Option B as fast-path for simple palette presets.

### What's left
- [ ] Fix v1 relative paths (Option A — 3 lines)
- [ ] Implement v2 dynamic scene fast-path (Option B)
- [ ] Add manual "Clean Bridge" button in Settings
- [ ] On-device soak test: apply animation, close app, verify lights keep going
- [ ] Resource capacity monitoring (rules/sensors/schedules are finite on bridge)

### Gotchas
- v1 rule actions: addresses are RELATIVE (`/lights/1/state`), NOT full API paths
- v1 rules: max 8 actions per rule. With N lights + 1 sensor bump = N+1 actions. Safe for up to 7 lights per room.
- v2 dynamic scenes: less control over per-light timing (bridge controls cycle), but zero resource overhead
- Bridge has finite resource limits (~100 rules, ~250 sensors, ~100 schedules). Must clean up between runs.
- `purgeAllChromaGlowResources()` finds all CG_ prefixed resources and deletes them. Currently runs before every upload.

### Current state
Root cause identified and documented. Build is green. Two implementation paths approved. Next step: apply the 3-line v1 fix, test on device, then build v2 dynamic scene path.

---

## 2026-05-08 — Multi-Bridge Routing Foundation for Widget/Watch (Cursor)

### What was built
- **`HueHome/Core/Network/WidgetDataStore.swift`** — Extended shared snapshot contract with `bridgeID` on `WidgetRoomSnapshot`, added `WidgetBridgeCredentials`, added bridge map persistence (`hue_widget_bridges_v1`), and added `credentials(for:)` resolver with legacy fallback.
- **`HueHome/Core/Network/UnifiedOrchestrator.swift`** — Writes bridge-aware room/zone snapshots, publishes active bridge credential map for App Group consumers, and pushes bridge map through watch sync path.
- **`HueHome/HueHomeApp.swift`** — Updated `WatchSessionManager.push` payload to include `wc_bridges_v1` (plus legacy fallback keys).
- **`HueHomeWidget/WidgetIntents.swift`** — Switched interactive widget intents to resolve per-room bridge credentials instead of global single-bridge creds.
- **`HueHome/Intents/HueRoomEntity.swift` + `HueHome/Intents/HueIntents.swift`** — Added `bridgeID` to intent entities and routed Siri intents through per-bridge credential resolution.
- **`LightShadeWatchApp Watch App/WatchStore.swift` + `LightShadeWatch/WatchWidgetStore.swift`** — Added bridge map decoding/storage and per-room bridge credential resolution on watch/watch-widget paths.

### What's working
- ✅ iOS app target (`HueHome`) compiles successfully after multi-bridge routing changes.
- ✅ watchOS app target (`LightShadeWatchApp Watch App`) compiles successfully after watch sync/store updates.
- ✅ Widget/intent/watch code paths now have a deterministic per-room bridge routing key (`bridgeID`) and a shared bridge credential map.
- ✅ Legacy single-bridge keys are still emitted/read as fallback for backward compatibility.

### What's left
- [ ] Add interactive watch complication/widget toggle intent wiring in `LightShadeWatch` (UI currently non-interactive).
- [ ] Validate on physical watch that Bridge 2 toggles now route correctly under real-world stale-cache conditions.
- [ ] Add explicit failure surfacing/telemetry when room routing metadata is missing or stale.
- [ ] Optionally add groupedLightID→bridgeID fallback map for extra resilience if room bridge metadata is absent.

### Gotchas
- Existing watch/widget data can remain stale across sessions; routing fixes require fresh app-driven sync to repopulate bridge-aware payloads.
- Some watchers still rely on legacy `hue_widget_bridge_ip`/`hue_widget_token`; keeping fallback keys avoids hard breaks while migrating.
- Multi-bridge correctness depends on `bridgeID` being present in snapshots; missing IDs will fall back to legacy credentials.

### Current state
Multi-bridge routing foundation is implemented across iOS widget, Siri intent, watch sync, and watch stores. Both iOS and watch targets build cleanly. Next step is on-device verification for Bridge 2 behavior and then watch widget interactivity wiring.

---

## 2026-06-01 — Build-Time Git Metadata Injection (IOS-OPS-001B) (Cursor)

### What was built
- **`Scripts/inject_build_metadata.sh`** — Injects `ChromaGlowGitCommit`, `ChromaGlowGitBranch`, `ChromaGlowBuildTimestamp`, and `ChromaGlowGitDirty` into the **built** app bundle plist (`${TARGET_BUILD_DIR}/${INFOPLIST_PATH}`) only. Never edits `HueHome/Info.plist`. Supports `CHROMAGLOW_METADATA_PLIST_PATH` and `CHROMAGLOW_REPO_ROOT` for tests.
- **`Scripts/tests/test_inject_build_metadata.sh`** — 19 fixture cases (clean/dirty/detached/non-git/stale keys/spaces/missing plist).
- **`HueHome.xcodeproj/project.pbxproj`** — HueHome target only: **Inject Build Metadata** Run Script phase (last phase). Uses dependency analysis with `inputPaths` = processed bundle Info.plist so injection runs **after** `ProcessInfoPlistFile` on incremental builds.

### Injected plist keys
| Key | Source |
|---|---|
| `ChromaGlowGitCommit` | `git rev-parse HEAD` (full SHA) |
| `ChromaGlowGitBranch` | `git branch --show-current` (omitted on detached HEAD) |
| `ChromaGlowBuildTimestamp` | UTC `date -u +%Y-%m-%dT%H:%M:%SZ` (always) |
| `ChromaGlowGitDirty` | `git status --porcelain` → `"1"` / `"0"` |

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → 19/19 pass
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' build` → **BUILD SUCCEEDED**
- Built `HueHome.app/Info.plist` contains injected keys; `git diff -- HueHome/Info.plist` → no diff
- Incremental second build retains keys; timestamp updates
- `codesign --verify --deep --strict` on built app → pass (generic iOS build)

### Physical-device verification
1. Open **`HueHome.xcodeproj`** (not `ChromaGlow.xcodeproj` — local shell has no `project.pbxproj`)
2. Scheme **`HueHome 1`** → physical iPhone
3. Clean Build Folder → Run
4. **More → Settings** → scroll to footer
5. Compare commit: `git rev-parse --short=8 HEAD`
6. With uncommitted changes expect **Working tree modified**; after a clean commit, dirty line should disappear
7. Force quit → relaunch → Settings stable

### Gotchas
- `ChromaGlow.xcodeproj` is an incomplete untracked wrapper; use **`HueHome.xcodeproj`**
- Run Script uses `ENABLE_USER_SCRIPT_SANDBOXING = NO` on HueHome (already set)
- Do not place `BuildMetadata.swift` under `HueHome/Core/Build/` — `.gitignore` rule `build/` ignores that path

### What's next
- [ ] **IOS-OPS-001C** — normalized build numbering (separate from Git metadata)
- [ ] Optionally migrate `MoreView` version line to `BuildMetadata.current`

### Current state
IOS-OPS-001B complete on branch `ios-ops/build-metadata-injection`. Settings footer can show live Git provenance from the built app plist. Not committed unless requested.

---

## 2026-06-01 — Normalize Version and Build Settings (IOS-OPS-001C) (Cursor)

### What was built
- **`HueHome/Info.plist`** — Replaced hard-coded `0.9.0` / `1` with `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` plist substitutions.
- **`HueHome.xcodeproj/project.pbxproj`** — Added `MARKETING_VERSION = 0.9.0` and `CURRENT_PROJECT_VERSION = 1` to HueHome Debug and Release target configurations (authoritative source of truth for the main app).
- **`HueHome/UI/More/MoreView.swift`** — Replaced direct `CFBundleShortVersionString` / `CFBundleVersion` reads (stale `"0.3.0"` fallback) with `BuildMetadata.current`.

### Version/build normalization policy
- Xcode build settings are the single source of truth: `MARKETING_VERSION = 0.9.0`, `CURRENT_PROJECT_VERSION = 1`.
- Main app plist uses build-setting substitutions; IOS-OPS-001B injection continues to write Git provenance keys into the **processed** bundle plist only.
- Embedded bundles already normalized via `GENERATE_INFOPLIST_FILE = YES` + per-target build settings — no extension/watch plist edits required.

### Pre-edit inventory (shipped bundles)
| Bundle / target | Info.plist path | Short-version source | Build-number source | Debug | Release | Embedded in main app? |
|---|---|---|---|---|---|---|
| HueHome (main) | `HueHome/Info.plist` | Hard-coded → now `$(MARKETING_VERSION)` | Hard-coded → now `$(CURRENT_PROJECT_VERSION)` | 0.9.0 / 1 | 0.9.0 / 1 | — |
| HueHomeWidgetExtension | `HueHomeWidget/Info.plist` (NSExtension only) | `MARKETING_VERSION` via generated plist | `CURRENT_PROJECT_VERSION` via generated plist | 0.9.0 / 1 | 0.9.0 / 1 | Yes (`PlugIns/`) |
| LightShadeWatchExtension | `LightShadeWatch/Info.plist` (NSExtension only) | `MARKETING_VERSION` via generated plist | `CURRENT_PROJECT_VERSION` via generated plist | 0.9.0 / 1 | 0.9.0 / 1 | No (watch app embeds separately) |
| LightShadeWatchApp Watch App | Generated (no source plist) | `MARKETING_VERSION` | `CURRENT_PROJECT_VERSION` | 0.9.0 / 1 | 0.9.0 / 1 | Yes (`Watch/`) |

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → **19/19 pass** (injector unchanged)
- Debug `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' build` → **BUILD SUCCEEDED** (60 pre-existing warnings, none from this change)
- Release build → **BUILD SUCCEEDED** (55 pre-existing warnings)
- Built main app plist: `CFBundleShortVersionString = 0.9.0`, `CFBundleVersion = 1`, Git metadata keys present, `ChromaGlowGitDirty = 1` during uncommitted work
- Nested bundles (widget `.appex`, watch `.app`): all `0.9.0` / `1` in Debug and Release
- Second incremental Debug build: keys not duplicated, timestamp updated (`2026-06-01T23:22:05Z` → `2026-06-01T23:24:38Z`)
- Source `HueHome/Info.plist` contains substitution tokens only (no Git keys)
- `codesign --verify --deep --strict` on Debug and Release built apps → **pass**
- `git diff --check` → clean

### Physical-device verification
1. Open **`HueHome.xcodeproj`** (not `ChromaGlow.xcodeproj`)
2. Scheme **`HueHome 1`** → physical iPhone
3. Product → Clean Build Folder → Run
4. **More → Settings** → scroll to footer
5. Confirm: `Version 0.9.0 · Build 1`, commit prefix matches `git rev-parse --short=8 HEAD`, branch `ios-ops/normalize-version-settings`, UTC timestamp, **Working tree modified** while uncommitted
6. Force quit → relaunch → footer stable
7. After commit + clean rebuild → dirty line disappears

### Gotchas
- Tracked project remains **`HueHome.xcodeproj`**; `ChromaGlow.xcodeproj` is an incomplete local shell
- HueHomeTests target has no `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (test bundle only, not shipped)

### What's next
- [x] **IOS-OPS-001D** — push-triggered CI build numbering (see DEVLOG entry below)

### Current state
IOS-OPS-001C merged to `main`. Effective version/build preserved at `0.9.0` / `1`.

---

## 2026-06-01 — Push-Triggered CI Build Numbering (IOS-OPS-001D) (Cursor)

### What was built
- **`.github/workflows/ios-build-provenance.yml`** — Push + manual workflow on `macos-latest` that runs shell tests, builds unsigned Debug iOS app with `CURRENT_PROJECT_VERSION=${GITHUB_RUN_NUMBER}`, verifies metadata, inspects nested widget/watch bundles, writes provenance report, and uploads report + processed main app plist artifact.
- **`Scripts/verify_built_app_metadata.sh`** — Read-only validator for processed built-app plists (version, build, Git metadata, timestamp format, dirty state).
- **`Scripts/tests/test_verify_built_app_metadata.sh`** — 17 fixture tests for the verifier.
- **`Scripts/inject_build_metadata.sh`** — Added `CHROMAGLOW_GIT_BRANCH_OVERRIDE` for CI detached-HEAD branch metadata (local behavior unchanged when unset).
- **`Scripts/tests/test_inject_build_metadata.sh`** — Added branch-override tests (detached HEAD + slash branch); now **21/21 pass**.

### CI build-number policy
- **CI:** `CURRENT_PROJECT_VERSION = GITHUB_RUN_NUMBER` via command-line `xcodebuild` override (no source or project-file mutation).
- **Local Xcode:** unchanged — `CURRENT_PROJECT_VERSION = 1` from project settings → Settings footer shows `Build 1`.
- **Marketing version:** `0.9.0` everywhere (unchanged).

### Branch metadata in CI
- `CHROMAGLOW_GIT_BRANCH_OVERRIDE=${GITHUB_REF_NAME}` is set **only on the Build unsigned iOS app step** (not job-wide), so shell fixture tests still see fixture repo branch `main`.
- Local builds without override preserve existing `git branch --show-current` behavior.

### CI workflow hardening (first hosted runs)
| Fix | Problem | Resolution |
|---|---|---|
| Fixture default branch | GitHub runners use `master`; clean-repo test expected `main` | `git init -q -b main` in `init_clean_repo` |
| Branch override scope | Job-level override leaked into shell tests | Move override to build step `env` only |
| Xcode toolchain | Default runner Xcode 16.4 vs local 26.4 | **Select Xcode 26.3** step sets `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer` |
| Processed plist lookup | `find -path 'Debug-iphoneos/...'` never matched absolute paths | Deterministic `${DERIVED_DATA}/Build/Products/Debug-iphoneos/HueHome.app/Info.plist` + diagnostic `find` fallback |

### Compiler compatibility (Xcode 26.3 CI only; behavior-neutral)
- **`HueHome/UI/LightControl/LightControlView.swift`** — `ColorWheelView`: explicit `CGFloat` angles + `CoreGraphics.cos` / `CoreGraphics.sin` (resolved ambiguous `cos`/`sin` overloads).
- **`HueHome/UI/Studio/StudioView.swift`** — `motionAngleDial` + `spatialMiniMap`: same `CGFloat` + `CoreGraphics` pattern (resolved type-check timeout on `ZStack`).

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- Local CI-style unsigned build with `CURRENT_PROJECT_VERSION=4242` + `CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**
- Main app built plist: `0.9.0` / `4242`, Git metadata present; deterministic plist path lookup **PASS**
- Nested bundles: widget + watch both `0.9.0` / `4242`
- `git diff -- HueHome/Info.plist` → **no diff** (IOS-OPS-001D policy unchanged)
- `git diff -- HueHome.xcodeproj/project.pbxproj` → **no diff**
- Ruby YAML parse of workflow → **PASS**

### Post-push GitHub validation
1. Push branch → **Actions** → **iOS Build Provenance** → confirm job succeeds end-to-end
2. Workflow summary: marketing `0.9.0`, CI build number = run number, commit/branch match, dirty `0`
3. Download artifact `ios-build-provenance-<run_id>-<attempt>`; confirm `ios-build-provenance.txt` + processed `HueHome.app/Info.plist`
4. After merge to `main`, confirm `main` push also triggers and passes

### Gotchas
- Tracked project remains **`HueHome.xcodeproj`**; `ChromaGlow.xcodeproj` is an incomplete local shell
- CI builds are **unsigned validation builds** — not installable on physical devices; local Xcode builds still show **`Build 1`**
- Hosted runner must have `Xcode_26.3.app`; workflow fails fast with installed Xcode list if missing
- No signing secrets, TestFlight upload, archive export, or auto-commit in this chunk

### What's next
- [ ] **IOS-OPS-001E** (optional) — signed archive and TestFlight delivery

### Current state
IOS-OPS-001D merged to `main` via PR #5 (`eb214c4`). Push-triggered **iOS Build Provenance** workflow validates CI build numbering and metadata without mutating source version settings. Local physical-device builds remain `Version 0.9.0 · Build 1`.

---

## 2026-06-01 — Dashboard Room Builder Recovery (IOS-REF-001R) (Cursor)

### What was built
- **Branch:** `ios-ref/dashboard-room-builder`
- **Starting SHA:** `1793338` (fast-forwarded to `origin/main`)
- **`HueHome/Core/Dashboard/DashboardDisplayModelBuilder.swift`** — pure `makeRooms(from:)` helper: flatten `roomsByBridge` values → localized alphabetical sort by name → ID-only de-duplication.
- **`HueHome/Core/Network/UnifiedOrchestrator.swift`** — `rebuildAllRooms()` delegates composition to the builder; navigation buffering (`isNavigating` / `sseRebuildPendingRooms`) and `scheduleWidgetWrite()` unchanged.
- **`HueHomeTests/DashboardDisplayModelBuilderTests.swift`** — seven focused contract tests (empty input, multi-bridge sort, duplicate IDs, sort-before-dedupe, same-name different IDs, field preservation, input non-mutation).
- **`HueHome.xcodeproj/project.pbxproj`** — `Dashboard` group under `Core`; builder + test file membership only.

### Preserved behavior
- Navigation buffering during push transitions
- Widget/watch snapshot scheduling via `scheduleWidgetWrite()` (orchestrator-only)
- ID-only de-duplication (not `(bridgeID, id)`)
- Localized ascending name sort before dedupe
- `rebuildAllZones()`, `scheduleWidgetWrite()`, `updateRoom(...)` untouched

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- `xcodebuild -project HueHome.xcodeproj -target HueHomeTests -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build` → **BUILD FAILED** (pre-existing: `LightShadeWatchApp Watch App` `AppIcon` asset catalog has no applicable content for iOS Simulator — HueHomeTests depends on HueHome, which embeds watch targets)
- Focused `xcodebuild test` → **blocked**: shared scheme `HueHome 1` has `<TestAction shouldAutocreateTestPlan="YES">` but no `<Testables>` entries (unchanged per task scope)

### Physical-device smoke (Brian)
1. Open **`HueHome.xcodeproj`**, scheme **`HueHome 1`**, physical iPhone.
2. **Product → Clean Build Folder → Run**
3. **More → Settings** footer: branch `ios-ref/dashboard-room-builder`, SHA matches `git rev-parse --short HEAD`
4. Dashboard: no crash; room cards alphabetical; no duplicate cards
5. Room detail → back; toggle room; adjust brightness; force quit → relaunch
6. Multi-bridge (if available): rooms from both bridges, no duplicate IDs
7. Widget (if installed): updates after room action

### Manual test run (Xcode)
- Open `DashboardDisplayModelBuilderTests.swift` → click diamond on `DashboardDisplayModelBuilderTests` class or individual tests in Test navigator (⌘6) after a successful app build on device/simulator.

### What's next
- [ ] **IOS-REF-002** — zone-list builder extraction (`rebuildAllZones()` seam)

### Current state
IOS-REF-001R complete on branch `ios-ref/dashboard-room-builder`. Behavior-neutral strangler seam; orchestrator remains facade. Not committed unless requested.

---

## 2026-06-01 — Dashboard Zone Builder Extraction (IOS-REF-002)

### What was built
- **Branch:** `ios-ref/dashboard-zone-builder`
- **Starting SHA:** `02fa48a`
- **`DashboardDisplayModelBuilder.makeRooms(from:)`** — left unchanged (IOS-REF-001R)
- **`DashboardDisplayModelBuilder.makeZones(from:)`** — pure helper: flatten `zonesByBridge` values → localized alphabetical sort by name → ID-only de-duplication
- **`UnifiedOrchestrator.rebuildAllZones()`** — composition delegates to `makeZones(from:)`; navigation buffering and `scheduleWidgetWrite()` remain orchestrator-only
- **`HueHomeTests/DashboardDisplayModelBuilderTests.swift`** — seven zone contract tests mirroring room coverage

### Preserved behavior
- Navigation buffering (`isNavigating` / `sseRebuildPendingZones`)
- Widget/watch snapshot scheduling via `scheduleWidgetWrite()` (orchestrator-only)
- ID-only de-duplication (not `(bridgeID, id)`)
- Localized ascending name sort before dedupe
- `rebuildAllRooms()`, `scheduleWidgetWrite()`, `updateRoom(...)` untouched

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- `xcodebuild -project HueHome.xcodeproj -target HueHomeTests -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build` → **BUILD FAILED** (pre-existing: `LightShadeWatchApp Watch App` `AppIcon` asset catalog has no applicable content for iOS Simulator)
- Focused `xcodebuild test` → **blocked**: shared scheme `HueHome 1` has `<TestAction shouldAutocreateTestPlan="YES">` but no `<Testables>` entries (unchanged per task scope)
- `git diff --check` → clean
- Prohibited files (`project.pbxproj`, `RoomDisplayItem.swift`, etc.) → **no diff**

### Physical-device smoke (Brian)
1. Open **`HueHome.xcodeproj`**, scheme **`HueHome 1`**, physical iPhone
2. **Product → Clean Build Folder → Run**
3. **More → Settings** footer: branch `ios-ref/dashboard-zone-builder`, SHA matches `git rev-parse --short HEAD`
4. Dashboard: no crash; room cards correct; zone section/cards if configured
5. Zone cards alphabetically ordered; no duplicate zone cards
6. Zone detail (if supported) → back; toggle zone if supported; force quit → relaunch
7. Multi-bridge (if available): zones from both bridges, no duplicate IDs
8. Widget (if installed): room state still updates after a room action

### Manual test run (Xcode)
- Test navigator (⌘6) → `DashboardDisplayModelBuilderTests` → run zone tests after app build

### What's next
- [ ] **IOS-REF-003** (optional) — shared flatten/sort/dedupe helper if a third dashboard list seam appears; not required while duplication stays bounded

### Current state
IOS-REF-002 complete on branch `ios-ref/dashboard-zone-builder`. Behavior-neutral zone-list strangler seam; orchestrator remains facade. Not committed unless requested.

---

## 2026-06-01 — Shared HueHome Unit-Test Scheme Configuration (IOS-TEST-001A)

### What was built
- **Branch:** `ios-test/configure-huehome-tests`
- **Starting SHA:** `7e16095`
- **Existing scheme gap:** shared `HueHome 1` had `<TestAction shouldAutocreateTestPlan="YES">` with no `<Testables>` entries — Xcode reported “no scheme and/or test plan that contains every test you are trying to run”
- **`HueHomeTests` added to shared scheme TestAction** — `BlueprintIdentifier = F28E742458072F94D9443FF7`, `BuildableName = HueHomeTests.xctest`
- **Production build action unchanged** — `BuildAction` still lists only `HueHome.app`
- **`project.pbxproj` unchanged**

### Validation
- `xmllint --noout` on `HueHome 1.xcscheme` → **valid**
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- **Test discovery:** `xcodebuild test` dependency graph includes `HueHomeTests`; `-only-testing:HueHomeTests/DashboardDisplayModelBuilderTests` accepted — missing `<Testables>` / “no scheme and/or test plan” error **resolved**
- **Focused test execution:** `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HueHomeTests/DashboardDisplayModelBuilderTests` → **TEST FAILED** (build): `HueHomeTests` — “Cannot code sign because the target does not have an Info.plist file” (`GENERATE_INFOPLIST_FILE` not set on test target; **out of IOS-TEST-001A scope** — needs `project.pbxproj` or follow-up)
- **Watch AppIcon blocker (still present on direct test-target simulator build):** `LightShadeWatchApp Watch App/Assets.xcassets` — AppIcon did not have any applicable content for iOS Simulator when building `-target HueHomeTests -sdk iphonesimulator` — **not fixed in IOS-TEST-001A**

### Follow-up
- [ ] **IOS-TEST-001B** — unblock simulator test runs (watch AppIcon / embed graph) without broadening god-object extraction scope

### Current state
IOS-TEST-001A complete on branch `ios-test/configure-huehome-tests`. Scheme testable wired; no production or pbxproj edits. Not committed unless requested.

---

## 2026-06-01 — Generated HueHomeTests Info.plist (IOS-TEST-001B)

### What was built
- **Branch:** `ios-test/generate-huehome-tests-infoplist`
- **Starting SHA:** `5080279`
- **`HueHomeTests` Debug (`04AA42E47C3895B901BFC504`)** — added `GENERATE_INFOPLIST_FILE = YES`
- **`HueHomeTests` Release (`23C04301B398D3D9D7657757`)** — added `GENERATE_INFOPLIST_FILE = YES`
- **No production build settings changed** — only the two HueHomeTests configuration blocks above
- **No Swift code changed** — `HueHome/` and `HueHomeTests/` untouched

### Validation
- `git diff --check` → **clean**
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- **Focused simulator test:** `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HueHomeTests/DashboardDisplayModelBuilderTests` → **TEST FAILED** (build): Swift compile errors in `HueHomeTests` (not Info.plist)
- **Info.plist blocker:** **resolved** — `ProcessInfoPlistFile` generates `HueHomeTests.xctest/Info.plist`; no “Cannot code sign because the target does not have an Info.plist file” error
- **Watch AppIcon blocker:** **not observed** on this scheme-based simulator test run (watch targets built; no AppIcon asset-catalog failure)

### Next blocker
- **`KeychainManagerTests.swift:12`** — `'KeychainManager' initializer is inaccessible due to 'private' protection level`
- **`HueAPIClientTests.swift:58`** — `overriding declaration requires an 'override' keyword` on `TestableAPIClient.init`

### Follow-up
- [x] **IOS-TEST-001C** (or test-source fix slice) — repair stale `HueHomeTests` compile errors so focused `DashboardDisplayModelBuilderTests` can run (out of IOS-TEST-001B scope)

### Current state
IOS-TEST-001B complete on branch `ios-test/generate-huehome-tests-infoplist`. Two generated-plist settings only; not committed unless requested.

---

## 2026-06-01 — Repair stale HueHomeTests compile errors (IOS-TEST-001C)

### What was built
- **`HueHomeTests/KeychainManagerTests.swift`** — use `KeychainManager.shared` instead of `KeychainManager()` (production init is `private`)
- **`HueHomeTests/HueAPIClientTests.swift`** — mark `TestableAPIClient.init(ip:token:)` as `override` and call `super.init(ip:token:)` to match production `HueAPIClient.init(ip:token:)`
- **No production Swift changed** — `HueHome/` untouched
- **No pbxproj / scheme / asset changes**

### Validation
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HueHomeTests/DashboardDisplayModelBuilderTests test CODE_SIGNING_ALLOWED=NO` → **TEST SUCCEEDED** (14/14 cases)
- Prior compile blockers (`KeychainManagerTests:12`, `HueAPIClientTests:58`) → **resolved**

### What's left
- [ ] Commit IOS-TEST-001C slice when requested
- [ ] Remaining HueHomeTests suites (Orchestrator, HueAPIClient, Keychain, etc.) not run in this focused validation

### Current state
IOS-TEST-001C complete locally. Test-only diff (2 files + DEVLOG); not committed unless requested.

---

## 2026-06-01 — Signed Simulator Runtime Test Repair (IOS-TEST-001D)

### Context
- **Branch:** `ios-test/repair-simulator-runtime-tests`
- **Starting SHA:** `1038a6a`
- Prior full-suite baseline on unsigned simulator runs (`CODE_SIGNING_ALLOWED=NO`): **60 passed / 8 failed / 68** (7× `errSecMissingEntitlement` in `KeychainManagerTests`, 1× stale `HueAPIClientTests.testMissingCredentialsThrowsCorrectError` expecting `missingCredentials` but receiving `httpError(404)`)

### Signed simulator baseline (before edit)
- Destination: `platform=iOS Simulator,name=iPhone 17 Pro` (no `CODE_SIGNING_ALLOWED=NO`)
- **Keychain entitlement failures:** disappeared — all 7 `KeychainManagerTests` passed
- **Remaining failure:** `HueAPIClientTests.testMissingCredentialsThrowsCorrectError` only
- Full `HueHomeTests`: **67 passed / 1 failed / 68**

### Fix (test-only)
- **`HueHomeTests/HueAPIClientTests.swift`** — `TestableAPIClient.credentials()` now rejects empty `stubIP` / `stubToken` with `HueAPIError.missingCredentials`, matching production `HueAPIClient.credentials()` semantics (no production Swift change)

### Validation (after edit)
- Shell: `Scripts/tests/test_inject_build_metadata.sh` → **21/21 PASS**; `Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 PASS**
- Generic unsigned app build (`CODE_SIGNING_ALLOWED=NO`, `generic/platform=iOS`) → **BUILD SUCCEEDED**
- Focused: `HueHomeTests/DashboardDisplayModelBuilderTests` (signed simulator) → **TEST SUCCEEDED** (14/14)
- Full: `HueHomeTests` (signed simulator) → **TEST SUCCEEDED** (68/68)

### Keychain isolation review (recommendation)
- `KeychainManagerTests` use production legacy keys (`hue_api_token`, `hue_bridge_ip`) via `saveAPIToken` / `saveBridgeIP` — not the per-test `tokenKey` / `ipKey` helpers (those apply only to generic `save(for:)` tests). Consider a follow-up harness slice to namespace test credentials or inject a test-only service name without touching production `KeychainManager` until approved.

### Current state
IOS-TEST-001D test-only slice ready for commit when requested. No production Keychain, entitlements, or pbxproj changes.

---

## 2026-06-02 — UnifiedOrchestrator Pure-Seam Inventory (IOS-REF-003A)

### What was done
- Branch: `ios-ref/orchestrator-pure-seam-inventory`
- Starting SHA: `4db4b68`
- Scope: documentation-only inventory of `UnifiedOrchestrator.swift` responsibilities, state surface, and side-effect boundaries.
- Added `docs/ios/unified-orchestrator-pure-seam-inventory.md` describing public/private state, responsibility map, classifications, and candidate pure seams.
- Recorded the existence of the previously extracted dashboard room/zone builder seam (`DashboardDisplayModelBuilder`) and its tests (`DashboardDisplayModelBuilderTests`).

### Baseline and tests
- Existing automated baseline (from IOS-TEST-001D): `DashboardDisplayModelBuilderTests` → 14/14 pass.
- Existing full `HueHomeTests` suite baseline: 68/68 pass on signed simulator.
- No new tests were added or run for IOS-REF-003A; this slice is docs-only.

### Recommended next refactor (IOS-REF-003B)
- Proposed task ID: `IOS-REF-003B`.
- Recommended seam: extract the room and zone display-model composition logic from `UnifiedOrchestrator.fetchAndMergeAllBridges()` into a pure helper (proposed `RoomAndZoneDisplayModelBuilder` under `HueHome/Core/Dashboard/`).
- Delegation point: the loops that build `RoomDisplayItem`/zone `RoomDisplayItem` values and light-to-room/zone maps from `rooms`, `zones`, `lights`, and `groupedLights` (currently around lines 606–751).
- Expected behavior: no change to network calls, SSE lifecycle, optimistic updates, rollback semantics, persistence, or widgets/watch; only pure transformation code moves behind a helper.

### Deferred high-risk areas
- SSE connection coordination and event application (`startSSE`, `stopSSE`, `runSSE`, `applySSEEvent`).
- Pending-action deadline logic and optimistic mutation/rollback for rooms and zones.
- All-day scenes scheduler and `UserDefaults`-backed anchors.
- Widget/watch snapshot writing and App Group payload shape.
- Bridge registry lifecycle and multi-bridge routing (`configure`, `addBridge`, `removeBridge`).
- Studio/Composer entertainment routing, bridge-stored animation, and Keychain/SwiftData/App Group contracts.

### Constraints for this slice
- No Swift files modified.
- No Xcode project files modified.
- No changes to networking, Hue API behavior, SSE cadence, optimistic updates, rollback, persistence, widgets, watch, or Studio/Composer runtime behavior.
- No new builds or physical-device tests required for IOS-REF-003A (documentation-only).

---

## 2026-06-02 — Room and Zone Display-Model Builder Extraction (IOS-REF-003B)

### What was built
- **Branch:** `ios-ref/room-zone-display-model-builder`
- **Starting SHA:** `6ebb0c3`
- Added pure helper: `HueHome/Core/Dashboard/RoomAndZoneDisplayModelBuilder.swift`
- Added focused tests: `HueHomeTests/RoomAndZoneDisplayModelBuilderTests.swift`
- `UnifiedOrchestrator.fetchAndMergeAllBridges()` now delegates deterministic room/zone model construction to `RoomAndZoneDisplayModelBuilder.makeDisplayModels(rooms:zones:lights:groupedLights:bridgeID:)` after the existing async fetches complete.

### Behavior preserved
- Networking behavior preserved (same per-bridge parallel `fetchRooms/fetchZones/fetchLights/fetchGroupedLights` pattern).
- Bridge routing preserved (orchestrator still iterates `clients` and merges per bridge).
- Outer state writes preserved in orchestrator (`roomsByBridge`, `zonesByBridge`, `lightIDToRoomID`, `lightIDToZoneID`, `connectionStatus`).
- SSE behavior preserved (`startSSE`/`applySSEEvent` paths untouched).
- Cache behavior preserved (`loadAll` / `writeCache` flow unchanged).
- Widget/watch write scheduling preserved (`rebuildAllRooms()`, `rebuildAllZones()`, `scheduleWidgetWrite()` unchanged).

### New focused tests
- Empty input returns empty rooms/zones/maps.
- Room model contract (name/archetype/kind/bridgeID/grouped light/child refs/isOn/brightness).
- Zone model contract (name/archetype/kind/bridgeID/grouped light/child refs/isOn/brightness).
- Room map semantics including room device-owner fallback behavior.
- Zone map semantics with direct light refs.
- Overlap behavior (same light can appear in room and zone maps).
- Dominant visual-state behavior (brightest ON color, mirek fallback, grouped-off fallback).
- Input immutability.

### Validation
- Signed simulator results: **pending local run in this slice**
- Generic unsigned app build result: **pending local run in this slice**

### Physical-device smoke instructions
1. Open `HueHome.xcodeproj`
2. Scheme: `HueHome 1`
3. Destination: physical iPhone
4. Product → Clean Build Folder
5. Product → Run
6. Verify dashboard and room/zone behaviors match pre-extraction baseline.

### Follow-up recommendation
- Keep future seams similarly bounded and pure (state-only transforms first, orchestration remains facade).

---

## 2026-06-02 — Composer Cadence Pure-Seam Inventory (IOS-REF-004A)

### What was done
- Branch: `ios-ref/composer-cadence-seam-inventory`
- Starting SHA: `bc1cbbc`
- Scope: documentation-only inventory of the next bounded pure `UnifiedOrchestrator` seam after IOS-REF-003B.
- Added inventory doc: `docs/ios/composer-cadence-pure-seam-inventory.md`

### Baseline and context
- Current validated baseline (project-tracked): signed-simulator `HueHomeTests` 74/74 pass.
- Prior extraction baseline acknowledged: IOS-REF-003B merged to `main`.
- IOS-REF-003B physical-device smoke: passed.

### Recommendation
- Cadence scalar quartet (`minimumComposerRESTInterval`, `minimumComposerBurstFloor`, `preferredComposerIdleInterval`, `lowPowerIdleInterval`) is PURE but currently has zero call sites.
- No IOS-REF-004B production extraction should proceed for this quartet; extracting unwired helpers would move dead-code-like logic without reducing live orchestrator runtime responsibility.
- `CompositionTier` is accepted by the quartet but currently does not affect outputs.
- Live REST scheduling remains driven by fixed cadence behavior inside `runCompositionScheduler()` (`tickInterval` + `nextDueAt` updates), not by the unwired quartet.
- Do not wire the quartet into scheduler paths as part of this refactor.
- Do not delete the quartet in this docs-only slice.
- Optional later dead-code cleanup may evaluate deletion only after explicit approval and Composer smoke planning.

### Recommended next docs-only task
- `IOS-REF-005A — Inventory a live pure scoring sub-helper inside nextCompositionRoomPriority(now:)`

### Deferred high-risk Composer areas
- Scheduler loop behavior and task timing (`runCompositionScheduler`, `runCompositionEntertainment`).
- Room-priority selection and runtime mutation (`nextCompositionRoomPriority`, `compositionRuntimes` lifecycle).
- REST mailbox behavior, DTLS routing, bridge-stored animation routing, and mic-demand orchestration.

### Constraints for this slice
- No Swift changes.
- No project-file changes.
- No physical-device test required for this docs-only slice.

---

## 2026-06-02 — Composer Light Resolver Extraction (IOS-REF-006B)

### What was done
- Branch: `ios-ref/composer-light-resolver`
- Starting SHA: `27d6a16`
- Added pure helper: `HueHome/Core/Composer/CompositionLightResolver.swift`
- Added focused tests: `HueHomeTests/CompositionLightResolverTests.swift`
- Delegated deterministic child-resource resolution from:
  - `resolveCompositionGamut(for:api:)`
  - `resolveCompositionLightIDs(for:api:)`
  in `HueHome/Core/Network/UnifiedOrchestrator.swift`

### Preserved behavior contract
- Direct-light precedence preserved: any `rtype == "light"` still short-circuits mixed refs to direct mode.
- ID direct mode preserved: ref order and duplicates preserved; non-light refs ignored.
- Gamut-path light resolution preserved: direct mode still uses set-membership against fetched lights and returns fetched-light order.
- Owner fallback preserved for both paths via `light.owner?.rid` matching.
- Conditional fetch behavior preserved:
  - gamut path still always fetches lights
  - light-ID direct mode still bypasses fetch
  - light-ID owner fallback still fetches lights
- Fetch-failure fallbacks preserved in orchestrator:
  - gamut -> `.c`
  - owner-ID path -> `[]`
- Gamut majority selection and implicit tie behavior left inline and unchanged.
- `resolveEntertainmentLightPositions(config:api:)` left untouched.

### Focused test coverage added
- `CompositionLightResolverTests` covers:
  - direct-mode detection (`false/true/mixed`)
  - direct ID semantics (order, duplicates, mixed refs, empty lights)
  - direct light resolution semantics (fetched-light ordering, deduplicated membership, omitted missing refs, mixed-ref precedence)
  - owner fallback semantics (owner matching, fetched-light order, duplicate-device refs, non-matching and nil-owner omission)
  - edge cases (empty refs/lights, non-matching refs, determinism, input immutability)

### Validation plan/results
- Existing pure-seam baselines expected unchanged:
  - `CompositionRoomPriorityScorerTests` target: 19/19
  - `RoomAndZoneDisplayModelBuilderTests` target: 6/6
  - `DashboardDisplayModelBuilderTests` target: 14/14
- Full signed-simulator suite target: prior 93 tests plus new resolver tests, all passing.
- Generic unsigned app build target: `BUILD SUCCEEDED`.
- Shell metadata tests expected unchanged:
  - Injector tests -> 21/21 PASS
  - Verifier tests -> 17/17 PASS

### Physical-device Composer smoke instructions
- Open `HueHome.xcodeproj`
- Scheme: `HueHome 1`
- Destination: physical iPhone
- Product -> Clean Build Folder
- Product -> Run
- Verify Settings footer first:
  - Branch `ios-ref/composer-light-resolver`
  - Working tree modified
- Then verify normal Composer flow:
  - app launch + dashboard render
  - Composer start/stop/restart responsiveness
  - expected lights animate/update with no unexpected toasts or stuck UI
  - direct-light and mixed-ref topologies (if available) preserve visible behavior
  - REST-vs-entertainment routing remains unchanged
  - force-quit + relaunch + re-run Composer

### Follow-up recommendation
- Keep any future light-resolution slices narrowly scoped:
  - leave network/credentials/JSON/routing in `UnifiedOrchestrator`
  - pin gamut tie behavior in a dedicated slice before extracting gamut-majority logic.

---

## 2026-06-02 — Composer Priority-Scoring Pure-Seam Inventory (IOS-REF-005A)

### What was done
- Branch: `ios-ref/composer-priority-scoring-inventory`
- Starting SHA: `cb01e11`
- Scope: documentation-only inventory for extracting a bounded live pure scoring helper from `nextCompositionRoomPriority(now:)`.
- Added inventory doc: `docs/ios/composer-priority-scoring-pure-seam-inventory.md`

### Baseline and prior decisions acknowledged
- Current validated baseline: signed-simulator `HueHomeTests` 74/74 pass.
- IOS-REF-003B physical-device dashboard/room/zone smoke: passed.
- IOS-REF-004A decision acknowledged: cadence quartet remains pure but unwired, with no IOS-REF-004B extraction recommended.

### Findings
- `nextCompositionRoomPriority(now:)` is confirmed live (called by `runCompositionScheduler()`).
- A value-only score sub-helper is recommended for IOS-REF-005B, with orchestrator-owned iteration/tie-breaking preserved unchanged.
- Score logic is deterministic and value-only; no network I/O, SSE, Task creation/cancellation, persistence, or routing decisions inside scoring.

### Deferred high-risk Composer areas
- Scheduler cadence/tick behavior and runtime mutation timing in `runCompositionScheduler()`.
- REST mailbox semantics (`studioRestSender`) and generation guard lifecycle.
- Transport routing (bridge-stored vs entertainment vs REST) and mic-demand orchestration.

### Constraints for this slice
- No Swift changes.
- No project-file changes.
- No physical-device testing required for this docs-only slice.

---

## 2026-06-02 — Composer Room-Priority Scorer Extraction (IOS-REF-005B)

### What was done
- Branch: `ios-ref/composer-priority-scorer`
- Starting SHA: `3d8ee2f`
- Added pure scorer helper: `HueHome/Core/Composer/CompositionRoomPriorityScorer.swift`
- Added focused tests: `HueHomeTests/CompositionRoomPriorityScorerTests.swift`
- Delegated only the eligibility-and-score block inside `nextCompositionRoomPriority(now:)` in `HueHome/Core/Network/UnifiedOrchestrator.swift`
- Preserved orchestrator-owned `compositionOrder` traversal and strict `score > selectedScore` tie-breaking.

### Preserved behavior contract
- Due-gate grace preserved exactly: `now + 0.004 < nextDueAt` ineligible.
- Numeric score terms/formulas preserved exactly:
  - `+1000` interaction
  - `+500` interaction burst
  - `+260` pending settle
  - `+min(220, overdue * 120)`
  - `+min(160, max(0, sinceLastSend - 1.4) * 45)`
  - `-min(60, Double(sendCount % 120) * 0.35)`
- Scheduler cadence unchanged (`tickInterval` and `nextDueAt` write path unchanged).
- REST mailbox behavior unchanged (`studioRestSender` usage unchanged).
- Runtime mutation timing unchanged (writes still in `runCompositionScheduler()` after selection).
- Transport routing unchanged (REST vs entertainment paths untouched).

### Test and validation notes
- Focused scorer tests cover due gate, all term contributions/caps, fallback semantics, modulo fairness rollover, combined score, determinism, and input immutability.
- Existing builder baselines remain expected:
  - `DashboardDisplayModelBuilderTests` 14/14 pass target.
  - `RoomAndZoneDisplayModelBuilderTests` 6/6 pass target.
- Full signed-simulator `HueHomeTests` baseline remains expected to include prior 74 plus new scorer tests.
- Generic unsigned app build target remains `BUILD SUCCEEDED`.

### Physical-device Composer smoke instructions
- Open `HueHome.xcodeproj`
- Scheme: `HueHome 1`
- Destination: physical iPhone
- Product -> Clean Build Folder
- Product -> Run
- In app, verify Settings footer shows:
  - Branch `ios-ref/composer-priority-scorer`
  - Working tree modified
- Then verify:
  - App launches without crash
  - Dashboard opens normally
  - Studio/Composer start/stop remains responsive
  - Multi-room interaction remains responsive with no starvation, stuck UI, or unexpected toast
  - Transport behavior remains unchanged (REST vs entertainment path)
  - Force quit, relaunch, and re-verify dashboard + Composer responsiveness

### Follow-up recommendation
- Keep future Composer refactors bounded to pure value helpers first, leaving scheduler ownership and runtime mutation timing in `UnifiedOrchestrator`.

---

## 2026-06-02 — Composer Light-Resolution Pure-Seam Inventory (IOS-REF-006A)

### What was done
- Branch: `ios-ref/composer-light-resolution-inventory`
- Starting SHA: `93a3584`
- Scope: documentation-only inventory for live Composer light-resolution seams in `UnifiedOrchestrator`.
- Added inventory doc: `docs/ios/composer-light-resolution-pure-seam-inventory.md`
- Inspected live methods:
  - `resolveCompositionGamut(for:api:)`
  - `resolveCompositionLightIDs(for:api:)`
  - `resolveEntertainmentLightPositions(config:api:)`
  - plus caller `startCompositionMode(...)`

### Baseline and prior context acknowledged
- Current validated baseline: full signed-simulator `HueHomeTests` 93/93 pass.
- IOS-REF-005B physical-device Composer smoke: passed.
- Prior extracted seams acknowledged (IOS-REF-001R / IOS-REF-002 / IOS-REF-003B / IOS-REF-005B).

### Recommendation
- Recommend one narrow IOS-REF-006B production extraction: shared value-only child-resource light resolution helper reused by gamut/light-ID methods.
- Keep all fetches, credentials access, JSON payload parsing, routing, and runtime mutation inside `UnifiedOrchestrator`.
- Keep gamut majority selection inline for IOS-REF-006B because tie behavior is currently implicit and should not be changed during this slice.

### Behavioral constraints captured
- Direct `rtype == "light"` semantics, owner fallback semantics, mixed-ref precedence, and empty-input behavior documented.
- Ordering/duplicate constraints documented:
  - direct-ref ID order and duplicate preservation
  - owner-path dependence on fetched light-array order
  - entertainment map duplicate overwrite behavior (last-write-wins across mapping layers)
- Fallback constraints documented:
  - gamut: `.c` fallbacks
  - light IDs: `[]` fallbacks
  - entertainment positions: `[:]` fallbacks

### Deferred high-risk areas
- Network access, credentials handling, and raw JSON parsing remain deferred.
- Transport and bridge routing behavior remains deferred.
- Scheduler cadence, mailbox behavior, generation guards, and runtime mutation remain deferred.

### Constraints for this slice
- No Swift changes.
- No project-file changes.
- No physical-device test required for this docs-only slice.

---

## 2026-06-02 — Composer Fetch-Path Parity Coverage Inventory (IOS-TEST-002A)

### Scope
- Branch: `ios-test/composer-fetch-path-parity-inventory`
- Starting SHA: `87432b3`
- Documentation-only; no Swift, no Xcode project, no commit/push

### Deliverable
- New inventory: `docs/ios/composer-fetch-path-parity-test-inventory.md`

### Baseline referenced
- `CompositionLightResolverTests` → 16/16
- `CompositionRoomPriorityScorerTests` → 19/19
- `RoomAndZoneDisplayModelBuilderTests` → 6/6
- `DashboardDisplayModelBuilderTests` → 14/14
- Signed-simulator `HueHomeTests` → 109/109
- IOS-REF-006B physical-device Composer smoke pass (prior entry)

### Fetch-path contracts inventoried
- `resolveCompositionGamut(for:api:)` — always one `fetchLights()`; failure or empty resolved lights → `.c`; majority gamut inline
- `resolveCompositionLightIDs(for:api:)` — empty refs → `[]` / 0 fetches; direct-light mode → 0 fetches; owner path → 1 fetch or `[]` on failure
- Pure matching delegated to `CompositionLightResolver` (IOS-REF-006B)

### Test-infrastructure findings
- `StubURLProtocol` + `TestableAPIClient` exist in `HueHomeTests/HueAPIClientTests.swift` (in target)
- `injectForTesting` is `#if DEBUG` in `UnifiedOrchestrator`
- Private fetch helpers are not `@testable`-accessible; `testApplySSEEvent` works only because `applySSEEvent` is `internal`
- `OrchestratorTests.swift` exists on disk (15 tests) but is not in `HueHome.xcodeproj` — explains 109 on-disk test methods in target vs 124 total in folder
- Spy subclass overriding `fetchLights()` is viable (`HueAPIClient` is non-`final`)

### IOS-TEST-002B recommendation
- Proceed: `#if DEBUG` wrappers `testResolveCompositionGamut` / `testResolveCompositionLightIDs`, new `ComposerFetchPathParityTests.swift` with fetch-counting spy, pbxproj membership
- Reject for this slice: `startCompositionMode` integration tests, `private`→`internal` widening, production fetch-policy helper, URLProtocol-only counting, source-text assertions
- Physical-device testing not required for IOS-TEST-002B unit slice

### Validation
- No Xcode build run (docs-only)
- No physical-device test required for this slice

---

## 2026-06-02 — Composer Fetch-Path Parity Tests (IOS-TEST-002B)

### Scope
- Branch: `ios-test/composer-fetch-path-parity-tests`
- Starting SHA: `6139154`
- DEBUG-only forward wrappers around existing private `resolveCompositionGamut(for:api:)` and `resolveCompositionLightIDs(for:api:)` in `UnifiedOrchestrator`
- New test file: `HueHomeTests/ComposerFetchPathParityTests.swift`
- Test-only `ComposerFetchCountingAPIClient` spy (`override fetchLights()`)
- Inventory count correction: IOS-TEST-002A matrix lists **9** core cases (5 ID + 4 GAM), not 8
- Private production method bodies unchanged; release behavior unchanged
- `OrchestratorTests.swift` orphan membership intentionally deferred

### Parity cases (9)
- ID-01 empty refs → 0 fetches, `[]`
- ID-02 direct refs → 0 fetches, order + duplicates preserved
- ID-03 mixed refs → 0 fetches, direct IDs only
- ID-04 owner fallback success → 1 fetch, fetched-light order
- ID-05 owner fallback failure → 1 fetch, `[]`
- GAM-01 direct refs majority → 1 fetch, `.a`
- GAM-02 owner fallback majority → 1 fetch, `.b`
- GAM-03 fetch failure → 1 fetch, `.c`
- GAM-04 empty resolved lights → 1 fetch, `.c`

### Validation results
- Injector shell tests → 21/21 PASS
- Verifier shell tests → 17/17 PASS
- Generic unsigned Debug app build → BUILD SUCCEEDED
- Generic unsigned Release app build → BUILD SUCCEEDED
- `ComposerFetchPathParityTests` → 9/9 PASS
- `CompositionLightResolverTests` → 16/16 PASS
- `CompositionRoomPriorityScorerTests` → 19/19 PASS
- `RoomAndZoneDisplayModelBuilderTests` → 6/6 PASS
- `DashboardDisplayModelBuilderTests` → 14/14 PASS
- Full signed-simulator `HueHomeTests` → 118/118 PASS
- No physical-device test required for this slice

### Follow-up
- Optional hygiene slice: register orphaned `OrchestratorTests.swift` in `HueHomeTests` target (15 tests on disk, not in pbxproj)
- Defer gamut tie-break policy pinning until product defines explicit rules

---

## 2026-06-02 — OrchestratorTests Target-Membership Repair Inventory (IOS-TEST-003A)

### Scope
- Branch: `ios-test/orchestrator-tests-membership-inventory`
- Starting SHA: `c1d5917`
- Documentation-only — no Swift, no Xcode project, no target membership changes
- New inventory: `docs/ios/orchestrator-tests-membership-repair-inventory.md`

### Baseline
- Full signed-simulator `HueHomeTests` → **118/118** pass (unchanged)
- `HueHomeTests/OrchestratorTests.swift` tracked on disk but **absent** from `HueHome.xcodeproj` Sources

### Findings
- Exact orphan XCTest method count: **14** (earlier **15** estimate incorrect — counted helper or stale handoff)
- Confirmed compile blockers: `BridgeAPIClient` `final` prevents `TestableBridgeAPIClient` subclass; `testApplySSEEvent` shim return-type mismatch; `turnAllOff()` `async` without `await` in test
- Runtime/fixture drift: missing `/clip/v2/resource/zone` stub breaks all `loadAll` success paths; entertainment cleanup GET unstubbed
- Concurrency: shared `StubURLProtocol.stubs` **not safe** under scheme `parallelizable="YES"` when multiple stub-using classes run together
- `applySSEEvent` already **internal** — orphan shim redundant (and invalid as written)

### Recommended IOS-TEST-003B slice
- **IOS-TEST-003B — Orchestrator cache + demo offline recovery (4 tests)**
- New file `OrchestratorCacheDemoTests.swift` — preloadCached ×3 + demo-mode loadAll ×1
- No production edits; no `BridgeAPIClient` finality change; defer remaining 10 orphan tests to B2–B4

### Validation
- No Xcode build run (docs-only)
- No physical-device test required for this slice

---

## 2026-06-02 — Orchestrator Cache + Demo Offline Recovery (IOS-TEST-003B)

### Scope
- Branch: `ios-test/orchestrator-cache-demo-tests`
- Starting SHA: `ae20fff`
- New test file: `HueHomeTests/OrchestratorCacheDemoTests.swift`
- Recovered tests (4): `testPreloadCached_populatesAllRooms`, `testPreloadCached_sortsAlphabetically`, `testPreloadCached_emptyInput_leavesAllRoomsEmpty`, `testDemoMode_loadAll_doesNotMakeNetworkRequests`
- No production Swift changes
- No orphan-file edits (`HueHomeTests/OrchestratorTests.swift` remains off-target)
- No `BridgeAPIClient` finality change
- No networking fixtures, `StubURLProtocol`, or client injection
- No shared URLProtocol state
- No scheme parallelization changes

### Validation
- Focused signed-simulator `OrchestratorCacheDemoTests` → **4/4** PASS
- Full signed-simulator `HueHomeTests` → **122/122** PASS (118 baseline + 4 new)
- Generic unsigned Debug build → **BUILD SUCCEEDED**
- Generic unsigned Release build → **BUILD SUCCEEDED**
- Shell injector tests → **21/21** PASS
- Shell verifier tests → **17/17** PASS
- No physical-device test required for this slice

### Deferred
- **IOS-TEST-003B2** — `loadAll` harness recovery (4 orphan tests; zone stub + compile repair for `TestableBridgeAPIClient` subclass blocker)

---

## 2026-06-02 — Orchestrator loadAll Harness Repair Inventory (IOS-TEST-003B2A)

### Scope
- Branch: `ios-test/orchestrator-loadall-harness-inventory`
- Starting SHA: `507e278`
- Documentation-only — no Swift, no Xcode project, no test implementation
- New inventory: `docs/ios/orchestrator-loadall-harness-repair-inventory.md`

### Baseline
- Full signed-simulator `HueHomeTests` → **122/122** pass (unchanged)
- `OrchestratorCacheDemoTests` → **4/4** pass
- Four deferred `loadAll()` orphan tests inventoried (remain in off-target `OrchestratorTests.swift`)

### Findings
- `BridgeAPIClient` is `final` — blocks orphan `TestableBridgeAPIClient` subclass; **declaration-only `final` removal required for B2**
- Recommended **IOS-TEST-003B2 Strategy A**: typed test-only spy in new `OrchestratorLoadAllTests.swift`; reuse existing `#if DEBUG injectForTesting(clients:)`
- **Avoid URLProtocol** — shared `StubURLProtocol.stubs` not parallel-safe under scheme `parallelizable="YES"`
- **Cleanup GET must be stubbed explicitly** via spy `get()` override (empty entertainment list); cleanup PUT avoidable
- **`lastLoadedAt` is completion-based**, not success-only — assigned after outer task group even when per-bridge fetches fail
- Orphan fixtures stale: missing zone stub; malformed redundant path key in `Fixture.installLoadAll`
- No `UnifiedOrchestrator.swift` or `HueAPIClient.swift` changes required for bounded B2 slice

### Expected future B2 target
- Focused `OrchestratorLoadAllTests` → **4/4** pass
- Full signed-simulator `HueHomeTests` → **126/126** pass (122 + 4)

### Validation
- No Xcode build run (docs-only)
- No physical-device test required for this slice

---

## 2026-06-02 — Orchestrator loadAll Offline Recovery (IOS-TEST-003B2B)

### Scope
- Branch: `ios-test/orchestrator-loadall-tests`
- Starting SHA: `039f0e8`
- New test file: `HueHomeTests/OrchestratorLoadAllTests.swift`
- Four recovered `loadAll()` offline tests (LOAD-01 through LOAD-04)
- Production edit: `BridgeAPIClient` `final` removed (declaration-only; no method-body changes)
- Typed test-only spy `OrchestratorLoadAllSpyBridgeClient` — no URLProtocol, no shared static stubs, no Keychain, no real bridge access
- Cleanup GET handled explicitly (`{"errors":[],"data":[]}` for entertainment_configuration); cleanup PUT avoided
- `lastLoadedAt` completion-based behavior pinned on error path (LOAD-03); production comment mismatch noted here only (not edited in `UnifiedOrchestrator.swift`)
- Orphan `HueHomeTests/OrchestratorTests.swift` untouched and off-target

### Validation
- Focused `OrchestratorLoadAllTests` → **4/4** pass (iPhone 17 Pro simulator)
- Full signed-simulator `HueHomeTests` → **126/126** pass (122 + 4)
- Shell: `test_inject_build_metadata.sh` → **21/21** pass; `test_verify_built_app_metadata.sh` → **17/17** pass
- Generic unsigned Debug build → **BUILD SUCCEEDED**
- Generic unsigned Release build → **BUILD SUCCEEDED**
- `git diff --check` → clean
- No physical-device test required (declaration-only production diff)

### Warning cleanup (pre-commit)
- Removed `setUp()`/`tearDown()` from `OrchestratorLoadAllTests`; per-test `@MainActor makeOrchestratorLoadAllSUT()` eliminates 6 MainActor lifecycle warnings introduced by this slice
- Deferred: `OrchestratorCacheDemoTests` still uses shared `setUp()`/`tearDown()` with the same MainActor pattern (preexisting; not edited in B2B)

### Deferred
- **IOS-TEST-003B3** — optimistic-update + SSE recovery from orphan suite (6 tests)

## 2026-06-02 — Orchestrator Optimistic-Update Recovery Inventory (IOS-TEST-003B3A)

### Scope
- Branch: `ios-test/orchestrator-optimistic-update-inventory`
- Starting SHA: `a0f37be`
- Documentation-only — no Swift, no `project.pbxproj`, no build run

### Inventory
- New doc: `docs/ios/orchestrator-optimistic-update-recovery-inventory.md`
- Three orphan mutation tests inventoried: `testSetRoom_optimisticUpdate_flipsIsOnImmediately`, `testSetRoom_rollback_onAPIError`, `testTurnAllOff_setsAllRoomsOffBeforeAPICallsComplete` (`HueHomeTests/OrchestratorTests.swift`, off-target)
- Current signed-simulator baseline: **126/126** `HueHomeTests` pass

### Findings
- **preloadCached fixture seeding:** sufficient when `cachedGroupedLightID` + `bridgeID` set — avoids `loadAll()` for grouped-light routing (`UnifiedOrchestrator.swift:505-537`)
- **Typed spy:** `BridgeAPIClient` non-final (B2B); override `setGroupedLight` — no URLProtocol, no Keychain
- **Actor recorder + gate:** recommended for MUT-01/MUT-03; immediate-throw spy for MUT-02 rollback
- **Fixed sleep:** rejected (`Task.sleep(300ms)` in orphan rollback test)
- **scheduleStateRefresh:** success-path `setRoom` schedules +1.5s delayed `loadAll()` — avoid via API failure teardown in optimistic-before-completion test
- **turnAllOff:** production `async`; orphan test omits `await` — B3B must `Task { await turnAllOff() }`
- **Production / DEBUG hooks:** not required for bounded B3B slice

### Recommended next slice
- **IOS-TEST-003B3B** — new `HueHomeTests/OrchestratorOptimisticUpdateTests.swift` (3 tests) + `project.pbxproj` membership
- Expected after B3B: focused **3/3**; full signed-simulator **129/129** (126 + 3)
- SSE orphan tests remain **IOS-TEST-003B4** (separate)

### Hygiene
- Preexisting `OrchestratorCacheDemoTests` MainActor lifecycle warnings remain deferred
- B3B should use per-test `@MainActor` SUT factory (match `OrchestratorLoadAllTests`)
- No physical-device test required for this docs-only slice

---

## 2026-06-02 — Orchestrator Optimistic-Update Offline Recovery (IOS-TEST-003B3B)

### Scope
- Branch: `ios-test/orchestrator-optimistic-update-tests`
- Starting SHA: `f46b887`
- New test file: `HueHomeTests/OrchestratorOptimisticUpdateTests.swift`
- Three recovered mutation tests (MUT-01 through MUT-03)
- `preloadCached(from:)` fixture with `cachedGroupedLightID` — no `loadAll()` fixture setup
- Typed spy `OrchestratorOptimisticUpdateSpyBridgeClient` overrides `setGroupedLight` only
- Actor recorder `OrchestratorOptimisticUpdateRecorder` + gate `OrchestratorGroupedLightGate`
- Bounded eventual rollback helper (`waitUntil` + 10ms polling) — fixed sleeps rejected
- Per-test `@MainActor` SUT factory — no `setUp()`/`tearDown()` lifecycle overrides
- No URLProtocol, no Keychain, no real network, no production Swift changes
- Orphan `HueHomeTests/OrchestratorTests.swift` untouched and off-target

### Recovered tests
- `testSetRoom_appliesOptimisticState_beforeAPICallCompletes`
- `testSetRoom_rollsBack_afterAPIError`
- `testTurnAllOff_appliesOptimisticState_beforeAPICallsComplete`

### Validation
- Focused `OrchestratorOptimisticUpdateTests` → **3/3** pass (iPhone 17 Pro simulator)
- Full signed-simulator `HueHomeTests` → **129/129** pass (126 + 3)
- Shell: `test_inject_build_metadata.sh` → **21/21** pass; `test_verify_built_app_metadata.sh` → **17/17** pass
- Generic unsigned Debug build → **BUILD SUCCEEDED**
- Generic unsigned Release build → **BUILD SUCCEEDED**
- `git diff --check` → clean
- No new lifecycle MainActor warnings from `OrchestratorOptimisticUpdateTests.swift`
- Preexisting `OrchestratorCacheDemoTests` `setUp()`/`tearDown()` warnings remain deferred
- No physical-device test required

### Deferred
- **IOS-TEST-003B4** — SSE orphan tests + `applySSEEvent` access recovery

---

## 2026-06-02 — Orchestrator SSE Recovery Inventory (IOS-TEST-003B4A)

### Scope
- Branch: `ios-test/orchestrator-sse-inventory`
- Starting SHA: `359a667`
- Documentation-only — no Swift, no `project.pbxproj`, no build run

### Inventory
- New doc: `docs/ios/orchestrator-sse-recovery-inventory.md`
- Three orphan SSE tests inventoried: `testApplySSEEvent_groupedLight_updatesRoomState`, `testApplySSEEvent_malformedJSON_doesNotCrash`, `testApplySSEEvent_unknownType_doesNotMutateState` (`HueHomeTests/OrchestratorTests.swift`, off-target)
- Current signed-simulator baseline: **129/129** `HueHomeTests` pass

### Findings
- **`applySSEEvent` is `internal`** — orphan shim redundant; shim `Bool` return invalid vs production `(rooms: Bool, zones: Bool)`
- **Public rebuild gap:** reducer mutates `roomsByBridge` only; live `runSSE` calls conditional `rebuildAllRooms`/`rebuildAllZones`; grouped-light visible parity requires rebuild
- **Malformed JSON test is decoder-only** — does not exercise `runSSE` line parsing; pin `UnifiedOrchestrator.sseDecoder`
- **`HueSSEService` unwired** — no `HueHome/` call sites; orchestrator owns inline `runSSE`
- **`preloadCached` + `cachedGroupedLightID` sufficient** — avoids `loadAll`, URLProtocol, Keychain, network
- **Recommended IOS-TEST-003B4B:** new `OrchestratorSSETests.swift` (3 tests) + DEBUG-only `testApplySSEEventsAndRebuild` in `UnifiedOrchestrator.swift` + `project.pbxproj` membership
- Expected after B4B: focused **3/3**; full signed-simulator **132/132** (129 + 3)

### Hygiene
- Preexisting `OrchestratorCacheDemoTests` MainActor lifecycle warnings remain deferred
- B4B should use per-test `@MainActor` SUT factory (match `OrchestratorLoadAllTests` / `OrchestratorOptimisticUpdateTests`)
- No physical-device test required for this docs-only slice

---

## 2026-06-02 — Bounded Orchestrator SSE Offline Recovery (IOS-TEST-003B4B)

### Scope
- Branch: `ios-test/orchestrator-sse-tests`
- Starting SHA: `17f0176`
- New test path: `HueHomeTests/OrchestratorSSETests.swift` (3 tests)
- DEBUG-only `testApplySSEEventsAndRebuild` in existing `#if DEBUG` test-injection block (`UnifiedOrchestrator.swift`)
- Release behavior unchanged — wrapper not compiled in Release
- `preloadCached` fixture strategy with `cachedGroupedLightID = gl-001`, `bridgeID = bridge-1`
- `UnifiedOrchestrator.sseDecoder` reuse — no ad-hoc `JSONDecoder`
- No `loadAll` fixture setup, no URLProtocol, no Keychain, no real network
- No `startSSE` / `runSSE` / `stopSSE` invocation from tests
- Public rebuild-gap coverage via DEBUG wrapper (SSE-01); malformed JSON decoder-only boundary (SSE-02); direct `applySSEEvent` for unknown type (SSE-03)
- `HueSSEService` remains untouched and unwired
- Orphan `HueHomeTests/OrchestratorTests.swift` not registered; stale `testApplySSEEvent` shim not copied

### Validation
- Shell: metadata injector **21/21** PASS; verifier **17/17** PASS
- Generic unsigned Debug build: **BUILD SUCCEEDED**
- Generic unsigned Release build: **BUILD SUCCEEDED** (DEBUG wrapper not compiled)
- Focused signed-simulator `OrchestratorSSETests`: **3/3** PASS (iPhone 17 Pro)
- Full signed-simulator `HueHomeTests`: **132/132** PASS (129 + 3)
- No new warnings from `OrchestratorSSETests.swift`; preexisting `OrchestratorCacheDemoTests` lifecycle warnings unchanged

### Hygiene
- Per-test `@MainActor` SUT factory — no `setUp()`/`tearDown()`; no new lifecycle MainActor warnings
- Preexisting `OrchestratorCacheDemoTests` MainActor lifecycle warnings remain deferred
- No physical-device test required (DEBUG-only production edit)
- Deferred: live SSE line parsing, reconnect/backoff, `HueSSEService` consolidation, zone/light SSE, pending-action guard during SSE

---

## 2026-06-02 — Cache/Demo MainActor Warning Cleanup (IOS-TEST-003B5)

### Scope
- Branch: `ios-test/orchestrator-cache-demo-warning-cleanup`
- Starting SHA: `039cb9c`
- Warning-hygiene slice only — test code + DEVLOG; no production Swift, no Xcode project edits

### Lifecycle warning source
- `HueHomeTests/OrchestratorCacheDemoTests.swift` was `@MainActor` but stored a shared `orchestrator: UnifiedOrchestrator!` mutated from synchronous `setUp()` / `tearDown()` overrides (nonisolated XCTest lifecycle hooks)

### Cleanup
- Removed shared orchestrator property
- Removed synchronous `setUp()` / `tearDown()` overrides
- Added per-test `@MainActor` factory `makeOrchestratorCacheDemoSUT() -> UnifiedOrchestrator`
- Each of the four existing tests constructs a fresh local orchestrator; assertions and fixtures unchanged

### Test names (unchanged)
- `testPreloadCached_populatesAllRooms`
- `testPreloadCached_sortsAlphabetically`
- `testPreloadCached_emptyInput_leavesAllRoomsEmpty`
- `testDemoMode_loadAll_doesNotMakeNetworkRequests`

### Warning inventory — before cleanup
**FROM_ORCHESTRATOR_CACHE_DEMO_TESTS**
- `OrchestratorCacheDemoTests.swift:12:9` — main actor-isolated property `orchestrator` can not be mutated from a nonisolated context (`setUp`)
- `OrchestratorCacheDemoTests.swift:12:24` — call to main actor-isolated initializer `init()` in a synchronous nonisolated context (`setUp`)
- `OrchestratorCacheDemoTests.swift:16:9` — main actor-isolated property `orchestrator` can not be mutated from a nonisolated context (`tearDown`)

**UNRELATED_PREEXISTING** (unchanged; not edited)
- Watch target: `WatchStore.swift`, `WatchWidgetStore.swift` MainActor / Codable warnings
- App icon asset unassigned-child warnings
- Production Swift 6 concurrency warnings (`StudioView`, `DashboardView`, `BridgeAnimationStore`, `UnifiedOrchestrator`, `StudioViewModel`, `SyncModeEngine`, etc.)

### Warning inventory — after cleanup
**FROM_ORCHESTRATOR_CACHE_DEMO_TESTS**
- None — `OrchestratorCacheDemoTests.swift` compiles with zero warnings; no MainActor `setUp()`/`tearDown()` lifecycle warnings

**UNRELATED_PREEXISTING** (unchanged)
- Same watch, asset, and production Swift 6 concurrency warnings as before slice

### Validation
- Shell: `test_inject_build_metadata.sh` → **21/21** PASS; `test_verify_built_app_metadata.sh` → **17/17** PASS
- Focused signed-simulator `OrchestratorCacheDemoTests` → **4/4** PASS (iPhone 17 Pro)
- Full signed-simulator `HueHomeTests` → **132/132** PASS
- No MainActor lifecycle warnings emitted from `OrchestratorCacheDemoTests.swift` after cleanup
- Generic unsigned builds not required for this slice
- No physical-device test required

### Recommended next stabilization follow-up
- **IOS-TEST-003B6** (or equivalent) — triage remaining unrelated preexisting Swift 6 / MainActor warnings in production and watch targets if warning-zero CI is desired

---

## 2026-06-02 — Native Android MVP Contract Freeze (ANDROID-CONTRACT-001)

### Scope
- Branch: `docs/android-mvp-contract-freeze`
- Starting SHA: `b4fbb58`
- Docs-only: `DEVLOG.md`, `docs/android/android-mvp-contract-freeze.md`
- No Swift, Kotlin, Xcode project, workflow, or script changes
- No Android Gradle project created
- No build, simulator run, or physical-device test required for this slice

### Product direction recorded
- Native Android (Kotlin + Jetpack Compose), not Flutter
- Minimal backend optional; **local Hue control remains local**
- Current iOS at `b4fbb58` is the behavior anchor

### iOS evidence anchor
- Full signed-simulator `HueHomeTests` → **132/132** PASS (includes orchestrator cache/demo/loadAll/optimistic/SSE suites)
- Metadata injector **21/21**, verifier **17/17** (per stabilization tooling)
- Orchestrator cache/demo MainActor lifecycle warnings cleared in **IOS-TEST-003B5** (prior entry)

### New document
- `docs/android/android-mvp-contract-freeze.md` — authoritative Android MVP contract freeze

### Contracts captured (from iOS source inspection)
- Discovery ladder: mDNS `_hue._tcp` → 12 s NUPnP `https://discovery.meethue.com/api/nupnp` → manual IP sheet (default port 443)
- Pairing: `POST /api`, 10 s timeout, devicetype `chromaglow#ios`, error 101 retry to `bridgeFound`, legacy Keychain persistence
- Credentials: `com.lightshade.app` service, legacy + `hue_bridge_{id}_*` keys, SwiftData `BridgeRecord`, duplicate-IP dedup, widget publish marked iOS-only
- REST v2: `https://{ip}/clip/v2/...`, `hue-application-key`, 10 s timeout, cert trust delegate; MVP reads/mutations tables
- Dashboard/room/zone display builders and aggregation rules
- Cache/stale-state, demo mode, optimistic `setRoom` rollback, `turnAllOff` optimistic behavior
- Scene MVP boundary: list + `recall.action = active` activation; create/edit/delete/dynamic_palette Post-MVP
- SSE: live path `UnifiedOrchestrator.runSSE`; `HueSSEService` unwired; reducer + 5→60 s backoff
- REST v1: **not required** for Android MVP (Composer/bridge animation only)
- Recommended Android package boundaries + 23-row acceptance matrix
- TODO-HARDWARE / TODO-SECURITY / TODO-PRODUCT / known `docs/ios` discrepancies listed

### Validation
- No commit or push in this session
- Recommended follow-up: merge docs PR, then deferred **iOS physical-device smoke** (dashboard, room/zone, scene activate, SSE) before Android implementation signoff

---

## 2026-06-03 — Final iOS Readiness Validation Handoff (IOS-OPS-FINAL-B)

### Scope
- Branch: `ios-ops/final-readiness-validation`
- Starting SHA: `5f7ec3a`
- Docs-only: `docs/ios/final-readiness-validation.md`, `DEVLOG.md`
- Draft report finalized at `docs/ios/final-readiness-validation.md`
- No Swift changes; no Xcode project changes; no Android code added
- No build rerun required in FINAL-B; no additional device testing run by Cursor

### Automated validation (IOS-OPS-FINAL-A, unchanged)
- Metadata injector → **21/21** pass
- Metadata verifier → **17/17** pass
- Unsigned Debug build → **BUILD SUCCEEDED**
- Unsigned Release build → **BUILD SUCCEEDED**
- Full signed-simulator `HueHomeTests` → **132/132** pass

### Physical test context
- Physical iPhone: `brian's iPhone` — **iPhone 17 Pro Max**, iOS **26.5**
- App launched from Xcode; local-network permission granted
- **Two Hue v2 bridges** tested

### Required physical matrix totals (20 rows)
- **PASS** → 17 / 20
- **PARTIAL** → 1 / 20 (`IOS-FINAL-PHYS-003` — mDNS finds bridge; discovered-result pairing unreliable)
- **FAIL** → 1 / 20 (`IOS-FINAL-PHYS-006` — link-button pairing loops from discovered result)
- **NOT AVAILABLE** → 1 / 20 (`IOS-FINAL-PHYS-015` — no mirek-capable lamp in test environment)

### Conditional hardware matrix totals (7 rows)
- **PASS** → 5 / 7
- **NOT TESTED** → 2 / 7
- **NOT PRACTICAL TODAY** → 1 / 7 (`IOS-FINAL-COND-001`)
- **NOT AVAILABLE** → 1 / 7 (`IOS-FINAL-COND-002` — no HTTP:80 legacy bridge)

### Verified on hardware
- Manual IP **HTTPS:443** pairing workaround (link button + manual IP)
- Two-bridge registration and bridge-specific room routing
- One-bridge-offline usability while other bridge remains usable
- External SSE visible-state update without pull-to-refresh
- Wi-Fi interruption and SSE recovery without app restart
- Dashboard, room/group controls, per-light controls (except mirek), scenes, stale-state

### Demo mode
- Demo launches without bridge dependency; **not** full-feature parity with current app

### Android-MVP kickoff blocker
- **Discovered-bridge pairing loop:** mDNS displays bridge; selecting discovered result does not reliably complete pairing; manual IP path works
- Android MVP kickoff remains **blocked** until defect is inventoried, repaired, and `IOS-FINAL-PHYS-003` / `IOS-FINAL-PHYS-006` are re-tested on hardware

### Recommended next work
- Branch: `ios-bug/discovered-bridge-pairing-loop-inventory`
- Task: **IOS-BUG-001A** — inventory discovered-bridge pairing-loop root cause (do not guess; inspect `BridgeDiscoveryService`, `BridgeDiscoveryViewModel`, `BridgeSetupView`, endpoint IP/port/scheme, mDNS handoff, pairing retry state)

### What's left
- [ ] IOS-BUG-001A inventory
- [ ] Fix discovered-result pairing handoff
- [ ] Physical re-test PHYS-003 and PHYS-006
- [ ] Android implementation (blocked until above)

---

## 2026-06-03 — Discovered-Bridge Pairing Loop Inventory (IOS-BUG-001A)

### Scope
- Branch: `ios-bug/discovered-bridge-pairing-loop-inventory`
- Starting SHA: `88b71cb`
- Docs-only: `docs/ios/discovered-bridge-pairing-loop-inventory.md`, `DEVLOG.md`
- No Swift changes; no Xcode project changes; no build; no simulator or device run by Cursor

### Readiness blocker source
- [`docs/ios/final-readiness-validation.md`](docs/ios/final-readiness-validation.md) — `IOS-FINAL-PHYS-003` PARTIAL, `IOS-FINAL-PHYS-006` FAIL; `IOS-FINAL-COND-003` PASS (manual IP HTTPS:443)
- Android MVP kickoff remains **blocked** until discovered-result pairing succeeds without manual IP

### Source-inspected endpoint and pairing facts
- mDNS (`BridgeDiscoveryService`): `_hue._tcp`, domain `local.`, LAN-only (`includePeerToPeer = false`), IPv4-forced resolve via `NWConnection` → `hostString` + preserved `port.rawValue`; Keychain IP saved on resolve
- Manual IP (`BridgeSetupView`): `BridgeEndpoint(name: "Hue Bridge", host: ip, port: 443)`
- Pairing (`BridgeDiscoveryViewModel`): `scheme = bridge.port == 443 ? "https" : "http"`; `BridgeCertTrustDelegate` only when port == 443; type **101** → `.bridgeFound`; URLSession failure → `.error`
- NUPnP fallback: `port = UInt16(first.port ?? 443)` (aligns with manual path when cloud returns no port)

### Primary hypothesis (not proven)
- Discovered path may pair over **HTTP:non-443** while manual path uses **HTTPS:443** on the same v2 bridge; manual workaround success is consistent but **runtime logs must confirm** resolved port and `POST` URL before any port normalization

### Inventory deliverables
- New doc: [`docs/ios/discovered-bridge-pairing-loop-inventory.md`](docs/ios/discovered-bridge-pairing-loop-inventory.md)
- Physical DEBUG log-capture packet and fill-in table for Brian (pre–IOS-BUG-001B)
- Existing tests: **no** `BridgeDiscovery` / pairing coverage; `StubURLProtocol` exists for CLIP v2 only
- Ranked repair strategies: log-capture first; then prefer **Strategy C** (`pairingCandidates`) after evidence — avoid blanket normalize-to-443 (Strategy A) without legacy policy
- **IOS-BUG-001B boundary:** run log capture; if transport mismatch confirmed, minimal ViewModel candidate ordering (discovered then HTTPS:443), not broad discovery rewrite in first commit

### Required physical re-test (post–001B)
- `IOS-FINAL-PHYS-003`, `IOS-FINAL-PHYS-005`, `IOS-FINAL-PHYS-006`, `IOS-FINAL-PHYS-007`, `IOS-FINAL-COND-003`, `IOS-FINAL-COND-004`

### What's left
- [ ] Brian: fill DEBUG log-capture table (discovered vs manual, both v2 bridges)
- [ ] IOS-BUG-001B — narrow pairing transport repair per inventory boundary
- [ ] Physical re-test PHYS-003 / PHYS-006 (and related rows)
- [ ] Android implementation (still blocked)

---

## 2026-06-03 — Multi-Bridge Discovery-Selection Evidence (IOS-BUG-001A2)

### Scope
- Branch: `ios-bug/discovered-bridge-pairing-loop-log-capture`
- Starting SHA: `88b71cb`
- Docs-only: `docs/ios/discovered-bridge-pairing-loop-inventory.md`, `DEVLOG.md`
- Physical DEBUG log capture **completed** — no further transport testing required for tested v2 bridges
- No Swift changes; no Xcode changes; no tests run by Cursor

### Confirmed physical evidence
- Two Hue v2 bridges via mDNS: `Hue Bridge - 663C54` → `192.168.40.116:443`; `Hue Bridge - 608DFC` → `192.168.40.117:443`
- Discovered pairing uses `https://host:443/api` with HTTPS cert trust delegate on both
- Pairing succeeds when link button matches the bridge in the pairing flow; manual IP succeeds for the other bridge

### Ruled-out hypothesis
- Port/scheme mismatch **ruled out** for tested v2 bridges (both resolve and pair on HTTPS:443)

### Corrected diagnosis
- **First-discovered bridge auto-selection** (`discoveredBridges.first`), immediate scan stop, **no discovered-bridge chooser** — user cannot target second LAN bridge without manual IP; adding second bridge may re-offer already-connected bridge A

### Separate issue
- NUPnP `GET https://discovery.meethue.com/api/nupnp` → **404 page not found**; warm mDNS retry followed — follow-up **IOS-BUG-002A** (not mixed into 001B)

### Recommended IOS-BUG-001B boundary
- Add discovered-bridge **selection UI** before pairing; preserve host/port/transport/pairing/Keychain; do not normalize ports or fix NUPnP in 001B

### Android-MVP kickoff
- Remains **blocked** until IOS-BUG-001B physical re-test passes (multi-bridge discovery selection without manual IP for second bridge)

### What's left
- [ ] IOS-BUG-001B — discovered-bridge selection before pairing
- [ ] Physical re-test PHYS-003, PHYS-006, COND-003, COND-004
- [ ] IOS-BUG-002A — NUPnP 404 inventory (separate)
- [ ] Android implementation (blocked)

---

## 2026-06-03 — Explicit Discovered-Bridge Selection Repair (IOS-BUG-001B)

### Scope
- Branch: `ios-bug/discovered-bridge-selection-ui`
- Starting SHA: `de5a0ec`
- Confirmed multi-bridge defect: mDNS resolves multiple v2 bridges; flow auto-selected `discoveredBridges.first`, stopped scan, and offered no chooser — second bridge required manual IP
- Narrow implementation boundary: selection UI + discovery handoff only; no pairing transport, cert trust, Keychain, or NUPnP changes

### Files changed
- `HueHome/Core/ViewModels/BridgeDiscoveryViewModel.swift`
- `HueHome/UI/BridgeSetup/BridgeSetupView.swift`
- `HueHome/Core/Network/BridgeDiscoveryService.swift` (host+port append dedupe only)
- `DEVLOG.md`

### Selection behavior added
- Scanning phase shows explicit tappable rows (`name` + `host:port`) via `discoveredBridgeChoices`
- `selectDiscoveredBridge(_:)` stops scan and transitions to `.bridgeFound(selected)` for pairing
- DEBUG logs: `🌉 Resolved bridge choice:` on new endpoint; `👆 Selected discovered bridge:` on user tap
- Normal mDNS first-bridge auto-selection **removed** (init Combine sink)
- Warm-cache mDNS retry first-bridge auto-selection **removed**; retry surfaces chooser when bridges resolve, errors only if still empty after 10 s poll
- Manual-IP fallback unchanged; `Pair with Bridge` / type-101 retry / HTTPS:443 + HTTP:80 pairing unchanged
- NUPnP cloud path unchanged (still auto-selects first cloud result); `GET discovery.meethue.com/api/nupnp` 404 deferred to **IOS-BUG-002A**

### Endpoint deduplication
- **Service append guard** compares `host` + `port` (not synthesized `Equatable` with random `id`)
- **ViewModel** `deduplicatedByHostAndPort` for chooser-facing list

### Focused tests
- **Not added** — selection is UI + `@MainActor` VM wiring; dedupe is trivial static helper; no new test file / pbxproj change to keep slice minimal. Physical re-test packet required.

### Automated validation
- `git diff --check`: PASS
- Metadata injector: **21/21 PASS**
- Metadata verifier: **17/17 PASS**
- Unsigned Debug build (`HueHome 1`, generic iOS): **BUILD SUCCEEDED**
- Unsigned Release build: **BUILD SUCCEEDED**
- Signed simulator suite (`iPhone 17 Pro`, `HueHomeTests` only): **TEST SUCCEEDED**, **132/132 PASS** (no new tests)

### Required physical re-test
- Brian: IOS-BUG-001B packet (Tests 1–6) on Debug iPhone with two v2 bridges (`.116` / `.117`) — see follow-up entry below

### What's left
- [x] Brian: physical re-test Tests 1–6 (recorded 2026-06-03)
- [ ] IOS-BUG-001C — clarify selected-bridge pairing retry feedback (non-blocking UX)
- [ ] IOS-BUG-002A — NUPnP 404 inventory (separate)
- [ ] Android implementation (blocked until PR merge + readiness reconciliation)

---

## 2026-06-03 — Explicit Discovery Selection Physical Re-Test (IOS-BUG-001B)

### Scope
- Branch: `ios-bug/discovered-bridge-selection-ui`
- Two Hue v2 bridges on same LAN: Bridge A `192.168.40.116:443`, Bridge B `192.168.40.117:443`
- Debug iPhone physical re-test; docs-only update to `DEVLOG.md` (implementation unchanged)

### IOS-BUG-001B Physical Re-Test

**Test 1 — chooser contents: PASS**
- Both Hue v2 bridges appear as explicit selectable choices
- No duplicate rows observed
- Neither bridge is silently forced as the only pairing target

**Test 2 — pair Bridge A (.116): PASS**
- Explicit selection of `192.168.40.116:443` pairs successfully after pressing the matching bridge link button

**Test 3 — pair Bridge B (.117) without manual IP: PASS**
- Explicit selection of `192.168.40.117:443` pairs successfully without manual IP entry after pressing the matching bridge link button

**Test 4 — type 101 retry: PASS WITH UX FOLLOW-UP**
- Retry behavior remains functional
- When the selected bridge and pressed physical bridge button do not match, current feedback does not clearly explain the mistake or identify the selected bridge

**Test 5 — manual-IP regression: PASS**
- Existing manual-IP HTTPS:443 pairing path remains functional

**Test 6 — two-bridge routing regression: PASS**
- Both registered bridges route room controls to the intended physical bridge

### Outcome
- Chooser shows both bridges; no duplicate chooser rows observed
- Bridge A pairs through explicit discovered selection
- Bridge B pairs through explicit discovered selection without manual IP
- Type 101 retry remains functional
- Manual-IP HTTPS:443 regression passes
- Two-bridge room-routing regression passes
- **Primary multi-bridge discovery-selection blocker is resolved**

### Android MVP kickoff
- After this PR merges and the readiness report is reconciled, Android MVP kickoff may move to **READY WITH DOCUMENTED FOLLOW-UPS**

### Follow-up — IOS-BUG-001C (non-blocking)
**IOS-BUG-001C — Clarify selected-bridge pairing retry feedback**

Observed UX gap:
When a user selects one discovered bridge but presses the physical link button on another bridge, retry remains functional but the UI does not clearly explain the mismatch or identify the selected bridge.

Boundary:
Improve user-facing retry feedback in a later narrow slice. Do not change pairing transport or state-machine behavior in IOS-BUG-001B.

### Follow-up — IOS-BUG-002A (separate)
**IOS-BUG-002A — Inventory Philips cloud-discovery fallback 404**

Not investigated or fixed in IOS-BUG-001B branch.

### What's left
- [ ] Merge IOS-BUG-001B PR; reconcile readiness report
- [ ] IOS-BUG-001C — pairing retry UX clarity (narrow slice)
- [ ] IOS-BUG-002A — NUPnP 404 inventory
- [ ] Android MVP kickoff (after merge + readiness reconciliation)

---

## 2026-06-03 — Final Readiness Reconciliation After Explicit Bridge Selection Repair (IOS-OPS-FINAL-C)

### Scope
- Branch: `docs/ios-readiness-reconcile-after-001b`
- Starting SHA: `72ee5ab`
- Docs-only: `docs/ios/final-readiness-validation.md`, `DEVLOG.md`
- IOS-BUG-001B merged at main SHA `72ee5ab`
- No Swift changes; no Xcode project changes; no Android code added
- No build rerun required in FINAL-C; no simulator rerun required in FINAL-C; no device tests run by Cursor

### Automated validation (unchanged baseline)
- Metadata injector → **21/21** pass
- Metadata verifier → **17/17** pass
- Unsigned generic Debug build → **BUILD SUCCEEDED**
- Unsigned generic Release build → **BUILD SUCCEEDED**
- Full signed-simulator `HueHomeTests` → **132/132** pass

### Physical re-test (two Hue v2 bridges, post–IOS-BUG-001B)
- Both discovered bridges appear as explicit selectable choices; no duplicate chooser rows observed
- Bridge A (`192.168.40.116:443`) discovered-selection pairing → **PASS**
- Bridge B (`192.168.40.117:443`) discovered-selection pairing without manual IP → **PASS**
- Type-101 retry functional → **PASS WITH UX FOLLOW-UP** (IOS-BUG-001C)
- Manual-IP HTTPS:443 regression → **PASS**
- Two-bridge routing regression → **PASS**

### Readiness outcome
- Multi-bridge discovery-selection blocker → **resolved**
- Android MVP kickoff → **READY WITH DOCUMENTED FOLLOW-UPS**
- IOS-BUG-001C → non-blocking UX follow-up (selected-vs-pressed bridge mismatch feedback)
- IOS-BUG-002A → non-blocking (NUPnP `GET https://discovery.meethue.com/api/nupnp` → 404)
- Credential rotation required before release signoff (DEBUG logs exposed bridge credentials)

### Historical preservation
- Original IOS-OPS-FINAL-B physical matrix (including `IOS-FINAL-PHYS-003` PARTIAL and `IOS-FINAL-PHYS-006` FAIL) preserved as pre-repair record
- Post-IOS-BUG-001B reconciliation section added to `docs/ios/final-readiness-validation.md`

### What's left
- [ ] IOS-BUG-001C — clarify selected-bridge pairing retry feedback
- [ ] IOS-BUG-002A — NUPnP fallback 404 inventory
- [ ] Credential rotation before release signoff
- [ ] Android MVP foundation implementation (unblocked with documented follow-ups)

---

## 2026-06-03 — Native Android Foundation Scaffold Inventory (ANDROID-001A)

### Scope
- Branch: `android/foundation-scaffold`
- Starting SHA: `092fdd7`
- Docs-only: `docs/android/android-foundation-scaffold-plan.md`, `DEVLOG.md`
- No Android code, Gradle files, SDK installs, iOS changes, builds, commits, or pushes

### Android kickoff readiness
- Repo docs: **READY WITH DOCUMENTED FOLLOW-UPS** (per IOS-OPS-FINAL-C / `docs/ios/final-readiness-validation.md`)
- Greenfield standalone native Android; iOS remains production behavior anchor; do not copy `UnifiedOrchestrator` god-object

### New artifact
- `docs/android/android-foundation-scaffold-plan.md`

### Existing Android scaffold inventory
- No Gradle/Kotlin/`AndroidManifest.xml` in repo
- Only `docs/android/` directory at depth ≤3; **no application scaffold**

### Local toolchain inventory (read-only)
| Component | Result |
| --- | --- |
| Java / `JAVA_HOME` | Unset; `/usr/bin/java` reports no JRE installed |
| Android Studio | Not found (`/Applications/Android Studio.app` absent) |
| Android SDK | `$HOME/Library/Android/sdk` missing |
| `adb` | Not on PATH |
| `sdkmanager` | Not on PATH |
| `emulator` | Not on PATH |
| `gradle` (global) | Not on PATH |

### Toolchain classification
- **BLOCKED — TOOLCHAIN INSTALL REQUIRED** (ANDROID-001B build verification needs Studio + JDK + SDK)

### Frozen / proposed scaffold decisions
| Item | Recommendation |
| --- | --- |
| Project root | `android/` |
| Gradle modules | `:app` only initially |
| Display name | `ChromaGlow` |
| Namespace | `com.chromaglow.app` — **approval required** |
| `applicationId` | `com.chromaglow.app` — **approval required** |
| `minSdk` / `targetSdk` | Propose API 26 min; target/compile from installed SDK at 001B — **approval required** |
| JDK | Derive from Studio (expect 17) at 001B |
| AGP / Kotlin / Compose BOM | **Deferred** — resolve from installed template; do not guess |

### Explicitly not done
- No Android project files or Kotlin sources added
- No Gradle wrapper added
- No iOS files changed
- No builds run; no installs performed

### Recommended next task
- **ANDROID-001B** — Create standalone native Android foundation scaffold (after Brian approves namespace + `applicationId` and local toolchain install)

### Non-blocking iOS follow-ups (unchanged)
- IOS-BUG-001C — selected-bridge pairing retry UX
- IOS-BUG-002A — NUPnP cloud-discovery 404 inventory
- Credential rotation before iOS release signoff

---

## 2026-06-03 — Native Android Compose Foundation Scaffold (ANDROID-001B)

### Context
- **Branch:** `android/foundation-scaffold-implementation`
- **Starting SHA:** `f2cb14a`
- **Template:** Android Studio Jetpack Compose Empty Activity

### Identity and SDK
| Item | Value |
| --- | --- |
| Namespace | `com.chromaglow.app` |
| `applicationId` | `com.chromaglow.app` |
| Hue `devicetype` | `chromaglow#android` |
| `minSdk` | 26 |
| `compileSdk` | 37 |
| `targetSdk` | 36 |

### Toolchain and dependency pins (generated template, unchanged in 001B)
| Item | Version |
| --- | --- |
| Gradle wrapper | 9.4.1 |
| Android Gradle Plugin | 9.2.1 |
| Kotlin | 2.2.10 |
| Compose BOM | 2026.02.01 |
| Bundled JBR | OpenJDK 21.0.10 (Android Studio) |

### What was built
- Initial **`:app`-only** module boundary under `android/`
- Machine-local paths excluded via `android/.gitignore` (`/.idea/`, `/.gradle/`, `/.kotlin/`, `local.properties`, build dirs)
- Starter **Hello Android** template validated before replacement
- **ChromaGlow** shell: `MainActivity` → `ChromaGlowTheme` → `ChromaGlowApp`
- Local setup placeholder destination (`feature.setup`)
- **Demo-mode entry boundary** (`data.demo.DemoModeBoundary`) — no fixtures, persistence, or networking
- Dashboard placeholder destination (`feature.dashboard`)
- Local Compose navigation state only (no Navigation Compose dependency)
- JVM smoke: `DemoModeBoundaryTest`
- Compose instrumented smoke: `ChromaGlowAppTest`
- Updated `docs/android/android-foundation-scaffold-plan.md` post-install record (preserves ANDROID-001A history)

### Explicitly not done
- Hue networking, discovery, pairing, credentials, Keystore, DataStore, Room, REST/SSE
- No iOS files changed
- No commit or push

### Automated validation (ANDROID-001B)
- **Gradle:** 9.4.1 (JBR 21.0.10)
- **`lintDebug`:** PASS
- **`testDebugUnitTest`:** PASS (`DemoModeBoundaryTest`)
- **`assembleDebug`:** PASS
- **`connectedDebugAndroidTest`:** PASS (`ChromaGlowAppTest` on Pixel_10 AVD)
- **APK install:** PASS
- **`MainActivity` launch:** PASS (`adb shell am start -n com.chromaglow.app/.MainActivity`)
- Logs: `/tmp/android-001b-build.log`, `/tmp/android-001b-connected-test.log`

### Manual verification required
- Inspect running emulator: setup copy → **Enter Demo Mode** → dashboard placeholder → **Back to Setup**

### Recommended next task
- **ANDROID-002A** — Establish Android design-system tokens and screen-shell parity map

---

## 2026-06-04 — Android Design-System Tokens and Screen-Shell Parity Map (ANDROID-002A)

- **Branch:** `android/design-system-shell-parity-map`
- **Starting SHA:** `63f35f3324d2294e868873b2b1f162ac9537d504`
- **Scope:** Docs-only — no Kotlin, Gradle, `AndroidManifest`, Swift, or iOS doc edits
- **New doc:** [`docs/android/android-design-system-shell-parity-map.md`](docs/android/android-design-system-shell-parity-map.md)
- **Content:** Material 3 token tables from `HueTokens.swift` / `HueTypography.swift`; setup and dashboard shell parity rows; room-card interaction contract; MVP acceptance traceability
- **Approved decisions recorded:** `dynamicColor = false` for MVP; Noir-only dark theme; Estate as future reference only; setup gradient = Noir base + subtle purple tint; glass = alpha surface + border + restrained glow (no blur / `RenderEffect`); semantic parity not pixel clone; keep `ChromaGlowDestination` enum navigation — **no Navigation Compose**; deferred presets, now-playing, automations, Studio, More, favorite scenes, wide-card toggle, light theme, haptics; `core.ui` extraction waits for second caller
- **ANDROID-002B boundary:** Replace template purple/dynamic colors, expand typography, theme two placeholders only — no new destinations, grid, setup phases, or fake rooms
- **Baseline noted:** `Theme.kt` still ships `dynamicColor = true` and purple starter colors until 002B
- **Explicit non-goals:** No `UnifiedOrchestrator` copy on Android; no placeholder stubs for deferred features in 002B
- **iOS follow-ups (appendix only):** IOS-BUG-001C, IOS-BUG-002A — non-blocking
- **Next recommended task:** **ANDROID-002B** — Apply ChromaGlow dark Material 3 tokens to theme + setup/dashboard placeholders
- No commit or push in this pass

---

## 2026-06-04 — Android Dark Material Theme and Placeholder Styling (ANDROID-002B)

- **Branch:** `android/dark-material-theme-placeholders`
- **Starting SHA:** `fb7cd25f755407db48ec3196f59bd1860f5cbc45`
- **Theme changes:** Fixed Noir-only Material 3 `darkColorScheme`; template purple/pink colors removed; `dynamicColor`, `darkTheme`, `isSystemInDarkTheme`, and light/dynamic scheme paths removed from `ChromaGlowTheme`
- **Tokens:** ChromaGlow amber, setup gradient stops, and Noir semantic colors in `Color.kt`
- **Typography:** Expanded `Typography` with verified Material 3 slots (display/headline/title/body/label per parity map)
- **Setup placeholder:** `Brush.linearGradient` background (no explicit `Offset`); title/subtitle use `onBackground` / `onSurfaceVariant`; default amber `Button` for Enter Demo Mode
- **Dashboard placeholder:** `background` root fill; themed text; `OutlinedButton` for Back to Setup
- **Unchanged:** Routing, `ChromaGlowApp`, demo boundary, Gradle, manifest, dependencies, tests, iOS, networking, persistence, Navigation Compose
- **Automated validation:** `git diff --check` PASS; `./gradlew clean lintDebug testDebugUnitTest assembleDebug` PASS; `./gradlew connectedDebugAndroidTest` PASS (Pixel_10 AVD, 1 test)
- **Manual:** Pixel_10 visual verification of gradient, amber CTA, Noir dashboard, and setup round-trip still required
- No commit or push in this pass

---

## 2026-06-04 — Android Demo-Mode Domain Models and Dashboard Fixtures (ANDROID-003A)

- **Branch:** `android/demo-mode-domain-fixtures`
- **Starting SHA:** `d5c1ebf9a1ab4e9d0f5fa9c343f5857a03c44e7b`
- **Domain:** `RoomDisplayModel` with constructor `require` invariants (brightness 1–100, non-blank ids/names/bridgeId)
- **Fixtures:** `DemoFixtures` — four deterministic in-memory rooms on `demo-bridge-main`, sorted by name
- **Session:** `DemoModeSession` carries `rooms`; `enterDemoMode()` returns `DemoFixtures.rooms`
- **Dashboard:** `DashboardPlaceholderScreen` evolved in place — `LazyColumn` of read-only `DemoRoomRow` (`On · N% · N lights` / off alpha 0.72)
- **Tests:** `DemoFixturesTest` (fixture + invariant coverage); `DemoModeBoundaryTest` and `ChromaGlowAppTest` smoke updated
- **Unchanged:** `ChromaGlowApp`, setup, theme, Gradle, manifest, dependencies, routing, iOS, networking, persistence, zones, controls, Navigation Compose
- **Automated validation:** `git diff --check` PASS; `./gradlew clean lintDebug testDebugUnitTest assembleDebug` PASS; `./gradlew connectedDebugAndroidTest` PASS (Pixel_10 AVD, 1 test)
- **Manual:** Pixel_10 fixture list and setup round-trip still required
- No commit or push in this pass

---

## 2026-06-04 — Android Local Credential-Storage Boundary (ANDROID-004A)

- **Branch:** `android/credential-storage-boundary`
- **Starting SHA:** `6f0f7167da7c2f27bd7d9dcc16d1d8787681ca56`
- **Scope:** API-token-only local credential boundary — no `CLIENT_KEY`, entertainment keys, secret-kind enums, or future-secret placeholders
- **Keystore:** Per-bridge `AndroidKeyStore` AES-256-GCM key material (`AES/GCM/NoPadding`)
- **At-rest blob:** Versioned IV + ciphertext under `Context.noBackupFilesDir/credentials/` (no backup); directory creation fails closed if path is missing, not a directory, or cannot be created
- **Alias strategy:** Deterministic `chromaglow.bridge.<bridgeId>.api_token` keystore alias and `bridge_<bridgeId>.api_token.enc` filename; unsafe bridge IDs rejected (not sanitized)
- **Store API:** `BridgeCredentialStore` with `saveApiToken` / `loadApiToken` / `deleteApiToken`; `BridgeSecretResult` = `Present` / `Absent` / `Failure`
- **Concurrency:** Process-wide `PROCESS_LOCK` shared across store instances
- **Save:** Validates bridge ID and non-blank token; fails closed before Keystore key creation when ciphertext path exists but is not a regular file; reuses or creates Keystore key; encrypts UTF-8; unique `createTempFile` write with `fd.sync()`; `Files.move` with `ATOMIC_MOVE` + `REPLACE_EXISTING`, falling back to `REPLACE_EXISTING` only; no delete-before-replace window; does not delete Keystore key before overwrite
- **Filesystem checks:** `Files.exists` / `Files.isRegularFile` use `LinkOption.NOFOLLOW_LINKS` on save, load, and delete (symlinks and other non-regular entries fail closed)
- **Load:** Neither key nor ciphertext path → `Absent`; path exists but not a regular file → `Failure`; exactly one of key or regular ciphertext file → `Failure`; both present → decrypt with on-disk blob length bounded before `readBytes`; crypto/I/O/format errors → `Failure` (`Exception` only, no token in messages)
- **Delete:** Non-regular ciphertext path → throw; `Files.deleteIfExists` propagates I/O failure before Keystore removal; idempotent when already absent
- **Tests:** `BridgeCredentialAliasTest` (JVM alias/filename validation); `AndroidKeystoreBridgeCredentialStoreTest` (round-trip, overwrite, idempotent delete, ciphertext does not contain token bytes, key-without-blob and blob-without-key `Failure`, directory-at-ciphertext-path save/load/delete, oversized encrypted blob rejection)
- **Deferred:** Biometric/user-presence prompt, metadata persistence, UI wiring, pairing, networking
- **Unchanged:** Gradle, manifest, dependencies, `MainActivity`, app/feature/ui packages, docs, iOS, DataStore, Room, SharedPreferences
- **Automated validation:** `git diff --check` PASS; forbidden storage/logging grep PASS; `./gradlew clean lintDebug testDebugUnitTest assembleDebug` PASS; `./gradlew connectedDebugAndroidTest` PASS (Pixel_10 AVD, 13 tests)
- No commit or push in this pass

## 2026-06-04 — Android mDNS Bridge-Discovery Chooser (ANDROID-005A)

- Branch: `android/mdns-bridge-discovery`
- Starting SHA: `950677ed3b89e999e4304326bc283aa4c7a6daaf`
- Hue DNS-SD type: `_hue._tcp` (no trailing dot), browsed via `NsdManager.PROTOCOL_DNS_SD`
- Android `NsdManager` platform adapter (`AndroidNsdBridgeDiscoveryService`) — LAN browse only, no extra dependency
- Manifest permissions: `CHANGE_WIFI_MULTICAST_STATE`; plus `INTERNET` added on runtime evidence — `getSystemService(NSD_SERVICE)` `NsdManager.<init>` → `INsdManager.connect()` throws `SecurityException` without it (proven by connected test before adding)
- `WifiManager` multicast lock lifecycle: non-reference-counted, acquired on start, released on stop/stopped/failure; never double-acquired or released-when-unheld
- API 34+ uses `registerServiceInfoCallback(serviceInfo, mainExecutor, callback)`; one callback tracked per service name; updates restore endpoint, callback loss removes it
- API 26–33 single-flight `@Suppress("DEPRECATION")` `resolveService` fallback; queued one-at-a-time, next drained after success/failure; stale-generation callbacks ignored
- Host extraction: API 34+ prefers first `Inet4Address` from `hostAddresses`, else first; legacy uses `serviceInfo.host`; both via `InetAddress.hostAddress`, require non-blank host, preserve `serviceInfo.port`, omit invalid endpoints
- `BridgeEndpoint` preserves resolved host + port; chooser rows derived from `BridgeEndpointDeduper.deduplicate(endpointByServiceName.values)` (host+port dedupe, first-seen wins, not by service name)
- No silent auto-selection; chooser row tap stops discovery and sets an inert selected endpoint ("Pairing will be added in a later step.")
- Generation counter + main-thread state changes guard against zombie callbacks; no `Log.*`/`println`/service-object dumping
- Lifecycle correction pass: `stopActiveDiscovery()` attempts `stopServiceDiscovery(listener)` whenever a `discoveryListener` exists (including the pre-`onDiscoveryStarted` window), catching `IllegalArgumentException` for not-yet-registered listeners — no longer gated on `isDiscoveryActive`
- Lifecycle correction pass: `acquireMulticastLock()` + `discoverServices(...)` share one bounded `try` catching `IllegalArgumentException`/`SecurityException`; either fails closed (clear listener/active/scanning, release multicast lock, `DISCOVERY_FAILED_MESSAGE`, publish) with no exception detail logged
- Lifecycle correction pass: API 26–33 in-flight `resolveService` callbacks cannot resurrect a service lost before resolution — `discoveredServiceNames` gates endpoint publication; `onServiceLost` drops the name, endpoint, queued entries, and queued-name set membership
- Lifecycle correction pass: legacy resolve queue is name-deduplicated via `queuedLegacyServiceNames` (skip if already queued or currently resolving); `currentlyResolvingServiceName` set before resolve and cleared on success/failure
- Lifecycle correction pass: API 34+ callback-map cleanup is identity-safe — `removeServiceInfoCallbackIfCurrent(...)` only removes a map entry when it still references the same callback instance, so a later replacement registered for the same service name is preserved
- Setup screen extended with defaulted `onDiscoveredBridgeSelected` callback (no `ChromaGlowApp.kt` edit); `DisposableEffect` stops discovery on dispose; Noir gradient, title, subtitle, and Enter Demo Mode preserved
- Tests: `BridgeEndpointDeduperTest` (11 JVM cases — dedupe, first-seen, service-name independence, endpointKey lowercase, IPv4/IPv6 displayAddress, blank name/host and bad port rejection); `ChromaGlowAppTest` adds Scan for Bridge + Enter Demo Mode assertions before/after dashboard round-trip
- No pairing, manual IP, NUPnP, cloud discovery, credentials, REST, TLS, Gradle, dependency, dashboard, iOS, DataStore, or Room changes
- Automated validation: `git diff --check` PASS; scope + forbidden-scope greps PASS; `./gradlew clean lintDebug testDebugUnitTest assembleDebug` PASS; `./gradlew connectedDebugAndroidTest` PASS (Pixel_10 AVD, 13 tests)
- Manual Pixel_10 LAN verification still required (no physical bridge discovery claimed)
- No commit or push in this pass

## 2026-06-04 — Android Manual-IP Bridge Entry (ANDROID-005B)

- Branch: `android/manual-ip-bridge-entry`
- Starting SHA: `f18fb29ef4f83d72a42f32ccb5cbf1201115e6b4`
- Inline manual-entry path on the setup screen — secondary `Enter IP Manually` action expands an inline section (no `ModalBottomSheet`); preserves landed ANDROID-005A discovery/lifecycle behavior
- Pure local parser (`ManualBridgeEndpointParser`) — no dependency, no Android networking imports, no DNS, never calls `InetAddress.getByName`; trims input, rejects blanks, schemes (`://`), `/?#@`, internal whitespace, and IPv6 zone IDs (`%`)
- Fixed local HTTPS port `443`; no custom-port field
- IPv4 accepted only as exactly four numeric octets in `0..255`; dotted-decimal candidates never fall through to the hostname path (so `256.1.1.1` is rejected, not treated as a name)
- IPv6 accepted conservatively: at most one `::` compression marker, no `:::`, hex groups 1–4 chars; bracketed literals such as `[2001:db8::1]` have exactly one matched surrounding pair stripped so `BridgeEndpoint.displayAddress` re-adds exactly one pair
- Safe ASCII hostnames: dot-separated or single-label, each label `1..63` chars of letters/digits/`-`, no leading/trailing `-`, total `≤253`; no resolution performed
- Bounded `Parsed.Valid`/`Parsed.Invalid` result with fixed inline error strings; valid input builds the existing `BridgeEndpoint(name = "Manual bridge", host, port = 443)`
- No network request on entry — typing updates local UI state only; selection reuses the existing inert `SelectedBridgeCard` and preserves `Pairing will be added in a later step.`
- Transitions: `Enter IP Manually` stops discovery, clears chooser rows / prior selection / prior manual input + error, opens the section; valid `Use This Bridge` sets the selected endpoint, closes the form, clears error, shows the inert card; invalid keeps the form open with an inline error and no card; `Scan for Bridge` / `Scan Again` clear manual visibility/text/error and selected state and restart mDNS through the existing service
- Selection remains read-only; no persistence
- Tests: `ManualBridgeEndpointParserTest` (JVM — valid IPv4/whitespace-trimmed/`fe80::1`/`[2001:db8::1]`/`bridge.local`/`huebridge`; invalid blank/whitespace/`256.1.1.1`/bad octet counts/malformed IPv6/multiple `::`/`fe80::1%eth0`/`https://…`/`…/api`/embedded whitespace/hyphen-edge labels/over-63 label; default port 443, synthetic name, unbracketed IPv6 storage, one-pair IPv6 display, `host:443` IPv4 display); `SetupManualEntryTest` (Compose — action visible, valid IPv4 renders inert card + `192.168.1.100:443`, invalid renders inline error and no card, `Scan Again` clears selection and returns to scanning); `ChromaGlowAppTest` unchanged
- No pairing, navigation, persistence, REST, TLS, cloud, backend, NUPnP, credentials, manual network probes, new lifecycle behavior, dependency, manifest, or Gradle changes
- Physical-device validation remains deferred — no physical Android device is currently available
- No commit or push in this pass

## 2026-06-04 — Android NUPnP Fallback Inventory and Gated Deferral (ANDROID-005C)

- Branch: `android/nupnp-fallback-inventory`
- Starting SHA: `785d085949dc22cf14b20c6948cb0268030f2768`
- Docs-only inventory / decision slice — read-only inventory reviewed and approved; no Android fallback behavior implemented; no network probe performed
- New decision record: `docs/android/android-nupnp-fallback-inventory.md` (title/status, decision, Android baseline, iOS fallback contract, IOS-BUG-002A evidence, architecture implications, why deferred, future preconditions, future implementation shape, non-goals)
- Existing iOS fallback contract recorded: cloud-assisted Philips Hue N-UPnP discovery (not LAN SSDP/mDNS, not local NUPnP) — `GET https://discovery.meethue.com/api/nupnp`; expects JSON array of `id`, `internalipaddress`, optional `port`; defaults port to `443` when omitted; runs after ~12s if still scanning; silently selects the first returned bridge; does not inspect HTTP status before decoding; failed decode falls into existing retry path
- IOS-BUG-002A evidence: physical DEBUG capture observed `GET https://discovery.meethue.com/api/nupnp` returning body `404 page not found`; root cause unresolved (endpoint drift vs transient vs account/network-specific vs other external assumption — not yet known); no fix claimed in this Android slice
- Decision: `DEFER UNTIL IOS-BUG-002A IS RESOLVED` — gated deferral, not MVP removal
- Android continues with ANDROID-005A mDNS chooser + ANDROID-005B manual entry as the active local-first onboarding baseline
- Any future Android cloud-assisted fallback must feed the existing chooser rows and require an explicit row tap — the iOS silent first-result selection must not be copied (would violate the landed ANDROID-005A explicit-chooser invariant); fallback stays optional and never the mandatory lighting-control path
- Future Android follow-up gated on: confirmed supported endpoint, confirmed response shape + explicit HTTP-status behavior, product approval for the narrow cloud-assisted exception, product approval that cloud results feed the chooser (no silent auto-select), and a bounded future task packet; no future task ID is frozen
- Foundation scaffold plan updated near the ANDROID-005C roadmap entry to record inventory/decision completion, the deferral, the active mDNS + manual-entry baseline, and a link to the decision record
- No Kotlin, Swift, manifest, Gradle, dependency, test, Xcode, or runtime changes
- No network probe performed
- No commit or push in this pass

## 2026-06-04 — Android Pairing TLS / Stable-Identity Decision Blocker (ANDROID-006A)

- Branch: `android/link-button-pairing`
- Starting SHA: `0571c6d0e67b6e11e314bf7b1e567b55bb60cf8c`
- Docs-only stable-identity / TLS inventory — read-only investigation reviewed and approved; no pairing runtime code added; no network probe performed
- New blocker record: `docs/android/android-pairing-tls-identity-decision.md` (status/decision, current onboarding baseline, known pairing contract, stable-identity blocker, TLS-bootstrap blocker, unsafe iOS precedent, why deferred, future preconditions, future sequencing shape, explicit non-goals)
- Status: `BLOCKED — SAFE TLS BOOTSTRAP AND CANONICAL BRIDGE IDENTITY MUST BE DECIDED BEFORE LIVE PAIRING CODE`
- Known pairing contract (evidence only): `POST {scheme}://{host}:{port}/api`; `Content-Type: application/json`; ~10s timeout; body `devicetype` + `generateclientkey`; Android device type `chromaglow#android`; JSON-array response; success `username` + optional `clientkey`; retryable type `101` (link button not pressed); type `7` invalid body/devicetype
- ANDROID-004A credential boundary (`BridgeCredentialStore` / `BridgeCredentialAlias`) requires a stable `bridgeId`, not host or port
- Android discovery (mDNS) and manual endpoint entry currently produce only `name`, `host`, and `port` via `BridgeEndpoint`; neither yields a canonical bridge ID
- Pairing response contains no stable bridge ID; host + port is short-lived routing/dedupe only and is not durable identity across DHCP changes; do not fabricate, randomly generate, or substitute a bridge ID; do not copy the iOS random-UUID storage precedent
- Safe first-contact TLS trust cannot be derived from repo evidence alone — no approved CA, fingerprint, hostname rule, pinning material, or TOFU-bootstrap rule exists; permissive `X509TrustManager` and blind-`true` `HostnameVerifier` are not approved; HTTP-stack selection deferred until trust policy approved
- iOS permissive local server-trust acceptance is evidence only and must not be copied; Android must not suppress trust failures and continue silently
- Decision: `C. RECORD A DOCS-ONLY TLS / IDENTITY DECISION BLOCKER BEFORE ANY PAIRING CODE` — runtime pairing blocked until approved TLS-bootstrap and canonical bridge-ID contracts exist; pairing remains the next runtime feature, gated
- Contract-freeze updated near the pairing + certificate-trust sections; foundation scaffold plan updated near the ANDROID-006A roadmap row; both link the new decision record
- No Kotlin, Swift, tests, manifest, Gradle, dependency, or runtime changes
- No network probe performed
- No commit or push in this pass

---

## 2026-07-09 - [Claude] BUILD 21 — Scenes excellence: QR sharing, 56 built-ins, engine honesty

### Branch
- `main` (8 commits). Rollback: `git reset --hard checkpoint/scenes-excellence-2026-07-09`
  (tag @ `c971704`, build 20).

### Did
Eight independently shippable commits, in order:

1. **`ea88643` three-row tray header.** The mixer-tray header was one HStack holding an icon,
   name+room, up to five badges (one a full sentence), and up to four 34pt action circles —
   ~170pt incompressible on a 360pt phone. Nothing had a `lineLimit` anywhere in the header, so
   every `Text` absorbed the squeeze and wrapped character-by-character. Now: row 1 identity +
   actions (name scales, never truncates), row 2 a horizontally scrolling badge lane, row 3 the
   transport sentence at full width. `StageBadge` refuses to wrap app-wide; `StageSheetScaffold`'s
   principal title scales to fit. `MixerTrayMetrics.headerBlockHeight(hasStatusLine:)` pays for
   the rows; the status line is *reserved*, not measured, so a transport switch doesn't resize
   the tray.
2. **`eae40a8` rolodex compaction.** `stageHeight` 148→96 (exactly 3 × 32pt detents), lens 42→36.
   Zone A: 194pt → ~134pt. `cardGrid` is already `maxHeight: .infinity` so it absorbs the gain.
3. **`db7bf4c` QR + link scene sharing.** `lightshade://share?d=<base64url(zlib(json))>` carries
   the whole scene — no backend, no account. A preset encodes to ~600B (a version-18 symbol).
   Versioned envelope refuses a v2 payload rather than misdecoding it. Identity and provenance
   (`id`, `createdAt`, `isBuiltIn`, `aiPrompt`) stay home, so importing a shared "Ocean Drift"
   can't overwrite the recipient's built-in. `DeepLinkCoordinator` decodes but never saves;
   Studio owns the only `CompositionStore`, so the confirm + save happen there.
4. **`b453825` transport menu honesty.** `UnifiedOrchestrator.entertainmentAvailability(for:)` —
   synchronous, no network — disables the streaming option with a reason instead of letting the
   effect silently demote to REST. Three-valued: a nil dict assignment removes the key, so
   `entertainmentConfigsFetchedBridges` records what we *asked*, and `.unknown` still offers
   streaming. Also "Preferred Engine…" on a saved preset (was save-time only).
5. **`8426331` bridge-native dynamic scenes.** The export read `palette.color1/color2` directly —
   wrong in spectrum mode (colours come from the hue wheel) and temperature mode (from mirek).
   New pure `BridgeDynamicSceneExporter` samples through `PaletteConfig.color(at:)`. Promoted to
   "Save to Bridge…" on any saved preset. Deleted `uploadV2DynamicScene` +
   `V2DynamicSceneManifest` (~105 lines, zero callers, built a scene with no `palette` block and
   recalled it as `dynamic_palette` — nothing to cycle).
6. **`358c3e9` six built-ins showed impossible colours.** Ocean Drift / Storm Chase / 4th of July /
   Hanukkah shared an out-of-gamut deep blue; Valentine's Glow a pink; St. Patrick's a green that
   is nearly gamut *A*'s primary. New `PresetCatalogTests` is the bar, including a 3Hz
   photosensitivity limit (WCAG 2.3.1).
7. **`e4aee25` `BuiltInSeedMigrator`.** The seed is create-only (M-13), so new presets — and the
   gamut fixes above — would never reach an existing install. Reconciles in memory on every load.
8. **`2d3502d` +36 built-ins (20 → 56)** across nature / cosmic / cozy / focus / cinematic, plus
   five energetic. Every stop computed sRGB → CIE xy → projected into gamut C.
9. **`602ee94` firmware-effect honesty.** Cosmos on a room of white-only bulbs sent PUTs, got 400s,
   discarded them, and printed "🟢 Cosmos → Kitchen" over a dark room.
   `EffectCapabilityResolver.routing` now answers `.run` / `.unsupported` / `.runUnverified`.

### Working
- Full suite green, twice in a row, on `iPhone 15 / OS 17.0`.
- Device build (`generic/platform=iOS`) green. Build bumped to **21** (all 12 pbxproj entries).

### Left
- **Brian's on-device pass for build 21.** Specifically:
  - Mixer tray with a long scene name ("Winter Wonderland") in a long-named room, bridge-stored
    banner visible, at accessibility Dynamic Type. Nothing should wrap mid-word.
  - Studio deck should feel taller (rolodex gave back ~60pt).
  - **Share…** on a composition → QR renders → scan it from a second phone (or paste the link)
    → import preview → "Add to My Scenes". The in-app scanner needs a real device (VisionKit's
    DataScanner does not exist in the Simulator).
  - **Save to Bridge…** on a gradient preset, then close the app: the lights should keep cycling.
    Then try it on a *spectrum* preset — the colours should now match what the Composer shows.
  - Transport menu on a bridge without an entertainment area: "Entertainment Area (Streaming)"
    should be greyed with a reason, not silently fall back.
  - Deck 0: run Cosmos on a room of white-only bulbs → expect "⚠ No lights in X can run Cosmos",
    not a green success.
  - Composer deck: 56 presets, 10 category chips. Existing installs should gain the 36 new ones
    (the migrator runs on load) without losing anything the user edited.
- The TEMP `⏱️PERF` prints (RoomDetailView + `loadAll`) are still pending removal from build 9.

### Validation
```
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' build
xcodebuild test -project HueHome.xcodeproj -scheme "HueHome 1" \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0'
```
New suites: `ScenePayloadCodecTests`, `SceneQRRendererTests`, `EntertainmentAvailabilityTests`,
`BridgeDynamicSceneExporterTests`, `PresetCatalogTests`, `BuiltInSeedMigratorTests`,
`EffectRoutingTests`. New files registered via `add_scene_sharing_files.rb` (idempotent).

### Gotchas
- **`SceneQRRendererTests` decodes with `CIDetector`, not Vision.** VisionKit — what the in-app
  scanner uses on device — needs a neural inference context that does not exist in the Simulator.
  It throws `"Could not create inference context"` for *every* image, valid or not, so it cannot
  serve as a test oracle. This cost an hour; don't rediscover it.
- **Gamut C is NOT a superset of A and B.** A's green primary (0.2151, 0.7106) is more saturated
  than C's (0.170, 0.700). C is the target because it's the modern colour bulb and what the
  Composer previews with (`activeCompositionGamut` defaults to `.c`), not because it contains
  them. St. Patrick's green was authored against gamut A.
- **A `scatter` pattern over a `temperature` palette renders every light identically.** Scatter
  varies only phase (its weight is a constant `1.0`) and `PaletteConfig.color(at:)` ignores phase
  in temperature mode. Two of the new presets were written that way and had to be given gradients.
  `PresetCatalogTests.testMovingPresetsSpreadAcrossLights` catches this class.
- **Deck 0's cards are defined in `StudioViewModel`, not `EffectLibrary`.** Auditing
  `HueEffect.params` (speed `1...10`, key `"color"`) and concluding the v2 sender is wrong is a
  trap — the real `StudioParam`s are speed `0...100` and `"base_color"`, which is exactly what
  `applyStudioEffectV2Parameters` reads. `EffectLibrary` remains live via automations.
- **`BuiltInSeedMigrator` matches on preset id.** A built-in written with `UUID()` would get a
  fresh id every launch: re-added forever, never refreshed. `PresetCatalogTests` now enforces the
  hand-assigned `0000000X-0001-0001-0001-...` scheme.
- The migrator adds **no write path**. Persisting during load would race the create-only seed and
  `ensureLoadedForMutation`'s sync load, and re-earning M-13's guarantees isn't worth it. The
  merged library is what the UI reads; the file catches up on the next ordinary save.
- `KeychainSharingTests.testForgetAllClearsSharedCredentialSurface` failed **once** in a full run,
  then passed in isolation and in two consecutive full runs. Order-dependent Keychain state,
  pre-existing, not introduced or fixed here. Worth a look if it recurs.

---

## 2026-07-09 - [Claude] BUILD 22 — Studio Round 2: audit fixes, room scoping, rename, parity

### Branch
- `main` (9 commits). Rollback: `git reset --hard checkpoint/studio-round2-2026-07-09`
  (tag @ `6285371`, build 21).

### Did
1. **`d601564` audit fixes.** CompositionStore.delete() reset built-ins by NAME — a renamed
   built-in ("Fireside" → "My Fire") was neither reset nor removed, permanently stuck. Now keys
   on id; a retired built-in (no catalog entry) actually deletes. Unsupported firmware effects
   now restore a room we switched on back to off (only if WE lit it). Scanner drain guarded
   against sheet-on-sheet; `acceptShareLink`'s no-openToken-bump documented as load-bearing.
2. **`a04f434` one brand.** Watch app + widget installed as "LightShade"/"LightShadeWatch"; the
   watch title, widget faces, gallery names, Siri failure strings, and notification fallback
   said "CastChroma". All six pbxproj display names + ten string sites now say **ChromaGlow**.
   Untouched: bundle IDs, target/folder names, keychain/OSLog `com.lightshade.app` (L-35).
3. **`5c86ab0` room-scoped presets.** iOS RoomDetail gains the Energize/Read/Relax/Sleep row it
   never had (ONE grouped_light PUT, optimistic + rollback). Watch room detail chips were
   whole-home INSIDE a room — now scoped via `applyPreset(_:to:)`. Room-pinned widget face
   (FocusedMediumWidgetView) gains a scoped preset strip; `ApplyPresetIntent.groupID` is
   optional so every existing widget keeps working. The four presets are now ONE definition:
   `LightingPreset` (pure Foundation, compiled into app+widget+watch); four hand-synced copies
   deleted.
4. **`eacd03d` Composer categories.** "All" groups into collapsible category sections (user's
   creations first, seasonal Holiday pinned second; collapse state persists). Save sheet gains
   a Category chip row; "Move to Category…" in every preset's overflow menu.
5. **`85573c9` tap-to-type sliders.** Tap any StageSlider readout → numeric field, parser
   accepts the formatted text as-is ("120 BPM", "64%", comma decimals), clamps to range,
   rejects garbage. Commit brackets onEditingChanged like a drag so debounce paths fire.
   One component, 21 call sites, zero call-site changes.
6. **`48fe15b` engine parity + storm depth.** Composer's hue/sat pad extracted to StageKit
   `HueSaturationPad` (gamut-clamped per sample); engine-card `.colorPicker` params get the pad
   + My Colors in the param sheet (compact tray keeps swatches — height math holds).
   Thunderstorm's hidden tunables became params: `flash_color`, `strike_rate`, `flash_length`,
   `afterglow` — consumed by BOTH the 50fps DTLS loop and the REST fallback; REST finally
   honors ambient/flash colors. Defaults reproduce the old storm exactly. Param-truth allowlist
   extended.
7. **`71daa46` room color popup.** Hold any room/zone card (~0.45s) → color wheel + brightness +
   harmony chips (with live anchor preview) + My Colors. Single color = one grouped PUT;
   harmony = per-light spread via pure `RoomColorWashPlanner` (HarmonyEngine anchors cycled,
   gamut-clamped, SavedColor.application capability degradation, batches of 5 @ 150ms).
8. **`6b21b60` cross-surfacing.** `PresetSurfaceClassifier` (derived, never stored): reactive →
   Live deck, static-steady-silent → scene, else → Effects deck. Decks 0/1 gain "From Composer"
   sections (full cards). Scenes tab gains a "Studio scenes" shelf — tap → pick a room → a REAL
   bridge scene is created there (exporter recipe, STUDIO provenance badge).
9. **`(this)` build 22 + docs.**

### Working
- Full suite green after every slice; final full run green. All four schemes build
  (main app, widget ext, watch app, watch extension — the extension via its Slice-1 build;
  the physical-watch destination was unreachable for later rebuilds, and no later slice
  touched that target).

### Left — Brian's on-device pass for build 22
- Watch home screen + iPhone widget gallery say **ChromaGlow** (fresh install may be needed
  for Springboard to drop cached names).
- **Energize inside a room** changes only that room: iOS RoomDetail row, watch room detail,
  room-pinned widget face. Dashboard bar + watch home + generic widget still whole-home.
- Renamed-built-in regression: rename a built-in composition, delete it → it resets.
- Run Cosmos on a white-only room that was OFF → warning AND the room goes back off.
- Hold Living Room card → popup; try Single and a Triad spread; check a CT-only/dimmable bulb
  joins at the right brightness.
- Thunderstorm: change Flash Color / Strike Chance / Flash Length / Afterglow live, on both
  streaming and REST (kill the entertainment area to force REST).
- Tap a BPM readout, type 120 — exact value lands; garbage cancels.
- Composer deck: sections collapse and persist; save sheet Category; Move to Category….
- Deck 0/1 "From Composer" sections; Scenes tab "Studio scenes" shelf → add to a room →
  the scene appears in that room with the STUDIO badge and runs from the bridge.

### Validation
Same commands as build 21 (scheme `HueHome 1`, iPhone 15 / OS 17.0 sim). New suites:
`CompositionStoreTests`, `RoomColorWashPlannerTests`, `PresetSurfaceClassifierTests`; extended:
`StudioEffectsV2Tests` (restore-off), `StageKitTests` (parseDraft), `StudioParamCatalogTests`
(section order, thunderstorm allowlist).

### Gotchas
- **`.equatable()` on RoomCard excludes closures from ==** — the new onLongPress closure is
  invisible to diffing, which is correct (it never changes identity) but means don't put
  state-dependent values inside it.
- **StageSlider's numeric field uses `.numbersAndPunctuation`, not `.decimalPad`** — the decimal
  pad has no Return key, which would make tap-away the only commit.
- **The Scenes tab reads compositions via `CompositionStore.readPresets(from:)` snapshots** —
  deliberately NOT a second live store (Studio owns the only mutable one). Refresh happens per
  tab activation; a save made in Studio appears on next visit.
- `WatchPreset` now reads label/icon/brightness/mirek from `LightingPreset` — the enum survives
  only for its watch-tuned chip colors and its `String` raw values.
- The widget `ApplyPresetIntent` dropped its unknown-id fallback (was: apply (60, 350)); an
  unknown preset id now no-ops.

## 2026-07-09 - [Claude] BUILD 23 — Engine coherence run 1: the three engines become one system

### Branch
- `main` (8 commits, `51f7862..`; rollback tag `checkpoint/coherence-run1-2026-07-09` —
  revert = `git reset --hard checkpoint/coherence-run1-2026-07-09`)

### Did
Source: the Studio/DJ/live-FX coherence deep-dive (three-agent exploration, plan
`warm-booping-dream`). Verdict was "coherent core, thrown-together connective tissue" —
this run fixed the connective tissue. One shippable commit per fix:

1. **Tap-Dial unmapped buttons no-op** — `?? 1` fallback fired phantom tap-tempo (re-pinning
   the clock) for any button whose control_id never resolved. SSE regression test.
2. **Shared now-playing registry** — `UnifiedOrchestrator.activeEffectEntries` had a writer
   API with ZERO callers; the Dashboard Now-Playing bar never rendered and Tap-Dial punch read
   an empty list forever. `StudioViewModel` now publishes at all five `runningEffects` write
   sites (+ rename re-publish) and removes at the `stopEffect` chokepoint. Dashboard Stop
   routes through the new `requestNowPlayingStop` → `studioStopHandler` (@ObservationIgnored)
   so the owning engine loop is torn down — the old path PUT `on:true` and left loops running.
   4 registry tests in `OrchestratorTests`.
3. **Per-room transport truth** — new `compositionTransportByRoom: [String: CompositionTransport]`
   (`.entertainment/.rest/.bridgeStored`), written only at start/stop/failover. Replaces the
   global `isBridgeStored` (wrong-room "BRIDGE ⚡" labels) and Perform's construction-time
   `isStreaming` snapshot (stale "⚡ STREAMING" + wrong punch branch after mid-set DTLS→REST
   failover). Tray badge/status + Perform header read live. Test in `MultiBridgeRoutingTests`.
4. **Per-room composition boxes** — `activeCompositionBox` was a single slot: with two rooms
   playing, the tray/Perform/revert edited whichever room applied LAST. Now a dict keyed by
   room id + a selected-room computed; stopping one room can no longer clear another's editor.
5. **Perform holds the mic demand** — `AudioDemand.performance` existed but was never set;
   the Perform beat panel advertised "Listening for a beat…" over a mic that never started.
   `begin()/end()` hold the refcounted demand; `anyCompositionNeedsMic()` also counts a
   mic-reactive deck-B cue (it previously read silence until promoted).
6. **Punch unification** — with Perform open, Tap-Dial buttons 2–4 engage the on-screen pads
   (strobe/blackout/burst, same room by construction, WCAG ≤3 Hz clamp in `applyPunch`) and
   release on lift (`punchRelease` mapping, `short_release`/`long_release`). Perform closed:
   signaling burst on the most recently started room (`.last`, was `.first`). REST STROBE pad
   alternates white↔deep blue (was white→white — a flash that could not flash); BURST is the
   steady white push. Mapping tests in `HueCapabilityFoundationTests`.
7. **bridgeOptimized one-shot guards** — one-shots have no live box and no render loop, yet
   the tray offered the full layer editor + Revert + Save + Perform (all silent no-ops; the
   Perform gate matches build-22's `PresetSurfaceClassifier` taxonomy: bridgeOptimized = scene).
   Now an honest notice pointing at the Scenes-tab Studio shelf. `SequencePlayer` bounds its
   fade wait (fade duration + 2 s grace, then lands manually) — a sequence can no longer hang
   forever awaiting a fade no render loop will clear. Async test in `BeatMathTests`.
8. **Honesty micro-pass** — iOS "Dim Flashing Lights" strobe 30% cap now real
   (`MADimFlashingLightsEnabled()`, MediaAccessibility; was hardcoded `false`), coverage badges
   clear on room switch instead of showing the previous room's counts, Perform's beat chip
   requests only capabilities its panel renders, dead `stop(_:)`/`selectedCard` deleted.

### Working
- Full suite green after every commit (511 → 518 tests, iPhone 17 Pro sim). Build bumped to 23
  (all 12 pbxproj entries).

### Left
- **Brian's on-device checklist (build 23):**
  - [ ] Start any Studio effect → Dashboard shows the Now-Playing bar; its Stop actually kills
        the loop (tray empties too); two rooms → dialog lists both, Stop All works.
  - [ ] Open Perform on a NON-reactive composition, play 120–128 BPM music → BPM readout locks
        within ~8 s (mic starts with the surface now); close Perform with no mic-reactive
        composition running → orange dot goes away.
  - [ ] DJ Mode + Perform open: dial buttons 2–4 punch the PERFORMING room with the on-screen
        pad semantics; holding engages, lifting releases. Perform closed: burst on the most
        recently started room.
  - [ ] Streaming composition, then kill bridge Wi-Fi >30 s mid-Perform → header flips
        ⚡ STREAMING → 🔌 REST live; STROBE pad then visibly alternates (REST burst).
  - [ ] Two rooms running compositions: tray badge + editor follow the SELECTED room; stopping
        room A leaves room B's editor intact; only a bridge-stored room says "BRIDGE ⚡".
  - [ ] Apply a still (bridge-optimized) Composer preset → tray shows the one-shot notice, no
        Perform/Save/Revert buttons; a sequence over it advances instead of hanging.
  - [ ] Settings → Accessibility → Dim Flashing Lights ON → Studio strobe runs at ≤30% brightness.
- Phase B (next run, needs decisions/pbxproj): extract live `RestSender` out of dead
  `SyncModeEngine.swift` + delete the dead Sync engines; Automations↔Studio arbitration via the
  now-populated registry; REST punch/scheduler contention; shared effect-identity table.
- Phase C (UX unification): one transport vocabulary + one TransportBadge, collapse the 4
  transport-selection surfaces, AUDIO status chip, Perform discoverability, card-art truth for
  cosmos/enchant/sunbeam/underwater.

### Validation
- `xcodebuild test -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
  full suite after each of the 8 commits + a final post-bump run; new tests:
  `OrchestratorSSETests` (unmapped button), `OrchestratorTests` (registry ×4),
  `MultiBridgeRoutingTests` (per-room transport), `BeatMathTests` (sequence fade deadline),
  `HueCapabilityFoundationTests` (punchRelease mapping).

### Gotchas
- `studioStopHandler` MUST stay `@ObservationIgnored` (closure var on an @Observable class).
- `compositionTransportByRoom` is written only at start/stop/failover — never per frame; keep
  it that way or the Studio tab invalidates at frame rate (same contract as CompositionParamBox).
- `activeCompositionBox` is now a get-only computed over `activeCompositionBoxes[selectedRoom.id]`;
  the editor's optional-chained field writes still work because `CompositionParamBox` is a class.
  The two ownership writes go straight to the dict — keyed by the APPLYING/STOPPING room, not
  the selected one.
- The Dim-Flashing-Lights API is `MADimFlashingLightsEnabled()` in **MediaAccessibility** —
  there is no UIAccessibility equivalent (that wrong guess is why it was stubbed `false`).
- Tap-Dial punch routing tests stop at the pure mapping layer; the orchestrator branch is
  6 lines of glue — covered by build + the on-device checklist.

---

## 2026-07-10 - [Claude] BUILD 24 — Copy/paste color on light cards + the first working Siri integration

### Branch
- `main` (13 shippable commits, rollback tag `checkpoint/copycolor-siri-2026-07-09` @ `df9711c`;
  revert with `git reset --hard checkpoint/copycolor-siri-2026-07-09`)

### Did
**Workstream A — light-card color copy/paste (RoomDetail, rooms + zones):**
- `ColorClipboard` (new, `Core/Models/`): app-wide session clipboard; pure `capture(from:)`
  rule — non-nil `colorTempMirek` means the light is IN CT mode (bridge nulls mirek in color
  mode), so mirek wins over stale xy; dimmable-only captures nil (Copy/Save hide); OFF lights
  copy their last-known look. Registered via `add_color_clipboard_files.rb`.
- Long-press on `CompactLightCard` → context menu (replaces the bare enter-select-mode gesture,
  which would race the menu recognizer): Copy Color · Paste Color (hidden until something is
  copied) · Save to My Colors · Identify · Select Lights. Menu attached at the ForEach call
  site (needs vm/armedColor/orchestrator scope), scene-chip precedent.
- **Sticky paint mode:** `applySavedColor` no longer disarms after one apply; the LIGHTS header
  swaps Select ↔ a "Painting · Done" pill (zero layout shift) while armed. Copy arms
  immediately; swatch arming is sticky too (one mental model). Paint and select mode are
  mutually exclusive. Leaving the room disarms (@State); the clipboard survives → cross-room
  menu Paste.

**Workstream B — Siri (the headline: `HueHome/Intents/` was dead code):**
- The four intent files were in NO target (zero pbxproj refs) — ChromaGlow had never shipped a
  working Siri command. `add_siri_intent_files.rb` registers the whole train (idempotent).
- Rewrote the foundation fixing two latent bugs: "Turn off X" phrases were bound to a Bool
  defaulting `true` (Bool can't be phrase-bound → `PowerState` AppEnum, two prefilled
  shortcuts), and entities were rooms-only (`HueGroupEntity` now serves rooms + zones with
  Room/Zone subtitles + case/diacritic-insensitive `EntityStringQuery` matching).
- 10 App Shortcuts (the hard cap, all slots used): power on / power off / brightness (number
  is Siri-prompted — ints can't live in phrases) / color / scene / preset / all lights /
  start composition / start effect / stop.
- `SiriColorTable`: 22 chromatic names via `HueColorUtils.xyFrom + clampXYToGamut(.c)` (legal
  by construction; test pins re-clamp stability to 1e-9 — saturated yellows project ONTO the
  gamut edge and re-project with ulp drift) + 5 whites as mirek 156/200/300/370/450.
- `HueSceneEntity`: app-target twin of the widget's SceneAppEntity (deliberate duplicate —
  dual-targeting a file inside the synchronized HueHomeWidget/ folder needs exception-set
  surgery; HueRoomEntity/RoomAppEntity set the precedent). Subtitled by owning room.
- Presets (Energize/Read/Relax/Sleep; optional room scope — unknown scope selects NOTHING
  rather than blasting the home), All Lights (ON = the widget's 80%/mirek-350 welcome-home
  contract), and fan-outs that name their failures (`partialFailure` dialogs, never silent).
- **Open-app intents:** `StartCompositionIntent` / `StartStudioEffectIntent`
  (openAppWhenRun = true) hand off via `DeepLinkCoordinator.shared.pendingStudioAction`
  (the pendingSharedScene pattern); MainTabView surfaces Studio; StudioView drains through
  `vm.apply(card, roomOverride:)` so runningEffects/the shared registry/mixer tray stay
  truthful. Cold-launch retries via ONE `task(id: siriDrainRetryKey)` — StudioView's body is
  at the type-checker's limit; stacking onChange modifiers broke the build (error at :437).
- `CompositionEntity` reads `compositions.json` via pure `readPresets` in-process (entity
  queries run in the app process) — no App Group snapshot, never stale; starter draft excluded.
- `StudioEffectChoice` mirrors the STUDIO deck catalogs (15 cards), NOT EffectLibrary (23,
  the automations surface); parity test pins ids + display names to
  `buildEffectCards()/buildLiveModeCards()` (made internal for the test).
- **Stop is a hybrid:** in-process notification → AppRootView loops `activeEffectEntries` →
  `requestNowPlayingStop(roomID:)` (the build-23 registry path — bare stopStudioMode/
  stopCompositionMode is the exact bug class b20f0ef fixed) + background grouped_light
  `no_effect` fan-out kills bridge-persistent candle/fire after app death. Lights stay on.
- Donation freshness: `updateAppShortcutParameters()` in `scheduleWidgetWrite()` (rides its
  500ms debounce) + injectable `CompositionStore.onPersist` (wired in HueHomeApp.init; nil in
  tests). `INAlternativeAppNames`: "Chroma Glow", "Hue Home".
- Widget-intent hygiene: `isDiscoverable = false` on the raw-param plumbing intents
  (ToggleRoomIntent/AdjustBrightnessIntent/WidgetPageIntent). Control-backing intents untouched.

### Working
- Full suite green, two consecutive runs at 548/548 (519 at the workstream-A gate; +29 new
  tests across ColorClipboard/entity/client/color-table/studio-intent suites).
- Build 24 in all 12 pbxproj entries.

### Left / on-device checklist for Brian (build 24)
**A — copy/paste color (repeat a pass in a ZONE):**
1. Long-press a light card → menu appears; plain tap still opens the light editor; power
   button still toggles without opening the menu; strip still scrolls.
2. Copy Color on a color-mode light → every card rings; tap 3–4 lights → each repaints,
   ring STAYS; Done exits. 3. Copy from a CT-mode light → paste onto CT bulb (mirek), color
   bulb (white via xy), dimmable (brightness only). 4. Dimmable-only card: no Copy/Save in
   menu; Paste still offered. 5. Copy → leave → other room → menu Paste works; paint mode NOT
   auto-armed. 6. Paste onto an OFF light turns it on in the color. 7. **Long-press while
   paint mode armed → menu still opens** (the one flagged risk; fallback: attach the same menu
   to the armed overlay). 8. Select Lights from menu ↔ paint pill mutual exclusion; drag-drop
   swatch still works and keeps paint mode.
**B — Siri (install, launch once, WAIT ~2–5 min for indexing; verify the Shortcuts app shows
10 ChromaGlow tiles first — that separates donation from recognition):**
1. "Turn on ⟨room⟩ in ChromaGlow" / off. 2. Same for a ZONE (name a room and zone alike →
   expect Room/Zone disambiguation). 3. "Dim ⟨room⟩ in ChromaGlow" → Siri asks the number
   (expected — ints can't be phrase-bound). 4. "Make my lights teal in ChromaGlow" → asks
   which room. 5. "Make my lights warm white in ChromaGlow" (CT path). 6. "Activate ⟨scene⟩
   in ChromaGlow" (duplicate names disambiguate by room). 7. "Set the lights to Relax in
   ChromaGlow" (whole home). 8. "Turn off all lights in ChromaGlow", then on (expect 80%
   warm). 9. "Start ⟨composer scene⟩ in ChromaGlow" → asks room → app opens → Studio running
   it; try warm, backgrounded, and killed-app cold launch. 10. Rename a composition, wait a
   minute, say the new name (re-donation). 11. "Start the Candle effect in ChromaGlow".
   12. Start candle → force-kill the app → "Stop the lights in ChromaGlow" → candle dies from
   background; with an app-driven effect running, same phrase stops it and Dashboard's
   Now-Playing bar clears. 13. Bare "turn on kitchen" (no app name) → HomeKit takes it —
   expected, phrases require the app name. 14. Bridge unreachable → honest error dialog.

### Validation
- `xcodebuild test` scheme "HueHome 1", iPhone 17 Pro sim — full suite green ×2 (verified via
  xcresulttool, not piped tail). Per-commit targeted suites during the run.

### Gotchas
- **`HueHome/Intents/` was never registered** — do not assume a folder on disk is in a target;
  the app target uses an explicit sources phase (only `HueHomeWidget/` is folder-synchronized).
- StudioView's body is at the Swift type-checker's ceiling: adding 4 modifiers produced
  "unable to type-check this expression in reasonable time" at :437. One `task(id:)` keyed on
  a combined string replaced four onChange modifiers.
- `CompositionPreset`'s memberwise init requires `seasonMonths/createdAt/updatedAt` — test
  fixtures must pass them.
- AppShortcut phrase rules (enforced at build by appintentsmetadataprocessor): ≤10 shortcuts,
  ≤1 dynamic param per phrase, AppEnum/AppEntity only — Bool/Int params are prompted, never
  spoken inline. On/off therefore ships as TWO shortcuts prefilled with a `PowerState` enum.
- Saturated yellow xy sits ON the gamut-C red–green edge: clamp-identity tests need 1e-9
  tolerance, not exactness (re-projecting an edge point drifts one ulp).

---

## 2026-07-10 - [Claude] Build 25: widget-scenes fix, builds-18–24 audit fixes, watch scenes face, Share Invite Phase 1

### Branch
- `main` (rollback tag `checkpoint/scenes-stop-invite-2026-07-10`; revert with
  `git reset --hard checkpoint/scenes-stop-invite-2026-07-10`)

### Did
- **Root-caused "scenes vanished from every widget"** (`d5f0ade`): the ONLY widget/watch
  publisher (`scheduleWidgetWrite`, fired from room/zone rebuilds) serialized `globalScenes`
  unconditionally — empty at launch because scenes load lazily after `loadAll` settles (the
  prewarm gate reorder made the empty write always land first), and `WidgetDataStore.write` +
  `WatchSessionManager.push` clobber stored data with `[]`. Scene mutations never republished.
  Fix: pure `scenesForPublish(hasLoaded:live:stored:)` preserves the stored snapshot until the
  first real scene load (post-load, empty propagates — delete-all stays honest); `loadAllScenes`
  republishes (+ reentrancy guard, demo parity); delete/rename republish; `loadAll` kicks ONE
  detached scene fetch per cold session; `forgetAllBridges` resets the flag. Bonus: Siri scene
  donations now refresh on launch + rename.
- **Siri stop honesty** (`ccc245f`): `requestNowPlayingStop(roomID:turnOffLights: Bool = true)`
  — still the only non-Studio stop path; Siri passes `false` so "Lights stay on at their
  current state" is finally true; Dashboard Stop unchanged (default true).
- **Room-scoped app-driven stop** (`ed5f47f`): `stopAppDrivenStudioEffect(roomID:bridgeID:)`
  replaces the global `stopStudioMode()` in `stopEffect`'s `.appDriven` branch — stops the
  single-slot loop + its bridge's ent session ONLY when no composition owns it. Stopping a
  Kitchen strobe no longer kills a Living Room composition + the whole Now-Playing registry.
  `stopStudioMode()` byte-identical for `forgetAllBridges`.
- **Stop-before-remove** (`4bb1572`): `removeBridge`/`deleteRoom`/`deleteZone` route doomed
  groups through `requestNowPlayingStop(turnOffLights:false)` BEFORE dropping clients; fixed
  removeBridge never clearing `zonesByBridge`/rebuilding zones (stale zones lived forever after
  removing the last bridge — `pruneStaleBridgeSnapshots` bails on empty clients); deletes now
  `scheduleWidgetWrite` so widgets drop the group immediately.
- **Move keeps ★ + history** (`f13dbbc`): `FavoriteSceneCSV.replacing` (in-place, order-
  preserving, deduping) + `SceneUsageStore.transfer/remove`; CopySceneSheet completion
  transfers on move, undo transfers BACK onto the recreated original (via
  `createSceneReturningID`) or scrubs; delete alert scrubs usage too.
- **Siri whole-home pacing** (`2001137`): `dedupedWholeHomeTargets` (rooms preferred; zones
  only for zone-only setups — documented trade-off: room-less zone lights are skipped) and
  `fanOut` now paces per bridge (sequential, 150ms gaps; bridges concurrent). Scoped commands
  unchanged.
- **Stale-mirek fix where it actually lives** (`57f039e`): NOT ColorClipboard (audit framing
  corrected — LightDisplayItem never carried mirek_valid) — the two SSE-apply sites kept old
  mirek on color-only events. `applySSEUpdates` nils it; `HueLight.applying` emits
  mirek:nil/mirek_valid:false with schema preserved. Fixes Copy Color capturing warm white
  after an official-app color change; also repairs `updateScene`'s CT fallback.
- **StudioView pressure relief** (`e686f92`): the three drain modifiers → one
  `StudioDrainWiring` ViewModifier (same file), behavior-identical; body sheds two modifiers.
- **Polish** (`99c9f2e`): `LightingPreset.welcomeHome` single source (Siri + widget Control);
  WidgetDataStore header now tells the truth; 10-shortcut cap documented at entry 10;
  donation-funnel no-rate-limit rationale documented at the onPersist install.
- **Watch face scenes** (`89ab403`): new second widget kind
  `com.lightshade.app.WatchSceneWidget` ("ChromaGlow Scenes", rectangular + inline) reading the
  watch-side mirror of `hue_widget_scenes_v1`; display-only (accessory complications are
  non-interactive) with `.widgetURL(lightshade://group/{roomID})` → watch app `onOpenURL` →
  existing watch RoomDetailView (which recalls scenes). No existing face-config migration.
- **Share Invite Phase 1** (`99fc6c0`): zero-secret "home-join" QR. `InvitePayloadCodec`
  (new `kind` on the existing versioned envelope; refuse-unknown both directions;
  `ScenePayloadCodec.probeKind` routes one URL host to many kinds). Owner: `ShareInviteSheet`
  from More (QR + ShareLink — NO secrets ride it; pre-D-016 records listed as "re-pair to
  share"). Guest: `JoinSharedHomeView` → per-bridge `BridgeSetupContent` seeded via the
  manual-IP seam + NEW `BridgeDiscoveryViewModel.expectedIdentity` (live-captured identity
  must match the invite BEFORE anything persists; QR pins verified-against, never ingested).
  Onboarding idle screen gains "Join a Shared Home" (scanner); tapped invite links route via
  `DeepLinkCoordinator.pendingInvite` (decode-only — the coordinator still never saves) to
  MainTabView (paired) or BridgeSetup (unpaired). Registered via `add_invite_files.rb`.
  Phases 2–4 designed in `docs/ios/profiles-access-share-invite-design-2026-07.md`
  ("Profiles & Access" stub stays Coming Soon).
- Build bump 24 → 25 (all 12 pbxproj entries); DEVLOG + AGENTS updated.

### Working
- Full suite green per commit; two consecutive green runs at round end. Watch targets
  verified compiling via the "LightShadeWatchApp Watch App" scheme (generic/watchOS).
- New tests: scenesForPublish selection (3), requestNowPlayingStop arity/threading (2 upd
  + 1 new), scoped-stop survival, stop-for-removed-groups, FavoriteSceneCSV.replacing (3),
  SceneUsageStore transfer/remove (4), whole-home dedupe (3), SSE stale-mirek (2),
  welcome-home single-source (upd), InvitePayloadCodecTests (11, incl. CIDetector QR
  round-trip and no-secrets-in-JSON).

### Left
- **Brian's on-device checklist (build 25):**
  1. Cold-launch with a scenes widget + watch face → scenes visible, never blank (kill+relaunch ×2).
  2. Rename/delete a scene → widget + "Activate ⟨scene⟩ in ChromaGlow" update in ~1s; delete
     ALL scenes in a room → that room's widget scenes honestly empty.
  3. Siri "stop the lights in ChromaGlow" while a composition runs → effect stops, lights STAY ON;
     Dashboard Stop → room goes off.
  4. Composition in Room A + strobe in Room B → stop the strobe from the bar → A keeps running,
     its entry + transport badge intact.
  5. Delete a room (and separately a bridge) mid-effect → bar entry clears, no ghost loop.
  6. Favorite a scene → Move to another room → ★ survives; Undo → ★ follows back.
  7. Whole-home "set the lights to Relax in ChromaGlow" → every room changes, none dropped.
  8. From the official Hue app paint a CT-mode light a color → ChromaGlow Copy Color captures
     the color (not warm white).
  9. Siri "Start Ocean Waves in the Bedroom in ChromaGlow" cold launch still drains; QR scene
     import still works (drain-wiring refactor regression check).
  10. Add the "ChromaGlow Scenes" complication → shows the pinned room's scenes; tap opens the
      watch app to that room.
  11. Share Invite (needs both phones): More → Share Invite on phone A → scan on phone B
      (camera or in-app "Join a Shared Home") → link-button step → paired to the correct
      bridge → dashboard. Link-tap variant: send the invite link in Messages and tap it.
- Invite Phases 2–4: per-guest minted keys, Profiles & Access UI + app-side enforcement,
  revocation (OPEN WITH the whitelist hardware spike on Brian's bridge) — see the design doc.
- Pre-existing: TEMP ⏱️PERF prints cleanup still gated on Brian's device verification;
  `.studioStopAll` notification is dead (posted, zero observers) — fold into that cleanup.

### Validation
- `xcodebuild test -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` green per commit (logs in session scratchpad); final state validated twice consecutively.
- Invite link handling is Simulator-testable: `xcrun simctl openurl booted "lightshade://share?d=…"`. Live QR scanning needs a physical device (VisionKit).

### Gotchas
- `scenesForPublish` preserve-rule: do NOT "simplify" to an unconditional write — the launch
  publish fires before scenes load and empties every scene surface (this round's headline bug).
- `stopStudioMode()` is now forgetAllBridges-only. Any new stop path must be room-scoped or
  route through `requestNowPlayingStop`.
- `fanOut` is deliberately sequential-per-bridge; don't "optimize" it back to a flat task group.
- The invite QR's `pinPK` is an expectation, never ingested — keep `expectedIdentity` checks
  BEFORE any Keychain write, and never put a token/clientkey in a share payload (Phase 2's
  token QR has its own rules: display-only, time-boxed, no ShareLink).
- `struct`s can't nest in generic functions (fanOut's Job is a typealias'd tuple for that reason).

---

## 2026-07-10 - [Claude] Build 26 — Family Sharing complete: Invite Phases 2–4 in one round

### What shipped (12 commits, `f3eac6b..`, tag `checkpoint/family-sharing-2026-07-10`)

1. `f3eac6b` refactor(pairing): `ApplicationKeyMinter` extracted verbatim from
   `performPairingRequest` — parameterized devicetype + generateclientkey; the VM keeps
   phase/Keychain/StartupTimeline. Preservation proof: SecretLogScrubTests H-04 pair passes
   UNCHANGED. Guest slug: `g-<slug≤12>-<4hex>` ≤ 19 chars.
2. `0110d08` feat(invite): `kind:"invite"` codec — token-bearing per-guest payload with
   expiry (TTL 15 min, accept grace ±5 min); refusals both directions; old builds refuse
   gracefully via `unsupportedKind`; size gates vs SceneQRRenderer thresholds.
3. `c30c79d` feat(profiles): `GuestProfile`/`GuestAccessGrant` (ADDITIVE SwiftData — Build-21
   upgrade is a lightweight migration), `GuestAccessGrantStore` (upsert = the re-scan update
   path; orphan pruning keys on ALL records so a disabled bridge keeps its grant),
   `GuestAccessPolicy` (nil grant passthrough; EMPTY ALLOWLIST FAILS CLOSED; scene filter =
   "scenes" feature AND allowed room; isGuestOnly truth table incl. mixed role).
4. `75921f6` fix(tests): KeychainManagerTests snapshot/restores the legacy slots it writes
   (pre-existing pollution that failed KeychainSharingTests when clones redistributed).
5. `deead8c` feat(profiles): THE choke point — `applyGuestAccessFilter()` inside
   rebuildAllRooms/rebuildAllZones (after `pruneStaleBridgeSnapshots`), prunes the per-bridge
   DICTIONARIES in place; `preloadCached` filters the SwiftData cache window; `loadAllScenes`
   filters scenes; `guestFeatures(for:)` + `guestAccessInfo` (observable) drive the UI;
   `gatedBulkWrite`/turnAllOff skip no-onOff bridges. configure() loads grants BEFORE its
   rebuilds — no flash of forbidden rooms, ever.
6. `436e3ea` feat(invite): owner minting — `GuestKeyStore`
   (`hue_invite_<profileID>_<bridgeRecordID>_token`, additive, sweep refuses foreign
   prefixes), `GuestInviteMintSheet` (per-bridge link-button mint; ≥1 allowed group or no key
   at all; QR display-only + photograph warning + countdown; regenerate reuses stored keys —
   no re-mint, no new whitelist entry; revoked specs refused). SecretLogScrub: mint logs
   carry no token and no `lightshade://` blob.
7. `8341432` feat(invite): guest accept — `GuestInviteAcceptor` engine + view + routing
   (`pendingGuestInvite`, kind dispatch in handle(), BridgeSetup scanner takes both kinds).
   Ordering contract: identity → Keychain → registrar → grant upsert → updateGuestGrants →
   addBridge → loadAll.
8. `1382e27` feat(profiles): Profiles & Access UI live (profile CRUD, room picker with
   stale-id hygiene, Generate Invite wiring, honest delete copy; DEBUG More row removed).
9. `a25e9a0` feat(profiles): guest experience — GuestAccessBanner + detail sheet (§5 copy
   verbatim), visibleTabs (Studio hidden guest-only; swipe/prewarm/deep-link guards),
   RoomCard/RoomDetail/CompactLightCard feature gates, guestLightSummary fallback, Scenes
   context-menu + create gating, Bridge Manager delete reruns updateGuestGrants.
10. `4205b09` feat(revocation): whitelist read/delete + H-03 — `maskWhitelistElement` in
    redactedPath + the four verb pre-logs + sanitizedForLog; `WhitelistEntry` textual forms
    pinned to displayID; delete outcome mapped ONLY from verify-by-re-read (pure, tested);
    `BridgeKeysView` = the shipped hardware spike.
11. `7599be2` feat(revocation): owner revoke — bridge delete best-effort, LOCAL WIPE ALWAYS,
    revokedAt set, report decides which §4 truth the dialog speaks.
12. `b39ea7c` feat(revocation): guest cooperative wipe — `onExplicitUnauthorized` at
    execute()'s status guard (401/403 only, pure rule pinned by tests),
    `BridgeAuthorizationMonitor` (storm-collapsing), MainTabView wipes granted bridges with
    a notice; owned bridges get re-pair advice only.

### Brian's on-device checklist (build 26)

1. **Two-phone invite (the headline):** phone A: More → Profiles & Access → New Profile
   (pick rooms + features) → Generate Invite → press link button → Mint → QR appears with
   countdown. Phone B: camera-scan (or onboarding "Join a Shared Home") → "You're in as
   ⟨name⟩" → Connect (NO button press) → dashboard shows ONLY the allowed rooms.
2. Phone B surfaces: widgets gallery + Control Center + watch + Siri ("turn on ⟨hidden
   room⟩ in ChromaGlow" must fail to resolve) show only allowed rooms; tab bar has no
   Studio when guest-only; swipe order correct; banner opens the honesty sheet.
3. Feature gates: a profile with onOff-only → phone B room cards show power but no
   brightness slider; light detail is the power-only summary page.
4. Re-scan update path: change the profile's rooms on phone A → Generate Invite → "New
   Code" → phone B re-scans → room list updates (no duplicate bridge in Bridge Manager).
5. Expired QR: wait out the countdown (or regenerate and use the OLD code) → phone B gets
   the honest expiry copy.
6. **The hardware spike:** More → Profiles & Access → "Keys on your bridges" → your bridge.
   RECORD IN DEVLOG which state fires: key list visible? "Try Remove" on the guest's
   disposable key → deletedVerified or the official-app fallback copy?
7. Revoke round-trip: phone A Revoke Access → if the spike showed deletes WORK, phone B's
   next command should 403 → automatic wipe + "your invite was revoked" notice; if deletes
   are refused, phone B keeps working and phone A saw the honest dialog.
8. Owned-bridge safety: on phone A (owner), nothing changed — no banner, Studio present,
   all rooms visible, scenes create/delete intact, Share Invite (home-join) still works.
9. Build-21-schema upgrade check if a TestFlight device is handy: install over the old
   build → opens clean (additive migration).
10. Demo mode: unaffected by everything above.

### Validation
- `xcodebuild test -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS
  Simulator,name=iPhone 17 Pro'` green per commit; final state validated with two
  consecutive green runs (667 tests).
- Invite LINK flows are Simulator-testable via `xcrun simctl openurl booted
  "lightshade://share?d=…"`; live QR scanning and the whitelist probe need physical devices.

### Gotchas / durable decisions
- The token invite QR is SECRET-BEARING: display-only, never ShareLink, never logged
  (SecretLogScrubTests gates both). The home-join QR remains zero-secret and shareable.
- `GuestInviteAcceptor` deliberately does NOT reuse `validateAndPersist(unattended:)` — no
  link button was pressed; the QR pinPK equality is the presence-equivalent. The
  never-overwrite-a-differing-pin rule is reproduced verbatim. Only LIVE captures persist.
- The choke point must stay INSIDE the rebuilds (and prune the DICTIONARIES, not just
  allRooms/allZones) — SSE lookups, updateRoom, and removeBridge read the dicts directly.
- Grant BEFORE addBridge in any future accept path — the first rebuild after integration
  must already be filtered.
- Guest keys mint with `generateclientkey:false`; `SharedBridgeInviteGrant` has no clientkey
  field — keep the leak structurally impossible.
- Whitelist elements are OTHER APPS' KEYS (H-03): anything that prints one must route
  through maskWhitelistElement / displayID. The four HueV1Client verb pre-logs used to log
  raw paths — fixed; don't reintroduce.
- Cooperative wipe: explicit 401/403 over pinned TLS ONLY. Never infer from timeouts/5xx.
  Owned (non-granted) credentials are never auto-wiped.

---

## 2026-07-10 - [Claude] Strict-concurrency warning cleanup (Brian's Xcode issue list)

Brian's post-build-26 Xcode build surfaced ~55 app-target "…this is an error in the Swift 6
language mode" warnings. Two commits, both suite-green (667), zero-warning clean build
restored across app+widget+watch (`xcodebuild clean build` → 0 warnings):

1. `067a71f` — the five the family-sharing round ADDED: four `#Predicate` fetches became
   fetch-all + `first(where:)` (the macro trips a KeyPath-Sendable warning on this
   toolchain; rows number a handful; matches the registrar idiom), one `_ = try?` (a
   @discardableResult doesn't survive try?'s optional wrapping), plus
   `nonisolated(unsafe)` on the new test stub statics.
2. `65cab4b` — everything that arrived with build 24 when `HueHome/Intents/` first joined
   the target: 42 stored `static var` AppIntents properties → computed (identical values);
   `StudioParam.format` + `StudioParamFormat.kelvin/.flashHz` → `@Sendable` (one root cause
   — this makes StudioCard Sendable, legalizing StudioCardView's nonisolated `==`);
   `composerStarterDraftPresetID` → `nonisolated static let`; **`DeepLinkCoordinator` is
   now `@MainActor`** (all consumers — onOpenURL, view bodies, both Siri perform()s —
   were already main-actor).

Durable facts:
- `#Predicate` is currently OFF the menu in app code — its macro expansion warns under
  strict concurrency. Use fetch-all + filter for the small tables; revisit when the
  toolchain fixes KeyPath Sendable-ness.
- AppIntents statics are COMPUTED properties in this repo. New intents must follow or the
  zero-warning build breaks.
- Any new DeepLinkCoordinator caller must be main-actor (it is @MainActor now); intents
  keep `@MainActor func perform()`.
- KNOWN, DELIBERATELY UNFIXED: the historic TEST-target warning pile (NSLock-in-async in
  ~8 test files, main-actor setUp field access in ~6, HueDataModelsTests' own #Predicate)
  — predates build 24, never appears in device builds. Its cleanup is a separate round.

## 2026-07-11 - [Claude] BUILD 27: App-Store-prep run — trademark fixes, compliance notices, 1.0.0, submission runbook

### Branch
- `main` (rollback tag `checkpoint/appstore-prep-2026-07-11`)

### Did
- Researched Apple's current (July 2026) submission requirements + audited the whole tree
  (3 explore passes + a design pass). Full findings + Brian's manual steps consolidated in
  **`docs/ios/app-store-submission-runbook.md`** (NEW).
- Trademark/naming: removed the "Hue Home" `INAlternativeAppName` (Info.plist); Lock-Screen
  widget label "HueHome • N on" → "ChromaGlow • N on" (last user-visible "HueHome").
- Signify developer-terms compliance: non-affiliation disclaimer in MoreView's app section +
  SettingsView's buildMetadataFooter + the hosted privacy policy; one-time photosensitivity
  notice on first Studio entry (added inside `StudioDrainWiring` — StudioView.body untouched
  at the type-checker ceiling), mentions the 3 flashes/sec cap + Dim Flashing Lights.
- Logging hygiene: 31 raw `print("[Composer]…"/"[Handoff]…"/"[Studio]…")` sites in
  UnifiedOrchestrator now route through a fileprivate `debugLog(_: @autoclosure)` whose body
  is `#if DEBUG` — Release consoles no longer see room names. The four already-gated
  `[Composer][REST]`/Telemetry prints were left as-is.
- Removed the TEMP ⏱️PERF diagnostics (loadAll.begin/fetch-done/total + room-open.begin/
  loaded and their `__loadStart`/`__diagStart` locals). KEPT: the `__seed` fast path in
  RoomDetailView.task, StartupTimeline itself, and the `loadAll.bridge-fetch.ok/FAIL` +
  `cache.write.done` marks (FAIL carries the Local Network permission-denial signature).
- Deleted the two empty placeholder AppIcon sets (widget + watch widget ext); explicit
  `CODE_SIGN_STYLE = Automatic` on the main target; bumped **1.0.0 build 27** (12+12 pbxproj
  entries) with the `ios-build-provenance.yml` assertions updated in the same commit;
  refreshed AGENTS.md/CLAUDE.md version facts.
- Hosted pages (GitHub Pages, this repo `main:/docs`): privacy policy now covers camera + 
  location (it only covered mic + local network — reviewers cross-check against permission
  prompts), notes discovery.meethue.com, adds the Signify disclaimer; support page de-beta'd,
  stale "Sync tab" copy fixed, links point at the renamed ChromaGlow repo.

### Working
- Two consecutive full-suite runs green at the final tree (667/667 each; per-commit gates
  green throughout — see Validation).
- Release-config build verified: app/widget/watch Info.plists all report 1.0.0 (27); all
  four bundles carry PrivacyInfo.xcprivacy; watch Assets.car contains AppIcon; the debugLog
  autoclosure never executes in Release (only a dead 12-byte "[Composer] " constant-pool
  fragment survives — no runtime output).

### Left
- Brian's ASC pass per the runbook: age rating questionnaire, privacy label (Data Not
  Collected), DSA trader status, metadata + screenshots (iPhone 6.9" + iPad 13" + watch),
  iPad QA smoke, archive/upload build 27, review notes + demo video, submit.
- Builds 18–26 on-device verification items still pending (two-phone family-sharing
  checklist etc.) — fold into the build-27 TestFlight smoke.

### Validation
- `xcodebuild test … -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
  green after the photosensitivity commit, after the PERF removal, and twice consecutively at
  the end (xcresulttool-verified 667/667 each time). Per-commit generic-platform build gates
  green. Release build with `CODE_SIGNING_ALLOWED=NO` green.

### Gotchas
- **FALSE POSITIVE, do not "re-fix":** the widget/watch/watch-app targets have EMPTY
  Resources build phases in project.pbxproj — that is objectVersion-70
  `PBXFileSystemSynchronizedRootGroup` behavior (membership computed at build time). Their
  privacy manifests and asset catalogs DO ship (verified in built products). Adding explicit
  Resources-phase entries creates duplicate membership → "Multiple commands produce…" failures.
- The dead `isPro` field on the SwiftData `AppSettings` model was deliberately left (schema
  migration risk); `INFOPLIST_KEY_NSHumanReadableCopyright` is empty on extension targets —
  both parked in the runbook appendix.
- App-name risk register (accepted): Apple's Logic Pro has a "ChromaGlow" plug-in feature;
  Big Star Lights sells a "Chromaglow Controller" (lighting hardware). Keep first-use evidence.
- **StudioView.body no longer type-checks on Xcode 26.3** ("unable to type-check this
  expression in reasonable time") — surfaced on the FIRST CI compile since build 19 (nothing
  was pushed during builds 20–26). Local/shipping Xcode 26.4 handles it; the provenance
  workflow now prefers `Xcode_26.4.app` (falls back 26.3) and is green. The body remains at
  the ceiling: the next Studio change should extract a subview rather than add anything to it.
