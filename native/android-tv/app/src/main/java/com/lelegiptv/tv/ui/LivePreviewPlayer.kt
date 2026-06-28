package com.lelegiptv.tv.ui

import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.lelegiptv.tv.data.LiveChannel
import com.lelegiptv.tv.data.XtreamProfile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout

private const val PreviewDebounceMs = 550L
private const val PreviewPlayTimeoutMs = 3_500L

@OptIn(UnstableApi::class)
@Composable
fun LivePreviewPlayer(
    profile: XtreamProfile,
    channel: LiveChannel?,
    modifier: Modifier = Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val lightweight = DeviceCapabilities.useLightweightPreview()
    var error by remember { mutableStateOf<String?>(null) }
    var previewGeneration by remember { mutableIntStateOf(0) }

    if (channel == null) {
        Box(
            modifier = modifier
                .clip(RoundedCornerShape(10.dp))
                .background(TvColors.SurfaceDeep),
            contentAlignment = Alignment.Center,
        ) {
            BasicText("Seleziona un canale", style = TvTypography.mutedStyle)
        }
        return
    }

    val player = remember(profile.baseUrl) {
        val dataSource = DefaultHttpDataSource.Factory()
            .setUserAgent("VLC/3.0.20 LibVLC/3.0.20")
            .setDefaultRequestProperties(mapOf("Referer" to "${profile.baseUrl}/"))
            .setAllowCrossProtocolRedirects(true)
        ExoPlayer.Builder(context)
            .setRenderersFactory(
                DefaultRenderersFactory(context).setEnableDecoderFallback(true),
            )
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .build()
            .apply {
                volume = if (lightweight) 0f else 1f
            }
    }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlayerError(playbackError: PlaybackException) {
                error = playbackError.errorCodeName
            }
        }
        player.addListener(listener)
        onDispose {
            player.removeListener(listener)
            player.stop()
            player.clearMediaItems()
            player.release()
        }
    }

    LaunchedEffect(channel.id) {
        previewGeneration += 1
        val generation = previewGeneration
        error = null
        player.stop()
        player.clearMediaItems()
        delay(PreviewDebounceMs)
        if (generation != previewGeneration) return@LaunchedEffect

        val urls = StreamPlayback.buildLiveStreamUrls(profile, channel.id)
        if (urls.isEmpty()) return@LaunchedEffect

        try {
            withTimeout(PreviewPlayTimeoutMs) {
                StreamPlayback.playPreviewUrl(player, urls, lightweight) {
                    if (generation == previewGeneration) error = it
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            if (generation == previewGeneration) {
                error = "Anteprima non disponibile"
            }
        }
    }

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(TvColors.SurfaceDeep),
        contentAlignment = Alignment.Center,
    ) {
        AndroidView(
            factory = {
                PlayerView(it).apply {
                    this.player = player
                    useController = false
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                    setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
                    keepScreenOn = false
                    isFocusable = false
                    descendantFocusability = android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS
                }
            },
            update = { it.player = player },
            modifier = Modifier.fillMaxSize(),
        )
        error?.let {
            BasicText(
                "Anteprima non disponibile",
                style = TvTypography.captionStyle.copy(fontWeight = FontWeight.SemiBold),
            )
        }
    }
}
