package com.lelegiptv.tv.ui

import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import com.lelegiptv.tv.data.XtreamProfile
import kotlinx.coroutines.delay

object StreamPlayback {
    fun buildLiveStreamUrls(profile: XtreamProfile, streamId: Int): List<String> {
        val primary = profile.liveContainer.trim().lowercase()
        val first = if (primary == "m3u8") "m3u8" else "ts"
        val second = if (first == "ts") "m3u8" else "ts"
        val base = profile.baseUrl
        val user = profile.username
        val pass = profile.password
        return listOf(
            "$base/live/$user/$pass/$streamId.$first",
            "$base/live/$user/$pass/$streamId.$second",
        )
    }

    fun alternateContainerUrl(url: String): String? {
        val lower = url.lowercase()
        return when {
            lower.endsWith(".ts") -> "${url.dropLast(3)}m3u8"
            lower.endsWith(".m3u8") -> "${url.dropLast(5)}ts"
            else -> null
        }
    }

    fun expandPlaybackUrls(primaryUrl: String): List<String> {
        val alternate = alternateContainerUrl(primaryUrl)
        return if (alternate == null) listOf(primaryUrl) else listOf(primaryUrl, alternate)
    }

    suspend fun playFirstWorkingUrl(
        player: Player,
        urls: List<String>,
        onError: (String?) -> Unit = {},
        maxAttemptsPerUrl: Int = 24,
    ) {
        onError(null)
        if (urls.isEmpty()) {
            player.stop()
            player.clearMediaItems()
            return
        }
        for (url in urls) {
            player.stop()
            player.clearMediaItems()
            player.setMediaItem(MediaItem.fromUri(url))
            player.prepare()
            player.playWhenReady = true
            repeat(maxAttemptsPerUrl) {
                if (player.playbackState == Player.STATE_READY &&
                    (player.duration > 0 || player.videoSize.width > 0 || player.isPlaying)
                ) {
                    return
                }
                val playbackError = player.playerError
                if (playbackError != null) {
                    onError(playbackError.errorCodeName)
                    break
                }
                delay(250)
            }
            if (player.playbackState == Player.STATE_READY && player.playerError == null) {
                onError(null)
                return
            }
        }
        if (player.playerError != null) {
            onError(player.playerError?.errorCodeName)
        }
    }

    /** Anteprima Live: timeout breve per non bloccare la UI durante lo scroll canali. */
    suspend fun playPreviewUrl(
        player: Player,
        urls: List<String>,
        lightweight: Boolean,
        onError: (String?) -> Unit = {},
    ) {
        if (lightweight) {
            playFirstWorkingUrl(
                player = player,
                urls = urls.take(1),
                onError = onError,
                maxAttemptsPerUrl = 6,
            )
        } else {
            playFirstWorkingUrl(
                player = player,
                urls = urls.take(1),
                onError = onError,
                maxAttemptsPerUrl = 8,
            )
        }
    }
}
