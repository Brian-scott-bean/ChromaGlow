# Android Pairing TLS / Stable-Identity Decision Blocker (ANDROID-006A)

## Status

- **Task:** ANDROID-006A — Record TLS / stable-identity blockers before link-button pairing code
- **Type:** Documentation-only blocker record (read-only investigation reviewed and approved)
- **Branch:** `android/link-button-pairing`
- **Starting SHA:** `0571c6d0e67b6e11e314bf7b1e567b55bb60cf8c`

```text
BLOCKED — SAFE TLS BOOTSTRAP AND CANONICAL BRIDGE IDENTITY MUST BE DECIDED BEFORE LIVE PAIRING CODE
```

- **No pairing runtime code is added in this slice. No network probe was performed.**

## Decision

```text
C. RECORD A DOCS-ONLY TLS / IDENTITY DECISION BLOCKER BEFORE ANY PAIRING CODE
```

This is a **gated blocker record**, not removal of pairing from the roadmap. Runtime link-button pairing remains the next runtime feature — but only after **both** blockers below are resolved in an approved decision.

Clarifications:

- This record does not invent a trust strategy.
- This record does not select or invent a canonical bridge-ID source.
- No pairing runtime code is added in this slice.
- Pairing remains the next runtime feature only after both blockers are resolved in an approved decision.

## Current Android onboarding baseline

The active Android onboarding path is **LAN-only** and remains unchanged by this record:

- **ANDROID-005A** — mDNS bridge-discovery chooser (explicit chooser rows, no silent auto-selection).
- **ANDROID-005B** — local manual endpoint entry (locally parsed, no network resolution).
- **ANDROID-005C** — N-UPnP cloud fallback **deferred** (gated on IOS-BUG-002A).

Pairing is the next runtime feature once both blockers in this record are resolved.

## Pairing contract already known

Recorded as verified evidence only. **Not implemented in code during this docs-only pass.**

- Link-button pairing uses:
  - `POST {scheme}://{host}:{port}/api`
  - `Content-Type: application/json`
  - approximately a **10-second** timeout
- The body contains:
  - `devicetype`
  - `generateclientkey`
- Android's approved device-type constant is:
  - `chromaglow#android`
- The response is a **JSON array**.
- Success contains:
  - `success.username`
  - optional `success.clientkey`
- Hue error type `101` means **link button not pressed** and is **retryable**.
- Hue error type `7` means **invalid body / devicetype**.
- ANDROID-004A deliberately landed an **API-token-only** credential boundary.
- Do **not** add `CLIENT_KEY` persistence in the pairing slice unless a later dedicated task explicitly approves it.

## Stable-identity blocker

Recorded verified facts:

- `BridgeCredentialStore` requires:
  - `saveApiToken(bridgeId: String, token: String)`
  - `loadApiToken(bridgeId: String)`
  - `deleteApiToken(bridgeId: String)`
- `BridgeCredentialAlias` derives its deterministic alias from `bridgeId`.
- The store expects a **stable bridge identity**, not a host or port.
- `BridgeEndpoint` currently provides only:
  - `name`
  - `host`
  - `port`
- mDNS selection does **not** currently produce a canonical bridge ID.
- Manual endpoint entry does **not** currently produce a canonical bridge ID.
- Host + port is suitable for **short-lived routing and deduplication only**.
- Host + port is **not** a durable bridge identity because DHCP changes can move the endpoint.
- The pairing response itself contains **no canonical bridge ID**.
- Do **not** fabricate, randomly generate, or silently substitute a bridge ID.
- Do **not** use the iOS random-UUID storage precedent as the Android identity contract.

The canonical Android `bridgeId` source and mapping rule **remain unresolved**.

Possible evidence sources that would each require a later approved decision (none selected or invented in this pass):

- a trusted local bridge/config response that exposes a stable bridge identifier,
- an mDNS TXT/attribute-derived identifier (only if proven stable across DHCP changes),
- another bridge-provided durable identifier surfaced during a future approved investigation.

No source above is chosen here.

## TLS-bootstrap blocker

Recorded verified facts:

- Real v2 Hue pairing uses local **HTTPS on port `443`**.
- Hue bridges present **self-signed certificates**.
- The repository contains **no approved Android first-contact trust policy**.
- No approved CA, certificate fingerprint, hostname rule, pinning material, or TOFU-bootstrap rule currently exists in repo evidence.
- Host scoping alone is **not** server authentication.
- A permissive `X509TrustManager` is **not** approved.
- A `HostnameVerifier` that blindly returns `true` is **not** approved.
- A TOFU or pinning design **must not** be invented during implementation.
- HTTP-stack selection **remains deferred** until the trust policy is approved.

Recorded plainly:

```text
Safe first-contact TLS trust cannot be derived from current repo evidence alone.
```

## Unsafe iOS precedent that Android must not copy

iOS currently uses **permissive server-trust acceptance** for local Hue HTTPS surfaces.

Clarifications:

- This is **evidence of existing behavior only**.
- It is **not** an approved Android decision.
- Android **must not** copy blanket certificate acceptance.
- Android **must not** suppress trust failures and continue silently.

## Why runtime pairing code is deferred

Both blockers are **independently hard blockers**:

1. A live HTTPS request cannot be added safely without an approved trust bootstrap.
2. A successful API token cannot be stored through the landed credential boundary without a canonical stable `bridgeId`.

A request/parser/UI-only implementation is **not** added during this slice. The blocker record is intentionally small and explicit.

## Preconditions for any future pairing implementation slice

Runtime pairing code is gated on all of the following:

1. An approved Android first-contact and ongoing TLS-trust policy.
2. An approved canonical bridge-ID source.
3. An approved mapping rule from canonical bridge ID to `BridgeCredentialStore`.
4. An explicit decision on whether `generateclientkey` remains `true` while the returned `clientkey` is ignored for MVP, or whether that request flag changes.
5. A bounded follow-up task packet before code edits.
6. Physical-Hue validation on reachable hardware when a device becomes available.

## Future bounded sequencing shape

Described at a high level only (no implementation code or pseudo-code):

- **First:** approve the TLS bootstrap and stable-identity contract.
- **Then:** add a small pure request builder and response parser with JVM tests.
- **Then:** add a narrowly scoped local pairing transport.
- **Then:** wire a setup-card link-button state machine.
- **Then:** persist only the approved API token through the existing credential-store boundary using the approved canonical `bridgeId`.
- Keep bridge metadata persistence, dashboard loading, room control, SSE, scenes, `CLIENT_KEY` persistence, N-UPnP, cloud behavior, and backend wiring **out** of the pairing slice.

## Explicit non-goals

This slice does **not**:

- implement link-button pairing,
- add a pairing client, request builder, response parser, UI state machine, or transport abstraction,
- add a `TrustManager`, `HostnameVerifier`, or network-security-config file,
- invent a TLS trust, pinning, or TOFU strategy,
- select, fabricate, randomly generate, or substitute a canonical bridge ID,
- add `CLIENT_KEY` persistence,
- change Kotlin, Swift, tests, manifest, Gradle, or dependencies,
- issue any network request or endpoint probe,
- stage, commit, push, merge, or open a PR.
