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
    compact: Boolean = false,
) {
    val cardHeight = if (compact) 96.dp else 168.dp
    val thumbWidth = if (compact) 118.dp else 200.dp
    val thumbHeight = if (compact) 66.dp else null
    val playIconSize = if (compact) 28.dp else 42.dp
    val playGlyph = if (compact) 12.sp else 16.sp
    FocusCard(
        onClick = onClick,
        focusRequester = focusRequester,
        selected = selected,
        focusScale = if (compact) 1f else 1.02f,
        modifier = modifier
            .fillMaxWidth()
            .height(cardHeight)
            .clip(RoundedCornerShape(6.dp)),
        padding = PaddingValues(0.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .padding(
                        start = if (compact) 8.dp else 12.dp,
                        end = if (compact) 8.dp else 10.dp,
                        top = if (compact) 8.dp else 10.dp,
                        bottom = if (compact) 8.dp else 10.dp,
                    )
                    .then(
                        if (thumbHeight != null) {
                            Modifier.width(thumbWidth).height(thumbHeight)
                        } else {
                            Modifier.width(thumbWidth).aspectRatio(16f / 9f)
                        },
                    )
                    .clip(RoundedCornerShape(if (compact) 6.dp else 8.dp))
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
                            .size(playIconSize)
                            .background(Color(0x99000000), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        BasicText("▶", style = TextStyle(color = Color.White, fontSize = playGlyph))
                    }
                }
                badge?.takeIf { it.isNotBlank() }?.let { label ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(4.dp)
                            .background(Color(0xCC000000), RoundedCornerShape(4.dp))
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    ) {
                        BasicText(
                            label,
                            style = TextStyle(
                                color = Color.White,
                                fontSize = if (compact) 10.sp else 11.sp,
                            ),
                        )
                    }
                }
                progressFraction?.takeIf { it in 0.01f..0.99f }?.let { fraction ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .height(3.dp)
                            .background(Color(0x66000000)),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(fraction)
                                .height(3.dp)
                                .background(TvColors.Accent),
                        )
                    }
                }
            }
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(
                        end = if (compact) 10.dp else 16.dp,
                        top = if (compact) 6.dp else 8.dp,
                        bottom = if (compact) 6.dp else 8.dp,
                    ),
                verticalArrangement = Arrangement.spacedBy(if (compact) 2.dp else 3.dp),
            ) {
                BasicText(
                    eyebrow,
                    style = if (compact) {
                        TvTypography.accentCaptionStyle.copy(fontSize = 10.sp)
                    } else {
                        TvTypography.accentCaptionStyle
                    },
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                BasicText(
                    title.ifBlank { "Senza titolo" },
                    maxLines = if (compact) 2 else 2,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = TvColors.Text,
                        fontSize = if (compact) 12.sp else 14.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = TvTypography.fontFamily,
                        lineHeight = if (compact) 15.sp else 18.sp,
                    ),
                )
                if (!compact) {
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
                            style = TvTypography.listMetaStyle.copy(lineHeight = 15.sp),
                        )
                    }
                }
            }
        }
    }
}
