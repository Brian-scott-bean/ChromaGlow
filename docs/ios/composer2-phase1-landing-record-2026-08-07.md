# Composer 2 — Phase 1 Landing Record (2026-08-07)

Governance record for the Composer 2 Phase 1 foundation. This file records what
Phase 1 **is**, what it **is not**, and what remains undecided. It is the
authoritative pointer for anyone asking "where did Composer 2 Phase 1 land, and
what may I rely on?".

## 1. What Phase 1 is

A typed, inert foundation. Five production files that **name** things and one
that **computes** a value. Nothing in the shipping runtime consumes any of them.

| Concern | File |
| --- | --- |
| Flag substrate (5 flags, all `defaultValue == false`) | `HueHome/Core/FlagStore.swift` |
| Canonical typed vocabulary | `HueHome/Core/Composer2Domain.swift` |
| Producer registration contracts | `HueHome/Core/Composer2Registration.swift` |
| Consumer request contracts | `HueHome/Core/Composer2ConsumerContracts.swift` |
| Pure resolver seam | `HueHome/Core/Composer2Resolver.swift` |

The seam:

```
Composer2ConsumerRequest + Composer2ObservedState
        → Composer2Resolver.resolve(...)
        → Composer2Resolution
```

## 2. What Phase 1 is NOT

Phase 1 does **not** provide, and this record does **not** claim:

- physical Hue hardware validation of anything in Phase 1;
- ownership runtime migration;
- runtime arbitration;
- transport selection;
- user-visible Composer 2 behavior or customization;
- execution of any resolution.

The resolver returns a value. It starts nothing, stops nothing, acquires
nothing, releases nothing, enqueues nothing, cancels nothing, mutates no
ownership map or counter, posts no notification, reads no storage and no flag,
and touches no interface state.

## 3. Accepted packet chain

Linear, merge-free, branched from `main` @ `320ebaf6ddd5d82c7c04f31884daaa901f7f4db9`.

| Packet | SHA | Subject |
| --- | --- | --- |
| 1A | `3982bb6795f07078a16c253d65cd4033eee05bb9` | Flag substrate |
| 1B1 | `dfdc39ff80384ad7c649e6a944663d33c673aa33` | REST scheduling characterization |
| 1B2 | `a04854c06603911305098d8adfdb98dd964b4386` | Ownership characterization |
| 1C1 | `ea2d13e4b1ec8b6431b342b5d8c3d4fef4c46797` | Ownership seam characterization |
| 1C2 | `b56988ed247449f54237800b942a8810a8b80c40` | Canonical typed vocabulary |
| 1C2-a | `9fa13cc12b03a04d9cfe49b2352e9d7541ef974a` | Automation producer correction |
| 1C3 | `7e25e71bbca191318e87c9eb9d9dbb4cdc25ef63` | Registration contracts |
| 1C4 | `2b19eda957658c87a01df32b555f357d3287420c` | Typed consumer contracts |
| 1D | `6ead505854317bc8243a73b1dee51be3c5c15820` | Pure resolver seam |

**Final implementation HEAD: `6ead505854317bc8243a73b1dee51be3c5c15820`.**

## 4. Registered baseline

Phase 1D full registered suite: **1573 passed, 0 failed, 0 skipped**, two
consecutive clean runs, counts read via `xcresulttool`.

Composer 2 foundation suites total **171**: `FlagStoreTests` 12 ·
`Composer2RESTCharacterizationTests` 16 · `Composer2OwnershipCharacterizationTests` 17 ·
`Composer2SeamCharacterizationTests` 4 · `Composer2DomainVocabularyTests` 22 ·
`Composer2RegistrationTests` 30 · `Composer2ConsumerContractsTests` 29 ·
`Composer2ResolverTests` 41.

`HueHomeTests/OrchestratorTests.swift` is tracked in git, contains 27 tests, and
remains **unregistered and unrun**. Its tests are excluded from every count
above and are not evidence for anything.

## 5. Zero runtime consumers

