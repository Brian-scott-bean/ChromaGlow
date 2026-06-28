# ChromaGlow Development Log

> **AI assistants: Append to this file after every session. Read it at the start of every session.**

---

## Current Status Snapshot

- Canonical agent context: `AGENTS.md`.
- Claude Code entry point: `CLAUDE.md` points to `AGENTS.md`.
- Live shared handoff: append-only entries in this `DEVLOG.md`.
- Git is the shared memory between tools; commit/push handoff updates when another agent needs them.
- iOS production anchor: native Swift/SwiftUI app in `HueHome/`.
- iOS build scheme: `HueHome 1` (not `HueHome`).
- Android baseline: native Kotlin/Jetpack Compose project exists under `android/`.
- Android completed baseline includes app shell, dark Material theme placeholders, demo fixtures, Android Keystore credential boundary, mDNS chooser, manual IP entry, NUPnP deferral record, and pairing TLS/identity blocker record.
- Android live pairing is blocked until safe TLS bootstrap and canonical bridge identity are decided.
- Latest local Android validation observed by Codex: Android Studio's bundled JDK plus `~/Library/Android/sdk` passed unit tests, lint, assembly, and all 17 connected tests on the `Pixel_10` AVD.
- Parallel multi-agent pipeline defined: lane registry, collision hotspots, execution-readiness gate, and the shared Claude⇄Codex Decision Log live in `docs/coordination/parallel-agent-pipeline.md`; the replacement Android Batch 1 manifest is a locally validated, execution-ready two-lane pilot.

### Handoff Entry Template

```markdown
## YYYY-MM-DD - [Codex|Claude|Cursor] Short title

### Branch
- `branch-name`

### Did
- ...

### Working
- ...

### Left
- ...

### Validation
- ...

### Gotchas
- ...
```

---

## 2026-06-28 - [Codex] Batch 1 adversarial review

### Branch
- Docs review: `docs/parallel-agent-pipeline`
- Reviewed integration: `integration/parallel-batch-1` @ `2a156b5`

### Did
- Confirmed Batch 1 lane branches are disjoint and the integration handoff records a fully green gate.
- Added D-007 for two pre-Batch-2 contract gaps: room `lightCount` values disagree with per-room demo fixtures, and `SceneDisplayModel` lacks explicit bridge routing required for cross-bridge activation.
- Confirmed no Batch 2 manifest or launch prompt exists yet; only the planning prompt is present.

### Working
- Batch 1 integration remains available on origin for correction and revalidation.

### Left
- Resolve D-007 on the Batch 1 integration branch and rerun the full Android gate.
- Then run `parallel-batch-2-prepare.md`, review its draft manifest, and create the Batch 2 launch prompt.

### Validation
- `git diff --check` passed for the docs review before publication.
- Runtime tests were not rerun; Claude's integrated handoff records 81 unit tests and 20 connected tests passing.

### Gotchas
- Do not merge Batch 1 to `main` merely because tests are green; the fixture and routing contracts become user-visible dependencies in Batch 2.

## 2026-06-28 - [Claude] Execute parallel Batch 1 two-lane Android pilot

### Branch
- Integration: `integration/parallel-batch-1` @ `2a156b5` (forked from `origin/main` @ `defe8691`).
- Lanes: `lane/android1-domain-models` @ `be51edd`, `lane/android1-dashboard-controls` @ `c25b9ac`.
- Not merged to `main` — awaits the human collaborator's final merge.

### Did
- Ran the first real parallel-pipeline batch end to end as batch owner. Re-fetched and re-verified the
  pinned base `defe8691…`, confirmed the local Android toolchain (JDK 21 / SDK / `Pixel_10` AVD),
  created `integration/parallel-batch-1` and two isolated lane worktrees off the base.
- Launched both lanes concurrently (Claude Workflow, one sub-agent per lane, disjoint globs):
  - L1 `android-models`: added `LightDisplayModel` + `SceneDisplayModel` and additive
    `DemoFixtures.lights` / `lightsByRoom` / `scenes` with JVM unit tests; kept `rooms` /
    `DEMO_BRIDGE_ID` byte-identical.
  - L2 `android-dashboard`: added an on/off `Switch` + brightness `Slider` to `DemoRoomRow` (in-memory
    session state, no persistence) with a Compose UI test; preserved the status-line text and the
    `DashboardPlaceholderScreen` public signature so the nav-shell caller still compiles.
- Independently verified each branch changed only its permitted globs (lanes disjoint, zero §2-hotspot
  edits), then merged both into the integration branch with `--no-ff` (no conflicts).
- Marked both registry lanes `merged` and recorded the result in pipeline-doc §7.

### Working
- Integrated gate all green: `testDebugUnitTest` 81/0 failures · `lintDebug` clean · `assembleDebug` ok ·
  `connectedDebugAndroidTest` 20/0 failures on the headless `Pixel_10`.

### Left
- Human collaborator performs the final merge of `integration/parallel-batch-1` → `main` (agent `gh`
  account is not a repo collaborator). Lane/integration branches and worktrees are retained for review.
- L1 fixtures (`lights` / `lightsByRoom` / `scenes`) are intentionally unconsumed this batch — Batch 2
  (room-detail / scenes) is their first consumer; see `parallel-batch-2-prepare.md`.

### Validation
- Pre-launch: base SHA re-pinned and unchanged; toolchain present; baseline already validated (D-005).
- Per lane: L1 `./gradlew testDebugUnitTest` green; L2 `./gradlew connectedDebugAndroidTest` green.
- Integrated: `testDebugUnitTest lintDebug assembleDebug` + `connectedDebugAndroidTest` all green with
  the manifest toolchain exports.

### Gotchas
- The workflow sub-agents' background emulator is reaped when the run ends; the batch owner re-boots
  `Pixel_10` for the integrated connected gate.
- `LightDisplayModel.brightness` and the L2 `Slider` stay in `1..100` even when a light/room is off
  (stored level), matching `RoomDisplayModel`'s `require(...)`; a 0 would crash `room.copy(...)`.
- Two concurrent Gradle builds in separate worktrees share `~/.gradle` cleanly (no corruption); only
  Lane 2 needs the emulator, so there was no device contention.

## 2026-06-28 - [Codex] Add Batch 2 preparation prompt

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Added `docs/coordination/prompts/parallel-batch-2-prepare.md` as the second orchestration prompt.
- Made it planning-only and gated on a completed, fully validated Batch 1 integration result.
- Directed Batch 2 planning toward parallel feature packages followed by one serialized navigation-integration wave.

### Working
- The prompt is ready to run after Batch 1 completes; it drafts Batch 2 for review without modifying Android source.

### Left
- Run the Batch 1 launch prompt first.
- After Batch 1 integration, run the preparation prompt and review its manifest before creating a Batch 2 launch prompt.

### Validation
- Docs-only; `git diff --check` passed before publication.

### Gotchas
- Batch 2 cannot be pinned safely until the actual Batch 1 integration SHA and landed model APIs exist.

## 2026-06-28 - [Codex] Add canonical Batch 1 launch prompt

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Added `docs/coordination/prompts/parallel-batch-1-launch.md` as the single ready-to-run Claude orchestration prompt.
- Linked the prompt from the Batch 1 manifest.

### Working
- Stable policy remains in `AGENTS.md`; batch-specific prompts can be revised or retired independently.

### Left
- Feed the prompt file to Claude Code when ready to launch Batch 1.

### Validation
- Docs-only; `git diff --check` passed before publication.

### Gotchas
- If `origin/main` advances, re-pin both the manifest and prompt before execution.

## 2026-06-28 - [Codex] Resolve local Android toolchain gate

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Found Android Studio's bundled JDK at `/Applications/Android Studio.app/Contents/jbr/Contents/Home`, the SDK at `~/Library/Android/sdk`, and the existing `Pixel_10` AVD.
- Updated D-005 from a blocker to a locally resolved validation prerequisite with explicit environment exports.
- Marked the narrowed two-lane Batch 1 manifest execution-ready and recorded baseline validation evidence.
- Made coordination files batch-owner-only during execution; lane agents return handoff text instead of concurrently editing `DEVLOG.md` or the manifest.

### Working
- Batch 1 can launch as two disjoint Claude lanes: domain models/fixtures and dashboard controls.
- Android CI remains recommended defense in depth but does not block the local pilot.

### Left
- Create the integration branch and two lane worktrees from the manifest's pinned `origin/main` SHA.
- Require each lane's listed validation to pass before integration.

### Validation
- `./gradlew testDebugUnitTest lintDebug assembleDebug` passed with the explicit JDK/SDK environment.
- `./gradlew connectedDebugAndroidTest` passed all 17 tests on the headless `Pixel_10` AVD.
- `git diff --check` passed before publication.

### Gotchas
- `/usr/bin/java` still reports no runtime; lane shells must use the explicit Android Studio `JAVA_HOME`.

## 2026-06-28 - [Claude] Apply Codex review to pipeline doc

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Conceded D-005: withdrew option (c); `testDebugUnitTest` is an AGP task so pure-Kotlin models in the `app` module still need JDK 17 + Android SDK. Recommended option (b): an Android Gradle CI job to gate the integration branch.
- Accepted D-006 (set ACCEPTED): narrowed Batch 1 to two lanes — L1 `android-models` (domain models + fixtures) and L2 `android-dashboard` (controls on the wired dashboard). Dropped standalone Settings + generic state composables (unwired dead UI).
- Fixed §2: added `ChromaGlowDestination.kt` and Kotlin `ui/theme/**` as Android collision hotspots; manifest terminology now matches §2.
- Reconciled §1 registry: `android-models-theme` → `android-models` (theme removed, now a hotspot); mapped both pilot lanes to registry entries with proposed owners.
- Rewrote §7 to the narrowed two-lane manifest with named lane owners; answered Q4/Q5.

### Working
- Doc is internally consistent: manifest lanes ↔ registry entries ↔ §2 hotspots all aligned.

### Left
- Codex to review this updated doc.
- Human decision on D-005 (provision local JDK 17 + Android SDK, or stand up Android CI). Nothing executes until then.

### Validation
- Docs-only; `git diff --check` clean.

### Gotchas
- L1 is unconsumed this batch — justified only as independently unit-tested foundation Batch 2 needs; two lanes is the minimum to actually rehearse a parallel merge.

## 2026-06-28 - [Codex] Batch 1 manifest review for Claude

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Appended a Codex response to D-005: pure Kotlin in the Android Gradle module still requires a JDK and Android SDK, while Compose instrumentation validation additionally requires an emulator/device runner.
- Added D-006 proposing a two-lane first pilot: domain models/fixtures plus controls on the already-wired dashboard.
- Responded to Q4/Q5: hold code lanes until equivalent validation exists and defer unwired Settings/state-component work until it has real callers.
- Requested Claude review of missing per-lane owners, registry mapping, and inconsistent collision-hotspot terminology.

### Working
- Claude's four-lane manifest remains a non-approved draft; no worktree should be created from it.
- D-005 and D-006 are `DISCUSSING` pending Claude/human response.

### Left
- Claude to weigh in on the narrower pilot and manifest corrections in the shared Decision Log.
- Provision a local Android toolchain or equivalent CI before approving code-writing lanes.

### Validation
- Docs-only review; `git diff --check` passed before publication.

### Gotchas
- A basic Android Gradle CI job does not exercise `connectedDebugAndroidTest`; Compose behavior tests need an emulator/device runner or a deliberately revised test strategy.

