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

## O. Composer 2 — Entertainment Area selection [packet 1b]

Simulator unit tests prove the *decisions*; only hardware proves which bulbs light up. Packet
1a's checks (in its DEVLOG entry) stay open and are NOT superseded by these.

For every item record: **app build · bridge IDs or labels · bridge firmware · room names · area
names · area membership · requested transport · actual transport · which lights actually moved.**

- [ ] Two areas on one bridge: Area A holds Room A's lights, Area B holds Room B's. Start
      Composer Entertainment in Room A → ONLY Area A streams. Then start in Room B → ONLY Area B
      streams. (This is the wrong-room defect; before 1b either room could get either area.)
- [ ] Response-order independence: refresh/relaunch several times and repeat the above → the
      selected area never changes with the order the bridge lists them in.
- [ ] Partial-room area: an Entertainment Area covering a deliberate subset of a larger room →
      that area is selected and streams (the unique largest safe subset).
- [ ] No matching area: start a composition in a room whose lights are in no area → the UI says
      so honestly ("No Entertainment Area can safely stream to this room…"), Composer falls back
      to REST, and **no other room's area activates**.
- [ ] Ambiguous areas (where practical): two areas with competing, incomparable overlap of one
      room → safe REST fallback, not a guess. Also try one whole-house area with a smaller room
      → REST fallback, and the rest of the house stays dark.
- [ ] Multi-bridge: each bridge has ≥1 area → each room selects only an area on **its own**
      bridge; two bridges can stream at once.
- [ ] Spatial movement: run a directional pattern → channel positions correspond to the selected
      area, with **no movement in another room**.
- [ ] Area membership change: edit an area's members in the Hue app, then refresh or relaunch
      ChromaGlow → the updated membership is used for selection.
- [ ] Studio cold path: force-quit, relaunch, tap a strobe/party/thunderstorm card **without**
      opening Composer or the transport menu first → the correct area streams (Studio warms its
      own cache; a cold cache used to demote silently to REST).
- [ ] Regression, single-area home: a bridge with exactly one correctly-mapped area streams
      normally — the conservative rules must not cost the common setup its streaming.
- [ ] Honesty check: with an area that does NOT cover the selected room, the transport menu says
      "no Entertainment Area for this room", **not** "this bridge has no entertainment area."

## P. Composer 2 — scoped bridge-stored cleanup [packet 2]

Simulator unit tests prove the *decisions*; only hardware proves which bulbs keep running.
Packet 1a's and packet 1b's checks (§O and packet 1a's DEVLOG entry) stay open and are NOT
superseded by these.

Before packet 2, every bridge-stored start deleted every `CG_` resource on the bridge — so
starting a look in one room stopped the other room's bridge-stored animation and orphaned its
manifest. These checks are the hardware proof that cleanup is now scoped to the room's own
recorded resources on its own bridge.

For every item record: **app build · bridge ID or label · bridge firmware · room names ·
preset names · requested transport · actual transport · which rooms continued · which rooms
stopped · maintenance-action result.**

- [ ] Two bridge-stored rooms on one bridge: start a bridge-optimized look in Room A, then
      start one in Room B. Expected: **Room A keeps running** and Room B starts. (Before
      packet 2, Room A died here.)
- [ ] Replace Room B: with A and B both running, pick a *different* bridge-optimized look in
      Room B. Expected: Room B's old resources stop, the new Room B look starts, **Room A
      continues undisturbed**.
- [ ] Stop Room B. Expected: Room B stops cleanly; **Room A continues**.
- [ ] Stop Room A afterward. Expected: Room A stops cleanly, and no stale ChromaGlow bridge
      resources remain visible.
- [ ] Multi-bridge isolation: run bridge-stored looks on bridge A **and** bridge B, then
      replace one. Expected: the other bridge sees **no interruption**.
- [ ] Explicit maintenance action — **use only disposable test animations**. Invoke Settings →
      Clean Bridge Resources manually. Expected: ChromaGlow bridge-animation resources are
      intentionally removed, and **ordinary Hue scenes / third-party (Hue Labs, Sync Box)
      resources remain untouched**. (Known limitation: this action targets one bridge — see
      the packet 2 DEVLOG entry.)
- [ ] Relaunch observation: relaunch the app while a bridge-stored animation is running.
      **Record the current behavior — missing in-app restoration is NOT a packet 2 failure.**
      Launch-time manifest reconciliation is Phase 0 item 10.

## Q. Composer 2 — scoped REST mailboxes [packet 3]

Simulator unit tests prove the *decisions*; only hardware proves which bulbs keep moving.
Packets 1a, 1b and 2's checks (§O, §P and packet 1a's DEVLOG entry) stay open and are NOT
superseded by these.

Before packet 3, ONE latest-wins REST mailbox served every Composer room, every Studio engine
loop, and every Studio live-param write across every bridge — so one room's stop cleared
everyone's queued frame, and a running multi-batch sweep had no way to notice it had been
superseded. These checks are the hardware proof that mailboxes are now per bridge × room ×
owner, and that a stop actually halts an in-flight sweep.

**Read the guarantee before judging a result.** `clear` stops *pending* work outright and
stops *executing* work before its next batch — **at most one already-dispatched batch or
individual light request may still complete**, and superseded intermediate values may be
dropped by design. A single brief overlap frame is expected. Minor pacing variation is not a
failure. What *is* a failure: continued old-look motion, a frozen or stalled scope, or a scope
being cleared that no one asked to stop.

For every item record: **app build · bridge IDs or labels · bridge firmware · room names ·
light counts · requested transport · actual transport · which rooms kept moving · which
stopped · how quickly the old look stopped.**

