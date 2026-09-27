package com.nalar.mobile.recents

import com.nalar.mobile.testing.InMemoryProjectsCache
import com.nalar.mobile.projects.ProjectsClient
import com.nalar.mobile.auth.AuthHttpResponse
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.auth.SessionStore
import com.nalar.mobile.storage.LastPositionStore
import com.nalar.mobile.testing.InMemoryLastPositionStore
import com.nalar.mobile.testing.InMemoryRecentsCache
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The scroll's contract at the ViewModel level: one page per request, appended
 * in order, stopped on the server's word rather than on an assumption.
 *
 * Main and IO run on SEPARATE schedulers, for the same reason as
 * [HomeViewModelCacheTest] — on a single scheduler the fetch completes inline
 * and the "still in flight" assertions become untestable.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelPaginationTest {

    private class Schedulers {
        val main = TestCoroutineScheduler()
        val io = TestCoroutineScheduler()
        val mainDispatcher = StandardTestDispatcher(main)
        val ioDispatcher = StandardTestDispatcher(io)

        fun drain() {
            repeat(20) {
                main.advanceUntilIdle()
                io.advanceUntilIdle()
            }
        }

        /**
         * Runs the request to the point where it is genuinely in flight: the
         * IO scheduler has started the call but has not been advanced to
         * deliver the response.
         */
        fun startButDoNotFinish() {
            main.advanceUntilIdle()
        }
    }

    private fun paginationTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
        val schedulers = Schedulers()
        Dispatchers.setMain(schedulers.mainDispatcher)
        try {
            body(schedulers)
        } finally {
            Dispatchers.resetMain()
        }
    }

    private class MemorySessionStore(var value: String? = "tok") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    /**
     * Serves scripted pages for `/api/session` and records what each request
     * asked for, so the resume position is assertable rather than assumed.
     *
     * Pages are indexed *per workspace* — a test that switches workspaces
     * would otherwise get workspace B's script replayed for A.
     */
    private class PagedTransport(
        private val pagesByWorkspace: Map<String, List<String>> = emptyMap(),
        private val workspaces: String =
            """{"workspaces":[{"id":"ws_1","name":"One"}]}""",
    ) : AuthTransport {
        var offline = false
        val requestedCursors = mutableListOf<String?>()
        val requestedWorkspaces = mutableListOf<String?>()
        var chatsRequests = 0

        private val servedPerWorkspace = mutableMapOf<String, Int>()

        override fun post(path: String, body: String, headers: Map<String, String>) =
            error("read-only")

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            if (path.startsWith(RecentsApi.WORKSPACES_PATH)) {
                return AuthHttpResponse(statusCode = 200, body = workspaces)
            }

            chatsRequests++
            val workspaceId = workspaceIdOf(path)
            requestedWorkspaces += workspaceId
            requestedCursors += path.substringAfter("cursor=", "")
                .takeIf { path.contains("cursor=") }

            val script = pagesByWorkspace[workspaceId].orEmpty()
            val index = servedPerWorkspace.getOrDefault(workspaceId, 0)
            servedPerWorkspace[workspaceId] = index + 1
            // Fall back to the last page so a test that scrolls once more than
            // scripted gets a stable answer instead of an exception.
            val body = script.getOrNull(index) ?: script.lastOrNull().orEmpty()
            return AuthHttpResponse(statusCode = 200, body = body)
        }

        private fun workspaceIdOf(path: String): String =
            path.substringAfter("workspace_id=", "").substringBefore("&")
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        transport: PagedTransport,
        cache: RecentsCache = InMemoryRecentsCache(),
        positionStore: LastPositionStore = InMemoryLastPositionStore(),
    ) = HomeViewModel(
        client = RecentsClient(MemorySessionStore(), httpTransport = transport),
        cache = cache,
        // The projects section has no say in these tests, so it gets a
        // client that answers nothing and a cache that answers nothing —
        // which is what keeps an unrelated project fetch from showing up
        // as a second request these tests would then have to account for.
        projectsClient = ProjectsClient(MemorySessionStore()),
        projectsCache = InMemoryProjectsCache(),
        positionStore = positionStore,
        ioDispatcher = ioDispatcher,
    )

    private fun page(
        ids: List<String>,
        hasMore: Boolean,
        nextCursor: String?,
        total: Int,
    ): String {
        val rows = ids.joinToString(",") { id ->
            """{"session_id":"$id","session_name":"Chat $id","updated_at":"2026-09-26 05:12:37"}"""
        }
        val cursor = nextCursor?.let { "\"$it\"" } ?: "null"
        return """{"sessions":[$rows],"total":$total,"has_more":$hasMore,"next_cursor":$cursor}"""
    }

    @Test
    fun scrollingToTheBottomAppendsTheNextPage() = paginationTest { s ->
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1", "c2"), hasMore = true, nextCursor = "cur-1", total = 4),
                    page(listOf("c3", "c4"), hasMore = false, nextCursor = "cur-2", total = 4),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        assertEquals(listOf("c1", "c2"), model.uiState.value.chats.map { it.id })
        assertTrue(model.uiState.value.hasMoreChats)

        model.loadMoreChats()
        s.drain()

        // The point of the feature: older chats arrive on their own.
        assertEquals(listOf("c1", "c2", "c3", "c4"), model.uiState.value.chats.map { it.id })
        // Page 2 must resume from page 1's cursor rather than restart the list.
        assertEquals(listOf(null, "cur-1"), transport.requestedCursors)
        assertFalse(model.uiState.value.hasMoreChats)
    }

    @Test
    fun aSecondScrollAsksForTheThirdPage() = paginationTest { s ->
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1"), hasMore = true, nextCursor = "cur-1", total = 3),
                    page(listOf("c2"), hasMore = true, nextCursor = "cur-2", total = 3),
                    page(listOf("c3"), hasMore = false, nextCursor = "cur-3", total = 3),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        model.loadMoreChats()
        s.drain()
        model.loadMoreChats()
        s.drain()

        assertEquals(listOf("c1", "c2", "c3"), model.uiState.value.chats.map { it.id })
        assertEquals(listOf(null, "cur-1", "cur-2"), transport.requestedCursors)
    }

    @Test
    fun scrollingStopsOnceTheServerSaysThereIsNoMore() = paginationTest { s ->
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1"), hasMore = false, nextCursor = "cur-1", total = 1),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        // `next_cursor` is still set — the server emits one whenever a page is
        // non-empty — so this is the assertion that `has_more`, not a
        // non-null cursor, is what ends the list.
        assertFalse(model.uiState.value.hasMoreChats)
        assertFalse(model.uiState.value.canLoadMoreChats)

        model.loadMoreChats()
        s.drain()

        assertEquals(1, transport.chatsRequests)
    }

    @Test
    fun nothingIsRequestedBeforeTheFirstPageHasLanded() = paginationTest { s ->
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1"), hasMore = true, nextCursor = "cur-1", total = 9),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")

        // Still loading: the scroll may already be at the bottom of an empty
        // list, and paging from here would append onto nothing.
        model.loadMoreChats()
        s.drain()

        assertEquals(1, transport.chatsRequests)
        assertEquals(listOf("c1"), model.uiState.value.chats.map { it.id })
    }

    @Test
    fun aPageThatRepeatsRowsOnesAlreadyShownEndsTheScroll() = paginationTest { s ->
        // A server that keeps replaying the same window would otherwise put the
        // sidebar into an unbounded fetch loop against a cursor that never
        // advances. The dedupe means the page adds nothing, so the scroll stops.
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1", "c2"), hasMore = true, nextCursor = "cur-1", total = 99),
                    page(listOf("c1", "c2"), hasMore = true, nextCursor = "cur-1", total = 99),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        model.loadMoreChats()
        s.drain()

        assertEquals(listOf("c1", "c2"), model.uiState.value.chats.map { it.id })
        assertFalse("a no-op page must end the scroll", model.uiState.value.hasMoreChats)

        // And it stays ended: no further requests on a subsequent scroll.
        model.loadMoreChats()
        s.drain()
        assertEquals(2, transport.chatsRequests)
    }

    @Test
    fun aRowThatOverlapsThePreviousPageIsNotDuplicated() = paginationTest { s ->
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1", "c2"), hasMore = true, nextCursor = "cur-1", total = 4),
                    page(listOf("c2", "c3"), hasMore = false, nextCursor = "cur-2", total = 4),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        model.loadMoreChats()
        s.drain()

        // A session touched between pages moves up the ordering, so the page
        // boundary can hand back a row already on screen. Two rows for one chat
        // would both be tappable and read as a rendering bug.
        assertEquals(listOf("c1", "c2", "c3"), model.uiState.value.chats.map { it.id })
    }

    @Test
    fun aFailedPageKeepsTheRowsOnScreenAndAllowsARetry() = paginationTest { s ->
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1", "c2"), hasMore = true, nextCursor = "cur-1", total = 4),
                    page(listOf("c3"), hasMore = false, nextCursor = "cur-2", total = 4),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        transport.offline = true
        model.loadMoreChats()
        s.drain()

        val state = model.uiState.value
        // Blanking a working sidebar, or silently ending the list, would both be
        // worse than a page that did not arrive.
        assertEquals(listOf("c1", "c2"), state.chats.map { it.id })
        assertFalse(state.isLoadingMoreChats)
        assertTrue("a failed page must be retryable", state.hasMoreChats)

        transport.offline = false
        model.loadMoreChats()
        s.drain()

        assertEquals(listOf("c1", "c2", "c3"), model.uiState.value.chats.map { it.id })
    }

    @Test
    fun theScrollStopsOnceTheAccumulatedListCoversTheServersCount() = paginationTest { s ->
        // Belt and braces for the case the parser cannot see: `total` is the
        // full filtered count, but each page is judged against it on its own,
        // so a page that fills the remainder still reports has_more=true. Only
        // the accumulated list knows the count has been reached.
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1", "c2"), hasMore = true, nextCursor = "cur-1", total = 4),
                    page(listOf("c3", "c4"), hasMore = true, nextCursor = "cur-2", total = 4),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()
        model.loadMoreChats()
        s.drain()

        // Four rows held, against a `total` of four, yet the server still says
        // there is more.
        assertEquals(4, model.uiState.value.chats.size)
        assertEquals(4, model.uiState.value.chatsTotal)
        assertTrue(model.uiState.value.hasMoreChats)
        assertFalse(
            "holding every row the server counted must end the scroll",
            model.uiState.value.canLoadMoreChats,
        )

        model.loadMoreChats()
        s.drain()

        assertEquals("no third request against an exhausted list", 2, transport.chatsRequests)
    }

    @Test
    fun switchingWorkspaceDiscardsTheOtherWorkspacesRecentsAndCursor() = paginationTest { s ->
        val transport = PagedTransport(
            workspaces = """{"workspaces":[
                {"id":"ws_1","name":"One"},{"id":"ws_2","name":"Two"}]}""",
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(page(listOf("a1"), hasMore = true, nextCursor = "ws1-cur", total = 9)),
                "ws_2" to listOf(page(listOf("b1"), hasMore = true, nextCursor = "ws2-cur", total = 9)),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()
        assertEquals(listOf("a1"), model.uiState.value.chats.map { it.id })

        model.selectWorkspace("ws_2")
        s.drain()

        val state = model.uiState.value
        assertEquals("ws_2", state.selectedWorkspaceId)
        // ws_1's rows must not survive into ws_2's list.
        assertEquals(listOf("b1"), state.chats.map { it.id })
        assertEquals("ws_2", state.chats.single().workspaceId)

        // ws_1's cursor must not page ws_2 from a position in ws_1's history:
        // the very first ws_2 request has to carry no cursor at all.
        val ws2Cursors = transport.requestedCursors
            .zip(transport.requestedWorkspaces)
            .filter { (_, workspaceId) -> workspaceId == "ws_2" }
            .map { (cursor, _) -> cursor }
        assertEquals(listOf(null), ws2Cursors)
    }

    @Test
    fun signingOutCancelsAPageInFlight() = paginationTest { s ->
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(page(listOf("c1"), hasMore = true, nextCursor = "cur-1", total = 9)),
            ),
        )
        val cache = InMemoryRecentsCache()
        val model = model(s.ioDispatcher, transport, cache)
        model.onUserChanged("user_a")
        s.drain()

        model.loadMoreChats()
        // The request is issued but the response has not been delivered.
        s.startButDoNotFinish()
        model.onSignedOut()
        s.drain()

        // A page belonging to the session that just ended must not repopulate a
        // signed-out sidebar.
        assertTrue(model.uiState.value.chats.isEmpty())
        assertTrue(cache.cleared)
    }

    @Test
    fun aRefreshResetsTheScrollBackToTheFirstPage() = paginationTest { s ->
        val transport = PagedTransport(
            pagesByWorkspace = mapOf(
                "ws_1" to listOf(
                    page(listOf("c1", "c2"), hasMore = true, nextCursor = "cur-1", total = 4),
                    page(listOf("c3"), hasMore = false, nextCursor = "cur-2", total = 4),
                    page(listOf("c1", "c2"), hasMore = true, nextCursor = "cur-1", total = 4),
                ),
            ),
        )
        val model = model(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()
        model.loadMoreChats()
        s.drain()
        assertEquals(3, model.uiState.value.chats.size)

        model.refresh()
        s.drain()

        // Pages the user had scrolled in are cut: a reload re-fetches page 1 and
        // pages forward again, so keeping them would resurrect deleted chats.
        assertEquals(listOf("c1", "c2"), model.uiState.value.chats.map { it.id })
        assertEquals(null, transport.requestedCursors.last())
    }
}
