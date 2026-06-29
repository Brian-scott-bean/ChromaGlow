package com.chromaglow.app.core.hue.pairing.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeConfigParserTest {

    private fun parse(body: String): BridgeConfigOutcome =
        BridgeConfigParser.parseConfig(body)

    private fun parsed(body: String): BridgeConfig {
        val outcome = parse(body)
        assertTrue("expected Parsed for '$body' but was $outcome", outcome is BridgeConfigOutcome.Parsed)
        return (outcome as BridgeConfigOutcome.Parsed).config
    }

    private fun assertMalformed(body: String) {
        val outcome = parse(body)
        assertTrue("expected Malformed for '$body' but was $outcome", outcome is BridgeConfigOutcome.Malformed)
    }

    @Test
    fun bridgeId_uppercaseHex_isAccepted() {
        val config = parsed("""{"bridgeid":"001788FFFE112233"}""")
        assertEquals("001788FFFE112233", config.bridgeId)
        assertNull(config.replacesBridgeId)
    }

    @Test
    fun bridgeId_lowercase_isNormalizedToUppercase() {
        val config = parsed("""{"bridgeid":"001788fffe112233"}""")
        assertEquals("001788FFFE112233", config.bridgeId)
    }

    @Test
    fun bridgeId_mixedCase_isNormalizedToUppercase() {
        val config = parsed("""{"bridgeid":"001788FffE112233"}""")
        assertEquals("001788FFFE112233", config.bridgeId)
    }

    @Test
    fun replacesBridgeId_optional_isParsedAndUppercasedButNotActiveIdentity() {
        val config = parsed(
            """{"bridgeid":"001788FFFE112233","replacesbridgeid":"aabbccddeeff0011"}""",
        )
        assertEquals("001788FFFE112233", config.bridgeId)
        assertEquals("AABBCCDDEEFF0011", config.replacesBridgeId)
        // The active identity is bridgeId and must never be the replaced one.
        assertTrue(config.bridgeId != config.replacesBridgeId)
    }

    @Test
    fun replacesBridgeId_absent_isNull() {
        assertNull(parsed("""{"bridgeid":"001788FFFE112233"}""").replacesBridgeId)
    }

    @Test
    fun replacesBridgeId_blank_isNull() {
        assertNull(
            parsed("""{"bridgeid":"001788FFFE112233","replacesbridgeid":"   "}""").replacesBridgeId,
        )
    }

    @Test
    fun bridgeId_tooShort_failsClosed() {
        assertMalformed("""{"bridgeid":"001788FFFE1122"}""")
    }

    @Test
    fun bridgeId_tooLong_failsClosed() {
        assertMalformed("""{"bridgeid":"001788FFFE11223344"}""")
    }

    @Test
    fun bridgeId_nonHex_failsClosed() {
        assertMalformed("""{"bridgeid":"001788FFFE11ZZ33"}""")
    }

    @Test
    fun bridgeId_missing_failsClosed() {
        assertMalformed("""{"name":"Hue Bridge"}""")
    }

    @Test
    fun bridgeId_nonString_failsClosed() {
        assertMalformed("""{"bridgeid":1234567890123456}""")
    }

    @Test
    fun malformedJson_failsClosed() {
        assertMalformed("""{"bridgeid":"001788FFFE112233"""")
    }

    @Test
    fun notAnObject_failsClosed() {
        assertMalformed("""["001788FFFE112233"]""")
    }

    @Test
    fun emptyString_failsClosed() {
        assertMalformed("")
    }

    @Test
    fun oversizeBody_failsClosed() {
        val padding = "x".repeat(PairingProtocol.MAX_BODY_BYTES)
        val body = """{"bridgeid":"001788FFFE112233","junk":"$padding"}"""
        assertTrue(body.toByteArray(Charsets.UTF_8).size > PairingProtocol.MAX_BODY_BYTES)
        assertMalformed(body)
    }
}
