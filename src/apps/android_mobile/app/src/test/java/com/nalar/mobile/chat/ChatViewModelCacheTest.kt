package com.nalar.mobile.chat

import com.nalar.mobile.auth.AuthHttpResponse
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.auth.SessionStore
import com.nalar.mobile.testing.InMemoryChatCache
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cache-then-revalidate contract at the ViewModel level.
 *
 * The contract is about ORDERING — paint from disk, then fetch — and the state
 * that proves it (real messages on screen with the spinner still running) is
 * exactly the state a synchronous test cannot see if both run on one
 * scheduler. So main and IO get separate schedulers, mirroring the device: the
 * fetch is genuinely pending until drained.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelCacheTest {

    private class Schedulers {
        val main = TestCoroutineScheduler()
        val io = TestCoroutineScheduler()
        val mainDispatcher = StandardTestDispatcher(main)
        val ioDispatcher = StandardTestDispatcher(io)

        fun drain() {
            repeat(30) {
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

    private fun List<String>.messagesRequest() =
        firstOrNull { it.contains("/messages") } ?: error("no messages request was made")

    private class FakeTransport(
        var messages: String = """{"messages":[],"has_more":false,"next_cursor":null,"total":0}""",
        var streamSnapshot: String = "",
        var sendStatus: Int = 201,
        var offline: Boolean = false,
    ) : AuthTransport {
        val requestedPaths = mutableListOf<String>()
        val sentBodies = mutableListOf<String>()

        override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            requestedPaths += "$POST $path"
            sentBodies += body
            return AuthHttpResponse(statusCode = sendStatus, body = """{"status":"send"}""")
        }

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            requestedPaths += "$GET $path"
            return AuthHttpResponse(
                statusCode = 200,
                body = if (path.endsWith("/stream")) {
                    streamSnapshot
                } else {
                    messages
                },
            )
        }

        companion object {
            const val POST = "POST"
            const val GET = "GET"
        }
    }

    private class FakeEventStream : ChatEventStream {
        var onEvent: ((ChatStreamEvent) -> Unit)? = null
        var onState: ((ChatStreamState) -> Unit)? = null
        var startCount = 0
        var stopCount = 0

        override fun start(
            onEvent: (ChatStreamEvent) -> Unit,
            onState: (ChatStreamState) -> Unit,
        ) {
            startCount++
            this.onEvent = onEvent
            this.onState = onState
        }

        override fun stop() {
            stopCount++
        }

        fun emit(event: ChatStreamEvent) = onEvent?.invoke(event) ?: Unit
        fun state(next: ChatStreamState) = onState?.invoke(next) ?: Unit
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        cache: ChatCache = InMemoryChatCache(),
        transport: AuthTransport = FakeTransport(),
        stream: FakeEventStream = FakeEventStream(),
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = cache,
        eventStream = stream,
        ioDispatcher = ioDispatcher,
        nowMillis = { 1_789_451_234_000L },
    ).also { it.onUserChanged("user_a") }

    /**
     * A realistic nanosecond stamp. `created_at` is only recognised as a stamp
     * when it is at least 13 digits, so a small test offset must be added to a
     * real base or every row sorts as 0 and the ordering assertions prove
     * nothing.
     */
    private val nanoBase = 1_789_451_234_567_000_000L

    private fun wire(
        id: String,
        offsetNanos: Long,
        role: String = ChatMessage.ROLE_USER,
        content: String = "hello",
    ) = """{"id":"$id","session_id":"sess_1","role":"$role","content":"$content","created_at":"${nanoBase + offsetNanos}"}"""

    private fun page(vararg messages: String, hasMore: Boolean = false, nextCursor: String? = null) =
        """{"messages":[${messages.joinToString(",")}],"has_more":$hasMore,"next_cursor":${nextCursor?.let { "\"$it\"" } ?: "null"},"total":${messages.size}}"""

    private fun cachedRow(
        id: String,
        offsetNanos: Long,
        role: String = ChatMessage.ROLE_USER,
        content: String = "cached hello",
    ): CachedChatMessage {
        val nanos = nanoBase + offsetNanos
        val raw = """{"id":"$id","session_id":"sess_1","role":"$role","content":"$content","created_at":"$nanos"}"""
        return CachedChatMessage(
            id = id,
            sortKeyNanos = nanos,
            sessionId = "sess_1",
            role = role,
            content = content,
            raw = raw,
        )
    }

    // --- Paint, then revalidate -------------------------------------------

    @Test
    fun `a cached transcript paints before the network returns`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "from disk")))
        }
        val model = model(s.ioDispatcher, cache)

        model.openSession("sess_1")

        // Undrained: this is the first frame, before the fetch runs.
        val state = model.uiState.value
        assertEquals(listOf("from disk"), state.messages.map { it.content })
        assertTrue("still loading behind the painted rows", state.isLoading)
    }

    @Test
    fun `a fresh fetch replaces the cached rows and is written through`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "stale")))
        }
        val model = model(
            s.ioDispatcher,
            cache,
            FakeTransport(messages = page(wire("m1", 100L, content = "fresh"), wire("m2", 200L, content = "newer"))),
        )

        model.openSession("sess_1")
        s.drain()

        assertEquals(listOf("fresh", "newer"), model.uiState.value.messages.map { it.content })
        assertFalse(model.uiState.value.isLoading)
        // Write-through: the next cold start reads the fetched rows, not the
        // stale ones.
        assertEquals(
            listOf("fresh", "newer"),
            cache.readMessages("user_a", "sess_1", 10)!!
                .sortedBy { it.sortKeyNanos }
                .map { it.raw.substringAfter("\"content\":\"").substringBefore("\"") },
        )
    }

    @Test
    fun `a cold start asks for the newest page, a warm one for the tail only`() = cacheTest { s ->
        val transport = FakeTransport(messages = page())

        model(s.ioDispatcher, InMemoryChatCache(), transport).openSession("sess_1")
        s.drain()
        assertTrue(
            transport.requestedPaths.messagesRequest(),
            transport.requestedPaths.messagesRequest().contains("direction=desc"),
        )

        // Second open with a stored cursor: only what is new since it.
        val warm = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L)))
            writeCursor("user_a", "sess_1", "${nanoBase + 100L}")
        }
        val warmTransport = FakeTransport(messages = page())
        model(s.ioDispatcher, warm, warmTransport).openSession("sess_1")
        s.drain()
        assertTrue(
            warmTransport.requestedPaths.messagesRequest(),
            warmTransport.requestedPaths.messagesRequest().contains("direction=asc"),
        )
        assertTrue(
            warmTransport.requestedPaths.messagesRequest().contains("cursor=${nanoBase + 100L}"),
        )
    }

    @Test
    fun `a failed revalidation keeps the cached rows and flags them stale`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "from disk")))
        }
        val model = model(s.ioDispatcher, cache, FakeTransport(offline = true))

        model.openSession("sess_1")
        s.drain()

        val state = model.uiState.value
        // A working chat must not blank because the network blipped.
        assertEquals(listOf("from disk"), state.messages.map { it.content })
        assertTrue("the error must be surfaced", state.errorMessage != null)
        assertTrue(state.isShowingStaleData)
    }

    @Test
    fun `a first launch with no cache and no network is an honest error`() = cacheTest { s ->
        val model = model(s.ioDispatcher, InMemoryChatCache(), FakeTransport(offline = true))

        model.openSession("sess_1")
        s.drain()

        val state = model.uiState.value
        // No cache AND no network is an error, not "this chat is empty" — those
        // are different truths and only one of them is worth a retry.
        assertTrue(state.messages.isEmpty())
        assertTrue(state.errorMessage != null)
        assertFalse(state.isEmptyConversation)
    }

    @Test
    fun `a genuinely empty chat is an empty state, not an error`() = cacheTest { s ->
        val model = model(s.ioDispatcher, InMemoryChatCache(), FakeTransport(messages = page()))

        model.openSession("sess_1")
        s.drain()

        assertNull(model.uiState.value.errorMessage)
        assertTrue(model.uiState.value.isEmptyConversation)
    }

    // --- User isolation ----------------------------------------------------

    @Test
    fun `a blank identity never reads a cache at all`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "A's secret")))
        }
        val model = model(s.ioDispatcher, cache, stream = FakeEventStream())
        model.onUserChanged(null)

        model.openSession("sess_1")

        assertTrue(
            "an unresolved identity must not surface another account's rows",
            model.uiState.value.messages.isEmpty(),
        )
    }

    @Test
    fun `changing account clears the previous transcript before any fetch`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "A's secret")))
        }
        val model = model(s.ioDispatcher, cache)
        model.openSession("sess_1")
        s.drain()
        assertEquals(1, model.uiState.value.messages.size)

        // B signs in on the same device. B must never see A's turns, not even
        // for the frames before B's own fetch lands.
        model.onUserChanged("user_b")

        assertTrue(model.uiState.value.messages.isEmpty())
    }

    @Test
    fun `signing out purges every namespace so the next account inherits nothing`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L)))
        }
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, cache, stream = stream)
        model.openSession("sess_1")
        s.drain()

        model.onSignedOut()
        s.drain()

        assertTrue("sign-out must purge", cache.cleared)
        assertNull(cache.readMessages("user_a", "sess_1", 10))
        assertTrue("the stream must be closed", stream.stopCount >= 1)
        assertTrue(model.uiState.value.messages.isEmpty())
    }

    // --- Streaming ---------------------------------------------------------

    @Test
    fun `the stream is attached before the first fetch so no turn is missed`() = cacheTest { s ->
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, stream = stream)

        model.openSession("sess_1")

        // A tool can finish while the initial load is in flight; a listener
        // attached afterwards can never see that event, and the backend has no
        // replay to ask again.
        assertEquals(1, stream.startCount)
        assertTrue(model.uiState.value.isLoading)
    }

    @Test
    fun `opening a second chat rebinds the stream instead of keeping the first`() = cacheTest { s ->
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, stream = stream)

        model.openSession("sess_1")
        s.drain()
        assertEquals(1, stream.startCount)

        // A stream left bound to chat A keeps delivering A's events into
        // handlers filtered to A, so B would sit there showing "connected" and
        // never receive a turn. Only a process restart would fix it.
        model.openSession("sess_2")
        s.drain()

        assertTrue("the previous stream must be closed", stream.stopCount >= 1)
        assertEquals("a fresh stream must be bound to the new chat", 2, stream.startCount)
    }

    @Test
    fun `a warm tail refresh does not destroy the ability to page backwards`() = cacheTest { s ->
        val transport = FakeTransport(
            messages = page(wire("m1", 100L), wire("m2", 200L), hasMore = true, nextCursor = "100"),
        )
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport, stream)
        model.openSession("sess_1")
        s.drain()
        assertTrue("the first load is a full one", model.uiState.value.hasMoreOlder)

        // Any warm revalidate — a session rename, a reconnect — is short by
        // definition, so the server answers has_more=false for it. Letting that
        // reset the paging state would switch off scroll-back for good.
        transport.messages = page(wire("m3", 300L))
        stream.state(ChatStreamState.Live)
        stream.state(ChatStreamState.Reconnecting)
        stream.state(ChatStreamState.Live)
        s.drain()

        assertTrue(
            "a short tail page must not switch off scroll-back for good",
            model.uiState.value.hasMoreOlder,
        )
    }

    @Test
    fun `chunks append rather than replace`() = cacheTest { s ->
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, stream = stream)
        model.openSession("sess_1")
        s.drain()

        stream.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "Hel"))
        stream.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "lo "))
        stream.emit(ChatStreamEvent.Chunk("sess_1", 0, reasoningContent = "hmm"))
        stream.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "world"))

        val streaming = model.uiState.value.messages.single()
        // The backend sends raw provider deltas. Assigning would leave only the
        // last fragment on screen.
        assertEquals("Hello world", streaming.content)
        assertEquals("hmm", streaming.reasoningContent)
        assertTrue(streaming.isStreaming)
        assertTrue(streaming.id.startsWith(ChatMessage.STREAMING_ID_PREFIX))
    }

    @Test
    fun `a full frame replaces the streaming placeholder and lands in the cache`() = cacheTest { s ->
        val cache = InMemoryChatCache()
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, cache, stream = stream)
        model.openSession("sess_1")
        s.drain()

        stream.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "partia"))
        stream.emit(ChatStreamEvent.ChunkFinished("sess_1", 42))
        val canonical = ChatMessage(
            id = "m9",
            role = ChatMessage.ROLE_ASSISTANT,
            content = "the complete answer",
            createdAtEpochMillis = nanoBase / 1_000_000L + 300L,
            sortKeyNanos = nanoBase + 300L,
        )
        stream.emit(ChatStreamEvent.Full("sess_1", canonical))
        s.drain()

        val messages = model.uiState.value.messages
        assertEquals(1, messages.size)
        assertEquals("the complete answer", messages.single().content)
        assertFalse("the placeholder must be gone", messages.single().isStreaming)
        // Write-through, so a cold start reads the completed turn rather than
        // a stub or nothing at all.
        assertEquals("m9", cache.readMessages("user_a", "sess_1", 10)!!.single().id)
    }

    @Test
    fun `a reconnect refetches because the server has no replay`() = cacheTest { s ->
        val transport = FakeTransport(messages = page(wire("m1", 100L)))
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport, stream)
        model.openSession("sess_1")
        s.drain()
        val afterFirstLoad = transport.requestedPaths.size

        stream.state(ChatStreamState.Live)
        stream.state(ChatStreamState.Reconnecting)
        transport.messages = page(wire("m1", 100L), wire("m2", 200L, content = "while away"))
        stream.state(ChatStreamState.Live)
        s.drain()

        assertTrue(
            "a reconnect must repair the gap with a refetch",
            transport.requestedPaths.size > afterFirstLoad,
        )
        assertEquals(
            listOf("hello", "while away"),
            model.uiState.value.messages.map { it.content },
        )
    }

    @Test
    fun `a live row is not rolled back by a rest response that started earlier`() = cacheTest { s ->
        val transport = FakeTransport(messages = page())
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport, stream)
        model.openSession("sess_1")

        // The tool's completed row arrives live while the fetch is in flight,
        // and the in-flight response still carries its placeholder content.
        val live = ChatMessage(
            id = "tool_1",
            role = ChatMessage.ROLE_TOOL,
            content = "the real result",
            createdAtEpochMillis = nanoBase / 1_000_000L + 400L,
            sortKeyNanos = nanoBase + 400L,
        )
        stream.emit(ChatStreamEvent.Full("sess_1", live))
        transport.messages = page(
            """{"id":"tool_1","session_id":"sess_1","role":"tool","content":"running…","created_at":"${nanoBase + 400L}"}""",
        )
        s.drain()

        // Writing the stale REST row back would turn a finished tool result
        // into a spinner.
        assertEquals("the real result", model.uiState.value.messages.single().content)
    }

    @Test
    fun `an event for another chat is ignored`() = cacheTest { s ->
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, stream = stream)
        model.openSession("sess_1")
        s.drain()

        stream.emit(
            ChatStreamEvent.Chunk("sess_other", 0, content = "not for you"),
        )
        stream.emit(
            ChatStreamEvent.Full(
                "sess_other",
                ChatMessage("x", ChatMessage.ROLE_ASSISTANT, "not for you", 0L, nanoBase),
            ),
        )

        assertTrue(model.uiState.value.messages.isEmpty())
    }

    // --- Sending -----------------------------------------------------------

    @Test
    fun `sending does not insert an optimistic bubble`() = cacheTest { s ->
        val transport = FakeTransport(messages = page())
        val stream = FakeEventStream()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport, stream)
        model.openSession("sess_1")
        s.drain()

        model.onDraftChanged("do the thing")
        model.sendMessage()
        s.drain()

        // The web removed its optimistic push deliberately: it lands at the
        // wrong end of the array and re-keys the grouped list.
        assertTrue(model.uiState.value.messages.isEmpty())
        assertTrue(
            "the turn was queued",
            transport.requestedPaths.any { it.startsWith("POST /api/llm/session") },
        )
        assertEquals("", model.uiState.value.draft)
        assertFalse(model.uiState.value.isSending)
    }

    @Test
    fun `a failed send keeps the draft so a retry is one tap`() = cacheTest { s ->
        val model = model(s.ioDispatcher, InMemoryChatCache(), FakeTransport(sendStatus = 400))
        model.openSession("sess_1")
        s.drain()

        model.onDraftChanged("do the thing")
        model.sendMessage()
        s.drain()

        assertEquals("do the thing", model.uiState.value.draft)
        assertTrue(model.uiState.value.errorMessage != null)
        assertFalse(model.uiState.value.isSending)
    }

    @Test
    fun `a send to a chat that is not open does nothing`() = cacheTest { s ->
        val transport = FakeTransport()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport)
        model.onDraftChanged("stray")

        model.sendMessage()
        s.drain()

        assertTrue(transport.requestedPaths.none { it.startsWith("POST") })
    }

    @Test
    fun `a run already in progress when the chat is opened is re attached`() = cacheTest { s ->
        // The backend writes `llm_history` only when a turn completes, so a cold
        // open mid-run otherwise stops one message short of the live answer.
        val model = model(
            s.ioDispatcher,
            InMemoryChatCache(),
            FakeTransport(
                messages = page(wire("m1", 100L)),
                streamSnapshot = """{"active":true,"content":"half an ans"}""",
            ),
        )

        model.openSession("sess_1")
        s.drain()

        val streaming = model.uiState.value.messages.last()
        assertEquals("half an ans", streaming.content)
        assertTrue(streaming.isStreaming)
        assertTrue(model.uiState.value.isStreaming)
    }

    @Test
    fun `an idle server contributes no placeholder`() = cacheTest { s ->
        val model = model(
            s.ioDispatcher,
            InMemoryChatCache(),
            FakeTransport(
                messages = page(wire("m1", 100L)),
                streamSnapshot = """{"active":false,"content":""}""",
            ),
        )

        model.openSession("sess_1")
        s.drain()

        assertEquals(1, model.uiState.value.messages.size)
        assertTrue(model.uiState.value.messages.none { it.isStreaming })
    }

    @Test
    fun `the re attached text never overwrites a stream that is already live`() = cacheTest { s ->
        val stream = FakeEventStream()
        val model = model(
            s.ioDispatcher,
            InMemoryChatCache(),
            FakeTransport(
                messages = page(wire("m1", 100L)),
                streamSnapshot = """{"active":true,"content":"stale snapshot"}""",
            ),
            stream,
        )
        model.openSession("sess_1")
        // The live stream wins the race, as it should.
        stream.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "the live one"))
        s.drain()

        assertEquals("the live one", model.uiState.value.messages.last().content)
    }

    // --- Paging backwards --------------------------------------------------

    @Test
    fun `scrolling to the top prepends the previous page without duplicates`() = cacheTest { s ->
        val transport = FakeTransport(
            messages = page(
                wire("m5", 500L),
                wire("m6", 600L),
                hasMore = true,
                nextCursor = "500",
            ),
        )
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport)
        model.openSession("sess_1")
        s.drain()
        assertTrue(model.uiState.value.hasMoreOlder)

        transport.messages = page(
            wire("m5", 500L),
            wire("m4", 400L, content = "older"),
            wire("m3", 300L, content = "oldest"),
        )
        model.loadOlderMessages()
        s.drain()

        // Ascending transcript order, and the overlap row is not duplicated.
        assertEquals(
            listOf("oldest", "older", "hello", "hello"),
            model.uiState.value.messages.map { it.content },
        )
        assertEquals(4, model.uiState.value.messages.map { it.id }.toSet().size)
    }

    @Test
    fun `paging is not retried once the server says there is no more`() = cacheTest { s ->
        val transport = FakeTransport(messages = page(wire("m1", 100L)))
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport)
        model.openSession("sess_1")
        s.drain()

        assertFalse("no has_more means no scroll-to-top arming", model.uiState.value.hasMoreOlder)

        val before = transport.requestedPaths.size
        model.loadOlderMessages()
        s.drain()

        assertEquals(before, transport.requestedPaths.size)
    }
}
