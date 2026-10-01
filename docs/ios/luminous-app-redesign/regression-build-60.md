# Build 60 device regression: bug log

**Date:** 2026-10-01, 01:50–03:40
**Device:** Brian's iPhone 17 Pro Max, driven by Claude through iPhone Mirroring, with the app's live console log captured.
**Build:** 1.0.0 (60), Debug, branch `experiment/luminous-app-redesign` (`bc58e70`, code identical to the TestFlight upload).
**Bridges:**
- "My Bridge": 5 rooms and 1 zone.
- "Bridge 8776": 3 rooms and 2 zones.
- 28 lights in total.

**Test room:** Main bathroom (8 lights). Bedroom and My room were never sent a command; the log was checked for this. The whole-house actions (All Off, Moods) were tested in Demo Mode only.

**Severities:**
- **High:** a feature is broken or unreachable, or data can be lost.
- **Medium:** wrong behavior with a workaround, a clearly visible defect, or a real performance cost.
- **Low:** polish.

Items marked *(Brian)* match the problem Brian reported: "can't scroll to the bottom / can't reach save, effect and delete controls".

## Fix status: build 61 (2026-10-01, same branch)

Rollback tag `checkpoint/pre-build-61-regression-fixes`. One commit per fix. Every item marked *phone* was
re-tested on Brian's iPhone on the real bridge (not Demo Mode, per Brian), with the live console log.

| Bug | Commit | Status |
|-----|--------|--------|
| **Crash (new, reported by Brian):** adding a colour in the Composer's Colors editor aborted the app (two crash reports, 05:03/05:05, Swift exclusivity violation) | `533347a` | Fixed, *phone*: 4th and 5th colours added; regression test `testEditClosureMayReadTheDocument` |
| Five+ colours pushed the Colors editor off both screen edges (new) | `533347a` | Fixed (scrolling swatch strip) |
| H-1 Select docks behind the tab bar | `4d9ceb1` | Fixed, *phone* |
| Lights → Scenes left the lights Select dock up (new) | `32fab72` | Fixed, *phone* |
| H-2 Sliders steal vertical swipes | `3af6cf2` | Fixed: simulator with real touches (swipe scrolls, value unchanged; sideways drag and tap set it); *phone*: a vertical drag no longer moves a Composer slider |
| H-3 Room scene Select taps did nothing | `1315e48` | Fixed, *phone* (no light command sent) |
| H-4 Room Delete Scene had no confirmation | `a6bd794` | Fixed, *phone* (throwaway scene: asked, then DELETE 200 41 ms) |
| H-5 Composer could never stream here (+ M-7 copy) | `f1d46d7` | Fixed, *phone*: the Composer's own area chooser; "Bed party" picked, Go Live → Live · Streaming over 10 lights, no per-light REST while streaming; the pick survives relaunch |
| Stop after streaming to an area that reaches other rooms left those lights on the last frame (new) | `f1d46d7` | Fixed, *phone*: Stop restored all 10 lights (8 + 2 Bedroom) |
| M-1 Home toast behind the tab bar | `c71eb97` | Fixed, *phone* (real mood) |
| Zones kept their old Off / 2% after a house-wide mood (new) | `fb22ef8` | Fixed, *phone* |
| M-2 Power on showed 1% for ~3 s | `a25d62f` | Fixed, *phone* (40% at once); lamps also light at once |
| M-3 Lamp dots under the power button | `f59f988` | Fixed, *phone* (incl. the "+4" count) |
| M-4 Made-up scene colours | `f291a2d` | Fixed, *phone* (Room tiles, Scenes tab, Copy sheet) |
| Room scene tiles never said "On now" (new: tested `"active"`, which CLIP v2 never sends) | `f291a2d` | Fixed, *phone* |
| M-5 Saved banner never dismissed | `667ab33` | Fixed, *phone* |
| M-6 Stop meant three things | `9ac7c9f` | Fixed for Studio Classic, *phone*: Candle → Stop restored the room, no grouped off |
| M-8 Static looks streamed forever | `d4c8a23` | Root cause: Studio speed 0 is the SLOWEST motion (20 s cycle), not still, and the AI gave a "Static" look a cascade. Still-light prompts now get the static pattern and a steady envelope. Not tested on hardware (Studio Classic out of scope) |
| M-9 Room-mode latency "doubled" | none | **Not a code regression**: the sending code is identical in builds 59 and 60. Per-request times inflate because each sweep sends 5 lights at once to a bridge that serialises them. Re-measured: Hallway 5.5 cmd/s, p50 163 ms |
| M-10 Search kept focus after Copy / Move | `a9b1c8e` | Fixed, *phone* |
| M-11 Schedules didn't say what they control | `1240467` | Fixed, *phone* |
| M-12 Demo Mode reorder / stale dots | none | Not fixed: Demo-only. Brian asked for real-bridge testing; the real-bridge equivalent (zones) is fixed |
| M-13 Dynamic scenes | `2679f86` | Fixed, *phone*: badge stays; speed 0.35 → 0.73 stored on the bridge; Activate → all 8 lights `dynamic_palette` at 0.73 |
| P-1 Full reload of both bridges after every change | `de02185` | Fixed, *phone*: a brightness drag re-reads only its own bridge (4 GETs, was 8) |
| P-6 Double effect commands | none | Deliberate: the v1 blanket gives the first bulb ~50 ms; v2 only follows when the user set speed / colour / warmth |
| Room Select bulk actions (were unreachable) | — | *phone*: Off / On / Brightness / Scene all work, 8 paced PUTs each |
| P-2, P-3, P-4, P-5, P-7, P-8, P-9 | none | Not done this round (duplicate GETs at startup / Go Live / scene save, paint PUTs, SSE watchdog, live slider, log gaps) |
| Low (polish) items | mostly none | Card lamps lagging after power-on fixed with M-2; the rest stay open |

