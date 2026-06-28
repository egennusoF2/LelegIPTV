package com.lelegiptv.tv.data

import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.StringReader
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.Calendar
import java.util.Locale

/**
 * Parses provider XMLTV and maps programmes onto Xtream live channels.
 * Mirrors the fallback used by the Flutter and web clients.
 */
object XmlTvEpg {
    private val XMLTV_DATE =
        Regex("""^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-]\d{4}))?""")

    @Volatile
    private var cachedProfileKey: String? = null

    @Volatile
    private var cachedBody: String? = null

    @Volatile
    private var cachedProgrammeIndexKey: String? = null

    @Volatile
    private var cachedProgrammeIndex: Map<String, List<EpgProgramme>>? = null

    fun clearCache() {
        cachedProfileKey = null
        cachedBody = null
        cachedProgrammeIndexKey = null
        cachedProgrammeIndex = null
    }

    /** Scarica xmltv.php una sola volta per profilo; le parse successive riusano il body. */
    fun warmCache(profile: XtreamProfile): Boolean {
        val key = profileKey(profile)
        if (cachedProfileKey == key && !cachedBody.isNullOrBlank()) return true
        val body = fetchXmlTv(profile)
        cachedProfileKey = key
        cachedBody = body
        cachedProgrammeIndexKey = null
        cachedProgrammeIndex = null
        return body.isNotBlank()
    }

    private fun profileKey(profile: XtreamProfile): String =
        "${profile.baseUrl}|${profile.username}"

    private fun cachedBodyFor(profile: XtreamProfile): String {
        val key = profileKey(profile)
        if (cachedProfileKey == key && !cachedBody.isNullOrBlank()) {
            return cachedBody.orEmpty()
        }
        return warmCache(profile).let { cachedBody.orEmpty() }
    }

    fun loadForChannels(
        profile: XtreamProfile,
        channels: List<LiveChannel>,
        limit: Int = 48,
        lookbackDays: Int = 7,
    ): Map<Int, List<EpgProgramme>> {
        if (channels.isEmpty()) return emptyMap()
        val body = cachedBodyFor(profile)
        if (body.isBlank()) return emptyMap()

        val channelNames = parseChannelNames(body)
        if (channelNames.isEmpty()) return emptyMap()

        val nameIndex = buildUniqueNameIndex(channelNames)
        val keysByChannelId = linkedMapOf<Int, String>()
        val wantedKeys = linkedSetOf<String>()
        for (channel in channels) {
            val key = resolveXmlTvKey(channel, channelNames, nameIndex)
            if (key.isEmpty()) continue
            keysByChannelId[channel.id] = key
            wantedKeys.add(key)
        }
        if (wantedKeys.isEmpty()) return emptyMap()

        val channelById = channels.associateBy(LiveChannel::id)
        val channelIdByKey = keysByChannelId.entries.associate { (id, key) -> key to id }
        val byKey = programmeIndex(body).filterKeys { it in wantedKeys }

        val now = System.currentTimeMillis()
        val result = linkedMapOf<Int, List<EpgProgramme>>()
        for ((channelId, key) in keysByChannelId) {
            val channel = channelById[channelId]
            val replayDays = when {
                channel == null -> lookbackDays
                channel.catchupDays > 0 -> maxOf(channel.catchupDays, lookbackDays)
                channel.hasCatchup -> maxOf(7, lookbackDays)
                else -> lookbackDays
            }
            val lowerBound = now - replayDays * 24L * 60L * 60L * 1000L
            val upperBound = now + 24L * 60L * 60L * 1000L
            val programmes = byKey[key]
                .orEmpty()
                .asSequence()
                .filter { programme ->
                    programme.endTimeMillis > lowerBound &&
                        programme.startTimeMillis < upperBound
                }
                .sortedBy(EpgProgramme::startTimeMillis)
                .take(limit.coerceAtLeast(1))
                .toList()
            if (programmes.isNotEmpty()) {
                result[channelId] = programmes
            }
        }
        return result
    }

