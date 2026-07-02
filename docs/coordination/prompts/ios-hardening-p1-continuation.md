# iOS Hardening P1 — Continuation Prompt (checkpoint round 2)

> Standalone launch prompt for a fresh Claude Code agent continuing **Phase P1** of the
> ChromaGlow iOS hardening. The prior conversation implemented ALL of P1, survived a
> multi-agent code review + security review, and went through TWO human on-device rounds.
> A fresh agent needs only the repo + this file. Prepared 2026-07-02 by Claude at the end
> of the P1 implementation session.

---

You are Claude Code (Fable 5), continuing **Phase P1** of the iOS security-hardening + quality
remediation for **ChromaGlow** (native Swift/SwiftUI Philips Hue controller; historical names
HueHome / LightShade / CastChroma appear in code). Everything below has already happened — your
job is the **round-2 checkpoint issues** in §4 and then the final push/merge gate in §6.

## 0. Orient (read in this order, before touching code)

1. `AGENTS.md` — canonical guardrails (Security Rules, iOS Engineering Rules, Hue API Rules). Overrides defaults.
2. `DEVLOG.md` — "Current Status Snapshot", then ALL the `2026-07-02 [Claude] iOS P1 …` entries
   (7 group entries + review entry + checkpoint-round-1 entry + checkpoint-round-2 entry). They
   are the detailed ledger of what changed and why.
3. `docs/audit/hardening-audit-2026-07-01.md` — the source of truth for finding IDs. §4 lists
   verified-good hardening you must NOT regress; L-15/L-17 (relevant to §4 item 1 below) are in
   the Round-1 LOW list.
4. `docs/coordination/parallel-agent-pipeline.md` — Decision Log. **D-018 is IMPLEMENTED** (see
   its 2026-07-02 turn). D-016/D-017/D-019 shipped in P0. D-020 (Android) is out of scope.
5. The original P1 brief: `docs/coordination/prompts/ios-hardening-p1-launch.md` (§2 golden
   rules and §5 validation commands still apply verbatim).

Toolchain: Xcode 26.4, iPhone 15 / iOS 17.0 simulator. Scheme is **`HueHome 1`**.

## 1. Current repo state (do not redo or break)

- Branch **`ios-ref/hardening-p1-2026-07`** @ **`03e2902`**, based on `main` @ `d023b1f`.
  **11 local commits — NOTHING PUSHED.** Working tree clean. Do NOT push until the human says
  "tested locally, go ahead" (then: push over SSH — `gh` is authed as a non-collaborator — and
  `--no-ff` merge to `main` after building/testing the merged tree, the P0 pattern).
- **All P1 groups are DONE, reviewed, and committed** (one commit per group):
  `0a784d4` M-02/L-30 Keychain access group (D-018) · `134ec1f` M-07/H-05/M-18 wrong-bridge
  sweep · `cba60b8` M-04/M-05 animation correctness · `a3fe67a` M-08/M-14/M-15 paced bulk/effect
  writes · `227a32c` M-13/L-27 non-destructive persistence · `7a65244` M-06/M-09/M-10/L-11 DTLS
  robustness · `50187b6` M-11/M-12 pairing/UX · `789232a` 8-angle review fixes ·
  `ced9bae` docs · `03e2902` checkpoint-round-1 fixes.
- Validation state at `03e2902`: device build green, **~195 tests green** (baseline 36 + ~60 new
  across 7 new test files), `./Scripts/hardening_guards.sh` **5 guards pass**, `/security-review`
  clean (recorded in DEVLOG).
