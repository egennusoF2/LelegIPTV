package com.lelegiptv.tv.ui

import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material3.Icon
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.lelegiptv.tv.data.EpgProgramme
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private const val ControlsTimeoutMs = 5_000L
private const val SeekIncrementMs = 10_000L
private const val ProgressFlushIntervalMs = 12_000L

private enum class TrackMenu {
    Audio,
    Subtitles,
}

private data class SelectableTrack(
    val key: String,
    val label: String,
    val group: Tracks.Group,
    val trackIndex: Int,
    val selected: Boolean,
)

@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(
    title: String,
    urls: List<String>,
    referer: String,
    programmes: List<EpgProgramme> = emptyList(),
    startPositionMs: Long = 0L,
    onProgressUpdate: ((positionMs: Long, durationMs: Long) -> Unit)? = null,
    onPreviousChannel: (() -> Unit)? = null,
    onNextChannel: (() -> Unit)? = null,
    onBack: () -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var error by remember { mutableStateOf<String?>(null) }
    var playbackState by remember { mutableIntStateOf(Player.STATE_IDLE) }
    var isPlaying by remember { mutableStateOf(false) }
    var positionMs by remember { mutableLongStateOf(0L) }
    var durationMs by remember { mutableLongStateOf(C.TIME_UNSET) }
    var tracks by remember { mutableStateOf(Tracks.EMPTY) }
    var controlsVisible by remember { mutableStateOf(true) }
    var interactionId by remember { mutableIntStateOf(0) }
    var trackMenu by remember { mutableStateOf<TrackMenu?>(null) }
    val playFocus = remember { FocusRequester() }
    val rootFocus = remember { FocusRequester() }
    val isLive = onPreviousChannel != null || onNextChannel != null

    val player = remember(referer) {
        val dataSource = DefaultHttpDataSource.Factory()
            .setUserAgent("VLC/3.0.20 LibVLC/3.0.20")
            .setDefaultRequestProperties(mapOf("Referer" to referer))
            .setAllowCrossProtocolRedirects(true)
        ExoPlayer.Builder(context)
            .setRenderersFactory(
                DefaultRenderersFactory(context).setEnableDecoderFallback(true),
            )
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .build()
    }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlayerError(playbackError: PlaybackException) {
                error = playbackError.errorCodeName
            }

            override fun onPlaybackStateChanged(state: Int) {
                playbackState = state
                durationMs = player.duration
            }

            override fun onIsPlayingChanged(playing: Boolean) {
                isPlaying = playing
            }

            override fun onTracksChanged(currentTracks: Tracks) {
                tracks = currentTracks
            }
        }
        player.addListener(listener)
        onDispose {
            if (onProgressUpdate != null && !isLive) {
                val duration = player.duration
                if (duration > 0) {
                    onProgressUpdate(player.currentPosition.coerceAtLeast(0L), duration)
                }
            }
            player.removeListener(listener)
            player.release()
        }
    }

    LaunchedEffect(player, urls, startPositionMs) {
        error = null
        controlsVisible = true
        interactionId++
        StreamPlayback.playFirstWorkingUrl(
            player = player,
            urls = urls,
            onError = { message -> error = message },
        )
        if (startPositionMs > 0L && player.duration > 0) {
            player.seekTo(startPositionMs.coerceAtMost(player.duration - 1_000L))
        }
    }

    LaunchedEffect(player, onProgressUpdate, isLive) {
        if (onProgressUpdate == null || isLive) return@LaunchedEffect
        while (true) {
            delay(ProgressFlushIntervalMs)
            val duration = player.duration
            if (duration > 0 && player.playbackState != Player.STATE_IDLE) {
                onProgressUpdate(player.currentPosition.coerceAtLeast(0L), duration)
            }
        }
    }

    LaunchedEffect(player) {
        while (true) {
            positionMs = player.currentPosition.coerceAtLeast(0L)
            durationMs = player.duration
            delay(500)
        }
    }

    LaunchedEffect(controlsVisible, interactionId, trackMenu) {
        if (controlsVisible && trackMenu == null) {
            delay(ControlsTimeoutMs)
            controlsVisible = false
        }
    }

    LaunchedEffect(controlsVisible, trackMenu) {
        if (controlsVisible && trackMenu == null) {
            delay(80)
            playFocus.safeRequestFocus()
        } else if (!controlsVisible) {
            rootFocus.safeRequestFocus()
        }
    }

    BackHandler {
        when {
            trackMenu != null -> trackMenu = null
            else -> onBack()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(rootFocus)
            .onPreviewKeyEvent { event ->
                if (isLive && event.isChannelPrevious() && onPreviousChannel != null) {
                    onPreviousChannel.invoke()
                    controlsVisible = true
                    interactionId++
                    return@onPreviewKeyEvent true
                }
                if (isLive && event.isChannelNext() && onNextChannel != null) {
                    onNextChannel.invoke()
                    controlsVisible = true
                    interactionId++
                    return@onPreviewKeyEvent true
                }
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                interactionId++
                if (!controlsVisible) {
                    controlsVisible = true
                    true
                } else {
                    false
                }
            }
            .focusable(),
    ) {
        AndroidView(
            factory = {
                PlayerView(it).apply {
                    this.player = player
                    useController = false
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                    setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
                    keepScreenOn = true
                    isFocusable = false
                    descendantFocusability = android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS
                }
            },
            update = { it.player = player },
            modifier = Modifier.fillMaxSize(),
        )

        if (!controlsVisible && programmes.isNotEmpty()) {
            val now = System.currentTimeMillis()
            val current = programmes.firstOrNull {
                now >= it.startTimeMillis && now < it.endTimeMillis
            }
            current?.let {
                BasicText(
                    text = "$title\n${it.title}",
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = Color.White,
                        fontSize = 19.sp,
                        fontWeight = FontWeight.SemiBold,
                    ),
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(24.dp)
                        .background(Color(0xB8081017), RoundedCornerShape(7.dp))
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                )
            }
        }

        if (controlsVisible) {
            PlayerControls(
                title = title,
                programmes = programmes,
                player = player,
                isPlaying = isPlaying,
                positionMs = positionMs,
                durationMs = durationMs,
                tracks = tracks,
                playFocus = playFocus,
                isLive = isLive,
                onInteraction = { interactionId++ },
                onOpenTracks = { trackMenu = it },
                modifier = Modifier.fillMaxSize(),
            )
        }

        if (playbackState == Player.STATE_BUFFERING) {
            StatusPill("Caricamento...", Modifier.align(Alignment.Center))
        }

        error?.let {
            StatusPill(
                text = "Errore di riproduzione: $it",
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(32.dp),
                isError = true,
            )
        }

        trackMenu?.let { menu ->
            TrackPicker(
                menu = menu,
                player = player,
                tracks = tracks,
                onClose = {
                    trackMenu = null
                    controlsVisible = true
                    interactionId++
                },
                modifier = Modifier.align(Alignment.CenterEnd),
            )
        }
    }
}

