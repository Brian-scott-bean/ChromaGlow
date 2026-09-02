package com.chromaglow.app.core.hue.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class BridgeEndpointTest {

    @Test
    fun plainHosts_areAccepted() {
        assertEquals("192.168.1.2", BridgeEndpoint("Bridge", "192.168.1.2", 443).host)
        assertEquals("fe80::1", BridgeEndpoint("Bridge", "fe80::1", 443).host)
        assertEquals("bridge.local", BridgeEndpoint("Bridge", "bridge.local", 80).host)
    }

    @Test
    fun ipv6ZoneIdHost_isRejected() {
        // L-38: a zone-scoped literal is not a URL host; OkHttp would throw far from the boundary.
        assertThrows(IllegalArgumentException::class.java) {
            BridgeEndpoint("Bridge", "fe80::abcd%wlan0", 443)
        }
        assertThrows(IllegalArgumentException::class.java) {
            BridgeEndpoint("Bridge", "fe80::abcd%25wlan0", 443)
        }
    }

    @Test
    fun hostWithWhitespace_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            BridgeEndpoint("Bridge", "192.168.1.2 ", 443)
        }
        assertThrows(IllegalArgumentException::class.java) {
            BridgeEndpoint("Bridge", "bad host", 443)
        }
    }

    @Test
    fun blankNameHostOrBadPort_areRejected() {
        assertThrows(IllegalArgumentException::class.java) { BridgeEndpoint(" ", "192.168.1.2", 443) }
        assertThrows(IllegalArgumentException::class.java) { BridgeEndpoint("Bridge", " ", 443) }
        assertThrows(IllegalArgumentException::class.java) { BridgeEndpoint("Bridge", "192.168.1.2", 0) }
        assertThrows(IllegalArgumentException::class.java) { BridgeEndpoint("Bridge", "192.168.1.2", 65536) }
    }
}
