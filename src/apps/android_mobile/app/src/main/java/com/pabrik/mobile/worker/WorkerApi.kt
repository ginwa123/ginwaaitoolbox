package com.pabrik.mobile.worker

import org.json.JSONObject
import java.net.URLEncoder

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
     * The same list narrowed to one session.
     *
     * Separate from [workersPath] rather than a filter the caller applies,
     * because the global list is truncated server-side at [WORKERS_PAGE_LIMIT]
     * and a chat asking "am *I* still running?" from it gets `false` the day
     * the server is busier than the cap — the one wrong answer this class
     * exists to prevent. Asking for one session puts the filter in the query
     * where the server applies it to the *whole* table before the limit bites,
     * so the answer is exact no matter how many workers exist.
     */
    fun workersPathForSession(sessionId: String): String =
        "/api/workers?session_id=${encodeQueryValue(sessionId)}&limit=1"

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    /**
     * Projects the workers envelope down to the ids that mean "busy".
     *
     * `session_id` is preferred and `id` is the fallback, because the two are
     * the same value in practice but not every emitter sends both — the delete
     * paths send an empty `session_id` and put the session in `id`. Reading
     * `session_id` alone is how a spinner stays lit forever after the run it
     * was describing finished.
     *
     * **Null means "could not read the list", and it is not the same answer as
     * an empty set.** "The server says nothing is running" and "the payload did
     * not have the field" used to both arrive as `emptySet()`, so a caller
     * acting on that would clear a live run's spinner because the envelope was
     * not the shape it expected — the backend does always send the array, but a
     * proxy, a captive portal or a future field rename is not a reason to
     * declare the agent idle. `ChatClient` turns this null into
     * `ChatResult.Unavailable`, which every caller already treats as "answer
     * nothing, change nothing".
     */
    fun parseRunningSessionIds(body: String): Set<String>? {
        val workers = JSONObject(body).optJSONArray("workers") ?: return null
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