@Composable
private fun PlayerControls(
    title: String,
    programmes: List<EpgProgramme>,
    player: Player,
    isPlaying: Boolean,
    positionMs: Long,
    durationMs: Long,
    tracks: Tracks,
    playFocus: FocusRequester,
    isLive: Boolean = false,
    onInteraction: () -> Unit,
    onOpenTracks: (TrackMenu) -> Unit,
    modifier: Modifier = Modifier,
) {
    val hasAudioTracks = remember(tracks) { selectableTracks(tracks, C.TRACK_TYPE_AUDIO).isNotEmpty() }
    val hasSubtitleTracks = remember(tracks) { selectableTracks(tracks, C.TRACK_TYPE_TEXT).isNotEmpty() }
    val isVod = durationMs != C.TIME_UNSET && durationMs > 0
    val now = System.currentTimeMillis()
    val currentProgramme =
        remember(programmes, now / 30_000) {
            programmes.firstOrNull { now >= it.startTimeMillis && now < it.endTimeMillis }
        }

    Box(modifier = modifier) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(160.dp)
                .align(Alignment.TopCenter)
                .background(
                    Brush.verticalGradient(
                        colors = listOf(
                            Color(0xE6081017),
                            Color(0x99081017),
                            Color.Transparent,
                        ),
                    ),
                ),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(280.dp)
                .align(Alignment.BottomCenter)
                .background(
                    Brush.verticalGradient(
                        colors = listOf(
                            Color.Transparent,
                            Color(0xCC081016),
                            Color(0xF2081016),
                        ),
                    ),
                ),
        )

        Column(
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(horizontal = 40.dp, vertical = 30.dp)
                .fillMaxWidth(0.72f),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (isLive) {
                LiveBadge()
            }
            BasicText(
                text = title,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = TextStyle(
                    color = Color.White,
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = TvTypography.fontFamily,
                ),
            )
            currentProgramme?.title?.takeIf { it.isNotBlank() }?.let { programmeTitle ->
                BasicText(
                    text = programmeTitle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = TvColors.Muted,
                        fontSize = 17.sp,
                        fontFamily = TvTypography.fontFamily,
                    ),
                )
            }
        }

        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(horizontal = 36.dp, vertical = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (isVod) {
                Timeline(
                    positionMs = positionMs,
                    durationMs = durationMs,
                    onSeekBy = { delta ->
                        player.seekTo((player.currentPosition + delta).coerceIn(0L, durationMs))
                        onInteraction()
                    },
                )
            } else {
                CurrentProgrammeInfo(currentProgramme)
                if (isLive) {
                    BasicText(
                        "↑ Canale precedente    ↓ Canale successivo",
                        style = TextStyle(
                            color = TvColors.Muted,
                            fontSize = 13.sp,
                            fontFamily = TvTypography.fontFamily,
                        ),
                    )
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(18.dp))
                    .background(Color(0xCC121A20))
                    .border(1.dp, Color(0xFF2D3A44), RoundedCornerShape(18.dp))
                    .padding(horizontal = 18.dp, vertical = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ControlChip(
                    icon = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                    label = if (isPlaying) "Pausa" else "Play",
                    emphasized = true,
                    onClick = {
                        if (isPlaying) player.pause() else player.play()
                        onInteraction()
                    },
                    modifier = Modifier.focusRequester(playFocus),
                )
                if (isVod) {
                    ControlChip(
                        icon = Icons.Default.Replay10,
                        label = "-10s",
                        onClick = {
                            player.seekTo((player.currentPosition - SeekIncrementMs).coerceAtLeast(0L))
                            onInteraction()
                        },
                    )
                    ControlChip(
                        icon = Icons.Default.Forward10,
                        label = "+10s",
                        onClick = {
                            player.seekTo((player.currentPosition + SeekIncrementMs).coerceAtMost(durationMs))
                            onInteraction()
                        },
                    )
                }
                Spacer(Modifier.weight(1f))
                ControlChip(
                    icon = Icons.AutoMirrored.Filled.VolumeUp,
                    label = if (hasAudioTracks) "Audio" else "Audio --",
                    enabled = hasAudioTracks,
                    onClick = { onOpenTracks(TrackMenu.Audio) },
                )
                ControlChip(
                    icon = Icons.Default.Subtitles,
                    label = if (hasSubtitleTracks) "Sottotitoli" else "Sottotitoli --",
                    enabled = hasSubtitleTracks,
                    onClick = { onOpenTracks(TrackMenu.Subtitles) },
                )
            }
        }
    }
}

