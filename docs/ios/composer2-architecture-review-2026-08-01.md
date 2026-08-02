# Composer 2 — Independent Architecture Review (Claude, 2026-08-01)

**What this is.** A second-reviewer response to the "ChromaGlow Composer 2 — Architecture and
Delivery Plan Hardening Prompt" (ChatGPT baseline). Every risk claim in that prompt was
verified against current `main` (`79b5e9b`, 1.0.0 build 46) by direct source inspection —
three parallel audits (Composer core; transport/orchestration; docs/UI/tests) plus manual
re-verification of the four most load-bearing findings. All file:line references are to
current HEAD. No code was changed.

**How to read this.** Part I is the delta list — where this review disagrees with, corrects,
or extends the baseline, with reasoning. Parts A–L mirror the baseline prompt's required
deliverable sections one-for-one so the two documents can be diffed directly.

---

# PART I — Deltas from the ChatGPT baseline

The baseline's end-state architecture (versioned document → compiler → immutable runtime →
capability graph → transport planner → per-bridge arbiter → per-bridge scheduler) is
**endorsed**. The corrections below are about diagnosis, sequencing, and fit to this specific
repository.

## Three structural corrections

### Correction 1 — The snapshot is stale: ~25% of the risk list is already fixed and test-locked

Verified already-fixed on main (do not re-plan these):

| Baseline claim | Current reality |
|---|---|
| Tap tempo is a generated sine at stored BPM | Real tap-derived phase clock: every tap re-anchors `beatEpoch`, BPM from median of last ≤8 tap intervals (`BeatClock.swift:154-179`); sine survives only as a legacy-preset fallback when the clock is dead (`CompositionEngine.swift:305-308`) |
| randomize / motion spread / reaction smoothing / color target / speed target unimplemented | All five implemented and unit-tested (`CompositionEngine.swift:409-417`, `:321-324`, `:343-371`, `:328-332`; `CompositionModels.swift:262-373`; `CompositionReactionTests`) |
| Persistence overwrites user data with built-ins after decode error | Element-level `FailableDecodable`, timestamped `.bak` backup, create-only seed writes (`.withoutOverwriting`), `seedNeedsPersist: false` on any decode problem (`CompositionStore.swift:177, 193-249`); locked by `NonDestructivePersistenceTests` |
| Built-in reset keyed by mutable name | Keyed by stable deterministic UUID (`CompositionStore.swift:79`), with retired-built-in handling; locked by `CompositionStoreTests` + `PresetCatalogTests.testEveryPresetIDIsDeterministicNotRandom` |
| `isBridgeStored` is global | Per-room `compositionTransportByRoom` (`UnifiedOrchestrator.swift:2309`); locked by `MultiBridgeRoutingTests` |
| Bridge-stored cleanup uses primary client | Cleanup resolves the manifest's actual bridge via `hueClient(forBridgeIP:)` (`UnifiedOrchestrator.swift:2966-2969`); tested |
| Generation captured before queued closure (tautology) | Deliberately removed with an explanatory comment (`UnifiedOrchestrator.swift:3136-3139` et al.); a *different* residual staleness gap remains (see risk table #38) |
| Single audio level for all sources | Per-source features exist: level/bass/mid/treble + onset + beat snapshot (`CompositionEngine.swift:293-317`, `AudioFeatureExtractor.swift:25-51`) |
| Mic demand synchronized every frame | Recompute is per-frame but cached; the cross-actor `setDemand` hop fires only on transitions (`UnifiedOrchestrator.swift:2525-2531`); policy tested |

Beyond individual fixes, the baseline underweights what already works: a 443-line render core
with **zero RNG** (fully deterministic hash-based randomness), a tested non-destructive
persistence layer, a robust DTLS client (exactly-once continuation gate, failed-open rollback,
bounded reconnect, terminal-failure → REST failover that carries the live param box across),
a pure, tested progressive-disclosure catalog (`ComposerControlCatalog`), a preset quality bar
enforced in tests (gamut legality, slider ranges, ≤3 Hz WCAG flash cap), and a versioned
onboarding/What's-New system. The repo also carries a formal SALVAGE decision record for this
exact core (`docs/ios/composer-studio-mic-audit-2026-07-06.md` §1).

**Consequence:** Composer 2 should be a **strangler-style hardening of the existing engine in
place**, not a parallel second engine behind a comparison flag. The baseline's Slice 13
(side-by-side old/new engine switching) and Slice 20 (legacy-engine removal criteria) assume a
big-bang replacement. In a one-developer, single-target, ~57k-line app with ~836 passing tests
and **no module system**, dual-engine machinery is nearly all cost: two engines to keep honest,
a flag layer that doesn't exist yet, and a combinatorial QA matrix Brian has to walk on
physical hardware alone. The strangler path retires the same risks in smaller, individually
shippable diffs — which is also exactly this repo's established working convention (one
shippable commit per fix, checkpoint tags, device-verification gates).

### Correction 2 — The live emergencies are ownership/transport bugs, not model bugs; the slice order is inverted

The baseline sequences domain model → capability graph → render core → compiler (Slices 2–5)
before the arbiter and scheduler (Slices 6–8). But every *user-facing silent failure* verified
open today is an ownership bug fixable against the current engine with no new data model:

1. **Wrong-room streaming.** `findEntertainmentConfig` returns `configs.first` for the bridge
   with no room-membership check (`UnifiedOrchestrator.swift:3577-3586`). A composition
   started on the Bedroom can stream into the Living Room's entertainment area. This also
   poisons `entertainmentAvailability(for:)`, which reports "available" for rooms with zero
   lights in any area.
2. **Silent permanent freeze.** `startStudioMode` tears down the bridge's Entertainment session
   with no ownership check (`UnifiedOrchestrator.swift:2428-2432`) and does not clear
   composition bookkeeping — the composition's 25 fps loop keeps rendering into a stopped
   client forever (`send` no-ops on `.disconnected`; `isTerminallyFailed` stays false, so the
   REST failover at `:2667` never fires).
3. **Global Entertainment lockout.** Entertainment startup requires
   `compositionRuntimes.isEmpty` **globally** (`UnifiedOrchestrator.swift:2628-2630`). One REST
   composition anywhere demotes every subsequent start on every bridge to REST. The per-bridge
   conjunct on the same line is correct; the `.isEmpty` conjunct is the defect.
4. **Cross-room resource destruction.** Every bridge-stored start runs
   `purgeAllChromaGlowResources` (`UnifiedOrchestrator.swift:2701`,
   `BridgeAnimationEngine.swift:412-466`), deleting *all* `CG_` schedules/rules/sensors/scenes
   on the bridge — including other rooms' live animations, whose manifests are left dangling.
5. **One global mailbox for everything.** A single `RestSender` (`UnifiedOrchestrator.swift:2212`;
   `RestSender.swift`, 57 lines) serializes all rooms on all bridges plus Studio slider writes,
   latest-wins. Stopping one room clears it globally (`:2980`, `:3488`, `:3529`) plus a 150 ms
   *global* settle. An in-flight closure is up to 4 batches × 80 ms sleeps (≥240 ms) with no
   cancellation checks — card A's stale frame lands ~100 ms *after* card B's prime frame.
6. **Third-party session eviction.** `deactivateStuckEntertainmentSessions`
   (`UnifiedOrchestrator.swift:4516-4555`) PUTs `action=stop` on ANY active entertainment
   configuration not owned by this process, on every launch/foreground (60 s throttle). A
   running Hue Sync Box, Hue Sync desktop, or second phone is unilaterally killed. No consent,
   no setting, no notice.
7. **All-Day stomping.** `tickAllDayScenes` writes CT+brightness to *every* room every 5
   minutes with no check against any playback registry (`UnifiedOrchestrator.swift:201-232`) —
   and because SSE is suppressed for app-driven rooms, the UI never shows it.
8. **Unstoppable animations after relaunch.** Bridge-stored manifests persist
   (`BridgeAnimationStore`), but nothing restores playback state at launch; `stopEffect`
   requires an in-memory `runningEffects` entry, so after a crash/force-quit the animation runs
   on the bridge with no in-app way to stop it.

