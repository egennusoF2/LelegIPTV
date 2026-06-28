package com.lelegiptv.tv.data

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class SavedProfile(
    val id: String,
    val profile: XtreamProfile,
) {
    val title: String get() = profile.title.ifBlank { "La mia lista" }

    fun matches(other: XtreamProfile): Boolean =
        profile.serverUrl.trim().equals(other.serverUrl.trim(), ignoreCase = true) &&
            profile.username.trim() == other.username.trim()

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("title", profile.title)
        .put("server", profile.serverUrl)
        .put("username", profile.username)
        .put("password", profile.password)

    companion object {
        fun fromJson(json: JSONObject): SavedProfile? {
            val id = json.optString("id").trim()
            val server = json.optString("server").trim()
            val username = json.optString("username").trim()
            val password = json.optString("password")
            if (id.isEmpty() || server.isEmpty() || username.isEmpty() || password.isEmpty()) {
                return null
            }
            return SavedProfile(
                id = id,
                profile = XtreamProfile(
                    title = json.optString("title", "La mia lista"),
                    serverUrl = server,
                    username = username,
                    password = password,
                ),
            )
        }

        fun create(profile: XtreamProfile, id: String = UUID.randomUUID().toString()): SavedProfile =
            SavedProfile(id = id, profile = profile)
    }
}

fun parseSavedProfiles(json: String): List<SavedProfile> {
    if (json.isBlank()) return emptyList()
    return runCatching {
        val array = JSONArray(json)
        buildList {
            for (index in 0 until array.length()) {
                SavedProfile.fromJson(array.optJSONObject(index) ?: continue)?.let(::add)
            }
        }
    }.getOrDefault(emptyList())
}

fun encodeSavedProfiles(profiles: List<SavedProfile>): String =
    JSONArray().apply {
        profiles.forEach { put(it.toJson()) }
    }.toString()
