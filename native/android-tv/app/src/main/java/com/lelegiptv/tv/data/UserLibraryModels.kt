package com.lelegiptv.tv.data

enum class FavoriteKind {
    LIVE,
    VOD,
    SERIES,
}

data class FavoriteMeta(
    val name: String,
    val logo: String,
)

data class PlaybackProgress(
    val positionMs: Long,
    val durationMs: Long,
    val updatedAt: Long,
) {
    val fraction: Double
        get() = if (durationMs > 0) positionMs.toDouble() / durationMs else 0.0

    val isCompleted: Boolean
        get() = durationMs > 0 && fraction >= COMPLETED_FRACTION

    val canResume: Boolean
        get() = positionMs >= RESUME_MIN_MS && !isCompleted

    val progressLabel: String?
        get() = when {
            isCompleted -> "Visto"
            canResume -> "${(fraction * 100).toInt()}%"
            else -> null
        }

    fun toJson(): org.json.JSONObject =
        org.json.JSONObject()
            .put("p", positionMs)
            .put("d", durationMs)
            .put("t", updatedAt)

    companion object {
        const val RESUME_MIN_MS = 15_000L
        const val COMPLETED_FRACTION = 0.92

        fun fromJson(json: org.json.JSONObject): PlaybackProgress =
            PlaybackProgress(
                positionMs = json.optLong("p"),
                durationMs = json.optLong("d"),
                updatedAt = json.optLong("t"),
            )
    }
}

data class MovieProgressEntry(
    val progress: PlaybackProgress,
    val name: String,
    val logo: String,
)

data class EpisodeProgressMeta(
    val seriesId: Int,
    val seriesName: String,
    val seriesLogo: String,
    val season: Int,
    val episodeNum: Int,
    val episodeTitle: String,
)

data class EpisodeProgressEntry(
    val progress: PlaybackProgress,
    val meta: EpisodeProgressMeta,
)

data class LastVodPlay(
    val type: String,
    val movieId: Int? = null,
    val seriesId: Int? = null,
    val episodeId: Int? = null,
    val updatedAt: Long,
) {
    fun toJson(): org.json.JSONObject =
        org.json.JSONObject()
            .put("type", type)
            .put("movieId", movieId)
            .put("seriesId", seriesId)
            .put("episodeId", episodeId)
            .put("t", updatedAt)

    companion object {
        fun fromJson(json: org.json.JSONObject): LastVodPlay =
            LastVodPlay(
                type = json.optString("type"),
                movieId = json.optInt("movieId").takeIf { json.has("movieId") && it > 0 },
                seriesId = json.optInt("seriesId").takeIf { json.has("seriesId") && it > 0 },
                episodeId = json.optInt("episodeId").takeIf { json.has("episodeId") && it > 0 },
                updatedAt = json.optLong("t"),
            )
    }
}

sealed interface ContinueWatchingItem {
    val title: String
    val subtitle: String
    val logo: String
    val progress: PlaybackProgress

    data class Movie(
        val movieId: Int,
        val movieName: String,
        override val logo: String,
        override val progress: PlaybackProgress,
    ) : ContinueWatchingItem {
        override val title: String get() = movieName
        override val subtitle: String = "Film"
    }

    data class Episode(
        val episodeId: Int,
        val seriesId: Int,
        override val progress: PlaybackProgress,
        val meta: EpisodeProgressMeta,
    ) : ContinueWatchingItem {
        override val title: String get() = meta.seriesName
        override val subtitle: String =
            "S${meta.season} E${meta.episodeNum}" +
                meta.episodeTitle.takeIf { it.isNotBlank() }?.let { " • $it" }.orEmpty()
        override val logo: String get() = meta.seriesLogo
    }
}

data class UserLibrarySnapshot(
    val favoriteLive: Set<Int> = emptySet(),
    val favoriteVod: Set<Int> = emptySet(),
    val favoriteSeries: Set<Int> = emptySet(),
    val favoriteMeta: Map<String, FavoriteMeta> = emptyMap(),
    val movieProgress: Map<Int, MovieProgressEntry> = emptyMap(),
    val episodeProgress: Map<Int, EpisodeProgressEntry> = emptyMap(),
    val lastVodPlay: LastVodPlay? = null,
) {
    fun isFavorite(kind: FavoriteKind, id: Int): Boolean =
        when (kind) {
            FavoriteKind.LIVE -> id in favoriteLive
            FavoriteKind.VOD -> id in favoriteVod
            FavoriteKind.SERIES -> id in favoriteSeries
        }

    fun continueWatching(limit: Int = 8): List<ContinueWatchingItem> {
        val items = buildList {
            for ((id, entry) in movieProgress) {
                if (entry.progress.canResume) {
                    add(ContinueWatchingItem.Movie(id, entry.name, entry.logo, entry.progress))
                }
            }
            for ((id, entry) in episodeProgress) {
                if (entry.progress.canResume) {
                    add(ContinueWatchingItem.Episode(id, entry.meta.seriesId, entry.progress, entry.meta))
                }
            }
        }
        val last = lastVodPlay
        val sorted = items.sortedByDescending { it.progress.updatedAt }
        if (last == null) return sorted.take(limit)
        val prioritized = sorted.partition { item ->
            when (item) {
                is ContinueWatchingItem.Movie -> item.movieId == last.movieId
                is ContinueWatchingItem.Episode -> item.episodeId == last.episodeId
            }
        }
        return (prioritized.first + prioritized.second).take(limit)
    }

    companion object {
        val Empty = UserLibrarySnapshot()
    }
}

fun favoriteMetaKey(kind: FavoriteKind, id: Int): String =
    when (kind) {
        FavoriteKind.LIVE -> "live:$id"
        FavoriteKind.VOD -> "vod:$id"
        FavoriteKind.SERIES -> "series:$id"
    }
