# Master On-Device Checklist — builds 18–28 (consolidated)

**Purpose:** ONE de-duplicated pass covering every on-device verification Brian still owes from
builds 18–28, merged from the per-build DEVLOG checklists + the parked agents' "Left" items,
ordered by surface so a single walk through the app covers everything. Sources: DEVLOG entries
for builds 18 (:646), 19 (:590), 20 (:519), 21 (:7031), 22 (:7141), 23 (:7231), 24 (:7343),
25 (:7468), 26 (:7561), 27 (:7686), 28 (:439) — line refs as of 2026-07-17. Where a later build
re-tests the same behavior, only the latest form appears here (supersession notes at the bottom).

**How to use:** install the CURRENT build on your main iPhone (28 or later — later builds carry
all earlier fixes). Items tagged `[2-phone]` need the second phone; `[fresh]` need a
delete-and-reinstall; `[TestFlight]` is the upgrade check. Origin build in brackets so you can
find the full DEVLOG context. Record failures in DEVLOG with the item tag.

---

## 0. Prerequisites

- [ ] Current build installed from `main` (Xcode → iPhone, scheme `HueHome 1`).
- [ ] Second phone available for §K (family sharing / invites) `[2-phone]`.
- [ ] Official Philips Hue app installed (cross-app checks in §B/§D/§I).

## A. First launch, onboarding, Welcome Tour [b28]

- [ ] `[fresh]` Fresh install → pair → tour auto-appears after dashboard paints; swipe all 12
      pages; Done.
- [ ] `[fresh]` Reinstall → "Explore Demo" → tour appears; then Studio tab → photosensitivity
      notice appears exactly once.
- [ ] Skip tour on page 2 → relaunch → no tour. Kill mid-tour → relaunch → tour returns.
- [ ] More → Replay the Tour works.
- [ ] `[2-phone]` Guest phone (family-sharing invite) shows the 9-page guest tour, no Studio
      pages.
- [ ] Widget/Siri cold launch → NO tour over the deep link; next normal launch → tour appears.
- [ ] Tour page 3 ("A library of looks"): traveling card lands in an empty slot at BOTH ends —
      never covers another card *(fix ships in build 29; verify then)*.

## B. Dashboard & master bar [b20 §8, supersedes b18 §1–5]

- [ ] Turn every light in a room off one-by-one (in-app) → master bar flips with the last one,
      no leave/return needed; turn one on → bar flips on.
- [ ] Per-light brightness changes move the room average smoothly.
- [ ] Toggle a light from the OFFICIAL Hue app → our dashboard card updates ≤2s without opening
      the room; master bar follows.
- [ ] Master-bar slider drag doesn't fight incoming updates (no bounce-back).
- [ ] Repeat the above once in a ZONE.
- [ ] Regressions: card power toggle instant; All Off works; pull-to-refresh; widget snapshots
      show correct state.

## C. Room detail — light cards, copy/paste color, paint mode [b24 A; repeat key items in a ZONE]

- [ ] Long-press a light card → context menu; plain tap opens editor; power button toggles;
      strip scrolls.
- [ ] Copy Color from a color-mode light → cards ring; tap 3–4 lights to repaint; ring stays;
      "Painting · Done" pill exits.
- [ ] Copy from a CT-mode light → paste onto CT (real mirek) / color (white via xy) / dimmable
      (brightness only).
- [ ] Dimmable-only light: no Copy/Save offered, Paste offered.
- [ ] Copy → leave room → other room → Paste works; paint NOT auto-armed on arrival.
- [ ] Paste onto an OFF light turns it on with the color.
- [ ] Long-press while paint is armed → menu still opens (flagged risk).
- [ ] Select Lights mode ↔ paint pill are mutually exclusive; drag-drop swatch keeps paint mode.
- [ ] After painting a CT light a color from the OFFICIAL app, Copy Color captures the color —
      not stale warm white [b25 §8].

## D. Scenes tab [b19, b20 §9, b21, b25]

- [ ] Rooms as collapsible sections; collapse state survives relaunch; Favorites shelf on top;
      sort menu flat modes bring chips back; search flattens [b19].
- [ ] Zone scenes show the zone name (not "Other") [b19].
- [ ] MY COLORS: save via ＋; tap swatch → tap light applies; drag swatch onto a scene card
      applies with ring; CT-only + dimmable lights degrade sensibly [b19].