## 2026-06-28 - [Claude] Batch 1 manifest draft (for Codex review)

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Investigated current Android tree at `origin/main` @ `defe869`: dashboard is read-only, nav has only Setup/Dashboard, no Light/Scene model, no Settings/room-detail/state components → identified genuine unlanded, non-blocked work.
- Appended §7 "Batch 1 Manifest — DRAFT" to `docs/coordination/parallel-agent-pipeline.md`: 4 fully-parallel Android lanes (domain-models, dashboard-controls, settings, ui-states) with exact globs, acceptance criteria, forbidden files, and a §5 gate self-check. Zero collision-hotspot edits; nav wiring + room-detail/scenes explicitly deferred to Batch 2.
- Surfaced new blocker D-005 (no local JDK/Android toolchain, no Android CI → code can't be compiled/tested before merge) and Open Questions Q4/Q5.

### Working
- Manifest is review-ready and pinned to a named base commit.

### Left
- Codex to adversarially review the manifest + D-005/Q4/Q5 before any worktree is created.
- Resolve D-005 (toolchain/CI) — manifest is NOT execution-ready until then.

### Validation
- Docs-only; `git diff --check` clean. Confirmed `origin/main` @ `defe869`, android tree identical, `/usr/bin/java` reports no runtime.

### Gotchas
- The manifest deliberately builds new screens as standalone (non-nav-wired) composables to keep lanes disjoint; nav wiring is a single serialized Batch 2 lane that owns `ChromaGlowApp.kt` + `ChromaGlowDestination.kt`.

## 2026-06-28 - [Codex] Re-scope parallel pipeline pilot

### Branch
- `docs/parallel-agent-pipeline`

### Did
- Marked the original Android Batch 1 table as historical and non-executable because its named work has landed.
- Added an execution-readiness gate requiring a current base SHA, exact disjoint globs, owner/branch, acceptance criteria, dependencies, forbidden files, and narrow validation for every lane.
- Added the `unscoped` registry state and applied it to Android ownership classes so landed work cannot be claimed as a new deliverable.
- Recorded D-004 and an independent Claude CLI review; Claude agreed and requested the D-003/registry consistency corrections now reflected in the document.

### Working
- Android remains the recommended first real parallel run, but no replacement Batch 1 lanes are scoped yet.
- Pairing and credential-persistence wiring remain blocked by D-001/D-002.

### Left
- Draft replacement Android lanes from the fetched current `origin/main` tree before creating worktrees.
- Land the stacked docs branches so the pipeline becomes canonical on `main`.

### Validation
- `git diff --check` passed.
- Claude CLI independently reviewed the proposal and agreed after identifying the registry/status consistency correction.

### Gotchas
- The branch remains stacked on `docs/consolidate-agent-handoff`; merge order still matters.

## 2026-06-24 - [Claude] Parallel agent pipeline + shared decision log

### Branch
- `docs/parallel-agent-pipeline` (stacked on `docs/consolidate-agent-handoff`)

### Did
- Added `docs/coordination/parallel-agent-pipeline.md`: lane registry (Android + iOS + cross-cutting), collision-hotspot list, branch/worktree/merge model, Android-only Batch 1 pilot, and a shared Claude⇄Codex Decision Log (seeded D-001 TLS blocker, D-002 identity blocker, D-003 Batch 1 scope, + Open Questions).
- Added "Parallel Agent Pipeline" section to `AGENTS.md` (canonical rules) plus branch-naming note and a Documentation Index entry for the new doc.
- Added a pointer line in `CLAUDE.md` and a snapshot line here in `DEVLOG.md`.

### Working
- Disjoint-lane model is documented and ready: agents own non-overlapping globs; gate files are single-owner per batch; merges land on `integration/parallel-batch-N` with a human final merge to `main`.
- Decision Log is the durable, git-backed back-and-forth channel between Claude and Codex.

### Left
- Codex to review and append to the Decision Log (especially D-001/D-002 and Open Questions Q1–Q3).
- Run the Android Batch 1 pilot via Claude Workflow + worktree isolation once scope is confirmed.
- Human collaborator to open/merge the PR (agent `gh` account is not a collaborator).

### Validation
- Docs-only change; `git diff --check` clean. No runtime/code/Xcode/Gradle files touched.

### Gotchas
- This branch is stacked on `docs/consolidate-agent-handoff`, which is not yet merged to `main`. Land that first (or merge both together) so the canonical `AGENTS.md`/`CLAUDE.md` and this pipeline doc arrive on `main` consistently.

## 2026-06-24 - [Codex] Agent handoff consolidation

### Branch
- `docs/consolidate-agent-handoff`

### Did
- Made `AGENTS.md` the canonical shared context and source catalog.
- Replaced `CLAUDE.md` with a thin Claude Code entry point that immediately directs Claude to `AGENTS.md` and `DEVLOG.md`.
- Added this current snapshot and handoff template to the top of `DEVLOG.md`.

### Working
- Root handoff now follows one-source-of-truth rules instead of maintaining two large duplicated context files.
- Current iOS scheme and Android status are reflected in the root handoff.

### Left
- Open/merge PR from GitHub with a collaborator account if repository policy requires review.

### Validation
- `git diff --check` passed.
- Scanned root handoff files for stale `HueHome` scheme and old Android-not-started language.
- Branch push succeeded.
- Draft PR creation via `gh pr create` was blocked because the authenticated GitHub account is not a collaborator.

### Gotchas
- `CURSOR_KICKOFF.md` and older historical devlog entries still contain stale `HueHome` scheme references; agents should follow `AGENTS.md` for current validation commands.
- Pushed branch is available at `origin/docs/consolidate-agent-handoff`; Claude can read it immediately after fetching/checking out that branch.

## 2026-05-07 — Multi-Bridge Concurrent Entertainment Sessions (Antigravity)

### What was built

Upgraded the entertainment transport layer from a single-session global to a **per-bridge dictionary**, enabling concurrent DTLS sessions across multiple Hue bridges simultaneously.

#### Root cause
The old guard `compositionEntRoomID == nil` was global — starting entertainment on Bridge A blocked Bridge B from ever using DTLS, silently falling back to choppy REST.

#### Changes
All single-slot state replaced with `[bridgeID: ...]` dictionaries:

| Old | New |
|---|---|
| `compositionEntTask: Task?` | `compositionEntTasks: [String: Task]` |
| `compositionEntRoomID: String?` | `compositionEntRoomByBridge: [String: String]` |
| `compositionEntertainmentParamBox` (weak) | `compositionEntParamBoxes: [String: CompositionParamBox]` |
| `studioEntClient: HueEntertainmentClient?` | `studioEntClients: [String: HueEntertainmentClient]` |
| `activeEntertainmentConfig: EntertainmentConfig?` (stored var) | `entertainmentConfigsByBridge: [String: EntertainmentConfig]` + `activeEntertainmentConfig(for: RoomDisplayItem?)` method |

#### Impact
- **2 bridges = 2 simultaneous DTLS sessions = 20 smooth channels**
- Single-bridge behavior unchanged (dictionary has one entry)
- StudioView mini-map and direction dial now read config for the **currently selected room's bridge** — correct when switching between bridge rooms
- Mic demand check updated to `anyOf` across all active param boxes
- Stop path looks up bridgeID from roomID → cleans only that bridge's session

### Files changed
| File | Change |
|---|---|
| `UnifiedOrchestrator.swift` | Dictionary state, per-bridge guard, start/stop/cleanup paths |
| `StudioView.swift` | `activeEntertainmentConfig(for:)` at 4 call sites |
| `StudioViewModel.swift` | `studioEntClients[bridgeID]` at 2 call sites |

### Git state
- Commit: `f2f360b` on `main`
- BUILD SUCCEEDED

### How to test
1. **Single-bridge regression:** Start entertainment composition → verify `⚡ Entertainment transport active` log → stop → verify no crash
2. **Multi-bridge:** Pair two bridges, both with entertainment areas → start composition on each → both should log `⚡` with different bridgeIDs → mini-map switches correctly when navigating between rooms

---

## 2026-05-07 — Transport Architecture Research (Antigravity)

### What was investigated

Deep dive into why 16-light REST compositions show "room by room" sequential updates.

#### Root cause
REST per-light mode batches 5 PUTs with 80ms gaps → ~1.1s to cycle all 16 lights per frame. Not a code bug — a fundamental HTTP rate-limit constraint.

#### Transport tiers (current architecture)
```
Entertainment (DTLS)   → 25fps, all lights simultaneously, 10 channel limit, 1 session/bridge
REST per-light         → ~10 PUTs/sec, batches of 5, choppy on 8+ lights
Bridge v1 rules chain  → 3s min step interval, app-free, bridgeOptimized presets only
V2 Dynamic Palette     → bridge firmware cycles palette, unlimited lights, smooth, app-free
```

#### V2 Dynamic Palette — key findings
- Create scene with `palette.color[]` array + `speed` + `auto_dynamic: true`
- Recall with `action: "dynamic_palette"`
- **Bridge firmware handles cycling on the light itself** — zero ongoing network traffic
- Unlimited lights (whole room via grouped_light), persists after app close
- Trade-off: no directional patterns (wave/cascade/mirror), no envelope shapes, no mic
- `BridgeAnimationEngine.uploadV2DynamicScene()` already exists but is **not wired to the composer flow** and missing the `palette` property on `CreateSceneRequest`

#### What's not yet built
- [ ] `CreateSceneRequest` needs `palette` property (`color[]`, `color_temperature[]`, `speed`, `auto_dynamic`)
- [ ] `uploadV2DynamicScene` should use composer palette colors (not single t=0 snapshot)
- [ ] Wire into `startCompositionMode` as a transport tier between DTLS and REST
- [ ] "Persist on Bridge ⚡" toggle in mixer tray
- [ ] Cleanup on stop (delete dynamic scene from bridge)

### What's next
- [ ] Implement V2 Dynamic Palette as a composer transport tier
- [ ] Map `motion.speed` (0–100) → Hue `speed` (0.0–1.0)
- [ ] Badge on room card when bridge-powered effect is active

---

## 2026-05-07 — Codebase Audit: Architecture, Risks, Follow-ups (Cursor)

### What was reviewed
Thorough pass over critical paths (no line-by-line coverage of every file): `UnifiedOrchestrator`, `HueAPIClient`, Studio/Composer wiring, `RoomDisplayItem`, SSE/optimistic merge, `MainTabView` shell, cold-launch changes, logging patterns.

### Positive findings (keep)
- `pendingActionDeadlines` for SSE vs optimistic grouped_light updates reduces toggle flicker.
- Direct `allRooms` mutation in `updateRoom` with documented `@Observable` rationale.
- Composer generation guards, RestSender mailbox, entertainment vs REST split align with bridge reality.
- `RoomDisplayItem` uses full-field `==` (not id-only) so SwiftUI sees on/brightness/dominant color changes.
- Hue self-signed cert handling documented for session + task delegate (iOS 15+).

### Issues / edge cases (prioritized)
**High — reconcile docs vs code**
- `.cursorrules` says never send `effects` to `grouped_light`; `HueAPIClient` + `EffectsViewModel` intentionally use `setGroupedLightNativeEffect` for bridge-native effects. Clarify rule (Composer/custom vs firmware native) in `.cursorrules` / `DEVDOC.md` to avoid wrong “fixes.”

**High — correctness**
- Deprecated `toggleRoom`: rollback uses captured `item.isOn` on failure — stale if state moved; prefer removal or rollback by reading current room by id (`UnifiedOrchestrator`).
- `RoomDisplayItem`: `hash(into:)` mixes fewer fields than `==` uses — `Hashable` contract risk if identity-related fields change without hash updates.

**Medium**
- `StudioViewModel`: many `print(...)` calls on apply/handoff/AI paths — migrate to `Logger` + `#if DEBUG` or privacy-redacted `os_log` for release.
- Concurrent `loadAll`: second caller hits guard and returns early — confirm refresh UX is acceptable.
- Parallel `loadAll`: `deactivateStuckEntertainmentSessions` + fetch overlap — brief window where data loads before stuck session cleared; monitor if odd throttle on cold launch.
- SwiftData: `fatalError` on container init — no recovery path (acceptable for corrupt DB but worth knowing).

**Lower**
- MainTabView tab prewarm: trades idle memory for snappy first switch; optional tuning on low-memory devices.
- Legacy branding strings (“CastChroma”) still in some file headers — cosmetic.

### What's left
- [ ] Update `.cursorrules` / `DEVDOC` for grouped_light native effects vs Composer effects.
- [ ] Fix `RoomDisplayItem` hashing to align with `Equatable`, or document exception.
- [ ] Remove/fix deprecated `toggleRoom` rollback or delete call sites.
- [ ] Replace Studio `print` with structured logging for release builds.

### Gotchas
- Audit did not include full Keychain/remote OAuth review or device QA against a live bridge.

### Current state
No code changes from this audit entry alone — documentation and small correctness fixes deferred to follow-up tasks.

---

## 2026-05-07 — Cold-Launch First Tab Switch: Prewarm + Parallel loadAll (Cursor)

### What was built

**MainTabView — deferred-tab prewarm**
- After Home paints, stagger inserting `.studio`, then `.scenes` / `.more` into `realizedTabs` (~280ms + ~160ms) so heavy roots (`StudioView`, etc.) compile off the first-tab-tap critical path.
- `.task { await prewarmDeferredTabs() }` on the shell `Group` (iPhone + iPad).

**UnifiedOrchestrator — loadAll**
- `deactivateStuckEntertainmentSessions()` and bridge fetch/merge now run **in parallel** via outer `withTaskGroup` (cleanup no longer gates room data).
- Extracted `fetchAndMergeAllBridges()` (previous inner task-group body).
- `await Task.yield()` before `rebuildAllRooms()` / `rebuildAllZones()` so pending UI work can run before large `allRooms` / `allZones` observable updates.

### What's working
- ✅ `xcodebuild` HueHome — BUILD SUCCEEDED

### What's left
- [ ] Device QA: confirm first Studio tap feels instant; watch memory with all tabs realized.
- [ ] Instruments (Time Profiler + SwiftUI) if any hitch remains — optional further split of `StudioView`.

### Gotchas
- Tapping Studio within ~280ms of launch may still pay cold-build cost (edge case).
- Prewarm realizes all lazy tabs → higher idle memory; trade for snappy navigation.

### Current state
Cold-launch tab responsiveness addressed by idle prewarm + shorter loadAll critical path; ready for on-device timing validation.

---

## 2026-05-07 — Audit Bugfixes: 3 Bugs in Spatial Engine (Antigravity)

### What was changed

Post-implementation audit found 3 bugs in the Spatial Motion Engine. All fixed and verified with clean build.

#### Bug #1 — REST Spatial Positions Never Worked (Critical)
- **Root cause:** `computeSpatialPositions()` used `channel.lightServiceIDs` as map keys, but these are **entertainment** service IDs (from `/clip/v2/resource/entertainment_configuration` → `members[].service.rid`), NOT `light` service IDs. REST `compositionLightIDs` come from `fetchLights().map { $0.id }` — different UUID namespace. Lookup always returned nil → silent fallback to index-based.
- **Fix:** Added `resolveEntertainmentLightPositions()` to `UnifiedOrchestrator`. Fetches `/clip/v2/resource/entertainment` services in parallel with lights, builds the bridge: `entertainment_service_id → device_id → light_id`. Changed `computeSpatialPositions()` to accept pre-built `lightPositions: [String: (x: Double, z: Double)]` map instead of raw `EntertainmentConfig`.

#### Bug #2 — Mirror Toggle Did Nothing on Index Path
- **Root cause:** `phase(lightIndex:total:time:)` never read the `mirror` field. Only the spatial overload `phase(spatialPosition:time:)` applied `abs(position - 0.5) * 2.0`.
- **Fix:** Added `if mirror { position = abs(p - 0.5) * 2.0 }` to the index-based function.

#### Bug #3 — PCA Overrides User's 0° Angle
- **Root cause:** `motionAngle` defaulted to `0`. Orchestrator checked `== 0` to decide whether to auto-detect. But 0° (→ rightward) is a valid user choice.
- **Fix:** Changed default to `-1` (sentinel = "auto-detect"). Check changed to `< 0`. UI clamps display to `max(0, angle)`.

### Files changed
| File | Change |
|---|---|
| `CompositionEngine.swift` | `computeSpatialPositions` now takes `lightPositions` map, not `config` |
| `UnifiedOrchestrator.swift` | +`resolveEntertainmentLightPositions()` (~60 lines), PCA check `< 0` |
| `CompositionModels.swift` | `motionAngle` default `-1`, mirror in index `phase()` |
| `StudioView.swift` | `max(0, angle)` at 4 UI read points |

### Git state
- All work merged to `main` (commit `6c8eb87`)
- Feature branch `feature/harmony-spatial-engine` deleted locally, still on remote
- Safe revert point: `7db5c1e` (pre-harmony/spatial, settings cleanup only)

### Known performance issue (not yet fixed)
- **First tab switch takes ~4-5 seconds** after cold launch. Likely causes:
  1. `StudioView` is ~2800 lines — first SwiftUI build is expensive
  2. Synchronous `rebuildAllRooms()` / `rebuildAllZones()` on `@MainActor` blocks UI during large `@Observable` diffs
  3. `deactivateStuckEntertainmentSessions()` runs sequentially before data load
- **NOT caused by** `await` blocking the main thread (Swift concurrency yields on `await`)
- Needs Instruments profiling (Time Profiler + SwiftUI) to confirm bottleneck split

### What's next
- [ ] Performance optimization: move heavy work off `@MainActor`, investigate StudioView cold build cost
- [ ] Test harmony + spatial features on device with bridge
- [ ] Test entertainment area creation flow end-to-end

---

## 2026-05-07 — Spatial Motion Engine (Antigravity)

### What was changed

Upgraded the Composer Motion Layer from array-index-based patterns to physical spatial coordinates. Wave, Cascade, and Bounce patterns now sweep across lights based on their actual positions in the room, not their arbitrary discovery order.

#### Spatial Math (`CompositionEngine.swift`)
- Added `computeSpatialPositions(config:orderedLightIDs:motionAngle:)` — projects entertainment channel positions onto a 2D direction vector via dot product, returns positions ordered to match REST lightIDs (fixes ordering mismatch between entertainment channels and REST resolution order).
- Added `computeSpatialPositionsForEntertainment(channels:motionAngle:)` — same math but returns in channel order for DTLS transport.
- Added `principalAngle(channels:)` — PCA via 2×2 covariance matrix eigenvector to auto-detect the axis of maximum light spread. Used as default `motionAngle` when user hasn't set one.
- Added lerp system (`targetSpatialPositions` + `spatialLerpProgress`) for smooth 0.3s transitions when angle changes.
- Render loop updated: uses spatial `phase()` when positions available, falls back to index for scatter pattern (which needs pseudo-random seeding by index).

#### Model (`CompositionModels.swift`)
- Added `motionAngle: Double = 0` to `MotionConfig` (migration-safe Codable default).
- Added `phase(spatialPosition:time:)` overload — same switch/case logic as index-based version, replaces `lightIndex/total` with pre-computed 0–1 position. Mirror support: `abs(spatialPosition - 0.5) * 2.0`.

#### Orchestrator Wiring (`UnifiedOrchestrator.swift`)
- Fetches entertainment config BEFORE transport decision — both REST and DTLS paths get spatial positions.
- Moved `resolveCompositionLightIDs` earlier to feed the REST-ordered position computation.
- Added `activeEntertainmentConfig: EntertainmentConfig?` (public, @Observable) — exposed for Studio UI mini-map and direction dial.
- Auto-detects principal angle on first launch.
- Clears `activeEntertainmentConfig` on composition stop.

#### Direction UI (`StudioView.swift`, ~280 lines)
- **Direction presets**: 8 arrow chips (→ ↗ ↑ ↖ ← ↙ ↓ ↘), amber-highlighted when selected.
- **Angle dial**: 80pt glassmorphic circle with drag-to-rotate, amber indicator line, 5° snap, haptic ticks at 45° boundaries.
- **Spatial mini-map**: 80pt rounded rect showing light dots at physical (x,z) positions with palette-derived colors + dashed amber direction arrow.
- **Entertainment area prompt**: When no entertainment config exists, shows a styled button that opens `EntertainmentConfigBuilderView` as a sheet. On creation, spatial positions are computed immediately.
- **recomputeSpatialPositions()**: Called from Binding setters (NOT onChange — CompositionParamBox is not @Observable). Triggers smooth lerp + REST burst.
- **Mirror toggle** added to motion controls.
- Direction UI hidden for scatter pattern (non-directional).

### Bugs prevented by audit (6 found before implementation)

| # | Bug | Prevention |
|---|---|---|
| 1 | Scatter breaks with spatial positions (becomes smooth wave) | Render loop skips spatial for `.scatter` |
| 2 | `onChange` on motionAngle never fires | Use Binding setters, not onChange |
| 3 | Entertainment config only fetched on DTLS path | Fetch before transport decision |
| 4 | REST light ordering mismatch (wrong position per light) | lightID→position lookup map |
| 5 | "L → R" direction labels misleading | Arrow symbols + mini-map |
| 6 | Static pattern excluded from dial | Show for all except scatter |

### Files changed
| File | Change |
|---|---|
| `HueHome/Core/Models/CompositionModels.swift` | +`motionAngle`, +spatial `phase()` overload |
| `HueHome/UI/Studio/CompositionEngine.swift` | +spatial fields on ParamBox, +4 static helpers, +lerp in render loop |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | +`activeEntertainmentConfig`, spatial wiring, moved lightID resolution |
| `HueHome/UI/Studio/StudioView.swift` | +direction presets, +angle dial, +mini-map, +entertainment prompt |
| `HueHome/UI/Studio/StudioViewModel.swift` | Cleanup (moved property to orchestrator) |

### What's next
- [ ] Test spatial sweep in simulator with multi-light entertainment area
- [ ] Consider expanding to 3D direction (include Y/height axis)
- [ ] Auto-suggest optimal direction based on pattern + light layout

---

## 2026-05-07 — Harmony Engine → Studio Composer (Antigravity)

### What was changed

Integrated the existing `HarmonyEngine` (from SceneBuilder) into the Studio Composer Palette tab. Users can select a harmony rule (Analogous, Triadic, Complementary, Split Complementary, Monochromatic) and drag the 2D hue/saturation pad to generate mathematically harmonious 3-color palettes in real-time.

#### Features
- **Conditional harmony UI**: Chips only appear in `.solid` or `.gradient` modes and only when the current room/zone contains at least one color-capable bulb.
- **Mode awareness**: Auto-clears `activeHarmonyRule` when switching to non-color modes (Spectrum/Temp).
- **Swatch editing**: Tappable preview row → ColorWheelView popover for fine-tuning individual harmony colors.
- **Persistence**: `harmonyRule: String?` on `PaletteConfig` (migration-safe optional).
- **User guidance**: Contextual hint ("Try Cascade or Wave…") when harmony is selected with static motion.

### Files changed
| File | Change |
|---|---|
| `HueHome/UI/Components/HueColorUtils.swift` | +`codableColor(from:gamut:)` helper |
| `HueHome/Core/Models/CompositionModels.swift` | +`harmonyRule: String?` to `PaletteConfig` |
| `HueHome/UI/Studio/StudioViewModel.swift` | +`roomHasColorLights`, +`restoredHarmonyRule` |
| `HueHome/UI/Studio/StudioView.swift` | +chip row, +swatch preview, +editing popover, +harmony-aware drag |

---

## 2026-05-07 — Settings Consolidation + Navigation Cleanup (Antigravity)

### What was changed

#### Settings is now exclusively in More
- Removed the gear (⚙) toolbar button and its associated `showSettings` sheet from **5 tabs**: Dashboard, Studio, Scenes, Effects, Sync.
- Settings is now accessed from **More → Settings** only — consistent with the iOS Settings app convention.
- `MoreView` is the single owner of `showSettings` state. No other tab manages it.

#### Duplicate content removed from SettingsView
- Removed the `exploreSection` (Automations + Devices navigation links) from `SettingsView`.
- These already exist in `MoreView`'s CONTROL section linking to the same destination views (`AutomationsView`, `DevicesView`). Having them in both places caused confusion.
- **Settings now contains:** Bridges, All Day Scenes, Account (API Token), Developer (Demo Mode + Clean Bridge), App info.
- **More now contains:** Automations, Devices & Firmware, Accessories, Profiles & Access, Share Invite, Bridge Manager, Connection status, Settings (link), Demo Mode, App version.

#### SyncModeView toolbar cleanup
- The `toolbarItems` `@ToolbarContentBuilder` was left empty after removing the gear button. Removed the property and the `.toolbar { toolbarItems }` call entirely rather than leaving a dead no-op.

### Files changed
| File | Change |
|---|---|
| `HueHome/UI/Dashboard/DashboardView.swift` | Removed `showSettings` state, `.fullScreenCover`, gear `ToolbarItem` |
| `HueHome/UI/Studio/StudioView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` |
| `HueHome/UI/Scenes/ScenesTabView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` |
| `HueHome/UI/Effects/EffectsView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` (bookmark + stop toolbar items untouched) |
| `HueHome/UI/Sync/SyncModeView.swift` | Removed `showSettings` state, `.sheet`, entire `toolbarItems` property + `.toolbar` call |
| `HueHome/UI/Settings/SettingsView.swift` | Removed `exploreSection` property and its call in body |

### What's working
- Settings is reachable from one place (More tab) — no more gear icon on every tab
- No duplicate Automations/Devices entries between More and Settings
- Sync tab toolbar is clean (no leftover empty builder)

### What's next
- [ ] Harmony engine integration into Studio card color pickers (hue strip + rule chip row)
- [ ] "Run on Bridge" opt-in button in mixer tray for `runtimeOnly` presets
- [ ] Manual "Clean Bridge" button already in Settings/Developer — needs soak test

---

## 2026-05-07 — Bridge Animation Fixes + Composer Dynamic Effects Restored (Antigravity)

### Problems fixed (4 bugs, 1 session)

#### 1. Schedule creation failing — error type 6 `"parameter, autoDelete, not available"`
- `HueV1Client.createRecurringSchedule()` was sending `"autodelete": autoDelete` in the POST body.
- Bridge firmware rejects this key with error type 6. Removed it — omitting defaults to `false` (schedule persists).

#### 2. Schedule command using wrong address format
- `sensorIncrementCommand()` returns a **relative** path (`/sensors/{id}/state`), correct for **rule actions**.
- Schedule `command.address` must be the **full** path `/api/{token}/sensors/{id}/state` — the bridge does NOT append user context for schedule commands (unlike rule actions).
- **Fix:** Added `sensorIncrementScheduleCommand()` that builds the full path; swapped the call site in `BridgeAnimationEngine`.

#### 3. Composer cards not turning lights on after bridge upload
- Bridge upload succeeded (rules, sensor, schedule created), but the first rule only fires when the schedule next ticks (~3–18s away). Lights stayed dark after card tap.
- **Fix:** Added an **immediate prime frame** after `bridgeAnimationStore.save(manifest)` — renders step 0 of the composition and pushes it via `setGroupedLightEffect(on: true)` so the room lights up within ~1s of the tap.

#### 4. Dynamic composer cards (cascade/wave/breathe) frozen — REST scheduler suppressed
- `canRunOnBridge` was `true` for ALL non-mic presets, so every composition went through bridge upload.
- Bridge upload returned early without starting the REST scheduler.
- Bridge rule chains have a **3-second minimum step interval** (bridge firmware limit), making cascade/wave/breathe presets look completely frozen.
- **Fix:** Gated bridge upload on `preset.capabilityTier == .bridgeOptimized` only. Dynamic presets fall through to REST/Entertainment as before.

### Files changed
| File | Change |
|---|---|
| `HueHome/Core/Network/HueV1Client.swift` | Removed `autodelete` from schedule body; added `sensorIncrementScheduleCommand()` with full address |
| `HueHome/Core/Network/BridgeAnimationEngine.swift` | Swapped `sensorIncrementCommand` → `sensorIncrementScheduleCommand` for schedule |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | Added prime frame after bridge upload; gated bridge path on `.bridgeOptimized` tier |

### Architecture: bridge transport tiers
```
bridgeOptimized  (static motion + steady envelope)
  → Bridge upload automatically: lights persist after app close, prime frame turns on immediately

runtimeOnly  (any motion or non-steady envelope — cascade/wave/breathe/etc.)
  → REST/Entertainment: continuous 120ms updates, smooth animation
  → Bridge: NOT auto-uploaded (3s/step would freeze the effect)

hybrid  (mic-reactive)
  → REST/Entertainment only (bridge has no mic)
```

### What's working
- ✅ Schedule creates successfully (no more type 6 errors)
- ✅ `bridgeOptimized` presets upload, persist after app close, turn on immediately
- ✅ `runtimeOnly` compositions produce smooth continuous animation via REST

### What's next
- [ ] "Run on Bridge ⚡" explicit opt-in button in mixer tray for `runtimeOnly` presets
- [ ] Manual "Clean Bridge" button in Settings
- [ ] On-device soak test: bridgeOptimized preset, close app, verify lights keep cycling

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

---

## 2026-05-06 — AI Provider + Preset Metadata Migration (Cursor)

### What was built
- Updated `CompositionPreset` in `CompositionModels.swift` with migration-safe AI metadata:
  - Added optional `aiPrompt` and `providerModel`.
  - Implemented custom `init(from:)` to decode both fields with graceful `nil` fallback for legacy JSON.
  - Implemented explicit `encode(to:)` for forward-compatible persistence.
- Replaced local heuristic generation path in `StudioViewModel.swift` with FoundationModels-backed generation:
  - Added `LanguageModelSession` request path (guarded by `canImport(FoundationModels)` and availability).
  - Added JSON extraction + decode pipeline for structured model output.
  - Added validation clamp step for all returned numeric fields (palette/motion/envelope/reaction ranges).
- Added AI-card visual affordance in `StudioCardView` (inside `StudioView.swift`):
  - Shows compact `wand.and.stars` badge for AI-generated composition cards.
  - Badge sits alongside layer activity chips and remains compact-layout safe.

### What's working
- ✅ Generic iOS build succeeds after provider integration and metadata migration.
- ✅ Existing composition JSON remains readable due decoder fallback behavior.
- ✅ New AI-generated presets persist prompt/model metadata and show AI badge.

### What's left
- [ ] Cross-device QA snapshot pass (SE/mini/standard/Max/iPad) for badge/chip density.
- [ ] Optional: transition from text-JSON parsing to strict guided structured output (`@Generable`) for stronger model guarantees.

### Gotchas
- FoundationModels can be unavailable per-device/runtime; generator now fails gracefully with clear user-facing message.

### Current state
AI generation now uses FoundationModels with clamp validation, and preset metadata is migration-safe for older saved compositions.

---

## 2026-05-06 — Composer UX Stabilization + Gamut-Aware Color Pipeline (Cursor)

### What was built
- Hardened AI generation reliability in `StudioViewModel.swift`:
  - Added markdown-fence sanitization before JSON decoding.
  - Added detailed decode failure logging (raw JSON candidate + decode error details).
  - Added tolerant decode path for variant provider payloads (including missing palette fields / `colors` array fallback mapping).
  - Added local fallback draft generator when FoundationModels fails/unavailable (notably simulator/runtime generation failures).
- Replaced fragmented Palette controls with a unified 2D Hue/Saturation pad in `StudioView.swift`:
  - Removed separate hue slider, saturation slider, and color-dot row.
  - Added 2D drag pad with thumb, clamp-safe drag math, and compact-layout-safe sizing.
  - Added live thumb tracking while dragging to eliminate perceived input lag.
- Improved Composer mixer tray interactions/lifecycle:
  - Added tap-outside dismissal overlay.
  - Added swipe-down-to-dismiss for inline mixer with threshold/predicted-end handling.
  - Added header drag-indicator tap dismiss.
  - Added keyboard dismissal utility (`hideKeyboard()`) and applied it to relevant tap backgrounds.
  - Re-anchored tray as a bottom overlay to reduce lock/unlock geometry glitches.
- Fixed hue pad visual consistency:
  - Corrected saturation axis orientation.
  - Added selected-color thumb fill + color preview dot to better reflect selected values.
  - Lifted tray above tab bar to avoid lower-edge clipping on compact devices.
- Implemented gamut-aware color accuracy improvements (Step 1 + 2):
  - Added Hue gamut triangles (A/B/C) and `clampXYToGamut` in `HueColorUtils.swift`.
  - Added room-dominant gamut resolution in `StudioViewModel` and `UnifiedOrchestrator`.
  - Clamped Composer color output to resolved gamut in both Entertainment and REST render paths.
  - Refactored hue pad to canonical clamp-first flow so displayed thumb/readout track post-clamp output (not pre-clamp gesture values).
- Tuned REST fallback responsiveness during color scrubbing:
  - Added interaction-aware cadence in `runCompositionREST`:
    - drag: faster interval + shorter transition
    - idle: conservative interval + smoother transition
  - Added post-drag settle write for cleaner final color landing.

### What's working
- ✅ AI generation succeeds more consistently across phone + simulator with graceful fallback path.
- ✅ 2D hue pad interaction is smoother (live tracking, clamp-safe drag, consistent thumb/readout).
- ✅ Mixer dismissal is easier and more native-feeling (tap-outside, swipe-down, header tap).
- ✅ Composer color output is now gamut-clamped end-to-end, reducing unreachable-color mismatch.
- ✅ Build and lint checks passed after each major slice.

### What's left
- [ ] Optional follow-up: switch Composer pad to full xy-native editing surface for even tighter perceptual parity.
- [ ] Optional follow-up: tune drag REST profile further (e.g., 0.7s/140ms) based on bridge/device QA.
- [ ] Product decision pending: enforce portrait-only orientation to avoid landscape UI regressions.

### Gotchas
- Hue bridge grouped_light path remains rate-limited; REST fallback will never feel as fluid as Entertainment streaming.
- Mixed-gamut rooms still require compromise mapping; dominant-gamut strategy is a practical middle ground.

### Current state
Composer UX is significantly more stable and color handling is now gamut-aware from picker input through transport output, with improved simulator resilience for AI generation.

---

## 2026-05-06 — Composer Multi-Room Runtime + Scheduler Tuning (Cursor)

### What was built
- Implemented non-destructive mixer dismissal in `StudioView.swift`:
  - Dismiss gestures (tap outside / swipe down / header tap) now collapse controls instead of stopping the running composition.
  - Added `Live Controls` quick chip to reopen the mixer while effect continues.
- Enabled multi-room concurrent compositions:
  - Refactored Composer orchestration from single global task semantics to room-scoped runtime state in `UnifiedOrchestrator`.
  - Updated `StudioViewModel` apply/stop logic so composition no longer force-stops other composition rooms.
- Replaced per-room composition REST loops with a global fair scheduler:
  - Added round-robin scheduler over active composition rooms to prevent one room from monopolizing bridge updates.
  - Added room-scoped start/stop generation guards and lifecycle cleanup.
- Added debug telemetry for Composer scheduler:
  - Per-room effective send rate (`hz`), average lag (`avgLagMs`), max lag (`maxLagMs`) logged in DEBUG builds.
- Improved startup responsiveness and pacing:
  - Added immediate prime write when a composition starts so newly selected rooms visibly turn on immediately.
  - Reduced smoothing/transition durations for faster visual response.
  - Passed pre-resolved gamut from `StudioViewModel` into `startCompositionMode` to avoid redundant fetch overhead at start.

### What's working
- ✅ Composition cards can now run concurrently across multiple rooms (REST path).
- ✅ Mixer can be hidden/reopened without canceling live composition playback.
- ✅ Scheduler fairness improved vs independent per-room loops.
- ✅ New composition start feels more immediate due to prime write.
- ✅ Build and lint checks passed after each slice.

### What's left
- [ ] Final scheduler calibration from fresh telemetry after latest transition/tick tuning.
- [ ] Decide whether to introduce "Bridge Optimized" vs "Custom Live Engine" mode badges.
- [ ] Optional: portrait-only lock decision if landscape regression costs remain high.

### Gotchas
- Native Hue dynamic effects remain smoother because they execute in bridge firmware; Composer remains app-driven for custom behavior.
- Multi-room Composer on grouped_light is bounded by bridge rate limits; scheduling can optimize fairness but not fully bypass hardware limits.

### Current state
Composer now supports practical multi-room concurrency with fair scheduling, faster start behavior, and a cleaner non-destructive mixer UX, while preserving custom composition flexibility.

---

## 2026-05-06 — Composer Responsiveness Investigation + Final Tuning Pass (Cursor)

### What was built
- Ran iterative tuning on Composer runtime behavior with repeated full build verification.
- Added and used DEBUG scheduler telemetry (`hz`, `avgLagMs`, `maxLagMs`) to validate runtime pacing and fairness.
- Tuned composition transition durations and startup behavior:
  - Shorter live transitions for Composer REST writes.
  - Immediate prime write on composition start so newly activated rooms visibly respond right away.
- Optimized startup path:
  - Reused `StudioViewModel`-resolved gamut by passing a `gamutOverride` into `startCompositionMode(...)` to avoid redundant fetches during room activation.
- Refined scheduler pacing strategy:
  - Maintained round-robin fairness and interaction-aware behavior.
  - Reduced burst-like write behavior in follow-up tuning attempts.

### What was verified
- ✅ Full iOS build succeeds after all tuning passes.
- ✅ Multi-room composition concurrency remains functional.
- ✅ Startup responsiveness improved via prime write.
- ✅ Native dynamic effects remain noticeably smoother than Composer under equivalent conditions.

### Findings from logs/telemetry
- Composer can show low scheduler lag (`avgLagMs` near 0) while still feeling visually laggy.
- This indicates the main bottleneck is not app-side queue backlog, but grouped_light REST animation granularity/cadence limits vs bridge-native dynamic effects.
- Native dynamic effects feel smoother because they execute in bridge firmware after one-shot effect commands.
- Composer (custom 4-layer runtime) still requires continuous grouped_light updates in REST mode, which has a lower smoothness ceiling.

### What's left
- [ ] Decide/implement Bridge-optimized composition identifiers and tiers (bridgeOptimized/hybrid/runtimeOnly) for each preset.
- [ ] Add clear user-facing capability badge so saveability/smoothness expectations are explicit.
- [ ] Evaluate transport strategy for best smoothness:
  - prioritized active-room cadence,
  - adaptive per-room degradation,
  - optional bridge-optimized compile path where possible.

### Current state
Composer is materially improved and instrumented, but logs confirm that REST grouped_light remains the limiting factor for “native-like” smoothness; next milestone is capability-tiering and bridge-optimized pathways.

---

## 2026-05-06 — Composition Optimization Tier Metadata + UI Badge (Cursor)

### What was built
- Added composition optimization identifiers directly to preset metadata in `CompositionModels.swift`:
  - `optimizationTier: bridgeOptimized | hybrid | runtimeOnly`
  - `bridgeOptimizationFlags: [BridgeOptimizationFlag]`
  - `bridgeOptimizationReason` computed string for UI/debug visibility.
- Implemented migration-safe decoding for existing saved presets:
  - if new fields are missing, flags are inferred from layer configs and tier is auto-derived.
- Added tier/reason propagation into Studio cards in `StudioViewModel.swift`:
  - `StudioCard` now carries `compositionOptimizationTier` + `bridgeOptimizationReason` for Composer presets.
- Added compact Composer card badge UI in `StudioView.swift`:
  - Tier capsule (`Bridge Optimized`, `Hybrid`, `Runtime Only`)
  - concise reason hint sourced from optimization flags.

### What’s working
- ✅ Every composition preset now stores optimization metadata on the model.
- ✅ Existing stored JSON presets remain compatible via decode-time inference.
- ✅ Composer cards show a compact optimization tier badge.
- ✅ Reason flags are visible in a compact, user-facing hint line.

### What’s left
- [ ] Optional: tune inference heuristics per preset family if product wants stricter tier semantics.
- [ ] Optional: surface full reason list in detail UI (e.g., context menu/details sheet) instead of compact hint truncation.

### Gotchas
- Existing presets in user storage did not contain new keys, so migration-safe defaults were required to avoid breaking decode.
- Tiering here is intentionally deterministic and model-based (layer config analysis), not runtime transport performance telemetry.

### Current state
Composer presets now have persisted bridge optimization identifiers and reason flags, and Studio displays a compact badge for immediate user clarity about bridge optimization capability level.

---

## 2026-05-06 — Composer Transport Hardening (Cursor)

### What was built
- Hardened Composer transport/scheduler behavior in `UnifiedOrchestrator`:
  - Added per-room due-time pacing using `nextDueAt` (instead of high-frequency global sleep clamp).
  - Set steady-state target to ~1Hz per room for grouped_light REST sends.
  - Added bounded interaction burst mode (short faster window) with automatic decay.
  - Added optional Entertainment-first path in `startCompositionMode(..., preferEntertainment:)` with REST fallback.
- Improved overlap safety in `StudioViewModel`:
  - Apply path now resolves room light IDs for composition/app-driven cards too.
  - Overlap detection now prevents competing effects across overlapping room/zone scopes beyond bridge-native-only cases.
- Added panic-stop affordance in `StudioView`:
  - New `stop.circle.fill` toolbar action appears while anything is running and calls `vm.stopAll()`.

### What’s working
- ✅ Full iOS build succeeds after transport hardening.
- ✅ Composer REST cadence is now significantly less burst-prone and closer to bridge limits.
- ✅ Quick slider interaction gets temporary responsiveness boost, then auto-returns to stable pacing.
- ✅ Overlapping room/zone runs are reduced by broader overlap checks.
- ✅ One-tap panic stop now available at top nav while effects are active.

### What’s left
- [ ] On-device validation pass for Entertainment-first composition route with multiple bridge layouts.
- [ ] Tune burst window/interval based on real bridge telemetry in live household scenarios.
- [ ] Optional: add explicit UI transport indicator per running composition room (REST vs Entertainment).

### Gotchas
- Entertainment API remains bridge-wide/single-session; composer entertainment preference must still gracefully fall back when unavailable.
- REST grouped_light smoothness remains bounded by bridge behavior even with improved scheduler pacing.

### Current state
Composer now uses a safer pacing model, broader overlap protection, bounded burst behavior, and optional entertainment-preferred transport, with a global panic-stop control for runaway room effects.

---

## 2026-05-06 — Composer Tier Guardrails + Runtime Hint (Cursor)

### What was built
- Added strict per-tier Composer REST cadence guardrails in `UnifiedOrchestrator`:
  - `CompositionRuntime` now tracks `tier`.
  - Scheduler enforces minimum interval by tier via `minIntervalForCompositionTier(_)`.
  - Current policy: `bridgeOptimized`, `hybrid`, and `runtimeOnly` all clamp to **>= 1.0s** per room/zone when on REST.
- Added debug clamp diagnostics:
  - When interaction burst requests faster updates than allowed, DEBUG builds log `[Composer][Guardrail] clamped cadence ...` with requested vs allowed interval.
- Wired tier into orchestrator start path:
  - `StudioViewModel` now passes `tier` into `startCompositionMode(..., tier:)` so cadence policy is centrally enforced.
- Added runtime-only expectation cue in mixer UI (`StudioView`):
  - For composition cards running on REST with `runtimeOnly` tier, mixer shows: `Runtime-only REST is rate-capped`.

### What’s working
- ✅ Full iOS build succeeds after guardrail/hint changes.
- ✅ REST cadence now respects the explicit 1.0s policy regardless of temporary burst requests.
- ✅ Users now get a visible smoothness expectation hint during runtime-only REST playback.

### What’s left
- [ ] Optional: expose active effective cadence value (e.g., `1.00s`) in mixer for QA visibility.
- [ ] Optional: differentiate future tier policy (e.g., slower bridgeOptimized cadence if needed).

### Gotchas
- The clamp is intentionally conservative and will trade responsiveness for reliability on grouped_light REST.
- Entertainment path remains preferred for high-motion smoothness; REST guardrails reduce lag/fighting but cannot match DTLS fluidity.

### Current state
Composer now has a centralized tier-aware REST safety policy, debug observability for cadence clamping, and a user-facing runtime-only rate-limit hint, improving predictability and reducing bridge overload behavior.

---

## 2026-05-06 — Composer Transport Choice + QA Cadence Visibility + AI Prompt Chips (Cursor)

### What was built
- Added explicit Composer transport choice UX in `StudioView`:
  - For non-bridgeOptimized composition cards, applying now prompts:
    - `Room Only (REST)`
    - `Entertainment Area (Streaming)`
    - `Always Room Only`
    - `Always Entertainment Area`
  - Persisted preference and prompt behavior are stored via `UserDefaults`.
- Added transport preference model in `StudioViewModel`:
  - `CompositionTransportPreference` enum (`auto`, `roomOnly`, `entertainmentArea`)
  - `compositionTransportPreference` + `isCompositionTransportPromptEnabled`
  - apply path now supports `preferEntertainmentOverride` and routes preference into `startCompositionMode(...)`.
- Added real-time REST cadence exposure in `UnifiedOrchestrator`:
  - `activeRESTCadence: Double?`
  - `activeRESTCadenceByRoom: [String: Double]`
  - cadence UI updates throttled (~1.5s) to avoid observation churn.
- Wired cadence into Studio UI:
  - Runtime-only mixer hint now appends live cadence when available, e.g.:
    - `Runtime-only REST is rate-capped (Live: ~1.0s)`.
- Added AI suggested prompt chips for Composer generation in expanded AI panel:
  - `Static Warm Sunset`
  - `Cozy Reading Corner`
  - `Energetic Club Pulse`
  - `Blinking Christmas Lights`
  - Tapping a chip fills prompt and immediately triggers generate+apply flow.

### What’s working
- ✅ Full iOS build succeeds after all changes.
- ✅ Composer transport is now user-selectable with optional persisted default.
- ✅ Runtime-only REST cadence is visible in mixer for QA.
- ✅ AI chip affordance works and triggers generation quickly.

### What’s left
- [ ] Optional: add a lightweight reset action for transport preference in settings/studio overflow.
- [ ] Optional: show active transport scope tag directly on card before apply (not only in mixer).

### Gotchas
- Entertainment remains bridge-wide/single-session; selection still depends on config/session availability and may fall back to REST.
- Runtime-only compositions on REST are intentionally capped for bridge safety; cadence visibility clarifies this but cannot make REST as smooth as DTLS.

### Current state
Composer now has explicit user-controlled transport scope, observable REST cadence for QA validation, and stronger AI prompt affordances to steer generation quality while preserving bridge-safe scheduling constraints.

---

## 2026-05-06 — Field QA Observation: Composer Start Order Contention (Cursor)

### What was observed
- In live testing, effect stacking behavior depends on apply order:
  - If Composer card is applied **last**, multi-effect behavior appears smooth and stable.
  - If Composer card is applied **first**, later effects feel laggy / delayed.
- User hypothesis (likely correct): Composer path is still competing for transport/state ownership when started first.

### Evidence pattern
- Symptoms look like transport contention rather than bridge rejection:
  - Composer telemetry still reports near-target cadence (~1 Hz REST in tested cases).
  - Other effects degrade primarily when Composer owns early lifecycle.
- This points to orchestration/order arbitration rather than pure rate limit failure.

### Likely root-cause area (next debugging slice)
- Cross-mode coordination between Composer runtime and subsequent effect engines:
  - ownership handoff sequencing,
  - overlap arbitration timing,
  - shared resource/session release timing (REST/Entertainment),
  - residual grouped_light transition/state settling from Composer startup.

### What to do next
- Add explicit “mode ownership handoff” instrumentation:
  - log per-room owner transitions (Composer ↔ bridgeNative/appDriven),
  - log overlap-stop decisions with timestamps,
  - log transport/session active state before/after each apply.
- Reproduce with deterministic sequence tests:
  1) Composer first → native/appDriven cards
  2) native/appDriven first → Composer
  3) same sequence with/without entertainment selection.
