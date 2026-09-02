# Unified Customization Capability Audit

**Status:** Binding audit/evidence contract; production inventory must be refreshed from current main before implementation
**Revision:** 2026-09-01
**Compatibility filename:** `docs/ios/unified-customization-capability-audit-2026-08-19.md`

> **Current-main verification — 2026-09-01.** Verified against `main` @ `8572b92` (local `main` == `origin/main`).
> Corrections in this revision are limited to file paths, type locations, and one control-key
> disambiguation (§9). No audit obligation, evidence standard, or product decision was relaxed.

---

## 1. Purpose

This document defines how ChromaGlow proves two statements before shipping the unified Studio instrument:

1. Everything the current product can meaningfully manipulate is reachable.
2. Nothing visible is fake, dead, misleading, cross-target, or unsupported.

It is intentionally evidence-driven.

Do not infer capability from UI labels or generic request fields. Reverse-audit the runtime, transport, decoded bridge capability, persistence, and hardware evidence.

---

## 2. Current-main facts already verified by the local audit

The local repository audit performed before this document was supplied reported the following current truths at main SHA `8572b92`:

- Track A is merged via PR #61; `8572b92` is the merge commit.
- Composer 2 Phase 1c/1d landed after the older 2026-08-05 planning packets and includes:
  - `HueHome/Core/Composer2Domain.swift`
  - `HueHome/Core/Composer2Registration.swift`
  - `HueHome/Core/Composer2Resolver.swift`
  - `HueHome/Core/Composer2ConsumerContracts.swift`
- The older Track B proposal for `Core/Controls/ControlDescriptor.swift` was never implemented; that file is absent.
- Older baseline SHAs `0b71ebd` and `320ebaf` are superseded by `8572b92`.

> **Path correction (2026-09-01).** The four Composer 2 files live directly in `HueHome/Core/`, **not**
> under `HueHome/Core/Composer/`. A separate, older `HueHome/Core/Composer/` directory exists and holds
> different files (`BridgeDynamicSceneExporter.swift`, `CompositionLightResolver.swift`,
> `CompositionMixer.swift`, `CompositionRoomPriorityScorer.swift`, `GradientChannelMap.swift`,
> `SequencePlayer.swift`). Do not conflate the two when auditing.
>
> **Landing commits (verified 2026-09-01):** `Composer2Domain.swift` @ `b56988e`,
> `Composer2Registration.swift` @ `7e25e71`, `Composer2Resolver.swift` @ `6ead505`,
> `Composer2ConsumerContracts.swift` @ `2b19eda` — all dated 2026-08-07, i.e. two days after the
> 2026-08-05 packets.

These facts came from the local agent’s direct repository audit and should be re-verified immediately before branching in case main has moved again.

The 2026-08-05 CNVS packets remain historical engineering evidence only.

---

## 2A. Slice 1 verified evidence (2026-09-01, `main` @ `9404686`)

Read directly from the shipping source this session. Everything not listed here remains unproven.

### Catalog totals

| | Cards | Controls |
| --- | ---: | ---: |
| Effects (bridge-native) | 11 | 45 |
| Live (app-driven) | 4 | 23 |
| **Total** | **15** | **68** |

These match §6 and §8's expected inventories exactly. The generated matrix is
`docs/ios/unified-customization-capability-matrix-2026-09-01.md`
(regenerate/verify with `Scripts/generate_capability_matrix.py [--check]`; re-find the cited
consumer line numbers with `--refresh-citations`, and `--check` fails loudly when a citation has
rotted). **68 is the catalog size, not a proof count.** The matrix splits its totals into
four separate figures, not one score:

| Figure | Controls |
| --- | ---: |
| Code-proven send path | 57 / 68 |
| No code-proven send path (hardware-pending evidence) | 11 / 68 |
| Pending / unknown | 0 / 68 |
| Code-proven rows still owing a hardware **behaviour** check | 23 / 68 — `base_color` ×9, `speed` ×11, `warmth` ×3 |

Code-proven means the write provably leaves the app, nothing more. The 23-row figure is a SUBSET of
the 57, not a fourth bucket. `--check` now strips comments before matching, fails on any uncited or
drifting loop read, cross-checks each row's evidence class and the pending-hardware list against
`EffectParameterProfiles.swift`, and scopes each loop span to the next declaration. Nothing here is
"68/68 proven".

### The central state defect

`StudioViewModel.paramValues` is `[String: [String: Double]]` **keyed by card id alone**
(`StudioViewModel.swift:1111-1112`), and the orchestrator holds one live box **per bridge**
(`studioEngineRuntimesByBridge[bridgeID]?.paramBox`, `UnifiedOrchestrator.swift:3091`, updated at
`:5156`). Between them those serve all three of spec §18's scopes at once. Consequences verified in
source, not inferred:

1. **The same card on two bridges cannot hold different live values** — there is one dictionary per
   card. This is the invariant §16 requires and current `main` cannot satisfy.
2. **A param write is routed by bridge only.** `setParamValue` (`:1568-1576`) reads
   `currentRoomEffect?.room.bridgeID` at call time and `updateStudioParams` guards on `bridgeID`
   alone — neither checks the room or card the gesture began on. Two rooms on one bridge can
   therefore cross-write.
3. **`resetParams` (`:1469`) nils the card-global dict**, so resetting on one bridge blanks the
   other bridge's displayed values.

### Identity coverage

| Key | Fields | Gap |
| --- | --- | --- |
| `RoomEffectKey` (`:465`) | bridge, room | no `kind`; a room and zone sharing an id collide |
| `StudioSelectionKey` (`:500`) | bridge, group, kind | no look, no generation |

Neither carries the running look or a generation, so no existing key can answer "is this pending
write still addressed to what the user was touching?".

### Transport encoding

`StudioParam.entOnly` (`StudioViewModel.swift:86`, consumed `StudioParamControls.swift:119`) is set
on exactly three params — `strobe.speed`, `strobe.flash_color`, `strobe.duty_cycle` — locked by
`CustomizationCatalogFactsTests.testEntOnlyInventoryMatchesTheAuditedThree`.

### Beat

No Live card declares a Beat param; Beat reaches engines through the orchestrator
(`BeatBinding.swift` + 4 referencing files). Locked by
`CustomizationCatalogFactsTests.testNoLiveCardDeclaresABeatParamYet`.

### Composer 2

**Confirmed inert.** `Composer2Domain`, `Composer2Registration`, `Composer2Resolver` and
`Composer2ConsumerContracts` have zero references outside their own files — the only external
mention is a doc comment. Slice 1 did not activate them.

### `ParamTier.advanced`

Live and load-bearing: `StudioParamControls.swift:300` partitions an `advancedParams` section, and
`.advanced` is applied to 7 Live params plus the `transition` (Smoothness) param on every
bridge-native Effect. Retiring it (spec §2.3) is Slice 2 work, not a Slice 1 correction.

---

## 2B. Slice 1 validation evidence (2026-09-01)

