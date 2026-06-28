package com.lelegiptv.tv.data

import android.util.Base64
import android.util.JsonReader
import android.util.JsonToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

class XtreamClient {
    suspend fun loadLive(profile: XtreamProfile): Pair<List<LiveCategory>, List<LiveChannel>> =
        withContext(Dispatchers.IO) {
            requestObject(profile, "get_account_info")
            val categories = parseCategories(request(profile, "get_live_categories"))
            val channels = parseChannels(request(profile, "get_live_streams"))
            categories to channels
        }

    suspend fun loadShortEpg(
        profile: XtreamProfile,
        streamId: Int,
        limit: Int = 100,
    ): List<EpgProgramme> = withContext(Dispatchers.IO) {
        require(streamId > 0) { "streamId deve essere positivo" }
        parseShortEpg(
            request(
                profile = profile,
                action = "get_short_epg",
                parameters = mapOf(
                    "stream_id" to streamId.toString(),
                    "limit" to limit.coerceAtLeast(1).toString(),
                ),
            ),
        )
    }

    /** EPG completo per canale (include giorni precedenti). */
    suspend fun loadSimpleEpg(
        profile: XtreamProfile,
        streamId: Int,
    ): List<EpgProgramme> = withContext(Dispatchers.IO) {
        require(streamId > 0) { "streamId deve essere positivo" }
        for (action in SIMPLE_EPG_ACTIONS) {
            val programmes = runCatching {
                parseShortEpg(
                    request(
                        profile = profile,
                        action = action,
                        parameters = mapOf("stream_id" to streamId.toString()),
                    ),
                )
            }.getOrDefault(emptyList())
            if (programmes.isNotEmpty()) return@withContext programmes
        }
        emptyList()
    }

    suspend fun loadXmlTvEpg(
        profile: XtreamProfile,
        channels: List<LiveChannel>,
        limit: Int = 48,
        lookbackDays: Int = 7,
    ): Map<Int, List<EpgProgramme>> = withContext(Dispatchers.IO) {
        runCatching { XmlTvEpg.loadForChannels(profile, channels, limit, lookbackDays) }
            .getOrDefault(emptyMap())
    }

    suspend fun loadVodCategories(profile: XtreamProfile): List<VodCategory> =
        withContext(Dispatchers.IO) {
            parseVodCategories(request(profile, "get_vod_categories"))
        }

    suspend fun loadVodMovies(profile: XtreamProfile): List<VodMovie> =
        withContext(Dispatchers.IO) {
            streamArray(profile, "get_vod_streams", "movies", "streams", "vod_streams") {
                readVodMovie(it)
            }
        }

    suspend fun loadVodInfo(profile: XtreamProfile, vodId: Int): VodInfo =
        withContext(Dispatchers.IO) {
            require(vodId > 0) { "vodId deve essere positivo" }
            parseVodInfo(
                request(
                    profile = profile,
                    action = "get_vod_info",
                    parameters = mapOf("vod_id" to vodId.toString()),
                ),
                vodId,
            )
        }

    suspend fun loadSeriesCategories(profile: XtreamProfile): List<SeriesCategory> =
        withContext(Dispatchers.IO) {
            parseSeriesCategories(request(profile, "get_series_categories"))
        }

    suspend fun loadSeries(profile: XtreamProfile): List<SeriesShow> =
        withContext(Dispatchers.IO) {
            streamArray(profile, "get_series", "series", "shows", "streams") {
                readSeriesShow(it)
            }
        }

    suspend fun loadSeriesInfo(profile: XtreamProfile, seriesId: Int): SeriesInfo =
        withContext(Dispatchers.IO) {
            require(seriesId > 0) { "seriesId deve essere positivo" }
            parseSeriesInfo(
                request(
                    profile = profile,
                    action = "get_series_info",
                    parameters = mapOf("series_id" to seriesId.toString()),
                ),
                seriesId,
            )
        }

