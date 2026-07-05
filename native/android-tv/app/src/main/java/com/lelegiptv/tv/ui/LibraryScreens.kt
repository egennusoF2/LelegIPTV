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
import androidx.compose.ui.graphics.Color
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
import com.lelegiptv.tv.data.ContinueWatchingItem
import com.lelegiptv.tv.data.FavoriteKind
import com.lelegiptv.tv.data.PlaybackProgress
import com.lelegiptv.tv.data.UserLibrarySnapshot
import com.lelegiptv.tv.data.favoriteMetaKey
import com.lelegiptv.tv.data.LiveChannel
import com.lelegiptv.tv.data.SeriesEpisode
import com.lelegiptv.tv.data.SeriesInfo
import com.lelegiptv.tv.data.SeriesShow
import com.lelegiptv.tv.data.VodInfo
import com.lelegiptv.tv.data.VodMovie
import coil3.compose.AsyncImage

private enum class CatalogSortMode(val label: String) {
    RECENT("Più recenti"),
    TITLE("Titolo A-Z"),
    RATING("Punteggio"),
    RECOMMENDED("Consigliati per te");

    fun next(): CatalogSortMode = entries[(ordinal + 1) % entries.size]
}

private fun rating(value: String): Double =
    value.replace(',', '.').toDoubleOrNull() ?: 0.0

private fun words(value: String): Set<String> =
    value.lowercase()
        .split(Regex("[^a-z0-9à-ÿ]+"))
        .filterTo(mutableSetOf()) { it.length >= 3 }

private fun sortMovies(
    source: List<VodMovie>,
    mode: CatalogSortMode,
    favorites: Set<Int>,
): List<VodMovie> {
    val favoriteItems = source.filter { it.id in favorites }
    return when (mode) {
        CatalogSortMode.TITLE -> source.sortedBy { it.name.lowercase() }
        CatalogSortMode.RATING -> source.sortedByDescending { rating(it.rating) }
        CatalogSortMode.RECOMMENDED -> source
            .filterNot { it.id in favorites }
            .sortedByDescending { movie ->
                val tokens = words(movie.name)
                favoriteItems.sumOf { favorite ->
                    (if (favorite.categoryId == movie.categoryId) 6 else 0) +
                        tokens.intersect(words(favorite.name)).size * 2
                } + rating(movie.rating) * 0.1
            }
        CatalogSortMode.RECENT -> source.sortedByDescending(VodMovie::id)
    }
}

private fun sortShows(
    source: List<SeriesShow>,
    mode: CatalogSortMode,
    favorites: Set<Int>,
): List<SeriesShow> {
    val favoriteItems = source.filter { it.id in favorites }
    return when (mode) {
        CatalogSortMode.TITLE -> source.sortedBy { it.name.lowercase() }
        CatalogSortMode.RATING -> source.sortedByDescending { rating(it.rating) }
        CatalogSortMode.RECOMMENDED -> source
            .filterNot { it.id in favorites }
            .sortedByDescending { show ->
                val tokens = words(show.name)
                favoriteItems.sumOf { favorite ->
                    (if (favorite.categoryId == show.categoryId) 6 else 0) +
                        tokens.intersect(words(favorite.name)).size * 2
                } + rating(show.rating) * 0.1
            }
        CatalogSortMode.RECENT -> source.sortedByDescending(SeriesShow::id)
    }
}

