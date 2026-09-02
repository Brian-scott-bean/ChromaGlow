# Unified Customization Engine — Large-Slice Execution Plan

**Status:** Binding delivery plan
**Revision:** 2026-09-01
**Compatibility filename:** `docs/ios/unified-customization-execution-plan-2026-08-19.md`
**Target:** one coherent feature branch / one reviewable PR, delivered in three large gated slices

> **Current-main verification — 2026-09-01.** Verified against `main` @ `8572b92` (local `main` == `origin/main`).
> Corrections in this revision are limited to file paths, type locations, and test-invocation facts.
> No slice boundary, gate, or product decision was altered.

---

## 1. Goal

Implement the final Unified Customization Engine / Studio instrument defined in `UNIFIED_CUSTOMIZATION_SPEC.md` while preserving current runtime ownership, Composer semantics, multi-bridge safety, Hue transport constraints, accessibility, and all verified user capability.

Move quickly in large slices, but use internal commits/checkpoints so each risk boundary is reviewable and rollback remains straightforward.

Do not merge the final PR unless Brian explicitly asks.

---

## 2. Current known repository baseline

A local audit performed before the finalized documents were supplied reported:

- current main at `8572b92`;
- Track A merged via PR #61;
- Composer 2 Phase 1c/1d foundation files present;
- older Track B `Core/Controls/ControlDescriptor.swift` proposal not implemented;
- older packet baselines `0b71ebd` and `320ebaf` superseded.

These are reference facts only.

Before branching, re-run:

```bash
git status --short --branch
git branch --show-current
git fetch --all --prune
git log --oneline --decorate --graph --all -n 40
git rev-parse main
git rev-parse origin/main
```

If local main differs from authoritative remote main, reconcile before work.

> **Re-verified 2026-09-01:** `main` and `origin/main` both at
> `8572b92038de8f8298cdb8857ce074939a0aaea2`. Composer 2 files confirmed at `HueHome/Core/Composer2*.swift`
> (see audit §2 for the path correction — they are **not** under `HueHome/Core/Composer/`).

---

## 3. Source-of-truth order

Read before implementation:

1. current `AGENTS.md` / repo operating rules;
2. current DEVLOG status + entries since Track A/Composer 2 work;
3. current Studio/Composer architecture records;
4. current Composer 2 landing records;
5. current hardening guards;
6. `UNIFIED_CUSTOMIZATION_SPEC.md`;
7. `docs/ios/unified-customization-capability-audit-2026-08-19.md`;
8. this execution plan;
9. older 2026-08-05 CNVS packets only as historical engineering evidence.

If a newer binding repository decision contradicts this product requirement, stop and report.

---

## 4. Branch / checkpoint

After current-main verification:

```bash
git checkout main
git pull --ff-only
git tag checkpoint/pre-unified-customization-instrument-2026-09-01
git checkout -b feat/unified-customization-instrument
```

Use the actual current date if work starts later.

Do not work directly on main.

> **Note (2026-09-01).** The docs-only PR that introduced these three finalized documents was delivered
> on the separate branch `docs/unified-customization-source-of-truth` and carries no checkpoint tag,
> because it does not touch `main` or any source file. The checkpoint tag above belongs to the
> implementation branch and is still outstanding.

---

## 5. Audit gate before production mutation

Before changing runtime/UI behavior, produce/update the capability matrix and a short implementation delta covering:

- current Studio host architecture;
- current active-room/Rolodex structure;
- current Composer 2 runtime-consumer status;
- current exact target keys;
- current non-Composer parameter store/value ownership;
- current app-driven runtime ownership by bridge/room;
- current Hue v2/legacy effect mutation semantics;
- current Beat consumers;
- current color/gamut handling;
- stale assumptions from these docs;
- controls that can be added now;
- candidate controls intentionally deferred because they require engine expansion or insufficient evidence;
- exact files/types proposed.

Continue automatically unless the audit finds:

- contradiction with a binding product decision;
- unsupported requested capability;
- safety weakening;
- need to activate an intentionally inert runtime foundation without authorization;
- conflicting unmerged ownership work that cannot be reconciled;
- pre-existing broken project/test registration.

---

# SLICE 1 — Truth Foundation

## 6. Slice 1 objective

Establish the exact state/capability architecture that makes the rest of the UI safe.

This slice should make few or no major visual changes.

**Deliverables**

- Final current-code capability matrix.
- Typed/semantic control identity where it reduces stringly-typed risk.
- Exact `RunningLookIdentity` or current-repo equivalent.
- Explicit separation of:
  - persistent defaults;
  - live running-instance values;
  - draft interaction values.
- `CustomizationSession` or equivalent exact-session value object combining:
  - exact selection/running identity;
  - category;
  - target capability context;
  - transport/runtime context;
  - live values.
- Pure capability/availability resolver.
- Mutation behavior metadata (immediate/debounced/reapply/etc.).
- Exact stale-selection/generation fencing.
- Room-specific temporary UI working-state model (scroll/expansion/domain) scoped to active session, if this can be introduced without visual migration yet.
- Deterministic unit tests for all foundation behavior.

---

## 7. Recommended architecture direction

