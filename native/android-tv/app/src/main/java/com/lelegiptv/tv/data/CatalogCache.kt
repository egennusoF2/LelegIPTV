package com.lelegiptv.tv.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

class CatalogCache(context: Context) {
    private val directory = File(context.cacheDir, "catalog").apply { mkdirs() }

    data class Snapshot(
        val categories: List<LiveCategory>,
        val channels: List<LiveChannel>,
        val ageMillis: Long,
    )

    fun read(profile: XtreamProfile, maxAgeMillis: Long): Snapshot? {
        val file = fileFor(profile)
        if (!file.isFile) return null
        return runCatching {
            val root = JSONObject(file.readText())
            val savedAt = root.optLong("savedAt")
            val age = System.currentTimeMillis() - savedAt
            if (savedAt <= 0 || age !in 0..maxAgeMillis) return null
            Snapshot(
                categories = parseCategories(root.optJSONArray("categories") ?: JSONArray()),
                channels = parseChannels(root.optJSONArray("channels") ?: JSONArray()),
                ageMillis = age,
            )
        }.getOrNull()
    }

    fun write(
        profile: XtreamProfile,
        categories: List<LiveCategory>,
        channels: List<LiveChannel>,
    ) {
        runCatching {
            val root = JSONObject()
                .put("savedAt", System.currentTimeMillis())
                .put(
                    "categories",
                    JSONArray().apply {
                        categories.forEach {
                            put(JSONObject().put("id", it.id).put("name", it.name))
                        }
                    },
                )
                .put(
                    "channels",
                    JSONArray().apply {
                        channels.forEach {
                            put(
                                JSONObject()
                                    .put("id", it.id)
                                    .put("name", it.name)
                                    .put("logo", it.logo)
                                    .put("categoryId", it.categoryId)
                                    .put("epgChannelId", it.epgChannelId)
                                    .put("catchupMode", it.catchupMode)
                                    .put("catchupDays", it.catchupDays),
                            )
                        }
                    },
                )
            val target = fileFor(profile)
            val temporary = File(target.parentFile, "${target.name}.tmp")
            temporary.writeText(root.toString())
            if (!temporary.renameTo(target)) {
                target.writeText(root.toString())
                temporary.delete()
            }
        }
    }

    private fun fileFor(profile: XtreamProfile): File {
        val identity = "${profile.baseUrl}|${profile.username}"
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(identity.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(directory, "$digest.json")
    }

    private fun parseCategories(array: JSONArray): List<LiveCategory> = buildList {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            add(LiveCategory(item.optString("id"), item.optString("name")))
        }
    }

    private fun parseChannels(array: JSONArray): List<LiveChannel> = buildList {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val id = item.optInt("id")
            if (id <= 0) continue
            add(
                LiveChannel(
                    id = id,
                    name = item.optString("name"),
                    logo = item.optString("logo"),
                    categoryId = item.optString("categoryId"),
                    epgChannelId = item.optString("epgChannelId"),
                    catchupMode = item.optString("catchupMode"),
                    catchupDays = item.optInt("catchupDays"),
                ),
            )
        }
    }
}
