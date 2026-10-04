package com.pabrik.mobile.worker

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The app-wide set of sessions with a live worker — the one place that knows
 * which chats are busy, for the whole process rather than for one screen.
 *
 * It is a process-wide singleton rather than ViewModel state because the two
 * surfaces that need it are never on screen together: the sidebar lives on the
 * shell route and the chat header on the chat route, and navigating to one
 * replaces the other. A store per ViewModel would mean the sidebar cannot see
 * a run that started while a chat was open, and vice versa.
 *
 * [RunningSessionsStore.default] is the production instance and every consumer
 * takes it as a defaulted constructor parameter, so a JVM test gets a fresh
 * empty store without any of them having to know about the singleton. Same
 * shape as `NetworkLogStore`.
 *
 * Every mutation is a whole-set replacement rather than an in-place edit: the
 * backing [MutableStateFlow] compares by equality, so rebuilding the set is
 * what makes a re-composition happen, and a `MutableSet` mutated behind a
 * `StateFlow` would emit an identical value and render nothing.
 */
class RunningSessionsStore {
    private val _runningSessionIds = MutableStateFlow<Set<String>>(emptySet())

    /** Session ids of every run currently in flight. */
    val runningSessionIds: StateFlow<Set<String>> = _runningSessionIds.asStateFlow()

    /**
     * Folds one worker lifecycle event into the set.
     *
     * `deleted` removes and everything else adds, which is the desktop's rule
     * (`App.vue`'s `handleWorkerEvent`). Only `deleted` is a *removal*, so an
     * action this app has never heard of — `worker_unknown` is a real event
     * name for exactly that — is treated as liveness rather than dropped: a
     * run we cannot classify is a run we must not report as idle.
     */
    fun apply(action: String, sessionId: String) {
        if (sessionId.isEmpty()) return
        val current = _runningSessionIds.value
        if (action == ACTION_DELETED) {
            if (sessionId !in current) return
            _runningSessionIds.value = current - sessionId
        } else {
            if (sessionId in current) return
            _runningSessionIds.value = current + sessionId
        }
    }

    /**
     * Replaces the set wholesale from a [WorkerApi] bootstrap.
     *
     * Replaces rather than merges, deliberately. This runs on every stream
     * (re)connect, and the only thing that can correct events missed while the
     * socket was down is a list of what is *actually* running now — merging
     * would keep every run that stopped while the app was disconnected lit
     * forever, which is the one failure a spinner must never have.
     */
    fun replace(sessionIds: Set<String>) {
        if (_runningSessionIds.value == sessionIds) return
        _runningSessionIds.value = sessionIds
    }

    /**
     * Drops every session. Called on sign-out: the ids are not account-scoped
     * and the cookie is about to go, so nothing here is any longer knowable and
     * nothing may be shown against the next account's session.
     */
    fun clear() {
        if (_runningSessionIds.value.isEmpty()) return
        _runningSessionIds.value = emptySet()
    }

    fun isRunning(sessionId: String?): Boolean =
        sessionId != null && sessionId in _runningSessionIds.value

    companion object {
        const val ACTION_CREATED = "created"
        const val ACTION_UPDATED = "updated"
        const val ACTION_DELETED = "deleted"

        val default = RunningSessionsStore()
    }
}