Use current repository naming where better equivalents exist.

Conceptually:

```swift
enum CustomizationCategory {
    case effect
    case live
    case composer
}

struct RunningLookIdentity: Hashable {
    // exact bridge + room/zone/kind + running look + generation/strategy as needed
}

struct CustomizationTargetContext {
    // exact cached capability snapshot
}

struct CustomizationSession {
    let runningIdentity: RunningLookIdentity
    let category: CustomizationCategory
    let target: CustomizationTargetContext
    let transport: CustomizationTransportContext
    let liveState: CustomizationLiveState
}
```

Availability should be pure and typed:

```swift
enum CustomizationAvailability: Equatable {
    case active
    case partial(current: Int, total: Int, reason: String)
    case staged(reason: String, remediation: CustomizationRemediation?)
    case unavailable(reason: String, remediation: CustomizationRemediation?)
    case hidden
}
```

Mutation behavior should be separate from availability:

```swift
enum CustomizationMutationBehavior {
    case immediate
    case debounced
    case nextCycle
    case requiresReapply
    case requiresRestart
    case staged
}
```

Do not cargo-cult names if current main has stronger equivalents.

> **Existing equivalents to evolve, not duplicate (verified 2026-09-01).** Track A already landed
> `StudioSelectionKey` (bridge + group + kind) for the Studio read path, and `RoomEffectKey` covers the
> write path. `RunningLookIdentity` should subsume these rather than become a third parallel identity
> type. Audit both before adding a new key.

---

## 8. StudioParam evolution

The historical `entOnly`-style binary requirement is insufficient.

Replace/evolve it toward pure requirement metadata capable of expressing:

- color support;
- CT support;
- Entertainment/Streaming support;
- firmware `effects_v2` support;
- effect-specific parameter support;
- partial room coverage;
- app-driven runtime support;
- known vs unknown evidence;
- running-state requirement.

Prefer composable requirements/predicates over a growing list of increasingly specific special cases.

Do not encode user-facing semantics inside SwiftUI `if card.id == ...` forests.

> **Current state (verified 2026-09-01).** `StudioParam.entOnly` is declared at
> `HueHome/UI/Studio/StudioViewModel.swift:86` and consumed at
> `HueHome/UI/Studio/StudioParamControls.swift:119`. It is set on exactly three params today:
> `strobe.speed`, `strobe.flash_color`, `strobe.duty_cycle`.
> `StudioParam` and its `ParamTier` enum live in `StudioViewModel.swift`, **not** in
> `HueHome/Core/Effects/StudioParamStore.swift` (which owns persistence only).
> Retiring `ParamTier.advanced` (`StudioViewModel.swift:92`) belongs to this work — see spec §2.3.

---

## 9. Exact live-state requirements

Required invariant:

> Two rooms/bridges may run the same card with different settings, and selecting either one shows/edits that exact instance while preserving last-used defaults for future fresh starts.

Draft values belong to the session that began the gesture.

A drag started on A may never commit to B after selection change.

---

## 10. Slice 1 tests

At minimum:

- same card on Bridge A/B with different values;
- selecting A/B returns correct live state;
- edit A does not mutate B;
- Stop A leaves B;
- Reset A leaves B;
- duplicate room IDs across bridges distinct;
- drag → target switch ignores old commit;
- drag → Stop ignores old commit;
- drag → Reset reset wins;
- card replace ignores old write;
- capability fetch A finishes after B selection → ignored;
- availability full/partial/staged/unavailable/hidden fixtures;
- no network in pure resolver/catalog;
- persistence defaults vs live state separation.

### Slice 1 status — 2026-09-01: **VALIDATED / COMPLETE**

**Exit gate CLEARED.** Foundation compiles, all tests pass, all guards pass.

| Deliverable | Status |
| --- | --- |
| Current-code capability matrix | **Done** — generated, self-checking (`Scripts/generate_capability_matrix.py --check`) |
| Typed/semantic control identity | **Done** — `CustomizationControlID` |
| Exact `RunningLookIdentity` | **Done**, plus `RunningLookTargetKey` and generation |
| Persisted / running / draft separation | **Done** — `CustomizationValueScopes` |
| `CustomizationSession` equivalent | **Done** — `CustomizationTargetSnapshot` carries identity + capability + transport |
| Pure capability/availability resolver | **Done** — `CustomizationResolver` |
| Mutation behaviour metadata | **Done** — `CustomizationMutationBehavior` |
| Stale-selection/generation fencing | **Done** — `CustomizationFence` |
| Room-specific temporary UI working state | **Deferred to Slice 2** — needs the visual migration to be meaningful |
| Deterministic unit tests | **Done — 57 tests, all passing** |

**Validation evidence** (destination: `iPhone 17 Pro`, iOS 26.5, `005EBEC4-ECF0-4E2C-8A9C-5389006C2A36`):

| Gate | Result |
| --- | --- |
| Compile | 0 errors |
| Slice 1 focused tests | 54/54 passed (before the same-bridge additions) |
| Full registered suite, run 1 | 1720/1720 passed, 0 failed, 0 skipped |
| Full registered suite, run 2 | 1723/1723 passed, 0 failed, 0 skipped |
| `./Scripts/hardening_guards.sh` | all guards passed |
| `generate_capability_matrix.py --check` | up to date |
| `git diff --check` | clean |

