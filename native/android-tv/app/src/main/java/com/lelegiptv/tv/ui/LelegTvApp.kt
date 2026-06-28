package com.lelegiptv.tv.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.focusTarget
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.lelegiptv.tv.TvViewModel
import com.lelegiptv.tv.EpgState
import com.lelegiptv.tv.GuideState
import com.lelegiptv.tv.ProfilesState
import com.lelegiptv.tv.SeriesDetailState
import com.lelegiptv.tv.SeriesState
import com.lelegiptv.tv.VodDetailState
import com.lelegiptv.tv.VodState
import com.lelegiptv.tv.data.CatalogState
import com.lelegiptv.tv.data.LIVE_FAVORITES_CATEGORY_ID
import com.lelegiptv.tv.data.LiveCategory
import com.lelegiptv.tv.data.LiveChannel
import com.lelegiptv.tv.data.ProfilePresets
import com.lelegiptv.tv.data.SavedProfile
import com.lelegiptv.tv.data.EpisodeProgressMeta
import com.lelegiptv.tv.data.FavoriteKind
import com.lelegiptv.tv.data.FavoriteMeta
import com.lelegiptv.tv.data.SeriesEpisode
import com.lelegiptv.tv.data.SeriesInfo
import com.lelegiptv.tv.data.SeriesShow
import com.lelegiptv.tv.data.VodMovie
import com.lelegiptv.tv.data.XtreamProfile
import com.lelegiptv.tv.data.epgProgrammeKey

private class SidebarFocusHandles(
    val home: FocusRequester = FocusRequester(),
    val live: FocusRequester = FocusRequester(),
    val movies: FocusRequester = FocusRequester(),
    val series: FocusRequester = FocusRequester(),
    val favorites: FocusRequester = FocusRequester(),
    val search: FocusRequester = FocusRequester(),
    val guide: FocusRequester = FocusRequester(),
    val settings: FocusRequester = FocusRequester(),
) {
    fun forRoute(route: TvRoute): FocusRequester =
        when (route) {
            TvRoute.Home -> home
            TvRoute.Live -> live
            TvRoute.Movies, TvRoute.MovieDetail -> movies
            TvRoute.Series, TvRoute.SeriesDetail -> series
            TvRoute.Favorites -> favorites
            TvRoute.Search -> search
            TvRoute.Guide -> guide
            TvRoute.Settings -> settings
        }
}

private enum class TvRoute {
    Home,
    Live,
    Movies,
    Series,
    Favorites,
    Search,
    Guide,
    MovieDetail,
    SeriesDetail,
    Settings,
}

private sealed class VodProgressTrack {
    data class Movie(val id: Int, val name: String, val logo: String) : VodProgressTrack()
    data class Episode(val episodeId: Int, val meta: EpisodeProgressMeta) : VodProgressTrack()
}

private sealed interface PlaybackRequest {
    data class Live(
        val profile: XtreamProfile,
        val channels: List<LiveChannel>,
        val index: Int,
    ) : PlaybackRequest {
        val channel: LiveChannel get() = channels[index]
    }

    data class Vod(
        val title: String,
        val urls: List<String>,
        val referer: String,
        val startPositionMs: Long = 0L,
        val track: VodProgressTrack? = null,
    ) : PlaybackRequest
}

