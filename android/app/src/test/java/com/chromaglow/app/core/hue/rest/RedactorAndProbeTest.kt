package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.testing.FakeHueClipTransport
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RedactorAndProbeTest {

    private val bridge = BridgeId("001788FFFE112233")

    // --- Redactor -----------------------------------------------------------------------------

    @Test
    fun redactor_masksHeaderValues_inEveryCommonShape() {
        val key = "AbCdEf0123456789-secret"
        assertEquals("hue-application-key: <redacted>", Redactor.redact("hue-application-key: $key"))
        assertEquals("Hue-Application-Key=<redacted>;", Redactor.redact("Hue-Application-Key=$key;"))
        assertEquals("""{"hue-application-key":"<redacted>"}""", Redactor.redact("""{"hue-application-key":"$key"}"""))
    }

    @Test
    fun redactor_masksUsernameAndClientkeyJson_andExplicitSecrets() {
        assertEquals("""[{"success":{"username":"<redacted>","clientkey":"<redacted>"}}]""",
            Redactor.redact("""[{"success":{"username":"abc123","clientkey":"DEADBEEF"}}]"""))
        assertEquals("token <redacted> here", Redactor.redact("token s3cr3t-value here", secrets = listOf("s3cr3t-value")))
        // Tiny "secrets" are not searched for: masking them would destroy the text without protecting anything.
        assertEquals("a b c", Redactor.redact("a b c", secrets = listOf("a")))
    }

    @Test
    fun applicationKey_isRedactedInToString_copiesInput_andCannotBeUsedOnceCleared() {
        val chars = "my-key-000000".toCharArray()
        val key = ApplicationKey(chars)
        chars.fill('x')
        assertEquals("my-key-000000", key.withHeaderValue { it })
        assertFalse(key.toString().contains("my-key"))
        key.clear()
        assertTrue(key.isCleared)
        assertThrows(IllegalStateException::class.java) { key.withHeaderValue { it } }
        assertThrows(IllegalArgumentException::class.java) { ApplicationKey(CharArray(0)) }
    }

    // --- Bridge identity probe (diagnostic, never fail-closed) ---------------------------------

    @Test
    fun probe_matchingBridgeId_anyCase_isMatch() = runTest {
        val fake = FakeHueClipTransport(bridge)
        fake.collection(ResourceType.BRIDGE, """{"data":[{"id":"b","type":"bridge","bridge_id":"001788fffe112233"}]}""")
        assertEquals(BridgeProbeResult.Match, BridgeIdentityProbe(fake).probe())
        assertEquals("GET", fake.wire.single().method)
        assertEquals(ResourceType.BRIDGE, fake.wire.single().type)
    }

    @Test
    fun probe_differentBridgeId_isMismatch_diagnosticOnly() = runTest {
        val fake = FakeHueClipTransport(bridge)
        fake.collection(ResourceType.BRIDGE, """{"data":[{"id":"b","type":"bridge","bridge_id":"AABBCCDDEEFF0011"}]}""")
        assertEquals(BridgeProbeResult.Mismatch("AABBCCDDEEFF0011"), BridgeIdentityProbe(fake).probe())
    }

    @Test
    fun probe_absentOrMalformedField_isMalformed() = runTest {
        val fake = FakeHueClipTransport(bridge)
        fake.collection(ResourceType.BRIDGE, """{"data":[{"id":"b","type":"bridge"}]}""")
        assertTrue(BridgeIdentityProbe(fake).probe() is BridgeProbeResult.Malformed)
        fake.collection(ResourceType.BRIDGE, """{"data":[{"id":"b","type":"bridge","bridge_id":"not-hex"}]}""")
        assertTrue(BridgeIdentityProbe(fake).probe() is BridgeProbeResult.Malformed)
        fake.collection(ResourceType.BRIDGE, """{"data":[]}""")
        assertTrue(BridgeIdentityProbe(fake).probe() is BridgeProbeResult.Malformed)
    }

    @Test
    fun probe_transportFailure_isUnavailable_carryingTheError() = runTest {
        val fake = FakeHueClipTransport(bridge)
        fake.fail(ResourceType.BRIDGE, ClipError.Timeout(afterTransmission = false))
        assertEquals(BridgeProbeResult.Unavailable(ClipError.Timeout(false)), BridgeIdentityProbe(fake).probe())
    }
}