The registered-suite baseline is now **1723**, not the 1573 recorded in older DEVLOG entries.

**Environment repair required to get here.** Three stacked toolchain problems, none in app source:
a stale `CoreSimulatorService` (framework 1051.55 vs job 1051.50), a missing **iOS 26.5** platform
(8.52 GB), and a missing **watchOS 26.5** platform (3.96 GB — the `HueHome 1` scheme embeds
`LightShadeWatchApp`, so it cannot test without it). Each masked the next.

**Note on the destination.** Three simulators are now named `iPhone 17 Pro` (26.3.1, 26.4.1, 26.5),
so the bare `name=iPhone 17 Pro` in `CLAUDE.md` is ambiguous. Pin the UDID above for reproducibility.

**One defect found and fixed during validation**, in a test fixture rather than the foundation:
`testAnyRequirementSucceedsOnOneSatisfiedBranch` omitted `mirekRange`, so `.colorTemperature`
correctly resolved `.unknown` and the `.any` had no satisfied branch. The resolver was right. Fixed,
plus two companion tests pinning `.any`'s unknown-vs-unsupported distinction.

**Slice 1 has ZERO production consumers.** The live cross-room/cross-bridge routing defect described
in the audit is **NOT fixed** — the foundation that makes fixing it safe is merely ready to wire.
Production routing changes are Slice 2.

**Slice 1 exit gate**

Do not proceed until exact-state/race tests are green and the capability matrix is sufficiently complete to drive the UI honestly.

---

# SLICE 2 — Studio Instrument (Effects + Live + Rooms + Look Browser)

## 11. Slice 2 objective

Land the largest user-visible portion in one coherent slice:

- refined active-room/session navigation;
- look browser;
- Preview Live;
- touch-native control primitives;
- complete Effects instrument;
- complete Live instrument;
- inline Beat;
- full color;
- Stop hierarchy;
- Reset behavior;
- premium interaction/motion/haptics.

This is the primary product slice.

---

## 12. Shared instrument primitives

Extend/reuse current StageKit/Studio primitives rather than building duplicated control families.

Needed primitives may include:

- encoder-style knob with direct drag;
- adaptive fine control;
- vertical level fader;
- stepped encoder/pads;
- contextual exact value readout/entry;
- double-tap single-parameter reset;
- hybrid haptics;
- inline B+ color editor;
- contextual capability/status treatment;
- controlled cinematic focus/reflow transitions.

Do not create multiple unrelated knob/fader implementations for different categories.

> StageKit is at `HueHome/UI/Components/StageKit.swift`; current param rendering is at
> `HueHome/UI/Studio/StudioParamControls.swift` (verified 2026-09-01).

---

## 13. Rolodex/session manager

Implement the binding behavior:

**Resting**

- selected room/zone only;
- full Rolodex hidden until invoked.

**Expanded**

- active rooms first;
- each shows room + running look + tiny live indicator;
- select active room → instant live console switch;
- individual stop available for other active rooms;
- search/find inactive room.

**New room**

Offer:

- Apply Current Look;
- Choose Another Look.

Apply Current Look copies settings once, then target instances become independent.

**Working memory**

Remember per-active-room:

- last editing position;
- meaningful contextual expansions;
- selected Composer domain if applicable later.

Clear temporary expansions when overall session ends.

**Transitions**

Use clean crossfade/replace between structurally different instruments.

> Current Rolodex: `HueHome/UI/Studio/RoomRolodexView.swift` (1066 lines), with
> `RolodexSelectionMachine` / `RolodexKinematics` extracted during Track A (verified 2026-09-01).
> Room picking also touches `HueHome/UI/Studio/RoomPickerSheetView.swift`.

---

## 14. Stop hierarchy

**Stop All**

Always visible, one tap, no confirmation.

Unique shape/placement; visually restrained but unmistakable.

**Selected target Stop**

One-tap contextual stop for the currently selected room/zone.

**Other active target Stop**

Available from expanded session/Rolodex manager.

Pending writes must not land after stop.

---

## 15. Unified look browser

Implement:

- Favorites row;
- Recents row;
- Effects / Live / Composer category entry points.

Favorite interaction:

- subtle visible favorite affordance;
- long-press shortcut.

Look cards:

- restrained visual identity;
- main tap = immediate apply;
- secondary affordance = details/setup.

---

## 16. Per-look setup and Preview Live

Pre-apply setup is small and look-specific.

Do not duplicate the live console.

Preview Live:

- opt-in;
- exact selected target;
- snapshot previous exact running look + live values;
- cancel restores previous look exactly;
- apply commits new look;
- selection changes/generation fences prevent cross-target restore.

Add deterministic preview restore tests.

---

## 17. Effects instrument migration

For every current bridge-native effect:

