package com.lelegiptv.tv.ui

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.lelegiptv.tv.data.XtreamProfile
import kotlinx.coroutines.delay

@OptIn(UnstableApi::class)
object StreamPlayback {
    private const val VodUserAgent = "VLC/3.0.20 LibVLC/3.0.20"
    private const val LiveUserAgent =
        "Mozilla/5.0 (Linux; Android 9; SM-G960F) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 " +
            "IPTVSmartersPlayer/3.1.5"
    private const val ConnectTimeoutMs = 20_000
    private const val ReadTimeoutMs = 30_000
    private val VodExtensions = listOf(
        "mp4", "mkv", "avi", "ts", "m3u8", "mpg", "mov", "m4v", "flv",
    )

    fun buildLiveStreamUrls(profile: XtreamProfile, streamId: Int): List<String> {
        val base = profile.baseUrl
        val user = profile.username
        val pass = profile.password
        val hls = "$base/live/$user/$pass/$streamId.m3u8"
        val ts = "$base/live/$user/$pass/$streamId.ts"
        // Xtream `.ts` is often a short progressive dump: ExoPlayer plays a few
        // seconds then hits EOS. HLS playlists keep fetching the next chunks.
        return listOf(hls, ts)
    }

    fun alternateContainerUrl(url: String): String? {
        val path = url.substringBefore('?')
        val query = url.substringAfter('?', missingDelimiterValue = "")
        val suffix = if (query.isEmpty()) "" else "?$query"
        val lower = path.lowercase()
        return when {
            lower.endsWith(".ts") -> path.dropLast(3) + ".m3u8" + suffix
            lower.endsWith(".m3u8") -> path.dropLast(5) + ".ts" + suffix
            else -> null
        }
    }

    fun expandPlaybackUrls(primaryUrl: String): List<String> {
        val path = primaryUrl.substringBefore('?')
        val query = primaryUrl.substringAfter('?', missingDelimiterValue = "")
        val suffix = if (query.isEmpty()) "" else "?$query"
        val lower = path.lowercase()
        val isVodPath = "/movie/" in lower || "/series/" in lower
        if (isVodPath) {
            val lastDot = path.lastIndexOf('.')
            val lastSlash = path.lastIndexOf('/')
            if (lastDot > lastSlash) {
                val base = path.substring(0, lastDot)
                val primaryExt = path.substring(lastDot + 1).lowercase()
                val ordered = listOf(primaryExt) + VodExtensions.filter { it != primaryExt }
                return ordered.map { "$base.$it$suffix" }.distinct()
            }
        }
        val alternate = alternateContainerUrl(primaryUrl)
        return when {
            alternate == null -> listOf(primaryUrl)
            lower.endsWith(".ts") -> listOf(alternate, primaryUrl)
            else -> listOf(primaryUrl, alternate)
        }
    }

    fun mediaItemFor(url: String): MediaItem {
        val builder = MediaItem.Builder().setUri(url)
        mimeTypeFor(url)?.let(builder::setMimeType)
        if (isHlsUrl(url)) {
            builder.setLiveConfiguration(
                MediaItem.LiveConfiguration.Builder()
                    .setMaxPlaybackSpeed(1.04f)
                    .build(),
            )
        }
        return builder.build()
    }