The §2A findings were read from source before the foundation compiled. They are now **executed**.

**Destination:** `iPhone 17 Pro`, iOS 26.5 (23F77), `005EBEC4-ECF0-4E2C-8A9C-5389006C2A36`.
Three simulators share the name `iPhone 17 Pro`; pin the UDID.

| Gate | Result |
| --- | --- |
| Compile | 0 errors |
| Slice 1 tests | **57 / 57 passed** |
| Full registered suite ×2 | **1720/1720**, then **1723/1723** — 0 failed, 0 skipped |
| `hardening_guards.sh` | all guards passed |
| `generate_capability_matrix.py --check` | up to date |
| `git diff --check` | clean |

Registered-suite baseline is now **1723** (older DEVLOG entries record 1573).

### Audit claims now proven by an executing test

| Claim (§2A / §9 / §17 / §20) | Test |
| --- | --- |
| Two bridges may share a room id and stay distinct | `testSameRoomIDOnTwoBridgesAreDistinctIdentities` |
| Same card on two bridges holds independent live values | `testSameCardOnTwoBridgesHoldsIndependentLiveValues` |
| **Two rooms on ONE bridge stay independent** | `testTwoRoomsOnTheSameBridgeHoldIndependentLiveValues` |
| **A write on one room cannot reach a sibling room on the same bridge** | `testWriteCapturedOnOneRoomDoesNotLandOnASiblingRoomOnTheSameBridge` |
| `RoomEffectKey` drops `kind`; the new identity does not | `testRoomAndZoneSharingAnIDAreDistinctEvenThoughEffectKeysCollide` |
| Reset isolates to one instance | `testResettingOneInstanceDoesNotDisturbTheOther` |
| Unknown ≠ unsupported | `testUnreadableCapabilityIsDistinctFromUnsupported` |
| CT claimed without a readable range is unknown | `testCTCapableButRangelessTargetIsUnknownNotActive` |
| `entOnly` inventory is exactly the audited set | `testEntOnlyInventoryMatchesTheAuditedSeven` — three at Slice 1; the engine reverse-audit took it to seven at Slice 2 (§2C, §8, §17) |
| No Live card declares a Beat param | `testNoLiveCardDeclaresABeatParamYet` |
| `ambient.color` ≠ `thunderstorm.ambient_color` | `testDeadAmbientColorSentinelIsNotTheLiveThunderstormAmbientColor` |
| `thunderstorm.ambient_color` still ships | `testThunderstormAmbientColorIsStillAShippingControl` |
| Resolution order is deterministic | `testResolveAllIsDeterministicAndStablySorted` |

### What is still NOT proven

- **The production defect is not fixed.** The foundation has zero production consumers; the
  card-global `paramValues` and bridge-only `updateStudioParams` routing described in §2A are
  untouched on this branch. The tests above prove the *foundation* behaves correctly, not that the
  shipping app does.
- **No bridge-native Effect row is proven.** All 45 remain `PENDING` pending the per-effect verified
  parameter profile required by §7.
- **No hardware was exercised.** Everything above is simulator/unit evidence.

---

## 2C. Slice 2 production-wiring evidence (2026-09-01, branch `feat/unified-customization-studio-instrument`)

### The §2A central state defect is FIXED in production

Verified by executing tests against the shipping paths (`StudioProductionWiringTests` — 17 at Slice 2
delivery, 24 after the first remediation round, 31 after the second, 41 after the third, 46 after the
fourth, **47** after the fifth):

| §2A defect | Fix | Proof |
| --- | --- | --- |
| `paramValues` card-global | Deleted. `CustomizationValueScopes<Color>` owns three separated scopes; live values keyed by `RunningLookTargetKey` | `testSameCardOnTwoBridgesHoldsIndependentValuesThroughTheProductionPath` |
| `updateStudioParams` bridge-only routing | Signature now `(values:colors:bridgeID:roomID:)` with a `runtime.roomID == roomID` guard (mirrors the round-4g stop path) | `testUpdateStudioParamsRefusesASiblingRoomOnTheSameBridge` |
| `resetParams` card-global blanking | Resets only the exact selected instance under a new generation; clears persisted defaults per spec §22 | `testResetOnOneInstanceLeavesTheSameCardEverywhereElse` |
| One global `paramTask` debounce | Per-target `[RunningLookTargetKey: Task]`, post-sleep re-fence on the captured identity | characterization test updated: `testCurrentStudioParamDebounceIsKeyedByExactRunningTarget` |
| `RoomEffectKey` drops `kind` | `runningEffects` / `activeCompositionBoxes` re-keyed by `StudioSelectionKey` (bridge+group+kind); kind-less records resolve fail-closed | `testRoomAndZoneSharingAnIDRemainIndependentInProduction` |

Every gesture captures a `StudioParamSession` (identity + API client + routing facts) at start; every
tick and every debounced send is fenced on the captured `RunningLookIdentity`. The weaker place-level
keys never decide at a mutation boundary.

### §7 verified parameter profile — now exists