- use capability matrix/profile to determine visible controls;
- arrange controls intentionally on the invisible grid;
- assign designed hero interaction;
- expose all verified current controls;
- no Advanced bucket;
- inline color B+ where supported;
- CT/warmth honest to hardware/effect;
- control-level partial/staged/unavailable truth;
- exact running-instance state;
- Reset to Defaults;
- current effect updates remain correctly paced/gated/cancelable.

Do not invent unsupported Hue parameters.

---

## 18. Live instrument migration

For Party, Strobe, Thunderstorm, Ambient, and any current main additions:

- reverse-audit all engine reads;
- expose every current user-tunable consumer;
- extract only small contained meaningful literals where explicitly justified;
- no Advanced bucket;
- choose hero/support hierarchy per look;
- inline Beat only where consumed;
- full color B+ where supported;
- transport-specific staging/unavailability shown honestly;
- exact multi-bridge runtime state;
- per-control reset + overall Reset;
- safety clamps preserved.

Do not turn this into a Live-engine redesign.

> The current Live catalog is built by `buildLiveModeCards()` in
> `HueHome/UI/Studio/StudioViewModel.swift`; the four cards are `party`, `strobe`, `thunderstorm`,
> `ambient` (verified 2026-09-01). Engine loops live in `HueHome/Core/Network/UnifiedOrchestrator.swift`.
> Per audit §9, `thunderstorm.ambient_color` is live and must not be removed as a dead control.

---

## 19. Beat in Live

When off:

- show the activation control only.

When enabled:

- natural reflow reveals full supported Beat instrument.

Header shortcut may focus/scroll to this in-page instrument, but must not make a popover the only Studio editing path.

Preserve shared Beat implementation used elsewhere in app.

> `BeatBinding` is at `HueHome/Core/Audio/BeatBinding.swift`; the shared panel is
> `HueHome/UI/Components/BeatPanelView.swift`. No Live card currently declares a Beat `StudioParam` —
> Beat reaches engines via the orchestrator (verified 2026-09-01). Prove per-engine consumption before
> rendering an inline Beat affordance (audit §20).

---

## 20. Studio visual/interaction acceptance

The resting board should feel calm.

Check:

- neutral chassis;
- hero obvious within seconds but not loud;
- negative space intentional;
- direct drag responsive;
- adaptive precision natural;
- contextual value appears/recedes cleanly;
- double-tap reset feels reliable;
- haptics semantic, not noisy;
- cinematic transitions restrained;
- progressive reveal/reflow clear;
- no detached settings/Advanced/color sheets;
- exactly one vertical Studio host scroll;
- status not cluttering main header;
- capability warnings local to affected control.

---

## 21. Slice 2 tests

**Structure**

- one vertical host scroll;
- no customization-path sheet/full-screen cover reintroduction;
- Effects/Live controls reachable;
- full color reachable inline;
- Beat reachable inline where consumed;
- Reset reachable;
- Stop All always present;
- selected room Stop reachable.

**Rolodex/session**

- active rooms first;
- exact room switch;
- last editing position restored per room;
- contextual expansion state restored during session;
- new room copies current settings once;
- instances independent afterward;
- stopped room removed from active list.

**Browser/preview**

- Favorites/Recents;
- immediate apply;
- details/setup;
- Preview Live cancel exact restore;
- target change during preview fenced.

**Controls**

- adaptive drag mapping;
- exact entry;
- double-tap reset;
- formatters;
- accessibility alternatives;
- Reduce Motion.

**Runtime**

- all Live engine tunables consumed;
- all visible firmware effect controls profile-verified;
- transport truth;
- safety ≤3 Hz.

**Slice 2 exit gate**

Do not proceed until all Studio instrument behavior is stable and no known fake/dead control remains.

### Slice 2 status — 2026-09-01: **IMPLEMENTED on `feat/unified-customization-studio-instrument` (PR open, unmerged)**