- **Load-bearing architecture added by P1 (extend, never remove):**
  - `HueHome/Core/Keychain/SharedKeychainStore.swift` — shared access group
    `2H9J347H3T.com.huehome.pro.shared` (entitlement `$(AppIdentifierPrefix)com.huehome.pro.shared`
    on app+widget+watch app). Service stays `com.lightshade.app` — **LIVE, do NOT rename**.
    Credentials blob account: `hue_shared_bridge_credentials_v1`. Pins share the group.
  - `KeychainManager.migrateToSharedAccessGroupIfNeeded()` — attributes-only fast scan,
    copy-first/delete-on-success, shared-copy-wins. Runs at singleton init.
  - `HueHome/Core/Network/BridgeCommandGate.swift` — per-bridge ~10 cmd/s pacing actor;
    orchestrator `commandGate(for:)`; `gatedBulkWrite` scaffold for All Off/automations;
    `lastBulkFailure` → Dashboard toast. Effect loops pass `retry: false`.
  - `HueEntertainmentClient` — refcounted app-owned-session registry (register BEFORE
    `action=start`); `ContinuationGate` (resume-once); bounded reconnect w/ teardown on abandon;
    `sendBestEffortStop` shared teardown.
  - `pruneStaleBridgeSnapshots()` in `UnifiedOrchestrator` — drops roomsByBridge/zonesByBridge
    keys with no live client at the rebuild chokepoint (demo exempt). Critical for
    forget→re-pair correctness.
  - `orchestrator.forgetAllBridges()` + SettingsView forget-all purges SwiftData room/scene
    cache and posts `.hueBridgeUnpaired` from every presentation path. Watch unpair is the
    **explicit `wc_unpaired` WCSession flag** — an empty credentials map must NEVER wipe.
  - `WidgetDataStore` — credentials Keychain-only; App Group carries routing metadata only;
    read-only upgrade-window fallback to legacy App Group keys; `write(bridges:)` skips
    identical blobs (sortedKeys) and calls `WidgetCenter.reloadAllTimelines()` when the blob
    CHANGES (widget revival).
  - `FailableDecodable`, lenient `HueV2Response`, `CompositionStore` .bak/no-reseed-overwrite,
    `CompositionPreset` decode requires only `id`.
- **pbxproj wiring:** new app files + test files use the synthetic `C0DEC0DE…` pattern
  (PBXBuildFile + PBXFileReference + group child + Sources-phase entry). **Used up through
  `C0DEC0DE010F…` — next free prefix is `C0DEC0DE0110…`.** Suffix `…0001`=app, `…0002`=widget,
  `…0003`=watch-app Sources phases for shared files; tests go in the HueHomeTests phase.
- `run_tests.sh` is stale — ignore it. Guards must stay green: `./Scripts/hardening_guards.sh`.
- The prior session sometimes hit subagent session-limits; if Agent/Workflow calls fail with a
  limit error, do the work inline.

## 2. Golden rules (unchanged from the original brief — violating these fails the task)

iOS ONLY (never touch `android/`). Never log/expose tokens/app keys/entertainment client keys
anywhere. Never trust-all TLS; `.useCredential` only inside `HueHome/Core/Network/Trust/`.
`com.lightshade.app` (Keychain service + OSLog subsystem) is LIVE — do not rename. Preserve
generation-counters, the `RestSender` latest-wins mailbox, the BridgeCommandGate, the pruning,
and the session registry. Prefer `@Observable`. No entitlement/signing/bundle-ID changes beyond
what already shipped. Small reviewable commits, one issue-group per commit, ending with:
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Append a dated `[Claude]` DEVLOG entry
per meaningful group. Build + full `HueHomeTests` + guards after every group.

## 3. Round-2 on-device results (2026-07-02, from Brian — context for §4)