@Composable
private fun LiveBadge() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Color(0x332FC8F1))
            .border(1.dp, TvColors.Accent.copy(alpha = 0.65f), RoundedCornerShape(999.dp))
            .padding(horizontal = 12.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(TvColors.Accent),
        )
        BasicText(
            "LIVE",
            style = TextStyle(
                color = TvColors.Accent,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = TvTypography.fontFamily,
            ),
        )
    }
}

@Composable
private fun CurrentProgrammeInfo(
    programme: EpgProgramme?,
) {
    if (programme == null) {
        BasicText(
            text = "IN DIRETTA  •  EPG non disponibile",
            style = TextStyle(
                color = TvColors.Accent,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
            ),
        )
        return
    }
    Column(
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        BasicText(
            "IN DIRETTA  ${formatClock(programme.startTimeMillis)} - " +
                formatClock(programme.endTimeMillis),
            style = TextStyle(
                color = TvColors.Accent,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
            ),
        )
        BasicText(
            programme.title,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = TextStyle(color = Color.White, fontSize = 17.sp),
        )
    }
}

private fun formatClock(timeMillis: Long): String =
    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timeMillis))

@Composable
private fun Timeline(
    positionMs: Long,
    durationMs: Long,
    onSeekBy: (Long) -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val progress = (positionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0x66121A20))
            .border(
                width = if (focused) 2.dp else 1.dp,
                color = if (focused) TvColors.Accent else Color(0xFF2D3A44),
                shape = RoundedCornerShape(12.dp),
            )
            .onFocusChanged { focused = it.hasFocus }
            .onPreviewKeyEvent {
                if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when (it.key) {
                    Key.DirectionLeft -> {
                        onSeekBy(-SeekIncrementMs)
                        true
                    }
                    Key.DirectionRight -> {
                        onSeekBy(SeekIncrementMs)
                        true
                    }
                    else -> false
                }
            }
            .focusable()
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            BasicText(
                text = formatTime(positionMs),
                style = TextStyle(color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
            )
            BasicText(
                text = formatTime(durationMs),
                style = TextStyle(color = TvColors.Muted, fontSize = 14.sp),
            )
        }
        Spacer(Modifier.height(10.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(8.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(Color(0xFF2D3A44)),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(progress)
                    .height(8.dp)
                    .background(
                        Brush.horizontalGradient(
                            listOf(TvColors.Accent.copy(alpha = 0.85f), TvColors.Accent),
                        ),
                        RoundedCornerShape(999.dp),
                    ),
            )
            if (progress > 0.02f) {
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .fillMaxWidth(progress)
                        .padding(end = 2.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.CenterEnd)
                            .size(14.dp)
                            .clip(CircleShape)
                            .background(Color.White)
                            .border(2.dp, TvColors.Accent, CircleShape),
                    )
                }
            }
        }
    }
}

