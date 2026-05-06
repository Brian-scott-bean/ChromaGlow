# ChromaGlow Development Log

> **AI assistants: Append to this file after every session. Read it at the start of every session.**

---

## 2026-05-06 — Home Layout Rebuild + All Day Scenes (Cursor)

### What was built
- **Home rebuild (`DashboardView.swift`)** — Threw out the per-section ad-hoc padding model entirely and rebuilt Home with the canonical SwiftUI dashboard pattern. The visual design is **identical** — every section component (TimeSuggestionBanner, NextAutomationBanner, presetsBar, RoomCard, summaryHeader, zonesSectionHeader, nowPlayingBar) is unchanged. Only the wrapper layout was rewritten.
- **New body shape**:
  - Root: `ScrollView` (no ZStack, no GeometryReader, no custom layout profile).
  - Content: a single `VStack(alignment: .leading, spacing: 14)` containing every section in order.
  - Horizontal inset: `.padding(.horizontal, 20)` applied **once** at the ScrollView's content. Sections never set their own horizontal padding.
  - Background: `DashboardAmbientBackground.ignoresSafeArea()` lives on the `.background { ... }` modifier, not as a ZStack sibling. This decouples its safe-area behavior from content sizing.
  - Toast: `.overlay(alignment: .top)` for the orchestrator toast and `.overlay(alignment: .bottom)` for the preset toast.
  - Grid: `[GridItem(.adaptive(minimum: 170))]` — auto-balances to 1 column on iPhone SE (335pt content < 2*170+spacing) and 2+ columns on every larger device with no breakpoint logic. The `useWideCards` AppStorage flag forces 1-column when desired.
- **Presets row bleed** — `.padding(.horizontal, -20)` then `.padding(.leading, 20)` so the first chip aligns with the rail and the trailing chips scroll under the screen edge (Apple Music / App Store pattern).
- **Removed dead code** — `HomeLayoutProfile` struct, `homeLayout` computed property, `homeContentRail` wrapper, `roomScrollView`, `roomsGrid`, `zonesGrid`, the unused `sizeClass` and `dynamicTypeSize` environment reads, and the debug HUD in `MainTabView`.
- **All Day Scenes (Circadian Auto-Pilot)** — One-time location permission, local solar curve (sunrise/sunset), throttled grouped_light updates via `allDayRestSender`, persisted via `UserDefaults`. Settings UI in `AllDayScenesView` (toggle, set/refresh location, anchor summary).

### Functionality preserved (no regressions)
- ✅ Ambient time-of-day gradient background
- ✅ Greeting, on/off counter, status dot
- ✅ Time-aware suggestion banner with one-tap CTA
- ✅ Next-automation banner with countdown chip + multi-automation sheet
- ✅ Horizontal preset rail (Energize/Read/Relax/Sleep + favorited room scenes)
- ✅ Now-playing strip with multi-effect dropdown and "Stop"/"Stop All"
- ✅ Room cards: glow color, brightness slider, power toggle, ellipsis, scale animations, equatable diffing, SSE-driven optimistic state
- ✅ Collapsible Zones section, persisted via @AppStorage
- ✅ Pull-to-refresh, NavigationLink to RoomDetail, simultaneousGesture for SSE suppression
- ✅ Toast notifications, demo-mode title decoration
- ✅ Toolbar items (settings, power-all, layout toggle)
- ✅ Empty state and shimmer state

### What's working
- ✅ Linter clean (`DashboardView`, `MainTabView`).
- ✅ All Day Scenes feature compiles, persists state, and respects the latest-wins `RestSender` mailbox.

### What's left
- [x] User QA pass on iPhone SE (3rd gen) portrait completed via screenshot validation.
- [ ] User QA pass on iPhone mini / standard / Max + iPad (screenshot matrix).
- [ ] AI Scene Generation (next differentiator after Home QA).

