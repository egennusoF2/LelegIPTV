package com.lelegiptv.tv.data

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class XtreamProfile(
    val title: String,
    val serverUrl: String,
    val username: String,
    val password: String,
    val liveContainer: String = "ts",
) {
    val baseUrl: String
        get() {
            val raw = serverUrl.trim().trimEnd('/')
            return if (raw.startsWith("http://") || raw.startsWith("https://")) raw else "http://$raw"
        }

    private fun liveExtension(): String =
        if (liveContainer.trim().equals("m3u8", ignoreCase = true)) "m3u8" else "ts"

    fun liveUrl(streamId: Int): String {
        val ext = liveExtension()
        return "$baseUrl/live/$username/$password/$streamId.$ext"
    }

    fun movieUrl(streamId: Int, extension: String = "mp4"): String =
        "$baseUrl/movie/$username/$password/$streamId.${extension.normalizedExtension()}"

    fun seriesUrl(episodeId: Int, extension: String = "mp4"): String =
        "$baseUrl/series/$username/$password/$episodeId.${extension.normalizedExtension()}"

    fun catchupUrl(channel: LiveChannel, programme: EpgProgramme): String? {
        val urls = catchupUrls(channel, programme)
        return urls.firstOrNull()
    }

    fun catchupUrls(channel: LiveChannel, programme: EpgProgramme): List<String> {
        if (!EpgReplay.canReplay(channel, programme)) return emptyList()
        val durationMinutes =
            ((programme.endTimeMillis - programme.startTimeMillis) / 60_000L)
                .coerceAtLeast(1L)
        val formatter = SimpleDateFormat("yyyy-MM-dd:HH-mm", Locale.US)
        val stamp = formatter.format(Date(programme.startTimeMillis))
        val ext = liveExtension()
        val alternate = if (ext == "ts") "m3u8" else "ts"
        val base =
            "$baseUrl/timeshift/$username/$password/$durationMinutes/$stamp/${channel.id}"
        return listOf("$base.$ext", "$base.$alternate")
    }

    private fun String.normalizedExtension(): String =
        trim().trimStart('.').ifBlank { "mp4" }
}

data class LiveCategory(
    val id: String,
    val name: String,
)

data class LiveChannel(
    val id: Int,
    val name: String,
    val logo: String,
    val categoryId: String,
    val epgChannelId: String,
    val catchupMode: String,
    val catchupDays: Int,
) {
    val hasCatchup: Boolean
        get() = catchupMode.isNotBlank() || catchupDays > 0
}

data class EpgProgramme(
    val title: String,
    val description: String,
    val startTimeMillis: Long,
    val endTimeMillis: Long,
)

data class VodCategory(
    val id: String,
    val name: String,
)

data class VodMovie(
    val id: Int,
    val name: String,
    val logo: String,
    val categoryId: String,
    val containerExtension: String,
    val rating: String,
    val year: String,
    val plot: String,
)

data class VodInfo(
    val movie: VodMovie,
    val backdropUrls: List<String>,
    val duration: String,
    val durationSeconds: Long?,
    val genre: String,
    val cast: String,
    val director: String,
    val releaseDate: String,
    val trailerUrl: String,
)

data class SeriesCategory(
    val id: String,
    val name: String,
)

data class SeriesShow(
    val id: Int,
    val name: String,
    val logo: String,
    val categoryId: String,
    val rating: String,
    val year: String,
    val plot: String,
)

data class SeriesEpisode(
    val id: Int,
    val title: String,
    val season: Int,
    val episode: Int,
    val containerExtension: String,
    val duration: String,
    val durationSeconds: Long?,
    val plot: String,
    val image: String,
)

data class SeriesInfo(
    val show: SeriesShow,
    val backdropUrls: List<String>,
    val genre: String,
    val cast: String,
    val director: String,
    val releaseDate: String,
    val episodes: List<SeriesEpisode>,
)

sealed interface CatalogState {
    data object Empty : CatalogState
    data class Loading(val message: String) : CatalogState
    data class Ready(
        val profile: XtreamProfile,
        val categories: List<LiveCategory>,
        val channels: List<LiveChannel>,
    ) : CatalogState
    data class Failed(val message: String) : CatalogState
}

fun mergeEpgProgrammes(
    primary: List<EpgProgramme>,
    fallback: List<EpgProgramme>,
): List<EpgProgramme> {
    if (fallback.isEmpty()) return primary.sortedBy(EpgProgramme::startTimeMillis)
    if (primary.isEmpty()) return fallback.sortedBy(EpgProgramme::startTimeMillis)
    val byKey = linkedMapOf<String, EpgProgramme>()
    for (programme in primary + fallback) {
        val key =
            "${programme.startTimeMillis}|${programme.endTimeMillis}|${programme.title.lowercase()}"
        byKey[key] = programme
    }
    return byKey.values.sortedBy(EpgProgramme::startTimeMillis)
}
