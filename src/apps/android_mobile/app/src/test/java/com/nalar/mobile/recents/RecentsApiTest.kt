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

    @Test
    fun chatsPathCarriesTheCursorSoTheNextPageCanBeAskedFor() {
        val path = RecentsApi.chatsPath("ws_1", cursor = "2026-09-26 05:12:37")

        // The space has to be encoded or the query parser truncates the cursor
        // at the first space and pages from the wrong position.
        assertTrue(path, path.contains("cursor=2026-09-26+05%3A12%3A37"))
    }

    @Test
    fun chatsPathOmitsTheCursorForTheFirstPageAndForABlankOne() {
        // A blank cursor is indistinguishable from "no cursor" to the server,
        // which would restart the list at page 1 and re-serve what is on screen.
        assertTrue(!RecentsApi.chatsPath("ws_1").contains("cursor="))
        assertTrue(!RecentsApi.chatsPath("ws_1", cursor = null).contains("cursor="))
        assertTrue(!RecentsApi.chatsPath("ws_1", cursor = "   ").contains("cursor="))
    }

    @Test
    fun chatsPathClampsThePageSize() {
        val path = RecentsApi.chatsPath("ws_1", limit = 0)

        // limit=0 would be parsed server-side as a fallback to 50, which is not
        // what the caller asked for and not something to discover at runtime.
        assertTrue(path, path.contains("&limit=1&"))
    }

    @Test
    fun parseChatsPageReadsTheScrollStateFromTheRealEnvelope() {
        val body = """
            {"sessions":[
              {"session_id":"task_1","session_name":"Newest","updated_at":"2026-09-26 05:12:37"},
              {"session_id":"task_2","session_name":"Older","updated_at":"2026-09-25 09:00:00"}
            ],"total":57,"has_more":true,"next_cursor":"2026-09-25 09:00:00"}
        """.trimIndent()

        val page = RecentsApi.parseChatsPage(body, "ws_1")

        assertEquals(listOf("task_1", "task_2"), page.chats.map { it.id })
        assertTrue(page.hasMore)
        assertEquals("2026-09-25 09:00:00", page.nextCursor)
        assertEquals(57, page.total)
    }

    @Test
    fun parseChatsPageStopsOnTotalEvenWhenTheServerStillSaysHasMore() {
        // `has_more` is `len == limit`, so a final page that happens to be
        // exactly full reports true. Without the `total` backstop the sidebar
        // would spend one more round-trip to be told the same thing.
        val body = """
            {"sessions":[
              {"session_id":"task_1","updated_at":"2026-09-26 05:12:37"},
              {"session_id":"task_2","updated_at":"2026-09-25 09:00:00"}
            ],"total":2,"has_more":true,"next_cursor":"2026-09-25 09:00:00"}
        """.trimIndent()

        val page = RecentsApi.parseChatsPage(body, "ws_1")

        assertEquals(false, page.hasMore)
    }

    @Test
    fun parseChatsPageStillTrustsHasMoreWhenTheServerSendsNoTotal() {
        // An older server that omits `total` reports 0. Reading that as "we have
        // them all" would silently truncate every list to its first page.
        val body = """
            {"sessions":[{"session_id":"task_1","updated_at":"2026-09-26 05:12:37"}],
             "has_more":true,"next_cursor":"2026-09-26 05:12:37"}
        """.trimIndent()

        val page = RecentsApi.parseChatsPage(body, "ws_1")

        assertTrue(page.hasMore)
        assertEquals(0, page.total)
    }

    @Test
    fun parseChatsPageTreatsABlankOrNullCursorAsAbsent() {
        // A blank cursor would be dropped from the query, which silently
        // restarts the list at page 1 — duplicates instead of older chats.
        assertNull(
            RecentsApi.parseChatsPage(
                """{"sessions":[],"total":0,"has_more":false,"next_cursor":"  "}""",
                "ws_1",
            ).nextCursor,
        )
        assertNull(
            RecentsApi.parseChatsPage(
                """{"sessions":[],"total":0,"has_more":false,"next_cursor":null}""",
                "ws_1",
            ).nextCursor,
        )
    }

    @Test
    fun parseChatsPageKeepsACursorEvenWhenItIsTheLastPage() {
        // The server emits `next_cursor` whenever the page was non-empty, so a
        // non-null cursor says nothing about there being more. `has_more` is
        // the only terminator and this pins that they are read independently.
        val body = """
            {"sessions":[{"session_id":"task_1","updated_at":"2026-09-26 05:12:37"}],
             "total":1,"has_more":false,"next_cursor":"2026-09-26 05:12:37"}
        """.trimIndent()

        val page = RecentsApi.parseChatsPage(body, "ws_1")

        assertEquals(false, page.hasMore)
        assertEquals("2026-09-26 05:12:37", page.nextCursor)
    }

    @Test
    fun mergeChatsByIdDropsRowsTheSidebarAlreadyShows() {
        // A session touched between pages moves up the ordering, so a page
        // boundary can legitimately hand back a row already on screen. Two rows
        // for one chat would both be selectable and look like a rendering bug.
        val current = listOf(
            ChatSummary("task_1", "ws_1", "First", 2_000L),
            ChatSummary("task_2", "ws_1", "Second", 1_000L),
        )
        val incoming = listOf(
            ChatSummary("task_2", "ws_1", "Second, renamed", 1_000L),
            ChatSummary("task_3", "ws_1", "Third", 500L),
        )

        val merged = RecentsApi.mergeChatsById(current, incoming)

        assertEquals(listOf("task_1", "task_2", "task_3"), merged.map { it.id })
        // A same-id row is replaced, not skipped: a renamed chat must show the
        // new name, and the merge must not leave two competing rows.
        assertEquals("Second, renamed", merged[1].title)
    }

    @Test
    fun mergeChatsByIdWithNothingIncomingReturnsTheSameRows() {
        val current = listOf(ChatSummary("task_1", "ws_1", "Only", 1_000L))

        assertEquals(current, RecentsApi.mergeChatsById(current, emptyList()))
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
