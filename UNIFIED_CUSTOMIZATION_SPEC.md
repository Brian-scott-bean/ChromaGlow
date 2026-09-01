# ChromaGlow Unified Customization Engine & Studio Instrument

**Status:** Binding product/UX source of truth
**Revision:** 2026-09-01
**Compatibility filename:** retained as `UNIFIED_CUSTOMIZATION_SPEC.md` for the implementation handoff
**Scope:** iOS Studio — Effects, Live, Composer, active-room navigation, look browser, and customization interactions

This document supersedes older Track A/Track B product/UX assumptions where they conflict with the decisions below. Older CNVS planning packets remain historical engineering evidence only. Current repository code and newer binding architecture records win on implementation details; this document wins on the product/UX behavior it explicitly defines.

> **Current-main verification — 2026-09-01.** Verified against `main` @ `8572b92` (local `main` == `origin/main`).
> Only file/architecture references were corrected in this revision; no product/UX decision in this document was altered.
> One deliberate divergence from current code is recorded in §2.3 — see the note there.

---

## 1. Mission

Build one capability-driven customization system for every running ChromaGlow look.

Effects, Live, and Composer must share one interaction language and one premium ChromaGlow instrument grammar while retaining their actual domain models, runtime behavior, transport constraints, and hardware limits.

The system must derive what the user can manipulate from:

> exact running identity + selected target + actual runtime + active transport + verified capabilities.

Composer remains the richest editing environment. Effects and Live expose every meaningful capability their real runtimes can consume and nothing they cannot.

A visible control must be able to answer:

- What does it change?
- Which exact running instance receives the change?
- Which lights are affected?
- Which transport/runtime implements the change?
- Is it active now, partial, staged, unavailable, or irrelevant?
- Is the change immediate, debounced, next-start, reapply, or restart?
- How does it behave across room changes, stop, reset, replacement, and persistence?

No visible control may exist without a tested mutation contract.

The user should perceive one instrument with different depths:

- Effects = focused
- Live = reactive
- Composer = complete

---

## 2. Binding product principles

### 2.1 Instrument first

The customization surface is not a settings screen.

It is a touch-native creative instrument inspired by the logic of a professional sound board / lighting console, without literally reproducing physical hardware.

The interface should feel:

- intentional;
- artistic;
- sophisticated;
- fluid;
- premium;
- calm at rest;
- expressive on contact;
- easy to understand without reading paragraphs of instructions.

### 2.2 Neutral chassis, directed focus

The console remains visually restrained and predominantly neutral.

Individual Effects, Live modes, and Composer layers do not theme the entire interface.

Personality comes from the thing being manipulated — color, motion, beat, waveform, spatial behavior, intensity, active state — rather than decorative chrome.

The resting board is quiet. The active instrument gets the attention.

Use:

- dark, controlled StageKit surfaces;
- limited accent color;
- strong typography;
- deliberate negative space;
- subtle depth;
- local color where semantically meaningful;
- restrained motion.

Avoid:

- persistent saturated backgrounds;
- decorative full-page gradients tied to each effect;
- excessive glow;
- multiple competing accents;
- visual noise for the sake of filling space.

### 2.3 Full capability underneath, curated attention on top

Visual simplicity must never remove real capability.

Every verified user-meaningful capability remains reachable from the continuous customization environment.

The interface controls attention using:

- hierarchy;
- scale;
- placement;
- progressive reveal;
- context-dependent prominence;
- natural reflow;
- temporary interaction focus.

There is no “Advanced” product concept for Studio customization.

A less-frequently-used parameter may be visually quieter, but it must not be arbitrarily buried because it is “advanced.”

> **Deliberate divergence from current code (recorded 2026-09-01, not a correction).**
> Current `main` still models an Advanced bucket: `StudioParam.ParamTier` declares `case advanced`
> (`HueHome/UI/Studio/StudioViewModel.swift:92`, commented “Advanced section of param sheet”), and it is
> applied today to `party.min_brightness`, `strobe.min_brightness`, `strobe.duty_cycle`,
> `thunderstorm.min_brightness`, `thunderstorm.strike_rate`, `thunderstorm.flash_length`, and
> `thunderstorm.afterglow`.
> This section intentionally overrides that behavior. The `.advanced` tier is expected to be retired or
> repurposed during implementation; it is recorded here as a known product change, **not** as a stale
> reference to be edited away.