| Deliverable | Status |
| --- | --- |
| Production truth wiring (§9 invariant) | **Done** — `CustomizationValueScopes` + generation fencing are production-active; card-global `paramValues`, bridge-only `updateStudioParams`, and the global debounce slot are deleted; `runningEffects` is kind-aware (`StudioSelectionKey`); gestures capture `StudioParamSession` identity |
| Shared instrument primitives (§12) | **Done** — StageKnob/StageFader/StageSteppedEncoder + `InstrumentControlMath` (adaptive fine control, semantic ticks, clamps), StageColorEditor (B+ inline), StageBeatSection (BeatPanelView reuse) |
| Per-look boards, no Advanced (§17/§18) | **Done** — `StudioBoardCatalog` descriptor with designed heroes for all 15 cards; `ParamTier.advanced` retired (→ `.support` prominence metadata); profile-driven availability on bridge-native boards; entOnly expanded 3→7 from the engine reverse-audit |
| Rolodex/session manager (§13) | **Done** — PLAYING NOW-first picker with exact per-row Stop, instant active-target console switch (`modeOnRoomChange` policy fn), per-target session working memory, Apply Current Look copy-once |
| Stop hierarchy (§14) | **Done** — always-visible Stop All octagon, header selected-target Stop, session-row Stop; pending writes fenced after every stop |
| Look browser + Preview Live (§15/§16) | **Done, with a recorded spec §16.5 deviation** — Favorites/Recents band (local-first store), card star + long-press, INLINE Details & Setup (no sheet), `PreviewLiveMachine` exact fenced restore through the normal apply path. **Deviation:** §16.5 says "canceling restores the previous running look exactly"; a *fenced* cancel restores **nothing**. If the audition's target changed, was stopped, or was replaced between begin and cancel, `cancelVerdict` returns `.drop` and the machine touches nothing — the world it would restore into has moved on, and a cross-target restore would be worse than no restore. The user is told rather than left guessing: a dropped restore posts `PreviewLiveCopy.restoreDropped` (`7d8d14e`), it is no longer a silent no-op. Navigating away from the browser does **not** cancel: the audition keeps playing on its target and is cancelled or committed explicitly. **Preview Live is also refused outright over a composition with live edits and over a recovered row** (`2200e98`) — there is no exact previous state to snapshot, so an audition would be a restore promise the machine could not keep; a chained audition on a *different* room is refused and names the armed room. `119aa4b` then fixed a stranded deferred audition: it was left behind on every confirmation early return and every non-prompt refusal, which **locked Preview Live out on every other room**; one release helper now runs on every exit. Production-path tests now exist: `StudioPreviewLiveProductionTests` (**19** tests at `2200e98`; **34** at `b06df67`, driving the real `apply()` path against the recording bridge client, no timing waits) landed in `7d8d14e` and grew in `2200e98`; the pre-existing `PreviewLiveTests` (9) exercise the machine only |
| Tests | Slice 1 57 + Slice 2 additions (production wiring 17, profiles 10, control math 14, preview 9, library/session 6, structural/probes updated). The 2026-09-01 remediation, across **five** review rounds, brings `FlashSafetyTests` to **75**, `StudioBoardAvailabilityTests` to **53**, `StudioProductionWiringTests` from 17 to **47**, `StudioPreviewLiveProductionTests` to **34**, `StudioLifecycleSerializationTests` to **7**, plus additions to `CustomizationResolverTests` and `CustomizationIdentityTests` (**31** each by file) — every new production test drives the real `apply()` path against the recording bridge client with no timing waits. Focused runs on `119aa4b`: flash 132/132, colour 107/107, lifecycle 523/523. Full registered suite recorded in DEVLOG |
| Hardware | **NOT run** — master checklist §V-B rows 37–65 |

Guard updates (deliberate, recorded): Guard 12 pins the stronger `bridgeID+roomID` update
signature and the new room-change policy function; the customization suites joined the
no-timing-wait lists. Guard 13's rule was unchanged and its anchors did not move, although the host
file itself (`MixerTrayView.swift`, which holds `StudioCustomizationHost`) was rewritten — the
one-surface rule held across the rewrite. The 2026-09-01 remediation adds Guard 14 (the
realized-frame flash invariant) and Guard 15 (the single board availability funnel), extends
Guard 13(a) to the six new instrument files, and re-hardens two Guard 12 anchors the Slice 2 PR had
loosened (the `updateStudioParams` signature literal is scoped to its body; the room-change rule must
*return* `.decks` on the non-customization branch). The second review round (`2200e98`) hardens them
again: Guard 14's symbol checks are declaration-shaped so a comment can no longer satisfy them, and
it additionally pins a `liveLock` count of ≥ 1 per loop, the helper body shape (no numeric bail-out,
the ledger period), the per-bridge ledger at every call site, `Budget` declared before the loop, and
the rise-gated conditions; Guard 15 gains sub-checks (f)–(j); Guard 12(d) pins the conjunction (an
`||` no longer passes); Guard 13(a) and the global-slot check use anchored comment filters; and a
suite **missing** from the no-timing-wait list now fails instead of being silently skipped. The third
round (`119aa4b`) hardens them once more: Guard 12(d) accepts either operand order and cannot be
satisfied from a trailing comment; Guard 13 anchors its comment filters and counts both `ScrollView`
spellings; Guard 14 gains sub-check **(h)**, pinning the emit helper and the ledger shape and banning
any numeric hold bail-out in either spelling; Guard 15 gains **(h)**, **(c)** and **(k)** — the editor
floor is scoped to the `StageColorEditor` call, its filter is anchored, and the funnel's answers
(disabled, opacity, note) must be applied in **all three** renderers. The matrix generator gains
`verify_send_path`: every bridge-native "code-proven" citation is verified against the
`performBridgeSend` body. The fourth round (`14a0cac`) pins commit-after-send, the `Bool` return and the
luminance symbols in Guard 14, anchors Guard 13(c), and pins non-shadowed funnel bindings in Guard 15(k);
the fifth round (`b06df67`) adds no-exit-between-send-and-commit, `commit(at: CACurrentMediaTime())` and
the restore-on-drop / silence-clock declarations to Guard 14, counts `.send(channels:` as a direct send,
pins read → stop → read **order** in Guard 12(b), fails a bare-literal binding in Guard 15(k), bans
`.popover(` in Guard 13(a), and makes the generator's `verify_send_path` require a non-nil assignment to
the payload symbol rather than a read of the key. Every sub-check mutation-tested on a scratch copy.

