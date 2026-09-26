package com.nalar.mobile.recents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wire contract, pinned. These payloads are copied from what
 * `workspaces_list.zig` and `buildSessionListJson` actually emit — the point is
 * that a rename on the backend shows up here as a failing test rather than as a
 * silently empty sidebar on a phone.
 */
class RecentsApiTest {

    @Test
    fun parseWorkspacesReadsIdsAndNamesFromTheRealPayload() {
        val body = """
            {"workspaces":[
              {"id":"item_1785055824163739523","name":"Sprint bulan Juni",
               "created_at":"2026-06-01 10:00:00","updated_at":"2026-09-20 08:00:00",
               "icon":"📁","items":[],"expanded":false,"items_count":4},
              {"id":"item_1789230913466053543","name":"Kabelweb",
               "created_at":"2026-07-02 11:00:00","updated_at":null,
               "icon":"📁","items":[],"expanded":false,"items_count":0}
            ]}
        """.trimIndent()

        val workspaces = RecentsApi.parseWorkspaces(body)

        assertEquals(2, workspaces.size)
        assertEquals("item_1785055824163739523", workspaces[0].id)
        assertEquals("Sprint bulan Juni", workspaces[0].name)
        assertEquals("item_1789230913466053543", workspaces[1].id)
        assertEquals("Kabelweb", workspaces[1].name)
    }

    @Test
    fun parseWorkspacesSkipsRowsWithoutAnId() {
        // An idless row cannot be scoped to, so it must not reach the dropdown.
        val body = """{"workspaces":[{"id":"","name":"Ghost"},{"id":"ws_real","name":"Real"}]}"""

        val workspaces = RecentsApi.parseWorkspaces(body)

        assertEquals(listOf("ws_real"), workspaces.map { it.id })
    }

    @Test
    fun parseWorkspacesOnEmptyListYieldsEmptySidebar() {
        assertEquals(emptyList<WorkspaceOption>(), RecentsApi.parseWorkspaces("""{"workspaces":[]}"""))
    }

    @Test
    fun parseChatsMapsSessionIdAndName() {
        val body = """
            {"sessions":[
              {"session_id":"task_1790399241151_1","cwd":"/home/ginwa/ginwaaitoolbox",
               "created_at":"2026-09-26 05:07:34","updated_at":"2026-09-26 05:12:37",
               "agent":"code-reviewer","session_name":"the mobile still mock the data ?",
               "selected_profile_model":"gpt-5","is_auto_retry_until_stop":"",
               "last_finish_reason":"","last_human_touched_at":"",
               "git_worktree_cwd":"","git_branch":""}
            ],"total":1,"has_more":false,"next_cursor":null}
        """.trimIndent()

        val chats = RecentsApi.parseChats(body, workspaceId = "ws_1")

        assertEquals(1, chats.size)
        assertEquals("task_1790399241151_1", chats[0].id)
        // The scoped response never echoes the workspace back.
        assertEquals("ws_1", chats[0].workspaceId)
        assertEquals("the mobile still mock the data ?", chats[0].displayTitle)
    }

    @Test
    fun parseChatsPrefersLastHumanTouchedOverUpdatedAt() {
        val body = sessionJson(
            lastHumanTouched = "2026-09-26 05:07:34",
            updated = "2026-09-26 05:12:37",
        )

        val chat = RecentsApi.parseChats(body, "ws_1").single()

        // An unattended run keeps moving updated_at; the human-touched stamp is
        // what the sidebar should show.
        assertEquals(1_790_399_254_000L, chat.updatedAtEpochMillis)
    }

    @Test
    fun parseChatsFallsBackToUpdatedAtWhenHumanTouchedIsEmpty() {
        val body = sessionJson(
            lastHumanTouched = "",
            updated = "2026-09-26 05:12:37",
        )

        val chat = RecentsApi.parseChats(body, "ws_1").single()

        assertEquals(1_790_399_557_000L, chat.updatedAtEpochMillis)
    }

    @Test
    fun parseChatsFallsBackToCreatedAtWhenBothStampsAreEmpty() {
        val body = sessionJson(
            lastHumanTouched = "",
            updated = "",
            created = "2026-09-20 08:00:00",
        )

        val chat = RecentsApi.parseChats(body, "ws_1").single()

        assertTrue(chat.hasTimestamp)
        // Never the epoch: a "56y" label on a chat from last week is a lie.
        assertEquals(1_789_891_200_000L, chat.updatedAtEpochMillis)
    }

