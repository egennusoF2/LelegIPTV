package com.lelegiptv.tv.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp

/** Intestazione pagina in stile macOS: eyebrow sopra, titolo sotto. */
@Composable
fun PageHeader(title: String, subtitle: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        BasicText(
            text = subtitle.uppercase(),
            style = TvTypography.pageEyebrowStyle,
        )
        BasicText(
            text = title,
            style = TvTypography.pageHeadingStyle,
        )
    }
}