None of these needs `CompositionDocument`, a compiler, or a capability graph. All are small,
individually testable diffs. **The revised plan front-loads a "stop the bleeding" phase
(Phase 0) of ~10 surgical fixes on the current engine**, then builds the arbiter/scheduler
(Phase 2), and only then the document/compiler work (Phases 3–5). The baseline's ordering
would leave users exposed to items 1–8 for the entire duration of the model/render rebuild.

### Correction 3 — The baseline assumes infrastructure this repo does not have

| Baseline assumption | Repo reality | Disposition |
|---|---|---|
| Feature flags / kill switches / staged enabling (Slices 0, 20) | `FeatureFlags.swift` is 21 lines, **one compile-time flag**; everything else is scattered `UserDefaults` keys | New prerequisite: a local runtime `FlagStore` (UserDefaults/JSON-backed, no backend — AGENTS backend rules) before any kill-switch language is meaningful (Delta D11) |
| UI tests, visual regression snapshots (Slice 19, §9) | **No XCUITest target exists.** One unit target; the only "UI test" is a host-render geometry assertion (`StudioScrollStabilityTests`) | Re-scope: pure catalog/metrics tests + host-render smoke tests + extensions to `docs/ios/master-on-device-checklist.md`. Brian owns visual/device testing by explicit convention — plans deliver device checklists, not simulator visual rigs (Delta D9) |
| Telemetry with budgets, migration metrics, cohorting (Slices 18, 20) | **Zero telemetry.** Shipped App Store privacy label = "Data Not Collected"; README claims zero tracking; diagnostics are DEBUG-only | Re-scope Slice 18 to local-only diagnostics (extend `Core/Diagnostics/`, fix the degenerate cadence metrics) unless Brian explicitly decides to change the privacy label — a product decision, not a footnote (Delta D10) |
| Proposed modules (`ComposerDomain`, `ComposerRenderCore`, …) as separable units (§10) | **No SPM packages, no framework targets.** Single app target; files registered in pbxproj manually or via `add_*.rb` scripts | Module names become folder/namespace boundaries + protocol seams, not build targets. A packaging migration is its own risky project (12 `CURRENT_PROJECT_VERSION` entries, script-driven registration) and should not be smuggled into Composer 2 |
| TestFlight cohort rollout (Slice 20) | One developer, direct Xcode installs to a physical phone from `main` | Rollout = FlagStore defaults + Brian's device gates; TestFlight cohorting deferred until distribution actually changes |

## The sixteen deltas (D1–D16)

- **D1 — Ownership first, schema later.** Arbiter + scheduler work needs no new document
  format and fixes every live silent failure (Correction 2). Schema work gates nothing urgent.
  Reorder: Phase 0 hotfixes → ownership rebuild → document/compiler.
- **D2 — Arbiter must include ALL writers, not just app-internal ones.** The baseline's §5.6
  arbiter lists Entertainment, Studio, Composer, scenes, REST. Current main has **two more
  writers the baseline missed**: All-Day solar scenes (stomps compositions every 5 min) and
  `deactivateStuckEntertainmentSessions` (evicts third parties). Both must become arbiter
  clients, and the external world (SSE-observed changes, other apps' sessions) must be modeled
  as a first-class owner the arbiter can *yield to*, not only suppress.
- **D3 — Don't design a new rate limiter; promote the existing one.** `BridgeCommandGate`
  (100 ms min-interval, single 400 ms-backoff retry, tested in `GatedBulkWriteTests`) already
  encodes the ~10 cmd/s budget — the composition path simply never uses it. The per-bridge
  scheduler should be: per-bridge `RestSender` instances, `clear(scope:)` keyed by
  bridge+room, cooperative cancellation checks inside batch loops, and delivery routed through
  the gate (extended to a token bucket + 429/503/`Retry-After` handling). This is an
  incremental hardening of ~130 existing lines, not a new subsystem.
- **D4 — Schema: wrap, don't replace.** `compositions.json` is a **bare top-level array** with
  no envelope — a version field cannot be added without a read-path change anyway. Introduce a
  v1 envelope `{schemaVersion, presets: [...]}` whose reader accepts bare-array v0 files;
  keep the existing tolerant per-field decode *within* a version (it is the right tool for
  additive change); add explicit version refusal (newer-major file → open read-only + back up,
  never default-and-overwrite). Two corrections to the baseline's §5.1: the domain model is
  **five** configs, not four (`CompositionSequence` is real and shipping), and the "immutable
  template IDs for built-ins" requirement is **already implemented and tested**
  (`BuiltInSeedMigrator` + deterministic UUIDs) — reuse it, don't respecify it. The repo also
  already contains the right envelope precedent: `ScenePayloadCodec` refuses unknown versions.
- **D5 — Render purity via state extraction, not a new module.** `CompositionEngine.render`
  mutates 8+ accumulator fields on the shared box (`CompositionEngine.swift:279-361`) — that
  is the *entire* impurity. Extract them into an explicit `RenderState` passed in/out (or
  returned), and `render` becomes genuinely pure and idempotent with roughly a one-file diff —
  which then makes golden test vectors for Android trivial to emit. The baseline's Slice 4
  ("render-core primitives" as a fresh build) throws away a working, tested core to get a
  property obtainable by refactor. Its color-science concerns are real but *contained*:
  adopt a perceptual space (recommend **OKLab** — cheap, good hue-linearity, trivially portable
  to Kotlin) inside `CodableColor.lerp` + the mixer/punch/gradient call sites, and send true
  mirek on CT-capable REST/scene paths instead of the xy chord approximation
  (`CompositionModels.swift:148-154`; every send path currently passes `mirek: nil`).
- **D6 — Capability graph: assemble, don't invent.** `HueLight` capability decode (tested
  golden-JSON), gamut utilities, and `EntertainmentConfigManager` already exist. The graph is
  mostly joining them into one queried snapshot + fixing per-light gamut (majority-vote is
  verified open, `UnifiedOrchestrator.swift:3364-3370`). One carve-out: room-filtered
  entertainment-config selection is a **Phase 0 hotfix**, not part of the graph — it is a live
  wrong-room-streaming bug.
- **D7 — Transport planner: validate dynamic scenes, don't rewrite them.** The baseline's §6
  says v2 dynamic-scene code "may exist but not be integrated" — **stale**: it is integrated on
  three surfaces with a contract-shaped payload builder (`CreateSceneRequest.swift:161-201`,
  white-only lights handled, 9-point palette cap). What's missing is a JSON round-trip test,
  error surfacing (`try?`-swallowed → silent nil today), and hardware validation. Also reuse
  `TransportVocabulary` (build 31, guard-enforced single vocabulary) as the seed of the
  degradation-report language the baseline asks for.
- **D8 — UX corrections.** (i) There are **two** coexisting token systems (`HuePalette`/`HueFont`
  and the newer `StagePalette`/StageKit); the baseline's "use existing tokens" is ambiguous,
  and the Cursor rules it cites reference tokens that don't exist (`HuePalette.Noir.card`).
  Decision: StageKit/StagePalette is the Composer-2 surface standard. (ii) `StudioView.body`
  is at the Swift type-checker's ceiling — all new UI must land via the established
  ViewModifier-wiring pattern (`StudioDrainWiring`/`StudioMusicWiring`), a hard constraint the
  baseline doesn't know about. (iii) Progressive disclosure **already exists** as a pure,
  tested catalog gating controls to what the engine actually consumes — extend
  `ComposerControlCatalog`; don't design a new disclosure system. (iv) The versioned Welcome
  Tour / What's-New machinery is the reusable help substrate; the genuinely missing piece is
  in-context help (no tooltips/info affordances anywhere) — that is the real greenfield UX work.
- **D9 — Testing shape** (see Correction 3). Characterization priority goes to
  **`RestSender` + `runCompositionScheduler` + ownership seams — currently ZERO coverage and
  the center of four verified-open claims** — not to preset encode/decode, which is already
  strongly covered. The baseline's Slice 1 list starts from the wrong end.