### 2.4 Parity means one language, not equal density

Effects, Live, and Composer do not need the same number of controls or identical layouts.

They share:

- interaction primitives;
- typography;
- spacing/grid rhythm;
- value behavior;
- color behavior;
- haptic behavior;
- availability language;
- accessibility behavior;
- motion language;
- exact-target honesty.

Their composition may differ based on what the look actually does.

### 2.5 Editing must not interrupt playback

Opening customization, scrolling, expanding a color editor, enabling a contextual section, changing rooms, or switching domains must not restart the running look.

Only a parameter that technically requires reapply/restart may do so, and only after the audit proves there is no live mutation path. The UI must state the behavior honestly.

---

## 3. Core visual composition model

### 3.1 Disciplined invisible grid

The board uses a consistent invisible grid for:

- alignment;
- spacing;
- touch rhythm;
- visual balance;
- predictable margins;
- consistent relationship between controls.

Individual looks may arrange controls differently, but the composition must never feel arbitrary.

### 3.2 Hero control

Each Effect or Live mode has an intentionally chosen hero interaction at rest.

The hero is chosen by design based on the core character of the look, not automatically by frequency of use.

Examples of the design logic:

- Candle might emphasize flame character / color-warmth behavior.
- Party might emphasize color-energy-rhythm.
- Strobe might emphasize pulse timing/intensity.
- A microphone-reactive mode might emphasize live input/sensitivity.

The hero is only subtly more prominent at rest.

When the user touches any other control, that control temporarily becomes the focal point. The board settles back to its designed hierarchy after interaction.

### 3.3 Negative space is intentional

Do not fill every region because screen area exists.

If a look has six meaningful controls, the board may contain six controls with generous breathing room rather than twelve tiles.

### 3.4 Functional motion, not decoration

Motion should communicate behavior.

Examples:

- increasing flicker rate may accelerate the visual representation;
- changing smoothness may visibly smooth the representation;
- beat division changes cadence;
- spread widens spatial representation;
- direction rotates directional motion;
- envelope edits change its visual curve.

All such behavior must honor Reduce Motion.

---

## 4. Control vocabulary

Do not standardize every parameter onto a horizontal slider.

Choose the interaction primitive according to parameter semantics and expected manipulation.

| Parameter concept | Preferred primitive |
| --- | --- |
| Brightness / level / intensity | Vertical fader when space/importance warrants; otherwise level-appropriate touch control |
| Minimum brightness / floor | Smaller fader or compact continuous control |
| Speed / rate | Rotary encoder-style knob |
| Sensitivity | Rotary encoder-style knob |
| Smoothness | Rotary encoder-style knob |
| Warmth / temperature | Temperature-aware knob/arc or other clear continuous control |
| Flash intensity | Level/fader |
| Duty cycle | Knob or compact continuous control |
| Beat division | Performance pads / compact discrete selector |
| Beat on/off | Illuminated/tactile toggle control |
| Tap tempo | Large, obvious TAP performance target |
| Phase / timing offset | Centered/bipolar knob where appropriate |
| Color | Compact swatches/current color → inline expandable full editor |
| Direction | Direction dial / compass-like control where spatial semantics apply |
| Spread | Knob |
| Count / heads / density | Stepped encoder or discrete selector |
| Pattern / mode | Pads for prominent choices; segmented/chips for quieter choices |
| Boolean behavior | Illuminated console button/toggle |
| Genuine two-variable control | XY surface |
| Envelope | Interactive visual envelope where supported |

The table is a design starting point, not a mandate to use a primitive where testing proves another touch interaction works better.

---

## 5. Continuous control interactions

### 5.1 Direct manipulation

Touch a knob or fader and the same gesture begins adjustment immediately.

No tap-to-select step is required.

### 5.2 Adaptive fine control

