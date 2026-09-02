package com.chromaglow.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** Default semantic test tag suffix; callers pass a full tag via [modifier]. */
const val STAGE_FADER_TRACK_TAG: String = "stage_fader_track"

/**
 * ChromaGlow's brightness/warmth instrument: a thin amber fill on a dark track, a numeric readout,
 * no thumb until touched. Value is an integer in [range].
 *
 * Interaction contract:
 *  - drag or tap changes a LOCAL preview value and calls [onPreview] for each step;
 *  - releasing calls [onCommit] once with the final value (callers send exactly one write);
 *  - accessibility "set progress" (TalkBack swipe, keyboard) previews AND commits immediately;
 *  - when [enabled] is false there is NO pointer input at all — raw gestures are refused, not
 *    merely ignored — and the node carries [disabled] plus [disabledReason] as its state.
 *
 * Semantics: one node with [ProgressBarRangeInfo] over [range], `contentDescription` =
 * [label] (must name the target, e.g. "Living Room brightness"), and a `stateDescription` that
 * reads the value with its unit.
 */
@Composable
fun StageFader(
    value: Int,
    onPreview: (Int) -> Unit,
    onCommit: (Int) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    range: IntRange = 1..100,
    enabled: Boolean = true,
    disabledReason: String? = null,
    unit: String = "%",
    readout: (Int) -> String = { "$it$unit" },
    fillColor: Color = MaterialTheme.colorScheme.primary,
) {
    var preview by remember { mutableStateOf<Int?>(null) }
    val shown = preview ?: value
    val span = (range.last - range.first).coerceAtLeast(1)
    val fraction = ((shown - range.first).toFloat() / span).coerceIn(0f, 1f)
    val trackColor = MaterialTheme.colorScheme.outline
    val disabledFill = MaterialTheme.colorScheme.onSurfaceVariant
    val steps = (span - 1).coerceAtLeast(0)

    fun snap(f: Float): Int = (range.first + (f.coerceIn(0f, 1f) * span)).roundToInt().coerceIn(range)

    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(48.dp)
            .semantics(mergeDescendants = true) {
                contentDescription = label
                stateDescription = if (enabled) readout(shown) else (disabledReason ?: "Unavailable")
                progressBarRangeInfo = ProgressBarRangeInfo(
                    current = shown.toFloat(),
                    range = range.first.toFloat()..range.last.toFloat(),
                    steps = steps,
                )
                if (enabled) {
                    setProgress { target ->
                        val v = target.roundToInt().coerceIn(range)
                        preview = null
                        onPreview(v)
                        onCommit(v)
                        true
                    }
                } else {
                    disabled()
                }
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .weight(1f)
                .height(48.dp)
                .testTag(STAGE_FADER_TRACK_TAG)
                .then(
                    if (enabled) {
                        Modifier
                            .pointerInput(range, span) {
                                detectTapGestures(
                                    onTap = { offset ->
                                        val v = snap(offset.x / size.width)
                                        preview = null
                                        onPreview(v)
                                        onCommit(v)
                                    },
                                )
                            }
                            .pointerInput(range, span) {
                                detectHorizontalDragGestures(
                                    onDragStart = { offset ->
                                        val v = snap(offset.x / size.width)
                                        preview = v
                                        onPreview(v)
                                    },
                                    onDragCancel = { preview = null },
                                    onDragEnd = {
                                        preview?.let(onCommit)
                                        preview = null
                                    },
                                ) { change, _ ->
                                    val v = snap(change.position.x / size.width)
                                    if (v != preview) {
                                        preview = v
                                        onPreview(v)
                                    }
                                }
                            }
                    } else {
                        Modifier
                    },
                ),
        ) {
            Canvas(modifier = Modifier.fillMaxWidth().height(48.dp)) {
                val trackHeight = 6.dp.toPx()
                val top = (size.height - trackHeight) / 2f
                val radius = CornerRadius(trackHeight / 2f)
                drawRoundRect(
                    color = trackColor,
                    topLeft = Offset(0f, top),
                    size = Size(size.width, trackHeight),
                    cornerRadius = radius,
                )
                val fillWidth = size.width * fraction
                if (fillWidth > 0f) {
                    drawRoundRect(
                        color = if (enabled) fillColor else disabledFill.copy(alpha = 0.35f),
                        topLeft = Offset(0f, top),
                        size = Size(fillWidth, trackHeight),
                        cornerRadius = radius,
                    )
                }
                if (preview != null) {
                    drawCircle(
                        color = fillColor,
                        radius = 9.dp.toPx(),
                        center = Offset(fillWidth, size.height / 2f),
                    )
                }
            }
        }
        Text(
            text = readout(shown),
            style = MaterialTheme.typography.labelLarge,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.End,
            modifier = Modifier
                .width(56.dp)
                .padding(start = 8.dp),
        )
    }
}