    private fun fetchXmlTv(profile: XtreamProfile): String {
        fun encode(value: String): String =
            URLEncoder.encode(value, StandardCharsets.UTF_8.name())
        val query = listOf(
            "username" to profile.username,
            "password" to profile.password,
        ).joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }
        val url = "${profile.baseUrl}/xmltv.php?$query"
        val connection =
            URI(url).toURL().openConnection() as HttpURLConnection
        return try {
            connection.connectTimeout = 12_000
            connection.readTimeout = 45_000
            connection.setRequestProperty("Accept", "application/xml,text/xml,*/*")
            connection.setRequestProperty("User-Agent", "VLC/3.0.20 LibVLC/3.0.20")
            connection.setRequestProperty("Referer", "${profile.baseUrl}/")
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            stream?.use { input ->
                val buffer = ByteArray(8192)
                val out = StringBuilder()
                var total = 0
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    total += read
                    if (total > MAX_XMLTV_BYTES) break
                    out.append(String(buffer, 0, read, StandardCharsets.UTF_8))
                }
                out.toString()
            }.orEmpty()
        } finally {
            connection.disconnect()
        }
    }

    private const val MAX_XMLTV_BYTES = 8 * 1024 * 1024

    private fun parseChannelNames(xml: String): Map<String, String> {
        val names = linkedMapOf<String, String>()
        parse(xml) { parser ->
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                if (parser.eventType != XmlPullParser.START_TAG) continue
                if (parser.name != "channel") continue
                val id = parser.getAttributeValue(null, "id")?.trim()?.lowercase(Locale.US).orEmpty()
                if (id.isEmpty()) {
                    skipTag(parser)
                    continue
                }
                var displayName = id
                while (parser.next() != XmlPullParser.END_TAG || parser.name != "channel") {
                    if (parser.eventType == XmlPullParser.START_TAG && parser.name == "display-name") {
                        val text = readText(parser).trim()
                        if (text.isNotEmpty()) displayName = text
                    } else if (parser.eventType == XmlPullParser.END_TAG && parser.name == "channel") {
                        break
                    }
                }
                names[id] = displayName
            }
        }
        return names
    }

    private fun programmeIndex(body: String): Map<String, List<EpgProgramme>> {
        val key = profileKeyFromBody(body)
        cachedProgrammeIndex?.takeIf { cachedProgrammeIndexKey == key }?.let { return it }
        synchronized(this) {
            cachedProgrammeIndex?.takeIf { cachedProgrammeIndexKey == key }?.let { return it }
            val parsed = parseProgrammes(
                xml = body,
                wantedKeys = null,
                channelById = emptyMap(),
                channelIdByKey = emptyMap(),
            )
            cachedProgrammeIndexKey = key
            cachedProgrammeIndex = parsed
            return parsed
        }
    }

    private fun profileKeyFromBody(body: String): String =
        "${body.length}:${body.hashCode()}"

    private fun parseProgrammes(
        xml: String,
        wantedKeys: Set<String>?,
        channelById: Map<Int, LiveChannel>,
        channelIdByKey: Map<String, Int>,
    ): Map<String, List<EpgProgramme>> {
        val now = System.currentTimeMillis()
        val byKey = linkedMapOf<String, MutableList<EpgProgramme>>()
        parse(xml) { parser ->
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                if (parser.eventType != XmlPullParser.START_TAG || parser.name != "programme") continue
                val key = parser.getAttributeValue(null, "channel")?.trim()?.lowercase(Locale.US).orEmpty()
                if (key.isEmpty() || (wantedKeys != null && key !in wantedKeys)) {
                    skipTag(parser)
                    continue
                }
                val start = parseXmlTvDate(parser.getAttributeValue(null, "start"))
                val end = parseXmlTvDate(parser.getAttributeValue(null, "stop"))
                var title = ""
                var description = ""
                while (parser.next() != XmlPullParser.END_TAG || parser.name != "programme") {
                    when {
                        parser.eventType == XmlPullParser.START_TAG && parser.name == "title" ->
                            title = readText(parser).trim()
                        parser.eventType == XmlPullParser.START_TAG && parser.name == "desc" ->
                            description = readText(parser).trim()
                        parser.eventType == XmlPullParser.END_TAG && parser.name == "programme" ->
                            break
                    }
                }
                if (title.isBlank() || start == null || end == null || end <= start) continue
                val channelId = channelIdByKey[key]
                val channel = channelId?.let(channelById::get)
                if (wantedKeys != null) {
                    if (
                        end < now - 30L * 60L * 1000L &&
                        !EpgReplay.canReplay(channel, start, end, now)
                    ) {
                        continue
                    }
                }
                byKey.getOrPut(key) { mutableListOf() }.add(
                    EpgProgramme(
                        title = title,
                        description = description,
                        startTimeMillis = start,
                        endTimeMillis = end,
                    ),
                )
            }
        }
        return byKey
    }

    private fun buildUniqueNameIndex(channelNames: Map<String, String>): Map<String, String> {
        val index = linkedMapOf<String, String>()
        val duplicates = linkedSetOf<String>()
        for ((id, name) in channelNames) {
            val normalized = normalizeGuideName(name)
            if (normalized.isEmpty()) continue
            val existing = index[normalized]
            when {
                existing == null -> index[normalized] = id
                existing != id -> duplicates.add(normalized)
            }
        }
        duplicates.forEach(index::remove)
        return index
    }

    private fun resolveXmlTvKey(
        channel: LiveChannel,
        channelNames: Map<String, String>,
        nameIndex: Map<String, String>,
    ): String {
        val tvgId = channel.epgChannelId.trim().lowercase(Locale.US)
        if (tvgId.isNotEmpty() && tvgId in channelNames) return tvgId
        val streamId = channel.id.toString()
        if (streamId in channelNames) return streamId
        return nameIndex[normalizeGuideName(channel.name)].orEmpty()
    }

    private fun normalizeGuideName(value: String): String =
        value
            .lowercase(Locale.US)
            .replace(Regex("\\[[^\\]]+\\]"), " ")
            .replace(Regex("\\|[^|]*\\|"), " ")
            .replace(Regex("[^a-z0-9]+"), "")

    private fun parseXmlTvDate(value: String?): Long? {
        val text = value?.trim().orEmpty()
        if (text.isEmpty()) return null
        val match = XMLTV_DATE.matchEntire(text)
        if (match == null) {
            return runCatching {
                java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
                    .parse(text)?.time
            }.getOrNull()
        }
        val year = match.groupValues[1].toInt()
        val month = match.groupValues[2].toInt()
        val day = match.groupValues[3].toInt()
        val hour = match.groupValues[4].toInt()
        val minute = match.groupValues[5].toInt()
        val second = match.groupValues[6].toInt()
        val offset = match.groupValues.getOrNull(7)?.takeIf { it.isNotEmpty() }
        val calendar = Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply {
            set(Calendar.MILLISECOND, 0)
            set(year, month - 1, day, hour, minute, second)
        }
        var utcMillis = calendar.timeInMillis
        if (offset != null) {
            val sign = if (offset.startsWith("-")) -1 else 1
            val offsetHours = offset.substring(1, 3).toInt()
            val offsetMinutes = offset.substring(3, 5).toInt()
            utcMillis -= sign * ((offsetHours * 60L) + offsetMinutes) * 60L * 1000L
        }
        return utcMillis
    }

    private inline fun parse(xml: String, block: (XmlPullParser) -> Unit) {
        val factory = XmlPullParserFactory.newInstance()
        factory.isNamespaceAware = false
        val parser = factory.newPullParser()
        parser.setInput(StringReader(xml))
        block(parser)
    }

    private fun readText(parser: XmlPullParser): String {
        var text = ""
        if (parser.next() == XmlPullParser.TEXT) {
            text = parser.text.orEmpty()
            parser.nextTag()
        }
        return text
    }

    private fun skipTag(parser: XmlPullParser) {
        var depth = 1
        while (depth > 0) {
            when (parser.next()) {
                XmlPullParser.START_TAG -> depth++
                XmlPullParser.END_TAG -> depth--
            }
        }
    }
}

object EpgReplay {
    fun canReplay(
        channel: LiveChannel?,
        startMillis: Long,
        endMillis: Long,
        nowMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        if (channel == null || !channel.hasCatchup) return false
        if (endMillis >= nowMillis || endMillis <= startMillis) return false
        val windowDays = when {
            channel.catchupDays > 0 -> channel.catchupDays
            channel.hasCatchup -> 7
            else -> 0
        }
        if (windowDays <= 0) return false
        return startMillis > nowMillis - windowDays * 24L * 60L * 60L * 1000L
    }

    fun canReplay(channel: LiveChannel?, programme: EpgProgramme, nowMillis: Long = System.currentTimeMillis()): Boolean =
        canReplay(channel, programme.startTimeMillis, programme.endTimeMillis, nowMillis)
}
