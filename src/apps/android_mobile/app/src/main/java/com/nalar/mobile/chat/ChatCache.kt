package com.nalar.mobile.chat

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * One cached transcript row.
 *
 * [raw] is the *verbatim* server object. It is stored whole on purpose: the
 * render model is produced by [ChatApi.toChatMessage], so a cached row and a
 * live row cannot disagree about a field, and a backend field this client has
 * never heard of survives a round-trip through the cache intact.
 *
 * The hoisted [sortKeyNanos] and [id] exist only so the cache can answer "newest
 * N" and "what is older than X" without parsing every payload.
 */
data class CachedChatMessage(
    val id: String,
    val sortKeyNanos: Long,
    val sessionId: String,
    val role: String,
    val content: String,
    val raw: String,
)

/**
 * Last-known transcript, so a cold boot or an offline launch paints real
 * messages instead of a spinner.
 *
 * This is the Android mirror of the web's `ChatEngineDb` (IndexedDB
 * `messages` + `sync_state`), reduced to the two things a phone can do
 * cheaply: hold the newest page per session, and hold a monotonic cursor for
 * the next tail fetch.
 *
 * The same three rules as the sidebar cache make it safe, and all three are
 * load-bearing:
 *
 * 1. **Namespaced per user.** Sign-out only clears the cookie, so an unscoped
 *    cache would put the previous account's conversation on screen for whoever
 *    signs in next on a shared device. A blank `userId` is a miss, not an
 *    unscoped read — stricter than the web's `userScopedKey`, which falls back
 *    to an unscoped key when identity is unresolved, which on a phone is
 *    exactly the leaking case.
 * 2. **Partitioned per session.** A transcript is per-chat by definition.
 * 3. **No TTL, by design.** The web has none either, and it is only safe
 *    because every paint is immediately followed by a live fetch — an
 *    invariant [ChatViewModel] enforces by having prime and revalidate in one
 *    function, not by convention.
 *
 * Every operation is fail-silent: a corrupt payload, a truncated write or a
 * full disk degrades to a plain cache miss. A broken cache must never be the
 * reason the app fails.
 */
interface ChatCache {
    /** Newest first, capped at [limit] — the IndexedDB `getAll` contract. */
    fun readMessages(userId: String?, sessionId: String, limit: Int): List<CachedChatMessage>?

    /** Write-through merge: a same-id row replaces the cached one. */
    fun writeMessages(userId: String?, sessionId: String, messages: List<CachedChatMessage>)

    fun readCursor(userId: String?, sessionId: String): String?

    fun writeCursor(userId: String?, sessionId: String, cursor: String?)

    /** Drops every cached transcript and cursor, for every user. */
    fun clear()
}

/**
 * The pure half of the cache — key namespacing, the `raw` envelope, the
 * monotonic cursor rule and JSON round-tripping — with no Android dependency so
 * it can be exercised on the JVM. The bugs that matter live here, so this is
 * what the unit tests drive.
 */
object ChatCacheCodec {
    private const val KEY_SEPARATOR = "::"
    private const val CACHE_VERSION = 1

    /**
     * `chats::u:<userId>::s:<sessionId>` / `chats-cursor::u:<userId>::s:<sessionId>`.
     *
     * The user id is part of the physical key, which is what makes
     * [ChatCache.clear] the only way to reach another namespace. The `:v1`
     * suffix is the versioned-key convention the web uses for its localStorage
     * caches: bumping it invalidates a shape this code can no longer read.
     */
    fun messagesKey(userId: String?, sessionId: String): String? {
        val user = userId?.takeIf { it.isNotBlank() } ?: return null
        if (sessionId.isBlank()) return null
        return "chats${KEY_SEPARATOR}v$CACHE_VERSION${KEY_SEPARATOR}u:$user${KEY_SEPARATOR}s:$sessionId"
    }

    fun cursorKey(userId: String?, sessionId: String): String? {
        val messages = messagesKey(userId, sessionId) ?: return null
        return "chats-cursor$messages"
    }

