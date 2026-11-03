**DO NOT MERGE WITHOUT BRIAN'S EXPLICIT APPROVAL.**

Slice 2 of the Unified Customization Engine — the Slice 1 truth foundation made production-active, plus the binding Studio instrument from `UNIFIED_CUSTOMIZATION_SPEC.md` — **followed by a nine-commit remediation, over five adversarial review rounds,** that answers the review that blocked it and then the reviews of the remediation itself. `main` is untouched. Slice 3 (Composer convergence) is deliberately not started. **No hardware validation of anything here.**

Base `main` @ `ca074b85`. Slice 2 delivery head `89de143` (also the rollback tag). **Nine** remediation commits across five review rounds: `c8c801f`, `910c861`, `f2f7a19`, `10c2301`, `7d8d14e`, `2200e98`, `119aa4b`, `14a0cac`, `b06df67`. Final code head `b06df67`; PR head `0959d03` (the docs commit on top of it).

---

## 1. Original Slice 2 implementation

**The §2A production exact-state bug is actually fixed.** The audit documented three shipping defects: `paramValues` was card-global (the same card on two targets could not hold different live values), `updateStudioParams` validated `bridgeID` alone (two rooms on one bridge could cross-write), and `resetParams` nil'ed the card-global dict (reset blanked every target running the card). All three are dead, proven by tests that drive the actual production paths.

**The Slice 1 foundation became production-active.** `StudioViewModel` owns a `CustomizationValueScopes<Color>` engine and the app's single `CustomizationGenerationCounter`. Every `apply()` arm mints a `RunningLookIdentity`; every stop/reset/replacement fences it. The old mutation quartet (`setParamValue`/`setParamColor`/`sendParam`/`sendColorParam`) and the single global `paramTask` are deleted.

- **Persistent defaults (scope 1):** per card, same `studio.lastParams.v1` store and shape — no migration.
- **Live running values (scope 2):** keyed by `RunningLookTargetKey` (bridge + group + kind + card + execution).
- **Drafts (scope 3):** a gesture captures a `StudioParamSession` at start; every tick commits through `CustomizationFence`; a drag that outlives the selection drops instead of landing on the new room.

**Multi-bridge / same-bridge independence.** `runningEffects` and `activeCompositionBoxes` are keyed by `StudioSelectionKey` (bridge + group + **kind**), so a room and a zone sharing an id are two independent rows; kind-less records resolve through fail-closed unique-match helpers. `updateStudioParams(values:colors:bridgeID:roomID:)` carries the same `runtime.roomID == roomID` proof the round-4g stop path has.

**Session manager and browser.** The wheel is untouched (`RolodexSelectionMachine` and its 40 pinned tests). The searchable picker is now the session manager: **PLAYING NOW** first, with a one-tap exact Stop per row; a stopped target leaves the section immediately. Selecting an active target keeps the console open and switches to that instance's real values (`modeOnRoomChange` became a pure policy; the decks-side auto-open defect is pinned dead in both directions). **Apply Current Look** copies the source's exact live values ONCE, then the new instance is independent. The look browser adds compact FAVORITES/RECENTS rows (`StudioLookLibraryStore`, local-first, stale ids filtered against the live catalog), a star on every card plus long-press, and **Details & Setup expanding INLINE** — no sheet, no `fullScreenCover`.

**The board.** `StudioBoardCatalog` composes each of the 15 looks on a shared invisible grid with a designed hero; semantic primitives per spec §4 (faders for levels, knobs for rates/character, chips for discrete choices, the inline B+ colour editor, progressive Beat reveal). `ParamTier.advanced` is retired to `.support` prominence metadata (spec §2.3) — the ADVANCED caption, the inline/overflow partition and the reserved header metrics are deleted with tombstones; `StudioParamSheet` stays defined-but-unpresented (Guard 13 keeps the ban). The header is one quiet line (`PARTY · LIVING ROOM ›`) with the exact selected-target Stop beside it; **Stop All is always visible** (toolbar octagon, one tap, heavy haptic). Shared touch primitives (`InstrumentControlMath`, `StageKnob`/`StageFader`/`StageSteppedEncoder`, `StageColorEditor`, `StageBeatSection`) implement one gesture contract once, with the clamp *in* the math and exact typed entry through the shared parser.

**Capability honesty.** `EffectParameterProfiles` classifies every declared bridge-native parameter from source evidence: `speed` is live per-light v2 with **no** legacy branch (honestly unavailable on v1-only rooms), `base_color`/`warmth` are live per-light v2 with the long-shipping grouped fallbacks preserved and classified as approximations pending hardware, `brightness` is a grouped state write whose visible scaling during a firmware effect is hardware-pending, and `transition` gains the honest `.nextWrite` class (sends nothing; shapes the next write). `CustomizationSnapshotBuilder` intersects per-light `mirek_schema` into a `MirekRange` — CT-capable-but-schemaless downgrades to `.unreadable`, never a fake `153…500` — and a failed capability read yields an all-`.unreadable` snapshot instead of stale numbers. The engine reverse-audit proved `party.speed`, `party.min_brightness`, `thunderstorm.flash_length` and `thunderstorm.afterglow` are Entertainment-only reads, taking the `entOnly` inventory from three to seven. Per-engine Beat consumption was proven by reading the four engine loops — all four materially consume division and phase.

**Preview Live (§16.5).** Opt-in audition on the exact selected room. `PreviewLiveMachine` snapshots the previous look's identity and its exact live values; "Put It Back" restores through the normal `apply()` path, fenced by `CustomizationFence` on the audition's identity. No parallel runtime store anywhere: audition, restore and commit are all ordinary production applies.

---

## 2. Review findings that blocked it

Five defect families. The arithmetic is the point.

**R1 — the ≤3 Hz flash ceiling bounded the *requested* value, not the *realized* one.** The Entertainment loops render on a 20 ms frame grid, and the grid was never part of the math.

| Loop | Realized worst case | How |
| --- | --- | --- |
| Thunderstorm free-run | **5.0 Hz** at `frequency` 100 / `flash_length` 1 / `afterglow` 0 (≈4.17 Hz at card defaults; unsafe for `frequency` ≥ 94) | **No rate clamp of any kind.** `Int((2.0 − 1.8) / 0.02)` = `Int(0.19999999999999996 / 0.02)` = **9** gap frames (IEEE floors to 9), + 1 flash frame, + 0 afterglow = a strike every **10 frames = 200 ms** |
| Strobe free-run | **3.13–3.33 Hz** for every duty 10…90 at `speed` 100 | ON and OFF frame counts floored **independently** → 15–16 frames per cycle |
| Party free-run | **3.13 Hz at the shipped default `smoothness` 20** (3.33 worst) | same independent-floor defect |
| Thunderstorm beat branch | unbounded by the cap | discarded the WCAG-capped lock and gated on the **raw `binding.beatsPerCycle`** — the only raw-`beatsPerCycle` loop site in the repo |
| Any beat lock at exactly 3 Hz | **0.32 s** intervals | a 1/3 s boundary quantized onto 20 ms frames realizes **16 frames** |

No test in the repo measured a realized inter-onset interval; every "3 Hz" test asserted a requested float or a UI string. An entry-path audit confirmed every user-reachable path (drag, adaptive gain, typed entry, VoiceOver, reset, persisted load) clamps to the catalog range — but the in-range extremes were themselves unsafe, so the catalog clamp could never be the safety boundary.

**R2 — colour bypassed the resolver.** `StudioBoardView.colorSection` rendered a live swatch row and hue pad from a coverage chip alone and never called the resolver. `resolution(for:)` returned `nil` for **every** app-driven card, so every Live-card control was unconditionally interactive. `colorCapabilityContext` hard-coded evidence `.known`, so an unreadable capability read looked identical to full coverage. Consequences: a colourless room got a live colour editor, and Strobe's streaming-only `flash_color` stayed fully live in Room mode with no note.

**R3 — eight tracked repo guardrails were deleted as collateral.** `909dc47` removed all eight tracked `.cursor` guardrail files — the seven `.cursor/rules/*.mdc` and `.cursor/skills/chromaglow-code-quality-review/SKILL.md` — without mentioning them, while `AGENTS.md` and `CLAUDE.md` still pointed at them.

**R4 — production wiring gaps.**

- **`rekeyRunningInstance` had zero production callers** (its only caller was a test); `.transportChanged` / `.bridgeReconnected` / `.capabilityRefreshed` / `.selectionChanged` / `.roomRemoved` were never bumped by any shipping path. A lost Studio Entertainment session removed the runtime and the Now Playing row but left the view-model row standing with `isEntertainment: true` and no engine behind it; a composition ENT→REST failover left `isEntertainment` stale, so the resolver reported the wrong transport.
- **`apply()` was re-entrant and the loser orphaned a scope.** Each arm installed its identity and row after roughly a dozen awaits with no epoch check, and `RunningLookTargetKey` includes the card id — so a superseded apply of card A left A's value scope believing it was current while B's engine ran, and A's debounced sends passed the re-fence.
- **Per-target send loss.** The debounce slot was keyed per target rather than per control: a second parameter committed within 150 ms **cancelled the first parameter's bridge write outright**.
- **Preview Live's flags were optimistic.** `previewing` was set before the apply and never rolled back on refusal; stop and Stop All never cleared preview state; a fenced `.drop` was a silent no-op; the restore overwrote persisted defaults before an apply that might bail. The only tests were machine-level ordering tests — zero production-path coverage.

**R5 — docs and tooling overclaimed.** The audit's "flash-class ≤3 Hz preserved", the matrix's "68/68 proven", `CustomizationIdentity`'s "bump() is called for every event", "Warmth is real CT, range-honest through the snapshot", "entOnly is exactly the audited three", and "Guard 13 untouched (host file unchanged)" were each false or misleading. All seven of the matrix generator's committed `CITED_CONSUMERS` line numbers were wrong, and `--check` could not notice because it only diffed the rendered string.

---

## 3. Remediation by commit