Capability-matrix wording: the generated matrix reports four separate figures, never one score —
**code-proven send path 57 / 68**, **no code-proven send path (hardware-pending evidence)
11 / 68**, **pending 0 / 68**, and **23 / 68 code-proven rows that still owe a hardware behaviour
check** (`base_color` ×9, `speed` ×11, `warmth` ×3; a subset of the 57, not a fourth bucket).
Code-proven means the write provably leaves the app. 68 is the catalog size. Nothing in this plan
may be read as "68/68 proven" — audit §7 still owes physical evidence. `--check` verifies every
citation, strips comments before matching, fails on any uncited or drifting loop read, and
cross-checks each row's evidence class and the pending-hardware list against
`EffectParameterProfiles.swift`; `--refresh-citations` re-finds the line numbers.

**Accepted debt carried into Slice 3 (recorded, not fixed here)**

- **Warmth authoring range is not snapshot-driven.** Availability is snapshot-honest (the
  `mirek_schema` intersection; a schemaless CT light resolves unknown, never a fake clamp), but the
  knob's range is still the catalog's `153...500` for all four Warmth params (grep
  `kind: .slider(min: 153, max: 500)` in `StudioViewModel.swift`) and the board's slider control
  reads its range from `param.kind` in its own `range` computed property (`StudioBoardView.swift`),
  not from the snapshot's `MirekRange`. On a narrower fixture the knob travels further than the
  device can go. The *availability* half of the app-driven warmth gap was closed in `2200e98`
  (app-driven warmth now requires `colorTemperature` instead of resolving `.none`); the authoring
  range was not. Owner: Slice 3. Checklist row: §V-B 58.
- `EffectEngine.swift`'s dead loops still declare unsafe ranges (no production caller; delete in
  Slice 3).
- `EFFECT_PROFILES` / `profile(effect:paramID:)` are keyed by paramID only.
- `targetSnapshot` hardcodes `entertainmentAvailable: .unknown`.
- Deck `effectCoverage` is still card-keyed; the `""` vs `"legacy"` bridge-key sentinel split
  remains.

---

# SLICE 3 — Composer Convergence + Cleanup + Final Hardening

## 22. Slice 3 objective

Bring Composer fully into the same instrument family while preserving its semantic editor/runtime model, then perform cleanup, accessibility, full regression, and device-validation documentation.

---

## 23. Composer convergence

Composer retains:

- layer selector;
- Palette;
- Motion;
- Brightness / Envelope;
- React;
- current context gating;
- harmony;
- spatial controls;
- color/My Colors;
- beat/reaction controls;
- Save;
- Revert;
- Perform;
- Stop;
- bridge save/export where valid;
- transport/degradation honesty.

Allowed UX convergence:

- same neutral chassis;
- same grid rhythm;
- same knobs/faders/pads where semantics match;
- same direct manipulation/adaptive precision;
- same contextual values;
- same haptics;
- same controlled motion;
- same inline color language;
- compact horizontal domain switcher when needed for density;
- same room/session navigation.

Do not flatten Composer into generic StudioParam/string-key control ownership.

Do not activate an inert Composer 2 runtime foundation unless newer binding architecture explicitly authorizes it.

---

## 24. Composer active-session memory

Per active room/composition, remember during the active session:

- current domain;
- scroll/working position as applicable;
- meaningful expanded contextual instruments;
- current layer selection where current product semantics allow.

When the overall session ends, temporary view expansions reset cleanly.

---

## 25. Legacy presentation cleanup

Search current production call sites for old detached customization surfaces/components.

Delete only when proven unused and without future binding role.

If a shared component still has a legitimate non-Studio owner, keep it.

Update guards/comments/tests to describe current reality.

Avoid unnecessary file rename / Xcode project churn unless materially required.

---

## 26. Keyboard, accessibility, and motion hardening

Verify all categories:

- exact numeric keyboard entry;
- keyboard does not collapse host or redirect room selection;
- VoiceOver labels/values/availability reasons;
- accessible reset alternatives;
- Stop All vs selected Stop clarity;
- Dynamic Type;
- accessibility sizes;
- switch/keyboard focus where available;
- Reduce Motion static equivalents;
- no safety signal by color alone.

---

## 27. Full race regression

Run deterministic tests for every critical race:

- capability load vs room scrub;
- draft vs room switch;
- debounce vs Stop;
- debounce vs Reset;
- old card vs replacement;
- same-card multi-bridge independence;
- Preview Live cancel/restore;
- transport changes — **transport fallback and Entertainment session loss are wired through
  `studioRuntimeEventHandler` (`7d8d14e`)**: the orchestrator seam tells the view
  model, so the running row and the resolver's transport stop disagreeing after an ENT→REST
  failover or a lost session;
- room deletion;
- bridge reconnect — **not wired by design, not proven by test**: SSE reconnect and capability
  refresh deliberately do not rekey, because they leave the running instance's identity unchanged
  (same bridge, group, kind, card, generation); only transport fallback and session loss change what
  the identity means. The ownership argument is recorded at the `UnifiedOrchestrator` seam and in the
  `bump()` doc comment of `HueHome/Core/CustomizationIdentity.swift` (`7d8d14e`), which lists only
  the reasons production actually bumps: `.cardReplaced`, `.stopped`, `.reset`, `.transportChanged`.
  **No test proves the argument** — it is an ownership argument about code, and membership staleness
  is recorded there as an accepted gap in it (`2200e98`). Hardware §V-B rows **59** and **63** remain
  **UNPROVEN** and are what would actually settle it;