@Composable
fun HomeScreen(
    firstFocusRequester: FocusRequester,
    liveCount: Int,
    movieCount: Int?,
    seriesCount: Int?,
    continueWatching: List<ContinueWatchingItem>,
    onContinueMovie: (Int) -> Unit,
    onContinueEpisode: (Int, Int) -> Unit,
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

        val continueFocusRequester = remember { FocusRequester() }
        val scope = rememberCoroutineScope()
        val hubCompact = continueWatching.isNotEmpty()
        val hubHeight = if (hubCompact) TvTypography.hubHeightCompact else TvTypography.hubHeight

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(hubHeight),
            horizontalArrangement = Arrangement.spacedBy(if (hubCompact) 12.dp else 16.dp),
        ) {
            HubTile(
                title = "Live TV",
                subtitle = "$liveCount canali e cosa va in onda adesso.",
                icon = TvNavIcons.Live,
                onClick = onLive,
                prominent = true,
                compact = hubCompact,
                focusRequester = firstFocusRequester,
                modifier = Modifier
                    .weight(2f)
                    .fillMaxHeight()
                    .onPreviewKeyEvent {
                        if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                        when (it.key) {
                            Key.DirectionLeft -> {
                                onMoveLeftToMenu()
                                true
                            }
                            Key.DirectionDown -> {
                                if (continueWatching.isNotEmpty()) {
                                    scope.launch { continueFocusRequester.safeRequestFocus() }
                                    true
                                } else {
                                    false
                                }
                            }
                            else -> false
                        }
                    },
            )
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                verticalArrangement = Arrangement.spacedBy(if (hubCompact) 10.dp else 16.dp),
            ) {
                HubTile(
                    title = "Film",
                    subtitle = movieCount?.let { "$it categorie nel catalogo." } ?: "Apri il catalogo film.",
                    icon = TvNavIcons.Movies,
                    onClick = onMovies,
                    compact = hubCompact,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                )
                HubTile(
                    title = "Serie",
                    subtitle = seriesCount?.let { "$it categorie nel catalogo." }
                        ?: "Apri il catalogo serie.",
                    icon = TvNavIcons.Series,
                    onClick = onSeries,
                    compact = hubCompact,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                )
            }
        }

        if (continueWatching.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                BasicText(
                    "CONTINUA A GUARDARE",
                    style = TextStyle(
                        color = TvColors.Muted,
                        fontSize = TvTypography.eyebrow,
                        fontWeight = FontWeight.ExtraBold,
                        letterSpacing = 1.1.sp,
                        fontFamily = TvTypography.fontFamily,
                    ),
                )
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    items(continueWatching, key = {
                        when (it) {
                            is ContinueWatchingItem.Movie -> "m-${it.movieId}"
                            is ContinueWatchingItem.Episode -> "e-${it.episodeId}"
                        }
                    }) { item ->
                        val isFirst = item == continueWatching.firstOrNull()
                        ContinueWatchingCard(
                            item = item,
                            focusRequester = if (isFirst) continueFocusRequester else null,
                            onClick = {
                                when (item) {
                                    is ContinueWatchingItem.Movie -> onContinueMovie(item.movieId)
                                    is ContinueWatchingItem.Episode ->
                                        onContinueEpisode(item.seriesId, item.episodeId)
                                }
                            },
                            modifier = if (isFirst) {
                                Modifier.onPreviewKeyEvent {
                                    if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                    when (it.key) {
                                        Key.DirectionLeft -> {
                                            onMoveLeftToMenu()
                                            true
                                        }
                                        Key.DirectionUp -> {
                                            scope.launch { firstFocusRequester.safeRequestFocus() }
                                            true
                                        }
                                        else -> false
                                    }
                                }
                            } else {
                                Modifier
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun MovieBrowserScreen(
    state: VodState,
    library: UserLibrarySnapshot,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onCategorySelect: (String) -> Unit,
    onMovie: (VodMovie) -> Unit,
) {
    when (state) {
        is VodState.Failed -> LibraryError(state.message)
        VodState.Idle, VodState.Loading -> LibraryLoading("Caricamento categorie film...")
        is VodState.Ready -> {
            if (state.categories.isEmpty()) {
                LibraryError("Nessuna categoria film disponibile")
            } else if (state.categoryLoading && state.movies.isEmpty()) {
                LibraryLoading("Caricamento titoli...")
            } else {
            val categories = remember(state.categories) {
                state.categories.map { it.id to it.name }
            }
            val selectedCategory = state.selectedCategoryId.ifBlank {
                state.categories.firstOrNull()?.id.orEmpty()
            }
            var sortMode by remember { mutableStateOf(CatalogSortMode.RECENT) }
            val sortedMovies = remember(state.movies, sortMode, library.favoriteVod) {
                sortMovies(state.movies, sortMode, library.favoriteVod)
            }
            LibraryBrowser(
                title = "Film",
                countLabel = "${state.movies.size} titoli in questa categoria",
                categories = categories,
                selectedCategory = selectedCategory,
                onCategory = onCategorySelect,
                firstFocusRequester = firstFocusRequester,
                onMoveLeftToMenu = onMoveLeftToMenu,
                entries = sortedMovies,
                sortLabel = sortMode.label,
                onSortNext = { sortMode = sortMode.next() },
                entryKey = { it.id },
                entryTitle = { it.name },
                entrySubtitle = { listOf(it.year, it.rating).filter(String::isNotBlank).joinToString("  •  ") },
                entryImage = { it.logo },
                onEntry = onMovie,
            )
            }
        }
    }
}

@Composable
fun SeriesBrowserScreen(
    state: SeriesState,
    library: UserLibrarySnapshot,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onCategorySelect: (String) -> Unit,
    onShow: (SeriesShow) -> Unit,
) {
    when (state) {
        is SeriesState.Failed -> LibraryError(state.message)
        SeriesState.Idle, SeriesState.Loading -> LibraryLoading("Caricamento categorie serie...")
        is SeriesState.Ready -> {
            if (state.categories.isEmpty()) {
                LibraryError("Nessuna categoria serie disponibile")
            } else if (state.categoryLoading && state.shows.isEmpty()) {
                LibraryLoading("Caricamento titoli...")
            } else {
            val categories = remember(state.categories) {
                state.categories.map { it.id to it.name }
            }
            val selectedCategory = state.selectedCategoryId.ifBlank {
                state.categories.firstOrNull()?.id.orEmpty()
            }
            var sortMode by remember { mutableStateOf(CatalogSortMode.RECENT) }
            val sortedShows = remember(state.shows, sortMode, library.favoriteSeries) {
                sortShows(state.shows, sortMode, library.favoriteSeries)
            }
            LibraryBrowser(
                title = "Serie",
                countLabel = "${state.shows.size} titoli in questa categoria",
                categories = categories,
                selectedCategory = selectedCategory,
                onCategory = onCategorySelect,
                firstFocusRequester = firstFocusRequester,
                onMoveLeftToMenu = onMoveLeftToMenu,
                entries = sortedShows,
                sortLabel = sortMode.label,
                onSortNext = { sortMode = sortMode.next() },
                entryKey = { it.id },
                entryTitle = { it.name },
                entrySubtitle = { listOf(it.year, it.rating).filter(String::isNotBlank).joinToString("  •  ") },
                entryImage = { it.logo },
                onEntry = onShow,
            )
            }
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
    sortLabel: String,
    onSortNext: () -> Unit,
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
            Column(
                modifier = Modifier.width(220.dp).fillMaxHeight(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FocusCard(
                    onClick = onSortNext,
                    modifier = Modifier
                        .fillMaxWidth()
                        .onPreviewKeyEvent {
                            if (it.type != KeyEventType.KeyDown) {
                                return@onPreviewKeyEvent false
                            }
                            when (it.key) {
                                Key.DirectionLeft -> {
                                    onMoveLeftToMenu()
                                    true
                                }
                                Key.DirectionRight -> {
                                    focusEntryGrid()
                                    true
                                }
                                else -> false
                            }
                        },
                ) {
                    Column {
                        BasicText(
                            "ORDINA",
                            style = TextStyle(
                                color = TvColors.Muted,
                                fontSize = TvTypography.cardMeta,
                                fontWeight = FontWeight.Bold,
                            ),
                        )
                        ItemTitle(sortLabel)
                    }
                }
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().weight(1f),
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
    library: UserLibrarySnapshot,
    firstFocusRequester: FocusRequester,
    onPlay: (VodMovie, Boolean) -> Unit,
    onToggleFavorite: (VodMovie) -> Unit,
) {
    when (state) {
        VodDetailState.Idle -> LibraryLoading("Seleziona un film")
        is VodDetailState.Loading -> {
            val progress = library.movieProgress[state.movie.id]?.progress
            DetailLayout(
                title = state.movie.name,
                imageUrl = state.movie.logo,
                description = state.movie.plot,
                metadata = "Caricamento dettagli...",
                canResume = progress?.canResume == true,
                isFavorite = library.isFavorite(FavoriteKind.VOD, state.movie.id),
                firstFocusRequester = firstFocusRequester,
                onPlay = { onPlay(state.movie, false) },
                onRestart = if (progress?.canResume == true) {
                    { onPlay(state.movie, true) }
                } else {
                    null
                },
                onToggleFavorite = { onToggleFavorite(state.movie) },
            )
        }
        is VodDetailState.Failed -> {
            val progress = library.movieProgress[state.movie.id]?.progress
            DetailLayout(
                title = state.movie.name,
                imageUrl = state.movie.logo,
                description = state.movie.plot.ifBlank { state.message },
                metadata = state.message,
                canResume = progress?.canResume == true,
                isFavorite = library.isFavorite(FavoriteKind.VOD, state.movie.id),
                firstFocusRequester = firstFocusRequester,
                onPlay = { onPlay(state.movie, false) },
                onRestart = if (progress?.canResume == true) {
                    { onPlay(state.movie, true) }
                } else {
                    null
                },
                onToggleFavorite = { onToggleFavorite(state.movie) },
            )
        }
        is VodDetailState.Ready -> MovieInfoLayout(
            info = state.info,
            library = library,
            firstFocusRequester = firstFocusRequester,
            onPlay = onPlay,
            onToggleFavorite = onToggleFavorite,
        )
    }
}

@Composable
private fun MovieInfoLayout(
    info: VodInfo,
    library: UserLibrarySnapshot,
    firstFocusRequester: FocusRequester,
    onPlay: (VodMovie, Boolean) -> Unit,
    onToggleFavorite: (VodMovie) -> Unit,
) {
    val progress = library.movieProgress[info.movie.id]?.progress
    DetailLayout(
        title = info.movie.name,
        imageUrl = resolveVodImage(info),
        description = info.movie.plot,
        metadata = listOf(info.releaseDate, info.genre, info.duration, info.movie.rating)
            .filter(String::isNotBlank)
            .joinToString("  •  "),
        canResume = progress?.canResume == true,
        isFavorite = library.isFavorite(FavoriteKind.VOD, info.movie.id),
        firstFocusRequester = firstFocusRequester,
        onPlay = { onPlay(info.movie, false) },
        onRestart = if (progress?.canResume == true) {
            { onPlay(info.movie, true) }
        } else {
            null
        },
        onToggleFavorite = { onToggleFavorite(info.movie) },
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
    canResume: Boolean = false,
    isFavorite: Boolean = false,
    onPlay: () -> Unit,
    onRestart: (() -> Unit)? = null,
    onToggleFavorite: (() -> Unit)? = null,
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
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FocusCard(
                    onClick = onPlay,
                    focusRequester = firstFocusRequester,
                    modifier = Modifier.width(180.dp),
                ) {
                    ItemTitle(if (canResume) "Riprendi" else "Riproduci")
                }
                if (onRestart != null) {
                    FocusCard(
                        onClick = onRestart,
                        modifier = Modifier.width(180.dp),
                    ) {
                        ItemTitle("Ricomincia")
                    }
                }
                if (onToggleFavorite != null) {
                    FocusCard(
                        onClick = onToggleFavorite,
                        modifier = Modifier.width(180.dp),
                    ) {
                        ItemTitle(if (isFavorite) "★ Preferito" else "☆ Preferiti")
                    }
                }
            }
        }
    }
}

@Composable
fun SeriesDetailScreen(
    state: SeriesDetailState,
    library: UserLibrarySnapshot,
    firstFocusRequester: FocusRequester,
    onEpisode: (SeriesEpisode, Boolean) -> Unit,
    onToggleFavorite: (SeriesShow) -> Unit,
) {
    when (state) {
        SeriesDetailState.Idle -> LibraryLoading("Seleziona una serie")
        is SeriesDetailState.Loading -> LibraryLoading("Caricamento ${state.show.name}...")
        is SeriesDetailState.Failed -> LibraryError(state.message)
        is SeriesDetailState.Ready -> SeriesEpisodes(
            info = state.info,
            library = library,
            firstFocusRequester = firstFocusRequester,
            onEpisode = onEpisode,
            onToggleFavorite = { onToggleFavorite(state.info.show) },
        )
    }
}

@Composable
private fun SeriesEpisodes(
    info: SeriesInfo,
    library: UserLibrarySnapshot,
    firstFocusRequester: FocusRequester,
    onEpisode: (SeriesEpisode, Boolean) -> Unit,
    onToggleFavorite: () -> Unit,
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

    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 20.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Box(
                modifier = Modifier
                    .width(132.dp)
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
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        style = TvTypography.mutedStyle.copy(fontSize = TvTypography.body),
                    )
                }
                FocusCard(
                    onClick = onToggleFavorite,
                    modifier = Modifier.width(200.dp),
                ) {
                    ItemTitle(
                        if (library.isFavorite(FavoriteKind.SERIES, info.show.id)) {
                            "★ Preferita"
                        } else {
                            "☆ Aggiungi ai preferiti"
                        },
                    )
                }
            }
        }

        if (seasonNumbers.isNotEmpty()) {
            Spacer(Modifier.height(12.dp))
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

        Spacer(Modifier.height(10.dp))
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
                contentPadding = PaddingValues(bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(seasonEpisodes, key = { it.id }) { episode ->
                    val isFirstEpisode = episode == seasonEpisodes.firstOrNull()
                    val episodeProgress = library.episodeProgress[episode.id]?.progress
                    val progressBadge = episodeProgress?.progressLabel
                    val durationBadge =
                        progressBadge ?: episode.duration.takeIf { it.isNotBlank() }
                    HorizontalMediaCard(
                        onClick = { onEpisode(episode, false) },
                        imageUrl = episode.image.ifBlank { imageUrl },
                        imageContentDescription = episode.title,
                        eyebrow =
                            "Stagione ${episode.season}  •  Episodio ${episode.episode}",
                        title = episode.title.ifBlank { "Episodio ${episode.episode}" },
                        badge = durationBadge,
                        progressFraction = episodeProgress?.fraction?.toFloat(),
                        compact = true,
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

private enum class SearchFilter {
    ALL,
    LIVE,
    VOD,
    SERIES,
}

@Composable
fun SearchScreen(
    channels: List<LiveChannel>,
    movies: List<VodMovie>,
    shows: List<SeriesShow>,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onResult: (SearchResult) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf(SearchFilter.ALL) }
    val channelResults = remember(query, channels) {
        val needle = query.trim()
        if (needle.length < 2) emptyList()
        else channels.asSequence().filter { it.name.contains(needle, true) }.take(40).toList()
    }
    val movieResults = remember(query, movies) {
        val needle = query.trim()
        if (needle.length < 2) emptyList()
        else movies.asSequence().filter { it.name.contains(needle, true) }.take(40).toList()
    }
    val showResults = remember(query, shows) {
        val needle = query.trim()
        if (needle.length < 2) emptyList()
        else shows.asSequence().filter { it.name.contains(needle, true) }.take(40).toList()
    }
    val results = remember(channelResults, movieResults, showResults, filter) {
        buildList {
            if (filter == SearchFilter.ALL || filter == SearchFilter.LIVE) {
                channelResults.forEach { add(SearchResult.Channel(it)) }
            }
            if (filter == SearchFilter.ALL || filter == SearchFilter.VOD) {
                movieResults.forEach { add(SearchResult.Movie(it)) }
            }
            if (filter == SearchFilter.ALL || filter == SearchFilter.SERIES) {
                showResults.forEach { add(SearchResult.Show(it)) }
            }
        }
    }
    val filters = SearchFilter.entries
    val filterRequester = remember { FocusRequester() }
    val resultsRequester = remember { FocusRequester() }
    val scope = rememberCoroutineScope()
    val gridState = rememberLazyGridState()
    val subtitle = remember(query, channelResults, movieResults, showResults, results, filter) {
        val needle = query.trim()
        when {
            needle.length < 2 -> "Canali, film e serie"
            filter == SearchFilter.ALL ->
                "${results.size} risultati • ${channelResults.size} live • ${movieResults.size} film • ${showResults.size} serie"
            else -> "${results.size} risultati"
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ScreenHeading("Cerca", subtitle)
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
                            scope.launch { filterRequester.safeRequestFocus() }
                            true
                        }
                        else -> false
                    }
                }
                .padding(horizontal = 16.dp, vertical = 13.dp),
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(filters.size) { index ->
                val item = filters[index]
                val label = when (item) {
                    SearchFilter.ALL -> "Tutti"
                    SearchFilter.LIVE -> "Live"
                    SearchFilter.VOD -> "Film"
                    SearchFilter.SERIES -> "Serie"
                }
                FocusCard(
                    onClick = { filter = item },
                    selected = filter == item,
                    focusRequester = if (index == 0) filterRequester else null,
                    modifier = if (index == 0) {
                        Modifier.onPreviewKeyEvent {
                            if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionLeft) {
                                onMoveLeftToMenu()
                                true
                            } else {
                                false
                            }
                        }
                    } else {
                        Modifier
                    },
                ) {
                    ItemTitle(label)
                }
            }
        }
        when {
            query.trim().length < 2 -> {
                BasicText(
                    "Digita almeno 2 caratteri",
                    style = TextStyle(color = TvColors.Muted, fontSize = TvTypography.body),
                )
            }
            results.isEmpty() -> {
                BasicText(
                    when (filter) {
                        SearchFilter.LIVE -> "Nessun canale trovato"
                        SearchFilter.VOD -> "Nessun film trovato nelle categorie caricate"
                        SearchFilter.SERIES -> "Nessuna serie trovata nelle categorie caricate"
                        SearchFilter.ALL -> "Nessun risultato"
                    },
                    style = TextStyle(color = TvColors.Muted, fontSize = TvTypography.body),
                )
            }
            else -> {
                LazyVerticalGrid(
                    state = gridState,
                    columns = GridCells.Adaptive(TvTypography.posterWidth),
                    modifier = Modifier
                        .fillMaxSize()
                        .focusRestorer(),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
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
                            onMoveLeftToMenu = onMoveLeftToMenu,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchResultCard(
    result: SearchResult,
    onClick: () -> Unit,
    focusRequester: FocusRequester?,
    onMoveLeftToMenu: () -> Unit,
) {
    val imageUrl: String
    val imageLabel: String
    val eyebrow: String
    val title: String
    val subtitle: String
    val cardAspectRatio: Float
    when (result) {
        is SearchResult.Channel -> {
            val channel = result.value
            imageUrl = channel.logo
            imageLabel = channel.name
            eyebrow = "CANALE"
            title = channel.name
            subtitle = buildString {
                append("Live TV")
                if (channel.hasCatchup) {
                    append("  •  Archivio ${channel.catchupDays.coerceAtLeast(1)}g")
                }
            }
            cardAspectRatio = 16f / 9f
        }
        is SearchResult.Movie -> {
            val movie = result.value
            imageUrl = movie.logo
            imageLabel = movie.name
            eyebrow = "FILM"
            title = movie.name
            subtitle = listOf(movie.year, movie.rating).filter(String::isNotBlank).joinToString("  •  ")
            cardAspectRatio = 2f / 3f
        }
        is SearchResult.Show -> {
            val show = result.value
            imageUrl = show.logo
            imageLabel = show.name
            eyebrow = "SERIE"
            title = show.name
            subtitle = listOf(show.year, show.rating).filter(String::isNotBlank).joinToString("  •  ")
            cardAspectRatio = 2f / 3f
        }
    }

    FocusCard(
        onClick = onClick,
        focusRequester = focusRequester,
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(cardAspectRatio)
            .onPreviewKeyEvent {
                if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                if (it.key == Key.DirectionLeft) {
                    onMoveLeftToMenu()
                    true
                } else {
                    false
                }
            },
        padding = PaddingValues(0.dp),
    ) {
        Box(Modifier.fillMaxSize()) {
            if (imageUrl.isNotBlank()) {
                AsyncImage(
                    model = imageUrl,
                    contentDescription = imageLabel,
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
                        title.take(1).uppercase(),
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
                    .background(Color(0xDD081017))
                    .padding(8.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                BasicText(
                    eyebrow,
                    style = TvTypography.accentCaptionStyle,
                    maxLines = 1,
                )
                BasicText(
                    title,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = TextStyle(
                        color = TvColors.Text,
                        fontSize = TvTypography.cardTitle,
                        fontWeight = FontWeight.SemiBold,
                        fontFamily = TvTypography.fontFamily,
                    ),
                )
                if (subtitle.isNotBlank()) {
                    BasicText(
                        subtitle,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style = TvTypography.listMetaStyle,
                    )
                }
            }
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
private fun ContinueWatchingCard(
    item: ContinueWatchingItem,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
) {
    val progressLabel = "${(item.progress.fraction * 100).toInt()}%"
    FocusCard(
        onClick = onClick,
        focusRequester = focusRequester,
        modifier = modifier
            .width(220.dp)
            .height(136.dp),
        padding = PaddingValues(0.dp),
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            if (item.logo.isNotBlank()) {
                AsyncImage(
                    model = item.logo,
                    contentDescription = item.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(TvColors.SurfaceDeep),
                )
            }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        androidx.compose.ui.graphics.Brush.verticalGradient(
                            listOf(
                                androidx.compose.ui.graphics.Color.Transparent,
                                androidx.compose.ui.graphics.Color(0xCC000000),
                                androidx.compose.ui.graphics.Color(0xEE000000),
                            ),
                        ),
                    ),
            )
            Column(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    BasicText(
                        item.subtitle.uppercase(),
                        style = TvTypography.accentCaptionStyle,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    BasicText(
                        item.title,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        style = TextStyle(
                            color = TvColors.Text,
                            fontSize = TvTypography.cardTitle,
                            fontWeight = FontWeight.Bold,
                            fontFamily = TvTypography.fontFamily,
                            lineHeight = 16.sp,
                        ),
                    )
                    BasicText(
                        "Riprendi • $progressLabel",
                        style = TvTypography.listMetaStyle.copy(lineHeight = 14.sp),
                        maxLines = 1,
                    )
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(4.dp)
                        .background(Color(0x66000000)),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth(item.progress.fraction.toFloat())
                            .height(4.dp)
                            .background(TvColors.Accent),
                    )
                }
            }
        }
    }
}

private enum class FavoritesFilter {
    ALL,
    LIVE,
    VOD,
    SERIES,
}

sealed interface FavoriteListEntry {
    val id: Int
    val title: String
    val logo: String
    val subtitle: String

    data class Live(val channel: LiveChannel) : FavoriteListEntry {
        override val id = channel.id
        override val title = channel.name
        override val logo = channel.logo
        override val subtitle = "Canale TV"
    }

    data class Movie(val movie: VodMovie) : FavoriteListEntry {
        override val id = movie.id
        override val title = movie.name
        override val logo = movie.logo
        override val subtitle = "Film"
    }

    data class Show(val show: SeriesShow) : FavoriteListEntry {
        override val id = show.id
        override val title = show.name
        override val logo = show.logo
        override val subtitle = "Serie TV"
    }
}

@Composable
fun FavoritesScreen(
    library: UserLibrarySnapshot,
    channels: List<LiveChannel>,
    vodState: VodState,
    seriesState: SeriesState,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onLive: (LiveChannel) -> Unit,
    onMovie: (VodMovie) -> Unit,
    onShow: (SeriesShow) -> Unit,
) {
    var filter by remember { mutableStateOf(FavoritesFilter.ALL) }
    val movies = (vodState as? VodState.Ready)?.movies.orEmpty()
    val shows = (seriesState as? SeriesState.Ready)?.shows.orEmpty()
    val entries = remember(library, channels, movies, shows, filter) {
        buildList {
            if (filter == FavoritesFilter.ALL || filter == FavoritesFilter.LIVE) {
                library.favoriteLive.forEach { id ->
                    channels.firstOrNull { it.id == id }?.let { add(FavoriteListEntry.Live(it)) }
                        ?: library.favoriteMeta[favoriteMetaKey(FavoriteKind.LIVE, id)]?.let { meta ->
                            add(
                                FavoriteListEntry.Live(
                                    LiveChannel(id, meta.name, meta.logo, "", "", "", 0),
                                ),
                            )
                        }
                }
            }
            if (filter == FavoritesFilter.ALL || filter == FavoritesFilter.VOD) {
                library.favoriteVod.forEach { id ->
                    movies.firstOrNull { it.id == id }?.let { add(FavoriteListEntry.Movie(it)) }
                        ?: library.favoriteMeta[favoriteMetaKey(FavoriteKind.VOD, id)]?.let { meta ->
                            add(
                                FavoriteListEntry.Movie(
                                    VodMovie(id, meta.name, meta.logo, "", "", "", "", ""),
                                ),
                            )
                        }
                }
            }
            if (filter == FavoritesFilter.ALL || filter == FavoritesFilter.SERIES) {
                library.favoriteSeries.forEach { id ->
                    shows.firstOrNull { it.id == id }?.let { add(FavoriteListEntry.Show(it)) }
                        ?: library.favoriteMeta[favoriteMetaKey(FavoriteKind.SERIES, id)]?.let { meta ->
                            add(
                                FavoriteListEntry.Show(
                                    SeriesShow(id, meta.name, meta.logo, "", "", "", ""),
                                ),
                            )
                        }
                }
            }
        }
    }
    val gridState = rememberLazyGridState()
    val filters = FavoritesFilter.entries

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ScreenHeading("Preferiti", "${entries.size} elementi salvati")
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(filters.size) { index ->
                val item = filters[index]
                val label = when (item) {
                    FavoritesFilter.ALL -> "Tutti"
                    FavoritesFilter.LIVE -> "Live"
                    FavoritesFilter.VOD -> "Film"
                    FavoritesFilter.SERIES -> "Serie"
                }
                FocusCard(
                    onClick = { filter = item },
                    selected = filter == item,
                    focusRequester = if (index == 0) firstFocusRequester else null,
                    modifier = if (index == 0) {
                        Modifier.onPreviewKeyEvent {
                            if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionLeft) {
                                onMoveLeftToMenu()
                                true
                            } else {
                                false
                            }
                        }
                    } else {
                        Modifier
                    },
                ) {
                    ItemTitle(label)
                }
            }
        }
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                BasicText(
                    "Nessun preferito. Aggiungi film, serie o canali dalle rispettive sezioni.",
                    style = TvTypography.mutedStyle,
                )
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(TvTypography.posterWidth),
                state = gridState,
                modifier = Modifier.fillMaxSize(),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                items(entries, key = {
                    when (it) {
                        is FavoriteListEntry.Live -> "live-${it.id}"
                        is FavoriteListEntry.Movie -> "vod-${it.id}"
                        is FavoriteListEntry.Show -> "series-${it.id}"
                    }
                }) { entry ->
                    FocusCard(
                        onClick = {
                            when (entry) {
                                is FavoriteListEntry.Live -> onLive(entry.channel)
                                is FavoriteListEntry.Movie -> onMovie(entry.movie)
                                is FavoriteListEntry.Show -> onShow(entry.show)
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(2f / 3f),
                        padding = PaddingValues(0.dp),
                    ) {
                        Box(Modifier.fillMaxSize()) {
                            if (entry.logo.isNotBlank()) {
                                AsyncImage(
                                    model = entry.logo,
                                    contentDescription = entry.title,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            } else {
                                Box(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .background(TvColors.SurfaceDeep),
                                )
                            }
                            Box(
                                modifier = Modifier
                                    .align(Alignment.BottomCenter)
                                    .fillMaxWidth()
                                    .background(Color(0xCC000000))
                                    .padding(8.dp),
                            ) {
                                Column {
                                    BasicText(
                                        entry.title,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                        style = TvTypography.listTitleStyle,
                                    )
                                    BasicText(entry.subtitle, style = TvTypography.listMetaStyle)
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
