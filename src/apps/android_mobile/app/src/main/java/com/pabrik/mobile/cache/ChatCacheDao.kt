package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction

/**
 * The transcript cache's SQL.
 *
 * Every method here is **blocking** on purpose. Room runs a blocking DAO call
 * on the caller's thread, and every caller that reaches one — the transcript
 * prime included — does so inside a `Dispatchers.IO` hop. See
 * `PabrikCacheDatabase` for why the reads are allowed to be main-thread-legal
 * at all.
 *
 * There are no `suspend` functions and no `Flow`. A cache that is written
 * exactly once per page and read exactly once per mount has no observer worth
 * keeping alive, and a `Flow` here would buy a coroutine per table and a
 * second source of truth to argue with.
 */
@Dao
abstract class ChatCacheDao {

    /**
     * Newest first, capped at [limit] — the IndexedDB `getAll` contract the
     * web's `ChatEngineDb` uses.
     *
     * `message_id DESC` is the tie-break for rows sharing a `created_at`, and
     * it is the same tie-break the old in-memory sort used, so a transcript
     * whose timestamps collide paints in the same order it always did.
     */
    @Query(
        """
        SELECT * FROM cached_messages
        WHERE user_id = :userId AND session_id = :sessionId
        ORDER BY sort_key_nanos DESC, message_id DESC
        LIMIT :limit
        """,
    )
    abstract fun newestFirst(
        userId: String,
        sessionId: String,
        limit: Int,
    ): List<CachedMessageEntity>

    /**
     * Write-through merge: a same-id row replaces the cached one.
     *
     * `REPLACE` on the primary key is the whole merge. The file cache had to
     * read the document, merge in Kotlin and rewrite it under a lock, and a
     * killed write could leave a half-document; neither failure exists here
     * because each row is its own statement and SQLite commits it atomically.
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsert(rows: List<CachedMessageEntity>)

    @Query("SELECT cursor FROM chat_cursors WHERE user_id = :userId AND session_id = :sessionId")
    abstract fun cursorFor(userId: String, sessionId: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun putCursor(row: ChatCursorEntity)

    @Query("DELETE FROM chat_cursors WHERE user_id = :userId AND session_id = :sessionId")
    abstract fun deleteCursor(userId: String, sessionId: String)

    /**
     * The session's older boundary, or null when none has been established.
     *
     * A null is a real state, not a miss: it means this app session has never
     * seen a descending page for this chat, so there is nothing to arm
     * scroll-to-top with. It is answered by a *full* descending load, exactly
     * as it was before any cursor was stored.
     */
    @Query(
        "SELECT * FROM chat_older_pages WHERE user_id = :userId AND session_id = :sessionId",
    )
    abstract fun olderPageFor(userId: String, sessionId: String): ChatOlderPageEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun putOlderPage(row: ChatOlderPageEntity)

    @Query("DELETE FROM chat_older_pages WHERE user_id = :userId AND session_id = :sessionId")
    abstract fun deleteOlderPage(userId: String, sessionId: String)

    /**
     * Drops everything past the newest [keep] rows of one session.
     *
     * The file cache was rewritten whole on every write, so its size was
     * bounded by the newest page. A row store is append-only by nature, and
     * "scrolled back through a thousand-turn session" would otherwise leave a
     * thousand rows on the device forever. Trimming the *oldest* keeps the
     * paint-from-cache window — which is the newest [ChatViewModel]'s
     * `CACHED_MESSAGE_LIMIT` rows — exactly as wide as it was.
     *
     * `NOT IN (SELECT … LIMIT …)` is a subquery over one session's index, not
     * a scan: the `user_id, session_id` prefix bounds it.
     */
    @Query(
        """
        DELETE FROM cached_messages
        WHERE user_id = :userId AND session_id = :sessionId
          AND message_id NOT IN (
            SELECT message_id FROM cached_messages
            WHERE user_id = :userId AND session_id = :sessionId
            ORDER BY sort_key_nanos DESC, message_id DESC
            LIMIT :keep
          )
        """,
    )
    abstract fun trimToNewest(
        userId: String,
        sessionId: String,
        keep: Int,
    )

    /**
     * Insert and trim as one transaction.
     *
     * Separate calls would leave a window where a kill between them drops the
     * oldest row without having stored the new one — the cache would be short a
     * message, silently, with no trace.
     */
    @Transaction
    open fun writeThrough(
        userId: String,
        sessionId: String,
        rows: List<CachedMessageEntity>,
        keep: Int,
    ) {
        upsert(rows)
        trimToNewest(userId, sessionId, keep)
    }

    @Query("DELETE FROM cached_messages")
    abstract fun deleteAllMessages()

    @Query("DELETE FROM chat_cursors")
    abstract fun deleteAllCursors()

    @Query("DELETE FROM chat_older_pages")
    abstract fun deleteAllOlderPages()

    /**
     * Sign-out purge, in one transaction.
     *
     * Deleting the rows and leaving the cursors behind would not leak anything
     * — a cursor is a number, and [ChatCache.readCursor] requires the same
     * non-blank `userId` to reach it — but it would leave a transcript that
     * loads full-descending after a sign-in that should have loaded only the
     * tail, which reads as the app having lost the user's history. One
     * transaction also means no interleaving with a write that is already in
     * flight from the session that just ended.
     */
    @Transaction
    open fun clearAll() {
        deleteAllMessages()
        deleteAllCursors()
        deleteAllOlderPages()
    }
}
