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

---

## Resolution proposal — 2026-06-28 [Claude]

**Status: PROPOSAL — awaiting Codex/human review. NOT code-approved.** D-001 and D-002 remain
**DEFERRED**; D-011 remains **DISCUSSING**. Prepared per
`docs/coordination/prompts/android-pairing-decisions-prepare.md` against `origin/main` @ `7ed6468`. No
source, dependency, or network changes were made; no bridge was probed. Research was primary-source-first
and then adversarially reviewed; several Hue-specific claims were **downgraded** because the authoritative
"Using HTTPS" and Configuration-API pages are behind a Hue developer-account login and could not be read
in this session.

### Evidence table

Legend — **fact**: read from a public official Signify/Hue or platform primary source · **community**:
consistent across community sources but the official page was login-gated/unreadable here · **inference**:
reasoned, not directly documented.

| # | Claim | Type | Source |
| --- | --- | --- | --- |
| 1 | Bridge serves the local Hue API over HTTPS on port 443 (`https://<ip>/api`, `/debug/clip.html`). | fact | developers.meethue.com Get Started |
| 2 | Local HTTPS endpoint added in bridge firmware 1.24; legacy HTTP being phased out. | fact | developers.meethue.com News |
| 3 | First-contact app trust = physical **link-button** push: `POST /api {"devicetype":"<app>#<device>"}` errors until the button is pressed, then returns an opaque **username** (application key). | fact | developers.meethue.com Get Started |
| 4 | Normal light/room/scene/group control authenticates by the **username alone**. | fact | developers.meethue.com Get Started |
| 5 | `generateclientkey:true` also returns a **clientkey** = PSK for **Entertainment** DTLS streaming only (UDP 2100). | community (cipher: RFC 5487) | Q42.HueApi / iotech.blog; RFC 5487 |
| 6 | Discovery = mDNS (`_hue._tcp`) + `https://discovery.meethue.com`; legacy UPnP deprecated (disabled Q2 2022). | fact | developers.meethue.com New Hue API / Get Started |
| 7 | Canonical identity field is **`bridgeid`** (config `bridgeid`; discovery `id`). | fact (field exists) / community (schema) | New Hue API; deCONZ wiki |
| 8 | `bridgeid` is 16 hex, uppercase in `/api/config`, contains `FFFE` mid-way (EUI-48→EUI-64 from MAC; OUI `00:17:88` = Philips). | community + inference | deCONZ wiki; IEEE OUI |
| 9 | Bridge cert **CN = bridgeid**; clients should verify CN == expected bridgeid (identity is the bridgeid, not the IP). | community (official page login-gated) | iotech.blog / callionica, attributed to Using HTTPS |
| 10 | Newer bridges present a cert signed by a **Signify private root CA** (`CN=root-bridge`), published as a bundleable `.pem`; older bridges self-signed. | community (page login-gated; `.pem` not publicly fetchable) | callionica mirror; ebaauw issue (Signify hearsay) |
| 11 | Hue bridges also carry **Matter** device certs from Signify's CA (Matter path, not the local CLIP TLS). | fact | Google Cloud / Signify blog |
| 12 | mDNS TXT, `/api/config` JSON, and host:port are all **unauthenticated** on the LAN → untrusted hints, not identity/trust. | inference (security) | grounded in New Hue API |
| 13 | Android default hostname verification follows **RFC 6125** (matches **SAN**, ignores CN); Network Security Config can pin a private CA trust anchor, but `<pin-set>` is keyed by domain (awkward for IP literals); the alternative is a custom `X509TrustManager`/`HostnameVerifier` — never blanket-true. | platform fact | developer.android.com Network Security Config; RFC 6125 |

### Threat model (first contact on an untrusted LAN)
- A LAN adversary can spoof mDNS, answer at a host:port, or MITM permissive TLS. So host:port and mDNS
  attributes prove nothing; the API token must only be sent to a server whose TLS identity is verified.
