# ChromaGlow iOS Feature Roadmap — 2026-07

Gap analysis + prioritized implementation roadmap, produced 2026-07-09 from a full code audit
(verified against `main` @ build 18). Priorities reflect Brian's picks: **Automation power-up,
Sensors & switches, Presence & away, Media & gradient — all four — plus differentiators no other
Hue app has.**

Companion work already approved and in flight (not in this doc): the Scenes overhaul
(grouped-by-room IA, saved colors with drag-to-light, scene copy/move between rooms).

---

## 1. What the app already has (verified inventory)

| Area | Surface |
| --- | --- |
| Control | Dashboard rooms/zones, RoomDetail per-light, multi-bridge, All Off, optimistic writes + SSE live state |
| Scenes | List/activate/capture/build/rename/delete/favorite; native **dynamic scenes** incl. speed; global scenes across bridges |
| Creative engine | Studio decks (firmware effects incl. effects_v2 params/coverage), **Composer** (palette/motion/envelope/reaction layers, spatial motion), DJ Perform + step sequencer, mic sync (`AudioAnalysisEngine`, tempo estimation) |
| Firmware effects | candle, fire, prism, sparkle, cosmos, enchant, colorloop (per-light, bridge-native) |
| Entertainment | DTLS/UDP streaming (`HueEntertainmentClient`), Entertainment Areas create/rename/delete UI |
| Circadian | **All Day Scenes** — solar-curve auto-adjust (5-min cadence, lat/lon anchor). Rare among competitors |
| Automations | Time-of-day + weekday, preset (energize/read/relax/sleep) or effect, **all rooms only** |
| System integration | Home Screen widgets, iOS 18 Lock Screen **Controls** (room toggle/scene/preset/all-off/All Lights), App Intents/Siri, watch app + complications, deep links |
| Physical controls | Tap Dial → DJ Mode (tempo/punch) via `ControlMappingEngine` |
| Infra | Keychain-stored credentials, TLS pinning, SSE event bus, demo mode, diagnostics timeline |

**"Coming Soon" stubs already in More:** Profiles & Access, Share Invite (QR).

## 2. Gap analysis (exists / partial / missing)

| Feature | Status | Evidence |
| --- | --- | --- |
| Scene scheduling (fire a saved scene at a time) | **MISSING** | `AppAutomation` fires presets/effects only |
| Wake-up / go-to-sleep fades | **MISSING** | No brightness-ramp automation; `timed_effects` (bridge-side sunrise/sunset) decoded but unused |
| Sunrise/sunset automation triggers | **MISSING** | Solar math exists only inside All Day Scenes |
| Per-room automation targeting | **MISSING** | Automations apply to all rooms |
| Motion sensor rules | **MISSING** | Motion devices shown as badges only (`DeviceDisplayItem`) |
| Button/dimmer/Tap-Dial user mapping | **PARTIAL** | `button`/`relative_rotary` SSE handled, but hard-wired to DJ mode |
| Geofencing home/away | **MISSING** | CLLocation used once for solar anchor; no region monitoring |
| Vacation / presence mimic | **MISSING** | — |
| Screen/video sync | **MISSING** | iOS can't capture other apps' audio/video; in-app/AirPlay contexts only |
| Music sync beyond mic | **MISSING** | Mic tap only |
| Gradient strip per-segment editor | **PARTIAL** | Backend exists (`HueAPIClient+Gradient`, `GradientChannelMap`); no UI |
| Energy/power insights | **MODEL-ONLY** | `EnergySnapshot` SwiftData model registered, surfaced nowhere |
| HomeKit / Matter bridge-through | **MISSING** | — |
| Backup/restore of app config | **MISSING** | — |
| Import from official Hue app | **MISSING** | No public API for this; low feasibility |
| Zones, dynamic scenes, adaptive lighting, entertainment UI | **EXIST** | see inventory |

