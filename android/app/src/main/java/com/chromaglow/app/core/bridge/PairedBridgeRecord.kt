package com.chromaglow.app.core.bridge

/**
 * Non-secret routing metadata for a paired Hue bridge.
 *
 * This record is deliberately free of secrets: it NEVER carries the application key / username or
 * any other credential. The bridge token lives only in
 * [com.chromaglow.app.core.credentials.BridgeCredentialStore] (Android Keystore), keyed by the same
 * canonical [bridgeId]. A [PairedBridgeRecord] is safe to persist in a Preferences DataStore, list
 * in UI, and log structurally without leaking a secret.
 *
 * All inputs are guarded so a malformed record can never be constructed; the registry treats a
 * construction failure while decoding stored metadata as corruption (an explicit recovery state),
 * never as an authenticated session.
 *
 * @property bridgeId canonical authenticated identity: exactly 16 UPPERCASE hex characters, as
 *   produced by the pairing transport from the CA-validated leaf Common Name.
 * @property name non-blank display name from the selected discovery/manual endpoint.
 * @property host non-blank routing host selected by the user.
 * @property port routing port (1..65535). The Batch 4 pairing path always uses 443.
 * @property isActive whether this is the one bridge surfaced by the current Batch 4 UI. The store
 *   is list-ready, so multiple records may exist even while exactly one is active.
 */
data class PairedBridgeRecord(
    val bridgeId: String,
    val name: String,
    val host: String,
    val port: Int,
    val isActive: Boolean,
) {
    init {
        require(CANONICAL_BRIDGE_ID.matches(bridgeId)) {
            "bridgeId must be exactly 16 uppercase hex characters"
        }
        require(name.isNotBlank()) { "name must not be blank" }
        require(host.isNotBlank()) { "host must not be blank" }
        require(port in 1..65535) { "port must be in 1..65535" }
    }

    companion object {
        /** Canonical paired-bridge identity: exactly 16 UPPERCASE hex characters (D-002). */
        private val CANONICAL_BRIDGE_ID = Regex("^[0-9A-F]{16}$")
    }
}