Continuous controls support adaptive precision if testing confirms the gesture feels natural and predictable.

Baseline behavior:

- drag near the control = normal/coarse response;
- move farther away during the same gesture = progressively finer adjustment;
- move closer again = normal sensitivity returns;
- no separate mode switch;
- value and haptic feedback remain synchronized.

This behavior must not ship if it feels unpredictable in physical-device testing.

### 5.3 Contextual precision

Exact numeric values are not permanently shown when doing so creates visual noise.

At rest, a control may show only its visual state and label.

On touch/adjustment:

- the exact value appears immediately;
- remains prominent while manipulating;
- recedes after interaction ends.

### 5.4 Exact entry

Support both:

- tap the contextual value while the control is active;
- long-press the knob/fader as a secondary shortcut.

Exact entry must clamp correctly and remain bound to the exact target captured when editing began.

### 5.5 Individual reset

Double-tap a continuous control to reset that parameter only to its default.

Also provide an accessible explicit action for VoiceOver and non-gesture interaction.

Double-tap is reserved for single-control reset; long-press is reserved for exact entry/help only where semantics remain unambiguous.

---

## 6. Haptics

Use hybrid haptics.

Continuous movement should remain mostly smooth.

Provide tactile feedback at meaningful semantic points such as:

- default snap;
- minimum/maximum;
- discrete steps;
- beat divisions;
- mode changes;
- individual reset;
- Stop All.

Do not produce constant buzzing during ordinary continuous adjustment.

---

## 7. Color interaction — compact first, full power inline

Use the B+ model.

At rest, a color-capable control shows:

- current color representation;
- compact saved/recent swatches where meaningful;
- a clear way to open precision editing.

Behavior:

- tapping a swatch applies it immediately;
- tapping the current color / edit affordance expands the full color editor inline inside the same board;
- full hue/saturation editing is available;
- My Colors / saved colors are available where meaningful;
- there is no Apply/Done step for the live console;
- expansion remains within the one vertical host surface;
- no detached color sheet;
- expansion may remain open for that room’s active working session.

The full editor must use honest target color capability/gamut context. Do not hardcode a single gamut for mixed/unknown targets.

---

## 8. Progressive reveal and natural reflow

When a feature is off, show only what is needed to understand and activate it.

Example:

```
BEAT SYNC ○
```

When enabled, related controls such as division, phase, Tap, Auto, and Resync reveal smoothly.

The board uses natural reflow:

- surrounding controls glide into new positions;
- additional controls become part of the board;
- no overlay popup;
- no temporary floating panel;
- no nested settings sheet.

The user should perceive the physical console reconfiguring itself.

---

## 9. Discrete controls

Use a hybrid strategy.

- prominent/performance decisions may use larger tactile pads;
- quieter secondary decisions may use compact segmented controls/chips;
- once a primitive is selected for a semantic class, reuse it consistently.

Do not choose a control style solely for visual symmetry.

---

## 10. Help and descriptions

The interface should explain itself visually first.

Use labels as quiet reinforcement rather than paragraphs of permanent instruction.

Most controls should have no help chrome.

For unfamiliar, capability-limited, or unusually complex controls, use contextual help only where needed through:

- subtle info affordance;
- accessibility description;
- long-press explanation only where it does not conflict with exact-entry semantics;
- local status copy when hardware/transport affects truthfulness.

Avoid generic explanatory text beneath every control.

---

## 11. Motion language

Use controlled, cinematic motion.

Transitions should be:

- short;
- polished;
- restrained;
- non-bouncy;
- purposeful;
- hierarchy-preserving.

Use animation to explain continuity, focus, reveal, reflow, and state changes.

Do not use playful springiness as the default visual personality.

---

## 12. Main layout behavior

### 12.1 Effects and Live

Prefer one continuous vertical instrument whenever practical.

There is exactly one vertical host scroll surface.

No nested vertical lists or detached Advanced/settings sheets.

### 12.2 Composer

Composer remains one cohesive editing environment but may use a compact horizontal domain switcher for dense domains such as:

- Palette;
- Motion;
- Brightness / Envelope;
- React.

