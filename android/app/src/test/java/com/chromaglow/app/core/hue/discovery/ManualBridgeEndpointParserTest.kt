package com.chromaglow.app.core.hue.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ManualBridgeEndpointParserTest {

    private fun valid(raw: String): BridgeEndpoint {
        val result = ManualBridgeEndpointParser.parse(raw)
        assertTrue("expected valid for '$raw' but was $result", result is ManualBridgeEndpointParser.Parsed.Valid)
        return (result as ManualBridgeEndpointParser.Parsed.Valid).endpoint
    }

    private fun assertInvalid(raw: String) {
        val result = ManualBridgeEndpointParser.parse(raw)
        assertTrue("expected invalid for '$raw' but was $result", result is ManualBridgeEndpointParser.Parsed.Invalid)
    }

    @Test
    fun validIpv4_isAccepted() {
        val endpoint = valid("192.168.1.100")
        assertEquals("192.168.1.100", endpoint.host)
    }

    @Test
    fun whitespaceWrappedIpv4_isTrimmedAndAccepted() {
        val endpoint = valid("  192.168.1.100  ")
        assertEquals("192.168.1.100", endpoint.host)
    }

    @Test
    fun bareIpv6_isAccepted() {
        val endpoint = valid("fe80::1")
        assertEquals("fe80::1", endpoint.host)
    }

    @Test
    fun bracketedIpv6_isStoredUnbracketed() {
        val endpoint = valid("[2001:db8::1]")
        assertEquals("2001:db8::1", endpoint.host)
    }

    @Test
    fun dottedHostname_isAccepted() {
        val endpoint = valid("bridge.local")
        assertEquals("bridge.local", endpoint.host)
    }

    @Test
    fun singleLabelHostname_isAccepted() {
        val endpoint = valid("huebridge")
        assertEquals("huebridge", endpoint.host)
    }

    @Test
    fun blankInput_isRejected() {
        assertInvalid("")
    }

    @Test
    fun whitespaceOnlyInput_isRejected() {
        assertInvalid("    ")
    }

    @Test
    fun ipv4OctetAbove255_isRejected() {
        assertInvalid("256.1.1.1")
    }

    @Test
    fun ipv4WithTooFewOctets_isRejected() {
        assertInvalid("192.168.1")
    }

    @Test
    fun ipv4WithTooManyOctets_isRejected() {
        assertInvalid("192.168.1.100.5")
    }

    @Test
    fun malformedIpv6_isRejected() {
        assertInvalid("2001:db8:::xyz")
    }

    @Test
    fun ipv6WithMultipleCompressionMarkers_isRejected() {
        assertInvalid("2001::db8::1")
    }

    @Test
    fun ipv6WithZoneId_isRejected() {
        assertInvalid("fe80::1%eth0")
    }

    @Test
    fun schemePrefixedInput_isRejected() {
        assertInvalid("https://192.168.1.100")
    }

    @Test
    fun inputWithPath_isRejected() {
        assertInvalid("192.168.1.100/api")
    }

    @Test
    fun inputWithEmbeddedWhitespace_isRejected() {
        assertInvalid("192.168.1 .100")
    }

    @Test
    fun hostnameLabelStartingWithHyphen_isRejected() {
        assertInvalid("-bridge.local")
    }

    @Test
    fun hostnameLabelEndingWithHyphen_isRejected() {
        assertInvalid("bridge-.local")
    }

    @Test
    fun hostnameLabelLongerThan63_isRejected() {
        val longLabel = "a".repeat(64)
        assertInvalid("$longLabel.local")
    }

    @Test
    fun defaultPort_is443() {
        assertEquals(443, valid("192.168.1.100").port)
    }

    @Test
    fun syntheticName_isManualBridge() {
        assertEquals("Manual bridge", valid("192.168.1.100").name)
    }

    @Test
    fun ipv6_isStoredWithoutBrackets() {
        assertEquals("2001:db8::1", valid("[2001:db8::1]").host)
        assertEquals("fe80::1", valid("fe80::1").host)
    }

    @Test
    fun ipv6DisplayAddress_hasExactlyOneBracketPair() {
        val display = valid("[2001:db8::1]").displayAddress
        assertEquals("[2001:db8::1]:443", display)
        assertEquals(1, display.count { it == '[' })
        assertEquals(1, display.count { it == ']' })
    }

    @Test
    fun ipv4DisplayAddress_isHostColonPort() {
        assertEquals("192.168.1.100:443", valid("192.168.1.100").displayAddress)
    }
}
