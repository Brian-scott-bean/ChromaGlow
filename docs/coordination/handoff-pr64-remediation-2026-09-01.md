> **Historical record (superseded 2026-09-01).** This handoff was written by the outgoing Claude session for the incoming one. The private plan path in the first paragraph belongs to an account that is no longer accessible and is not needed; §11 was executed by the successor session (`https://claude.ai/code/session_01Th5ub6JekJVJGsyxYavJzV`), whose fifth review round and final validation are recorded in the `2026-09-01 [Claude] PR #64 remediation` DEVLOG entry and in PR #64's body. Kept, unedited below, as the factual record of the handoff state; it follows the `docs/coordination/prompts/` convention of tracking agent handoff prompts.

# HANDOFF — PR #64 remediation (Slice 2 Studio instrument) — 2026-09-01

Written by the outgoing Claude orchestrator session for the incoming one. Read this whole file, then
`AGENTS.md`, `CLAUDE.md`, the DEVLOG "Current Status Snapshot", and the plan file at
`~/Library/Application Support/CNVS/claude-accounts/cec652db/plans/important-use-the-large-foamy-giraffe.md`
(the approved remediation plan, R1–R5 + decisions). Then resume at **§6 "What to do next"**.

## 0. Mission and hard rules (unchanged)

Take PR #64 (`feat/unified-customization-studio-instrument` → `main`) from "blocked in review" to an
independently verified **SAFE TO MERGE**, push, rewrite the PR body, and hand Brian a decision packet.
Rules: **do not merge PR #64**; do not touch `main`; do not start Slice 3; preserve `.cnvs/`,
`.cursor/mcp.json` and other developer-local files (now gitignored); ≤3 Hz flash safety is
non-negotiable and must be a realized-on-the-wire invariant; unknown ≠ unsupported; `.staged` is
editable exactly as spec §17 defines; no Composer semantic changes (the composition render loop is
out of scope — see debt); every fresh BLOCKER/HIGH from an adversarial pass must be fixed and
revalidated before declaring SAFE TO MERGE; one shippable commit per coherent fix; Claude attribution
footer + session link on commits (this session:
`https://claude.ai/code/session_01MnE1h4jgoXYFV8RdWiuMob`; use your own).

## 1. Ground truth at handoff

- Branch `feat/unified-customization-studio-instrument`, base `ca074b85` (= `origin/main`).
- Reviewed head at start: `89de143`. **Nothing has been pushed.** `origin` still at `89de143`; PR #64 is
  OPEN, base `main`, body NOT yet rewritten.
- Rollback tag (local): `checkpoint/pre-slice2-remediation-2026-09-01` = `89de143`.
- **Seven local commits** on top of `89de143` (all validated; messages are the factual record):

| Commit | What |
|---|---|
| `c8c801f` | Restore the 8 `.cursor` rule/skill files deleted as collateral in `909dc47`, with narrow factual patches |
| `910c861` | Flash safety as a realized-frame invariant (FlashSafety plans, per-bridge OnsetLedger, 2.94 Hz ENT lock ceiling, FlashSafetyTests) |
| `f2f7a19` | One board availability funnel (`StudioBoardAvailability`), colour resolved like every control |
| `10c2301` | Matrix citation verification, proven-count split, Guards 14/15, re-hardened Guard 12/13 anchors |
| `7d8d14e` | Lifecycle FIFO serialization, runtime-event seams (session lost / composition fallback), coalesced sends, Preview Live production tests |
| `2200e98` | First adversarial review round closed (Party rise gate, 0.34 s ledger, trap guards, evidence notes, CHECKING recovery, gesture belt, grouped PUT split, box-fenced failover, identity probe, preview refusals…) |
| `119aa4b` | Second round closed (wire-level emit gate, frozen instance bases, unknown never refuses, mixed-room narrowing, failover generation re-check, PUT order by commit, Guard/generator hardening, .gitignore) |

