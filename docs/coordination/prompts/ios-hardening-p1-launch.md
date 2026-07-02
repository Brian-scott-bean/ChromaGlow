# iOS Hardening — Phase P1 Launch Prompt

> Standalone launch prompt for a fresh Claude Code agent to execute **Phase P1** of the
> iOS security-hardening + quality remediation. A fresh agent needs only the repo + this file.
> Phase P0 is already merged to `main` @ `aca0d77`. Prepared 2026-07-02 by Claude after P0 shipped.

---

You are Claude Code (Fable 5), taking over **Phase P1** of the iOS security-hardening + quality remediation for the **ChromaGlow** app (a native Swift/SwiftUI Philips Hue controller; historical names HueHome / LightShade / CastChroma still appear in code). Phase P0 is already merged to `main`. Your job is to execute P1 — reliability of the flagship real-time features + credential-surface reduction — local-first, so the human can test on a physical Hue bridge before anything merges.

## 0. Orient yourself first (before touching code)

Read, in order, from the repo root `/Users/brianbean/Desktop/huehome-pro-v0.3.0`:

1. **`AGENTS.md`** — canonical project context (guardrails, Security Rules, iOS Engineering Rules, Hue API Rules, identity values, validation commands). This overrides your defaults.
2. **`DEVLOG.md`** — read the "Current Status Snapshot" at the top, then the latest `[Claude]` entries. The most recent is the **P0 hardening remediation** entry (privacy manifests, log scrub, TLS pinning) — that is the work you are building on. Do not repeat or regress it.
3. **`docs/audit/hardening-audit-2026-07-01.md`** — THE SOURCE OF TRUTH. Every finding has a stable ID (H-01…H-06, M-01…M-19, L-01…L-55, I-01…I-16) with a **file:line, a concrete failure scenario, and a recommended fix**. Read each P1 finding there in full before implementing it — this prompt names the IDs but the audit carries the exact detail. §4 lists verified-good hardening you must NOT regress; §5 is the roadmap; §6 lists the regression tests to add.
4. **`docs/coordination/parallel-agent-pipeline.md`** — the Decision Log. P0 recorded/closed **D-016** (TLS pinning), **D-017** (no-secrets-in-logs), **D-019** (privacy manifests). **D-018 (Keychain access group) is still PROPOSED — you implement it in P1 (item 1); append a dated `[Claude]` implementation turn.** D-020 (Android CI) is out of scope for you.
5. Skim `docs/ios/persistence-and-credentials.md`, `docs/ios/hue-contract-inventory.md`, and `.cursorrules` for iOS-area context.

Then confirm the toolchain: run `xcodebuild -version`. Xcode 26.4 with an iPhone 15 / iOS 17.0 simulator is expected on this machine. If Xcode is absent (e.g. a Linux runner), make surgical, inspection-correct changes with tests and **clearly flag in your handoff that a macOS build + test + on-device pass is mandatory before merge** — do not claim validation you didn't run.

## 1. Current repo state (what P0 already did — do not redo or break)

- **`main` is at merge commit `aca0d77`**, synced to `origin/main`. P0 (privacy manifests M-03, log scrub H-03/H-04/L-09, TLS pinning H-01/H-02/M-01/H-06) is merged and on-device-tested. Marketing version `0.9.0`, **build number is now `2`**.
- A safety tag **`pre-hardening-2026-07-01`** marks the pre-P0 state (pushed to origin).
- **New TLS trust module** lives at `HueHome/Core/Network/Trust/`:
  - `BridgeTrustEvaluator.swift` — `BridgeTrust.verdict/pairingCapture/evaluateChain`, `BridgePin`, `PairingLeafCapture`. Identity = uppercase-16-hex bridgeid CN + SPKI pin.
  - `HueBridgeTrustRoots.swift` — the two bundled Signify/Hue root CAs (DER), fingerprint-asserted by a test.
  - `BridgePinStore.swift` — pins persisted in **Keychain (authoritative) + App Group UserDefaults mirror + standard UserDefaults + WCSession** (storage key `hue_bridge_tls_pins_v1`). Pins are public key material, not secrets.
  - `BridgePinnedTrustDelegate.swift` — the ONE data-plane URLSession delegate (`.shared`); `BridgePairingTrustDelegate` (TOFU capture at pairing); `BridgePinAcquirer` (`ensurePins` migration from `loadAll`, `validateAndPersist` gate, `acquirePin`). Silent migration requires CA-attestation; interactive pairing may pin self-signed.
