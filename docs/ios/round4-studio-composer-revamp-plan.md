# Round 4 — Studio & Composer UX/UI Revamp ("Stage Redesign") — BUILD-READY PLAN

**Written:** 2026-07-06 by Claude, at the end of Round 3, explicitly so a FRESH context
window can execute this plan with no other conversation history.

**Read order for the executor:** `AGENTS.md` → `DEVLOG.md` Current Status Snapshot + the four
2026-07-06 `[Claude]` entries → `docs/ios/composer-studio-mic-audit-2026-07-06.md` (§6 has the
Round-3 capability matrix + design) → this file. The visual reference is the published design
spec artifact: https://claude.ai/code/artifact/52839d43-4209-403f-98d3-b16f073b1ad0

---

## 0. TL;DR for the executor

Round 3 shipped all the MACHINERY (universal beat panel, Hue power A–G, Perform surface,
sequencer — see DEVLOG). Round 4 is the **visual + structural revamp of Studio and Composer**
so the app looks and feels like the design spec end-to-end:

1. **Extract Composer out of `StudioView.swift`** (3,160 lines) into `UI/Composer/` — pure,
   behavior-identical file moves first.
2. **Build StageKit** — the small reusable component set the spec's mockups use (cards,
   labeled sliders, animated pattern strips, badges).
3. **Reskin** the Composer editor, Studio decks, and Effects cards with StageKit.
4. **Finish the two shipped-but-unpolished surfaces**: composer beat panel unification and
   sequence-persistence UI.

Everything below is ordered, per-commit, with exact member names to move (verified against
source on 2026-07-06), acceptance criteria, and gates. No engine/transport changes anywhere
in this round.

**Starting state:** branch `ios-ref/hardening-p1-2026-07` @ `776a274`, suite 305/305 green,
scheme `HueHome 1`, tests on `platform=iOS Simulator,name=iPhone 15,OS=17.0`.
Build gate after EVERY commit:
`xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' build 2>&1 | rg -e 'error:' -e 'BUILD SUCCEEDED' -e 'BUILD FAILED'`

---

## 1. Goals / non-goals

**Goals**
- Composer becomes a real module (`UI/Composer/`), not "Deck 3 inside StudioView".
- One visual system (StageKit) across Studio decks, Composer editor, Effects cards, and
  Perform — matching the design artifact's language: stage black `#0B0B0F`-class surfaces,
  Hue amber accent, condensed uppercase display labels, mono data labels, capsule pills,
  animated 8-segment pattern strips.
- The Composer editor reads as the spec's layered mixer: each layer (Color / Motion /
  Envelope / React) is a stage card; the beat controls are the SHARED BeatPanelView, not a
  bespoke block.
- Studio cards show a live animated "pattern signature" strip when running.
- Sequence persistence UI: sequences save/load with composition presets (model shipped in
  R3-D; only the UI wiring is missing).

**Non-goals (do NOT do these)**
- No changes to CompositionEngine, CompositionMixer, transports, RestSender/gate, BeatClock,
  or any `Core/` logic (except the one BeatPanelView extension in R4-5, which is UI).
- No Effects/Sync-tab LOGIC consolidation (standing backlog; binding rule: no new effect
  logic outside the Composer stack).
- No new pbxproj target changes beyond adding the new files (follow the handcrafted
  `C0DEC0DExxxx000000000000/1` UUID pattern; next free index at time of writing: `0138`).
  Main-target file refs use `path = HueHome/...`; test files use `path = ./HueHomeTests/...`.
  Each file needs FOUR pbxproj insertions: PBXBuildFile, PBXFileReference, group children,
  target Sources phase. Grep `C0DEC0DE0137` to find all four current insertion neighborhoods.

**Invariants (from AGENTS.md — non-negotiable)**
- @Observable only (no new ObservableObject).
- Never accumulate beat phase; derive from `BeatClock.snapshot()`.
- WCAG ≤3 Hz strobe clamp stays where it is.
- All model changes additive/decodeIfPresent (R4 has only one: none planned).
- Full suite green before every commit; append a `[Claude]` DEVLOG entry when the round ends.
- Per Brian's standing rule: create a rollback tag BEFORE the first commit.

---

## 2. Current structure — verified anchors

Line numbers WILL drift; anchor by symbol name with `rg -n "<name>" HueHome/UI/Studio/StudioView.swift`.

