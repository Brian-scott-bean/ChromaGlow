package com.chromaglow.app.core.hue.pairing.tls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.security.auth.x500.X500Principal

/**
 * Unit tests for the SAN-less Hue bridge identity extractor. These drive the extractor with
 * crafted subject distinguished names (both raw RFC 2253 strings and ones normalized through a
 * real [X500Principal]) so every branch of the Common Name identity contract is covered without
 * needing a real certificate.
 */
class HueBridgeCommonNameTest {

    private val validBridgeId = "001788FFFE112233"

    /** Normalize through a real X500Principal to mirror what a leaf certificate would yield. */
    private fun fromPrincipal(dn: String) =
        HueBridgeCommonName.extract(X500Principal(dn).getName(X500Principal.RFC2253))

    @Test
    fun singleUppercaseHexCommonName_isValid() {
        val result = fromPrincipal("CN=$validBridgeId,O=Philips Hue,C=NL")
        assertEquals(BridgeCommonNameResult.Valid(validBridgeId), result)
    }

    @Test
    fun lowercaseCommonName_isNormalizedToUppercase() {
        val result = fromPrincipal("CN=001788fffe112233")
        assertEquals(BridgeCommonNameResult.Valid("001788FFFE112233"), result)
    }

    @Test
    fun mixedCaseCommonName_isNormalizedToUppercase() {
        val result = fromPrincipal("CN=001788FffE112233")
        assertEquals(BridgeCommonNameResult.Valid("001788FFFE112233"), result)
    }

    @Test
    fun commonNameAttributeMatchesCaseInsensitively() {
        // X500Principal emits "CN", but make sure a raw lowercase "cn" attribute type still matches.
        val result = HueBridgeCommonName.extract("cn=$validBridgeId")
        assertEquals(BridgeCommonNameResult.Valid(validBridgeId), result)
    }

    @Test
    fun missingCommonName_isMissingFailure() {
        val result = fromPrincipal("O=Philips Hue,C=NL")
        assertEquals(BridgeCommonNameResult.MissingCommonName, result)
    }

    @Test
    fun multipleCommonNames_isMultipleFailure() {
        // Two separate CN RDNs make the identity ambiguous.
        val result = HueBridgeCommonName.extract("CN=$validBridgeId,CN=AABBCCDDEEFF0011")
        assertEquals(BridgeCommonNameResult.MultipleCommonNames, result)
    }

    @Test
    fun tooShortCommonName_isMalformed() {
        val result = fromPrincipal("CN=001788FFFE1122")
        assertTrue(result is BridgeCommonNameResult.MalformedCommonName)
        assertEquals("001788FFFE1122", (result as BridgeCommonNameResult.MalformedCommonName).rawCommonName)
    }

    @Test
    fun tooLongCommonName_isMalformed() {
        val result = fromPrincipal("CN=001788FFFE11223344")
        assertTrue(result is BridgeCommonNameResult.MalformedCommonName)
    }

    @Test
    fun nonHexCommonName_isMalformed() {
        val result = fromPrincipal("CN=001788FFFE11ZZ33")
        assertTrue(result is BridgeCommonNameResult.MalformedCommonName)
    }

    @Test
    fun escapedCommaInCommonName_isMalformedAndKeepsComma() {
        // CN value contains a comma, so it cannot be a 16-hex bridgeid.
        val result = fromPrincipal("""CN=0017\,88FFFE1122,O=x""")
        assertTrue(result is BridgeCommonNameResult.MalformedCommonName)
        assertEquals("0017,88FFFE1122", (result as BridgeCommonNameResult.MalformedCommonName).rawCommonName)
    }

    @Test
    fun emptyCommonName_isMalformed() {
        val result = HueBridgeCommonName.extract("CN=,O=x")
        assertTrue(result is BridgeCommonNameResult.MalformedCommonName)
    }

    @Test
    fun commonNameAmongOtherAttributes_isExtracted() {
        val result = fromPrincipal("C=NL,O=Signify Hue,OU=devices,CN=$validBridgeId")
        assertEquals(BridgeCommonNameResult.Valid(validBridgeId), result)
    }
}
