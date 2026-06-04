package com.chromaglow.app.core.hue.discovery

import org.junit.Assert.assertEquals
import org.junit.Test

class BridgeEndpointDeduperTest {
    @Test
    fun duplicateHostAndPort_collapsesToOneRow() {
        val endpoints = listOf(
            BridgeEndpoint(name = "Bridge A", host = "192.168.1.2", port = 443),
            BridgeEndpoint(name = "Bridge A", host = "192.168.1.2", port = 443),
        )

        val result = BridgeEndpointDeduper.deduplicate(endpoints)

        assertEquals(1, result.size)
    }

    @Test
    fun differentHosts_remainDistinct() {
        val endpoints = listOf(
            BridgeEndpoint(name = "Bridge A", host = "192.168.1.2", port = 443),
            BridgeEndpoint(name = "Bridge B", host = "192.168.1.3", port = 443),
        )

        val result = BridgeEndpointDeduper.deduplicate(endpoints)

        assertEquals(2, result.size)
    }

    @Test
    fun sameHostDifferentPorts_remainDistinct() {
        val endpoints = listOf(
            BridgeEndpoint(name = "Bridge A", host = "192.168.1.2", port = 443),
            BridgeEndpoint(name = "Bridge A", host = "192.168.1.2", port = 80),
        )

        val result = BridgeEndpointDeduper.deduplicate(endpoints)

        assertEquals(2, result.size)
    }

    @Test
    fun firstSeenEndpoint_wins() {
        val endpoints = listOf(
            BridgeEndpoint(name = "First", host = "192.168.1.2", port = 443),
            BridgeEndpoint(name = "Second", host = "192.168.1.2", port = 443),
        )

        val result = BridgeEndpointDeduper.deduplicate(endpoints)

        assertEquals(1, result.size)
        assertEquals("First", result.first().name)
    }

    @Test
    fun serviceNameDifferences_doNotPreventHostAndPortDedupe() {
        val endpoints = listOf(
            BridgeEndpoint(name = "Philips hue - AABBCC", host = "192.168.1.2", port = 443),
            BridgeEndpoint(name = "Philips hue - DDEEFF", host = "192.168.1.2", port = 443),
        )

        val result = BridgeEndpointDeduper.deduplicate(endpoints)

        assertEquals(1, result.size)
        assertEquals("Philips hue - AABBCC", result.first().name)
    }

    @Test
    fun endpointKey_lowercasesHost() {
        val endpoint = BridgeEndpoint(name = "Bridge", host = "FE80::1", port = 443)

        assertEquals("fe80::1:443", endpoint.endpointKey)
    }

    @Test
    fun ipv4DisplayAddress_isHostColonPort() {
        val endpoint = BridgeEndpoint(name = "Bridge", host = "192.168.1.2", port = 443)

        assertEquals("192.168.1.2:443", endpoint.displayAddress)
    }

    @Test
    fun ipv6DisplayAddress_isBracketedHostColonPort() {
        val endpoint = BridgeEndpoint(name = "Bridge", host = "fe80::1", port = 443)

        assertEquals("[fe80::1]:443", endpoint.displayAddress)
    }

    @Test(expected = IllegalArgumentException::class)
    fun blankName_isRejected() {
        BridgeEndpoint(name = "   ", host = "192.168.1.2", port = 443)
    }

    @Test(expected = IllegalArgumentException::class)
    fun blankHost_isRejected() {
        BridgeEndpoint(name = "Bridge", host = "   ", port = 443)
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidPort_isRejected() {
        BridgeEndpoint(name = "Bridge", host = "192.168.1.2", port = 0)
    }
}