`HueHome/Core/EffectParameterProfiles.swift` (mirrored by the generator's `EFFECT_PROFILES` table,
locked by `EffectParameterProfilesTests`). Code-proven live paths: `speed` (v2-only, NO legacy
branch — honestly unavailable on v1-only rooms), `base_color` / `warmth` (per-light v2; the grouped
xy/mirek fallback for v2-incapable lights is PRESERVED shipping behavior classified as an
approximation), `transition` (new mutation class `.nextWrite` — sends nothing, shapes the next
write's `dynamics.duration`). Hardware-pending: visible brightness scaling during an active firmware
effect; whether the grouped fallbacks visibly fight a running effect; per-effect visual response to
live v2 speed. Prism / Color Loop tint/warmth (§6): investigated, no evidence, NOT exposed.

### §19 CT honesty — mirek ranges now plumbed

`CustomizationSnapshotBuilder` intersects per-light `color_temperature.mirek_schema` into
`MirekRange`; a CT-capable light without a readable schema downgrades evidence to `.unreadable`
(resolves unknown, never a fake 153…500 clamp). A failed capability read produces an all-
`.unreadable` snapshot instead of leaving stale coverage standing.

**Scope of that claim (corrected 2026-09-01).** What is snapshot-honest is *availability*: whether
a Warmth control resolves active / partial / unknown / unavailable. The knob's **authoring range is
not** — it is still the catalog's `153...500` for all four Warmth params in the `StudioCard`
catalog (`StudioViewModel.swift`, the four `StudioParam(id: "warmth", … kind: .slider(min: 153,
max: 500))` declarations; grep the literal rather than trusting a line number), and the board's
slider control derives its range from `param.kind` in its own `range` computed property
(`StudioBoardView.swift`), never from the snapshot's `MirekRange`. On a fixture whose `mirek_schema` is narrower than
153…500 the knob still travels the full catalog range. Separately, `ambient.warmth` is an
app-driven slider with `entOnly == false`, so `StudioBoardAvailability.requirement(for:)` gives it
`.none` — it resolves active with no CT gate at all. Both are Slice 3 debt (execution plan, Slice 2
status → "Accepted debt carried into Slice 3"; §V-B checklist row 58). Do not describe Warmth as "range-honest through the snapshot".

### §20 Beat — per-engine consumption PROVEN (read from the loops, 2026-09-01)

All four engines materially derive output from `BeatBinding` via `BeatMath.liveLock`; the Beat
instrument is justified for all four. Division and phase are genuinely consumed everywhere; Tap /
Auto / Resync act on the shared `BeatClock` transport.

| Engine | Exact consumer | What Beat materially changes | Transport difference | Safety |
| --- | --- | --- | --- | --- |
| Strobe | ENT `runStrobeEntertainment` (phase-derived ON/OFF per 20 ms frame); REST cycle flips | Flash cadence locks to the division; phase shifts alignment; duty cycle shapes the ON window inside each cycle | REST floors the lock at ~1.1 Hz cadence | `FlashSafety.StrobePlan` sizes the safe TOTAL cycle first (≥ 17 frames), then splits ON/OFF without shortening it |
| Party | ENT `runPartyEntertainment` (`cycleIndex` picks the palette slot, `cyclePhase` drives hold/fade); REST index-stepped colors + `sleepUntilNextCycle` | Palette steps exactly on cycle boundaries; smoothness fades track the cycle | REST floors at 1 Hz | `FlashSafety.PartyPlan` — same ≥ 17-frame total; each palette step is an onset and is admitted through the ledger |
| Thunderstorm | ENT strike gating (streams ambient until the cycle boundary — DTLS never pauses); REST holds the strike to the next boundary | Strikes land on the beat grid; division sets strike-opportunity spacing | REST floors at 2 Hz | `FlashSafety.ThunderstormPlan.Budget` carries frames-since-onset across skipped strikes and beat waits, so no strike lands inside 17 frames |
| Ambient | REST breathing phase from `cyclePhase` (trough on the boundary) | Breath length = the division; phase shifts the trough | REST-only engine, floors at 1 Hz | n/a (no flash) |

**Safety correction (2026-09-01 remediation).** The Safety column above previously read
"flash-class ≤3 Hz preserved" for Thunderstorm and named the requested-float clamps for
Strobe/Party. That was false on the frame grid: the requested Hz was capped, the REALIZED
cadence was not. Thunderstorm had no rate clamp at all and ran a strike every 10 frames
(**5.0 Hz**) at frequency 100; Strobe/Party floored the ON and OFF frame counts independently and
realized 15–16 frames per cycle (3.13–3.33 Hz); the storm's beat branch gated on the raw
`binding.beatsPerCycle` rather than the capped lock; and beat locks at exactly 3 Hz quantized onto
20 ms frames as 16-frame (0.32 s) intervals.

The invariant is now stated in realized frames, not in a requested float: **every Entertainment
onset — first bright frame, first strike frame, palette step — is at least 17 frames (0.34 s)
after the previous one**, enforced by the pure `BeatMath.FlashSafety` plans and backstopped by a
per-bridge `OnsetLedger` whose wall-clock gate outlives loop restarts. Entertainment beat locks
therefore cap at `entertainmentMaxLockHz` = 1/(17 × 0.02) = **2.94 Hz**. That ceiling is an
implementation consequence of the realized-onset invariant on this grid, not a new product
preference: exactly three narrow tempo bands step up a division — ×1 over (176.47, 180] BPM
(**3.53 BPM** wide), ×½ over (88.24, 90] BPM (**1.76 BPM** wide), ×¼ over (44.12, 45] BPM
(**0.88 BPM** wide) — the same bands where the old lock realized 16-frame intervals. REST loops are
unchanged (cadence ≥ 0.7 s). Landed in `910c861`; Guard 14 added in `10c2301`; the adversarial
review's flash blockers closed in `2200e98`. Proof: `FlashSafetyTests` (**39** pure, seeded,
wait-free tests, 54 after the third round, 69 after the fourth, **75** after the fifth) and
`hardening_guards.sh` Guard 14 (`slice2-r1`),
every sub-check mutation-tested against a scratch copy.

**Second-round correction (`2200e98`).** The realized-frame plans were necessary but not sufficient.
Party's beat-locked branch gated *cycle-index changes*, not *luminance rises*, so a backwards phase
correction (music-service drive, a nudge) or a smoothness drag restored peak brightness mid-cycle
with **no gate call at all** — a realized 0.02–0.06 s rise. Every rendered rise above the previous
frame's brightness (`flashRiseEpsilon`) now passes the ledger: in Party, in Strobe's `min_brightness`
raise while dark, and in the storm's ambient. `OnsetGate` refused only when `t >= last` and re-based
itself backwards on an out-of-order stamp; it now refuses any backwards time outright. The ledger
period is `minOnsetLedgerPeriod` = 17 × 20 ms = **0.34 s** — the same value the frame plans realize —
so the cross-run path (card switch, loop restart) carries the same jitter slack as a run; the
remaining 1e-9 is IEEE rounding tolerance, measured across 4000 grid points. The storm's beat wait
now re-reads the binding every frame, so Beat-off exits within one frame (this closes the Low debt
recorded in the first round). `FlashSafety.clampedInt` and a guard in `BeatBinding.init` stop
`Int(Double)` trapping on NaN/inf before the ranges clamp (`cycleIndex` did `Int(floor(nan))`).

**Third-round correction (`119aa4b`) — the gate moved to the wire.** Round two still measured *the
transitions the loop computed*, not *the frames it emitted*, and four escapes survived: a hold frame
streamed while the ledger refused could itself be a rise (`min_brightness` 0 → 50 across a card switch
realized a **50 % step 0.05 s** after the last onset); the storm's afterglow-to-ambient step was an
ungated **+10 %** two frames after a strike; an inverted Strobe (`brightness <= min_brightness`)
stamped the *falling* edge and realized the rise **0.08 s** later; and a sub-epsilon ramp accumulated
unmeasured. One mechanism now replaces every per-branch gate: the per-bridge `OnsetLedger` tracks the
**last frame put on the wire** and the **trough since the last admitted onset**, and every frame the
three Entertainment loops send passes through `emitGatedFrame` (`WireFrame` / `FrameVerdict` /
`OnsetGate.admit`). A frame that rises **≥ 10 % of full scale** above that trough — or steps the
palette at or above the admitted level — is an onset candidate and is **held at the last emitted
frame** until the 0.34 s period admits it; falls and sub-threshold rises pass. The storm's afterglow is
**floored at the ambient level** so the decay is monotone, **no direct `sendUniform` remains in the
loops**, and `BeatClock`'s audio-ingest BPM is clamped to **20–300**. `FlashSafetyTests` 39 → **54**,
each scenario measured on the emitted frame list with the pre-fix model still failing. Accepted and
documented: the first frame of a bridge's ledger life is emitted unconditionally and stamped only if
bright (worst case one delay of ≤ 0.34 s), and a refused onset now **holds the last emitted frame**
rather than blacking the light out.

