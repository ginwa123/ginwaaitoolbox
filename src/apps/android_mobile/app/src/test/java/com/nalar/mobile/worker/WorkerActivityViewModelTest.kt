package com.nalar.mobile.worker

import com.nalar.mobile.auth.AuthHttpResponse
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.auth.SessionStore
import com.nalar.mobile.chat.ChatClient
import com.nalar.mobile.chat.ChatEventStream
import com.nalar.mobile.chat.ChatStreamEvent
import com.nalar.mobile.chat.ChatStreamState
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two sources the spinner is built on, and the only repair for the gap
 * between them: a `Live` transition means the server may have started or
 * finished runs while the socket was down, so the list has to be re-read.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class WorkerActivityViewModelTest {

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

    private class MemorySessionStore : SessionStore {
        private var value: String? = "session-cookie"
        override fun read(): String? = value
        override fun save(cookieValue: String) {
            value = cookieValue
        }

        override fun clear() {
            value = null
        }
    }

    private class FakeTransport(
        private val respond: () -> AuthHttpResponse,
    ) : AuthTransport {
        var workerRequests = 0
        var lastWorkerPath: String? = null

        override fun post(path: String, body: String, headers: Map<String, String>) =
            AuthHttpResponse(200, "{}")

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (path.startsWith("/api/workers")) {
                workerRequests++
                lastWorkerPath = path
            }
            return respond()
        }
    }

    private fun workerBody(vararg sessionIds: String): String {
        val rows = sessionIds.joinToString(",") { """{"id":"$it","session_id":"$it"}""" }
        return """{"workers":[$rows],"count":${sessionIds.size}}"""
    }

    private fun modelTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
        val schedulers = Schedulers()
        Dispatchers.setMain(schedulers.mainDispatcher)
        try {
            body(schedulers)
        } finally {
            Dispatchers.resetMain()
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        store: RunningSessionsStore = RunningSessionsStore(),
        stream: FakeEventStream = FakeEventStream(),
        transport: AuthTransport = FakeTransport { AuthHttpResponse(200, workerBody()) },
        nowMillis: () -> Long = { 1_789_451_234_000L },
    ) = WorkerActivityViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        store = store,
        eventStream = stream,
        ioDispatcher = ioDispatcher,
        nowMillis = nowMillis,
    )

    @Test
    fun `nothing is subscribed until an account is signed in`() = modelTest { schedulers ->
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, stream = stream)

        // The handshake is a cookie and the pump treats any non-2xx as
        // terminal. Opened before sign-in it would be rejected once and never
        // recover, which is indistinguishable from "no worker has ever run".
        assertEquals(0, stream.startCount)
        assertTrue(model.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `signing in subscribes exactly once`() = modelTest { schedulers ->
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, stream = stream)

        model.onUserChanged("user_1")
        model.onUserChanged("user_1")

        assertEquals(1, stream.startCount)
    }

    @Test
    fun `going Live replaces the set with the server's list`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val stream = FakeEventStream()
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1", "task_2")) }
        val model = model(schedulers.ioDispatcher, store, stream, transport)
        model.onUserChanged("user_1")

        stream.state(ChatStreamState.Live)
        schedulers.drain()

        assertEquals(setOf("task_1", "task_2"), store.runningSessionIds.value)
        assertEquals(1, transport.workerRequests)
        assertEquals("/api/workers?limit=50", transport.lastWorkerPath)
    }

    @Test
    fun `a session that stopped while the socket was down stops spinning`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val stream = FakeEventStream()
        var served = workerBody("task_1", "task_2")
        val transport = FakeTransport { AuthHttpResponse(200, served) }
        val model = model(schedulers.ioDispatcher, store, stream, transport)
        model.onUserChanged("user_1")

        stream.state(ChatStreamState.Live)
        schedulers.drain()
        assertEquals(setOf("task_1", "task_2"), store.runningSessionIds.value)

        // task_2 finishes while the socket is down, so no `worker_deleted` is
        // ever delivered. Only the resync can correct it.
        served = workerBody("task_1")
        var now = 1_789_451_234_000L
        val later = FakeEventStream()
        val second = model(
            ioDispatcher = schedulers.ioDispatcher,
            store = store,
            stream = later,
            transport = transport,
            nowMillis = { now },
        )
        second.onUserChanged("user_1")
        later.state(ChatStreamState.Live)
        schedulers.drain()

        assertEquals(setOf("task_1"), store.runningSessionIds.value)
    }

    @Test
    fun `a rapid reconnect does not re-fetch`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, stream = stream, transport = transport)
        model.onUserChanged("user_1")

        stream.state(ChatStreamState.Live)
        schedulers.drain()
        stream.state(ChatStreamState.Live)
        schedulers.drain()

        // The pump reaches Live on a two-second backoff, so a flapping
        // connection would otherwise turn every retry into a list request.
        assertEquals(1, transport.workerRequests)
    }

    @Test
    fun `a reconnect after the throttle window does re-fetch`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        var now = 1_789_451_234_000L
        val stream = FakeEventStream()
        val model = model(
            ioDispatcher = schedulers.ioDispatcher,
            stream = stream,
            transport = transport,
            nowMillis = { now },
        )
        model.onUserChanged("user_1")

        stream.state(ChatStreamState.Live)
        schedulers.drain()
        now += WorkerActivityViewModel.RESYNC_THROTTLE_MILLIS
        stream.state(ChatStreamState.Live)
        schedulers.drain()

        assertEquals(2, transport.workerRequests)
    }

    @Test
    fun `a failed resync leaves the set alone`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        var fail = false
        val transport = FakeTransport {
            if (fail) AuthHttpResponse(503, "") else AuthHttpResponse(200, workerBody("task_1"))
        }
        val first = FakeEventStream()
        val model = model(schedulers.ioDispatcher, store, first, transport)
        model.onUserChanged("user_1")
        first.state(ChatStreamState.Live)
        schedulers.drain()
        assertEquals(setOf("task_1"), store.runningSessionIds.value)

        fail = true
        val second = FakeEventStream()
        val reopened = model(
            ioDispatcher = schedulers.ioDispatcher,
            store = store,
            stream = second,
            transport = transport,
            nowMillis = { 1L },
        )
        reopened.onUserChanged("user_1")
        second.state(ChatStreamState.Live)
        schedulers.drain()

        // Emptying the set would be the tempting repair and the wrong one: a
        // spinner that clears because the network blipped is the same lie as
        // one that never lights up.
        assertEquals(setOf("task_1"), store.runningSessionIds.value)
    }

    @Test
    fun `a worker_created event lights a session with no fetch`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val stream = FakeEventStream()
        // Never goes Live, so no list request happens at all.
        val transport = FakeTransport { AuthHttpResponse(200, workerBody()) }
        val model = model(schedulers.ioDispatcher, store, stream, transport)
        model.onUserChanged("user_1")

        stream.emit(
            ChatStreamEvent.WorkerChanged("task_1", ChatStreamEvent.WorkerChanged.ACTION_CREATED),
        )
        schedulers.drain()

        assertTrue(store.isRunning("task_1"))
        assertEquals(0, transport.workerRequests)
    }

    @Test
    fun `a worker_deleted event clears a session`() = modelTest { schedulers ->
        val store = RunningSessionsStore().apply { replace(setOf("task_1")) }
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, store, stream)
        model.onUserChanged("user_1")

        stream.emit(
            ChatStreamEvent.WorkerChanged("task_1", ChatStreamEvent.WorkerChanged.ACTION_DELETED),
        )
        schedulers.drain()

        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `a non-worker stream event changes nothing`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, store, stream)
        model.onUserChanged("user_1")

        stream.emit(ChatStreamEvent.Connected)
        stream.emit(ChatStreamEvent.Chunk(sessionId = "task_1", index = 0, content = "hi"))
        schedulers.drain()

        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `a Reconnecting transition does not fetch`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, stream = stream, transport = transport)
        model.onUserChanged("user_1")

        stream.state(ChatStreamState.Connecting)
        stream.state(ChatStreamState.Reconnecting)
        stream.state(ChatStreamState.Failed("nope"))
        schedulers.drain()

        assertEquals(0, transport.workerRequests)
    }

    @Test
    fun `signing out stops the stream and drops the ids`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, store, stream)
        model.onUserChanged("user_1")
        store.replace(setOf("task_1"))

        model.onSignedOut()

        assertEquals(1, stream.stopCount)
        // Ids are not account-scoped and the cookie is gone, so nothing here is
        // any longer knowable, and nothing may show against the next account.
        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `signing out through the account hook does the same thing`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, store, stream)
        model.onUserChanged("user_1")
        store.replace(setOf("task_1"))

        model.onUserChanged(null)

        assertEquals(1, stream.stopCount)
        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `a stopped stream can be started again on the next sign-in`() = modelTest { schedulers ->
        val stream = FakeEventStream()
        val model = model(schedulers.ioDispatcher, stream = stream)

        model.onUserChanged("user_1")
        model.onUserChanged(null)
        model.onUserChanged("user_1")

        assertEquals(2, stream.startCount)
    }

    @Test
    fun `an unreachable server is not a crash`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val stream = FakeEventStream()
        val offline = object : AuthTransport {
            override fun post(path: String, body: String, headers: Map<String, String>) =
                throw IOException("offline")

            override fun get(path: String, headers: Map<String, String>) =
                throw IOException("offline")
        }
        val model = model(schedulers.ioDispatcher, store, stream, offline)
        model.onUserChanged("user_1")

        stream.state(ChatStreamState.Live)
        schedulers.drain()

        assertTrue(store.runningSessionIds.value.isEmpty())
    }
}
