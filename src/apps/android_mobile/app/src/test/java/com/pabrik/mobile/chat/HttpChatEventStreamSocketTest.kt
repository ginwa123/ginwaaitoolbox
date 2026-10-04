package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.SessionStore
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.BufferedReader
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The SSE pump, driven against a real socket.
 *
 * Every other test in this package feeds the *parser* a string. None of them
 * touch [HttpChatEventStream], which is where the connection actually lives —
 * and "the chat never updates" is a statement about the pump, not about the
 * parser. The bytes below are the ones a real `GET /api/events` sends, copied
 * from kabelweb's `http_server.zig` SSE preamble plus a live capture, framing
 * included:
 *
 *   HTTP/1.1 200 OK
 *   Content-Type: text/event-stream
 *   Cache-Control: no-cache
 *   Connection: close
 *   Transfer-Encoding: chunked
 *   X-Accel-Buffering: no
 *   Access-Control-Allow-Origin: *
 *
 * Reproducing the preamble *and* the chunked framing is the point. A pump that
 * assumes a `Content-Length`, or that trips over `Connection: close`, passes
 * every string-fed test and delivers nothing on a phone.
 */
class HttpChatEventStreamSocketTest {

    companion object {
        /**
         * Every case here has a hard deadline, and the deadline is JUnit's
         * rather than the test's.
         *
         * *That is the whole point.* The regression these pin is a
         * **deadlock**: on the unfixed pump, `stop()` parks inside
         * `HttpURLConnection.disconnect()` while the pump thread is inside
         * the very socket read it is waiting on, and the test never
         * returns. A suite that hangs is a suite CI eventually stops
         * reading, so the failure has to be a red test with a stack trace
         * rather than a build that quietly times out.
         */
        const val TEST_TIMEOUT_MILLIS = 45_000L
    }

    private lateinit var server: ServerSocket
    private lateinit var serverThread: Thread
    private val sockets = CopyOnWriteArrayList<Socket>()
    private val streams = CopyOnWriteArrayList<StreamScript>()

    @Volatile
    private var accepted = 0

    /** What one accepted connection should write, as raw bytes to hand to the socket. */
    private data class StreamScript(val frames: List<String>, val keepOpen: Boolean = true)

    private val store = object : SessionStore {
        override fun read(): String? = "test-cookie"
        override fun save(cookieValue: String) = Unit
        override fun clear() = Unit
    }