    @Test
    fun parseChatsWithNoUsableTimestampIsMarkedAsUnknownRatherThanEpoch() {
        val body = sessionJson(
            lastHumanTouched = "",
            updated = "",
            created = "",
        )

        val chat = RecentsApi.parseChats(body, "ws_1").single()

        assertEquals(RecentsApi.UNKNOWN_TIMESTAMP, chat.updatedAtEpochMillis)
        assertEquals(false, chat.hasTimestamp)
    }

    @Test
    fun parseChatsWithBlankSessionNameFallsBackToNewChat() {
        val body = sessionJson(sessionName = "   ")

        assertEquals("New Chat", RecentsApi.parseChats(body, "ws_1").single().displayTitle)
    }

    @Test
    fun parseChatsOnEmptyListYieldsNoRows() {
        val body = """{"sessions":[],"total":0,"has_more":false,"next_cursor":null}"""

        assertEquals(emptyList<ChatSummary>(), RecentsApi.parseChats(body, "ws_1"))
    }

    @Test
    fun chatsPathScopesToTheWorkspaceAndAsksForNewestFirst() {
        val path = RecentsApi.chatsPath("item_1785055824163739523")

        assertTrue(path, path.startsWith("/api/session?"))
        assertTrue(path, path.contains("sort_by=updated_at"))
        assertTrue(path, path.contains("direction=desc"))
        assertTrue(path, path.contains("limit=${RecentsApi.CHATS_PAGE_LIMIT}"))
        assertTrue(path, path.contains("workspace_id=item_1785055824163739523"))
    }

    @Test
    fun chatsPathEncodesAWorkspaceIdWithQueryUnsafeCharacters() {
        val path = RecentsApi.chatsPath("ws a&b")

        // Unencoded, the '&' would start a second query parameter and silently
        // scope the list to the wrong (or no) workspace.
        assertTrue(path, path.contains("workspace_id=ws+a%26b"))
    }

    @Test
    fun workspacesPathSkipsItemsToKeepTheSidebarPayloadSmall() {
        assertEquals(
            "/api/workspaces?is_include_items=false",
            RecentsApi.WORKSPACES_PATH,
        )
    }

    @Test
    fun parseTimestampEpochMillisReadsSqliteDatetimeAsUtc() {
        // 2026-09-26 05:07:34 UTC. The absolute value is the assertion: parsing
        // this as device-local time would shift every sidebar label by the
        // device's offset, which a "looks about right" test would not catch.
        assertEquals(
            1_790_399_254_000L,
            RecentsApi.parseTimestampEpochMillis("2026-09-26 05:07:34"),
        )
    }

    @Test
    fun parseTimestampEpochMillisAcceptsTheIsoSeparator() {
        assertEquals(
            1_790_399_254_000L,
            RecentsApi.parseTimestampEpochMillis("2026-09-26T05:07:34"),
        )
    }

    @Test
    fun parseTimestampEpochMillisAcceptsTheUnixMillisShapeSseEmits() {
        assertEquals(
            1_790_399_254_000L,
            RecentsApi.parseTimestampEpochMillis("1790399254000"),
        )
    }

    @Test
    fun parseTimestampEpochMillisReturnsNullForMissingAndGarbageValues() {
        assertNull(RecentsApi.parseTimestampEpochMillis(null))
        assertNull(RecentsApi.parseTimestampEpochMillis(""))
        assertNull(RecentsApi.parseTimestampEpochMillis("   "))
        assertNull(RecentsApi.parseTimestampEpochMillis("not a date"))
        assertNull(RecentsApi.parseTimestampEpochMillis("2026-09-26"))
        // SQLite's COALESCE can hand back the string "null" for a NULL column.
        assertNull(RecentsApi.parseTimestampEpochMillis("null"))
    }

    @Test
    fun parseTimestampEpochMillisRejectsCalendarInvalidDates() {
        assertNull(RecentsApi.parseTimestampEpochMillis("2026-02-31 00:00:00"))
        assertNull(RecentsApi.parseTimestampEpochMillis("2026-13-01 00:00:00"))
    }

    private fun sessionJson(
        sessionName: String = "A chat",
        created: String = "2026-09-26 05:07:34",
        updated: String = "2026-09-26 05:12:37",
        lastHumanTouched: String = "2026-09-26 05:07:34",
    ): String = """
        {"sessions":[{"session_id":"task_1","cwd":"/tmp",
         "created_at":"$created","updated_at":"$updated",
         "agent":"code-reviewer","session_name":"$sessionName",
         "last_human_touched_at":"$lastHumanTouched"}],
        "total":1,"has_more":false,"next_cursor":null}
    """.trimIndent()
}
