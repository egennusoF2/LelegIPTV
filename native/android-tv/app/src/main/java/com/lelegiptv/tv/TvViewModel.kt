package com.lelegiptv.tv

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lelegiptv.tv.data.CatalogState
import com.lelegiptv.tv.data.CatalogCache
import com.lelegiptv.tv.data.EpgProgramme
import com.lelegiptv.tv.data.LiveChannel
import com.lelegiptv.tv.data.LibraryCache
import com.lelegiptv.tv.data.SeriesCategory
import com.lelegiptv.tv.data.SeriesInfo
import com.lelegiptv.tv.data.SeriesShow
import com.lelegiptv.tv.data.VodCategory
import com.lelegiptv.tv.data.VodInfo
import com.lelegiptv.tv.data.VodMovie
import com.lelegiptv.tv.data.ProfilePresets
import com.lelegiptv.tv.data.ProfileStore
import com.lelegiptv.tv.data.UserLibraryStore
import com.lelegiptv.tv.data.FavoriteKind
import com.lelegiptv.tv.data.FavoriteMeta
import com.lelegiptv.tv.data.PlaybackProgress
import com.lelegiptv.tv.data.EpisodeProgressMeta
import com.lelegiptv.tv.data.EpisodeProgressEntry
import com.lelegiptv.tv.data.LastVodPlay
import com.lelegiptv.tv.data.MovieProgressEntry
import com.lelegiptv.tv.data.UserLibrarySnapshot
import com.lelegiptv.tv.data.favoriteMetaKey
import com.lelegiptv.tv.data.XtreamClient
import com.lelegiptv.tv.data.XtreamProfile
import com.lelegiptv.tv.data.XmlTvEpg
import com.lelegiptv.tv.data.dedupeEpgProgrammes
import com.lelegiptv.tv.data.dayCoversProgrammes
import com.lelegiptv.tv.data.mergeEpgProgrammes
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.cancellation.CancellationException

