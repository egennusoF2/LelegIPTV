package com.lelegiptv.tv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage

@Composable
fun HorizontalMediaCard(
    onClick: () -> Unit,
    imageUrl: String,
    imageContentDescription: String,
    eyebrow: String,
    title: String,
    modifier: Modifier = Modifier,
    badge: String? = null,
    progressFraction: Float? = null,
    subtitle: String? = null,
    description: String? = null,
    selected: Boolean = false,
    focusRequester: FocusRequester? = null,
    showPlayIcon: Boolean = true,
) {
    FocusCard(
        onClick = onClick,
        focusRequester = focusRequester,
        selected = selected,
        modifier = modifier
            .fillMaxWidth()
            .height(132.dp),
        padding = PaddingValues(0.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .padding(10.dp)
                    .width(180.dp)
                    .aspectRatio(16f / 9f)
                    .clip(RoundedCornerShape(6.dp))
                    .background(TvColors.SurfaceDeep),
            ) {
                if (imageUrl.isNotBlank()) {
                    AsyncImage(
                        model = imageUrl,
                        contentDescription = imageContentDescription,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                if (showPlayIcon) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .size(42.dp)
                            .background(Color(0x99000000), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        BasicText("▶", style = TextStyle(color = Color.White, fontSize = 16.sp))
                    }
                }
                badge?.takeIf { it.isNotBlank() }?.let { label ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(6.dp)
                            .background(Color(0xCC000000), RoundedCornerShape(4.dp))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    ) {
                        BasicText(
                            label,
                            style = TextStyle(color = Color.White, fontSize = 11.sp),
                        )
                    }
                }
                progressFraction?.takeIf { it in 0.01f..0.99f }?.let { fraction ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .height(4.dp)
                            .background(Color(0x66000000)),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(fraction)
                                .height(4.dp)
                                .background(TvColors.Accent),
                        )
                    }
                }
            }
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(end = 14.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                BasicText(
                    eyebrow,
                    style = TvTypography.accentCaptionStyle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                BasicText(
                    title.ifBlank { "Senza titolo" },
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = TvColors.Text,
                        fontSize = TvTypography.cardTitle,
                        fontWeight = FontWeight.Bold,
                        fontFamily = TvTypography.fontFamily,
                    ),
                )
                subtitle?.takeIf { it.isNotBlank() }?.let { line ->
                    BasicText(
                        line,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style = TvTypography.listMetaStyle,
                    )
                }
                description?.takeIf { it.isNotBlank() }?.let { line ->
                    BasicText(
                        line,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        style = TvTypography.listMetaStyle,
                    )
                }
            }
        }
    }
}
