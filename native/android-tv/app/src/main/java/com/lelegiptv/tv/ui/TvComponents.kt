package com.lelegiptv.tv.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AllInclusive
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.LiveTv
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.automirrored.outlined.PlaylistPlay
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun BrandMark(compact: Boolean = true, sidebar: Boolean = false) {
    val fontSize = if (sidebar) 12.sp else TvTypography.brandLabel
    val iconSize = if (sidebar) 20.dp else 24.dp
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = Icons.Filled.AllInclusive,
            contentDescription = null,
            tint = TvColors.Accent,
            modifier = Modifier.size(iconSize),
        )
        Spacer(Modifier.width(if (sidebar) 8.dp else 10.dp))
        BasicText(
            "Leleg",
            style = TextStyle(
                color = TvColors.Text,
                fontSize = fontSize,
                fontWeight = FontWeight.ExtraBold,
                fontFamily = TvTypography.fontFamily,
            ),
        )
        BasicText(
            " IPTV",
            style = TextStyle(
                color = TvColors.Accent,
                fontSize = fontSize,
                fontWeight = FontWeight.Black,
                fontFamily = TvTypography.fontFamily,
            ),
        )
    }
}

@Composable
fun SidebarNavItem(
    label: String,
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    subtitle: String? = null,
) {
    var focused by remember { mutableStateOf(false) }
    val active = selected || focused
    val requesterModifier =
        if (focusRequester == null) Modifier else Modifier.focusRequester(focusRequester)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(if (subtitle.isNullOrBlank()) TvTypography.navItemHeight else 48.dp)
            .then(requesterModifier)
            .scale(if (focused) 1.02f else 1f)
            .clip(RoundedCornerShape(10.dp))
            .background(if (active) TvColors.PanelSelected else Color.Transparent)
            .border(
                BorderStroke(
                    width = if (focused) 2.dp else if (selected) 1.dp else 0.dp,
                    color = when {
                        focused -> TvColors.Accent
                        selected -> TvColors.Accent.copy(alpha = 0.45f)
                        else -> Color.Transparent
                    },
                ),
                RoundedCornerShape(10.dp),
            )
            .onFocusChanged { focused = it.isFocused }
            .tvActivate(onClick)
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (active) TvColors.Accent else TvColors.Muted,
                modifier = Modifier.size(18.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                BasicText(
                    label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = if (active) TvColors.Text else TvColors.Muted,
                        fontSize = TvTypography.navLabel,
                        fontWeight = if (active) FontWeight.ExtraBold else FontWeight.SemiBold,
                        fontFamily = TvTypography.fontFamily,
                    ),
                )
                subtitle?.takeIf { it.isNotBlank() }?.let { line ->
                    BasicText(
                        line,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style = TextStyle(
                            color = if (active) TvColors.Accent else TvColors.Muted,
                            fontSize = TvTypography.caption,
                            fontFamily = TvTypography.fontFamily,
                        ),
                    )
                }
            }
        }
    }
}

@Composable
fun HubTile(
    title: String,
    subtitle: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    prominent: Boolean = false,
    focusRequester: FocusRequester? = null,
) {
    var focused by remember { mutableStateOf(false) }
    val gradientColors =
        if (prominent) {
            listOf(Color(0xFF0E3540), Color(0xFF122026), TvColors.Surface)
        } else {
            listOf(Color(0xFF0D2D36), Color(0xFF142229), TvColors.Surface)
        }
    val requesterModifier =
        if (focusRequester == null) Modifier else Modifier.focusRequester(focusRequester)

    Box(
        modifier = modifier
            .then(requesterModifier)
            .clip(RoundedCornerShape(18.dp))
            .scale(if (focused) 1.015f else 1f)
            .border(
                BorderStroke(
                    width = if (focused) 2.dp else 1.dp,
                    color = if (focused) TvColors.Accent else TvColors.Line,
                ),
                RoundedCornerShape(18.dp),
            )
            .background(
                Brush.linearGradient(
                    colors = gradientColors,
                    start = Offset.Zero,
                    end = Offset(800f, 900f),
                ),
            )
            .onFocusChanged { focused = it.isFocused }
            .tvActivate(onClick)
            .padding(if (prominent) 22.dp else 18.dp),
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = TvColors.Accent,
                    modifier = Modifier.size(
                        if (prominent) TvTypography.hubProminentIcon else TvTypography.hubIcon,
                    ),
                )
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = TvColors.Muted,
                    modifier = Modifier.size(20.dp),
                )
            }
            Spacer(
                Modifier.height(if (prominent) 20.dp else 10.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(if (prominent) 6.dp else 4.dp)) {
                BasicText(
                    title,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = TvColors.Text,
                        fontSize = if (prominent) TvTypography.hubProminentTitle else TvTypography.hubTitle,
                        fontWeight = FontWeight.Black,
                        fontFamily = TvTypography.fontFamily,
                        lineHeight = if (prominent) 32.sp else 24.sp,
                    ),
                )
                BasicText(
                    subtitle,
                    maxLines = if (prominent) 2 else 2,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = TvColors.Muted,
                        fontSize = TvTypography.hubSubtitle,
                        fontFamily = TvTypography.fontFamily,
                    ),
                )
            }
        }
    }
}

object TvNavIcons {
    val Home = Icons.Outlined.Home
    val Live = Icons.Outlined.LiveTv
    val Movies = Icons.Outlined.Movie
    val Series = Icons.Outlined.Layers
    val Search = Icons.Outlined.Search
    val Guide = Icons.Outlined.CalendarMonth
    val Lists = Icons.AutoMirrored.Outlined.PlaylistPlay
}