- **D10 — Telemetry conflicts with shipped privacy posture** (see Correction 3).
- **D11 — Kill switches need a flag layer that doesn't exist** (see Correction 3).
- **D12 — Timeline/automation must graduate `CompositionSequence`.** A binding decision record
  already governs the baseline's Slice 16: *"There must not be a second sequence system…
  Sequence Builder is the graduation of this system, not a sibling"*
  (`docs/ios/sequence-builder-design-2026-07.md` §2). Timeline clips and automation lanes
  extend `CompositionSequence`/`SequencePlayer`/`PerformanceMixBox` — new `Timeline` types are
  ruled out. (Two live bugs to fix on the way: `SequencePlayer.adopt` leaves runtime
  accumulators stale across steps, and `run()` captures steps by value so mid-playback edits
  never take effect.)
- **D13 — The schema must stay AI-promptable.** `AICompositionGenerator` (FoundationModels)
  generates presets from the flat, defaultable config shape and is a shipped feature. A deeply
  nested graph-of-nodes document would break it. Constraint: the v1/v2 document keeps flat,
  individually-defaultable parameter fields; layers/modulators arrive as *optional additive*
  structures with complete defaults.
- **D14 — Four slices the baseline lacks entirely:** (i) third-party session-eviction consent
  UX; (ii) All-Day/composition coexistence policy; (iii) launch-time playback reconciliation
  (restore manifests → stoppable UI); (iv) `NWPathMonitor` + bridge IP re-resolution (zero
  hits today; IPs are captured at `configure()` and never refreshed).
- **D15 — Blackout semantics are coupled to the floor.** The ≥1% floor (`max(1, …)` +
  `on: true` on all seven REST-family send sites) is the implicit "never turn lights off"
  hack. Removing it (the baseline is right that intentional blackout must be possible)
  requires explicit per-frame on/off semantics — today the Perform blackout pad already goes
  fully dark on DTLS but clamps to 1% on REST, a visible transport inconsistency.
- **D16 — Cuts.** Endorse "no visible node graph" strongly (structured routing panels if/when
  modulation ships). Cut the searchable glossary. Cut dual-engine flag machinery (Correction 1).
  Shrink Slice 21 (Android) to golden fixtures + numerical vectors emitted from the purified
  render core — a real consumer (`android/`) already exists, so the contract has a customer
  from day one.

---

# PART A — Executive decision

**Recommended architecture (end state):** the baseline's pipeline, adjusted per D1–D16.

> versioned envelope + `CompositionDocument` → compiler → immutable `CompiledComposition` →
> runtime coordinator (actor) with explicit `RenderState` → pure render → blend → safety →
> per-target calibration (per-light gamut / CT) → transport plan → per-bridge session arbiter →
> transport adapters (native effect / dynamic scene / DTLS / per-light REST / grouped REST)
> with per-bridge gated schedulers.

**Why it fits this app:** every layer either already exists in embryonic, tested form
(deterministic render math, DTLS client with failover, dynamic-scene payload builder, command
gate, tolerant persistence, disclosure catalog) or replaces a verified-broken global
(mailbox, ownership booleans, majority gamut). The plan's job is to *promote and connect*
proven pieces, not to rebuild them.