    @Before
    fun startServer() {
        server = ServerSocket(0)
        serverThread = Thread {
            while (!server.isClosed) {
                val socket = try {
                    server.accept()
                } catch (_: Exception) {
                    return@Thread
                }
                accepted++
                sockets.add(socket)
                // Read the request head so the client's write completes, then
                // reply. Never read past the blank line: the client sends no
                // body and nothing more.
                Thread {
                    try {
                        val reader = BufferedReader(socket.getInputStream().reader())
                        var line = reader.readLine()
                        while (line != null && line.isNotEmpty()) line = reader.readLine()
                        val script = streams.getOrElse(accepted - 1) {
                            StreamScript(listOf(headers, connected))
                        }
                        socket.getOutputStream().write(script.frames.joinToString("").toByteArray())
                        socket.getOutputStream().flush()
                        if (!script.keepOpen) socket.close()
                    } catch (_: Exception) {
                        // The client hung up; nothing to do.
                    }
                }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }
        serverThread.start()
    }

    @After
    fun stopServer() {
        runCatching { sockets.forEach { it.close() } }
        runCatching { server.close() }
    }

    private fun baseUrl() = "http://127.0.0.1:${server.localPort}"

    private fun awaitEvents(
        events: List<ChatStreamEvent>,
        states: List<ChatStreamState>,
        count: Int,
        timeoutMillis: Long = 8_000,
    ) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (events.size >= count) return
            Thread.sleep(25)
        }
        fail("timed out waiting for $count events; got ${events.size}: $events; states=$states")
    }

    private fun stream(reconnectDelayMillis: Long = 50L) =
        HttpChatEventStream(
            sessionStore = store,
            // A provider, not a captured host: this stream reconnects against
            // whatever it names at connect time, which is the same rule
            // production relies on for a mid-session server change.
            baseUrlProvider = { baseUrl() },
            reconnectDelayMillis = reconnectDelayMillis,
        )

    // ── the wire bytes, verbatim ──────────────────────────────────────────

    /**
     * One `Transfer-Encoding: chunked` SSE frame, the way `SseManager` writes
     * it: `<hex len>\r\n<payload>\r\n`.
     */
    private fun chunk(payload: String): String {
        val bytes = payload.toByteArray()
        return "${Integer.toHexString(bytes.size)}\r\n$payload\r\n"
    }

    private val headers = buildString {
        append("HTTP/1.1 200 OK\r\n")
        append("Content-Type: text/event-stream\r\n")
        append("Cache-Control: no-cache\r\n")
        append("Connection: close\r\n")
        append("Transfer-Encoding: chunked\r\n")
        append("X-Accel-Buffering: no\r\n")
        append("Access-Control-Allow-Origin: *\r\n")
        append("\r\n")
    }

    private val connected = chunk("event: connected\ndata: {\"connected\": true}\n\n")

    private fun llmChunkFrame(sessionId: String, content: String): String {
        val json = JSONObject()
            .put("index", 0)
            .put("content", content)
            .put("type", "chunk")
            .put("session_id", sessionId)
        return chunk("event: llm_chunk\ndata: $json\n\n")
    }

    // ── tests ──────────────────────────────────────────────────────────────

    /**
     * The headline regression: a stream that is connected and receiving
     * delivers nothing.
     *
     * Every `decodeChatFrame` case in `ChatEventStreamTest` passes against a
     * string, which is exactly why this had to be driven through a socket —
     * the failure mode is a pump that never gets past the handshake.
     */
    @Test(timeout = TEST_TIMEOUT_MILLIS)
    fun `the handshake and a delta both arrive over a chunked socket`() {
        streams.add(
            StreamScript(
                listOf(headers, connected, llmChunkFrame("sess_1", "Hel"), llmChunkFrame("sess_1", "lo")),
            ),
        )
        val events = CopyOnWriteArrayList<ChatStreamEvent>()
        val states = CopyOnWriteArrayList<ChatStreamState>()
        val pump = stream()

        pump.start(onEvent = { events.add(it) }, onState = { states.add(it) })
        try {
            awaitEvents(events, states, count = 2)
        } finally {
            pump.stop()
        }

        assertEquals(ChatStreamEvent.Connected, events[0])
        val chunkEvent = events[1] as ChatStreamEvent.Chunk
        assertEquals("sess_1", chunkEvent.sessionId)
        assertEquals("Hel", chunkEvent.content)
        assertTrue(
            "the pump never reported Live: $states",
            states.any { it is ChatStreamState.Live },
        )
    }

    /**
     * A pretty-printed payload arrives as several `data:` lines, which is how
     * *every* real `llm_full` is framed. The pump has to rejoin them before
     * the decode can see a JSON object at all.
     */
    @Test(timeout = TEST_TIMEOUT_MILLIS)
    fun `a pretty-printed full frame is rejoined across its data lines`() {
        val payload = """
            {
                "id": "m1",
                "index": 0,
                "content": "the answer",
                "type": "full",
                "session_id": "sess_1",
                "role": "assistant",
                "finish_reason": "stop",
                "tool_call_id": "",
                "tool_name": "",
                "is_error": false
            }
        """.trimIndent()
        val framed = buildString {
            append("event: llm_full\n")
            payload.lines().forEach { append("data: $it\n") }
            append("\n")
        }
        streams.add(StreamScript(listOf(headers, connected, chunk(framed))))
        val events = CopyOnWriteArrayList<ChatStreamEvent>()
        val states = CopyOnWriteArrayList<ChatStreamState>()
        val pump = stream()

        pump.start(onEvent = { events.add(it) }, onState = { states.add(it) })
        try {
            awaitEvents(events, states, count = 2)
        } finally {
            pump.stop()
        }

        val full = events[1] as ChatStreamEvent.Full
        assertEquals("m1", full.message.id)
        assertEquals("the answer", full.message.content)
    }

    /**
     * The heartbeat is an unnamed `data: ping` frame. It must not be mistaken
     * for a payload, and — the part that matters — it must not stop the pump.
     */
    @Test(timeout = TEST_TIMEOUT_MILLIS)
    fun `a heartbeat between frames does not stop the stream`() {
        streams.add(
            StreamScript(
                listOf(
                    headers,
                    connected,
                    chunk("data: ping\n\n"),
                    llmChunkFrame("sess_1", "after the ping"),
                ),
            ),
        )
        val events = CopyOnWriteArrayList<ChatStreamEvent>()
        val states = CopyOnWriteArrayList<ChatStreamState>()
        val pump = stream()

        pump.start(onEvent = { events.add(it) }, onState = { states.add(it) })
        try {
            awaitEvents(events, states, count = 2)
        } finally {
            pump.stop()
        }

        assertEquals("the ping was decoded as an event: $events", 2, events.size)
        assertEquals("after the ping", (events[1] as ChatStreamEvent.Chunk).content)
    }
    /**
     * The server drops the connection. The pump has to come back on its own —
     * an SSE stream has no replay buffer, so "give up" means the chat is dead
     * until the reader switches chats.
     */
    @Test(timeout = TEST_TIMEOUT_MILLIS)
    fun `a dropped connection is reconnected rather than abandoned`() {
        streams.add(
            StreamScript(
                listOf(headers, connected, llmChunkFrame("sess_1", "before")),
                keepOpen = false,
            ),
        )
        streams.add(StreamScript(listOf(headers, connected, llmChunkFrame("sess_1", "after"))))
        val events = CopyOnWriteArrayList<ChatStreamEvent>()
        val states = CopyOnWriteArrayList<ChatStreamState>()
        val pump = stream()

        pump.start(onEvent = { events.add(it) }, onState = { states.add(it) })
        try {
            awaitEvents(events, states, count = 3, timeoutMillis = 10_000)
        } finally {
            pump.stop()
        }

        val contents = events.filterIsInstance<ChatStreamEvent.Chunk>().map { it.content }
        assertEquals(listOf("before", "after"), contents)
    }

    /**
     * Switching chats stops the old stream and starts a new one, and the new
     * one has to be the one that is actually reading.
     *
     * This is the sequence a reader performs every time they tap another chat
     * in the drawer, so a stream that is left "running" by a stopped pump makes
     * the next chat receive nothing at all — which is indistinguishable, from
     * the screen, from the server having gone quiet.
     */
    @Test(timeout = TEST_TIMEOUT_MILLIS)
    fun `a restart after stop delivers into the new callbacks`() {
        streams.add(StreamScript(listOf(headers, connected, llmChunkFrame("sess_1", "first"))))
        streams.add(StreamScript(listOf(headers, connected, llmChunkFrame("sess_2", "second"))))
        val pump = stream()

        val firstEvents = CopyOnWriteArrayList<ChatStreamEvent>()
        val firstStates = CopyOnWriteArrayList<ChatStreamState>()
        pump.start(onEvent = { firstEvents.add(it) }, onState = { firstStates.add(it) })
        awaitEvents(firstEvents, firstStates, count = 2)
        pump.stop()

        val secondEvents = CopyOnWriteArrayList<ChatStreamEvent>()
        val secondStates = CopyOnWriteArrayList<ChatStreamState>()
        // Give the stopped pump a moment to unwind, which is the window a
        // user-driven chat switch lands in.
        Thread.sleep(150)
        pump.start(onEvent = { secondEvents.add(it) }, onState = { secondStates.add(it) })
        try {
            awaitEvents(secondEvents, secondStates, count = 2, timeoutMillis = 10_000)
        } finally {
            pump.stop()
        }

        val chunkEvent = secondEvents[1] as ChatStreamEvent.Chunk
        assertEquals("sess_2", chunkEvent.sessionId)
        assertEquals("second", chunkEvent.content)
    }

    /**
     * A non-2xx handshake is terminal by design (the pump must not burn the
     * radio retrying a rejected cookie), and the *message* is what the chat
     * shows. A pump that silently swallows the status leaves the header reading
     * "Connecting…" for the life of the process.
     */
    @Test(timeout = TEST_TIMEOUT_MILLIS)
    fun `a rejected handshake reports the status instead of hanging`() {
        val rejected = buildString {
            append("HTTP/1.1 401 Unauthorized\r\n")
            append("Content-Type: application/json\r\n")
            append("Content-Length: 2\r\n")
            append("Connection: close\r\n")
            append("\r\n")
            append("{}")
        }
        streams.add(StreamScript(listOf(rejected)))
        val states = CopyOnWriteArrayList<ChatStreamState>()
        val events = CopyOnWriteArrayList<ChatStreamEvent>()
        val pump = stream()

        pump.start(onEvent = { events.add(it) }, onState = { states.add(it) })
        try {
            val deadline = System.currentTimeMillis() + 8_000
            while (System.currentTimeMillis() < deadline && states.none { it is ChatStreamState.Failed }) {
                Thread.sleep(25)
            }
        } finally {
            pump.stop()
        }

        val failure = states.filterIsInstance<ChatStreamState.Failed>().firstOrNull()
        assertTrue("no Failed state; states=$states", failure != null)
        assertTrue(
            "the status is not in the message: ${failure!!.message}",
            failure.message.contains("401"),
        )
    }

    /**
     * A reader who leaves the chat and comes back must get a working stream
     * again. `ChatViewModel.openSession` does exactly stop-then-start, and the
     * pump's own bookkeeping has to survive it.
     */
    @Test(timeout = TEST_TIMEOUT_MILLIS)
    fun `start stop start stop leaves the pump usable`() {
        val scripts = (1..3).map { n ->
            StreamScript(listOf(headers, connected, llmChunkFrame("sess_$n", "turn $n")))
        }
        streams.addAll(scripts)
        val pump = stream()

        repeat(3) { round ->
            val events = CopyOnWriteArrayList<ChatStreamEvent>()
            val states = CopyOnWriteArrayList<ChatStreamState>()
            pump.start(onEvent = { events.add(it) }, onState = { states.add(it) })
            try {
                awaitEvents(events, states, count = 2)
                assertEquals("turn ${round + 1}", (events[1] as ChatStreamEvent.Chunk).content)
            } finally {
                pump.stop()
            }
            Thread.sleep(100)
        }
    }
}