### Gotchas
- `.adaptive(minimum:)` is the responsive grid contract — do not replace with custom screen-width math.
- The presets row bleed uses `.padding(.horizontal, -20)` followed by `.padding(.leading, 20)` — both modifiers are required; removing either breaks leading alignment or collapses the bleed.
- The ambient background MUST be applied via `.background { … }` modifier (not a ZStack sibling). A sibling with `.ignoresSafeArea()` propagates safe-area behavior to siblings via the ZStack's coordinate space, which is what caused the original SE clipping.
- Sections that produce intrinsic-width content (e.g. a plain `Text`) will leave whitespace on the right inside the leading-aligned VStack. Every section in `content` either uses HStack+Spacer or a LazyVGrid, both of which fill the proposed width.

### Current state
SE portrait validation is complete and looks correct. Home layout rebuild is stable; remaining step is cross-device matrix validation (13/14, Pro Max, iPad) before tagging a checkpoint.

---

## 2026-05-05 — Composer Engine Built (Antigravity/Gemini)

### What was built
- `CompositionModels.swift` — 4 layer configs (Palette, Motion, Envelope, Reaction) with full render math
- `CompositionEngine.swift` — Pure render engine, outputs CIE xy + brightness per light per frame
- `CompositionStore.swift` — JSON persistence + 20 built-in presets (5 ambient, 3 energetic, 12 holidays)
- `StudioViewModel.swift` — Added `.composition(presetID:)` strategy, `composerStudioCards`, apply/stop
- `UnifiedOrchestrator.swift` — Added `startCompositionMode()` with dual-transport (DTLS 25fps / REST 5fps)

### What's working
- ✅ All engine code compiles (BUILD SUCCEEDED)
- ✅ Existing Studio effects (Deck 1+2) unchanged and functional
- ✅ Multi-room concurrent effects still working
- ✅ 20 presets seed on first launch via JSON

### What's left (for next session)
- [ ] Phase 3A: Add Deck 3 to StudioView card carousel
- [ ] Phase 3B: Mixer tray layer tabs for compositions
- [ ] Phase 3C: Layer-specific slider controls
- [ ] Phase 3D: Save flow (name input → persist → new card)
- [ ] Phase 4: Polish (animations, haptics, seasonal banner)

### Gotchas
- `StudioStrategy` now requires `Equatable` conformance (added)
- `composerStudioCards` is a computed property, not a stored let (updates when store changes)
- Slider values write directly to `activeCompositionBox` — no debounce or API call needed
- The `sendColorParam` method searches `composerStudioCards` array too (line ~483)

### Current tag
`v0.17.0-cursor-ready`

---

## 2026-05-05 — Composer Phase 3A: Deck 3 UI (Cursor)

### What was built
- **`StudioView.swift`** — Third carousel page (Composer): category chips (`PresetCategory.allCases`), animated gradient-border **+ Create** hero, filtered preset grid with same `StudioCardView` as other decks, three deck dots, rename alert. Long-press context menu: Edit, Rename, Duplicate, Delete. In-season presets sort to the top; Holiday chip gets extra border emphasis when any preset `isInSeason`.
- **`StudioViewModel.swift`** — Hidden starter template preset (`composerStarterDraftPresetID`) excluded from grid; `applyStarterComposition()`, `ensureComposerStarterDraft()`, `studioCard(for:)`, `composerPresets(for:)`, `renameCompositionPreset`, `duplicateCompositionPreset`, `deleteCompositionPreset`; `sendParam` lookup includes starter card.

### What's working
- ✅ `xcodebuild` generic iOS **BUILD SUCCEEDED**

### What's left
- [ ] Phase 3B: Mixer layer tabs for compositions
- [ ] Phase 3C: Layer sliders
- [ ] Phase 3D: Save sheet

### Gotchas
- Starter draft is persisted on first **+ Create** (not one of the 20 built-ins). Grid omits it by ID so it never appears as a card.
- `+ Create` title includes a leading “+” and a `plus.circle.fill` icon (slight redundancy).

### Current state
Phase 3A complete; ready for 3B.

---

## 2026-05-05 — Composer Routing + Queue Race Fixes (Cursor)

