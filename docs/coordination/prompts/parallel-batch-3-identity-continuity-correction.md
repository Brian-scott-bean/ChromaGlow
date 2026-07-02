# Parallel Batch 3 Identity-Continuity Correction Prompt

## Status

- **State:** COMPLETED — correction integrated at `c385616` and accepted by Codex promotion review.
- **Batch:** `parallel-batch-3` correction (single serialized lane)
- **Starting point:** `origin/integration/parallel-batch-3` @
  `142ca71452c78f9edec70e3c4b8007f7997e8f13`
- **Decision:** D-014
- **Last reviewed:** 2026-06-29 [Codex]

## Prompt

```text
Read AGENTS.md completely, the Current Status Snapshot and latest relevant DEVLOG entries,
docs/android/android-pairing-tls-identity-decision.md, D-001/D-002/D-012/D-014 and §10 of
docs/coordination/parallel-agent-pipeline.md.

Correct the Batch 3 identity-continuity defect on top of the exact pushed integration head
142ca71452c78f9edec70e3c4b8007f7997e8f13. Do not merge to main.

Why this is required:
OkHttpHuePairingClient currently creates one client with HueLeafHostnameVerifier(expectedBridgeId).
When expectedBridgeId is null, GET /api/0/config authenticates a CA-valid Hue identity and confirms its
bridgeid, but POST /api reuses a verifier that still accepts any valid Hue bridge CN. A reconnect or route
change between requests can therefore send create-user to a different CA-valid bridge. Existing tests use
one certificate for both requests and do not exercise this transition.

Execution:
1. Fetch/prune and confirm origin/integration/parallel-batch-3 is exactly the pinned SHA above. If it
   advanced, stop and re-review the delta.
2. Create lane/android3-pairing-identity-continuity-correction from that exact integration SHA.
3. The lane may edit only:
   - android/app/src/main/java/com/chromaglow/app/core/hue/pairing/transport/OkHttpHuePairingClient.kt
   - android/app/src/test/java/com/chromaglow/app/core/hue/pairing/transport/OkHttpHuePairingClientTest.kt
4. Preserve all D-001/D-002/D-012 behavior and the existing public HuePairingClient API.

Acceptance criteria:
- After GET leaf CN, config bridgeid, and any caller hint agree, POST /api is attempted through a client
  whose TLS verifier is pinned to that authenticated bridgeid even when the original hint was null.
- Do not rely only on connection-pool behavior. Also inspect the POST response handshake leaf and require
  it to match the authenticated bridgeid before parsing or returning any create-user outcome.
- If the endpoint presents a different CA-valid Hue leaf between GET and POST, fail closed. The
  create-user HTTP request must not reach the different bridge when its TLS handshake can be rejected.
- Add a real HTTPS MockWebServer/okhttp-tls regression test for the null-hint path that forces distinct
  CA-valid bridge identities across the two legs. A mocked parser-only assertion is insufficient.
- Keep success, case-insensitive matching, type 101, type 7, size limits, redirect refusal, timeout,
  wrong-CA, and wrong-identity tests green.
- No trust-all behavior, system CA fallback, redirects, POST retries, logging, persistence, UI, discovery,
  Gradle, resource, protocol, or TLS-package edits.

Validation and handoff:
1. Export the Android Studio JBR and Android SDK environment documented in AGENTS.md.
2. Run the focused transport test, then ./gradlew testDebugUnitTest lintDebug assembleDebug.
3. Merge the correction lane --no-ff into integration/parallel-batch-3 and rerun the full integrated gate,
   including connectedDebugAndroidTest serially on Pixel_10 and git diff --check.
4. Boundary-audit the correction commit and repeat the prohibited-pattern scan from §10.
5. Push the lane and corrected integration branch. Update D-014, §10, AGENTS.md, and one consolidated
   DEVLOG handoff on docs/parallel-agent-pipeline; record 29 total changed paths versus main and the exact
   two-file correction commit boundary.
6. Report the lane SHA, corrected integration SHA, exact test counts, boundary audit, and deviations.
7. Do NOT merge integration/parallel-batch-3 to main. Await explicit human go-ahead after Codex review.
```
