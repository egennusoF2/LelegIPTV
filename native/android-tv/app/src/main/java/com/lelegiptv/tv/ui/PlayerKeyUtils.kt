package com.lelegiptv.tv.ui

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type

internal fun KeyEvent.nativeKeyCode(): Int {
    return try {
        @Suppress("DiscouragedPrivateApi")
        val field = KeyEvent::class.java.getDeclaredField("nativeKeyEvent")
        field.isAccessible = true
        (field.get(this) as AndroidKeyEvent).keyCode
    } catch (_: Exception) {
        -1
    }
}

internal fun KeyEvent.isChannelPrevious(): Boolean {
    if (type != KeyEventType.KeyDown) return false
    val code = nativeKeyCode()
    return key == Key.DirectionUp ||
        code == AndroidKeyEvent.KEYCODE_CHANNEL_UP ||
        code == AndroidKeyEvent.KEYCODE_PAGE_UP ||
        code == AndroidKeyEvent.KEYCODE_MEDIA_PREVIOUS
}

internal fun KeyEvent.isChannelNext(): Boolean {
    if (type != KeyEventType.KeyDown) return false
    val code = nativeKeyCode()
    return key == Key.DirectionDown ||
        code == AndroidKeyEvent.KEYCODE_CHANNEL_DOWN ||
        code == AndroidKeyEvent.KEYCODE_PAGE_DOWN ||
        code == AndroidKeyEvent.KEYCODE_MEDIA_NEXT
}
