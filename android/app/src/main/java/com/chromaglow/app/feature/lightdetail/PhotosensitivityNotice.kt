package com.chromaglow.app.feature.lightdetail

/**
 * Informational photosensitivity disclosure shown once before the Effects controls. It is a
 * notice, NOT a safety mechanism: the realized-output invariant is enforced in the session layer.
 *
 * Acknowledgement is process-scoped here because feature code owns no persistence and no Android
 * context. Durable "once per install" is an ELMO QUESTION for the shell (a shell-provided flag
 * would be injected through the ViewModel's `noticeAcknowledged` parameter).
 */
object PhotosensitivityNotice {
    const val TITLE: String = "About light effects"
    const val BODY: String =
        "Some firmware effects change brightness and colour continuously. If you or anyone nearby " +
            "is sensitive to flashing or changing light, choose effects with care. Stop an effect at " +
            "any time with None."
    const val ACTION: String = "Got it"

    @Volatile
    var acknowledged: Boolean = false
}
