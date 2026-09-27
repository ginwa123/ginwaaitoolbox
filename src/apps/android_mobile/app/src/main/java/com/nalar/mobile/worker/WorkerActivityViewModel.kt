package com.nalar.mobile.worker

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.HttpsAuthTransport
import com.nalar.mobile.auth.SessionCookieStore
import com.nalar.mobile.chat.ChatClient
import com.nalar.mobile.chat.ChatResult
import com.nalar.mobile.chat.ChatStreamEvent
import com.nalar.mobile.chat.ChatStreamState
import com.nalar.mobile.chat.SseBus
import com.nalar.mobile.chat.SseBusHolder
import com.nalar.mobile.network.RecordingAuthTransport
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Keeps [RunningSessionsStore] in step with the backend's `worker` table for the
 * whole app, not for one screen.
 *
 * The two surfaces that need it are never on screen together: the sidebar lives
 * on the shell route and the chat header on the chat route, and navigating to
 * one replaces the other. So the set lives beside
 * [com.nalar.mobile.chat.ChatViewModel] as its own ViewModel, and both are fed
 * by the root [SseBus] that [com.nalar.mobile.MainActivity] opens at sign-in.
 *
 * Three sources, because no two of them are correct. The bus keeps the set true
 * as runs start and stop; `GET /api/workers` re-runs on every reconnect, because
 * the server keeps no replay buffer and a socket that dropped mid-run has no way
 * to be asked what it missed; and a periodic beat plus [onForeground] cover the
 * case the other two both miss - a `worker_deleted` that was emitted while the
 * app was backgrounded, which the socket never dispatches to a collector that
 * was not running and never re-opens to correct. The desktop's
 * `fetchInitialWorkers` does the first two and neither of the others, which is
 * why the desktop has the same stuck spinner.
 */
