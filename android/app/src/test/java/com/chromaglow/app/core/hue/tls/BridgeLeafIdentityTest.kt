package com.chromaglow.app.core.hue.tls

import com.chromaglow.app.core.hue.pairing.tls.BridgeCommonNameResult
import com.chromaglow.app.core.identity.BridgeId
import okhttp3.tls.HeldCertificate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The BRIDGE-ID CASE INVARIANT: BridgeId never normalises; the certificate-CN boundary accepts
 * any-case 16-hex, canonicalises to uppercase, and compares to the expected BridgeId by value.
 */
class BridgeLeafIdentityTest {

    private val expected = BridgeId("001788FFFE112233")
    private val other = BridgeId("AABBCCDDEEFF0011")

    private fun leaf(cn: String) = HeldCertificate.Builder().commonName(cn).ecdsa256().build().certificate

    // --- canonicalize -------------------------------------------------------------------------

    @Test
    fun canonicalize_uppercase_isAccepted() {
        assertEquals(expected, BridgeLeafIdentity.canonicalize("001788FFFE112233"))
    }

    @Test
    fun canonicalize_lowercase_isCanonicalizedToUppercase() {
        assertEquals(expected, BridgeLeafIdentity.canonicalize("001788fffe112233"))
    }

    @Test
    fun canonicalize_mixedCase_isCanonicalizedToUppercase() {
        assertEquals(expected, BridgeLeafIdentity.canonicalize("001788FffE112233"))
        assertEquals(expected, BridgeLeafIdentity.canonicalize("001788ffFE1122aa".replace("aa", "33")))
    }

    @Test
    fun canonicalize_nonHex_isRejected() {
        assertNull(BridgeLeafIdentity.canonicalize("001788FFFE11223G"))
        assertNull(BridgeLeafIdentity.canonicalize("DEMO000000000001"))
        assertNull(BridgeLeafIdentity.canonicalize("ecb5fafffe000000-x"))
    }

    @Test
    fun canonicalize_wrongLength_isRejected() {
        assertNull(BridgeLeafIdentity.canonicalize("001788FFFE11223"))
        assertNull(BridgeLeafIdentity.canonicalize("001788FFFE1122334"))
        assertNull(BridgeLeafIdentity.canonicalize(""))
        assertNull(BridgeLeafIdentity.canonicalize(" 001788FFFE112233"))
    }

    @Test
    fun bridgeIdItself_neverNormalizes() {
        // The invariant this boundary exists to protect: the value type stays strict.
        assertNull(BridgeId.parseOrNull("001788fffe112233"))
        assertEquals(expected, BridgeId.parseOrNull("001788FFFE112233"))
    }

    // --- verify(leaf) ------------------------------------------------------------------------

    @Test
    fun verify_uppercaseCn_matches() {
        assertEquals(LeafIdentityVerdict.Match(expected), BridgeLeafIdentity.verify(leaf("001788FFFE112233"), expected))
    }

    @Test
    fun verify_lowercaseCn_matchesAndCanonicalizes() {
        val verdict = BridgeLeafIdentity.verify(leaf("001788fffe112233"), expected)
        assertEquals(LeafIdentityVerdict.Match(expected), verdict)
        assertEquals("001788FFFE112233", (verdict as LeafIdentityVerdict.Match).bridgeId.value)
    }

    @Test
    fun verify_mixedCaseCn_canonicalizes() {
        assertEquals(LeafIdentityVerdict.Match(expected), BridgeLeafIdentity.verify(leaf("001788FffE112233"), expected))
    }

    @Test
    fun verify_nonHexCn_isMalformed() {
        val verdict = BridgeLeafIdentity.verify(leaf("001788FFFE11223Z"), expected)
        assertTrue(verdict is LeafIdentityVerdict.Malformed)
        assertTrue((verdict as LeafIdentityVerdict.Malformed).reason is BridgeCommonNameResult.MalformedCommonName)
    }

    @Test
    fun verify_wrongLengthCn_isMalformed() {
        assertTrue(BridgeLeafIdentity.verify(leaf("001788FFFE11223"), expected) is LeafIdentityVerdict.Malformed)
        assertTrue(BridgeLeafIdentity.verify(leaf("001788FFFE1122334"), expected) is LeafIdentityVerdict.Malformed)
    }

    @Test
    fun verify_canonicalizedCnNotEqualToExpected_failsClosedAsMismatch() {
        val verdict = BridgeLeafIdentity.verify(leaf("aabbccddeeff0011"), expected)
        assertEquals(LeafIdentityVerdict.Mismatch(expected = expected, presented = other), verdict)
    }

    @Test
    fun verify_leafWithDefaultUuidCn_isMalformed() {
        // okhttp-tls always emits a CN (a random UUID by default); a UUID is not a bridge id.
        val uuidCn = HeldCertificate.Builder().organizationalUnit("no-bridge-cn").ecdsa256().build().certificate
        val verdict = BridgeLeafIdentity.verify(uuidCn, expected)
        assertTrue(verdict is LeafIdentityVerdict.Malformed)
        assertTrue((verdict as LeafIdentityVerdict.Malformed).reason is BridgeCommonNameResult.MalformedCommonName)
    }

    @Test
    fun verify_nullSession_isNoVerifiedPeer() {
        assertEquals(LeafIdentityVerdict.NoVerifiedPeer, BridgeLeafIdentity.verify(null, expected))
    }

    // --- hostname verifier ---------------------------------------------------------------------

    @Test
    fun hostnameVerifier_nullSession_isFalse_andNeverConsultsHostname() {
        val verifier = BridgeIdHostnameVerifier(expected)
        assertFalse(verifier.verify("001788FFFE112233.local", null))
        assertFalse(verifier.verify(null, null))
        assertEquals(LeafIdentityVerdict.NoVerifiedPeer, verifier.lastVerdict)
    }

    @Test
    fun hueTrust_cachesOneVerifierPerBridge() {
        val ca = HeldCertificate.Builder().certificateAuthority(0).commonName("Test CA").ecdsa256().build()
        val trust = HueTrust.fromCertificateAuthorities(listOf(ca.certificate))
        val a1 = trust.forBridge(expected)
        val a2 = trust.forBridge(expected)
        val b = trust.forBridge(other)
        assertSame(a1, a2)
        assertSame(a1.hostnameVerifier, a2.hostnameVerifier)
        assertEquals(expected, a1.hostnameVerifier.expected)
        assertEquals(other, b.hostnameVerifier.expected)
        assertSame(a1.sslSocketFactory, b.sslSocketFactory)
    }
}
