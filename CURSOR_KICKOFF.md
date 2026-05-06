# Cursor Kickoff — Current State (v0.17.x)

> Composer foundation and core UI are shipped. Use this kickoff to avoid redoing completed work and to focus only on remaining polish + verification.

## Step 1: Read First

Read these files before making changes:

1. `.cursorrules` — non-negotiable architecture and API constraints
2. `DEVDOC.md` — latest architecture context and historical decisions
3. `DEVLOG.md` — latest implementation status and unresolved tasks
4. `COMPOSER_SPEC.md` — implementation status map (updated)

## Step 2: Current Composer Status

### Implemented
- Engine and models (`CompositionModels`, `CompositionEngine`, `CompositionStore`)
- Studio strategy and orchestrator wiring (`composition(presetID:)`, dual transport)
- Deck 3 in `StudioView` with category chips and `+ Create`
- Mixer tray layer tabs and core controls for Palette/Motion/Envelope/Reaction
- Save flow and preset CRUD actions (rename/duplicate/delete)
- Starter presets and seasonal ordering behavior

### Remaining focus
- Phase 4 polish:
  - Layer-tab transition refinement
  - Haptic consistency on composer-specific interactions
  - Seasonal visual affordance/banner polish
  - Optional stronger layer-activity affordances on cards
- Device QA matrix:
  - iPhone mini, standard, Pro Max, iPad
  - Verify Deck 3 density, tray sizing, and transport badges
- Stability checks:
  - Entertainment vs REST fallback UX consistency
  - No stale updates when stopping/switching rooms rapidly

## Step 3: Guardrails

1. Do not re-implement Composer core architecture.
2. Keep `StudioStrategy.composition(presetID:)` as the current contract.
3. Keep slider writes direct to `activeCompositionBox` (no debounce/API intermediary).
4. Do not violate bridge constraints:
   - no `effects` on `grouped_light`
   - respect REST mailbox latest-wins behavior
   - preserve generation guards around async effect loops

## Verify After Any Change

```bash
PROJ=/Users/brianbean/Desktop/huehome-pro-v0.3.0
xcodebuild -project "$PROJ/HueHome.xcodeproj" -scheme HueHome -destination 'generic/platform=iOS' build 2>&1 | rg -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

## Suggested Next Slice

1. Polish layer-tab transitions + haptics in `StudioView`.
2. Run cross-device screenshot matrix for Home + Studio Deck 3.
3. Record findings in `DEVLOG.md` and tag next checkpoint once matrix passes.
