# Parallel Batch 3 Launch Prompt

## Status

- **State:** READY — execution-approved by D-013; not yet launched.
- **Batch:** `parallel-batch-3` (pairing foundations only)
- **Manifest:** `docs/coordination/parallel-agent-pipeline.md` §10
- **Pinned base:** `origin/main` @ `7ed64687b600e9456d32510fa86e709c841fefd5`
- **Accepted decisions:** D-001, D-002, D-011, D-012, D-013
- **Last reviewed:** 2026-06-29 [Codex]

## Prompt

```text
Read AGENTS.md completely, the Current Status Snapshot and latest relevant entries in DEVLOG.md,
docs/android/android-pairing-tls-identity-decision.md, and §1–§3, §5–§6, §9–§10 of
docs/coordination/parallel-agent-pipeline.md.

Execute the READY Android pairing-foundation Batch 3 manifest exactly as written in §10. This batch
implements dependencies/CA resources, pure protocol contracts, TLS/identity verification, and a tested
HTTPS transport. It does NOT implement or edit Setup UI, app navigation, discovery, credential storage,
token persistence, live bridge traffic, or physical pairing.

Preflight:
1. Fetch all remotes and prune. Confirm origin/main is exactly
   7ed64687b600e9456d32510fa86e709c841fefd5. If it advanced, stop and revalidate/re-pin §10.
2. Confirm D-001/D-002/D-011/D-012/D-013 are ACCEPTED and this prompt is READY.
3. Confirm the working tree/worktree slate is clean and no Batch 3 branches already contain unreviewed
   work. Do not delete unrelated human work.
4. Confirm these local source files exist outside Git and match exactly:
   - /Users/brianbean/Desktop/chromaglow-hue-ca/root-bridge.pem
     SHA-256 9eb5d8ee06004a6128659eee9727490387f582112fd6fa8657a3b75e2aef7e44
   - /Users/brianbean/Desktop/chromaglow-hue-ca/hue-root-ca-01.pem
     SHA-256 dfb5bd1e3a46b980f4c1494d96d2670216b4080d7ca1e33c3d4464abb1b363c5
   If either differs, stop. Never substitute a community certificate.
5. Export:
   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   ANDROID_HOME="$HOME/Library/Android/sdk"
   ANDROID_SDK_ROOT="$ANDROID_HOME"
6. Create integration/parallel-batch-3 from the pinned origin/main commit. The batch owner alone edits
   DEVLOG.md and docs/coordination/parallel-agent-pipeline.md while lanes run.

Execution order:

W0 — serialized bootstrap:
1. Create lane/android3-pairing-bootstrap from the pinned main base.
2. Give it only the W0 globs in §10. Pin the exact approved dependency versions and copy the two exact CA
   files to the named res/raw paths. It may not edit Kotlin or the manifest.
3. Run its validation, boundary-audit, commit, and merge --no-ff into integration.
4. Record the merged integration SHA. W1 branches fork from this SHA.

W1 — parallel protocol + TLS:
1. Concurrently create lane/android3-pairing-protocol and lane/android3-pairing-tls from the post-W0
   integration SHA.
2. Give each agent only its exact §10 source/test globs and acceptance criteria.
3. Require focused tests and boundary audits in each isolated worktree. Agents return structured handoffs;
   they do not edit shared docs.
4. Merge both lanes --no-ff into integration only after each is green. Resolve no overlap by construction;
   unexpected shared edits are a stop condition, not an auto-resolution task.

W2 — serialized transport integration:
1. Create lane/android3-pairing-transport from the post-W1 integration SHA.
2. Implement only the §10 transport globs against the merged public protocol/TLS APIs. Do not modify those
   APIs in W2; if an API is insufficient, stop and re-dispatch the owning W1 lane before continuing.
3. Use MockWebServer/test certificates only. Do not contact a LAN bridge.
4. Run focused and lane validation, boundary-audit, commit, and merge --no-ff into integration.

Security/adversarial review before the final gate:
- Chain trust uses only the two bundled Hue roots; no system/user CA fallback.
- Identity validation never returns true without a valid 16-hex leaf CN and optional expected-ID match.
- CA-valid but wrong-CN, wrong-CA, self-signed leaf, expired leaf, and config/CN mismatch all fail closed.
- HTTPS only; redirects disabled; POST not automatically retried; response sizes and timeout bounded.
- Request contains devicetype only. No generateclientkey, CLIENT_KEY, token persistence, credential-store
  calls, sensitive logs, Setup/app/discovery edits, or live network access.

Shared-device rule:
- Only one Pixel_10 AVD exists. Lanes may compile/test concurrently, but the batch owner runs all connected
  tests serially after merges. Do not let multiple Gradle connected-test jobs contend for the AVD.

Final integrated gate:
1. ./gradlew testDebugUnitTest lintDebug assembleDebug
2. ./gradlew connectedDebugAndroidTest on the single Pixel_10 AVD
3. git diff --check
4. Boundary audit by lane and scan the prohibited patterns listed in §10.

Handoff:
1. Push all lane branches and origin/integration/parallel-batch-3.
2. Update the lane registry, §10 execution result, Decision Log only if a new decision was required,
   AGENTS.md current status, and one consolidated DEVLOG handoff on docs/parallel-agent-pipeline.
3. Commit and push the docs branch.
4. Report lane SHAs, integration SHA, exact test results, dependency versions, CA fingerprints, boundary
   audit, deviations, and remote refs.
5. Do NOT merge integration/parallel-batch-3 to main. Await explicit human go-ahead.
```
