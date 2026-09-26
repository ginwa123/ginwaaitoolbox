package com.nalar.mobile.recents

import com.nalar.mobile.auth.AuthHttpResponse
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.auth.SessionStore
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
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stale-while-revalidate contract at the ViewModel level.
 *
 * The cache contract is about ORDERING: paint from cache, then revalidate. A
 * synchronous unit test cannot observe the intermediate state users actually
 * see — which is precisely the state that makes a cache worth having.
 *
 * Main and IO run on SEPARATE schedulers, mirroring the device. On a single
 * scheduler the fetch completes inline inside `onUserChanged` (the test body is
 * already on that dispatcher, so `withContext` never suspends), and the
 * "painted before the network answered" assertion becomes untestable. With two
 * schedulers the fetch is genuinely pending until drained.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelCacheTest {

    private class Schedulers {
        val main = TestCoroutineScheduler()
        val io = TestCoroutineScheduler()
        val mainDispatcher = StandardTestDispatcher(main)
        val ioDispatcher = StandardTestDispatcher(io)

        /** Runs the fetch to completion; it hops main -> io -> main. */
        fun drain() {
            repeat(20) {
                main.advanceUntilIdle()
                io.advanceUntilIdle()
            }
        }
    }

    private fun cacheTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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

    private class FakeTransport(
        var workspaces: String = """{"workspaces":[{"id":"ws_1","name":"One"}]}""",
        var chatsByWorkspace: Map<String, String> = emptyMap(),
        var offline: Boolean = false,
    ) : AuthTransport {
        override fun post(path: String, body: String, headers: Map<String, String>) =
            error("read-only")

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            val body = if (path.startsWith(RecentsApi.WORKSPACES_PATH)) {
                workspaces
            } else {
                chatsByWorkspace[path.substringAfter("workspace_id=")]
                    ?: """{"sessions":[],"total":0,"has_more":false,"next_cursor":null}"""
            }
            return AuthHttpResponse(statusCode = 200, body = body)
        }
    }

    private class FakeCache : RecentsCache {
        val workspaces = mutableMapOf<String, List<WorkspaceOption>>()
        val chats = mutableMapOf<String, List<ChatSummary>>()
        var cleared = false

        override fun readWorkspaces(userId: String?): List<WorkspaceOption>? =
            RecentsCacheCodec.workspacesKey(userId)?.let { workspaces[it] }

        override fun writeWorkspaces(userId: String?, value: List<WorkspaceOption>) {
            RecentsCacheCodec.workspacesKey(userId)?.let { workspaces[it] = value }
        }

        override fun readChats(userId: String?, workspaceId: String): List<ChatSummary>? =
            RecentsCacheCodec.chatsKey(userId, workspaceId)?.let { chats[it] }

        override fun writeChats(userId: String?, workspaceId: String, value: List<ChatSummary>) {
            RecentsCacheCodec.chatsKey(userId, workspaceId)?.let { chats[it] = value }
        }

        override fun clear() {
            cleared = true
            workspaces.clear()
            chats.clear()
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        cache: RecentsCache,
        transport: AuthTransport = FakeTransport(),
    ) = HomeViewModel(
        client = RecentsClient(MemorySessionStore(), httpTransport = transport),
        cache = cache,
        ioDispatcher = ioDispatcher,
    )

    private fun chat(workspaceId: String, id: String) =
        ChatSummary(id, workspaceId, "Chat $id", 1_000L)

    @Test
    fun aCachedSidebarPaintsBeforeTheNetworkReturns() = cacheTest { s ->
        val cache = FakeCache()
        cache.writeWorkspaces("user_a", listOf(WorkspaceOption("ws_1", "Cached One")))
        cache.writeChats("user_a", "ws_1", listOf(chat("ws_1", "cached-chat")))

        val model = model(s.ioDispatcher, cache)
        model.onUserChanged("user_a")

        // Undrained: this is the first frame, before the fetch runs.
        val state = model.uiState.value
        assertEquals(listOf("Cached One"), state.workspaces.map { it.name })
        assertEquals(listOf("cached-chat"), state.chats.map { it.id })
        assertTrue("still loading behind the painted rows", state.isLoading)
    }

    @Test
    fun aSuccessfulFetchReplacesTheCachedRows() = cacheTest { s ->
        val cache = FakeCache()
        cache.writeWorkspaces("user_a", listOf(WorkspaceOption("ws_1", "Cached One")))
        cache.writeChats("user_a", "ws_1", listOf(chat("ws_1", "stale-chat")))

        val model = model(
            s.ioDispatcher,
            cache,
            FakeTransport(
                chatsByWorkspace = mapOf(
                    "ws_1" to """{"sessions":[{"session_id":"fresh-chat","session_name":"Fresh"}],"total":1}""",
                ),
            ),
        )
        model.onUserChanged("user_a")
        s.drain()

        assertEquals(listOf("fresh-chat"), model.uiState.value.chats.map { it.id })
        // Replace, not merge, so a chat deleted upstream stays deleted.
        assertEquals(listOf("fresh-chat"), cache.readChats("user_a", "ws_1")?.map { it.id })
    }

    @Test
    fun switchingWorkspacePaintsThatWorkspacesCachedRecents() = cacheTest { s ->
        val cache = FakeCache()
        cache.writeChats("user_a", "ws_2", listOf(chat("ws_2", "two-cached-chat")))

        val model = model(
            s.ioDispatcher,
            cache,
            FakeTransport(
                workspaces = """{"workspaces":[
                    {"id":"ws_1","name":"One"},{"id":"ws_2","name":"Two"}]}""",
            ),
        )
        model.onUserChanged("user_a")
        s.drain()

        model.selectWorkspace("ws_2")

        // Without priming here this would be empty until the network answered:
        // a spinner over rows already on disk. The web's loadChats primes from
        // cache on every call, not just on mount.
        val state = model.uiState.value
        assertEquals(listOf("two-cached-chat"), state.chats.map { it.id })
        assertEquals("ws_2", state.chats.single().workspaceId)
    }

    @Test
    fun aFailedRefreshKeepsCachedRowsAndFlagsThemStale() = cacheTest { s ->
        val cache = FakeCache()
        cache.writeWorkspaces("user_a", listOf(WorkspaceOption("ws_1", "Cached One")))
        cache.writeChats("user_a", "ws_1", listOf(chat("ws_1", "cached-chat")))

        val model = model(s.ioDispatcher, cache, FakeTransport(offline = true))
        model.onUserChanged("user_a")
        s.drain()

        val state = model.uiState.value
        // A working sidebar must not blank because the network blipped.
        assertEquals(listOf("Cached One"), state.workspaces.map { it.name })
        assertEquals(listOf("cached-chat"), state.chats.map { it.id })
        assertTrue("error must be surfaced", state.errorMessage != null)
        assertTrue(state.isShowingStaleData)
    }

    @Test
    fun aFirstLaunchWithNoCacheAndNoNetworkIsAnHonestErrorNotAnEmptyList() = cacheTest { s ->
        val model = model(s.ioDispatcher, FakeCache(), FakeTransport(offline = true))
        model.onUserChanged("user_a")
        s.drain()

        val state = model.uiState.value
        // No cache AND no network must read as an error, never as "you have no
        // workspaces" — those are different truths.
        assertTrue(state.workspaces.isEmpty())
        assertTrue("expected an error message", state.errorMessage != null)
        assertEquals(false, state.isEmpty)
    }

    @Test
    fun aGenuinelyEmptyAccountIsAnEmptyStateNotAnError() = cacheTest { s ->
        val model = model(
            s.ioDispatcher,
            FakeCache(),
            FakeTransport(workspaces = """{"workspaces":[]}"""),
        )
        model.onUserChanged("user_a")
        s.drain()

        val state = model.uiState.value
        assertEquals(null, state.errorMessage)
        assertTrue(state.isEmpty)
    }

    @Test
    fun signingOutPurgesEveryNamespaceSoTheNextAccountInheritsNothing() = cacheTest { s ->
        val cache = FakeCache()
        cache.writeWorkspaces("user_a", listOf(WorkspaceOption("ws_1", "A's secret")))

        val model = model(s.ioDispatcher, cache)
        model.onUserChanged("user_a")
        s.drain()

        model.onSignedOut()
        s.drain()

        assertTrue("sign-out must purge", cache.cleared)
        assertEquals(null, cache.readWorkspaces("user_a"))
        assertTrue(model.uiState.value.workspaces.isEmpty())
    }

    @Test
    fun changingAccountClearsTheOtherAccountsRowsBeforeAnyFetch() = cacheTest { s ->
        val cache = FakeCache()
        cache.writeWorkspaces("user_a", listOf(WorkspaceOption("ws_a", "A's workspace")))

        val model = model(s.ioDispatcher, cache)
        model.onUserChanged("user_a")
        assertEquals(listOf("A's workspace"), model.uiState.value.workspaces.map { it.name })

        // B signs in on the same device. B must never see A's rows, not even
        // for the frames before B's own fetch lands.
        model.onUserChanged("user_b")

        assertTrue(model.uiState.value.workspaces.isEmpty())
    }
}
