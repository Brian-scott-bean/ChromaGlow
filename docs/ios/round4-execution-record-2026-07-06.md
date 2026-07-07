# Round 4 Execution Record — Stage Redesign, Effects Port, Scenes Library

**Date:** 2026-07-06 · **Branch:** `ios-ref/hardening-p1-2026-07` @ `c01b814` (13 code/docs
commits, local/unpushed) · **Rollback:** `git reset --hard checkpoint/pre-round4-2026-07-06`
**Companions:** `round4-studio-composer-revamp-plan.md` (the build-ready plan, now banner-marked
executed), `composer-studio-mic-audit-2026-07-06.md` (Round-3 context), the Round-4 DEVLOG entry
(session handoff), and the design spec artifact:
https://claude.ai/code/artifact/52839d43-4209-403f-98d3-b16f073b1ad0

This record is the durable "everything you'd need to know" document: intention, what shipped,
design decisions with rationale, contracts future code must respect, limitations, and follow-ups.

---

## 1. Intention

Before Round 4 the app had DJ-grade machinery (BeatClock with audio tempo, pure CompositionEngine,
DTLS streaming, CompositionMixer crossfades, WCAG-clamped punch pads) behind a settings-app UI:
stock sliders in lists, controls 3 taps deep, three parallel effect surfaces with duplicated
catalogs, and dead knobs. Round 4 makes the interface match the engine.

The design spec's five principles ARE the intention:

1. **The room is the screen** — the phone is a controller for a show happening in physical space;
   everything must read in a dark room at arm's length.
2. **One tap, you're live** — entering any surface never interrupts the running composition.
3. **The beat is the grid** — one clock, one visible face (the amber chip), drives every effect.
4. **Big, forgiving, momentary** — destructive-feeling actions are hold-to-engage, self-releasing.
5. **Honest state, always** — transport, clock source, and per-light capability are shown, never
   papered over.

