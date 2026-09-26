package com.nalar.mobile.testing

import com.nalar.mobile.chat.CachedChatMessage
import com.nalar.mobile.chat.ChatCache
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.RecentsCache
import com.nalar.mobile.recents.WorkspaceOption

/**
 * In-memory stand-ins for the three caches, for the ViewModel tests.
 *
 * These are not stubs that return null and let a test pass by accident — each
 * one reimplements the same rules the Room caches do, so a ViewModel test that
 * passes here is testing the ViewModel and not the absence of a cache:
 *
 * - a null or blank `userId` is a **miss**, never an unscoped read;
 * - a transcript write is a **merge** that replaces a same-id row;
 * - a transcript read is **newest-first and capped**;
 * - a sidebar write **replaces** its partition, so a row deleted upstream stays
 *   deleted;
 * - server order is preserved verbatim, because that is what the endpoint sent.
 *
 * Those rules are the *contract*; `RoomChatCacheTest`, `RoomRecentsCacheTest`
 * and `RoomAuthMeCacheTest` are what prove SQLite honours them. Keeping the two
 * in step is the point of writing them in one file.
 */
class InMemoryChatCache : ChatCache {
    private val rows = mutableMapOf<String, MutableMap<String, CachedChatMessage>>()
    private val cursors = mutableMapOf<String, String>()

    var cleared = false
        private set

    override fun readMessages(
        userId: String?,
        sessionId: String,
        limit: Int,
    ): List<CachedChatMessage>? {
        val rows = rows[key(userId, sessionId)] ?: return null
        return rows.values
            .sortedWith(
                compareByDescending<CachedChatMessage> { it.sortKeyNanos }
                    .thenByDescending { it.id },
            )
            .take(limit.coerceAtLeast(1))
    }

    override fun writeMessages(
        userId: String?,
        sessionId: String,
        messages: List<CachedChatMessage>,
    ) {
        if (messages.isEmpty()) return
        val bucket = rows.getOrPut(key(userId, sessionId) ?: return) { mutableMapOf() }
        messages.forEach { bucket[it.id] = it }
    }

    override fun readCursor(userId: String?, sessionId: String): String? =
        cursors[key(userId, sessionId)]

    override fun writeCursor(userId: String?, sessionId: String, cursor: String?) {
        val key = key(userId, sessionId) ?: return
        if (cursor.isNullOrBlank()) cursors.remove(key) else cursors[key] = cursor
    }

    override fun clear() {
        cleared = true
        rows.clear()
        cursors.clear()
    }

    private fun key(userId: String?, sessionId: String): String? {
        val user = userId?.takeIf { it.isNotBlank() } ?: return null
        if (sessionId.isBlank()) return null
        return "$user::$sessionId"
    }
}

class InMemoryRecentsCache : RecentsCache {
    private val workspaces = mutableMapOf<String, List<WorkspaceOption>>()
    private val chats = mutableMapOf<String, List<ChatSummary>>()

    var cleared = false
        private set

    override fun readWorkspaces(userId: String?): List<WorkspaceOption>? =
        workspaces[userKey(userId)]

    override fun writeWorkspaces(userId: String?, value: List<WorkspaceOption>) {
        workspaces[userKey(userId) ?: return] = value
    }

    override fun readChats(userId: String?, workspaceId: String): List<ChatSummary>? =
        chats[chatsKey(userId, workspaceId)]

    override fun writeChats(userId: String?, workspaceId: String, value: List<ChatSummary>) {
        chats[chatsKey(userId, workspaceId) ?: return] = value
    }

    override fun clear() {
        cleared = true
        workspaces.clear()
        chats.clear()
    }

    private fun userKey(userId: String?): String? = userId?.takeIf { it.isNotBlank() }

    private fun chatsKey(userId: String?, workspaceId: String): String? {
        val user = userKey(userId) ?: return null
        if (workspaceId.isBlank()) return null
        return "$user::$workspaceId"
    }
}