**Fourth-round correction (`14a0cac`) — wire truth.** `emitGatedFrame` recorded and stamped a frame
*before* a send the DTLS client silently drops during a reconnect, so the ledger ran ahead of the wire.
`send`/`sendUniform` now answer whether the frame was handed to the transport; the gate is **reserve →
send → commit** (the stamp moves to delivery time; a dropped frame rolls it back), and the 10 % rule is
measured in **relative luminance** (L\*-cube dimming × sRGB-primaries chromaticity factor) above the
trough since the last admitted onset, with a saturated-red chroma rule. `FlashSafetyTests` 54 → **69**.

**Fifth-round correction (`b06df67`) — a dropped send changes nothing on the wire.** Round four also
*forgot* the wire on a dropped send, and that opened three escapes the suite's own viewer measured: a
refused bright frame held black at the *requested* chromaticity is, against the frame still on the
wire, a red-rule onset (**1 frame**); the cold path re-based the trough upward across a single dropped
frame (**3 frames**); and the cold path never applied the red rule at all (in-catalog Thunderstorm with
a red ambient: **1 frame**). A dropped send now **restores** the pre-drop wire state and trough; a wire
silent for a whole ledger period is unknown and goes cold; the cold path applies the red rule against
the last known frame and holds black at the last *known* chromaticity; the trough survives a forget as
a running minimum. Every scenario is asserted against a replica of the round-four gate (seeded ramps ×
drop 115/1380 violating → 0; in-catalog storm 36/60 → 0). `FlashSafetyTests` 69 → **75**. The
assumption this rests on — the bridge keeps showing the last delivered frame across a short DTLS drop and
may have reverted after a longer silence — is hardware-checkable and recorded as checklist row 65.

---

## 3. Mandatory current-main audit before production edits

Before implementing, run and record:

```bash
git status --short --branch
git branch --show-current
git fetch --all --prune
git log --oneline --decorate --graph --all -n 40
git rev-parse main
git rev-parse origin/main
```

Then read current repository source-of-truth docs, current DEVLOG entries, Studio/Composer rules, hardening guards, and all landed Composer 2 records.

Do not assume file names from older packets are current.

At minimum inspect the current equivalents of:

- Studio host/container;
- Studio view model/state owner;
- non-Composer parameter catalog/store;
- Studio parameter renderers;
- StageKit primitives;
- Beat panel and `BeatBinding`;
- Effect capability resolver;
- Hue effect request bodies and effect apply/update paths;
- Hue light capability models;
- app-driven Live engine loops in the orchestrator/runtime layer;
- Composer editor/control catalog/render/runtime files;
- exact room/zone/bridge selection keys;
- multi-bridge runtime ownership;
- command gate/mailbox/cancellation code;
- structural/scroll/identity/persistence tests;
- hardening guards.

> **Verified current locations (2026-09-01)** — starting points only; confirm before editing:
>
> | Concern | Current file |
> | --- | --- |
> | Studio host/container | `HueHome/UI/Studio/StudioView.swift` (3145 lines) |
> | Studio view model / state owner | `HueHome/UI/Studio/StudioViewModel.swift` (4085 lines) |
> | `StudioParam`, `ParamTier`, card catalog | `HueHome/UI/Studio/StudioViewModel.swift` (**not** `StudioParamStore.swift`) |
> | Non-Composer param persistence | `HueHome/Core/Effects/StudioParamStore.swift` |
> | Studio parameter renderers | `HueHome/UI/Studio/StudioParamControls.swift` |
> | StageKit primitives | `HueHome/UI/Components/StageKit.swift` |
> | Beat binding | `HueHome/Core/Audio/BeatBinding.swift` |
> | Beat panel | `HueHome/UI/Components/BeatPanelView.swift` |
> | Live engine loops / runtime ownership | `HueHome/Core/Network/UnifiedOrchestrator.swift` |
> | Rolodex | `HueHome/UI/Studio/RoomRolodexView.swift` |
> | Composer editor surfaces | `HueHome/UI/Composer/ComposerLayerSheet.swift`, `HueHome/UI/Composer/CompositionEditorPanel.swift` |
>
> Both hotspot files (`StudioView.swift`, `StudioViewModel.swift`) exceed 3,000 lines; treat them as
> collision hotspots per the execution plan §32.

Record every stale assumption found in the DEVLOG and PR.

---

## 4. Evidence matrix — required deliverable

Create/update the canonical capability matrix from current code.

One row per card and one row per control.

Required columns:

| Field | Meaning |
| --- | --- |
| category | Effects / Live / Composer |
| card ID | stable runtime/catalog identity |
| display name | user-facing name |
| control ID | typed/semantic identity where possible |
| label | user-facing label |
| semantic purpose | what the control means |
| control primitive | fader / knob / pad / color / XY / etc. |
| hero/support role | hero / primary / supporting / contextual |
| current default | runtime/store default |
| persistence key | if persisted |
| runtime consumer | production code consuming value |
| start-time consumer | code using value on launch |
| live-update consumer | code using value while running |
| mutation behavior | immediate / debounced / next-cycle / reapply / restart / staged |
| transport(s) | Entertainment / Room REST / firmware v2 / legacy / other |
| capability requirement | hardware/runtime/transport requirement |
| coverage | full / partial / unknown |
| current UI exposure | yes/no |
| current UI live effect | yes/no/partial/staged |
| misleading today | yes/no + reason |
| target availability state | active/partial/staged/unavailable/hidden |
| target composition | intended board placement/context |
| test | test proving consumer + routing |
| hardware validation | exact physical check required |

The matrix is the proof behind “full capability” and “zero fake capability.”

---

## 5. Control honesty invariant

Every visible control must have a tested mutation contract establishing:

- real production consumer;
- exact running target identity;
- supported runtime/transport;
- hardware coverage;
- availability state;
- persistence semantics;
- cancellation/generation behavior;
- reset behavior;
- formatting/range safety.

If any element cannot be established, do not render the control as active.

---

## 6. Historical/expected Effects inventory — verify, do not freeze blindly

The later planning state identified these bridge-native Effect cards and user controls.

| Effect | Expected/current controls to verify |
| --- | --- |
| Candle | Brightness; Flicker Rate; Warmth; Base Color; Smoothness |
| Fire | Brightness; Flicker Rate; Warmth; Base Color; Smoothness |
| Sparkle | Brightness; Twinkle Rate; Base Color; Smoothness |
| Prism | Brightness; Speed; Smoothness |
| Opal | Brightness; Speed; Warmth; Base Color; Smoothness |
| Glisten | Brightness; Speed; Base Color; Smoothness |
| Cosmos | Brightness; Speed; Tint; Smoothness |
| Enchant | Brightness; Speed; Tint; Smoothness |
| Sunbeam | Brightness; Speed; Tint; Smoothness |
| Underwater | Brightness; Speed; Tint; Smoothness |
| Color Loop | Brightness; Speed; Smoothness |

