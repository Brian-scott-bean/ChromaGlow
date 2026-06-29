package com.chromaglow.app.core.bridge

import org.junit.Assert.assertThrows
import org.junit.Assert.assertEquals
import org.junit.Test

class PairedBridgeRecordTest {

    private val validId = "001788FFFE112233"

    @Test
    fun validRecord_isConstructed() {
        val record = PairedBridgeRecord(
            bridgeId = validId,
            name = "Living Room Bridge",
            host = "192.168.1.100",
            port = 443,
            isActive = true,
        )

        assertEquals(validId, record.bridgeId)
        assertEquals(443, record.port)
        assertEquals(true, record.isActive)
    }

    @Test
    fun lowercaseBridgeId_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            PairedBridgeRecord(validId.lowercase(), "B", "h", 443, true)
        }
    }

    @Test
    fun nonHexBridgeId_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            PairedBridgeRecord("ZZ1788FFFE112233", "B", "h", 443, true)
        }
    }

    @Test
    fun wrongLengthBridgeId_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            PairedBridgeRecord("001788FFFE1122", "B", "h", 443, true)
        }
    }

    @Test
    fun blankName_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            PairedBridgeRecord(validId, "  ", "h", 443, true)
        }
    }

    @Test
    fun blankHost_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            PairedBridgeRecord(validId, "B", "", 443, true)
        }
    }

    @Test
    fun portOutOfRange_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            PairedBridgeRecord(validId, "B", "h", 0, true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            PairedBridgeRecord(validId, "B", "h", 65_536, true)
        }
    }
}