class TvViewModel(application: Application) : AndroidViewModel(application) {
    private val store = ProfileStore(application)
    private val libraryStore = UserLibraryStore(application)
    private val cache = CatalogCache(application)
    private val libraryCache = LibraryCache(application)
    private val client = XtreamClient()
    private val mutableState = MutableStateFlow<CatalogState>(CatalogState.Empty)
    private val mutableEpgState = MutableStateFlow<EpgState>(EpgState.Idle)
    private val mutableGuideState = MutableStateFlow<GuideState>(GuideState.Idle)
    private val mutableVodState = MutableStateFlow<VodState>(VodState.Idle)
    private val mutableSeriesState = MutableStateFlow<SeriesState>(SeriesState.Idle)
    private val mutableVodDetailState = MutableStateFlow<VodDetailState>(VodDetailState.Idle)
    private val mutableSeriesDetailState =
        MutableStateFlow<SeriesDetailState>(SeriesDetailState.Idle)
    private val mutableProfilesState = MutableStateFlow(ProfilesState())
    private val mutableLibraryState = MutableStateFlow(UserLibrarySnapshot.Empty)
    private var lastGuideChannelIds: List<Int>? = null
    private val epgMemoryCache =
        object : LinkedHashMap<Int, List<EpgProgramme>>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, List<EpgProgramme>>?): Boolean =
                size > EPG_CACHE_MAX_CHANNELS
        }
    private val xmlTvCache = mutableMapOf<Int, List<EpgProgramme>>()
    private var xmlTvProfileKey: String? = null
    private var epgLoadJob: Job? = null
    private var epgRequestSeq = 0
    private var guideWarmJob: Job? = null
    private var guideChannelJob: Job? = null
    private val guideFullLoadChannels = mutableSetOf<Int>()

    val state: StateFlow<CatalogState> = mutableState.asStateFlow()
    val epgState: StateFlow<EpgState> = mutableEpgState.asStateFlow()
    val guideState: StateFlow<GuideState> = mutableGuideState.asStateFlow()
    val vodState: StateFlow<VodState> = mutableVodState.asStateFlow()
    val seriesState: StateFlow<SeriesState> = mutableSeriesState.asStateFlow()
    val vodDetailState: StateFlow<VodDetailState> = mutableVodDetailState.asStateFlow()
    val seriesDetailState: StateFlow<SeriesDetailState> = mutableSeriesDetailState.asStateFlow()
    val profilesState: StateFlow<ProfilesState> = mutableProfilesState.asStateFlow()
    val libraryState: StateFlow<UserLibrarySnapshot> = mutableLibraryState.asStateFlow()

    init {
        refreshProfilesState()
        val active = store.loadActive()
        when {
            active != null -> load(active.profile, persist = false)
            else -> ProfilePresets.resolve("ITALIA1")?.let { addProfile(it) }
        }
    }

    private fun refreshProfilesState() {
        mutableProfilesState.value = ProfilesState(
            profiles = store.loadAll(),
            activeId = store.loadActiveId(),
        )
        reloadLibraryState()
    }

    private fun reloadLibraryState() {
        val profileId = store.loadActiveId().orEmpty()
        mutableLibraryState.value = libraryStore.load(profileId)
    }

    private fun persistLibrary(snapshot: UserLibrarySnapshot) {
        val profileId = store.loadActiveId() ?: return
        libraryStore.save(profileId, snapshot)
        mutableLibraryState.value = snapshot
    }

    fun toggleFavorite(kind: FavoriteKind, id: Int, meta: FavoriteMeta) {
        val current = mutableLibraryState.value
        val metaKey = favoriteMetaKey(kind, id)
        val nextMeta = current.favoriteMeta + (metaKey to meta)
        val snapshot = when (kind) {
            FavoriteKind.LIVE -> {
                val next = if (id in current.favoriteLive) {
                    current.favoriteLive - id
                } else {
                    current.favoriteLive + id
                }
                current.copy(favoriteLive = next, favoriteMeta = nextMeta)
            }
            FavoriteKind.VOD -> {
                val next = if (id in current.favoriteVod) {
                    current.favoriteVod - id
                } else {
                    current.favoriteVod + id
                }
                current.copy(favoriteVod = next, favoriteMeta = nextMeta)
            }
            FavoriteKind.SERIES -> {
                val next = if (id in current.favoriteSeries) {
                    current.favoriteSeries - id
                } else {
                    current.favoriteSeries + id
                }
                current.copy(favoriteSeries = next, favoriteMeta = nextMeta)
            }
        }
        persistLibrary(snapshot)
    }

    fun saveMovieProgress(
        movieId: Int,
        name: String,
        logo: String,
        positionMs: Long,
        durationMs: Long,
    ) {
        if (durationMs <= 0) return
        val current = mutableLibraryState.value
        val progress = PlaybackProgress(
            positionMs = positionMs.coerceAtLeast(0L),
            durationMs = durationMs,
            updatedAt = System.currentTimeMillis(),
        )
        val snapshot = current.copy(
            movieProgress = current.movieProgress + (movieId to MovieProgressEntry(progress, name, logo)),
        )
        persistLibrary(snapshot)
    }

    fun saveEpisodeProgress(
        episodeId: Int,
        meta: EpisodeProgressMeta,
        positionMs: Long,
        durationMs: Long,
    ) {
        if (durationMs <= 0) return
        val current = mutableLibraryState.value
        val progress = PlaybackProgress(
            positionMs = positionMs.coerceAtLeast(0L),
            durationMs = durationMs,
            updatedAt = System.currentTimeMillis(),
        )
        val snapshot = current.copy(
            episodeProgress = current.episodeProgress + (
                episodeId to EpisodeProgressEntry(progress, meta)
                ),
        )
        persistLibrary(snapshot)
    }

    fun clearMovieProgress(movieId: Int) {
        val current = mutableLibraryState.value
        if (movieId !in current.movieProgress) return
        persistLibrary(current.copy(movieProgress = current.movieProgress - movieId))
    }

    fun clearEpisodeProgress(episodeId: Int) {
        val current = mutableLibraryState.value
        if (episodeId !in current.episodeProgress) return
        persistLibrary(current.copy(episodeProgress = current.episodeProgress - episodeId))
    }

    fun setLastVodMovie(movieId: Int) {
        val current = mutableLibraryState.value
        persistLibrary(
            current.copy(
                lastVodPlay = LastVodPlay(
                    type = "movie",
                    movieId = movieId,
                    updatedAt = System.currentTimeMillis(),
                ),
            ),
        )
    }

    fun setLastVodEpisode(seriesId: Int, episodeId: Int) {
        val current = mutableLibraryState.value
        persistLibrary(
            current.copy(
                lastVodPlay = LastVodPlay(
                    type = "episode",
                    seriesId = seriesId,
                    episodeId = episodeId,
                    updatedAt = System.currentTimeMillis(),
                ),
            ),
        )
    }

    fun load(profile: XtreamProfile, forceRefresh: Boolean = false, persist: Boolean = true) {
        if (persist) {
            val id = store.upsert(profile)
            store.setActive(id)
            refreshProfilesState()
        }
        epgMemoryCache.clear()
        xmlTvProfileKey = null
        xmlTvCache.clear()
        XmlTvEpg.clearCache()
        lastGuideChannelIds = null
        guideWarmJob?.cancel()
        guideChannelJob?.cancel()
        guideFullLoadChannels.clear()
        mutableState.value = CatalogState.Loading("Caricamento categorie e canali...")
        viewModelScope.launch {
            if (!forceRefresh) {
                val snapshot = withContext(Dispatchers.IO) {
                    cache.read(profile, CATALOG_TTL_MILLIS)
                }
                if (snapshot != null) {
                    mutableState.value =
                        CatalogState.Ready(profile, snapshot.categories, snapshot.channels)
                    return@launch
                }
            }
            mutableState.value = try {
                val (categories, channels) = withContext(Dispatchers.IO) {
                    client.loadLive(profile)
                }
                withContext(Dispatchers.IO) { cache.write(profile, categories, channels) }
                CatalogState.Ready(profile, categories, channels)
            } catch (error: Exception) {
                CatalogState.Failed(error.message ?: "Errore durante il caricamento")
            }
        }
    }

    fun addProfile(profile: XtreamProfile) {
        val id = store.upsert(profile)
        store.setActive(id)
        refreshProfilesState()
        load(profile, persist = false)
    }

    fun selectProfile(id: String) {
        val saved = store.loadAll().firstOrNull { it.id == id } ?: return
        store.setActive(id)
        refreshProfilesState()
        load(saved.profile, persist = false)
    }

    fun deleteProfile(id: String) {
        val wasActive = store.loadActiveId() == id
        val nextActiveId = store.delete(id)
        refreshProfilesState()
        if (!wasActive) return
        val next = nextActiveId?.let { activeId ->
            store.loadAll().firstOrNull { it.id == activeId }
        }
        if (next != null) {
            load(next.profile, persist = false)
        } else {
            clearLoadedCatalog()
        }
    }

    private fun clearLoadedCatalog() {
        epgMemoryCache.clear()
        xmlTvProfileKey = null
        xmlTvCache.clear()
        XmlTvEpg.clearCache()
        lastGuideChannelIds = null
        guideWarmJob?.cancel()
        guideChannelJob?.cancel()
        guideFullLoadChannels.clear()
        mutableState.value = CatalogState.Empty
        mutableEpgState.value = EpgState.Idle
        mutableGuideState.value = GuideState.Idle
        mutableVodState.value = VodState.Idle
        mutableSeriesState.value = SeriesState.Idle
        mutableVodDetailState.value = VodDetailState.Idle
        mutableSeriesDetailState.value = SeriesDetailState.Idle
    }

    fun loadEpg(profile: XtreamProfile, streamId: Int, channel: LiveChannel? = null) {
        epgMemoryCache[streamId]?.takeIf { it.isNotEmpty() }?.let {
            mutableEpgState.value = EpgState.Ready(streamId, it)
            return
        }
        epgLoadJob?.cancel()
        val requestSeq = ++epgRequestSeq
        epgLoadJob = viewModelScope.launch {
            mutableEpgState.value = EpgState.Loading(streamId)
            val resolvedChannel = channel ?: findChannel(streamId)
            try {
                val shortEpg = withContext(Dispatchers.IO) {
                    withTimeout(EPG_SHORT_TIMEOUT_MS) {
                        runCatching {
                            client.loadShortEpg(profile, streamId, limit = 100)
                        }.getOrDefault(emptyList())
                    }
                }
                if (requestSeq != epgRequestSeq) return@launch

                if (shortEpg.isNotEmpty()) {
                    val quick = dedupeEpgProgrammes(shortEpg)
                    epgMemoryCache[streamId] = quick
                    mutableEpgState.value = EpgState.Ready(streamId, quick)
                }

                if (resolvedChannel == null) {
                    if (shortEpg.isEmpty()) {
                        mutableEpgState.value = EpgState.Failed(streamId, "EPG non disponibile")
                    }
                    return@launch
                }

                val xmlTvEpg = withContext(Dispatchers.IO) {
                    withTimeout(EPG_XML_TIMEOUT_MS) {
                        runCatching {
                            ensureXmlTv(profile, listOf(resolvedChannel))[streamId].orEmpty()
                        }.getOrDefault(emptyList())
                    }
                }
                if (requestSeq != epgRequestSeq) return@launch

                val programmes = dedupeEpgProgrammes(mergeEpgProgrammes(shortEpg, xmlTvEpg))
                if (programmes.isNotEmpty()) {
                    epgMemoryCache[streamId] = programmes
                    mutableEpgState.value = EpgState.Ready(streamId, programmes)
                } else if (shortEpg.isEmpty()) {
                    epgMemoryCache.remove(streamId)
                    mutableEpgState.value = EpgState.Failed(streamId, "EPG non disponibile")
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (requestSeq != epgRequestSeq) return@launch
                epgMemoryCache.remove(streamId)
                mutableEpgState.value = EpgState.Failed(
                    streamId,
                    error.message ?: "EPG non disponibile",
                )
            }
        }
    }

    fun loadGuide(
        profile: XtreamProfile,
        channels: List<LiveChannel>,
        force: Boolean = false,
    ) {
        if (channels.isEmpty()) {
            mutableGuideState.value = GuideState.Ready(emptyMap())
            return
        }
        val channelIds = channels.map(LiveChannel::id)
        if (!force && channelIds == lastGuideChannelIds) {
            val current = mutableGuideState.value
            if (current is GuideState.Ready && !current.loading) return
        }
        lastGuideChannelIds = channelIds
        guideWarmJob?.cancel()
        guideWarmJob = viewModelScope.launch {
            publishGuide(emptyMap(), loading = true, progress = "Preparazione indice EPG...")
            val warmed = withContext(Dispatchers.IO) {
                runCatching { XmlTvEpg.warmCache(profile) }.getOrDefault(false)
            }
            publishGuide(
                programmesByChannel = emptyMap(),
                loading = false,
                progress = if (warmed) null else "XMLTV non disponibile, uso EPG per canale",
            )
        }
    }

    fun loadGuideChannel(
        profile: XtreamProfile,
        channel: LiveChannel,
        requiredDayStart: Long? = null,
    ) {
        val cached = epgMemoryCache[channel.id].orEmpty()
        val requiredDayEnd = requiredDayStart?.plus(DAY_MILLIS)
        if (cached.isNotEmpty()) {
            val coversDay = requiredDayStart == null || requiredDayEnd == null ||
                dayCoversProgrammes(cached, requiredDayStart, requiredDayEnd)
            if (coversDay || channel.id in guideFullLoadChannels) {
                mergeGuideChannel(channel.id, cached, loading = false)
                return
            }
        }
        val current = mutableGuideState.value
        if (current is GuideState.Ready && current.loadingChannelId == channel.id) return
        mergeGuideChannel(
            channel.id,
            cached,
            loading = true,
            loadingChannelId = channel.id,
            progress = channel.name,
        )
        guideChannelJob?.cancel()
        guideChannelJob = viewModelScope.launch {
            try {
                val needsFullTable = requiredDayStart != null &&
                    !dayCoversProgrammes(cached, requiredDayStart, requiredDayStart + DAY_MILLIS)
                val programmes = loadProgrammesForChannel(
                    profile = profile,
                    channel = channel,
                    includeFullTable = needsFullTable || cached.isEmpty(),
                )
                if (programmes.isNotEmpty()) {
                    epgMemoryCache[channel.id] = programmes
                }
                mergeGuideChannel(channel.id, programmes, loading = false)
            } catch (_: Exception) {
                mergeGuideChannel(channel.id, cached, loading = false)
            }
        }
    }

    fun cancelGuideLoads() {
        guideWarmJob?.cancel()
        guideChannelJob?.cancel()
        val current = mutableGuideState.value
        if (current is GuideState.Ready && current.loading) {
            publishGuide(current.programmesByChannel, loading = false)
        }
    }

    private suspend fun loadProgrammesForChannel(
        profile: XtreamProfile,
        channel: LiveChannel,
        includeFullTable: Boolean,
    ): List<EpgProgramme> {
        val xmlTvEpg = ensureXmlTv(
            profile = profile,
            channels = listOf(channel),
            limit = GUIDE_PROGRAMME_LIMIT,
            lookbackDays = GUIDE_LOOKBACK_DAYS,
        )[channel.id].orEmpty()
        val simpleEpg = if (includeFullTable) {
            withContext(Dispatchers.IO) {
                runCatching { client.loadSimpleEpg(profile, channel.id) }.getOrDefault(emptyList())
            }.also { loaded ->
                if (loaded.isNotEmpty()) guideFullLoadChannels.add(channel.id)
            }
        } else {
            emptyList()
        }
        val shortEpg = withContext(Dispatchers.IO) {
            runCatching {
                client.loadShortEpg(profile, channel.id, limit = 100)
            }.getOrDefault(emptyList())
        }
        return dedupeEpgProgrammes(
            mergeEpgProgrammes(
                mergeEpgProgrammes(simpleEpg, xmlTvEpg),
                shortEpg,
            ),
        )
    }

    private fun publishGuide(
        programmesByChannel: Map<Int, List<EpgProgramme>>,
        loading: Boolean,
        loadingChannelId: Int? = null,
        progress: String? = null,
    ) {
        mutableGuideState.value = GuideState.Ready(
            programmesByChannel = programmesByChannel,
            loading = loading,
            loadingChannelId = loadingChannelId,
            progress = progress,
        )
    }

    private fun mergeGuideChannel(
        channelId: Int,
        programmes: List<EpgProgramme>,
        loading: Boolean,
        loadingChannelId: Int? = null,
        progress: String? = null,
    ) {
        val existing = when (val current = mutableGuideState.value) {
            is GuideState.Ready -> current.programmesByChannel
            else -> emptyMap()
        }
        publishGuide(
            existing.toMutableMap().apply { put(channelId, programmes) },
            loading = loading,
            loadingChannelId = loadingChannelId,
            progress = progress,
        )
    }

    private fun currentProgrammes(state: GuideState, channelId: Int): List<EpgProgramme> =
        (state as? GuideState.Ready)?.programmesByChannel?.get(channelId).orEmpty()

    private suspend fun ensureXmlTv(
        profile: XtreamProfile,
        channels: List<LiveChannel>,
        limit: Int = 100,
        lookbackDays: Int = 7,
    ): Map<Int, List<EpgProgramme>> {
        if (channels.isEmpty()) return emptyMap()
        val profileKey = "${profile.baseUrl}|${profile.username}"
        if (xmlTvProfileKey != profileKey) {
            xmlTvProfileKey = profileKey
            xmlTvCache.clear()
        }
        val missing = channels.filter { channel ->
            xmlTvCache[channel.id].orEmpty().isEmpty()
        }
        if (missing.isNotEmpty()) {
            val loaded = withContext(Dispatchers.IO) {
                runCatching {
                    client.loadXmlTvEpg(
                        profile = profile,
                        channels = missing,
                        limit = limit,
                        lookbackDays = lookbackDays,
                    )
                }.getOrDefault(emptyMap())
            }
            xmlTvCache.putAll(loaded)
        }
        return channels.mapNotNull { channel ->
            xmlTvCache[channel.id]
                ?.takeIf { it.isNotEmpty() }
                ?.let { channel.id to it }
        }.toMap()
    }

    private fun findChannel(streamId: Int): LiveChannel? {
        val ready = mutableState.value as? CatalogState.Ready ?: return null
        return ready.channels.firstOrNull { it.id == streamId }
    }

    fun ensureVod(profile: XtreamProfile) {
        if (mutableVodState.value is VodState.Ready || mutableVodState.value is VodState.Loading) {
            return
        }
        viewModelScope.launch {
            mutableVodState.value = VodState.Loading
            mutableVodState.value = try {
                val snapshot = withContext(Dispatchers.IO) {
                    libraryCache.readVod(profile, CATALOG_TTL_MILLIS)
                }
                if (snapshot != null) {
                    return@launch mutableVodState.emit(
                        VodState.Ready(snapshot.categories, snapshot.movies),
                    )
                }
                val categories = withContext(Dispatchers.IO) { client.loadVodCategories(profile) }
                val movies = withContext(Dispatchers.IO) { client.loadVodMovies(profile) }
                withContext(Dispatchers.IO) {
                    libraryCache.writeVod(profile, categories, movies)
                }
                VodState.Ready(categories, movies)
            } catch (error: Exception) {
                VodState.Failed(error.message ?: "Catalogo film non disponibile")
            }
        }
    }

    fun ensureSeries(profile: XtreamProfile) {
        if (
            mutableSeriesState.value is SeriesState.Ready ||
            mutableSeriesState.value is SeriesState.Loading
        ) {
            return
        }
        viewModelScope.launch {
            mutableSeriesState.value = SeriesState.Loading
            mutableSeriesState.value = try {
                val snapshot = withContext(Dispatchers.IO) {
                    libraryCache.readSeries(profile, CATALOG_TTL_MILLIS)
                }
                if (snapshot != null) {
                    return@launch mutableSeriesState.emit(
                        SeriesState.Ready(snapshot.categories, snapshot.shows),
                    )
                }
                val categories = withContext(Dispatchers.IO) { client.loadSeriesCategories(profile) }
                val shows = withContext(Dispatchers.IO) { client.loadSeries(profile) }
                withContext(Dispatchers.IO) {
                    libraryCache.writeSeries(profile, categories, shows)
                }
                SeriesState.Ready(categories, shows)
            } catch (error: Exception) {
                SeriesState.Failed(error.message ?: "Catalogo serie non disponibile")
            }
        }
    }

    fun loadVodDetail(profile: XtreamProfile, movie: VodMovie) {
        viewModelScope.launch {
            mutableVodDetailState.value = VodDetailState.Loading(movie)
            mutableVodDetailState.value = try {
                VodDetailState.Ready(withContext(Dispatchers.IO) { client.loadVodInfo(profile, movie.id) })
            } catch (error: Exception) {
                VodDetailState.Failed(movie, error.message ?: "Dettaglio film non disponibile")
            }
        }
    }

    fun loadSeriesDetail(profile: XtreamProfile, show: SeriesShow) {
        viewModelScope.launch {
            mutableSeriesDetailState.value = SeriesDetailState.Loading(show)
            mutableSeriesDetailState.value = try {
                SeriesDetailState.Ready(withContext(Dispatchers.IO) { client.loadSeriesInfo(profile, show.id) })
            } catch (error: Exception) {
                SeriesDetailState.Failed(show, error.message ?: "Dettaglio serie non disponibile")
            }
        }
    }

    private companion object {
        const val CATALOG_TTL_MILLIS = 24L * 60L * 60L * 1000L
        const val EPG_CACHE_MAX_CHANNELS = 12
        const val EPG_SHORT_TIMEOUT_MS = 10_000L
        const val EPG_XML_TIMEOUT_MS = 15_000L
        const val GUIDE_LOOKBACK_DAYS = 7
        const val GUIDE_PROGRAMME_LIMIT = 120
        const val DAY_MILLIS = 24L * 60L * 60L * 1000L
    }
}

