package com.chromaglow.app.core.hue.capability

import com.chromaglow.app.core.identity.ResourceKey

/** "N of M" coverage of a group by lamps that report a capability. */
data class Coverage(val capable: Set<ResourceKey>, val total: Int) {
    init {
        require(total >= 0 && capable.size <= total) { "coverage out of range" }
    }

    val isFull: Boolean get() = total > 0 && capable.size == total
    val isEmpty: Boolean get() = capable.isEmpty()
}

/**
 * The resolver's verdict for a firmware effect on a group. Only [Run] may become a user-facing
 * mutation. [RunUnverified] exists for diagnostics (no member lamp reported ANY effect block, i.e.
 * a decode/firmware gap) and is deliberately NOT a permission to send.
 */
sealed interface EffectRouting {
    /** Whether the coordinator may turn this verdict into an outbound write. */
    val permitsUserMutation: Boolean

    data class Run(val targets: Set<ResourceKey>, val coverage: Coverage) : EffectRouting {
        override val permitsUserMutation: Boolean get() = targets.isNotEmpty()
    }

    data class Unsupported(val effect: String) : EffectRouting {
        override val permitsUserMutation: Boolean get() = false
    }

    data class RunUnverified(val candidates: Set<ResourceKey>) : EffectRouting {
        override val permitsUserMutation: Boolean get() = false
    }
}
