package com.nalar.mobile.chat

import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.SessionStore
import com.nalar.mobile.server.requireUsableBaseUrl
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/**
 * The chat's live connection to `GET /api/events`.
 *
 * An interface rather than a concrete class so the ViewModel's streaming paths
 * are testable on the JVM without a server, and so the connection lifecycle is
 * owned by the ViewModel's scope rather than by a static singleton.
 */
interface ChatEventStream {
    fun start(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    )

    fun stop()
}

/**
 * SSE over [HttpsURLConnection].
 *
 * Deliberately not routed through [com.nalar.mobile.auth.AuthTransport]: that
 * transport reads a request to completion, and a stream never completes. It is
 * also not recorded by the network inspector, for the same reason — a
 * half-consumed infinite body would pin a record open for the life of the
 * session. Every other chat call still goes through the transport and is
 * captured.
 *
 * Reconnect is unconditional and has no resume: the server emits no `id:`
 * frames, keeps no replay buffer, and exposes no `since` parameter. Every
 * reconnect therefore costs a full refetch of the tail, which is why
 * [ChatViewModel] refetches on the [ChatStreamState.Live] transition rather than
 * trying to stitch a gap.
 *
 * The lifecycle is token-based rather than a boolean. A thread blocked on
 * [BufferedReader.readLine] is not interruptible, so [stop] bumps a token that
 * the old pump re-checks on every wake — otherwise the woken thread sees a
 * cleared "stopped" flag, reconnects, and runs beside its replacement,
 * appending every chunk twice for the rest of the process. The token is
 * claimed in [start], under the lock, so a replacement can never be handed a
 * token its predecessor is about to take.
 *
 * [stop] additionally closes the socket, but **not on the caller's thread**:
 * `disconnect()` on a chunked response contends for a lock the reading thread
 * is holding, and the ViewModel calls [stop] from the main thread. See [stop].
 */
