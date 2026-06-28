package com.lelegiptv.tv.ui

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lelegiptv.tv.R

/** Design tokens aligned with Flutter `LelegColors` and web CSS variables. */
object TvColors {
    val Background = androidx.compose.ui.graphics.Color(0xFF081016)
    val BackgroundDeep = androidx.compose.ui.graphics.Color(0xFF040A0F)
    val BackgroundGlow = androidx.compose.ui.graphics.Color(0xFF0B2530)
    val Sidebar = androidx.compose.ui.graphics.Color(0xFF081016)
    val Surface = androidx.compose.ui.graphics.Color(0xFF121A20)
    val SurfaceDeep = androidx.compose.ui.graphics.Color(0xFF0E151B)
    val Surface2 = androidx.compose.ui.graphics.Color(0xFF172028)
    val Panel = androidx.compose.ui.graphics.Color(0xFF121A20)
    val PanelSelected = androidx.compose.ui.graphics.Color(0xFF1F2B34)
    val Line = androidx.compose.ui.graphics.Color(0xFF2D3A44)
    val Accent = androidx.compose.ui.graphics.Color(0xFF45C7F1)
    val Text = androidx.compose.ui.graphics.Color(0xFFF4F8FB)
    val Muted = androidx.compose.ui.graphics.Color(0xFF9AA7B1)
    val Error = androidx.compose.ui.graphics.Color(0xFFFF7A7A)
}

object TvTypography {
    val fontFamily = FontFamily(
        Font(R.font.geist_regular, FontWeight.Normal),
        Font(R.font.geist_semibold, FontWeight.SemiBold),
        Font(R.font.geist_bold, FontWeight.Bold),
    )

    /** Sizing aligned with Flutter desktop / macOS. */
    val eyebrow = 11.sp
    val pageHeading = 22.sp
    val pageTitle = pageHeading
    val section = 15.sp
    val body = 13.sp
    val caption = 11.sp
    val navLabel = 13.sp
    val brandLabel = 14.sp
    val listTitle = 13.sp
    val listMeta = 11.sp
    val cardTitle = 13.sp
    val cardMeta = 11.sp
    val inputText = 15.sp

    val hubHeight = 360.dp
    val hubProminentTitle = 34.sp
    val hubTitle = 22.sp
    val hubSubtitle = 13.sp
    val hubProminentIcon = 42.dp
    val hubIcon = 30.dp
    val posterWidth = 158.dp
    val sidebarWidth = 200.dp
    val navItemHeight = 40.dp

    val brand = brandLabel
    val hero = pageTitle
    val title = section

    val listTitleStyle = TextStyle(
        color = TvColors.Text,
        fontSize = listTitle,
        fontWeight = FontWeight.SemiBold,
        fontFamily = fontFamily,
    )

    val listMetaStyle = TextStyle(
        color = TvColors.Muted,
        fontSize = listMeta,
        fontFamily = fontFamily,
    )

    val pageHeadingStyle = TextStyle(
        color = TvColors.Text,
        fontSize = pageHeading,
        fontWeight = FontWeight.Black,
        fontFamily = fontFamily,
    )

    val pageEyebrowStyle = TextStyle(
        color = TvColors.Muted,
        fontSize = eyebrow,
        fontWeight = FontWeight.ExtraBold,
        fontFamily = fontFamily,
        letterSpacing = 1.1.sp,
    )

    val heroStyle = pageHeadingStyle

    val titleStyle = TextStyle(
        color = TvColors.Text,
        fontSize = title,
        fontWeight = FontWeight.Bold,
        fontFamily = fontFamily,
    )

    val sectionStyle = TextStyle(
        color = TvColors.Text,
        fontSize = section,
        fontWeight = FontWeight.SemiBold,
        fontFamily = fontFamily,
    )

    val bodyStyle = TextStyle(
        color = TvColors.Text,
        fontSize = body,
        fontWeight = FontWeight.SemiBold,
        fontFamily = fontFamily,
    )

    val mutedStyle = TextStyle(
        color = TvColors.Muted,
        fontSize = body,
        fontFamily = fontFamily,
    )

    val captionStyle = TextStyle(
        color = TvColors.Muted,
        fontSize = caption,
        fontFamily = fontFamily,
    )

    val accentCaptionStyle = TextStyle(
        color = TvColors.Accent,
        fontSize = caption,
        fontWeight = FontWeight.Bold,
        fontFamily = fontFamily,
    )
}
