# Android Pairing Evidence-Closure Prompt

## Status

- **State:** READY — docs/evidence only; safe for Claude Code to execute.
- **Purpose:** Close the remaining D-001/D-002 evidence, propose the legacy-bridge policy, and prepare
  an explicit acceptance packet before any Batch 3 implementation manifest.
- **Pinned code base:** `origin/main` @ `7ed64687b600e9456d32510fa86e709c841fefd5`
- **Pinned docs base:** `origin/docs/parallel-agent-pipeline` @ `a92fa6c`
- **Coordination decision:** D-012 in `docs/coordination/parallel-agent-pipeline.md`
- **Last reviewed:** 2026-06-28 [Codex]

## Prompt

```text
Read AGENTS.md, the Current Status Snapshot and latest relevant DEVLOG entries,
docs/coordination/parallel-agent-pipeline.md (D-001, D-002, D-011, D-012, and §9), and the full
docs/android/android-pairing-tls-identity-decision.md, including the Codex review and redacted empirical
probe addendum.

This is the final evidence-closure session, not implementation. Do not modify application source,
tests, Gradle, manifests, resources, dependencies, or credentials. Do not probe bridges again, reboot
equipment, pair, request tokens, create Batch 3 worktrees, draft a Batch 3 manifest, or create a launch
prompt.

Preflight:
1. Fetch all remotes. Confirm origin/main is
   7ed64687b600e9456d32510fa86e709c841fefd5 and origin/docs/parallel-agent-pipeline contains
   a92fa6c. If either advanced incompatibly, stop and reconcile this packet first.
2. Confirm the committed probe evidence remains redacted and the working tree is clean.
3. Use only an existing human-authenticated Hue developer-portal session. Never request, echo, save,
   automate, or commit the user's portal password/session cookies. If no authenticated session is
   available, stop and report the exact pages/files the human must open or provide.

Official evidence to obtain:
1. Hue "Using HTTPS" guidance and the official downloadable Signify `root-bridge` CA certificate.
2. Hue Configuration API documentation for unauthenticated `/api/0/config` and `bridgeid` semantics.
3. Hue pairing/Entertainment documentation for `generateclientkey` and `clientkey` behavior.
4. Any official compatibility statement identifying CA-signed versus legacy self-signed bridge
   firmware/support.

Root-certificate verification:
1. Download the official CA file to a temporary path outside the repository. Do not use a community
   transcription as the source of truth.
2. Inspect it with standard certificate tooling. Record only the official source URL, SHA-256 file
   digest, certificate SHA-256 fingerprint, subject/issuer, serial, validity, public-key algorithm, and
   whether it is a CA. Do not commit portal content verbatim or the certificate file in this docs pass.
3. Confirm its subject matches the probed leaf issuer (`C=NL, O=Philips Hue, CN=root-bridge`) and that
   the documented certificate profile supports chain validation plus a case-insensitive leaf-CN ==
   canonical `bridgeid` identity check when the leaf has no SAN.
4. Delete the temporary file after recording the non-secret verification metadata. If any check fails,
   keep D-001 DEFERRED and report the exact mismatch.

Decision policy to review:
- Recommend that Android MVP support only CA-signed bridges validating to the official bundled Signify
  root. A legacy self-signed bridge must fail closed with guidance to update bridge firmware; no TOFU,
  trust-all, silent fallback, or leaf-on-first-use pinning. Treat broader legacy support as a later,
  separately reviewed compatibility feature.
- Canonical identity remains normalized uppercase 16-hex `bridgeid`; compare certificate CN and config
  identity case-insensitively. mDNS/host/port remain discovery hints, never durable identity.
- For manual endpoint entry, document exactly how the official trust guidance establishes the expected
  bridge identity without deriving both sides solely from an unauthenticated response.
- Decide `generateclientkey` only from official Hue evidence. Keep CLIENT_KEY persistence out of MVP.

Required repository output:
1. Append a dated "Official evidence closure" section to
   docs/android/android-pairing-tls-identity-decision.md. Include direct official links, certificate
   verification metadata, the final proposed TLS/identity contracts, legacy policy, `generateclientkey`
   decision, recovery behavior, and any remaining uncertainty. Preserve all existing history.
2. Append Claude turns under D-001, D-002, D-011, and D-012. Never rewrite prior turns.
3. If every required official check succeeds, mark the packet READY FOR ACCEPTANCE but leave final
   ACCEPTED/code-authorized status to Codex + the human. If access or evidence is incomplete, keep the
   blockers DEFERRED and state one exact next action.
4. Append one DEVLOG.md handoff. Keep AGENTS.md unchanged unless a current factual statement is proven
   wrong; flag contract changes for acceptance instead of silently applying them.
5. Run git diff --check, commit, and push docs/parallel-agent-pipeline for Codex review.

Report the evidence result, proposed legacy policy, remaining blocker (if any), commit SHA, and remote
branch. Stop after the acceptance packet; do not prepare or launch Batch 3.
```