## Logs: TestFlight build vs Xcode build

The TestFlight build cannot show live logs, for two reasons:
- It is a Release build. Every diagnostic `print` is compiled out under `#if DEBUG`.
- App Store and TestFlight builds don't allow a debugger to attach, so `devicectl --console` cannot connect to them.

For this run the Debug build 60 was installed on top of the TestFlight copy. Nothing was deleted, and the pairing and data survived. That build shows every bridge request with its status, latency and size, plus the orchestrator's decision log.

To go back to the TestFlight copy, reinstall it from the TestFlight app.

## High

| # | Bug | Repro | Evidence / cause | Fix direction |
|---|-----|-------|------------------|---------------|
| H-1 *(Brian)* | **The Select-mode action buttons are hidden behind the tab bar.** For lights that is On / Off / Brightness / Scene; for scenes it is Edit / Delete. Only the "N selected · All" row shows. | Room → Select → pick lights. Or Room → Scenes → Select. | `RoomDetailView.swift:182` docks the bar with an inner `.safeAreaInset`. That inset does not stack on MainTabView's own inset (DEVLOG ~5521). The pre-redesign code used `.padding(.bottom, 100)`. | Clear the bar explicitly (bar height plus margin), using one shared constant. |
| H-2 *(Brian)* | **Sliders steal scroll swipes.** A vertical swipe that starts on a slider changes its value instead of scrolling. In Composer → Tune this moved Speed from ×1 to ×0.48 and marked the look EDITED. The same slider is used on Light control, Room, the Home cards and the Color wash sheet. | Composer → any look → Tune → swipe up starting on a slider. | `LuminousGlowSlider` (LuminousKit.swift:686) and `Composer2GlowSlider` (Composer2Controls.swift:125) use `DragGesture(minimumDistance: 0)` over the full track. | Use a minimum distance of about 8 and claim only horizontal-dominant drags. |
| H-3 | **Scenes can't be selected one by one in Room Select mode.** Tapping a card or its circle does nothing; only All / None work. | Room → Scenes → Select → tap a scene. | `RoomDetailView.swift:823-828`: the Button's label (`RoomSceneTile`) has `.allowsHitTesting(false)`, so the button has no hit area. | Move `allowsHitTesting(false)` to the tile's inner content, or give the Button a `contentShape`. |
| H-4 | **Room "Delete Scene" deletes immediately.** The long-press menu removes the scene from the bridge with no confirmation and no undo. The Scenes tab does confirm. | Room → Scenes → long-press a scene → Delete Scene. | `RoomDetailView.swift:873-876` calls `vm.deleteScene` directly. | Reuse the Scenes tab's confirmation dialog. |
| H-5 | **The Composer can never stream (Entertainment) in Brian's home.** It always falls back to Room mode, which is slower and uses REST. | Composer → Main bathroom → Go Live. The dock says "Several Entertainment Areas cover this room. Choose one in Studio Classic…". | `Composer2LiveGateway.swift:144-147` turns `.choiceRequired` into Room mode. The Composer has no area picker, and an area picked in Studio Classic isn't shared with it: retested after picking an area in Studio, still Room mode. `.choiceRequired` is also raised for a **single** area that also covers lights outside the room ("1 areas could serve room — asking which"). | Add an area picker to the Composer, or share Studio's per-room choice. Auto-pick when exactly one area covers the room entirely. |

