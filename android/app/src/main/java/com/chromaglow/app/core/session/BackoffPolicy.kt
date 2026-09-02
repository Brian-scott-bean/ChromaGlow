package com.chromaglow.app.core.session

/** Reconnect schedule for the event stream: 5, 10, 20, 40, 60, 60, … seconds; reset on a successful connection. */
object BackoffPolicy {
    private val STEPS_MILLIS = longArrayOf(5_000L, 10_000L, 20_000L, 40_000L, 60_000L)

    const val CAP_MILLIS: Long = 60_000L

    /** Delay before reconnect attempt number [attempt] (0-based: the first retry waits 5 s). */
    fun delayMillis(attempt: Int): Long = STEPS_MILLIS[attempt.coerceIn(0, STEPS_MILLIS.lastIndex)]
}
