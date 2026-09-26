package com.nalar.mobile.chat

import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.SessionStore
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
 * [BufferedReader.readLine] is not interruptible, so [stop] disconnects the
 * socket to unblock it AND bumps a token that the old pump checks — otherwise
 * the woken thread sees a cleared "stopped" flag, reconnects, and runs beside
 * its replacement, appending every chunk twice for the rest of the process.
 */
class HttpChatEventStream(
    private val sessionStore: SessionStore,
    baseUrl: String = AuthConfig.BASE_URL,
    private val reconnectDelayMillis: Long = DEFAULT_RECONNECT_DELAY_MILLIS,
) : ChatEventStream {
    private val normalizedBaseUrl = baseUrl.trimEnd('/')
    private val lock = Any()

    private var worker: Thread? = null
    private var running = false
    private var token = 0
    private var openConnection: HttpURLConnection? = null

    override fun start(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ) {
        val thread = synchronized(lock) {
            // Starting while one is already up is a caller bug, but silently
            // keeping the old callbacks would be worse: the new chat would look
            // connected while receiving another chat's events.
            if (running) return
            running = true
            Thread({ pump(++token, onEvent, onState) }, "nalar-chat-sse")
                .also { worker = it }
        }
        thread.isDaemon = true
        thread.start()
    }

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
        runCatching { toClose?.disconnect() }
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
                    runCatching { connection.disconnect() }
                    synchronized(lock) { if (token == myToken) openConnection = null }
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

    private fun open(): HttpsURLConnection {
        val connection = URL(normalizedBaseUrl + ChatApi.eventsPath())
            .openConnection() as HttpsURLConnection
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
