package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction

/**
 * The sidebar cache's SQL: workspaces and recent chats, both partitioned by
 * user *and* by workspace.
 *
 * Blocking for the same reason as [ChatCacheDao], and `Flow`-free for the same
 * reason.
 */
@Dao
abstract class RecentsCacheDao {

    /**
     * Server order, not sorted order.
     *
     * The endpoint already returns recents in the order it wants them drawn, and
     * re-sorting by name or id would reorder the drawer under a user who
     * expects it stable. `position` is written at insert time and read back
     * here, so the array order the old JSON codec relied on is now an explicit
     * column.
     */
    @Query(
        """
        SELECT * FROM cached_workspaces
        WHERE user_id = :userId
        ORDER BY position ASC
        """,
    )
    abstract fun workspacesFor(userId: String): List<CachedWorkspaceEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertWorkspaces(rows: List<CachedWorkspaceEntity>)

    @Query("DELETE FROM cached_workspaces WHERE user_id = :userId")
    abstract fun deleteWorkspacesFor(userId: String)

    @Query(
        """
        SELECT * FROM cached_chat_summaries
        WHERE user_id = :userId AND workspace_id = :workspaceId
        ORDER BY position ASC
        """,
    )
    abstract fun chatsFor(
        userId: String,
        workspaceId: String,
    ): List<CachedChatSummaryEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertChats(rows: List<CachedChatSummaryEntity>)

    @Query(
        "DELETE FROM cached_chat_summaries WHERE user_id = :userId AND workspace_id = :workspaceId",
    )
    abstract fun deleteChatsFor(userId: String, workspaceId: String)

    /**
     * Replace-not-merge, for both lists.
     *
     * This is the assertion `HomeViewModelCacheTest` makes when a refresh lands
     * — a chat deleted upstream must stay deleted. An `upsert` without the
     * delete would resurrect it from the previous page forever, and the delete
     * has to be in the same transaction as the insert or a kill between them
     * leaves an empty sidebar that reads as "you have no chats".
     */
    @Transaction
    open fun replaceWorkspaces(userId: String, rows: List<CachedWorkspaceEntity>) {
        deleteWorkspacesFor(userId)
        if (rows.isNotEmpty()) upsertWorkspaces(rows)
    }

    @Transaction
    open fun replaceChats(
        userId: String,
        workspaceId: String,
        rows: List<CachedChatSummaryEntity>,
    ) {
        deleteChatsFor(userId, workspaceId)
        if (rows.isNotEmpty()) upsertChats(rows)
    }

    @Query("DELETE FROM cached_workspaces")
    abstract fun deleteAllWorkspaces()

    @Query("DELETE FROM cached_chat_summaries")
    abstract fun deleteAllChats()

    /** Sign-out purge, in one transaction. See [ChatCacheDao.clearAll]. */
    @Transaction
    open fun clearAll() {
        deleteAllWorkspaces()
        deleteAllChats()
    }
}