    /**
     * Builds a cache row from a wire object, hoisting the two fields the cache
     * indexes on. The full object is kept in [CachedChatMessage.raw].
     */
    fun toCachedMessage(sessionId: String, row: JSONObject): CachedChatMessage? {
        val id = row.optNullableString("id")?.trim().orEmpty()
        if (id.isEmpty()) return null
        return CachedChatMessage(
            id = id,
            sortKeyNanos = ChatApi.parseCreatedAtNanos(row.optNullableString("created_at")),
            sessionId = sessionId,
            role = row.optNullableString("role").orEmpty(),
            content = row.optNullableString("content").orEmpty(),
            raw = row.toString(),
        )
    }

    /**
     * Sync cursor for the next tail fetch: the newest row seen so far.
     *
     * The backend only returns `next_cursor` when `has_more` is true, so it
     * cannot serve as the sync cursor — persisting it wipes a good cursor to
     * null after every small delta, which forces a full descending reload on
     * the next mount. Advance to the newest received row instead, never regress
     * below the previous cursor, and let an empty delta keep what is already
     * there. The web's `newestCursor` states the same rule.
     */
    fun newestCursor(
        items: List<CachedChatMessage>,
        nextCursor: String?,
        previousCursor: String?,
    ): String? {
        var best: Long? = previousCursor?.trim()?.toLongOrNull()
        items.forEach { item ->
            if (item.sortKeyNanos > 0L && (best == null || item.sortKeyNanos > best!!)) {
                best = item.sortKeyNanos
            }
        }
        return best?.toString() ?: nextCursor ?: previousCursor
    }

    fun encodeMessages(messages: List<CachedChatMessage>): String {
        val array = JSONArray()
        messages.forEach { message ->
            array.put(
                JSONObject()
                    .put("id", message.id)
                    .put("sortKey", message.sortKeyNanos)
                    .put("session_id", message.sessionId)
                    .put("role", message.role)
                    .put("content", message.content)
                    .put("raw", message.raw),
            )
        }
        return JSONObject()
            .put("version", CACHE_VERSION)
            .put("messages", array)
            .toString()
    }

    /** Null on any unrecognizable payload, so a foreign entry reads as a miss. */
    fun decodeMessages(payload: String?): List<CachedChatMessage>? {
        val array = try {
            JSONObject(payload.orEmpty()).optJSONArray("messages")
        } catch (_: Exception) {
            null
        } ?: return null

        val out = ArrayList<CachedChatMessage>(array.length())
        for (index in 0 until array.length()) {
            val entry = array.optJSONObject(index) ?: return null
            val id = entry.optString("id").trim()
            if (id.isEmpty()) return null
            val raw = entry.optString("raw")
            if (raw.isBlank()) return null
            out.add(
                CachedChatMessage(
                    id = id,
                    sortKeyNanos = entry.optLong("sortKey", 0L),
                    sessionId = entry.optString("session_id"),
                    role = entry.optString("role"),
                    content = entry.optString("content"),
                    raw = raw,
                ),
            )
        }
        return out
    }

    /** Newest first, mirroring the IndexedDB read order. */
    fun sortNewestFirst(messages: List<CachedChatMessage>): List<CachedChatMessage> =
        messages.sortedWith(
            compareByDescending<CachedChatMessage> { it.sortKeyNanos }.thenByDescending { it.id },
        )

    /** Same-id incoming row replaces the cached one, order preserved. */
    fun mergeReplacing(
        cached: List<CachedChatMessage>,
        incoming: List<CachedChatMessage>,
    ): List<CachedChatMessage> {
        if (incoming.isEmpty()) return cached
        val byId = LinkedHashMap<String, CachedChatMessage>(cached.size + incoming.size)
        cached.forEach { byId[it.id] = it }
        incoming.forEach { byId[it.id] = it }
        return byId.values.toList()
    }
}

/**
 * [ChatCache] on plain files, one JSON document per session.
 *
 * Files rather than [android.content.SharedPreferences] because a long
 * transcript outgrows a preferences value, and files rather than Room because
 * the whole document is rewritten on every write-through anyway — a row store
 * would buy nothing and would add a dependency and a migration to manage.
 *
 * The payload is not encrypted with the Keystore the way the sidebar's is.
 * Unlike a workspace list, a transcript is bulk user content written on every
 * streamed frame, and Keystore round-trips that per write cost more than the
 * exposure is worth on a device that is already full-disk-encrypted. The
 * session cookie, which is a *credential*, stays under the Keystore.
 */
class FileChatCache(context: Context) : ChatCache {
    private val root = File(context.applicationContext.filesDir, DIRECTORY_NAME)