Verified by registered source-shape guards and by direct scan of `HueHome/`:

- **`Composer2Flag` / `FlagStore`** — no production consumer. The only file
  naming either is `FlagStore.swift` itself.
- **`Composer2Resolver` / `Composer2ObservedState` / `Composer2Evidence`** — no
  production consumer. The only file naming any of them is
  `Composer2Resolver.swift` itself.
- The vocabulary, registration and consumer-contract guards each pin their
  allowlist by **exact filename** with an anti-vacuity assertion that the
  allowlisted file was really scanned. There is no directory-wide `Composer2`
  exemption, so the first genuine runtime consumer fails a registered test.

## 6. Production-runtime footprint outside the Composer 2 files

Packet 1C1 added **29 lines to `HueHome/Core/Network/UnifiedOrchestrator.swift`** —
the only Phase 1 change to a pre-existing production file:

1. `testCaptureCompositionEntertainmentTask(forBridge:)`, a pure slot read,
   placed inside the **pre-existing** `#if DEBUG` seam block. That block spans
   lines 3453–4119 and is present verbatim at line 3453 in `ea2d13e`'s parent —
   1C1 did not introduce it.
2. One `recordStopAudit(...)` call at `startStudioMode`'s own engine eviction,
   wrapped whole in a `#if DEBUG` that 1C1 **did** add.

**Both are absent from Release.** Independently re-verified on 2026-08-07 by
building `-configuration Release` and scanning the app binary's symbol table
with non-vacuous controls:

| | |
| --- | --- |
| binary | `HueHome.app/HueHome`, 36,100,800 bytes |
| total symbols | 220,154 |
| `UnifiedOrchestrator` symbols | 9,778 (the scan genuinely covers this file) |
| controls, expected present | `startCompositionMode` 232 · `stopCompositionMode` 52 · `canAcquireEntertainment` 10 |
| `testCaptureCompositionEntertainmentTask` | **0** (`nm` and `strings`) |
| `testCanAcquireEntertainment`, `testStageEntertainmentOwner`, `testHasCompositionEntertainmentTask`, `testCompositionRuntimeBridges`, `testAllDayGeneration` | **0** (`nm` and `strings`) |

Phase 1 therefore adds **no Release-compiled runtime behavior** to
`UnifiedOrchestrator.swift`. What Release does gain from Phase 1 is the four
inert Composer 2 value-type files, which have no callers.

This absence is currently proven by a manual Release build, **not** by a
registered guard. Adding such a guard is deliberately deferred (see §8).

## 7. Evidence debt

| # | Item | Disposition |
| --- | --- | --- |
| 1 | **Multi-holder evidence.** `Composer2Evidence<Composer2Producer>` names at most one holder; production can transiently have two on one resource, and third-party reads can show more than one foreign session. | Deferred **until** runtime integration. Expressing it needs either a new `Composer2Contention` case or a precedence rule; neither is decidable while consumers are zero. Naming one of several would be a priority table. Does not block landing. |
| 2 | **`anyBridgeHosting` stop scope** resolves `undetermined`: the target-local observation cannot perform the room→bridge hosting lookup, and inferring one is forbidden. | Deferred **until** runtime integration. Does not block landing. |
| 3 | **Foreign-controller consent.** A foreign holder always yields `requiresUserDecision`; previously granted or consumed consent is not a resolver input. | Deferred **before** runtime integration — must be settled before any producer consumes the resolver, or a consented takeover would re-prompt. Does not block landing. |
| 4 | **Counter absence semantics unproven** for `restScopeEpoch`, `roomOwnership`, `allDayPlayback`. Proven only for `compositionPlayback` and `bridgeNativeOwnership`. | Historical evidence debt; deferred **before** runtime integration. The current answer is fail-closed `undetermined`, which is safe. Tightening requires new characterization evidence. Does not block landing. |
| 5 | **Resolver ordering normalization.** Currency/staleness is evaluated before target emptiness, uniformly for both request shapes. Production's stop paths check absence first and consult no counter there. | Recorded, no action. This is a deterministic normalization chosen for reviewable totality, is strictly fail-closed, and is **not** a claim that existing runtime paths behave that way. Does not block landing. |
| 6 | **Phantom suites.** `EntertainmentOwnershipTests` and `EntertainmentRoomSelectionTests` do not exist. They were cited in the accepted 1B2 artifact. | Historical evidence debt. The citation is **void** and must not be relied on. 1B2 is **not** rewritten to erase it — the accepted artifact stands as written, with this record as the correction. Does not block landing. |
| 7 | **`OrchestratorTests.swift`** — 27 tracked but unregistered tests. | Brian decision required on registration. Excluded from all counts. Deliberately not expanded in the landing packet. Does not block landing. |
| 8 | **DEBUG-absence has no registered guard** (see §6). | Deferred to a separate hardening or runtime-integration packet; it changes the test surface and would break the governance-only boundary. Does not block landing. |

