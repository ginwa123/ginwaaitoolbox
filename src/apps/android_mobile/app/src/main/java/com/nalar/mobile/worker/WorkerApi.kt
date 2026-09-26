package com.nalar.mobile.worker

import org.json.JSONObject

/**
 * The agentic loop's run state: which sessions currently have a live worker.
 *
 * A session is "running" exactly when a row exists in the backend's `worker`
 * table keyed on `id == session_id`. There is no boolean to read — the backend
 * hardcodes `status: "running"` and `is_running: true` for every row it
 * returns — so the *presence* of the row is the whole signal, and that is what
 * [parseRunningSessionIds] projects the response down to.
 *
 * Two endpoints feed the same set, for the same reason the desktop app uses
 * two: the list is the truth at a point in time, and the stream is what keeps
 * it true. Either alone is wrong — a list alone never sees a run that starts
 * after it was fetched, and a stream alone never sees a run that was already
 * going when the app opened, because the backend keeps no replay buffer.
 */
object WorkerApi {
    /**
     * The server's own default, kept explicit so the URL is legible in the
     * network inspector. It *is* a real ceiling: with more concurrent workers
     * than the limit, the tail of the list is silently dropped on every
     * resync, so this is worth raising before a busy server is the common case
     * rather than after.
     */
    const val WORKERS_PAGE_LIMIT = 50

    fun workersPath(limit: Int = WORKERS_PAGE_LIMIT): String =
        "/api/workers?limit=$limit"

    /**
     * The `workers` channel on its own, not added to [com.nalar.mobile.chat.ChatApi.eventsPath].
     *
     * The chat stream is opened by [com.nalar.mobile.chat.ChatViewModel.openSession],
     * which only runs once a chat is on screen — and the sidebar, which is
     * where a per-session indicator is most useful, is on screen precisely
     * when no chat is open. Reusing that stream would therefore report "nothing
     * is running" at exactly the moment the user is scanning the list for what
     * is running.
     */
    fun eventsPath(): String = "/api/events?channels=workers"

    /**
     * Projects the workers envelope down to the ids that mean "busy".
     *
     * `session_id` is preferred and `id` is the fallback, because the two are
     * the same value in practice but not every emitter sends both — the delete
     * paths send an empty `session_id` and put the session in `id`. Reading
     * `session_id` alone is how a spinner stays lit forever after the run it
     * was describing finished.
     */
    fun parseRunningSessionIds(body: String): Set<String> {
        val workers = JSONObject(body).optJSONArray("workers") ?: return emptySet()
        val ids = LinkedHashSet<String>(workers.length())
        for (index in 0 until workers.length()) {
            val row = workers.optJSONObject(index) ?: continue
            val sessionId = row.optStringOrEmpty("session_id")
                .ifEmpty { row.optStringOrEmpty("id") }
            if (sessionId.isNotEmpty()) ids += sessionId
        }
        return ids
    }

    private fun JSONObject.optStringOrEmpty(name: String): String {
        if (!has(name) || isNull(name)) return ""
        return optString(name).takeIf { it != "null" }.orEmpty()
    }
}