- [ ] Two rooms on one bridge, both Composer REST: stop room A. Expected: room B does **not**
      stall, does **not** freeze on a stale colour, and does **not** have its queued work
      cleared. (Before packet 3, the global clear also poisoned room B's delta gate, so room B
      could sit frozen on the discarded frame's colour.)
- [ ] Two bridges, one Composer room each: stop the bridge-A room. Expected: bridge B keeps
      running. Minor pacing variation is not a failure.
- [ ] Card replacement, same room, **≥10 lights** (ideally a gradient strip): tap card 1, then
      card 2 fast. Expected: at most **one** already-dispatched batch of the old look may
      complete after the new prime; no subsequent old batch may begin. A single brief overlap
      frame is expected and acceptable — **continued old-look motion is a failure**.
- [ ] Same-bridge Studio + Composer: the Studio scope must not be cleared or frozen when the
      Composer room stops, and vice versa. Minor pacing variation is not a packet 3 failure.
- [ ] Slider + Composer: scrub a Studio param while a Composer look runs elsewhere. Expected:
      both scopes keep converging to their latest intended values. Intermediate superseded
      values may be dropped by design; **neither scope may be globally cleared or frozen**.
- [ ] Studio running in room A, then start Studio in room B. Expected: room A stops cleanly,
      room B starts clean, **no crossfire from room A**. (One global task slot used to leave
      room A's queued writes legal.)
- [ ] Composer running, tap a Studio entertainment card on the same bridge, confirm the
      prompt. Expected: a clean switch (packet 1A regression check).
- [ ] Remove a bridge from Bridge Manager while a Composer look runs on **another** bridge.
      Expected: the other bridge's look continues uninterrupted.
- [ ] Bridge-native effect on a room with **≥10 v2-capable lights**: drag the warmth or speed
      slider, then immediately stop or switch the card. Expected: the old per-light
      re-parameterization stops **within roughly one light**, not continuing to sweep the room.
      (This is the path that previously ran ~lightCount × 100 ms uncancellable — about 2 s on a
      20-light room.)
- [ ] Stop/start the same card **5× rapidly**. Expected: no stuck lights, no doubled ramps.

## R. Composer 2 — honest completion-based REST telemetry [packet 4]

Simulator tests prove the counters and expiry rules; only hardware proves what the mixer
tray shows while real requests fly. §O–§Q stay open and are NOT superseded.

Before packet 4, the cadence line was computed at enqueue time — lag structurally 0.0,
discarded frames counted as sends, and one global number shared by every room. It is now
completion-based, per bridge × room, and expires when completions stop.

- [ ] 1. Start a Room-mode composition. Expected: the tray NEVER flashes "updates about
      every 0.0s" — it reads "…a little slower" until real completions justify a number.
- [ ] 2. Two rooms, one bridge, both Room mode: each card shows its own number or none —
      never the other room's.
- [ ] 3. Two bridges, one Room-mode room each: the numbers move independently.
- [ ] 4. Composition + a Studio slider in the SAME room: the composer cadence must NOT
      collapse while the slider is scrubbed (different scopes under packet 3).
- [ ] 5. Streaming (Entertainment) composition: no cadence sentence at all.
- [ ] 6. DTLS→REST failover (kill the stream mid-composition): the sentence appears fresh
      for the REST session — never a stale number carried across the switch.
- [ ] 7. Stop, then immediately restart the same room: no number carried over; the fresh
      session earns its own.
- [ ] 8. Pull the bridge off the network mid-composition: the number DISAPPEARS within
      ~5 s (back to "a little slower") rather than freezing at the last good value.
- [ ] 9. Stop a 20+ light room mid-sweep: lights still halt within one already-dispatched
      batch (packet 3 cancellation is untouched by the instrumentation).
- [ ] 10. DEBUG console during a Room-mode run: non-zero queue delay and network duration;
      successful items ≤ enqueued items; dispatched counts, not entry counts.
- [ ] 11. Unplug ONE light mid-composition: the room keeps animating, and the unplugged
      light recovers when it returns — partial failures must not freeze the delta gate
      (completion-only bookkeeping keeps the frame eligible for re-send).

## S. Composer 2 — honest light limits [packet 5]

Simulator tests prove the arithmetic, the fairness and the refusals; only
hardware proves what a real 30-light room and a real saturated bridge do.
§O–§R stay open and are NOT superseded.

Before packet 5 a composition silently drove only the first 20 lights on every
non-streaming transport: lights 21+ received no write at all, were not counted,
and nothing on screen said so. The cap was never a Hue limit.

- [ ] 1. Room with MORE than 20 lights, Room mode. Expected: **every** bulb
      animates. Before this build, bulbs 21+ sat frozen at whatever the prime
      frame left them.
- [ ] 2. Same room: the tray reads "…this room is large, so its lights take
      turns updating". Per-light refresh is visibly slower than a small room —
      that is the honest trade, not a bug.
- [ ] 3. A 20-light-or-smaller room: unchanged from build 28 in both motion and
      wording. No rotation sentence.
- [ ] 4. 21-light room, STATIC look (no motion, no mic): the lights settle and
      the room goes quiet after one pass. It must not keep pulsing forever.
- [ ] 5. Unplug ONE bulb in a 30-light room mid-composition. Expected: the room
      KEEPS rotating rather than going quiet, and the bulb rejoins when it
      returns. (Quiescence requires a rotation that fully delivered.)
- [ ] 6. Stop a 30-light room mid-rotation: lights halt within one already
      dispatched batch, as in §Q.
- [ ] 7. Two bridges, one large room each: they rotate independently, and each
      card's sentence describes its OWN room.
- [ ] 8. Gradient strip in a room of 20+ lights: the strip still shows a full
      multi-point gradient (it used to collapse to one flat colour), and the
      bulbs on either side of it keep their own positions in the wave — no
      shifted or mirrored motion.
- [ ] 9. Perform header: the transport badge reads "AREA"/"ROOM", never "REST".
- [ ] 10. **Capture for the record:** with a bridge reachable, grab
      `GET /api/<key>/capabilities` (any REST client) and attach the body. The
      capability decoder is currently pinned to the documented shape, not a
      captured one, and this is what lets us tighten it.
- [ ] 11. **Capture for the record:** if you can saturate a bridge (many rules),
      attempt a bridge-stored look and capture the raw v1 error body. Today
      every creation error surfaces the generic "couldn't be stored" sentence
      because no verified capacity discriminator exists; this capture is what
      would let us classify it.

> Note: the bridge-stored branch is not reachable from the shipping UI — the
> `.bridgeOptimized` tier fires a one-shot instead of calling the orchestrator.
> Items 10–11 are therefore captures, not pass/fail tests, and the capacity
> work they inform is correctness-in-waiting for Phase 6.


## T. Composer 2 — All-Day playback ownership [packet 6]

Simulator tests prove the decisions; only hardware proves which bulbs actually
get overwritten, and when. §O–§S stay open and are NOT superseded.

Before packet 6, All Day Scenes wrote colour temperature and brightness to every
room every five minutes with no idea whether you were already playing something
there — so a Composer look or a Studio effect was quietly stomped, and because
the app suppresses its own echo you never saw it happen. Worse, All-Day shared
ONE queue slot across every room, so in a home with several rooms most of them
silently missed their update anyway.

**Read the guarantee before judging a result.** A skipped room is a PASS, not a
failure — All-Day now yields to whatever is playing. A freed room comes back on
the NEXT normal tick, which can be up to five minutes later; there is
deliberately no catch-up burst. All-Day still never touches zones.

For every item record: **app build · bridge IDs or labels · bridge firmware ·
room names · which rooms updated · which were skipped · what was playing where ·
how long until a freed room resumed.**

- [ ] 1. All Day on, two rooms, nothing playing. Expected: **both** rooms shift
      within one tick. (Before this build, typically only one of them did.)
- [ ] 2. Start a Composer look in room A. Expected: room A is **not** overwritten
      while it plays, and room B still receives its All-Day update.
- [ ] 3. Repeat item 2 with a Studio card in room A — once with an app-driven
      card, and once with a **firmware card (Candle or Fire)**. Expected: the
      same result for both.
- [ ] 4. Repeat items 2–3 with two bridges, one room playing on each. Expected:
      each bridge's free rooms keep updating.
- [ ] 5. Queue-then-claim: with two bridges, unplug bridge A so its queue backs
      up, then start playback in a bridge-B room within the same five-minute
      window. Expected: that room is **not** written when the queue drains.
- [ ] 6. Stop playback. Expected: the room resumes on the **next** tick (up to
      5 min). An immediate change is NOT expected.
- [ ] 7. Disable All Day mid-tick. Expected: no later stray write on any room.
- [ ] 8. Toggle All Day **off and immediately back on, twice in a row**.
      Expected: the first tick after each restart still updates every eligible
      room. (A regression looks like rooms silently missing an update right
      after a restart.)
- [ ] 9. Remove a bridge from Bridge Manager while All Day is active. Expected:
      the other bridge keeps updating normally.
- [ ] 10. Remove a bridge, then re-pair it. Expected: All Day resumes updating
      that bridge's rooms within one tick. **Repeat once with a force-quit and
      relaunch between removing and re-pairing** — that exercises the other
      registration path. (A regression looks like that bridge never receiving
      All-Day again.)
- [ ] 11. Forget All Bridges while All Day is enabled, and try to re-enable the
      All Day toggle before the teardown finishes. Expected: no lights change
      afterwards, and All Day stays **off** until you deliberately turn it on.
- [ ] 12. Same room name on two bridges, one of them playing. Expected: only the
      playing bridge's room is skipped.
- [ ] 13. Start a firmware card (Candle) in a room, then pull that bridge off the
      network and press Stop. Expected: the card clears from Now Playing, and
      once the bridge returns that room receives All-Day again on the next tick.
      (A regression looks like the room never resuming.)
- [ ] 14. Start a firmware card in a room whose bulbs cannot run it (white-only
      bulbs). Expected: you get the "no lights can run" message, the room does
      not stay stuck lit, and that room **still** receives All-Day on the next
      tick. (A regression looks like the room being skipped forever after a card
      that never started.)

> Note: All-Day does not restore ownership of a firmware effect across an app
> relaunch — after a force-quit, a still-running Candle may be overwritten on the
> next tick. Launch-time playback reconciliation is separate, later work.


## U. Composer 2 — third-party Entertainment consent [packet 7]

Branch `fix/third-party-entertainment-consent`; rollback tag
`checkpoint/pre-composer-packet-7`. No build bump — run this on a build made from
that branch.

**What changed:** ChromaGlow used to stop *any* Entertainment session it did not
recognise, on every launch, foreground, and refresh. It now yields: it only ever
cleans up sessions it recorded as its own, and it replaces another controller
only after you explicitly start a streaming look **and** tap Take Over.

**You need:** a second controller on the same bridge — a Hue Sync Box, the
official Hue app's Entertainment/sync mode, or any other app that streams. Item 7
also needs a second bridge. A "streaming look" below means Party, Strobe,
Thunderstorm, or a Composer look set to Streaming, in a room that has an
Entertainment Area.

- [ ] 1. Start the other controller's show, then launch ChromaGlow cold and wait
      through the initial load (give it a full minute). Expected: **the other
      show continues uninterrupted and no prompt appears.** (The old build killed
      it within seconds of launch.)
- [ ] 2. With that show still running, background ChromaGlow and foreground it
      again, twice. Expected: still uninterrupted, still no prompt.
- [ ] 3. Pull to refresh on the Dashboard (and toggle a light to trigger a state
      refresh). Expected: the other show remains uninterrupted.
- [ ] 4. While the other show runs, explicitly start a ChromaGlow streaming look
      in a room on that bridge. Expected: the takeover prompt appears —
      **"Another app was controlling these lights — take over?"** — and the other
      show is **still running** at that moment. Nothing may stop before you answer.
- [ ] 5. Choose **Keep Existing**. Expected: the other show continues, and the
      ChromaGlow look does **not** start. Repeat once by swiping the alert away
      instead of tapping — same result.
- [ ] 6. Repeat item 4 and choose **Take Over**. Expected: the other show stops
      first, then ChromaGlow starts. The lights must not flicker back to the other
      app.
- [ ] 7. **Two bridges.** Run the other controller's show on bridge A, then start
      a ChromaGlow streaming look in a room on bridge B. Expected: **no prompt**,
      bridge B starts normally, and bridge A's show is completely untouched.
- [ ] 8. Force-quit ChromaGlow while it is streaming its own look, then relaunch.
      Expected: its own leftover session is cleaned up (the room stops streaming
      and behaves normally). Then repeat with the other controller's show running
      too: expected: **only** ChromaGlow's own leftover session is cleaned up —
      the other show survives the relaunch.
- [ ] 9. **Failed takeover.** Start the other controller's show, tap a ChromaGlow
      streaming look to raise the prompt, then pull the bridge off the network
      (unplug its ethernet or power) and tap Take Over. Expected: an honest
      failure message — ChromaGlow must **not** claim success and must not show
      the look as playing. Plug the bridge back in and confirm the app recovers.
- [ ] 10. **Owner changed under the prompt.** Start controller #1's show, tap a
      ChromaGlow streaming look to raise the prompt, and — while the prompt is
      still open — stop controller #1 and start a *different* controller (or the
      same one on a different area). Then tap Take Over. Expected: the replacement
      is **not** stopped; you are asked again (or told honestly). Stale consent
      must never evict a session you did not agree to replace.

> If item 1, 2, 3, or 7 fails, stop and report — those are the trust-critical
> ones. Items 5, 9, and 10 are the honesty checks: the app must never claim a
> takeover that did not happen, and must never touch a session you declined.

**Hardware run — what actually happened.** Items 1, 2 and 3 passed: the official
Hue app's show survived cold launch, two foreground cycles and a pull-to-refresh
untouched. Item 4 **FAILED** — "Entertainment Area (Streaming)" was shown greyed
out and could not be tapped, so streaming could not be requested and no prompt
was ever reachable. The area only became available after the Hue session was
stopped, ChromaGlow was force-quit, and the app was relaunched. Because the
prompt could not be reached, items **5, 6, 9 and 10 are BLOCKED, not failed** —
Keep Existing, Take Over, failed takeover and changed-owner-under-the-prompt were
never exercised. Item 7 **PASSED**: Hue drove an area on bridge A while
ChromaGlow streamed on bridge B, and both continued independently. Item 8's
normal termination behaviour **PASSED** and its foreign-session survival half
(8B) **PASSED**; the persisted-orphan cleanup half is **still unproven**.
Reduce Motion correctly blocked Strobe (functional safety **PASS**) but gave no
explanation at all (UX **FAIL**). Starting a streaming composition in a space
where Strobe already owned Entertainment did not apply and produced no handoff or
refusal — a **provisional FAIL** for the Studio-to-composition direction.

The follow-up branch `fix/packet7-device-followups` corrects all three. **It is now
MERGED — PR #59, merge `3479243` — and that is the build Brian tested in the §U-R
pass recorded below.** Packet 7 hardware validation is **not** complete.

### U-R. Packet 7 hardware follow-up — retest (RESULTS RECORDED)

Run against merge `3479243`. Verdicts from Brian's pass:

| Test | Verdict | Note |
| --- | --- | --- |
| 1 — cached unavailable row is tappable | **PASS** | Exact copy appeared |
| 2 — exact-room targeting | **UNPROVEN** | Original exact-room scenario not exercised; see the confirmed defect below |
| — overlapping / mixed-room targeting | **CONFIRMED DEFECT** | Bedroom resolved; hallway and bathroom reported "no compatible area" |
| 3 — foreign takeover prompt reachable | **PASS** | |
| 4 — Keep Existing preserves the Hue session | **PASS** | Did not block a later request |
| 5 — Take Over gives stable ownership | **FAIL** pending instrumented root-cause distinction | Hue kept or reclaimed control; the look applied only once Hue Sync was disabled |
| 6 | **BLOCKED** | |
| 7 | **UNPROVEN** | |
| 8 | **UNPROVEN** | |
| 9 | **UNPROVEN** | |
| 10 — Studio | **PASS** | |
| 10 — Perform | **UNPROVEN** | |
| 11 | **UNPROVEN** | |
| 12 | **UNPROVEN** | |

The overlapping-area defect and the takeover failure are addressed in §V below;
re-run this section too once §V has been exercised.

**Original §U-R instructions follow.**

**What changed:** the Streaming row can no longer be greyed out by a stale cache;
tapping it re-reads the bridge before answering. A ChromaGlow look that already
owns a bridge's Entertainment session is now detected and asked about, instead of
a second session being opened underneath it. And a Strobe refused for Reduce
Motion now says so.

**Read the guarantee before judging a result.** A row that is tappable but then
explains that no compatible area exists is a **PASS** — the honest answers are
"here is why" and an unchanged bridge, not a dead control. Room mode starting
after that sentence is also a **PASS**; the sentence says it will. A silent tap
that changes nothing is a FAIL.

**You need:** a second controller on the same bridge (Hue Sync Box or the Hue
app's Entertainment mode), a second bridge for item 11, and the ability to create
and edit an Entertainment Area in the official Hue app while ChromaGlow stays
open.

For every item record: **app build · bridge IDs or labels · bridge firmware ·
room names · look names · what the transport menu showed before and after the
tap · what the lights actually did.**

- [ ] 1. Put the transport menu into a stale state (open Studio for a room whose
      bridge has no area yet), then confirm the **Entertainment Area (Streaming)**
      row is **still tappable** and only explains itself underneath. Expected:
      the row is never greyed out, whatever the cached answer says.
- [ ] 2. With ChromaGlow open the whole time, create an Entertainment Area for
      that room in the official Hue app, return to ChromaGlow and pull to refresh
      (then re-enter Studio). Expected: **the new area becomes usable without
      force-quitting.** This is the exact failure that blocked the last run.
- [ ] 3. Start the Hue app's show on that bridge, then tap the Streaming row in
      ChromaGlow. Expected: the takeover prompt appears — **"Another app was
      controlling these lights — take over?"** — and the other show is **still
      running** at that moment.
- [ ] 4. Choose **Keep Existing**. Expected: the other show continues and the
      ChromaGlow look does not start. Repeat once by swiping the alert away.
- [ ] 5. Repeat item 3 and choose **Take Over**. Expected: the other show stops
      first, then ChromaGlow starts, with no flicker back.
- [ ] 6. **Failed takeover.** Raise the prompt, pull the bridge off the network,
      then tap Take Over. Expected: an honest failure message; ChromaGlow must
      not claim success or show the look as playing.
- [ ] 7. **Owner changed under the prompt.** Raise the prompt, and while it is
      open stop controller #1 and start a different controller (or the same one
      on a different area). Tap Take Over. Expected: the replacement is **not**
      stopped; you are asked again or told honestly.
- [ ] 8. **Strobe → composition, cancel.** Start Strobe in a room with an
      Entertainment Area, then start a Composer look set to Streaming on that
      same bridge. Expected: **"Switch lighting modes?"** appears with Strobe
      still running. Choose **Keep Playing**: Strobe keeps going and the
      composition does not start. Repeat for Party and Thunderstorm.
- [ ] 9. **Strobe → composition, confirm.** Repeat item 8 and choose **Switch**.
      Expected: Strobe stops **first**, then the composition starts streaming
      exactly once. The composition must not quietly play in Room mode
      underneath a still-running Strobe — that was the old behaviour.
- [ ] 10. **Reduce Motion.** Turn on Reduce Motion in iOS Settings, then request
      Strobe from the Studio card and again from the Perform tab's STROBE pad.
      Expected both times: **"Strobe is unavailable while Reduce Motion is on."**
      and whatever was already playing keeps playing, untouched. Note that the
      Perform pad now refuses where it previously flashed.
- [ ] 11. **Bridge isolation.** With Strobe owning bridge A, start a streaming
      composition in a room on bridge B. Expected: **no prompt**, bridge B
      streams normally, and bridge A's Strobe is untouched. Then confirm a
      handoff on A and check nothing on B changed.
- [ ] 12. **Rapid overlapping requests.** Tap the Streaming row, a streaming card
      and a Composer look in quick succession, and double-tap the confirm button
      on each prompt. Expected: no double stop, no double start, no orphaned
      session, and Now Playing matching what the lights are actually doing.

> Items 2, 3 and 11 are the trust-critical ones — if any fails, stop and report.
> Items 6, 7, 9 and 12 are the honesty checks: the app must never claim a switch
> or a takeover that did not happen, and must never stop a session you did not
> agree to replace.

## V. Composer 2 — bridge-stored animation relaunch reconciliation [packet 8]

Branch `fix/bridge-animation-relaunch-reconciliation`; rollback tag
`checkpoint/pre-composer-packet-8`. No build bump — run this on a build made from
that branch. Nothing in §T is superseded: firmware Studio cards (Candle, Fire)
are still not restored at launch, and that is later work. This section is only
about Composer looks you chose to store **on the bridge**.

**What changed:** a bridge-stored look keeps running on the bridge after you
force-quit ChromaGlow — that is the whole point of it. But nothing brought it
back into the app at launch, so there was no entry to stop and **no way to stop
it from inside the app at all**. The only escape was Settings → Clean Bridge
Resources, which wipes every ChromaGlow resource on that bridge, including looks
running in other rooms. ChromaGlow now reads each bridge once at launch, checks
each stored look against what the bridge actually reports, and restores the ones
still running into Now Playing and Studio so Stop works normally. A look it can
prove is gone is quietly retired; a look it **cannot check** — offline bridge,
unreadable bridge — is kept, not guessed at.

**Read the guarantee before judging a result.** Nothing is deleted from a bridge
during the launch check itself: reconciling a running look is read-only. "I can't
stop it because the bridge is offline" is a **PASS** — the honest answers are
"try again when the bridge is back" and a row that stays visible. A row that
silently vanishes while the bulbs keep cycling is a FAIL. The check runs once per
launch and once per foreground refresh, not continuously.

**You need:** at least one Composer preset that runs on the bridge (a
`bridgeOptimized` look — static motion, steady envelope), and for items 4–5 a
second room and a second bridge.

For every item record: **app build · bridge IDs or labels · bridge firmware ·
room names · look names · what Now Playing showed at launch · whether Stop
succeeded · what the lights actually did.**

- [ ] 1. Start a bridge-stored look in one room and confirm the lights are
      cycling. Force-quit ChromaGlow (swipe it away) and wait a full minute with
      the app dead. Expected: the lights **keep cycling**. Relaunch. Expected:
      the look reappears in Now Playing under its own name during the first
      load, and tapping Stop actually stops it — the lights stop cycling and the
      room goes off. (Before this build there was no Stop to tap: the animation
      ran until the bridge was purged.)
- [ ] 2. Repeat item 1 but stop from the **Dashboard** Now Playing bar without
      ever opening Studio. Expected: identical result. Then repeat once more and
      stop from **Studio**. Expected: identical again. Also check the restored
      Studio row shows no sliders and no layer chips — there is no live render
      loop behind it, and the controls must not pretend otherwise.
- [ ] 3. Repeat item 1, but open the **Studio tab before the first load
      finishes** (launch, then immediately tap Studio). Expected: the restored
      look appears there too. The order you visit screens in must not change
      what you see.
- [ ] 4. **Two rooms, one bridge.** Start a bridge-stored look in room A and a
      different one in room B, force-quit, relaunch. Expected: **both** appear
      in Now Playing, with the right names against the right rooms. Stop room A
      only. Expected: room A stops and **room B keeps running**, with its row
      still visible. Then stop room B. Expected: it stops too.
- [ ] 5. **Two bridges.** Start a bridge-stored look in a room on each bridge,
      force-quit, relaunch. Expected: both are restored. Stop one. Expected:
      only that bridge's room stops; the other bridge's look is completely
      untouched — watch the bulbs, not just the UI.
- [ ] 6. **Bridge offline at relaunch.** Start a bridge-stored look, force-quit,
      unplug that bridge, then relaunch. Expected: the app does **not** claim
      the look is gone and does **not** silently drop it. Plug the bridge back
      in and pull to refresh (or background and foreground). Expected: the look
      is recognised again and Stop works. (A regression looks like the row
      vanishing while the bulbs keep cycling — the exact state this packet
      exists to end.)
- [ ] 7. **Resources removed externally.** Start a bridge-stored look in room A
      and another in room B, force-quit, then use Settings → Clean Bridge
      Resources or the official Hue app to delete the ChromaGlow resources while
      ChromaGlow is closed. Relaunch. Expected: no phantom running row for the
      deleted look, no error, and any room whose look is genuinely still running
      is untouched and still stoppable.
- [ ] 8. **Preset renamed.** Start a bridge-stored look, force-quit, relaunch and
      confirm the row appears. Now rename that Composer preset, force-quit again,
      relaunch. Expected: a row still appears and Stop still works, showing the
      **current** preset name.
- [ ] 9. **Preset deleted.** Start a bridge-stored look, force-quit, delete the
      preset from Composer, force-quit, relaunch. Expected: the row is still
      there with a sensible name (not blank, not "Untitled" — it falls back to
      the name recorded when the look was uploaded), and Stop still removes the
      animation from the bridge. A look you can see running but cannot stop is
      the failure this packet exists to prevent.
- [ ] 10. **Room deleted or recreated.** Start a bridge-stored look, force-quit,
      then delete or recreate that room in the Hue app. Relaunch. Expected: a
      recovered entry is still listed under the room name recorded at upload
      time, **no other room is shown as running**, and Stop still removes the
      resources from the bridge. Nothing may be powered off in a room the app
      cannot identify.
- [ ] 11. **Failed stop.** Start a bridge-stored look, force-quit, relaunch, then
      put the bridge out of reach (unplug it or drop Wi-Fi) and tap Stop.
      Expected: an honest error, the row **stays visible**, and the look is
      still listed after a refresh. Restore the bridge and tap Stop again.
      Expected: it now succeeds and the row clears. At no point may the app
      report a stop that did not happen.

> If item 1, 2, 4, 5, or 9 fails, stop and report — those are the trust-critical
> ones: they are the difference between a look you can stop and a look that runs
> on your bridge forever. Items 6, 7, 10, and 11 are the honesty checks: the app
> must never claim a look is gone because it could not reach the bridge, never
> claim a stop that did not happen, and never guess a room.


## Parked-agent "Left" register (tracked, not device QA)

| Owner | Item | Status |
| --- | --- | --- |
| Baylee | Phase B: RestSender extraction; Automations-vs-Studio arbitration | Backlog (deliberate) |
| Baylee | Phase C: one transport vocabulary + audio status chip | **Executing in build 31 (Round C)** |
| Elmo | ~80 historic test-target concurrency warnings (~15 test files) | Backlog (own round) |
| Helena | Build-28 tour device pass; 3 minor unverified UI findings were pre-fixed | In progress (Brian) |
| All | Builds 18–26 checklists | This document |

### V. Hardware Convergence Slice A — retest

Branch `fix/hardware-convergence-entertainment-targeting`; rollback tag
`checkpoint/pre-hardware-convergence-entertainment-targeting` (at `3479243`).
No build bump — build from that branch.

**What changed.** A room that several Entertainment Areas could serve now asks
which one instead of reporting that none exists. Take Over verifies that the
other controller actually released the area, and that our own session actually
opened, before claiming anything. Bridge saves persist their ownership record
before anything starts running, and the app now states whether a look is running
from ChromaGlow or from the bridge. The room wheel is no longer covered by the
effect panel.

**Read the guarantee before judging a result.** "Nothing started, and here is
why" is a **PASS** wherever the app cannot prove it is safe to act. A refusal
with an explanation is the designed answer; a silent no-op is not.

| # | Test | Expected | Result |
| --- | --- | --- | --- |
| 1 | Room served by exactly one area → start Streaming | Starts with no chooser | |
| 2 | Room served by two areas → start Streaming | Chooser lists BOTH by name | |
| 3 | Pick the area spanning bedroom+hallway for the hallway | Row warns it also controls lights outside the hallway, before you tap | |
| 4 | Read the chooser rows | Bridge label shown (never an IP); rooms and light counts correct | |
| 5 | Open the chooser, delete that area in the Hue app, then choose it | Nothing starts; honest message | |
| 6 | Take Over while Hue Sync refuses to release | Nothing starts; no Now Playing row; message or a fresh prompt | |
| 7 | Take Over, then let Hue Sync reclaim immediately | Treated as a NEW conflict — fresh prompt, no false ownership | |
| 8 | Take Over succeeds but ChromaGlow cannot open its session | No ownership, no Now Playing, no silent Room-mode fallback | |
| 9 | Take Over with Hue Sync closed | ChromaGlow takes control and holds it; badge says AREA | |
| 10 | Keep Existing, then request Streaming again | Take Over is reachable and works the second time | |
| 11 | Start an app-driven look, force-close | Lights stop; the app said it would | |
| 12 | Save a look to the bridge, read the result sheet | Names bridge, room, bridge-run, local preset, Stop-after-relaunch | |
| 13 | Force-close after a bridge save, relaunch | The row comes back with a working Stop | |
| 14 | Stop that recovered row | Exactly that look stops; nothing else changes | |
| 15 | Bridge save where the manifest cannot be written | Never says "saved and running"; no untracked resources left | |
| 16 | Two bridge-run looks in two rooms | Both recover; stopping one leaves the other running | |
| 17 | Clean Bridge Resources | Confirmation names the exact bridge; result states what was removed and what was not | |
| 18 | Scroll the room wheel onto a room with a running effect | Wheel stays visible and usable; the panel does not cover it or flicker | |
| 19 | **Round 4g.** Start a streaming look (Party/Strobe/Thunderstorm) on bridge 1, then start one on bridge 2 | BOTH bridges stream at the same time; bridge 1's lights keep animating after bridge 2 starts | |
| 20 | **Round 4g.** With both bridges streaming, stop ONE of them | The other bridge's stream keeps running, its Now Playing row stays, and its controls still work | |
| 21 | **Round 4g.** With both bridges streaming, move a slider in each room | The edit changes only that room's bridge; the other bridge's look is unaffected | |
| 22 | **Round 4g.** With bridge 2 streaming, start a second streaming room on bridge 2 | The app ASKS (switch prompt); confirming stops the old room and streams the new one — same-bridge exclusivity unchanged | |

### V-A. Track A — unified customization engine, Rolodex + inline host

**Every row below is UNPROVEN. Nothing here has been on a device.**

Branch `fix/unified-rolodex-host`, rollback tag `checkpoint/pre-unified-rolodex-host`
(at `320ebaf`). Five commits, **unmerged**, no build bump (a `project.pbxproj`
edit was forbidden in this packet, so `CURRENT_PROJECT_VERSION` must be bumped in
its own commit before installing).

| Commit | SHA | What |
| --- | --- | --- |
| C1 | `fd03ecb` | bridge-qualify every selection-keyed side effect |
| C2 | `afed54f` | extract `RolodexSelectionMachine` — no behaviour change |
| C3 | `1c01b14` | previews while dragging, commits after settling, tap activates |
| C4 | `d73760c` | extract `StudioRegionWiring` |
| C5 | `757a1ea` | inline customization host below the pinned rolodex |

**What the automated run does and does not prove.** The suite is 1440 passed /
0 failed across 96 suites, and `Scripts/hardening_guards.sh` passes. **None of
that is evidence about hardware.** In particular C5's layout probes render a
harness that MIRRORS `StudioView`'s composition order (wheel above region) rather
than driving the real screen — `StudioView`'s view model is `@State private` and
a running effect cannot be injected into it. Real-screen placement, real gesture
routing, and the feel of the settle are therefore **hardware-UNPROVEN**, and the
render probes must not be read as placement evidence.

**One removal needs explicit device attention.** The drag-up-to-expand gesture
went with the overlay: `isMixerExpanded` was a HEIGHT job on a fixed-height box,
and full-region there is no height to expand. Advanced params are now reached
ONLY through the host's own disclosure and the existing "+N more" sheet. Row 36
exists because that path lost its old entry point and nothing on the automated
side can prove the new one is discoverable.

| # | Test | Expected | Result |
| --- | --- | --- | --- |
| 23 | Drag the wheel fast across 6+ rooms, several with running effects | Scrolls smoothly through all; the panel does **not** open, close, or flash; only the centre highlight moves | **UNPROVEN** |
| 24 | Watch the centred room name while dragging, then release | Mid-drag the name highlights and the lens reads "hovering"; nothing below changes. On release it snaps and *then* the panel switches. Should feel crisper — report if abrupt | **UNPROVEN** |
| 25 | Console/Charles open; drag across 6 rooms on a bridge with entertainment areas | **Zero** selection-triggered network work *during* the drag. After settling, **no more than one** refresh for the final exact selection — subject to the existing ≤60s coverage cache and in-flight coalescing, so a legitimately cached no-GET is also a PASS | **UNPROVEN** |
| 26 | Start a streaming look, then drag the wheel | Wheel stays on screen and responsive for the whole gesture; never removed mid-drag, never covered | **UNPROVEN** |
| 27 | With an effect running, scroll the panel top→bottom in one continuous drag | One continuous scroll, no inner panel scrolling separately, no rubber-band stop; header stays pinned and tappable | **UNPROVEN** |
| 28 | Drag the hue/saturation pad, then each slider | Every drag lands on the control it started on; panel never dismisses under the finger | **UNPROVEN** |
| 29 | Tap "Back to decks" in the panel's **pinned header**, then the "Live Controls" pill | Decks return with the effect still running; the pill brings the panel back. Nothing restarts, nothing stops | **UNPROVEN** |
| 30 | VoiceOver: swipe to the wheel's centre row and double-tap | Customization **opens** for that room (today the row announces as a button and activating it does nothing at all) | **UNPROVEN** |
| 31 | Two bridges with the **same** Hue room id; switch between them | Deck-0 coverage badges refresh — bridge A's numbers never show against bridge B's room | **UNPROVEN** |
| 32 | Rename/delete a room in the Hue app **while mid-drag** | Drag continues; wheel re-centres on a surviving room; nothing stays selected that no longer exists | **UNPROVEN** |
| 33 | With the panel open: background→foreground, switch tabs and back | Panel and scroll position preserved; no animation runs while Studio is off screen | **UNPROVEN** |
| 34 | Release the wheel and watch closely as it springs to rest | Nothing below the wheel changes *while it is still moving*. The panel/room content switches only once the wheel has visibly stopped | **UNPROVEN** |
| 35 | Tap the centred room when it is **already** the selected room | Customization opens for that room (this is the case a commit-only design silently no-ops). Nothing starts, stops, or restarts | **UNPROVEN** |
| 36 | **C5 amendment — advanced controls.** With an engine card running, look for the advanced params: use the host's disclosure, then the "+N more" sheet | Every advanced param is reachable WITHOUT the deleted drag-up gesture; the disclosure is discoverable without being told it exists; "+N more" still opens `StudioParamSheet` unchanged | **UNPROVEN** |

Rows 23–35 are the approved §V set from the Track A packet, verbatim. Row 36 is
an addition made when C5 removed the drag-up reveal.

**Track A is NOT complete and NOT merge-ready.** It is five green commits on a
branch. It becomes a candidate only after rows 23–36 are physically executed.

---

Items 6, 7 and 8 need a second controller (Hue Sync or the Hue app) and cannot be
produced in the simulator — the test harness deliberately cannot complete a DTLS
handshake, so a genuinely stable takeover is hardware-only. Leave any
bridge-disconnection or multi-controller case **BLOCKED** or **UNPROVEN** until
physically executed.

**Packet 8 is still open.** Item 15 in particular needs a reproduction where a
manifest definitely persisted. Note that "Save as Hue dynamic scene" (Palette →
+N more) creates a Hue *scene*, which is bridge-run but has no ownership record
and can only be stopped from Scenes or the Hue app — if that is what produced the
original unstoppable effect, the symptom is real but is not a reconciliation bug.
Record which action was used.

### V-B. Slice 2 — unified customization Studio instrument (2026-09-01)

**Every row below is UNPROVEN. Nothing here has been on a device or a physical
bridge.** Branch `feat/unified-customization-studio-instrument` (base `ca074b8`,
rollback tag `checkpoint/pre-unified-customization-slice2-2026-09-01`).

What the automated run does and does not prove: the registered suite, the
hardening guards and the generated capability matrix prove the exact-identity
state model, the fences, the board composition, and every code-proven send
path — on simulator. None of that is evidence about firmware behaviour, radio
timing, gesture feel, haptics, or VoiceOver. The render probes MIRROR
`StudioView`'s composition order and must not be read as placement evidence.

Rows 37–39 are the capability-matrix hardware-pending rows (audit §2C): until
they run, `brightness` and the legacy color/warmth fallbacks stay classified
as approximations, never full live mutation.

| # | Test | Expected | Result |
| --- | --- | --- | --- |
| 37 | Each firmware effect running on effects_v2 lights: drag Speed, pick a Base Color, turn Warmth | The EFFECT itself visibly re-parameterizes per light (rate/tint/temperature), per effect and light model | **UNPROVEN** |
| 38 | Any firmware effect running: drag Brightness | The grouped state write visibly scales the running effect's output (not a flicker-fight, not ignored) | **UNPROVEN** |
| 39 | v1-only lights running an effect: pick Base Color / Warmth | The grouped xy/mirek fallback shifts the look without visibly fighting the firmware effect; if it fights, the control must be reclassified staged | **UNPROVEN** |
| 40 | Room whose lights all reject effects_v2: open a firmware effect's board | Speed renders DISABLED with the local reason copy — no knob that moves while doing nothing | **UNPROVEN** |
| 41 | ONE bridge, TWO rooms, same Live card on both | Independent values on switch; edit A never moves B; Reset A leaves B; Stop A leaves B playing | **UNPROVEN** |
| 42 | [2-phone] TWO bridges sharing a Hue room id, same card on both | Selecting either shows ITS exact values; edits/reset/stop never cross bridges | **UNPROVEN** |
| 43 | A room and a zone sharing an identifier, both active | Two rows in PLAYING NOW; each independently editable and stoppable | **UNPROVEN** |
| 44 | **Adaptive fine control feel (spec §5.2 gate).** Drag a knob, slide the finger sideways, return | Precision increases predictably away, restores near; if it feels unpredictable, the gesture must NOT ship | **UNPROVEN** |
| 45 | Double-tap a knob; long-press it; tap the readout and type 999 | Double-tap resets that one param; long-press/tap opens exact entry; typed value clamps into range | **UNPROVEN** |
| 46 | Sweep a knob end to end slowly | Ticks ONLY at default/limits/steps — no continuous buzzing; Stop All's haptic clearly heavier | **UNPROVEN** |
| 47 | Tap `PARTY · LIVING ROOM ›`; use the panel's Reset; tap the header's circular Stop | Panel expands inline (no sheet); Reset restores THIS room only; Stop stops THIS room only | **UNPROVEN** |
| 48 | With looks on several rooms/bridges: tap the toolbar octagon | One tap, no confirmation, every ChromaGlow look stops everywhere; no debounced write lands afterwards | **UNPROVEN** |
| 49 | Open the magnifier list with looks running | PLAYING NOW first (room + look + live dot); row Stop removes it immediately; tapping an active row switches the console instantly without closing it | **UNPROVEN** |
| 50 | Idle room selected, another room playing: tap "Apply … here" | The look starts with the source's CURRENT values, once; edits afterwards never link the two rooms | **UNPROVEN** |
| 51 | Long-press a deck card; tap its star; check FAVORITES/RECENTS bands | Context menu offers favorite + Details & Setup; star toggles in place; bands stay compact and current | **UNPROVEN** |
| 52 | Details & Setup → PREVIEW LIVE over a running look → "Put It Back" | The previous look returns with its EXACT values; switching rooms mid-preview then cancelling restores NOTHING anywhere | **UNPROVEN** |
| 53 | Beat: activation row only when off; enable on each engine; strobe beat-locked at high BPM | Full Beat instrument reveals inline; division/phase audibly land per engine; flashes never exceed 3 Hz | **UNPROVEN** |
| 54 | Expand a color editor in room A, switch to active room B, back to A; stop A; restart | A's expansion is restored during the session, gone after its stop; a fresh session starts clean | **UNPROVEN** |
| 55 | Exact entry on a knob with the keyboard up; scroll; switch rooms mid-entry | Host never collapses; the wheel never jumps; the typed value lands on the room the edit began on or drops | **UNPROVEN** |
| 56 | Reduce Motion + largest Dynamic Type + VoiceOver over the board | No springs/decorative motion; labels/values/adjustable actions on every knob and fader; "Reset to default" action present; strobe refusal intact | **UNPROVEN** |
| 57 | Party/Thunderstorm in Room mode (no streaming) | Speed, Fade Floor, Flash Length, Afterglow show STREAMING ONLY and genuinely change nothing until streaming starts | **UNPROVEN** |

**Slice 2 is NOT hardware-complete until rows 37–57 are physically executed.**
Row 36 above is SUPERSEDED by rows 45–47: the Advanced bucket, its disclosure,
and the `StudioParamSheet` reveal it tested no longer exist as a product path —
every control now lives on the one board (spec §2.3).

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