**Major alternatives rejected:**
- *Parallel new engine behind a comparison flag* (the baseline's implicit shape) — rejected;
  see Correction 1.
- *Full graph/node composition document now* — rejected; breaks AI generation (D13), collides
  with the sequence-graduation decision record (D12), and no current UX surface needs it.
- *SPM modularization as part of this effort* — rejected; folder/protocol seams first (§10
  discipline is achievable without build-system risk).

**Build first:** Phase 0 ownership hotfixes (Part G), starting with the first packet in Part L.
**Explicitly wait:** layering/modulation/automation UI, node-graph anything, Android
implementation (contract fixtures only), telemetry beyond local diagnostics, TestFlight
cohorting machinery.

---

# PART B — Current-main findings

## B.1 What exists and works (do not regress, do not rebuild)

- Deterministic render core, zero RNG (`CompositionEngine.hash01` + patterned math); 10 motion
  patterns, 6 envelope shapes, 8 reaction sources with per-source audio features and a real
  beat/tap clock.
- Non-destructive persistence with element-level failure isolation, `.bak` backups, create-only
  seeding; deterministic built-in UUIDs + seed migrator (66 built-ins).
- DTLS client: pinned DTLS 1.2 PSK (`0x00A8`), exactly-once continuation gate, failed-open
  compensating stop, bounded reconnect, terminal-failure → REST failover carrying the live
  param box (user edits and mic survive the fallback).
- Per-room transport truth (`compositionTransportByRoom`), manifest-bridge-scoped cleanup,
  multi-bridge client routing — all tested.
- Progressive disclosure catalog; preset quality bar in tests including the ≤3 Hz WCAG flash
  cap; transport vocabulary guard; versioned tour/What's-New system.
- Editing never interrupts playback (the tray *is* the editor); one-tap `+ Create` starts a
  live starter draft.

## B.2 What is incomplete or broken — full verified risk table

Statuses: **OPEN** = verified open · **FIXED** = already fixed · **N/A** = no longer
applicable/refuted · **TRADEOFF** = intentional · **PARTIAL** = mixed · **HW** = needs
hardware validation. "Fix" column = phase in Part G.

| # | Baseline claim (§6 order) | Status | Evidence | Fix |
|---|---|---|---|---|
| 1 | `CompositionParamBox` `@unchecked Sendable`, cross-executor | OPEN (latent) — the *real* race is `StudioParamBox`: `nonisolated(unsafe)` dict writes vs main-actor reads | `CompositionEngine.swift:28`; `UnifiedOrchestrator.swift:2396-2415` | P2/P5 |
| 2 | `render` mutates state despite "pure renderer" label | OPEN — 8+ fields per frame; not idempotent at t=0; mixer deck-B dt jump on re-engage | `CompositionEngine.swift:279-361`; `CompositionMixer.swift:130-137` | P4 |
| 3 | Generation captured before queued closure | FIXED (tautology removed) — residual staleness now rests on `clear()` which can't stop in-flight work | `UnifiedOrchestrator.swift:3136-3139`; `RestSender.swift:53-56` | P0/P2 |
| 4 | One global REST sender across rooms/bridges | OPEN — head-of-line blocking *across bridges*; second global mailbox for All-Day | `UnifiedOrchestrator.swift:2212, 126`; `RestSender.swift:38-42` | P0/P2 |
| 5 | Stopping one room clears global mailbox | OPEN — unscoped `clear()` + 150 ms global settle | `UnifiedOrchestrator.swift:2980, 3488, 3529` | P0 |
| 6 | Entertainment blocked by any REST composition globally | OPEN — `compositionRuntimes.isEmpty` conjunct | `UnifiedOrchestrator.swift:2628-2630` | P0 (packet 1) |
| 7 | Entertainment ownership ambiguous Studio/Composer | OPEN — start-side unarbitrated → silent permanent freeze | `UnifiedOrchestrator.swift:2428-2432` | P0 (packet 1) + P2 |
| 8 | `isBridgeStored` global | FIXED (per-room; nit: keyed by roomID only) | `UnifiedOrchestrator.swift:2309` | — |
| 9 | Cleanup uses primary client | FIXED (manifest's bridge; residual: unregistered bridge → orphan runs forever) | `UnifiedOrchestrator.swift:2966-2976` | P2 |
| 10 | Start purges all `CG_` resources | OPEN — destroys sibling rooms' animations; no session ID in naming | `UnifiedOrchestrator.swift:2701`; `BridgeAnimationEngine.swift:412-466` | P0 |
| 11 | Partial upload leaves orphans | OPEN — straight-line creates, no compensating deletes; #10 and #11 are each other's mitigation | `BridgeAnimationEngine.swift:177-285` | P2 |
| 12 | v1 rules exceed action-per-rule capacity | PARTIAL — 7-actions chunking fixed+tested; capacity precheck (`rulesAvailable >= 12`) doesn't scale (20 lights × 8 steps = 24 rules) | `BridgeAnimationEngine.swift:197-241`; `HueV1Client.swift:39-43` | P2 |
| 13 | Fake UInt8 channel IDs → 20-light cap | OPEN — REST, pre-render, and gradient paths all cap at 20 | `UnifiedOrchestrator.swift:3068-3070`; `BridgeAnimationEngine.swift:121`; `GradientChannelMap.swift:36-43` | P0/P2 |
| 14 | Lights beyond cap silently get no frame | OPEN — enumerated then `continue`d, no log/error | `UnifiedOrchestrator.swift:3208`; `BridgeAnimationEngine.swift:160` | P0/P2 |
| 15 | Change detection inspects only first light | OPEN — `frames[0]` gate skips whole frame; several sliders never trigger the force-burst escape | `UnifiedOrchestrator.swift:3100-3121`; `ComposerLayerSheet.swift:187-428` | P0/P2 |
| 16 | Per-light REST far above sustainable rate | OPEN — ~55–80 PUT/s attempted vs repo's own ~10 cmd/s budget; no 429/503/`Retry-After` anywhere; `BridgeCommandGate` unused on this path | `UnifiedOrchestrator.swift:3203-3228`; `BridgeCommandGate.swift:7,19` | P2 |
| 17 | Telemetry measures enqueue not completion | OPEN and degenerate — `dueAt: now, sentAt: now` → lag always 0; enqueues counted incl. dropped frames; user-visible in tray | `UnifiedOrchestrator.swift:3269-3274`; `MixerTrayView.swift:517` | P0 |
| 18 | Single majority gamut per room | OPEN — per-runtime gamut applied to every light; scene path hardcodes `.c` | `UnifiedOrchestrator.swift:3364-3370, 4379` | P3 |
| 19 | hueShift/saturation only affect spectrum | OPEN in model / mitigated in UI (controls hidden per mode; persisted values silently inert on mode switch) | `CompositionModels.swift:122-156`; `ComposerLayerSheet.swift:95` | P4 |
| 20 | randomize/spread/smoothing/color/speed targets unimplemented | FIXED — all implemented + tested | `CompositionEngine.swift:321-417`; `CompositionReactionTests` | — |
| 21 | Attack/decay don't affect most envelopes | OPEN in model / TRADEOFF in UI (knobs hidden except `.swell`) | `CompositionModels.swift:446-508`; `ComposerLayerSheet.swift:107` | P4 |
| 22 | Tap tempo is a sine at stored BPM | FIXED — real tap-derived phase clock; sine = legacy fallback only | `BeatClock.swift:154-179` | — |
| 23 | Direct CIE xy interpolation | OPEN (TRADEOFF today) — xy-lerp on gradients, temperature, crossfade, punches, strips | `CompositionModels.swift:49-55`; `CompositionMixer.swift:140-141` | P4 |
| 24 | Temperature mode = xy approximation | OPEN — straight chord, not Planckian; `mirek: nil` on every send path incl. 8 CT built-ins | `CompositionModels.swift:148-154`; `UnifiedOrchestrator.swift:2745, 2820, 3172, 3247` | P4 |
| 25 | ≥1% brightness floor, blackout impossible | OPEN on REST paths (7 send sites `max(1,…)` + `on: true`); Perform blackout works on DTLS, fails on REST | `UnifiedOrchestrator.swift:2740-3239`; `CompositionMixer.swift:184-188` | P4 + K3 |
| 26 | Mic demand recomputed/synced every frame | MOSTLY FIXED — cached; cross-actor hop only on transitions; cheap per-frame recompute remains | `UnifiedOrchestrator.swift:2501-2531` | — |
| 27 | Single audio level, no per-source features | N/A (refuted) — level/bass/mid/treble/onset/beat all consumed per source | `CompositionEngine.swift:293-317` | — |
| 28 | Spatial fallback discards all positions | OPEN — one unmapped light → `[]` → index-order for everyone; radial path inconsistently substitutes (0,0) | `CompositionEngine.swift:134-144, 183-187` | P3/P4 |
| 29 | PCA direction flips 180° | OPEN + HW — θ mapping bug (−20°→340° not 160°); recomputed on every auto-angle apply; no canonicalization/hysteresis | `CompositionEngine.swift:220-244` | P4 |
| 30 | Position mapping: segments/fixtures/dups/out-of-room | OPEN — 1:1 device dict drops multi-light fixture positions; duplicate members last-wins; strip segments collapse to a point; **ent config not room-filtered (streams into other rooms)** | `UnifiedOrchestrator.swift:3406-3455, 3577-3586` | P0 (room filter) + P3 |
| 31 | Persistence overwrites user data after decode error | FIXED | `CompositionStore.swift:193-249` | — |
| 32 | No schema version / migration path | OPEN — bare array; tolerant decode is the only strategy; no version refusal | `CompositionStore.swift:176, 200, 253` | P3 |
| 33 | Built-in reset by mutable name | FIXED | `CompositionStore.swift:79` | — |
| 34 | Live mutation → no undo/dirty/save consistency | OPEN — zero undo/redo/dirty hits; revert only for saved presets; save reads live state mid-frame; `duplicate()` drops `sequence` | `StudioViewModel.swift:673-685, 1826-1829`; `CompositionStore.swift:96-113` | P5 |
| 35 | Dynamic-scene code not integrated/validated | PARTIAL + HW — integrated on 3 surfaces, contract-shaped payloads; no round-trip test, failures `try?`-swallowed | `CreateSceneRequest.swift:161-201`; `UnifiedOrchestrator.swift:4388` | P6 |
| 36 | Transport classification = coarse heuristics | OPEN — hardcoded card-name list; 3-field tier match; `!requiresMic`; nothing consults room reality | `StudioViewModel.swift:57-60`; `CompositionModels.swift:814-833` | P6 |
| 37 | Fights external controllers / SSE | OPEN and worse — SSE for app-driven rooms *suppressed* not reconciled; plus unconsented eviction of third-party sessions | `UnifiedOrchestrator.swift:1608-1613, 4516-4555` | P2 + K1 |
| 38 | Rapid card switch leaves stale writes | OPEN — no exec-time cancellation; in-flight batch (≥240 ms) outlives 150 ms settle; DTLS mostly safe | `UnifiedOrchestrator.swift:3204-3230, 2982` | P0/P2 |
| 39 | Crash/reboot/Wi-Fi/bg leaves stale state | OPEN — no launch restore (bridge-stored unstoppable after relaunch); phantom-owned session after backgrounding; no `NWPathMonitor`; `stopSSE` leaves status stale | `StudioViewModel.swift:1342`; `UnifiedOrchestrator.swift:1403-1441` | P0/P2 + D14 |
| 40 | Errors log and continue silently | OPEN on playback paths (84 `try?` in the orchestrator; start failures guard-return silently; good error strings never reach UI). CRUD/bulk/availability paths DO surface errors | `UnifiedOrchestrator.swift:2547, 2755-2758, 3571` | cross-cutting |

## B.3 New risks not in the baseline (found during this review)

| ID | Finding | Severity | Evidence |
|---|---|---|---|
| N1 | Wrong-room streaming: `configs.first`, no room membership; availability lies | HIGH | `UnifiedOrchestrator.swift:3577-3586, 2371-2379` |
| N2 | `startStudioMode` orphans a Composer DTLS stream → silent permanent freeze | HIGH | `UnifiedOrchestrator.swift:2428-2432` |
| N3 | Bridge-stored animations unstoppable after app relaunch | HIGH | `StudioViewModel.swift:1342`; no restore path |
| N4 | Unconsented eviction of third-party Entertainment sessions (Sync Box etc.) | HIGH (product/trust) | `UnifiedOrchestrator.swift:4516-4555` |
| N5 | All-Day scenes overwrite active compositions every 5 min, invisibly | MED | `UnifiedOrchestrator.swift:201-232` |
| N6 | Studio DTLS loops (strobe/party/thunderstorm) have no terminal-failure fallback | MED | `UnifiedOrchestrator.swift:3594, 3699, 3844` |
| N7 | `StudioParamBox`/`activeParamBox` genuine cross-thread dictionary race | MED | `UnifiedOrchestrator.swift:2396-2415` |
| N8 | Cross-transport spatial ordering mismatch (ent-channel order lerped against REST order, wrong ordering committed) | MED | `ComposerLayerSheet.swift:727-733`; `CompositionEngine.swift:282, 388-390` |
| N9 | Direction dial silently inert on bridges with no cached ent config (guard precedes the angle write) | MED | `ComposerLayerSheet.swift:724-726` |
| N10 | Direction drag resets the 0.3 s spatial lerp every frame + writes an observed property at gesture rate | LOW/MED | `ComposerLayerSheet.swift:586, 734` |
| N11 | Dead code that lies: 4 cadence functions + `CompositionSchedulerProfile` encode scaling the live path ignores | MED (misleading) | `UnifiedOrchestrator.swift:3281-3295, 2238-2243` |
| N12 | Scorer inputs `wasInteracting`/`pendingSettle`/`interactionBurstUntil` never written → +500/+260 terms unreachable; 19 tests exercise dead code | MED | `UnifiedOrchestrator.swift:2791-2793` |
| N13 | `SequencePlayer.adopt` keeps stale accumulators across steps; steps captured by value → mid-play edits ignored | MED | `SequencePlayer.swift:125, 171-178` |
| N14 | `resolveCompositionLightIDs` returns `[]` on fetch failure → silent collapse to a grouped blob | LOW/MED | `UnifiedOrchestrator.swift:3391` |
| N15 | `duplicate()` silently drops `sequence`; `hash01` duplicated verbatim in two files; built-in reconciliation re-runs in memory every launch | LOW | `CompositionStore.swift:96-113, 211-215`; `CompositionEngine.swift:438-441` vs `CompositionModels.swift:284-287` |
| N16 | No `NWPathMonitor`; IPs never re-resolved; `stopSSE` leaves "connected" status | LOW/MED | repo-wide grep; `UnifiedOrchestrator.swift:1403-1406` |

## B.4 Doc↔code contradictions (mark these stale in their sources)

- `.cursorrules` says v0.16.0 / "Composer next"; `DEVDOC.md` says v0.17.x current; reality is
  **1.0.0 build 46** with the Composer long shipped.
- `COMPOSER_SPEC.md`: 20 presets (actual 66), 5 motion patterns (actual 10), "no manual
  transport toggle for v1" (shipped with per-preset preference + prompt), "💾 overwrites"
  (save always creates a new preset), "Deck 3" (code index 2).
- `.cursor/rules/studio-ui.mdc` and `.cursorrules` prescribe `HuePalette.Noir.card` — token
  does not exist; actual surfaces use `StagePalette`.
- `.cursor/rules/build-verify.mdc` / `xcode-project.mdc` say `-scheme HueHome`; real scheme is
  `HueHome 1` (this one IS fixed in `run_tests.sh`, but `CLAUDE.md`/`DEVLOG` still describe it
  as stale).
- App-name drift across README ("HueHome Pro") / DEVDOC + source headers ("CastChroma") /
  shipping name ("ChromaGlow").

---

# PART C — Architecture diagram (target end state)

```
┌────────────────────────────── UI / Editing ──────────────────────────────┐
│ Studio deck · mixer tray · CompositionEditorPanel · ComposerLayerSheet   │
│ (StageKit tokens · ViewModifier wiring · ComposerControlCatalog gating)  │
└──────────────┬───────────────────────────────────────────────────────────┘
               │ ParameterPatch / document edits (typed, journaled → undo)
┌──────────────▼──────────────┐        ┌──────────────────────────────┐
│ CompositionDocument (v1     │        │ CapabilitySnapshot           │
│ envelope; 5 configs + seq;  │        │ per-light: gamut · CT range  │
│ flat, AI-promptable)        │        │ gradient segments · position │
└──────────────┬──────────────┘        │ reachability · ent channels  │
               │ compile(document, capabilities)   (SSE-refreshed)    │
┌──────────────▼──────────────┐        └──────────────┬───────────────┘
│ Compiler → CompiledComposition (immutable) + diagnostics             │
└──────────────┬──────────────────────────────────────┘
               │ snapshot
┌──────────────▼───────────────────────────────────────────────────────┐
│ Runtime coordinator (actor): monotonic clock · RenderState in/out ·  │
│ start/pause/replace/stop generations · audio feature snapshots       │
│   render(pure) → blend(mixer/seq) → SAFETY (flash/luminance caps) →  │
│   per-target calibration (per-light gamut · true mirek · on/off)     │
└──────────────┬───────────────────────────────────────────────────────┘
               │ frames + intent
┌──────────────▼──────────────┐
│ Transport planner            │→ human-readable degradation report
│ (compiled requirements ×     │   (TransportVocabulary)
│  capabilities, per bridge)   │
└──────────────┬──────────────┘
               │ plan
┌──────────────▼───────────────────────────────────────────────────────┐
│ Per-bridge Session Arbiter (actor, one per bridge)                   │
│ owns: DTLS session · REST membership · bridge-stored manifests ·     │
│ studio engine slot · All-Day writes · external-owner yield policy    │
└───┬───────────┬───────────────┬────────────────┬─────────────────────┘
    │           │               │                │
┌───▼───┐ ┌─────▼─────┐ ┌───────▼───────┐ ┌──────▼──────┐
│native │ │dynamic    │ │DTLS adapter   │ │REST adapter │
│effect │ │scene      │ │(HueEntertain- │ │per-bridge   │
│adapter│ │adapter    │ │ mentClient)   │ │RestSender + │
└───────┘ └───────────┘ └───────────────┘ │CommandGate  │
                                          │token bucket │
                                          └─────────────┘
Persistence: CompositionStore (envelope v1, .bak, seed migrator) · manifests (launch-restored)
Diagnostics: local-only (Core/Diagnostics) — honest completion-based cadence/lag
```

---

# PART D — Domain model

## D.1 Envelope (Phase 3; wrap-don't-replace)

```swift
// v0 = today's bare [CompositionPreset] array — reader must keep accepting it.
struct CompositionFile: Codable {
    var schemaVersion: Int          // 1 on first write of the envelope
    var presets: [CompositionPreset]
    // decode: try envelope; on failure try bare array → treat as v0, upgrade on next save
    // schemaVersion > CURRENT_MAJOR → open READ-ONLY + .bak; never default-and-overwrite
}
```

Rules (all reusing existing precedent): per-field tolerant decode stays *within* a version
(`CompositionModels.init(from:)` pattern); element-level `FailableDecodable` +
`.bak`-on-failure stays; `BuiltInSeedMigrator` stays as-is; `ScenePayloadCodec`'s
refuse-unknown-version behavior is the model for major-version handling.

## D.2 Document evolution (Phase 5+; additive, AI-promptable per D13)

```swift
struct CompositionPreset {                 // existing, stays decodable forever
    let id: UUID
    var palette: PaletteConfig             // the five shipping configs remain
    var motion: MotionConfig               //   the "base layer"
    var envelope: EnvelopeConfig
    var reaction: ReactionConfig
    var sequence: CompositionSequence?     // graduation target for timeline work (D12)
    // — additive, all-optional, all-defaultable (AI + old-build safe): —
    var extraLayers: [CompositionLayer]?   // blend mode + mask + own configs
    var modulators: [Modulator]?           // LFO/env → (layer, paramKeyPath, depth)
    var seed: UInt64?                      // explicit determinism for duplicate-variation
    var safetyPolicy: SafetyPolicy?        // caps; absent = global defaults
    var transportPreference: …             // exists today; keep
}
```

Runtime split (Phase 4/5):

```swift
struct RenderParams { … }   // value snapshot compiled from the document (immutable per frame)
struct RenderState  { … }   // the 8 accumulators (warpedMotionTime, smoothedReactionLevel,
                            //   spatialLerpProgress, lastTriggerBeatIndex, …) — owned by the
                            //   runtime coordinator, passed in/out of render(), never in UI
```

`CompositionParamBox` remains the UI-facing observable during the transition; the coordinator
diffs it into `RenderParams` snapshots (or, later, consumes typed `ParameterPatch`es that also
feed the undo journal).

---

# PART E — Transport and ownership state machines

**Composition runtime (per room):**
`idle → priming (prime frame + transport resolve) → running(transport) →
{replacing(gen+1) | degrading(ent→REST failover, param box carried) | stopping}` →
`stopped (scoped mailbox clear → await in-flight drain [bounded, cancellable] → state refresh)`.
Invariant: a frame closure carries `(bridgeID, roomID, generation)` and re-checks the arbiter's
current generation *at execution time*; the 150 ms blind settle is replaced by drain-or-cancel.

**Bridge session ownership (per-bridge arbiter):** resource classes
`{entertainment, restMembership(room set), bridgeStored(manifests), studioEngine, allDay}`.
`acquire(class, owner, targets)` → grants iff legal combination; conflicting-owner acquisition
returns `.needsHandoff(current)` → caller must present the conflict (user-visible) → ordered
handoff: `stop(current) [full bookkeeping] → drain → grant`. `startStudioMode`'s direct
`stopSession()` becomes illegal by construction. External owners: an SSE-observed off/scene on
an owned target → arbiter policy (K5): yield-and-stop (surface "taken over by another
controller") rather than silently overwrite.

**Entertainment startup/failure/fallback (exists, keep; extend):**
`register(process registry) → PUT action=start → DTLS handshake (10 s timeout, exactly-once
gate) → streaming ⇄ reconnect(≤3, 300/600/900 ms) → terminal → REST failover (live box)`.
Extensions: room-filtered config selection before `register`; strobe/party/thunderstorm loops
adopt the same terminal-failure branch (N6); backgrounding releases the session and clears the
process registry so foreground reclaim works (risk #39).

**REST scheduler lifecycle (per bridge):**
`idle → scheduling (per-room due times, fairness) → dispatch(coalesced per resource) →
gate (token bucket ~10/s, 429/503 backoff with Retry-After) → completion (telemetry stamped at
completion) → adaptive (widen intervals on sustained latency/errors; rolling subsets for >N
lights)`. Cancellation generations checked at dispatch *and* between batches.

**Background/foreground:** background → stop SSE (status set honestly), release DTLS sessions
(registry cleared), suspend schedulers; foreground → `loadAll`, restore manifests →
reconcile `runningEffects`/transport map (N3), restart SSE, re-arbitrate sessions.
`NWPathMonitor`: path change → mark clients suspect → re-resolve bridge IP (mDNS) → rebuild
clients → resume or fail over.

**Audio session/permission:** unchanged state machine (`AudioAnalysisEngine` demand counting,
cached composer demand) — it is already correct; add route-change/interruption re-entry tests.

---

# PART F — UX and aesthetic plan

- **Information architecture: largely unchanged.** Cards remain the entry point; `+ Create`
  remains live-by-default; the tray remains the editor; browsing/editing never interrupts
  playback (all already true on main — these become explicit no-regression contracts in
  Slice 0). The one deliberate structural change is the unified creation experience below.
- **Unified creation experience (explicit new work, Phase 7):** Create and Advanced
  settings become **one continuous editor**. The `+ Create` flow opens the same editor
  surface the tray uses, and `ComposerControlCatalog` progressive disclosure carries the
  user from the basic tier to advanced tiers *in place* — no separate Create modal, no
  separate Advanced-settings modal, no context switch between them. Lands via the
  ViewModifier-wiring pattern (D8 ii) and the catalog's "no dead controls" discipline.
- **Disclosure:** extend `ComposerControlCatalog` (basic = the current essential tier;
  advanced = current advanced tier; expert additions arrive as new catalog entries only when
  the engine consumes them — the catalog's existing "no dead controls" test discipline is the
  enforcement mechanism).
- **Visual contract:** StageKit/StagePalette for all new Composer surfaces (D8); no new
  hard-coded colors/fonts/spacing (the *existing* files' token debt — 35 raw font sizes in
  `StudioView` — is noted but out of scope). All new StudioView-adjacent behavior lands as
  ViewModifiers.
- **Transport honesty:** degradation reports built on `TransportVocabulary`; the tray's status
  sentence + badge lane is the existing surface for it. Proposed copy (plain, ≤1 sentence):
  - "Streaming — full motion." · "Room mode — smooth animation, simpler motion."
  - "This room has no Entertainment Area, so movement is simplified."
  - "2 lights are white-only; they'll follow brightness and warmth."
  - "Another app was controlling these lights — take over?" (K1 consent)
  - "This look runs on the bridge; live sliders don't apply. Save changes to update it." (K4)
- **Help:** in-context = new lightweight info affordance (popover on control long-press/ⓘ,
  content from a pure `HelpCatalog` mirroring `ComposerControlCatalog` IDs — testable the same
  way); first-run/feature-intro = existing Welcome Tour What's-New machinery (add pages, bump
  `catalogVersion`); permission pre-prompts = pattern already exists for mic; recovery guidance
  = surface the already-written `BridgeAnimationError`/start-failure strings as toasts
  (risk #40).
- **Accessibility/safety:** the ≤3 Hz flash cap and photosensitivity notice already exist;
  Composer 2 formalizes them into the post-blend safety stage so *combined* layers can't
  exceed caps (baseline §Slice 17 endorsed; enforcement point = one stage, tested).
- **Visual regression:** host-render smoke tests (existing pattern) + Brian's device checklist;
  no XCUITest/snapshot rig (D9).

---

# PART G — Delivery plan (replaces the baseline's 21-slice ordering)

Common fields: every slice = one or more single-commit PR-equivalents on `main` behind
Brian's checkpoint-tag convention; rollback = revert to checkpoint tag; DoD = suite green
(`xcodebuild test -project HueHome.xcodeproj -scheme "HueHome 1" …` verified via xcresulttool,
never chained with the commit) + device-checklist items appended for Brian where hardware is
implicated.

### Phase 0 — Stop the bleeding (current engine; ~10 surgical fixes, one commit each)
Objective: retire every live silent failure without new architecture. **Rule: every Phase 0
correction lands with its regression test in the same commit** — no fix-now-test-later.
1. Per-bridge Entertainment gate (drop `.isEmpty`) — packet 1 (Part L).
2. `startStudioMode` ownership check → user-confirmed handoff, never a silent stop — packet 1.
3. Room-filtered `findEntertainmentConfig` (exact/unambiguous best match + honest
   availability) — packet 1.
4. Scoped bridge-stored cleanup: manifest-aware deletes; global `CG_` purge only via an
   explicit maintenance action, never on start (`UnifiedOrchestrator.swift:2701`).
5. Scoped mailbox: `clear(roomID:bridgeID:)` semantics + cooperative cancellation checks
   inside batch loops (bounded stale-write window ≤1 batch).
6. Honest telemetry: stamp `sentAt` at network completion; count sends, not enqueues
   (`UnifiedOrchestrator.swift:3269-3274`).
7. 20-light cap: REST paths iterate real light IDs (cap removed; rolling subsets if >20);
   bridge-stored truncation surfaced in UI copy; `GradientChannelMap` documents the DTLS-only
   20-channel protocol limit as such.
8. All-Day skips rooms present in any playback registry (`UnifiedOrchestrator.swift:216-231`).
9. Third-party sessions yielded to by default (K1): launch/foreground stuck-cleanup only
   auto-stops sessions *this app* recorded (persisted registry) and never touches — or
   prompts about — foreign sessions. The take-over prompt appears only when an **explicit
   user playback action** conflicts with a foreign session (the arbiter's `.needsHandoff`
   path, Part E); the app never surfaces a conflict the user didn't initiate.
10. Launch-time manifest reconciliation: restore `runningEffects`/transport map from
    `BridgeAnimationStore` so relaunched animations are stoppable (N3).
Edge/error cases per fix are in Part H. Hardware checks: two-bridge concurrency, wrong-room
repro, Sync-Box coexistence, relaunch-stop.

### Phase 1 — Characterization + scaffolding
- Tests around `RestSender`, `runCompositionScheduler` cadence/batching/delta-gate,
  start/stop/replace races, cross-bridge isolation (all zero-coverage today, D9).
  Explicitly tag tests that pin *defects* (e.g. frames[0] gate) as characterization-of-bug so
  they're deleted with the fix, per the baseline's own §Slice 1 warning.
- `FlagStore` (local runtime flags; UserDefaults-backed; DEBUG overrides panel in More) — the
  kill-switch substrate for everything after (D11).
- Delete the lying dead code (N11, N12) or wire it — either way the file stops misleading.

### Phase 2 — Ownership rebuild
- `BridgeSessionArbiter` actor per bridge (Part E semantics); `StudioViewModel`'s hardcoded
  card-list arbitration and `activeStudioTask` global collapse into it.
- Per-bridge REST scheduler: per-bridge `RestSender` instances routed through
  `BridgeCommandGate` extended to a token bucket with 429/503/`Retry-After`; coalescing keyed
  by resource; fairness across rooms; adaptive backoff; completion-based metrics; rolling
  subsets for large rooms per the K6 contract (round-robin fairness with a bounded rotation,
  frame-age cap of one rotation, cancellation checks between subsets, degradation copy) and
  with defined degradation order (brightness cadence > color cadence > spatial resolution >
  grouped fallback).
- Studio DTLS loops adopt failover parity (N6); upload rollback (compensating deletes) +
  scaled capacity precheck for bridge-stored (#11, #12); `NWPathMonitor` + IP re-resolution.
- Non-goals: no document changes; UI unchanged except conflict/consent surfaces.

### Phase 3 — Document envelope + capability snapshot
- v1 envelope per Part D.1 (migration tests: v0→v1 round-trip, newer-major refusal, corrupt
  quarantine — extends `NonDestructivePersistenceTests`).
- `CapabilitySnapshot`: per-light gamut (kills majority-vote, #18), CT ranges, gradient
  segment counts, positions with multi-light-fixture/duplicate handling (#30), reachability;
  SSE-refreshed; spatial fallback keeps valid positions and synthesizes only the missing (#28).

### Phase 4 — Render purity + color science
- `RenderState` extraction (#1, #2, N13's accumulator reset on step adopt); single shared
  `hash01`; PCA canonicalization (axis mod 180°, hysteresis, persist resolved angle) (#29);
  cross-transport ordering unification (N8) — one canonical light ordering owned by the
  snapshot, both transports map from it.
- OKLab interpolation behind a flag; true mirek on CT paths; explicit on/off frame semantics +
  floor removal per K3 (#23–#25); hueShift/saturation defined across all palette modes or
  formally scoped (#19, #21).
- Emit golden vectors (fixed seed/time/light-set → frame arrays) — the Android contract
  artifact (D16).

### Phase 5 — Compiler + editing model
- `compile(document, capabilities) → CompiledComposition + diagnostics`; typed
  `ParameterPatch` path from UI → coordinator (ends direct live mutation, #34); undo/redo
  journal + dirty state + consistent save snapshots; `duplicate()` carries `sequence` + seed
  policy (K-level decision on duplicate-variation).

### Phase 6 — Transport planner
- Requirements derived from the compiled graph replace the three heuristics (#36); planner
  emits plan + degradation report; dynamic-scene adapter gets round-trip payload tests, error
  surfacing, and a hardware validation session (#35); mid-session failover + resync formalized
  (mostly exists for DTLS→REST).

### Phase 7 — UX expansion + showcase + audio polish
- Unified creation editor: Create and Advanced settings merge into one continuous,
  progressively disclosed editor (Part F) — a named slice, not incidental polish.
- In-context help system (`HelpCatalog`); conflict/consent copy;
  showcase effect proving the pipeline end-to-end — recommend **Lava Lamp on the real
  engine** (the preset pack shipped in build 32 proves the *look*; the showcase proves
  per-segment gradient output + spatial sampling + degradation tiers) plus the baseline's
  gradient/breathe parity composition.
- Audio: route-change/interruption tests, latency compensation, beat-confidence exposure —
  the feature extractor and clocks largely exist.

### Later (explicitly waiting)
Layering/modulation/automation via `CompositionSequence` graduation (D12) with structured
routing panels (no node graph); Android implementation (fixtures already emitted in P4);
telemetry beyond local diagnostics (K2).

Dependency order: P0 → P1 → P2 → P3 → P4 → P5 → P6 → P7; P3 and the tail of P2 can overlap;
P4's color work can start once P3's capability snapshot lands.

---

# PART H — Edge-case decision matrix

Owner key: **ARB** arbiter · **SCHED** rest scheduler · **CAP** capability snapshot ·
**RT** runtime/render · **DOC** persistence · **UI** studio surfaces · **AUD** audio.

| Case | Decision | Owner | Test |
|---|---|---|---|
| Room with no lights | Start refused with toast (today: silent guard-return) | UI+ARB | unit |
| One light | Full pipeline; spatial degrades to scalar; already tested at 1 light | RT | exists (`PresetCatalogTests`) |
| Duplicate membership via room/zone overlap | Dedupe by lightID at resolve; position = first channel, warn in diagnostics (today: last-wins silently) | CAP | unit |
| Gradient fixture, multiple segments | Segments are distinct render targets with interpolated positions (today: collapse to a point) | CAP+RT | unit + HW |
| Multi-light fixture, one device | device→[lightIDs] one-to-many (today: 1:1 dict loses lights) | CAP | unit |
| White-only + color mixed | Per-target calibration: white-only follow brightness/CT; copy states it | CAP+UI | unit |
| Mixed gamuts | Per-light gamut mapping (kills majority vote) | CAP | unit |
| Light unreachable mid-show | Keep rendering; scheduler skips with backoff; badge "N unreachable" | SCHED+UI | unit + HW |
| Ent config includes out-of-room lights | Config chosen only on exact/unambiguous room match (subset preferred, unique max-overlap else, tie → REST); channels outside target rendered black or excluded — never driven by another room's look | ARB+CAP | unit + HW |
| Positions missing/identical/collinear | Keep valid positions; synthesize missing (centroid/index-interpolated); never discard all (#28); collinear → 1-D axis fine; identical → scalar | RT | unit |
| Second composition, same room | Replace via ordered handoff (drain → start); no user prompt (same surface swap — the one deliberate exception to the confirmation rule) | ARB | unit |
| Composition in overlapping zone | Arbiter detects target-set overlap → conflict prompt naming the running look | ARB | unit |
| Another Entertainment mode, same bridge | Confirmation prompt naming the running look, then handoff with full bookkeeping (never the N2 orphan, never silent) | ARB | unit |
| Effects on a different bridge | Fully concurrent (post P0-1) | ARB | unit |
| Rapid A/B card alternation | Generation-checked dispatch; ≤1 batch stale window; prime always lands last | SCHED | race unit |
| Stop while REST batch in flight | Drain-or-cancel bounded by one batch; then state refresh | SCHED | unit |
| External app changes a light mid-playback | Arbiter yield policy (K5): detect via SSE, stop that room, toast "another controller took over" (today: silent overwrite war) | ARB | unit + HW |
| Bridge reboot / IP change | `NWPathMonitor` + SSE loss → suspect → re-resolve → resume/failover; ent session re-arbitrated | ARB | HW |
| Background / lock / kill / crash | Background releases DTLS + registry; relaunch restores manifests → stoppable UI (N3); REST loops stop with the process (documented behavior + copy) | ARB | unit + HW |
| Edit a running built-in | Live edit on the box; save creates user copy (already true); built-in itself immutable (already true) | UI+DOC | exists |
| Leave with unsaved changes | Dirty flag (P5) → keep-live + badge; discard restores saved snapshot | UI | unit |
| Crash during save | Envelope written atomically to temp + rename; `.bak` retained | DOC | unit |
| Old schema unmigratable / newer-major file | Read-only + `.bak`; explicit "made by a newer version" copy; never default-overwrite | DOC | unit |
| Imported doc with unknown/extreme values | Existing validation envelope pattern (ScenePayloadCodec) + range clamps + version refusal | DOC | exists+unit |
| Target room renamed/deleted | Presets store target *intent*; resolve at apply; missing target → picker prompt | UI | unit |
| Built-ins change in later version | `BuiltInSeedMigrator` (exists, tested) | DOC | exists |
| Duplicate a randomized effect | Deterministic hash today = identical twin; with `seed` field (P5): duplicate re-seeds by default, "exact copy" as option | DOC | unit |
| Mic denied/revoked; no route; route change; call | Existing demand state machine + notification path; add route/interruption re-entry tests; reaction degrades to none with badge | AUD | unit |
| Sync mode owns the audio session | `AudioAnalysisEngine` demand counting already shared; keep single owner | AUD | exists |
| Silence / clipping / lost beat confidence | AGC + noise floor exist; expose beat confidence → fall back to tap/steady below threshold | AUD | unit |
| High-frequency pulse requested | Post-blend safety stage clamps to ≤3 Hz (cap exists in preset tests; move to runtime enforcement) | RT | unit |
| Brightness → 0 | K3: explicit off allowed; safety stage owns max luminance-jump rate | RT | unit |
| Layers combine above safe output | Safety stage after blending, before every transport (baseline endorsed) | RT | unit |
| Out-of-gamut conversion | Per-light clamp at calibration; never NaN (bounds tests exist) | CAP | exists+unit |

---

# PART I — Test and hardware plan

**Pyramid** (extends the existing 836-test suite; one unit target, no XCUITest — D9):
1. **Pure math/domain** — golden vectors (fixed seed/time/lights → frames), render idempotence
   at fixed t, envelope/oscillator phase, OKLab bounds/no-NaN, PCA sign stability, gamut
   mapping per light, envelope round-trips v0→v1, compiler diagnostics, safety clamps.
   (Patterns: `PresetCatalogTests`, `BeatMathTests`.)
2. **Concurrency** — start/replace/stop races with generation assertions; stale queued work
   cannot send; per-bridge independence (stop A ≠ clears B); audio demand transitions exactly
   once; cancellation closes sockets. (Zero coverage today around `RestSender`/scheduler —
   this is the priority block.)
3. **Contract** — Hue payload golden JSON (pattern exists: `HueCapabilityFoundationTests`);
   dynamic-scene create/recall bodies; DTLS frame bytes (header/colorspace/channel layout —
   currently untested); scheduler semantics; shared fixtures consumed by `android/`.
4. **UI-adjacent** — catalog/metrics purity tests; host-render smoke (existing
   `StudioScrollStabilityTests` pattern); vocabulary guards.
5. **Hardware (Brian, via `master-on-device-checklist.md` extensions)** — named matrix:
   bridge(s) + firmware, one gradient strip, one white-only bulb, one CT-only bulb, ≥2 color
   bulbs across gamuts; scenarios: two-bridge concurrent playback, wrong-room repro before/after
   P0-3, Sync-Box coexistence (K1), 20+ light room on REST, relaunch-stop (N3), Wi-Fi drop
   mid-stream, All-Day + composition coexistence, dynamic-scene create/recall, blackout on
   both transports. Record bridge + device firmware per run.

---

# PART J — Rollout and rollback

- **Flags:** `FlagStore` (P1) gates: OKLab path, floor-removal/off semantics, per-bridge
  scheduler, arbiter enforcement, planner. Each is a kill switch back to prior behavior; no
  dual-engine flag (Correction 1).
- **Cohorting/telemetry:** none (single-developer direct-install reality). "Metrics" = local
  diagnostics + Brian's device gates. If TestFlight distribution starts, revisit.
- **Data:** envelope upgrade is write-forward with `.bak`; v0 readable forever; downgrade path
  = old build reads envelope? No — old builds predate the envelope, so the upgrade is *lazy*:
  only rewrite the file as v1 on the first user-initiated save after the update (keeps a
  reinstall/downgrade window), plus the `.bak`.
- **Bridge resources:** no destructive global purge on any normal path (P0-4); explicit
  "Clean up ChromaGlow leftovers on this bridge" maintenance action in Settings, paced through
  the command gate.
- **Legacy removal criteria:** each strangled global (`studioRestSender`, `activeStudioTask`,
  ad-hoc arbitration in `StudioViewModel`) is deleted in the same PR that lands its
  replacement's tests — no long-lived parallel paths.

---

# PART K — Open decisions requiring product approval (Brian)

| # | Decision | Recommendation | If chosen differently |
|---|---|---|---|
| K1 | Third-party Entertainment-session eviction | Yield by default: launch/foreground never touches foreign sessions; the consent prompt ("Another app is streaming to this bridge — take over?") appears only when an explicit playback action conflicts; auto-stop only sessions this app recorded | Keep silent eviction: fastest UX, but breaks Sync Box users invisibly and is an App-Store/trust liability |
| K2 | Diagnostics vs "Data Not Collected" privacy label | Local-only diagnostics; no label change | Real telemetry: changes privacy label + README claim; requires new infra + disclosure |
| K3 | True blackout on REST | Allow explicit off-frames (remove floor) with safety-stage rate limiting | Keep 1% floor: transports stay inconsistent; Perform blackout pad stays broken on REST |
| K4 | Bridge-stored preset shows a dead-slider editor (existing DEVLOG product call) | Read-only summary card + "Edit a live copy" action | Hide editor entirely: simpler, loses discoverability of editing |
| K5 | External-controller conflict policy | Composition yields + toast (external wins) | App wins (re-assert): guarantees the show but fights wall switches/other apps forever |
| K6 | >20-light rooms on REST | Rolling subsets with a defined contract: round-robin fairness (every light served within one bounded rotation), frame-age limit (a frame older than one rotation is dropped, never sent late), generation-checked cancellation between subsets, and degradation copy via `TransportVocabulary` ("Large room — lights update in rotation") | Honest hard cap with UI copy: simpler, permanently strands lights 21+ |

---

# PART L — First implementation packet

**Name:** Entertainment ownership correctness (Phase 0, fixes 1–3).
**Goal:** no wrong-room streaming; no silent freeze; no global Entertainment lockout.
**Files:** `HueHome/Core/Network/UnifiedOrchestrator.swift` only (three functions:
`startCompositionMode` gate at `:2628-2630`, `startStudioMode` head at `:2428-2432`,
`findEntertainmentConfig` at `:3577-3586`, plus `entertainmentAvailability(for:)` honesty).
**Must not broadly modify:** `StudioView.swift`, `StudioViewModel.swift`,
`CompositionEngine.swift`, `RestSender.swift`, any model/persistence file.
**Changes:**
1. Gate: `compositionEntRoomByBridge[bridgeID] == nil` only (drop `compositionRuntimes.isEmpty`).
2. `startStudioMode`: if `compositionEntRoomByBridge[stopBid]` exists, present a
   **confirmation prompt naming the running look** ("Stop <composition> and start <card>?")
   *before* any teardown — Studio never silently terminates a running composition. On
   confirm, route through `stopCompositionMode(roomID:)` for that room (full bookkeeping +
   failover state cleared) before acquiring the session; on cancel, the card does not start.
3. `findEntertainmentConfig`: selection requires an **exact or unambiguous best match** —
   never mere channel intersection. Prefer a config whose channel light-services are a
   subset of the target room's lights (data available via the light resolver + config
   channels); otherwise accept the max-overlap config only when it is unique with a clear
   margin. A tie/near-tie between candidate configs, or no overlap at all → return nil
   (clean REST fallback) — when in doubt, don't stream. `entertainmentAvailability` uses
   the same predicate so it stops reporting areas the room isn't in.
**Acceptance criteria:** two-bridge scenario — REST composition on bridge A does not demote a
new start on bridge B to REST; starting a Studio entertainment card over a running composition
asks for confirmation first, then stops that composition cleanly (transport map cleared, no
orphaned 25 fps loop); a room with no exact/unambiguous entertainment-area match never opens
a DTLS session and reports availability honestly.
**Tests:** `MultiBridgeRoutingTests`-style units for all three (stub configs with channel
membership; assert gate, teardown ordering, and selection). Suite verified via xcresulttool,
commit in a separate call, checkpoint tag first — per repo conventions.
**Rollback:** revert to checkpoint tag; no data-format changes.
**Estimated complexity:** small (three localized diffs + tests).
**Hardware validation (Brian):** wrong-room repro before/after on the two-area bridge; Studio
card over running composition; two-bridge concurrent playback.

---

*Review method note: statuses above were produced by direct source inspection of `main`
@ `79b5e9b`; four highest-impact findings (#6, #7, N1, and the `RestSender.clear()` semantics)
were independently re-verified line-by-line. Where the baseline's claim text and current code
diverge, current code is cited. Items marked HW cannot be closed from the simulator.*