sealed interface GuideState {
    data object Idle : GuideState
    data class Ready(
        val programmesByChannel: Map<Int, List<EpgProgramme>>,
        val loading: Boolean = false,
        val loadingChannelId: Int? = null,
        val progress: String? = null,
    ) : GuideState
    data class Failed(val message: String) : GuideState
}

sealed interface EpgState {
    data object Idle : EpgState
    data class Loading(val streamId: Int) : EpgState
    data class Ready(val streamId: Int, val programmes: List<EpgProgramme>) : EpgState
    data class Failed(val streamId: Int, val message: String) : EpgState
}

sealed interface VodState {
    data object Idle : VodState
    data object Loading : VodState
    data class Ready(val categories: List<VodCategory>, val movies: List<VodMovie>) : VodState
    data class Failed(val message: String) : VodState
}

sealed interface SeriesState {
    data object Idle : SeriesState
    data object Loading : SeriesState
    data class Ready(
        val categories: List<SeriesCategory>,
        val shows: List<SeriesShow>,
    ) : SeriesState
    data class Failed(val message: String) : SeriesState
}

sealed interface VodDetailState {
    data object Idle : VodDetailState
    data class Loading(val movie: VodMovie) : VodDetailState
    data class Ready(val info: VodInfo) : VodDetailState
    data class Failed(val movie: VodMovie, val message: String) : VodDetailState
}

sealed interface SeriesDetailState {
    data object Idle : SeriesDetailState
    data class Loading(val show: SeriesShow) : SeriesDetailState
    data class Ready(val info: SeriesInfo) : SeriesDetailState
    data class Failed(val show: SeriesShow, val message: String) : SeriesDetailState
}

data class ProfilesState(
    val profiles: List<com.lelegiptv.tv.data.SavedProfile> = emptyList(),
    val activeId: String? = null,
)