### What was built
- **`UnifiedOrchestrator.swift`** — Composer entertainment selection now matches room light refs to config lights (no blind `.first` config). Added Studio generation counter + `studioRestSender.clear()` on start/stop, and generation guards in Composer REST loop/enqueued closures to block stale delayed sends after stop/switch.
- **`SyncModeEngine.swift`** — `RestSender` gained `clear()` to drop pending mailbox work safely.
- **`StudioViewModel.swift`** — Added single-engine guard for `.appDriven`/`.composition` cards (stop other engine-based room effects before starting a new one). Added `apply(_:roomOverride:)` so the tapped room snapshot is used.
- **`StudioView.swift`** — Card taps now capture room snapshot and pass override into `apply`, removing selection race. Mixer header now shows explicit scope/transport badges (`ENT AREA`, `ROOM`, `COMPOSER: ...`).

### What's working
- ✅ `xcodebuild` generic iOS **BUILD SUCCEEDED** after each fix batch
- ✅ Room-target logs match user taps (`Hallway → Kitchen → Hallway → Main bedroom`)
- ✅ No delayed ghost re-activation observed after stop in retest

### What's left
- [ ] Phase 3B: Mixer layer tabs for compositions
- [ ] Phase 3C: Layer sliders
- [ ] Phase 3D: Save sheet
- [ ] Built-in preset UX: hide/unhide instead of delete

### Gotchas
- Studio engine in orchestrator is singleton (`activeStudioTask`); UI must enforce this to avoid conflicting room expectations.
- Room-selection race can occur if swipe/pick changes around tap time; using room snapshot at tap eliminates this.
- REST mailbox can still have one in-flight request; generation guards are required so stale closures no-op after stop.

### Current state
Composer room routing and delayed-send race appear stable in manual tests. Ready for Phase 3B implementation.

---

## 2026-05-05 — Composer REST backlog fix (Cursor)

### What was wrong
- `runCompositionREST` sent grouped_light PUTs every **200 ms (~5 Hz)**.
- `HueAPIClient` documents grouped_light at **~1 PUT/sec** — excess traffic queues on the bridge → **30–60 s lag** as stale commands drain.

### Fix
- Throttle Composer REST loop to **~1 Hz** (1.05 s spacing), dynamics ≈ **900 ms**. Logs/docs updated from “~5fps”.

### Current state
**BUILD SUCCEEDED**. Entertainment path unchanged (25 fps).

---

## 2026-05-05 — Composer Mixer UI (3B/3C) + Save (3D), Multi-room Notes (Cursor)

### What was built
- **`StudioView.swift`** — For `.composition` cards: mixer shows four layer tabs (Palette / Motion / Envelope / Reaction), tabbed controls bound directly to `vm.activeCompositionBox` (live sliders, pickers, toggles). Increased composer mixer tray height. Header save button (`square.and.arrow.down`) opens save sheet (name + SF Symbol grid).
- **`StudioViewModel.swift`** — `saveActiveComposition(name:icon:)` builds a `CompositionPreset` from `activeCompositionBox` and `compositionStore.save` (category `.myCreations`).

### Product / architecture notes (current behavior)
- **Multi-room:** Bridge-native effects (Deck 1) can still run in multiple rooms. **Composer and other `.appDriven` Studio engines are intentionally single-active globally** — applying in room B stops Composer/Live in room A (see earlier `StudioViewModel` guard). Matches one orchestrator Studio task + one Entertainment session per bridge.
- **Composer REST:** After grouped_light throttle fix, room-scoped REST Composer updates ~**1×/second**; smooth motion requires Entertainment path when config matches.

### What's left
- [ ] Phase 4 polish: tab cross-fade refinement, stronger haptics, seasonal banner, optional per-light REST path for smoother Composer without Entertainment

### Current state
Phase 3B–D composer mixer + save shipped in tree; verify on device with Entertainment vs REST badges.

---

<!-- NEXT SESSION: Append below this line -->

## 2026-05-06 — SE Portrait Layout Spike (Cursor)