Working now: forget-all behavior improvements, cross-bridge preset sync ("energize/read/relax/
sleep apply across bridges — syncing now"), location flow, bridge-1 rooms after the round-1
pruning fix (implied — no longer reported broken). CLOSED: lost-compositions (#8) — user
attributes it to an earlier app delete/reinstall (Documents wiped); accepts prevention-only.

## 4. The work — round-2 issues, in order (commit per item)

**Item 1 — First-paired bridge lost after pairing two bridges in one session (HIGH).**
Symptom: forget-all → pair bridge A → pair bridge B; app works during the session, but after
swipe-out/relaunch the app has forgotten bridge A (bridge B survives); re-pairing A fixed it.
Almost certainly audit **L-15** (+ L-17 adjacency): pairing persists the token to the LEGACY
single-bridge Keychain slots (`hue_api_token`/`hue_bridge_ip`) and only migrates to per-bridge
namespaced keys when "Add to ChromaGlow" is tapped (`BridgeSetupView.swift` ~`handlePairedAction`,
`migrateLegacyCredentials` result discarded); a second pairing overwrites the legacy slots, so
bridge A's per-bridge credentials can end up missing/empty → on relaunch `configure()` logs
"No credentials for bridge <id> — skipping". Fix per the audit: **write pairing results directly
to per-bridge namespaced keys at pairing time** (keyed by the new BridgeRecord id), create the
record + persist credentials atomically, surface migrate failures, and dedup records by canonical
bridgeid (L-17) if cheap. Regression test: two sequential simulated pairings leave BOTH bridges'
per-bridge credentials readable (`KeychainManager.loadCredentials(for:)`), and `configure()`
builds two clients. Read the actual pairing flow first — `BridgeDiscoveryViewModel` (pairing
POST + `pinAcquisitionOverride` test seam exists) and `BridgeSetupView` (handlePairedAction).

**Item 2 — Onboarding: "Pair another bridge" (feature, small).**
After a successful pair in the setup flow, offer two actions: "Pair another bridge" (returns to
scanning, keeps the just-paired record) and "Continue to app". Today the flow drops you into the
app and additional bridges are added elsewhere. Keep it minimal — `BridgeSetupView`/`SplashView`
level, no nav rework. This also reduces Item-1 exposure but do NOT treat it as the fix.

**Item 3 — Widget shows "blurriness" (regression, HIGH).**
Round 1 the large widget vanished; after the round-1 fixes (`reloadAllTimelines` on blob change)
the widget now renders BLURRY content — that is WidgetKit's redacted/placeholder rendering,
which typically means the timeline provider is crashing, hanging, or the system is stuck on
`placeholder(in:)`. Suspects to check in `HueHomeWidget/HueHomeWidget.swift` +
`WidgetDataStore`: (a) a crash/hang in `timeline(for:in:)` — it does a synchronous-looking
network fetch via `WidgetAPIClient.fetchGroupedLights` and now TWO Keychain reads
(`isPaired`→routing UD only, but `primaryCredentials()`→Keychain) — Keychain reads in a widget
process before first unlock return nothing (handled) but a CRASH would leave the redacted
snapshot; (b) reload loop: `write(bridges:)` reload fires on every blob change — verify it isn't
thrashing WidgetKit's budget (blob compare should make it once-per-pairing-change; confirm the
sortedKeys compare actually stabilizes — if the map iteration/encode is somehow unstable the
widget reloads constantly and iOS throttles it to placeholder); (c) `getSnapshot`/`placeholder`
paths. Repro locally: run the `HueHomeWidgetExtension` scheme in the simulator with Console
attached; check for crash logs (`~/Library/Logs/DiagnosticReports` on device sync). Fix +
explain in the DEVLOG. If you need on-device data, ask Brian for: widget crash logs under
iPhone Settings → Privacy & Security → Analytics Data (filter "HueHomeWidget").

**Item 4 — Entertainment-area builder is undiscoverable (UX, MEDIUM).**
Brian cannot find the "New Entertainment Area" UI at all (so he never saw the M-18 bridge
picker). The builder sheet exists (`EntertainmentConfigBuilderView`, presented from
`SyncModeView` via `showCreateArea`). Find the actual trigger (grep `showCreateArea` in
`HueHome/UI/Sync/SyncModeView.swift`) — verify it's reachable (it may only appear in a
controls card when no configs exist, or be buried). Make it plainly discoverable (e.g. a
"New Entertainment Area" row/button in the Sync tab's config picker area), confirm the Bridge
picker section renders when `orchestrator.allBridgeIDs.count > 1`, and give Brian exact
tap-by-tap steps in the handoff.

**Item 5 — Re-verify round-1 fixes still hold after Items 1–4** (forget-all totality, bridge-1
rooms after re-pair, widget revival) and run the full validation cycle.

## 5. Validation (after every item)

```bash
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcodebuild -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' -derivedDataPath build/DerivedData -only-testing:HueHomeTests test 2>&1 | grep -E "error:|Test case '.*failed|TEST (SUCCEEDED|FAILED)"
./Scripts/hardening_guards.sh
```

## 6. Checkpoint discipline (STOP — same as before)

After Items 1–4 are green: append the DEVLOG entry, post a concise secret-free handoff with
exact on-device steps for Brian (multi-pair persistence across relaunch; widget renders real
content; find + use the entertainment-area builder with the bridge picker; quick regression
pass on forget-all and bridge-1 rooms), and **STOP. Do not push.** On "tested locally, go
ahead": push the branch over SSH, build+test the merged tree, `--no-ff` merge to `main` (ask
Brian merge vs PR; note `gh pr create` fails on this machine — non-collaborator account — he
opens PRs from the pushed-branch URL).

## 7. Definition of done

Items 1–4 fixed with tests; no P1 architecture (§1 list) or audit-§4 verified-good item
regressed; build + full HueHomeTests + 5 guards green; DEVLOG updated per item; branch ready
and STOPPED for Brian's round-3 on-device pass.