The audit must specifically determine:

- whether Prism has a meaningful verified tint/warmth capability;
- whether Color Loop has a meaningful verified tint/warmth capability;
- whether any color/temperature control is merely approximation rather than true effect parameter behavior;
- whether Speed is inert on legacy-only targets;
- whether Smoothness/transition changes the firmware effect itself or only subsequent non-effect state writes;
- whether fallback light-state writes fight an active firmware effect;
- whether any new Hue effect parameters are genuinely supported by decoded current capability + API contract + hardware evidence.

Never expose a generic API field merely because a request body can encode it.

---

## 7. Bridge-native effect audit procedure

For every firmware effect:

1. Identify effect catalog ID/name.
2. Inspect decoded capability discovery (`effects_v2` and legacy as applicable).
3. Inspect request body types used to start/update the effect.
4. Inspect exact live-update routes for brightness, speed, color/tint, CT/warmth, transition.
5. Inspect fallback/legacy semantics.
6. Determine exact bridge/light routing.
7. Confirm pacing/gate/cancellation behavior.
8. Confirm whether mutation is live, partial, staged, next-start, or unsupported.
9. Verify with unit tests and physical Hue hardware where simulator cannot prove behavior.

If the bridge does not expose a machine-readable per-effect parameter schema, maintain a small explicit verified parameter profile backed by source/docs/hardware evidence.

Unverified combinations remain unexposed or explicitly marked pending hardware validation; never guess.

---

## 8. Historical/expected Live inventory — verify and reverse-audit for omissions

### Party

Expected controls to verify:

- Speed
- Brightness
- Flash Color
- Fade Floor (`min_brightness`)
- Smoothness
- Beat Sync if the current engine genuinely consumes `BeatBinding`

Product composition intent:

- color / energy / rhythm should carry visual emphasis;
- supporting controls remain accessible without an Advanced bucket.

Critical audit:

- verify whether Flash Color has a real production consumer in current main;
- reverse-audit any internal palette behavior/hardcoded constants;
- classify potentially tunable palette behavior as current scope vs future engine expansion.

> **Verified 2026-09-01.** All five non-Beat controls are present in the current catalog
> (`HueHome/UI/Studio/StudioViewModel.swift`, `buildLiveModeCards()`, card id `party`). Note the Flash
> Color control’s param id is `color` — not `flash_color`, which is Strobe’s and Thunderstorm’s id.
> Its production consumer is still to be proven per the critical-audit item above.

### Strobe

Expected controls to verify:

- Speed
- Brightness
- Flash Color
- Min Brightness
- Duty Cycle
- Beat Sync if genuinely consumed

Historical planning indicated some values were Streaming-only.

Audit current transport behavior and resolve each control as:

- active now;
- staged for Streaming;
- unavailable with reason;
- partial where applicable.

> **Verified 2026-09-01 (count corrected in the remediation).** All five non-Beat controls present
> (card id `strobe`). Strobe carries three `entOnly: true` params — `speed`, `flash_color`,
> `duty_cycle` — and the Slice 2 engine reverse-audit took the catalog-wide inventory from three to
> **seven** (adding `party.speed`, `party.min_brightness`, `thunderstorm.flash_length`,
> `thunderstorm.afterglow`). The flag is no longer read by a view: the `entOnly` →
> `.transport(.entertainment)` migration is complete through
> `HueHome/Core/StudioBoardAvailability.swift` (`f2f7a19`), which translates the bit into a
> `CapabilityRequirement` once and lets the resolver decide — pinned by Guard 15 (`slice2-r2`) and
> `StudioBoardAvailabilityTests` (42 after the third review round, 48 after the fourth, **53** after
> the fifth). See §17 and spec §2.3.

Safety:

- free-running and beat-locked output must remain ≤3 Hz;
- exact typed values may not bypass clamp;
- UI range/formatter should reflect the real safe range.

> **Met on 2026-09-01 (remediation).** As a realized-frame invariant, not a requested-float clamp:
> every Entertainment onset is ≥ 17 frames (0.34 s) apart via `BeatMath.FlashSafety` plans plus the
> per-bridge `OnsetLedger`; Entertainment beat locks cap at `entertainmentMaxLockHz` = 2.94 Hz as an
> implementation consequence of that invariant. Landed in `910c861`, hardened in `2200e98`. Proof:
> `FlashSafetyTests` (54 after the third round; 75 at `b06df67`) and Guard 14. See the safety correction note in §2C.

### Thunderstorm

Expected controls to verify:

- Storm Intensity (`frequency`)
- Flash Brightness (`flash_intensity`)
- Ambient Color (`ambient_color`)
- Flash Color (`flash_color`)
- Ambient Level (`min_brightness`)
- Strike Chance (`strike_rate`)
- Flash Length (`flash_length`)
- Afterglow (`afterglow`)

Historical planning states these were intentionally extracted from previously hardcoded storm literals. Verify all eight current production consumers.

Only expose Beat Sync if the engine truly consumes it.

Audit flash-class combinations for safety.

> **Met on 2026-09-01 (remediation).** The storm was the worst offender — no rate clamp at all,
> 5.0 Hz at frequency 100 / flash_length 1 / afterglow 0. `FlashSafety.ThunderstormPlan.Budget` now
> carries frames-since-onset across skipped strikes and beat waits so gap + frames-since-onset ≥ 17
> at every frequency × flash_length × afterglow, and the beat branch gates on the capped lock
> (≤ `entertainmentMaxLockHz` = 2.94 Hz) instead of the raw `beatsPerCycle`. Landed in `910c861`,
> hardened in `2200e98` (the beat wait re-reads the binding every frame; the dead pre-strike
> `noteAmbient` is gone) and again in `119aa4b` (the afterglow is floored at the ambient level, and
> every emitted frame passes the wire-level gate). Proof: `FlashSafetyTests` (54 after the third round; 75 at `b06df67`) and Guard 14. See the
> safety correction note in §2C.

> **Verified 2026-09-01.** All eight controls are present in the current catalog (card id
> `thunderstorm`). `ambient_color` has a confirmed live production consumer at
> `HueHome/Core/Network/UnifiedOrchestrator.swift` (the `paramBox.colors["ambient_color"]` reads
> inside `runThunderstormEntertainment` and the REST storm loop — the capability matrix carries the
> exact machine-verified line numbers and `--refresh-citations` re-finds them)
> (`paramBox.colors["ambient_color"]` → `entClient.sendUniform`). The remaining seven consumers still
> require the proof this section demands.

### Ambient

Expected controls to verify:

- Speed
- Brightness
- Warmth
- Smoothness
- Min Brightness
- Beat Sync only if consumed

Do not reintroduce a dead `ambient.color` control without a real production consumer.

---

## 9. Known dead-control regression list

Historical tests/planning explicitly identified these as dead/no-op unless a newer production consumer has since been added:

- `thunderstorm.brightness`
- `party.saturation`
- `prism.saturation`
- `ambient.color`