### What was built
- Investigated compact-device clipping reports using iPhone SE (3rd gen) simulator screenshots across Home / Scenes / Studio.
- Ran multiple adaptive layout experiments on Home and tab-shell sizing (`DashboardView`, `MainTabView`, `HueHomeApp`) to test whether width clamping originated from section padding, grid strategy, or root container sizing.
- Reverted non-improving runtime layout experiments after validation so no unstable SE workaround remains in shipped UI code.
- Added roadmap context in `DEVDOC.md` for post-Composer differentiators (AI scene generation first, then sharing, weather-reactive, and Tier 2 items).

### What's working
- ✅ Build passes after cleanup (`xcodebuild` BUILD SUCCEEDED).
- ✅ Studio still renders cleanly on SE (useful baseline for Home refactor target).
- ✅ Existing Composer 3B/3C/3D + routing/queue fixes remain intact.

### What's left
- [ ] Refactor Home layout architecture to match Studio's deterministic container model.
- [ ] Introduce one Home content rail + breakpoint profile (compact/standard/large) instead of per-section ad-hoc sizing.
- [ ] Validate SE portrait first, then iPhone standard/Max and iPad, with screenshot matrix before release.

### Gotchas
- SE issue appears architectural (root/intrinsic width interactions across mixed sections), not a simple padding tweak.
- Landscape can look acceptable while compact portrait fails, so portrait-on-small-device must be the primary acceptance gate.

### Current state
SE portrait Home still needs a structural refactor; experimental quick fixes were rolled back. Next step is a focused Home layout-system pass while preserving current visual style.

---

## 2026-05-06 — AI Scene Generation Architecture Artifact + UX Decisions (Cursor)

### What was built
- Created a new canvas artifact at `canvases/ai-scene-gen-and-composer-revamp.canvas.tsx` describing:
  - AI Scene Generation architecture (`prompt -> provider -> validate -> CompositionPreset -> Composer engine -> lights`)
  - Provider strategy (FoundationModels-first, optional cloud fallback, local curated fallback)
  - Data contract constraints for generated `CompositionPreset` values
  - Progressive disclosure rules for Composer tools (essential vs advanced controls)
  - Visual flow mockups for top bar, AI generation states, and 2-axis hue control concept
- Iteratively rewrote the artifact to incorporate product decisions from live review feedback.

### Product/UX decisions captured
- Keep **room picker** as the primary navigation anchor in Studio (explicitly prioritized).
- Remove top deck-name labels if there is a conflict with room-picker clarity.
- Keep AI entry as a **pill**.
- Keep visible **AI badge** on generated cards.
- Default AI apply scope = **current room**.
- Regenerate flow clarified with simple UX framing (live regenerate + card-level regenerate).

### Follow-up decision (latest)
- User requested to **keep room picker exactly as-is** for now (no immediate room-picker redesign implementation).

### What's left
- [ ] Choose first implementation slice (recommended: AI pill shell + state handling, or HueRail prototype behind flag).
- [ ] Convert selected parts of artifact into concrete StudioView/StudioViewModel tickets.

### Current state
Architecture and UX artifact is complete and updated with current decisions. No production Studio code changes were applied in this session.

---

## 2026-05-06 — Documentation Refresh (Cursor)

### What was built
- Updated `CURSOR_KICKOFF.md` from a Composer build-instruction doc to a current-state kickoff.
- Reframed kickoff around what is already shipped vs what remains (polish, QA, transport/stability checks).
- Updated `COMPOSER_SPEC.md` with a top-level implementation status section and historical-plan clarifications.
- Corrected stale strategy references in `COMPOSER_SPEC.md` from `composition(preset:)` to `composition(presetID:)`.

### What's working
- ✅ Session onboarding docs now align with current implementation state.
- ✅ Future sessions can start from active priorities instead of already-completed phases.

### What's left
- [ ] Run cross-device screenshot QA matrix and record outcomes.
- [ ] Complete remaining Composer polish items (transitions, haptics, seasonal affordances).
- [ ] Begin first AI Scene Generation implementation slice once UI QA is green.

### Gotchas
- Large planning docs can quickly become stale after rapid implementation phases; add explicit status headers to prevent accidental rework.

### Current state
Documentation is now synchronized for current v0.17.x direction; no runtime code paths changed in this session.

---

## 2026-05-06 — DEVDOC Consistency Pass (Cursor)

