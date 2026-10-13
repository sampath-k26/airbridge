package com.mahi.airbridge.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

private val Brand = Color(0xFF1F6FEB)

private val Light = lightColorScheme(
    primary = Brand, onPrimary = Color.White,
    primaryContainer = Color(0xFFDCE8FD), onPrimaryContainer = Color(0xFF0A2A5E),
    secondary = Color(0xFF475569), onSecondary = Color.White,
    tertiary = Color(0xFF0E9F6E),
    background = Color(0xFFF7F8FA), onBackground = Color(0xFF0F172A),
    surface = Color.White, onSurface = Color(0xFF0F172A),
    surfaceVariant = Color(0xFFEEF1F5), onSurfaceVariant = Color(0xFF5B6475),
    surfaceContainer = Color(0xFFFFFFFF), surfaceContainerHigh = Color(0xFFF1F3F7),
    outline = Color(0xFFD5DAE1), outlineVariant = Color(0xFFE6E9EE),
    error = Color(0xFFD1242F), errorContainer = Color(0xFFFDE7E9),
)

private val Dark = darkColorScheme(
    primary = Color(0xFF6EA8FE), onPrimary = Color(0xFF07214D),
    primaryContainer = Color(0xFF15386E), onPrimaryContainer = Color(0xFFDCE8FD),
    secondary = Color(0xFF94A3B8), onSecondary = Color(0xFF0F172A),
    tertiary = Color(0xFF34D399),
    background = Color(0xFF0E1116), onBackground = Color(0xFFE6EAF0),
    surface = Color(0xFF161B22), onSurface = Color(0xFFE6EAF0),
    surfaceVariant = Color(0xFF1F2630), onSurfaceVariant = Color(0xFF9AA4B2),
    surfaceContainer = Color(0xFF161B22), surfaceContainerHigh = Color(0xFF1F2630),
    outline = Color(0xFF30363D), outlineVariant = Color(0xFF262C34),
    error = Color(0xFFFF7B72), errorContainer = Color(0xFF3D1517),
)

@Composable
fun AirBridgeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) Dark else Light,
        shapes = Shapes(small = RoundedCornerShape(10.dp), medium = RoundedCornerShape(14.dp), large = RoundedCornerShape(20.dp)),
        content = content,
    )
}
