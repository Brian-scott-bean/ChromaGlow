# Parallel Agent Pipeline + Shared Decision Log

## Status

- **Purpose:** Define how multiple coding agents (Claude, Codex, Cursor) work concurrently on
  ChromaGlow — each in its own git worktree on a disjoint set of files — so their branches merge
  together without conflict. Also defines the shared **Decision Log** where agents propose, debate,
  and record agreements across tools.
- **Type:** Process / coordination contract.
- **Consolidated:** 2026-06-24
- **Canonical rules live in:** `AGENTS.md` → "Parallel Agent Pipeline" section. This doc is the
  operational registry + decision log that section points to.

## Rules for this doc

- Git is the shared memory. Both tools see this file only after fetch/pull — commit and push changes
  the moment another agent needs them.
- A **lane** is a disjoint glob of files one agent owns for the duration of a batch. No two active
  lanes may share a glob.
- **Collision-hotspot** files (below) may be touched by at most one lane per batch. Feature lanes do
  not edit them directly — they request the change via the Decision Log.
- Append to the Decision Log; never rewrite another agent's turn. `Status` records the agreed state.

---

## 1. Lane Registry

`open` = unclaimed · `claimed` = an agent owns it this batch · `merged` = landed on integration branch.

### Android lanes (parallel-safe — modular, greenfield)

| Lane ID | Ownership globs | Parallel-safe | Status | Owner |
| --- | --- | --- | --- | --- |
| `android-setup` | `android/app/src/main/java/com/chromaglow/app/feature/setup/**` | Yes | open | — |
| `android-dashboard` | `android/app/src/main/java/com/chromaglow/app/feature/dashboard/**` | Yes | open | — |
| `android-credentials` | `android/app/src/main/java/com/chromaglow/app/core/credentials/**`, `…/core/hue/discovery/**` | Yes (non-pairing only) | open | — |
| `android-models-theme` | `android/app/src/main/java/com/chromaglow/app/core/model/**`, `…/data/demo/**`, `…/ui/theme/**` | Yes | open | — |
| `android-tests` | `android/app/src/test/**`, `android/app/src/androidTest/**` | Yes | open | — |

### iOS lanes (documented, but mostly NOT parallel-safe — see §2)

| Lane ID | Ownership globs | Parallel-safe | Status | Owner |
| --- | --- | --- | --- | --- |
| `ios-design-system` | `HueHome/UI/Components/**` | Yes (pure UI, no app state) | open | — |
| `ios-widgets-intents` | `HueHomeWidget/**`, `HueHome/Intents/**` | Yes (extension code) | open | — |
| `ios-tests` | `HueHomeTests/**` | Yes (per test subject) | open | — |
| `ios-dashboard` | `HueHome/UI/Dashboard/**`, `HueHome/Core/Dashboard/**` | Partial (reads orchestrator) | open | — |
| `ios-roomdetail` | `HueHome/UI/RoomDetail/**`, `HueHome/UI/LightControl/**`, `HueHome/Core/ViewModels/RoomDetailViewModel.swift` | Partial | open | — |
| `ios-scenes` | `HueHome/UI/Scenes/**`, `HueHome/UI/SceneBuilder/**` | Partial | open | — |
| `ios-studio` | `HueHome/UI/Studio/**`, `HueHome/Core/Composer/**` | No (largest; gate files) | open | — |
| `ios-sync` | `HueHome/UI/Sync/**` (excl. shared engine files) | No (gate files) | open | — |
| `ios-effects-automations` | `HueHome/UI/Effects/**`, `HueHome/UI/Automations/**`, related ViewModels | Partial | open | — |
| `ios-bridge-setup` | `HueHome/UI/BridgeSetup/**`, `HueHome/UI/BridgeManager/**`, `HueHome/Core/ViewModels/BridgeDiscoveryViewModel.swift` | Partial | open | — |

### Cross-cutting

| Lane ID | Ownership globs | Parallel-safe | Status | Owner |
| --- | --- | --- | --- | --- |
| `docs` | `docs/**`, root `*.md` (coordinate `AGENTS.md`/`DEVLOG.md` edits) | Yes | open | — |

---

## 2. Collision Hotspots (single-owner per batch)

These files gate many features. At most one lane may modify each per batch; all other lanes route
requests through the Decision Log.

**iOS:**
- `HueHome/Core/Network/UnifiedOrchestrator.swift` (~3,232 LOC) — the central monolith; nearly every
  state mutation flows through it.
- `HueHome/Core/Network/HueAPIClient.swift`
- `HueHome/Core/Network/BridgeAnimationEngine.swift`
- `HueHome/Core/Models/CompositionModels.swift`
- `HueHome/Core/ViewModels/RoomDetailViewModel.swift`
- `HueHome/Core/Effects/HueEffect.swift`
- `HueHome/UI/Navigation/MainTabView.swift`
- `HueHome/HueHomeApp.swift` (entry point + `Notification.Name` registry + SwiftData container)
- `HueHome/Core/Persistence/*` (SwiftData schema)
- `HueHome/Info.plist`, `HueHome/HueHome.entitlements`