class HttpChatEventStream(
    private val sessionStore: SessionStore,
    private val baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    private val reconnectDelayMillis: Long = DEFAULT_RECONNECT_DELAY_MILLIS,
    /**
     * Which `channels=` set to subscribe to.
     *
     * Everything above the socket is channel-agnostic — same parse, same
     * reconnect, same dispatch — so the only per-subscriber difference is which
     * events the server is asked for. An unknown token terminates the stream
     * outright, so this is spelled out at each call site rather than assembled
     * from a set.
     */
    private val path: String = SseChannels.eventsPath(),
) : ChatEventStream {
    private val lock = Any()

    private var worker: Thread? = null
    private var running = false
    private var token = 0
    private var openConnection: HttpURLConnection? = null

    override fun start(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ) {
        val myToken: Int
        val thread: Thread
        synchronized(lock) {
            // Starting while one is already up is a caller bug, but silently
            // keeping the old callbacks would be worse: the new chat would look
            // connected while receiving another chat's events.
            if (running) return
            running = true
            // Claimed here, not in the thread body. A thread that bumps the
            // token whenever it happens to be scheduled can take the token its
            // own replacement is about to be given, and the replacement then
            // exits before it has opened a socket — a chat that reports
            // "connected" and then never receives a frame.
            myToken = ++token
            thread = Thread({ pump(myToken, onEvent, onState) }, "nalar-chat-sse")
            worker = thread
        }
        thread.isDaemon = true
        thread.start()
    }

    /**
     * Tears the stream down, and returns without waiting for the socket.
     *
     * **The socket must not be closed from here.** `disconnect()` on a chunked
     * response reaches `ChunkedInputStream.close()`, which takes a lock the
     * *reading* thread holds for the whole of every socket read and then drains
     * the remaining chunks hunting for the trailer. Calling it inline parks
     * the caller for as long as the server says nothing — the ~15 s heartbeat
     * for an idle chat, the full read timeout for a socket that died quietly —
     * and [ChatViewModel] calls `stop()` from the main thread on every session
     * switch, immediately *before* it starts the replacement stream. The
     * observed symptom is a chat that never updates: the old pump is already
     * invalidated so it delivers nothing, and the new one does not exist yet
     * because the switch is still parked inside the teardown.
     *
     * The close still has to happen, and only the pump's own exit can finish
     * it without contending for that lock, so it is handed to a thread nobody
     * joins. The pump sees the invalidated token on its next wake, stops
     * dispatching, and closes the connection itself.
     */
    override fun stop() {
        val toClose = synchronized(lock) {
            if (!running) return
            running = false
            // Invalidate the current pump before releasing the socket, so a
            // thread that wakes from its read exits instead of reconnecting.
            token++
            worker = null
            openConnection.also { openConnection = null }
        }
        toClose?.let { connection ->
            Thread({ runCatching { connection.disconnect() } }, "nalar-chat-sse-close")
                .apply { isDaemon = true }
                .start()
        }
    }

    private fun pump(
        myToken: Int,
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ) {
        val parser = SseFrameParser()
        var hasConnectedOnce = false

        try {
            while (isCurrent(myToken)) {
                onState(
                    if (hasConnectedOnce) ChatStreamState.Reconnecting else ChatStreamState.Connecting,
                )

                val connection = try {
                    open()
                } catch (_: Exception) {
                    sleepBackoff(myToken)
                    continue
                }

                var handshakeFailed = false
                try {
                    synchronized(lock) { if (token == myToken) openConnection = connection }

                    val statusCode = connection.responseCode
                    if (statusCode !in 200..299) {
                        // Do NOT loop: a rejected handshake retries forever and
                        // burns the radio. Report it and let the ViewModel show
                        // the message.
                        onState(
                            ChatStreamState.Failed("The event stream is unavailable ($statusCode)."),
                        )
                        handshakeFailed = true
                        return
                    }

                    hasConnectedOnce = true
                    onState(ChatStreamState.Live)

                    BufferedReader(connection.inputStream.reader()).use { reader ->
                        var line = reader.readLine()
                        while (isCurrent(myToken) && line != null) {
                            parser.accept(line)?.let { frame -> dispatch(frame, onEvent) }
                            line = reader.readLine()
                        }
                    }
                } catch (_: Exception) {
                    // Offline, rotated, killed by the system. A reconnect plus a
                    // refetch is the whole recovery story.
                } finally {
                    // Only this pump's own connection, and only while it is
                    // still the current one. A `stop()` that has already taken
                    // the connection away handed it to the closer thread, and
                    // two threads inside one chunked stream's close is the
                    // contention that teardown must not have. Identity rather
                    // than the token, so a reconnecting pump cannot clear the
                    // socket its replacement just opened.
                    val stillOurs = synchronized(lock) { openConnection === connection }
                    if (stillOurs) {
                        synchronized(lock) { openConnection = null }
                        runCatching { connection.disconnect() }
                    }
                    // A socket that died mid-frame would otherwise swallow a
                    // complete-looking payload.
                    parser.flush()?.let { frame -> dispatch(frame, onEvent) }
                }

                if (handshakeFailed || !isCurrent(myToken)) return
                sleepBackoff(myToken)
            }
        } finally {
            // Any exit path releases the slot, so a later start() is not
            // silently refused for the rest of the process.
            synchronized(lock) {
                if (token == myToken) {
                    running = false
                    worker = null
                }
            }
        }
    }

    private fun dispatch(frame: SseFrame, onEvent: (ChatStreamEvent) -> Unit) {
        decodeChatFrame(frame)?.let(onEvent)
    }

    private fun isCurrent(myToken: Int): Boolean = synchronized(lock) {
        running && token == myToken
    }

    private fun sleepBackoff(myToken: Int) {
        if (!isCurrent(myToken)) return
        try {
            Thread.sleep(reconnectDelayMillis)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    /**
     * Opens the request without reading a byte of the body.
     *
     * Typed as [HttpURLConnection] rather than [HttpsURLConnection] because
     * nothing here is TLS-specific — the same six headers and the same cookie
     * are all a stream needs — and the base type is what lets the pump be
     * driven against a plain-HTTP socket in `HttpChatEventStreamSocketTest`.
     * A cast to the https subclass would have made the one layer that actually
     * opens sockets the only layer no test could reach.
     */
    private fun open(): HttpURLConnection {
        // Resolved here, at connect time, not captured at construction. The bus
        // is a process singleton built on the first `SseBusHolder.get(...)`, so
        // a captured host would outlive every change of server the reader makes
        // for the rest of the process — and the reconnect after a switch would
        // go to the deployment they just left.
        val baseUrl = requireUsableBaseUrl(baseUrlProvider())
        val connection = URL(baseUrl + path).openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = CONNECT_TIMEOUT_MILLIS
        // The stream is idle between turns, so a short read timeout would
        // reconnect all evening. This only fires if the socket truly died.
        connection.readTimeout = READ_TIMEOUT_MILLIS
        connection.useCaches = false
        connection.setRequestProperty("Accept", "text/event-stream")
        connection.setRequestProperty("Cache-Control", "no-cache")
        // The session is the `nalar_session` cookie and nothing else.
        sessionStore.read()?.let { cookie ->
            connection.setRequestProperty(
                "Cookie",
                "${AuthConfig.SESSION_COOKIE_NAME}=$cookie",
            )
        }
        return connection
    }

    private companion object {
        const val CONNECT_TIMEOUT_MILLIS = 15_000
        const val READ_TIMEOUT_MILLIS = 120_000
        const val DEFAULT_RECONNECT_DELAY_MILLIS = 2_000L
    }
}
