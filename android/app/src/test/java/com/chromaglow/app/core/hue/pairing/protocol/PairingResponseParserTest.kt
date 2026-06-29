package com.chromaglow.app.core.hue.pairing.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingResponseParserTest {

    private fun parse(body: String): CreateUserOutcome =
        PairingResponseParser.parseCreateUser(body)

    private fun assertMalformed(body: String) {
        val outcome = parse(body)
        assertTrue("expected Malformed for '$body' but was $outcome", outcome is CreateUserOutcome.Malformed)
    }

    @Test
    fun success_returnsUsername() {
        val outcome = parse("""[{"success":{"username":"abc123KEY"}}]""")
        assertEquals(CreateUserOutcome.Success("abc123KEY"), outcome)
    }

    @Test
    fun success_isNotRetryable() {
        val outcome = parse("""[{"success":{"username":"abc123KEY"}}]""")
        assertFalse((outcome as CreateUserOutcome.Success).isRetryable)
    }

    @Test
    fun success_withClientKey_ignoresClientKey() {
        val outcome = parse("""[{"success":{"username":"abc123KEY","clientkey":"DEADBEEF00112233"}}]""")
        assertTrue(outcome is CreateUserOutcome.Success)
        assertEquals("abc123KEY", (outcome as CreateUserOutcome.Success).username)
        // The retained outcome must not carry the client key anywhere.
        assertFalse(outcome.toString().contains("DEADBEEF", ignoreCase = true))
        assertFalse(outcome.toString().contains("clientkey", ignoreCase = true))
    }

    @Test
    fun success_blankUsername_failsClosed() {
        assertMalformed("""[{"success":{"username":"   "}}]""")
    }

    @Test
    fun success_missingUsername_failsClosed() {
        assertMalformed("""[{"success":{"foo":"bar"}}]""")
    }

    @Test
    fun success_nonStringUsername_failsClosed() {
        assertMalformed("""[{"success":{"username":12345}}]""")
    }

    @Test
    fun errorType101_isRetryableLinkButton() {
        val outcome = parse("""[{"error":{"type":101,"description":"link button not pressed"}}]""")
        assertEquals(CreateUserOutcome.LinkButtonNotPressed, outcome)
        assertTrue(outcome.isRetryable)
    }

    @Test
    fun errorType7_isInvalidRequest() {
        val outcome = parse("""[{"error":{"type":7,"description":"invalid value"}}]""")
        assertEquals(CreateUserOutcome.InvalidRequest, outcome)
        assertFalse(outcome.isRetryable)
    }

    @Test
    fun unknownErrorType_carriesTypeAndDescription() {
        val outcome = parse("""[{"error":{"type":4,"description":"method not available"}}]""")
        assertEquals(CreateUserOutcome.UnknownError(4, "method not available"), outcome)
        assertFalse(outcome.isRetryable)
    }

    @Test
    fun error_missingNumericType_failsClosed() {
        assertMalformed("""[{"error":{"description":"no type here"}}]""")
    }

    @Test
    fun malformedJson_failsClosed() {
        assertMalformed("""[{"success":{"username":"abc""")
    }

    @Test
    fun notAnArray_failsClosed() {
        assertMalformed("""{"success":{"username":"abc"}}""")
    }

    @Test
    fun emptyArray_failsClosed() {
        assertMalformed("""[]""")
    }

    @Test
    fun multiElementArray_failsClosed() {
        assertMalformed("""[{"success":{"username":"a"}},{"success":{"username":"b"}}]""")
    }

    @Test
    fun mixedSuccessAndError_failsClosed() {
        assertMalformed("""[{"success":{"username":"a"},"error":{"type":7,"description":"x"}}]""")
    }

    @Test
    fun arrayElementNotObject_failsClosed() {
        assertMalformed("""["nope"]""")
    }

    @Test
    fun neitherSuccessNorError_failsClosed() {
        assertMalformed("""[{"other":{"foo":"bar"}}]""")
    }

    @Test
    fun emptyString_failsClosed() {
        assertMalformed("")
    }

    @Test
    fun oversizeBody_failsClosed() {
        // Build a syntactically irrelevant body larger than the 64 KiB guard.
        val huge = "a".repeat(PairingProtocol.MAX_BODY_BYTES + 1)
        assertMalformed(huge)
    }

    @Test
    fun exactlyMaxSizeBody_isNotRejectedForSizeAlone() {
        // A body at exactly the limit must not be rejected for size; here it is valid JSON.
        val username = "u".repeat(PairingProtocol.MAX_BODY_BYTES - 40)
        val body = """[{"success":{"username":"$username"}}]"""
        // Sanity: ensure we are at/under the limit so this exercises the boundary, not oversize.
        assertTrue(body.toByteArray(Charsets.UTF_8).size <= PairingProtocol.MAX_BODY_BYTES)
        assertTrue(parse(body) is CreateUserOutcome.Success)
    }
}
