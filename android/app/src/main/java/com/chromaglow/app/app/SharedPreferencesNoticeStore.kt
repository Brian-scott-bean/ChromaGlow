package com.chromaglow.app.app

import android.content.Context
import android.content.SharedPreferences
import com.chromaglow.app.feature.lightdetail.NoticeAcknowledgementStore

/**
 * Durable, local-only acknowledgement of the photosensitivity notice (C-2). Plain
 * SharedPreferences: no credential, no cloud dependency — the app opts out of backup and its
 * extraction rules exclude shared prefs, so the flag never leaves the device. Reset only by
 * clearing app data. The notice is informational and is not a safety control.
 */
class SharedPreferencesNoticeStore(context: Context) : NoticeAcknowledgementStore {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun isAcknowledged(): Boolean = prefs.getBoolean(KEY_PHOTOSENSITIVITY, false)

    override fun acknowledge() {
        prefs.edit().putBoolean(KEY_PHOTOSENSITIVITY, true).apply()
    }

    private companion object {
        const val FILE = "chromaglow.notices"
        const val KEY_PHOTOSENSITIVITY = "photosensitivity_acknowledged"
    }
}