This is not navigation into separate settings screens. It is moving across domains of the same instrument.

Composer keeps its full domain model and control gating.

---

## 13. Header / identity / status

The primary header must become quieter than the historically busy top row.

The running identity itself may be interactive, e.g. conceptually:

```
PARTY · LIVING ROOM ›
```

Secondary operational/context information can expand from that identity rather than permanently occupying the header.

Keep status mostly behind the tappable identity/header.

Surface status directly beside a control only when it materially changes what that control can do.

Examples that warrant local visibility:

- partial hardware coverage;
- Streaming-only behavior while in Room mode;
- unknown capability;
- staged-for-next-mode behavior;
- unavailable hardware support.

Technical API terminology must not be required for comprehension.

---

## 14. Active rooms, zones, and the Rolodex

The Rolodex remains a core Studio concept.

Its purpose is not just target selection before launch. It is navigation among independent active lighting instruments.

### 14.1 Resting state

Normally show only the selected room/zone in a restrained form.

The full Rolodex is not permanently visible.

Tap/swipe the room identity to expand it.

### 14.2 Expanded state

Show active rooms first.

Each active entry shows, at minimum:

- room/zone name;
- running look name;
- tiny live status indicator.

Then provide an obvious path to search/find another room or zone.

Do not turn this surface into a dashboard full of controls.

### 14.3 Selecting an active room

Tapping an active room switches immediately to that room’s real live controls and values.

- No preview step.
- No restart.
- No confirmation.

### 14.4 Room-specific working memory

Each active room remembers its own last editing position and meaningful expanded working state during the active session.

Examples:

- scroll position;
- Beat section expanded;
- color editor expanded;
- current Composer domain.

When the overall session ends, temporary editing expansions reset so a future session starts clean.

### 14.5 Structurally different instruments

When switching between substantially different surfaces (e.g. Party ↔ Composer), use a clean crossfade/replace transition rather than morphing every control between incompatible layouts.

### 14.6 Adding another room

When selecting a new inactive room, offer a fast path to:

- Apply Current Look; or
- Choose Another Look.

Applying the current look copies the current live settings once as the starting state.

After launch, the new room is independent.

No implicit linking between rooms.

### 14.7 Same look on multiple rooms/bridges

Two rooms may run the same card with different values.

Selecting either room must show and edit that room’s actual running instance.

Edits never cross bridge/room identity unless the user explicitly performs a multi-target action that is separately designed and authorized.

---

## 15. Stop hierarchy

There are three stop scopes.

### 15.1 Stop All — master/world cancellation

Stop All is always visible.

It immediately stops every ChromaGlow-managed running look in the active session.

Requirements:

- one tap;
- no confirmation dialog;
- visually quiet by default;
- unique shape and/or placement so it is instantly recognizable;
- enough separation from high-frequency controls to make accidental taps unlikely;
- meaningful haptic feedback.

Safety comes from placement/shape, not confirmation friction.

### 15.2 Selected room/zone Stop

When a room/zone is selected and has a running look, a contextual one-tap Stop for that selected target is available.

It must not stop other active rooms.

### 15.3 Stop another active room

The expanded Rolodex/session manager may expose a stop action for each other active room without requiring the user to first navigate its full console.

After an individual room is stopped, it leaves the active section immediately and returns to the normal searchable room list.

---

## 16. Changing looks / unified look browser

Changing the running look happens after selecting a room, not directly from the Rolodex row.

The look browser uses a hybrid structure:

- compact Favorites;
- compact Recents;
- clear category entry points for Effects, Live, and Composer.

### 16.1 Favorites

Support both:

- subtle visible favorite affordance;
- long-press shortcut to add/remove favorite.

### 16.2 Look cards

Use restrained visual cards:

- enough visual identity to be inviting and recognizable;
- name/category secondary;
- no noisy artwork wall;
- consistent neutral chassis.

### 16.3 Apply vs details

Use hybrid card behavior:

- tap main card → apply immediately using last-used/default settings;
- secondary affordance → open preview/details/setup before applying.

