package com.lelegiptv.tv.data

object ProfilePresets {
    private val values = mapOf(
        "LELEG" to XtreamProfile(
            title = "LELEG",
            serverUrl = "http://muti14.fonsecatemp.com",
            username = "notv_w7cehc",
            password = "ffhuax4a",
        ),
        "JOLLY" to XtreamProfile(
            title = "JOLLY",
            serverUrl = "http://muti14.fonsecatemp.com",
            username = "notv_71d762",
            password = "qgjjhnty",
        ),
        "AMICO" to XtreamProfile(
            title = "AMICO",
            serverUrl = "http://muti14.fonsecatemp.com",
            username = "notv_93me22",
            password = "x7g35zhh",
        ),
        "ALESSANDRO" to XtreamProfile(
            title = "ALESSANDRO",
            serverUrl = "http://watchtivo-4k.com",
            username = "S8eLtOiTtE",
            password = "ut6YxwMG6X",
        ),
        "GIORDANO" to XtreamProfile(
            title = "GIORDANO",
            serverUrl = "http://watchtivo-4k.com",
            username = "bSFZGHX1Gr",
            password = "zHwiKBmB1O",
        ),
    )

    fun resolve(code: String): XtreamProfile? = values[code.trim().uppercase()]

    /** Compila server/username/password dal codice lista se riconosciuto. */
    fun profileFromForm(
        rawTitle: String,
        rawServer: String,
        rawUsername: String,
        rawPassword: String,
    ): XtreamProfile? {
        val preset = resolve(rawTitle)
        val server = (preset?.serverUrl ?: rawServer).trim()
        val username = (preset?.username ?: rawUsername).trim()
        val password = preset?.password ?: rawPassword
        if (server.isBlank() || username.isBlank() || password.isBlank()) return null
        val title = rawTitle.trim().ifBlank { preset?.title ?: "La mia lista" }
        return XtreamProfile(
            title = preset?.title ?: title,
            serverUrl = server,
            username = username,
            password = password,
        )
    }

    /** Codici selezionabili da telecomando senza tastiera. */
    fun codes(): List<String> = values.keys.sorted()
}
