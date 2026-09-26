package com.nalar.mobile.recents

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

/**
 * Last-known sidebar data, so a cold boot or an offline launch paints real rows
 * instead of an error screen.
 *
 * Two rules make this safe on a phone, and both are load-bearing:
 *
 * 1. **Namespaced per user.** `useAnotherAccount()` only clears the session
 *    cookie, so an unscoped cache would put the previous account's workspaces
 *    and chat titles on screen for the next person who signs in on a shared
 *    device. Every read and write requires a non-blank `userId`.
 * 2. **Encrypted at rest.** Chat titles are user content and
 *    SharedPreferences are plaintext on disk. This mirrors
 *    [com.nalar.mobile.auth.SessionCookieStore], under its own key alias so the
 *    two can be rotated independently.
 *
 * Every operation is fail-silent: a corrupt payload, an undecryptable entry or
 * a Keystore that refuses to open degrades to a plain cache miss. A broken
 * cache must never be the reason the app fails.
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
 * through the Android Keystore.
 *
 * A separate key alias from the session cookie on purpose: a suspected
 * credential leak and a suspected cache leak are different investigations, and
 * rotating one must not invalidate the other.
 */
class KeystoreRecentsCache(context: Context) : RecentsCache {
    private val preferences by lazy {
        context.applicationContext.getSharedPreferences(
            PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
    }

    override fun readWorkspaces(userId: String?): List<WorkspaceOption>? {
        val key = RecentsCacheCodec.workspacesKey(userId) ?: return null
        return RecentsCacheCodec.decodeWorkspaces(read(key))
    }

    override fun writeWorkspaces(userId: String?, workspaces: List<WorkspaceOption>) {
        val key = RecentsCacheCodec.workspacesKey(userId) ?: return
        write(key, RecentsCacheCodec.encodeWorkspaces(workspaces))
    }

    override fun readChats(userId: String?, workspaceId: String): List<ChatSummary>? {
        val key = RecentsCacheCodec.chatsKey(userId, workspaceId) ?: return null
        return RecentsCacheCodec.decodeChats(read(key))
    }

    override fun writeChats(userId: String?, workspaceId: String, chats: List<ChatSummary>) {
        val key = RecentsCacheCodec.chatsKey(userId, workspaceId) ?: return
        write(key, RecentsCacheCodec.encodeChats(chats))
    }

    override fun clear() {
        // `commit` rather than `apply`: sign-out must not race a pending write
        // that would restore the very rows we are purging.
        preferences.edit().clear().commit()
    }

    private fun read(key: String): String? = try {
        val payload = preferences.getString(key, null) ?: return null
        decrypt(payload).takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        // An entry written by a different Keystore key (e.g. after a restore to
        // a new device) is unreadable. Drop it and treat it as a miss.
        runCatching { preferences.edit().remove(key).commit() }
        null
    }

    private fun write(key: String, plainText: String) {
        try {
            preferences.edit().putString(key, encrypt(plainText)).commit()
        } catch (_: Exception) {
            // Quota / Keystore unavailable — the live fetch still works; only
            // the next launch's instant paint is lost.
        }
    }

    private fun encrypt(plainText: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.doFinal(plainText.toByteArray(StandardCharsets.UTF_8))
        return listOf(
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(encrypted, Base64.NO_WRAP),
        ).joinToString(PAYLOAD_SEPARATOR)
    }

    private fun decrypt(payload: String): String {
        val parts = payload.split(PAYLOAD_SEPARATOR, limit = 2)
        require(parts.size == 2) { "Malformed recents cache payload" }

        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val encrypted = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val PREFERENCES_NAME = "nalar_recents"
        const val KEY_ALIAS = "nalar_cache_key_v1"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val PAYLOAD_SEPARATOR = ":"
    }
}
