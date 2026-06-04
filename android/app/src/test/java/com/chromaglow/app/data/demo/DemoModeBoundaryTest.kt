package com.chromaglow.app.data.demo

import org.junit.Assert.assertTrue
import org.junit.Test

class DemoModeBoundaryTest {
    @Test
    fun enterDemoMode_returnsDemoModeSession() {
        val session = DemoModeBoundary.enterDemoMode()

        assertTrue(session.isDemoMode)
    }
}
