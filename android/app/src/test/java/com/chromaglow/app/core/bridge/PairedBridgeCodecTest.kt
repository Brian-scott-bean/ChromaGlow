package com.chromaglow.app.core.bridge

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PairedBridgeCodecTest {

    private val recordA = PairedBridgeRecord("001788FFFE112233", "Bridge A", "192.168.1.10", 443, true)
    private val recordB = PairedBridgeRecord("AABBCCDDEEFF0011", "Bridge B", "bridge-b.local", 8443, false)

    @Test
    fun encodeThenDecode_roundTripsRecords() {
        val decoded = PairedBridgeCodec.decode(PairedBridgeCodec.encode(listOf(recordA, recordB)))

        assertEquals(listOf(recordA, recordB), decoded)
    }

    @Test
    fun encodeEmptyList_decodesToEmptyList() {
        assertEquals("[]", PairedBridgeCodec.encode(emptyList()))
        assertEquals(emptyList<PairedBridgeRecord>(), PairedBridgeCodec.decode("[]"))
    }

    @Test
    fun encode_onlyEmitsKnownNonSecretFields() {
        val obj = Json.parseToJsonElement(PairedBridgeCodec.encode(listOf(recordA)))
            .jsonArray
            .single() as JsonObject

        assertEquals(
            setOf("bridgeId", "name", "host", "port", "isActive"),
            obj.keys,
        )
        // Defensive: no secret-looking field may ever be emitted by the metadata codec.
        val serialized = PairedBridgeCodec.encode(listOf(recordA)).lowercase()
        assertFalse(serialized.contains("token"))
        assertFalse(serialized.contains("username"))
        assertFalse(serialized.contains("clientkey"))
    }

    // --- recoverable decode --------------------------------------------------------------------

    @Test
    fun decodeRecoverable_allValid_returnsAllWithZeroSkipped() {
        val recovered = PairedBridgeCodec.decodeRecoverable(PairedBridgeCodec.encode(listOf(recordA, recordB)))

        assertEquals(listOf(recordA, recordB), recovered.records)
        assertEquals(0, recovered.skipped)
    }

    @Test
    fun decodeRecoverable_oneDamagedEntry_keepsTheOthers_andCountsIt() {
        val raw = """[
            {"bridgeId":"001788FFFE112233","name":"Bridge A","host":"192.168.1.10","port":443,"isActive":true},
            {"bridgeId":"not-hex","name":"Broken","host":"x","port":443,"isActive":false},
            "not an object",
            {"bridgeId":"AABBCCDDEEFF0011","name":"Bridge B","host":"bridge-b.local","port":8443,"isActive":false}
        ]"""

        val recovered = PairedBridgeCodec.decodeRecoverable(raw)

        assertEquals(listOf(recordA, recordB), recovered.records)
        assertEquals(2, recovered.skipped)
    }

    @Test
    fun decodeRecoverable_duplicateBridgeId_keepsFirst_andCountsTheRest() {
        val dupe = recordA.copy(name = "Later duplicate")
        val recovered = PairedBridgeCodec.decodeRecoverable(PairedBridgeCodec.encode(listOf(recordA, dupe)))

        assertEquals(listOf(recordA), recovered.records)
        assertEquals(1, recovered.skipped)
    }

    @Test
    fun decodeRecoverable_nonArrayRoot_stillThrowsMalformed() {
        assertThrows(MalformedMetadataException::class.java) {
            PairedBridgeCodec.decodeRecoverable("""{"bridgeId":"001788FFFE112233"}""")
        }
        assertThrows(MalformedMetadataException::class.java) {
            PairedBridgeCodec.decodeRecoverable("{ corrupt")
        }
    }

    @Test
    fun decodeStrict_stillFailsOnOneDamagedEntry() {
        // The strict variant keeps all-or-nothing semantics for round-trip checks.
        assertThrows(MalformedMetadataException::class.java) {
            PairedBridgeCodec.decode("""[{"bridgeId":"001788FFFE112233","name":"A","host":"h","port":443,"isActive":true},{"x":1}]""")
        }
    }

    @Test
    fun decode_invalidJson_throwsMalformed() {
        assertThrows(MalformedMetadataException::class.java) {
            PairedBridgeCodec.decode("{ not json")
        }
    }

    @Test
    fun decode_nonArrayRoot_throwsMalformed() {
        assertThrows(MalformedMetadataException::class.java) {
            PairedBridgeCodec.decode("""{"bridgeId":"001788FFFE112233"}""")
        }
    }

    @Test
    fun decode_missingField_throwsMalformed() {
        assertThrows(MalformedMetadataException::class.java) {
            PairedBridgeCodec.decode("""[{"bridgeId":"001788FFFE112233","name":"B","host":"h","port":443}]""")
        }
    }

    @Test
    fun decode_wrongTypedField_throwsMalformed() {
        // port served as a string instead of a number.
        assertThrows(MalformedMetadataException::class.java) {
            PairedBridgeCodec.decode(
                """[{"bridgeId":"001788FFFE112233","name":"B","host":"h","port":"443","isActive":true}]""",
            )
        }
    }

    @Test
    fun decode_recordViolatingGuard_throwsMalformed() {
        // bridgeId lowercase violates the canonical-identity guard.
        assertThrows(MalformedMetadataException::class.java) {
            PairedBridgeCodec.decode(
                """[{"bridgeId":"001788fffe112233","name":"B","host":"h","port":443,"isActive":true}]""",
            )
        }
    }

    @Test
    fun decode_toleratesActiveBooleanVariants() {
        val decoded = PairedBridgeCodec.decode(
            """[{"bridgeId":"001788FFFE112233","name":"B","host":"h","port":443,"isActive":false}]""",
        )

        assertTrue(decoded.single().isActive.not())
    }
}
