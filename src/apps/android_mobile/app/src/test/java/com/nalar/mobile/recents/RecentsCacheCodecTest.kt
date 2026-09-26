package com.nalar.mobile.recents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cache's pure half. The bugs that matter here are user isolation (one
 * account seeing another's rows) and corrupt-payload handling, so both are
 * driven directly rather than left to the Android storage layer.
 */
class RecentsCacheCodecTest {

    @Test
    fun workspacesRoundTrip() {
        val workspaces = listOf(
            WorkspaceOption("ws_1", "Sprint bulan Juni"),
            WorkspaceOption("ws_2", "Kabelweb"),
        )

        val decoded = RecentsCacheCodec.decodeWorkspaces(
            RecentsCacheCodec.encodeWorkspaces(workspaces),
        )

        assertEquals(workspaces, decoded)
    }

    @Test
    fun chatsRoundTripIncludingTheUnknownTimestampSentinel() {
        val chats = listOf(
            ChatSummary("task_1", "ws_1", "the mobile still mock the data ?", 1_790_399_254_000L),
            // No parseable timestamp: the sentinel must survive the round trip
            // or the row would come back looking decades old.
            ChatSummary("task_2", "ws_1", "", RecentsApi.UNKNOWN_TIMESTAMP),
        )

        val decoded = RecentsCacheCodec.decodeChats(RecentsCacheCodec.encodeChats(chats))

        assertEquals(chats, decoded)
        assertEquals(false, decoded!![1].hasTimestamp)
    }

    @Test
    fun aUsersKeysAreDistinctFromAnothers() {
        // The whole point of namespacing: B must never be able to address A's
        // namespace, because that is what `useAnotherAccount()` leaves behind.
        assertNotEquals(
            RecentsCacheCodec.workspacesKey("user_a"),
            RecentsCacheCodec.workspacesKey("user_b"),
        )
        assertNotEquals(
            RecentsCacheCodec.chatsKey("user_a", "ws_1"),
            RecentsCacheCodec.chatsKey("user_b", "ws_1"),
        )
        // And the user id must not be forgeable by a crafted workspace id.
        assertNotEquals(
            RecentsCacheCodec.chatsKey("user_a", "ws_1"),
            RecentsCacheCodec.chatsKey("user_a::u:user_b", "ws_1"),
        )
    }

    @Test
    fun chatsAreKeyedPerWorkspaceWithinAUser() {
        assertNotEquals(
            RecentsCacheCodec.chatsKey("user_a", "ws_1"),
            RecentsCacheCodec.chatsKey("user_a", "ws_2"),
        )
    }

    @Test
    fun keysCarryTheUserIdInPlainSight() {
        val key = RecentsCacheCodec.workspacesKey("user_a")!!

        assertTrue(key, key.contains("user_a"))
        assertTrue(key, key.startsWith("workspaces"))
    }

    @Test
    fun corruptPayloadsDecodeAsAMissRatherThanPartialData() {
        val garbage = listOf(
            null,
            "",
            "not json at all",
            "[]",
            """{"workspaces":"nope"}""",
            """{"chats":"nope"}""",
            "{\"workspaces\":[",
        )

        garbage.forEach { payload ->
            assertNull("workspaces should miss on: $payload", RecentsCacheCodec.decodeWorkspaces(payload))
            assertNull("chats should miss on: $payload", RecentsCacheCodec.decodeChats(payload))
        }
    }

    @Test
    fun aRowWithoutAnIdInvalidatesTheWholePayload() {
        // A half-trustworthy list is worse than no list: the undropped rows
        // would paint while the id-less ones silently vanish.
        val payload = """{"workspaces":[{"id":"ws_1","name":"Keep"},{"id":"","name":"Ghost"}]}"""

        assertNull(RecentsCacheCodec.decodeWorkspaces(payload))
    }

    @Test
    fun aChatRowWithoutAnIdOrWorkspaceInvalidatesTheWholePayload() {
        assertNull(
            RecentsCacheCodec.decodeChats("""{"chats":[{"id":"","workspaceId":"ws_1"}]}"""),
        )
        assertNull(
            RecentsCacheCodec.decodeChats("""{"chats":[{"id":"task_1","workspaceId":""}]}"""),
        )
    }

    @Test
    fun anEmptyListIsAValidHitNotAMiss() {
        // Distinguishing "cached: you have no workspaces" from "no cache" is
        // what lets the sidebar show an honest empty state offline.
        assertEquals(
            emptyList<WorkspaceOption>(),
            RecentsCacheCodec.decodeWorkspaces(RecentsCacheCodec.encodeWorkspaces(emptyList())),
        )
        assertEquals(
            emptyList<ChatSummary>(),
            RecentsCacheCodec.decodeChats(RecentsCacheCodec.encodeChats(emptyList())),
        )
    }

    @Test
    fun anAbsentUserIdCannotBeExpressedAsAKeyAtAll() {
        // Stricter than the desktop's `userScopedKey`, which falls back to an
        // UNSCOPED key when identity is unresolved. On a phone that fallback is
        // exactly the case where one account's rows leak to the next, so the
        // no-identity case is unrepresentable rather than merely discouraged —
        // callers have nothing to cache under.
        assertNull(RecentsCacheCodec.workspacesKey(null))
        assertNull(RecentsCacheCodec.chatsKey(null, "ws_1"))

        // A blank id is as unusable as a null one.
        assertNull(RecentsCacheCodec.workspacesKey(""))
        assertNull(RecentsCacheCodec.workspacesKey("   "))
        assertNull(RecentsCacheCodec.chatsKey("   ", "ws_1"))
    }

    @Test
    fun aBlankWorkspaceIdCannotBeKeyed() {
        assertNull(RecentsCacheCodec.chatsKey("user_a", ""))
        assertNull(RecentsCacheCodec.chatsKey("user_a", "  "))
    }
}