`StudioView.swift` (3,160 lines) contains three zones plus the whole Composer editor:
- **Zone A/B (Studio proper):** `roomRolodex`, `cardGrid`, `deckGrid(cards:deckIndex:)`,
  `composerGrid(deckIndex:)`, `deckDots` (now a named tappable switcher), `deckNames`.
- **Zone C mixer:** `mixerTray` (~:917–1200), `mixerDismissDragGesture`, `collapseMixer`,
  `expandMixer`, `resolvedMixerHeight`, `computeMixerHeight`.
- **Transport plumbing:** `clearPendingCompositionTransportPrompt`,
  `switchRunningCompositionTransport`, `applyCompositionQuick`,
  `composerPresetOverflowActions`, the transport `confirmationDialog` (remembers first
  choice since R3-A-6), Perform launch (`showPerform` / `performVM` state + amber
  `slider.vertical.3` button + `.fullScreenCover`).
- **Composer editor (ALL of this moves in R4-1):**
  `compositionMixerBody`, `beatQuickToggle`, `compositionSectionHeader`,
  `compositionSlider`, `reactionTargetLabel`, `reactionTargetToggleBinding`,
  `compositionPaletteControls`, `showHarmonyControls`, `filteredHarmonyRules`,
  `harmonyChipRow`, `harmonyChipButton`, `harmonyAccessibilityName`, `harmonySwatchPreview`,
  `harmonySwatchColor`, `swatchEditPopover`, `swatchHueBinding`, `swatchSatBinding`,
  `commitSwatchEdit`, `applyHarmonyToComposition`, `hueSaturationPad`,
  `patternIcons` / `sourceLabels` / `sourceIcons` (static dicts),
  `motionPatternIsSpatial`, `compositionMotionControls`, `directionControl`,
  `motionAngleDial`, `spatialMiniMap`, `entertainmentAreaPrompt`,
  `recomputeSpatialPositions`, `compositionEnvelopeControls`,
  `compositionReactionControls`, `reactionBeatControls`, `compositionSaveSheet`,
  `exportDynamicScene(named:)` + its state (`showDynamicScenePrompt`, `dynamicSceneName`)
  + the save-sheet state (`compositionSaveName/Icon/Transport`, `showCompositionSaveSheet`)
  + editor tab state (`activeCompositionTab`, `activeHarmonyRule`, `editingSwatch`).
- **StudioParamRow** (separate struct near the file bottom: `sliderRow`, `colorPickerRow`,
  `toggleRow`, `essentialParams`, `colorParams`) — used by non-composition cards; stays.