- [ ] Scene menu → Copy to Room…: preview tints target lights; confirm creates; Undo removes;
      Move + Undo restores [b19].
- [ ] Drag a scene card onto another room's section header → pre-targeted sheet [b19].
- [ ] Dynamic scene copy keeps palette + speed (preview shows palette strip) [b19].
- [ ] `[2-bridge]` Copy a scene to a room on the OTHER bridge; colors land [b19].
- [ ] Activate a scene from the OFFICIAL app → ACTIVE badge flips here; in-app activation
      deactivates room-mates [b20 §9].
- [ ] Layout toggle grid↔bars persists relaunch [b20 §9].
- [ ] Favorite ★ a scene → Move to another room → ★ + usage history survive; Undo carries them
      back [b25 §6].
- [ ] Demo mode: no Copy/Move menu items; drops rejected [b19].

## E. Studio — Deck 0/1 effects & parameters [b20 §1–4, b21, b22]

- [ ] Deck 0 brightness lands ≤~200ms; speed re-params live effects without restart.
- [ ] Candle/fire/sparkle rate sliders: verify firmware actually honors them (if not: drop is a
      one-line revert — note result) [b20 §1].
- [ ] Base-color swatch re-tints a running effect; warmth glides candle/fire without restart
      flicker; Kelvin readouts sane; Smoothness chips glide later updates [b20 §1].
- [ ] Strobe ≤3Hz at max (Hz readout matches); area-only hints appear only when not streaming
      [b20 §2].
- [ ] Thunderstorm: Flash Brightness scales strikes; Flash Color/Strike Chance/Flash Length/
      Afterglow change LIVE on both streaming and room mode (kill the entertainment area to
      force the fallback) [b20 §3, b22].
- [ ] Party: Flash Color tints palette live; Smoothness changes hold/fade feel [b20 §4].
- [ ] Deck 0 capability honesty: run Cosmos on white-only bulbs → "⚠ No lights in X can run
      Cosmos", not a green success [b21]; on a white-only room that was OFF → warning AND room
      returns to off [b22].
- [ ] Tap a BPM readout, type 120 → exact value; garbage cancels [b22].
- [ ] Relaunch: Deck 0/1 sliders reopen at last-used; Reset restores defaults live [b20 §7].

## F. Composer deck & mixer tray [b20 §5–7, b21, b22]

- [ ] Essentials per tab; "+N more" opens the layer sheet (Motion dial/mini-map, drag lerps
      lights); drag tray up → ADVANCED inline [b20 §5].
- [ ] Temperature mode shows Warmth slider (no color pad); Smoothing visibly lags mic response;
      static/steady gating correct; beat quick-toggle auto-scrolls [b20 §5].
- [ ] "+ Create" opens the same editor; save-sheet accent swatches land on the saved card
      [b20 §6]; save-sheet Category works; Move to Category… [b22].
- [ ] Composer Revert snaps to last saved [b20 §7].
- [ ] Composer deck: 56 presets across 10 category chips; existing installs gain the new
      built-ins WITHOUT losing user edits [b21]; sections collapse + persist [b22].
- [ ] Deck 0/1 "From Composer" shelves present [b22].
- [ ] Scenes tab "Studio scenes" shelf → add to a room → scene appears with STUDIO badge and
      runs from the bridge [b22].
- [ ] Mixer tray: long scene name in a long-named room + accessibility Dynamic Type → nothing
      wraps mid-word or clips [b21].
- [ ] Tray drag up/half/collapse + Live Controls pill; pad/dial drags don't move the tray;
      Dynamic Type XL scrolls; tab away/back pauses strips [b20 §10].
- [ ] Rename a BUILT-IN composition, then delete it → it resets to stock (rename keeps built-in
      identity) [b22].

## G. Transports, Perform, DJ [b21, b23; Baylee's session items]

- [ ] Transport menu on a bridge with NO entertainment area → "Entertainment Area (Streaming)"
      greyed WITH a reason, not silent fallback [b21].
- [ ] Save to Bridge… on a gradient preset → close the app → lights keep cycling; a *spectrum*
      preset's colors match the Composer [b21].
