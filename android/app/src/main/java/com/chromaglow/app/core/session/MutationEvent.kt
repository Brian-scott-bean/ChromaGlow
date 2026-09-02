package com.chromaglow.app.core.session

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

/** Why a mutation that left the coordinator did not (provably) apply. Secret-free: no strings. */
enum class MutationFailure {
    REJECTED_BY_BRIDGE,
    UNAUTHORIZED,
    RATE_LIMITED,
    HTTP_ERROR,
    TRANSPORT,

    /** The body reached the socket and no answer came back: the lamp may hold the new value; a refresh reconciles. */
    TIMEOUT_AMBIGUOUS,
    DECODE,
}

/**
 * Honest post-admission feedback for the UI (C-1). [Refused] never reached the wire; [Applied]
 * was acknowledged by the bridge; [Failed] did not (or may not have) apply, and [Failed.rolledBack]
 * says whether the optimistic value was reverted (false when a newer write already owned the
 * field, or when the outcome was ambiguous and the refresh reconciles instead).
 */
sealed interface MutationEvent {
    val mutation: LiveMutation

    data class Refused(override val mutation: LiveMutation, val reason: RefusalReason) : MutationEvent

    data class Applied(override val mutation: LiveMutation) : MutationEvent

    data class Failed(override val mutation: LiveMutation, val failure: MutationFailure, val rolledBack: Boolean) : MutationEvent
}

object MutationEvents {
    /** The default for implementations that emit nothing (fakes, demo). Never completes, never emits. */
    val NONE: SharedFlow<MutationEvent> = MutableSharedFlow()

    /** A sink sized for bursts; slow collectors drop the oldest, never suspend the coordinator. */
    fun sink(): MutableSharedFlow<MutationEvent> = MutableSharedFlow(extraBufferCapacity = 64, onBufferOverflow = kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST)
}