## 8. Unresolved product policy

Phase 1 deliberately answers **none** of the following. They are recorded, not
decided, and each requires Brian:

manual-control ownership duration · manual versus Composer precedence · whether
Widget/Siri acquire ownership · Studio/Composer coexistence · All-Day
coexistence · general producer precedence · transport-selection policy ·
cross-runtime stopping rights · **automatic replacement** · Entertainment
coexistence · light → room implication · runtime arbiter topology · scheduler
unification · stop-scope correction · manual claim model.

That is **fifteen** items. `automatic replacement` — whether a producer's new
work may displace existing work on the same resource, including its own — is
listed here because it **remains unresolved**. Phase 1D deliberately refuses to
answer it.

What was explicitly decided was the refusal, not the policy. `resolveIntent`
does not compare a request's origin to the observed holder — it does not receive
the request at all — so an occupied target yields `requiresRelease` for every
in-app holder, **including when the holder is the origin**. That states only the
necessary condition: the hold must end. It does not decide whether that release
may later happen automatically, who may cause it, or whether anyone is asked
first. Letting self-replacement proceed would have answered this question in
code; declining to compare leaves it open for the runtime-integration packet.

None of these blocks landing, because inert code with zero consumers decides
nothing. All of them block **runtime integration**.

The resolver's own refusals are structural, not accidental:

- it never compares the request's origin to the observed holder for an intent —
  `resolveIntent` does not receive the request at all;
- it uses producer equality only for stops, and the verdict is symmetric under
  swap, so no producer outranks another;
- it names no transport type and no target type, so it cannot select a transport
  and cannot map a light to its room;
- it answers a held target with `requiresRelease` even when the holder is the
  origin, so no automatic replacement is encoded anywhere.

## 9. Landing status

**Not landed. Nothing merged. Nothing pushed.**

- Topology: **Option A** — preserve the accepted stack, no rebase, squash, or
  rewrite. `main` is the merge-base, the chain is linear and merge-free, and no
  commit exists on `main` that Phase 1D lacks, so a fast-forward is available and
  all nine accepted SHAs stay intact.
- Sequencing: **Composer 2 Phase 1 before Track A**, which preserves that
  fast-forward. Landing Track A first would move `main` and cost it.
- Track A (`fix/unified-rolodex-host`, PR #61) is **untouched**: not checked out,
  edited, merged, closed, rebased, retargeted, or pushed. Its sequencing remains
  Brian's decision.
- Final landing requires a separate, explicit authorization from Brian.

## 10. Next boundary

The next packet is **runtime integration**, and it is the first packet in this
program that may change shipping behavior. Before it begins:

- the policy items in §8 that its scope touches must be decided by Brian;
- evidence debt items 3 and 4 should be closed;
- `Composer2Flag` gains its first real consumer, so every flag's default and
  rollback path becomes load-bearing.

Until then the honest statement is: **Composer 2 Phase 1 is a typed foundation
with zero runtime consumers, and no Composer 2 behavior ships.**
