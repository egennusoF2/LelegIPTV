package com.lelegiptv.tv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.lelegiptv.tv.GuideState
import com.lelegiptv.tv.data.EpgProgramme
import com.lelegiptv.tv.data.EpgReplay
import com.lelegiptv.tv.data.LiveCategory
import com.lelegiptv.tv.data.LiveChannel
import com.lelegiptv.tv.data.dayBoundary
import com.lelegiptv.tv.data.epgProgrammeKey
import com.lelegiptv.tv.data.isLiveAt
import com.lelegiptv.tv.data.nextDayBoundary
import com.lelegiptv.tv.data.programmesForDay
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val ChannelColumnWidth = 248.dp
private const val DefaultLookbackDays = 7

@Composable
fun GuideScreen(
    channels: List<LiveChannel>,
    categories: List<LiveCategory>,
    guideState: GuideState,
    selectedCategoryId: String,
    onCategorySelected: (String) -> Unit,
    onLoadChannel: (LiveChannel, Long) -> Unit,
    onOpenChannel: (LiveChannel) -> Unit,
    onCatchup: (LiveChannel, EpgProgramme) -> Unit,
    onRetry: () -> Unit,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    modifier: Modifier = Modifier,
    nowMillis: Long = System.currentTimeMillis(),
) {
    val programmesByChannel = (guideState as? GuideState.Ready)?.programmesByChannel.orEmpty()
    val readyGuide = guideState as? GuideState.Ready
    val isLoading = guideState is GuideState.Idle || readyGuide?.loading == true
    val progress = when (guideState) {
        GuideState.Idle -> "Preparazione guida TV..."
        is GuideState.Ready -> guideState.progress
        else -> null
    }

    var selectedChannel by remember(channels) { mutableStateOf(channels.firstOrNull()) }
    var selectedDayOffset by rememberSaveable { mutableIntStateOf(0) }

    LaunchedEffect(channels) {
        if (selectedChannel == null || channels.none { it.id == selectedChannel?.id }) {
            selectedChannel = channels.firstOrNull()
        }
    }

    val lookbackDays = remember(selectedChannel) {
        selectedChannel?.let { channel ->
            when {
                channel.catchupDays > 0 -> channel.catchupDays.coerceAtMost(14)
                channel.hasCatchup -> DefaultLookbackDays
                else -> DefaultLookbackDays
            }
        } ?: DefaultLookbackDays
    }

    LaunchedEffect(selectedDayOffset, lookbackDays) {
        if (selectedDayOffset < -lookbackDays) {
            selectedDayOffset = -lookbackDays
        }
    }

    val dayStart = remember(nowMillis, selectedDayOffset) { dayBoundary(nowMillis, selectedDayOffset) }
    val dayEnd = remember(dayStart) { nextDayBoundary(dayStart) }

    val channelProgrammes = remember(selectedChannel, programmesByChannel) {
        selectedChannel?.let { programmesByChannel[it.id].orEmpty() }.orEmpty()
    }

    val dayProgrammes = remember(channelProgrammes, dayStart, dayEnd) {
        programmesForDay(channelProgrammes, dayStart, dayEnd)
    }
    val liveProgrammeIndex = remember(dayProgrammes, nowMillis, selectedDayOffset) {
        if (selectedDayOffset != 0) -1
        else dayProgrammes.indexOfFirst { it.isLiveAt(nowMillis) }
    }

    val channelLoading = selectedChannel?.let { channel ->
        channelProgrammes.isEmpty() &&
            (
                guideState is GuideState.Idle ||
                    readyGuide?.loadingChannelId == channel.id ||
                    (readyGuide?.loading == true && readyGuide.programmesByChannel[channel.id] == null)
                )
    } == true

    LaunchedEffect(selectedChannel?.id, selectedDayOffset) {
        val channel = selectedChannel ?: return@LaunchedEffect
        delay(300)
        onLoadChannel(channel, dayStart)
    }

    val programmeListState = rememberLazyListState()
    LaunchedEffect(liveProgrammeIndex, dayProgrammes.size) {
        if (liveProgrammeIndex >= 0) {
            programmeListState.scrollToItem(liveProgrammeIndex.coerceAtLeast(0))
        }
    }

    val channelFocusRequester = remember { FocusRequester() }
    val dayFocusRequester = remember { FocusRequester() }
    val programmeFocusRequester = remember { FocusRequester() }
    val channelListState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    fun focusChannelList() {
        scope.launch {
            val index = channels.indexOfFirst { it.id == selectedChannel?.id }.coerceAtLeast(0)
            channelListState.scrollToItem(index)
            channelFocusRequester.safeRequestFocus()
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(TvColors.Background)
            .padding(start = 20.dp, end = 24.dp, top = 18.dp, bottom = 16.dp),
    ) {
        GuideHeader(
            channelCount = channels.size,
            isLoading = isLoading,
            progress = progress,
        )
        if (categories.isNotEmpty()) {
            GuideCategoryStrip(
                categories = categories,
                selectedCategoryId = selectedCategoryId,
                onCategorySelected = onCategorySelected,
            )
        }
        GuideDayStrip(
            lookbackDays = lookbackDays,
            selectedDayOffset = selectedDayOffset,
            nowMillis = nowMillis,
            dayFocusRequester = dayFocusRequester,
            onSelect = { selectedDayOffset = it },
            onMoveDown = {
                if (dayProgrammes.isNotEmpty()) {
                    scope.launch { programmeFocusRequester.safeRequestFocus() }
                } else {
                    focusChannelList()
                }
            },
        )
        Spacer(Modifier.height(14.dp))
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            GuideChannelColumn(
                channels = channels,
                selectedChannel = selectedChannel,
                listState = channelListState,
                channelFocusRequester = channelFocusRequester,
                firstFocusRequester = firstFocusRequester,
                onSelect = { selectedChannel = it },
                onMoveRight = {
                    scope.launch { dayFocusRequester.safeRequestFocus() }
                },
                onMoveLeftToMenu = onMoveLeftToMenu,
            )
            GuideProgrammeColumn(
                channel = selectedChannel,
                programmes = dayProgrammes,
                dayStart = dayStart,
                dayEnd = dayEnd,
                nowMillis = nowMillis,
                selectedDayOffset = selectedDayOffset,
                liveProgrammeIndex = liveProgrammeIndex,
                isLoading = channelLoading,
                programmeFocusRequester = programmeFocusRequester,
                programmeListState = programmeListState,
                onMoveLeft = { focusChannelList() },
                onOpenChannel = onOpenChannel,
                onCatchup = onCatchup,
                onRetry = onRetry,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun GuideHeader(
    channelCount: Int,
    isLoading: Boolean,
    progress: String?,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            "Guida TV",
            style = TvTypography.pageHeadingStyle,
        )
        Spacer(Modifier.width(12.dp))
        BasicText(
            "$channelCount canali",
            style = TvTypography.captionStyle.copy(fontSize = 14.sp),
        )
        Spacer(Modifier.weight(1f))
        if (isLoading) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    color = TvColors.Accent,
                    strokeWidth = 2.dp,
                )
                BasicText(
                    progress ?: "Caricamento...",
                    style = TextStyle(color = TvColors.Accent, fontSize = 13.sp),
                )
            }
        }
    }
}

