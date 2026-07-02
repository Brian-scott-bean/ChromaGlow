# Android Pairing Decisions Preparation Prompt

## Status

- **State:** COMPLETED — proposal, probe, CA verification, and final D-001/D-002 acceptance are recorded.
  Do not rerun; Batch 3 continues at `parallel-batch-3-launch.md`.
- **Purpose:** Produce reviewable resolutions for D-001 (TLS bootstrap) and D-002 (canonical bridge
  identity) before any Android pairing implementation or Batch 3 manifest.
- **Pinned code base:** `origin/main` @ `7ed64687b600e9456d32510fa86e709c841fefd5`
- **Coordination decision:** D-011 in `docs/coordination/parallel-agent-pipeline.md`
- **Last reviewed:** 2026-06-28 [Codex]

## Prompt

```text
Read AGENTS.md, the Current Status Snapshot and latest relevant entries in DEVLOG.md,
docs/coordination/parallel-agent-pipeline.md (especially D-001, D-002, D-011, and §9), and
docs/android/android-pairing-tls-identity-decision.md. Inspect the current Android discovery and
credential contracts under:

- android/app/src/main/java/com/chromaglow/app/core/hue/discovery/**
- android/app/src/main/java/com/chromaglow/app/core/credentials/**

This is a decision-preparation session only. Do not modify Android/iOS source, tests, Gradle, the
manifest, resources, dependencies, credentials, or network-security configuration. Do not create
Batch 3 branches/worktrees or a launch prompt. Do not probe a physical bridge unless the human user
explicitly approves that probe in this session; never print or persist bridge credentials.

Preflight:
1. Fetch all remotes.
2. Confirm origin/main is 7ed64687b600e9456d32510fa86e709c841fefd5. If it advanced, stop and
   reconcile this packet against the new main before researching.
3. Confirm origin/docs/parallel-agent-pipeline contains D-011 and this prompt.
4. Re-verify from source that BridgeEndpoint contains only name/host/port, host:port is used only as
   an endpoint key, and BridgeCredentialStore aliases require a stable validated bridgeId.

Research rules:
1. Use primary sources for externally asserted facts: official Signify/Philips Hue developer
   documentation for Hue behavior and official Android/Java security documentation for platform TLS
   behavior. Link each material claim to its source and distinguish documented facts from inference.
2. Do not treat current permissive iOS trust behavior, service names, IP addresses, ports, random
   UUIDs, or unverified mDNS attributes as an Android trust or identity contract.
3. Do not propose a trust-all X509TrustManager, an always-true HostnameVerifier, silent certificate
   acceptance, fabricated bridge IDs, or host:port as durable identity.
4. If primary evidence cannot safely resolve either blocker, say exactly what evidence is missing and
   leave that blocker DEFERRED. Do not fill gaps with implementation assumptions.

Produce one coupled decision proposal covering:

A. D-001 TLS bootstrap
- First-contact server-authentication flow for a Hue self-signed HTTPS bridge.
- Exactly what certificate/bridge evidence is checked before trust is established.
- Ongoing validation after first contact, including pin storage scope and mismatch behavior.
- Hostname/IP handling without a permissive hostname bypass.
- Certificate renewal/replacement, bridge reset/replacement, and user-visible recovery behavior.
- Failure modes and a JVM/instrumented/physical-device validation matrix.

B. D-002 canonical bridge identity
- Authoritative bridge-ID source and evidence that it is stable across DHCP/address changes.
- Normalization/canonicalization compatible with BridgeCredentialAlias, or a narrowly justified alias
  contract change for a later implementation batch.
- How both mDNS selection and manual endpoint entry obtain and verify the same identity.
- Mapping from endpoint to bridgeId before saving the API token; mismatch/duplicate/replacement rules.
- Relationship, if any, between the chosen identity and the TLS certificate evidence.

C. Remaining pairing prerequisite
- Decide whether generateclientkey stays true while clientkey is ignored for MVP, or becomes false,
  using official Hue contract evidence. Do not add CLIENT_KEY persistence.

Required repository output:
1. Preserve the existing blocker history in docs/android/android-pairing-tls-identity-decision.md and
   append a dated "Resolution proposal" section containing the evidence table, threat model, proposed
   contracts, alternatives rejected, recovery behavior, test matrix, and unresolved evidence.
2. Append Claude turns under D-001 and D-002 and a review turn under D-011. Do not rewrite prior agent
   turns. Keep D-001/D-002 DEFERRED and D-011 DISCUSSING unless the written evidence fully resolves
   both blockers; even then, mark the proposal as awaiting Codex/human review, not code-approved.
3. Append one DEVLOG.md handoff. Keep AGENTS.md unchanged unless a currently stated fact is proven
   wrong; flag any proposed contract change instead of silently changing it.
4. Run git diff --check, commit, and push docs/parallel-agent-pipeline so Codex can review the proposal.

Report the recommendation, primary-source links, remaining uncertainties, docs commit SHA, and remote
branch. Stop after the decision packet. A Batch 3 manifest and launch prompt come only after D-001 and
D-002 are explicitly accepted.
```
