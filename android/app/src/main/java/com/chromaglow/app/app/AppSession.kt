package com.chromaglow.app.app

import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.data.demo.DemoModeSession

/**
 * The single app-level mode the router switches on. Demo and Live never share a state container:
 * demo keeps the shell-owned in-memory lists; live exposes [LiveHome]. Owned by ChromaGlowApp.
 */
sealed interface AppSession {
    data object None : AppSession
    data class Demo(val session: DemoModeSession) : AppSession
    data class Live(val home: LiveHome) : AppSession
}