@Composable
fun LelegTvApp(viewModel: TvViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val epgState by viewModel.epgState.collectAsStateWithLifecycle()
    val guideState by viewModel.guideState.collectAsStateWithLifecycle()
    val vodState by viewModel.vodState.collectAsStateWithLifecycle()
    val seriesState by viewModel.seriesState.collectAsStateWithLifecycle()
    val vodDetailState by viewModel.vodDetailState.collectAsStateWithLifecycle()
    val seriesDetailState by viewModel.seriesDetailState.collectAsStateWithLifecycle()
    val profilesState by viewModel.profilesState.collectAsStateWithLifecycle()
    val libraryState by viewModel.libraryState.collectAsStateWithLifecycle()
    var route by remember {
        mutableStateOf(
            if (state is CatalogState.Empty || state is CatalogState.Failed) {
                TvRoute.Settings
            } else {
                TvRoute.Home
            },
        )
    }
    var playing by remember { mutableStateOf<PlaybackRequest?>(null) }
    var showExitConfirm by remember { mutableStateOf(false) }
    val context = LocalContext.current

    val activeListTitle = profilesState.profiles
        .firstOrNull { it.id == profilesState.activeId }
        ?.title
        ?: (state as? CatalogState.Ready)?.profile?.title

    when (val request = playing) {
        is PlaybackRequest.Live -> {
            val channel = request.channel
            LaunchedEffect(channel.id) {
                viewModel.loadEpg(request.profile, channel.id, channel)
            }
            val programmes = (epgState as? EpgState.Ready)
                ?.takeIf { it.streamId == channel.id }
                ?.programmes
                .orEmpty()
            PlayerScreen(
                title = channel.name,
                urls = StreamPlayback.buildLiveStreamUrls(request.profile, channel.id),
                referer = "${request.profile.baseUrl}/",
                programmes = programmes,
                onPreviousChannel = {
                    playing = request.copy(
                        index = if (request.index <= 0) request.channels.lastIndex else request.index - 1,
                    )
                },
                onNextChannel = {
                    playing = request.copy(
                        index = if (request.index >= request.channels.lastIndex) 0 else request.index + 1,
                    )
                },
                onBack = { playing = null },
            )
            return
        }
        is PlaybackRequest.Vod -> {
            PlayerScreen(
                title = request.title,
                urls = request.urls,
                referer = request.referer,
                startPositionMs = request.startPositionMs,
                onProgressUpdate = request.track?.let { track ->
                    { positionMs: Long, durationMs: Long ->
                        when (track) {
                            is VodProgressTrack.Movie -> viewModel.saveMovieProgress(
                                movieId = track.id,
                                name = track.name,
                                logo = track.logo,
                                positionMs = positionMs,
                                durationMs = durationMs,
                            )
                            is VodProgressTrack.Episode -> viewModel.saveEpisodeProgress(
                                episodeId = track.episodeId,
                                meta = track.meta,
                                positionMs = positionMs,
                                durationMs = durationMs,
                            )
                        }
                    }
                },
                onBack = { playing = null },
            )
            return
        }
        null -> Unit
    }

    if (state is CatalogState.Loading) {
        LoadingState((state as CatalogState.Loading).message)
        return
    }

    val ready = state as? CatalogState.Ready
    val sidebarFocus = remember { SidebarFocusHandles() }
    val contentRequester = remember { FocusRequester() }
    val scope = rememberCoroutineScope()

    fun focusSidebarMenu() {
        scope.launch { sidebarFocus.forRoute(route).safeRequestFocus() }
    }

    var guideCategoryId by rememberSaveable { mutableStateOf("") }

    LaunchedEffect(ready?.categories) {
        if (guideCategoryId.isBlank() && ready != null && ready.categories.isNotEmpty()) {
            guideCategoryId = defaultLiveCategory(ready.categories).id
        }
    }

    fun openRoute(next: TvRoute) {
        route = next
        val profile = ready?.profile ?: viewModel.activeProfile()
        profile?.let { activeProfile ->
            if (next == TvRoute.Movies || next == TvRoute.Search || next == TvRoute.Favorites) {
                viewModel.ensureVod(activeProfile)
            }
            if (next == TvRoute.Series || next == TvRoute.Search || next == TvRoute.Favorites) {
                viewModel.ensureSeries(activeProfile)
            }
        }
    }

    val guideChannels = remember(ready?.channels, guideCategoryId) {
        val all = ready?.channels.orEmpty()
        val scoped = if (guideCategoryId.isBlank()) {
            all
        } else {
            all.filter { it.categoryId == guideCategoryId }
        }
        scoped.take(60)
    }

    LaunchedEffect(route) {
        if (route != TvRoute.Guide) {
            viewModel.cancelGuideLoads()
        }
    }

    LaunchedEffect(route, guideChannels, ready?.profile) {
        if (route == TvRoute.Guide && ready != null && guideChannels.isNotEmpty()) {
            viewModel.loadGuide(ready.profile, guideChannels)
        }
    }
    fun playChannel(channel: LiveChannel) {
        val catalog = ready ?: return
        val index = catalog.channels.indexOfFirst { it.id == channel.id }
        if (index >= 0) {
            playing = PlaybackRequest.Live(catalog.profile, catalog.channels, index)
        }
    }
    fun playMovie(movie: VodMovie, restart: Boolean = false) {
        val profile = ready?.profile ?: return
        val progress = libraryState.movieProgress[movie.id]?.progress
        val startMs = if (restart || progress?.canResume != true) {
            0L
        } else {
            progress.positionMs
        }
        if (restart) viewModel.clearMovieProgress(movie.id)
        viewModel.setLastVodMovie(movie.id)
        playing = PlaybackRequest.Vod(
            title = movie.name,
            urls = StreamPlayback.expandPlaybackUrls(
                profile.movieUrl(movie.id, movie.containerExtension),
            ),
            referer = "${profile.baseUrl}/",
            startPositionMs = startMs,
            track = VodProgressTrack.Movie(movie.id, movie.name, movie.logo),
        )
    }

    fun playEpisode(episode: SeriesEpisode, restart: Boolean = false) {
        val profile = ready?.profile ?: return
        val seriesInfo = (seriesDetailState as? SeriesDetailState.Ready)?.info
        val stored = libraryState.episodeProgress[episode.id]
        val progress = stored?.progress
        val startMs = if (restart || progress?.canResume != true) {
            0L
        } else {
            progress.positionMs
        }
        if (restart) viewModel.clearEpisodeProgress(episode.id)
        val meta = seriesInfo?.let {
            EpisodeProgressMeta(
                seriesId = it.show.id,
                seriesName = it.show.name,
                seriesLogo = it.show.logo,
                season = episode.season,
                episodeNum = episode.episode,
                episodeTitle = episode.title,
            )
        } ?: stored?.meta ?: EpisodeProgressMeta(
            seriesId = 0,
            seriesName = episode.title,
            seriesLogo = "",
            season = episode.season,
            episodeNum = episode.episode,
            episodeTitle = episode.title,
        )
        seriesInfo?.show?.id?.let { viewModel.setLastVodEpisode(it, episode.id) }
        playing = PlaybackRequest.Vod(
            title = episode.title.ifBlank { "S${episode.season} E${episode.episode}" },
            urls = StreamPlayback.expandPlaybackUrls(
                profile.seriesUrl(episode.id, episode.containerExtension),
            ),
            referer = "${profile.baseUrl}/",
            startPositionMs = startMs,
            track = VodProgressTrack.Episode(episode.id, meta),
        )
    }

    fun resumeContinueMovie(movieId: Int) {
        val movie = viewModel.allCachedVodMovies().firstOrNull { it.id == movieId }
            ?: (vodState as? VodState.Ready)?.movies?.firstOrNull { it.id == movieId }
            ?: libraryState.movieProgress[movieId]?.let { entry ->
                VodMovie(movieId, entry.name, entry.logo, "", "", "", "", "")
            }
        movie?.let { playMovie(it, restart = false) }
    }

    fun resumeContinueEpisode(seriesId: Int, episodeId: Int) {
        val entry = libraryState.episodeProgress[episodeId] ?: return
        val profile = ready?.profile ?: return
        val progress = entry.progress
        if (!progress.canResume) return
        viewModel.setLastVodEpisode(seriesId, episodeId)
        playing = PlaybackRequest.Vod(
            title = entry.meta.episodeTitle.ifBlank {
                "S${entry.meta.season} E${entry.meta.episodeNum}"
            },
            urls = StreamPlayback.expandPlaybackUrls(
                profile.seriesUrl(episodeId, "mp4"),
            ),
            referer = "${profile.baseUrl}/",
            startPositionMs = progress.positionMs,
            track = VodProgressTrack.Episode(episodeId, entry.meta),
        )
    }

    fun toggleMovieFavorite(movie: VodMovie) {
        viewModel.toggleFavorite(
            FavoriteKind.VOD,
            movie.id,
            FavoriteMeta(movie.name, movie.logo),
        )
    }

    fun toggleSeriesFavorite(show: SeriesShow) {
        viewModel.toggleFavorite(
            FavoriteKind.SERIES,
            show.id,
            FavoriteMeta(show.name, show.logo),
        )
    }

    fun toggleLiveFavorite(channel: LiveChannel) {
        viewModel.toggleFavorite(
            FavoriteKind.LIVE,
            channel.id,
            FavoriteMeta(channel.name, channel.logo),
        )
    }

    BackHandler(enabled = route != TvRoute.Home && route != TvRoute.Settings) {
        route = when (route) {
            TvRoute.MovieDetail -> TvRoute.Movies
            TvRoute.SeriesDetail -> TvRoute.Series
            else -> TvRoute.Home
        }
    }
    BackHandler(enabled = route == TvRoute.Settings && ready != null) {
        route = TvRoute.Home
    }
    BackHandler(enabled = route == TvRoute.Home) {
        showExitConfirm = true
    }

    LaunchedEffect(route) {
        if (route == TvRoute.Home) {
            scope.launch { sidebarFocus.home.safeRequestFocus() }
        }
    }

    LaunchedEffect(ready?.profile?.baseUrl, ready?.profile?.username) {
        val profile = ready?.profile ?: viewModel.activeProfile() ?: return@LaunchedEffect
        viewModel.ensureVod(profile)
        viewModel.ensureSeries(profile)
    }

    LaunchedEffect(route, libraryState.movieProgress, libraryState.episodeProgress, ready?.profile) {
        if (route == TvRoute.Home && ready != null && libraryState.continueWatching().isNotEmpty()) {
            viewModel.ensureVod(ready.profile)
            viewModel.ensureSeries(ready.profile)
        }
    }

    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(
                androidx.compose.ui.graphics.Brush.linearGradient(
                    listOf(
                        TvColors.BackgroundGlow,
                        TvColors.Background,
                        TvColors.BackgroundDeep,
                    ),
                ),
            ),
    ) {
        Sidebar(
            route = route,
            sidebarFocus = sidebarFocus,
            activeProfileTitle = activeListTitle,
            onRoute = ::openRoute,
            onMoveRight = { scope.launch { contentRequester.safeRequestFocus() } },
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .fillMaxWidth(),
        ) {
        when (route) {
            TvRoute.Home -> HomeScreen(
                firstFocusRequester = contentRequester,
                liveCount = ready?.channels?.size ?: 0,
                movieCount = (vodState as? VodState.Ready)?.categories?.size,
                seriesCount = (seriesState as? SeriesState.Ready)?.categories?.size,
                continueWatching = libraryState.continueWatching(),
                onContinueMovie = ::resumeContinueMovie,
                onContinueEpisode = ::resumeContinueEpisode,
                onLive = { openRoute(TvRoute.Live) },
                onMovies = { openRoute(TvRoute.Movies) },
                onSeries = { openRoute(TvRoute.Series) },
                onMoveLeftToMenu = ::focusSidebarMenu,
            )
            TvRoute.Live -> LiveScreen(
                state = state,
                epgState = epgState,
                library = libraryState,
                firstFocusRequester = contentRequester,
                onMoveLeftToMenu = ::focusSidebarMenu,
                onToggleLiveFavorite = ::toggleLiveFavorite,
                onSelectChannel = { profile, channel ->
                    viewModel.loadEpg(profile, channel.id, channel)
                },
                onProgramme = { profile, channel, programme ->
                    val now = System.currentTimeMillis()
                    val catchupUrls = profile.catchupUrls(channel, programme)
                    if (
                        catchupUrls.isNotEmpty() &&
                        programme.endTimeMillis <= now
                    ) {
                        playing = PlaybackRequest.Vod(
                            title = "${channel.name} • ${programme.title}",
                            urls = catchupUrls,
                            referer = "${profile.baseUrl}/",
                        )
                    } else if (
                        programme.startTimeMillis <= now &&
                        programme.endTimeMillis > now
                    ) {
                        playChannel(channel)
                    }
                },
                onPlay = { profile, channels, index ->
                    playing = PlaybackRequest.Live(profile, channels, index)
                },
                onOpenSettings = { openRoute(TvRoute.Settings) },
            )
            TvRoute.Movies -> MovieBrowserScreen(
                state = vodState,
                firstFocusRequester = contentRequester,
                onMoveLeftToMenu = ::focusSidebarMenu,
                onCategorySelect = { categoryId ->
                    viewModel.activeProfile()?.let { profile ->
                        viewModel.loadVodCategory(profile, categoryId)
                    }
                },
                onMovie = {
                    ready?.profile?.let { profile -> viewModel.loadVodDetail(profile, it) }
                    route = TvRoute.MovieDetail
                },
            )
            TvRoute.Series -> SeriesBrowserScreen(
                state = seriesState,
                firstFocusRequester = contentRequester,
                onMoveLeftToMenu = ::focusSidebarMenu,
                onCategorySelect = { categoryId ->
                    viewModel.activeProfile()?.let { profile ->
                        viewModel.loadSeriesCategory(profile, categoryId)
                    }
                },
                onShow = {
                    ready?.profile?.let { profile -> viewModel.loadSeriesDetail(profile, it) }
                    route = TvRoute.SeriesDetail
                },
            )
            TvRoute.Favorites -> FavoritesScreen(
                library = libraryState,
                channels = ready?.channels.orEmpty(),
                vodState = vodState,
                seriesState = seriesState,
                firstFocusRequester = contentRequester,
                onMoveLeftToMenu = ::focusSidebarMenu,
                onLive = ::playChannel,
                onMovie = {
                    ready?.profile?.let { profile -> viewModel.loadVodDetail(profile, it) }
                    route = TvRoute.MovieDetail
                },
                onShow = {
                    ready?.profile?.let { profile -> viewModel.loadSeriesDetail(profile, it) }
                    route = TvRoute.SeriesDetail
                },
            )
            TvRoute.Search -> SearchScreen(
                channels = ready?.channels.orEmpty(),
                movies = viewModel.allCachedVodMovies().ifEmpty {
                    (vodState as? VodState.Ready)?.movies.orEmpty()
                },
                shows = viewModel.allCachedSeriesShows().ifEmpty {
                    (seriesState as? SeriesState.Ready)?.shows.orEmpty()
                },
                firstFocusRequester = contentRequester,
                onMoveLeftToMenu = ::focusSidebarMenu,
                onResult = { result ->
                    when (result) {
                        is SearchResult.Channel -> {
                            val profile = ready?.profile
                            if (profile != null) {
                                playing = PlaybackRequest.Live(profile, listOf(result.value), 0)
                            }
                        }
                        is SearchResult.Movie -> {
                            ready?.profile?.let { viewModel.loadVodDetail(it, result.value) }
                            route = TvRoute.MovieDetail
                        }
                        is SearchResult.Show -> {
                            ready?.profile?.let { viewModel.loadSeriesDetail(it, result.value) }
                            route = TvRoute.SeriesDetail
                        }
                    }
                },
            )
            TvRoute.Guide -> {
                val guide = guideState
                when (guide) {
                    is GuideState.Failed -> EmptyState(
                        guide.message,
                        onSettings = {
                            ready?.let { viewModel.loadGuide(it.profile, guideChannels, force = true) }
                        },
                        error = true,
                    )
                    GuideState.Idle, is GuideState.Ready -> GuideScreen(
                        channels = guideChannels,
                        categories = ready?.categories.orEmpty(),
                        guideState = guide,
                        selectedCategoryId = guideCategoryId,
                        onCategorySelected = { guideCategoryId = it },
                        onLoadChannel = { channel, dayStart ->
                            ready?.profile?.let { viewModel.loadGuideChannel(it, channel, dayStart) }
                        },
                        onOpenChannel = ::playChannel,
                        onCatchup = { channel, programme ->
                            ready?.profile?.let { profile ->
                                val catchupUrls = profile.catchupUrls(channel, programme)
                                if (catchupUrls.isNotEmpty()) {
                                    playing = PlaybackRequest.Vod(
                                        title = "${channel.name} • ${programme.title}",
                                        urls = catchupUrls,
                                        referer = "${profile.baseUrl}/",
                                    )
                                } else {
                                    playChannel(channel)
                                }
                            }
                        },
                        onRetry = {
                            ready?.profile?.let { profile ->
                                viewModel.loadGuide(profile, guideChannels, force = true)
                                guideChannels.firstOrNull()?.let { channel ->
                                    viewModel.loadGuideChannel(profile, channel, null)
                                }
                            }
                        },
                        firstFocusRequester = contentRequester,
                        onMoveLeftToMenu = ::focusSidebarMenu,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
            TvRoute.MovieDetail -> MovieDetailScreen(
                state = vodDetailState,
                library = libraryState,
                firstFocusRequester = contentRequester,
                onPlay = ::playMovie,
                onToggleFavorite = ::toggleMovieFavorite,
            )
            TvRoute.SeriesDetail -> SeriesDetailScreen(
                state = seriesDetailState,
                library = libraryState,
                firstFocusRequester = contentRequester,
                onEpisode = ::playEpisode,
                onToggleFavorite = ::toggleSeriesFavorite,
            )
            TvRoute.Settings -> SettingsScreen(
                state = state,
                profilesState = profilesState,
                firstFocusRequester = contentRequester,
                onSelectProfile = { id ->
                    viewModel.selectProfile(id)
                    route = TvRoute.Home
                },
                onDeleteProfile = viewModel::deleteProfile,
                onAddProfile = viewModel::addProfile,
            )
        }
        }
    }
    if (showExitConfirm) {
        ExitConfirmation(
            onConfirm = { (context as? Activity)?.finish() },
            onDismiss = {
                showExitConfirm = false
            },
        )
    }
}

@Composable
private fun ExitConfirmation(
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val noRequester = remember { FocusRequester() }
    BackHandler(onBack = onDismiss)
    LaunchedEffect(Unit) {
        kotlinx.coroutines.delay(80)
        noRequester.safeRequestFocus()
    }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(androidx.compose.ui.graphics.Color(0xCC000000)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .width(520.dp)
                .background(TvColors.Panel)
                .padding(30.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            BasicText(
                "Vuoi uscire dall'applicazione?",
                style = TextStyle(
                    color = TvColors.Text,
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                FocusCard(onClick = onDismiss, focusRequester = noRequester) { Label("No") }
                FocusCard(onClick = onConfirm) { Label("Sì, esci") }
            }
        }
    }
}

@Composable
private fun Sidebar(
    route: TvRoute,
    sidebarFocus: SidebarFocusHandles,
    activeProfileTitle: String?,
    onRoute: (TvRoute) -> Unit,
    onMoveRight: () -> Unit,
) {
    Column(
        modifier = Modifier
            .width(TvTypography.sidebarWidth)
            .fillMaxHeight()
            .background(ColorSidebar)
            .drawBehind {
                val stroke = 1.dp.toPx()
                drawLine(
                    color = TvColors.Line,
                    start = Offset(size.width - stroke / 2f, 0f),
                    end = Offset(size.width - stroke / 2f, size.height),
                    strokeWidth = stroke,
                )
            }
            .padding(horizontal = 10.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        BrandMark(compact = true, sidebar = true)
        Spacer(Modifier.height(12.dp))
        SidebarNavItem(
            label = "Home",
            icon = TvNavIcons.Home,
            selected = route == TvRoute.Home,
            onClick = { onRoute(TvRoute.Home) },
            focusRequester = sidebarFocus.home,
            modifier = sidebarNavFocus(
                up = FocusRequester.Cancel,
                down = sidebarFocus.live,
                onMoveRight = onMoveRight,
            ),
        )
        SidebarNavItem(
            label = "Live TV",
            icon = TvNavIcons.Live,
            selected = route == TvRoute.Live,
            onClick = { onRoute(TvRoute.Live) },
            focusRequester = sidebarFocus.live,
            modifier = sidebarNavFocus(
                up = sidebarFocus.home,
                down = sidebarFocus.movies,
                onMoveRight = onMoveRight,
            ),
        )
        SidebarNavItem(
            label = "Film",
            icon = TvNavIcons.Movies,
            selected = route == TvRoute.Movies || route == TvRoute.MovieDetail,
            onClick = { onRoute(TvRoute.Movies) },
            focusRequester = sidebarFocus.movies,
            modifier = sidebarNavFocus(
                up = sidebarFocus.live,
                down = sidebarFocus.series,
                onMoveRight = onMoveRight,
            ),
        )
        SidebarNavItem(
            label = "Serie",
            icon = TvNavIcons.Series,
            selected = route == TvRoute.Series || route == TvRoute.SeriesDetail,
            onClick = { onRoute(TvRoute.Series) },
            focusRequester = sidebarFocus.series,
            modifier = sidebarNavFocus(
                up = sidebarFocus.movies,
                down = sidebarFocus.favorites,
                onMoveRight = onMoveRight,
            ),
        )
        SidebarNavItem(
            label = "Preferiti",
            icon = TvNavIcons.Favorites,
            selected = route == TvRoute.Favorites,
            onClick = { onRoute(TvRoute.Favorites) },
            focusRequester = sidebarFocus.favorites,
            modifier = sidebarNavFocus(
                up = sidebarFocus.series,
                down = sidebarFocus.search,
                onMoveRight = onMoveRight,
            ),
        )
        SidebarNavItem(
            label = "Cerca",
            icon = TvNavIcons.Search,
            selected = route == TvRoute.Search,
            onClick = { onRoute(TvRoute.Search) },
            focusRequester = sidebarFocus.search,
            modifier = sidebarNavFocus(
                up = sidebarFocus.favorites,
                down = sidebarFocus.guide,
                onMoveRight = onMoveRight,
            ),
        )
        SidebarNavItem(
            label = "Guida TV",
            icon = TvNavIcons.Guide,
            selected = route == TvRoute.Guide,
            onClick = { onRoute(TvRoute.Guide) },
            focusRequester = sidebarFocus.guide,
            modifier = sidebarNavFocus(
                up = sidebarFocus.search,
                down = sidebarFocus.settings,
                onMoveRight = onMoveRight,
            ),
        )
        Spacer(Modifier.weight(1f))
        SidebarNavItem(
            label = "Le mie liste",
            icon = TvNavIcons.Lists,
            selected = route == TvRoute.Settings,
            onClick = { onRoute(TvRoute.Settings) },
            subtitle = activeProfileTitle?.takeIf { it.isNotBlank() } ?: "Nessuna lista",
            focusRequester = sidebarFocus.settings,
            modifier = sidebarNavFocus(
                up = sidebarFocus.guide,
                down = FocusRequester.Cancel,
                onMoveRight = onMoveRight,
            ),
        )
    }
}

private fun sidebarNavFocus(
    up: FocusRequester,
    down: FocusRequester,
    onMoveRight: () -> Unit,
): Modifier =
    Modifier
        .focusProperties {
            this.up = up
            this.down = down
            left = FocusRequester.Cancel
        }
        .onPreviewKeyEvent {
            if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionRight) {
                onMoveRight()
                true
            } else {
                false
            }
        }

private val ColorSidebar = TvColors.Sidebar

@Composable
private fun LiveScreen(
    state: CatalogState,
    epgState: EpgState,
    library: com.lelegiptv.tv.data.UserLibrarySnapshot,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onToggleLiveFavorite: (LiveChannel) -> Unit,
    onSelectChannel: (XtreamProfile, LiveChannel) -> Unit,
    onProgramme: (XtreamProfile, LiveChannel, com.lelegiptv.tv.data.EpgProgramme) -> Unit,
    onPlay: (XtreamProfile, List<LiveChannel>, Int) -> Unit,
    onOpenSettings: () -> Unit,
) {
    when (state) {
        CatalogState.Empty -> EmptyState("Aggiungi una lista per iniziare", onOpenSettings)
        is CatalogState.Loading -> LoadingState(state.message)
        is CatalogState.Failed -> EmptyState(state.message, onOpenSettings, error = true)
        is CatalogState.Ready -> LiveBrowser(
            state = state,
            epgState = epgState,
            library = library,
            firstFocusRequester = firstFocusRequester,
            onMoveLeftToMenu = onMoveLeftToMenu,
            onToggleLiveFavorite = onToggleLiveFavorite,
            onSelectChannel = onSelectChannel,
            onProgramme = onProgramme,
            onPlay = onPlay,
        )
    }
}

private fun defaultLiveCategory(categories: List<LiveCategory>): LiveCategory {
    return categories.firstOrNull {
        it.id.isNotBlank() && it.name.contains("italia", ignoreCase = true)
    } ?: categories.firstOrNull { it.id.isNotBlank() }
        ?: categories.firstOrNull()
        ?: LiveCategory("", "Tutti i canali")
}

private const val LiveChannelDisplayLimit = 400
private const val LIVE_EPG_DEBOUNCE_MS = 450L

@Composable
private fun LiveBrowser(
    state: CatalogState.Ready,
    epgState: EpgState,
    library: com.lelegiptv.tv.data.UserLibrarySnapshot,
    firstFocusRequester: FocusRequester,
    onMoveLeftToMenu: () -> Unit,
    onToggleLiveFavorite: (LiveChannel) -> Unit,
    onSelectChannel: (XtreamProfile, LiveChannel) -> Unit,
    onProgramme: (XtreamProfile, LiveChannel, com.lelegiptv.tv.data.EpgProgramme) -> Unit,
    onPlay: (XtreamProfile, List<LiveChannel>, Int) -> Unit,
) {
    var selectedCategory by remember(state.categories) {
        mutableStateOf(defaultLiveCategory(state.categories))
    }
    var selectedChannel by remember { mutableStateOf<LiveChannel?>(null) }
    val categoryFocusRequester = remember { FocusRequester() }
    val channelFocusRequester = remember { FocusRequester() }
    val epgFocusRequester = remember { FocusRequester() }
    val channelListState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val liveCategories = remember(state.categories) {
        buildList {
            add(state.categories.firstOrNull() ?: LiveCategory("", "Tutti i canali"))
            add(LiveCategory(LIVE_FAVORITES_CATEGORY_ID, "Preferiti"))
            state.categories.drop(1).forEach { category ->
                if (category.id != LIVE_FAVORITES_CATEGORY_ID) add(category)
            }
        }
    }
    val channelsByCategory = remember(state.channels) {
        state.channels.groupBy(LiveChannel::categoryId)
    }
    val filtered = remember(state.channels, channelsByCategory, selectedCategory.id, library.favoriteLive) {
        when (selectedCategory.id) {
            LIVE_FAVORITES_CATEGORY_ID ->
                state.channels.filter { it.id in library.favoriteLive }
            "" -> state.channels
            else -> channelsByCategory[selectedCategory.id].orEmpty()
        }
    }
    val visibleChannels = remember(filtered) { filtered.take(LiveChannelDisplayLimit) }
    val truncated = filtered.size > visibleChannels.size
    LaunchedEffect(selectedCategory.id, visibleChannels) {
        val current = selectedChannel
        val stillVisible = current != null && visibleChannels.any { it.id == current.id }
        if (!stillVisible) {
            selectedChannel = visibleChannels.firstOrNull()
        }
        channelListState.scrollToItem(0)
    }

    LaunchedEffect(selectedChannel?.id, state.profile) {
        val channel = selectedChannel ?: return@LaunchedEffect
        delay(LIVE_EPG_DEBOUNCE_MS)
        if (selectedChannel?.id == channel.id) {
            onSelectChannel(state.profile, channel)
        }
    }

    fun focusSelectedCategory() {
        scope.launch {
            if (selectedCategory == liveCategories.firstOrNull()) {
                firstFocusRequester.safeRequestFocus()
            } else {
                categoryFocusRequester.safeRequestFocus()
            }
        }
    }

    fun focusSelectedChannel() {
        scope.launch {
            val target = selectedChannel ?: visibleChannels.firstOrNull() ?: return@launch
            val index = visibleChannels.indexOfFirst { it.id == target.id }.coerceAtLeast(0)
            channelListState.scrollToItem(index)
            channelFocusRequester.safeRequestFocus()
        }
    }

    fun focusEpgPanel() {
        scope.launch { epgFocusRequester.safeRequestFocus() }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp, vertical = 20.dp),
    ) {
        Heading(
            title = "Live TV",
            subtitle = buildString {
                append("${filtered.size} di ${state.channels.size} canali")
                if (truncated) append(" • primi $LiveChannelDisplayLimit")
            },
        )
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(top = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            LazyColumn(
                modifier = Modifier
                    .width(220.dp)
                    .fillMaxHeight(),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(liveCategories, key = { it.id }) { category ->
                    val itemFocusRequester = when {
                        category == liveCategories.firstOrNull() -> firstFocusRequester
                        category.id == selectedCategory.id -> categoryFocusRequester
                        else -> null
                    }
                    FocusCard(
                        onClick = { selectedCategory = category },
                        focusRequester = itemFocusRequester,
                        selected = category == selectedCategory,
                        modifier = Modifier
                            .fillMaxWidth()
                            .onPreviewKeyEvent {
                                if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                when (it.key) {
                                    Key.DirectionLeft -> {
                                        if (category == liveCategories.firstOrNull()) {
                                            onMoveLeftToMenu()
                                            true
                                        } else {
                                            false
                                        }
                                    }
                                    Key.DirectionRight -> {
                                        if (visibleChannels.isNotEmpty()) {
                                            focusSelectedChannel()
                                            true
                                        } else false
                                    }
                                    else -> false
                                }
                            },
                    ) {
                        ListLabel(category.name)
                    }
                }
            }
            LazyColumn(
                state = channelListState,
                modifier = Modifier
                    .width(260.dp)
                    .fillMaxHeight(),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(visibleChannels.size, key = { visibleChannels[it].id }) { index ->
                    val channel = visibleChannels[index]
                    val isSelectedChannel = channel.id == selectedChannel?.id
                    FocusCard(
                        onClick = { onPlay(state.profile, visibleChannels, index) },
                        focusRequester = if (isSelectedChannel) channelFocusRequester else null,
                        selected = isSelectedChannel,
                        modifier = Modifier
                            .fillMaxWidth()
                            .onPreviewKeyEvent {
                                if (it.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                when (it.key) {
                                    Key.DirectionLeft -> {
                                        focusSelectedCategory()
                                        true
                                    }
                                    Key.DirectionRight -> {
                                        focusEpgPanel()
                                        true
                                    }
                                    else -> false
                                }
                            }
                            .onFocusChanged {
                                if (it.isFocused && selectedChannel?.id != channel.id) {
                                    selectedChannel = channel
                                }
                            },
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            ListLabel(channel.name)
                            BasicText(
                                text = "#${channel.id}" +
                                    if (channel.hasCatchup) "  • Archivio ${channel.catchupDays.coerceAtLeast(1)}g" else "",
                                style = TvTypography.listMetaStyle,
                                maxLines = 1,
                            )
                        }
                    }
                }
            }
            LiveEpgPanel(
                profile = state.profile,
                channel = selectedChannel,
                epgState = epgState,
                isFavorite = selectedChannel?.let {
                    library.isFavorite(FavoriteKind.LIVE, it.id)
                } == true,
                onToggleFavorite = {
                    selectedChannel?.let(onToggleLiveFavorite)
                },
                epgFocusRequester = epgFocusRequester,
                onMoveLeft = ::focusSelectedChannel,
                onProgramme = { channel, programme ->
                    onProgramme(state.profile, channel, programme)
                },
                onOpenFullscreen = {
                    val index = visibleChannels.indexOfFirst { it.id == selectedChannel?.id }
                    if (index >= 0) onPlay(state.profile, visibleChannels, index)
                },
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun LiveEpgPanel(
    profile: XtreamProfile,
    channel: LiveChannel?,
    epgState: EpgState,
    isFavorite: Boolean,
    onToggleFavorite: () -> Unit,
    epgFocusRequester: FocusRequester,
    onMoveLeft: () -> Unit,
    onProgramme: (LiveChannel, com.lelegiptv.tv.data.EpgProgramme) -> Unit,
    onOpenFullscreen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val programmes = (epgState as? EpgState.Ready)
        ?.takeIf { it.streamId == channel?.id }
        ?.programmes
        .orEmpty()
    val epgLoading = epgState is EpgState.Loading && epgState.streamId == channel?.id
    val epgFailed = (epgState as? EpgState.Failed)?.takeIf { it.streamId == channel?.id }
    val now = System.currentTimeMillis()
    val currentIndex = programmes.indexOfFirst {
        now >= it.startTimeMillis && now < it.endTimeMillis
    }.coerceAtLeast(0)
    val firstVisibleProgramme = (currentIndex - 3).coerceAtLeast(0)
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(TvColors.Panel)
            .padding(16.dp)
            .onPreviewKeyEvent {
                if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionLeft) {
                    onMoveLeft()
                    true
                } else {
                    false
                }
            },
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        LivePreviewPlayer(
            profile = profile,
            channel = channel,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .heightIn(max = 230.dp),
        )
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            BasicText(
                channel?.name ?: "Seleziona un canale",
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = TvTypography.listTitleStyle,
                modifier = Modifier.fillMaxWidth(),
            )
            if (channel != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FocusCard(
                        onClick = onToggleFavorite,
                        padding = androidx.compose.foundation.layout.PaddingValues(
                            horizontal = 12.dp,
                            vertical = 8.dp,
                        ),
                    ) {
                        Label(if (isFavorite) "★ Preferito" else "☆ Preferiti")
                    }
                    FocusCard(
                        onClick = onOpenFullscreen,
                        focusRequester = epgFocusRequester,
                        modifier = Modifier.onPreviewKeyEvent {
                            if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionLeft) {
                                onMoveLeft()
                                true
                            } else {
                                false
                            }
                        },
                        padding = androidx.compose.foundation.layout.PaddingValues(
                            horizontal = 14.dp,
                            vertical = 8.dp,
                        ),
                    ) {
                        Label("Fullscreen")
                    }
                }
            }
        }
        if (epgLoading && programmes.isEmpty()) {
            BasicText("Caricamento EPG...", style = TextStyle(color = TvColors.Muted))
        } else if (programmes.isEmpty()) {
            BasicText(
                epgFailed?.message ?: "EPG non disponibile",
                style = TextStyle(color = TvColors.Muted),
            )
        } else {
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.weight(1f),
            ) {
                items(
                    programmes.drop(firstVisibleProgramme).take(10),
                    key = { epgProgrammeKey(it) },
                ) { programme ->
                    val live = now in programme.startTimeMillis until programme.endTimeMillis
                    FocusCard(
                        onClick = {
                            channel?.let { onProgramme(it, programme) }
                        },
                        selected = live,
                        modifier = Modifier.fillMaxWidth(),
                        padding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                    ) {
                        Column {
                            val past = programme.endTimeMillis <= now
                            BasicText(
                                (if (live) "LIVE  " else if (past) "REC  " else "") +
                                    java.text.SimpleDateFormat(
                                        "HH:mm",
                                        java.util.Locale.getDefault(),
                                    ).format(java.util.Date(programme.startTimeMillis)),
                                style = TextStyle(
                                    color = TvColors.Accent,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                ),
                            )
                            BasicText(
                                programme.title,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                                style = TvTypography.listTitleStyle,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsScreen(
    state: CatalogState,
    profilesState: ProfilesState,
    firstFocusRequester: FocusRequester,
    onSelectProfile: (String) -> Unit,
    onDeleteProfile: (String) -> Unit,
    onAddProfile: (XtreamProfile) -> Unit,
) {
    var formGeneration by remember { mutableIntStateOf(0) }
    var title by remember(formGeneration) { mutableStateOf("") }
    var server by remember(formGeneration) { mutableStateOf("") }
    var username by remember(formGeneration) { mutableStateOf("") }
    var password by remember(formGeneration) { mutableStateOf("") }

    fun applyPresetFromTitle(rawTitle: String) {
        val preset = ProfilePresets.resolve(rawTitle) ?: return
        if (server != preset.serverUrl) server = preset.serverUrl
        if (username != preset.username) username = preset.username
        if (password != preset.password) password = preset.password
    }

    LaunchedEffect(state) {
        if (state is CatalogState.Ready || state is CatalogState.Failed) {
            formGeneration++
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Heading(
            "Le mie liste",
            "${profilesState.profiles.size} salvate • seleziona, aggiungi o elimina",
        )
        if (profilesState.profiles.isEmpty()) {
            BasicText(
                "Nessuna lista salvata. Aggiungi la prima sorgente Xtream qui sotto.",
                style = TextStyle(color = TvColors.Muted, fontSize = 15.sp),
            )
        } else {
            LazyColumn(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 8.dp),
            ) {
                items(
                    profilesState.profiles,
                    key = { it.id },
                ) { saved ->
                    SavedProfileRow(
                        saved = saved,
                        isActive = saved.id == profilesState.activeId,
                        loading = state is CatalogState.Loading && saved.id == profilesState.activeId,
                        focusRequester = if (saved == profilesState.profiles.firstOrNull()) {
                            firstFocusRequester
                        } else {
                            null
                        },
                        onSelect = { onSelectProfile(saved.id) },
                        onDelete = { onDeleteProfile(saved.id) },
                    )
                }
            }
        }
        BasicText(
            "Nuova lista",
            style = TvTypography.sectionStyle,
        )
        BasicText(
            "Dopo il caricamento il modulo si svuota. Stesso server e username aggiornano la lista esistente.",
            style = TvTypography.mutedStyle,
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            TvTextField(
                label = "Nome lista",
                value = title,
                onValueChange = { newTitle ->
                    title = newTitle
                    applyPresetFromTitle(newTitle)
                },
                focusRequester = if (profilesState.profiles.isEmpty()) firstFocusRequester else null,
                modifier = Modifier.weight(1f),
            )
            TvTextField(
                "Server URL",
                server,
                { server = it },
                modifier = Modifier.weight(1f),
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            TvTextField(
                "Username",
                username,
                { username = it },
                modifier = Modifier.weight(1f),
            )
            TvTextField(
                "Password",
                password,
                { password = it },
                password = true,
                modifier = Modifier.weight(1f),
            )
        }
        FocusCard(
            onClick = {
                ProfilePresets.profileFromForm(title, server, username, password)?.let(onAddProfile)
            },
            modifier = Modifier.width(260.dp),
        ) {
            Label(if (state is CatalogState.Loading) "Caricamento..." else "Aggiungi lista")
        }
        if (state is CatalogState.Failed) {
            BasicText(state.message, style = TextStyle(color = TvColors.Error))
        }
    }
}

@Composable
private fun SavedProfileRow(
    saved: SavedProfile,
    isActive: Boolean,
    loading: Boolean,
    focusRequester: FocusRequester?,
    onSelect: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FocusCard(
            onClick = { if (!isActive) onSelect() },
            focusRequester = focusRequester,
            selected = isActive,
            modifier = Modifier.weight(1f),
            padding = androidx.compose.foundation.layout.PaddingValues(
                horizontal = 18.dp,
                vertical = 14.dp,
            ),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                BasicText(
                    if (isActive) "LISTA ATTIVA" else "LISTA SALVATA",
                    style = TvTypography.accentCaptionStyle,
                )
                BasicText(
                    when {
                        loading -> "Caricamento..."
                        else -> saved.title
                    },
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = TvTypography.listTitleStyle,
                )
                if (!isActive) {
                    BasicText(
                        "OK per attivare",
                        style = TvTypography.listMetaStyle,
                    )
                }
            }
        }
        FocusCard(
            onClick = onDelete,
            modifier = Modifier.width(120.dp),
            padding = androidx.compose.foundation.layout.PaddingValues(
                horizontal = 12.dp,
                vertical = 14.dp,
            ),
        ) {
            BasicText(
                "Elimina",
                style = TvTypography.listTitleStyle.copy(color = TvColors.Error),
            )
        }
    }
}

@Composable
private fun TvTextField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    focusRequester: FocusRequester? = null,
    password: Boolean = false,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val requester = if (focusRequester == null) Modifier else Modifier.focusRequester(focusRequester)
    Column(modifier = modifier) {
        BasicText(label, style = TvTypography.listMetaStyle)
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            textStyle = TextStyle(
                color = TvColors.Text,
                fontSize = TvTypography.inputText,
                fontFamily = TvTypography.fontFamily,
            ),
            cursorBrush = SolidColor(TvColors.Accent),
            visualTransformation =
                if (password) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = if (password) KeyboardType.Password else KeyboardType.Text,
            ),
            singleLine = true,
            modifier = Modifier
                .then(requester)
                .fillMaxWidth()
                .height(46.dp)
                .background(TvColors.Panel)
                .onFocusChanged {
                    focused = it.isFocused
                    if (it.isFocused) keyboard?.show()
                }
                .then(
                    if (focused) Modifier.background(TvColors.PanelSelected)
                    else Modifier,
                )
                .padding(horizontal = 16.dp, vertical = 14.dp)
                .focusTarget(),
        )
    }
}

@Composable
private fun LoadingState(message: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            BasicText(
                text = "●",
                style = TvTypography.mutedStyle,
            )
            Spacer(Modifier.height(16.dp))
            Label(message)
        }
    }
}

@Composable
private fun EmptyState(message: String, onSettings: () -> Unit, error: Boolean = false) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            BasicText(
                text = message,
                style = TvTypography.mutedStyle.copy(
                    color = if (error) TvColors.Error else TvColors.Muted,
                ),
            )
            Spacer(Modifier.height(18.dp))
            FocusCard(onClick = onSettings) { Label("Apri le mie liste") }
        }
    }
}

@Composable
private fun Heading(title: String, subtitle: String) {
    PageHeader(title = title, subtitle = subtitle)
}

@Composable
private fun ListLabel(text: String) {
    BasicText(
        text = text,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        style = TvTypography.listTitleStyle,
    )
}

@Composable
private fun Label(text: String) {
    BasicText(text = text, style = TvTypography.listTitleStyle)
}
