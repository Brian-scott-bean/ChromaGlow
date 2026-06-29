package com.chromaglow.app.core.hue.pairing.tls

import java.security.cert.X509Certificate
import javax.security.auth.x500.X500Principal

/**
 * Outcome of extracting a Hue `bridgeid` from a leaf certificate's subject Common Name.
 *
 * Philips Hue bridge leaf certificates are currently SAN-less and identify the bridge via a
 * single `CN` Relative Distinguished Name whose value is the 16-hex-character `bridgeid`.
 */
sealed interface BridgeCommonNameResult {

    /** The leaf carried exactly one well-formed `bridgeid`, normalized to UPPERCASE. */
    data class Valid(val bridgeId: String) : BridgeCommonNameResult

    /** The leaf subject did not satisfy the Common Name identity contract. */
    sealed interface Failure : BridgeCommonNameResult

    /** No `CN` attribute was present in the subject. */
    data object MissingCommonName : Failure

    /** More than one `CN` attribute was present; the identity is ambiguous. */
    data object MultipleCommonNames : Failure

    /** A single `CN` was present but its value is not a 16-hex-character `bridgeid`. */
    data class MalformedCommonName(val rawCommonName: String) : Failure
}

/**
 * Extracts and validates the Hue `bridgeid` carried in a leaf certificate's subject Common Name.
 *
 * This runs the SAN-less identity contract: there must be EXACTLY ONE `CN` Relative
 * Distinguished Name and its value must match `^[0-9A-Fa-f]{16}$`. The returned bridge id is
 * normalized to UPPERCASE so callers can compare case-insensitively against a discovered id.
 *
 * Certificate-chain and validity verification is the responsibility of the trust manager
 * ([HueRootTrustManager]); this extractor only inspects the already-presented subject DN.
 */
object HueBridgeCommonName {

    private const val COMMON_NAME_TYPE = "CN"
    private val BRIDGE_ID_PATTERN = Regex("^[0-9A-Fa-f]{16}$")

    /** Extract the bridge id from [leaf]'s RFC 2253 subject distinguished name. */
    fun extract(leaf: X509Certificate): BridgeCommonNameResult =
        extract(leaf.subjectX500Principal.getName(X500Principal.RFC2253))

    /**
     * Extract the bridge id directly from an RFC 2253 [distinguishedName] string. Exposed for
     * exercising the identity contract against crafted subject DNs.
     */
    fun extract(distinguishedName: String): BridgeCommonNameResult {
        val commonNames = Rfc2253DistinguishedName.parse(distinguishedName)
            .flatten()
            .filter { it.type.equals(COMMON_NAME_TYPE, ignoreCase = true) }

        return when {
            commonNames.isEmpty() -> BridgeCommonNameResult.MissingCommonName
            commonNames.size > 1 -> BridgeCommonNameResult.MultipleCommonNames
            else -> {
                val rawCommonName = commonNames.single().value
                if (BRIDGE_ID_PATTERN.matches(rawCommonName)) {
                    BridgeCommonNameResult.Valid(rawCommonName.uppercase())
                } else {
                    BridgeCommonNameResult.MalformedCommonName(rawCommonName)
                }
            }
        }
    }
}