- If confirmed, add a small guarded handoff delay or hard ownership barrier when transitioning away from Composer-first starts.

### Current state
- Transport controls, cadence guardrails, and UI diagnostics are materially improved.
- A reproducible sequencing edge case remains: **Composer-first startup can still degrade subsequent effect smoothness**.

---

## 2026-05-06 — Composer Handoff Barrier + Sequencing Instrumentation (Cursor)

### What was built
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Added `[Handoff]` lifecycle logs in `stopCompositionMode(roomID:)` for:
    - stop requested,
    - `studioRestSender.clear()` moment,
    - post-clear settle complete,
    - teardown complete.
  - Added `try await Task.sleep(for: .milliseconds(150))` immediately after `studioRestSender.clear()` in `stopCompositionMode(roomID:)`.
  - Added matching `[Handoff]` lifecycle logs in `stopStudioMode()` and a 150ms settle delay right after `studioRestSender.clear()`.
- `HueHome/UI/Studio/StudioViewModel.swift`
  - In overlap arbitration inside `apply(_:roomOverride:preferEntertainmentOverride:)`, added `[Handoff]` logs around `await stopEffect(on:)` to make the barrier observable.
  - Added explicit `[Handoff]` startup log right before new effect startup sequence begins.
  - In `stopEffect(on:)` bridge-native cleanup path, added:
    - `[Handoff]` log before per-light `no_effect`,
    - 150ms settle delay after batched `no_effect`,
    - `[Handoff]` completion log after settle.

### What’s working
- ✅ Hard async barrier already present in overlap flow remains intact (`await stopEffect(on:)`).
- ✅ New startup is now instrumented to begin only after overlap cleanup + settle barrier.
- ✅ Teardown paths now include explicit bridge settle windows after REST sender clear / `no_effect` cleanup.
- ✅ Project builds successfully with:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What’s left
- [ ] Run on-device/simulator sequencing QA and confirm `[Handoff]` logs appear in strict order during rapid override scenarios.
- [ ] Validate no perceptible regression in perceived responsiveness when quickly swapping cards (150ms barrier tradeoff).

### Gotchas
- `xcodebuild` in sandbox failed due to host permission/simulator service constraints; non-sandbox build succeeded.
- Handoff delay is intentionally short (150ms) to avoid bridge queue flooding while minimizing UX lag.
- Entertainment remains bridge-wide and single-session; sequencing barriers do not change that hardware constraint.

### What to test
- 1) **Composer -> Native immediate override**
  - Select room A, start a Composer card, immediately tap a bridge-native card.
  - Expect `[Handoff]` teardown logs to complete before startup log appears.
- 2) **Composer -> appDriven immediate override**
  - Start Composer, immediately tap Strobe/Party/Thunderstorm.
  - Expect same strict ordering and no interleaved startup before teardown completion.
- 3) **Overlap path (Home zone vs room)**
  - Run effect in room A, switch to Home zone and start another card.
  - Expect overlap detection log, awaited stop barrier, then startup barrier-clear log.
- 4) **Rapid repeated taps**
  - Repeatedly switch between two cards in same room.
  - Confirm no stuck effect state and no bridge command flood behavior.
- 5) **Cross-room non-overlap sanity**
  - Run room A effect, then room B effect with no shared lights.
  - Confirm independent behavior remains unchanged.

### Current state
Composer handoff now has explicit teardown instrumentation and guarded settle barriers at ownership boundaries. Build is green; remaining work is runtime QA to verify strict log ordering and user-perceived smoothness under rapid card switching.

---

## 2026-05-06 — Portrait Lock + Studio SE Mixer Fit + Title Picker Cleanup (Cursor)

### What was built
- `HueHome/Info.plist`
  - Locked app orientation to portrait by reducing `UISupportedInterfaceOrientations` to:
    - `UIInterfaceOrientationPortrait`
- `HueHome/Core/Services/AutomationHandler.swift`
  - Added AppDelegate runtime orientation lock:
    - `application(_:supportedInterfaceOrientationsFor:) -> .portrait`
- `HueHome/UI/Studio/StudioView.swift`
  - Kept the original rolodex room/zone title interaction (swipe L/R rooms, U/D zones, tap for search sheet).
  - Removed the room/zone chevron icon from the Studio title row.
  - Added accessibility traits/hint so the title still reads as tappable control for the room/zone sheet.
  - Reworked mixer sizing for compact devices:
    - wrapped root in `GeometryReader`
    - dynamic tray cap based on available viewport (`resolvedMixerHeight(proxy:)`)
    - tab-bar/home-indicator aware bottom clearance
  - Reworked mixer scroll behavior:
    - composition controls now use a fill-height scroll region (`GeometryReader` + `ScrollView`)
    - essential parameter controls use same pattern
    - prevents bottom content from being clipped on iPhone SE-sized screens.

### What’s working
- ✅ Build succeeds:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`
- ✅ Studio title remains tappable for room/zone search without visual chevron clutter.
- ✅ Mixer can grow taller on compact devices and keeps content scrollable to reach bottom controls.
- ✅ Orientation is portrait-only at plist and runtime delegate levels.

### What’s left
- [ ] Validate on real iPhone SE that all composition controls (including lower controls) are reachable without clipping.
- [ ] Verify no unexpected layout regressions on larger phones after dynamic tray cap changes.

### Gotchas
- Portrait lock is now enforced in two places (plist + AppDelegate delegate callback) intentionally for consistency.
- Mixer tray now consumes more vertical space on compact devices; this is deliberate to preserve control visibility.

### What to test
- 1) **Portrait lock**
  - Launch app and rotate device/simulator to landscape.
  - Expect UI to remain portrait with no layout rotation.
- 2) **Studio title row interaction**
  - In Studio, tap the room/zone title (no chevron now).
  - Expect Room/Zone search sheet to open exactly as before.
- 3) **Rolodex navigation still intact**
  - Swipe title left/right to cycle rooms; up/down to cycle zones.
  - Confirm transitions remain smooth and selection updates correctly.
- 4) **iPhone SE mixer fit (critical)**
  - On Composer card, open mixer and scroll through controls.
  - Confirm bottom controls are reachable and not hidden behind tab bar/home indicator.
- 5) **Non-composer mixer fit**
  - Use bridge-native and app-driven cards with several sliders.
  - Confirm lower rows remain reachable via scroll on compact height.
- 6) **Regression sanity**
  - Verify card grid remains visible when mixer is expanded/collapsed.
  - Verify stop/save buttons remain visible and tappable.

### Current state
App is now portrait-locked and Studio mixer layout is hardened for compact screens (including SE) with viewport-aware tray sizing and scrollable content regions. Next step is focused SE device QA for final visual tuning.

---

## 2026-05-06 — App Store Orientation Compliance + Runtime Rotation Toggle (Cursor)

### What was built
- `HueHome/Info.plist`
  - Restored full iPhone orientation set required for App Store upload validation:
    - `UIInterfaceOrientationPortrait`
    - `UIInterfaceOrientationPortraitUpsideDown`
    - `UIInterfaceOrientationLandscapeLeft`
    - `UIInterfaceOrientationLandscapeRight`
- `HueHome/Core/Services/AutomationHandler.swift`
  - Updated `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` to be user-preference-driven:
    - default behavior remains portrait-only,
    - optional landscape via user setting.
  - Added `OrientationPrefs.allowLandscape` (`"app.allowLandscapeRotation"`) UserDefaults key.
- `HueHome/UI/Settings/SettingsView.swift`
  - Added new `APP` section toggle:
    - `Allow Landscape Rotation`
    - Backed by `@AppStorage("app.allowLandscapeRotation")`
    - Default is `false` (portrait lock remains default behavior).

### What’s working
- ✅ Upload-blocking orientation metadata issue is addressed by plist orientation restoration.
- ✅ Runtime behavior still defaults to portrait lock for normal users.
- ✅ Landscape can be explicitly enabled by testers/power users from Settings.
- ✅ Build succeeds:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What’s left
- [ ] Verify App Store upload path no longer returns error 90474.
- [ ] Validate that toggling landscape in Settings updates runtime behavior as expected across major app screens.

### Gotchas
- App Store validation checks declared plist orientations, not only runtime locks.
- Runtime orientation changes can appear delayed until next screen transition in some UIKit/SwiftUI stacks.

### What to test
- 1) **Upload compliance**
  - Archive + upload; confirm no orientation validation error (90474).
- 2) **Default lock behavior**
  - Fresh install / default settings: rotate device.
  - Expect portrait lock.
- 3) **Landscape opt-in**
  - Settings -> App -> enable `Allow Landscape Rotation`.
  - Rotate on Studio/Home/Settings; expect landscape support.
- 4) **Toggle off regression**
  - Disable toggle and retest rotation.
  - Expect portrait lock restored.

### Current state
Orientation handling is now split correctly between App Store compliance (full plist support) and product UX preference (portrait-first runtime lock with optional tester override). Build is green; next checkpoint is successful archive upload and quick on-device rotation QA.

---

## 2026-05-06 — Composer Mic + REST Snappiness + Tab Lazy-Load + Perf (Cursor)

### What was built

**Composer microphone (reaction layer)**  
- New `HueHome/UI/Studio/CompositionMicCapture.swift` — FFT band splits aligned with `VisualizerEngine`, lock-protected levels, `syncDemand(_:)` lifecycle.  
- `UnifiedOrchestrator` wires `CompositionMicCapture.reactionAudioLevel(for:)` into all `CompositionEngine.render` paths (REST scheduler, ENT loop, prime frame); `refreshCompositionMicDemand()` tied to composition lifecycle; weak `compositionEntertainmentParamBox` for mic-demand when ENT transport is active.  
- `HueHome/HueHomeApp.swift` — `Notification.Name` extensions: `composerMicExclusiveBegan`, `compositionMicPermissionDenied`.  
- `SyncModeEngine` observes `composerMicExclusiveBegan` and calls `stop()` if Sync is running (avoid dual `AVAudioEngine`).  
- `CompositionEngine` — **tap tempo** uses envelope BPM sine wave (no mic); mic sources still use passed `audioLevel`.  
- Exclusive handoff delay after posting mic notification: **35ms** (was 60ms).  
- **Parallel warmup**: When gamut must be fetched and reaction uses mic, mic `syncDemand(true)` runs **concurrently** with `resolveCompositionGamut` / `resolveDominantGamut`, and mic completion is **awaited before** blocking on gamut result (`StudioViewModel` + `UnifiedOrchestrator`).  
- ENT path: `tryStartEntertainment` and `findEntertainmentConfig` run **in parallel** when choosing streaming transport.

**REST Composer cadence (Sync-aligned)**  
- Scheduler uses **`0.15s × active composition room count`** as baseline (matches `SyncModeEngine` REST visualizer spacing model).  
- Separate **burst floors** for color-pad interaction vs idle tier guardrails (`bridgeOptimized` remains more conservative).  
- Idle/settle transition durations tightened slightly for grouped_light; post-send scheduler yield **40ms → 20ms**.

**Shell performance**  
- `MainTabView` — **lazy tab realization** (`realizedTabs`): Scenes / Studio / More roots not constructed until first visit; tab bar inserts current tab on tap; `onAppear`/`onChange` register selection for restoration.  
- `StudioView` — removed `.animation(..., value: currentDeck)` on deck `TabView` to reduce paging hitch.

### Files touched (high level)
- `CompositionMicCapture.swift` (new), `UnifiedOrchestrator.swift`, `CompositionEngine.swift`, `HueHomeApp.swift`, `SyncModeEngine.swift`, `StudioViewModel.swift`, `StudioView.swift`, `MainTabView.swift`, `HueHome.xcodeproj/project.pbxproj`

### What’s working
- ✅ `xcodebuild` HueHome scheme — BUILD SUCCEEDED (`generic/platform=iOS`)

### Gotchas
- Hue does not stream “voice” over the bridge — mic only improves **client-derived** levels fed into Composer; bridge latency unchanged.  
- `grouped_light` REST remains throughput-sensitive; burst paths must not defeat tier guardrails on weak bridges.  
- Lazy tabs: first open of Studio still pays full `StudioView` cost once.

### What to test (QA checklist)

**A — Composer mic**  
1. **Permission** — Fresh install or revoke mic: apply a composition with reaction source **Mic** (amplitude / bass / mid / treble). Expect system prompt once; if denied, capture still fails gracefully (optional toast pipeline not wired — verify no crash).  
2. **Reaction vs tap tempo** — Preset with **Tap tempo**: lights should pulse to **envelope BPM**, not room noise. Switch to **Mic amplitude**: verify motion follows voice/claps.  
3. **Sync exclusivity** — Start **Music Sync** (or any Sync mode using mic), then start **Composer** with mic reaction. Expect Sync to stop and Composer mic to work (no stuck dual-engine state).  
4. **ENT vs REST Composer + mic** — Same mic preset: room with entertainment area (streaming) and force **Room only (REST)** via transport prompt; verify both paths show reactive brightness (REST will be lower cadence).  
5. **Background** — Composer + mic running: send app to background; verify capture stops / no runaway session (resume foreground).

**B — REST Composer snappiness**  
6. **Single room** — Runtime composition on **one** room: updates should feel closer to **Sync visualizer** pacing (~150ms scale), not 1 Hz slideshow.  
7. **Multi-room** — Two+ rooms with compositions: verify fair rotation and **no** bridge lag storm (no 30–60s drain — back off if observed).  
8. **Interaction burst** — Drag color pad / interact: expect snappier bursts than idle (within reason).  
9. **bridgeOptimized tier** — Still more conservative cadence; confirm acceptable on real bridge.

**C — Startup / Studio shell**  
10. **Cold launch** — From quit: land on **Home**; first tap **Studio** — should avoid building Studio until then (may feel faster than when all tabs eager-loaded).  
11. **Deck paging** — Swipe Effects → Live → Composer; confirm no extra animation jank on deck switch.  
12. **iPad** — Sidebar tab switch still realizes tabs and shows content.

**D — Regressions**  
13. Apply **bridge-native** cards (candle, fire, …) — unchanged path.  
14. **Stop composition / handoff** — Stop Composer then apply another Studio card; no stuck lights or duplicate sessions.

### Current state
Composer reactions can use real microphone levels with Sync-safe exclusivity; REST Composer pacing matches the app’s Sync REST model for dynamic tiers; main shell defers heavy tabs until first visit. Ready for **device QA** (mic + multi-room + bridge load).

---

## 2026-05-06 — Studio Room Target Race + Composer REST Efficiency Pass (Cursor)

### Problem observed
- Composer apply could target the wrong room under rapid UI interaction.
- Logs showed mismatches like `selectedRoom: Main bedroom` while `groupedLightID` resolved to Bathroom.
- Composer REST mode still generated heavy traffic (frequent `PUT /grouped_light/...`) and startup duplicated `GET /light` work.

### What was fixed

**1) Room-targeting race in Studio UI**
- `HueHome/UI/Studio/StudioView.swift`
  - Removed render-time `roomSnapshot` captures from card/grid/menu paths.
  - Room is now captured at action time inside apply helpers, so apply always uses current selection.
  - Updated helper signatures:
    - `applyCardWithTransportPrompt(_:)`
    - `applyCompositionQuick(_:mode:)`
    - `composerPresetOverflowActions(preset:card:)`

**2) Startup GET dedupe in apply flow**
- `HueHome/UI/Studio/StudioViewModel.swift`
  - Added cached-light overloads:
    - `resolveLightIDs(for:api:cachedLights:)`
    - `resolveDominantGamut(for:api:cachedLights:)`
  - Apply now fetches bridge light inventory once (only when needed for device-backed rooms) and reuses it for:
    - overlap detection / room light resolution
    - dominant gamut resolution
  - Eliminates redundant back-to-back `GET /light` calls at composition startup.

**3) Balanced scheduler efficiency tightening**
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Added extra balanced-profile skip gate for tiny deltas sent too recently.
  - Increased balanced idle / low-power intervals for `.hybrid` and `.runtimeOnly` tiers.
  - Goal: preserve interaction responsiveness while reducing sustained REST chatter in non-interacting periods.

### Verification
- ✅ Lints clean on edited files.
- ✅ Build succeeded:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What to test
- 1) **Room correctness under fast interaction**
  - Rapidly change room/zone and immediately tap composer cards / overflow actions.
  - Confirm `selectedRoom` and `groupedLightID` always map to the same target room.
- 2) **Composer startup traffic**
  - Start a composition and confirm reduced duplicate `GET /light` bursts.
- 3) **REST efficiency in Balanced**
  - Let a composition run idle for 30-60s; expect fewer PUTs than prior runs.
  - During active slider/pad interaction, responsiveness should remain acceptable.

### Current state
Wrong-room apply race is closed at the Studio action layer, startup light fetches are deduplicated, and Balanced REST cadence is more conservative when visual deltas are small. Ready for on-device validation focused on room-target integrity and perceived smoothness vs call volume.

---

## 2026-05-06 — Composer Color Edit Immediate Flush (REST burst override)

### Problem observed
- In Composer REST mode, user hue/saturation pad edits could be treated as "not meaningful" by balanced low-power gating, causing delayed/no visible color response immediately after drag.
- Logs showed low-power skips right after pad interaction (`Δxy` near zero after gamut clamp), even though user expected instant feedback.

### What was built

**User-edit forced burst path**
- `HueHome/UI/Studio/CompositionEngine.swift`
  - `CompositionParamBox` now includes:
    - `forceRESTBurstUntil: TimeInterval`
    - `triggerRESTBurst(seconds: 0.55)`
  - Purpose: mark a short post-edit window where REST scheduler should prioritize sending.

- `HueHome/UI/Studio/StudioView.swift`
  - Hue/saturation pad now calls `triggerRESTBurst()`:
    - on drag change
    - on drag end
  - Keeps existing `isColorPadInteracting` semantics.

- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Scheduler reads `userEditBurstActive = runtime.paramBox.forceRESTBurstUntil > now`.
  - During this window:
    - bypass low-power + efficiency skip gates
    - use burst cadence/floor path (same responsiveness class as interaction burst)

### Why this works
- Even if gamut clamp results in tiny `Δxy`, a direct UI edit now forces near-term sends so the bridge gets an immediate state update.
- Balanced mode remains efficient outside the short user-edit burst window.

### Verification
- ✅ Lints clean on edited files.
- ✅ Build succeeded:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What to test
- 1) Start Composer in Bathroom (REST transport).
- 2) Drag hue/saturation pad briefly and release.
- 3) Confirm visible color response occurs immediately after drag (no perceived dead period).
- 4) Let composition idle for 20-30s; verify cadence still backs off in balanced mode.

---

## 2026-05-06 — Composer Color Pad Haptics + Ultra-Low REST Cadence Constants (Cursor)

### What was built
- `HueHome/UI/Studio/StudioView.swift`
  - Added continuous, throttled haptic feedback while dragging the Composer hue/saturation pad:
    - New state: `lastHuePadHapticAt`
    - During `DragGesture.onChanged`, fires `HapticManager.shared.selection()` at most once every ~80ms.
    - Resets haptic timer on drag end; existing end-of-drag haptic remains.
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Aggressively lowered Composer REST scheduler interval constants for fast-response testing:
    - Lowered idle baseline (`preferredComposerIdleInterval`) and all tier minimums.
    - Lowered non-burst floors (`minimumComposerRESTInterval`) and burst floors (`minimumComposerBurstFloor`).
    - Tightened burst interval calculation (`max(0.03, syncRestInterval * 0.25)`).
    - Lowered low-power idle intervals to keep cadence high even during small-delta periods.

### What's working
- ✅ Lints clean on edited files (`StudioView.swift`, `UnifiedOrchestrator.swift`).
- ✅ Build succeeded:
  - `xcodebuild -project /Users/brianbean/Desktop/huehome-pro-v0.3.0/HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`
- ✅ Composer color pad now provides tactile feedback during drag (not only on drag end).

### What's left
- [ ] On-device bridge QA for overload/lag behavior with the new ultra-low intervals (single room + multi-room).
- [ ] Confirm no command-flood side effects (dropped updates, delayed bridge recovery, or perceived jitter).
- [ ] Decide final production cadence policy after telemetry review (`hz`, `avgLagMs`, `maxLagMs`).

### Gotchas
- REST grouped_light still has practical bridge throughput limits; very low interval constants can reduce stability even if app-side scheduler lag remains near zero.
- Haptic feedback is intentionally throttled to avoid excessive vibration spam during continuous drags.

### Current state
Composer editor responsiveness is now aggressively biased toward immediacy: the color pad gives live haptic pulses during drag, and REST cadence guardrails are significantly lowered for stress/perf validation. Build is green; next step is focused real-bridge QA before locking production values.

---

## 2026-05-07 — Bridge-Stored Animation Engine: Root Cause + Fix (Antigravity/Gemini)

### Problem
Compositions applied from Studio did not persist when the app was closed. The bridge-stored v1 animation chain (rules + CLIP sensor + schedule) was failing silently at rule creation with error 608/6.

### Root cause (after 4 iterations of debugging)
**v1 rule/schedule action addresses must be relative paths** — NOT the full `/api/{token}/...` path.

```diff
# WRONG (what we were sending):
- "address": "/api/ZVcY.../lights/1/state"