- [ ] Share… a composition → QR renders → scan from 2nd phone (or paste link) → import preview →
      "Add to My Scenes" (real device; Simulator can't scan) [b21] `[2-phone]`.
- [ ] Open Perform on a non-reactive composition, play 120–128 BPM music → BPM locks within
      ~8s; close Perform with no mic-reactive comp → orange mic dot goes away [b23].
- [ ] DJ Mode + Perform open: Tap-Dial buttons 2–4 punch the performing room (hold engages,
      lift releases); Perform closed → burst on the most-recent room [b23].
- [ ] Streaming composition, kill bridge Wi-Fi >30s mid-Perform → header flips
      STREAMING → room-mode LIVE; STROBE pad still visibly alternates [b23, Baylee].
- [ ] Two rooms with compositions: tray badge + editor follow the SELECTED room; stopping room A
      leaves room B's editor; only a bridge-stored room shows the bridge badge [b23].
- [ ] Apply a still (bridge-optimized) preset → tray shows the one-shot notice, no
      Perform/Save/Revert; a sequence over it advances instead of hanging [b23].
- [ ] Accessibility → Dim Flashing Lights ON → Studio strobe runs at ≤30% brightness [b23,
      Baylee].

## H. Now Playing & stop honesty [b23, b25]

- [ ] Start any Studio effect → Dashboard Now-Playing bar appears; its Stop kills the loop
      (tray empties); two rooms → dialog lists both; Stop All works [b23].
- [ ] Siri "stop the lights" while a composition runs → effect stops, lights STAY ON;
      Dashboard Stop → room goes off (deliberate difference) [b25 §3].
- [ ] Composition in room A + strobe in room B → stop B from the bar → A keeps running, entry +
      transport badge intact [b25 §4].
- [ ] Delete a room (and separately a bridge) mid-effect → bar entry clears, no ghost loop;
      stale zones don't linger after removing the last bridge [b25 §5].

## I. Siri (10 App Shortcuts) [b24 B, b25]

Setup: install, launch once, wait ~2–5 min; verify Shortcuts app shows 10 ChromaGlow tiles first.

- [ ] "Turn on/off ⟨room⟩ in ChromaGlow"; same for a ZONE (disambiguation offered).
- [ ] "Dim ⟨room⟩ in ChromaGlow" → Siri prompts for the number.
- [ ] "Make my lights teal in ChromaGlow" → prompts for room; "…warm white…" (CT path).
- [ ] "Activate ⟨scene⟩ in ChromaGlow" (duplicate names disambiguated by room).
- [ ] "Set the lights to Relax in ChromaGlow" (whole home); "Turn off all lights…" then on
      (expect 80% warm welcome-home).
- [ ] Whole-home commands touch every room, none dropped (zones-vs-rooms deduped) [b25 §7].
- [ ] "Start ⟨composer scene⟩ in ChromaGlow" → asks room → app opens running it. Test warm,
      backgrounded, AND killed-app cold launch [b24; drain regression re-check b25 §9].
- [ ] Rename a composition, wait ~1 min, invoke by NEW name (re-donation).
- [ ] "Start the Candle effect in ChromaGlow".
- [ ] Start candle → force-kill app → "Stop the lights in ChromaGlow" → candle dies from
      background; app-driven effect → same phrase stops it and Now-Playing clears.
- [ ] Bare "turn on kitchen" → HomeKit answers (expected, not ours).
- [ ] Bridge unreachable → honest Siri error dialog.
- [ ] Room-scoped presets: Energize INSIDE a room touches only that room on iOS RoomDetail row,
      watch room detail, and the room-pinned widget; dashboard bar/watch home/generic widget
      stay whole-home [b22, Adam].

## J. Widgets, Control Center, Watch [b25, b22]

- [ ] `[fresh]`-ish: cold-launch with a scenes widget + watch scene face installed → scenes
      visible, never blank (kill + relaunch ×2) [b25 §1].
- [ ] Rename/delete a scene → widget + Siri scene names update ~1s; delete ALL scenes in a room
      → that room's widget goes honestly empty [b25 §2].
- [ ] Watch home screen + iPhone widget gallery say **ChromaGlow** (may need fresh install for
      Springboard cache) [b22, Adam].
- [ ] Add "ChromaGlow Scenes" watch complication → shows pinned room's scenes; tap opens the
      watch app to that room [b25 §10].

## K. Sharing & Family (two-phone) [b25 §11, b26 — b26 supersedes the Phase-1-only flow]

- [ ] `[2-phone]` Owner invite: More → Profiles & Access → New Profile (pick rooms + features) →
      Generate Invite → press link button → Mint → display-only QR with countdown.
- [ ] `[2-phone]` Guest join: scan (or onboarding "Join a Shared Home") → "You're in as ⟨name⟩"
      → Connect (NO link-button press) → dashboard shows ONLY allowed rooms.
- [ ] `[2-phone]` Guest surfaces inherit: widgets + Control Center + watch + Siri (a hidden room
      must fail to resolve); no Studio tab when guest-only; swipe order correct; banner opens
      the honesty sheet.
- [ ] `[2-phone]` Feature gates: onOff-only profile → guest cards show power only; detail is a
      power-only page.
- [ ] `[2-phone]` Re-scan update path: change profile rooms → Generate → "New Code" → guest
      re-scans → list updates, NO duplicate bridge.
- [ ] `[2-phone]` Expired QR (wait out countdown or use an old code) → honest expiry copy.
- [ ] **RECORD THE RESULT** — hardware spike: Profiles & Access → "Keys on your bridges" → your
      bridge. Which state fires? Key list visible? "Try Remove" → deletedVerified, or the
      official-app fallback copy? *(This answer is still owed to the family-sharing record.)*
- [ ] `[2-phone]` Revoke round-trip: owner Revoke Access → if bridge delete works, guest's next
      command 401/403 → cooperative wipe + "invite revoked" notice; if firmware refuses, guest
      keeps working and owner saw the honest dialog.
- [ ] Owned-bridge safety: on the owner phone nothing changed (no banner, Studio present, all
      rooms, create/delete intact; home-join Share Invite still works).
- [ ] `[2-phone]` Phase-1 home-join QR (More → Share Invite): scan on phone B → link button
      once → paired to the correct bridge → dashboard; also test the link via Messages [b25 §11].

## L. Migration & modes [b26]

- [ ] `[TestFlight]` Install current build OVER an old build (e.g. 21-era schema) → opens clean,
      library intact.
- [ ] Demo mode unaffected by all of the above.

## M. Accessibility pass (cross-cutting)

- [ ] Reduce Motion: tour stills; Studio strips/canvases still; strobe blocked.
- [ ] Dynamic Type XXL: tour, mixer tray, Scenes tab — nothing clipped or mid-word wrapped.
- [ ] VoiceOver: tour page-turn announcements; Studio deck cards labeled.
- [ ] Dim Flashing Lights: strobe ≤30% (§G).
- [ ] iPad: tour + main surfaces render sanely [b28].

## N. Program items owned by Brian (not app QA)

- [ ] App Store Connect pass per `docs/ios/app-store-submission-runbook.md` (age rating,
      privacy label Data Not Collected, DSA trader, metadata, screenshots iPhone 6.9" + iPad
      13" + watch, archive/upload, review notes + demo video, submit) [b27].
- [ ] Android Batch 4: re-run the physical link-button gate with the CORRECT worktree APK
      (`integration/parallel-batch-4` @ `040fed7`), then Codex review + explicit go-ahead →
      merge to `main` (see pipeline doc §11; stale-APK diagnosis 2026-07-01).
- [ ] Decide D-020 (canonical Android tree + CI hardening-presence gate) with Codex.

## Parked-agent "Left" register (tracked, not device QA)

| Owner | Item | Status |
| --- | --- | --- |
| Baylee | Phase B: RestSender extraction; Automations-vs-Studio arbitration | Backlog (deliberate) |
| Baylee | Phase C: one transport vocabulary + audio status chip | **Executing in build 31 (Round C)** |
| Elmo | ~80 historic test-target concurrency warnings (~15 test files) | Backlog (own round) |
| Helena | Build-28 tour device pass; 3 minor unverified UI findings were pre-fixed | In progress (Brian) |
| All | Builds 18–26 checklists | This document |

## Supersession notes

- Build 18 items 1–5 (SSE/live cards) are covered by §B (build 20's master-bar + scene-SSE
  re-test, a superset).
- Build 24's Siri stop (item 12) is re-verified in the corrected build-25 form (§H) — test the
  b25 semantics.
- Build 25 §11 (Share Invite Phase 1) is kept as the last item of §K; build 26's Phases 2–4 flow
  is the primary two-phone pass.
- The TEMP ⏱️PERF prints flagged in b21/b25 were removed in build 27 — no longer a checklist item.
- Build 27's "Left" folded builds 18–26 into one TestFlight smoke — this document IS that smoke,
  expanded; build 28's tour QA is §A; the ASC pass remains §N.