### 16.4 Pre-apply setup

Pre-apply setup is lightweight and look-specific.

Each look may expose a small intentional set of choices that genuinely matter before launch.

Do not duplicate the full live console.

### 16.5 Preview Live

Pre-apply setup supports optional Preview Live.

Default setup is non-live.

If Preview Live is activated:

- audition on the exact selected room;
- preserve the previous running look and its exact live settings;
- canceling Preview Live restores the previous running look exactly;
- accepting/applying commits the new look;
- preview state must be exact-target and race-safe.

---

## 17. Capability honesty

A visible control resolves to exactly one availability state:

- **Active** — changing it affects the selected running look now.
- **Partial** — known subset responds; coverage is stated.
- **Staged** — editable/saved but intentionally not affecting current output; reason/remediation shown.
- **Unavailable** — concept applies but hardware/transport cannot currently honor it; reason/remediation shown.
- **Hidden** — irrelevant in the current context and should not render.

Unknown capability must not be silently converted into unsupported.

A slider/knob that moves while silently doing nothing is a defect.

---

## 18. Required state model

Keep three concepts separate.

### 18.1 Persistent defaults

“What should this card use the next time I start it?”

May remain per card where existing product behavior expects last-used defaults.

### 18.2 Live running-instance values

“What is this exact bridge + room/zone + running look using now?”

Must be keyed to exact running identity.

### 18.3 Draft interaction values

“What is the user currently dragging/typing before commit?”

Ephemeral and owned by the exact customization session that began the gesture.

A draft started on Room A must never commit to Room B if selection changes mid-gesture.

---

## 19. Running identity contract

Every mutation begins with a captured exact running identity and must still be valid at commit/send time.

Identity must distinguish, as applicable:

- bridge ID;
- room/zone ID;
- room/zone kind;
- running card/composition identity;
- runtime strategy;
- generation/version used to fence stale asynchronous work.

Never reintroduce room-ID-only ownership in a multi-bridge path.

---

## 20. Composer contract

Composer is not flattened into StudioParam or string-key generic sliders.

Composer retains its semantic editing model, including current supported behavior for:

- layer selection;
- Palette;
- Motion;
- Brightness / Envelope;
- React;
- harmony;
- spatial controls;
- beat/reaction behavior;
- saved colors / color editing;
- Save;
- Perform;
- Revert;
- bridge save/export where valid;
- transport/degradation honesty.

The unified work aligns interaction/presentation grammar and capability seams, not Composer runtime ownership unless a newer binding repository decision explicitly authorizes it.

Recovered/bridge-stored compositions that lack a live runtime box remain read-only/summary rather than showing fake editable controls.

---

## 21. Beat contract

One Beat implementation remains app-wide.

For any Live engine that genuinely consumes `BeatBinding`, full Beat controls must be reachable inline in the continuous customization surface.

When Beat is off, show only the activation control. Enabling Beat progressively reveals the relevant controls.

Potential supported behavior includes the existing shared vocabulary such as:

- Off;
- beat division;
- phase/timing offset;
- Tap;
- Auto;
- Resync;
- BPM where appropriate.

Do not show Beat for an engine that does not consume it.

Flash-class beat behavior must remain under the existing ≤3 Hz safety ceiling.

---

## 22. Reset / Revert

### Effects / Live

Provide a reachable overall Reset to Defaults behavior for the selected running instance/card.

Reset must:

- invalidate older pending writes;
- reset only the exact selected running instance;
- update persistent last-used default state appropriately;
- not mutate another room/bridge running the same card;
- not resurrect stale debounced writes.

### Composer

Keep Revert to Saved semantics for saved compositions.

Do not rename it Reset to Defaults when that would misrepresent the operation.

---

## 23. Color and temperature honesty

Color and Warmth/CT controls are capability-aware.

Requirements:

- no color-capable targets → no active color editor;
- one known gamut → author/clamp honestly;
- mixed gamuts → use existing common-safe intent/per-target output rule if available;
- unknown capability → expose uncertainty rather than fake precision;
- CT uses actual mirek ranges where available;
- mixed CT ranges clamp safely;
- partial support shows coverage;
- no Warmth control where the current effect/runtime cannot meaningfully consume it.