# CORRECT (what the bridge expects):
+ "address": "/lights/1/state"
```

The bridge internally resolves the user context for rule/schedule actions. Including the token made the address malformed, causing:
- Error 608: "Rule actions contain errors or an action on an unsupported resource"
- Error 6: "parameter, transitiontime/on/address/method, not available" (bridge couldn't parse the action at all)

Additional bugs found and fixed during the debugging process:
1. **v1/v2 light ID mismatch** — v2 uses UUIDs, v1 uses numeric IDs ("1", "2"). Added `resolveV1LightIDs()`.
2. **Double rule creation** — Code created rules twice (scene-only, then deleted and recreated with sensor advance). Collapsed to single-pass.
3. **Scene activation in rules** — v1 rules don't reliably support `{"scene": "id"}` on group actions. Switched to direct per-light state commands (`PUT /lights/{id}/state`).
4. **Sensor kickoff** — Sensor started at 0; setting to 0 didn't trigger the `dx` condition. Now starts at 99.
5. **Orphaned resources** — Multiple test runs left 18+ scenes and 3+ sensors on the bridge. Added `purgeAllChromaGlowResources()` and auto-cleanup before upload.

### What was built
- **`HueV1Client.swift`** — v1 REST client for rules, scenes, CLIP sensors, schedules, resourcelinks. Includes `resolveV1LightIDs()`, fetch methods for all resource types, and `token` exposed for rule action construction.
- **`BridgeAnimationEngine.swift`** — Pre-renders compositions into v1 rule chains. Direct per-light state commands (no scene activation). Sensor-based step counter with schedule-driven cycling. `purgeAllChromaGlowResources()` for cleanup.
- **`UnifiedOrchestrator.swift`** — Bridge-stored upload integration with auto-cleanup, `isBridgeStored` state flag, transport priority: Bridge-Stored > Entertainment > Per-light REST > Grouped REST.

### Two implementation paths identified

**Option A: Fix v1 relative paths (3-line fix)** — Change addresses in `sceneActivationCommand()`, `sensorIncrementCommand()`, and direct light actions from `/api/{token}/...` to `/...`. Gets the full v1 rule chain working for ALL composition patterns.

**Option B: v2 Dynamic Scene** — Create v2 scene with `POST /clip/v2/resource/scene`, recall with `{"recall": {"action": "dynamic_palette", "duration": 5000}}`. Bridge autonomously cycles colors. Zero rules/sensors/schedules. Already have `CreateSceneRequest`, `activateScene(id:speed:)`, and `HueScene.isDynamic` in the codebase.

**Decision: Implement both.** Option A for complex motion (cascade/wave/scatter), Option B as fast-path for simple palette presets.

### What's left
- [ ] Fix v1 relative paths (Option A — 3 lines)
- [ ] Implement v2 dynamic scene fast-path (Option B)
- [ ] Add manual "Clean Bridge" button in Settings
- [ ] On-device soak test: apply animation, close app, verify lights keep going
- [ ] Resource capacity monitoring (rules/sensors/schedules are finite on bridge)

### Gotchas
- v1 rule actions: addresses are RELATIVE (`/lights/1/state`), NOT full API paths
- v1 rules: max 8 actions per rule. With N lights + 1 sensor bump = N+1 actions. Safe for up to 7 lights per room.
- v2 dynamic scenes: less control over per-light timing (bridge controls cycle), but zero resource overhead
- Bridge has finite resource limits (~100 rules, ~250 sensors, ~100 schedules). Must clean up between runs.
- `purgeAllChromaGlowResources()` finds all CG_ prefixed resources and deletes them. Currently runs before every upload.

### Current state
Root cause identified and documented. Build is green. Two implementation paths approved. Next step: apply the 3-line v1 fix, test on device, then build v2 dynamic scene path.

---

## 2026-05-08 — Multi-Bridge Routing Foundation for Widget/Watch (Cursor)

### What was built
- **`HueHome/Core/Network/WidgetDataStore.swift`** — Extended shared snapshot contract with `bridgeID` on `WidgetRoomSnapshot`, added `WidgetBridgeCredentials`, added bridge map persistence (`hue_widget_bridges_v1`), and added `credentials(for:)` resolver with legacy fallback.
- **`HueHome/Core/Network/UnifiedOrchestrator.swift`** — Writes bridge-aware room/zone snapshots, publishes active bridge credential map for App Group consumers, and pushes bridge map through watch sync path.
- **`HueHome/HueHomeApp.swift`** — Updated `WatchSessionManager.push` payload to include `wc_bridges_v1` (plus legacy fallback keys).
- **`HueHomeWidget/WidgetIntents.swift`** — Switched interactive widget intents to resolve per-room bridge credentials instead of global single-bridge creds.
- **`HueHome/Intents/HueRoomEntity.swift` + `HueHome/Intents/HueIntents.swift`** — Added `bridgeID` to intent entities and routed Siri intents through per-bridge credential resolution.
- **`LightShadeWatchApp Watch App/WatchStore.swift` + `LightShadeWatch/WatchWidgetStore.swift`** — Added bridge map decoding/storage and per-room bridge credential resolution on watch/watch-widget paths.

### What's working
- ✅ iOS app target (`HueHome`) compiles successfully after multi-bridge routing changes.
- ✅ watchOS app target (`LightShadeWatchApp Watch App`) compiles successfully after watch sync/store updates.
- ✅ Widget/intent/watch code paths now have a deterministic per-room bridge routing key (`bridgeID`) and a shared bridge credential map.
- ✅ Legacy single-bridge keys are still emitted/read as fallback for backward compatibility.

### What's left
- [ ] Add interactive watch complication/widget toggle intent wiring in `LightShadeWatch` (UI currently non-interactive).
- [ ] Validate on physical watch that Bridge 2 toggles now route correctly under real-world stale-cache conditions.
- [ ] Add explicit failure surfacing/telemetry when room routing metadata is missing or stale.
- [ ] Optionally add groupedLightID→bridgeID fallback map for extra resilience if room bridge metadata is absent.

### Gotchas
- Existing watch/widget data can remain stale across sessions; routing fixes require fresh app-driven sync to repopulate bridge-aware payloads.
- Some watchers still rely on legacy `hue_widget_bridge_ip`/`hue_widget_token`; keeping fallback keys avoids hard breaks while migrating.
- Multi-bridge correctness depends on `bridgeID` being present in snapshots; missing IDs will fall back to legacy credentials.

### Current state
Multi-bridge routing foundation is implemented across iOS widget, Siri intent, watch sync, and watch stores. Both iOS and watch targets build cleanly. Next step is on-device verification for Bridge 2 behavior and then watch widget interactivity wiring.

---

## 2026-06-01 — Build-Time Git Metadata Injection (IOS-OPS-001B) (Cursor)

### What was built
- **`Scripts/inject_build_metadata.sh`** — Injects `ChromaGlowGitCommit`, `ChromaGlowGitBranch`, `ChromaGlowBuildTimestamp`, and `ChromaGlowGitDirty` into the **built** app bundle plist (`${TARGET_BUILD_DIR}/${INFOPLIST_PATH}`) only. Never edits `HueHome/Info.plist`. Supports `CHROMAGLOW_METADATA_PLIST_PATH` and `CHROMAGLOW_REPO_ROOT` for tests.
- **`Scripts/tests/test_inject_build_metadata.sh`** — 19 fixture cases (clean/dirty/detached/non-git/stale keys/spaces/missing plist).
- **`HueHome.xcodeproj/project.pbxproj`** — HueHome target only: **Inject Build Metadata** Run Script phase (last phase). Uses dependency analysis with `inputPaths` = processed bundle Info.plist so injection runs **after** `ProcessInfoPlistFile` on incremental builds.

### Injected plist keys
| Key | Source |
|---|---|
| `ChromaGlowGitCommit` | `git rev-parse HEAD` (full SHA) |
| `ChromaGlowGitBranch` | `git branch --show-current` (omitted on detached HEAD) |
| `ChromaGlowBuildTimestamp` | UTC `date -u +%Y-%m-%dT%H:%M:%SZ` (always) |
| `ChromaGlowGitDirty` | `git status --porcelain` → `"1"` / `"0"` |

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → 19/19 pass
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' build` → **BUILD SUCCEEDED**
- Built `HueHome.app/Info.plist` contains injected keys; `git diff -- HueHome/Info.plist` → no diff
- Incremental second build retains keys; timestamp updates
- `codesign --verify --deep --strict` on built app → pass (generic iOS build)

### Physical-device verification
1. Open **`HueHome.xcodeproj`** (not `ChromaGlow.xcodeproj` — local shell has no `project.pbxproj`)
2. Scheme **`HueHome 1`** → physical iPhone
3. Clean Build Folder → Run
4. **More → Settings** → scroll to footer
5. Compare commit: `git rev-parse --short=8 HEAD`
6. With uncommitted changes expect **Working tree modified**; after a clean commit, dirty line should disappear
7. Force quit → relaunch → Settings stable

### Gotchas
- `ChromaGlow.xcodeproj` is an incomplete untracked wrapper; use **`HueHome.xcodeproj`**
- Run Script uses `ENABLE_USER_SCRIPT_SANDBOXING = NO` on HueHome (already set)
- Do not place `BuildMetadata.swift` under `HueHome/Core/Build/` — `.gitignore` rule `build/` ignores that path

### What's next
- [ ] **IOS-OPS-001C** — normalized build numbering (separate from Git metadata)
- [ ] Optionally migrate `MoreView` version line to `BuildMetadata.current`

### Current state
IOS-OPS-001B complete on branch `ios-ops/build-metadata-injection`. Settings footer can show live Git provenance from the built app plist. Not committed unless requested.

---

## 2026-06-01 — Normalize Version and Build Settings (IOS-OPS-001C) (Cursor)

### What was built
- **`HueHome/Info.plist`** — Replaced hard-coded `0.9.0` / `1` with `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` plist substitutions.
- **`HueHome.xcodeproj/project.pbxproj`** — Added `MARKETING_VERSION = 0.9.0` and `CURRENT_PROJECT_VERSION = 1` to HueHome Debug and Release target configurations (authoritative source of truth for the main app).
- **`HueHome/UI/More/MoreView.swift`** — Replaced direct `CFBundleShortVersionString` / `CFBundleVersion` reads (stale `"0.3.0"` fallback) with `BuildMetadata.current`.

### Version/build normalization policy
- Xcode build settings are the single source of truth: `MARKETING_VERSION = 0.9.0`, `CURRENT_PROJECT_VERSION = 1`.
- Main app plist uses build-setting substitutions; IOS-OPS-001B injection continues to write Git provenance keys into the **processed** bundle plist only.
- Embedded bundles already normalized via `GENERATE_INFOPLIST_FILE = YES` + per-target build settings — no extension/watch plist edits required.

### Pre-edit inventory (shipped bundles)
| Bundle / target | Info.plist path | Short-version source | Build-number source | Debug | Release | Embedded in main app? |
|---|---|---|---|---|---|---|
| HueHome (main) | `HueHome/Info.plist` | Hard-coded → now `$(MARKETING_VERSION)` | Hard-coded → now `$(CURRENT_PROJECT_VERSION)` | 0.9.0 / 1 | 0.9.0 / 1 | — |
| HueHomeWidgetExtension | `HueHomeWidget/Info.plist` (NSExtension only) | `MARKETING_VERSION` via generated plist | `CURRENT_PROJECT_VERSION` via generated plist | 0.9.0 / 1 | 0.9.0 / 1 | Yes (`PlugIns/`) |
| LightShadeWatchExtension | `LightShadeWatch/Info.plist` (NSExtension only) | `MARKETING_VERSION` via generated plist | `CURRENT_PROJECT_VERSION` via generated plist | 0.9.0 / 1 | 0.9.0 / 1 | No (watch app embeds separately) |
| LightShadeWatchApp Watch App | Generated (no source plist) | `MARKETING_VERSION` | `CURRENT_PROJECT_VERSION` | 0.9.0 / 1 | 0.9.0 / 1 | Yes (`Watch/`) |

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → **19/19 pass** (injector unchanged)
- Debug `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' build` → **BUILD SUCCEEDED** (60 pre-existing warnings, none from this change)
- Release build → **BUILD SUCCEEDED** (55 pre-existing warnings)
- Built main app plist: `CFBundleShortVersionString = 0.9.0`, `CFBundleVersion = 1`, Git metadata keys present, `ChromaGlowGitDirty = 1` during uncommitted work
- Nested bundles (widget `.appex`, watch `.app`): all `0.9.0` / `1` in Debug and Release
- Second incremental Debug build: keys not duplicated, timestamp updated (`2026-06-01T23:22:05Z` → `2026-06-01T23:24:38Z`)
- Source `HueHome/Info.plist` contains substitution tokens only (no Git keys)
- `codesign --verify --deep --strict` on Debug and Release built apps → **pass**
- `git diff --check` → clean

### Physical-device verification
1. Open **`HueHome.xcodeproj`** (not `ChromaGlow.xcodeproj`)
2. Scheme **`HueHome 1`** → physical iPhone
3. Product → Clean Build Folder → Run
4. **More → Settings** → scroll to footer
5. Confirm: `Version 0.9.0 · Build 1`, commit prefix matches `git rev-parse --short=8 HEAD`, branch `ios-ops/normalize-version-settings`, UTC timestamp, **Working tree modified** while uncommitted
6. Force quit → relaunch → footer stable
7. After commit + clean rebuild → dirty line disappears

### Gotchas
- Tracked project remains **`HueHome.xcodeproj`**; `ChromaGlow.xcodeproj` is an incomplete local shell
- HueHomeTests target has no `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (test bundle only, not shipped)

### What's next
- [x] **IOS-OPS-001D** — push-triggered CI build numbering (see DEVLOG entry below)

### Current state
IOS-OPS-001C merged to `main`. Effective version/build preserved at `0.9.0` / `1`.

---

## 2026-06-01 — Push-Triggered CI Build Numbering (IOS-OPS-001D) (Cursor)

### What was built
- **`.github/workflows/ios-build-provenance.yml`** — Push + manual workflow on `macos-latest` that runs shell tests, builds unsigned Debug iOS app with `CURRENT_PROJECT_VERSION=${GITHUB_RUN_NUMBER}`, verifies metadata, inspects nested widget/watch bundles, writes provenance report, and uploads report + processed main app plist artifact.
- **`Scripts/verify_built_app_metadata.sh`** — Read-only validator for processed built-app plists (version, build, Git metadata, timestamp format, dirty state).
- **`Scripts/tests/test_verify_built_app_metadata.sh`** — 17 fixture tests for the verifier.
- **`Scripts/inject_build_metadata.sh`** — Added `CHROMAGLOW_GIT_BRANCH_OVERRIDE` for CI detached-HEAD branch metadata (local behavior unchanged when unset).
- **`Scripts/tests/test_inject_build_metadata.sh`** — Added branch-override tests (detached HEAD + slash branch); now **21/21 pass**.

### CI build-number policy
- **CI:** `CURRENT_PROJECT_VERSION = GITHUB_RUN_NUMBER` via command-line `xcodebuild` override (no source or project-file mutation).
- **Local Xcode:** unchanged — `CURRENT_PROJECT_VERSION = 1` from project settings → Settings footer shows `Build 1`.
- **Marketing version:** `0.9.0` everywhere (unchanged).

### Branch metadata in CI
- `CHROMAGLOW_GIT_BRANCH_OVERRIDE=${GITHUB_REF_NAME}` is set **only on the Build unsigned iOS app step** (not job-wide), so shell fixture tests still see fixture repo branch `main`.
- Local builds without override preserve existing `git branch --show-current` behavior.

### CI workflow hardening (first hosted runs)
| Fix | Problem | Resolution |
|---|---|---|
| Fixture default branch | GitHub runners use `master`; clean-repo test expected `main` | `git init -q -b main` in `init_clean_repo` |
| Branch override scope | Job-level override leaked into shell tests | Move override to build step `env` only |
| Xcode toolchain | Default runner Xcode 16.4 vs local 26.4 | **Select Xcode 26.3** step sets `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer` |
| Processed plist lookup | `find -path 'Debug-iphoneos/...'` never matched absolute paths | Deterministic `${DERIVED_DATA}/Build/Products/Debug-iphoneos/HueHome.app/Info.plist` + diagnostic `find` fallback |

### Compiler compatibility (Xcode 26.3 CI only; behavior-neutral)
- **`HueHome/UI/LightControl/LightControlView.swift`** — `ColorWheelView`: explicit `CGFloat` angles + `CoreGraphics.cos` / `CoreGraphics.sin` (resolved ambiguous `cos`/`sin` overloads).
- **`HueHome/UI/Studio/StudioView.swift`** — `motionAngleDial` + `spatialMiniMap`: same `CGFloat` + `CoreGraphics` pattern (resolved type-check timeout on `ZStack`).

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- Local CI-style unsigned build with `CURRENT_PROJECT_VERSION=4242` + `CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**
- Main app built plist: `0.9.0` / `4242`, Git metadata present; deterministic plist path lookup **PASS**
- Nested bundles: widget + watch both `0.9.0` / `4242`
- `git diff -- HueHome/Info.plist` → **no diff** (IOS-OPS-001D policy unchanged)
- `git diff -- HueHome.xcodeproj/project.pbxproj` → **no diff**
- Ruby YAML parse of workflow → **PASS**

### Post-push GitHub validation
1. Push branch → **Actions** → **iOS Build Provenance** → confirm job succeeds end-to-end
2. Workflow summary: marketing `0.9.0`, CI build number = run number, commit/branch match, dirty `0`
3. Download artifact `ios-build-provenance-<run_id>-<attempt>`; confirm `ios-build-provenance.txt` + processed `HueHome.app/Info.plist`
4. After merge to `main`, confirm `main` push also triggers and passes

### Gotchas
- Tracked project remains **`HueHome.xcodeproj`**; `ChromaGlow.xcodeproj` is an incomplete local shell
- CI builds are **unsigned validation builds** — not installable on physical devices; local Xcode builds still show **`Build 1`**
- Hosted runner must have `Xcode_26.3.app`; workflow fails fast with installed Xcode list if missing
- No signing secrets, TestFlight upload, archive export, or auto-commit in this chunk

### What's next
- [ ] **IOS-OPS-001E** (optional) — signed archive and TestFlight delivery

### Current state
IOS-OPS-001D merged to `main` via PR #5 (`eb214c4`). Push-triggered **iOS Build Provenance** workflow validates CI build numbering and metadata without mutating source version settings. Local physical-device builds remain `Version 0.9.0 · Build 1`.

---

## 2026-06-01 — Dashboard Room Builder Recovery (IOS-REF-001R) (Cursor)

