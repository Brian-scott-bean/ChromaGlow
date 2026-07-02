# Android Live Pairing Workflow Contract

## Status

- **State:** ACCEPTED for Batch 4 implementation under D-015.
- **Base:** `main` @ `f3380a7`.
- **Scope:** one-active-bridge onboarding UI backed by a list-ready metadata store, secure token
  persistence, restart restoration, local forget, and one human-assisted physical bridge validation.
- **Not in scope:** Hue resource loading, a real dashboard, REST control, SSE, multi-bridge UI, remote
  application-key revocation, N-UPnP, or legacy self-signed bridges.

## Why Batch 4 Needs Contract Work First

The Batch 3 transport is secure and tested, but two integration facts must be corrected before Setup can
persist a live pairing:

1. `HuePairingResult.Success` currently returns only `username`; it must also return the canonical
   authenticated `bridgeid`, otherwise `BridgeCredentialStore.saveApiToken(bridgeId, token)` cannot be
   called without fabricating or re-fetching identity.
2. mDNS preserves the service-advertised port (commonly the HTTP service port), while the accepted Android
   pairing contract is HTTPS on port 443. Pairing must derive an HTTPS routing endpoint with the selected
   host and fixed port 443 without mutating discovery's raw endpoint model.

## Durable Data Contract

`PairedBridgeRecord` is non-secret routing metadata:

- `bridgeId`: canonical uppercase 16-hex identity authenticated by pairing.
- `name`: non-blank display name from the selected endpoint.
- `host`: non-blank selected routing host.
- `port`: 443 for this MVP pairing path.
- `isActive`: true for the one bridge exposed by Batch 4 UI.

The metadata API must be list-ready even though Batch 4 exposes one active bridge. Store metadata through
Preferences DataStore in `noBackupFilesDir`; never put the API token in DataStore, SharedPreferences,
Compose state, logs, saved state, or test output. Continue storing only the token in
`AndroidKeystoreBridgeCredentialStore`, keyed by canonical `bridgeId`.

Malformed/corrupt metadata and metadata-with-missing-secret are explicit recovery states, not silently
treated as an authenticated session.

## Pairing Transaction

The workflow runs off the main thread and owns this order:

1. Convert the selected discovery/manual endpoint to an HTTPS pairing endpoint on port 443.
2. Call `HuePairingClient.pair(...)`; do not automatically retry a create-user POST.
3. On type 101, return a retryable "press the link button" outcome without persisting anything.
4. On success, receive both authenticated `bridgeId` and `username` from the transport.
5. Save `username` to `BridgeCredentialStore` under `bridgeId`.
6. Upsert the non-secret `PairedBridgeRecord` only after the token save succeeds.
7. If metadata persistence fails, best-effort delete the just-saved token and return a terminal local
   persistence error. Never report pairing as complete with only half the local state committed.
8. Return only the non-secret record to presentation. The token must not escape into UI state.

On startup, a paired state is valid only when the record exists and `loadApiToken(bridgeId)` is Present.
Absent/failing credentials produce a repair/forget state.

"Forget Bridge" is deliberately local-only in Batch 4: delete the local Keystore token, then remove the
metadata record. If either operation fails, show a retryable local cleanup error. The Hue bridge-side
application key may remain until remote revocation is implemented in a later authenticated REST slice;
the UI must say "Forget Bridge", not "Revoke" or "Remove access from bridge".

## Setup UX Contract

Preserve the existing Scan, bridge chooser, manual host entry, Scan Again, and Enter Demo Mode workflows.
Replace the inert selected card with these states:

- **Selected:** bridge name/address, instruction to press the physical bridge button, Pair button.
- **Pairing:** one in-flight attempt, progress indicator, repeated Pair disabled.
- **Link button required:** return to selected state with a concise retry message; retry only on user tap.
- **Paired:** durable "Bridge connected" state, non-secret bridge name/address, local Forget Bridge.
- **Recovery/error:** static user-safe text; never surface raw exceptions, response bodies, bridge IDs,
  tokens, certificate details, or local filesystem paths.

Batch 4 remains on Setup after pairing. It must not route a real bridge into the demo dashboard or seed
DemoFixtures. Batch 5 will add authenticated resource loading and a real dashboard session.

## Validation Contract

Automated:

- Pairing success carries the authenticated bridge ID and preserves all Batch 3 security tests.
- Discovery port 80 maps to pairing/persisted port 443; manual 443 remains 443.
- Type 101 persists nothing; terminal errors persist nothing.
- Token-save failure creates no metadata.
- Metadata-save failure compensates by deleting the just-saved token.
- Restart restoration requires record + readable token.
- Forget deletes local secret and metadata and is idempotent/retryable.
- Compose tests cover selected, pairing, retry, paired, recovery, and local forget states without network.
- Existing demo navigation and all prior tests stay green.

Human-assisted physical gate (redacted evidence only):

1. Select one CA-signed BSB002 bridge by discovery or manual host entry.
2. Tap Pair before pressing the bridge button; verify the type-101 retry UX.
3. Press the physical link button, tap Pair once, and verify "Bridge connected".
4. Force-stop and relaunch; verify the paired state restores without pressing Pair again.
5. Tap Forget Bridge; verify Setup returns and another relaunch remains unpaired.
6. Optionally repeat with the second bridge to exercise both observed certificate-CN casing variants.

Never commit or paste the generated username/token, full bridge ID, local address, or raw log capture.
