package com.chromaglow.app.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics

const val FEEDBACK_HOST_TAG: String = "feedback_host"

/** What kind of outcome the user is being told about. Copy never carries raw error text. */
enum class FeedbackKind {
    /** The coordinator refused before any wire activity (capability, offline, revoked, denied). */
    REFUSED,

    /** The write failed and the optimistic value was reverted. */
    FAILED_REVERTED,

    /** Delivery is ambiguous (e.g. timeout after transmission); the app is refreshing to learn the truth. */
    FAILED_UNKNOWN,
}

/**
 * One piece of mutation feedback for a Snackbar. [id] is monotonic so an identical message
 * shown twice still re-announces; [message] names the control in plain words.
 */
data class MutationFeedbackUi(
    val id: Long,
    val kind: FeedbackKind,
    val message: String,
)

/**
 * Hosts mutation feedback as a Snackbar overlaid at the bottom of [content]. The host carries an
 * explicit polite live region in addition to Snackbar's own announcement. Each new [feedback]
 * id is shown once; [onShown] lets the ViewModel clear it.
 */
@Composable
fun FeedbackHost(
    feedback: MutationFeedbackUi?,
    onShown: (MutationFeedbackUi) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val hostState = remember { SnackbarHostState() }
    LaunchedEffect(feedback?.id) {
        val current = feedback ?: return@LaunchedEffect
        hostState.showSnackbar(message = current.message, duration = SnackbarDuration.Short)
        onShown(current)
    }
    Box(modifier = modifier.fillMaxSize()) {
        content()
        SnackbarHost(
            hostState = hostState,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .testTag(FEEDBACK_HOST_TAG)
                .semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}