### What was built
- **Branch:** `ios-ref/dashboard-room-builder`
- **Starting SHA:** `1793338` (fast-forwarded to `origin/main`)
- **`HueHome/Core/Dashboard/DashboardDisplayModelBuilder.swift`** — pure `makeRooms(from:)` helper: flatten `roomsByBridge` values → localized alphabetical sort by name → ID-only de-duplication.
- **`HueHome/Core/Network/UnifiedOrchestrator.swift`** — `rebuildAllRooms()` delegates composition to the builder; navigation buffering (`isNavigating` / `sseRebuildPendingRooms`) and `scheduleWidgetWrite()` unchanged.
- **`HueHomeTests/DashboardDisplayModelBuilderTests.swift`** — seven focused contract tests (empty input, multi-bridge sort, duplicate IDs, sort-before-dedupe, same-name different IDs, field preservation, input non-mutation).
- **`HueHome.xcodeproj/project.pbxproj`** — `Dashboard` group under `Core`; builder + test file membership only.

### Preserved behavior
- Navigation buffering during push transitions
- Widget/watch snapshot scheduling via `scheduleWidgetWrite()` (orchestrator-only)
- ID-only de-duplication (not `(bridgeID, id)`)
- Localized ascending name sort before dedupe
- `rebuildAllZones()`, `scheduleWidgetWrite()`, `updateRoom(...)` untouched

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- `xcodebuild -project HueHome.xcodeproj -target HueHomeTests -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build` → **BUILD FAILED** (pre-existing: `LightShadeWatchApp Watch App` `AppIcon` asset catalog has no applicable content for iOS Simulator — HueHomeTests depends on HueHome, which embeds watch targets)
- Focused `xcodebuild test` → **blocked**: shared scheme `HueHome 1` has `<TestAction shouldAutocreateTestPlan="YES">` but no `<Testables>` entries (unchanged per task scope)

### Physical-device smoke (Brian)
1. Open **`HueHome.xcodeproj`**, scheme **`HueHome 1`**, physical iPhone.
2. **Product → Clean Build Folder → Run**
3. **More → Settings** footer: branch `ios-ref/dashboard-room-builder`, SHA matches `git rev-parse --short HEAD`
4. Dashboard: no crash; room cards alphabetical; no duplicate cards
5. Room detail → back; toggle room; adjust brightness; force quit → relaunch
6. Multi-bridge (if available): rooms from both bridges, no duplicate IDs
7. Widget (if installed): updates after room action

### Manual test run (Xcode)
- Open `DashboardDisplayModelBuilderTests.swift` → click diamond on `DashboardDisplayModelBuilderTests` class or individual tests in Test navigator (⌘6) after a successful app build on device/simulator.

### What's next
- [ ] **IOS-REF-002** — zone-list builder extraction (`rebuildAllZones()` seam)

### Current state
IOS-REF-001R complete on branch `ios-ref/dashboard-room-builder`. Behavior-neutral strangler seam; orchestrator remains facade. Not committed unless requested.

---

## 2026-06-01 — Dashboard Zone Builder Extraction (IOS-REF-002)

### What was built
- **Branch:** `ios-ref/dashboard-zone-builder`
- **Starting SHA:** `02fa48a`
- **`DashboardDisplayModelBuilder.makeRooms(from:)`** — left unchanged (IOS-REF-001R)
- **`DashboardDisplayModelBuilder.makeZones(from:)`** — pure helper: flatten `zonesByBridge` values → localized alphabetical sort by name → ID-only de-duplication
- **`UnifiedOrchestrator.rebuildAllZones()`** — composition delegates to `makeZones(from:)`; navigation buffering and `scheduleWidgetWrite()` remain orchestrator-only
- **`HueHomeTests/DashboardDisplayModelBuilderTests.swift`** — seven zone contract tests mirroring room coverage

### Preserved behavior
- Navigation buffering (`isNavigating` / `sseRebuildPendingZones`)
- Widget/watch snapshot scheduling via `scheduleWidgetWrite()` (orchestrator-only)
- ID-only de-duplication (not `(bridgeID, id)`)
- Localized ascending name sort before dedupe
- `rebuildAllRooms()`, `scheduleWidgetWrite()`, `updateRoom(...)` untouched

### Validation
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- `xcodebuild -project HueHome.xcodeproj -target HueHomeTests -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build` → **BUILD FAILED** (pre-existing: `LightShadeWatchApp Watch App` `AppIcon` asset catalog has no applicable content for iOS Simulator)
- Focused `xcodebuild test` → **blocked**: shared scheme `HueHome 1` has `<TestAction shouldAutocreateTestPlan="YES">` but no `<Testables>` entries (unchanged per task scope)
- `git diff --check` → clean
- Prohibited files (`project.pbxproj`, `RoomDisplayItem.swift`, etc.) → **no diff**

### Physical-device smoke (Brian)
1. Open **`HueHome.xcodeproj`**, scheme **`HueHome 1`**, physical iPhone
2. **Product → Clean Build Folder → Run**
3. **More → Settings** footer: branch `ios-ref/dashboard-zone-builder`, SHA matches `git rev-parse --short HEAD`
4. Dashboard: no crash; room cards correct; zone section/cards if configured
5. Zone cards alphabetically ordered; no duplicate zone cards
6. Zone detail (if supported) → back; toggle zone if supported; force quit → relaunch
7. Multi-bridge (if available): zones from both bridges, no duplicate IDs
8. Widget (if installed): room state still updates after a room action

### Manual test run (Xcode)
- Test navigator (⌘6) → `DashboardDisplayModelBuilderTests` → run zone tests after app build

### What's next
- [ ] **IOS-REF-003** (optional) — shared flatten/sort/dedupe helper if a third dashboard list seam appears; not required while duplication stays bounded

### Current state
IOS-REF-002 complete on branch `ios-ref/dashboard-zone-builder`. Behavior-neutral zone-list strangler seam; orchestrator remains facade. Not committed unless requested.

---

## 2026-06-01 — Shared HueHome Unit-Test Scheme Configuration (IOS-TEST-001A)

### What was built
- **Branch:** `ios-test/configure-huehome-tests`
- **Starting SHA:** `7e16095`
- **Existing scheme gap:** shared `HueHome 1` had `<TestAction shouldAutocreateTestPlan="YES">` with no `<Testables>` entries — Xcode reported “no scheme and/or test plan that contains every test you are trying to run”
- **`HueHomeTests` added to shared scheme TestAction** — `BlueprintIdentifier = F28E742458072F94D9443FF7`, `BuildableName = HueHomeTests.xctest`
- **Production build action unchanged** — `BuildAction` still lists only `HueHome.app`
- **`project.pbxproj` unchanged**

### Validation
- `xmllint --noout` on `HueHome 1.xcscheme` → **valid**
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- **Test discovery:** `xcodebuild test` dependency graph includes `HueHomeTests`; `-only-testing:HueHomeTests/DashboardDisplayModelBuilderTests` accepted — missing `<Testables>` / “no scheme and/or test plan” error **resolved**
- **Focused test execution:** `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HueHomeTests/DashboardDisplayModelBuilderTests` → **TEST FAILED** (build): `HueHomeTests` — “Cannot code sign because the target does not have an Info.plist file” (`GENERATE_INFOPLIST_FILE` not set on test target; **out of IOS-TEST-001A scope** — needs `project.pbxproj` or follow-up)
- **Watch AppIcon blocker (still present on direct test-target simulator build):** `LightShadeWatchApp Watch App/Assets.xcassets` — AppIcon did not have any applicable content for iOS Simulator when building `-target HueHomeTests -sdk iphonesimulator` — **not fixed in IOS-TEST-001A**

### Follow-up
- [ ] **IOS-TEST-001B** — unblock simulator test runs (watch AppIcon / embed graph) without broadening god-object extraction scope

### Current state
IOS-TEST-001A complete on branch `ios-test/configure-huehome-tests`. Scheme testable wired; no production or pbxproj edits. Not committed unless requested.

---

## 2026-06-01 — Generated HueHomeTests Info.plist (IOS-TEST-001B)

### What was built
- **Branch:** `ios-test/generate-huehome-tests-infoplist`
- **Starting SHA:** `5080279`
- **`HueHomeTests` Debug (`04AA42E47C3895B901BFC504`)** — added `GENERATE_INFOPLIST_FILE = YES`
- **`HueHomeTests` Release (`23C04301B398D3D9D7657757`)** — added `GENERATE_INFOPLIST_FILE = YES`
- **No production build settings changed** — only the two HueHomeTests configuration blocks above
- **No Swift code changed** — `HueHome/` and `HueHomeTests/` untouched

### Validation
- `git diff --check` → **clean**
- `bash Scripts/tests/test_inject_build_metadata.sh` → **21/21 pass**
- `bash Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 pass**
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- **Focused simulator test:** `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HueHomeTests/DashboardDisplayModelBuilderTests` → **TEST FAILED** (build): Swift compile errors in `HueHomeTests` (not Info.plist)
- **Info.plist blocker:** **resolved** — `ProcessInfoPlistFile` generates `HueHomeTests.xctest/Info.plist`; no “Cannot code sign because the target does not have an Info.plist file” error
- **Watch AppIcon blocker:** **not observed** on this scheme-based simulator test run (watch targets built; no AppIcon asset-catalog failure)

### Next blocker
- **`KeychainManagerTests.swift:12`** — `'KeychainManager' initializer is inaccessible due to 'private' protection level`
- **`HueAPIClientTests.swift:58`** — `overriding declaration requires an 'override' keyword` on `TestableAPIClient.init`

### Follow-up
- [x] **IOS-TEST-001C** (or test-source fix slice) — repair stale `HueHomeTests` compile errors so focused `DashboardDisplayModelBuilderTests` can run (out of IOS-TEST-001B scope)

### Current state
IOS-TEST-001B complete on branch `ios-test/generate-huehome-tests-infoplist`. Two generated-plist settings only; not committed unless requested.

---

## 2026-06-01 — Repair stale HueHomeTests compile errors (IOS-TEST-001C)

### What was built
- **`HueHomeTests/KeychainManagerTests.swift`** — use `KeychainManager.shared` instead of `KeychainManager()` (production init is `private`)
- **`HueHomeTests/HueAPIClientTests.swift`** — mark `TestableAPIClient.init(ip:token:)` as `override` and call `super.init(ip:token:)` to match production `HueAPIClient.init(ip:token:)`
- **No production Swift changed** — `HueHome/` untouched
- **No pbxproj / scheme / asset changes**

### Validation
- `xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HueHomeTests/DashboardDisplayModelBuilderTests test CODE_SIGNING_ALLOWED=NO` → **TEST SUCCEEDED** (14/14 cases)
- Prior compile blockers (`KeychainManagerTests:12`, `HueAPIClientTests:58`) → **resolved**

### What's left
- [ ] Commit IOS-TEST-001C slice when requested
- [ ] Remaining HueHomeTests suites (Orchestrator, HueAPIClient, Keychain, etc.) not run in this focused validation

### Current state
IOS-TEST-001C complete locally. Test-only diff (2 files + DEVLOG); not committed unless requested.

---

## 2026-06-01 — Signed Simulator Runtime Test Repair (IOS-TEST-001D)

### Context
- **Branch:** `ios-test/repair-simulator-runtime-tests`
- **Starting SHA:** `1038a6a`
- Prior full-suite baseline on unsigned simulator runs (`CODE_SIGNING_ALLOWED=NO`): **60 passed / 8 failed / 68** (7× `errSecMissingEntitlement` in `KeychainManagerTests`, 1× stale `HueAPIClientTests.testMissingCredentialsThrowsCorrectError` expecting `missingCredentials` but receiving `httpError(404)`)

### Signed simulator baseline (before edit)
- Destination: `platform=iOS Simulator,name=iPhone 17 Pro` (no `CODE_SIGNING_ALLOWED=NO`)
- **Keychain entitlement failures:** disappeared — all 7 `KeychainManagerTests` passed
- **Remaining failure:** `HueAPIClientTests.testMissingCredentialsThrowsCorrectError` only
- Full `HueHomeTests`: **67 passed / 1 failed / 68**

### Fix (test-only)
- **`HueHomeTests/HueAPIClientTests.swift`** — `TestableAPIClient.credentials()` now rejects empty `stubIP` / `stubToken` with `HueAPIError.missingCredentials`, matching production `HueAPIClient.credentials()` semantics (no production Swift change)

### Validation (after edit)
- Shell: `Scripts/tests/test_inject_build_metadata.sh` → **21/21 PASS**; `Scripts/tests/test_verify_built_app_metadata.sh` → **17/17 PASS**
- Generic unsigned app build (`CODE_SIGNING_ALLOWED=NO`, `generic/platform=iOS`) → **BUILD SUCCEEDED**
- Focused: `HueHomeTests/DashboardDisplayModelBuilderTests` (signed simulator) → **TEST SUCCEEDED** (14/14)
- Full: `HueHomeTests` (signed simulator) → **TEST SUCCEEDED** (68/68)

### Keychain isolation review (recommendation)
- `KeychainManagerTests` use production legacy keys (`hue_api_token`, `hue_bridge_ip`) via `saveAPIToken` / `saveBridgeIP` — not the per-test `tokenKey` / `ipKey` helpers (those apply only to generic `save(for:)` tests). Consider a follow-up harness slice to namespace test credentials or inject a test-only service name without touching production `KeychainManager` until approved.

### Current state
IOS-TEST-001D test-only slice ready for commit when requested. No production Keychain, entitlements, or pbxproj changes.

---

## 2026-06-02 — UnifiedOrchestrator Pure-Seam Inventory (IOS-REF-003A)

### What was done
- Branch: `ios-ref/orchestrator-pure-seam-inventory`
- Starting SHA: `4db4b68`
- Scope: documentation-only inventory of `UnifiedOrchestrator.swift` responsibilities, state surface, and side-effect boundaries.
- Added `docs/ios/unified-orchestrator-pure-seam-inventory.md` describing public/private state, responsibility map, classifications, and candidate pure seams.
- Recorded the existence of the previously extracted dashboard room/zone builder seam (`DashboardDisplayModelBuilder`) and its tests (`DashboardDisplayModelBuilderTests`).

### Baseline and tests
- Existing automated baseline (from IOS-TEST-001D): `DashboardDisplayModelBuilderTests` → 14/14 pass.
- Existing full `HueHomeTests` suite baseline: 68/68 pass on signed simulator.
- No new tests were added or run for IOS-REF-003A; this slice is docs-only.

### Recommended next refactor (IOS-REF-003B)
- Proposed task ID: `IOS-REF-003B`.
- Recommended seam: extract the room and zone display-model composition logic from `UnifiedOrchestrator.fetchAndMergeAllBridges()` into a pure helper (proposed `RoomAndZoneDisplayModelBuilder` under `HueHome/Core/Dashboard/`).
- Delegation point: the loops that build `RoomDisplayItem`/zone `RoomDisplayItem` values and light-to-room/zone maps from `rooms`, `zones`, `lights`, and `groupedLights` (currently around lines 606–751).
- Expected behavior: no change to network calls, SSE lifecycle, optimistic updates, rollback semantics, persistence, or widgets/watch; only pure transformation code moves behind a helper.

### Deferred high-risk areas
- SSE connection coordination and event application (`startSSE`, `stopSSE`, `runSSE`, `applySSEEvent`).
- Pending-action deadline logic and optimistic mutation/rollback for rooms and zones.
- All-day scenes scheduler and `UserDefaults`-backed anchors.
- Widget/watch snapshot writing and App Group payload shape.
- Bridge registry lifecycle and multi-bridge routing (`configure`, `addBridge`, `removeBridge`).
- Studio/Composer entertainment routing, bridge-stored animation, and Keychain/SwiftData/App Group contracts.

### Constraints for this slice
- No Swift files modified.
- No Xcode project files modified.
- No changes to networking, Hue API behavior, SSE cadence, optimistic updates, rollback, persistence, widgets, watch, or Studio/Composer runtime behavior.
- No new builds or physical-device tests required for IOS-REF-003A (documentation-only).

---

## 2026-06-02 — Room and Zone Display-Model Builder Extraction (IOS-REF-003B)

### What was built
- **Branch:** `ios-ref/room-zone-display-model-builder`
- **Starting SHA:** `6ebb0c3`
- Added pure helper: `HueHome/Core/Dashboard/RoomAndZoneDisplayModelBuilder.swift`
- Added focused tests: `HueHomeTests/RoomAndZoneDisplayModelBuilderTests.swift`
- `UnifiedOrchestrator.fetchAndMergeAllBridges()` now delegates deterministic room/zone model construction to `RoomAndZoneDisplayModelBuilder.makeDisplayModels(rooms:zones:lights:groupedLights:bridgeID:)` after the existing async fetches complete.

### Behavior preserved
- Networking behavior preserved (same per-bridge parallel `fetchRooms/fetchZones/fetchLights/fetchGroupedLights` pattern).
- Bridge routing preserved (orchestrator still iterates `clients` and merges per bridge).
- Outer state writes preserved in orchestrator (`roomsByBridge`, `zonesByBridge`, `lightIDToRoomID`, `lightIDToZoneID`, `connectionStatus`).
- SSE behavior preserved (`startSSE`/`applySSEEvent` paths untouched).
- Cache behavior preserved (`loadAll` / `writeCache` flow unchanged).
- Widget/watch write scheduling preserved (`rebuildAllRooms()`, `rebuildAllZones()`, `scheduleWidgetWrite()` unchanged).

### New focused tests
- Empty input returns empty rooms/zones/maps.
- Room model contract (name/archetype/kind/bridgeID/grouped light/child refs/isOn/brightness).
- Zone model contract (name/archetype/kind/bridgeID/grouped light/child refs/isOn/brightness).
- Room map semantics including room device-owner fallback behavior.
- Zone map semantics with direct light refs.
- Overlap behavior (same light can appear in room and zone maps).
- Dominant visual-state behavior (brightest ON color, mirek fallback, grouped-off fallback).
- Input immutability.

### Validation
- Signed simulator results: **pending local run in this slice**
- Generic unsigned app build result: **pending local run in this slice**

### Physical-device smoke instructions
1. Open `HueHome.xcodeproj`
2. Scheme: `HueHome 1`
3. Destination: physical iPhone
4. Product → Clean Build Folder
5. Product → Run
6. Verify dashboard and room/zone behaviors match pre-extraction baseline.

### Follow-up recommendation
- Keep future seams similarly bounded and pure (state-only transforms first, orchestration remains facade).

---

## 2026-06-02 — Composer Cadence Pure-Seam Inventory (IOS-REF-004A)

### What was done
- Branch: `ios-ref/composer-cadence-seam-inventory`
- Starting SHA: `bc1cbbc`
- Scope: documentation-only inventory of the next bounded pure `UnifiedOrchestrator` seam after IOS-REF-003B.
- Added inventory doc: `docs/ios/composer-cadence-pure-seam-inventory.md`

### Baseline and context
- Current validated baseline (project-tracked): signed-simulator `HueHomeTests` 74/74 pass.
- Prior extraction baseline acknowledged: IOS-REF-003B merged to `main`.
- IOS-REF-003B physical-device smoke: passed.

### Recommendation
- Cadence scalar quartet (`minimumComposerRESTInterval`, `minimumComposerBurstFloor`, `preferredComposerIdleInterval`, `lowPowerIdleInterval`) is PURE but currently has zero call sites.
- No IOS-REF-004B production extraction should proceed for this quartet; extracting unwired helpers would move dead-code-like logic without reducing live orchestrator runtime responsibility.
- `CompositionTier` is accepted by the quartet but currently does not affect outputs.
- Live REST scheduling remains driven by fixed cadence behavior inside `runCompositionScheduler()` (`tickInterval` + `nextDueAt` updates), not by the unwired quartet.
- Do not wire the quartet into scheduler paths as part of this refactor.
- Do not delete the quartet in this docs-only slice.
- Optional later dead-code cleanup may evaluate deletion only after explicit approval and Composer smoke planning.

### Recommended next docs-only task
- `IOS-REF-005A — Inventory a live pure scoring sub-helper inside nextCompositionRoomPriority(now:)`

### Deferred high-risk Composer areas
- Scheduler loop behavior and task timing (`runCompositionScheduler`, `runCompositionEntertainment`).
- Room-priority selection and runtime mutation (`nextCompositionRoomPriority`, `compositionRuntimes` lifecycle).
- REST mailbox behavior, DTLS routing, bridge-stored animation routing, and mic-demand orchestration.

### Constraints for this slice
- No Swift changes.
- No project-file changes.
- No physical-device test required for this docs-only slice.

---

## 2026-06-02 — Composer Light Resolver Extraction (IOS-REF-006B)

### What was done
- Branch: `ios-ref/composer-light-resolver`
- Starting SHA: `27d6a16`
- Added pure helper: `HueHome/Core/Composer/CompositionLightResolver.swift`
- Added focused tests: `HueHomeTests/CompositionLightResolverTests.swift`
- Delegated deterministic child-resource resolution from:
  - `resolveCompositionGamut(for:api:)`
  - `resolveCompositionLightIDs(for:api:)`
  in `HueHome/Core/Network/UnifiedOrchestrator.swift`

### Preserved behavior contract
- Direct-light precedence preserved: any `rtype == "light"` still short-circuits mixed refs to direct mode.
- ID direct mode preserved: ref order and duplicates preserved; non-light refs ignored.
- Gamut-path light resolution preserved: direct mode still uses set-membership against fetched lights and returns fetched-light order.
- Owner fallback preserved for both paths via `light.owner?.rid` matching.
- Conditional fetch behavior preserved:
  - gamut path still always fetches lights
  - light-ID direct mode still bypasses fetch
  - light-ID owner fallback still fetches lights
- Fetch-failure fallbacks preserved in orchestrator:
  - gamut -> `.c`
  - owner-ID path -> `[]`
- Gamut majority selection and implicit tie behavior left inline and unchanged.
- `resolveEntertainmentLightPositions(config:api:)` left untouched.

### Focused test coverage added
- `CompositionLightResolverTests` covers:
  - direct-mode detection (`false/true/mixed`)
  - direct ID semantics (order, duplicates, mixed refs, empty lights)
  - direct light resolution semantics (fetched-light ordering, deduplicated membership, omitted missing refs, mixed-ref precedence)
  - owner fallback semantics (owner matching, fetched-light order, duplicate-device refs, non-matching and nil-owner omission)
  - edge cases (empty refs/lights, non-matching refs, determinism, input immutability)

### Validation plan/results
- Existing pure-seam baselines expected unchanged:
  - `CompositionRoomPriorityScorerTests` target: 19/19
  - `RoomAndZoneDisplayModelBuilderTests` target: 6/6
  - `DashboardDisplayModelBuilderTests` target: 14/14
- Full signed-simulator suite target: prior 93 tests plus new resolver tests, all passing.
- Generic unsigned app build target: `BUILD SUCCEEDED`.
- Shell metadata tests expected unchanged:
  - Injector tests -> 21/21 PASS
  - Verifier tests -> 17/17 PASS

### Physical-device Composer smoke instructions
- Open `HueHome.xcodeproj`
- Scheme: `HueHome 1`
- Destination: physical iPhone
- Product -> Clean Build Folder
- Product -> Run
- Verify Settings footer first:
  - Branch `ios-ref/composer-light-resolver`
  - Working tree modified
- Then verify normal Composer flow:
  - app launch + dashboard render
  - Composer start/stop/restart responsiveness
  - expected lights animate/update with no unexpected toasts or stuck UI
  - direct-light and mixed-ref topologies (if available) preserve visible behavior
  - REST-vs-entertainment routing remains unchanged
  - force-quit + relaunch + re-run Composer

### Follow-up recommendation
- Keep any future light-resolution slices narrowly scoped:
  - leave network/credentials/JSON/routing in `UnifiedOrchestrator`
  - pin gamut tie behavior in a dedicated slice before extracting gamut-majority logic.

---

## 2026-06-02 — Composer Priority-Scoring Pure-Seam Inventory (IOS-REF-005A)

### What was done
- Branch: `ios-ref/composer-priority-scoring-inventory`
- Starting SHA: `cb01e11`
- Scope: documentation-only inventory for extracting a bounded live pure scoring helper from `nextCompositionRoomPriority(now:)`.
- Added inventory doc: `docs/ios/composer-priority-scoring-pure-seam-inventory.md`

### Baseline and prior decisions acknowledged
- Current validated baseline: signed-simulator `HueHomeTests` 74/74 pass.
- IOS-REF-003B physical-device dashboard/room/zone smoke: passed.
- IOS-REF-004A decision acknowledged: cadence quartet remains pure but unwired, with no IOS-REF-004B extraction recommended.

### Findings
- `nextCompositionRoomPriority(now:)` is confirmed live (called by `runCompositionScheduler()`).
- A value-only score sub-helper is recommended for IOS-REF-005B, with orchestrator-owned iteration/tie-breaking preserved unchanged.
- Score logic is deterministic and value-only; no network I/O, SSE, Task creation/cancellation, persistence, or routing decisions inside scoring.

### Deferred high-risk Composer areas
- Scheduler cadence/tick behavior and runtime mutation timing in `runCompositionScheduler()`.
- REST mailbox semantics (`studioRestSender`) and generation guard lifecycle.
- Transport routing (bridge-stored vs entertainment vs REST) and mic-demand orchestration.

### Constraints for this slice
- No Swift changes.
- No project-file changes.
- No physical-device testing required for this docs-only slice.

---

## 2026-06-02 — Composer Room-Priority Scorer Extraction (IOS-REF-005B)

### What was done
- Branch: `ios-ref/composer-priority-scorer`
- Starting SHA: `3d8ee2f`
- Added pure scorer helper: `HueHome/Core/Composer/CompositionRoomPriorityScorer.swift`
- Added focused tests: `HueHomeTests/CompositionRoomPriorityScorerTests.swift`
- Delegated only the eligibility-and-score block inside `nextCompositionRoomPriority(now:)` in `HueHome/Core/Network/UnifiedOrchestrator.swift`
- Preserved orchestrator-owned `compositionOrder` traversal and strict `score > selectedScore` tie-breaking.

### Preserved behavior contract
- Due-gate grace preserved exactly: `now + 0.004 < nextDueAt` ineligible.
- Numeric score terms/formulas preserved exactly:
  - `+1000` interaction
  - `+500` interaction burst
  - `+260` pending settle
  - `+min(220, overdue * 120)`
  - `+min(160, max(0, sinceLastSend - 1.4) * 45)`
  - `-min(60, Double(sendCount % 120) * 0.35)`
- Scheduler cadence unchanged (`tickInterval` and `nextDueAt` write path unchanged).
- REST mailbox behavior unchanged (`studioRestSender` usage unchanged).
- Runtime mutation timing unchanged (writes still in `runCompositionScheduler()` after selection).
- Transport routing unchanged (REST vs entertainment paths untouched).

### Test and validation notes
- Focused scorer tests cover due gate, all term contributions/caps, fallback semantics, modulo fairness rollover, combined score, determinism, and input immutability.
- Existing builder baselines remain expected:
  - `DashboardDisplayModelBuilderTests` 14/14 pass target.
  - `RoomAndZoneDisplayModelBuilderTests` 6/6 pass target.
- Full signed-simulator `HueHomeTests` baseline remains expected to include prior 74 plus new scorer tests.
- Generic unsigned app build target remains `BUILD SUCCEEDED`.

### Physical-device Composer smoke instructions
- Open `HueHome.xcodeproj`
- Scheme: `HueHome 1`
- Destination: physical iPhone
- Product -> Clean Build Folder
- Product -> Run
- In app, verify Settings footer shows:
  - Branch `ios-ref/composer-priority-scorer`
  - Working tree modified
- Then verify:
  - App launches without crash
  - Dashboard opens normally
  - Studio/Composer start/stop remains responsive
  - Multi-room interaction remains responsive with no starvation, stuck UI, or unexpected toast
  - Transport behavior remains unchanged (REST vs entertainment path)
  - Force quit, relaunch, and re-verify dashboard + Composer responsiveness

### Follow-up recommendation
- Keep future Composer refactors bounded to pure value helpers first, leaving scheduler ownership and runtime mutation timing in `UnifiedOrchestrator`.

---

## 2026-06-02 — Composer Light-Resolution Pure-Seam Inventory (IOS-REF-006A)

### What was done
- Branch: `ios-ref/composer-light-resolution-inventory`
- Starting SHA: `93a3584`
- Scope: documentation-only inventory for live Composer light-resolution seams in `UnifiedOrchestrator`.
- Added inventory doc: `docs/ios/composer-light-resolution-pure-seam-inventory.md`
- Inspected live methods:
  - `resolveCompositionGamut(for:api:)`
  - `resolveCompositionLightIDs(for:api:)`
  - `resolveEntertainmentLightPositions(config:api:)`
  - plus caller `startCompositionMode(...)`

### Baseline and prior context acknowledged
- Current validated baseline: full signed-simulator `HueHomeTests` 93/93 pass.
- IOS-REF-005B physical-device Composer smoke: passed.
- Prior extracted seams acknowledged (IOS-REF-001R / IOS-REF-002 / IOS-REF-003B / IOS-REF-005B).

### Recommendation
- Recommend one narrow IOS-REF-006B production extraction: shared value-only child-resource light resolution helper reused by gamut/light-ID methods.
- Keep all fetches, credentials access, JSON payload parsing, routing, and runtime mutation inside `UnifiedOrchestrator`.
- Keep gamut majority selection inline for IOS-REF-006B because tie behavior is currently implicit and should not be changed during this slice.

### Behavioral constraints captured
- Direct `rtype == "light"` semantics, owner fallback semantics, mixed-ref precedence, and empty-input behavior documented.
- Ordering/duplicate constraints documented:
  - direct-ref ID order and duplicate preservation
  - owner-path dependence on fetched light-array order
  - entertainment map duplicate overwrite behavior (last-write-wins across mapping layers)
- Fallback constraints documented:
  - gamut: `.c` fallbacks
  - light IDs: `[]` fallbacks
  - entertainment positions: `[:]` fallbacks

### Deferred high-risk areas
- Network access, credentials handling, and raw JSON parsing remain deferred.
- Transport and bridge routing behavior remains deferred.
- Scheduler cadence, mailbox behavior, generation guards, and runtime mutation remain deferred.

### Constraints for this slice
- No Swift changes.
- No project-file changes.
- No physical-device test required for this docs-only slice.

---

## 2026-06-02 — Composer Fetch-Path Parity Coverage Inventory (IOS-TEST-002A)

### Scope
- Branch: `ios-test/composer-fetch-path-parity-inventory`
- Starting SHA: `87432b3`
- Documentation-only; no Swift, no Xcode project, no commit/push

### Deliverable
- New inventory: `docs/ios/composer-fetch-path-parity-test-inventory.md`

### Baseline referenced
- `CompositionLightResolverTests` → 16/16
- `CompositionRoomPriorityScorerTests` → 19/19
- `RoomAndZoneDisplayModelBuilderTests` → 6/6
- `DashboardDisplayModelBuilderTests` → 14/14
- Signed-simulator `HueHomeTests` → 109/109
- IOS-REF-006B physical-device Composer smoke pass (prior entry)

### Fetch-path contracts inventoried
- `resolveCompositionGamut(for:api:)` — always one `fetchLights()`; failure or empty resolved lights → `.c`; majority gamut inline
- `resolveCompositionLightIDs(for:api:)` — empty refs → `[]` / 0 fetches; direct-light mode → 0 fetches; owner path → 1 fetch or `[]` on failure
- Pure matching delegated to `CompositionLightResolver` (IOS-REF-006B)

### Test-infrastructure findings
- `StubURLProtocol` + `TestableAPIClient` exist in `HueHomeTests/HueAPIClientTests.swift` (in target)
- `injectForTesting` is `#if DEBUG` in `UnifiedOrchestrator`
- Private fetch helpers are not `@testable`-accessible; `testApplySSEEvent` works only because `applySSEEvent` is `internal`
- `OrchestratorTests.swift` exists on disk (15 tests) but is not in `HueHome.xcodeproj` — explains 109 on-disk test methods in target vs 124 total in folder
- Spy subclass overriding `fetchLights()` is viable (`HueAPIClient` is non-`final`)