Structural intention added during execution (user-approved): **Studio = the stage** (create,
perform), **Scenes = the library** (what you saved, with provenance). The full "Library" merge of
composition presets into the Scenes tab was considered and deferred (Round-5-sized; would
restructure Studio Deck 3's relationship to the store).

## 2. What shipped (commit map)

| Commit | What |
|---|---|
| `622ece3` | R4-1: Composer editor (33 members) → `UI/Composer/CompositionEditorPanel.swift`. Pure move. StudioView 3,160 → 1,868 lines. |
| `fa1a39b` | R4-2: mixer tray → `UI/Studio/MixerTrayView.swift` (header, content switch, drag gesture, badge helpers). StudioView → 1,503. |
| `379fc3e` | R4-3: **StageKit** (`UI/Components/StageKit.swift`) + `StageKitTests` (7). |
| `5559818` | R4-4: Composer editor reskin — 4 layer StageCards, 16 StageSliders, live Motion strip, stage tab pills. |
| `57152c2` | R4-5: beat panel unification — `BeatPanelView(reaction:)` renders punch decay / color step / motion lock; bespoke block deleted; first `.composer` capability consumer. |
| `889a843` | R4-6: Studio deck reskin — pattern strips on running cards, stage deck pills, header badges. |
| `20bb780` | Effects port 1/2: 4 new firmware cards + speed on Opal/Glisten; per-light effects_v2 upgrade after the v1 blanket; live per-light speed/tint sliders; coverage badges. `StudioEffectsV2Tests` (4). |
| `b69e926` | Effects port 2/2: deleted the unreachable EffectsView/EffectControlsView/EffectsViewModel/SyncModeView/TabShells (~3,000 lines); moved EffectParamState + Array[safeIndex:] out first; removed dead Music Sync/Gaming cards + `.studioStartMicSync`; migrated MultiBridgeRoutingTests 3-for-3. |
| `1ab27b1` | R4-7: sequence persistence — presetID plumbing (draft sentinel = unsaved), preload on Perform open, "Save with composition", store round-trip test. |
| `84835b5` | Scenes 1/3: SceneProvenanceStore (STUDIO badges) + favorites on the tab. `SceneProvenanceStoreTests` (9). |
| `27f6a74` | Scenes 2/3: full StageKit reskin of ScenesTabView (zero `Color(red` literals, VoiceOver, Reduce Motion). |
| `72147dd` | Scenes 3/3: unified creation — toolbar `+` menu → Capture Room Look / Build Colors… (`SceneBuilderLauncherView` → existing `SceneColorBuilderView`); `LightDisplayItem(from: HueLight)`. |
| `c01b814` | Docs: DEVLOG entry, audit-doc + plan-doc status updates. |

Suite: 305 → **327** tests, green per commit (build gate + full suite on iPhone 15 / iOS 17.0).

## 3. Architecture after Round 4

```
HueHome/UI/
  Composer/CompositionEditorPanel.swift   ← the 4-layer editor (was inside StudioView)
  Studio/StudioView.swift (1,536)         ← shell: rolodex, decks, transport plumbing, dialogs
  Studio/MixerTrayView.swift              ← Zone-C tray: header + editor/param-row content
  Studio/StudioViewModel.swift            ← + effects_v2 upgrade path, coverage, v2CapableLightIDs
  Components/StageKit.swift               ← design system (see §4)
  Components/BeatPanelView.swift          ← ONE beat panel app-wide (+ reaction: binding)
  Performance/PerformanceView.swift       ← + presetID/store, sequence save/preload
  Scenes/ScenesTabView.swift              ← stage reskin, provenance badges, favorites, + menu
  Scenes/SceneBuilderLauncherView.swift   ← room picker → SceneColorBuilderView
Core/Models/SceneProvenanceStore.swift    ← STUDIO badge registry + FavoriteSceneCSV helpers
```

Deleted (unreachable since the v0.15.0 nav rework — MainTabView is 4 tabs Home/Scenes/Studio/More):
`UI/Effects/EffectsView.swift` (incl. EffectCard), `UI/Effects/EffectControlsView.swift`,
`Core/ViewModels/EffectsViewModel.swift`, `UI/Sync/SyncModeView.swift`,
`UI/Navigation/TabShells.swift`. Kept deliberately: `Core/Effects/HueEffect.swift` (EffectLibrary
is live via automations), `SavedEffectPreset.swift` (user data + relocated EffectParamState),
`SyncModeEngine.swift` (defines RestSender), `EffectEngine.swift` (gate-pacing test double).

pbxproj: handcrafted `C0DEC0DExxxx` indexes now consumed through `013F`. New group
`C0DEC0DE0138…0002 /* Composer */` under UI. Note the pre-existing quirks: Studio UI files live
under a group literally named "Scenes"; Core's "Composer" group holds PerformanceView.swift.

## 4. StageKit — usage guide for future surfaces

Tokens (`StagePalette`): `stage #0B0B0F` (screen bg) · `surface #16161D` · `raised #1E1E27` ·
`ink #F2F0EA` · `muted #8F8C99` · `line` = white 0.10 hairline. Accents stay sourced from
`HuePalette.amber` (#FFC107) and `HuePalette.Noir.success` (live green). Display type = SF bold +
`.tracking(1.0–1.4)` + uppercase (deliberate approximation of the spec's Avenir Next Condensed —
no custom font shipped).

Components:
- `StageCard(icon:title:subtitle:content:)` — radius-14 surface card with uppercase tracked label.
- `StageSlider(title:value:range:format:)` — title left, mono value right, amber tint.
- `StageBadge(text:style:)` — `.live` / `.amber` / `.muted` status pills (LIVE, ENT AREA, coverage,
  STUDIO).
- `PatternStripView(pattern:accent:animated:)` — 8-capsule animated signature.
  `TimelineView(.animation(minimumInterval: 1/12))` over the **pure static function**
  `StageStripMath.opacity(index:pattern:time:)`. Reduce Motion (or `animated: false`) → static 0.6.

**Rule:** StageStripMath must remain a pure function of (index, pattern, time) — no accumulated
state. `StageKitTests` locks 0…1 bounds, determinism, per-pattern periodicity, pairwise signature
distinctness, and hot-cell travel; extend the tests if you add a pattern.

## 5. Contracts future code must respect (all test-locked)

- **Favorites CSV** (`@AppStorage("favoriteSceneIDs")`): comma-joined **raw** `bridgeSceneID`
  UUIDs, order-preserving — never the composite id. Writers: RoomDetail + Scenes tab (via
  `FavoriteSceneCSV`); reader: Dashboard pills. (`SceneProvenanceStoreTests`)
- **Provenance keys** (`castchroma.studioExportedSceneKeys`): the composite `GlobalSceneItem.id`
  format `"bridgeID:sceneID"` — byte-identical to the orchestrator's join. (`SceneProvenanceStoreTests`)
- **Sequence persistence:** `CompositionPreset.sequence` is nil-additive; empty steps save as nil.
  The "+ Create" draft sentinel `StudioViewModel.composerStarterDraftPresetID` counts as UNSAVED —
  never attach a sequence to it. (`BeatMathTests` sequencer section)
- **Bridge-native activation order:** per-light v1 blanket first (Studio's proven path — the old
  Effects code's grouped_light `effects` blanket contradicts `StudioStrategy.groupedLightOnlyEffects`
  and the repo Hue rules; do NOT adopt it), THEN gate-paced per-light effects_v2 upgrade with
  `retry: false` (a 400 leaves that light on the blanket). Live sliders target only
  `RunningEffect.v2CapableLightIDs` through the studio latest-wins mailbox + BridgeCommandGate.
  (`StudioEffectsV2Tests`, `MultiBridgeRoutingTests`)
- **Coverage semantics:** `EffectCapabilityResolver` is v2-first — a light exposing any effects_v2
  list is judged only by it. This is why Color Loop honestly shows NOT SUPPORTED on modern firmware.
- **Extraction seams:** `applyHarmonyToComposition` + both harmony `onChange` handlers stay in
  StudioView (the restore chain must fire while the tray is unmounted). The
  `.id("reactionBeatControls")` anchor + its ScrollViewReader both live inside MixerTrayView's
  subtree. `collapseMixer`/`expandMixer` + tray height math stay in StudioView (Live Controls pill
  and card taps use them).
- **Testing seam:** `setLightEffectV2` is an HueAPIClient *extension* method — spies must override
  the `put(path:body:ip:token:)` class method, not the extension.

## 6. Decisions and rejected alternatives

- **Port + delete (chosen) vs reskin the dead Effects tab vs resurrect the tab.** R3-B's
  effects_v2 work had landed only in unreachable UI; porting to Studio Deck 0 makes it real,
  deleting removes the trap that swallowed a whole feature phase. Resurrecting a 5th tab would
  reverse the deliberate v0.15.0 four-tab decision.
- **Scenes keeps its tab, reframed as the library (chosen) vs full Library merge vs defer.**
  Scenes is the daily-driver surface for non-DJ moments; the merge is Round-5-sized.
- **Remove Music Sync/Gaming cards (chosen) vs wire to mic compositions vs leave.** They posted
  `.studioStartMicSync` to zero observers — silent no-ops. Mic-reactive lighting lives in Composer
  reaction sources + Perform; the cards can return properly wired later.
- **All-Rooms one-tap UI dropped** with the dead surface. The M-17/H-05 regression guards migrated
  to `applyAutomationEffect` (the surviving whole-home fan-out); Home-zone selection + automations
  cover the user story.
- **Keyframe timeline** remains rejected (Round-3 decision): the step sequencer covers "looks that
  evolve with the night" without a giant editing surface.
- **Segmented pickers → ChipPickerRow pills** in the beat section: a deliberate visible change for
  consistency with the panel and spec (flagged in advance, approved via the plan).

## 7. Limitations (honest edges)

- **UI-tier only.** No engine/transport changes: REST rooms remain rate-gated (~10 cmd/s),
  bar-boundary synced, with the slower punchBurst fallback; smooth per-beat needs an Entertainment
  Area over DTLS. The UI surfaces these limits (badges, disabled states) rather than hiding them.
- **Pattern strips are signatures, not previews** — stylized approximations. Engine cards get a
  decorative `bounce`; active dynamic scenes a decorative `wave`. Reduce Motion → static.
- **Capability honesty:** v1-only bulbs get the blanket effect without live speed/tint; Color Loop
  reads NOT SUPPORTED on modern firmware (true — it is not an effects_v2 value).
- **Provenance is local-only** (UserDefaults): doesn't sync across devices, lost on reinstall,
  stale keys are harmless no-matches. The bridge has no app-metadata field we rely on.
- **Favorites format inherited unchanged** (raw UUIDs — theoretical cross-bridge collision)
  because changing it would break existing users' pins.
- **Not yet validated on-device** — simulator + 327 unit tests only; physical-bridge checklist
  below.

## 8. Follow-ups / open items

- **Orphaned `activeEffectEntries` readers:** the Dashboard Now-Playing bar and the Tap-Dial
  punchBurst read state whose only writer died with EffectsViewModel (both were already dead in
  practice). Decide: wire StudioViewModel in, or remove the bar. Related dead wire: `.studioStopAll`
  posts with zero observers.
- **Production-orphaned engines:** `EffectEngine.swift` + SyncModeEngine's engine paths — keep for
  now (RestSender lives there; gate-pacing tests use EffectLoops); candidates for a later cleanup.
- **Keychain test flake (pre-existing):** `KeychainSharingTests.testForgetAllClearsSharedCredentialSurface`
  intermittently races `KeychainManagerTests`' legacy keychain writes through WidgetDataStore's
  legacy-credential fallback under parallel scheduling. Passes in isolation and on re-run. Fix =
  keychain test isolation.
- Standing backlog unchanged: iOS TLS pinning + log scrubbing (P0 audit items), Keychain access
  group migration, Effects/Sync engine consolidation, `OrchestratorTests.swift` exists on disk but
  is not in the test target.

## 9. On-device validation checklist (needs a physical bridge)

Everything in the Round-3 audit doc §4/§4b/§6.3, plus new for Round 4:

- [ ] Cosmos/Enchant/Sunbeam/Underwater run from Studio Deck 0; the speed slider visibly changes a
      v2-capable light while running; tint lands.
- [ ] Stop clears a v2-parameterized effect (per-light v1 `no_effect`).
- [ ] Coverage badges read correctly on a mixed room ("N OF M LIGHTS"); Color Loop shows NOT
      SUPPORTED on modern firmware (expected).
- [ ] 10-minute composition + Perform soak — editor-refactor regression check (sliders → running
      lights over both transports).
- [ ] Sequence: capture steps → Save with composition → force-quit → reopen Perform on that preset
      → steps restored.
- [ ] Composer export → Scenes tab shows the STUDIO badge on that scene only; delete clears it.
- [ ] Favorite from the Scenes tab appears on Dashboard pills and as the star in RoomDetail.
- [ ] Scenes `+` → Build Colors… on a room AND a zone; builder Cancel reverts bulbs.
- [ ] Reduce Motion ON: pattern strips and shimmer render static everywhere.
