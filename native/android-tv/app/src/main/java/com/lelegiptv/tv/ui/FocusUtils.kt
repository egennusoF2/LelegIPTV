package com.lelegiptv.tv.ui

import androidx.compose.foundation.focusable
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import kotlinx.coroutines.delay

/** Evita crash Compose "FocusRequester is not initialized". */
suspend fun FocusRequester.safeRequestFocus() {
    repeat(3) { attempt ->
        try {
            if (attempt > 0) delay(80L * attempt)
            withFrameNanos {}
            requestFocus()
            return
        } catch (_: IllegalStateException) {
            // Focus target non ancora montato.
        }
    }
}

/** Attivazione telecomando: focus + OK/Enter (senza clickable che blocca il D-pad). */
fun Modifier.tvActivate(onActivate: () -> Unit): Modifier =
    focusable()
        .onPreviewKeyEvent { event ->
            if (
                event.type == KeyEventType.KeyDown &&
                (event.key == Key.DirectionCenter ||
                    event.key == Key.Enter ||
                    event.key == Key.NumPadEnter)
            ) {
                onActivate()
                true
            } else {
                false
            }
        }
