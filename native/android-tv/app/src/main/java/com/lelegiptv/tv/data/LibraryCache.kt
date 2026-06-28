package com.lelegiptv.tv.data

import android.content.Context
import android.util.JsonReader
import android.util.JsonToken
import android.util.JsonWriter
import java.io.File
import java.io.FileReader
import java.io.FileWriter
import java.security.MessageDigest

class LibraryCache(context: Context) {
    private val directory = File(context.cacheDir, "libraries").apply { mkdirs() }

    fun readVod(profile: XtreamProfile, maxAgeMillis: Long): VodSnapshot? = runCatching {
        val categories = mutableListOf<VodCategory>()
        val movies = mutableListOf<VodMovie>()
        var savedAt = 0L
        JsonReader(FileReader(file(profile, "vod"))).use { reader ->
            reader.beginObject()
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "savedAt" -> savedAt = reader.nextLong()
                    "categories" -> readArray(reader) {
                        categories += readCategory(reader).let { VodCategory(it.first, it.second) }
                    }
                    "items" -> readArray(reader) { movies += readMovie(reader) }
                    else -> reader.skipValue()
                }
            }
            reader.endObject()
        }
        val age = System.currentTimeMillis() - savedAt
        VodSnapshot(categories, movies).takeIf { age in 0..maxAgeMillis }
    }.getOrNull()

    fun readSeries(profile: XtreamProfile, maxAgeMillis: Long): SeriesSnapshot? = runCatching {
        val categories = mutableListOf<SeriesCategory>()
        val shows = mutableListOf<SeriesShow>()
        var savedAt = 0L
        JsonReader(FileReader(file(profile, "series"))).use { reader ->
            reader.beginObject()
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "savedAt" -> savedAt = reader.nextLong()
                    "categories" -> readArray(reader) {
                        categories += readCategory(reader).let {
                            SeriesCategory(it.first, it.second)
                        }
                    }
                    "items" -> readArray(reader) { shows += readShow(reader) }
                    else -> reader.skipValue()
                }
            }
            reader.endObject()
        }
        val age = System.currentTimeMillis() - savedAt
        SeriesSnapshot(categories, shows).takeIf { age in 0..maxAgeMillis }
    }.getOrNull()

    fun writeVod(
        profile: XtreamProfile,
        categories: List<VodCategory>,
        movies: List<VodMovie>,
    ) {
        write(profile, "vod", {
            categories.forEach { writeCategory(it.id, it.name) }
        }) {
            movies.forEach { writeMovie(it) }
        }
    }

    fun writeSeries(
        profile: XtreamProfile,
        categories: List<SeriesCategory>,
        shows: List<SeriesShow>,
    ) {
        write(profile, "series", {
            categories.forEach { writeCategory(it.id, it.name) }
        }) {
            shows.forEach { writeShow(it) }
        }
    }

    private fun write(
        profile: XtreamProfile,
        kind: String,
        categories: JsonWriter.() -> Unit,
        items: JsonWriter.() -> Unit,
    ) {
        val target = file(profile, kind)
        val temporary = File(target.parentFile, "${target.name}.tmp")
        JsonWriter(FileWriter(temporary)).use { writer ->
            writer.beginObject()
            writer.name("savedAt").value(System.currentTimeMillis())
            writer.name("categories").beginArray()
            writer.categories()
            writer.endArray()
            writer.name("items").beginArray()
            writer.items()
            writer.endArray()
            writer.endObject()
        }
        if (!temporary.renameTo(target)) {
            temporary.copyTo(target, overwrite = true)
            temporary.delete()
        }
    }

    private fun JsonWriter.writeCategory(id: String, name: String) {
        beginObject()
        name("id").value(id)
        name("name").value(name)
        endObject()
    }

    private fun JsonWriter.writeMovie(movie: VodMovie) {
        beginObject()
        name("id").value(movie.id)
        name("name").value(movie.name)
        name("logo").value(movie.logo)
        name("categoryId").value(movie.categoryId)
        name("containerExtension").value(movie.containerExtension)
        name("rating").value(movie.rating)
        name("year").value(movie.year)
        name("plot").value(movie.plot)
        endObject()
    }

    private fun JsonWriter.writeShow(show: SeriesShow) {
        beginObject()
        name("id").value(show.id)
        name("name").value(show.name)
        name("logo").value(show.logo)
        name("categoryId").value(show.categoryId)
        name("rating").value(show.rating)
        name("year").value(show.year)
        name("plot").value(show.plot)
        endObject()
    }

    private fun readCategory(reader: JsonReader): Pair<String, String> {
        var id = ""
        var name = ""
        reader.beginObject()
        while (reader.hasNext()) {
            when (reader.nextName()) {
                "id" -> id = reader.nextText()
                "name" -> name = reader.nextText()
                else -> reader.skipValue()
            }
        }
        reader.endObject()
        return id to name
    }

    private fun readMovie(reader: JsonReader): VodMovie {
        val values = readValues(reader)
        return VodMovie(
            values.int("id"),
            values.text("name"),
            values.text("logo"),
            values.text("categoryId"),
            values.text("containerExtension"),
            values.text("rating"),
            values.text("year"),
            values.text("plot"),
        )
    }

    private fun readShow(reader: JsonReader): SeriesShow {
        val values = readValues(reader)
        return SeriesShow(
            values.int("id"),
            values.text("name"),
            values.text("logo"),
            values.text("categoryId"),
            values.text("rating"),
            values.text("year"),
            values.text("plot"),
        )
    }

    private fun readValues(reader: JsonReader): Map<String, String> = buildMap {
        reader.beginObject()
        while (reader.hasNext()) {
            val name = reader.nextName()
            put(name, reader.nextText())
        }
        reader.endObject()
    }

    private fun readArray(reader: JsonReader, item: () -> Unit) {
        reader.beginArray()
        while (reader.hasNext()) item()
        reader.endArray()
    }

    private fun JsonReader.nextText(): String = when (peek()) {
        JsonToken.NULL -> {
            nextNull()
            ""
        }
        JsonToken.BOOLEAN -> nextBoolean().toString()
        JsonToken.STRING, JsonToken.NUMBER -> nextString()
        else -> {
            skipValue()
            ""
        }
    }

    private fun Map<String, String>.text(key: String) = get(key).orEmpty()
    private fun Map<String, String>.int(key: String) = get(key)?.toIntOrNull() ?: 0

    private fun file(profile: XtreamProfile, kind: String): File {
        val source = "${profile.baseUrl}|${profile.username}|$kind"
        val key = MessageDigest.getInstance("SHA-256")
            .digest(source.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(directory, "$key.json")
    }
}

data class VodSnapshot(
    val categories: List<VodCategory>,
    val movies: List<VodMovie>,
)

data class SeriesSnapshot(
    val categories: List<SeriesCategory>,
    val shows: List<SeriesShow>,
)
