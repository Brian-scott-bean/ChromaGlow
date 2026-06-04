package com.chromaglow.app.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.chromaglow.app.data.demo.DemoModeBoundary
import com.chromaglow.app.data.demo.DemoModeSession
import com.chromaglow.app.feature.dashboard.DashboardPlaceholderScreen
import com.chromaglow.app.feature.setup.SetupPlaceholderScreen

@Composable
fun ChromaGlowApp() {
    var destination by remember { mutableStateOf(ChromaGlowDestination.Setup) }
    var demoSession by remember { mutableStateOf<DemoModeSession?>(null) }

    when (destination) {
        ChromaGlowDestination.Setup -> SetupPlaceholderScreen(
            onEnterDemoMode = {
                demoSession = DemoModeBoundary.enterDemoMode()
                destination = ChromaGlowDestination.Dashboard
            },
        )

        ChromaGlowDestination.Dashboard -> DashboardPlaceholderScreen(
            demoSession = demoSession,
            onBackToSetup = {
                demoSession = null
                destination = ChromaGlowDestination.Setup
            },
        )
    }
}