Treat these as regression sentinels.

A control may leave the dead list only when current production code demonstrates a real consumer and tests are updated intentionally.

> **Notation and status clarified 2026-09-01 — the sentinels stand; only their reading is corrected.**
>
> These four entries use documentation notation `card.param`, **not** literal Swift string keys.
> Verified against current `main`:
>
> | Sentinel | Status at `8572b92` |
> | --- | --- |
> | `thunderstorm.brightness` | Absent from the `thunderstorm` card catalog — still dead. |
> | `party.saturation` | Absent from the `party` card catalog — still dead. |
> | `prism.saturation` | Absent from the Prism effect catalog — still dead. |
> | `ambient.color` | Absent from the `ambient` card catalog — still dead. |
>
> **Do not confuse `ambient.color` with `ambient_color`.** The dead sentinel `ambient.color` means a
> color control on the **Ambient** card, which does not exist. The live param `ambient_color` is
> **Thunderstorm’s** “Ambient Color” (§8), and it *does* have a real consumer. Removing or suppressing
> `ambient_color` on the grounds that it appears on the dead list would be a capability regression.
>
> Any future automated check for these sentinels must match on card + param identity, not on a
> substring — a naive regex for `ambient.color` matches `ambient_color` and produces a false positive.

---

## 10. Reverse-audit every app-driven engine

For every app-driven Studio/Live engine:

- list every parameter key/value read from its live parameter box/state;
- list every user-meaningful behavior literal still hardcoded;
- classify each literal as:
  - user-tunable behavior → candidate for exposure;
  - safety invariant → internal;
  - transport/network implementation → internal;
  - random/internal algorithm detail → internal unless product-approved;
  - unused/dead → removal/follow-up, not UI;
- map every user-tunable key to one catalog control;
- prove every catalog control has a production consumer.

A new Live control may be added in this initiative when:

- the engine already has meaningful behavior to manipulate; or
- exposing it is a small contained extraction of an existing meaningful literal.

Do not turn this initiative into a Live-engine rewrite.

---

## 11. Candidate future controls — audit only, do not auto-approve

The UX discussion identified potentially valuable expansion areas. These are not binding implementation requirements unless the current engine already has a contained real behavior seam or product approval is added.

**Party candidates**

- palette source (ChromaGlow / My Colors / selected palette)
- color diversity
- color order (sequential/random)
- fade character
- beat phase/division richness

**Thunderstorm candidates**

- strike variation
- cluster size
- spatial lightning behavior

**Strobe candidates**

- flash shape

**Ambient candidates**

- breathing depth
- envelope shape
- color/temperature drift amount
- beat influence

**Composer future candidates**

- multiple editable color stops
- interpolation mode
- palette rotation/contrast/warmth bias
- saved palette presets
- motion path variants
- richer envelope editing
- frequency-band React routing (bass/mid/treble)
- future modulation routing

Do not implement speculative engine expansion merely to populate the new console.

---

## 12. Composer richness ceiling — preserve semantic model

Composer remains outside generic StudioParam ownership.

Current conceptual inventory to verify against current main includes:

**Palette**

- Mode
- Hue/Saturation or Temperature
- Harmony where applicable
- Hue Shift for Spectrum where applicable
- Saturation for Spectrum where applicable
- Randomize
- Dynamic Scene export where valid

**Motion**

- Pattern
- Speed
- Direction/forward where spatial
- direction angle where valid
- Spread
- Offset / Heads / Density depending on pattern
- Mirror where spatial

**Brightness / Envelope**

- Shape
- BPM when not Steady
- Depth when not Steady
- Attack / Decay where applicable
- Duty Cycle for Pulse
- Min Brightness where applicable
- Max Brightness
- visual envelope representation

**React**

- Source
- Targets
- Beat/onset/tap controls
- Sensitivity for microphone sources
- Smoothing
- Threshold
- Intensity
- current beat/reaction controls such as punch decay/color step/motion lock where production exposes them

All current context gating must remain truthful: if the current engine does not consume a parameter in the current mode, it does not render as active.

---

## 13. Current Composer 2 seam

The local current-main audit reports that Composer 2 Phase 1c/1d foundation files are now present.

Before using them, inspect the latest landing/architecture records and determine whether they are still inert foundation contracts or have authorized runtime consumers.

Do not silently make an inert resolver/runtime seam authoritative merely because it would simplify UI implementation.

If newer repository decisions authorize runtime ownership, follow the newer binding decision and document the divergence from older packets.

> **Records to read first (verified present 2026-09-01):**
> `docs/ios/composer2-architecture-review-2026-08-01.md`,
> `docs/ios/composer2-phase1-landing-record-2026-08-07.md`,
> and the DEVLOG entries for commits `b56988e`, `7e25e71`, `6ead505`, `2b19eda`.
> The DEVLOG snapshot also records an outstanding “Composer 2 Phase 1 evidence debt” item (`f9d640f`) —
> resolve its status before treating any Phase 1 seam as proven.

---

## 14. Capability context required by the UI

The customization resolver needs a stable exact snapshot that can answer, for the selected target:

- exact selection identity;
- bridge ID;
- room/zone ID and kind;
- target light IDs;
- total target count;
- reachable target count if known;
- dimming support;
- color support and coverage;
- CT support and ranges;
- effect capability (`effects_v2`, legacy);
- effect-specific verified support;
- gradient/spatial capability where relevant;
- Entertainment availability;
- current running transport;
- capability evidence quality: known / absent / unsupported / unreadable / unknown.

Use cached orchestrator/light data where possible.

Do not fetch from SwiftUI body.

Stale async results must be fenced by exact selection identity/generation.

---

## 15. Availability resolution

The final resolver should combine:

- parameter requirement metadata;
- card/effect strategy;
- runtime capability;
- exact target capability;
- active transport;
- current running state;
- evidence quality.

Avoid a forest of `if card.id == ...` checks in SwiftUI.

Prefer pure deterministic requirements/predicates and card-specific semantic profiles.

Availability result:

- `active`;
- `partial(current, total, reason)`;
- `staged(reason, remediation)`;
- `unavailable(reason, remediation)`;
- `hidden`.

Also classify mutation behavior separately:

- `immediate`;
- `debounced`;
- `nextCycle`;
- `reapply`;
- `restart`;
- `staged`/next-start.

---

## 16. Running-instance identity and state audit

Verify that current production can distinguish the same card running independently on multiple targets.

Required state separation:

- persistent last-used defaults by card (where existing product behavior expects it);
- exact live running-instance values;
- exact-session draft interaction values.

Required invariants:

- same card on Bridge A and Bridge B may hold different live values;
- selecting A shows A;
- selecting B shows B;
- editing A does not mutate B;
- Stop/Reset on A does not mutate B;
- persistent defaults update intentionally for future launches;
- duplicate room IDs across bridges never collide.