    /**
     * Serializes every read-modify-write of a transcript document.
     *
     * There are three concurrent writers — the tail revalidate, the older-page
     * fetch, and the write-through that follows every streamed turn — and each
     * does read → merge → rewrite. Unsynchronized, two of them read the same
     * `existing`, each merges only its own row, and the loser's row is gone.
     * It does not come back on the next load either, because that row is
     * filtered out of every page as already-seen-live.
     */
    private val lock = Any()

    override fun readMessages(
        userId: String?,
        sessionId: String,
        limit: Int,
    ): List<CachedChatMessage>? {
        val key = ChatCacheCodec.messagesKey(userId, sessionId) ?: return null
        val rows = ChatCacheCodec.decodeMessages(readText(key)) ?: return null
        return ChatCacheCodec.sortNewestFirst(rows).take(limit.coerceAtLeast(1))
    }

    override fun writeMessages(
        userId: String?,
        sessionId: String,
        messages: List<CachedChatMessage>,
    ) {
        if (messages.isEmpty()) return
        val key = ChatCacheCodec.messagesKey(userId, sessionId) ?: return
        synchronized(lock) {
            val existing = ChatCacheCodec.decodeMessages(readText(key)).orEmpty()
            val merged = ChatCacheCodec.mergeReplacing(existing, messages)
            writeText(key, ChatCacheCodec.encodeMessages(merged))
        }
    }

    override fun readCursor(userId: String?, sessionId: String): String? {
        val key = ChatCacheCodec.cursorKey(userId, sessionId) ?: return null
        return readText(key)?.trim()?.takeIf { it.isNotEmpty() }
    }

    override fun writeCursor(userId: String?, sessionId: String, cursor: String?) {
        val key = ChatCacheCodec.cursorKey(userId, sessionId) ?: return
        if (cursor.isNullOrBlank()) {
            deleteText(key)
        } else {
            writeText(key, cursor)
        }
    }

    override fun clear() {
        synchronized(lock) {
            try {
                root.deleteRecursively()
            } catch (_: Exception) {
                // Sign-out already cleared the transcript from memory; a file we
                // cannot delete is not worth failing the sign-out over.
            }
        }
    }

    private fun readText(key: String): String? = try {
        val file = File(root, fileNameFor(key))
        if (file.isFile) file.readText() else null
    } catch (_: Exception) {
        // A truncated write, a revoked key, a full disk. All of them are a miss.
        null
    }

    private fun writeText(key: String, value: String) {
        try {
            if (!root.isDirectory && !root.mkdirs()) return
            val file = File(root, fileNameFor(key))
            // Write to a sibling and rename, so a kill mid-write cannot leave a
            // half-document that would read as a corrupt transcript forever.
            val temp = File(root, "${file.name}.tmp")
            temp.writeText(value)
            if (!temp.renameTo(file)) {
                file.writeText(value)
                temp.delete()
            }
        } catch (_: Exception) {
            // The live fetch still works; only the next launch's instant paint is lost.
        }
    }

    private fun deleteText(key: String) {
        runCatching { File(root, fileNameFor(key)).delete() }
    }

    /**
     * The key contains `:` and would be a legal but unreadable filename, and a
     * user id inside a path is a user id on disk. A hash of the full key keeps
     * namespaces apart and keeps the id out of the path; the readable tail is
     * only there so a directory listing is diagnosable.
     */
    private fun fileNameFor(key: String): String {
        val isCursor = key.startsWith(CURSOR_KEY_PREFIX)
        val prefix = if (isCursor) CURSOR_KEY_PREFIX else MESSAGE_KEY_PREFIX
        val readableTail = key.removePrefix(prefix)
            .replace(NON_FILENAME_CHARS, "_")
            .takeLast(MAX_READABLE_TAIL)
        val extension = if (isCursor) "cursor" else "json"
        return "${key.hashCode().toUInt().toString(16)}_$readableTail.$extension"
    }

    private companion object {
        const val DIRECTORY_NAME = "nalar_chat_cache"
        const val MESSAGE_KEY_PREFIX = "chats"
        const val CURSOR_KEY_PREFIX = "chats-cursor"
        const val MAX_READABLE_TAIL = 40
        val NON_FILENAME_CHARS = Regex("[^A-Za-z0-9._-]")
    }
}
