package com.chromaglow.app.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LightDisplayModelTest {
    private fun valid(
        id: String = "light-1",
        name: String = "Bedside Lamp",
        isOn: Boolean = true,
        brightness: Int = 50,
        roomId: String = "room-1",
        bridgeId: String = "bridge-1",
    ) = LightDisplayModel(
        id = id,
        name = name,
        isOn = isOn,
        brightness = brightness,
        roomId = roomId,
        bridgeId = bridgeId,
    )

    @Test
    fun construct_withValidInput_succeeds() {
        val light = valid()

        assertEquals("light-1", light.id)
        assertEquals("Bedside Lamp", light.name)
        assertTrue(light.isOn)
        assertEquals(50, light.brightness)
        assertEquals("room-1", light.roomId)
        assertEquals("bridge-1", light.bridgeId)
    }

    @Test
    fun construct_withBlankId_throws() {
        assertThrows(IllegalArgumentException::class.java) { valid(id = "") }
        assertThrows(IllegalArgumentException::class.java) { valid(id = "   ") }
    }

    @Test
    fun construct_withBlankName_throws() {
        assertThrows(IllegalArgumentException::class.java) { valid(name = "") }
        assertThrows(IllegalArgumentException::class.java) { valid(name = "   ") }
    }

    @Test
    fun construct_withBlankRoomId_throws() {
        assertThrows(IllegalArgumentException::class.java) { valid(roomId = "") }
        assertThrows(IllegalArgumentException::class.java) { valid(roomId = "   ") }
    }

    @Test
    fun construct_withBlankBridgeId_throws() {
        assertThrows(IllegalArgumentException::class.java) { valid(bridgeId = "") }
        assertThrows(IllegalArgumentException::class.java) { valid(bridgeId = "   ") }
    }

    @Test
    fun construct_withBrightnessTooLow_throws() {
        assertThrows(IllegalArgumentException::class.java) { valid(brightness = 0) }
    }

    @Test
    fun construct_withBrightnessTooHigh_throws() {
        assertThrows(IllegalArgumentException::class.java) { valid(brightness = 101) }
    }

    @Test
    fun construct_withBrightnessAtBounds_succeeds() {
        assertEquals(1, valid(brightness = 1).brightness)
        assertEquals(100, valid(brightness = 100).brightness)
    }
}
