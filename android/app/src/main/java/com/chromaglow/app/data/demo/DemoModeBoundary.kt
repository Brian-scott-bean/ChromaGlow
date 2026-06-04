package com.chromaglow.app.data.demo

data class DemoModeSession(
    val isDemoMode: Boolean,
)

object DemoModeBoundary {
    fun enterDemoMode(): DemoModeSession = DemoModeSession(isDemoMode = true)
}