    private fun apiUrl(
        profile: XtreamProfile,
        action: String,
        parameters: Map<String, String> = emptyMap(),
    ): String {
        fun encode(value: String): String =
            URLEncoder.encode(value, StandardCharsets.UTF_8.name())
        val query = buildList {
            add("username" to profile.username)
            add("password" to profile.password)
            add("action" to action)
            addAll(parameters.entries.map { it.key to it.value })
        }.joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }
        return "${profile.baseUrl}/player_api.php?$query"
    }

    private fun requestObject(profile: XtreamProfile, action: String): JSONObject {
        val value = request(profile, action)
        return value as? JSONObject
            ?: throw IOException("$action non ha restituito un oggetto JSON")
    }

    private fun request(
        profile: XtreamProfile,
        action: String,
        parameters: Map<String, String> = emptyMap(),
    ): Any {
        val connection =
            URI(apiUrl(profile, action, parameters)).toURL().openConnection() as HttpURLConnection
        return try {
            connection.connectTimeout = 30_000
            connection.readTimeout = when (action) {
                "get_live_streams" -> 90_000
                "get_vod_streams", "get_series" -> 150_000
                "get_series_info" -> 75_000
                "get_short_epg" -> 12_000
                "get_simple_data_table" -> 15_000
                else -> 45_000
            }
            connection.setRequestProperty("Accept", "application/json,text/plain,*/*")
            connection.setRequestProperty("User-Agent", "VLC/3.0.20 LibVLC/3.0.20")
            connection.setRequestProperty("Referer", "${profile.baseUrl}/")
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (status !in 200..299) {
                throw IOException("$action HTTP $status")
            }
            val trimmed = body.trim()
            when {
                trimmed.startsWith("[") -> JSONArray(trimmed)
                trimmed.startsWith("{") -> JSONObject(trimmed)
                else -> throw IOException("$action ha restituito una risposta non JSON")
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun <T : Any> streamArray(
        profile: XtreamProfile,
        action: String,
        vararg objectArrayNames: String,
        readItem: (JsonReader) -> T?,
    ): List<T> {
        val connection =
            URI(apiUrl(profile, action)).toURL().openConnection() as HttpURLConnection
        return try {
            connection.connectTimeout = 30_000
            connection.readTimeout = 180_000
            connection.setRequestProperty("Accept", "application/json,text/plain,*/*")
            connection.setRequestProperty("User-Agent", "VLC/3.0.20 LibVLC/3.0.20")
            connection.setRequestProperty("Referer", "${profile.baseUrl}/")
            val status = connection.responseCode
            if (status !in 200..299) throw IOException("$action HTTP $status")
            JsonReader(InputStreamReader(connection.inputStream, StandardCharsets.UTF_8)).use {
                reader ->
                val result = mutableListOf<T>()
                when (reader.peek()) {
                    JsonToken.BEGIN_ARRAY -> readItems(reader, result, readItem)
                    JsonToken.BEGIN_OBJECT -> {
                        reader.beginObject()
                        while (reader.hasNext()) {
                            val name = reader.nextName()
                            if (
                                name in objectArrayNames &&
                                reader.peek() == JsonToken.BEGIN_ARRAY
                            ) {
                                readItems(reader, result, readItem)
                            } else {
                                reader.skipValue()
                            }
                        }
                        reader.endObject()
                    }
                    else -> throw IOException("$action non ha restituito un array JSON")
                }
                result
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun <T : Any> readItems(
        reader: JsonReader,
        destination: MutableList<T>,
        readItem: (JsonReader) -> T?,
    ) {
        reader.beginArray()
        while (reader.hasNext()) {
            if (reader.peek() == JsonToken.BEGIN_OBJECT) {
                readItem(reader)?.let(destination::add)
            } else {
                reader.skipValue()
            }
        }
        reader.endArray()
    }

    private fun readVodMovie(reader: JsonReader): VodMovie? {
        var id = 0
        var name = ""
        var logo = ""
        var categoryId = ""
        var extension = "mp4"
        var rating = ""
        var year = ""
        var plot = ""
        reader.beginObject()
        while (reader.hasNext()) {
            when (reader.nextName()) {
                "stream_id", "vod_id", "id" -> id = reader.nextText().toIntOrNull() ?: id
                "name", "title" -> name = reader.nextText()
                "stream_icon", "cover", "movie_image", "poster" -> logo = reader.nextText()
                "category_id" -> categoryId = reader.nextText()
                "container_extension", "containerExtension", "extension" ->
                    extension = reader.nextText()
                "rating", "rating_5based", "tmdb_rating" -> rating = reader.nextText()
                "year", "releaseDate", "release_date", "releasedate" -> year = reader.nextText()
                "plot", "description", "overview" -> plot = reader.nextText()
                else -> reader.skipValue()
            }
        }
        reader.endObject()
        if (id <= 0) return null
        return VodMovie(
            id = id,
            name = name.ifBlank { "Film $id" },
            logo = logo,
            categoryId = categoryId,
            containerExtension = extension.trim().trimStart('.').ifBlank { "mp4" },
            rating = rating,
            year = year,
            plot = plot,
        )
    }

    private fun readSeriesShow(reader: JsonReader): SeriesShow? {
        var id = 0
        var name = ""
        var logo = ""
        var categoryId = ""
        var rating = ""
        var year = ""
        var plot = ""
        reader.beginObject()
        while (reader.hasNext()) {
            when (reader.nextName()) {
                "series_id", "stream_id", "id" -> id = reader.nextText().toIntOrNull() ?: id
                "name", "title" -> name = reader.nextText()
                "cover", "stream_icon", "poster" -> logo = reader.nextText()
                "category_id" -> categoryId = reader.nextText()
                "rating", "rating_5based", "tmdb_rating" -> rating = reader.nextText()
                "year", "releaseDate", "release_date" -> year = reader.nextText()
                "plot", "description", "overview" -> plot = reader.nextText()
                else -> reader.skipValue()
            }
        }
        reader.endObject()
        if (id <= 0) return null
        return SeriesShow(id, name.ifBlank { "Serie $id" }, logo, categoryId, rating, year, plot)
    }

    private fun JsonReader.nextText(): String = when (peek()) {
        JsonToken.NULL -> {
            nextNull()
            ""
        }
        JsonToken.STRING, JsonToken.NUMBER -> nextString()
        JsonToken.BOOLEAN -> nextBoolean().toString()
        else -> {
            skipValue()
            ""
        }
    }

    private fun parseCategories(value: Any): List<LiveCategory> {
        val array = when (value) {
            is JSONArray -> value
            is JSONObject -> value.optJSONArray("categories") ?: JSONArray()
            else -> JSONArray()
        }
        return buildList {
            add(LiveCategory("", "Tutti i canali"))
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val id = item.optString("category_id")
                val name = item.optString("category_name")
                if (id.isNotBlank() && name.isNotBlank()) add(LiveCategory(id, name))
            }
        }
    }

    private fun parseChannels(value: Any): List<LiveChannel> {
        val array = when (value) {
            is JSONArray -> value
            is JSONObject -> value.optJSONArray("streams") ?: JSONArray()
            else -> JSONArray()
        }
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val id = item.optInt("stream_id")
                if (id <= 0) continue
                add(
                    LiveChannel(
                        id = id,
                        name = item.optString("name", "Canale $id"),
                        logo = item.optString("stream_icon"),
                        categoryId = item.optString("category_id"),
                        epgChannelId = item.optString(
                            "epg_channel_id",
                            item.optString("tvg_id"),
                        ),
                        catchupMode = parseCatchupMode(item),
                        catchupDays = parseCatchupDays(item),
                    ),
                )
            }
        }
    }

    private fun parseShortEpg(value: Any): List<EpgProgramme> {
        val array = when (value) {
            is JSONArray -> value
            is JSONObject -> sequenceOf("epg_listings", "epg_list", "epg", "programmes")
                .mapNotNull(value::optJSONArray)
                .firstOrNull()
                ?: JSONArray()
            else -> JSONArray()
        }
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val title = decodePossibleBase64(
                    item.firstText("title", "title_raw"),
                ).trim()
                if (title.isBlank()) continue

                val startTime = item.firstTimestamp("start_timestamp", "start")
                val endTime = item.firstTimestamp(
                    "stop_timestamp",
                    "end_timestamp",
                    "end",
                    "stop",
                )
                if (startTime == null || endTime == null || endTime <= startTime) continue

                add(
                    EpgProgramme(
                        title = title,
                        description = decodePossibleBase64(
                            item.firstText("description", "description_raw", "desc"),
                        ).trim(),
                        startTimeMillis = startTime,
                        endTimeMillis = endTime,
                    ),
                )
            }
        }.sortedBy(EpgProgramme::startTimeMillis)
    }

    private fun parseVodCategories(value: Any): List<VodCategory> =
        value.firstArray("categories", "vod_categories").mapObjects { item ->
            val id = item.firstText("category_id", "id")
            val name = item.firstText("category_name", "name", "title")
            if (id.isBlank() || name.isBlank()) null else VodCategory(id, name)
        }

    private fun parseVodMovies(value: Any): List<VodMovie> =
        value.firstArray("movies", "streams", "vod_streams").mapObjects(::parseVodMovie)

    private fun parseVodMovie(item: JSONObject, fallbackId: Int = 0): VodMovie? {
        val id = item.firstInt("stream_id", "vod_id", "id") ?: fallbackId
        if (id <= 0) return null
        return VodMovie(
            id = id,
            name = item.firstText("name", "title").ifBlank { "Film $id" },
            logo = item.firstText("stream_icon", "cover", "movie_image", "poster"),
            categoryId = item.firstText("category_id"),
            containerExtension = item.firstText(
                "container_extension",
                "containerExtension",
                "extension",
            ).normalizedExtension(),
            rating = item.firstText("rating", "rating_5based", "tmdb_rating"),
            year = item.firstText("year", "releaseDate", "release_date", "releasedate"),
            plot = item.firstText("plot", "description", "overview"),
        )
    }

    private fun parseVodInfo(value: Any, vodId: Int): VodInfo {
        val root = value as? JSONObject
            ?: throw IOException("get_vod_info non ha restituito un oggetto JSON")
        val info = root.firstObject("info", "movie_info") ?: JSONObject()
        val movieData = root.firstObject("movie_data", "movie", "stream")
            ?: root
        val merged = mergeObjects(info, movieData)
        val movie = parseVodMovie(merged, vodId)
            ?: throw IOException("get_vod_info non contiene un film valido")
        return VodInfo(
            movie = movie,
            backdropUrls = merged.firstStringList(
                "backdrop_path",
                "backdrop",
                "backdrops",
            ),
            duration = merged.firstText("duration", "runtime"),
            durationSeconds = merged.firstLong("duration_secs", "duration_seconds"),
            genre = merged.firstText("genre", "genres"),
            cast = merged.firstText("cast", "actors"),
            director = merged.firstText("director"),
            releaseDate = merged.firstText(
                "releasedate",
                "release_date",
                "releaseDate",
                "year",
            ),
            trailerUrl = merged.firstText("youtube_trailer", "trailer", "trailer_url"),
        )
    }

    private fun parseSeriesCategories(value: Any): List<SeriesCategory> =
        value.firstArray("categories", "series_categories").mapObjects { item ->
            val id = item.firstText("category_id", "id")
            val name = item.firstText("category_name", "name", "title")
            if (id.isBlank() || name.isBlank()) null else SeriesCategory(id, name)
        }

    private fun parseSeries(value: Any): List<SeriesShow> =
        value.firstArray("series", "shows", "streams").mapObjects(::parseSeriesShow)

    private fun parseSeriesShow(item: JSONObject, fallbackId: Int = 0): SeriesShow? {
        val id = item.firstInt("series_id", "stream_id", "id") ?: fallbackId
        if (id <= 0) return null
        return SeriesShow(
            id = id,
            name = item.firstText("name", "title").ifBlank { "Serie $id" },
            logo = item.firstText("cover", "stream_icon", "poster"),
            categoryId = item.firstText("category_id"),
            rating = item.firstText("rating", "rating_5based", "tmdb_rating"),
            year = item.firstText("year", "releaseDate", "release_date"),
            plot = item.firstText("plot", "description", "overview"),
        )
    }

    private fun parseSeriesInfo(value: Any, seriesId: Int): SeriesInfo {
        val root = value as? JSONObject
            ?: throw IOException("get_series_info non ha restituito un oggetto JSON")
        val info = root.firstObject("info", "series_info") ?: JSONObject()
        val showData = root.firstObject("series", "show") ?: JSONObject()
        val merged = mergeObjects(info, showData)
        val show = parseSeriesShow(merged, seriesId)
            ?: throw IOException("get_series_info non contiene una serie valida")
        val episodes = parseEpisodes(root.opt("episodes"))
        return SeriesInfo(
            show = show,
            backdropUrls = merged.firstStringList(
                "backdrop_path",
                "backdrop",
                "backdrops",
            ),
            genre = merged.firstText("genre", "genres"),
            cast = merged.firstText("cast", "actors"),
            director = merged.firstText("director"),
            releaseDate = merged.firstText(
                "releaseDate",
                "release_date",
                "releasedate",
                "year",
            ),
            episodes = episodes,
        )
    }

    private fun parseEpisodes(value: Any?): List<SeriesEpisode> {
        val episodes = mutableListOf<SeriesEpisode>()
        when (value) {
            is JSONArray -> appendEpisodes(episodes, value, 0)
            is JSONObject -> {
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val seasonHint = key.toIntOrNull() ?: 0
                    when (val seasonValue = value.opt(key)) {
                        is JSONArray -> appendEpisodes(episodes, seasonValue, seasonHint)
                        is JSONObject -> {
                            seasonValue.optJSONArray("episodes")?.let {
                                appendEpisodes(episodes, it, seasonHint)
                            } ?: parseEpisode(seasonValue, seasonHint)?.let(episodes::add)
                        }
                    }
                }
            }
        }
        return episodes
            .distinctBy(SeriesEpisode::id)
            .sortedWith(compareBy(SeriesEpisode::season, SeriesEpisode::episode, SeriesEpisode::id))
    }

    private fun appendEpisodes(
        destination: MutableList<SeriesEpisode>,
        array: JSONArray,
        seasonHint: Int,
    ) {
        for (index in 0 until array.length()) {
            parseEpisode(array.optJSONObject(index) ?: continue, seasonHint)
                ?.let(destination::add)
        }
    }

    private fun parseEpisode(item: JSONObject, seasonHint: Int): SeriesEpisode? {
        val id = item.firstInt("id", "stream_id", "episode_id") ?: return null
        if (id <= 0) return null
        val info = item.firstObject("info") ?: JSONObject()
        val merged = mergeObjects(info, item)
        return SeriesEpisode(
            id = id,
            title = merged.firstText("title", "name").ifBlank { "Episodio $id" },
            season = if (seasonHint > 0) {
                seasonHint
            } else {
                merged.firstInt("season", "season_num") ?: 0
            },
            episode = merged.firstInt("episode_num", "episode", "episode_number") ?: 0,
            containerExtension = merged.firstText(
                "container_extension",
                "containerExtension",
                "extension",
            ).normalizedExtension(),
            duration = merged.firstText("duration", "runtime"),
            durationSeconds = merged.firstLong("duration_secs", "duration_seconds"),
            plot = merged.firstText("plot", "description", "overview"),
            image = merged.firstText("movie_image", "cover", "stream_icon", "poster"),
        )
    }

    private fun Any.firstArray(vararg keys: String): JSONArray = when (this) {
        is JSONArray -> this
        is JSONObject -> keys.asSequence().mapNotNull(::optJSONArray).firstOrNull()
            ?: JSONArray()
        else -> JSONArray()
    }

    private inline fun <T : Any> JSONArray.mapObjects(
        transform: (JSONObject) -> T?,
    ): List<T> = buildList {
        for (index in 0 until length()) {
            transform(optJSONObject(index) ?: continue)?.let(::add)
        }
    }

    private fun JSONObject.firstObject(vararg keys: String): JSONObject? =
        keys.asSequence().mapNotNull(::optJSONObject).firstOrNull()

    private fun JSONObject.firstInt(vararg keys: String): Int? =
        keys.asSequence()
            .mapNotNull { key -> opt(key)?.toString()?.trim()?.toIntOrNull() }
            .firstOrNull()

    private fun JSONObject.firstLong(vararg keys: String): Long? =
        keys.asSequence()
            .mapNotNull { key -> opt(key)?.toString()?.trim()?.toDoubleOrNull()?.toLong() }
            .firstOrNull()

    private fun JSONObject.firstStringList(vararg keys: String): List<String> {
        for (key in keys) {
            when (val value = opt(key)) {
                is JSONArray -> return buildList {
                    for (index in 0 until value.length()) {
                        value.optString(index).trim().takeIf(String::isNotBlank)?.let(::add)
                    }
                }
                is String -> {
                    val text = value.trim()
                    if (text.isBlank()) continue
                    if (text.startsWith("[")) {
                        runCatching { JSONArray(text) }.getOrNull()?.let { array ->
                            return buildList {
                                for (index in 0 until array.length()) {
                                    array.optString(index).trim()
                                        .takeIf(String::isNotBlank)
                                        ?.let(::add)
                                }
                            }
                        }
                    }
                    return listOf(text)
                }
            }
        }
        return emptyList()
    }

    private fun mergeObjects(primary: JSONObject, secondary: JSONObject): JSONObject =
        JSONObject().also { merged ->
            listOf(primary, secondary).forEach { source ->
                val keys = source.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val value = source.opt(key)
                    if (value != null && value != JSONObject.NULL) merged.put(key, value)
                }
            }
        }

    private fun String.normalizedExtension(): String =
        trim().trimStart('.').lowercase(Locale.US).ifBlank { "mp4" }

    private fun JSONObject.firstText(vararg keys: String): String {
        for (key in keys) {
            if (!has(key) || isNull(key)) continue
            val value = opt(key)?.toString()?.trim().orEmpty()
            if (value.isNotBlank() && !value.equals("null", ignoreCase = true)) return value
        }
        return ""
    }

    private fun JSONObject.firstTimestamp(vararg keys: String): Long? {
        for (key in keys) {
            if (!has(key) || isNull(key)) continue
            parseTimestamp(opt(key))?.let { return it }
        }
        return null
    }

    private fun parseTimestamp(value: Any?): Long? {
        val text = value?.toString()?.trim().orEmpty()
        if (text.isBlank() || text.equals("null", ignoreCase = true)) return null
        text.toDoubleOrNull()?.let { numeric ->
            if (!numeric.isFinite() || numeric <= 0.0) return null
            return if (numeric < 100_000_000_000.0) {
                (numeric * 1_000.0).toLong()
            } else {
                numeric.toLong()
            }
        }

        val patterns = listOf(
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
        )
        for (pattern in patterns) {
            val formatter = SimpleDateFormat(pattern, Locale.getDefault()).apply {
                isLenient = false
                when {
                    pattern.endsWith("'Z'") -> timeZone = java.util.TimeZone.getTimeZone("UTC")
                    pattern.contains("XXX") -> timeZone = java.util.TimeZone.getTimeZone("UTC")
                    else -> timeZone = java.util.TimeZone.getDefault()
                }
            }
            val position = ParsePosition(0)
            val parsed = formatter.parse(text, position)
            if (parsed != null && position.index == text.length) return parsed.time
        }
        return null
    }

    private fun decodePossibleBase64(value: String): String {
        val compact = value.trim()
        if (compact.length < 4 || compact.length % 4 != 0 ||
            !compact.matches(BASE64_PATTERN)
        ) {
            return value
        }
        return runCatching {
            val decoded = Base64.decode(compact, Base64.DEFAULT).toString(StandardCharsets.UTF_8)
            if (decoded.isNotBlank() && decoded.all { it == '\n' || it == '\r' || it == '\t' || !it.isISOControl() }) {
                decoded
            } else {
                value
            }
        }.getOrDefault(value)
    }

    private fun parseCatchupMode(item: JSONObject): String {
        val explicit = item.optString("catchup").trim()
        if (explicit.isNotEmpty()) return explicit
        return if (item.optInt("tv_archive") > 0) "xtream" else ""
    }

    private fun parseCatchupDays(item: JSONObject): Int {
        val explicit = item.optInt("tv_archive_duration", -1)
        if (explicit > 0) return explicit
        return if (item.optInt("tv_archive") > 0) 7 else 0
    }

    private companion object {
        val BASE64_PATTERN = Regex("^[A-Za-z0-9+/]+={0,2}$")
        val SIMPLE_EPG_ACTIONS = listOf(
            "get_simple_data_table",
            "get_simple_date_table",
        )
    }
}