## 3. Prioritized roadmap

Sequenced by user value ÷ effort and by dependency. Each phase is shippable alone.
Effort: S ≈ a day, M ≈ 2–4 days, L ≈ a week+ of focused runs.

### R1 — Automation power-up (highest value, nearest term)

Extends `AppAutomation`/`AutomationsViewModel`/`CreateAutomationView`; local notifications remain
the scheduler until a bridge-side option is added per item.

| # | Item | Effort | Notes |
| --- | --- | --- | --- |
| R1.1 | **Scene scheduling** — automation action = any saved scene (per-room by nature) | M | Reuses `GlobalSceneItem` + `activateGlobalScene`; picker UI mirrors widget scene intent |
| R1.2 | **Per-room targeting** for preset/effect automations | S | Add `targetGroupIDs` to `AppAutomation` (additive Codable) |
| R1.3 | **Wake-up fade** (sunrise alarm: 0→target over N min) & **sleep fade** | M | Prefer bridge-native `timed_effects` (sunrise/sunset) where the light supports it — works with app closed; app-driven ramp as fallback |
| R1.4 | **Sunrise/sunset triggers** (± offset) | S/M | Reuse All Day Scenes' solar calculator + stored lat/lon; recompute next-fire daily |
| R1.5 | Automation reliability pass — background delivery expectations, missed-fire recovery on launch | S | Local notifications don't run code in background; document + reconcile-on-open |

**Caveat to design around:** app-side schedules only fire reliably when the notification is
tapped / app opens. For "lights change with nobody touching the phone," R1 items should prefer
**bridge-side** mechanisms (v1 schedules API via `HueV1Client`, or `timed_effects`) — worth a
one-day spike (R1.0) to pick the mechanism per item before building UI.

### R2 — Sensors & switches (the "my whole house works in ChromaGlow" unlock)

| # | Item | Effort | Notes |
| --- | --- | --- | --- |
| R2.1 | Read + surface motion/temperature/light-level sensors (CLIP `motion`, `temperature`, `light_level`) in Devices | S | Read-only first; SSE already delivers the events |
| R2.2 | **Motion rules**: motion → scene/on, no-motion N min → off, with time-of-day condition | L | Bridge-side v1 rules (works without app) vs app-side SSE handling (richer, app-dependent) — decide in a spike like R1.0; the bridge's own CLIP `behavior_script` is a third option |
| R2.3 | **User-mappable switches**: dimmer/Tap-Dial buttons → scene/room actions | M/L | Generalize `ControlMappingEngine` beyond DJ mode; UI = per-button action picker in Physical Controls |
| R2.4 | Temperature display on dashboard cards (sensor-equipped rooms) | S | Pure UI once R2.1 lands |

### R3 — Presence & away

| # | Item | Effort | Notes |
| --- | --- | --- | --- |
| R3.1 | **Geofenced home/away**: leave-home action (all off / eco), arrive-home scene | M/L | `CLMonitor`/region monitoring; new Always-location permission surface + privacy manifest update; works only while phone-side — set expectations |
| R3.2 | **Vacation mimic mode**: replay typical evening usage with ±jitter | M | Feeds off `SceneUsageStore` (built in Scenes overhaul Phase 2) — history of what actually runs when; bridge-side v1 schedules make it work while away |
| R3.3 | Home/away status tile + manual override | S | Pairs with R3.1 |

### R4 — Media & gradient

| # | Item | Effort | Notes |
| --- | --- | --- | --- |
| R4.1 | **Gradient per-segment editor** — paint each segment of a strip/Signe | M | Backend half-exists (`HueAPIClient+Gradient`, `GradientChannelMap`); UI = segment strip in LightControl + SceneColorBuilder |
| R4.2 | **In-app music sync**: play Apple Music/local files in-app, analyze the *decoded* audio (not mic) | L | MusicKit playback + `AVAudioEngine` tap on the player node; far cleaner beat data than mic |
| R4.3 | Mic-pipeline upgrades: genre presets, sensitivity auto-cal | S/M | Incremental on `AudioAnalysisEngine` |
| R4.4 | Screen sync — **scoped honestly**: in-app camera/screen-share contexts only | — | iOS forbids capturing other apps' output; recommend NOT building until a real use case; revisit with macOS companion idea (see D8) |