- Full registered suite evidence (xcresult, `xcrun xcresulttool get test-results summary`):

| Tree | Run | passed / failed / skipped |
|---|---|---|
| `7d8d14e` (pre-review-fix) | 1, 2 | 1844 / 0 / 0 (×2) |
| `2200e98` | 3, 4 | 1883 / 0 / 0 (×2) |
| `119aa4b` | 5, 6 | **1935 / 0 / 0 (×2)** |

  Bundles were in the session scratchpad
  (`/private/tmp/claude-501/-Users-brianbean-Desktop-huehome-pro-v0-3-0/a93fbb95-…/scratchpad/full{1..6}.xcresult`);
  copies of runs 5 and 6 are at `~/Desktop/pr64-xcresults/` if that directory exists. If gone, re-run
  the suite twice on the final tree anyway (required below).
- Baseline before remediation: 1782/1782. Slice 2 catalogue: 68 controls.

## 2. Uncommitted working tree at handoff — READ CAREFULLY

`git status` shows modified files in three groups:

**(a) Docs (safe, ready; only placeholders left):** `DEVLOG.md`, `docs/ios/unified-customization-capability-audit-2026-08-19.md`,
`docs/ios/unified-customization-execution-plan-2026-08-19.md`, `docs/ios/master-on-device-checklist.md`,
`UNIFIED_CUSTOMIZATION_SPEC.md`, `HueHome/Core/CustomizationCapability.swift` (header comment only).
Placeholders to fill at the end: `<<HEAD>>`, `<<FULL1>>`, `<<FULL2>>`, `<<GUARDS>>` in DEVLOG (snapshot + entry validation table)
and in the PR body draft `docs/coordination/pr64-body-draft-2026-09-01.md` (`<<XCRESULT>>` too).

**(b) Third-round fixers' work — IN FLIGHT when this session ended (may be complete or mid-edit):**
three Opus fixers were running with disjoint file ownership. Their edits are in the working tree,
uncommitted. They may have been killed mid-edit when the session ended. Files:

