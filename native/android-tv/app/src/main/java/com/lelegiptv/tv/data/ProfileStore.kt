package com.lelegiptv.tv.data

import android.content.Context

class ProfileStore(context: Context) {
    private val preferences =
        context.getSharedPreferences("leleg_tv_profile", Context.MODE_PRIVATE)

    init {
        migrateLegacyIfNeeded()
    }

    fun loadAll(): List<SavedProfile> =
        parseSavedProfiles(preferences.getString(KEY_PROFILES, "").orEmpty())

    fun loadActiveId(): String? =
        preferences.getString(KEY_ACTIVE_ID, null)?.takeIf { it.isNotBlank() }

    fun loadActive(): SavedProfile? {
        val activeId = loadActiveId() ?: return null
        return loadAll().firstOrNull { it.id == activeId }
    }

    fun saveAll(profiles: List<SavedProfile>, activeId: String?) {
        preferences.edit()
            .putString(KEY_PROFILES, encodeSavedProfiles(profiles))
            .putString(KEY_ACTIVE_ID, activeId)
            .apply()
    }

    fun setActive(id: String) {
        preferences.edit().putString(KEY_ACTIVE_ID, id).apply()
    }

    /** Aggiorna se esiste (stesso server+username), altrimenti aggiunge. */
    fun upsert(profile: XtreamProfile): String {
        val profiles = loadAll().toMutableList()
        val existing = profiles.indexOfFirst { it.matches(profile) }
        val id = if (existing >= 0) {
            profiles[existing] = SavedProfile(profiles[existing].id, profile)
            profiles[existing].id
        } else {
            val saved = SavedProfile.create(profile)
            profiles.add(saved)
            saved.id
        }
        saveAll(profiles, id)
        return id
    }

    fun delete(id: String): String? {
        val profiles = loadAll().filterNot { it.id == id }
        val activeId = loadActiveId()
        val nextActive = when {
            profiles.isEmpty() -> null
            activeId == id -> profiles.first().id
            else -> activeId
        }
        saveAll(profiles, nextActive)
        return nextActive
    }

    private fun migrateLegacyIfNeeded() {
        if (preferences.contains(KEY_PROFILES)) return
        val server = preferences.getString("server", null) ?: return
        val username = preferences.getString("username", null) ?: return
        val password = preferences.getString("password", null) ?: return
        val profile = XtreamProfile(
            title = preferences.getString("title", "La mia lista").orEmpty(),
            serverUrl = server,
            username = username,
            password = password,
        )
        val saved = SavedProfile.create(profile)
        saveAll(listOf(saved), saved.id)
        preferences.edit()
            .remove("title")
            .remove("server")
            .remove("username")
            .remove("password")
            .apply()
    }

    private companion object {
        const val KEY_PROFILES = "profiles_json"
        const val KEY_ACTIVE_ID = "active_profile_id"
    }
}
