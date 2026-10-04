package com.pabrik.mobile.chat

import android.content.Context
import com.pabrik.mobile.cache.CachedMessageEntity
import com.pabrik.mobile.cache.ChatCacheDao
import com.pabrik.mobile.cache.ChatCursorEntity
import com.pabrik.mobile.cache.ChatOlderPageEntity
import com.pabrik.mobile.cache.PabrikCacheDatabase
import org.json.JSONObject

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
 * Where a session's older history starts, and whether the server said there is
 * more above it.
 *
 * Stored whole rather than as a bare cursor because the cursor alone cannot arm
 * scroll-to-top. A cursor says where to start asking; `hasMore` says whether to
 * offer the reader the chance at all, and only the server knows that. Re-derive
 * it as `true` on every open and every fully-cached chat grows a permanent
 * "scroll for earlier messages" row that never leads anywhere.
 */
data class ChatOlderPage(
    val cursor: String,
    val hasMore: Boolean,
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

    /**
     * The session's older boundary, or null when this device has never fetched a
     * descending page for it.
     *
     * Separate from [readCursor] on purpose: the tail cursor is a *sync* cursor
     * and the older page is a *paging* cursor, they are written from opposite
     * ends of a response, and deriving one from the other is what made a
     * returning chat stop paging backwards for good.
     */
    fun readOlderPage(userId: String?, sessionId: String): ChatOlderPage?

    /** A null [page] drops the boundary — the server said there is nothing older. */
    fun writeOlderPage(userId: String?, sessionId: String, page: ChatOlderPage?)

    /** Drops every cached transcript and cursor, for every user. */
    fun clear()
}

/**
 * The pure half of the cache — building a row from a wire object and the
 * monotonic cursor rule — with no Android dependency so it can be exercised on
 * the JVM. Everything that used to live here and was about *storage* (key
 * namespacing, JSON envelopes, merge and sort in Kotlin) is now SQL, in
 * `com.pabrik.mobile.cache`.
 *
 * What is left is the two rules that are still the caller's to make: which
 * fields to hoist out of the payload, and when the tail cursor may move.
 */
object ChatCacheCodec {

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
     *
     * This is a pure function of three arguments precisely because the
     * read-modify-write it drives is not: the caller has to read the stored
     * cursor, decide, and write it back, and the rule is the part that can be
     * wrong.
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
}

/**
 * [ChatCache] on Room, one row per message.
 *
 * What the file-backed version had to do by hand, and where each of those now
 * lives:
 *
 * - **Namespacing.** A key string built from `userId` and `sessionId` became
 *   the composite primary key, so a partition is a `WHERE` clause and a
 *   namespace cannot be escaped.
 * - **Newest-first with a limit.** `sortNewestFirst(...).take(n)` in Kotlin
 *   became `ORDER BY sort_key_nanos DESC, message_id DESC LIMIT :n` in SQLite,
 *   which no longer parses every row to answer "give me 400".
 * - **Write-through merge.** Read the document, merge in Kotlin, rewrite the
 *   whole thing under a lock became `INSERT … ON CONFLICT REPLACE` per row, so
 *   a kill mid-write can no longer leave a half-document that reads as a
 *   corrupt transcript forever.
 * - **Atomic rename.** The temp-file-then-rename dance is SQLite's job.
 *
 * The payload is not sealed with the Keystore. Unlike a workspace list, a
 * transcript is bulk user content written on every streamed frame, and a
 * Keystore round-trip per write costs more than the exposure is worth on a
 * device that is already full-disk-encrypted. The session cookie, which is a
 * *credential*, stays under the Keystore.
 */