## 4. Differentiators — features no other Hue app has

Ranked by (uniqueness × feasibility on existing infra). These are the "why ChromaGlow" features.

| # | Idea | What it is | Reuses | Effort |
| --- | --- | --- | --- | --- |
| D1 | **Live Activity / Dynamic Island for running effects** | Running composition/effect shows in the Island: name, palette strip, stop/intensity controls | Effect state + App Intents + widget snapshot plumbing | M |
| D2 | **Focus-mode lighting** | iOS Focus (Work/Sleep/Gaming) automatically triggers a scene via Focus filters | App Intents (`SetFocusFilterIntent`); tiny surface | S/M |
| D3 | **ShazamKit "Now Playing palette"** | One tap: identify the song playing in the room → pull its album-art palette → feed the Composer palette layer | Mic pipeline + Composer palettes + `HueColorUtils` | M |
| D4 | **RoomPlan/LiDAR 3D light placement** | Scan the room, place lights in real 3D, drive the *existing* spatial motion engine (angles/radial/spiral already in `CompositionParamBox`) outside entertainment areas | Spatial engine + `computeSpatialPositions` | L |
| D5 | **Composition sharing (file/QR)** | Export a Composer preset as a `.chromaglow` file / QR; import on a friend's phone. Fills the "Share Invite" stub | `CompositionStore` JSON + Transferable (built in Scenes overhaul Phase 4/6) | M |
| D6 | **Knock/doorbell flash (accessibility)** | Mic onset detection flashes chosen rooms — deaf/hard-of-hearing alerting | `AudioAnalysisEngine` onsets | M |
| D7 | **Countdown lighting** | "Bedtime in 20 min" — room dims stepwise to zero; pomodoro color shifts; kid-friendly | Ramps + App Intents | S/M |
| D8 | **Energy insights** | Estimated Wh per room/day, "left on while away" nudges — `EnergySnapshot` model already registered, zero UI | SwiftData model + dashboard | M |

Suggested first two: **D1 + D2** — both small, highly visible, and no competitor has either.

## 5. Suggested sequencing

1. **Now (this run):** Scenes overhaul (approved plan) — lands SceneUsageStore (feeds R3.2),
   Transferable infra (feeds D5), scene-detail fetch (feeds R1.1 previews).
2. **Next run:** R1.0 spike (bridge-side vs app-side scheduling) → R1.1 → R1.2 → R1.4, plus
   D2 (Focus) as the quick differentiator.
3. **Then:** R2.1 → R2.3 → R2.2 (rules engine after the spike), D1 (Live Activity).
4. **Then:** R3.1 geofencing (permission/privacy review first — see AGENTS.md telemetry rules),
   R3.2 vacation mimic, D7/D8.
5. **Creative track (interleave as desired):** R4.1 gradient editor → D3 ShazamKit → R4.2
   in-app music sync → D4 RoomPlan.

## 6. Standing constraints (from AGENTS.md — apply to every roadmap item)

- Local-first: no cloud routing for control/discovery/entertainment; credentials never leave device.
- No custom effects payloads to `grouped_light`; per-light REST batched/staggered; latest-wins mailbox.
- Location/room names/etc. stay out of telemetry without explicit review; geofencing (R3.1) needs a
  privacy-manifest + permission-string review before build.
- New always-on animation surfaces must consume `\.isTabActive`.
- iOS 17 deployment target: Live Activities OK; iOS 18-only APIs (some Controls/Focus surfaces)
  need availability gating.
