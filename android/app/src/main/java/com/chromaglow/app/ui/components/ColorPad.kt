package com.chromaglow.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Gamut
import com.chromaglow.app.core.hue.capability.GamutSource

const val COLOR_PAD_TAG: String = "color_pad"
const val COLOR_PAD_CHIPS_TAG: String = "color_pad_chips"

/**
 * Gamut-aware colour pad. Draws the lamp's own gamut triangle in CIE xy, filled with a coarse
 * colour mesh, and accepts tap/drag; every proposed point is clamped INTO the triangle before
 * [onCommit]. Below the pad a row of named colour chips (48 dp, `selected` semantics) offers the
 * same reach without a 2-D gesture, so colour is never gesture-only.
 *
 * Provenance is stated in words: a spec-derived gamut says so in the footnote.
 */
@Composable
fun ColorPad(
    gamut: Gamut,
    current: CieXy?,
    label: String,
    onPreview: (CieXy) -> Unit,
    onCommit: (CieXy) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    var preview by remember { mutableStateOf<CieXy?>(null) }
    val shown = preview ?: current
    val outline = MaterialTheme.colorScheme.outline
    val marker = MaterialTheme.colorScheme.onSurface

    // Map xy ∈ [0,0.8]² onto the pad; Hue gamuts live inside that window.
    fun toXy(offset: Offset, size: Size): CieXy {
        val x = (offset.x / size.width * 0.8).coerceIn(0.0, 1.0)
        val y = ((1f - offset.y / size.height) * 0.8).coerceIn(0.0, 1.0)
        return ColorMath.clampToGamut(CieXy(x, y), gamut)
    }
    fun toOffset(xy: CieXy, size: Size): Offset =
        Offset((xy.x / 0.8 * size.width).toFloat(), ((1.0 - xy.y / 0.8) * size.height).toFloat())

    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Canvas(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1.35f)
                .testTag(COLOR_PAD_TAG)
                .semantics {
                    contentDescription = label
                    stateDescription = shown?.let { "x ${"%.3f".format(it.x)}, y ${"%.3f".format(it.y)}" } ?: "No colour set"
                }
                .then(
                    if (enabled) {
                        Modifier
                            .pointerInput(gamut) {
                                detectTapGestures { offset ->
                                    val xy = toXy(offset, Size(size.width.toFloat(), size.height.toFloat()))
                                    preview = null
                                    onPreview(xy)
                                    onCommit(xy)
                                }
                            }
                            .pointerInput(gamut) {
                                detectDragGestures(
                                    onDragStart = { offset ->
                                        preview = toXy(offset, Size(size.width.toFloat(), size.height.toFloat()))
                                        preview?.let(onPreview)
                                    },
                                    onDragEnd = {
                                        preview?.let(onCommit)
                                        preview = null
                                    },
                                    onDragCancel = { preview = null },
                                ) { change, _ ->
                                    val xy = toXy(change.position, Size(size.width.toFloat(), size.height.toFloat()))
                                    preview = xy
                                    onPreview(xy)
                                }
                            }
                    } else {
                        Modifier
                    },
                ),
        ) {
            val steps = 22
            val cell = Size(size.width / steps, size.height / steps)
            for (i in 0 until steps) {
                for (j in 0 until steps) {
                    val cx = (i + 0.5) / steps * 0.8
                    val cy = (1.0 - (j + 0.5) / steps) * 0.8
                    val p = CieXy(cx.coerceIn(0.0, 1.0), cy.coerceIn(0.0, 1.0))
                    if (ColorMath.inside(p, gamut.red, gamut.green, gamut.blue)) {
                        drawRect(
                            color = ColorMath.toDisplayColor(p).copy(alpha = if (enabled) 1f else 0.35f),
                            topLeft = Offset(i * cell.width, j * cell.height),
                            size = Size(cell.width + 1f, cell.height + 1f),
                        )
                    }
                }
            }
            val path = Path().apply {
                val r = toOffset(gamut.red, size)
                val g = toOffset(gamut.green, size)
                val b = toOffset(gamut.blue, size)
                moveTo(r.x, r.y); lineTo(g.x, g.y); lineTo(b.x, b.y); close()
            }
            drawPath(path, color = outline, style = Stroke(width = 2.dp.toPx()))
            shown?.let { xy ->
                val o = toOffset(xy, size)
                drawCircle(Color.Black.copy(alpha = 0.5f), radius = 11.dp.toPx(), center = o)
                drawCircle(marker, radius = 9.dp.toPx(), center = o, style = Stroke(width = 2.dp.toPx()))
            }
        }
        ChoiceChipRow(
            options = ColorMath.NAMED.map { ChipOption(id = it.name, label = it.name, swatch = ColorMath.toDisplayColor(it.xy)) },
            selectedId = shown?.let { s -> ColorMath.NAMED.minByOrNull { d -> (d.xy.x - s.x).let { it * it } + (d.xy.y - s.y).let { it * it } }?.takeIf { near -> (near.xy.x - s.x).let { it * it } + (near.xy.y - s.y).let { it * it } < 0.0004 }?.name },
            onSelect = { id ->
                val named = ColorMath.NAMED.first { it.name == id }
                val xy = ColorMath.clampToGamut(named.xy, gamut)
                onPreview(xy)
                onCommit(xy)
            },
            enabled = enabled,
            modifier = Modifier.testTag(COLOR_PAD_CHIPS_TAG),
        )
        Text(
            text = when (gamut.source) {
                GamutSource.BRIDGE -> "Colours limited to what this light reports it can show."
                GamutSource.SPEC_DERIVED -> "Colour range derived from this light's gamut type; the bridge did not publish an exact range."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