| Commit | What it does |
| --- | --- |
| `c8c801f` chore(rules) | Restores all eight `.cursor` guardrail files from the base tree byte-for-byte, then patches **only** the statements Slice 1/2 invalidated, preserving every guardrail's intent (see §15). |
| `910c861` fix(studio) | Makes the 3 Hz flash ceiling a **realized-frame invariant**: `BeatMath.FlashSafety` (pure, clock-free), per-bridge onset ledger, `entertainmentMaxLockHz` = 2.94 Hz, all three Entertainment loops replanned. `FlashSafetyTests` (31). |
| `f2f7a19` fix(studio) | Resolves **every** board control, colour included, through one `StudioBoardAvailability` funnel with spec §17 staged semantics. `StudioBoardAvailabilityTests` (11). |
| `10c2301` chore(guards) | Machine-verifies every matrix citation, splits proven counts into code-proven / hardware-pending / pending, re-hardens two loosened Guard 12 anchors, extends Guard 13(a), adds **Guard 14** and **Guard 15**. |
| `7d8d14e` fix(studio) | Serializes Studio lifecycle mutations through one FIFO chain, wires the runtime rekey seams, coalesces per-target sends, and proves Preview Live on the production path. `StudioLifecycleSerializationTests` (6), `StudioPreviewLiveProductionTests` (7), `StudioProductionWiringTests` 17 → 24. |
| `2200e98` fix(studio) | Closes every BLOCKER and HIGH from a **fresh ten-lane adversarial review of the remediation itself** — flash, colour and lifecycle. See §3B. Suite on that tree: **1883 passed, 0 failed, 0 skipped**, twice. |
| `119aa4b` fix(studio) | Closes a **second** adversarial pass, against the round-two fixes themselves: gate the wire, freeze instance bases, unknown never refuses. See §3C. Focused on that tree: flash **132/132**, colour **107/107**, lifecycle **523/523**. Suite on that tree: **1935 passed, 0 failed, 0 skipped**, twice. |
| `14a0cac` fix(studio) | Closes a **third** adversarial pass: the flash gate becomes **wire-true** (reserve → send → commit, stamp at delivery, luminance model), copy-back layers instead of replacing, colour reach is effect-specific. See §3D. Suite on that tree: **1967 passed, 0 failed, 0 skipped** (one full run; the second was superseded by round five). |
| `b06df67` fix(studio) | Closes a **fourth** adversarial pass, run by a fresh orchestrator against `119aa4b..14a0cac`: a dropped send no longer forgets the wire, the cold path applies the red rule, the same-card audition restore is exact, the deferred-audition bracket is explicit, the colour badge shows the funnel's reach, and four guard gaps are closed. See §3E. |

---

## 3B. Second review round (`2200e98`)

A **fresh ten-lane adversarial review of the remediation itself** found real holes. Every BLOCKER and HIGH is fixed here, each with a deterministic test and, where a text guard can pin the shape, a Guard 14/15 sub-check.

### Flash safety

- **Party's beat-locked branch gated cycle-index *changes*, not luminance *rises*.** A backwards phase correction (music-service drive, a nudge) or a smoothness drag restored peak brightness mid-cycle with **no gate call at all** — a realized **0.02–0.06 s** rise. The round-1 frame plans were necessary but not sufficient. Every rendered rise above the previous frame's brightness (`flashRiseEpsilon`) now passes the ledger: in Party, in Strobe's `min_brightness` raise while dark, and in the storm's ambient.
- **`OnsetGate` refused only when `t >= last`** and *re-based itself backwards* on an out-of-order stamp. It now refuses any backwards time outright.
- **The ledger period is `minOnsetLedgerPeriod` = 17 × 20 ms = 0.34 s** — the same value the frame plans realize — so the cross-run path (card switch, loop restart) carries the same jitter slack as a run. The remaining 1e-9 is IEEE rounding tolerance only, measured across 4000 grid points.
- **The storm's beat wait re-reads the binding every frame**, so Beat-off exits within one frame; the dead pre-strike `noteAmbient` is gone. (This closes the Low debt the first round recorded.)
- **`Int(Double)` could trap on NaN/inf** before the ranges clamped: `FlashSafety.clampedInt` guards the two storm sites, and `BeatBinding.init` guards `phaseOffsetBeats` (`cycleIndex` did `Int(floor(nan))`).
- `FlashSafetyTests` 31 → **39**, including Party epoch-correction and smoothness-drag models **with an ungated arm that reproduces the shipped defect**, backwards time, exact 17-frame admission at every grid position, and degenerate values.

### Colour / board availability

- **Profile evidence was discarded**, so hardware-pending params rendered as fully live. `StudioBoardResolution` now carries `isHardwareUnverified`; those controls stay editable at staged opacity with **"UNVERIFIED ON THESE LIGHTS"** (`brightness` everywhere; `base_color`/`warmth` on the legacy transport). This is the UI half of the matrix's 23-row figure in §11.
- **CHECKING was a dead end.** `warmEntertainmentCaches` dropped its own light fetch from the guard, the light cache was not observable, and `refreshCoverage` / `roomHueLights` fetched inventories and discarded them — so a board could say CHECKING WHAT THESE LIGHTS SUPPORT forever. The guard now includes `needsLights`, `capabilityInventoryGeneration` is bumped on every inventory seed and read by `targetSnapshot`, both fetches seed the cache, and the note tells the user the board refreshes when the bridge answers. A target with genuinely no lights says so instead of checking forever.
- **`.disabled` was the only gate for raw gestures.** Knobs, faders, chips, toggles, the colour editor and the hue pad now short-circuit their own callbacks when not interactive; a non-interactive editor never renders the pad and refuses expansion.
- **App-driven warmth now requires `colorTemperature`** (it previously resolved `.none` with no CT gate at all). `.hidden` renders nothing; a bridge-native param with no profile fails closed; the reason note keeps its own alpha; the colour section reuses the one snapshot.
- **`LookDetailsPanel` hero sliders** resolve through the same funnel when the card is running on the selected room, and otherwise say they set the next start.
- `StudioBoardAvailabilityTests` 11 → **22**; Guard 15 gains sub-checks (f)–(j).

### Lifecycle / sends / Preview Live

- **The coalesced grouped PUT was invalid.** Merging `base_color` and `warmth` produced one grouped PUT carrying both `color` and `color_temperature`, **which the bridge rejects — taking brightness down with it**. The closure now emits dimming+xy first, then mirek.
- **The `compositionFellBackToREST` emit sat after two awaits**, so a superseded failover could rekey the *current* row. The event now carries the re-entered box's `ObjectIdentifier`, and the handler requires the live box to match.
- **`stillCurrent()` tracked only the REST scope epoch**, which bridge-native stops never bump: an already-enqueued closure could **re-arm the firmware effect after Stop**. Every send now also requires the captured identity to be current, so the in-flight window survives a mailbox drop.
- **The task-local re-entrancy marker leaked** into every engine task spawned by a start; starts now run with it reset.
- **Preview Live** refuses over a composition with live edits and over a recovered row; audition start is detected by **identity**, not card id; a restore or audition that hits a handoff/takeover/area prompt keeps its snapshot and arms on confirmation; Keep It / Put It Back are **per audition card**; a chained audition on another room is refused and names the armed room; cancel over an idle room keeps the lights on; rows removed outside `stopEffect` consume the audition; the restore passes the observed transport; commit is serialized.
- **`applyCore`** seeds a bridge-native start from the card's defaults when the target is not the selected room, and instances start from the full catalog defaults so shared last-used defaults never leak between rooms; `renameCompositionPreset` keeps a row's recovered/ownership fields; the install belt clears session memory.
- Lifecycle 6 → **7**, preview production 7 → **19**, wiring 24 → **31**, including source-shape pins for the stop-handler reachability claim.

### Accepted as documented (reviewed, deliberately not changed)

- **Cross-bridge composite cadence is per-bridge by design.** The onset ledger is per bridge, so two bridges lighting one physical space each keep their own 17-frame cadence, and a viewer in the overlap can see a combined rate above the per-bridge ceiling. A global ledger would couple unrelated rooms; the per-bridge boundary is the deliberate choice.
- **The ledger stamps admission, not emission.** The 0.34 s period is what absorbs the gap: it tolerates under 6.67 ms of jitter between admission and the frame actually going out.
- **`min_brightness` > `brightness` ramps upward within a gated cycle** — pre-existing, and the cycle is still gated, so it cannot shorten an onset interval.
- **Perform-pad `CompositionMixer` strobe at 25 fps** can realize 320 ms intervals — **pre-existing on `main`**, outside this PR's diff (§13).
- **`EffectEngine.swift`'s dead loops** still declare unsafe ranges; no production caller (§13).
- **`showsEntOnlyHint` is still compiled** in the dead `StudioParamControls`. It is unreachable, and Guard 15 pins it out of `StudioBoardView`.
- **`StudioLookBrowser` now resolves hero sliders** through the funnel — raised by the review as a gap, fixed above.
- **Membership staleness is an accepted gap in the no-rekey ownership argument**, recorded in `CustomizationIdentity.swift` rather than papered over (§5).
- **`speed`'s visible firmware response is still hardware-owed** even though its send path is code-proven — one of the 23 rows in §11, and the reason `speed` alone accounts for 11 of them.

---

## 3C. Third review round (`119aa4b`)

A **second fresh adversarial pass**, this one against the round-two fixes themselves, found holes in the fixes. Every BLOCKER and HIGH is closed here, with tests and, where a text guard can pin the shape, Guard 14/15 sub-checks.

### Flash safety — the gate moved to the wire

Round two gated **the transitions the loop computed**, not **the frames it emitted**. Four escapes survived:

| Escape | Realized |
| --- | --- |
| A hold frame streamed while the ledger refused could itself be a rise — `min_brightness` 0 → 50 across a card switch | a **50 % step 0.05 s** after the last onset |
| The storm's afterglow-to-ambient step was ungated | **+10 %** two frames after a strike |
| An inverted Strobe (`brightness <= min_brightness`) stamped the *falling* edge | the rise landed **0.08 s** later |
| A sub-epsilon ramp | accumulated unmeasured |