## Medium

- **M-1: the Home toast is hidden behind the tab bar.** The confirmation (e.g. "Test 1 is on") can't be read. Cause: `DashboardView.swift:102-107` uses `.overlay(.bottom)` with 16pt padding.
- **M-2: power ON from a Home card shows 1% for about 3 s.** The slider sits at its minimum until the delayed full reload restores the real 6%. The optimistic state doesn't carry the last brightness.
- **M-3: Home card lamp dots sit under the power button.** The last lamp is hidden on rooms of 2, 3, 8 and 10 lights. The "+4" overflow count on Living space (16 lights) is hidden too.
- **M-4: scene cards show made-up colors.**
  - Room scene tiles always use a color derived from the scene's name (`SceneDisplayItem.swift:19` `color(for: name)`, `SceneChip.swift:23`). For example, the red/blue/green "Test 1" shows as lavender.
  - Scenes-tab cards, Copy and Move do the same for scenes with no `palette`. "QA Capture 60" was all red but showed lavender, and "Bedroom Aurora" is wrong too.
  - Fix: use the scene's actions (xy/mirek), as the Home starred strip already does correctly.
- **M-5: the Composer "Saved · <name>" banner never dismisses itself** (still up after more than 60 s). It sits exactly over the editor's top bar (✕, room picker, undo/redo), so it has to be dismissed before you can close the editor.
- **M-6: Stop means different things in different places.**
  - Composer Stop puts the room back exactly as it was (verified).
  - Studio Classic bulb effects (Candle) and Studio's Composer tab turn the room **off** (`grouped_light on=false`).
  - Studio Live (Ambient, and streamed Thunderstorm) sends nothing, so the lights freeze on the last frame. Main bathroom was left at a dim blue 4.7%.
  - Fix: one "restore what was there" rule for every engine.
- **M-7: the Entertainment copy is wrong.**
  - Studio's chooser says "More than one Entertainment Area covers this room." while listing **one** area ("Bed party").
  - The Composer dock says "Several…" for the same room.
  - The real situation is that the only area also drives 2 Bedroom lights.
  - The dock line (`Composer2PerformanceBar.swift:85`, `lineLimit(2)`) is also at its limit.