**Android:**
- `android/app/build.gradle.kts`, `android/settings.gradle.kts`, `android/gradle.properties`
- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/java/com/chromaglow/app/app/ChromaGlowApp.kt`
- `android/app/src/main/java/com/chromaglow/app/MainActivity.kt`
- `android/app/src/main/res/values/**` (`strings.xml`, `colors.xml`, `themes.xml`)

> **Why iOS is mostly not parallel-safe:** because `UnifiedOrchestrator.swift` and the other gate
> files above sit on the path of most iOS features, two "different" iOS lanes frequently want the
> same file. Run iOS lanes one-or-two at a time, not 10-wide. Android's modular layout has no such
> central choke point.

---

## 3. Branch / Worktree / Merge Model

- **Lane branch:** `lane/<batch>-<slice>` — e.g. `lane/android1-dashboard`.
- **Integration branch:** `integration/parallel-batch-1` (forked from `main`).
- **Worktree:** one per lane, forked from `main`, auto-managed by the orchestration run.
- **Merge model:**
  `main → integration/parallel-batch-1 → (each clean lane branch merged in) → human review → main`.
  Disjoint lanes merge without conflict by construction. A human (collaborator) performs the final
  merge to `main` because the agent `gh` account is not a repo collaborator.

### Lane lifecycle

1. **Claim** — mark the lane `claimed` (with owner) in the registry above.
2. **Work** — edit only the lane's globs in its worktree; run the narrowest validation.
3. **Handoff** — append a `DEVLOG.md` entry using the standard template
   (`## YYYY-MM-DD - [Claude|Codex|Cursor] …` / Branch / Did / Working / Left / Validation / Gotchas).
4. **Merge** — merge the lane branch onto `integration/parallel-batch-1`; set the lane `merged`.

---

## 4. Pilot — Batch 1 (Android-only, ~5 lanes)

The first real run. Driven by Claude Code's Workflow + worktree isolation. All lanes stay within
frozen Android MVP scope and respect the pairing blocker (see Decision Log D-001/D-002).

| Lane branch | Source lane | Scope notes |
| --- | --- | --- |
| `lane/android1-setup` | `android-setup` | Build the setup screen out from placeholder |
| `lane/android1-dashboard` | `android-dashboard` | Room grid from demo fixtures |
| `lane/android1-credentials` | `android-credentials` | **Non-pairing only** — manual-IP parser, discovery chooser UI, tests. No live pairing, no credential persistence calls (blocked by D-001/D-002). |
| `lane/android1-models-theme` | `android-models-theme` | Demo models/data + theme tokens |
| `lane/android1-tests` | `android-tests` | JVM/instrumented tests per subject |

**Held out of Batch 1** (gate files): `android/app/build.gradle.kts`, `AndroidManifest.xml`,
`settings.gradle.kts`, `res/values/**`. Any needed change → open a Decision Log entry.

**Validation per lane:** from `android/`, `./gradlew testDebugUnitTest lintDebug` **iff** a JDK /
Android toolchain is present. If `/usr/bin/java` reports no runtime, the lane reports
`validation skipped: no toolchain` rather than failing.

---

## 5. Decision Log

Append dated, tagged turns. Never rewrite another agent's turn. `Status` is the agreed state:
`PROPOSED | DISCUSSING | ACCEPTED | REJECTED | DEFERRED`.

### D-001 — Android pairing TLS bootstrap policy
- Status: DEFERRED (blocker)
- 2026-06-24 [Claude]: Recorded from `docs/android/android-pairing-tls-identity-decision.md`. Live
  pairing must not ship until a safe TLS bootstrap for Hue self-signed bridge HTTPS is decided. No
  trust-all TLS, no permissive hostname verifier, no blind cert acceptance.
- Resolution: open — needs human/Codex decision before any pairing lane writes pairing code.

### D-002 — Canonical stable bridge identity for credential aliasing
- Status: DEFERRED (blocker)
- 2026-06-24 [Claude]: Credential storage needs a canonical stable bridge identity; no fabricated
  bridge IDs. Blocks credential-persistence work in the `android-credentials` lane.
- Resolution: open — needs decision; pairs with D-001.

### D-003 — Batch 1 scope = Android-only, ~5 lanes
- Status: ACCEPTED
- 2026-06-24 [Claude]: First parallel run is Android-only (setup, dashboard, credentials non-pairing,
  models+theme, tests). iOS lanes documented but held back because gate files (UnifiedOrchestrator
  etc.) don't parallelize. Integration via `integration/parallel-batch-1` with human final merge.
  Orchestration via Claude Workflow + worktree isolation.
- Resolution: ACCEPTED (user decision, 2026-06-24).

### Open Questions
- Q1: Should the `android-credentials` lane build discovery-chooser UI now (non-pairing), or wait
  until D-001/D-002 resolve? (Proposed: yes, UI + parser + tests only.)
- Q2: After Batch 1 proves clean, which iOS-isolated lanes (`ios-design-system`, `ios-tests`,
  `ios-widgets-intents`) go in Batch 2?
- Q3: Do we want a second integration target (e.g. `prod`) or is `main` the only merge destination?