- Two independent guarantees are required: **server authentication** (TLS: is this the real bridge?) and
  **proof of physical presence** (the link button: does the user control it?). The username is durable
  only because it is bound to a verified bridge identity.

### Proposed contracts (DRAFT — direction agreed, mechanics deferred)

**D-001 — first-contact + ongoing TLS trust.**
- Never a trust-all `X509TrustManager`, never a blanket-true `HostnameVerifier`, never silent continuation
  past a trust failure (the iOS anti-precedent stands).
- Establish trust by validating BOTH (a) the leaf chains to the **Signify private root CA** (bundled from
  the official `.pem`) and (b) the certificate **identity equals the expected `bridgeid`**.
- App-layer first contact is the **link-button** flow; the token is requested only over the
  identity-verified TLS channel. Re-validate chain + identity every connection; on mismatch fail closed
  and surface a re-pair path.
- **DEFERRED mechanics (block code):** self-signed vs CA-signed on *current* firmware + the migration
  version; whether the official `.pem` matches the community transcription; **whether the leaf carries a
  usable SAN** (decisive — SAN ⇒ Network-Security-Config CA trust anchor can work; CN-only ⇒ a custom
  verifier comparing the leaf identity to `bridgeid` is required because Android ignores CN); leaf
  validity/rotation cadence; the local minimum TLS version; the legacy-self-signed-bridge support policy.