Do not treat CT as arbitrary tint.

---

## 24. Safety invariants

The ≤3 Hz flash safety ceiling remains non-negotiable.

No exact typed value, adaptive drag, beat lock, “expert” interaction, or transport change may bypass runtime safety.

Existing photosensitivity disclosure paths remain intact.

Do not expose internal safety/transport/network constants as user controls.

---

## 25. Accessibility

Every new or moved control must support appropriate behavior for:

- VoiceOver label;
- current value;
- selected traits;
- disabled/staged/unavailable reason;
- minimum touch target;
- Dynamic Type;
- accessibility sizes;
- Reduce Motion;
- exact-value entry;
- keyboard/switch interaction where SwiftUI provides it;
- non-gesture alternatives for reset/help/exact entry.

Color controls announce semantic color context.

Stop All and selected-room Stop must be distinct.

Safety information must not rely on color alone.

---

## 26. Keyboard behavior

Exact entry must not:

- collapse/unmount the customization host;
- cause the room selector/Rolodex to jump;
- change the selected target unexpectedly;
- commit to a newly selected room;
- reopen previously fixed keyboard/presentation races.

Interactive scroll dismissal is preferred where appropriate.

---

## 27. Performance and network requirements

Do not create new hot paths.

No:

- capability fetch from view body;
- full light fetch per frame;
- timer solely to keep static UI alive;
- extra SSE connection;
- new high-frequency REST animation sender;
- unpaced per-light fanout;
- backend dependency for local lighting control.

Use existing caches, command gates, cancellation/mailbox semantics, BeatClock, exact bridge routing, and existing orchestration seams.

Bridge-native continuous animation must not be implemented as a fast REST loop.

---

## 28. Race invariants

The implementation must explicitly protect against:

- capability load A completing after selection moved to B;
- slider/knob drag started on A committing to B;
- debounced write landing after Stop;
- older write landing after Reset;
- old card write landing after card replacement;
- same card on two bridges sharing live values;
- duplicate room IDs across bridges colliding;
- Preview Live cancel/restore crossing target identity;
- transport changes resolving control state incorrectly;
- room/zone deletion while the host is open.

Prefer deterministic generation/state-machine tests over sleeps.

---

## 29. Product-quality acceptance

The implementation succeeds when a user can say:

> “I tapped something that is running and ChromaGlow gave me the right instrument for it.”

Not:

> “Effects has settings, Live has another menu, and Composer is a different app.”

The surface must answer, without requiring Hue API knowledge:

- What can I change?
- What is changing now?
- Which room am I controlling?
- Which lights are affected?
- Is hardware or transport limiting this?
- Is this value staged for later?
- Why is something unavailable?
- Can I reset this control?
- Can I restore the look?
- Can I stop this room?
- Can I stop everything?

---

## 30. Implementation latitude

The design/implementation agent may change current layout substantially if doing so improves the binding experience above.

The current busy top-row composition is not protected product behavior.

The agent may redesign placement/orchestration of controls, header, look browser, Rolodex expansion, and exact instrument composition, provided it preserves:

- all real capability;
- exact-target behavior;
- the one-system feel;
- safety;
- accessibility;
- performance/network constraints;
- the binding decisions in this spec.

Use Claude Code Design or equivalent design exploration to determine the most refined placement once the current capability audit is complete.

---

## 31. Source-of-truth precedence

When implementing:

1. Current repository code + newer binding architecture decisions determine what exists and how runtime ownership currently works.
2. This document determines the binding product/UX behavior described here.
3. `docs/ios/unified-customization-capability-audit-2026-08-19.md` determines the evidence/audit contract and must be updated from current code before implementation.
4. `docs/ios/unified-customization-execution-plan-2026-08-19.md` determines the large-slice delivery plan.
5. Older 2026-08-05 CNVS Track A/B packets are historical evidence only and must not override later product/UX decisions.

If current main contains a binding decision that directly contradicts this product requirement, stop and report rather than silently choosing one.
