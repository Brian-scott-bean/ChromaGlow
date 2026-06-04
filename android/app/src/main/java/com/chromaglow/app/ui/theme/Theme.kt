package com.chromaglow.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val ChromaGlowNoirDarkColorScheme = darkColorScheme(
    primary = ChromaAmber,
    onPrimary = Color.Black,
    primaryContainer = NoirPrimaryContainer,
    onPrimaryContainer = ChromaAmber,
    secondary = NoirSurfaceElevated,
    onSecondary = NoirTextPrimary,
    background = NoirBackground,
    onBackground = NoirTextPrimary,
    surface = NoirSurface,
    onSurface = NoirTextPrimary,
    surfaceVariant = NoirSurfaceElevated,
    onSurfaceVariant = NoirTextSecondary,
    outline = NoirSurfaceBorder,
    error = NoirDestructive,
    onError = Color.White,
)

@Composable
fun ChromaGlowTheme(
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = ChromaGlowNoirDarkColorScheme,
        typography = Typography,
        content = content,
    )
}