**One mechanism now replaces every per-branch gate.** The per-bridge `OnsetLedger` tracks **the last frame put on the wire** and **the trough since the last admitted onset**. Every frame the three Entertainment loops send passes through `emitGatedFrame` (`WireFrame` / `FrameVerdict` / `OnsetGate.admit`). A frame that rises **≥ 10 % of full scale** above that trough — **or steps the palette at or above the admitted level** — is an onset candidate and is **held at the last emitted frame** until the 0.34 s period admits it. **Falls and sub-threshold rises pass.** The storm's afterglow is **floored at the ambient level** so the decay is monotone, **no direct `sendUniform` remains in the loops** (Guard 14 pins this), and `BeatClock`'s audio-ingest BPM is clamped to **20–300**.

`FlashSafetyTests` 39 → **54**, each scenario **measured on the emitted frame list, with the pre-fix model still failing**.

### Colour / availability — unknown must never refuse

An UNKNOWN `effects_v2` capability was mapped to the **refusal** reason, so a cold snapshot's Speed knob asserted "THESE LIGHTS CAN'T CHANGE THIS WHILE RUNNING" **beside neighbours saying CHECKING**. Now:

- unknown coverage resolves `capabilityUnknown` **with a retry remediation**, and `.effectsV2Unavailable` is reachable **only from an unsupported answer**;
- in a mixed v2/v1 room `base_color` / `warmth` / `speed` reach only the v2 lights, so the funnel **narrows them to the `effects_v2` partial coverage**;
- the unverified caveat derives from `EffectParameterProfiles.pendingHardwareCheckParamIDs` — **`speed` is now labelled too** — and **coexists with** the coverage count rather than replacing it;
- descriptors claim their own card, so `.hidden` is reachable; the CHECKING copy fits its tag; **NO LIGHTS HERE outranks every state**;
- the look-browser **setup slider uses the same fail-closed funnel form as the board**.

`StudioBoardAvailabilityTests` 22 → **42**.

### Lifecycle / Preview Live — freeze the instance base

Round two's **full-catalog seed was itself a leak**: it made apply-current-look and Put It Back **copy every catalog default into the persisted defaults**, so every bridge-native start shipped a mirek the user never chose — and reset *still* fell through to another instance's later edits. Running sets are **sparse again**, and each instance layers over a **base frozen at start** (re-frozen on reset), closing the leak on both paths without inflating defaults.

- A **deferred audition was stranded on every confirmation early return and every non-prompt refusal**, which **locked Preview Live out on every other room**. One release helper now runs on every exit.
- The composition failover captured its ownership before two awaits and could re-enter over a successor's run; it now **re-checks the playback generation and the box after `stopSession()`**.
- The split grouped PUT follows **commit order** for the exclusive xy/mirek pair.
- Row removals consume a pending audition **at the tail of `stopEffect`, and only when the row actually goes**; the warmth seed follows the room rule; the install belt **keeps the successor's** session memory; `seedRawLightCache` is **fill-only**.

`StudioProductionWiringTests` 31 → **41**, `StudioPreviewLiveProductionTests` 19 → **21**, plus additions to `CustomizationResolverTests` and `CustomizationIdentityTests`.

### Tooling / rules

Guard 12(d) accepts either operand order and **cannot be satisfied from a trailing comment**. Guard 13 anchors its comment filters and counts **both `ScrollView` spellings**. Guard 14 gains **(h)** — the emit helper and ledger shape are pinned, and any numeric hold bail-out is banned **in either spelling**. Guard 15 gains **(h)**, **(c)** and **(k)** — the editor floor is scoped to the `StageColorEditor` call, its filter is anchored, and the funnel's answers (**disabled, opacity, note**) must be applied in **all three** renderers. The matrix generator gains **`verify_send_path`**: every bridge-native "code-proven" citation is verified against the `performBridgeSend` body. `.gitignore` now covers `.cursor/mcp.json`, `.cnvs/` and `Scripts/__pycache__/`.

### Accepted as documented (third round)

- **The first frame of a bridge's ledger life is emitted unconditionally** and stamped only if bright — worst case one delay of ≤ 0.34 s, never a missed gate.
- **A refused onset holds the light at the last emitted frame** rather than blacking it out — safer to look at, and closer to the artistic intent.
- **`.capabilityUnreadable` as a distinct reason is reserved.** Unknown and unreadable render identically today, so the distinction lives in the type, not on screen.
- **`.effectsV2Unavailable` is now reachable only from an unsupported answer**, never from an unknown one — that is the point of the colour fix above.

---

## 3D. Fourth review round (`14a0cac`)

A **third fresh adversarial pass**, against the round-three fixes. Every BLOCKER and HIGH is closed here; each lane validated on its own focused suites and the converged tree compiled, passed the guards and passed the matrix check with refreshed citations.

### Flash safety — wire truth

`emitGatedFrame` recorded and stamped a frame **before** a send that the DTLS client silently drops during a reconnect, so the ledger ran ahead of the wire and the first delivered frame after the restore could be a full-scale unmeasured rise. `send` / `sendUniform` now return whether the frame was handed to the transport; the gate is **reserve → send → commit**: the onset stamp moves to delivery time, a dropped frame rolls the stamp back, and `emitOnsetFrame` waits for delivery and exits on terminal failure. The 10 % threshold is measured in **relative luminance** (an L\*-cube dimming term × an sRGB-primaries chromaticity factor: white 1.0, red 0.21, blue 0.07) above the trough since the last admitted onset, with a saturated-red chroma rule; the brightness-based exemptions are gone. `FlashSafetyTests` 54 → **69** with an independent luminance measurement, a dropped-send wire model and a 2040-scenario reconnect sweep; Guard 14 pins commit-after-send, the `Bool` return and the luminance symbols.

### Colour / availability — effect-specific reach

The mixed-room narrowing keyed on generic `effects_v2` support while sends reach only the lights that list **this** effect in `effect_values`. `targetSnapshot` now measures effect-specific reach and the colour / CT intersections, and the funnel narrows to the intersection; zero reach resolves unavailable with **"NO LIGHT HERE RESPONDS TO THIS"** rather than a live 0-of-n knob. Unverified-but-active controls keep their caption at full opacity; the joined caveat is shortened; Guard 13(c) anchors the horizontal exclusion, Guard 15(k) pins non-shadowed funnel bindings, `verify_send_path` matches subscript keys only. `StudioBoardAvailabilityTests` 42 → **48**.

### Lifecycle / Preview Live — layered copy-back

Copying a sparse live set into persisted defaults **deleted defaults written after the instance started** — both copy-back sites (Apply Current Look, Put It Back) now layer over the current defaults. The `effects_v2` body carries only the later-committed member of the exclusive xy / mirek pair. Confirmation replays run with the audition in flight so a chained audition behind a prompt keeps its snapshot; a deferred restore the confirmation refuses rolls its defaults back; row-removal notices fire only when a row existed; the failover removes only its own client; cancels release symmetrically. `StudioProductionWiringTests` 41 → **46**, `StudioPreviewLiveProductionTests` 21 → **27**.

---

## 3E. Fifth review round (`b06df67`)

The handoff to a fresh orchestrator ran a **fourth adversarial pass** — ten read-only lanes against `119aa4b..14a0cac` plus the uncommitted docs. Every BLOCKER and HIGH is closed here, each with a deterministic test that fails on the reverted fix; the guard gaps the pass found are closed and mutation-tested.

### Flash safety — a dropped send changes nothing on the wire

Round four's reserve/commit gate was right to roll the stamp back on a dropped send, but it also **forgot the wire** (`lastEmitted = nil`, trough 0), and that was two BLOCKERs with one cause — a refused send was never handed to the transport, so the bridge is still showing the last **delivered** frame:

| Escape | Realized |
| --- | --- |
| After the forget, a refused bright frame was held **black at the requested chromaticity**. Against the frame actually on the wire that is a chroma step; with a saturated-red request (Party palette entry 0, a red tint drag) it satisfies the gate's own red rule — an unstamped onset — and the zeroed trough admits the next red frame as a rise | **1 frame** |
| After the forget, the cold path **re-based the trough upward** to the next frame's luminance, so a blue→cyan ramp was under-measured across a single dropped frame | **3 frames** |
| The cold path judged candidacy on **absolute luminance only** and never applied the red rule: an in-catalog Thunderstorm (red ambient, dim white strike) with one dropped frame realized two red-flash onsets | **1 frame** |

The reviewer's independent sweeps found 1,184 / 31,752 ramp × drop-window scenarios and 3,941 / 50,544 in-catalog storm scenarios violating.

