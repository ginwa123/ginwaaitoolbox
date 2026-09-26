package com.nalar.mobile.recents

import android.content.Context
import com.nalar.mobile.storage.EncryptedPrefs
import org.json.JSONArray
import org.json.JSONObject

/**
 * Last-known sidebar data, so a cold boot or an offline launch paints real rows
 * instead of an error screen.
 *
 * **Scope: exactly two endpoints**, deliberately — `GET /api/workspaces?is_include_items=false`
 * and `GET /api/session?workspace_id=…`. These are the two the sidebar renders and the
 * two the Vue web's sidebar primitives mirror (`workspacesCache.ts`, `SessionEngineDb`).
 * The web also caches git status, task media, auth/me and message history, but none of
 * those are on this screen, and a general-purpose cache would be harder to reason about
 * than two named accessors. Adding a third endpoint here should be a deliberate change
 * to this interface, not a side effect of some new caller.
 *
 * Three rules make this safe on a phone, and all three are load-bearing:
 *
 * 1. **Namespaced per user.** `logout()` only clears the session
 *    cookie, so an unscoped cache would put the previous account's workspaces
 *    and chat titles on screen for the next person who signs in on a shared
 *    device. Every read and write requires a non-blank `userId`.
 * 2. **Partitioned per workspace.** Recents are scoped server-side, so the cache
 *    is keyed the same way. Painting workspace A's rows under workspace B's name
 *    is the failure this prevents.
 * 3. **Encrypted at rest.** Chat titles are user content and
 *    SharedPreferences are plaintext on disk. This mirrors
 *    [com.nalar.mobile.auth.SessionCookieStore], under its own key alias so the
 *    two can be rotated independently.
 *
 * Every operation is fail-silent: a corrupt payload, an undecryptable entry or
 * a Keystore that refuses to open degrades to a plain cache miss. A broken
 * cache must never be the reason the app fails.
 *
 * There is **no TTL**, matching `workspacesCache.ts`. That is only safe because
 * every paint is immediately followed by a live fetch — an invariant
 * [HomeViewModel] enforces by construction, not by convention.
 */
interface RecentsCache {
    fun readWorkspaces(userId: String?): List<WorkspaceOption>?
    fun writeWorkspaces(userId: String?, workspaces: List<WorkspaceOption>)

    fun readChats(userId: String?, workspaceId: String): List<ChatSummary>?
    fun writeChats(userId: String?, workspaceId: String, chats: List<ChatSummary>)

    /** Drops every cached entry for every user. Called on sign-out. */
    fun clear()
}

/**
 * The pure half of the cache: key namespacing and JSON round-tripping, with no
 * Android dependency so it can be exercised on the JVM. The bugs that matter
 * live here — user isolation, corrupt-payload handling, rows without ids — so
 * this is what the unit tests drive.
 */
object RecentsCacheCodec {
    private const val KEY_SEPARATOR = "::"

    /**
     * `workspaces::u:<userId>` / `chats::u:<userId>::w:<workspaceId>`.
     *
     * The user id is part of the physical key, which is what makes
     * [RecentsCache.clear] the only way to reach another namespace.
     *
     * Returns null for a null or blank `userId` so the no-identity case cannot
     * be expressed as a key at all. This is stricter than the desktop's
     * `userScopedKey`, which falls back to an UNSCOPED key when identity is
     * unresolved; on a phone that fallback is precisely the case where one
     * account's rows leak to the next, so callers cannot opt into it.
     */
    fun workspacesKey(userId: String?): String? =
        userId
            ?.takeIf { it.isNotBlank() }
            ?.let { "workspaces${KEY_SEPARATOR}u:$it" }

    fun chatsKey(userId: String?, workspaceId: String): String? {
        val id = userId?.takeIf { it.isNotBlank() } ?: return null
        if (workspaceId.isBlank()) return null
        return "chats${KEY_SEPARATOR}u:$id${KEY_SEPARATOR}w:$workspaceId"
    }