- All five former trust-all delegates are gone; every bridge URLSession uses `BridgePinnedTrustDelegate.shared`. **Do not reintroduce a trust-all delegate or a raw `.useCredential` outside the Trust module.**
- **`Scripts/hardening_guards.sh`** exists with 3 guards (privacy manifests; `privacy: .public` on secret/PII interpolations + token in `appendLog` + v1 URL logging; `.useCredential` outside the Trust module + discarded `SecTrustEvaluateWithError`). **Run it after every phase; extend it (item 3 below).**
- Tests added in P0: `HueHomeTests/SecretLogScrubTests.swift`, `HueHomeTests/BridgeTrustEvaluatorTests.swift`. Keep them green.
- **Pins interaction with your item 1:** P0 deliberately mirrors pins to App Group + standard UserDefaults so the widget/Siri/watch can read them. Your Keychain-access-group work (D-018) must move **both credentials and pins** into the shared access group and drop the plaintext-token UserDefaults writes — see item 1.

Facts you will need, already verified:
- **`hueClient(for: bridgeID)` is defined at `HueHome/Core/Network/UnifiedOrchestrator.swift:2817`** and is the correct per-bridge client resolver. **`primaryAPIClient` (= `clients.values.first`, nondeterministic) has ~10 references** — the wrong-bridge bug class.
- **`RestSender` (latest-wins mailbox) is an `actor` defined at `HueHome/UI/Sync/SyncModeEngine.swift:46`**, used there and in `UnifiedOrchestrator`/Studio. Extend it to the paths that bypass it; never remove it.
- **`BridgeRecord.id` is a random `UUID`, not the Hue 16-hex bridgeid** (`HueHome/Core/Models/HueDataModels.swift`). The canonical bridgeid lives only inside `BridgePin`.
- Entitlements files: `HueHome/HueHome.entitlements` (has `application-groups` = `group.com.huehome.pro`, **no `keychain-access-groups` yet**), `HueHomeWidgetExtension.entitlements`, `LightShadeWatch/LightShadeWatch.entitlements`, `LightShadeWatchApp Watch App/LightShadeWatchApp.entitlements`, `LightShadeWatchApp Watch App/LightShadeWatchApp Watch App.entitlements`.
- `HueHome/Intents/` (HueIntentAPIClient etc.) has **no Xcode target membership** — dead code; the live Siri surface is the widget extension. Don't rely on it.
- `run_tests.sh` targets a hardcoded physical device and the wrong scheme — **ignore it; use the xcodebuild commands in §5.**

## 2. Golden rules (violating these fails the task)

