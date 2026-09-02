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
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.MutationEvent
import com.chromaglow.app.core.session.MutationFailure
import com.chromaglow.app.core.session.RefusalReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

const val FEEDBACK_HOST_TAG: String = "feedback_host"

/** What kind of outcome the user is being told about. Copy never carries raw error text. */
enum class FeedbackKind {
    /** The coordinator refused before any wire activity (capability, offline, revoked, denied). */
    REFUSED,

    /** The write failed and the optimistic value was reverted. */
    FAILED_REVERTED,

    /** Delivery is ambiguous or a newer write owns the field; the app refreshes to learn the truth. */
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
    val target: ResourceKey,
)

/** Pure copy for mutation outcomes. Secret-free and free of raw error text by construction. */
object MutationFeedbackCopy {

    /** Null for [MutationEvent.Applied]: success is shown by state, not by a toast. */
    fun from(event: MutationEvent, id: Long, nameOf: (ResourceKey) -> String?): MutationFeedbackUi? {
        val target = event.mutation.target
        val subject = subject(nameOf(target), event.mutation)
        return when (event) {
            is MutationEvent.Applied -> null
            is MutationEvent.Refused -> MutationFeedbackUi(id, FeedbackKind.REFUSED, refusedCopy(subject, event.reason), target)
            is MutationEvent.Failed -> if (event.rolledBack) {
                MutationFeedbackUi(id, FeedbackKind.FAILED_REVERTED, "$subject couldn't be changed. Reverted.", target)
            } else {
                MutationFeedbackUi(id, FeedbackKind.FAILED_UNKNOWN, failedUnknownCopy(subject, event.failure), target)
            }
        }
    }

    fun controlWord(mutation: LiveMutation): String = when (mutation) {
        is LiveMutation.SetPower -> "power"
        is LiveMutation.SetBrightness -> "brightness"
        is LiveMutation.SetColor -> "colour"
        is LiveMutation.SetColorTemperature -> "warmth"
        is LiveMutation.SelectEffect, is LiveMutation.StopEffect -> "effect"
        is LiveMutation.StartTimedEffect, is LiveMutation.CancelTimedEffect -> "timed effect"
        is LiveMutation.SetGradient -> "gradient"
        is LiveMutation.RecallScene -> "scene"
    }

    private fun subject(name: String?, mutation: LiveMutation): String {
        val control = controlWord(mutation)
        return if (mutation is LiveMutation.RecallScene) {
            if (name != null) "The scene $name" else "The scene"
        } else if (name != null) {
            "$name $control"
        } else {
            "The $control"
        }
    }

    private fun refusedCopy(subject: String, reason: RefusalReason): String = when (reason) {
        RefusalReason.CAPABILITY_NOT_KNOWN -> "$subject can't be set yet. Still checking what these lights can do."
        RefusalReason.OFFLINE -> "$subject wasn't sent. The bridge is offline."
        RefusalReason.REVOKED -> "$subject wasn't sent. This app's access was removed on the bridge."
        RefusalReason.EFFECT_DENIED_BY_SAFETY_REGISTER -> "$subject isn't available on this app."
        RefusalReason.TARGET_UNKNOWN -> "$subject wasn't sent. That light or group is no longer known."
        RefusalReason.SESSION_CLOSED -> "$subject wasn't sent. The connection was closed."
        RefusalReason.UNSAFE_DURATION -> "$subject wasn't sent. Choose a longer duration."
    }

    private fun failedUnknownCopy(subject: String, failure: MutationFailure): String = when (failure) {
        MutationFailure.TIMEOUT_AMBIGUOUS -> "Couldn't confirm the change to $subject. Refreshing."
        MutationFailure.UNAUTHORIZED -> "$subject couldn't be changed. This app's access may have been removed."
        MutationFailure.RATE_LIMITED -> "$subject couldn't be changed. The bridge is busy. Refreshing."
        MutationFailure.REJECTED_BY_BRIDGE,
        MutationFailure.HTTP_ERROR,
        MutationFailure.TRANSPORT,
        MutationFailure.DECODE,
        -> "$subject couldn't be changed. Refreshing."
    }
}

/**
 * Collects a session's mutation events for one screen, keeps the newest relevant feedback, and
 * clears it once shown. Latest-wins: a burst shows the most recent message only.
 */
class MutationFeedbackController(
    scope: CoroutineScope,
    events: SharedFlow<MutationEvent>,
    private val isRelevant: (LiveMutation) -> Boolean,
    private val nameOf: (ResourceKey) -> String?,
    private val onEvent: (MutationEvent) -> Unit = {},
) {
    private val counter = MutableStateFlow(0L)
    private val current = MutableStateFlow<MutationFeedbackUi?>(null)

    val feedback: StateFlow<MutationFeedbackUi?> = current.asStateFlow()

    init {
        scope.launch {
            events.collect { event ->
                if (!isRelevant(event.mutation)) return@collect
                onEvent(event)
                MutationFeedbackCopy.from(event, counter.updateAndGet { it + 1 }, nameOf)?.let { current.value = it }
            }
        }
    }

    /** Clear only the message that was shown; a newer one must not be lost. */
    fun dismiss(shown: MutationFeedbackUi) {
        current.update { if (it?.id == shown.id) null else it }
    }

    private fun MutableStateFlow<Long>.updateAndGet(f: (Long) -> Long): Long {
        var result = 0L
        update { v -> f(v).also { result = it } }
        return result
    }
}

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
