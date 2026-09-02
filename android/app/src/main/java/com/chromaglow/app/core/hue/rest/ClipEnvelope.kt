package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.hue.rest.wire.ClipJson
import com.chromaglow.app.core.hue.rest.wire.arr
import com.chromaglow.app.core.hue.rest.wire.str
import kotlinx.serialization.json.JsonObject

/** Result of reading a CLIP v2 response body. */
sealed interface ClipEnvelope {
    /** A well-formed envelope. [skippedElements] counts `data[]` entries that were not objects. */
    data class Document(val document: ClipDocument, val skippedElements: Int) : ClipEnvelope

    data class Malformed(val reason: String) : ClipEnvelope
}

/**
 * Tolerant envelope reader: `{"errors":[{"description":…}], "data":[…]}`.
 *  - Body not a JSON object → [ClipEnvelope.Malformed].
 *  - `data` absent or not an array → treated as empty (the bridge omits it on some errors).
 *  - Non-object `data` elements are skipped and counted; they never fail the document.
 *  - `errors[]` entries missing a string description become "unspecified bridge error".
 */
object ClipEnvelopeParser {
    const val UNSPECIFIED_ERROR: String = "unspecified bridge error"

    fun parse(body: String): ClipEnvelope {
        if (body.isBlank()) return ClipEnvelope.Document(ClipDocument(emptyList(), emptyList()), 0)
        val root = ClipJson.parseOrNull(body) as? JsonObject
            ?: return ClipEnvelope.Malformed("response body is not a JSON object")
        var skipped = 0
        val data = root.arr("data")?.mapNotNull { element ->
            (element as? JsonObject).also { if (it == null) skipped++ }
        } ?: emptyList()
        val errors = root.arr("errors")?.map { element ->
            (element as? JsonObject)?.str("description")?.takeIf { it.isNotBlank() } ?: UNSPECIFIED_ERROR
        } ?: emptyList()
        return ClipEnvelope.Document(ClipDocument(data = data, errors = errors), skipped)
    }

    /**
     * The bridge-body policy shared by every 2xx: `errors[]` with no `data` is a refusal wearing
     * a success status ([ClipError.BridgeRejected]); `errors[]` alongside `data` is partial success.
     */
    fun toResult(envelope: ClipEnvelope): ClipResult<ClipDocument> = when (envelope) {
        is ClipEnvelope.Malformed -> ClipResult.Err(ClipError.Decode(envelope.reason))
        is ClipEnvelope.Document -> {
            val doc = envelope.document
            if (doc.errors.isNotEmpty() && doc.data.isEmpty()) {
                ClipResult.Err(ClipError.BridgeRejected(doc.errors))
            } else {
                ClipResult.Ok(doc, partialErrors = doc.errors)
            }
        }
    }
}