### What was built
- Updated `DEVDOC.md` Composer section to include a 2026-05-06 status note clarifying it is mostly implemented and now serves as architecture reference.
- Corrected stale strategy notation in `DEVDOC.md` from `StudioStrategy.composition(preset:)` to `StudioStrategy.composition(presetID:)`.
- Updated the roadmap block in `DEVDOC.md` to mark Composer core as done and set `v0.17.x` focus to polish + QA + transport UX hardening.

### What's working
- ✅ `DEVDOC.md`, `CURSOR_KICKOFF.md`, and `COMPOSER_SPEC.md` now align on Composer status.

### What's left
- [ ] Cross-device screenshot matrix pass (Home + Studio Deck 3).
- [ ] Remaining Composer polish items and transport UX validation.

### Gotchas
- Historical design sections are still useful but need explicit status annotations to prevent duplicate implementation work.

### Current state
Primary documentation is synchronized with current implementation state; no production code changes in this pass.

---

## 2026-05-06 — Composer AI Pill + Prompt Generation v1 (Cursor)

### What was built
- Updated `StudioView.swift` Composer `+ Create` hero to support inline AI mode:
  - Added a small `wand.and.stars` affordance on the create pill.
  - Tapping AI expands the same pill into prompt input with `Generate` and `Cancel`.
  - Added inline loading state and error messaging beneath the hero.
- Added AI generation pipeline in `StudioViewModel.swift`:
  - Introduced a local-first `AICompositionGenerator` abstraction (`AICompositionDraft` + error type).
  - Added `generateCompositionFromPrompt(_:)` with input trimming, prompt-length validation, generation lock, and user-facing error/status messages.
  - Generated outputs map directly to valid `CompositionPreset` objects and save into `CompositionStore` as `.myCreations`.
- On successful generation, Studio now auto-applies the generated preset to the captured room snapshot and opens live mixer flow.

### What's working
- ✅ `xcodebuild` generic iOS build succeeds after changes.
- ✅ AI flow uses the same creation surface (no modal detour) and keeps one-tap Composer mental model intact.
- ✅ Guardrails in place for empty prompts, duplicate taps while generating, and recoverable generation failures.

### What's left
- [ ] Swap local heuristic generator to FoundationModels-backed provider behind the same abstraction.
- [ ] Add persisted AI badge metadata for generated presets (model field + migration-safe decode path).
- [ ] Tune prompt UX copy and optional suggested prompt chips.

### Gotchas
- Nested button interactions in the create hero can cause accidental trigger overlap; implementation avoids this by separating create and AI actions into explicit independent buttons.
- Generation is currently deterministic/local by design to keep UX stable while backend provider is integrated.

### Current state
AI entry is now integrated into Deck 3 creation pill and is production-safe for local generation. Foundation model provider wiring is the next implementation slice.

---

## 2026-05-06 — Composer Polish: Layer Activity + Seasonal Banner (Cursor)

### What was built
- Added Composer layer-activity metadata to `StudioCard` via new `compositionLayerActivity` payload.
- Implemented preset-derived layer activity detection in `StudioViewModel` to flag active/customized layers (`palette`, `motion`, `envelope`, `reaction`).
- Updated `StudioCardView` to render compact layer chips (`🎨 🌊 📈 🎤`) with active vs inactive styling for Composer cards.
- Added a lightweight seasonal banner in Deck 3 when seasonal presets are currently active.
- Refined composition tab content transition with a subtle fade+scale identity swap for cleaner layer switching feel.

### What's working
- ✅ Build succeeds after polish updates.
- ✅ Composer cards now show at-a-glance layer activity affordance.
- ✅ Seasonal context appears without changing existing deck flow.

### What's left
- [ ] FoundationModels provider integration behind current AI generator abstraction.
- [ ] Cross-device screenshot matrix validation for Home + Studio Deck 3.
- [ ] Final transport UX hardening checks for ENT vs REST labels/behavior.

### Gotchas
- Adding fields to `StudioCard` required updating every catalog card constructor to keep init sites compiling.

### Current state
Composer polish advanced with visual layer activity cues and seasonal deck affordance; compile status remains green.