    fun createPlayer(
        context: Context,
        referer: String,
        preview: Boolean = false,
        live: Boolean = false,
    ): ExoPlayer {
        val dataSource = DefaultHttpDataSource.Factory()
            .setUserAgent(if (live) LiveUserAgent else VodUserAgent)
            .setDefaultRequestProperties(
                mapOf(
                    "Referer" to referer,
                    "Accept" to "*/*",
                    "Connection" to "keep-alive",
                ),
            )
            .setConnectTimeoutMs(ConnectTimeoutMs)
            .setReadTimeoutMs(ReadTimeoutMs)
            .setAllowCrossProtocolRedirects(true)
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                if (preview) 5_000 else 12_000,
                if (preview) 15_000 else 40_000,
                if (preview) 1_000 else 1_500,
                if (preview) 2_000 else 3_000,
            )
            .build()
        return ExoPlayer.Builder(context)
            .setRenderersFactory(
                DefaultRenderersFactory(context).setEnableDecoderFallback(true),
            )
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .setLoadControl(loadControl)
            .setSeekBackIncrementMs(10_000)
            .setSeekForwardIncrementMs(10_000)
            .build()
            .apply {
                videoScalingMode = C.VIDEO_SCALING_MODE_SCALE_TO_FIT
            }
    }

    fun attachLiveContinuity(player: ExoPlayer, isLive: () -> Boolean): Player.Listener {
        var reloads = 0
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) reloads = 0
            }

            override fun onPlaybackStateChanged(state: Int) {
                if (!isLive() || state != Player.STATE_ENDED || reloads >= 8) return
                reloads += 1
                recoverLive(player)
            }

            override fun onPlayerError(error: PlaybackException) {
                if (!isLive() || reloads >= 8) return
                val recoverable =
                    error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW ||
                        error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT ||
                        error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED ||
                        error.errorCode == PlaybackException.ERROR_CODE_IO_UNSPECIFIED ||
                        error.errorCode == PlaybackException.ERROR_CODE_TIMEOUT ||
                        error.errorCode == PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED
                if (!recoverable) return
                reloads += 1
                recoverLive(player)
            }
        }
        player.addListener(listener)
        return listener
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
            player.setMediaItem(mediaItemFor(url))
            player.prepare()
            player.playWhenReady = true
            val hls = isHlsUrl(url)
            val attempts = if (hls) maxAttemptsPerUrl.coerceAtLeast(48) else maxAttemptsPerUrl
            var ready = false
            var attempt = 0
            while (attempt < attempts && player.playerError == null && !ready) {
                if (player.playbackState == Player.STATE_READY || player.isPlaying) {
                    ready = true
                    break
                }
                delay(250)
                attempt += 1
            }
            if (ready && player.playerError == null) {
                onError(null)
                return
            }
            // Slow IPTV HLS can stay in BUFFERING without a hard error. Keep it
            // instead of falling back to a short progressive `.ts` dump.
            if (hls &&
                player.playerError == null &&
                player.playbackState == Player.STATE_BUFFERING
            ) {
                onError(null)
                return
            }
        }
        onError(player.playerError?.errorCodeName)
    }

    suspend fun playPreviewUrl(
        player: Player,
        urls: List<String>,
        lightweight: Boolean,
        onError: (String?) -> Unit = {},
    ) {
        playFirstWorkingUrl(
            player = player,
            urls = urls.take(1),
            onError = onError,
            maxAttemptsPerUrl = if (lightweight) 8 else 12,
        )
    }

    private fun recoverLive(player: ExoPlayer) {
        val current = player.currentMediaItem?.localConfiguration?.uri?.toString().orEmpty()
        val alternate = alternateContainerUrl(current)
        if (current.lowercase().substringBefore('?').endsWith(".ts") && alternate != null) {
            player.setMediaItem(mediaItemFor(alternate))
        } else {
            player.seekToDefaultPosition()
        }
        player.prepare()
        player.playWhenReady = true
    }

    private fun isHlsUrl(url: String): Boolean =
        url.lowercase().substringBefore('?').endsWith(".m3u8")

    private fun mimeTypeFor(url: String): String? {
        val path = url.substringBefore('?').lowercase()
        return when {
            path.endsWith(".m3u8") -> MimeTypes.APPLICATION_M3U8
            path.endsWith(".mpd") -> MimeTypes.APPLICATION_MPD
            path.endsWith(".mp4") -> MimeTypes.VIDEO_MP4
            path.endsWith(".ts") -> MimeTypes.VIDEO_MP2T
            else -> null
        }
    }
}
