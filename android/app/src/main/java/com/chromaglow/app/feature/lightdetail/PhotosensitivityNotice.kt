package com.chromaglow.app.feature.lightdetail

/**
 * Informational photosensitivity disclosure shown once before the Effects controls. It is a
 * notice, NOT a safety mechanism: the realized-output invariant is enforced in the session layer.
 *
 * Acknowledgement state lives in a [NoticeAcknowledgementStore] injected into
 * [LightDetailViewModel]; this object holds copy only.
 */
object PhotosensitivityNotice {
    const val TITLE: String = "About light effects"
    const val BODY: String =
        "Some firmware effects change brightness and colour continuously. If you or anyone nearby " +
            "is sensitive to flashing or changing light, choose effects with care. Stop an effect at " +
            "any time with None."
    const val ACTION: String = "Got it"
}
