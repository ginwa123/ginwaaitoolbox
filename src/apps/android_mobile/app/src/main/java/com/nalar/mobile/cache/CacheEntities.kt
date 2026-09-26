package com.nalar.mobile.cache

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/**
 * One cached transcript row, and one table per cache partition.
 *
 * Every table is keyed by the same triple the old hand-written keys encoded:
 * the user, then the thing inside the user. Putting the user id *in the primary
 * key* rather than in a string prefix is the point of the move — a namespace can
 * no longer be escaped, because there is no string to escape it with, and
 * `DELETE FROM cached_workspaces` is a complete, provable purge.
 *
 * Two rules the old JSON documents enforced by hand and this schema now
 * enforces structurally:
 *
 * 1. **Per-user isolation** is a column of the primary key, so a row written
 *    for `user_a` is physically unreachable by a query for `user_b`.
 * 2. **Replace-not-merge** for a whole list is `DELETE` + `INSERT` inside one
 *    transaction, and replace-one-row is `OnConflictStrategy.REPLACE` against
 *    the primary key.
 *
 * Only columns the server or the UI can order and filter on are stored in the
 * clear. Anything a stranger should not read on a shared device is sealed — see
 * `SealingCipher` for why the sealing is per-column rather than whole-file.
 */

/**
 * A transcript row. [raw] is the verbatim server object; `sort_key_nanos` is
 * hoisted out of it so the query can order and limit without parsing JSON.
 */
@Entity(
    tableName = "cached_messages",
    primaryKeys = ["user_id", "session_id", "message_id"],
    // Covers `WHERE user_id AND session_id ORDER BY sort_key_nanos DESC,
    // message_id DESC` — every transcript read this app makes. An index on
    // `sort_key_nanos` alone could not serve it without a second b-tree lookup.
    indices = [
        Index(value = ["user_id", "session_id", "sort_key_nanos", "message_id"]),
    ],
)
data class CachedMessageEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "session_id") val sessionId: String,
    @ColumnInfo(name = "message_id") val messageId: String,
    @ColumnInfo(name = "sort_key_nanos") val sortKeyNanos: Long,
    val role: String,
    val content: String,
    /**
     * Deliberately NOT sealed. This is bulk user content rewritten on every
     * streamed frame, and the session cookie — the actual credential — is under
     * the Keystore already. `ChatCache` carries the same reasoning in prose.
     */
    val raw: String,
)

/**
 * The monotonic tail-fetch cursor for one session. Its own table because it is
 * written on a different cadence from the rows and read on its own, and because
 * "the newest row seen" is a fact about the session, not a property of any row.
 */
@Entity(
    tableName = "chat_cursors",
    primaryKeys = ["user_id", "session_id"],
)
data class ChatCursorEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "session_id") val sessionId: String,
    val cursor: String,
)

/**
 * One workspace row, in the order the server sent it.
 *
 * [position] is the load-bearing column. The old codec stored a JSON array, so
 * array order *was* the order; a row store has no such free guarantee, and
 * `ORDER BY name` would silently re-sort the drawer under the user.
 */
@Entity(
    tableName = "cached_workspaces",
    primaryKeys = ["user_id", "workspace_id"],
    indices = [Index(value = ["user_id", "position"])],
)
data class CachedWorkspaceEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "workspace_id") val workspaceId: String,
    val position: Int,
    /** Sealed: a workspace name is user content on a device that may be shared. */
    @ColumnInfo(name = "name_sealed") val nameSealed: String,
)

/**
 * One recent-chat row, in the order the server sent it.
 *
 * `updated_at` stays in the clear even though it is user data: it is the sort
 * key, and sealing it would mean decrypting every row to order them. It reveals
 * when you last worked, not what you worked on.
 *
 * `last_human_touched_at` is stored the same way and for the same reason —
 * it is the row's *label* key, so a cold boot paints the same relative times
 * the network paint would. Persisting only the order key would make every
 * cached row claim the agent's last activity was yours.
 */
@Entity(
    tableName = "cached_chat_summaries",
    primaryKeys = ["user_id", "workspace_id", "chat_id"],
    indices = [Index(value = ["user_id", "workspace_id", "position"])],
)
data class CachedChatSummaryEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "workspace_id") val workspaceId: String,
    @ColumnInfo(name = "chat_id") val chatId: String,
    val position: Int,
    @ColumnInfo(name = "updated_at_epoch_millis") val updatedAtEpochMillis: Long,
    @ColumnInfo(name = "last_human_touched_at_epoch_millis")
    val lastHumanTouchedAtEpochMillis: Long,
    /** Sealed: a chat title is the single most identifying string in the app. */
    @ColumnInfo(name = "title_sealed") val titleSealed: String,
)

/**
 * One cached `GET /api/auth/me` response, keyed by a fingerprint of the session
 * cookie. An identity, so it is sealed whole; there is no column to sort or
 * filter on, so nothing needs to stay readable.
 */
@Entity(tableName = "cached_auth_me", primaryKeys = ["cookie_fingerprint"])
data class CachedAuthMeEntity(
    @ColumnInfo(name = "cookie_fingerprint") val cookieFingerprint: String,
    @ColumnInfo(name = "body_sealed") val bodySealed: String,
    @ColumnInfo(name = "stored_at_epoch_millis") val storedAtEpochMillis: Long,
)

/**
 * One `workspace_items` row, in the order the server sent it.
 *
 * Same shape and same reasoning as [CachedWorkspaceEntity] one level down: the
 * user id is *in the primary key*, so a row written for one account is
 * physically unreachable by a query for another, and [position] is what keeps
 * the drawer from re-sorting the list alphabetically under a user who never
 * asked for that.
 */
@Entity(
    tableName = "cached_projects",
    primaryKeys = ["user_id", "workspace_id", "project_id"],
    indices = [Index(value = ["user_id", "workspace_id", "position"])],
)
data class CachedProjectEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "workspace_id") val workspaceId: String,
    @ColumnInfo(name = "project_id") val projectId: String,
    val position: Int,
    /**
     * NOT sealed, unlike the name beside it. `item_type` is a closed vocabulary
     * (`kanban` / `agent` / `routine` / `design` / `folder`) that reveals nothing
     * about what the user is working on, and keeping it readable means the
     * glyph decision needs no decrypt.
     */
    val itemType: String,
    /** Sealed: a project name is user content on a device that may be shared. */
    @ColumnInfo(name = "name_sealed") val nameSealed: String,
)

/**
 * One project's chat row, in the order the server sent it.
 *
 * The task id is the session id (the backend's own join, `http_response.zig`),
 * so [chatId] is what the chat route takes and nothing has to be translated
 * between a cached row and a navigation argument.
 */
@Entity(
    tableName = "cached_project_chats",
    primaryKeys = ["user_id", "workspace_id", "project_id", "chat_id"],
    indices = [Index(value = ["user_id", "workspace_id", "project_id", "position"])],
)
data class CachedProjectChatEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "workspace_id") val workspaceId: String,
    @ColumnInfo(name = "project_id") val projectId: String,
    @ColumnInfo(name = "chat_id") val chatId: String,
    val position: Int,
    /**
     * In the clear for the same reason a recents row's is: it is the sort key,
     * and sealing it would mean decrypting every row to order them. It reveals
     * when you last worked, not what you worked on.
     */
    @ColumnInfo(name = "updated_at_epoch_millis") val updatedAtEpochMillis: Long,
    /** Sealed: a chat title is the single most identifying string in the app. */
    @ColumnInfo(name = "name_sealed") val nameSealed: String,
)
