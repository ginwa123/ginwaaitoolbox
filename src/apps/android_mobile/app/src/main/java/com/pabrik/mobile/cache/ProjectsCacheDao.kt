package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction

/**
 * The projects cache's SQL: a workspace's projects, and each project's chats.
 *
 * Partitioned by user *and* workspace, one level deeper than
 * [RecentsCacheDao] — a project's chats are only meaningful next to the project
 * they belong to, and the same project id is fetched again under a different
 * workspace's scope.
 *
 * Blocking and `Flow`-free for the same reasons as every other DAO here; see
 * [PabrikCacheDatabase] on `allowMainThreadQueries`.
 */
@Dao
abstract class ProjectsCacheDao {

    @Query(
        """
        SELECT * FROM cached_projects
        WHERE user_id = :userId AND workspace_id = :workspaceId
        ORDER BY position ASC
        """,
    )
    abstract fun projectsFor(
        userId: String,
        workspaceId: String,
    ): List<CachedProjectEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertProjects(rows: List<CachedProjectEntity>)

    @Query("DELETE FROM cached_projects WHERE user_id = :userId AND workspace_id = :workspaceId")
    abstract fun deleteProjectsFor(
        userId: String,
        workspaceId: String,
    )

    @Query(
        """
        SELECT * FROM cached_project_chats
        WHERE user_id = :userId AND workspace_id = :workspaceId AND project_id = :projectId
        ORDER BY position ASC
        """,
    )
    abstract fun projectChatsFor(
        userId: String,
        workspaceId: String,
        projectId: String,
    ): List<CachedProjectChatEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertProjectChats(rows: List<CachedProjectChatEntity>)

    @Query(
        """
        DELETE FROM cached_project_chats
        WHERE user_id = :userId AND workspace_id = :workspaceId AND project_id = :projectId
        """,
    )
    abstract fun deleteProjectChatsFor(
        userId: String,
        workspaceId: String,
        projectId: String,
    )

    /**
     * Replace-not-merge, for both lists, in one transaction each.
     *
     * Same argument as [RecentsCacheDao.replaceChats]: a project deleted on the
     * server must stay deleted, and a delete that is not in the same
     * transaction as its insert leaves an empty list that reads as "you have no
     * projects" if the process dies between them.
     */
    @Transaction
    open fun replaceProjects(
        userId: String,
        workspaceId: String,
        rows: List<CachedProjectEntity>,
    ) {
        deleteProjectsFor(userId, workspaceId)
        if (rows.isNotEmpty()) upsertProjects(rows)
    }

    @Transaction
    open fun replaceProjectChats(
        userId: String,
        workspaceId: String,
        projectId: String,
        rows: List<CachedProjectChatEntity>,
    ) {
        deleteProjectChatsFor(userId, workspaceId, projectId)
        if (rows.isNotEmpty()) upsertProjectChats(rows)
    }

    /**
     * Drop a workspace's chats when the workspace's projects are replaced.
     *
     * Without this, a project removed on the server leaves its chat rows behind
     * forever — unreachable through the UI, but still on disk, still under the
     * previous account's key, and still readable by anyone who opens the file.
     *
     * The empty case is its own statement on purpose. `NOT IN (:keepProjectIds)`
     * with an empty bind list is not reliably `NOT IN ()` — that is a syntax
     * error, and Room's rewrite of an empty collection is not something a cache
     * should be betting a sign-out on. "The workspace has no projects left, so
     * drop all of their chats" deserves a query that says exactly that.
     */
    @Transaction
    open fun deleteChatsForWorkspace(
        userId: String,
        workspaceId: String,
        rows: List<CachedProjectEntity>,
    ) {
        if (rows.isEmpty()) {
            deleteAllProjectChatsFor(userId, workspaceId)
        } else {
            deleteProjectChatsForMissing(userId, workspaceId, rows.map { it.projectId })
        }
        replaceProjects(userId, workspaceId, rows)
    }

    /** Every chat in this workspace, for the "this workspace has no projects" case. */
    @Query(
        """
        DELETE FROM cached_project_chats
        WHERE user_id = :userId AND workspace_id = :workspaceId
        """,
    )
    abstract fun deleteAllProjectChatsFor(
        userId: String,
        workspaceId: String,
    )

    /**
     * Delete the chats of every project not in [keepProjectIds]. Callers pass a
     * non-empty list; see [deleteChatsForWorkspace] for why the empty case does
     * not come through here.
     */
    @Query(
        """
        DELETE FROM cached_project_chats
        WHERE user_id = :userId
          AND workspace_id = :workspaceId
          AND project_id NOT IN (:keepProjectIds)
        """,
    )
    abstract fun deleteProjectChatsForMissing(
        userId: String,
        workspaceId: String,
        keepProjectIds: List<String>,
    )

    @Query("DELETE FROM cached_projects")
    abstract fun deleteAllProjects()

    @Query("DELETE FROM cached_project_chats")
    abstract fun deleteAllProjectChats()

    /** Sign-out purge, in one transaction. */
    @Transaction
    open fun clearAll() {
        deleteAllProjects()
        deleteAllProjectChats()
    }
}
