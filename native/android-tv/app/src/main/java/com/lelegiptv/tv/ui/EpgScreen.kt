package com.lelegiptv.tv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lelegiptv.tv.data.EpgProgramme
import com.lelegiptv.tv.data.LiveChannel
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.max

private val ChannelColumnWidth = 224.dp
private val MinuteWidth = 4.dp
private val ProgrammeRowHeight = 88.dp
private val TimelineHeaderHeight = 42.dp
private const val AutoCenterOffsetPx = 560

/**
 * Guida TV giornaliera ottimizzata per telecomando.
 *
 * La colonna canale resta fissa; intestazione e righe condividono la stessa
 * posizione orizzontale. Solo selettori giorno e programmi ricevono il focus.
 */
@Composable
fun EpgScreen(
    channels: List<LiveChannel>,
    programmesByChannel: Map<Int, List<EpgProgramme>>,
    onOpenChannel: (LiveChannel) -> Unit,
    onCatchup: (LiveChannel, EpgProgramme) -> Unit,
    modifier: Modifier = Modifier,
    nowMillis: Long = System.currentTimeMillis(),
    categories: List<com.lelegiptv.tv.data.LiveCategory> = emptyList(),
    selectedCategoryId: String = "",
    onCategorySelected: ((String) -> Unit)? = null,
    loadingLabel: String? = null,
) {
    var selectedDayOffset by rememberSaveable { mutableIntStateOf(0) }
    val dayStart = remember(nowMillis, selectedDayOffset) {
        dayBoundary(nowMillis, selectedDayOffset)
    }
    val dayEnd = remember(dayStart) { nextDayBoundary(dayStart) }
    val dayDurationMinutes = max(1L, (dayEnd - dayStart) / 60_000L)
    val timelineWidth = MinuteWidth * dayDurationMinutes.toFloat()
    val timelineScroll = rememberScrollState()
    val initialFocusRequester = remember { FocusRequester() }

    val rows = remember(channels, programmesByChannel, dayStart, dayEnd) {
        channels.map { channel ->
            EpgRow(
                channel = channel,
                programmes = programmesByChannel[channel.id]
                    .orEmpty()
                    .asSequence()
                    .filter { it.endTimeMillis > it.startTimeMillis }
                    .filter { it.startTimeMillis < dayEnd && it.endTimeMillis > dayStart }
                    .sortedBy(EpgProgramme::startTimeMillis)
                    .toList(),
            )
        }
    }
    val initialLiveChannelId = remember(rows, nowMillis, selectedDayOffset) {
        if (selectedDayOffset != 0) {
            null
        } else {
            rows.firstOrNull { row ->
                row.programmes.any { it.isLiveAt(nowMillis) }
            }?.channel?.id
        }
    }

    LaunchedEffect(dayStart, dayEnd, nowMillis) {
        val targetMinutes = if (nowMillis in dayStart until dayEnd) {
            (nowMillis - dayStart) / 60_000f
        } else {
            0f
        }
        val targetPx = (targetMinutes * MinuteWidth.value).toInt() - AutoCenterOffsetPx
        timelineScroll.scrollTo(targetPx.coerceAtLeast(0))
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(TvColors.Background)
            .padding(top = 22.dp),
    ) {
        EpgTitle(channels.size)
        if (categories.isNotEmpty() && onCategorySelected != null) {
            EpgCategoryStrip(
                categories = categories,
                selectedCategoryId = selectedCategoryId,
                onCategorySelected = onCategorySelected,
            )
        }
        DaySelector(
            selectedDayOffset = selectedDayOffset,
            dayStart = dayStart,
            onSelect = { selectedDayOffset = it },
        )
        Spacer(Modifier.height(12.dp))
        TimelineHeader(
            dayStart = dayStart,
            dayEnd = dayEnd,
            timelineWidth = timelineWidth,
            timelineScroll = timelineScroll,
        )

        if (rows.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Text("Nessun canale disponibile.", color = TvColors.Muted, fontSize = 18.sp)
            }
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(rows, key = { it.channel.id }) { row ->
                    TimelineChannelRow(
                        row = row,
                        dayStart = dayStart,
                        dayEnd = dayEnd,
                        nowMillis = nowMillis,
                        timelineWidth = timelineWidth,
                        timelineScroll = timelineScroll,
                        initialFocusRequester =
                            initialFocusRequester.takeIf {
                                row.channel.id == initialLiveChannelId
                            },
                        onOpenChannel = onOpenChannel,
                        onCatchup = onCatchup,
                    )
                }
            }
        }

        loadingLabel?.let { label ->
            Text(
                text = label,
                color = TvColors.Accent,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 30.dp, vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun EpgTitle(channelCount: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 30.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        Text(
            text = "Guida TV",
            color = TvColors.Text,
            fontSize = 38.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.width(14.dp))
        Text(
            text = "$channelCount canali",
            color = TvColors.Muted,
            fontSize = 15.sp,
            modifier = Modifier.padding(bottom = 5.dp),
        )
    }
}

@Composable
private fun DaySelector(
    selectedDayOffset: Int,
    dayStart: Long,
    onSelect: (Int) -> Unit,
) {
    Row(
        modifier = Modifier.padding(horizontal = 30.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DayCard(
            label = "‹  Ieri",
            selected = selectedDayOffset == -1,
            onClick = { onSelect(-1) },
        )
        DayCard(
            label = "Oggi",
            selected = selectedDayOffset == 0,
            onClick = { onSelect(0) },
        )
        DayCard(
            label = "Domani  ›",
            selected = selectedDayOffset == 1,
            onClick = { onSelect(1) },
        )
        Text(
            text = SimpleDateFormat("EEEE d MMMM", Locale.getDefault())
                .format(Date(dayStart))
                .replaceFirstChar { it.uppercase() },
            color = TvColors.Text,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .weight(1f)
                .padding(start = 12.dp),
        )
    }
}

@Composable
private fun EpgCategoryStrip(
    categories: List<com.lelegiptv.tv.data.LiveCategory>,
    selectedCategoryId: String,
    onCategorySelected: (String) -> Unit,
) {
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 30.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(categories, key = { it.id }) { category ->
            FocusCard(
                onClick = { onCategorySelected(category.id) },
                selected = category.id == selectedCategoryId,
                padding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
            ) {
                Text(
                    text = category.name,
                    color = TvColors.Text,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun DayCard(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    FocusCard(
        onClick = onClick,
        selected = selected,
        modifier = Modifier
            .width(124.dp)
            .height(44.dp),
        padding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                text = label,
                color = if (selected) TvColors.Accent else TvColors.Text,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
private fun TimelineHeader(
    dayStart: Long,
    dayEnd: Long,
    timelineWidth: Dp,
    timelineScroll: androidx.compose.foundation.ScrollState,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(TimelineHeaderHeight)
            .background(TvColors.Panel),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .width(ChannelColumnWidth)
                .height(TimelineHeaderHeight)
                .background(Color(0xFF0C181E))
                .padding(start = 24.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            Text(
                text = "CANALE",
                color = TvColors.Muted,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Box(
            modifier = Modifier
                .weight(1f)
                .horizontalScroll(timelineScroll),
        ) {
            Box(
                modifier = Modifier
                    .width(timelineWidth)
                    .height(TimelineHeaderHeight),
            ) {
                hourMarks(dayStart, dayEnd).forEach { hour ->
                    val x = (MinuteWidth.value * minuteOffset(dayStart, hour)).dp
                    Text(
                        text = hour.asClockTime(),
                        color = TvColors.Muted,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .offset(x = x)
                            .padding(start = 8.dp, top = 12.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun TimelineChannelRow(
    row: EpgRow,
    dayStart: Long,
    dayEnd: Long,
    nowMillis: Long,
    timelineWidth: Dp,
    timelineScroll: androidx.compose.foundation.ScrollState,
    initialFocusRequester: FocusRequester?,
    onOpenChannel: (LiveChannel) -> Unit,
    onCatchup: (LiveChannel, EpgProgramme) -> Unit,
) {
    val liveProgramme = remember(row.programmes, nowMillis) {
        row.programmes.firstOrNull { it.isLiveAt(nowMillis) }
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(ProgrammeRowHeight)
            .background(Color(0xFF0A151B)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ChannelLabel(row.channel)
        Box(
            modifier = Modifier
                .weight(1f)
                .height(ProgrammeRowHeight)
                .horizontalScroll(timelineScroll),
        ) {
            Box(
                modifier = Modifier
                    .width(timelineWidth)
                    .height(ProgrammeRowHeight)
                    .background(Color(0xFF0D1A20)),
            ) {
                hourMarks(dayStart, dayEnd).forEach { hour ->
                    Box(
                        modifier = Modifier
                            .offset(
                                x = (MinuteWidth.value * minuteOffset(dayStart, hour)).dp,
                            )
                            .width(1.dp)
                            .height(ProgrammeRowHeight)
                            .background(Color(0xFF22323A)),
                    )
                }

                row.programmes.forEach { programme ->
                    val visibleStart = maxOf(dayStart, programme.startTimeMillis)
                    val visibleEnd = minOf(dayEnd, programme.endTimeMillis)
                    val x = (MinuteWidth.value * minuteOffset(dayStart, visibleStart)).dp
                    val width = max(
                        54f,
                        minuteOffset(visibleStart, visibleEnd) * MinuteWidth.value - 4f,
                    ).dp
                    val isLive = programme.isLiveAt(nowMillis)
                    val isPast = programme.endTimeMillis <= nowMillis
                    val hasCatchup = isPast && row.channel.hasCatchup

                    ProgrammeCard(
                        programme = programme,
                        isLive = isLive,
                        hasCatchup = hasCatchup,
                        focusRequester =
                            initialFocusRequester.takeIf { programme === liveProgramme },
                        modifier = Modifier
                            .offset(x = x, y = 5.dp)
                            .width(width),
                        onClick = {
                            when {
                                hasCatchup -> onCatchup(row.channel, programme)
                                !isPast -> onOpenChannel(row.channel)
                            }
                        },
                    )
                }

                if (nowMillis in dayStart until dayEnd) {
                    Box(
                        modifier = Modifier
                            .offset(
                                x = (MinuteWidth.value * minuteOffset(dayStart, nowMillis)).dp,
                            )
                            .width(2.dp)
                            .height(ProgrammeRowHeight)
                            .background(TvColors.Accent),
                    )
                }
            }
        }
    }

    LaunchedEffect(initialFocusRequester, liveProgramme) {
        if (initialFocusRequester != null && liveProgramme != null) {
            withFrameNanos { }
            initialFocusRequester.safeRequestFocus()
        }
    }
}

@Composable
private fun ChannelLabel(channel: LiveChannel) {
    Column(
        modifier = Modifier
            .width(ChannelColumnWidth)
            .height(ProgrammeRowHeight)
            .background(TvColors.Panel)
            .padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = channel.name,
            color = TvColors.Text,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (channel.hasCatchup) {
            Text(
                text = "Archivio ${channel.catchupDays.coerceAtLeast(1)}g",
                color = TvColors.Accent,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
private fun ProgrammeCard(
    programme: EpgProgramme,
    isLive: Boolean,
    hasCatchup: Boolean,
    focusRequester: FocusRequester?,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    FocusCard(
        onClick = onClick,
        focusRequester = focusRequester,
        selected = isLive,
        modifier = modifier.height(78.dp),
        padding = PaddingValues(horizontal = 12.dp, vertical = 9.dp),
    ) {
        Column(verticalArrangement = Arrangement.Center) {
            Text(
                text = buildString {
                    when {
                        isLive -> append("LIVE  ")
                        hasCatchup -> append("REC  ")
                    }
                    append(programme.timeRange())
                },
                color = if (isLive || hasCatchup) TvColors.Accent else TvColors.Muted,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(5.dp))
            Text(
                text = programme.title.ifBlank { "Programma" },
                color = TvColors.Text,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private data class EpgRow(
    val channel: LiveChannel,
    val programmes: List<EpgProgramme>,
)

private fun EpgProgramme.isLiveAt(nowMillis: Long): Boolean =
    startTimeMillis <= nowMillis && nowMillis < endTimeMillis

private fun EpgProgramme.timeRange(): String =
    "${startTimeMillis.asClockTime()} - ${endTimeMillis.asClockTime()}"

private fun Long.asClockTime(): String =
    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(this))

private fun dayBoundary(referenceMillis: Long, dayOffset: Int): Long =
    Calendar.getInstance().run {
        timeInMillis = referenceMillis
        add(Calendar.DAY_OF_YEAR, dayOffset)
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
        timeInMillis
    }

private fun nextDayBoundary(dayStart: Long): Long =
    Calendar.getInstance().run {
        timeInMillis = dayStart
        add(Calendar.DAY_OF_YEAR, 1)
        timeInMillis
    }

private fun hourMarks(dayStart: Long, dayEnd: Long): List<Long> {
    val marks = mutableListOf<Long>()
    val calendar = Calendar.getInstance().apply { timeInMillis = dayStart }
    while (calendar.timeInMillis < dayEnd) {
        marks += calendar.timeInMillis
        calendar.add(Calendar.HOUR_OF_DAY, 1)
    }
    return marks
}

private fun minuteOffset(originMillis: Long, targetMillis: Long): Float =
    (targetMillis - originMillis) / 60_000f