### IOS-TEST-002B recommendation
- Proceed: `#if DEBUG` wrappers `testResolveCompositionGamut` / `testResolveCompositionLightIDs`, new `ComposerFetchPathParityTests.swift` with fetch-counting spy, pbxproj membership
- Reject for this slice: `startCompositionMode` integration tests, `private`→`internal` widening, production fetch-policy helper, URLProtocol-only counting, source-text assertions
- Physical-device testing not required for IOS-TEST-002B unit slice

### Validation
- No Xcode build run (docs-only)
- No physical-device test required for this slice

---

## 2026-06-02 — Composer Fetch-Path Parity Tests (IOS-TEST-002B)

### Scope
- Branch: `ios-test/composer-fetch-path-parity-tests`
- Starting SHA: `6139154`
- DEBUG-only forward wrappers around existing private `resolveCompositionGamut(for:api:)` and `resolveCompositionLightIDs(for:api:)` in `UnifiedOrchestrator`
- New test file: `HueHomeTests/ComposerFetchPathParityTests.swift`
- Test-only `ComposerFetchCountingAPIClient` spy (`override fetchLights()`)
- Inventory count correction: IOS-TEST-002A matrix lists **9** core cases (5 ID + 4 GAM), not 8
- Private production method bodies unchanged; release behavior unchanged
- `OrchestratorTests.swift` orphan membership intentionally deferred

### Parity cases (9)
- ID-01 empty refs → 0 fetches, `[]`
- ID-02 direct refs → 0 fetches, order + duplicates preserved
- ID-03 mixed refs → 0 fetches, direct IDs only
- ID-04 owner fallback success → 1 fetch, fetched-light order
- ID-05 owner fallback failure → 1 fetch, `[]`
- GAM-01 direct refs majority → 1 fetch, `.a`
- GAM-02 owner fallback majority → 1 fetch, `.b`
- GAM-03 fetch failure → 1 fetch, `.c`
- GAM-04 empty resolved lights → 1 fetch, `.c`

### Validation results
- Injector shell tests → 21/21 PASS
- Verifier shell tests → 17/17 PASS
- Generic unsigned Debug app build → BUILD SUCCEEDED
- Generic unsigned Release app build → BUILD SUCCEEDED
- `ComposerFetchPathParityTests` → 9/9 PASS
- `CompositionLightResolverTests` → 16/16 PASS
- `CompositionRoomPriorityScorerTests` → 19/19 PASS
- `RoomAndZoneDisplayModelBuilderTests` → 6/6 PASS
- `DashboardDisplayModelBuilderTests` → 14/14 PASS
- Full signed-simulator `HueHomeTests` → 118/118 PASS
- No physical-device test required for this slice

### Follow-up
- Optional hygiene slice: register orphaned `OrchestratorTests.swift` in `HueHomeTests` target (15 tests on disk, not in pbxproj)
- Defer gamut tie-break policy pinning until product defines explicit rules

---

## 2026-06-02 — OrchestratorTests Target-Membership Repair Inventory (IOS-TEST-003A)

### Scope
- Branch: `ios-test/orchestrator-tests-membership-inventory`
- Starting SHA: `c1d5917`
- Documentation-only — no Swift, no Xcode project, no target membership changes
- New inventory: `docs/ios/orchestrator-tests-membership-repair-inventory.md`

### Baseline
- Full signed-simulator `HueHomeTests` → **118/118** pass (unchanged)
- `HueHomeTests/OrchestratorTests.swift` tracked on disk but **absent** from `HueHome.xcodeproj` Sources

### Findings
- Exact orphan XCTest method count: **14** (earlier **15** estimate incorrect — counted helper or stale handoff)
- Confirmed compile blockers: `BridgeAPIClient` `final` prevents `TestableBridgeAPIClient` subclass; `testApplySSEEvent` shim return-type mismatch; `turnAllOff()` `async` without `await` in test
- Runtime/fixture drift: missing `/clip/v2/resource/zone` stub breaks all `loadAll` success paths; entertainment cleanup GET unstubbed
- Concurrency: shared `StubURLProtocol.stubs` **not safe** under scheme `parallelizable="YES"` when multiple stub-using classes run together
- `applySSEEvent` already **internal** — orphan shim redundant (and invalid as written)

### Recommended IOS-TEST-003B slice
- **IOS-TEST-003B — Orchestrator cache + demo offline recovery (4 tests)**
- New file `OrchestratorCacheDemoTests.swift` — preloadCached ×3 + demo-mode loadAll ×1
- No production edits; no `BridgeAPIClient` finality change; defer remaining 10 orphan tests to B2–B4

### Validation
- No Xcode build run (docs-only)
- No physical-device test required for this slice

---

## 2026-06-02 — Orchestrator Cache + Demo Offline Recovery (IOS-TEST-003B)

### Scope
- Branch: `ios-test/orchestrator-cache-demo-tests`
- Starting SHA: `ae20fff`
- New test file: `HueHomeTests/OrchestratorCacheDemoTests.swift`
- Recovered tests (4): `testPreloadCached_populatesAllRooms`, `testPreloadCached_sortsAlphabetically`, `testPreloadCached_emptyInput_leavesAllRoomsEmpty`, `testDemoMode_loadAll_doesNotMakeNetworkRequests`
- No production Swift changes
- No orphan-file edits (`HueHomeTests/OrchestratorTests.swift` remains off-target)
- No `BridgeAPIClient` finality change
- No networking fixtures, `StubURLProtocol`, or client injection
- No shared URLProtocol state
- No scheme parallelization changes

### Validation
- Focused signed-simulator `OrchestratorCacheDemoTests` → **4/4** PASS
- Full signed-simulator `HueHomeTests` → **122/122** PASS (118 baseline + 4 new)
- Generic unsigned Debug build → **BUILD SUCCEEDED**
- Generic unsigned Release build → **BUILD SUCCEEDED**
- Shell injector tests → **21/21** PASS
- Shell verifier tests → **17/17** PASS
- No physical-device test required for this slice

### Deferred
- **IOS-TEST-003B2** — `loadAll` harness recovery (4 orphan tests; zone stub + compile repair for `TestableBridgeAPIClient` subclass blocker)

---

## 2026-06-02 — Orchestrator loadAll Harness Repair Inventory (IOS-TEST-003B2A)

### Scope
- Branch: `ios-test/orchestrator-loadall-harness-inventory`
- Starting SHA: `507e278`
- Documentation-only — no Swift, no Xcode project, no test implementation
- New inventory: `docs/ios/orchestrator-loadall-harness-repair-inventory.md`

### Baseline
- Full signed-simulator `HueHomeTests` → **122/122** pass (unchanged)
- `OrchestratorCacheDemoTests` → **4/4** pass
- Four deferred `loadAll()` orphan tests inventoried (remain in off-target `OrchestratorTests.swift`)

### Findings
- `BridgeAPIClient` is `final` — blocks orphan `TestableBridgeAPIClient` subclass; **declaration-only `final` removal required for B2**
- Recommended **IOS-TEST-003B2 Strategy A**: typed test-only spy in new `OrchestratorLoadAllTests.swift`; reuse existing `#if DEBUG injectForTesting(clients:)`
- **Avoid URLProtocol** — shared `StubURLProtocol.stubs` not parallel-safe under scheme `parallelizable="YES"`
- **Cleanup GET must be stubbed explicitly** via spy `get()` override (empty entertainment list); cleanup PUT avoidable
- **`lastLoadedAt` is completion-based**, not success-only — assigned after outer task group even when per-bridge fetches fail
- Orphan fixtures stale: missing zone stub; malformed redundant path key in `Fixture.installLoadAll`
- No `UnifiedOrchestrator.swift` or `HueAPIClient.swift` changes required for bounded B2 slice

### Expected future B2 target
- Focused `OrchestratorLoadAllTests` → **4/4** pass
- Full signed-simulator `HueHomeTests` → **126/126** pass (122 + 4)

### Validation
- No Xcode build run (docs-only)
- No physical-device test required for this slice

---

## 2026-06-02 — Orchestrator loadAll Offline Recovery (IOS-TEST-003B2B)

### Scope
- Branch: `ios-test/orchestrator-loadall-tests`
- Starting SHA: `039f0e8`
- New test file: `HueHomeTests/OrchestratorLoadAllTests.swift`
- Four recovered `loadAll()` offline tests (LOAD-01 through LOAD-04)
- Production edit: `BridgeAPIClient` `final` removed (declaration-only; no method-body changes)
- Typed test-only spy `OrchestratorLoadAllSpyBridgeClient` — no URLProtocol, no shared static stubs, no Keychain, no real bridge access
- Cleanup GET handled explicitly (`{"errors":[],"data":[]}` for entertainment_configuration); cleanup PUT avoided
- `lastLoadedAt` completion-based behavior pinned on error path (LOAD-03); production comment mismatch noted here only (not edited in `UnifiedOrchestrator.swift`)
- Orphan `HueHomeTests/OrchestratorTests.swift` untouched and off-target

### Validation
- Focused `OrchestratorLoadAllTests` → **4/4** pass (iPhone 17 Pro simulator)
- Full signed-simulator `HueHomeTests` → **126/126** pass (122 + 4)
- Shell: `test_inject_build_metadata.sh` → **21/21** pass; `test_verify_built_app_metadata.sh` → **17/17** pass
- Generic unsigned Debug build → **BUILD SUCCEEDED**
- Generic unsigned Release build → **BUILD SUCCEEDED**
- `git diff --check` → clean
- No physical-device test required (declaration-only production diff)

### Warning cleanup (pre-commit)
- Removed `setUp()`/`tearDown()` from `OrchestratorLoadAllTests`; per-test `@MainActor makeOrchestratorLoadAllSUT()` eliminates 6 MainActor lifecycle warnings introduced by this slice
- Deferred: `OrchestratorCacheDemoTests` still uses shared `setUp()`/`tearDown()` with the same MainActor pattern (preexisting; not edited in B2B)

### Deferred
- **IOS-TEST-003B3** — optimistic-update + SSE recovery from orphan suite (6 tests)

## 2026-06-02 — Orchestrator Optimistic-Update Recovery Inventory (IOS-TEST-003B3A)

### Scope
- Branch: `ios-test/orchestrator-optimistic-update-inventory`
- Starting SHA: `a0f37be`
- Documentation-only — no Swift, no `project.pbxproj`, no build run

### Inventory
- New doc: `docs/ios/orchestrator-optimistic-update-recovery-inventory.md`
- Three orphan mutation tests inventoried: `testSetRoom_optimisticUpdate_flipsIsOnImmediately`, `testSetRoom_rollback_onAPIError`, `testTurnAllOff_setsAllRoomsOffBeforeAPICallsComplete` (`HueHomeTests/OrchestratorTests.swift`, off-target)
- Current signed-simulator baseline: **126/126** `HueHomeTests` pass

### Findings
- **preloadCached fixture seeding:** sufficient when `cachedGroupedLightID` + `bridgeID` set — avoids `loadAll()` for grouped-light routing (`UnifiedOrchestrator.swift:505-537`)
- **Typed spy:** `BridgeAPIClient` non-final (B2B); override `setGroupedLight` — no URLProtocol, no Keychain
- **Actor recorder + gate:** recommended for MUT-01/MUT-03; immediate-throw spy for MUT-02 rollback
- **Fixed sleep:** rejected (`Task.sleep(300ms)` in orphan rollback test)
- **scheduleStateRefresh:** success-path `setRoom` schedules +1.5s delayed `loadAll()` — avoid via API failure teardown in optimistic-before-completion test
- **turnAllOff:** production `async`; orphan test omits `await` — B3B must `Task { await turnAllOff() }`
- **Production / DEBUG hooks:** not required for bounded B3B slice

### Recommended next slice
- **IOS-TEST-003B3B** — new `HueHomeTests/OrchestratorOptimisticUpdateTests.swift` (3 tests) + `project.pbxproj` membership
- Expected after B3B: focused **3/3**; full signed-simulator **129/129** (126 + 3)
- SSE orphan tests remain **IOS-TEST-003B4** (separate)

### Hygiene
- Preexisting `OrchestratorCacheDemoTests` MainActor lifecycle warnings remain deferred
- B3B should use per-test `@MainActor` SUT factory (match `OrchestratorLoadAllTests`)
- No physical-device test required for this docs-only slice

---

## 2026-06-02 — Orchestrator Optimistic-Update Offline Recovery (IOS-TEST-003B3B)

### Scope
- Branch: `ios-test/orchestrator-optimistic-update-tests`
- Starting SHA: `f46b887`
- New test file: `HueHomeTests/OrchestratorOptimisticUpdateTests.swift`
- Three recovered mutation tests (MUT-01 through MUT-03)
- `preloadCached(from:)` fixture with `cachedGroupedLightID` — no `loadAll()` fixture setup
- Typed spy `OrchestratorOptimisticUpdateSpyBridgeClient` overrides `setGroupedLight` only
- Actor recorder `OrchestratorOptimisticUpdateRecorder` + gate `OrchestratorGroupedLightGate`
- Bounded eventual rollback helper (`waitUntil` + 10ms polling) — fixed sleeps rejected
- Per-test `@MainActor` SUT factory — no `setUp()`/`tearDown()` lifecycle overrides
- No URLProtocol, no Keychain, no real network, no production Swift changes
- Orphan `HueHomeTests/OrchestratorTests.swift` untouched and off-target

### Recovered tests
- `testSetRoom_appliesOptimisticState_beforeAPICallCompletes`
- `testSetRoom_rollsBack_afterAPIError`
- `testTurnAllOff_appliesOptimisticState_beforeAPICallsComplete`

### Validation
- Focused `OrchestratorOptimisticUpdateTests` → **3/3** pass (iPhone 17 Pro simulator)
- Full signed-simulator `HueHomeTests` → **129/129** pass (126 + 3)
- Shell: `test_inject_build_metadata.sh` → **21/21** pass; `test_verify_built_app_metadata.sh` → **17/17** pass
- Generic unsigned Debug build → **BUILD SUCCEEDED**
- Generic unsigned Release build → **BUILD SUCCEEDED**
- `git diff --check` → clean
- No new lifecycle MainActor warnings from `OrchestratorOptimisticUpdateTests.swift`
- Preexisting `OrchestratorCacheDemoTests` `setUp()`/`tearDown()` warnings remain deferred
- No physical-device test required

### Deferred
- **IOS-TEST-003B4** — SSE orphan tests + `applySSEEvent` access recovery

---

## 2026-06-02 — Orchestrator SSE Recovery Inventory (IOS-TEST-003B4A)

### Scope
- Branch: `ios-test/orchestrator-sse-inventory`
- Starting SHA: `359a667`
- Documentation-only — no Swift, no `project.pbxproj`, no build run

### Inventory
- New doc: `docs/ios/orchestrator-sse-recovery-inventory.md`
- Three orphan SSE tests inventoried: `testApplySSEEvent_groupedLight_updatesRoomState`, `testApplySSEEvent_malformedJSON_doesNotCrash`, `testApplySSEEvent_unknownType_doesNotMutateState` (`HueHomeTests/OrchestratorTests.swift`, off-target)
- Current signed-simulator baseline: **129/129** `HueHomeTests` pass

### Findings
- **`applySSEEvent` is `internal`** — orphan shim redundant; shim `Bool` return invalid vs production `(rooms: Bool, zones: Bool)`
- **Public rebuild gap:** reducer mutates `roomsByBridge` only; live `runSSE` calls conditional `rebuildAllRooms`/`rebuildAllZones`; grouped-light visible parity requires rebuild
- **Malformed JSON test is decoder-only** — does not exercise `runSSE` line parsing; pin `UnifiedOrchestrator.sseDecoder`
- **`HueSSEService` unwired** — no `HueHome/` call sites; orchestrator owns inline `runSSE`
- **`preloadCached` + `cachedGroupedLightID` sufficient** — avoids `loadAll`, URLProtocol, Keychain, network
- **Recommended IOS-TEST-003B4B:** new `OrchestratorSSETests.swift` (3 tests) + DEBUG-only `testApplySSEEventsAndRebuild` in `UnifiedOrchestrator.swift` + `project.pbxproj` membership
- Expected after B4B: focused **3/3**; full signed-simulator **132/132** (129 + 3)

### Hygiene
- Preexisting `OrchestratorCacheDemoTests` MainActor lifecycle warnings remain deferred
- B4B should use per-test `@MainActor` SUT factory (match `OrchestratorLoadAllTests` / `OrchestratorOptimisticUpdateTests`)
- No physical-device test required for this docs-only slice

---

## 2026-06-02 — Bounded Orchestrator SSE Offline Recovery (IOS-TEST-003B4B)

### Scope
- Branch: `ios-test/orchestrator-sse-tests`
- Starting SHA: `17f0176`
- New test path: `HueHomeTests/OrchestratorSSETests.swift` (3 tests)
- DEBUG-only `testApplySSEEventsAndRebuild` in existing `#if DEBUG` test-injection block (`UnifiedOrchestrator.swift`)
- Release behavior unchanged — wrapper not compiled in Release
- `preloadCached` fixture strategy with `cachedGroupedLightID = gl-001`, `bridgeID = bridge-1`
- `UnifiedOrchestrator.sseDecoder` reuse — no ad-hoc `JSONDecoder`
- No `loadAll` fixture setup, no URLProtocol, no Keychain, no real network
- No `startSSE` / `runSSE` / `stopSSE` invocation from tests
- Public rebuild-gap coverage via DEBUG wrapper (SSE-01); malformed JSON decoder-only boundary (SSE-02); direct `applySSEEvent` for unknown type (SSE-03)
- `HueSSEService` remains untouched and unwired
- Orphan `HueHomeTests/OrchestratorTests.swift` not registered; stale `testApplySSEEvent` shim not copied