- **iOS ONLY.** Touch `HueHome/`, `HueHomeWidget/`, `LightShadeWatch/`, `LightShadeWatchApp Watch App/`, `HueHomeTests/`, and the Xcode project. **Do not touch `android/`.**
- Never log/expose Hue bridge tokens, application keys, or entertainment client keys — not in code, logs, commit messages, or DEVLOG. (P0's `Scripts/hardening_guards.sh` enforces this; keep it passing.)
- Never implement trust-all TLS or blindly accept certs. Never route Hue control or credentials through the cloud (local-first). Never collect raw audio.
- **The iOS Keychain service identifier `com.lightshade.app` and the OSLog subsystem `com.lightshade.app` are LIVE — do NOT rename** (renaming orphans every user's stored credentials).
- Preserve the **generation-counter** patterns around async effects and the **`RestSender` latest-wins mailbox**. Extend the mailbox to paths that bypass it; never remove it.
- Prefer `@Observable` / Observation; don't add new `ObservableObject`/`@Published` unless touching legacy code that already uses it.
- The build scheme is **`HueHome 1`** (not `HueHome`).
- Entitlement changes are authorized **only** for the item-1 Keychain-access-group work (and must migrate existing Keychain items so no user loses credentials). Do not otherwise change signing/provisioning/bundle IDs/App Groups.
- Keep changes small and reviewable — **one finding-group per commit**. Targeted edits to the large "do-not-casually-touch" files (`UnifiedOrchestrator.swift`, `EffectsViewModel.swift`, `StudioView.swift`, `StudioViewModel.swift`, `DashboardView.swift`, `RoomDetailView.swift`) are authorized **for these specific findings only** — no free refactors.

## 3. Branch & workflow

- Base off `main` (`aca0d77`). Create **`ios-ref/hardening-p1-2026-07`**.
- Work the item groups below **in order**. After each group: build green (scheme `HueHome 1`), run `HueHomeTests`, add that group's regression tests (audit §6), run `Scripts/hardening_guards.sh`, and commit with a message referencing the finding IDs. End each commit message with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Append a dated `[Claude]` entry to `DEVLOG.md` after each meaningful group (what changed, IDs closed, validation run, what's left, gotchas). Append a `[Claude]` implementation turn to **D-018** in the pipeline Decision Log when you do item 1.
- Use `/code-review` and `/verify` on your diffs, and `/security-review` on the credential-storage (item 1) and DTLS (item 6) changes, before the checkpoint.
- **Do NOT push or open a PR until the human has tested locally.** Commit locally, keep the branch local, STOP at the checkpoint in §6. When the human says "tested locally, go ahead," push `ios-ref/hardening-p1-2026-07` and either merge to `main` with a `--no-ff` merge (the P0 pattern) or open a PR — ask the human which. Note: the `gh` CLI on this machine is authed as a non-collaborator account, so `gh pr create` fails with "must be a collaborator"; pushing over SSH works, and the human opens the PR from the URL git prints. Before pushing `main`, always build+test the **merged** tree first.

## 4. The work — P1 groups (read each finding in the audit for the exact fix)

Do these in order; commit per group.

**Group 1 — M-02 / L-30: Keychain access group (credential + pin surface reduction; implements D-018).**
Move shared credentials to a **Keychain access group** (`kSecAttrAccessGroup`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) so widget/watch/intents read secrets from Keychain instead of App Group / watch UserDefaults. Stop writing the token to `group.com.huehome.pro` UserDefaults and to watch `UserDefaults.standard` (store only non-secret routing metadata — ip, bridgeid, names — there). Use a **watch Keychain**. **Clear the watch token on forget-all.** Fold the P0 `BridgePinStore` pin mirror into the same shared access group (pins can move with the credentials). Add the `keychain-access-groups` entitlement to the app + widget + watch targets. **Critical: migrate existing Keychain items** — adding an access group / changing accessibility changes the query, so read old items and re-write them into the group on first launch, or existing users lose credentials. Files: `HueHome/Core/Keychain/KeychainManager.swift`, `HueHome/Core/Network/WidgetDataStore.swift`, `HueHome/Core/Network/Trust/BridgePinStore.swift`, `HueHomeWidget/WidgetIntents.swift`, `HueHome/Intents/HueIntentAPIClient.swift`, `LightShadeWatchApp Watch App/WatchStore.swift`, `HueHome/HueHomeApp.swift` (WCSession push), the entitlements files. Tests (audit §6): Keychain writes use `AfterFirstUnlockThisDeviceOnly` + non-syncable; token is never in the App Group suite or watch `UserDefaults` (only routing metadata); entertainment client key never enters `WidgetBridgeCredentials`/WCSession; forget-all clears the watch token + App Group mirror and `credentials(for:)` returns nil after.

**Group 2 — M-07 / H-05 / M-18: sweep room-targeted writes off `primaryAPIClient`.** Replace `primaryAPIClient` with `hueClient(for: bridgeID)` on every room-targeted path: composition teardown (`stopCompositionMode`, `UnifiedOrchestrator.swift`), the Effects tab (`EffectsViewModel.configure/activate`), and the entertainment-area builder (`EntertainmentConfigBuilderView.loadLights/createConfig`). Thread the target bridge identity where it isn't currently passed. **Add a guard to `Scripts/hardening_guards.sh` that fails if `primaryAPIClient` appears in a room-targeted write path** (grep-based, matching the existing guard style). Tests: multi-bridge test that Effects/entertainment/composition-teardown target the manifest/room's bridge, not `clients.values.first`.

**Group 3 — M-04 / M-05: bridge-stored animation correctness.** Map v1 light IDs by **`id_v1` identity** (pass the v2 light objects into `resolveV1LightIDs`; delete the dead positional/`uniqueIDToV1ID` code) — `HueV1Client.swift`. Chunk step-rule actions to **≤7 lights per rule** (or drive via scene activation); validate action count before POSTing — `BridgeAnimationEngine.swift`. Tests: 8+ light room produces rules with ≤8 actions and uploads; `resolveV1LightIDs` maps via `id_v1` (mismatched numeric ordering doesn't scramble output).

**Group 4 — M-08 / M-14 / M-15: route bulk/effect writes through the mailbox.** Route bulk `grouped_light` writes (`applyAutomationPreset/applyAutomationEffect/turnAllOff`), the Effects engine loops (`EffectEngine.setAll/setOne`), and the one-shot/gradual per-light writes (`EffectsViewModel`) through the shared **`RestSender`** / a per-bridge ~10 cmd/sec rate limiter. Collapse same-color frames to a single `grouped_light` PUT. **Stop swallowing 429s** (no more `try?`-hiding rate-limit failures; back off/surface). Preserve the existing per-light batching in §4-verified-good paths. Tests: N-room All-Off/automation routes through the limiter and surfaces failures (no silent partial application).

**Group 5 — M-13 / L-27: non-destructive persistence.** `CompositionStore.load()` must **never `persist()` on a decode error**; decode elements leniently (keep the good ones via a `FailableDecodable` wrapper), write a timestamped `.bak` before any recovery reseed, and give the Composer sub-configs (`PaletteConfig/MotionConfig/EnvelopeConfig/ReactionConfig/CodableColor`) **migration-safe `init(from:)`** using `decodeIfPresent` + defaults for every non-optional field — `CompositionStore.swift`, `CompositionModels.swift`. Apply the same lossy-decode wrapper to `HueV2Response.data` — `HueRoom.swift`. Tests: one malformed element preserves the rest + writes `.bak` + never overwrites source on decode error; round-trip an old-schema JSON missing new sub-config fields (must not reseed); `FailableDecodable` for `HueV2Response.data`.

**Group 6 — M-06, M-09 / M-10 / L-11: entertainment/DTLS robustness.** Guard `deactivateStuckEntertainmentSessions` so it never stops the app's own active Studio/Composer session (track active configID per bridge; or only deactivate stale/unowned sessions) — `UnifiedOrchestrator.swift`. Make the DTLS handshake continuation resume exactly once (atomic `finishOnce`) — `HueEntertainmentClient.openDTLSConnection`. On send failure, cancel + reconnect or fall back to REST — `handleSendError`. On failed open, issue a compensating `action=stop` — `startSession`. Tests: simultaneous handshake-complete + timeout resumes once (no CONTINUATION MISUSE); mid-session send error triggers reconnect/REST fallback; failed open issues `action=stop`; an active app-owned config is excluded from stuck-session cleanup.

**Group 7 — M-11 / M-12: pairing/UX correctness.** Guard the NUPnP fallback on `discoveredBridgeChoices.isEmpty` (don't let a cloud-empty result wipe an existing local selection or drive `handleError`) — `BridgeDiscoveryViewModel.swift`. Keep the one-shot `CLLocationManager` alive across the `await` and add a timeout so "Set location" can't hang — `SettingsView.OneShotLocation`. Tests where feasible (the location one may need on-device notes).

## 5. Validation commands (run locally; scheme is `HueHome 1`)

```bash
# Build (filtered)
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData build 2>&1 | rg -e 'error:' -e 'BUILD SUCCEEDED' -e 'BUILD FAILED'

# Test (list destinations first if iPhone 15 / iOS 17.0 isn't present)
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -showdestinations
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' -derivedDataPath build/DerivedData -only-testing:HueHomeTests test 2>&1 | rg -e 'error:' -e 'TEST SUCCEEDED' -e 'TEST FAILED'

# Guards (must pass)
./Scripts/hardening_guards.sh
```
When adding a Swift test file, wire it into the `HueHomeTests` target in `HueHome.xcodeproj/project.pbxproj` (the project uses explicit membership; follow the existing synthetic `C0DEC0DE…`-style fileRef/build-file/group/Sources-phase entries — add a build-file, a fileRef, a group entry, and a Sources-phase entry). Widget/watch targets are file-system-synchronized groups where folder presence = membership.

## 6. Local-first checkpoint (STOP and hand back to the human)

Some P1 changes can't be fully validated without a physical Hue bridge (ideally two). After all groups are implemented and green, **STOP** and post a concise, secret-free handoff. The human must verify:
- **Credentials still work after the Keychain-access-group migration** (item 1): existing paired bridge still controls after upgrade; widget + watch still control; forget-all fully clears secrets.
- **Multi-bridge correctness** (item 2): Effects, entertainment-area builder, and composition teardown target the correct (non-primary) bridge.
- **Bulk/All-Off on a large home** (item 4) no longer drops commands.
- **Bridge-stored animation** on an 8+ light room (item 3) uploads and runs.
- **Studio/Composer session survives a background refresh** (item 6) and DTLS recovers from a transient error.
- Composition library survives an old-schema `compositions.json` without data loss (item 5).

Give exact on-device steps. In the handoff summarize: IDs closed, files touched, tests added, build/test result, and what to test on-device. **Do not push until the human says "tested locally, go ahead."**

## 7. Definition of done (P1)

All P1 findings fixed with regression tests; no §4 verified-good item regressed; build green; `HueHomeTests` green; `Scripts/hardening_guards.sh` passes (including the new `primaryAPIClient` guard); `/code-review` + `/security-review` clean on the diff; no secret ever logged or committed; `DEVLOG.md` and the D-018 Decision Log turn updated; branch `ios-ref/hardening-p1-2026-07` ready and STOPPED for the human's on-device multi-bridge checkpoint before any push/merge.

## 8. Do NOT

Touch `android/`; rename `com.lightshade.app`; change bundle IDs/signing/App Groups beyond the item-1 Keychain-access-group entitlement work (with migration); remove the mailbox or generation-counter patterns; reintroduce trust-all TLS or a raw `.useCredential` outside the Trust module; broad-refactor the monolith files; push before the human's local validation; or put any credential value into logs/commits/DEVLOG.