    fun encodeWorkspaces(workspaces: List<WorkspaceOption>): String {
        val array = JSONArray()
        workspaces.forEach { workspace ->
            array.put(
                JSONObject()
                    .put("id", workspace.id)
                    .put("name", workspace.name),
            )
        }
        return JSONObject().put("workspaces", array).toString()
    }

    /** Null on any unrecognizable payload, so a foreign entry reads as a miss. */
    fun decodeWorkspaces(payload: String?): List<WorkspaceOption>? {
        val array = try {
            JSONObject(payload.orEmpty()).optJSONArray("workspaces")
        } catch (_: Exception) {
            null
        } ?: return null

        val out = ArrayList<WorkspaceOption>(array.length())
        for (index in 0 until array.length()) {
            val entry = array.optJSONObject(index) ?: return null
            val id = entry.optString("id").trim()
            // A row without an id cannot be selected, so the whole payload is
            // suspect rather than half-trustworthy.
            if (id.isEmpty()) return null
            out.add(WorkspaceOption(id = id, name = entry.optString("name").trim()))
        }
        return out
    }

    fun encodeChats(chats: List<ChatSummary>): String {
        val array = JSONArray()
        chats.forEach { chat ->
            array.put(
                JSONObject()
                    .put("id", chat.id)
                    .put("workspaceId", chat.workspaceId)
                    .put("title", chat.title)
                    .put("updatedAt", chat.updatedAtEpochMillis),
            )
        }
        return JSONObject().put("chats", array).toString()
    }

    fun decodeChats(payload: String?): List<ChatSummary>? {
        val array = try {
            JSONObject(payload.orEmpty()).optJSONArray("chats")
        } catch (_: Exception) {
            null
        } ?: return null

        val out = ArrayList<ChatSummary>(array.length())
        for (index in 0 until array.length()) {
            val entry = array.optJSONObject(index) ?: return null
            val id = entry.optString("id").trim()
            if (id.isEmpty()) return null
            val workspaceId = entry.optString("workspaceId").trim()
            if (workspaceId.isEmpty()) return null
            val updatedAt = entry.optLong("updatedAt", RecentsApi.UNKNOWN_TIMESTAMP)
            out.add(
                ChatSummary(
                    id = id,
                    workspaceId = workspaceId,
                    title = entry.optString("title"),
                    updatedAtEpochMillis = updatedAt,
                ),
            )
        }
        return out
    }
}

/**
 * [RecentsCache] on SharedPreferences, with every value sealed under AES-GCM
 * through the Android Keystore. Shares [EncryptedPrefs] with the session cookie
 * so the crypto lives in one place, but under its own key alias.
 */
class KeystoreRecentsCache(context: Context) : RecentsCache {
    private val prefs = EncryptedPrefs(
        context = context,
        preferencesName = PREFERENCES_NAME,
        keyAlias = KEY_ALIAS,
    )

    override fun readWorkspaces(userId: String?): List<WorkspaceOption>? {
        val key = RecentsCacheCodec.workspacesKey(userId) ?: return null
        return RecentsCacheCodec.decodeWorkspaces(prefs.get(key))
    }

    override fun writeWorkspaces(userId: String?, workspaces: List<WorkspaceOption>) {
        val key = RecentsCacheCodec.workspacesKey(userId) ?: return
        prefs.put(key, RecentsCacheCodec.encodeWorkspaces(workspaces))
    }

    override fun readChats(userId: String?, workspaceId: String): List<ChatSummary>? {
        val key = RecentsCacheCodec.chatsKey(userId, workspaceId) ?: return null
        return RecentsCacheCodec.decodeChats(prefs.get(key))
    }

    override fun writeChats(userId: String?, workspaceId: String, chats: List<ChatSummary>) {
        val key = RecentsCacheCodec.chatsKey(userId, workspaceId) ?: return
        prefs.put(key, RecentsCacheCodec.encodeChats(chats))
    }

    override fun clear() = prefs.clear()

    private companion object {
        const val PREFERENCES_NAME = "nalar_recents"
        const val KEY_ALIAS = "nalar_cache_key_v1"
    }
}
