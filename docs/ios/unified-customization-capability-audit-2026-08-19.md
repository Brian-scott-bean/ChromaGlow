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

> **Verified 2026-09-01.** All five non-Beat controls present (card id `strobe`). Three carry
> `entOnly: true` today — `speed`, `flash_color`, `duty_cycle` — which is the current encoding of the
> historical “Streaming-only” claim. See §17 and spec §2.3 on why this binary flag is insufficient.

Safety:

- free-running and beat-locked output must remain ≤3 Hz;
- exact typed values may not bypass clamp;
- UI range/formatter should reflect the real safe range.

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

> **Verified 2026-09-01.** All eight controls are present in the current catalog (card id
> `thunderstorm`). `ambient_color` has a confirmed live production consumer at
> `HueHome/Core/Network/UnifiedOrchestrator.swift:8219` and `:8239`
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

> **Current encoding (verified 2026-09-01).** Today this is a single boolean, `StudioParam.entOnly`
> (declared `HueHome/UI/Studio/StudioViewModel.swift:86`, consumed
> `HueHome/UI/Studio/StudioParamControls.swift:119`), set on `strobe.speed`, `strobe.flash_color`, and
> `strobe.duty_cycle`. This is exactly the binary requirement the execution plan §8 replaces.

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