@Composable
private fun TrackPicker(
    menu: TrackMenu,
    player: Player,
    tracks: Tracks,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val trackType = if (menu == TrackMenu.Audio) C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
    val options = remember(tracks, trackType) { selectableTracks(tracks, trackType) }
    val firstFocus = remember { FocusRequester() }

    LaunchedEffect(menu, options) {
        delay(80)
        firstFocus.safeRequestFocus()
    }

    BackHandler(onBack = onClose)
    Column(
        modifier = modifier
            .fillMaxHeight()
            .width(430.dp)
            .background(Color(0xF2081017))
            .padding(28.dp),
    ) {
        BasicText(
            text = if (menu == TrackMenu.Audio) "Traccia audio" else "Sottotitoli",
            style = TextStyle(
                color = Color.White,
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
            ),
        )
        Spacer(Modifier.height(18.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (menu == TrackMenu.Subtitles) {
                item {
                    TrackButton(
                        label = "Disattivati",
                        selected = player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT),
                        onClick = {
                            player.trackSelectionParameters = player.trackSelectionParameters
                                .buildUpon()
                                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                                .build()
                            onClose()
                        },
                        modifier = Modifier.focusRequester(firstFocus),
                    )
                }
            }
            items(options, key = { it.key }) { option ->
                TrackButton(
                    label = option.label,
                    selected = option.selected &&
                        !player.trackSelectionParameters.disabledTrackTypes.contains(trackType),
                    onClick = {
                        player.trackSelectionParameters = player.trackSelectionParameters
                            .buildUpon()
                            .setTrackTypeDisabled(trackType, false)
                            .clearOverridesOfType(trackType)
                            .setOverrideForType(
                                TrackSelectionOverride(option.group.mediaTrackGroup, option.trackIndex),
                            )
                            .build()
                        onClose()
                    },
                    modifier = if (menu == TrackMenu.Audio && option == options.firstOrNull()) {
                        Modifier.focusRequester(firstFocus)
                    } else {
                        Modifier
                    },
                )
            }
            if (menu == TrackMenu.Audio && options.isEmpty()) {
                item {
                    ControlButton(
                        label = "Nessuna traccia audio selezionabile",
                        onClick = onClose,
                        modifier = Modifier.focusRequester(firstFocus),
                    )
                }
            }
            if (menu == TrackMenu.Subtitles && options.isEmpty()) {
                item {
                    BasicText(
                        "Nessuna traccia sottotitoli rilevata nel flusso.",
                        style = TextStyle(color = TvColors.Muted, fontSize = 15.sp),
                        modifier = Modifier.padding(vertical = 12.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun ControlChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    emphasized: Boolean = false,
) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(14.dp)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier
            .defaultMinSize(minWidth = 78.dp)
            .clip(shape)
            .background(
                when {
                    !enabled -> Color(0xFF1A232B)
                    focused -> TvColors.Accent
                    emphasized -> Color(0xFF1F5366)
                    else -> Color(0xFF172028)
                },
                shape,
            )
            .border(
                width = if (focused) 2.dp else 1.dp,
                color = when {
                    !enabled -> Color(0xFF2D3A44)
                    focused -> Color.White
                    emphasized -> TvColors.Accent.copy(alpha = 0.55f)
                    else -> Color(0xFF36424C)
                },
                shape = shape,
            )
            .onFocusChanged { focused = it.hasFocus }
            .clickable(enabled = enabled, onClick = onClick)
            .focusable(enabled)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = if (enabled) Color.White else Color(0xFF7D8992),
            modifier = Modifier.size(22.dp),
        )
        BasicText(
            text = label,
            style = TextStyle(
                color = if (enabled) Color.White else Color(0xFF7D8992),
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = TvTypography.fontFamily,
            ),
        )
    }
}

@Composable
private fun ControlButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    var focused by remember { mutableStateOf(false) }
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(46.dp)
            .background(
                color = when {
                    !enabled -> Color(0xFF28323A)
                    focused -> TvColors.Accent
                    else -> Color(0xFF202B33)
                },
                shape = RoundedCornerShape(7.dp),
            )
            .border(
                width = if (focused) 2.dp else 1.dp,
                color = if (focused) Color.White else Color(0xFF53606A),
                shape = RoundedCornerShape(7.dp),
            )
            .onFocusChanged { focused = it.hasFocus }
            .clickable(enabled = enabled, onClick = onClick)
            .focusable(enabled)
            .padding(horizontal = 20.dp),
    ) {
        BasicText(
            text = label,
            style = TextStyle(
                color = if (enabled) Color.White else Color(0xFF7D8992),
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            ),
        )
    }
}

@Composable
private fun TrackButton(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .background(
                if (focused) Color(0xFF1F5366) else Color(0xFF141E25),
                RoundedCornerShape(6.dp),
            )
            .border(
                2.dp,
                if (focused) TvColors.Accent else Color.Transparent,
                RoundedCornerShape(6.dp),
            )
            .onFocusChanged { focused = it.hasFocus }
            .clickable(onClick = onClick)
            .focusable()
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        BasicText(
            text = if (selected) "[x]" else "[ ]",
            style = TextStyle(color = TvColors.Accent, fontSize = 16.sp),
        )
        Spacer(Modifier.width(12.dp))
        BasicText(
            text = label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = TextStyle(color = Color.White, fontSize = 16.sp),
        )
    }
}

