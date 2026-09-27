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
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the chat stream's own state transitions do to `isStreaming`.
 *
 * `isChatWorking` is `isRunning || isStreaming`, so a turn left flagged as
 * streaming keeps the "Working…" label and the Stop button on screen after the
 * agent has gone. The two events that can end a turn — `chunk_final` and
 * `llm_full` — are both ordinary frames, and neither can arrive once the socket
 * has given up for good, so the *terminal* transition has to clear the flag
 * itself.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelStreamStateTest {

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

    private fun streamStateTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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
        var messages: String = """{"messages":[],"has_more":false,"next_cursor":null,"total":0}""",
        var streamSnapshot: String = "",
        var offline: Boolean = false,
    ) : AuthTransport {
        override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            return AuthHttpResponse(201, """{"status":"send"}""")
        }

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            return AuthHttpResponse(
                statusCode = 200,
                body = if (path.endsWith("/stream")) streamSnapshot else messages,
            )
        }
    }

    private class FakeEventStream : ChatEventStream {
        var onEvent: ((ChatStreamEvent) -> Unit)? = null
        var onState: ((ChatStreamState) -> Unit)? = null

        override fun start(
            onEvent: (ChatStreamEvent) -> Unit,
            onState: (ChatStreamState) -> Unit,
        ) {
            this.onEvent = onEvent
            this.onState = onState
        }

        override fun stop() = Unit

        fun emit(event: ChatStreamEvent) = onEvent?.invoke(event) ?: Unit
        fun state(next: ChatStreamState) = onState?.invoke(next) ?: Unit
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        stream: FakeEventStream = FakeEventStream(),
        transport: AuthTransport = FakeTransport(),
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = InMemoryChatCache(),
        eventStream = stream,
        ioDispatcher = ioDispatcher,
        nowMillis = { 1_789_451_234_000L },
    ).also { it.onUserChanged("user_a") }

    /** Opens a session and gets a delta on screen, i.e. a run in progress. */
    private suspend fun TestScope.openStreamingTurn(
        schedulers: Schedulers,
        stream: FakeEventStream,
    ): ChatViewModel {
        val model = model(schedulers.ioDispatcher, stream)
        model.openSession("sess_1")
        schedulers.drain()
        stream.state(ChatStreamState.Live)
        schedulers.drain()
        stream.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "part"))
        schedulers.drain()
        assertTrue("precondition: the turn is streaming", model.uiState.value.isStreaming)
        return model
    }

    @Test
    fun `a terminal stream failure stops claiming the turn is streaming`() =
        streamStateTest { schedulers ->
            val stream = FakeEventStream()
            val model = openStreamingTurn(schedulers, stream)

            // The pump `return`s on a rejected handshake instead of retrying, so
            // neither `chunk_final` nor `llm_full` is ever coming for this turn.
            stream.state(ChatStreamState.Failed("The event stream is unavailable (401)."))
            schedulers.drain()

            assertFalse(model.uiState.value.isStreaming)
            assertFalse(isChatWorking(isRunning = false, isStreaming = model.uiState.value.isStreaming))
            assertEquals("The event stream is unavailable (401).", model.uiState.value.errorMessage)
        }

    @Test
    fun `an is_error frame clears the flag too, the way a terminal failure now does`() =
        streamStateTest { schedulers ->
            val stream = FakeEventStream()
            val model = openStreamingTurn(schedulers, stream)

            // `llm_full` with `is_error` is an agentic-loop diagnostic ("a retry
            // notice", "TooManyRetries"), not a turn, and it already cleared the
            // flag before this change. The two must not disagree about whether a
            // run that has given up is still running.
            stream.emit(
                ChatStreamEvent.Failed("The agent hit TooManyRetries and gave up."),
            )
            schedulers.drain()

            assertFalse(model.uiState.value.isStreaming)
            assertEquals("The agent hit TooManyRetries and gave up.", model.uiState.value.errorMessage)
        }

    @Test
    fun `a reconnecting stream leaves the flag alone`() = streamStateTest { schedulers ->
        val stream = FakeEventStream()
        val model = openStreamingTurn(schedulers, stream)

        // A reconnect is not the end of the run — the refetch it triggers is
        // what may settle it — so this transition must not clear anything.
        stream.state(ChatStreamState.Reconnecting)
        schedulers.drain()

        assertTrue(model.uiState.value.isStreaming)
    }
}