- recovered composition with no live box.

---

## 28. Performance/network review

Fresh-review for:

- body-triggered fetches;
- duplicate state stores;
- repeated expensive observable recreation;
- unpaced per-light writes;
- direct high-frequency REST animation;
- extra SSE;
- unsafe primary client routing;
- cancellation holes;
- per-frame decode/network work.

Fix findings before final PR.

---

## 29. Hardware checklist

Append/update a named block in the master on-device checklist covering:

- build/commit;
- bridge firmware;
- representative light firmware/models;
- room/zone and Entertainment Area;
- all visual/interaction acceptance;
- Rolodex/session behavior;
- Favorites/Recents/browser/Preview Live;
- each Effect control;
- each Live control;
- Beat;
- same-card multi-bridge independence;
- pending-write races;
- Composer domains/actions;
- safety;
- reconnect/background/foreground.

Do not claim unrun physical validation.

> The checklist file is `docs/ios/master-on-device-checklist.md`. Its §V-A Track A block is still marked
> **UNPROVEN / zero hardware rows executed** as of 2026-09-01 — the new block should be added without
> disturbing that outstanding debt. The Slice 2 block is §V-B, rows 37–65; the reconnect /
> background-foreground / room-deletion / transport-loss cases required by audit §27 are rows
> 59–64, and the Warmth range debt above is row 58. All of them are **UNPROVEN**.

---

## 30. Test/guard gates

During development:

- focused relevant tests before each implementation commit;
- `git diff --check`.

Before final PR:

- current hardening guard script;
- full registered test suite using the current repo-supported simulator destination;
- repeat full suite if current DEVLOG convention requires it;
- verify `.xcresult` rather than trusting piped output;
- `git diff --check`;
- no tests and commit chained in a way that obscures results.

Do not assume an old test script/destination is valid without verifying current repo conventions.

> **Verified 2026-09-01 — scheme name.** The iOS scheme is **`HueHome 1`**, not `HueHome`.
> **Correction (Slice 2, 2026-09-01):** `run_tests.sh` now targets the correct scheme and resolves a
> deterministic destination (preferred model at the highest installed OS; `CHROMAGLOW_TEST_UDID` /
> `CHROMAGLOW_TEST_MODEL` overrides). A bare `name=iPhone 17 Pro` destination is ambiguous — several
> simulators share the name across OS runtimes — so invoke xcodebuild with an exact `id=`:
>
> ```bash
> xcodebuild test -project HueHome.xcodeproj -scheme "HueHome 1" \
>   -destination "platform=iOS Simulator,id=<udid from run_tests.sh discovery or simctl>"
> ```
>
> Also per repo convention: bump `CURRENT_PROJECT_VERSION` across all 12 `project.pbxproj` entries for
> each device-test round.

---

## 31. Suggested commit boundaries inside the three large slices

The feature remains one branch / one PR, but commits should preserve review/rollback semantics.

**Slice 1**

- `docs(studio): refresh customization capability evidence`
- `fix(studio): key customization state to exact running targets`
- `refactor(studio): add pure customization capability resolution`

**Slice 2**

- `feat(studio): add shared touch instrument controls`
- `feat(studio): refine active-room session and look browser`
- `feat(studio): bring Effects into the Studio instrument`
- `feat(studio): bring Live modes and Beat into the Studio instrument`

**Slice 3**

- `refactor(composer): converge on Studio instrument language`
- `chore(studio): retire obsolete customization presentation paths`
- `test(studio): harden unified customization instrument`

Collapse/expand naturally if current code topology makes another split safer, but keep the three large product slices intact.

---

## 32. Collision-hotspot discipline

Treat the current equivalents of these as high-risk/collision files:

- Studio root view;
- Studio view model;
- unified orchestrator/runtime owner;
- large Composer editor/runtime files.

Prefer pure/small files for:

- presentation descriptors;
- capability resolver;
- instrument primitives;
- exact runtime/live-state adapter;
- look-browser/session state.

Do not edit a giant file simply because it is nearby.

Parallelize read-only audit freely; do not have multiple write agents editing the same hotspots simultaneously.

> **Measured hotspots (verified 2026-09-01):**
> `HueHome/UI/Studio/StudioViewModel.swift` 4085 lines ·
> `HueHome/UI/Studio/StudioView.swift` 3145 lines ·
> `HueHome/UI/Studio/RoomRolodexView.swift` 1066 lines ·
> `HueHome/UI/Composer/ComposerLayerSheet.swift` 759 lines ·
> `HueHome/UI/Composer/CompositionEditorPanel.swift` 740 lines ·
> `HueHome/UI/Studio/MixerTrayView.swift` 646 lines.
> `HueHome/Core/Network/UnifiedOrchestrator.swift` exceeds 8,200 lines and is the highest-risk file in
> this initiative.