@Composable
private fun StatusPill(
    text: String,
    modifier: Modifier = Modifier,
    isError: Boolean = false,
) {
    BasicText(
        text = text,
        style = TextStyle(
            color = Color.White,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
        ),
        modifier = modifier
            .background(
                if (isError) Color(0xEFAE2734) else Color(0xD9081017),
                RoundedCornerShape(8.dp),
            )
            .padding(horizontal = 20.dp, vertical = 13.dp),
    )
}

private fun selectableTracks(tracks: Tracks, trackType: Int): List<SelectableTrack> {
    val result = mutableListOf<SelectableTrack>()
    tracks.groups.forEachIndexed { groupIndex, group ->
        if (group.type != trackType || !group.isSupported) return@forEachIndexed
        for (trackIndex in 0 until group.length) {
            if (!group.isTrackSupported(trackIndex)) continue
            val format = group.getTrackFormat(trackIndex)
            val fallback = if (trackType == C.TRACK_TYPE_AUDIO) "Audio" else "Sottotitoli"
            val parts = listOfNotNull(
                format.label?.takeIf { it.isNotBlank() },
                format.language?.takeIf { it.isNotBlank() && it != "und" },
            ).distinct()
            result += SelectableTrack(
                key = "$trackType-$groupIndex-$trackIndex",
                label = parts.joinToString(" - ").ifBlank { "$fallback ${result.size + 1}" },
                group = group,
                trackIndex = trackIndex,
                selected = group.isTrackSelected(trackIndex),
            )
        }
    }
    return result
}

private fun formatTime(timeMs: Long): String {
    if (timeMs == C.TIME_UNSET || timeMs < 0) return "--:--"
    val totalSeconds = timeMs / 1_000
    val hours = totalSeconds / 3_600
    val minutes = (totalSeconds % 3_600) / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
        "%d:%02d:%02d".format(hours, minutes, seconds)
    } else {
        "%02d:%02d".format(minutes, seconds)
    }
}