> **Existing prior art (verified 2026-09-01).** Track A landed `StudioSelectionKey` (bridge + group +
> kind) as the Studio read-path selection identity, and `RoomEffectKey` covers the write path. Audit
> both before introducing a new identity type — the execution plan’s `RunningLookIdentity` should
> evolve these rather than add a third parallel key.

---

## 17. Transport-aware semantics

Transport should be treated as an implementation provider for a semantic control, not merely a badge.

For each visible control determine behavior under all relevant transports/modes.

Examples:

- Entertainment active → live mutation supported;
- Room mode → fixed/limited/staged behavior;
- firmware v2 → per-light effect mutation;
- legacy fallback → grouped/per-light state semantics;
- no viable route → unavailable.

Do not permanently encode “Streaming-only” as a UI fact if the semantic capability might gain another valid implementation later; encode current implementation truth in the resolver/profile.

> **Current encoding (verified 2026-09-01, corrected in the remediation).** The catalog still
> declares a single boolean, `StudioParam.entOnly` (`HueHome/UI/Studio/StudioViewModel.swift:86`),
> now set on **seven** params — `party.speed`, `party.min_brightness`, `strobe.speed`,
> `strobe.flash_color`, `strobe.duty_cycle`, `thunderstorm.flash_length`,
> `thunderstorm.afterglow`. The binary flag is no longer the decision: it is translated once into
> `.transport(.entertainment)` by `HueHome/Core/StudioBoardAvailability.swift`
> (`descriptor(card:param:)`), which is the single funnel every board control passes through —
> colour pickers and Live-card controls included, resolved exactly the way bridge-native params
> already were. Spec §17's staged semantics are applied at the control: active/partial/staged stay
> editable, staged renders at reduced opacity with a "STREAMING ONLY — INACTIVE IN ROOM MODE"
> note, and unavailable/hidden are disabled with a local reason. What remains of execution plan §8
> is deleting the catalog bit itself, not the branching it used to drive.
>
> **Second-round correction (`2200e98`).** The funnel was the right shape but discarded evidence and
> was not the only gate:
>
> - **Profile evidence was thrown away**, so hardware-pending params rendered as fully live.
>   `StudioBoardResolution` now carries `isHardwareUnverified`; those controls stay editable at
>   staged opacity with **"UNVERIFIED ON THESE LIGHTS"** (`brightness` everywhere;
>   `base_color`/`warmth` on the legacy transport). This is the UI half of the matrix's 23-row
>   figure above.
> - **CHECKING was a dead end.** `warmEntertainmentCaches` dropped its own light fetch from the
>   guard; the light cache was not observable; `refreshCoverage` and `roomHueLights` fetched
>   inventories and discarded them — so a board could say CHECKING WHAT THESE LIGHTS SUPPORT
>   forever. The guard now includes `needsLights`, `capabilityInventoryGeneration` is bumped on
>   every inventory seed and read by `targetSnapshot`, both fetches seed the cache, and the note
>   tells the user the board refreshes when the bridge answers. A target with genuinely no lights
>   says so instead of checking forever.
> - **`.disabled` was the only gate for raw gestures.** Knobs, faders, chips, toggles, the colour
>   editor and the hue pad now short-circuit their own callbacks when not interactive, and a
>   non-interactive editor never renders the pad and refuses expansion.
> - **App-driven warmth now requires `colorTemperature`** (it previously resolved `.none` with no CT
>   gate at all — see the Warmth scope note in §2C, of which this fixes the availability half but
>   not the authoring range). `.hidden` renders nothing, a bridge-native param with no profile fails
>   closed, the reason note keeps its own alpha, and the colour section reuses the one snapshot.
> - **The look browser's hero sliders** in `LookDetailsPanel` now resolve through the same funnel
>   when the card is running on the selected room, and otherwise say they set the next start.
>
> `StudioBoardAvailabilityTests` 11 → **22**; Guard 15 gains sub-checks (f)–(j).
>
> **Third-round correction (`119aa4b`) — unknown must never refuse.** An UNKNOWN `effects_v2`
> capability was mapped to the *refusal* reason, so a cold snapshot's Speed knob asserted "THESE
> LIGHTS CAN'T CHANGE THIS WHILE RUNNING" **beside neighbours saying CHECKING**. Unknown coverage now
> resolves `capabilityUnknown` with a retry remediation, and `.effectsV2Unavailable` is reachable
> **only from an unsupported answer**. In a mixed v2/v1 room `base_color` / `warmth` / `speed` reach
> only the v2 lights, so the funnel **narrows them to the `effects_v2` partial coverage**. The
> unverified caveat now derives from `EffectParameterProfiles.pendingHardwareCheckParamIDs` — **`speed`
> is labelled too** — and **coexists with** the coverage count rather than replacing it. Descriptors
> claim their own card so `.hidden` is reachable, the CHECKING copy fits its tag, **NO LIGHTS HERE
> outranks every state**, and the look-browser setup slider uses the same fail-closed funnel form as
> the board. `StudioBoardAvailabilityTests` 22 → **42**. Accepted and documented: `.capabilityUnreadable`
> as a distinct reason is **reserved** — unknown and unreadable render identically today, so the
> distinction lives in the type, not on screen.
>
> **Fourth-round correction (`14a0cac`) — effect-specific reach.** The narrowing keyed on generic
> `effects_v2` support while sends reach only the lights whose `effect_values` list *this* effect.
> `targetSnapshot` now measures effect-specific reach and the colour / CT intersections; the funnel
> narrows to the intersection, and zero reach resolves unavailable with "NO LIGHT HERE RESPONDS TO
> THIS" rather than a live 0-of-n knob. Unverified-but-active controls keep their caption at full
> opacity. `StudioBoardAvailabilityTests` 42 → **48**.
>
> **Fifth-round correction (`b06df67`) — the badge shows the funnel's reach.** The colour editor
> suppresses the coverage note because it badges its own count, but that badge read the *un-narrowed*
> snapshot colour coverage: a mixed room (3 colour lights, one listing the effect) rendered a fully
> live Tint editor with no badge and no caption. `StudioBoardAvailability.editorCoverage` now feeds the
> editor the resolution's partial counts. `StudioBoardAvailabilityTests` 48 → **53**.

---

## 18. Color/gamut audit

For every color control:

- determine exact target color capability;
- determine authoring color context;
- avoid hardcoded gamut C;
- define mixed-gamut behavior;
- define unknown capability behavior;
- verify saved color application;
- verify exact-target state shown in UI;
- verify outgoing per-target clamp if current architecture performs it.

If adding per-light v2 clamping, golden-test outgoing XY per light.

Do not create competing color-science implementations if a newer Composer 2 color pipeline already owns the accepted rule.

---

## 19. CT/warmth audit

For every Warmth control:

- verify the card/runtime genuinely consumes CT;
- use actual mirek ranges where available;
- define mixed-range intersection/clamping behavior;
- show partial coverage honestly;
- do not render as active for unsupported targets;
- preserve stored mirek semantics even if user formatter shows Kelvin.

---

## 20. Beat audit