---

## 33. Suggested read-only audit fan-out

**Agent A — firmware Effects**

Audit:

- effect catalog;
- v2/legacy routing;
- capability models;
- request bodies;
- parameter profiles;
- hardware docs/evidence.

**Agent B — Live engines**

Audit:

- every engine loop;
- parameter reads;
- Beat consumption;
- safety;
- meaningful hardcoded literals.

**Agent C — UI/interaction**

Audit:

- current host;
- StageKit;
- parameter renderer;
- Composer editor;
- Rolodex;
- browser/navigation;
- one-scroll guard;
- keyboard/accessibility;
- current busy-header sources.

**Agent D — state/tests/races**

Audit:

- exact identity keys;
- runtime ownership;
- mailboxes/cancellation;
- persistence;
- capability race seams;
- structural tests;
- hardening guards.

Reconcile evidence before write agents begin.

---

## 34. Mandatory self-review before PR

Perform a fresh review as though you did not write the code.

**Capability**

- any engine-readable user knob hidden?
- any visible control without consumer?
- any unverified generic Hue field exposed?

**Identity**

- any new bare room-ID keyed dictionaries?
- live values accidentally card-global?
- same card on two bridges independent?
- drafts/preview fenced?

**UX**

- any Advanced section returned?
- any detached settings/color sheet?
- more than one vertical Studio scroll?
- neutral chassis still calm?
- hero hierarchy intentional?
- full capability reachable?
- Rolodex active-room workflow intact?
- Stop All always visible?

**Transport**

- staged controls falsely look active?
- partial coverage explicit?
- unknown mislabeled unsupported?

**Network**

- unpaced per-light writes?
- body fetch?
- stale debounce after Stop/Reset?

**Safety**

- any path above 3 Hz?
- exact entry bypass?
- beat bypass?
- missing disclosure?

**Tests**

- every risky behavior has targeted proof?
- any sleeps standing in for deterministic state?
- any guard weakened merely to get green?

Fix findings before PR.

---

## 35. Final definition of done

**Functional**

- one Studio instrument language across Effects, Live, Composer;
- no Advanced concept;
- all verified Effect controls reachable;
- all verified Live controls reachable;
- all current Composer controls remain reachable;
- color B+ full editor inline where supported;
- Beat inline where consumed;
- per-control reset + Effects/Live overall Reset;
- Composer Revert preserved;
- Favorites + Recents look browser;
- per-look setup;
- reversible Preview Live;
- refined Rolodex active-room management;
- exact same-card multi-bridge independence;
- always-visible Stop All;
- selected-room and other-room Stop behavior;
- capability/transport honesty;
- no dead controls;
- no safety weakening;
- no high-frequency REST animation;
- tests/guards green.

**Visual/interaction**

- premium neutral chassis;
- controlled cinematic motion;
- disciplined invisible grid;
- intentional hero per look;
- direct manipulation;
- adaptive fine control passes device feel test;
- contextual precision;
- restrained semantic haptics;
- progressive reveal/natural reflow;
- intentional negative space;
- status does not crowd main board.

**Honesty**

For every control/look/room the UI can answer what changes, where, now vs staged, coverage, limitations, restore/reset, and stop scope without API jargon.

---

## 36. DEVLOG requirements

Append a dated agent entry including:

- branch;
- starting main SHA;
- checkpoint tag;
- source audit;
- stale assumptions corrected;
- Composer 2 current status;
- capability counts;
- architecture chosen;
- files touched;
- commit list;
- focused/full tests;
- guard/diff results;
- hardware pending rows;
- unverified Hue combinations intentionally not exposed;
- rollback information.

Do not claim all Hue parameters unless the matrix proves it.

---

## 37. PR requirements

Open one PR against current main.

Do not merge.

Suggested title:

```
feat(studio): build unified customization instrument
```

PR body sections:

- Problem
- Product/UX contract
- Current-main audit / stale assumptions corrected
- Architecture
- Capability matrix
- Slice 1 — Truth Foundation
- Slice 2 — Studio Instrument
- Slice 3 — Composer Convergence + Hardening
- Tests
- Hardware validation status
- Risks
- Rollback
- Known intentionally deferred engine-expansion ideas

State simulator/unit validation vs physical Hue validation accurately.

---

## 38. Final completion report

Report:

**Identity**

- branch
- base SHA
- head SHA
- checkpoint

**What shipped**

- exact state/capability foundation
- Rolodex/session manager
- look browser
- Preview Live
- shared instrument controls
- Effects
- Live
- Beat
- Composer convergence
- color
- reset/revert
- Stop hierarchy
- cleanup

**Capability totals**

For each Effect/Live card:

- visible controls;
- active/partial/staged/unavailable notes;
- unverified controls intentionally withheld.

**Tests**

- focused suites
- full suite
- pass/fail/skipped
- guards
- diff check

**Hardware**

- exact pending/completed checklist rows

**Files changed**

**Genuine deferred work**

Only intentional future engine expansion, not unfinished requirements from this plan.

**PR**

- URL
- do not merge until explicit approval.