| Fixer | Owned files | Task (from the third adversarial pass) |
|---|---|---|
| **F10 lifecycle round 3** | `StudioViewModel.swift`, `StudioViewModel+CustomizationWiring.swift`, `CustomizationValueScopes.swift`, `UnifiedOrchestrator.swift` (only `failCompositionEntertainmentToREST`), `CustomizationCapability.swift` + `CustomizationSnapshotBuilder.swift` (effect-specific v2 coverage fields), tests `StudioPreviewLiveProductionTests`, `StudioProductionWiringTests`, `StudioLifecycleSerializationTests` | H1 `setDefaults(live.layered(over: defaults))` at seedApplyCurrentLook + restore (sparse live set was DELETING newer defaults); H2 effects_v2 body carries only the later-committed of base_color/warmth (+speed); M1 confirmation cores set `isAuditionInFlight` around their replay when an audition is armed; M2 `pendingRestoreRollback` for a deferred restore later refused; M3 wrap the three literal `runningEffects.removeValue` sites' `notePreviewRowRemoved` in `if runningEffects[key] != nil`; M5 failover removes `studioEntClients[bridgeID]` only if `=== entClient`; L2 cancels use `releaseDeferredPreviewIfUnresolved`; tests for confirmAreaChoice/confirmStudioHandoff defers; failover source-shape test asserts capture before first await; **plus** effect-specific `effectsV2` coverage in `targetSnapshot(for:)` (lights whose `effect_values` contain THIS effect) and optional `effectV2ColorLights`/`effectV2CTLights` intersection counts on `CustomizationTargetSnapshot`. |
| **F11 flash round 3 (wire truth)** | `BeatBinding.swift`, `HueEntertainmentClient.swift` (send/sendUniform return `Bool` = handed to transport), `UnifiedOrchestrator.swift` flash regions (ledger, `emitGatedFrame`/`emitOnsetFrame`, three `run*Entertainment` loops, call sites), `FlashSafetyTests.swift`, Guard 14 | BLOCKER B-1: `emitGatedFrame` recorded/stamped BEFORE a send that the DTLS client silently drops during reconnect → ledger ran ahead of the wire; fix = reserve/commit (decide under lock, send, commit+stamp only on delivery; on drop roll back and forget the wire; first frame after a forgotten wire with a prior stamp is a candidate whose hold is BLACK); H-1/H-2/M-3: measure the 10 % threshold in RELATIVE LUMINANCE (Y = ((100·bri+16)/116)^3 × chromaticity luminance factor from xy→linear RGB normalized to max drive; white≈1, blue≈0.07), colour steps governed by luminance except saturated-red steps; drop `lastAdmittedBrightness` exemption if the luminance model makes it unnecessary; H-3 stamp after send; tests: `onsetsOnTheWire` independent luminance measurement, WireModel with dropped frames, reconnect scenarios for all three loops, storm skip/beat-wait measured on emitted frames, non-vacuous floor helper, pinned constant values; Guard 14: commit-after-send ordering, `-> Bool` on sendUniform, luminance symbols. |
| **F12 colour/tooling round 3** | `StudioBoardAvailability.swift`, `StudioBoardView.swift`, `StudioBoardAvailabilityTests.swift`, `generate_capability_matrix.py`, `hardening_guards.sh` Guard 13(c) + Guard 15, `.gitignore` comment | Narrowing uses the intersection counts F10 adds (fallback `min`); unverified-but-active controls at FULL opacity (caption only; M-7); note `lineLimit(3)`, shortened "UNVERIFIED HERE" when joined with a coverage count; remove dead `case .active, .hidden` arm; Guard 13(c) `.horizontal` exclusion anchored to the ScrollView token; generator `verify_send_path` searches the string-stripped text; Guard 15(k) pins `let interactive = StudioBoardAvailability.isInteractive(` / `let opacity = StudioBoardAvailability.opacity(` (anti-shadowing); `.gitignore` comment mentions SKILL.md. |

**How to triage (b):**
1. `git diff --stat 119aa4b` and read each fixer's diff against its task above.
2. `xcodebuild build-for-testing …` (see §8). If it fails, inspect: an incomplete fixer edit is the
   likely cause. Finish it (preferred — the tasks are fully specified above) or, if hopeless, revert
   just that lane's files with `git checkout 119aa4b -- <files>` and redo the lane with a fresh
   agent. Never reset the whole tree; the docs group (a) must survive.
3. Run the focused suites per lane, then `./Scripts/hardening_guards.sh`,
   `python3 Scripts/generate_capability_matrix.py --refresh-citations` (orchestrator line numbers move
   with every loop edit) then `--check`, `git diff --check`.
4. Commit the round-three batch as ONE commit (`fix(studio): third review round - …`) with a message
   in the style of `2200e98`/`119aa4b` (read them with `git show -s`).

**(c) Tooling/gitignore:** `.gitignore` (three entries + F12 comment), `Scripts/*` (F11/F12 edits).

`docs/coordination/pr64-body-draft-2026-09-01.md` is the PR body draft (copied from the scratchpad; untracked — commit it
with the docs or delete after `gh pr edit`). It needs the round-three section and placeholder fill.

## 3. Decisions already made (do not re-litigate)

1. ENT beat-lock ceiling `entertainmentMaxLockHz` = 1/(17×0.02) = 2.94 Hz is an implementation consequence of the
   ≥17-frame realized invariant (Brian confirmed). Bands that step up a division: ×1 (176.47,180] = 3.53 BPM,
   ×½ (88.24,90] = 1.76 BPM, ×¼ (44.12,45] = 0.88 BPM.
2. `.staged` = editable + saved + not affecting output, rendered with the STREAMING ONLY note (spec §17). Numeric
   controls aligned to the same rule.