**The fix keeps what the gate actually knows.** `commit(delivered: false)` rolls the stamp back and **restores** the pre-drop wire state and trough (under the existing identity guard; an interleaved instance still forgets). A wire that has been **silent for a whole ledger period** is unknown — `admit` forgets it first, which is also the production trigger `forgetWire()` never had (a card-switch teardown left a stale wire model behind). The cold path now applies the **red rule against the last known frame**, a cold refusal holds black at the last **known** chromaticity, and the trough survives a forget as a running minimum (the eye integrates the outage; the "bridge may have reverted" case is answered by the cold path's absolute rule, not by lowering the floor). Restoring the pre-drop state **unconditionally** — the reviewer's proposal — was rejected: it reopens the long-outage case, where the bridge has reverted to its own state and a fall-then-rise two frames after the reconnect would be admitted against the old stamp.

`FlashSafetyTests` 69 → **75**: the wire model now drives either the production gate or a faithful replica of the round-four gate, so every scenario is asserted on both (seeded ramps × drop position 115 / 1380 violating before, 0 after; Party tint drag 11 / 100; blue→cyan single drops 13 / 120; in-catalog storm 36 / 60); the viewer inlines its chroma distance so the measurement shares nothing with production; the churn test carries seeded outages; the drop sweep rotates saturated-red storm palettes and requires ≥ 3 onsets. Guard 14 gains: no exit between the send and the commit, `commit(at: CACurrentMediaTime())` not a hoisted sample, and declaration pins for the restore-on-drop and the silence clock (8 / 8 mutations caught). A full revert to the round-four gate kills **9** tests.

### Lifecycle / Preview Live — the audition's own edits, the deferral's own replay

- **A same-card audition's edits survived Put It Back.** Layering the snapshot over the *current* defaults kept keys the audition instance itself had written into the shared card's defaults, so the restore restarted with a mirek the previous look never had. The restore base now subtracts the audition instance's own sparse keys — only when the audition card is the previous card; keys are per card.
- **The audition-in-flight bracket fired for every confirmation replay**, not only the deferred audition's. A deliberate apply of another card on the audition's room that hit a handoff / takeover / area prompt was **armed as the audition on confirmation** (Put It Back would then undo a deliberate apply); a cross-room confirmation that tore the armed row down left the machine armed on a dead row with nothing said. The deferral is now **named** — card id and exact selection key recorded when an audition waits behind a prompt — and the bracket raises the flag only for that replay.
- **The "did the restore land" test was card-id only**, trivially true for a same-card audition, so a refused restore skipped its rollback and said nothing; it is now the file's identity idiom, on both the immediate and the deferred path. **A second deferred restore for a different card overwrote the first card's pending rollback**; pending rollbacks are now keyed per card and every entry is settled.
- **An older mailbox closure could clear a successor window's in-flight record** (unkeyed clear), reopening the per-target send loss the record exists to prevent; each window carries a token and clears only its own record — proven by a deterministic test that holds the first closure pending behind a gated second scope.

`StudioPreviewLiveProductionTests` 27 → **34**, `StudioProductionWiringTests` 46 → **47**.

### Colour — the badge shows the funnel's reach

The colour editor suppresses the "n OF m LIGHTS RESPOND" note because the editor badges its own count — but that badge read the **un-narrowed** snapshot colour coverage. In a mixed room (3 colour lights, one listing the effect) the editor rendered fully live with **no badge and no caption**; with 3 of 4 colour lights and a reach of 1 the badge **overstated**. A pure `editorCoverage` helper feeds the editor the resolution's partial counts; the board hands a per-control context to `StageColorEditor`. `StudioBoardAvailabilityTests` 48 → **53**, including a source-shape pin.

### Tooling

Guard 14's direct-send count now covers `.send(channels:` as well as `sendUniform(`; Guard 12(b) pins **read → stop → read** order rather than a count; Guard 15(k) fails a `let interactive` / `let opacity` bound to a bare literal; Guard 13(a) bans `.popover(` (one pre-existing Composer swatch popover is carved out by literal string — see §13); the matrix generator's `verify_send_path` now requires a **non-nil assignment to the payload symbol**, not merely a read of the key, and a bare array literal no longer counts as a subscript read. `composer.mdc` now states the verified 66 built-in presets. Every change mutation-tested on a scratch copy.

### Accepted as documented (fifth round)

See §13 for the full list. The pre-existing apply-time `effects_v2` body that carries both colour and mirek was **deliberately not changed**: the claim that the bridge rejects that body is itself hardware-unverified, and dropping a user-set warmth on start for an unproven gain is the wrong trade.

---

## 4. Exact safety changes

**Invariant.** Realized onset-to-onset spacing is **≥ 17 frames (0.34 s)** on the 20 ms Entertainment grid, on every legal path — free-run, beat-locked, parameter churn, lock toggles, tempo taps/nudges/phase edits, and stop/start loop restarts. "Onset" means the first bright frame (Strobe), the first strike frame (Thunderstorm), or a palette step (Party). The ceiling is no longer a property of a requested float.

**Math.** All of it lives in `BeatMath.FlashSafety`, pure and clock-free:

- `minCycleFrames` = `ceil(0.3333 / 0.02)` = **17**.
- `cycleFrames(hz:frameDuration:)` computes the **safe TOTAL first** (`max(17, ceil((1/clamp(hz))/fd))`), finite-guarded so degenerate inputs (0, −1, NaN, ∞) never trap.
- `splitFrames(total:firstFraction:)` splits ON/OFF (or hold/fade) **without ever shortening the total**; each half ≥ 1, sum == total, fraction clamped 0…1.
- `StrobePlan` / `PartyPlan` / `ThunderstormPlan` are the functions the loops call; the ad-hoc `/ 0.02` arithmetic is deleted, and frame sleeps use the one shared quantum rather than a literal.
- `ThunderstormPlan.Budget` carries `framesSinceOnset` across skipped strikes and beat waits, so `gap + framesSinceOnset ≥ 17` holds at every frequency × flash_length × afterglow.

Worked worst cases: Strobe/Party at `speed` 100 → 17 frames (was 15–16). Thunderstorm at `frequency` 100 / flash 1 / afterglow 0 → since = 1, gap = max(9, 16) = 16, spacing 17. Card defaults at `frequency` 100 → since = 3, gap = 14, spacing 17.

**2.94 Hz, and why.** Every Entertainment `liveLock` now passes `maxHz: FlashSafety.entertainmentMaxLockHz` = 1/(17 × 0.02) = **2.94 Hz**. This is a **consequence of the invariant on this grid, not a new product preference.** Keeping 3.0 and letting a gate absorb the quantization was evaluated and rejected: it produces unbounded lag (6.67 ms per cycle) and periodic dropped flashes across the whole 3 Hz band, whereas at P ≥ 340 ms quantization alone can never yield fewer than 17 frames. The musical cost is exactly **three narrow tempo bands** stepping to the next division:

| Band | Width | Old | New |
| --- | ---: | --- | --- |
| (176.47, 180] BPM | 3.53 BPM | ×1 | ×2 |
| (88.24, 90] BPM | 1.76 BPM | ×½ | ×1 |
| (44.12, 45] BPM | 0.88 BPM | ×¼ | ×½ |

These are precisely the bands where the old lock realized 16-frame intervals. Recorded in spec §24, audit §2C, and the DEVLOG.

**Ledger.** One `OnsetLedger` **per bridge** (`studioFlashOnsetLedgersByBridge`, get-or-create, never removed) is passed into each Entertainment loop, so stop/start, card switches and session re-establishment cannot realize two onsets less than 1/3 s apart. Every onset is admitted through `tryOnset` first; on refusal the loop streams one hold frame (dark / previous colour+brightness / ambient) and re-checks — **delay, never skip**. Edge state (`isBright`; `renderedIdx`/`lastColor`/`lastBri`) lives outside the `while` and is shared by both branches, so beat → free-run toggles mid-cycle and tempo/phase transients are covered.

**Round 2 made the gate cover rises, not just cycle boundaries.** See §3B: `2200e98` gates every rendered luminance rise (`flashRiseEpsilon`), refuses backwards time in `OnsetGate`, sets the ledger period to `minOnsetLedgerPeriod` = 0.34 s so the cross-run path carries the same jitter slack as a run, makes the storm's beat wait re-read the binding every frame, and stops `Int(Double)` trapping on NaN/inf. Without those, the round-1 plans were still breakable by a backwards phase correction or a smoothness drag.

**Round 3 moved the gate to the wire — this is the shipping mechanism.** See §3C: `119aa4b` replaced every per-branch gate with `emitGatedFrame`, through which **every frame the Entertainment loops send** must pass. The ledger tracks the last wire frame and the trough since the last admitted onset; a rise of **≥ 10 % of full scale** above that trough (or a palette step at or above the admitted level) is held at the last emitted frame until the 0.34 s period admits it. Read §4's plans as *how the loops shape a cycle* and §3C as *what is actually allowed onto the wire*: the plans no longer carry the safety argument alone.

**Round 4 moved the stamp to the delivery and the threshold to luminance.** See §3D: `14a0cac` makes every emit reserve → send → commit, so a frame the DTLS client drops during a reconnect never stamps the ledger; the 10 % rule is measured in relative luminance above the trough since the last admitted onset, with a saturated-red chroma rule.

**Round 5 made the gate keep what it knows.** See §3E: a dropped send restores the pre-drop wire state instead of forgetting it (the bridge still shows the last delivered frame); a wire silent for a whole period is unknown and goes cold; the cold path applies the red rule against the last known frame and holds black at the last known chromaticity. Both directions are proven on the emitted frame list against a replica of the round-four gate.

**REST is unchanged.** The REST loops were already cadence-safe (≥ 0.7 s) and were not modified; they carry the proof comment.

**Proof (round 1; 75 tests at `b06df67`).** `FlashSafetyTests` — 31 pure tests at `910c861`, seeded LCG RNG, **no sleeps and no timing waits**. They sweep every catalog range and widened ranges, simulate realized frame plans under parameter churn, prove the storm budget at every frequency × flash_length × afterglow with worst-case draws, **document the old 10-frame storm and the 16-frame beat grid as regression pins**, and prove the gate/ledger across jitter, lock toggles and loop restarts. Guard 14 pins the shape structurally.

---

## 5. Production rekey status

**Wired (a production path bumps the generation with this reason today):**

- `.cardReplaced` — `installRunningIdentity`, every `apply()` arm.
- `.stopped` — `stopEffect` and `stopAll` (and `.roomRemoved` reaches this through row teardown).
- `.reset` — `resetParams`.
- `.transportChanged` — the composition Entertainment→REST failover, via `StudioRuntimeEvent.compositionFellBackToREST` → `rekeyRunningInstance(at:reason:)`.

The orchestrator emits a **synchronous** `StudioRuntimeEvent` in the same actor turn as its own fence: `entertainmentSessionLost` from `reconcileStudioSessionAfterLoop` *before* `await entClient.stopSession()`, and `compositionFellBackToREST` from `failCompositionEntertainmentToREST` only once the exact `CompositionPlaybackKey` claim is `.rest`. It is deliberately **not** routed through the lifecycle chain — a delayed async handler could act on a successor's row. The view model's handler fails closed on the exact row **and** strategy: session lost ends the row and retires its scopes (there is nothing left to rekey); fallback flips `isEntertainment` / `transportFallback` and rekeys with `.transportChanged`, so writes authored against the streaming transport drop.

**Not wired by design — SSE reconnect and capability refresh do NOT rekey. This is an ownership argument about code, and no test proves it.** The argument is recorded in source, in the `bump()` doc comment of `HueHome/Core/CustomizationIdentity.swift` (~lines 200–240) and again at the orchestrator seam: an SSE reconnect changes **no component** of a `RunningLookIdentity` — bridge id, group id, kind, card, execution and generation are all app-side facts, and a re-registered client keeps the same ip and token. The mutation authority for an app-driven look is the bridge+room engine box, which SSE never touches. Availability is re-resolved at render from the light cache, so a reconnect that genuinely changes capability is already visible without a fence bump. Per-light SSE patches arrive constantly; bumping on them would drop every drag the user is mid-gesture on. And a bridge genuinely going away is a *different* event — `removeBridge` stops the rows first via `stopEffectsForRemovedGroups`, which bumps `.stopped`. Capability refresh is the same argument: it re-reads lights, the resolver re-resolves from that cache at render, no identity component moves, and no in-flight write becomes wrong. **Membership staleness is recorded in that same comment as an accepted gap in the argument** (`2200e98`) rather than papered over, and hardware §V-B rows **59** and **63** remain **UNPROVEN** — they are what would actually settle it. Do not read this section as "proven". `.selectionChanged` is excluded by design — the selection is not part of the identity, which is the entire point of capturing identity at gesture start; a selection move must not invalidate the *other* target's pending writes. The counter's doc comment now lists **only** the reasons production actually bumps, because an aspirational "every event bumps" sentence is exactly how a missing seam hides in plain sight.

---

## 6. Colour gating

`StudioBoardAvailability` (`HueHome/Core/StudioBoardAvailability.swift`) is the **single pure funnel**, and both `boardControl` and `colorSection` resolve against the same cached snapshot and apply the same interactivity, opacity and note:

- **bridge-native params** keep the `EffectParameterProfiles` path, unchanged;
- **app-driven colour pickers** require `.all([.color] + (.transport(.entertainment) when entOnly))` — hardware "no" outranks the transport note via `combineAll`;
- **numeric `entOnly` params** require the Entertainment transport;
- **other numerics** require `.none`.

**Staged semantics (spec §17).** `.active` / `.partial` / `.staged` are **editable** — staged means "editable and saved, not affecting current output", so it renders at reduced opacity with the note **"STREAMING ONLY — INACTIVE IN ROOM MODE"**. `.unavailable` / `.hidden` are disabled with the local reason (NO COLOR LIGHTS HERE / CHECKING WHAT THESE LIGHTS SUPPORT). This also aligns the numeric controls, which previously disabled staged in contradiction of the spec; bridge-native profiles never yield `.staged` on a running board, so shipping behaviour there is unchanged. The separate `showsEntOnlyHint` line is gone — one note per control — and `colorCapabilityContext` now derives coverage from the snapshot with evidence preserved instead of hard-coding `.known`.

The four cases that were wrong, and are now right:

| Case | Before | After |
| --- | --- | --- |
| Colourless room + `base_color` | live colour editor | `.unavailable(.noColorCapableLights)`, disabled, NO COLOR LIGHTS HERE |
| `strobe.flash_color` on Room REST | fully live, no note | `.staged(.requiresEntertainment)`, editable at reduced opacity, STREAMING ONLY — INACTIVE IN ROOM MODE |
| Partial coverage (1 of 3 colour lights) | indistinguishable from full | `.partial`, interactive, the editor badges "n OF m LIGHTS" |
| Unreadable capability snapshot | indistinguishable from full | `.unavailable(.capabilityUnknown)`, disabled, CHECKING WHAT THESE LIGHTS SUPPORT |

**Round-4 / round-5 corrections (`14a0cac`, `b06df67`) — see §3D / §3E.** Reach is effect-specific (lights whose `effect_values` list this effect), narrowed to the colour / CT intersection, with zero reach saying NO LIGHT HERE RESPONDS TO THIS; and the colour editor's badge now shows that narrowed count rather than the un-narrowed snapshot figure. `StudioBoardAvailabilityTests` 42 → 48 → **53**.

**Round-3 corrections (`119aa4b`) — see §3C.** An UNKNOWN `effects_v2` capability was mapped to the **refusal** reason, so a cold snapshot's Speed knob asserted "THESE LIGHTS CAN'T CHANGE THIS WHILE RUNNING" beside neighbours saying CHECKING; unknown now resolves `capabilityUnknown` with retry, and `.effectsV2Unavailable` is reachable **only from an unsupported answer**. In a mixed v2/v1 room `base_color` / `warmth` / `speed` narrow to the `effects_v2` partial coverage. The unverified caveat derives from `pendingHardwareCheckParamIDs` (**`speed` is labelled too**) and coexists with the coverage count. `.hidden` is reachable, **NO LIGHTS HERE outranks every state**, and the look-browser setup slider uses the same fail-closed funnel form. `StudioBoardAvailabilityTests` 22 → **42**.

**Round-2 corrections (`2200e98`).** Profile evidence was being discarded, so hardware-pending params still rendered as fully live: `StudioBoardResolution` now carries `isHardwareUnverified`, and those controls stay editable at staged opacity with **"UNVERIFIED ON THESE LIGHTS"** (`brightness` everywhere; `base_color`/`warmth` on the legacy transport). CHECKING was a dead end — `warmEntertainmentCaches` dropped its own light fetch from the guard, the light cache was not observable, and `refreshCoverage` / `roomHueLights` fetched inventories and discarded them; the guard now includes `needsLights`, `capabilityInventoryGeneration` is bumped on every inventory seed and read by `targetSnapshot`, both fetches seed the cache, and a target with genuinely no lights says so instead of checking forever. `.disabled` was the only gate for raw gestures, so knobs, faders, chips, toggles, the colour editor and the hue pad now short-circuit their own callbacks when not interactive. App-driven warmth now requires `colorTemperature`; `.hidden` renders nothing; a bridge-native param with no profile fails closed. `StudioBoardAvailabilityTests` 11 → **22**; Guard 15 gains sub-checks (f)–(j).

Regression guard: `seedRawLightCache` is now seeded from apply, so the board never renders CHECKING merely because no inventory has been read yet. `StudioBoardAvailabilityTests` (11 at `f2f7a19`; 53 at `b06df67`) cover all of the above plus non-`entOnly` and `entOnly` numerics, hardware-outranks-transport, and that **no Live-card control escapes the resolver**; the `entOnly` inventory test now asserts the `.transport(.entertainment)` migration is complete. Guard 15 pins both renderers to the funnel, function-scoped so a file-wide grep cannot pass vacuously.

---

## 7. Preview Live production proof

`previewing` is set **only after** the audition is confirmed, cleared on refusal, and consumed by an explicit stop or Stop All. A second audition chains onto the **original** snapshot rather than snapshotting the audition. The restore captures the card's defaults first and rolls them back if the previous look did not reinstall. A fenced cancel now **says so** — `PreviewLiveCopy.restoreDropped` — instead of being a silent no-op.

`StudioPreviewLiveProductionTests` (7 at `7d8d14e`; 34 at `b06df67`) drive the real `apply()` path against the recording bridge client with no timing waits: cancel restores the exact live values on the exact target; a refusal rolls preview state back; a target stopped mid-audition drops, notices, and writes nothing; Stop All clears; commit keeps the audition with the current identity; a second audition keeps the original snapshot. The pre-existing `PreviewLiveTests` (9) remain, exercising the machine's ordering only.

**Round-4 / round-5 corrections (`14a0cac`, `b06df67`).** Put It Back layers the snapshot over the current defaults instead of replacing them, and for a same-card audition subtracts the audition instance's own keys first, so the restore is exact on the wire; a chained audition behind a prompt keeps its snapshot because the deferral is now named and only its own replay runs with the audition in flight; a refused deferred restore rolls its defaults back (identity-tested, per card) and says so. `StudioPreviewLiveProductionTests` 21 → 27 → **34**.

**Round-3 correction (`119aa4b`).** A **deferred audition was stranded on every confirmation early return and every non-prompt refusal**, which **locked Preview Live out on every other room**; one release helper now runs on every exit. Row removals consume a pending audition at the tail of `stopEffect`, and **only when the row actually goes**. `StudioPreviewLiveProductionTests` 19 → **21**.

**Round-2 hardening (`2200e98`).** Preview Live now **refuses outright over a composition with live edits and over a recovered row** — there is no exact previous state to snapshot, so an audition would be a restore promise the machine could not keep. Audition start is detected by **identity**, not card id. A restore or audition that hits a handoff/takeover/area prompt keeps its snapshot and arms on confirmation. Keep It / Put It Back are **per audition card**. A chained audition on a different room is refused and names the armed room. Cancel over an idle room keeps the lights on. Rows removed outside `stopEffect` consume the audition. The restore passes the observed transport, and commit is serialized. `StudioPreviewLiveProductionTests` 7 → **19**.

**Recorded spec §16.5 deviation.** §16.5 says "canceling restores the previous running look exactly". A **fenced** cancel restores **nothing**: if the audition's target changed, was stopped, or was replaced between begin and cancel, `cancelVerdict` returns `.drop` and the machine touches nothing — the world it would restore into has moved on, and a cross-target restore would be worse than no restore. The user is now told rather than left guessing. Separately, navigating away from the browser does **not** cancel: the audition keeps playing on its target and is cancelled or committed explicitly. Both are recorded in the execution plan's Slice 2 status table.

---

## 8. Lifecycle serialization and send coalescing

**One FIFO chain.** Studio lifecycle mutations — `apply`, stops, reset, preview begin/cancel, handoff / takeover / area confirmations, and Now Playing stops — run through one global serialized chain on the view model. It is global rather than per-bridge because there is one preview machine, the dictionary lookups are fail-closed and whole-map, and these are user-paced operations; the worst-case wait for a queued tap is the ~0.4–1 s settle sleeps behind an in-flight apply. Nested calls are detected with a task-local and run **inline** (recorded in DEBUG) so the chain can never wait on itself. A structural pin proves the orchestrator never reaches `studioStopHandler` from a start or stop path, so no chain cycle exists.

**Belt as well as braces.** `installRunningIdentity` retires every value scope and pending send at the same bridge + group + kind — whatever the card, whatever the execution — before registering the new instance, so a superseded apply can no longer leave an orphan `isCurrent` scope behind.

**Coalesced sends.** The per-target debounce slot used to cancel the previous parameter's bridge write when a second parameter committed within 150 ms; per-parameter keys would only have moved that loss down into `RestSender`'s latest-wins mailbox per `RestScope`. Commits now accumulate into **one pending set per target** and fire as **one** mailbox closure: one grouped PUT (brightness + xy + mirek together) and one `effects_v2` body per light carrying **every** changed field, with `stillCurrent()` re-checked before each send. `retirePendingSends(for:)` replaces the old two-line cancel idiom at every teardown site.

Two structural pins in `MultiBridgeRoutingTests` were retargeted to the coalesced closure and to `applyCore`.

**Round-4 / round-5 corrections (`14a0cac`, `b06df67`).** Apply Current Look layers instead of replacing (a sparse live set had been deleting defaults written after the instance started); the `effects_v2` body carries only the later-committed member of the exclusive xy / mirek pair; and each pending window carries a token so an older mailbox closure can no longer clear a successor window's in-flight record. `StudioProductionWiringTests` 41 → 46 → **47**.

**Round-3 corrections (`119aa4b`).** Round two's fix for cross-room default leakage — seeding instances from the **full catalog** — was itself a leak: it made apply-current-look and Put It Back **copy every catalog default into the persisted defaults**, so every bridge-native start shipped a mirek the user never chose, and reset *still* fell through to another instance's later edits. Running sets are **sparse again**, and each instance layers over a **base frozen at start** (re-frozen on reset), closing the leak on both paths without inflating defaults. The composition failover captured its ownership before two awaits and could re-enter over a successor's run; it now **re-checks the playback generation and the box after `stopSession()`**. The split grouped PUT follows **commit order** for the exclusive xy/mirek pair. The warmth seed follows the room rule, the install belt **keeps the successor's** session memory, and `seedRawLightCache` is **fill-only**. `StudioProductionWiringTests` 31 → **41**.

**Round-2 corrections (`2200e98`).** Coalescing had merged `base_color` and `warmth` into one grouped PUT carrying both `color` and `color_temperature`, **which the bridge rejects — taking brightness down with it**; the closure now emits dimming+xy first, then mirek. `stillCurrent()` tracked only the REST scope epoch, which bridge-native stops never bump, so an already-enqueued closure could **re-arm the firmware effect after Stop** — every send now also requires the captured identity to be current. The `compositionFellBackToREST` emit sat after two awaits, so a superseded failover could rekey the current row; the event now carries the re-entered box's `ObjectIdentifier` and the handler requires the live box to match. The task-local re-entrancy marker leaked into every engine task spawned by a start; starts now run with it reset. `applyCore` seeds a bridge-native start from the card's defaults when the target is not the selected room, and instances start from the full catalog defaults so shared last-used defaults never leak between rooms. `StudioLifecycleSerializationTests` 6 → **7**, `StudioProductionWiringTests` 24 → **31**.

---

## 9. Test totals

**Focused runs, all green:**

| Focused set | Result |
| --- | --- |
| `FlashSafetyTests` + `BeatMathTests` + `InstrumentControlMathTests` + `StudioParamCatalogTests` | **85/85** |
| `StudioBoardAvailabilityTests` + resolver + catalog facts | **68/68** |
| Production wiring + lifecycle + preview production + routing + preview machine | **485/485** |

The round-1 focused figures above are superseded by the focused runs on `119aa4b` (**flash 132/132**, **colour 107/107**, **lifecycle 523/523**), on `14a0cac` (flash **139/139**, colour **110/110**, lifecycle **459/459** — the lifecycle set no longer includes the identity suite, which moved to the colour set), and on the final tree: `**146/146** / **115/115** / **467/467**`.

**Full registered suite:**

| Run | Tree | Result |
| --- | --- | --- |
| Runs 1–2 | `7d8d14e` (pre-review-fix baseline) | **1844/1844**, 0 failed, 0 skipped — twice consecutively |
| Runs 3–4 | `2200e98` (round-one-fixed baseline) | **1883/1883**, 0 failed, 0 skipped — twice consecutively |
| Runs 5–6 | `119aa4b` | **1935/1935**, 0 failed, 0 skipped — twice consecutively |
| Run 7 | `14a0cac` | **1967/1967**, 0 failed, 0 skipped (run 8 on that tree was superseded by the fifth-round fixes and is not counted) |
| Run 8 | `b06df67` | **1987/1987**, 0 failed, 0 skipped (`~/Desktop/pr64-xcresults/full8.xcresult`) |
| Run 9 | `b06df67` | **1987/1987**, 0 failed, 0 skipped (`~/Desktop/pr64-xcresults/full9.xcresult`) |

(Slice 2's delivery baseline was 1782/1782 twice consecutively, itself up from 1723.)

**Suites added or extended, counted with `grep -c "func test"` on each tree:**

| Suite | Round 1 (`7d8d14e`) | Round 2 (`2200e98`) | Round 3 (`119aa4b`) | Round 4 (`14a0cac`) | Round 5 (`b06df67`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `HueHomeTests/FlashSafetyTests.swift` | 31 (new) | 39 | 54 | 69 | **75** |
| `HueHomeTests/StudioBoardAvailabilityTests.swift` | 11 (new) | 22 | 42 | 48 | **53** |
| `HueHomeTests/StudioProductionWiringTests.swift` | 24 (17 at Slice 2 + 7) | 31 | 41 | 46 | **47** |
| `HueHomeTests/StudioPreviewLiveProductionTests.swift` | 7 (new) | 19 | 21 | 27 | **34** |
| `HueHomeTests/StudioLifecycleSerializationTests.swift` | 6 (new) | 7 | 7 | 7 | **7** |
| `HueHomeTests/CustomizationResolverTests.swift` (file) | 29 | 29 | 31 | 31 | **31** |
| `HueHomeTests/CustomizationIdentityTests.swift` (Slice 1) | 28 | 28 | 31 | 31 | **31** |
| **Total across the five Slice-2 suites** | **79** | **118** — a +39 delta reconciling exactly to 1844 → 1883 | **165** | **197** | **216** |
| `HueHomeTests/BeatMathTests.swift` | 34 | 34 | 34 | 34 | **35** |
| `HueHomeTests/EffectParameterProfilesTests.swift` | 10 | 10 | 10 | 10 | 10 |
| `HueHomeTests/InstrumentControlMathTests.swift` | 14 | 14 | 14 | 14 | 14 |
| `HueHomeTests/PreviewLiveTests.swift` | 9 | 9 | 9 | 9 | 9 |
| `HueHomeTests/StudioLookLibraryTests.swift` | 6 | 6 | 6 | 6 | 6 |

**Counting notes.** `CustomizationResolverTests.swift` holds **two** classes — `CustomizationResolverTests` (**26**) and `CustomizationCatalogFactsTests` (**5**) — so the file greps 31 where the class the review named is 26. `CustomizationIdentityTests` is a single class of 31. `2200e98`'s commit message quotes `lifecycle 6 -> 9` and `preview production 7 -> 17`; the actual greps were **7** and **19**, and only the greps reconcile to the +39 delta. The greps are authoritative for the per-file counts; the xcresult bundles are authoritative for what ran (`BeatMathTests` greps 34 but registers 21 test cases — nested helpers named `test…` inflate the grep — and `StudioParamCatalogTests` greps 20 / registers 19).

Every new production test drives the real `apply()` path against the recording bridge client. **No sleeps and no timing waits anywhere in the new race tests** — the new suites are on the guard's no-timing-wait list, which is enforced.

---

## 10. xcresult evidence

All verdicts read with `xcrun xcresulttool get test-results summary --path <bundle>`; bundles preserved under `~/Desktop/pr64-xcresults/` on Brian's Mac (not in the repo):

| Bundle | Tree | passed / failed / skipped | Scope |
| --- | --- | --- | --- |
| `full5.xcresult`, `full6.xcresult` | `119aa4b` | 1935 / 0 / 0, twice | full registered suite |
| `full7.xcresult` | `14a0cac` | 1967 / 0 / 0 | full registered suite (its second run was superseded by the fifth-round fixes and discarded) |
| `full8.xcresult` | `b06df67` | **1987 / 0 / 0** | full registered suite, run 8 |
| `full9.xcresult` | `b06df67` | **1987 / 0 / 0** | full registered suite, run 9 — identical final tree |
| `focused-flash.xcresult` | `b06df67` | 146 / 0 / 0 | FlashSafety, BeatMath, InstrumentControlMath, StudioParamCatalog, StudioEffectsV2, EffectParameterProfiles |
| `focused-colour.xcresult` | `b06df67` | 115 / 0 / 0 | StudioBoardAvailability, CustomizationResolver, CustomizationCatalogFacts, CustomizationIdentity |
| `focused-lifecycle.xcresult` | `b06df67` | 467 / 0 / 0 | StudioProductionWiring, StudioLifecycleSerialization, StudioPreviewLiveProduction, PreviewLive, MultiBridgeRouting, StudioLookLibrary |

Simulators: three "iPhone 17 Pro" and one "iPhone 17 Pro Max" by exact `id=`, each lane with its own DerivedData; every full run on one simulator, sequentially, with no code change between runs 8 and 9.

(Verdicts read with `xcrun xcresulttool get test-results summary --path <bundle>`; the destination is resolved by `run_tests.sh`'s discovery — preferred model at the highest installed iOS, exact `id=`, because several simulators share the name `iPhone 17 Pro`.)

---

## 11. Guard evidence

`./Scripts/hardening_guards.sh` — `hardening_guards: all guards passed.` `python3 Scripts/generate_capability_matrix.py --check` — `capability matrix: 4 citation(s) verified, doc up to date`. Both on the final tree `b06df67`, after every fifth-round edit; `git diff --check` clean; the app compiles for the `HueHome 1` scheme (exit 0).

**Guard 14 (`slice2-r1`) — the flash ceiling is a realized-frame invariant.** Structural, function-scoped over each Entertainment loop: the `FlashSafety` API exists; the plans compute a safe total then split it; each loop takes the shared per-bridge ledger, admits onsets through it, sleeps the shared quantum, does **no** `0.02` arithmetic, **never** reads the raw `binding.beatsPerCycle`, and caps **every** `liveLock` at `entertainmentMaxLockHz`; the ledger map is never removed; and the proof suite is registered in the test target.

**Guard 15 (`slice2-r2`) — one board availability funnel.** `boardControl` and `colorSection` both resolve through `StudioBoardAvailability.resolve(` and take interactivity from `StudioBoardAvailability.isInteractive(` — scoped to those two function bodies, because a file-wide grep would pass vacuously as soon as one of the two kept calling it. The per-view `showsEntOnlyHint` / `param.entOnly` verdicts stay gone (comment lines stripped so history may still name them), colour coverage comes from the same board snapshot, and the suite is registered.

Every new sub-check was **mutation-tested against a scratch copy** and fails when its condition is broken; comment-only mentions do not trip it.

**Round-4 / round-5 hardening (`14a0cac`, `b06df67`).** Guard 14 pins commit-after-send, the `Bool` return, the luminance symbols, no exit between the send and the commit, `commit(at: CACurrentMediaTime())`, and the restore-on-drop / silence-clock declarations; its direct-send count covers `.send(channels:`. Guard 12(b) pins read → stop → read **order**. Guard 13(a) bans `.popover(` and 13(c) anchors the horizontal exclusion. Guard 15(k) pins non-shadowed funnel bindings and fails a bare-literal `let interactive` / `let opacity`. The generator's `verify_send_path` requires a non-nil assignment to the payload symbol, matches subscript keys only, and ignores bare array literals. Every sub-check mutation-tested on a scratch copy (round five: 8 / 8 Guard 14 mutations caught, recorded in `b06df67`'s message; the tooling fixer reported its own mutations caught, which is its report rather than an artifact in the tree).

**Round-3 hardening (`119aa4b`).** Guard 12(d) accepts either operand order and **cannot be satisfied from a trailing comment**. Guard 13 anchors its comment filters and counts **both `ScrollView` spellings**. Guard 14 gains **(h)**: the emit helper and the ledger shape are pinned, and any numeric hold bail-out is banned **in either spelling** — so a future loop cannot reintroduce a per-branch gate or call `sendUniform` directly. Guard 15 gains **(h)**, **(c)** and **(k)**: the editor floor is scoped to the `StageColorEditor` call, its filter is anchored, and the funnel's answers (**disabled, opacity, note**) must be applied in **all three** renderers, not merely resolved. The matrix generator gains **`verify_send_path`**, which checks every bridge-native "code-proven" citation against the `performBridgeSend` body — a citation that no longer reaches a send now fails `--check`.

**Round-2 hardening (`2200e98`).** Guard 14's symbol checks are now **declaration-shaped**, so a comment naming a symbol can no longer satisfy them, and it additionally pins a `liveLock` count of ≥ 1 per loop, the helper body shape (no numeric bail-out, the ledger period), the per-bridge ledger at every call site, `Budget` declared before the loop, and the rise-gated conditions. Guard 15 gains sub-checks (f)–(j). Guard 12(d) pins the **conjunction** — an `||` no longer passes. Guard 13(a) and the global-slot check use anchored comment filters. And a suite **missing** from the no-timing-wait list now **fails** instead of being silently skipped.

**Re-hardened anchors.** Two Guard 12 anchors the Slice 2 PR had loosened are restored: the `updateStudioParams` signature literal is scoped to its body (not matched file-wide), and the room-change rule must **return** `.decks` on the non-customization branch rather than merely mention `current == .customization`. Guard 13(a) (no `.sheet(` / `.fullScreenCover(`) is extended to the six new instrument files; 13(b) is deliberately **not**, because `StageColorEditor` owns a caller-bound `isExpanded` by design.

**Matrix citations.** The generator had trusted a hand-written `CITED_CONSUMERS` table; all seven committed line numbers were wrong, and `--check` could never notice because it only diffed the rendered string. Every `file:line` citation is now **verified on every run** — the cited line must contain `paramBox.colors["<param>"]` for that exact param, inside the run loop owned by that exact card — with `--refresh-citations` to re-find them after the loops move. Hardware-pending rows are no longer counted as proven. The totals are now **four separate figures, never one score**:

| Figure | Controls |
| --- | ---: |
| Code-proven send path | 57 / 68 |
| No code-proven send path (hardware-pending evidence) | 11 / 68 |
| Pending / unknown | 0 / 68 |
| Code-proven rows still owing a hardware **behaviour** check | 23 / 68 — `base_color` ×9, `speed` ×11, `warmth` ×3 |

The 23-row figure is a **subset of the 57, not a fourth bucket**. After `2200e98`, `--check` additionally strips comments before matching, fails on any uncited or drifting loop read, cross-checks each row's evidence class and the pending-hardware list against `EffectParameterProfiles.swift`, and scopes each loop span to the next declaration. The audit-§7 sentence that physical evidence is still owed is restored. **68 is the catalog size, not a proof count. Nothing here is "68/68 proven."**

---

## 12. Hardware: UNPROVEN

**Nothing was run on a device or a physical bridge, and nothing is claimed.** Master checklist §V-B rows **37–65** are all **UNPROVEN**:

- **37–39** are the capability-matrix hardware-pending rows; until they run, `brightness` and the legacy colour/warmth fallbacks stay classified as approximations, never full live mutation.
- **44** is the spec-§5.2 adaptive-fine-control feel gate — the gesture must not ship if it feels unpredictable on device.
- **58** is the Warmth authoring-range debt (below).
- **59–64** are the reconnect, background/foreground, Preview-Live-across-reconnect, room-deletion, Entertainment-session-loss and composition ENT→REST-failover cases that audit §27 requires and the checklist did not previously list. **Row 59 is now split by transport:** a bridge reboot on a **Room-mode (REST)** look must resume the same running instance (row 59), while a bridge reboot on an **Entertainment** look loses the session and must **end the row** — that is row 63's behaviour, recorded as row **59b**. Expecting an Entertainment instance to resume would be the wrong test.
- Rows **59 / 59b / 63** carry the entire burden of proof for §5's no-rekey ownership argument, because no test proves it.
- **65** (new in round five) is the wire assumption behind the gate's restore-on-drop: a short DTLS drop keeps the last delivered frame showing, a longer silence may not. No test can prove what the bridge shows.

"Code-proven" in the matrix means the write provably leaves the app — **not** that anyone has watched a light obey it. §V-A's Track A debt is untouched and still UNPROVEN.

---

## 13. Accepted debt

Recorded, not fixed here. None of it is a BLOCKER or HIGH.

| Severity | Item | Owner / slice | Checklist row |
| --- | --- | --- | --- |
| Medium | **Perform-pad strobe punch** (`HueHome/Core/Composer/CompositionMixer.swift:200-216`) renders at a 25 fps (40 ms) cadence and can therefore realize 320 ms intervals — same defect shape as R1. **Pre-existing on `main`, outside this PR's diff.** Still open. | later slice, same fix shape (the wire-level emit gate + shared onset ledger) | — |
| Medium | **Warmth authoring range is not snapshot-driven.** Availability *is* snapshot-honest (the `mirek_schema` intersection; a schemaless CT light resolves unknown, never a fake clamp), and `2200e98` closed the app-driven half by making warmth require `colorTemperature` instead of resolving `.none`. The **authoring range** is still the catalog's `153...500` for all four Warmth params, and the board's slider control derives its range from `param.kind` in its own `range` computed property, not the snapshot's `MirekRange`. Do not describe Warmth as "range-honest through the snapshot". | Slice 3 | §V-B 58 |
| Medium | **`EffectEngine.swift`'s dead loops** still declare unsafe ranges (strobe 30–480 BPM ≈ 8 Hz; thunderstorm 100 ms intra-burst). **No production caller — dead code.** | delete in Slice 3 | — |
| Low | **Cross-bridge composite cadence is per-bridge by design.** Two bridges lighting one physical space each keep their own 17-frame cadence, so a viewer in the overlap can see a combined rate above the per-bridge ceiling. A global ledger would couple unrelated rooms. Reviewed and accepted, not a defect. | — | — |
| Low | **The ledger stamps admission, not emission** — the 0.34 s period absorbs the gap, tolerating under 6.67 ms of jitter between admission and the frame going out. **Narrowed in `119aa4b`:** the ledger now tracks the last frame actually *put on the wire* and the trough since the last admitted onset, so what is measured is the emitted frame list. Reviewed and accepted. | — | — |
| Low | **`min_brightness` > `brightness` ramps upward within a gated cycle.** Pre-existing; and since `119aa4b` every emitted frame passes the wire gate, so the ramp cannot realize an unadmitted rise. | — | — |
| Low | **The first frame of a bridge's ledger life is emitted unconditionally**, stamped only if bright — worst case one delay of ≤ 0.34 s, never a missed gate. Reviewed and accepted (`119aa4b`). | — | — |
| Low | **A refused onset holds the light at the last emitted frame** rather than blacking it out — safer to look at, and closer to the artistic intent. Reviewed and accepted (`119aa4b`). | — | — |
| Low | **`.capabilityUnreadable` as a distinct reason is reserved.** Unknown and unreadable render identically today, so the distinction lives in the type, not on screen (`119aa4b`). | Slice 3 | — |
| Low | **`.effectsV2Unavailable` is reachable only from an unsupported answer**, never from an unknown one (`119aa4b`) — recorded so a future edit does not re-widen it. | — | — |
| Low | **`showsEntOnlyHint` is still compiled** in the dead `StudioParamControls`. Unreachable, and Guard 15 pins it out of `StudioBoardView`. | Slice 3 | — |
| Low | **`speed`'s visible firmware response is still hardware-owed** even though its send path is code-proven — one of the 23 rows in §11, and the reason `speed` alone accounts for 11 of them. Since `119aa4b` the UI **says so**: the unverified caveat derives from `pendingHardwareCheckParamIDs` and `speed` is labelled. What remains owed is the physical check, not the disclosure. | hardware | §V-B 37–39 |
| Low | **Membership staleness is an accepted gap in the no-rekey ownership argument**, recorded in `CustomizationIdentity.swift` rather than papered over. | Slice 3 | §V-B 59 / 59b / 63 |
| Low | `EFFECT_PROFILES` / `profile(effect:paramID:)` are keyed by paramID only, mirroring the Swift table, so per-effect differences in a bridge-native parameter cannot be expressed. | Slice 3 | — |
| Low | `StudioEffectsV2Tests.swift:232-238` polls up to 2 s for the debounced write instead of pinning it deterministically (which is why that suite is not on the no-timing-wait list). | Slice 3 | — |
| Low | `targetSnapshot` hardcodes `entertainmentAvailable: .unknown` (`StudioViewModel+CustomizationWiring.swift:847` at `b06df67`). | Slice 3 | — |
| Low | Deck `effectCoverage` is still card-keyed (selection-guarded; the resolver-grade target-keyed context ships beside it). | Slice 3 | — |
| Low | The `""` vs `"legacy"` bridge-key sentinel split between the engine map and the REST scopes remains. | Slice 3 | — |
| Low | `StudioParamFormat.flashHz` labels speed 97–100 as 2.9–3.0 Hz while the realized ceiling is 2.94 Hz. Cosmetic. | Slice 3 | — |
| Medium | **Pre-existing on `main`: the apply-time `effects_v2` body** (`StudioViewModel.applyStudioEffectV2Parameters`) still carries a seeded colour **and** a seeded mirek together on start. The live-edit path now sends only the later-committed member (`14a0cac`); the start path was deliberately left alone because the claim that the bridge rejects the combined body is itself hardware-unverified, and dropping a user-set warmth on start for an unproven gain is the wrong trade. Settle with hardware, then align. | hardware → Slice 3 | §V-B 38 |
| Medium | **Pre-existing on `main`: two sibling `studioEntClients.removeValue` sites** (`stopCompositionMode`, `stopAppDrivenStudioEffect`) remove by key presence, not identity — the exact shape the failover's `=== entClient` guard (`14a0cac`) fixed on its own path. A successor started during the `stopSession()` suspension loses its record. Same two-line fix; not in this PR's diff. | Slice 3 | — |
| Medium | **`speed` can be a live knob that sends nothing** when the apply-time `v2CapableLightIDs` set is empty (the apply's light fetch failed) but the live cache later says the room is v2-capable: the board narrows from the cache, the send gates on the frozen apply-time set. A facet of the accepted apply-time staleness gap. Fix shape: treat `speed` as zero reach when the row's transport is `.legacy`. | Slice 3 | §V-B 37–39 |
| Medium | **The rollback paths restore `before` wholesale.** Both the immediate and the deferred restore rollback replace the card's defaults with a value captured before an `await`; a default written during that window (a setup slider on another surface) is reverted with it. Bounded by alert modality. Fix shape: roll back per key. | Slice 3 | — |
| Medium | **The deferred rollback's notice overwrites the confirmation's own failure sentence** (`.failed(message)` is replaced by "we couldn't put it back"). Fix shape: compose, or write only when no notice stands. | Slice 3 | — |
| Low | **Zero effect-specific reach with generic v2 support present skips the narrowing** (the gate is `effectsV2.isPartial`, which requires `supported > 0`); today such a row resolves `.legacy` and takes the grouped fallback with its UNVERIFIED caveat, so the refusal is only missed when the frozen apply-time set and the live cache diverge. | Slice 3 | — |
| Low | **The four prompt-dismissal handlers write persisted defaults outside the lifecycle FIFO** (via `releaseDeferredPreviewIfUnresolved` → rollback). Not a new class — the machine mutation was already unserialized — but round four widened what they mutate. Fix shape: hand the rollback to the chain. | Slice 3 | — |
| Low | **The three guarded row-removal notice sites** (`if runningEffects[key] != nil { notePreviewRowRemoved… }`) have no regression test of their own; reverting the guard kills nothing. | Slice 3 | — |
| Low | **The layered copy-back comments overstate what layering preserves**: a default whose *value* changed after the instance started is still overwritten by the frozen base; layering rescues only keys *added* after start. Apply Current Look also seeds the new instance from another instance's last-used values for controls the source is silent about (§14.6 fidelity). | Slice 3 | — |
| Low | **Concurrent-admit interleaving can keep a stamp slightly *early*** (mirror image of the accepted slightly-late case): during the un-awaited cancel window, a refused hold that re-sends the other instance's provisionally recorded bright frame leaves `lastOnset` at that instance's pre-send sample. Bounded by main-actor jitter. | — | — |
| Low | **A non-finite clock sample leaves the cold gate open** (`tryOnset` refuses to stamp, so the next bright first frame is again emitted unstamped). `CACurrentMediaTime()` never returns NaN; unreachable today. | — | — |
| Low | **Saturated blue is never an onset** — Party's blue palette entry at brightness 0.90 has relative luminance 0.055 < 0.10, so a black↔blue strobe rests entirely on the ≥ 17-frame plan, not on the gate. Correct under WCAG 2.3.1 (only red is carved out); recorded as a known consequence. | — | — |
| Low | **Guard 14 pins the names of `onsetRiseThreshold` / `minOnsetLedgerPeriod`, not their values**; the values are pinned by `FlashSafetyTests`. `send` / `sendUniform` remain `@discardableResult`, so a *new* caller can drop the delivery answer without a warning. | Slice 3 | — |
| Low | **Guard 13(a)'s new `.popover(` ban carries one anchored exemption**: the pre-existing Composer harmony swatch editor `CompositionEditorPanel.swift` `.popover(item: $editingSwatch)` — a genuine detached control surface on `main`, outside this PR's diff and the Composer semantics rule. Any other popover fails. | later slice | — |
| Low | **The composition render loop discards the delivery `Bool`** and has no onset ledger — the same Composer-semantics debt as the 25 fps strobe row above; after a composition has driven a shared bridge, the Studio ledger's wire model is stale until its own silence clock forgets it (≥ 0.34 s, which a card start always exceeds). | later slice | — |
| Low | `.cursor/rules/composer.mdc`'s preset count and UUID range were stale (20 / `…03`); corrected to the verified 66 / `…09` in round five. `architecture.mdc`'s grouped-light TODO and `@Published` absolutism remain pre-existing contradictions, untouched. | — | — |

**Closed since first recorded, and no longer debt:** the storm's beat-wait binding staleness and its afterglow cadence escape (`2200e98`, `119aa4b`); `speed` rendering with no unverified caveat (`119aa4b`); and the `LookDetailsPanel` setup slider bypassing the availability funnel (`2200e98` for the hero sliders, `119aa4b` for the setup slider's fail-closed form).

Also deliberately deferred: audit-§11 candidate engine expansions (palette source, strike variation, …) and Slice 3 Composer convergence.

---

## 14. Rollback / checkpoint

Nothing touched `main`; the base is `ca074b85` and a fast-forward is still available. Rollback tag **`checkpoint/pre-slice2-remediation-2026-09-01`** at **`89de143`** (the Slice 2 delivery head) — reset there to drop the entire remediation while keeping Slice 2. The earlier tag `checkpoint/pre-unified-customization-slice2-2026-09-01` at `ca074b85` drops Slice 2 as well. Every one of the nine remediation commits is independently revertable; the state wiring (`909dc47`) is the root the rest builds on.

---

## 15. Repo hygiene

The eight guardrail files deleted as collateral in `909dc47` are **restored and tracked again** — the seven `.cursor/rules/*.mdc` plus `.cursor/skills/chromaglow-code-quality-review/SKILL.md`, taken byte-for-byte from the base tree and then patched **only** where Slice 1/2 made a statement factually wrong, with every guardrail's intent preserved: `runningEffects` is `StudioSelectionKey`-keyed and never a bare room id; the generation counter has a named home (`CustomizationGenerationCounter` / `CustomizationFence`); the scheme is `HueHome 1` with an exact `id=` destination and there is no auto-commit after builds; the four-place pbxproj recipe applies to the classic-group main target only; `activeCompositionBox` is the selection-derived accessor over the `StudioSelectionKey`-keyed box map; the current `startStudioMode` signature, `studioRestSender`'s removal in favour of per-bridge scopes via `enqueueStudioRestWrite`, and the honest device-reported `mirek_schema` range (153–500 is only the Hue span); the canonical `AGENTS.md` entry header and `checkpoint/*` tags; Composer shipped and the customization host is the inline one-surface `StudioCustomizationHost` → `StudioBoardView`; and `StudioViewModel+CustomizationWiring.swift` joins the protected surfaces.

`2200e98` additionally corrects `.cursorrules` so it no longer teaches the bare room-id key, and `119aa4b` narrows two more rule statements (`architecture.mdc`, `hue-bridge.mdc`) and adds a `.gitignore` block covering `.cursor/mcp.json`, `.cnvs/` and `Scripts/__pycache__/`. `.cursor/mcp.json` was **never tracked, stays untracked, and is now ignored explicitly**; the eight `.cursor` rule/skill files remain tracked. `.cnvs/` is untouched. Pre-existing contradictions in those rule files (`architecture.mdc`'s grouped-light effects TODO and its `@Published` absolutism) were deliberately **not** touched and are recorded as debt.

---

**DO NOT MERGE WITHOUT BRIAN'S EXPLICIT APPROVAL.**

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01Th5ub6JekJVJGsyxYavJzV
