package com.lelegiptv.tv

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.core.view.WindowCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lelegiptv.tv.ui.LelegTvApp
import com.lelegiptv.tv.ui.TvColors
import com.lelegiptv.tv.ui.TvTypography

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContent {
            LelegTvTheme {
                LelegTvApp(viewModel())
            }
        }
    }
}

@Composable
private fun LelegTvTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            background = TvColors.Background,
            surface = TvColors.Surface,
            primary = TvColors.Accent,
            onBackground = TvColors.Text,
            onSurface = TvColors.Text,
        ),
        typography = MaterialTheme.typography.copy(
            bodyLarge = TvTypography.bodyStyle,
            bodyMedium = TvTypography.mutedStyle,
            titleLarge = TvTypography.titleStyle,
            headlineLarge = TvTypography.heroStyle,
            labelLarge = TvTypography.sectionStyle,
        ),
        content = content,
    )
}
