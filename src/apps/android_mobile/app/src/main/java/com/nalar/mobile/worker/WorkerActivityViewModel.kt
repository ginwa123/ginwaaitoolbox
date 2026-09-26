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
import com.nalar.mobile.chat.ChatEventStream
import com.nalar.mobile.chat.ChatResult
import com.nalar.mobile.chat.ChatStreamEvent
import com.nalar.mobile.chat.ChatStreamState
import com.nalar.mobile.chat.HttpChatEventStream
import com.nalar.mobile.network.RecordingAuthTransport
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Keeps [RunningSessionsStore] in step with the backend's `worker` table for the
 * whole app, not for one screen.
 *
 * This is a ViewModel rather than state inside `ChatViewModel` because the chat
 * stream only exists while a chat is open — `ChatViewModel.openSession` is what
 * starts it — and the sidebar, which is on screen precisely when no chat is
 * open, is where a per-session "busy" marker is most wanted. Reusing the chat
 * stream would report "nothing is running" exactly when the user is scanning
 * the list for what is running, so this subscribes to the `workers` channel on
 * its own connection instead.
 *
 * Two sources, because neither alone is correct. The stream keeps the set true
 * as runs start and stop; `GET /api/workers` re-runs on every (re)connect,
 * because the server keeps no replay buffer and a socket that dropped mid-run
 * has no way to be asked what it missed. The desktop's `fetchInitialWorkers`
 * does the same thing, throttle and all.
 */
class WorkerActivityViewModel(
    private val client: ChatClient,
    private val store: RunningSessionsStore,
    private val eventStream: ChatEventStream,
    // Injected so tests can drive the resync on the same scheduler as the
    // stream callbacks; `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    val runningSessionIds: StateFlow<Set<String>> = store.runningSessionIds

    private var resyncJob: Job? = null
    private var streaming = false
    private var lastResyncAtMillis = 0L

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
            stop()
        } else if (!streaming) {
            start()
        }
    }

    /** Sign-out. The ids are not account-scoped, so they cannot outlive the cookie. */
    fun onSignedOut() = stop()

    private fun start() {
        streaming = true
        eventStream.start(
            onEvent = { event -> handleEvent(event) },
            onState = { state -> handleState(state) },
        )
    }

    private fun stop() {
        if (!streaming) return
        streaming = false
        resyncJob?.cancel()
        resyncJob = null
        eventStream.stop()
        lastResyncAtMillis = 0L
        store.clear()
    }

    override fun onCleared() {
        eventStream.stop()
        super.onCleared()
    }

    private fun handleEvent(event: ChatStreamEvent) {
        if (event is ChatStreamEvent.WorkerChanged) {
            store.apply(event.action, event.sessionId)
        }
    }

    private fun handleState(state: ChatStreamState) {
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
     * (the clock starts at zero) and only a rapid reconnect is skipped.
     */
    private fun resync() {
        val now = nowMillis()
        if (now - lastResyncAtMillis < RESYNC_THROTTLE_MILLIS) return
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
                    eventStream = HttpChatEventStream(
                        sessionStore = sessionStore,
                        path = WorkerApi.eventsPath(),
                    ),
                )
            }
        }
    }
}