class RoomChatCache(
    private val dao: ChatCacheDao,
    private val retainedRowsPerSession: Int = RETAINED_ROWS_PER_SESSION,
) : ChatCache {

    constructor(context: Context) : this(PabrikCacheDatabase.get(context).chatCacheDao())

    override fun readMessages(
        userId: String?,
        sessionId: String,
        limit: Int,
    ): List<CachedChatMessage>? {
        val user = userId.orNull() ?: return null
        val session = sessionId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.newestFirst(
                userId = user,
                sessionId = session,
                limit = limit.coerceAtLeast(1),
            )
            // No rows is a miss, and it is the *only* miss a read can have now.
            // The file version could also hold a decoded-empty document; it
            // never did in practice, because `writeMessages` refused an empty
            // list, and `ChatViewModel.readCachedTranscript` cannot tell the two
            // apart.
            if (rows.isEmpty()) null else rows.map { it.toCachedMessage() }
        }
    }

    override fun writeMessages(
        userId: String?,
        sessionId: String,
        messages: List<CachedChatMessage>,
    ) {
        val user = userId.orNull() ?: return
        val session = sessionId.orNull() ?: return
        // An empty write is a no-op rather than a purge. "The page came back
        // empty" is a normal tail-fetch answer, and treating it as "this
        // session now has no messages" would blank the transcript the moment
        // the user reaches the top of it.
        if (messages.isEmpty()) return
        quietly(Unit) {
            dao.writeThrough(
                userId = user,
                sessionId = session,
                rows = messages.map { it.toEntity(user, session) },
                keep = retainedRowsPerSession,
            )
        }
    }

    override fun readCursor(userId: String?, sessionId: String): String? {
        val user = userId.orNull() ?: return null
        val session = sessionId.orNull() ?: return null
        return quietly(null) { dao.cursorFor(user, session) }
    }

    override fun writeCursor(userId: String?, sessionId: String, cursor: String?) {
        val user = userId.orNull() ?: return
        val session = sessionId.orNull() ?: return
        quietly(Unit) {
            if (cursor.isNullOrBlank()) {
                dao.deleteCursor(user, session)
            } else {
                dao.putCursor(ChatCursorEntity(userId = user, sessionId = session, cursor = cursor))
            }
        }
    }

    override fun readOlderPage(userId: String?, sessionId: String): ChatOlderPage? {
        val user = userId.orNull() ?: return null
        val session = sessionId.orNull() ?: return null
        return quietly(null) {
            dao.olderPageFor(user, session)?.let { row ->
                ChatOlderPage(cursor = row.cursor, hasMore = row.hasMore)
            }
        }
    }

    override fun writeOlderPage(userId: String?, sessionId: String, page: ChatOlderPage?) {
        val user = userId.orNull() ?: return
        val session = sessionId.orNull() ?: return
        quietly(Unit) {
            if (page == null) {
                dao.deleteOlderPage(user, session)
            } else {
                dao.putOlderPage(
                    ChatOlderPageEntity(
                        userId = user,
                        sessionId = session,
                        cursor = page.cursor,
                        hasMore = page.hasMore,
                    ),
                )
            }
        }
    }

    override fun clear() = quietly(Unit) { dao.clearAll() }

    /**
     * Runs a cache operation and reports a miss instead of throwing.
     *
     * Every SQLite failure this cache can hit — a full disk, a file the system
     * will not let it open, a row written by a version whose schema is gone —
     * is a reason the *next* launch paints a spinner. None of them is a reason
     * the app fails, and the contract says so.
     */
    private inline fun <T> quietly(fallback: T, block: () -> T): T = try {
        block()
    } catch (_: Exception) {
        fallback
    }

    companion object {
        /**
         * How many rows one session may keep on the device.
         *
         * Deliberately larger than `ChatViewModel.CACHED_MESSAGE_LIMIT` (400),
         * which is the width of the paint-from-cache window. Holding five
         * windows means a reader who scrolled back a few hundred turns still
         * finds that history after a restart, while a session that grows
         * without bound still stops: a row store does not rewrite itself, so
         * without a ceiling "open a long session" would be a slow disk leak.
         */
        const val RETAINED_ROWS_PER_SESSION = 2_000
    }
}

/** A null or blank identity cannot address a partition, so it is not a partition. */
private fun String?.orNull(): String? = this?.takeIf { it.isNotBlank() }

private fun CachedMessageEntity.toCachedMessage(): CachedChatMessage = CachedChatMessage(
    id = messageId,
    sortKeyNanos = sortKeyNanos,
    sessionId = sessionId,
    role = role,
    content = content,
    raw = raw,
)

/**
 * Both partition columns come from the *call*, not from the row.
 *
 * `CachedChatMessage` carries its own `sessionId`, and the two would normally
 * agree — `ChatViewModel` builds every row with `toCachedMessage(sessionId, …)`
 * for the session it is writing. "Normally" is the whole problem: if they ever
 * disagreed, the row would be written into a partition the caller never reads,
 * where it would sit forever consuming the retention budget and never appear.
 * Deriving both from the call makes that unrepresentable, and it keeps the
 * entity's key columns identical to the `WHERE` clause that will find them.
 */
private fun CachedChatMessage.toEntity(
    userId: String,
    sessionId: String,
): CachedMessageEntity = CachedMessageEntity(
    userId = userId,
    sessionId = sessionId,
    messageId = id,
    sortKeyNanos = sortKeyNanos,
    role = role,
    content = content,
    raw = raw,
)