### Validation
- Shell: metadata injector **21/21** PASS; verifier **17/17** PASS
- Generic unsigned Debug build: **BUILD SUCCEEDED**
- Generic unsigned Release build: **BUILD SUCCEEDED** (DEBUG wrapper not compiled)
- Focused signed-simulator `OrchestratorSSETests`: **3/3** PASS (iPhone 17 Pro)
- Full signed-simulator `HueHomeTests`: **132/132** PASS (129 + 3)
- No new warnings from `OrchestratorSSETests.swift`; preexisting `OrchestratorCacheDemoTests` lifecycle warnings unchanged

### Hygiene
- Per-test `@MainActor` SUT factory — no `setUp()`/`tearDown()`; no new lifecycle MainActor warnings
- Preexisting `OrchestratorCacheDemoTests` MainActor lifecycle warnings remain deferred
- No physical-device test required (DEBUG-only production edit)
- Deferred: live SSE line parsing, reconnect/backoff, `HueSSEService` consolidation, zone/light SSE, pending-action guard during SSE

---

## 2026-06-02 — Cache/Demo MainActor Warning Cleanup (IOS-TEST-003B5)

### Scope
- Branch: `ios-test/orchestrator-cache-demo-warning-cleanup`
- Starting SHA: `039cb9c`
- Warning-hygiene slice only — test code + DEVLOG; no production Swift, no Xcode project edits

### Lifecycle warning source
- `HueHomeTests/OrchestratorCacheDemoTests.swift` was `@MainActor` but stored a shared `orchestrator: UnifiedOrchestrator!` mutated from synchronous `setUp()` / `tearDown()` overrides (nonisolated XCTest lifecycle hooks)

### Cleanup
- Removed shared orchestrator property
- Removed synchronous `setUp()` / `tearDown()` overrides
- Added per-test `@MainActor` factory `makeOrchestratorCacheDemoSUT() -> UnifiedOrchestrator`
- Each of the four existing tests constructs a fresh local orchestrator; assertions and fixtures unchanged

### Test names (unchanged)
- `testPreloadCached_populatesAllRooms`
- `testPreloadCached_sortsAlphabetically`
- `testPreloadCached_emptyInput_leavesAllRoomsEmpty`
- `testDemoMode_loadAll_doesNotMakeNetworkRequests`

### Warning inventory — before cleanup
**FROM_ORCHESTRATOR_CACHE_DEMO_TESTS**
- `OrchestratorCacheDemoTests.swift:12:9` — main actor-isolated property `orchestrator` can not be mutated from a nonisolated context (`setUp`)
- `OrchestratorCacheDemoTests.swift:12:24` — call to main actor-isolated initializer `init()` in a synchronous nonisolated context (`setUp`)
- `OrchestratorCacheDemoTests.swift:16:9` — main actor-isolated property `orchestrator` can not be mutated from a nonisolated context (`tearDown`)

**UNRELATED_PREEXISTING** (unchanged; not edited)
- Watch target: `WatchStore.swift`, `WatchWidgetStore.swift` MainActor / Codable warnings
- App icon asset unassigned-child warnings
- Production Swift 6 concurrency warnings (`StudioView`, `DashboardView`, `BridgeAnimationStore`, `UnifiedOrchestrator`, `StudioViewModel`, `SyncModeEngine`, etc.)

### Warning inventory — after cleanup
**FROM_ORCHESTRATOR_CACHE_DEMO_TESTS**
- None — `OrchestratorCacheDemoTests.swift` compiles with zero warnings; no MainActor `setUp()`/`tearDown()` lifecycle warnings

**UNRELATED_PREEXISTING** (unchanged)
- Same watch, asset, and production Swift 6 concurrency warnings as before slice

### Validation
- Shell: `test_inject_build_metadata.sh` → **21/21** PASS; `test_verify_built_app_metadata.sh` → **17/17** PASS
- Focused signed-simulator `OrchestratorCacheDemoTests` → **4/4** PASS (iPhone 17 Pro)
- Full signed-simulator `HueHomeTests` → **132/132** PASS
- No MainActor lifecycle warnings emitted from `OrchestratorCacheDemoTests.swift` after cleanup
- Generic unsigned builds not required for this slice
- No physical-device test required

### Recommended next stabilization follow-up
- **IOS-TEST-003B6** (or equivalent) — triage remaining unrelated preexisting Swift 6 / MainActor warnings in production and watch targets if warning-zero CI is desired

---

## 2026-06-02 — Native Android MVP Contract Freeze (ANDROID-CONTRACT-001)

### Scope
- Branch: `docs/android-mvp-contract-freeze`
- Starting SHA: `b4fbb58`
- Docs-only: `DEVLOG.md`, `docs/android/android-mvp-contract-freeze.md`
- No Swift, Kotlin, Xcode project, workflow, or script changes
- No Android Gradle project created
- No build, simulator run, or physical-device test required for this slice

### Product direction recorded
- Native Android (Kotlin + Jetpack Compose), not Flutter
- Minimal backend optional; **local Hue control remains local**
- Current iOS at `b4fbb58` is the behavior anchor

### iOS evidence anchor
- Full signed-simulator `HueHomeTests` → **132/132** PASS (includes orchestrator cache/demo/loadAll/optimistic/SSE suites)
- Metadata injector **21/21**, verifier **17/17** (per stabilization tooling)
- Orchestrator cache/demo MainActor lifecycle warnings cleared in **IOS-TEST-003B5** (prior entry)

### New document
- `docs/android/android-mvp-contract-freeze.md` — authoritative Android MVP contract freeze

### Contracts captured (from iOS source inspection)
- Discovery ladder: mDNS `_hue._tcp` → 12 s NUPnP `https://discovery.meethue.com/api/nupnp` → manual IP sheet (default port 443)
- Pairing: `POST /api`, 10 s timeout, devicetype `chromaglow#ios`, error 101 retry to `bridgeFound`, legacy Keychain persistence
- Credentials: `com.lightshade.app` service, legacy + `hue_bridge_{id}_*` keys, SwiftData `BridgeRecord`, duplicate-IP dedup, widget publish marked iOS-only
- REST v2: `https://{ip}/clip/v2/...`, `hue-application-key`, 10 s timeout, cert trust delegate; MVP reads/mutations tables
- Dashboard/room/zone display builders and aggregation rules
- Cache/stale-state, demo mode, optimistic `setRoom` rollback, `turnAllOff` optimistic behavior
- Scene MVP boundary: list + `recall.action = active` activation; create/edit/delete/dynamic_palette Post-MVP
- SSE: live path `UnifiedOrchestrator.runSSE`; `HueSSEService` unwired; reducer + 5→60 s backoff
- REST v1: **not required** for Android MVP (Composer/bridge animation only)
- Recommended Android package boundaries + 23-row acceptance matrix
- TODO-HARDWARE / TODO-SECURITY / TODO-PRODUCT / known `docs/ios` discrepancies listed

### Validation
- No commit or push in this session
- Recommended follow-up: merge docs PR, then deferred **iOS physical-device smoke** (dashboard, room/zone, scene activate, SSE) before Android implementation signoff

---

## 2026-06-03 — Final iOS Readiness Validation Handoff (IOS-OPS-FINAL-B)

### Scope
- Branch: `ios-ops/final-readiness-validation`
- Starting SHA: `5f7ec3a`
- Docs-only: `docs/ios/final-readiness-validation.md`, `DEVLOG.md`
- Draft report finalized at `docs/ios/final-readiness-validation.md`
- No Swift changes; no Xcode project changes; no Android code added
- No build rerun required in FINAL-B; no additional device testing run by Cursor

### Automated validation (IOS-OPS-FINAL-A, unchanged)
- Metadata injector → **21/21** pass
- Metadata verifier → **17/17** pass
- Unsigned Debug build → **BUILD SUCCEEDED**
- Unsigned Release build → **BUILD SUCCEEDED**
- Full signed-simulator `HueHomeTests` → **132/132** pass

### Physical test context
- Physical iPhone: `brian's iPhone` — **iPhone 17 Pro Max**, iOS **26.5**
- App launched from Xcode; local-network permission granted
- **Two Hue v2 bridges** tested

### Required physical matrix totals (20 rows)
- **PASS** → 17 / 20
- **PARTIAL** → 1 / 20 (`IOS-FINAL-PHYS-003` — mDNS finds bridge; discovered-result pairing unreliable)
- **FAIL** → 1 / 20 (`IOS-FINAL-PHYS-006` — link-button pairing loops from discovered result)
- **NOT AVAILABLE** → 1 / 20 (`IOS-FINAL-PHYS-015` — no mirek-capable lamp in test environment)

### Conditional hardware matrix totals (7 rows)
- **PASS** → 5 / 7
- **NOT TESTED** → 2 / 7
- **NOT PRACTICAL TODAY** → 1 / 7 (`IOS-FINAL-COND-001`)
- **NOT AVAILABLE** → 1 / 7 (`IOS-FINAL-COND-002` — no HTTP:80 legacy bridge)

### Verified on hardware
- Manual IP **HTTPS:443** pairing workaround (link button + manual IP)
- Two-bridge registration and bridge-specific room routing
- One-bridge-offline usability while other bridge remains usable
- External SSE visible-state update without pull-to-refresh
- Wi-Fi interruption and SSE recovery without app restart
- Dashboard, room/group controls, per-light controls (except mirek), scenes, stale-state

### Demo mode
- Demo launches without bridge dependency; **not** full-feature parity with current app

### Android-MVP kickoff blocker
- **Discovered-bridge pairing loop:** mDNS displays bridge; selecting discovered result does not reliably complete pairing; manual IP path works
- Android MVP kickoff remains **blocked** until defect is inventoried, repaired, and `IOS-FINAL-PHYS-003` / `IOS-FINAL-PHYS-006` are re-tested on hardware

### Recommended next work
- Branch: `ios-bug/discovered-bridge-pairing-loop-inventory`
- Task: **IOS-BUG-001A** — inventory discovered-bridge pairing-loop root cause (do not guess; inspect `BridgeDiscoveryService`, `BridgeDiscoveryViewModel`, `BridgeSetupView`, endpoint IP/port/scheme, mDNS handoff, pairing retry state)

### What's left
- [ ] IOS-BUG-001A inventory
- [ ] Fix discovered-result pairing handoff
- [ ] Physical re-test PHYS-003 and PHYS-006
- [ ] Android implementation (blocked until above)

---

## 2026-06-03 — Discovered-Bridge Pairing Loop Inventory (IOS-BUG-001A)

### Scope
- Branch: `ios-bug/discovered-bridge-pairing-loop-inventory`
- Starting SHA: `88b71cb`
- Docs-only: `docs/ios/discovered-bridge-pairing-loop-inventory.md`, `DEVLOG.md`
- No Swift changes; no Xcode project changes; no build; no simulator or device run by Cursor

### Readiness blocker source
- [`docs/ios/final-readiness-validation.md`](docs/ios/final-readiness-validation.md) — `IOS-FINAL-PHYS-003` PARTIAL, `IOS-FINAL-PHYS-006` FAIL; `IOS-FINAL-COND-003` PASS (manual IP HTTPS:443)
- Android MVP kickoff remains **blocked** until discovered-result pairing succeeds without manual IP

### Source-inspected endpoint and pairing facts
- mDNS (`BridgeDiscoveryService`): `_hue._tcp`, domain `local.`, LAN-only (`includePeerToPeer = false`), IPv4-forced resolve via `NWConnection` → `hostString` + preserved `port.rawValue`; Keychain IP saved on resolve
- Manual IP (`BridgeSetupView`): `BridgeEndpoint(name: "Hue Bridge", host: ip, port: 443)`
- Pairing (`BridgeDiscoveryViewModel`): `scheme = bridge.port == 443 ? "https" : "http"`; `BridgeCertTrustDelegate` only when port == 443; type **101** → `.bridgeFound`; URLSession failure → `.error`
- NUPnP fallback: `port = UInt16(first.port ?? 443)` (aligns with manual path when cloud returns no port)

### Primary hypothesis (not proven)
- Discovered path may pair over **HTTP:non-443** while manual path uses **HTTPS:443** on the same v2 bridge; manual workaround success is consistent but **runtime logs must confirm** resolved port and `POST` URL before any port normalization

### Inventory deliverables
- New doc: [`docs/ios/discovered-bridge-pairing-loop-inventory.md`](docs/ios/discovered-bridge-pairing-loop-inventory.md)
- Physical DEBUG log-capture packet and fill-in table for Brian (pre–IOS-BUG-001B)
- Existing tests: **no** `BridgeDiscovery` / pairing coverage; `StubURLProtocol` exists for CLIP v2 only
- Ranked repair strategies: log-capture first; then prefer **Strategy C** (`pairingCandidates`) after evidence — avoid blanket normalize-to-443 (Strategy A) without legacy policy
- **IOS-BUG-001B boundary:** run log capture; if transport mismatch confirmed, minimal ViewModel candidate ordering (discovered then HTTPS:443), not broad discovery rewrite in first commit

### Required physical re-test (post–001B)
- `IOS-FINAL-PHYS-003`, `IOS-FINAL-PHYS-005`, `IOS-FINAL-PHYS-006`, `IOS-FINAL-PHYS-007`, `IOS-FINAL-COND-003`, `IOS-FINAL-COND-004`

### What's left
- [ ] Brian: fill DEBUG log-capture table (discovered vs manual, both v2 bridges)
- [ ] IOS-BUG-001B — narrow pairing transport repair per inventory boundary
- [ ] Physical re-test PHYS-003 / PHYS-006 (and related rows)
- [ ] Android implementation (still blocked)

---

## 2026-06-03 — Multi-Bridge Discovery-Selection Evidence (IOS-BUG-001A2)

### Scope
- Branch: `ios-bug/discovered-bridge-pairing-loop-log-capture`
- Starting SHA: `88b71cb`
- Docs-only: `docs/ios/discovered-bridge-pairing-loop-inventory.md`, `DEVLOG.md`
- Physical DEBUG log capture **completed** — no further transport testing required for tested v2 bridges
- No Swift changes; no Xcode changes; no tests run by Cursor

### Confirmed physical evidence
- Two Hue v2 bridges via mDNS: `Hue Bridge - 663C54` → `192.168.40.116:443`; `Hue Bridge - 608DFC` → `192.168.40.117:443`
- Discovered pairing uses `https://host:443/api` with HTTPS cert trust delegate on both
- Pairing succeeds when link button matches the bridge in the pairing flow; manual IP succeeds for the other bridge

### Ruled-out hypothesis
- Port/scheme mismatch **ruled out** for tested v2 bridges (both resolve and pair on HTTPS:443)

### Corrected diagnosis
- **First-discovered bridge auto-selection** (`discoveredBridges.first`), immediate scan stop, **no discovered-bridge chooser** — user cannot target second LAN bridge without manual IP; adding second bridge may re-offer already-connected bridge A

### Separate issue
- NUPnP `GET https://discovery.meethue.com/api/nupnp` → **404 page not found**; warm mDNS retry followed — follow-up **IOS-BUG-002A** (not mixed into 001B)

### Recommended IOS-BUG-001B boundary
- Add discovered-bridge **selection UI** before pairing; preserve host/port/transport/pairing/Keychain; do not normalize ports or fix NUPnP in 001B

### Android-MVP kickoff
- Remains **blocked** until IOS-BUG-001B physical re-test passes (multi-bridge discovery selection without manual IP for second bridge)

### What's left
- [ ] IOS-BUG-001B — discovered-bridge selection before pairing
- [ ] Physical re-test PHYS-003, PHYS-006, COND-003, COND-004
- [ ] IOS-BUG-002A — NUPnP 404 inventory (separate)
- [ ] Android implementation (blocked)

---

## 2026-06-03 — Explicit Discovered-Bridge Selection Repair (IOS-BUG-001B)

### Scope
- Branch: `ios-bug/discovered-bridge-selection-ui`
- Starting SHA: `de5a0ec`
- Confirmed multi-bridge defect: mDNS resolves multiple v2 bridges; flow auto-selected `discoveredBridges.first`, stopped scan, and offered no chooser — second bridge required manual IP
- Narrow implementation boundary: selection UI + discovery handoff only; no pairing transport, cert trust, Keychain, or NUPnP changes

### Files changed
- `HueHome/Core/ViewModels/BridgeDiscoveryViewModel.swift`
- `HueHome/UI/BridgeSetup/BridgeSetupView.swift`
- `HueHome/Core/Network/BridgeDiscoveryService.swift` (host+port append dedupe only)
- `DEVLOG.md`

### Selection behavior added
- Scanning phase shows explicit tappable rows (`name` + `host:port`) via `discoveredBridgeChoices`
- `selectDiscoveredBridge(_:)` stops scan and transitions to `.bridgeFound(selected)` for pairing
- DEBUG logs: `🌉 Resolved bridge choice:` on new endpoint; `👆 Selected discovered bridge:` on user tap
- Normal mDNS first-bridge auto-selection **removed** (init Combine sink)
- Warm-cache mDNS retry first-bridge auto-selection **removed**; retry surfaces chooser when bridges resolve, errors only if still empty after 10 s poll
- Manual-IP fallback unchanged; `Pair with Bridge` / type-101 retry / HTTPS:443 + HTTP:80 pairing unchanged
- NUPnP cloud path unchanged (still auto-selects first cloud result); `GET discovery.meethue.com/api/nupnp` 404 deferred to **IOS-BUG-002A**

### Endpoint deduplication
- **Service append guard** compares `host` + `port` (not synthesized `Equatable` with random `id`)
- **ViewModel** `deduplicatedByHostAndPort` for chooser-facing list

### Focused tests
- **Not added** — selection is UI + `@MainActor` VM wiring; dedupe is trivial static helper; no new test file / pbxproj change to keep slice minimal. Physical re-test packet required.

### Automated validation
- `git diff --check`: PASS
- Metadata injector: **21/21 PASS**
- Metadata verifier: **17/17 PASS**
- Unsigned Debug build (`HueHome 1`, generic iOS): **BUILD SUCCEEDED**
- Unsigned Release build: **BUILD SUCCEEDED**
- Signed simulator suite (`iPhone 17 Pro`, `HueHomeTests` only): **TEST SUCCEEDED**, **132/132 PASS** (no new tests)

### Required physical re-test
- Brian: IOS-BUG-001B packet (Tests 1–6) on Debug iPhone with two v2 bridges (`.116` / `.117`) — see follow-up entry below

### What's left
- [x] Brian: physical re-test Tests 1–6 (recorded 2026-06-03)
- [ ] IOS-BUG-001C — clarify selected-bridge pairing retry feedback (non-blocking UX)
- [ ] IOS-BUG-002A — NUPnP 404 inventory (separate)
- [ ] Android implementation (blocked until PR merge + readiness reconciliation)

---

## 2026-06-03 — Explicit Discovery Selection Physical Re-Test (IOS-BUG-001B)

### Scope
- Branch: `ios-bug/discovered-bridge-selection-ui`
- Two Hue v2 bridges on same LAN: Bridge A `192.168.40.116:443`, Bridge B `192.168.40.117:443`
- Debug iPhone physical re-test; docs-only update to `DEVLOG.md` (implementation unchanged)

### IOS-BUG-001B Physical Re-Test

**Test 1 — chooser contents: PASS**
- Both Hue v2 bridges appear as explicit selectable choices
- No duplicate rows observed
- Neither bridge is silently forced as the only pairing target

**Test 2 — pair Bridge A (.116): PASS**
- Explicit selection of `192.168.40.116:443` pairs successfully after pressing the matching bridge link button

**Test 3 — pair Bridge B (.117) without manual IP: PASS**
- Explicit selection of `192.168.40.117:443` pairs successfully without manual IP entry after pressing the matching bridge link button

**Test 4 — type 101 retry: PASS WITH UX FOLLOW-UP**
- Retry behavior remains functional
- When the selected bridge and pressed physical bridge button do not match, current feedback does not clearly explain the mistake or identify the selected bridge

**Test 5 — manual-IP regression: PASS**
- Existing manual-IP HTTPS:443 pairing path remains functional

**Test 6 — two-bridge routing regression: PASS**
- Both registered bridges route room controls to the intended physical bridge

### Outcome
- Chooser shows both bridges; no duplicate chooser rows observed
- Bridge A pairs through explicit discovered selection
- Bridge B pairs through explicit discovered selection without manual IP
- Type 101 retry remains functional
- Manual-IP HTTPS:443 regression passes
- Two-bridge room-routing regression passes
- **Primary multi-bridge discovery-selection blocker is resolved**

### Android MVP kickoff
- After this PR merges and the readiness report is reconciled, Android MVP kickoff may move to **READY WITH DOCUMENTED FOLLOW-UPS**

### Follow-up — IOS-BUG-001C (non-blocking)
**IOS-BUG-001C — Clarify selected-bridge pairing retry feedback**

Observed UX gap:
When a user selects one discovered bridge but presses the physical link button on another bridge, retry remains functional but the UI does not clearly explain the mismatch or identify the selected bridge.

Boundary:
Improve user-facing retry feedback in a later narrow slice. Do not change pairing transport or state-machine behavior in IOS-BUG-001B.

### Follow-up — IOS-BUG-002A (separate)
**IOS-BUG-002A — Inventory Philips cloud-discovery fallback 404**

Not investigated or fixed in IOS-BUG-001B branch.

### What's left
- [ ] Merge IOS-BUG-001B PR; reconcile readiness report
- [ ] IOS-BUG-001C — pairing retry UX clarity (narrow slice)
- [ ] IOS-BUG-002A — NUPnP 404 inventory
- [ ] Android MVP kickoff (after merge + readiness reconciliation)

---

## 2026-06-03 — Final Readiness Reconciliation After Explicit Bridge Selection Repair (IOS-OPS-FINAL-C)

### Scope
- Branch: `docs/ios-readiness-reconcile-after-001b`
- Starting SHA: `72ee5ab`
- Docs-only: `docs/ios/final-readiness-validation.md`, `DEVLOG.md`
- IOS-BUG-001B merged at main SHA `72ee5ab`
- No Swift changes; no Xcode project changes; no Android code added
- No build rerun required in FINAL-C; no simulator rerun required in FINAL-C; no device tests run by Cursor

### Automated validation (unchanged baseline)
- Metadata injector → **21/21** pass
- Metadata verifier → **17/17** pass
- Unsigned generic Debug build → **BUILD SUCCEEDED**
- Unsigned generic Release build → **BUILD SUCCEEDED**
- Full signed-simulator `HueHomeTests` → **132/132** pass

### Physical re-test (two Hue v2 bridges, post–IOS-BUG-001B)
- Both discovered bridges appear as explicit selectable choices; no duplicate chooser rows observed
- Bridge A (`192.168.40.116:443`) discovered-selection pairing → **PASS**
- Bridge B (`192.168.40.117:443`) discovered-selection pairing without manual IP → **PASS**
- Type-101 retry functional → **PASS WITH UX FOLLOW-UP** (IOS-BUG-001C)
- Manual-IP HTTPS:443 regression → **PASS**
- Two-bridge routing regression → **PASS**

### Readiness outcome
- Multi-bridge discovery-selection blocker → **resolved**
- Android MVP kickoff → **READY WITH DOCUMENTED FOLLOW-UPS**
- IOS-BUG-001C → non-blocking UX follow-up (selected-vs-pressed bridge mismatch feedback)
- IOS-BUG-002A → non-blocking (NUPnP `GET https://discovery.meethue.com/api/nupnp` → 404)
- Credential rotation required before release signoff (DEBUG logs exposed bridge credentials)

### Historical preservation
- Original IOS-OPS-FINAL-B physical matrix (including `IOS-FINAL-PHYS-003` PARTIAL and `IOS-FINAL-PHYS-006` FAIL) preserved as pre-repair record
- Post-IOS-BUG-001B reconciliation section added to `docs/ios/final-readiness-validation.md`

### What's left
- [ ] IOS-BUG-001C — clarify selected-bridge pairing retry feedback
- [ ] IOS-BUG-002A — NUPnP fallback 404 inventory
- [ ] Credential rotation before release signoff
- [ ] Android MVP foundation implementation (unblocked with documented follow-ups)

---

## 2026-06-03 — Native Android Foundation Scaffold Inventory (ANDROID-001A)

### Scope
- Branch: `android/foundation-scaffold`
- Starting SHA: `092fdd7`
- Docs-only: `docs/android/android-foundation-scaffold-plan.md`, `DEVLOG.md`
- No Android code, Gradle files, SDK installs, iOS changes, builds, commits, or pushes

### Android kickoff readiness
- Repo docs: **READY WITH DOCUMENTED FOLLOW-UPS** (per IOS-OPS-FINAL-C / `docs/ios/final-readiness-validation.md`)
- Greenfield standalone native Android; iOS remains production behavior anchor; do not copy `UnifiedOrchestrator` god-object

### New artifact
- `docs/android/android-foundation-scaffold-plan.md`

### Existing Android scaffold inventory
- No Gradle/Kotlin/`AndroidManifest.xml` in repo
- Only `docs/android/` directory at depth ≤3; **no application scaffold**

