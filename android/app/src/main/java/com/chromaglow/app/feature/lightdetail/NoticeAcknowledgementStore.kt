package com.chromaglow.app.feature.lightdetail

/**
 * Where "the photosensitivity notice has been acknowledged" lives. The shell provides a durable
 * (SharedPreferences) implementation and injects it; feature code never touches storage.
 */
interface NoticeAcknowledgementStore {
    fun isAcknowledged(): Boolean

    fun acknowledge()
}

/**
 * Process-memory implementation for tests, previews, and as the constructor default until the
 * shell injects the durable store. Not a singleton: two ViewModels share acknowledgement only
 * when they are handed the same instance.
 */
class InMemoryNoticeAcknowledgementStore(initial: Boolean = false) : NoticeAcknowledgementStore {
    @Volatile
    private var acknowledged: Boolean = initial

    override fun isAcknowledged(): Boolean = acknowledged

    override fun acknowledge() {
        acknowledged = true
    }
}