**D-002 — canonical bridge identity.**
- Canonical identity = the bridge-reported **`bridgeid`**, read over the trust-established HTTPS channel
  from `GET /api/0/config`, and (once D-001's binding is settled) cross-checked against the cert identity.
- mDNS `bridgeid` / discovery `id` / host:port are **discovery hints only** — locate the endpoint, never
  stored as identity. `BridgeEndpoint` stays host/port routing-only.
- Both mDNS-selected and manually-entered endpoints derive the SAME identity the same way (`/api/0/config`).
- Normalize `bridgeid` (uppercase); it must satisfy the existing `BridgeCredentialAlias` charset
  `^[A-Za-z0-9_-]+$` (16-hex qualifies) — **no alias-contract change needed**.
- Map endpoint→`bridgeid` BEFORE `saveApiToken`; duplicate → reuse; mismatch/replacement → never overwrite
  silently, prompt re-pair.
- **DEFERRED (block code):** official `bridgeid` charset/length/case; **stability across
  reboot/DHCP/factory-reset** (the core "durable identity" premise — currently inference); the official
  unauthenticated `/api/config` schema; the CN==bridgeid binding that couples D-001 and D-002.

**C — `generateclientkey` (recommendation).**
- For the non-Entertainment MVP, **omit `generateclientkey` (or send `false`)** so no `clientkey` is
  returned, and **do not persist `CLIENT_KEY`** (consistent with the landed API-token-only boundary).
  Normal control needs only the username. Revisit only when Entertainment streaming is scoped.

### Alternatives rejected
- Trust-all TrustManager / blanket-true HostnameVerifier (the iOS precedent) — no server authentication.
- host:port or mDNS service name as durable identity — DHCP-mobile and unauthenticated.
- Fabricated/random UUID bridge id (the iOS storage precedent) — not bridge-authoritative.
- Pure pin-on-first-use with no identity check — a first-contact MITM would be pinned; pinning is
  acceptable only *after* CA-chain + `bridgeid` identity are verified.
- Bundling the community-transcribed root CA as-is — not until byte-verified against the official `.pem`.

### Recovery behavior
- Cert/identity mismatch on a known bridge → fail closed, "couldn't verify this bridge," offer
  re-scan/re-pair; never auto-accept.
- Factory reset/replacement → `bridgeid` may persist (same hardware) or change (new hardware); a
  changed/unknown `bridgeid` is a new pairing (new alias); let the user delete the stale credential.
- CA/cert rotation → absorbed by chaining to the long-lived root CA rather than pinning a leaf, once the
  CA is verified.

### Validation matrix (for the future implementation slice — not run here)
| Layer | What | Notes |
| --- | --- | --- |
| JVM unit | request/response builder+parser; `bridgeid` normalization + alias-charset; error 101/7 mapping | pure, no network |
| Instrumented | credential-store round-trip keyed by canonical `bridgeid`; trust/verifier logic with fixture certs (valid CA-chain + matching id pass; wrong-CA / wrong-id / self-signed / expired fail closed) | emulator |
| Physical bridge (human-approved) | `openssl s_client -connect <ip>:443` for chain/CN/**SAN**/validity/issuer; `GET /api/0/config` for `bridgeid` format; reboot + DHCP change for `bridgeid` stability; full link-button pair | needs a real bridge + explicit approval; never print/persist the token |

### Unresolved evidence (keeps D-001/D-002 DEFERRED) and how to close it
1. Read the login-gated official pages with a Hue developer account — **Using HTTPS** (CA / CN / SAN / the
   `.pem`), **Configuration API "Get configuration"** (`/api/0/config` schema), **Bridge Discovery** (mDNS
   TXT schema), **Core Concepts** — and byte-verify the official root-CA `.pem`.
2. Empirically probe a real bridge (human-approved; never print/persist the token): `openssl s_client` for
   chain / CN / **SAN** / validity / issuer; `/api/0/config` for `bridgeid` format; reboot + DHCP-lease
   change to confirm **`bridgeid` stability**.
3. Confirm the self-signed→CA-signed migration firmware and the legacy-bridge support stance.

Only after (1)–(3) can D-001/D-002 move from DEFERRED to ACCEPTED and a Batch 3 implementation
manifest/launch prompt be drafted.

---

## Codex review — 2026-06-28

**Verdict: directionally reasonable; deferral is correct. NOT code-approved.** D-001 and D-002 remain
DEFERRED and D-011 remains DISCUSSING.

### Required contract corrections

1. The physical link button proves user presence and authorizes application-key creation; it does not
   authenticate the TLS server. Treat it as a separate authorization guarantee, not "first-contact
   transport trust."
2. `bridgeid` is a plausible canonical identity candidate, but an expected `bridgeid` learned only from
   `/api/0/config` over the connection being authenticated cannot independently bootstrap that same
   connection. Acceptance requires an authenticated independent binding (for example, the official
   Signify chain/certificate profile) and a precise rule for the expected identity used by verification.
3. The proposal's evidence table names sources but does not include the direct links required by the
   preparation prompt. The public primary sources independently rechecked by Codex are:
   - [Hue Get Started](https://developers.meethue.com/develop/get-started-2/)
   - [New Hue API](https://developers.meethue.com/new-hue-api/)
   - [Android Network Security Configuration](https://developer.android.com/privacy-and-security/security-config)
   - [Android 9 certificate hostname verification](https://developer.android.com/about/versions/pie/android-9.0-changes-all#certificate-hostname-verification)
   - [Android unsafe HostnameVerifier guidance](https://developer.android.com/privacy-and-security/risks/unsafe-hostname)
4. Keep the `generateclientkey` recommendation proposed, not accepted, until the official Hue API
   contract is available. The public Get Started page verifies username-based control but does not
   document the `generateclientkey`/Entertainment-only claim.

### Evidence assessment

- Public official Hue evidence confirms local HTTPS, link-button application authorization, and that
  Hue moved bridges toward Signify-signed certificates. It does not publish the root certificate or
  define the leaf SAN/CN identity profile needed for an Android verifier.
- Official Android evidence supports custom CA anchors and confirms that modern Android hostname
  verification requires a matching SAN rather than CN fallback. This makes the actual Hue leaf profile
  a blocking input, not an implementation detail.
- No Batch 3 manifest should be drafted until the login-gated official Hue material is captured and/or
  the human approves a read-only real-bridge certificate/config probe. Any probe must redact tokens and
  local addresses from committed evidence.