class WorkerActivityViewModel(
    private val client: ChatClient,
    private val store: RunningSessionsStore,
    /**
     * The app's ONE event connection, shared with the chat.
     *
     * Subscribed once, in `init`. This class no longer owns a socket, which is
     * why its job narrowed to what a socket cannot do: keeping [store] honest
     * against the REST list on a timer and on the way back into the app.
     */
    private val bus: SseBus,
    // Injected so tests can drive the resync on the same scheduler as the
    // stream callbacks; `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    /**
     * The periodic reconciliation beat, as a stream of ticks.
     *
     * Injected rather than hard-coded as a `while (isActive) { delay(...) }`
     * loop for one reason: a self-rescheduling `delay()` never lets
     * `kotlinx-coroutines-test`'s `advanceUntilIdle` settle, so a default here
     * would hang every JVM test that constructs this class. A test passes
     * `emptyFlow()` to switch the beat off, or a finite flow to drive it.
     */
    private val resyncTicks: Flow<Unit> = flow {
        while (currentCoroutineContext().isActive) {
            delay(RESYNC_INTERVAL_MILLIS)
            emit(Unit)
        }
    },
) : ViewModel() {
    val runningSessionIds: StateFlow<Set<String>> = store.runningSessionIds

    private var resyncJob: Job? = null
    private var tickJob: Job? = null
    private var tracked = false
    private var lastResyncAtMillis = 0L
    private var currentUserId: String? = null
    private var unsubscribeFromBus: (() -> Unit)? = null

    init {
        unsubscribeFromBus = bus.subscribe(
            onEvent = { event -> handleEvent(event) },
            onState = { state -> handleState(state) },
        )
    }

    /**
     * Starts the subscription, or tears it down when nobody is signed in.
     *
     * Gated on the account because the transport is a cookie, and the pump
     * treats any non-2xx handshake as terminal — it reports the failure and
     * returns rather than retrying. Started before sign-in it would open once,
     * be rejected, and never recover, which looks exactly like "no worker has
     * ever run".
     */
    fun onUserChanged(newUserId: String?) {
        if (newUserId.isNullOrBlank()) {
            stopTracking()
            // Not reset by `stopTracking()` itself, because it short-circuits
            // when nothing is being tracked.
            currentUserId = null
            return
        }
        if (newUserId == currentUserId) {
            if (!tracked) startTracking()
            return
        }
        // A *different* account is as much a teardown as a sign-out. The ids in
        // the store are not account-scoped, so carrying them across the switch
        // paints the outgoing account's "running" markers against the incoming
        // account's chats.
        stopTracking()
        currentUserId = newUserId
        startTracking()
    }

    /** Sign-out. The ids are not account-scoped, so they cannot outlive the cookie. */
    fun onSignedOut() {
        stopTracking()
        currentUserId = null
    }

    /**
     * Re-reads the list on the way back into the app, ignoring the throttle.
     *
     * Coming back is the moment the set is most visible and least
     * trustworthy: the workers socket was open the whole time the app was away,
     * so a run that ended while it was backgrounded left no `worker_deleted`
     * for this process to apply, and no reconnect is coming to correct it. The
     * throttle exists to stop a flapping connection turning every retry into a
     * request — it has nothing to say about a user who just opened the app.
     */
    fun onForeground() {
        if (!tracked) return
        resync(force = true)
    }

    /**
     * Starts the reconciliation beat for a signed-in account.
     *
     * Named for what it does rather than `start()`, because it no longer starts
     * anything a socket needs: the bus is opened by `MainActivity` off the same
     * `authState.userId`. Only the periodic REST resync is this class's.
     */
    private fun startTracking() {
        tracked = true
        tickJob?.cancel()
        tickJob = viewModelScope.launch {
            resyncTicks.collect { resync() }
        }
    }

    private fun stopTracking() {
        if (!tracked) return
        tracked = false
        resyncJob?.cancel()
        resyncJob = null
        tickJob?.cancel()
        tickJob = null
        lastResyncAtMillis = 0L
        store.clear()
    }

    override fun onCleared() {
        // `stopTracking()` alone is not enough: it returns early when nothing is
        // being tracked, and the store is a process-wide singleton, so an
        // Activity destroyed while the process survives would leave its last set
        // published for whatever Activity is created next.
        stopTracking()
        store.clear()
        unsubscribeFromBus?.invoke()
        unsubscribeFromBus = null
        super.onCleared()
    }

    /**
     * The set is only *ours* to maintain while an account is signed in.
     *
     * The bus is subscribed for the life of the process, so without this guard a
     * `worker_created` that arrived between sign-out and the next sign-in would
     * repaint a set the next account then inherited. In production the bus is
     * closed at sign-out and cannot emit at all; the guard is what makes that
     * true by construction rather than by ordering.
     */
    private fun handleEvent(event: ChatStreamEvent) {
        if (!tracked) return
        if (event is ChatStreamEvent.WorkerChanged) {
            store.apply(event.action, event.sessionId)
        }
    }

    private fun handleState(state: ChatStreamState) {
        if (!tracked) return
        // Every transition back to Live — including the first connect — is a
        // moment where the set is possibly wrong: runs that started or stopped
        // while the socket was down left no trace to apply. The list is the only
        // thing that can correct it.
        if (state is ChatStreamState.Live) resync()
    }

    /**
     * Replaces the set with what the server reports *now*.
     *
     * Throttled because a flapping connection reaches `Live` on a two-second
     * backoff, and the resync is a real request. The throttle is not a
     * staleness budget, it is a rate limit: the first connect always fetches
     * (the clock starts at zero) and only a rapid reconnect is skipped. The
     * interval is longer than the throttle, so the periodic beat is never the
     * thing that gets skipped.
     */
    private fun resync(force: Boolean = false) {
        val now = nowMillis()
        if (!force && now - lastResyncAtMillis < RESYNC_THROTTLE_MILLIS) return
        lastResyncAtMillis = now

        resyncJob?.cancel()
        resyncJob = viewModelScope.launch {
            when (val result = withContext(ioDispatcher) { client.loadRunningSessions() }) {
                is ChatResult.Loaded -> store.replace(result.value)

                // A failed resync leaves the set exactly as it was. Emptying it
                // would be the tempting repair and the wrong one: a spinner that
                // clears because the network blipped is the same lie as one
                // that never lights up.
                is ChatResult.SignedOut,
                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> Unit
            }
        }
    }

    companion object {
        /** Matches the desktop's `lastWorkersFetchAt` guard. */
        const val RESYNC_THROTTLE_MILLIS = 10_000L

        /**
         * How often the set is re-read while nothing else has prompted it.
         *
         * Deliberately far above the throttle and far below the point where a
         * stale spinner becomes the thing a user reports: a run that ended
         * while the app was backgrounded is corrected within half a minute of
         * the app being used again, without a reconnect that may never come.
         */
        const val RESYNC_INTERVAL_MILLIS = 30_000L

        fun factory(application: Application): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val sessionStore = SessionCookieStore(application)
                WorkerActivityViewModel(
                    client = ChatClient(
                        sessionStore = sessionStore,
                        // Recorded like auth, so the inspector shows the exact
                        // bytes this sent.
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport(AuthConfig.BASE_URL),
                        ),
                    ),
                    store = RunningSessionsStore.default,
                    bus = SseBusHolder.get(sessionStore),
                )
            }
        }
    }
}
