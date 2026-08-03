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
