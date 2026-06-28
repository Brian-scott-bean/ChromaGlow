package com.chromaglow.app.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class SceneDisplayModelTest {
    private fun valid(
        id: String = "scene-1",
        name: String = "Relax",
        roomId: String = "room-1",
        brightness: Int = 30,
        isActive: Boolean = false,
    ) = SceneDisplayModel(
        id = id,
        name = name,
        roomId = roomId,
        brightness = brightness,
        isActive = isActive,
    )

    @Test
    fun construct_withValidInput_succeeds() {
        val scene = valid()

        assertEquals("scene-1", scene.id)
        assertEquals("Relax", scene.name)
        assertEquals("room-1", scene.roomId)
        assertEquals(30, scene.brightness)
        assertFalse(scene.isActive)
    }

    @Test
    fun construct_isActiveDefaultsToFalse() {
        val scene = SceneDisplayModel(
            id = "scene-2",
            name = "Focus",
            roomId = "room-1",
            brightness = 80,
        )

        assertFalse(scene.isActive)
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