3. Lifecycle mutations run through one global FIFO (`serialized{}`) with a task-local re-entrancy marker; nested
   calls run inline; engine tasks are spawned with the marker reset.
4. SSE reconnect and capability refresh do NOT rekey (ownership argument in `CustomizationIdentity.swift`);
   transport fallback and session loss do (`StudioRuntimeEvent`, synchronous, box-fenced).
5. Sends are coalesced per target into one mailbox closure; the exclusive xy/mirek pair is ordered by commit.
6. Preview Live is refused over a composition with a live box or a recovered row; a fenced cancel restores nothing
   and says so (`PreviewLiveCopy.restoreDropped`) — recorded spec §16.5 deviation.
7. Flash gate lives at the WIRE (per-bridge ledger tracks last emitted frame + trough since last admitted onset;
   every ENT frame goes through `emitGatedFrame`; no direct `sendUniform` in the loops). Storm afterglow floored
   at the ambient level. First frame of a ledger's life emitted unconditionally, stamped if bright.
8. Composer/Perform-pad strobe on the 25 fps composition render loop (`CompositionMixer` + `runCompositionEntertainment`)
   is **pre-existing on main and out of scope** (Composer semantics rule). Recorded as HIGH debt in DEVLOG/PR;
   recommend a Slice 3 ticket to route that loop through the same ledger.
9. `EffectEngine.swift` loops are dead code with unsafe ranges — delete in Slice 3 (debt).

## 4. Accepted-as-documented findings (already in DEVLOG/PR drafts)

Cross-bridge composite cadence is per bridge by design; the ledger stamps admission (F11 moves it to after the send);
min_brightness > brightness ramps inside a gated cycle; `showsEntOnlyHint` still compiled in dead
`StudioParamControls.swift`; membership staleness is a named gap in the no-rekey proof; `.capabilityUnreadable`
reason reserved (renders like unknown); `.effectsV2Unavailable` reachable only from unsupported; Guard 12(d)/15(k)
are structural pins with known bypass classes (behaviour pinned by tests); `git ls-files -ci` lists 67 `android/`
files because of the pre-existing root `.gitignore` `ChromaGlow/` rule + case-insensitive FS (pre-existing, not
touched — worth a separate fix); Warmth authoring range is still the catalog's 153…500 (Slice 3 debt, checklist row 58);
hardware rows §V-B 37–64 all UNPROVEN.

## 5. Third-pass MEDIUM/LOW still open (record, don't expand)

