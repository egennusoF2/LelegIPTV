package com.lelegiptv.tv.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@Composable
fun FocusCard(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    selected: Boolean = false,
    padding: PaddingValues = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
    content: @Composable () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val requesterModifier =
        if (focusRequester == null) Modifier else Modifier.focusRequester(focusRequester)
    Box(
        modifier = modifier
            .then(requesterModifier)
            .scale(if (focused) 1.02f else 1f)
            .background(
                when {
                    focused -> TvColors.PanelSelected
                    selected -> TvColors.PanelSelected.copy(alpha = 0.7f)
                    else -> TvColors.Panel
                },
                RoundedCornerShape(6.dp),
            )
            .border(
                BorderStroke(
                    if (focused) 2.dp else 1.dp,
                    if (focused) TvColors.Accent else TvColors.Line,
                ),
                RoundedCornerShape(6.dp),
            )
            .onFocusChanged { focused = it.isFocused }
            .tvActivate(onClick)
            .padding(padding),
    ) {
        content()
    }
}
