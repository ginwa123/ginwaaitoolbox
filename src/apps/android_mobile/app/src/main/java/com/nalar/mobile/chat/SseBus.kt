package com.nalar.mobile.chat

import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.SessionStore
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The ONE channel string the whole app listens on.
 *
 * `channels` is required by the endpoint and an unknown token terminates the
 * stream outright, so the set is spelled out here rather than assembled from a
 * collection — a typo has to be a compile error here, not a silently dead
 * socket on a user's phone.
 *
 * `llm` and `queue` are subscribed as bare central keys with no session id.
 * Every subscriber filters by `event.session_id` itself, which is what collapses
 * "one socket per open chat" into one socket for the process.
 */
object SseChannels {
    fun eventsPath(): String = "/api/events?channels=llm,queue,sessions,workers"
}

/**
 * The app's single server-sent-events connection.
 *
 * One socket, many subscribers — the same shape as the web app's
 * `installSseBus()`, and for the same reasons:
 *
 * 1. **Two sockets with two lifetimes was the bug.** The chat stream only
 *    existed while a chat was open, and the workers stream existed for the whole
 *    process. A sidebar asking "is anything running?" is on screen precisely
 *    when no chat is open, so the two could never agree.
 * 2. **A socket is a scarce, shared thing.** The chat stream was stopped and
 *    started on every session switch; a rapid switch-through is a burst of
 *    handshakes against a server that keeps no replay buffer.
 * 3. **One connection means one place to be stale.** The bus knows its own
 *    state, so a reconnect is a single event every subscriber reacts to,
 *    rather than N independent flaps.
 *
 * Deliberately *not* ported from the web bus: the BroadcastChannel
 * leader/follower election, `onResync`, `reconnectGlobal` and the exponential
 * backoff. All of them exist because a browser window can be frozen, throttled,
 * or one of several sharing a 6-connection budget. A phone holds its own
 * connection and cannot miss a delivery; what it can suffer is process death and
 * Doze, which `WorkerActivityViewModel`'s resync beat and its foreground hook
 * already cover against the REST API.
 */
interface SseBus {
    /**
     * The connection's state, as a flow.
     *
     * A `StateFlow` and not a plain value so a subscriber that attaches late
     * learns what the socket is already doing instead of waiting for the next
     * transition that may never come.
     */
    val state: StateFlow<ChatStreamState>

    /**
     * Registers a listener and returns its unsubscribe.
     *
     * The returned function is the ONLY way to detach: [close] closes the
     * socket, it does not clear this list, so a subscriber that outlives a
     * sign-out and comes back is still registered.
     *
     * A new subscriber is immediately handed the *current* [state]. Without
     * that, a chat opened onto an already-live socket would wait for the next
     * `Live` to know it is connected — and the next `Live` is a reconnect, so
     * the "have I missed anything?" flag would start out wrong.
     */
    fun subscribe(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ): () -> Unit

    /** Opens the socket. Idempotent, and gated on there being an account. */
    fun open()

    /** Closes the socket. Idempotent. Subscribers stay registered. */
    fun close()
}

/**
 * The production bus: one [ChatEventStream], fanned out to every subscriber.
 *
 * The fan-out runs on the transport's own thread, so it is synchronous by
 * construction — the same trade the web bus makes. A listener that blocks blocks
 * every other listener, which is why the two subscribers are the two ViewModels
 * and neither does IO in its callback.
 *
 * One listener throwing must not cost the others their event, so each is called
 * inside its own `try`. [CopyOnWriteArrayList] is not decoration: a listener is
 * allowed to unsubscribe itself from inside its own callback, which is exactly
 * what a screen does when it goes away mid-fan-out.
 */
class RootSseBus(
    private val stream: ChatEventStream,
) : SseBus {

    constructor(sessionStore: SessionStore) : this(
        HttpChatEventStream(sessionStore = sessionStore, path = SseChannels.eventsPath()),
    )

    private val subscribers = CopyOnWriteArrayList<Subscriber>()
    private val _state = MutableStateFlow<ChatStreamState>(ChatStreamState.Connecting)

    @Volatile
    private var open = false

    override val state: StateFlow<ChatStreamState> = _state.asStateFlow()

    override fun subscribe(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ): () -> Unit {
        val subscriber = Subscriber(onEvent, onState)
        subscribers.add(subscriber)
        // Seeded outside the lock, and best-effort: a listener that throws on
        // the seed must still be registered, or the subscriber is invisible.
        runCatching { onState(_state.value) }
        return { subscribers.remove(subscriber) }
    }

    override fun open() {
        // The handshake is a cookie the server answers once and never retries,
        // and the pump treats a non-2xx as terminal. Opening this before sign-in
        // would burn the one handshake on a request with no cookie and leave the
        // bus permanently `Failed` — which reads as "no worker has ever run".
        // `MainActivity` is therefore the only caller, gated on `authState.userId`.
        if (open) return
        open = true
        stream.start(
            onEvent = { event -> dispatchEvent(event) },
            // Both halves are load-bearing. The flow is for anyone *collecting*
            // it; the fan-out is for the registered subscribers, and those are
            // registered in each ViewModel's `init` — long before sign-in, which
            // is the only thing that opens this socket. Setting the flow and
            // stopping there leaves every production subscriber pinned at the
            // seed it was handed, so `isLive` never turns green and the worker
            // resync never fires.
            onState = { next -> dispatchState(next) },
        )
    }

    override fun close() {
        if (!open) return
        open = false
        stream.stop()
        // Not `Live` and not `Reconnecting`: the honest value for "there is no
        // socket", so a header showing a green dot is never left behind by a
        // sign-out. Fanned out for the same reason `open` fans out — the
        // subscribers are the ones that render it.
        dispatchState(ChatStreamState.Connecting)
    }

    /** Whether the socket is up. Exposed for the bus's own tests, not for callers. */
    internal val isOpen: Boolean get() = open

    private fun dispatchEvent(event: ChatStreamEvent) {
        // A CopyOnWriteArrayList is safe to iterate while a listener detaches
        // itself below, so no snapshot copy is needed.
        for (subscriber in subscribers) {
            runCatching { subscriber.onEvent(event) }
        }
    }

    private fun dispatchState(next: ChatStreamState) {
        _state.value = next
        for (subscriber in subscribers) {
            runCatching { subscriber.onState(next) }
        }
    }

    private class Subscriber(
        val onEvent: (ChatStreamEvent) -> Unit,
        val onState: (ChatStreamState) -> Unit,
    )
}

/**
 * The production bus, built once for the process.
 *
 * A `remember`-ed object in a composable would be a *screen* singleton, and the
 * two subscribers are never on screen together — the sidebar is on the shell
 * route and the chat header on the chat route, and navigating to one replaces
 * the other. A screen-scoped bus would therefore be destroyed and rebuilt
 * across every navigation, which is the exact churn this class exists to
 * remove.
 */
object SseBusHolder {
    private var instance: SseBus? = null

    fun get(sessionStore: SessionStore): SseBus =
        instance ?: RootSseBus(sessionStore).also { instance = it }

    /**
     * Drops the singleton so a JVM test can install its own.
     *
     * Same shape as the web bus's `__resetSseBus()`: a module-level singleton
     * is the right production design and a test hazard, and the fix is one
     * escape hatch rather than threading an instance through every factory.
     */
    internal fun reset() {
        instance = null
    }
}