- **M-8: static looks keep sending commands forever.** An AI look with motion speed 0 ("Static Warm Sunset", Cascade at speed 0) sent about 9 per-light commands per second indefinitely (63 writes in 7 s). The Composer's REST sender doesn't skip unchanged frames.
- **M-9: Composer Room-mode latency doubled against build 59.**
  - Go Live Thunderstorm on 8 lights ran at 7.9 commands/s:
    - build 60: p50 286 ms, p90 566 ms, max 749 ms;
    - build 59: p50 128 ms, p90 299 ms, max 396 ms.
  - Room → Looks → Play here ran at about 15 commands/s (296 PUTs in about 19 s, measured before timestamps were added; worth rechecking). That is above the bridge's roughly 10/s budget, and its p50 was 298 ms.
  - Bulb-effect starts dispatch 5 at a time, so latencies stack from 223 ms up to 775 ms.
- **M-10: Scenes tab, the search field stays focused after Copy or Move.** The list then jumps back toward the top whenever the layout changes. During testing it shifted the page in the middle of a long-press, onto a different "Test 1" card. Dismiss focus when those sheets close.
- **M-11: schedules don't say what they control.** New schedule → Mood or Effect has no room or light target. A weekday 8 AM "Energize" gives no hint whether the whole house is affected.
- **M-12: Demo Mode problems after a Mood.**
  - The room cards reorder (Bathroom and Guest Bedroom jump to the top).
  - The lamp dots go stale: Living Room keeps a blue dot under the warm Relax mood, and Bathroom shows 1 dark dot for 3 lit lights.
- **M-13: dynamic scenes are inconsistent** (partly suspected).
  - The app always recalls scenes with `action: active` (`HueAPIClient.swift:222`).
  - The "Dynamic" label and the speed dial only appear while the bridge reports `dynamic_palette`. After the Scenes tab recalled "Test 1" both disappeared.
  - The speed set in the sheet (0.69) was not saved to the scene; the bridge still reports `speed 0.35`.

## Low (polish)

**Welcome tour**
- **Outdated art:**
  - Page 2's art shows the old icon-and-slider tiles while the copy describes glowing lamp dots.
  - Page 3's mood bar is a grey blur.
  - Page 4's art is "Light 1/2/3" list rows while the copy says "stage".
  - Page 5's "Neon Nights" card floats between the columns.
- **Last page:** the header jumps up about 11pt and the art shrinks.
- **"No cloud":** the copy says "no cloud" although discovery falls back to the Philips cloud endpoint.

**Home**
- Content scrolls under the status bar and the floating buttons with no fade.
- Card lamp dots lag about 1.7 s after a slider change (they only refresh on the full reload).
- An Off card loses its slider and goes out of line with its neighbour.
- Room titles render at different sizes: `minimumScaleFactor` shrinks "Kitchen" and "My room".
- The Color wash sheet always defaults to 80% brightness; at night that jumps the room from 6% to 80%.
- All Off has no confirmation or undo, and it acts on all 28 lights. This was tested in Demo Mode only.

**Room and light pages**
- Entering or leaving Select mode resets the scroll position.
- After using Warmth, the light page still shows the old color thumb and swatch as selected.
- In the scene builder the light chips truncate to "Main bath…" ×8.
- A newly saved scene isn't marked On now even though the lights match it.
- The active mood isn't shown as active.

**Composer**
- The ✕ scrolls away with the content.
- The "Delete this look?" popover has no Cancel button.
- The room capsule uses a generic house icon.
- The library remembers the last category filter (Party) between visits.

**Scenes**
- The Move sheet labels the source room "Duplicate".
- On Capture, choosing a room inserts a notice that pushes Save down, so a tap lands on the notice.
- Capture shows no confirmation.
- Room icons differ between the Capture chips and the Home cards.

**Studio Classic**
- It still uses the old style.
- It opened on Bathroom rather than the room chosen in the Composer.
- Its Composer card still says "EXPERIMENTAL".
- A Live mode is added to Recents even when the area chooser is dismissed.
- The AI generator returned an icon name equal to the prompt (the fallback works), and called a look "Static" while giving it a Cascade pattern.