From the flash pass: M-4 test measurement re-implements the definition (F11 replaces with a luminance-based
independent measurement); L-3 `Int(floor)` in `cycleIndex`/`beatIndex` totality is inherited from upstream clamps.
From the lifecycle pass: M4 failover residual window when a successor is still inside `prepareEntertainment`
(successor's generation wins; documented); L1 `stopEffect` retires scopes before the recovered early return;
L3 reset resurrection via a sibling's frozen base. From the colour/tooling pass: M-2 narrowing skipped when
`effectsV2` evidence is unread (consistent today); M-3/M-4 guard bypass classes; M-8 android ignore rule;
L-5/L-6 unknown renders pixel-identical to a refusal (copy differs; retry is implicit via
`capabilityInventoryGeneration`); L-8 `.hidden` reachable from tests only; L-10 setup-slider caption when the card
runs in another room.

## 6. What to do next (in order)

1. Triage §2(b) (finish/verify F10, F11, F12); commit round three.
2. Refresh citations, `--check`, guards, `git diff --check`.
3. Full registered suite **twice** on the final code tree (nohup pattern, §8); record counts from xcresult.
4. Final targeted adversarial pass (fresh Opus reviewers, read-only) on the round-three diff only: flash wire truth
   (reserve/commit, luminance model, reconnect scenarios), lifecycle (layered copy-back, v2 exclusive pair,
   chained-audition replay, deferred restore rollback), colour narrowing (effect-specific coverage,
   intersections), guards/generator. Fix any BLOCKER/HIGH, re-run suite ×2.
5. Fill placeholders in DEVLOG + PR body (HEAD, run counts, `hardening_guards: all guards passed.`,
   `capability matrix: N citation(s) verified, doc up to date`, xcresult paths). Add a "Fourth round" paragraph
   if step 4 changed code. Commit docs (`docs(studio): record PR #64 remediation …`).
6. `git push origin feat/unified-customization-studio-instrument` (and the checkpoint tag).
7. `gh pr edit 64 --body-file docs/coordination/pr64-body-draft-2026-09-01.md` (keep DO NOT MERGE banner top and
   bottom); verify `gh pr view 64 --json state,baseRefName,headRefOid,mergeable` (OPEN, base main, new head).
8. Decision packet to Brian (format in the original task prompt: FINAL VERDICT / FINAL HEAD / COMMITS / TEST
   TOTAL / XCRESULT EVIDENCE / GUARDS / BLOCKER 0 / HIGH 0 / MEDIUM / LOW / HARDWARE UNPROVEN / PR URL). Then STOP
   and wait. Do not enable auto-merge. If capacity remains, read-only Slice 3 preflight research only.

## 7. Swarm pattern that worked

- Research/review: many parallel read-only Opus agents; each must classify BLOCKER/HIGH/MEDIUM/LOW with file:line and
  a concrete scenario; the orchestrator independently inspects every BLOCKER/HIGH before accepting.
- Writers: disjoint file ownership, orchestrator edits last with re-read, Guard regions split by guard number,
  pbxproj edits as an atomic python read-modify-write with unique ID prefixes (`A1D000xx…`).
- Every fixer validates with its own `-derivedDataPath` and its own simulator UDID; the orchestrator runs the
  full suite. Simulators used: `9DFCA074-75AD-41E4-9EF9-20811FD44585`, `76B14B66-1234-495A-B352-4BD35B785131`,
  `005EBEC4-ECF0-4E2C-8A9C-5389006C2A36` (all "iPhone 17 Pro").
- Docs writer resumed by `SendMessage` with the new commit's facts each round; numbers always re-verified with
  `grep -c "func test"` (note `CustomizationResolverTests.swift` holds two classes: 26 + 5).

## 8. Commands

```bash
# build for testing (own DerivedData)
xcodebuild build-for-testing -project HueHome.xcodeproj -scheme "HueHome 1" \
  -destination 'platform=iOS Simulator,id=9DFCA074-75AD-41E4-9EF9-20811FD44585' -derivedDataPath <DD> -quiet
# focused
xcodebuild test-without-building … -only-testing:HueHomeTests/FlashSafetyTests -resultBundlePath <path>.xcresult
# full suite, detached (the harness kills long foreground runs)
nohup /bin/zsh -c "xcodebuild test -project HueHome.xcodeproj -scheme 'HueHome 1' -destination 'platform=iOS Simulator,id=9DFCA074-75AD-41E4-9EF9-20811FD44585' -derivedDataPath <DD> -resultBundlePath <path>.xcresult -quiet > <log> 2>&1; echo \$? > <flag>" >/dev/null 2>&1 & disown
xcrun xcresulttool get test-results summary --path <path>.xcresult
./Scripts/hardening_guards.sh
python3 Scripts/generate_capability_matrix.py --refresh-citations && python3 Scripts/generate_capability_matrix.py --check
git diff --check
```
Ignore `(ipc/mig) server died` lines in the test log (simulator-clone noise; the xcresult verdict is authoritative).
Delete `Scripts/__pycache__` if it appears (now gitignored).

## 9. Key symbols (for orientation)

`BeatMath.FlashSafety` (BeatBinding.swift): `entertainmentMaxLockHz`, `minCycleFrames`, `cycleFrames`, `splitFrames`,
`StrobePlan`/`PartyPlan`/`ThunderstormPlan.Budget`, `OnsetGate`/`OnsetLedger` (`admit`, `WireFrame`, `FrameVerdict`,
`onsetRiseThreshold`), `clampedInt`. Orchestrator: `studioFlashOnsetLedgersByBridge`, `emitGatedFrame`,
`emitOnsetFrame`, `StudioRuntimeEvent`/`studioRuntimeEventHandler`, `capabilityInventoryGeneration`,
`seedRawLightCache(replace:)`. VM: `serialized{}`/`StudioLifecycleContext`, `applyCore` + `*Core` wrappers,
`handleStudioRuntimeEvent`, `pendingParamSends`/`inFlightParamSends`/`retirePendingSends`,
`beginPreviewLiveCore`/`cancelPreviewLiveCore`/`notePreviewAuditionOutcome`/`releaseDeferredPreviewIfUnresolved`,
`removeRunningRow`, `hasPendingLifecyclePrompt`. Scopes: `frozenBases`, `stopRunning(atPlace:)`. Board:
`StudioBoardAvailability` (`resolve`→`StudioBoardResolution`, `isInteractive(resolution:strategy:)`,
`opacity(resolution:strategy:)`, `note(for:strategy:isColor:)`, `rendersControl`, `narrowedToEffectsV2Coverage`).
Guards: 14 = `slice2-r1` (flash), 15 = `slice2-r2` (availability funnel).

## 10. Late updates (after §2 was written)

- **F12 (colour/tooling round 3) FINISHED and reported green** on its own lane: all 8 items done; StudioBoardAvailabilityTests 41 → 47 (97/97 across its four suites); Guard 13(c) anchor, Guard 15(k) anti-shadowing pin and generator `verify_send_path` subscript-key check all mutation-tested. Decision it made (documented in source): a bridge-native colour/warmth control whose effect-specific v2 reach ∩ capability is 0 resolves `.unavailable(.partialHardwareCoverage, .addCapableLights)` with copy "NO LIGHT HERE RESPONDS TO THIS" (a 0-of-n partial would be a live knob doing nothing). Unverified-but-active controls now render at FULL opacity (caption only). F12 saw guard/matrix failures only from F11's in-flight orchestrator/BeatBinding edits (`slice2-r1`, citation drift) — expected to clear once F11 lands; run `--refresh-citations`.
- **F10 (lifecycle round 3) and F11 (flash wire truth) had NOT reported** when the session ended — treat their files per §2(b) triage. F10 had already landed the `effectV2ColorLights`/`effectV2CTLights` snapshot fields (F12 built against them).
- **F10 (lifecycle round 3) FINISHED and reported green**: all items done (H1 layered copy-back, H2 v2 body carries only the later-committed xy/mirek member, M1 `withDeferredAuditionInFlight`, M2 `pendingRestoreRollback` + `resolveDeferredRestoreRollback`, M3 guarded literal sites, M5 client removal only if `=== entClient`, L2 cancels via `releaseDeferredPreviewIfUnresolved`, effect-specific `effectsV2` coverage via `runningEffectV2Name:` in `CustomizationSnapshotBuilder` + `effectV2ColorLights`/`effectV2CTLights`). 11 new tests; 534/0/0 on its ten suites, mutation-checked (reverting the six fixes kills exactly 7 tests). CAVEAT: F10 validated on an isolated copy because the live tree's `FlashSafetyTests.swift` did not compile while F11 was mid-edit — re-run its suites on the live tree once F11 lands. It did NOT run `--refresh-citations` (owed after the orchestrator settles).
- **Only F11 (flash wire truth) is unconfirmed.** If `FlashSafetyTests.swift` / `BeatBinding.swift` / the orchestrator flash regions / `HueEntertainmentClient.swift` do not build, F11 was cut off — finish per §2(b) F11 spec or revert those four files to `119aa4b` and redo the lane.
- **F11 (flash wire truth) FINISHED and reported green** — so ALL THREE round-three lanes are complete in the working tree. F11: `send`/`sendUniform` return `Bool` (delivered); `OnsetGate.admit` → `Reservation`, `commit(_:delivered:at:)` (stamp moves to delivery time; a dropped frame rolls back and `forgetWire()`), `emitGatedFrame` returns `GatedFrameOutcome { verdict, delivered, landedOnWire }` in strict reserve→send→commit order; luminance model (`WireFrame.relativeLuminance` = L*-cube dimming × sRGB-primaries chromaticity factor: white 1.0, red 0.2126, blue 0.0722, storm ambient 0.176); rule 1 = luminance rise ≥ 0.10 above the trough since the last admitted onset; rule 2 = saturated-red chroma step with ≥ 0.02 luminance change; `lastAdmittedBrightness`/`onsetVisibleBrightness` removed; `emitOnsetFrame` ends on delivery and exits on terminal failure. FlashSafetyTests 54 → 69 (independent luminance measurement, dropped-send WireModel, 2040-scenario reconnect sweep); 165/165 on its seven suites; Guard 14 11/11 mutations caught. Debt: Composer render loop still discards the delivery Bool and has no ledger (out of scope by instruction); rollback is identity-guarded so a rare concurrent-admit interleaving keeps a slightly-late stamp (conservative).
- **Therefore §2(b) triage reduces to:** build the live tree once (all lanes converged), run the three focused sets (flash 7 suites; colour 4; lifecycle 10) on the LIVE tree, `--refresh-citations` → `--check`, guards, `git diff --check`, then commit round three as one commit and continue at §6 step 3.

## 11. FINAL STATE (supersedes §1/§2/§6 where they differ)

- **Eight local commits**: the seven in §1 plus **`14a0cac` fix(studio): third review round** (all three round-three lanes,
  committed after the converged live tree compiled and `--refresh-citations`/`--check`, `hardening_guards.sh`,
  `git diff --check` all passed). Read `git show -s 14a0cac` for the factual record.
- **Uncommitted = docs only**: `DEVLOG.md`, `UNIFIED_CUSTOMIZATION_SPEC.md`, `docs/ios/master-on-device-checklist.md`,
  `docs/ios/unified-customization-capability-audit-2026-08-19.md`, `docs/ios/unified-customization-execution-plan-2026-08-19.md`,
  plus untracked `docs/coordination/handoff-pr64-remediation-2026-09-01.md` and `docs/coordination/pr64-body-draft-2026-09-01.md`.
  Note `HueHome/Core/CustomizationCapability.swift` (header comment from the docs lane) went into `14a0cac` with F10's field additions.
- **Not yet done on the `14a0cac` tree**: the focused suites on the LIVE converged tree (each lane ran them on its own tree state) and
  the full registered suite ×2. The last full runs (1935/0/0 ×2) were on `119aa4b`; expect ~+30 tests on `14a0cac`
  (FlashSafety +15, BoardAvailability +6, Wiring +5, PreviewProduction +6 = 1967 registered, verify by xcresult).
- **Resume here**: run the three focused sets on the live tree → full suite ×2 (nohup) → final targeted adversarial pass on
  `git diff 119aa4b..14a0cac` (flash wire truth, luminance model, layered copy-back, v2 exclusive pair, chained/deferred
  audition, effect-specific reach; fix BLOCKER/HIGH, rerun) → add a "Fourth round" paragraph to DEVLOG/PR body only if code
  changed → fill placeholders (`<<HEAD>>`, `<<FULL1>>`, `<<FULL2>>`, `<<GUARDS>>`, `<<XCRESULT>>`) → commit docs (include the
  two `docs/coordination/` files) → push branch + checkpoint tag → `gh pr edit 64 --body-file docs/coordination/pr64-body-draft-2026-09-01.md`
  → verify PR open/base/head → decision packet → STOP. Do not merge.