### Local toolchain inventory (read-only)
| Component | Result |
| --- | --- |
| Java / `JAVA_HOME` | Unset; `/usr/bin/java` reports no JRE installed |
| Android Studio | Not found (`/Applications/Android Studio.app` absent) |
| Android SDK | `$HOME/Library/Android/sdk` missing |
| `adb` | Not on PATH |
| `sdkmanager` | Not on PATH |
| `emulator` | Not on PATH |
| `gradle` (global) | Not on PATH |

### Toolchain classification
- **BLOCKED — TOOLCHAIN INSTALL REQUIRED** (ANDROID-001B build verification needs Studio + JDK + SDK)

### Frozen / proposed scaffold decisions
| Item | Recommendation |
| --- | --- |
| Project root | `android/` |
| Gradle modules | `:app` only initially |
| Display name | `ChromaGlow` |
| Namespace | `com.chromaglow.app` — **approval required** |
| `applicationId` | `com.chromaglow.app` — **approval required** |
| `minSdk` / `targetSdk` | Propose API 26 min; target/compile from installed SDK at 001B — **approval required** |
| JDK | Derive from Studio (expect 17) at 001B |
| AGP / Kotlin / Compose BOM | **Deferred** — resolve from installed template; do not guess |

### Explicitly not done
- No Android project files or Kotlin sources added
- No Gradle wrapper added
- No iOS files changed
- No builds run; no installs performed

### Recommended next task
- **ANDROID-001B** — Create standalone native Android foundation scaffold (after Brian approves namespace + `applicationId` and local toolchain install)

### Non-blocking iOS follow-ups (unchanged)
- IOS-BUG-001C — selected-bridge pairing retry UX
- IOS-BUG-002A — NUPnP cloud-discovery 404 inventory
- Credential rotation before iOS release signoff

---

## 2026-06-03 — Native Android Compose Foundation Scaffold (ANDROID-001B)

### Context
- **Branch:** `android/foundation-scaffold-implementation`
- **Starting SHA:** `f2cb14a`
- **Template:** Android Studio Jetpack Compose Empty Activity

### Identity and SDK
| Item | Value |
| --- | --- |
| Namespace | `com.chromaglow.app` |
| `applicationId` | `com.chromaglow.app` |
| Hue `devicetype` | `chromaglow#android` |
| `minSdk` | 26 |
| `compileSdk` | 37 |
| `targetSdk` | 36 |

### Toolchain and dependency pins (generated template, unchanged in 001B)
| Item | Version |
| --- | --- |
| Gradle wrapper | 9.4.1 |
| Android Gradle Plugin | 9.2.1 |
| Kotlin | 2.2.10 |
| Compose BOM | 2026.02.01 |
| Bundled JBR | OpenJDK 21.0.10 (Android Studio) |

### What was built
- Initial **`:app`-only** module boundary under `android/`
- Machine-local paths excluded via `android/.gitignore` (`/.idea/`, `/.gradle/`, `/.kotlin/`, `local.properties`, build dirs)
- Starter **Hello Android** template validated before replacement
- **ChromaGlow** shell: `MainActivity` → `ChromaGlowTheme` → `ChromaGlowApp`
- Local setup placeholder destination (`feature.setup`)
- **Demo-mode entry boundary** (`data.demo.DemoModeBoundary`) — no fixtures, persistence, or networking
- Dashboard placeholder destination (`feature.dashboard`)
- Local Compose navigation state only (no Navigation Compose dependency)
- JVM smoke: `DemoModeBoundaryTest`
- Compose instrumented smoke: `ChromaGlowAppTest`
- Updated `docs/android/android-foundation-scaffold-plan.md` post-install record (preserves ANDROID-001A history)

### Explicitly not done
- Hue networking, discovery, pairing, credentials, Keystore, DataStore, Room, REST/SSE
- No iOS files changed
- No commit or push

### Automated validation (ANDROID-001B)
- **Gradle:** 9.4.1 (JBR 21.0.10)
- **`lintDebug`:** PASS
- **`testDebugUnitTest`:** PASS (`DemoModeBoundaryTest`)
- **`assembleDebug`:** PASS
- **`connectedDebugAndroidTest`:** PASS (`ChromaGlowAppTest` on Pixel_10 AVD)
- **APK install:** PASS
- **`MainActivity` launch:** PASS (`adb shell am start -n com.chromaglow.app/.MainActivity`)
- Logs: `/tmp/android-001b-build.log`, `/tmp/android-001b-connected-test.log`

### Manual verification required
- Inspect running emulator: setup copy → **Enter Demo Mode** → dashboard placeholder → **Back to Setup**

### Recommended next task
- **ANDROID-002A** — Establish Android design-system tokens and screen-shell parity map

---

## 2026-06-04 — Android Design-System Tokens and Screen-Shell Parity Map (ANDROID-002A)

- **Branch:** `android/design-system-shell-parity-map`
- **Starting SHA:** `63f35f3324d2294e868873b2b1f162ac9537d504`
- **Scope:** Docs-only — no Kotlin, Gradle, `AndroidManifest`, Swift, or iOS doc edits
- **New doc:** [`docs/android/android-design-system-shell-parity-map.md`](docs/android/android-design-system-shell-parity-map.md)
- **Content:** Material 3 token tables from `HueTokens.swift` / `HueTypography.swift`; setup and dashboard shell parity rows; room-card interaction contract; MVP acceptance traceability
- **Approved decisions recorded:** `dynamicColor = false` for MVP; Noir-only dark theme; Estate as future reference only; setup gradient = Noir base + subtle purple tint; glass = alpha surface + border + restrained glow (no blur / `RenderEffect`); semantic parity not pixel clone; keep `ChromaGlowDestination` enum navigation — **no Navigation Compose**; deferred presets, now-playing, automations, Studio, More, favorite scenes, wide-card toggle, light theme, haptics; `core.ui` extraction waits for second caller
- **ANDROID-002B boundary:** Replace template purple/dynamic colors, expand typography, theme two placeholders only — no new destinations, grid, setup phases, or fake rooms
- **Baseline noted:** `Theme.kt` still ships `dynamicColor = true` and purple starter colors until 002B
- **Explicit non-goals:** No `UnifiedOrchestrator` copy on Android; no placeholder stubs for deferred features in 002B
- **iOS follow-ups (appendix only):** IOS-BUG-001C, IOS-BUG-002A — non-blocking
- **Next recommended task:** **ANDROID-002B** — Apply ChromaGlow dark Material 3 tokens to theme + setup/dashboard placeholders
- No commit or push in this pass

---

## 2026-06-04 — Android Dark Material Theme and Placeholder Styling (ANDROID-002B)

- **Branch:** `android/dark-material-theme-placeholders`
- **Starting SHA:** `fb7cd25f755407db48ec3196f59bd1860f5cbc45`
- **Theme changes:** Fixed Noir-only Material 3 `darkColorScheme`; template purple/pink colors removed; `dynamicColor`, `darkTheme`, `isSystemInDarkTheme`, and light/dynamic scheme paths removed from `ChromaGlowTheme`
- **Tokens:** ChromaGlow amber, setup gradient stops, and Noir semantic colors in `Color.kt`
- **Typography:** Expanded `Typography` with verified Material 3 slots (display/headline/title/body/label per parity map)
- **Setup placeholder:** `Brush.linearGradient` background (no explicit `Offset`); title/subtitle use `onBackground` / `onSurfaceVariant`; default amber `Button` for Enter Demo Mode
- **Dashboard placeholder:** `background` root fill; themed text; `OutlinedButton` for Back to Setup
- **Unchanged:** Routing, `ChromaGlowApp`, demo boundary, Gradle, manifest, dependencies, tests, iOS, networking, persistence, Navigation Compose
- **Automated validation:** `git diff --check` PASS; `./gradlew clean lintDebug testDebugUnitTest assembleDebug` PASS; `./gradlew connectedDebugAndroidTest` PASS (Pixel_10 AVD, 1 test)
- **Manual:** Pixel_10 visual verification of gradient, amber CTA, Noir dashboard, and setup round-trip still required
- No commit or push in this pass

---

## 2026-06-04 — Android Demo-Mode Domain Models and Dashboard Fixtures (ANDROID-003A)

- **Branch:** `android/demo-mode-domain-fixtures`
- **Starting SHA:** `d5c1ebf9a1ab4e9d0f5fa9c343f5857a03c44e7b`
- **Domain:** `RoomDisplayModel` with constructor `require` invariants (brightness 1–100, non-blank ids/names/bridgeId)
- **Fixtures:** `DemoFixtures` — four deterministic in-memory rooms on `demo-bridge-main`, sorted by name
- **Session:** `DemoModeSession` carries `rooms`; `enterDemoMode()` returns `DemoFixtures.rooms`
- **Dashboard:** `DashboardPlaceholderScreen` evolved in place — `LazyColumn` of read-only `DemoRoomRow` (`On · N% · N lights` / off alpha 0.72)
- **Tests:** `DemoFixturesTest` (fixture + invariant coverage); `DemoModeBoundaryTest` and `ChromaGlowAppTest` smoke updated
- **Unchanged:** `ChromaGlowApp`, setup, theme, Gradle, manifest, dependencies, routing, iOS, networking, persistence, zones, controls, Navigation Compose
- **Automated validation:** `git diff --check` PASS; `./gradlew clean lintDebug testDebugUnitTest assembleDebug` PASS; `./gradlew connectedDebugAndroidTest` PASS (Pixel_10 AVD, 1 test)
- **Manual:** Pixel_10 fixture list and setup round-trip still required
- No commit or push in this pass

---

## 2026-06-04 — Android Local Credential-Storage Boundary (ANDROID-004A)

- **Branch:** `android/credential-storage-boundary`
- **Starting SHA:** `6f0f7167da7c2f27bd7d9dcc16d1d8787681ca56`
- **Scope:** API-token-only local credential boundary — no `CLIENT_KEY`, entertainment keys, secret-kind enums, or future-secret placeholders
- **Keystore:** Per-bridge `AndroidKeyStore` AES-256-GCM key material (`AES/GCM/NoPadding`)
- **At-rest blob:** Versioned IV + ciphertext under `Context.noBackupFilesDir/credentials/` (no backup); directory creation fails closed if path is missing, not a directory, or cannot be created
- **Alias strategy:** Deterministic `chromaglow.bridge.<bridgeId>.api_token` keystore alias and `bridge_<bridgeId>.api_token.enc` filename; unsafe bridge IDs rejected (not sanitized)
- **Store API:** `BridgeCredentialStore` with `saveApiToken` / `loadApiToken` / `deleteApiToken`; `BridgeSecretResult` = `Present` / `Absent` / `Failure`
- **Concurrency:** Process-wide `PROCESS_LOCK` shared across store instances
- **Save:** Validates bridge ID and non-blank token; fails closed before Keystore key creation when ciphertext path exists but is not a regular file; reuses or creates Keystore key; encrypts UTF-8; unique `createTempFile` write with `fd.sync()`; `Files.move` with `ATOMIC_MOVE` + `REPLACE_EXISTING`, falling back to `REPLACE_EXISTING` only; no delete-before-replace window; does not delete Keystore key before overwrite
- **Filesystem checks:** `Files.exists` / `Files.isRegularFile` use `LinkOption.NOFOLLOW_LINKS` on save, load, and delete (symlinks and other non-regular entries fail closed)
- **Load:** Neither key nor ciphertext path → `Absent`; path exists but not a regular file → `Failure`; exactly one of key or regular ciphertext file → `Failure`; both present → decrypt with on-disk blob length bounded before `readBytes`; crypto/I/O/format errors → `Failure` (`Exception` only, no token in messages)
- **Delete:** Non-regular ciphertext path → throw; `Files.deleteIfExists` propagates I/O failure before Keystore removal; idempotent when already absent
- **Tests:** `BridgeCredentialAliasTest` (JVM alias/filename validation); `AndroidKeystoreBridgeCredentialStoreTest` (round-trip, overwrite, idempotent delete, ciphertext does not contain token bytes, key-without-blob and blob-without-key `Failure`, directory-at-ciphertext-path save/load/delete, oversized encrypted blob rejection)
- **Deferred:** Biometric/user-presence prompt, metadata persistence, UI wiring, pairing, networking
- **Unchanged:** Gradle, manifest, dependencies, `MainActivity`, app/feature/ui packages, docs, iOS, DataStore, Room, SharedPreferences
- **Automated validation:** `git diff --check` PASS; forbidden storage/logging grep PASS; `./gradlew clean lintDebug testDebugUnitTest assembleDebug` PASS; `./gradlew connectedDebugAndroidTest` PASS (Pixel_10 AVD, 13 tests)
- No commit or push in this pass

## 2026-06-04 — Android mDNS Bridge-Discovery Chooser (ANDROID-005A)

- Branch: `android/mdns-bridge-discovery`
- Starting SHA: `950677ed3b89e999e4304326bc283aa4c7a6daaf`
- Hue DNS-SD type: `_hue._tcp` (no trailing dot), browsed via `NsdManager.PROTOCOL_DNS_SD`
- Android `NsdManager` platform adapter (`AndroidNsdBridgeDiscoveryService`) — LAN browse only, no extra dependency
- Manifest permissions: `CHANGE_WIFI_MULTICAST_STATE`; plus `INTERNET` added on runtime evidence — `getSystemService(NSD_SERVICE)` `NsdManager.<init>` → `INsdManager.connect()` throws `SecurityException` without it (proven by connected test before adding)
- `WifiManager` multicast lock lifecycle: non-reference-counted, acquired on start, released on stop/stopped/failure; never double-acquired or released-when-unheld
- API 34+ uses `registerServiceInfoCallback(serviceInfo, mainExecutor, callback)`; one callback tracked per service name; updates restore endpoint, callback loss removes it
- API 26–33 single-flight `@Suppress("DEPRECATION")` `resolveService` fallback; queued one-at-a-time, next drained after success/failure; stale-generation callbacks ignored
- Host extraction: API 34+ prefers first `Inet4Address` from `hostAddresses`, else first; legacy uses `serviceInfo.host`; both via `InetAddress.hostAddress`, require non-blank host, preserve `serviceInfo.port`, omit invalid endpoints
- `BridgeEndpoint` preserves resolved host + port; chooser rows derived from `BridgeEndpointDeduper.deduplicate(endpointByServiceName.values)` (host+port dedupe, first-seen wins, not by service name)
- No silent auto-selection; chooser row tap stops discovery and sets an inert selected endpoint ("Pairing will be added in a later step.")
- Generation counter + main-thread state changes guard against zombie callbacks; no `Log.*`/`println`/service-object dumping
- Lifecycle correction pass: `stopActiveDiscovery()` attempts `stopServiceDiscovery(listener)` whenever a `discoveryListener` exists (including the pre-`onDiscoveryStarted` window), catching `IllegalArgumentException` for not-yet-registered listeners — no longer gated on `isDiscoveryActive`
- Lifecycle correction pass: `acquireMulticastLock()` + `discoverServices(...)` share one bounded `try` catching `IllegalArgumentException`/`SecurityException`; either fails closed (clear listener/active/scanning, release multicast lock, `DISCOVERY_FAILED_MESSAGE`, publish) with no exception detail logged
- Lifecycle correction pass: API 26–33 in-flight `resolveService` callbacks cannot resurrect a service lost before resolution — `discoveredServiceNames` gates endpoint publication; `onServiceLost` drops the name, endpoint, queued entries, and queued-name set membership
- Lifecycle correction pass: legacy resolve queue is name-deduplicated via `queuedLegacyServiceNames` (skip if already queued or currently resolving); `currentlyResolvingServiceName` set before resolve and cleared on success/failure
- Lifecycle correction pass: API 34+ callback-map cleanup is identity-safe — `removeServiceInfoCallbackIfCurrent(...)` only removes a map entry when it still references the same callback instance, so a later replacement registered for the same service name is preserved
- Setup screen extended with defaulted `onDiscoveredBridgeSelected` callback (no `ChromaGlowApp.kt` edit); `DisposableEffect` stops discovery on dispose; Noir gradient, title, subtitle, and Enter Demo Mode preserved
- Tests: `BridgeEndpointDeduperTest` (11 JVM cases — dedupe, first-seen, service-name independence, endpointKey lowercase, IPv4/IPv6 displayAddress, blank name/host and bad port rejection); `ChromaGlowAppTest` adds Scan for Bridge + Enter Demo Mode assertions before/after dashboard round-trip
- No pairing, manual IP, NUPnP, cloud discovery, credentials, REST, TLS, Gradle, dependency, dashboard, iOS, DataStore, or Room changes
- Automated validation: `git diff --check` PASS; scope + forbidden-scope greps PASS; `./gradlew clean lintDebug testDebugUnitTest assembleDebug` PASS; `./gradlew connectedDebugAndroidTest` PASS (Pixel_10 AVD, 13 tests)
- Manual Pixel_10 LAN verification still required (no physical bridge discovery claimed)
- No commit or push in this pass

## 2026-06-04 — Android Manual-IP Bridge Entry (ANDROID-005B)

- Branch: `android/manual-ip-bridge-entry`
- Starting SHA: `f18fb29ef4f83d72a42f32ccb5cbf1201115e6b4`
- Inline manual-entry path on the setup screen — secondary `Enter IP Manually` action expands an inline section (no `ModalBottomSheet`); preserves landed ANDROID-005A discovery/lifecycle behavior
- Pure local parser (`ManualBridgeEndpointParser`) — no dependency, no Android networking imports, no DNS, never calls `InetAddress.getByName`; trims input, rejects blanks, schemes (`://`), `/?#@`, internal whitespace, and IPv6 zone IDs (`%`)
- Fixed local HTTPS port `443`; no custom-port field
- IPv4 accepted only as exactly four numeric octets in `0..255`; dotted-decimal candidates never fall through to the hostname path (so `256.1.1.1` is rejected, not treated as a name)
- IPv6 accepted conservatively: at most one `::` compression marker, no `:::`, hex groups 1–4 chars; bracketed literals such as `[2001:db8::1]` have exactly one matched surrounding pair stripped so `BridgeEndpoint.displayAddress` re-adds exactly one pair
- Safe ASCII hostnames: dot-separated or single-label, each label `1..63` chars of letters/digits/`-`, no leading/trailing `-`, total `≤253`; no resolution performed
- Bounded `Parsed.Valid`/`Parsed.Invalid` result with fixed inline error strings; valid input builds the existing `BridgeEndpoint(name = "Manual bridge", host, port = 443)`
- No network request on entry — typing updates local UI state only; selection reuses the existing inert `SelectedBridgeCard` and preserves `Pairing will be added in a later step.`
- Transitions: `Enter IP Manually` stops discovery, clears chooser rows / prior selection / prior manual input + error, opens the section; valid `Use This Bridge` sets the selected endpoint, closes the form, clears error, shows the inert card; invalid keeps the form open with an inline error and no card; `Scan for Bridge` / `Scan Again` clear manual visibility/text/error and selected state and restart mDNS through the existing service
- Selection remains read-only; no persistence
- Tests: `ManualBridgeEndpointParserTest` (JVM — valid IPv4/whitespace-trimmed/`fe80::1`/`[2001:db8::1]`/`bridge.local`/`huebridge`; invalid blank/whitespace/`256.1.1.1`/bad octet counts/malformed IPv6/multiple `::`/`fe80::1%eth0`/`https://…`/`…/api`/embedded whitespace/hyphen-edge labels/over-63 label; default port 443, synthetic name, unbracketed IPv6 storage, one-pair IPv6 display, `host:443` IPv4 display); `SetupManualEntryTest` (Compose — action visible, valid IPv4 renders inert card + `192.168.1.100:443`, invalid renders inline error and no card, `Scan Again` clears selection and returns to scanning); `ChromaGlowAppTest` unchanged
- No pairing, navigation, persistence, REST, TLS, cloud, backend, NUPnP, credentials, manual network probes, new lifecycle behavior, dependency, manifest, or Gradle changes
- Physical-device validation remains deferred — no physical Android device is currently available
- No commit or push in this pass

## 2026-06-04 — Android NUPnP Fallback Inventory and Gated Deferral (ANDROID-005C)

- Branch: `android/nupnp-fallback-inventory`
- Starting SHA: `785d085949dc22cf14b20c6948cb0268030f2768`
- Docs-only inventory / decision slice — read-only inventory reviewed and approved; no Android fallback behavior implemented; no network probe performed
- New decision record: `docs/android/android-nupnp-fallback-inventory.md` (title/status, decision, Android baseline, iOS fallback contract, IOS-BUG-002A evidence, architecture implications, why deferred, future preconditions, future implementation shape, non-goals)
- Existing iOS fallback contract recorded: cloud-assisted Philips Hue N-UPnP discovery (not LAN SSDP/mDNS, not local NUPnP) — `GET https://discovery.meethue.com/api/nupnp`; expects JSON array of `id`, `internalipaddress`, optional `port`; defaults port to `443` when omitted; runs after ~12s if still scanning; silently selects the first returned bridge; does not inspect HTTP status before decoding; failed decode falls into existing retry path
- IOS-BUG-002A evidence: physical DEBUG capture observed `GET https://discovery.meethue.com/api/nupnp` returning body `404 page not found`; root cause unresolved (endpoint drift vs transient vs account/network-specific vs other external assumption — not yet known); no fix claimed in this Android slice
- Decision: `DEFER UNTIL IOS-BUG-002A IS RESOLVED` — gated deferral, not MVP removal
- Android continues with ANDROID-005A mDNS chooser + ANDROID-005B manual entry as the active local-first onboarding baseline
- Any future Android cloud-assisted fallback must feed the existing chooser rows and require an explicit row tap — the iOS silent first-result selection must not be copied (would violate the landed ANDROID-005A explicit-chooser invariant); fallback stays optional and never the mandatory lighting-control path
- Future Android follow-up gated on: confirmed supported endpoint, confirmed response shape + explicit HTTP-status behavior, product approval for the narrow cloud-assisted exception, product approval that cloud results feed the chooser (no silent auto-select), and a bounded future task packet; no future task ID is frozen
- Foundation scaffold plan updated near the ANDROID-005C roadmap entry to record inventory/decision completion, the deferral, the active mDNS + manual-entry baseline, and a link to the decision record
- No Kotlin, Swift, manifest, Gradle, dependency, test, Xcode, or runtime changes
- No network probe performed
- No commit or push in this pass

## 2026-06-04 — Android Pairing TLS / Stable-Identity Decision Blocker (ANDROID-006A)

- Branch: `android/link-button-pairing`
- Starting SHA: `0571c6d0e67b6e11e314bf7b1e567b55bb60cf8c`
- Docs-only stable-identity / TLS inventory — read-only investigation reviewed and approved; no pairing runtime code added; no network probe performed
- New blocker record: `docs/android/android-pairing-tls-identity-decision.md` (status/decision, current onboarding baseline, known pairing contract, stable-identity blocker, TLS-bootstrap blocker, unsafe iOS precedent, why deferred, future preconditions, future sequencing shape, explicit non-goals)
- Status: `BLOCKED — SAFE TLS BOOTSTRAP AND CANONICAL BRIDGE IDENTITY MUST BE DECIDED BEFORE LIVE PAIRING CODE`
- Known pairing contract (evidence only): `POST {scheme}://{host}:{port}/api`; `Content-Type: application/json`; ~10s timeout; body `devicetype` + `generateclientkey`; Android device type `chromaglow#android`; JSON-array response; success `username` + optional `clientkey`; retryable type `101` (link button not pressed); type `7` invalid body/devicetype
- ANDROID-004A credential boundary (`BridgeCredentialStore` / `BridgeCredentialAlias`) requires a stable `bridgeId`, not host or port
- Android discovery (mDNS) and manual endpoint entry currently produce only `name`, `host`, and `port` via `BridgeEndpoint`; neither yields a canonical bridge ID
- Pairing response contains no stable bridge ID; host + port is short-lived routing/dedupe only and is not durable identity across DHCP changes; do not fabricate, randomly generate, or substitute a bridge ID; do not copy the iOS random-UUID storage precedent
- Safe first-contact TLS trust cannot be derived from repo evidence alone — no approved CA, fingerprint, hostname rule, pinning material, or TOFU-bootstrap rule exists; permissive `X509TrustManager` and blind-`true` `HostnameVerifier` are not approved; HTTP-stack selection deferred until trust policy approved
- iOS permissive local server-trust acceptance is evidence only and must not be copied; Android must not suppress trust failures and continue silently
- Decision: `C. RECORD A DOCS-ONLY TLS / IDENTITY DECISION BLOCKER BEFORE ANY PAIRING CODE` — runtime pairing blocked until approved TLS-bootstrap and canonical bridge-ID contracts exist; pairing remains the next runtime feature, gated
- Contract-freeze updated near the pairing + certificate-trust sections; foundation scaffold plan updated near the ANDROID-006A roadmap row; both link the new decision record
- No Kotlin, Swift, tests, manifest, Gradle, dependency, or runtime changes
- No network probe performed
- No commit or push in this pass