Other relevant files (all already shipped, don't rebuild):
- `UI/Components/BeatPanelView.swift` — `BeatPanelCapabilities` (incl. unused-so-far
  `.colorStep/.motionLock/.punchDecay` flags), `BeatPanelView`, `BeatStatusChip`,
  `ChipPickerRow`, `BeatChipButton`.
- `UI/Performance/PerformanceView.swift` — Perform + sequencer sheet + `PerformanceViewModel`
  (has `sequence: CompositionSequence`, `playSequence/stopSequence`, `captureCurrentStep`).
- `Core/Composer/SequencePlayer.swift` — `CompositionSequence` (+ `CompositionPreset.sequence`
  optional field, already Codable-wired and test-locked).
- `UI/Components/HueTokens.swift` — `HuePalette.amber`, `HuePalette.Noir.*`, `HueSpacing`.
- Design-language source of truth: the artifact's footer tokens — stage `#0B0B0F`, surface
  `#16161D`, raised `#1E1E27`, line `rgba(242,240,234,0.10)`, ink `#F2F0EA`, muted `#8F8C99`,
  amber `#FFB84D` (app uses `HuePalette.amber #FFC107` — KEEP the app's amber), live green
  `#6FE3A5` (≈ `HuePalette.Noir.success`). Display type = SF system, heavy weight, uppercase,
  +tracking (the artifact's Avenir-Condensed look is approximated with
  `.system(size:weight:.bold)` + `.tracking(1.0–1.4)` + `.textCase(.uppercase)` — do NOT
  ship a custom font).

---

## 3. Commit sequence

### R4-0 · Checkpoint + kickoff (no code)
- `git tag checkpoint/pre-round4-<today>` (revert = `git reset --hard <tag>`; branch unpushed).
- Verify suite green before touching anything.

### R4-1 · Extract the Composer editor (pure move, zero visual change)
New files (pbxproj ×4 insertions each):
- `HueHome/UI/Composer/CompositionEditorPanel.swift` — a `struct CompositionEditorPanel: View`
  containing `compositionMixerBody` as its `body`, plus EVERY member in the "Composer editor"
  list in §2. Inputs it needs (pass in; all currently read from StudioView scope):
  `vm: StudioViewModel`, `orchestrator: UnifiedOrchestrator` (Environment),
  `@Binding activeCompositionTab`, `@Binding activeHarmonyRule`, `@Binding editingSwatch`,
  and closures/bindings for the save sheet + dynamic-scene prompt state (or move that state
  INTO the panel — preferred: the panel owns `showDynamicScenePrompt`, `dynamicSceneName`;
  the save sheet stays in StudioView because the deck's save button also uses it).
- Keep `compositionSaveSheet` in StudioView (it is presented from deck-level buttons).
- StudioView keeps: `.id("reactionBeatControls")` anchor + the ScrollViewReader auto-anchor
  `onChange` (verify it still finds the id inside the extracted panel — it will, same
  ScrollView).
**Acceptance:** StudioView.swift < 2,100 lines; pixel-identical UI; suite green; NO logic
edits — if a member needs modification to move, STOP and re-read (only access-level and
parameter plumbing changes are allowed in this commit).

### R4-2 · Extract the mixer tray shell
- `HueHome/UI/Studio/MixerTrayView.swift` — `mixerTray` + `mixerDismissDragGesture` +
  collapse/expand + height computation, parameterized on `vm`, the current `effect`, and a
  `content` closure so StudioView injects either `CompositionEditorPanel` or the
  `StudioParamRow` list. Transport badge/menu and Perform button move with the header.
**Acceptance:** StudioView.swift < 1,400 lines; identical behavior; suite green.

### R4-3 · StageKit component set
New file `HueHome/UI/Components/StageKit.swift`:
- `StageCard { header: (icon, title, subtitle?), content }` — the artifact's "ed-block":
  `RoundedRectangle(cornerRadius: 14)`, fill `Color.white.opacity(0.06)`, hairline stroke
  `white.opacity(0.10)`, 14–16pt padding, uppercase mono-tracked section label
  (10pt bold, `white.opacity(0.38)`, tracking 1.2).
- `StageSlider(title:value:range:format:)` — generalizes the existing `compositionSlider`
  (title left, mono value right, amber tint). Replace `compositionSlider` calls with it.
- `PatternStripView(pattern: MotionConfig.Pattern, accent: Color, animated: Bool)` — the
  8-segment animated signature from the artifact (chase = traveling hot cell with tail decay,
  twinkle = random per-cell pulse via deterministic per-index phase offsets, pulse_center =
  symmetric ripple, comet = traveling + long tail, spiral/wave/cascade = phase-offset sweep,
  scatter = shuffled phases, bounce = ping-pong, static = steady). Implementation:
  `TimelineView(.animation(minimumInterval: 1/12))` + `HStack` of 8 capsules whose opacity
  is a pure function `opacity(index:pattern:time:)` — write it as a static pure function so
  it's unit-testable (`StageKitTests`: monotonic wrap, 0…1 bounds, distinct signatures).
  Respect `accessibilityReduceMotion` (`@Environment(\.accessibilityReduceMotion)`) → static
  0.6 opacity.
- `StageBadge(text:style: .live/.amber/.muted)` — the LIVE / ENT AREA / coverage pill.
**Acceptance:** components render in previews; PatternStripView pure function tested
(new `HueHomeTests/StageKitTests.swift`, pbxproj ×4); no call sites yet; suite green.

### R4-4 · Composer editor reskin
In `CompositionEditorPanel`:
- Wrap each layer's controls in a `StageCard` (COLOR / MOTION / ENVELOPE / REACT icons:
  `paintpalette.fill`, `wind`, `waveform.path.ecg`, `bolt.fill`).
- Replace every `compositionSlider` with `StageSlider`.
- Motion card header shows a live `PatternStripView(pattern: current, animated: isRunning)`.
- Layer tab pills: keep behavior, adopt the StageCard label style.
- Keep ALL bindings identical — this commit is presentation only.
**Acceptance:** every existing control still present and functional (manually tick through:
mode picker, hue pad, harmony, sliders, pattern pills, direction dial, envelope pills +
sliders, react source pills, targets, beat controls, save-as-scene button); suite green.

### R4-5 · Beat panel unification in Composer
- Extend `BeatPanelView` with an optional `reaction: Binding<ReactionConfig>?` parameter;
  when non-nil AND capabilities contain `.punchDecay/.colorStep/.motionLock`, render those
  three controls (same bindings as today's `reactionBeatControls`: `punchDecay` slider
  0–100, `quantizeBeats` pills ¼/½/1/2/4 shown only when targets contains `.color` plus the
  `colorStepPerTrigger` slider, `motionBeatsPerCycle` pills Off/1/2/4/8).
- Replace `reactionBeatControls` in the editor with
  `BeatPanelView(capabilities: .composer, reaction: <binding to activeCompositionBox.reaction>)`
  wrapped in the React StageCard, keeping the `.id("reactionBeatControls")` anchor on it.
- Delete the now-dead bespoke `reactionBeatControls`.
**Acceptance:** all reaction beat controls still function (source .beat → punch decay etc.);
one beat panel implementation app-wide; suite green.

### R4-6 · Studio deck + Effects card reskin
- Studio running card: add `PatternStripView` (composition cards use the box's pattern;
  engine cards map strobe→static-blink signature is out of scope — give engine cards the
  `bounce` signature, commented as decorative).
- `EffectCard` (Effects tab): adopt StageCard visuals (shape/stroke/padding) WITHOUT changing
  its layout contract; running dynamic cards get a small animated strip. Coverage badge
  becomes `StageBadge(.muted)`.
- Deck switcher pills + mixer header adopt the label style.
**Acceptance:** no functional changes; visual consistency across the three decks and the
Effects tab; suite green.

### R4-7 · Sequence persistence UI (closes the R3-D gap)
- `PerformanceViewModel`: add `presetID: UUID?` (pass from StudioView launch site — the
  running composition's preset id is `vm.currentRoomEffect`-adjacent; StudioViewModel resolves
  the running preset via `compositionStore.presets.first(where:)` — see `applyCompositionQuick`
  for the id plumbing pattern) + `func saveSequenceToPreset(store: CompositionStore)` that
  writes `preset.sequence = sequence` and `store.save(preset)`.
- On Perform open: if the launching preset has `sequence`, preload it into the VM.
- Sequence sheet: add a "Save with composition" button (disabled when `presetID == nil`).
**Acceptance:** create steps → save → kill/relaunch flow (simulator): reopening Perform on
that preset shows the steps (unit-test the store round-trip instead of UI where possible —
extend `BeatMathTests`' sequencer section); suite green.

### R4-8 · Docs
- Append the dated `[Claude]` DEVLOG entry (Branch/Did/Working/Left/Validation/Gotchas).
- Update `docs/ios/composer-studio-mic-audit-2026-07-06.md` §3 structural-liabilities note
  (Composer module boundary now exists) and §6 status line.
- Refresh the design artifact if visuals drifted from the mockups (optional).

Order: R4-0 → R4-1 → R4-2 (structural, riskiest for merge conflicts — do first while the
tree is quiet) → R4-3 → R4-4 → R4-5 → R4-6 → R4-7 → R4-8. Each commit independently
shippable; stop cleanly at any boundary.

---

## 4. Verification

- **Per commit:** build gate + full suite
  (`xcodebuild … test 2>&1 | rg -e "TEST SUCCEEDED" -e "TEST FAILED"`); suite is 305 at
  round start and must never drop.
- **Extraction commits (R4-1/2):** additionally `git diff --stat` sanity — StudioView loses
  what the new files gain; `rg` that no moved symbol still exists in StudioView.
- **New tests:** `StageKitTests` (pattern-strip pure function), sequencer persistence
  round-trip (R4-7).
- **Manual simulator pass at round end:** every Composer control listed in R4-4 acceptance;
  Perform open→sequence→save→reopen; Effects card badges; deck switching; beat chip popovers
  on all three surfaces.
- **On-device (Brian):** unchanged Round-3 checklist in audit doc §4/§4b/§6.3 still pending;
  Round 4 adds nothing device-only (pure UI), but re-run a 10-min composition + Perform soak
  to catch any editor-refactor regression in live param plumbing (sliders → running lights).

## 5. Deliberately open (executor's judgment)
- Exact split if `CompositionEditorPanel.swift` exceeds ~1,500 lines: prefer a second file
  `CompositionEditorSections.swift` for the motion/direction-dial cluster; keep ONE public
  entry view either way.
- Whether Effects-tab reskin (R4-6) lands before R4-5 — they're independent.
- Micro-animations (deck transitions, card springs): keep or add only where they don't
  fight `accessibilityReduceMotion`.
