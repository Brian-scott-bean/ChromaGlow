# Parallel Batch 4 Launch Prompt

## Status

- **State:** READY — implementation approved by D-015; physical promotion gate requires the human.
- **Batch:** `parallel-batch-4` (live pairing onboarding + durable local registration)
- **Manifest:** `docs/coordination/parallel-agent-pipeline.md` §11
- **Pinned base:** `origin/main` @ `f3380a71896fb57b311352b81e9d7ee7958918c1`
- **Accepted decisions:** D-001, D-002, D-012, D-014, D-015
- **Last reviewed:** 2026-06-29 [Codex]

## Prompt

```text
Read AGENTS.md completely, the Current Status Snapshot and latest relevant DEVLOG entries,
docs/android/android-pairing-tls-identity-decision.md,
docs/android/android-live-pairing-workflow-contract.md, and §1–§3, §5–§6, §9–§11 of
docs/coordination/parallel-agent-pipeline.md.

Execute the READY Batch 4 manifest exactly as written in §11. This batch wires the landed secure pairing
transport into Setup, persists the application token through the existing Keystore store, persists
non-secret bridge routing metadata in a no-backup DataStore, restores paired state after relaunch, and
provides local Forget Bridge. It does NOT add Hue REST resource loading, a real dashboard, SSE, remote key
revocation, multi-bridge UI, N-UPnP, or legacy self-signed support.

Preflight:
1. Fetch/prune and confirm origin/main is exactly
   f3380a71896fb57b311352b81e9d7ee7958918c1. If it advanced, stop and re-pin/review §11.
2. Confirm D-015 is ACCEPTED, §11 and this prompt are READY, and the worktree slate contains no unreviewed
   Batch 4 branches. Do not delete unrelated work.
3. Export the Android Studio JBR and Android SDK environment from AGENTS.md. Confirm the Pixel_10 AVD is
   available; connected jobs remain serial.
4. Create integration/parallel-batch-4 from the pinned base. The batch owner alone edits shared docs.

Execution order:

W0 — serialized dependency bootstrap:
- Run lane/android4-pairing-bootstrap with only the exact Gradle/catalog files in §11. Pin only the
  approved DataStore, Lifecycle ViewModel, and coroutine-test dependencies. Validate resolution/build,
  boundary-audit, commit, and merge --no-ff. All W1 lanes fork from the post-W0 integration SHA.

W1 — parallel contracts:
- Run lane/android4-pairing-result and lane/android4-bridge-registry concurrently from post-W0.
- The result lane makes successful pairing return authenticated bridgeId + username and updates exact
  transport tests without changing TLS policy.
- The registry lane implements only non-secret, list-ready metadata under core/bridge/** with its own
  tests and a Preferences DataStore file in noBackupFilesDir. It never stores or accepts a token.
- Boundary-audit and merge both --no-ff before W2.

W2 — serialized transactional workflow:
- Run lane/android4-pairing-workflow from post-W1. Implement the typed workflow under
  core/hue/pairing/workflow/** only. Normalize selected endpoints to HTTPS port 443, execute pairing off
  the main thread, persist token then metadata with compensation, restore only record+readable-token, and
  implement local-only forget. UI-safe outcomes only; the token must never escape to presentation.
- Run focused tests, boundary-audit, commit, and merge --no-ff.

W3 — serialized Setup UI integration:
- Run lane/android4-setup-live-pairing from post-W2. It owns feature/setup/** and exact setup tests only.
  Preserve scan/manual/demo behavior; replace the inert selected card with selected/pairing/type-101/
  paired/recovery states. Keep SetupPlaceholderScreen's app entry compatible so app/nav files need no edit.
  Use a feature ViewModel/factory and injectable fakes; Compose tests must never touch a real bridge.
- Run focused tests, boundary-audit, commit, and merge --no-ff.

Automated integrated gate:
1. ./gradlew testDebugUnitTest lintDebug assembleDebug
2. ./gradlew connectedDebugAndroidTest on the single Pixel_10 AVD, serially
3. git diff --check and lane/full boundary audits
4. Scan for trust-all/blanket-true verification, generateclientkey/CLIENT_KEY, token or username logs,
   token storage outside the Keystore boundary, raw exceptions in UI, automatic POST retries, and edits
   outside §11.
5. An independent read-only reviewer checks transaction compensation, startup reconciliation, ViewModel
   threading, no token in UI state, endpoint port 443 normalization, and regression coverage.

Human-assisted physical gate — STOP and ask the human before live pairing:
1. Do not probe or pair a LAN bridge unattended. Present the redacted checklist from the contract doc and
   ask which bridge is available. Explain that local Forget Bridge does not yet revoke the bridge-side app
   key.
2. With the human present: Pair before button (expect retry), press the physical link button, Pair once
   (expect connected), force-stop/relaunch (expect restored), Forget Bridge, relaunch (expect unpaired).
3. One bridge is required; a second bridge is optional. Record only redacted pass/fail evidence. Never
   record token/username, full bridge ID, local IP, or raw logs.

Handoff:
1. Push all lanes and origin/integration/parallel-batch-4. Do not merge to main.
2. Update §1, D-015, §9, §11, AGENTS.md, prompt status, and one consolidated DEVLOG handoff on the docs
   branch; commit and push it.
3. Report lane/integration SHAs, dependency versions, exact automated results, physical-gate result,
   boundary/security audits, deviations, and remaining work.
4. Batch 4 is not main-eligible until the physical gate passes and Codex reviews the integrated result.
```
