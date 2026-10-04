package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.testing.FakeSseBus
import com.pabrik.mobile.testing.InMemoryChatCache
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
 * What a refetch does to a turn the stream stopped reporting on.
 *
 * **The bug this exists for.** `chunk_final` and `llm_full` are ordinary SSE
 * frames, and the backend keeps no replay buffer — a client that reconnects
 * cannot ask for what it missed. A phone that was backgrounded, rotated, or
 * briefly offline across the end of a run therefore loses both frames and has
 * no way left to learn the run finished: the header reads "Working…", the
 * composer offers a Stop button for a worker that no longer exists, and a
 * `streaming…` hint hangs under an answer that is already complete.
 *
 * Nothing else in the class can repair that. `ChatApi.mergeById` keeps any row
 * whose id never appears in a server page, and a `streaming-` id never can —
 * the placeholder is minted precisely *because* the turn had not been written
 * yet. So the refetch has to do it, and it has to ask two questions rather
 * than one: the transcript says which turns have been **written**, the worker
 * list says whether anything is still **running**.
 *
 * Each test here drives the real reproduction — a live run, a dropped socket
 * across the end of it, and a reconnect — rather than poking the state, because
 * the failure is a *sequence* and a test that seeds the final state proves only
 * that the assertions are true of it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelStreamingReconcileTest {

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

    private fun reconcileTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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
     * Routes by path so one fake can answer the three reads a chat screen
     * makes: the transcript, the worker list, and the in-memory snapshot.
     *
     * The envelopes are the backend's own shapes — `{"workers":[…],"count":n}`
     * from `makeWorkerListResponse`, and the `SessionMessage` fields
     * `ChatApi.toChatMessage` reads — because a hand-written fixture that
     * happens to parse proves the parser agrees with the fixture, not with the
     * server.
     */
    private class FixtureTransport : AuthTransport {
        /** What `GET /api/llm/session/{id}/messages` answers. */
        var messages: String = emptyPage()

        /** What `GET /api/workers?session_id=…` answers. */
        var workers: String = runningWorker()

        /** A worker read that fails, which must change nothing. */
        var workersUnavailable = false

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse = when {
            path.startsWith("/api/workers") ->
                if (workersUnavailable) {
                    throw IOException("offline")
                } else {
                    AuthHttpResponse(200, workers)
                }

            // `/queue_messages` does not contain "/messages" — the separator
            // is `_` — so the two paths cannot be confused for one another.
            path.contains("/messages") -> AuthHttpResponse(200, messages)
            path.endsWith("/stream") -> AuthHttpResponse(200, """{"active":false,"content":""}""")
            else -> AuthHttpResponse(200, "{}")
        }

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse = AuthHttpResponse(201, "{}")
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        bus: FakeSseBus = FakeSseBus(),
        transport: FixtureTransport = FixtureTransport(),
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = InMemoryChatCache(),
        bus = bus,
        ioDispatcher = ioDispatcher,
        nowMillis = { 1_790_835_984_283_000L },
    ).also { it.onUserChanged("user_a") }

    /**
     * Opens the chat, connects, and gets a delta on screen — a run the phone is
     * watching, with a placeholder it is still filling.
     */
    private suspend fun TestScope.openedStreamingTurn(
        schedulers: Schedulers,
        transport: FixtureTransport,
        bus: FakeSseBus,
    ): ChatViewModel {
        val model = model(schedulers.ioDispatcher, bus, transport)
        model.openSession("sess_1")
        schedulers.drain()
        bus.state(ChatStreamState.Live)
        schedulers.drain()
        bus.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = PARTIAL_ANSWER))
        schedulers.drain()
        assertTrue("precondition: the turn is streaming", model.uiState.value.isStreaming)
        assertEquals(
            "precondition: one placeholder row",
            1,
            model.uiState.value.messages.count { it.isStreaming },
        )
        return model
    }

    /** The socket drops and comes back, which is the only repair there is. */
    private fun reconnect(schedulers: Schedulers, bus: FakeSseBus) {
        bus.state(ChatStreamState.Reconnecting)
        schedulers.drain()
        bus.state(ChatStreamState.Live)
        schedulers.drain()
    }

    @Test
    fun `a refetch replaces the placeholder with the turn that finished`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // The run finished on the server while this phone was not looking:
            // the turn is persisted, and the worker row is gone. Neither fact
            // ever arrives as a frame.
            transport.messages = pageOf(assistantTurn(SAVED_ANSWER))
            transport.workers = noWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertFalse("the header must stop claiming a run", state.isStreaming)
            assertTrue(
                "no row may still claim to be mid-sentence",
                state.messages.none { it.isStreaming },
            )
            assertEquals(
                "the persisted turn replaces the stub",
                listOf(SAVED_ANSWER),
                state.messages.map { it.content },
            )
        }

    @Test
    fun `a refetch during a live run leaves the streaming turn exactly as it was`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // The same reconnect, but the worker is still there — so the answer
            // is still arriving and nothing may be settled.
            transport.workers = runningWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertTrue("a live run must keep its flag", state.isStreaming)
            assertEquals(
                "the placeholder must keep the text it streamed",
                listOf(PARTIAL_ANSWER),
                state.messages.map { it.content },
            )
        }

    @Test
    fun `a refetch whose worker read failed settles nothing`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // "No answer" is not "no worker". Clearing a live turn because the
            // network blipped is the same lie as never lighting one up — the
            // rule `WorkerActivityViewModel` already applies to its own set.
            transport.workersUnavailable = true
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertTrue("a failed read must not claim the run ended", state.isStreaming)
            assertEquals(
                listOf(PARTIAL_ANSWER),
                state.messages.map { it.content },
            )
        }

    @Test
    fun `a run that ended without writing a row keeps its text and stops claiming to stream`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // No worker and no row: the turn can never be written now, because
            // nothing is running to write it. That is the cancel-before-the-first-
            // token path and the crash path, and in both the partial text IS the
            // answer — so the row is unfrozen rather than deleted, which is
            // exactly what a reader who pressed Stop is given.
            transport.messages = emptyPage()
            transport.workers = noWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertFalse("there is no run left to claim", state.isStreaming)
            assertEquals(
                "the text the reader watched arrive must not be thrown away",
                listOf(PARTIAL_ANSWER),
                state.messages.map { it.content },
            )
            assertTrue(
                "and it must not keep the streaming hint",
                state.messages.none { it.isStreaming },
            )
        }

    @Test
    fun `an older turn that happens to start the same way does not retire the placeholder`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // "Your URL" was the whole of a *previous* answer, and the turn in
            // flight starts with the same words. Only the newest assistant row
            // may retire a placeholder — otherwise a run two turns old deletes
            // real text mid-stream.
            transport.messages = pageOf(
                assistantTurn("Your URL", id = "old", nanos = OLD_NANOS),
                assistantTurn("Completely different", id = "new", nanos = NEW_NANOS),
            )
            transport.workers = runningWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertTrue("a live run keeps its flag", state.isStreaming)
            assertEquals(
                "the placeholder must survive a decoy",
                1,
                state.messages.count { it.isStreaming },
            )
        }

    @Test
    fun `a refetch with no placeholder on screen leaves the flag to whatever wrote it`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // A normal turn: `chunk_final` lands, the placeholder stays on screen
            // by design until the canonical row does, and a refetch arrives in
            // that window. Nothing is streaming and nothing may be invented.
            bus.emit(ChatStreamEvent.ChunkFinished(sessionId = "sess_1", totalTokens = null))
            schedulers.drain()
            transport.messages = emptyPage()
            transport.workers = noWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertFalse(state.isStreaming)
            assertEquals(
                listOf(PARTIAL_ANSWER),
                state.messages.map { it.content },
            )
        }

    private companion object {
        /** A prefix of [SAVED_ANSWER] — deltas only ever append. */
        const val PARTIAL_ANSWER = "Your URL sugg"

        const val SAVED_ANSWER =
            "Your URL suggestion\n\nYou're right that /app/<ws>/doc/<id> is the better shape."

        const val OLD_NANOS = 1_790_835_900_000_000_000L
        const val NEW_NANOS = 1_790_835_984_283_000_000L

        fun emptyPage(): String =
            """{"messages":[],"has_more":false,"next_cursor":null,"total":0}"""

        /** One live worker on `sess_1`, exactly as `updateWorker` broadcasts it. */
        fun runningWorker(): String =
            """{"workers":[{"id":"sess_1","session_id":"sess_1","working_directory":"/home/ginwa",""" +
                """"last_activity":"2026-10-01 13:25:00","last_activity_description":"streaming",""" +
                """"created_at":"2026-10-01 13:24:00","status":"running","is_running":true,""" +
                """"queue_count":0}],"count":1}"""

        /** No workers at all — the run is over. */
        fun noWorker(): String = """{"workers":[],"count":0}"""

        fun pageOf(vararg rows: String): String =
            """{"messages":[${rows.joinToString(",")}],"has_more":false,""" +
                """"next_cursor":null,"total":${rows.size}}"""

        /**
         * A persisted assistant turn, in the shape `llm_history` rows take on
         * the wire: `created_at` is a *string* holding a nanosecond epoch.
         */
        fun assistantTurn(
            content: String,
            id: String = "saved_turn",
            nanos: Long = NEW_NANOS,
        ): String =
            """{"id":"$id","role":"assistant","content":${quote(content)},""" +
                """"created_at":"$nanos","finish_reason":"stop"}"""

        fun quote(value: String): String =
            "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""
    }
}