@Composable
private fun GuideCategoryStrip(
    categories: List<LiveCategory>,
    selectedCategoryId: String,
    onCategorySelected: (String) -> Unit,
) {
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 12.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(categories, key = { it.id }) { category ->
            FocusCard(
                onClick = { onCategorySelected(category.id) },
                selected = category.id == selectedCategoryId,
                padding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
            ) {
                BasicText(
                    category.name,
                    style = TextStyle(
                        color = TvColors.Text,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun GuideDayStrip(
    lookbackDays: Int,
    selectedDayOffset: Int,
    nowMillis: Long,
    dayFocusRequester: FocusRequester,
    onSelect: (Int) -> Unit,
    onMoveDown: () -> Unit,
) {
    val dayOffsets = remember(lookbackDays) {
        buildList {
            for (offset in -lookbackDays..1) add(offset)
        }
    }
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .background(TvColors.Panel, RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(dayOffsets, key = { it }) { offset ->
            val selected = offset == selectedDayOffset
            FocusCard(
                onClick = { onSelect(offset) },
                focusRequester = if (offset == selectedDayOffset) dayFocusRequester else null,
                selected = selected,
                modifier = Modifier
                    .width(if (offset in listOf(-1, 0, 1)) 96.dp else 78.dp)
                    .height(42.dp)
                    .onPreviewKeyEvent {
                        if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionDown) {
                            onMoveDown()
                            true
                        } else {
                            false
                        }
                    },
                padding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
            ) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    BasicText(
                        formatDayTab(offset, nowMillis),
                        style = TextStyle(
                            color = if (selected) TvColors.Accent else TvColors.Text,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                        ),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun GuideChannelColumn(
    channels: List<LiveChannel>,
    selectedChannel: LiveChannel?,
    listState: androidx.compose.foundation.lazy.LazyListState,
    channelFocusRequester: FocusRequester,
    firstFocusRequester: FocusRequester,
    onSelect: (LiveChannel) -> Unit,
    onMoveRight: () -> Unit,
    onMoveLeftToMenu: () -> Unit,
) {
    LazyColumn(
        state = listState,
        modifier = Modifier
            .width(ChannelColumnWidth)
            .fillMaxHeight()
            .background(TvColors.Panel, RoundedCornerShape(8.dp))
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        items(channels, key = { it.id }) { channel ->
            val isSelected = channel.id == selectedChannel?.id
            FocusCard(
                onClick = { onSelect(channel) },
                focusRequester = when {
                    channel == channels.firstOrNull() -> firstFocusRequester
                    isSelected -> channelFocusRequester
                    else -> null
                },
                selected = isSelected,
                modifier = Modifier
                    .fillMaxWidth()
                    .onPreviewKeyEvent {
                        if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                        when (it.key) {
                            Key.DirectionLeft -> {
                                if (channel == channels.firstOrNull()) {
                                    onMoveLeftToMenu()
                                    true
                                } else {
                                    false
                                }
                            }
                            Key.DirectionRight -> {
                                onMoveRight()
                                true
                            }
                            else -> false
                        }
                    }
                    .onFocusChanged {
                        if (it.isFocused && !isSelected) onSelect(channel)
                    },
                padding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
            ) {
                BasicText(
                    channel.name,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = TvColors.Text,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    ),
                )
            }
        }
    }
}

@Composable
private fun GuideProgrammeColumn(
    channel: LiveChannel?,
    programmes: List<EpgProgramme>,
    dayStart: Long,
    dayEnd: Long,
    nowMillis: Long,
    selectedDayOffset: Int,
    liveProgrammeIndex: Int,
    isLoading: Boolean,
    programmeFocusRequester: FocusRequester,
    programmeListState: androidx.compose.foundation.lazy.LazyListState,
    onMoveLeft: () -> Unit,
    onOpenChannel: (LiveChannel) -> Unit,
    onCatchup: (LiveChannel, EpgProgramme) -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxHeight(),
    ) {
        if (channel == null) {
            GuideEmptyMessage("Seleziona un canale")
            return
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 10.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                BasicText(
                    channel.name,
                    style = TextStyle(
                        color = TvColors.Text,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                    ),
                )
                BasicText(
                    formatDayLabel(dayStart),
                    style = TextStyle(color = TvColors.Accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                )
            }
            BasicText(
                "${programmes.size} programmi",
                style = TextStyle(color = TvColors.Muted, fontSize = 13.sp),
            )
        }
        when {
            isLoading -> {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(color = TvColors.Accent)
                        Spacer(Modifier.height(12.dp))
                        BasicText(
                            "Caricamento programmi...",
                            style = TextStyle(color = TvColors.Muted, fontSize = 15.sp),
                        )
                    }
                }
            }
            programmes.isEmpty() -> {
                GuideEmptyMessage(
                    message = "Nessun programma per ${formatDayLabel(dayStart)}",
                    actionLabel = "Riprova",
                    onAction = onRetry,
                )
            }
            else -> {
                LazyColumn(
                    state = programmeListState,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    contentPadding = PaddingValues(bottom = 24.dp),
                ) {
                    items(
                        count = programmes.size,
                        key = { index -> epgProgrammeKey(programmes[index]) },
                    ) { index ->
                        val programme = programmes[index]
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            if (
                                programme.isLiveAt(nowMillis) &&
                                index == liveProgrammeIndex &&
                                selectedDayOffset == 0
                            ) {
                                GuideLiveMarker()
                            }
                            GuideProgrammeCard(
                                channel = channel,
                                programme = programme,
                                nowMillis = nowMillis,
                                focusRequester = when {
                                    index == liveProgrammeIndex && selectedDayOffset == 0 -> programmeFocusRequester
                                    liveProgrammeIndex < 0 && index == 0 -> programmeFocusRequester
                                    else -> null
                                },
                                onMoveLeft = onMoveLeft,
                                onClick = {
                                    val isPast = programme.endTimeMillis <= nowMillis
                                    val canReplay = EpgReplay.canReplay(channel, programme, nowMillis)
                                    when {
                                        isPast && canReplay -> onCatchup(channel, programme)
                                        programme.startTimeMillis <= nowMillis -> onOpenChannel(channel)
                                    }
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GuideLiveMarker() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .weight(1f)
                .height(1.dp)
                .background(TvColors.Line),
        )
        BasicText(
            "▶  IN ONDA ADESSO",
            style = TextStyle(
                color = TvColors.Accent,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
            ),
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .height(1.dp)
                .background(TvColors.Line),
        )
    }
}

@Composable
private fun GuideProgrammeCard(
    channel: LiveChannel,
    programme: EpgProgramme,
    nowMillis: Long,
    focusRequester: FocusRequester?,
    onMoveLeft: () -> Unit,
    onClick: () -> Unit,
) {
    val isLive = programme.isLiveAt(nowMillis)
    val isPast = programme.endTimeMillis <= nowMillis
    val canReplay = EpgReplay.canReplay(channel, programme, nowMillis)
    val durationMin =
        ((programme.endTimeMillis - programme.startTimeMillis) / 60_000L).coerceAtLeast(1L)

    HorizontalMediaCard(
        onClick = onClick,
        imageUrl = channel.logo,
        imageContentDescription = channel.name,
        eyebrow = buildString {
            append(formatClock(programme.startTimeMillis))
            append(" - ")
            append(formatClock(programme.endTimeMillis))
            when {
                isLive -> append("  •  LIVE")
                isPast && canReplay -> append("  •  ARCHIVIO")
                isPast -> append("  •  TERMINATO")
            }
        },
        title = programme.title,
        badge = "$durationMin min",
        subtitle = formatProgrammeDate(programme.startTimeMillis),
        description = programme.description,
        selected = isLive,
        focusRequester = focusRequester,
        modifier = Modifier.onPreviewKeyEvent {
            if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionLeft) {
                onMoveLeft()
                true
            } else {
                false
            }
        },
    )
}

@Composable
private fun GuideEmptyMessage(
    message: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            BasicText(message, style = TextStyle(color = TvColors.Muted, fontSize = 16.sp))
            if (actionLabel != null && onAction != null) {
                Spacer(Modifier.height(14.dp))
                FocusCard(onClick = onAction, padding = PaddingValues(horizontal = 18.dp, vertical = 10.dp)) {
                    BasicText(actionLabel, style = TvTypography.bodyStyle)
                }
            }
        }
    }
}

private fun formatDayTab(dayOffset: Int, referenceMillis: Long): String =
    when (dayOffset) {
        -1 -> "IERI"
        0 -> "OGGI"
        1 -> "DOMANI"
        else -> {
            val calendar = Calendar.getInstance().apply {
                timeInMillis = referenceMillis
                add(Calendar.DAY_OF_YEAR, dayOffset)
            }
            val dow = SimpleDateFormat("EEE", Locale.ITALIAN)
                .format(calendar.time)
                .uppercase(Locale.ITALIAN)
                .take(3)
            val day = calendar.get(Calendar.DAY_OF_MONTH)
            "$dow $day"
        }
    }

private fun formatDayLabel(dayStart: Long): String =
    SimpleDateFormat("EEEE d MMMM", Locale.ITALIAN)
        .format(Date(dayStart))
        .replaceFirstChar { it.titlecase(Locale.ITALIAN) }

private fun formatProgrammeDate(timeMillis: Long): String =
    SimpleDateFormat("dd/MM/yyyy", Locale.ITALIAN).format(Date(timeMillis))

private fun formatClock(timeMillis: Long): String =
    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timeMillis))