For every Live engine that exposes Beat:

- verify the engine consumes `BeatBinding`/current shared beat source;
- verify Off preserves legacy timing;
- verify division, phase, Tap/Auto/Resync behavior at the adaptation layer;
- verify exact running instance isolation across bridges;
- verify Strobe safety clamp under beat lock;
- remove false Beat affordances if an engine does not consume the binding.

Do not duplicate beat-clock math unnecessarily; test the Studio adaptation/routing seam.

> **Current consumers (verified 2026-09-01).** `BeatBinding` is defined at
> `HueHome/Core/Audio/BeatBinding.swift` and referenced from `HueHome/UI/Studio/MixerTrayView.swift`,
> `HueHome/UI/Components/BeatPanelView.swift`, `HueHome/UI/Performance/PerformanceView.swift`, and
> `HueHome/Core/Network/UnifiedOrchestrator.swift`. Note that no Live card in the current catalog
> declares a Beat param — Beat reaches Live engines through the orchestrator, not through
> `StudioParam`. Establish per-engine consumption before rendering any inline Beat affordance.

---

## 21. Look browser / Preview Live capability audit

The new look browser requires evidence for:

- last-used/default launch state;
- Favorites persistence;
- Recents ordering/update semantics;
- immediate apply;
- per-look lightweight setup descriptors;
- optional Preview Live;
- snapshot/restore of the previous exact running look;
- cancel restore correctness;
- selection/bridge change during preview;
- stop/reset while preview is active.

Preview Live must never destroy the previous running state merely because the user auditioned another look.

---

## 22. Stop audit

Verify exact behavior for:

- Stop All;
- selected-room Stop;
- stop another active room from expanded Rolodex/session manager.

Stop All must use current production ownership to stop all ChromaGlow-managed active runtimes safely across bridges.

A pending debounced write must not resurrect/modify a stopped look.

An individual stop removes that room from the active list immediately.

---

## 23. Required pure/catalog tests

Add/extend deterministic tests proving:

- every Effect card classified;
- every Live card classified;
- every visible non-Composer control belongs to exactly one semantic placement/context;
- no orphan control;
- no duplicate control;
- empty contextual groups do not render;
- deterministic composition order/placement descriptors;
- Composer remains outside string-key generic ownership;
- availability deterministic from value inputs;
- no network in catalog/resolver;
- every app-driven tunable engine-read key has one control;
- every catalog control has a real production consumer;
- dead-control regression list remains dead unless intentionally consumed;
- bridge-native effect profiles contain only verified combinations.

---

## 24. Required identity/race tests

Deterministically cover:

- capability fetch A completes after selection B → ignored;
- drag A → select B → A commit does not target B;
- drag → Stop → pending commit ignored;
- drag → Reset → reset wins;
- effect A → replace with effect B → A pending write ignored;
- same card on two bridges with different live values;
- duplicate room IDs across bridges;
- Preview Live cancel restores exact previous running state;
- Preview Live target changes are fenced;
- transport switch resolves availability immediately;
- repeated Reset/Stop does not duplicate start/stop work.

Avoid arbitrary sleeps where generation/state seams can be injected.

---

## 25. Persistence tests

Cover:

- new parameter defaults when absent;
- removed parameter dropped;
- stale/unknown card dropped;
- out-of-range clamped;
- segmented values snapped;
- NaN/Infinity rejected;
- colors persist safely;
- live instance state is not persisted forever as room-specific history unless separately approved;
- Reset clears persisted custom defaults as intended;
- existing store version remains readable where key schema is unchanged;
- Favorites/Recents migration and stability if introduced.

---

## 26. Accessibility and interaction tests

Verify:

- VoiceOver labels/current values;
- selected traits;
- unavailable/staged reasons;
- color semantic announcements;
- Stop All distinct from room Stop;
- double-tap reset has explicit accessible alternative;
- long-press exact entry has explicit discoverable/accessibility alternative;
- Dynamic Type;
- accessibility sizes;
- Reduce Motion;
- keyboard exact entry does not collapse/unmount host;
- adaptive fine-control gesture does not create inaccessible-only capability.

---

## 27. Hardware / capability edge cases

Each must receive a unit test, host test, hardware checklist row, or explicit out-of-scope reason:

- room with zero lights;
- zone with direct light refs;
- room with device refs;
- one light;
- mixed color + CT + white-only room;
- CT-only room;
- white-only room;
- partial `effects_v2` support;
- legacy/v1-only support;
- capability block absent;
- capability fetch failure;
- unreachable light;
- gradient fixture;
- multiple gradient targets;
- partial firmware effect coverage;
- Entertainment unavailable;
- Entertainment ambiguous;
- third-party Entertainment session;
- Room fallback;
- Streaming active;
- bridge reboot/reconnect during customization;
- app background/foreground;
- recovered/bridge-stored composition with no live box;
- external controller changes state during edit;
- room/zone deleted while host open;
- same effect across multiple bridges;
- Preview Live across bridge reconnect.

---

## 28. Device validation matrix

Do not claim simulator tests prove Hue hardware behavior.

The final master device checklist should include:

**Visual / interaction**

- neutral chassis remains calm;
- hero hierarchy obvious but restrained;
- no “Advanced” section;
- progressive reveal/reflow feels intentional;
- adaptive fine control feels natural;
- contextual values readable;
- double-tap reset reliable;
- haptics restrained/semantic;
- cinematic transitions non-bouncy;
- color editor B+ behavior;
- narrow iPhone and large phone;
- Dynamic Type;
- Reduce Motion;
- VoiceOver.

**Rolodex/session**

- active rooms first;
- room + running look + live indicator;
- instant switch between active rooms;
- room-specific live values restored;
- room-specific scroll/context restored during session;
- new room → Apply Current Look copies once then becomes independent;
- Choose Another Look path;
- selected-room Stop;
- stop another room from expanded list;
- always-visible Stop All;
- stopped room leaves active section immediately.

**Look browser / Preview Live**

- Favorites + Recents;
- favorite affordance + long-press;
- restrained visual cards;
- main tap immediate apply;
- details path;
- per-look lightweight setup;
- Preview Live;
- cancel exact restore.

**Effects**

Validate every visible control for every current firmware effect on representative hardware/support combinations.

**Live**

Validate every visible control, Beat behavior, transport-specific state, same-card multi-bridge independence, pending-write races, background/foreground.

**Composer**

Validate current layer/domain controls, full color, motion/spatial, brightness/envelope, React/Beat, Revert/Save/Perform/Stop, and exact-target behavior.

**Safety**

Validate free-running and beat-locked Strobe caps plus existing photosensitivity path.

---

## 29. Audit completion criteria

The audit is complete only when, for every visible control, the team can point to:

- production consumer;
- exact target identity;
- current transport implementation;
- hardware/capability requirement;
- availability result;
- persistence/default semantics;
- reset behavior;
- deterministic test;
- physical validation requirement where needed.

Anything unproven remains hidden/unavailable rather than guessed.
