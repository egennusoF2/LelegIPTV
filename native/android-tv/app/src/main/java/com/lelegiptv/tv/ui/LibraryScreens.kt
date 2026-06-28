package com.lelegiptv.tv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lelegiptv.tv.SeriesDetailState
import com.lelegiptv.tv.SeriesState
import com.lelegiptv.tv.VodDetailState
import com.lelegiptv.tv.VodState
import com.lelegiptv.tv.data.LiveChannel
import com.lelegiptv.tv.data.SeriesEpisode
import com.lelegiptv.tv.data.SeriesInfo
import com.lelegiptv.tv.data.SeriesShow
import com.lelegiptv.tv.data.VodInfo
import com.lelegiptv.tv.data.VodMovie
import coil3.compose.AsyncImage

@Composable
fun HomeScreen(
    firstFocusRequester: FocusRequester,
    liveCount: Int,
    movieCount: Int?,
    seriesCount: Int?,
    onLive: () -> Unit,
    onMovies: () -> Unit,
    onSeries: () -> Unit,
    onMoveLeftToMenu: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            BasicText(
                "IN EVIDENZA",
                style = TextStyle(
                    color = TvColors.Muted,
                    fontSize = TvTypography.eyebrow,
                    fontWeight = FontWeight.ExtraBold,
                    letterSpacing = 1.1.sp,
                    fontFamily = TvTypography.fontFamily,
                ),
            )
            BasicText(
                "Leleg IPTV",
                style = TextStyle(
                    color = TvColors.Text,
                    fontSize = TvTypography.pageTitle,
                    fontWeight = FontWeight.Black,
                    fontFamily = TvTypography.fontFamily,
                    lineHeight = 28.sp,
                ),
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(TvTypography.hubHeight),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            HubTile(
                title = "Live TV",
                subtitle = "$liveCount canali e cosa va in onda adesso.",
                icon = TvNavIcons.Live,
                onClick = onLive,
                prominent = true,
                focusRequester = firstFocusRequester,
                modifier = Modifier
                    .weight(2f)
                    .fillMaxHeight()
                    .onPreviewKeyEvent {
                        if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionLeft) {
                            onMoveLeftToMenu()
                            true
                        } else {
                            false
                        }
                    },
            )
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                HubTile(
                    title = "Film",
                    subtitle = movieCount?.let { "$it titoli nel catalogo." } ?: "Apri il catalogo film.",
                    icon = TvNavIcons.Movies,
                    onClick = onMovies,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                )
                HubTile(
                    title = "Serie",
                    subtitle = seriesCount?.let { "$it serie e stagioni complete." }
                        ?: "Apri il catalogo serie.",
                    icon = TvNavIcons.Series,
                    onClick = onSeries,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
fun MovieBrowserScreen(
    state: VodState,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onMovie: (VodMovie) -> Unit,
) {
    when (state) {
        VodState.Idle, VodState.Loading -> LibraryLoading("Caricamento film...")
        is VodState.Failed -> LibraryError(state.message)
        is VodState.Ready -> {
            var categoryId by remember { mutableStateOf("") }
            val categories = remember(state.categories) {
                listOf("" to "Tutti i film") + state.categories.map { it.id to it.name }
            }
            val moviesByCategory = remember(state.movies) {
                state.movies.groupBy(VodMovie::categoryId)
            }
            val movies = remember(state.movies, moviesByCategory, categoryId) {
                if (categoryId.isBlank()) state.movies
                else moviesByCategory[categoryId].orEmpty()
            }
            LibraryBrowser(
                title = "Film",
                countLabel = "${movies.size} di ${state.movies.size} titoli",
                categories = categories,
                selectedCategory = categoryId,
                onCategory = { categoryId = it },
                firstFocusRequester = firstFocusRequester,
                onMoveLeftToMenu = onMoveLeftToMenu,
                entries = movies,
                entryKey = { it.id },
                entryTitle = { it.name },
                entrySubtitle = { listOf(it.year, it.rating).filter(String::isNotBlank).joinToString("  •  ") },
                entryImage = { it.logo },
                onEntry = onMovie,
            )
        }
    }
}

@Composable
fun SeriesBrowserScreen(
    state: SeriesState,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onShow: (SeriesShow) -> Unit,
) {
    when (state) {
        SeriesState.Idle, SeriesState.Loading -> LibraryLoading("Caricamento serie...")
        is SeriesState.Failed -> LibraryError(state.message)
        is SeriesState.Ready -> {
            var categoryId by remember { mutableStateOf("") }
            val categories = remember(state.categories) {
                listOf("" to "Tutte le serie") + state.categories.map { it.id to it.name }
            }
            val showsByCategory = remember(state.shows) {
                state.shows.groupBy(SeriesShow::categoryId)
            }
            val shows = remember(state.shows, showsByCategory, categoryId) {
                if (categoryId.isBlank()) state.shows
                else showsByCategory[categoryId].orEmpty()
            }
            LibraryBrowser(
                title = "Serie",
                countLabel = "${shows.size} di ${state.shows.size} titoli",
                categories = categories,
                selectedCategory = categoryId,
                onCategory = { categoryId = it },
                firstFocusRequester = firstFocusRequester,
                onMoveLeftToMenu = onMoveLeftToMenu,
                entries = shows,
                entryKey = { it.id },
                entryTitle = { it.name },
                entrySubtitle = { listOf(it.year, it.rating).filter(String::isNotBlank).joinToString("  •  ") },
                entryImage = { it.logo },
                onEntry = onShow,
            )
        }
    }
}

@Composable
private fun <T> LibraryBrowser(
    title: String,
    countLabel: String,
    categories: List<Pair<String, String>>,
    selectedCategory: String,
    onCategory: (String) -> Unit,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    entries: List<T>,
    entryKey: (T) -> Any,
    entryTitle: (T) -> String,
    entrySubtitle: (T) -> String,
    entryImage: (T) -> String,
    onEntry: (T) -> Unit,
) {
    val categoryFocusRequester = remember { FocusRequester() }
    val entryFocusRequester = remember { FocusRequester() }
    val entryGridState = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    var focusedEntryIndex by remember { mutableIntStateOf(0) }

    LaunchedEffect(selectedCategory, entries.size) {
        focusedEntryIndex = 0
        if (entries.isNotEmpty()) {
            entryGridState.scrollToItem(0)
        }
    }

    fun focusCategoryList() {
        scope.launch {
            if (categories.firstOrNull()?.first == selectedCategory) {
                firstFocusRequester.safeRequestFocus()
            } else {
                categoryFocusRequester.safeRequestFocus()
            }
        }
    }

    fun focusEntryGrid() {
        scope.launch {
            if (entries.isEmpty()) return@launch
            val index = focusedEntryIndex.coerceIn(0, entries.lastIndex)
            entryGridState.scrollToItem(index)
            if (index == 0) {
                entryFocusRequester.safeRequestFocus()
            }
        }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 20.dp)) {
        PageHeader(title = title, subtitle = countLabel)
        Row(
            modifier = Modifier.fillMaxSize().padding(top = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            LazyColumn(
                modifier = Modifier.width(220.dp).fillMaxHeight(),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(categories, key = { it.first }) { category ->
                    val itemFocusRequester = when {
                        category == categories.firstOrNull() -> firstFocusRequester
                        category.first == selectedCategory -> categoryFocusRequester
                        else -> null
                    }
                    FocusCard(
                        onClick = { onCategory(category.first) },
                        selected = selectedCategory == category.first,
                        focusRequester = itemFocusRequester,
                        modifier = Modifier
                            .fillMaxWidth()
                            .onPreviewKeyEvent {
                                if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                when (it.key) {
                                    Key.DirectionLeft -> {
                                        if (category == categories.firstOrNull()) {
                                            onMoveLeftToMenu()
                                            true
                                        } else {
                                            false
                                        }
                                    }
                                    Key.DirectionRight -> {
                                        if (entries.isNotEmpty()) {
                                            focusEntryGrid()
                                            true
                                        } else {
                                            false
                                        }
                                    }
                                    else -> false
                                }
                            },
                    ) {
                        ItemTitle(category.second)
                    }
                }
            }
            if (entries.isEmpty()) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    contentAlignment = Alignment.Center,
                ) {
                    BasicText(
                        "Nessun titolo in questa categoria",
                        style = TextStyle(color = TvColors.Muted, fontSize = TvTypography.body),
                    )
                }
            } else {
                LazyVerticalGrid(
                    state = entryGridState,
                    columns = GridCells.Adaptive(TvTypography.posterWidth),
                    modifier = Modifier.weight(1f).fillMaxHeight(),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(
                        count = entries.size,
                        key = { index -> entryKey(entries[index]) },
                    ) { index ->
                        val entry = entries[index]
                        val isFocusedEntry = index == focusedEntryIndex
                        FocusCard(
                            onClick = { onEntry(entry) },
                            focusRequester = if (index == 0) entryFocusRequester else null,
                            modifier = Modifier
                                .fillMaxWidth()
                                .aspectRatio(2f / 3f)
                                .onFocusChanged {
                                    if (it.isFocused) focusedEntryIndex = index
                                }
                                .onPreviewKeyEvent {
                                    if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                    when (it.key) {
                                        Key.DirectionLeft -> {
                                            focusCategoryList()
                                            true
                                        }
                                        else -> false
                                    }
                                },
                            padding = PaddingValues(0.dp),
                        ) {
                            Box(Modifier.fillMaxSize()) {
                                val imageUrl = entryImage(entry)
                                if (imageUrl.isNotBlank()) {
                                    AsyncImage(
                                        model = imageUrl,
                                        contentDescription = entryTitle(entry),
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                } else {
                                    Box(
                                        modifier = Modifier
                                            .fillMaxSize()
                                            .background(TvColors.SurfaceDeep),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        BasicText(
                                            entryTitle(entry).take(1).uppercase(),
                                            style = TextStyle(
                                                color = TvColors.Muted,
                                                fontSize = 22.sp,
                                                fontWeight = FontWeight.Bold,
                                            ),
                                        )
                                    }
                                }
                                Column(
                                    modifier = Modifier
                                        .align(Alignment.BottomStart)
                                        .fillMaxWidth()
                                        .background(androidx.compose.ui.graphics.Color(0xDD081017))
                                        .padding(8.dp),
                                ) {
                                    BasicText(
                                        entryTitle(entry),
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                        style = TextStyle(
                                            color = TvColors.Text,
                                            fontSize = TvTypography.cardTitle,
                                            fontWeight = FontWeight.SemiBold,
                                            fontFamily = TvTypography.fontFamily,
                                        ),
                                    )
                                    val subtitle = entrySubtitle(entry)
                                    if (subtitle.isNotBlank()) {
                                        BasicText(
                                            subtitle,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                            style = TextStyle(
                                                color = TvColors.Muted,
                                                fontSize = TvTypography.cardMeta,
                                                fontFamily = TvTypography.fontFamily,
                                            ),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun MovieDetailScreen(
    state: VodDetailState,
    firstFocusRequester: FocusRequester,
    onPlay: (VodMovie) -> Unit,
) {
    when (state) {
        VodDetailState.Idle -> LibraryLoading("Seleziona un film")
        is VodDetailState.Loading -> DetailLayout(
            title = state.movie.name,
            imageUrl = state.movie.logo,
            description = state.movie.plot,
            metadata = "Caricamento dettagli...",
            firstFocusRequester = firstFocusRequester,
            onPlay = { onPlay(state.movie) },
        )
        is VodDetailState.Failed -> DetailLayout(
            title = state.movie.name,
            imageUrl = state.movie.logo,
            description = state.movie.plot.ifBlank { state.message },
            metadata = state.message,
            firstFocusRequester = firstFocusRequester,
            onPlay = { onPlay(state.movie) },
        )
        is VodDetailState.Ready -> MovieInfoLayout(
            info = state.info,
            firstFocusRequester = firstFocusRequester,
            onPlay = onPlay,
        )
    }
}

@Composable
private fun MovieInfoLayout(
    info: VodInfo,
    firstFocusRequester: FocusRequester,
    onPlay: (VodMovie) -> Unit,
) {
    DetailLayout(
        title = info.movie.name,
        imageUrl = resolveVodImage(info),
        description = info.movie.plot,
        metadata = listOf(info.releaseDate, info.genre, info.duration, info.movie.rating)
            .filter(String::isNotBlank)
            .joinToString("  •  "),
        firstFocusRequester = firstFocusRequester,
        onPlay = { onPlay(info.movie) },
    )
}

private fun resolveVodImage(info: VodInfo): String =
    info.backdropUrls.firstOrNull { it.isNotBlank() } ?: info.movie.logo

private fun resolveSeriesImage(info: SeriesInfo): String =
    info.backdropUrls.firstOrNull { it.isNotBlank() } ?: info.show.logo

@Composable
private fun DetailLayout(
    title: String,
    imageUrl: String,
    description: String,
    metadata: String,
    firstFocusRequester: FocusRequester,
    onPlay: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxSize()
            .padding(40.dp),
        horizontalArrangement = Arrangement.spacedBy(28.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .width(320.dp)
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(10.dp))
                .background(TvColors.SurfaceDeep),
        ) {
            if (imageUrl.isNotBlank()) {
                AsyncImage(
                    model = imageUrl,
                    contentDescription = title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            BasicText(
                title,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = TvTypography.pageHeadingStyle,
            )
            if (metadata.isNotBlank()) {
                BasicText(metadata, style = TvTypography.accentCaptionStyle.copy(fontSize = TvTypography.body))
            }
            BasicText(
                description.ifBlank { "Descrizione non disponibile." },
                maxLines = 6,
                overflow = TextOverflow.Ellipsis,
                style = TvTypography.mutedStyle,
            )
            Spacer(Modifier.height(8.dp))
            FocusCard(
                onClick = onPlay,
                focusRequester = firstFocusRequester,
                modifier = Modifier.width(220.dp),
            ) {
                ItemTitle("Riproduci")
            }
        }
    }
}

@Composable
fun SeriesDetailScreen(
    state: SeriesDetailState,
    firstFocusRequester: FocusRequester,
    onEpisode: (SeriesEpisode) -> Unit,
) {
    when (state) {
        SeriesDetailState.Idle -> LibraryLoading("Seleziona una serie")
        is SeriesDetailState.Loading -> LibraryLoading("Caricamento ${state.show.name}...")
        is SeriesDetailState.Failed -> LibraryError(state.message)
        is SeriesDetailState.Ready -> SeriesEpisodes(
            info = state.info,
            firstFocusRequester = firstFocusRequester,
            onEpisode = onEpisode,
        )
    }
}

@Composable
private fun SeriesEpisodes(
    info: SeriesInfo,
    firstFocusRequester: FocusRequester,
    onEpisode: (SeriesEpisode) -> Unit,
) {
    val seasons = remember(info.episodes) {
        info.episodes
            .groupBy(SeriesEpisode::season)
            .toSortedMap()
    }
    var selectedSeason by remember(info.episodes) {
        mutableIntStateOf(seasons.keys.firstOrNull() ?: 1)
    }
    val seasonEpisodes = remember(info.episodes, selectedSeason) {
        info.episodes
            .filter { it.season == selectedSeason }
            .sortedBy(SeriesEpisode::episode)
    }
    val seasonListState = rememberLazyListState()
    val episodeListState = rememberLazyListState()
    val seasonFocusRequester = remember { FocusRequester() }
    val episodeFocusRequester = remember { FocusRequester() }
    val scope = rememberCoroutineScope()
    var focusedSeasonIndex by remember { mutableIntStateOf(0) }
    val seasonNumbers = seasons.keys.toList()
    val imageUrl = resolveSeriesImage(info)
    val totalEpisodes = info.episodes.size
    val seasonCountLabel =
        if (seasons.size == 1) "1 stagione" else "${seasons.size} stagioni"

    LaunchedEffect(seasons) {
        selectedSeason = seasons.keys.firstOrNull() ?: 1
        focusedSeasonIndex = 0
    }

    fun focusSeasonTabs() {
        scope.launch {
            if (seasonNumbers.isEmpty()) return@launch
            val index = focusedSeasonIndex.coerceIn(0, seasonNumbers.lastIndex)
            seasonListState.scrollToItem(index)
            if (index == 0) {
                firstFocusRequester.safeRequestFocus()
            } else {
                seasonFocusRequester.safeRequestFocus()
            }
        }
    }

    fun focusEpisodeList() {
        scope.launch {
            if (seasonEpisodes.isEmpty()) return@launch
            episodeListState.scrollToItem(0)
            episodeFocusRequester.safeRequestFocus()
        }
    }

    Column(Modifier.fillMaxSize().padding(30.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            Box(
                modifier = Modifier
                    .width(180.dp)
                    .aspectRatio(2f / 3f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(TvColors.SurfaceDeep),
            ) {
                if (imageUrl.isNotBlank()) {
                    AsyncImage(
                        model = imageUrl,
                        contentDescription = info.show.name,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                BasicText(
                    info.show.name,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = TvTypography.pageHeadingStyle,
                )
                BasicText(
                    listOf(
                        seasonCountLabel,
                        "$totalEpisodes episodi",
                        listOf(info.releaseDate, info.genre, info.show.rating)
                            .filter(String::isNotBlank)
                            .joinToString("  •  "),
                    ).filter(String::isNotBlank).joinToString("  •  "),
                    style = TvTypography.accentCaptionStyle.copy(fontSize = TvTypography.body),
                )
                if (info.show.plot.isNotBlank()) {
                    BasicText(
                        info.show.plot,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        style = TvTypography.mutedStyle,
                    )
                }
            }
        }

        if (seasonNumbers.isNotEmpty()) {
            Spacer(Modifier.height(18.dp))
            LazyRow(
                state = seasonListState,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                items(seasonNumbers, key = { it }) { seasonNumber ->
                    val index = seasonNumbers.indexOf(seasonNumber)
                    val episodeCount = seasons[seasonNumber]?.size ?: 0
                    val isSelected = selectedSeason == seasonNumber
                    val isFocusedTab = index == focusedSeasonIndex
                    FocusCard(
                        onClick = {
                            selectedSeason = seasonNumber
                            focusEpisodeList()
                        },
                        selected = isSelected,
                        focusRequester = when {
                            index == 0 && focusedSeasonIndex == 0 -> firstFocusRequester
                            isFocusedTab -> seasonFocusRequester
                            else -> null
                        },
                        modifier = Modifier
                            .width(190.dp)
                            .onFocusChanged {
                                if (it.isFocused) focusedSeasonIndex = index
                            }
                            .onPreviewKeyEvent {
                                if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                when (it.key) {
                                    Key.DirectionDown -> {
                                        focusEpisodeList()
                                        true
                                    }
                                    else -> false
                                }
                            },
                    ) {
                        Column {
                            ItemTitle("Stagione $seasonNumber")
                            BasicText(
                                if (episodeCount == 1) "1 episodio" else "$episodeCount episodi",
                                style = TvTypography.listMetaStyle,
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(14.dp))
        if (seasonEpisodes.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                BasicText(
                    "Nessun episodio in questa stagione",
                    style = TvTypography.mutedStyle,
                )
            }
        } else {
            LazyColumn(
                state = episodeListState,
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(seasonEpisodes, key = { it.id }) { episode ->
                    val isFirstEpisode = episode == seasonEpisodes.firstOrNull()
                    HorizontalMediaCard(
                        onClick = { onEpisode(episode) },
                        imageUrl = episode.image.ifBlank { imageUrl },
                        imageContentDescription = episode.title,
                        eyebrow =
                            "Stagione ${episode.season}  •  Episodio ${episode.episode}",
                        title = episode.title.ifBlank { "Episodio ${episode.episode}" },
                        subtitle = episode.duration.takeIf { it.isNotBlank() },
                        description = episode.plot.takeIf { it.isNotBlank() },
                        badge = episode.duration.takeIf { it.isNotBlank() },
                        focusRequester = if (isFirstEpisode) episodeFocusRequester else null,
                        modifier = Modifier.onPreviewKeyEvent {
                            if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                            when (it.key) {
                                Key.DirectionUp -> {
                                    if (isFirstEpisode) {
                                        focusSeasonTabs()
                                        true
                                    } else {
                                        false
                                    }
                                }
                                else -> false
                            }
                        },
                    )
                }
            }
        }
    }
}

sealed interface SearchResult {
    data class Channel(val value: LiveChannel) : SearchResult
    data class Movie(val value: VodMovie) : SearchResult
    data class Show(val value: SeriesShow) : SearchResult
}

@Composable
fun SearchScreen(
    channels: List<LiveChannel>,
    vodState: VodState,
    seriesState: SeriesState,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onResult: (SearchResult) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val movies = (vodState as? VodState.Ready)?.movies.orEmpty()
    val shows = (seriesState as? SeriesState.Ready)?.shows.orEmpty()
    val results = remember(query, channels, movies, shows) {
        val needle = query.trim()
        if (needle.length < 2) emptyList()
        else buildList {
            channels.asSequence().filter { it.name.contains(needle, true) }.take(40)
                .forEach { add(SearchResult.Channel(it)) }
            movies.asSequence().filter { it.name.contains(needle, true) }.take(40)
                .forEach { add(SearchResult.Movie(it)) }
            shows.asSequence().filter { it.name.contains(needle, true) }.take(40)
                .forEach { add(SearchResult.Show(it)) }
        }.take(100)
    }
    val resultsRequester = remember { FocusRequester() }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().padding(32.dp)) {
        ScreenHeading("Cerca", "Canali, film e serie")
        BasicTextField(
            value = query,
            onValueChange = { query = it },
            singleLine = true,
            textStyle = TextStyle(
                color = TvColors.Text,
                fontSize = TvTypography.inputText,
                fontFamily = TvTypography.fontFamily,
            ),
            cursorBrush = SolidColor(TvColors.Accent),
            modifier = Modifier
                .focusRequester(firstFocusRequester)
                .fillMaxWidth()
                .height(52.dp)
                .background(TvColors.Panel)
                .onPreviewKeyEvent {
                    if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    when (it.key) {
                        Key.DirectionLeft -> {
                            onMoveLeftToMenu()
                            true
                        }
                        Key.DirectionDown -> {
                            if (results.isNotEmpty()) {
                                scope.launch { resultsRequester.safeRequestFocus() }
                                true
                            } else {
                                false
                            }
                        }
                        else -> false
                    }
                }
                .padding(horizontal = 16.dp, vertical = 13.dp),
        )
        Spacer(Modifier.height(14.dp))
        LazyColumn(
            modifier = Modifier.fillMaxSize().focusRestorer(),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            contentPadding = PaddingValues(bottom = 24.dp),
        ) {
            items(
                count = results.size,
                key = { index -> searchResultKey(results[index]) },
            ) { index ->
                val result = results[index]
                SearchResultCard(
                    result = result,
                    onClick = { onResult(result) },
                    focusRequester = if (index == 0) resultsRequester else null,
                )
            }
        }
    }
}

@Composable
private fun SearchResultCard(
    result: SearchResult,
    onClick: () -> Unit,
    focusRequester: FocusRequester?,
) {
    when (result) {
        is SearchResult.Channel -> HorizontalMediaCard(
            onClick = onClick,
            imageUrl = result.value.logo,
            imageContentDescription = result.value.name,
            eyebrow = "CANALE  •  LIVE TV",
            title = result.value.name,
            subtitle = buildString {
                append("Canale #${result.value.id}")
                if (result.value.hasCatchup) {
                    append("  •  Archivio ${result.value.catchupDays.coerceAtLeast(1)}g")
                }
            },
            focusRequester = focusRequester,
        )
        is SearchResult.Movie -> {
            val movie = result.value
            HorizontalMediaCard(
                onClick = onClick,
                imageUrl = movie.logo,
                imageContentDescription = movie.name,
                eyebrow = "FILM",
                title = movie.name,
                badge = movie.year.ifBlank { movie.rating }.takeIf { it.isNotBlank() },
                subtitle = listOf(movie.year, movie.rating)
                    .filter(String::isNotBlank)
                    .joinToString("  •  ")
                    .ifBlank { null },
                description = movie.plot,
                focusRequester = focusRequester,
            )
        }
        is SearchResult.Show -> {
            val show = result.value
            HorizontalMediaCard(
                onClick = onClick,
                imageUrl = show.logo,
                imageContentDescription = show.name,
                eyebrow = "SERIE TV",
                title = show.name,
                badge = show.year.ifBlank { show.rating }.takeIf { it.isNotBlank() },
                subtitle = listOf(show.year, show.rating)
                    .filter(String::isNotBlank)
                    .joinToString("  •  ")
                    .ifBlank { null },
                description = show.plot,
                focusRequester = focusRequester,
            )
        }
    }
}

private fun searchResultKey(result: SearchResult): String =
    when (result) {
        is SearchResult.Channel -> "channel_${result.value.id}"
        is SearchResult.Movie -> "movie_${result.value.id}"
        is SearchResult.Show -> "show_${result.value.id}"
    }

@Composable
private fun ScreenHeading(title: String, subtitle: String) {
    PageHeader(title = title, subtitle = subtitle)
}

@Composable
private fun ItemTitle(value: String) {
    BasicText(
        value,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        style = TvTypography.listTitleStyle,
    )
}

@Composable
private fun LibraryLoading(message: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        BasicText(message, style = TvTypography.mutedStyle)
    }
}

@Composable
private fun LibraryError(message: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        BasicText(message, style = TvTypography.mutedStyle.copy(color = TvColors.Error))
    }
}