**More**
- **Automations:**
  - Switching Mood ↔ Effect jumps the scroll.
  - The schedule ⋯ menu anchors to the header chip.
  - "Automations Console" (raw bridge IDs and byte counts) is reachable in the consumer UI.
- **Devices:** rows aren't tappable.
- **Physical Controls:** it doesn't say that no Tap Dial is paired.
- **Entertainment Areas, New area:**
  - Light names truncate ("Kitchen light q…" ×3, "Main bathroom…" ×3; `EntertainmentConfigBuilderView` `lineLimit(1)`).
  - Typing right after the bridge menu closes is dropped.
- **Bridge Manager:** the hold menu puts the red Remove Bridge above Rename.
- **Settings:**
  - Rows scrolled under the sheet's floating Done strip can't be tapped.
  - Preview Demo Mode switches on immediately with no confirmation, and the list shifts under the finger.
  - The footer shows the branch name (`experiment/luminous-app-redesign`) to TestFlight testers.
- **Demo Mode:**
  - The Exit Demo Mode icon is blank.
  - The More header still says "All 2 bridges connected".
- **Music Source:** Apple Music uses a house icon.

## Performance and logic (from the live log)

| # | Finding | Measured | Fix direction |
|---|---------|----------|---------------|
| P-1 | Every successful change (toggle, slider, scene) schedules a full `loadAll()` of **both** bridges 1.5 s later, even after SSE has confirmed it. | 9 GETs, about 60 KB per action (`UnifiedOrchestrator.swift` `scheduleStateRefresh`) | Refresh only the bridge that was touched, or skip when SSE already confirmed. |
| P-2 | Startup fetches the same data several times: `/light` 2× per bridge, `entertainment_configuration` 3×, `entertainment` 2×, because Studio and Composer prewarm each fetch their own copy. | about 150 KB extra | Share one cache. |
| P-3 | Go Live does 7× GET `/light` (28.5 KB each) plus 3× entertainment config and 3× entertainment before the first light command. | about 1.0 s from tap to first light | Reuse the orchestrator cache. |
| P-4 | Scene save, rename or update triggers 2–5 full GET `/scene` refetches. | 25–36 KB each | Fetch once per bridge. |
| P-5 | Paint/paste sends 2 PUTs per light (mirek, then brightness). The scene builder sends 8 per-light PUTs when every light is selected, and on Cancel restores all lights with 2 PUTs each. | 16 commands for 8 lights | One PUT per light; use a grouped_light PUT when every light gets the same value. |
| P-6 | Starting a bulb effect sends both v1 `effects` and v2 `effects_v2` for every light. | 16 commands; latency stacks up to 775 ms | Send v2 first and fall back to v1 only on a 400. |
| P-7 | SSE reconnects every 180 s on both bridges (idle watchdog). | 5 reconnects in 12 min | A heartbeat-aware watchdog. |
| P-8 | Sliders send only when released, so the bulbs don't follow the finger. | — | Design call: optional throttled live updates at about 5–8 Hz. |
| P-9 | Logging gaps: Composer per-light writes log only `effect on=Optional(true) dur=200ms` (no xy or brightness, so sends can't be audited); "splash.route unpaired → setup" appears while paired; "✅ enabled" is printed before the PUT returns; Debug prints whole 21–36 KB GET bodies. | — | Log the payload summary; trim the bodies. |

**Responsiveness (bridge round-trips):**
- **Room power:** 76–79 ms. **Slider commit:** 58–67 ms. **Wash:** 70 ms.
- **Color wheel:** 155 ms. **Swatch:** 91 ms. **Warmth:** 96 ms. **Identify:** 45 ms.
- **Mood:** 67 ms. **Scene recall:** 92–167 ms (432 ms with speed).
- **Scene:** create 45–139 ms, rename 40 ms, update 73 ms, delete 38–66 ms; cross-bridge copy 536 ms.
- **Automation toggle:** 121–548 ms.
- **Area:** create 367 ms, delete 128 ms.
- **Entertainment session:** start 224 ms, stop 289 ms.
- **Startup:** first frame +156 ms, both bridges loaded at +596 ms, SSE connected under 1 s.

## Verified working on hardware

- **Welcome tour:** all 12 pages.
- **Home:**
  - The power toggle sends one grouped PUT.
  - The slider commits once, on release.
  - Hold → Color wash applies.
  - The starred-scene strip shows real colors.
  - The Now Playing card and its Stop work.
  - SSE updates the room and zone cards.
- **Room:**
  - Light control: brightness, wheel, swatches, warmth, Identify, My Colors.
  - Copy Color → Paint mode.
  - Edit Room (cancelled) and Light Console.
  - A mood with its toast; scene activate; Favorite.
  - New scene → rename → edit/update → delete.
  - Looks → Play here → Stop, with an exact restore.
- **Composer:**
  - Room picker; Try it → preview → Go Live.
  - Live Tune changes; Another take.
  - Save as new; the Yours filter; Duplicate; Delete (confirmed).
  - Play in room from the menu; See all.
  - Stop (about 0.4 s, exact restore), including Stop from Home's Now Playing card.
- **Scenes:**
  - Search, sort and card size.
  - Copy to Room across bridges; Move to Room.
  - **Undo** (5 s window): deletes the new copy and re-creates the original.
  - Delete with confirmation; the dynamic Speed sheet; Capture Room Look; Build Colors with Cancel restoring the room.
- **Studio Classic:**
  - Opens from the Composer with a back button; the room rolodex.
  - Candle with live Base Color; Live Ambient with a live fader.
  - The area chooser: Done starts nothing.
  - Generate with AI → the Room Only chooser; the Layers editor.
- **Entertainment streaming, first verification on Brian's bridge:**
  - Studio Live Thunderstorm streamed over a temporary 8-light area.
  - No REST writes were sent while streaming.
  - Clean session teardown in under 0.7 s.
- **More:**
  - Automations: create, Save, Delete a schedule; toggle a bridge automation; the console.
  - Devices; Entertainment Areas (create, delete); Physical Controls.
  - Profiles: the editor opens, and Done discards an empty draft.
  - Share Invite (QR shown, not shared); Bridge Manager (menu opened, cancelled).
  - Settings: scrolls to the bottom; All Day Scenes view; Music Source sheet.
- **Demo Mode:**
  - Enter and exit, with zero bridge writes while in demo.
  - All Off and Relax mood across 7 demo rooms.

## Not tested, and why

- **Whole-house actions on the real home** (All Off, Moods "every room at once", All Day Scenes enable, the real Sleep suggestion): too disruptive at 3 AM. Tested in Demo Mode only.
- **Keyboard overlap** (the AI prompt, sheets with text fields): iPhone Mirroring hides the on-screen keyboard. **Dynamic Type sizes and small phones:** this device runs at default text size only. The code audit flagged several issues for small screens and large text:
  - The bulk Brightness sheet (`.fraction(0.34)`) clips its Apply button.
  - SceneSpeedSheet doesn't scroll.
  - `LuminousScreenTitle`'s subtitle and `LuminousRow`'s subtitle stop at `lineLimit(2)`.
  - Studio's caveat and badge lanes clip.
  - The tab bar is 72pt tall but 64pt is reserved, and it rides up on the keyboard.
- **Perform and the sequencer:** not reached; the Perform button only shows in a running composition's mixer tray.
- **Destructive or account actions:**
  - Forget All Bridges, Remove Bridge, Clean Bridge Resources.
  - Creating a real guest profile or invite (these mint bridge keys).
  - Pairing a new bridge.
- **Inputs needing permissions or hardware:** the microphone, Apple Music, Spotify and Auto-Detect sources (no mic permission was granted), Tap Dial DJ Mode (no dial is paired), Siri/Shortcuts, widgets, Apple Watch, landscape.
- **Room select-mode bulk actions:** On/Off, Brightness, Scene, Edit and Delete could not be tested because their buttons are unreachable (H-1, H-3).

## State left on the phone and bridges

- The phone runs the **Debug** build 60 (developer-signed), not the TestFlight copy.
- During testing, the iOS notification prompt was answered **Allow**.
- Every test item was deleted, and "Test 1" is no longer starred. The test items were:
  - scenes "QA Regression 60" / "QA Renamed 60", "QA Capture 60", and the Laundry-room copy of "Test 1";
  - the look "QA Storm 60" and its copy;
  - the schedule "QA Schedule 60";
  - the Entertainment Area "QA Stream 60".
- One orange swatch was added to My Colors and is still there.
- Leaving home → enabled → disabled again (it was off).
- Main bathroom is left on "Test 1". Every other room was never sent a command.

## Appendix: read-only code audit (layout clipping), not reproduced at default text size on a Pro Max

- **Tab bar height:** the bar is 50 + 7×2 + 8 = **72pt**, but `MainTabView.swift:442` reserves only 64pt (the comment at :441 is stale). The bar's `.contentShape(Rectangle())` (:658) also swallows taps across the full-width strip.
- **Insets don't stack:** a tab screen's own `.safeAreaInset` does not add to MainTabView's (DEVLOG ~5491-5496, ~5521). That is the root of H-1.
- **Bulk Brightness sheet:** `BulkActionBar.swift:71-98` offers only `.fraction(0.34)` with a non-scrolling VStack of about 217pt. Apply clips on an SE and at AX2+ text. Fix: add `.medium`, or a ScrollView.
- **SceneSpeedSheet:** `SceneSpeedSheet.swift:29-74` is a non-scrolling VStack of about 441pt at `.medium`. "Activate Scene" falls off-screen on an SE.
- **`lineLimit(2)` caps:**
  - `LuminousScreenTitle` subtitle (LuminousKit.swift:403) truncates the manual-IP help (BridgeSetupView.swift:540), the Bridge Manager hint (BridgeManagerView.swift:34), and others.
  - `LuminousRow` subtitle (LuminousKit.swift:980) truncates the Clean Bridge Resources results (SettingsView.swift:273, :527-546), the location anchor (:622) and the MusicSourcePicker descriptions (:203).
  - The Composer dock status line (Composer2PerformanceBar.swift:85).
- **Studio Classic:**
  - The AI prompt with the keyboard up spills under the music bar (StudioView.swift:1016-1033, :1085-1087, card :2712-2722; `minimumHeight` at :2658 is never enforced).
  - "Details & Setup" doesn't scroll (StudioLookBrowserView.swift:38-61).
  - Caveats are capped at `lineLimit(3)` in a column about 117pt wide (StudioBoardView.swift:170, :286; ComposerLayerSheet.swift:273; StudioLookBrowserView.swift:306).
  - A badge set to `.lineLimit(1).fixedSize()` runs off the "Choose area" sheet (StageKit.swift:394-402, used at StudioView.swift:3069).
  - The MixerTray badge lane has a fixed `.frame(height: 28)` (MixerTrayView.swift:261).
  - Knob typing on an SE (MixerTrayView.swift:68-75).
- **Smaller items:**
  - Light names in the area builder are capped at `lineLimit(1)` (EntertainmentConfigBuilderView.swift:261). Its error notice sits below the grid while Create is in the toolbar (:132-134).
  - The tab bar rides up on the keyboard (MainTabView.swift:450); it should hide while the keyboard is up.
  - "Add Another Bridge" (BridgeManagerView.swift:77) and the Profiles empty state (ProfilesAccessView.swift:63) have only a few points of bottom padding.
  - Studio's music bar pads 70 against the bar's 72 (NowPlayingBar.swift:194).
  - The New Profile swatch row overflows by about 11pt on an SE (GuestProfileEditorView.swift:71-92).
  - The Composer hero badges truncate (Composer2HeroCard.swift:97).
