package com.chromaglow.app.core.hue.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeDisplayNameTest {

    private val host = "192.168.1.2"

    @Test
    fun ordinaryName_isPreserved() {
        assertEquals("Philips Hue - 1A2B3C", BridgeDisplayName.sanitize("Philips Hue - 1A2B3C", host))
        assertEquals("Küche Brücke", BridgeDisplayName.sanitize("Küche Brücke", host))
    }

    @Test
    fun nullOrBlankName_fallsBackToHost() {
        assertEquals(host, BridgeDisplayName.sanitize(null, host))
        assertEquals(host, BridgeDisplayName.sanitize("", host))
        assertEquals(host, BridgeDisplayName.sanitize("   ", host))
    }

    @Test
    fun bidiOverridesAndIsolates_areStripped() {
        // U+202E RIGHT-TO-LEFT OVERRIDE, U+202C POP, U+2066 LRI, U+2069 PDI, U+200F RLM
        val spoofed = "\u202EHue\u202C \u2066Bridge\u2069\u200F"
        val cleaned = BridgeDisplayName.sanitize(spoofed, host)
        assertEquals("Hue Bridge", cleaned)
        assertFalse(cleaned.any { Character.getType(it).toByte() == Character.FORMAT })
    }

    @Test
    fun nonWhitespaceControlCharacters_vanish() {
        assertEquals("HueBridge", BridgeDisplayName.sanitize("Hue\u0000\u0007Bridge", host))
    }

    @Test
    fun whitespaceControlCharacters_becomeOneSeparator() {
        assertEquals("Hue Bridge", BridgeDisplayName.sanitize("Hue\r\n\tBridge", host))
        assertEquals("Hue Bridge", BridgeDisplayName.sanitize("Hue\u2028Bridge", host))
    }

    @Test
    fun bidiMarkAdjacentToSpace_leavesExactlyOneSpace() {
        assertEquals("Hue Bridge", BridgeDisplayName.sanitize("Hue \u200FBridge", host))
        assertEquals("Hue Bridge", BridgeDisplayName.sanitize("Hue\u200F Bridge", host))
    }

    @Test
    fun zeroWidthJoinersAndPrivateUse_areStripped() {
        assertEquals("HueBridge", BridgeDisplayName.sanitize("Hue\u200D\u200BBridge", host))
        assertEquals("Hue", BridgeDisplayName.sanitize("Hue\uE000\uF8FF", host))
    }

    @Test
    fun whitespaceRuns_collapseToOneSpace_andEdgesTrim() {
        assertEquals("Hue Bridge", BridgeDisplayName.sanitize("   Hue   \u00A0 Bridge   ", host))
    }

    @Test
    fun nameOnlyOfInvisibleCharacters_fallsBackToHost() {
        assertEquals(host, BridgeDisplayName.sanitize("\u202E\u200B\u0000", host))
    }

    @Test
    fun overlongName_isBounded() {
        val long = "A".repeat(500)
        val cleaned = BridgeDisplayName.sanitize(long, host)
        assertEquals(BridgeDisplayName.MAX_LENGTH, cleaned.length)
        assertTrue(cleaned.all { it == 'A' })
    }

    @Test
    fun boundedName_doesNotEndWithTrailingSpace() {
        val name = "A".repeat(BridgeDisplayName.MAX_LENGTH - 1) + " B"
        val cleaned = BridgeDisplayName.sanitize(name, host)
        assertFalse(cleaned.endsWith(" "))
    }
}
