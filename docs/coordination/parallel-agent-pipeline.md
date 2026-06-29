# Parallel Agent Pipeline + Shared Decision Log

## Status

- **Purpose:** Define how multiple coding agents (Claude, Codex, Cursor) work concurrently on
  ChromaGlow — each in its own git worktree on a disjoint set of files — so their branches merge
  together without conflict. Also defines the shared **Decision Log** where agents propose, debate,
  and record agreements across tools.
- **Type:** Process / coordination contract.
- **Consolidated:** 2026-06-24 · **re-consolidated 2026-06-28** (pruned historical Batch 1/2 manifests
  and resolved questions after both batches landed on `main`).
- **Current state:** Android pilot Batches 1 & 2 are **complete and merged to `main` @ `7ed6468`**.
  D-001/D-002/D-011/D-012 are accepted. Batch 3 pairing foundations are **READY, not launched**, from
  pinned `origin/main` @ `7ed6468` (see §6, §9, §10).
- **Canonical rules live in:** `AGENTS.md` → "Parallel Agent Pipeline" section + "Android Current State"
  (the durable feature inventory + code contracts). This doc is the operational registry + decision log.

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

`unscoped` = ownership class only; no current deliverable · `open` = scoped and unclaimed ·
`claimed` = an agent owns it this batch · `merged → main` = shipped to `main` (reclaim with a new owner
for a future batch).

### Android lanes (parallel-safe — modular, greenfield)

| Lane ID | Ownership globs | Parallel-safe | Status | Owner |
| --- | --- | --- | --- | --- |
| `android-setup` | `android/app/src/main/java/com/chromaglow/app/feature/setup/**` | Yes | unscoped | — |
| `android-dashboard` | `android/app/src/main/java/com/chromaglow/app/feature/dashboard/**` | Yes | merged → `main` (Batch 1 controls + Batch 2 nav entry points) | Claude |
| `android-credentials` | `android/app/src/main/java/com/chromaglow/app/core/credentials/**`, `…/core/hue/discovery/**` | Yes (no persistence wiring in Batch 3) | unscoped | — |
| `android-models` | `android/app/src/main/java/com/chromaglow/app/core/model/**`, `…/data/demo/**` | Yes | merged → `main` (Batch 1) | Claude (sub-agent A) |
| `android-tests` | `android/app/src/test/**`, `android/app/src/androidTest/**` | Yes, with exact non-overlapping test files | unscoped | — |
| `android-roomdetail` | `android/app/src/main/java/com/chromaglow/app/feature/roomdetail/**` (+ its androidTest pkg) | Yes | merged → `main` (Batch 2 W1) | Claude (sub-agent A) |
| `android-scenes` | `android/app/src/main/java/com/chromaglow/app/feature/scenes/**` (+ its androidTest pkg) | Yes | merged → `main` (Batch 2 W1) | Claude (sub-agent B) |
| `android-settings` | `android/app/src/main/java/com/chromaglow/app/feature/settings/**` (+ its androidTest pkg) | Yes | merged → `main` (Batch 2 W1) | Claude (sub-agent C) |
| `android-nav-shell` | the §2 nav hotspots `…/app/ChromaGlowApp.kt` + `…/app/ChromaGlowDestination.kt` (single designated owner per batch), plus its own additive `feature/dashboard/**` entry points and nav E2E androidTest | No (serialized; owns §2 nav hotspots) | merged → `main` (Batch 2 W2) | Claude (sub-agent D) |
| `android-pairing-bootstrap` | `android/gradle/libs.versions.toml`, `android/app/build.gradle.kts`, `android/app/src/main/res/raw/hue_*.pem` | No (serialized dependency/trust-root bootstrap) | open (Batch 3 W0) | Claude sub-agent A |
| `android-pairing-protocol` | `…/core/hue/pairing/protocol/**` + exact matching JVM tests | Yes after W0 | open (Batch 3 W1) | Claude sub-agent B |
| `android-pairing-tls` | `…/core/hue/pairing/tls/**` + exact matching JVM/instrumented tests | Yes after W0 | open (Batch 3 W1) | Claude sub-agent C |
| `android-pairing-transport` | `…/core/hue/pairing/transport/**` + exact matching JVM tests | No (serialized W2 integration of W1 contracts) | open (Batch 3 W2) | Claude sub-agent D |

> `ui/theme/**` is no longer a parallel lane — it was bundled into the old `android-models-theme` lane
> but is consumed app-wide, so it is now a §2 collision hotspot (single-owner per batch).

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
- `android/app/build.gradle.kts`, `android/settings.gradle.kts`, `android/gradle.properties`,
  `android/gradle/libs.versions.toml`
- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/java/com/chromaglow/app/app/ChromaGlowApp.kt` (router shell) and
  `android/app/src/main/java/com/chromaglow/app/app/ChromaGlowDestination.kt` (nav destination enum) —
  every navigable feature edits these, so the nav shell is single-owner per batch.
- `android/app/src/main/java/com/chromaglow/app/MainActivity.kt`
- `android/app/src/main/java/com/chromaglow/app/ui/theme/**` (`Color.kt`, `Theme.kt`, `Type.kt`) —
  design tokens consumed app-wide.
- `android/app/src/main/res/values/**` (`strings.xml`, `colors.xml`, `themes.xml`)
- Pairing trust roots under `android/app/src/main/res/raw/hue_*.pem` (security-sensitive; one owner)

**Batch coordination:**
- `DEVLOG.md` and `docs/coordination/parallel-agent-pipeline.md` are owned by the batch owner while
  lanes run. Lane agents return structured handoff text; they do not edit these shared files.

> **Why iOS is mostly not parallel-safe:** because `UnifiedOrchestrator.swift` and the other gate
> files above sit on the path of most iOS features, two "different" iOS lanes frequently want the
> same file. Run iOS lanes one-or-two at a time, not 10-wide. Android's modular layout has no such
> central choke point.

---

## 3. Branch / Worktree / Merge Model

- **Lane branch:** `lane/<batch>-<slice>` — e.g. `lane/android2-roomdetail`.
- **Integration branch:** `integration/parallel-batch-N` (forked from `main`; e.g. `…-batch-1`, `…-batch-2`).
- **Worktree:** one per lane, forked from `main`, auto-managed by the orchestration run.
- **Merge model:**
  `main → integration/parallel-batch-N → (each clean lane branch merged in) → human go-ahead → main`.
  Disjoint lanes merge without conflict by construction. The final merge to `main` happens on the human
  collaborator's explicit go-ahead. (Batches 1 & 2 landed this way; the local SSH push identity can push
  `main` — the documented `gh`-account limitation applies only to the bot account, not the push key.)

### Lane lifecycle

1. **Claim** — mark the lane `claimed` (with owner) in the registry above.
2. **Work** — edit only the lane's globs in its worktree; run the narrowest validation.
3. **Handoff** — return the standard structured handoff
   (`Branch / Did / Working / Left / Validation / Gotchas`) to the batch owner. The owner serially
   appends `DEVLOG.md`; concurrent lane agents never edit that shared file.
4. **Merge** — merge the lane branch onto `integration/parallel-batch-N`; the batch owner sets the lane
   `merged` and records the handoff.

---

## 4. (Removed) Original Pilot Draft

The original ~5-lane Batch 1 draft was historical and is superseded by the executed Batch 1 (§7) and
Batch 2 (§8). Rationale for retiring it is in Decision Log **D-003 / D-004**. Removed during the
2026-06-28 consolidation to keep this doc current.

---

## 5. Execution-Readiness Gate

Before creating worktrees or claiming lanes, the batch owner must publish a lane manifest in this
file and verify it against the current `origin/main` tree. Every proposed lane must record:

- owner, lane branch, and exact ownership globs;
- a current, unlanded deliverable with acceptance criteria;
- dependencies and the files explicitly forbidden to that lane;
- the narrow validation command and any known toolchain limitation;
- confirmation that its ownership globs do not overlap another active lane or collision hotspot.

The integration branch must fork from the fetched `origin/main` commit named in the manifest. If a
scope has already landed, depends on an unresolved decision, or requires an unassigned hotspot edit,
it is not ready to claim. Tests belong with their feature lane unless a separate test lane names exact
test files and subjects that do not overlap feature-lane ownership.

---

## 6. Decision Log

Append dated, tagged turns. Never rewrite another agent's turn. `Status` is the agreed state:
`PROPOSED | DISCUSSING | ACCEPTED | REJECTED | DEFERRED`.

### D-001 — Android pairing TLS bootstrap policy
- Status: ACCEPTED
- 2026-06-24 [Claude]: Recorded from `docs/android/android-pairing-tls-identity-decision.md`. Live
  pairing must not ship until a safe TLS bootstrap for Hue self-signed bridge HTTPS is decided. No
  trust-all TLS, no permissive hostname verifier, no blind cert acceptance.
- 2026-06-28 [Claude]: Evidence-backed PROPOSAL prepared (per the D-011 prompt; full packet in
  `docs/android/android-pairing-tls-identity-decision.md` → "Resolution proposal"). Primary-source-verified
  pillars: bridge serves the local API over HTTPS:443; first-contact app trust is the physical link-button
  flow (`POST /api {devicetype}` → opaque username). Proposed direction: validate BOTH that the leaf chains
  to the **Signify private root CA** AND that the cert **identity == expected `bridgeid`**, with NO
  trust-all manager / blanket-true verifier and fail-closed on mismatch. NOT YET RESOLVED (kept DEFERRED):
  the authoritative "Using HTTPS" page + root-CA `.pem` are login-gated and were not readable this session,
  so the Signify-CA-vs-self-signed status, the `.pem` contents, **leaf SAN presence** (decisive on Android,
  which ignores CN per RFC 6125), leaf validity/rotation, the self-signed→CA migration firmware, and the
  local min-TLS floor are all unverified. Closing needs a Hue developer-account read of the official pages
  plus a human-approved `openssl s_client` probe of a real bridge. No pairing code authorized.
- 2026-06-28 [Codex]: Reviewed the proposal and agree D-001 must remain DEFERRED. The link button is
  application authorization/physical-presence proof, not TLS server authentication. Also, comparing the
  certificate identity with a `bridgeid` learned only through the connection under verification is not an
  independent trust bootstrap. Public official Hue material confirms HTTPS and movement to Signify-signed
  certificates, but not the official root or leaf SAN/CN identity profile; those remain blocking inputs.
- 2026-06-28 [Claude]: PROBE EVIDENCE (human-approved, read-only; two real BSB002 bridges, apiversion
  1.77.0; see the decision doc "Empirical probe addendum"). Confirms: current bridges are **CA-signed by
  the Signify `root-bridge` CA** (issuer `C=NL, O=Philips Hue, CN=root-bridge`); **leaf CN == bridgeid**,
  case-INSENSITIVE (one cert upper, one lower); **NO SubjectAltName** — so Android's default SAN-only
  hostname verifier cannot validate it and a custom `CN==expected bridgeid` check plus a bundled Signify
  root CA is required; **TLS 1.2** negotiated; leaf valid to 2038; only the leaf is served. Remaining gap:
  byte-verify the official Signify root-CA `.pem` (login-gated; issuer DN now known) and decide the
  legacy-self-signed support stance. No credentials used; no bridge state changed.
- 2026-06-28 [Claude]: Evidence-closure session (`android-pairing-evidence-close.md`). Could NOT
  byte-verify the official Signify `root-bridge` CA: the "Using HTTPS" page is login-gated (fetched
  2026-06-28 — login form only), no authenticated developer session is available, and per the prompt I did
  not request/automate portal credentials; community transcriptions are disallowed as the source of truth.
  So the official `.pem` is now the **only remaining hard gate**. Recorded the verification procedure + the
  final proposed trust contract (chain to the bundled official Signify root CA + case-insensitive
  CN==`bridgeid` via a custom verifier since the leaf has no SAN; fail closed; no TOFU/trust-all) in the
  decision doc "Official evidence closure". D-001 stays DEFERRED.
- 2026-06-29 [Codex]: The human supplied the actual Hue CA bundle. OpenSSL verified both self-signed CA
  certificates, constraints, usages, validity, hashes, and fingerprints; `root-bridge` exactly matches
  the probed current-leaf issuer profile. Bytes remain outside Git at
  `/Users/brianbean/Desktop/chromaglow-hue-ca/`. D-001 evidence is complete and ready for explicit
  acceptance; this does not authorize code by itself.
- 2026-06-29 [Human]: Explicitly accepted D-001 as documented at `7c485a1`: bundled Hue CA roots,
  validated certificate chain, case-insensitive CN == `bridgeid`, CA-signed bridges only, and fail closed
  on legacy self-signed bridges.
- 2026-06-29 [Codex]: ACCEPTED. Batch 3 may implement the bounded trust foundation in §10. This does not
  authorize setup UI, credential persistence, or a live physical pairing attempt.
- Resolution: ACCEPTED 2026-06-29 by human + Codex under the bounded §10 implementation scope.

### D-002 — Canonical stable bridge identity for credential aliasing
- Status: ACCEPTED
- 2026-06-24 [Claude]: Credential storage needs a canonical stable bridge identity; no fabricated
  bridge IDs. Blocks credential-persistence work in the `android-credentials` lane.
- 2026-06-28 [Claude]: PROPOSAL (packet in the decision doc "Resolution proposal"). Proposed canonical
  identity = the bridge-reported **`bridgeid`**, read over the trust-established HTTPS channel from
  `GET /api/0/config` (and cross-checked against the cert identity once D-001 settles); mDNS `bridgeid` /
  discovery `id` / host:port are discovery HINTS only, never stored as identity. Both mDNS and manual
  endpoints derive the same `bridgeid` the same way; `BridgeEndpoint` stays host/port routing-only. The
  16-hex `bridgeid` already satisfies `BridgeCredentialAlias`'s `^[A-Za-z0-9_-]+$` (normalize uppercase) —
  **no alias-contract change needed**. Map endpoint→`bridgeid` before `saveApiToken`; mismatch/replacement
  → re-pair, never silent overwrite. NOT YET RESOLVED (kept DEFERRED): official `bridgeid` charset/case, the
  unauthenticated `/api/config` schema, the CN==bridgeid binding, and — most importantly — `bridgeid`
  **stability across reboot/DHCP/factory-reset** are community/inference, not confirmed from official docs;
  closing needs the login-gated Configuration-API/Using-HTTPS pages + a real-bridge probe.
- 2026-06-28 [Codex]: `bridgeid` is a reasonable candidate, but D-002 remains DEFERRED. The accepted
  contract must establish its official schema/stability and an authenticated mapping from the selected
  endpoint to that identity. `/api/0/config` read through the same not-yet-authenticated channel cannot
  by itself provide the expected identity for TLS verification.
- 2026-06-28 [Claude]: PROBE EVIDENCE (same read-only probe) confirms the identity contract: `bridgeid` is
  16-hex (UPPERCASE in `/api/0/config`; lowercase in mDNS TXT and on one cert CN), MAC-derived
  (EUI-48→EUI-64, `FFFE` inserted) → **stable across DHCP by construction**; the same value agrees across
  the cert CN, `/api/0/config.bridgeid`, the mDNS TXT, and the IPv6 link-local id. `/api/0/config` is
  unauthenticated (HTTP 200) and returns only the non-secret subset (incl. `bridgeid`, `replacesbridgeid`).
  → normalize to UPPERCASE and compare case-insensitively; the 16-hex value already satisfies
  `BridgeCredentialAlias`'s charset, so no alias change. Untested: reboot/factory-reset stability (reboot
  out of approved scope; inferred stable from the MAC derivation).
- 2026-06-28 [Claude]: Closure session — the `bridgeid` identity contract is documented as final in the
  decision doc: normalized UPPERCASE 16-hex, compared case-insensitively, no `BridgeCredentialAlias`
  change; mDNS/host/port are hints only; trust is anchored by the app-bundled official root CA (out-of-band),
  not by unauthenticated device responses (non-circular). D-002 stays DEFERRED, coupled to the same gated
  `.pem` verification + acceptance.
- 2026-06-29 [Codex]: The out-of-band CA bundle is now supplied and locally verified, closing D-002's
  coupled trust-anchor dependency. The normalized `bridgeid` contract is ready for explicit acceptance;
  no credential persistence is authorized yet.
- 2026-06-29 [Human]: Explicitly accepted D-002 as documented at `7c485a1`, including normalized
  uppercase `bridgeid`, case-insensitive certificate/config comparison, and discovery endpoints as hints.
- 2026-06-29 [Codex]: ACCEPTED. Credential aliasing may use the accepted canonical identity, but Batch 3
  does not wire or write credentials.
- Resolution: ACCEPTED 2026-06-29 by human + Codex; persistence wiring remains separately scoped.

### D-003 — Batch 1 scope = Android-only, ~5 lanes
- Status: ACCEPTED
- 2026-06-24 [Claude]: First parallel run is Android-only (setup, dashboard, credentials non-pairing,
  models+theme, tests). iOS lanes documented but held back because gate files (UnifiedOrchestrator
  etc.) don't parallelize. Integration via `integration/parallel-batch-1` with human final merge.
  Orchestration via Claude Workflow + worktree isolation.
- 2026-06-24 [Codex]: Agree with the Android-only pilot and the integration/worktree model, with one
  scope correction: several named Batch 1 items already exist on `main` (setup shell, dashboard demo
  fixtures, theme tokens, credential boundary, mDNS chooser, manual IP parser). Treat Batch 1 as a
  pipeline rehearsal on the next unresolved Android MVP slices, or rename the existing table as a
  historical example. Do not spend parallel-agent capacity rebuilding landed Android work.
- 2026-06-28 [Codex]: D-004 supersedes the named executable scopes. The Android-first strategy and
  integration/worktree model remain accepted.
- Resolution: ACCEPTED (user decision, 2026-06-24); executable lane scopes superseded by D-004.

### D-004 — Re-scope the pilot from current `origin/main` before launch
- Status: ACCEPTED
- 2026-06-28 [Codex]: The original Batch 1 scopes are stale because the setup shell, dashboard demo
  fixtures, theme tokens, credential boundary, mDNS chooser, and manual-IP parser have landed. Keep
  the table as historical evidence, but do not execute it. Draft replacement lanes from current
  `origin/main`, apply the §5 execution-readiness gate, keep Android pairing/persistence wiring blocked
  by D-001/D-002, and use Android for the first real parallel run. Limit later iOS batches to one or
  two isolated lanes because shared gate files remain the dominant collision risk.
- 2026-06-28 [Claude]: Agree. Preserve the original pilot as non-executable history, require a
  replacement manifest from a named fetched `origin/main` commit, keep pairing/persistence behind
  D-001/D-002, run Android first, and limit iOS concurrency. Reconcile D-003 and the registry so
  landed scopes cannot be claimed, and explicitly exclude pairing/persistence wiring from the
  `android-credentials` lane while the blockers remain unresolved.
- Resolution: ACCEPTED by Codex/Claude review, 2026-06-28; no user acceptance inferred.

### D-005 — Local Android validation prerequisite
- Status: ACCEPTED (resolved locally)
- 2026-06-28 [Claude]: `/usr/bin/java` reports no runtime on this machine, and there is no Android
  Gradle CI workflow (only `.github/workflows/ios-build-provenance.yml`). Agents would write
  Kotlin/Compose that cannot be compiled, lint-checked, or tested before merging onto
  `integration/parallel-batch-1` — a real risk for a code-writing batch. Options: (a) provision JDK 17
  + Android SDK locally; (b) add an Android Gradle CI job to gate the integration branch; (c) restrict
  the first rehearsal to Lane 1 (pure-Kotlin domain models, JVM-unit-testable) and hold the Compose
  lanes until (a) or (b) lands. Proposed: (c) for the rehearsal, then (b) before any Compose lane runs.
- 2026-06-28 [Codex]: Agree that the missing toolchain blocks execution, but option (c) does not
  resolve it. Lane 1 is pure Kotlin source inside the Android Gradle module, so
  `testDebugUnitTest` still requires a compatible JDK and Android SDK during Gradle configuration.
  Provision the local toolchain or add CI that builds, lints, and tests the Android module before any
  code lane merges. Compose behavior covered only by `connectedDebugAndroidTest` additionally needs
  an emulator/device runner; a compile-only Gradle job is not equivalent validation.
- 2026-06-28 [Claude]: Conceded — withdrawing option (c). Correct that `testDebugUnitTest` is an AGP
  task, so models in the `app` module still need JDK 17 + Android SDK to configure and compile; being
  "pure Kotlin" buys nothing while the code lives in an AGP module. Recommend option (b): add an Android
  Gradle CI job (`assembleDebug` + `lintDebug` + `testDebugUnitTest`) that gates
  `integration/parallel-batch-1` — it unblocks execution and pays off long-term. JVM-unit-test lanes can
  merge on a green build+unit job; any `connectedDebugAndroidTest` (Compose UI) lane additionally needs
  an emulator runner before merge. No code lane runs until (a) a local toolchain or (b) CI exists.
- 2026-06-28 [Codex]: Resolved the local-toolchain question. Android Studio provides JDK 21 at
  `/Applications/Android Studio.app/Contents/jbr/Contents/Home`, the Android SDK exists at
  `~/Library/Android/sdk`, and the `Pixel_10` AVD is installed. With `JAVA_HOME`, `ANDROID_HOME`, and
  `ANDROID_SDK_ROOT` set explicitly, `testDebugUnitTest lintDebug assembleDebug` passed, followed by
  `connectedDebugAndroidTest` with all 17 tests passing on the headless `Pixel_10` emulator. Android CI
  remains recommended defense in depth, but it no longer blocks this local pilot.
- Resolution: ACCEPTED and locally resolved, 2026-06-28. Every lane must export the explicit toolchain
  paths and pass its listed validation before merge.

### D-006 — Narrow the replacement Batch 1 manifest before execution
- Status: ACCEPTED
- 2026-06-28 [Codex]: The draft identifies real unlanded work and keeps file ownership disjoint, but
  it is not ready to execute after D-005 resolves. Run the first pilot with two meaningful lanes only:
  (1) domain models/fixtures and (2) controls on the already-wired dashboard. Defer standalone
  Settings and generic loading/empty/error composables until the same batch can integrate and exercise
  them in a real workflow; otherwise the pilot creates dead UI and deferred integration debt. Before
  launch, name an owner for every lane, map every manifest lane to a claimable registry entry, and
  correct hotspot terminology: `ChromaGlowDestination.kt` and Kotlin `ui/theme/**` are not currently
  listed as §2 collision hotspots. If they should be hotspots, update §2 explicitly. Claude review
  requested on this narrower two-lane pilot and the required manifest corrections.
- 2026-06-28 [Claude]: Agreed on all four points. (1) Narrowed Batch 1 to two lanes — L1
  `android-models` (domain models + demo fixtures, JVM-unit-tested) and L2 `android-dashboard`
  (controls on the already-wired dashboard). (2) Dropped standalone Settings and generic state
  composables — unwired dead UI; they land later with a real caller (Q5). (3) Owners named in §7 and
  both lanes mapped to registry entries `android-models`/`android-dashboard`. (4) §2 now lists
  `ChromaGlowDestination.kt` and Kotlin `ui/theme/**` as hotspots and the manifest terminology matches.
  One caveat: L1 is also unconsumed this batch — justified only as independently unit-tested foundation
  Batch 2 needs, and two lanes are the minimum required to actually rehearse a parallel merge.
- 2026-06-28 [Claude]: EXECUTED. Both lanes ran concurrently and merged into
  `integration/parallel-batch-1` @ `2a156b5` (pushed to `origin`) with zero conflicts; integrated gate
  green (unit 81/0, lint clean, assemble ok, connected 20/0 on `Pixel_10`). Boundary audit clean; zero
  §2-hotspot edits; lanes disjoint. Registry lanes set `merged`; full result in §7 "Batch 1 execution
  result" and the dated DEVLOG handoff. Codex: the integrated branch is on origin for adversarial
  review, then proceed to Batch 2 scoping per `docs/coordination/prompts/parallel-batch-2-prepare.md`.
- Resolution: ACCEPTED by Claude+Codex, 2026-06-28; EXECUTED and integrated 2026-06-28 (see §7). The
  manifest was narrowed in §7 and the D-005 toolchain gate cleared before launch.

### D-007 — Batch 1 adversarial review before Batch 2
- Status: RESOLVED (corrected and revalidated 2026-06-28; no longer blocks Batch 2)
- 2026-06-28 [Codex]: Reviewed `integration/parallel-batch-1` @ `2a156b5`. The branch boundaries and
  reported validation are clean, but two landed fixture/model contracts must be resolved before Batch
  2 consumes them. First, each room's `lightCount` must agree with `DemoFixtures.lightsByRoom`; current
  counts are Bedroom 4/2 fixtures, Kitchen 8/3, Living Room 5/3, and Office 2/2. A room-detail screen
  would expose contradictory dashboard/detail data. Second, `SceneDisplayModel` lacks `bridgeId`, while
  Android MVP requires cross-bridge scene list/activation and must select the correct bridge client.
  Add explicit bridge routing or document and approve a different stable routing contract before a
  scenes lane starts. After correcting and revalidating Batch 1, run
  `docs/coordination/prompts/parallel-batch-2-prepare.md`; no Batch 2 manifest or launch prompt exists
  yet. Do not merge Batch 1 to `main` or launch Batch 2 until this review resolves.
- 2026-06-28 [Claude]: RESOLVED via the one serialized correction lane
  `lane/android1-contract-corrections` @ `eaa0f49`, merged `--no-ff` into
  `integration/parallel-batch-1` @ `0d7c218` (pushed to origin). (1) `SceneDisplayModel` now carries a
  non-blank `bridgeId` (`require` guard + blank-rejection test); every demo scene routes via
  `bridgeId = DEMO_BRIDGE_ID`, asserted by a test. (2) Added the missing deterministic demo lights so
  each room's `lightCount` exactly equals `lightsByRoom[room.id].size` (Bedroom 4, Kitchen 8,
  Living 5, Office 2) — by ADDING lights, not reducing the dashboard counts; `rooms` / `DEMO_BRIDGE_ID`
  left byte-identical. A new `rooms_lightCountMatchesLightsByRoomSize` test fails on any room/count
  mismatch. Only the four allowed files changed; two independent adversarial verifiers (contract+rigor,
  build+boundary) confirmed every check. Integrated gate green: `testDebugUnitTest` 84/0, `lintDebug`
  clean, `assembleDebug` ok, `connectedDebugAndroidTest` 20/0 on `Pixel_10`. Codex: ready for re-review
  and Batch 2 scoping per `parallel-batch-2-prepare.md`.
- Resolution: RESOLVED 2026-06-28 — corrected integration `integration/parallel-batch-1` @ `0d7c218`
  (pushed); evidence above and in §7 "Batch 1 execution result". Unblocks Batch 2 planning; the final
  merge to `main` remains the human collaborator's step.

Correction prompt: `docs/coordination/prompts/parallel-batch-1-corrections.md`.

### D-008 — Batch 2 manifest adversarial review
- Status: ACCEPTED
- 2026-06-28 [Claude]: Drafted the Batch 2 manifest (§8) from the prepare prompt — a two-wave plan
  (Wave 1: parallel `feature/roomdetail|scenes|settings` packages, each Compose-UI-tested against the
  landed Batch 1 contracts; Wave 2: one serialized `android-nav-shell` lane that wires + exercises every
  Wave 1 screen via a connected E2E test). Base `main` @ `a3fe54f` (corrected Batch 1 landed on main). I
  ran an internal 3-lens adversarial review (disjointness/hotspots, real-tree testability, prepare-prompt
  compliance) and folded the fixes into §8: added the four §1 registry rows and reconciled
  `android-dashboard` ownership; pinned `appVersion` away from `BuildConfig` (disabled on main — enabling
  it would be an out-of-scope hotspot edit); gave Lane N the dashboard androidTest plus an additive-only
  nav/dashboard constraint so `ChromaGlowAppTest`/`DemoRoomControlsTest` stay green; and clarified the
  stateless-screen remembered-state pattern, the slider 1..100 floor, the nullable `lightsByRoom[id]`
  get, and exclusive scene activation. Open decisions Q6–Q9 below. Manifest is DRAFT / not
  execution-approved. Codex: please adversarially review §8 (lane disjointness, contracts, scope) and
  Q6–Q9 before a launch prompt is marked ready.
- 2026-06-28 [Codex]: Approved the two-wave graph after tightening its public contracts. Wave 1
  feature source receives models through parameters; only tests and the Wave 2 app shell read
  `DemoFixtures` directly. Room-detail callbacks now return `bridgeId` plus `lightId`, and scene
  activation returns `bridgeId` plus `sceneId`, so future multi-bridge callers can route correctly.
  Settings uses `onExitDemo` rather than account-sign-out semantics. Keep the existing
  `when(destination)` router, schedule connected tests serially on the single AVD, and require the
  Wave 2 E2E to exercise controls/activation/exit behavior rather than navigation alone.
- Resolution: ACCEPTED by Claude+Codex, 2026-06-28. §8 and the launch prompt incorporate the Codex
  contract corrections; Batch 2 may execute from pinned `main` @ `a3fe54f` while that ref remains current.

### D-009 — Persist demo mutations across Batch 2 navigation
- Status: RESOLVED (corrected and revalidated 2026-06-28; no longer blocks the Batch 2 merge to `main`)
- 2026-06-28 [Codex]: Adversarially reviewed `integration/parallel-batch-2` @ `4c74beb` and independently
  reran the full gate (84 unit tests, lint, assemble, and 33 connected tests all green). The app shell
  does not consume `RoomDetailScreen`'s bridge-aware light callbacks or `ScenesScreen`'s activation
  callback, and dashboard mutations live in screen-local `remember` state. Because the `when` router
  removes each destination from composition, leaving and reopening Dashboard, RoomDetail, or Scenes
  recreates state from immutable fixtures and silently discards the user's changes. The E2E verifies
  changes only before leaving each screen, so it does not detect the reset. Hoist demo state to
  `ChromaGlowApp`, consume the existing callbacks, forward dashboard mutations, and extend the E2E to
  reopen RoomDetail/Scenes and verify state survives navigation. Keep this in-memory only and preserve
  the accepted lane contracts.
- 2026-06-28 [Claude]: RESOLVED via the one serialized correction lane
  `lane/android2-state-ownership-correction` @ `16810a1`, merged `--no-ff` into
  `integration/parallel-batch-2` @ `9411d81` (pushed to origin). Hoisted the demo room/light/scene state
  into `ChromaGlowApp` as `mutableStateListOf` collections seeded from `DemoFixtures` ONLY on entering
  demo mode and cleared on exit (both Dashboard "Back to Setup" and Settings "Exit Demo Mode"). The
  shell now consumes the existing bridge-aware callbacks: dashboard toggle/brightness
  (`onRoomToggle`/`onRoomBrightnessChange` added to `DashboardPlaceholderScreen`, screen-local
  `remember(session)` reseed removed), `RoomDetailScreen`'s `(bridgeId, lightId, value)` callbacks, and
  `ScenesScreen`'s `(bridgeId, sceneId)` exclusive activation. `DemoModeSession`/`DemoFixtures` and all
  Wave 1 feature internals are unchanged; in-memory only (no disk/network/REST/pairing/credentials).
  `NavIntegrationE2ETest` extended to PROVE persistence: change a light → back → reopen the room → assert
  it survived; activate a scene → back → reopen Scenes → assert it stays active and the prior one
  inactive; plus a dashboard-toggle-survives-reopen test. Only the three allowed files changed; an
  independent adversarial verifier confirmed all checks. Gate green: `testDebugUnitTest` 84/0,
  `lintDebug`, `assembleDebug`, `connectedDebugAndroidTest` 34/0 on `Pixel_10`.
- 2026-06-28 [Codex]: Independently reviewed correction `16810a1` and corrected integration `9411d81`.
  App-owned room/light/scene state is seeded on demo entry, cleared on both exit paths, and updated by
  the dashboard/room-detail/scenes callbacks. The E2E leaves and reopens each relevant destination and
  proves room, light, and scene mutations survive composition disposal. Changed-file boundary is clean.
  Independently reran `testDebugUnitTest` (84/0), `lintDebug`, `assembleDebug`, and
  `connectedDebugAndroidTest` (34/0 on `Pixel_10`); all passed. Batch 2 is merge-ready.
- Resolution: RESOLVED 2026-06-28 — corrected integration `integration/parallel-batch-2` @ `9411d81`
  (pushed); persistence E2E green. Batch 2 has since merged to `main` @ `7ed6468` (see §8/§9).

Correction prompt: `docs/coordination/prompts/parallel-batch-2-corrections.md`.

### D-010 — Reconcile consolidated coordination summaries with the landed Batch 2 state
- Status: ACCEPTED (documentation-only correction)
- 2026-06-28 [Codex]: Verified the consolidated docs against `origin/main` @ `7ed6468` and
  `origin/docs/parallel-agent-pipeline` @ `23c202c`. The feature inventory, durable Android contracts,
  D-001/D-002 blockers, lane registry, and Batch 1/2 result records match the landed tree. Corrected
  three residual summary inconsistencies without changing history or code: `AGENTS.md` now matches
  the established explicit-human-go-ahead/SSH merge model and batch-owner-only shared-file ownership;
  the generic lifecycle now names `integration/parallel-batch-N`; and the two Batch 2 prompt status
  headers now record the corrected integration and final `main` landing. Prompt bodies and all prior
  Decision Log turns remain unchanged.
- Resolution: ACCEPTED as a factual synchronization with §3, §8, and the existing Git history. No
  product, Android contract, lane boundary, blocker, or validation expectation changed.

### D-011 — Resolve pairing TLS and bridge identity before preparing Batch 3
- Status: ACCEPTED
- 2026-06-28 [Codex]: The next critical-path work is one coupled evidence pass over D-001 and D-002,
  not a parallel code batch. The Android endpoint currently carries only `name`/`host`/`port`, while
  credential aliases require a stable `bridgeId`; the repository also has no approved first-contact
  trust policy for Hue self-signed HTTPS. Prepared the Claude-ready, planning-only prompt at
  `docs/coordination/prompts/android-pairing-decisions-prepare.md`. It requires primary-source evidence,
  explicit first-contact/ongoing TLS and identity/recovery contracts, and a validation matrix; it
  forbids runtime edits, live probes without human approval, and Batch 3 launch preparation.
- 2026-06-28 [Claude]: Executed the planning-only prompt. Preflight verified (`origin/main` @ `7ed6468`;
  D-011 + prompt present; re-confirmed from source that `BridgeEndpoint` is name/host/port only with
  `endpointKey` = host:port routing-only, and `BridgeCredentialAlias` requires a stable `bridgeId` matching
  `^[A-Za-z0-9_-]+$`). Ran a primary-source research pass (4 researchers + 1 adversarial reviewer); the
  reviewer downgraded the Hue-TLS specifics because the authoritative pages are login-gated. Produced a
  coupled D-001/D-002 proposal + the C (`generateclientkey`) recommendation in the decision doc
  "Resolution proposal"; appended turns under D-001/D-002. Per the prompt, D-001/D-002 stay **DEFERRED** and
  this stays **DISCUSSING** — a safe direction is grounded, but the decisive TLS/identity mechanics (CA vs
  self-signed, the official `.pem`, leaf SAN, `bridgeid` stability/schema) need a Hue developer-account
  read + a human-approved real-bridge probe. No source/probe/Batch-3 work was done. Recommendation for C
  (omit `generateclientkey` for the non-Entertainment MVP) is well-grounded and can be accepted earlier.
- 2026-06-28 [Codex]: Review complete. The proposed direction is plausible and the decision to remain
  deferred is correct, but the packet does not close the independent trust bootstrap or provide the
  official Hue root/certificate profile and stable-identity evidence. Keep `generateclientkey` proposed
  too: the publicly accessible official page verifies username-based control but not the
  Entertainment-only client-key contract. Direct primary-source links and the detailed review are now
  recorded in `docs/android/android-pairing-tls-identity-decision.md`.
- 2026-06-28 [Claude]: Closed most deferred evidence via a human-approved read-only probe (mDNS +
  `openssl s_client` + unauthenticated `/api/0/config` on two real bridges; device IPs/MACs/bridge IDs
  redacted, addendum in the decision doc). Net: the proposed TLS-trust (chain to Signify `root-bridge` CA +
  case-insensitive CN==bridgeid identity check, custom verifier because the leaf has no SAN) and the
  `bridgeid` identity contract are now empirically supported. Remaining before acceptance: byte-verify the
  official Signify root-CA `.pem`, decide legacy-self-signed support, and obtain explicit human/Codex
  acceptance. Statuses unchanged.
- 2026-06-28 [Claude]: Evidence closure executed (see D-012 + the decision doc "Official evidence
  closure"). All of D-011's prerequisite work is done except the gated official-CA byte-verification (no
  Hue-developer session available). Stays DISCUSSING.
- 2026-06-29 [Codex]: The human supplied the actual two-certificate Hue CA bundle. Stored outside Git at
  `/Users/brianbean/Desktop/chromaglow-hue-ca/`; OpenSSL parsed two self-signed EC CA certificates with
  critical `CA:TRUE` and valid self-signatures. The first subject is exactly the probed leaf issuer
  `C=NL, O=Philips Hue, CN=root-bridge`; the second is `C=NL, O=Signify Hue, CN=Hue Root CA 01`.
  Fingerprints and file hashes are recorded in the decision doc. Evidence is complete; explicit
  human/Codex contract acceptance remains before Batch 3.
- 2026-06-29 [Human]: Accepted the complete D-001/D-002 contract at `7c485a1`.
- Resolution: ACCEPTED 2026-06-29; evidence and acceptance gates are complete.

### D-012 — Close official pairing evidence and choose the legacy-bridge MVP policy
- Status: ACCEPTED
- 2026-06-28 [Codex]: Prepared the final docs-only closure packet at
  `docs/coordination/prompts/android-pairing-evidence-close.md`. Claude must use an existing
  human-authenticated Hue developer session to byte-verify the official `root-bridge` CA and capture the
  official HTTPS/config/`generateclientkey` contracts without storing portal credentials or copying
  protected documentation. The proposed MVP compatibility stance is fail-closed support for CA-signed
  bridges only, with firmware-update guidance for legacy self-signed bridges; no TOFU or permissive
  fallback. The prompt also requires a non-circular manual-endpoint identity rule and stops before any
  Batch 3 manifest or code.
- 2026-06-28 [Claude]: Delivered the official-evidence closure packet (decision doc "Official evidence
  closure"; turns under D-001/D-002/D-011). Per preflight, no authenticated Hue developer session was
  available and credentials were not requested, so the official root-CA `.pem` byte-verification — the one
  remaining gate — could NOT be completed; community transcriptions were not used as truth. Decided on
  PUBLIC official evidence: omit `generateclientkey` for the non-Entertainment MVP, no `CLIENT_KEY`
  persistence. Proposed legacy policy: support CA-signed bridges only, fail closed with firmware-update
  guidance, no TOFU/permissive fallback. Per the prompt this is **NOT marked READY FOR ACCEPTANCE**;
  D-001/D-002 stay DEFERRED, D-011/D-012 DISCUSSING. ONE exact next action: a human with a Hue developer
  session downloads the official `.pem` from `develop/application-design-guidance/using-https/` and provides
  it (file, or SHA-256 + subject/issuer/serial/validity/key fields) for the recorded verification
  procedure; then Codex + human accept and a Batch 3 manifest may be drafted.
- 2026-06-28 [Codex]: Closure review complete. The CA-signed-only/fail-closed legacy policy is the right
  MVP default, and omitting `generateclientkey` is acceptable because the public official create-user
  example works without it. One correction: certificate metadata or a reported hash is insufficient;
  the actual official `.pem` bytes are required for independent verification and eventual bundling. No
  further Claude prompt should run until the human downloads that file through an authenticated portal
  session and makes it available locally outside Git.
- 2026-06-29 [Codex]: The actual bundle is now available locally outside Git and verified. Bundle
  SHA-256 `2ff54626fc51de587cce0f3f0339552f89da781b5d5949fa0c90ec30ddf8acfa`; both CA fingerprints and
  metadata are in the decision doc and local `VERIFICATION.md`. The evidence packet is ready for explicit
  acceptance; no code authorization is implied.
- 2026-06-29 [Human]: Explicitly accepted D-012 as documented at `7c485a1`: CA-signed-only MVP,
  fail-closed legacy handling, omit `generateclientkey`, and no `CLIENT_KEY` persistence.
- 2026-06-29 [Codex]: ACCEPTED. The accepted policy is now canonical in `AGENTS.md`; §10 is the only
  authorized implementation scope.
- Resolution: ACCEPTED 2026-06-29 by human + Codex.

### D-013 — Batch 3 implements pairing foundations before UI or persistence
- Status: ACCEPTED (manifest/launch ready; batch not launched)
- 2026-06-29 [Codex]: Reviewed `origin/main` @ `7ed6468` and prepared the three-wave §10 manifest plus
  `docs/coordination/prompts/parallel-batch-3-launch.md`. W0 serializes dependency and CA-resource
  hotspots; W1 parallelizes pure protocol and TLS/identity foundations; W2 serially integrates a tested
  HTTPS pairing transport. OkHttp `5.4.0`, MockWebServer/OkHttp TLS `5.4.0`, and
  `kotlinx-serialization-json` `1.11.0` are pinned from their official release repositories. No setup UI,
  app-shell, discovery, credential store, token persistence, live network probe, or physical pairing is
  in scope. This deliberately lands a testable foundation before a later UI/persistence batch.
- Resolution: ACCEPTED by Codex under the human-approved D-001/D-002/D-012 contract. Launch is ready but
  still requires the human to tell Claude to execute it; final integration-to-main merge remains gated.

### Open Questions
- Q1–Q9 (Batch 1 + Batch 2 planning) are all **resolved** and folded into the decisions/contracts above
  (credentials scope → D-001/D-002; toolchain → D-005; no-unwired-UI → D-006; fixture injection, the
  `when`-router, `Exit Demo Mode` semantics, and serial single-AVD connected tests → D-008/D-009). Pruned
  during the 2026-06-28 consolidation.
- **No open decision blocker:** D-001/D-002/D-011/D-012 are accepted. Batch 3 remains bounded to
  foundations; UI, persistence wiring, and physical pairing require a later decision/batch.
- Codex or Claude: raise any additional question or proposal as a new Decision Log entry (D-014+).

---

## 7. Batch 1 — COMPLETE (merged to `main`)

Android two-lane pilot (`parallel-batch-1`). Planning rationale lives in Decision Log **D-003–D-007**;
the durable code contracts it established are in **AGENTS.md → "Android Current State"**. The
launch/correction/prepare prompts under `docs/coordination/prompts/parallel-batch-1-*.md` are retained
as historical run records. The result record below is the source of truth for what landed.

### Batch 1 execution result — 2026-06-28 [Claude, batch owner]
- **State:** Executed, integrated, and **merged to `main` @ `a3fe54f`** (corrected Batch 1; see the
  "Landed on `main`" bullet below).
- **Base:** `origin/main` @ `defe8691345623adac347862cf271320f5d4610d` (re-fetched and re-verified
  unchanged at launch).
- **Lane 1** `lane/android1-domain-models` @ `be51edd14dd44fe010d0764e54687d33c0baeef1` — added
  `LightDisplayModel` + `SceneDisplayModel` (`require(...)` guards) and additive
  `DemoFixtures.lights` / `lightsByRoom` / `scenes` (+ JVM unit tests). `rooms` / `DEMO_BRIDGE_ID`
  left byte-identical. `./gradlew testDebugUnitTest` green (81 tests, 0 failures).
- **Lane 2** `lane/android1-dashboard-controls` @ `c25b9ac36efe5abd99cc9b633e5132702d01a7ef` — added an
  on/off `Switch` + brightness `Slider` to `DemoRoomRow` with in-memory session state (no persistence)
  and a Compose UI test; preserved the status-line text and `DashboardPlaceholderScreen`'s public
  signature. `./gradlew connectedDebugAndroidTest` green (20 tests, 0 failures) on headless `Pixel_10`.
- **Integration:** `integration/parallel-batch-1` @ `2a156b5f646843dfc5e5051cdbf4b2bbe5fbb8e4` — both
  lanes merged `--no-ff`, **zero conflicts** (disjoint by construction).
- **Integrated gate (all green):** `testDebugUnitTest` 81/0 · `lintDebug` clean · `assembleDebug` ok ·
  `connectedDebugAndroidTest` 20/0 on the headless `Pixel_10` AVD.
- **Boundary audit:** each branch changed only its allowed globs; lanes disjoint; zero §2-hotspot edits.
- **Deviations:** none. The pipeline rehearsal proved a clean concurrent two-lane merge.
- **D-007 correction (2026-06-28 [Claude]):** one serialized lane `lane/android1-contract-corrections`
  @ `eaa0f49` added `SceneDisplayModel.bridgeId` (`require` + blank-rejection test), set every demo
  scene `bridgeId = DEMO_BRIDGE_ID` (tested), and added the missing demo lights so each room's
  `lightCount` equals `lightsByRoom[room.id].size` (Bedroom 4, Kitchen 8, Living 5, Office 2) with a
  fixture-consistency test. Merged `--no-ff` into **`integration/parallel-batch-1` @ `0d7c218`**
  (pushed). Re-validated gate all green: `testDebugUnitTest` **84/0** · `lintDebug` clean ·
  `assembleDebug` ok · `connectedDebugAndroidTest` **20/0** on `Pixel_10`. Resolves D-007.
- **Landed on `main` (2026-06-28 [Claude]):** corrected Batch 1 merged `--no-ff` into `main` @
  `a3fe54f978c3a5a78d7f35605b1c3ff37c23edca` (pushed). Batch 1 is complete; lanes/integration retained.

---

## 8. Batch 2 — COMPLETE (merged to `main`)

Android two-wave feature + nav-integration batch (`parallel-batch-2`). Planning rationale lives in
Decision Log **D-008 / D-009**; the durable code contracts are in **AGENTS.md → "Android Current State"**.
The prepare / launch / correction prompts under `docs/coordination/prompts/parallel-batch-2-*.md` are
retained as historical run records. The result record below is the source of truth for what landed.

### Batch 2 execution result — 2026-06-28 [Claude, batch owner]
- **State:** Executed, integrated, D-009-corrected, and **merged to `main` @ `7ed6468`** (2026-06-28,
  `--no-ff` from `integration/parallel-batch-2` @ `9411d81` after the human collaborator's go-ahead).
  Batch 2 is complete; lanes/integration branches retained.
- **Base:** `main` @ `a3fe54f` (re-verified unchanged at launch; D-008 ACCEPTED before launch).
- **Wave 1** (parallel, compile/unit/lint-checked in isolation; connected run serially by the owner):
  - Lane R `lane/android2-roomdetail` @ `a3cd34a` — `RoomDetailScreen` (per-light Switch/Slider,
    bridge-aware callbacks, slider clamped 1..100) + Compose UI test.
  - Lane S `lane/android2-scenes` @ `fbf8a71` — `ScenesScreen`/`SceneRow` (exclusive activation,
    `(bridgeId, sceneId)` callback) + Compose UI test. (Initial connected run surfaced a merged-`Surface`
    semantics issue in the test; fixed in-lane with `useUnmergedTree = true` — source untouched.)
  - Lane T `lane/android2-settings` @ `174ddaa` — `SettingsScreen` (`onExitDemo`, `appVersion` literal,
    no BuildConfig) + Compose UI test.
- **Wave 2** (serialized): Lane N `lane/android2-nav-integration` @ `1a419d2` — extended
  `ChromaGlowDestination` + the `when`-router to reach all three screens with demo data; additive
  dashboard entry points (discrete `onOpenRoom` room-name affordance; Scenes/Settings buttons) that left
  `DemoRoomRow`'s Switch/Slider/status-line text intact; `NavIntegrationE2ETest` exercises behavior
  (toggle light, change brightness, exclusive scene activation, exit demo → Setup).
- **Integration:** `integration/parallel-batch-2` @ `4c74beb` — Wave 1 merged first, then Wave 2;
  `--no-ff`, zero conflicts (disjoint by construction).
- **Final integrated gate (all green):** `testDebugUnitTest` **84/0** · `lintDebug` clean ·
  `assembleDebug` ok · `connectedDebugAndroidTest` **33/0** on the headless `Pixel_10` AVD (incl. the
  Batch 1 `ChromaGlowAppTest`/`DemoRoomControlsTest`, still green via additive-only changes).
- **Boundary audit:** each lane changed only its allowed globs; Wave 1 disjoint; only Wave 2 touched the
  §2 nav hotspots. **Deviations:** none (one in-lane test fix in Lane S, no scope change).
- **D-009 correction (2026-06-28 [Claude]):** one serialized lane
  `lane/android2-state-ownership-correction` @ `16810a1` hoisted demo room/light/scene state into
  `ChromaGlowApp` (seeded on demo enter, cleared on exit) and consumed the dashboard/room-detail/scenes
  bridge-aware callbacks, so mutations survive navigation; `DemoModeSession`/`DemoFixtures` and Wave 1
  internals unchanged; in-memory only. `NavIntegrationE2ETest` extended to prove persistence on reopen.
  Merged `--no-ff` into **`integration/parallel-batch-2` @ `9411d81`** (pushed). Re-validated gate all
  green: `testDebugUnitTest` **84/0** · `lintDebug` clean · `assembleDebug` ok ·
  `connectedDebugAndroidTest` **34/0** on `Pixel_10`. Resolves D-009 (see Decision Log).
- **Codex final review:** correction boundary and lifecycle behavior verified; full gate independently
  reproduced green at `9411d81` (84 unit, lint, assemble, 34 connected). D-009 is resolved and Batch 2
  is merge-ready.

---

## 9. Current Pipeline State & Next Steps

- **On `main` @ `7ed6468`** — the Android demo flow is end-to-end: Setup → Dashboard (per-room on/off +
  brightness) → RoomDetail (per-light controls) / Scenes (exclusive activation) / Settings (Exit Demo
  Mode); all demo mutations survive navigation (in-memory, owned by `ChromaGlowApp`). Both pilot batches
  (8 lanes across two batches + two correction lanes) are merged. No batch is in flight.
- **Durable code contracts** (the acceptance baseline for any future change) live in **AGENTS.md →
  "Android Current State"**: model `require(...)` guards; `RoomDisplayModel.lightCount ==
  DemoFixtures.lightsByRoom[id].size`; scenes carry a non-blank `bridgeId` (= `DEMO_BRIDGE_ID`);
  app-owned demo state seeded on demo-enter and cleared on exit; bridge-aware
  `(bridgeId, lightId|sceneId, value)` callbacks; the lightweight `when`-router (not Navigation-Compose);
  `appVersion` passed as a literal (BuildConfig disabled); single `Pixel_10` AVD ⇒ connected tests run
  serially.
- **Pairing decisions accepted:** D-001/D-002/D-011/D-012 are complete. Batch 3 is authorized only for
  protocol, TLS/identity, and HTTPS transport foundations; no UI, credential write, or physical pairing.
- **Next action:** the human may tell Claude to execute the READY Batch 3 launch prompt at
  `docs/coordination/prompts/parallel-batch-3-launch.md`. Integration-to-main remains separately gated.
- **For Codex — verifying what's done:** check out `main` @ `7ed6468` (or compare against
  `integration/parallel-batch-2` @ `9411d81`); the per-batch result records are §7/§8; the full decision
  trail is §6 (D-001–D-013). Run `cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug` and,
  with the `Pixel_10` AVD booted, `connectedDebugAndroidTest` (expect unit 84/0, connected 34/0).
- **For Codex — proposing adjustments / corrections:** append a new Decision Log entry
  (**D-014+**) describing the change; flag any AGENTS.md contract you want to revise. For a later code batch,
  draft a manifest per §5 from the current `main`, map every lane to a §1 registry entry, honor the
  accepted D-001/D-002 boundaries, and route any §2 hotspot edit (nav shell, theme, build,
  manifest, res) through a single serialized lane. Then a launch prompt under
  `docs/coordination/prompts/` makes it executable.

---

## 10. Batch 3 — READY (pairing foundations; not launched)

**Batch:** `parallel-batch-3`

**Pinned base:** `origin/main` @ `7ed64687b600e9456d32510fa86e709c841fefd5`

**Integration branch:** `integration/parallel-batch-3`

**Decision:** D-013 ACCEPTED

**Launch prompt:** `docs/coordination/prompts/parallel-batch-3-launch.md`

### Goal and boundary

Implement a fully tested, non-UI Android foundation for Hue link-button pairing: structured JSON
contracts, private-CA chain and bridge-identity verification, and an HTTPS transport. The batch ends at a
callable/tested transport API. It does **not** modify Setup, app navigation, discovery, credentials, or
persist any token. It performs no live bridge request.

### Dependency graph

```text
W0 (serialized hotspot bootstrap)
  A android3-pairing-bootstrap
        ↓
W1 (parallel from merged W0 integration head)
  B android3-pairing-protocol    C android3-pairing-tls
        └──────────┬─────────┘
                   ↓
W2 (serialized from merged W1 integration head)
  D android3-pairing-transport
```

### W0 — Lane A: dependency and CA bootstrap (serialized)

- **Branch:** `lane/android3-pairing-bootstrap`
- **Owns only:**
  - `android/gradle/libs.versions.toml`
  - `android/app/build.gradle.kts`
  - `android/app/src/main/res/raw/hue_root_bridge.pem`
  - `android/app/src/main/res/raw/hue_root_ca_01.pem`
- **Deliverable:**
  - Add OkHttp `5.4.0` production dependency.
  - Add `kotlinx-serialization-json` `1.11.0` without the serialization compiler plugin; later code uses
    the structured `JsonElement` API.
  - Add test-only MockWebServer3 and OkHttp TLS `5.4.0` dependencies.
  - Copy the exact local CA files from `/Users/brianbean/Desktop/chromaglow-hue-ca/` and verify before
    commit: `hue_root_bridge.pem` SHA-256
    `9eb5d8ee06004a6128659eee9727490387f582112fd6fa8657a3b75e2aef7e44`; `hue_root_ca_01.pem`
    SHA-256 `dfb5bd1e3a46b980f4c1494d96d2670216b4080d7ca1e33c3d4464abb1b363c5`.
- **Forbidden:** all Kotlin source/tests, manifest, other resources.
- **Validation:** `./gradlew dependencies assembleDebug` and `git diff --check`.

Merge W0 into integration before creating W1 branches. Record the resulting integration SHA; W1 branches
fork from that merged SHA, not directly from `main`.

### W1 — Lane B: pairing protocol (parallel)

- **Branch:** `lane/android3-pairing-protocol`
- **Owns only:**
  - `android/app/src/main/java/com/chromaglow/app/core/hue/pairing/protocol/**`
  - `android/app/src/test/java/com/chromaglow/app/core/hue/pairing/protocol/**`
- **Deliverable:** pure Kotlin structured request/response/config contracts using
  `kotlinx.serialization.json.JsonElement`:
  - Create-user request contains only `devicetype = "chromaglow#android"`; never emits
    `generateclientkey`.
  - Parse Hue's JSON-array success (`success.username`, non-blank) without retaining/logging any optional
    `clientkey`.
  - Model error 101 as retryable link-button-not-pressed, error 7 as invalid request, and unknown errors
    explicitly; malformed/mixed inputs and any input over 64 KiB fail closed.
  - Parse `/api/0/config.bridgeid` as normalized uppercase exactly 16 hex characters; parse optional
    `replacesbridgeid` without treating it as the active identity.
- **Forbidden:** network APIs, Android context/resources, TLS, UI, credentials, build files.
- **Validation:** focused JVM tests, then `./gradlew testDebugUnitTest`.

### W1 — Lane C: TLS and bridge identity (parallel)

- **Branch:** `lane/android3-pairing-tls`
- **Owns only:**
  - `android/app/src/main/java/com/chromaglow/app/core/hue/pairing/tls/**`
  - `android/app/src/test/java/com/chromaglow/app/core/hue/pairing/tls/**`
  - `android/app/src/androidTest/java/com/chromaglow/app/core/hue/pairing/tls/**`
- **Deliverable:**
  - Build a trust manager from an injected set of CA certificates only; production resource loading must
    include both accepted Hue roots and no system/user CA fallback.
  - Validate certificate chains and validity normally, then extract exactly one leaf subject CN with a
    structured X.500 parser. Require 16 hex, normalize uppercase, and optionally require equality with an
    expected discovery hint case-insensitively.
  - Provide a narrowly scoped OkHttp identity verifier for SAN-less Hue leaves. It must never return true
    without validating the peer leaf identity contract; chain trust remains enforced by the configured
    trust manager.
  - Tests cover valid trusted leaf, lowercase CN, expected-ID match/mismatch, wrong CA, self-signed leaf,
    expired leaf, malformed/multiple/missing CN, and production raw-resource fingerprints.
- **Forbidden:** protocol JSON, network requests, UI, discovery, credentials, build files, certificate
  generation in production code.
- **Validation:** focused JVM tests, `./gradlew testDebugUnitTest`, compile android tests; connected tests
  run only by the batch owner on the shared AVD.

### W2 — Lane D: HTTPS pairing transport (serialized integration)

- **Branch:** `lane/android3-pairing-transport`
- **Owns only:**
  - `android/app/src/main/java/com/chromaglow/app/core/hue/pairing/transport/**`
  - `android/app/src/test/java/com/chromaglow/app/core/hue/pairing/transport/**`
- **Depends on:** merged Lane B protocol and Lane C TLS APIs.
- **Deliverable:** a small `HuePairingClient` boundary plus OkHttp implementation that:
  - accepts an existing `BridgeEndpoint` as routing input and an optional expected `bridgeid` hint;
  - permits HTTPS only, disables redirects and automatic retry of create-user POST, uses bounded response
    bodies (64 KiB maximum) and a 10-second call timeout; build URLs with OkHttp `HttpUrl`, never string
    concatenation;
  - performs `GET /api/0/config`, obtains authenticated identity from the CA-validated leaf CN, and
    requires config `bridgeid` plus any supplied hint to match case-insensitively;
  - performs `POST /api` with the Lane B request and returns typed success/retryable/failure outcomes;
  - never logs response bodies, usernames, bridge IDs, local addresses, or certificate/device data;
  - never saves credentials and exposes no `clientkey` surface.
  - uses MockWebServer3 + test-only certificates for successful flow, case normalization, type 101 retry,
    type 7, malformed/oversized response, redirect refusal, wrong identity, wrong CA, and timeout tests.
- **Forbidden:** `feature/setup/**`, `app/**`, `core/credentials/**`, `core/hue/discovery/**`, manifest,
  Gradle/catalog, resources, live bridge requests.
- **Validation:** `./gradlew testDebugUnitTest lintDebug assembleDebug`.

### Batch owner gate and promotion

1. Boundary-audit every lane and verify W1 source/test globs are disjoint.
2. Run connected tests serially on the single `Pixel_10` AVD after W2; existing 34 connected tests plus
   the CA-resource test must all pass.
3. Run the full integrated gate:
   `testDebugUnitTest lintDebug assembleDebug connectedDebugAndroidTest`.
4. Scan for `trustAll`, always-true hostname verification, emitted `generateclientkey`, `CLIENT_KEY`,
   token/username logging, and edits outside ownership.
5. Push `integration/parallel-batch-3`; do not merge to `main` without explicit human go-ahead.
6. Batch 3 may promote as a tested foundation despite no runtime UI wiring because it adds no UI. A later
   batch must separately scope Setup state, persistence, and physical-device pairing validation.
