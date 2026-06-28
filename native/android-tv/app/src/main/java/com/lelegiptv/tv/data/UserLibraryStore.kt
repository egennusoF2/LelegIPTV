package com.lelegiptv.tv.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

class UserLibraryStore(context: Context) {
    private val preferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun load(profileId: String): UserLibrarySnapshot {
        if (profileId.isBlank()) return UserLibrarySnapshot.Empty
        val raw = preferences.getString(key(profileId), null) ?: return UserLibrarySnapshot.Empty
        return parse(raw)
    }

    fun save(profileId: String, snapshot: UserLibrarySnapshot) {
        if (profileId.isBlank()) return
        preferences.edit()
            .putString(key(profileId), encode(trimProgress(snapshot)))
            .apply()
    }

    private fun key(profileId: String) = "library_$profileId"

    private fun trimProgress(snapshot: UserLibrarySnapshot): UserLibrarySnapshot {
        if (snapshot.movieProgress.size + snapshot.episodeProgress.size <= MAX_PROGRESS_ENTRIES) {
            return snapshot
        }
        val keep = buildList<Pair<String, Long>>() {
            snapshot.movieProgress.forEach { (id, entry) ->
                add("m:$id" to entry.progress.updatedAt)
            }
            snapshot.episodeProgress.forEach { (id, entry) ->
                add("e:$id" to entry.progress.updatedAt)
            }
        }
            .sortedByDescending { it.second }
            .take(MAX_PROGRESS_ENTRIES)
            .map { it.first }
            .toSet()
        return snapshot.copy(
            movieProgress = snapshot.movieProgress.filterKeys { "m:$it" in keep },
            episodeProgress = snapshot.episodeProgress.filterKeys { "e:$it" in keep },
        )
    }

    private fun parse(raw: String): UserLibrarySnapshot =
        runCatching {
            val root = JSONObject(raw)
            UserLibrarySnapshot(
                favoriteLive = root.optJSONArray("favoriteLive").toIntSet(),
                favoriteVod = root.optJSONArray("favoriteVod").toIntSet(),
                favoriteSeries = root.optJSONArray("favoriteSeries").toIntSet(),
                favoriteMeta = root.optJSONObject("favoriteMeta").toMetaMap(),
                movieProgress = root.optJSONObject("movieProgress").toMovieProgressMap(),
                episodeProgress = root.optJSONObject("episodeProgress").toEpisodeProgressMap(),
                lastVodPlay = root.optJSONObject("lastVod")?.let(LastVodPlay::fromJson),
            )
        }.getOrDefault(UserLibrarySnapshot.Empty)

    private fun encode(snapshot: UserLibrarySnapshot): String =
        JSONObject()
            .put("favoriteLive", snapshot.favoriteLive.toJsonArray())
            .put("favoriteVod", snapshot.favoriteVod.toJsonArray())
            .put("favoriteSeries", snapshot.favoriteSeries.toJsonArray())
            .put("favoriteMeta", snapshot.favoriteMeta.toMetaJson())
            .put("movieProgress", snapshot.movieProgress.toMovieProgressJson())
            .put("episodeProgress", snapshot.episodeProgress.toEpisodeProgressJson())
            .put("lastVod", snapshot.lastVodPlay?.toJson())
            .toString()

    private companion object {
        const val PREFS_NAME = "leleg_tv_library"
        const val MAX_PROGRESS_ENTRIES = 200
    }
}

private fun JSONArray?.toIntSet(): Set<Int> {
    if (this == null) return emptySet()
    return buildSet {
        for (index in 0 until length()) {
            optInt(index).takeIf { it > 0 }?.let(::add)
        }
    }
}

private fun Set<Int>.toJsonArray(): JSONArray =
    JSONArray().also { array ->
        sorted().forEach(array::put)
    }

private fun JSONObject?.toMetaMap(): Map<String, FavoriteMeta> {
    if (this == null) return emptyMap()
    return buildMap {
        keys().forEach { key ->
            optJSONObject(key)?.let { json ->
                put(
                    key,
                    FavoriteMeta(
                        name = json.optString("name"),
                        logo = json.optString("logo"),
                    ),
                )
            }
        }
    }
}

private fun Map<String, FavoriteMeta>.toMetaJson(): JSONObject =
    JSONObject().also { root ->
        forEach { (key, meta) ->
            root.put(
                key,
                JSONObject()
                    .put("name", meta.name)
                    .put("logo", meta.logo),
            )
        }
    }

private fun JSONObject?.toMovieProgressMap(): Map<Int, MovieProgressEntry> {
    if (this == null) return emptyMap()
    return buildMap {
        keys().forEach { key ->
            val id = key.toIntOrNull() ?: return@forEach
            val json = optJSONObject(key) ?: return@forEach
            put(
                id,
                MovieProgressEntry(
                    progress = PlaybackProgress.fromJson(json),
                    name = json.optString("name"),
                    logo = json.optString("logo"),
                ),
            )
        }
    }
}

private fun Map<Int, MovieProgressEntry>.toMovieProgressJson(): JSONObject =
    JSONObject().also { root ->
        forEach { (id, entry) ->
            root.put(
                id.toString(),
                entry.progress.toJson()
                    .put("name", entry.name)
                    .put("logo", entry.logo),
            )
        }
    }

private fun JSONObject?.toEpisodeProgressMap(): Map<Int, EpisodeProgressEntry> {
    if (this == null) return emptyMap()
    return buildMap {
        keys().forEach { key ->
            val id = key.toIntOrNull() ?: return@forEach
            val json = optJSONObject(key) ?: return@forEach
            put(
                id,
                EpisodeProgressEntry(
                    progress = PlaybackProgress.fromJson(json),
                    meta = EpisodeProgressMeta(
                        seriesId = json.optInt("seriesId"),
                        seriesName = json.optString("seriesName"),
                        seriesLogo = json.optString("seriesLogo"),
                        season = json.optInt("season"),
                        episodeNum = json.optInt("episodeNum"),
                        episodeTitle = json.optString("episodeTitle"),
                    ),
                ),
            )
        }
    }
}

private fun Map<Int, EpisodeProgressEntry>.toEpisodeProgressJson(): JSONObject =
    JSONObject().also { root ->
        forEach { (id, entry) ->
            root.put(
                id.toString(),
                entry.progress.toJson()
                    .put("seriesId", entry.meta.seriesId)
                    .put("seriesName", entry.meta.seriesName)
                    .put("seriesLogo", entry.meta.seriesLogo)
                    .put("season", entry.meta.season)
                    .put("episodeNum", entry.meta.episodeNum)
                    .put("episodeTitle", entry.meta.episodeTitle),
            )
        }
    }
