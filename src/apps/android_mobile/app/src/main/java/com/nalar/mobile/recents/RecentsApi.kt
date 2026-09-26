package com.nalar.mobile.recents

import org.json.JSONObject
import java.net.URLEncoder
import java.time.DateTimeException
import java.time.LocalDateTime
import java.time.ZoneOffset

/**
 * The sidebar's two endpoints, and the wire shape that comes back.
 *
 * Both are read-only lists the desktop store already consumes:
 * `GET /api/workspaces?is_include_items=false` for the dropdown and
 * `GET /api/session?workspace_id=…` for recents. (`/api/llm/session` is the
 * same handler under an alias; the desktop store uses that one, either is fine.)
 *
 * Auth is the `nalar_session` cookie and nothing else — the backend accepts no
 * `Authorization` header and has no CSRF token, so a native client has to send
 * the cookie itself. See [RecentsClient].
 */
object RecentsApi {
    /**
     * `is_include_items` defaults to `"true"` on the server, which drags along
     * every workspace item and its tasks. The sidebar only shows names, so the
     * parameter is always sent explicitly and the payload stays one row per
     * workspace.
     */
    const val WORKSPACES_PATH = "/api/workspaces?is_include_items=false"

    /** Matches the desktop store's first page. */
    const val CHATS_PAGE_LIMIT = 30

    /**
     * `workspace_id` is only honoured when it resolves to real sessions, so this
     * is a scoped list rather than a client-side filter. An unknown id fails
     * closed to an empty array — never send a guessed id.
     */
    fun chatsPath(workspaceId: String): String =
        "/api/session?sort_by=updated_at&direction=desc" +
            "&limit=$CHATS_PAGE_LIMIT" +
            "&workspace_id=${encodeQueryValue(workspaceId)}"

    fun parseWorkspaces(body: String): List<WorkspaceOption> {
        val workspaces = JSONObject(body).optJSONArray("workspaces")
            ?: return emptyList()

        return buildList(workspaces.length()) {
            for (index in 0 until workspaces.length()) {
                val workspace = workspaces.optJSONObject(index) ?: continue
                val id = workspace.stringField("id")
                // A row without an id cannot be scoped to, so it is unusable.
                if (id.isEmpty()) continue
                add(
                    WorkspaceOption(
                        id = id,
                        name = workspace.stringField("name"),
                    ),
                )
            }
        }
    }

    fun parseChats(
        body: String,
        workspaceId: String,
    ): List<ChatSummary> {
        val sessions = JSONObject(body).optJSONArray("sessions")
            ?: return emptyList()

        return buildList(sessions.length()) {
            for (index in 0 until sessions.length()) {
                val session = sessions.optJSONObject(index) ?: continue
                val id = session.stringField("session_id")
                if (id.isEmpty()) continue
                add(
                    ChatSummary(
                        id = id,
                        // The scoped response does not echo the workspace back,
                        // so the id we asked with is the only one available.
                        workspaceId = workspaceId,
                        title = session.stringField("session_name"),
                        updatedAtEpochMillis = sessionTimestampMillis(session),
                    ),
                )
            }
        }
    }

    /**
     * `last_human_touched_at` is the stamp the human actually last saw the
     * chat, so it sorts/renders ahead of `updated_at` (which keeps moving while
     * an unattended run works). It is an empty string for rows predating
     * Migration 082, hence the fallbacks. Both are SQLite UTC strings, so the
     * missing stamp degrades to `updated_at` then `created_at` rather than to
     * "1970", which would read as `56y` in the sidebar.
     */
    private fun sessionTimestampMillis(session: JSONObject): Long =
        parseTimestampEpochMillis(session.stringField("last_human_touched_at"))
            ?: parseTimestampEpochMillis(session.stringField("updated_at"))
            ?: parseTimestampEpochMillis(session.stringField("created_at"))
            ?: UNKNOWN_TIMESTAMP

    /**
     * Parses the two timestamp shapes the backend emits into epoch millis, or
     * null when the value is absent or unparseable.
     *
     * The REST list sends a SQLite datetime string (`2026-09-26 05:07:34`) which
     * the server formats in UTC — reading it as device-local time would shift
     * every label by the device's offset. SSE emits the same field as bare unix
     * millis, so a digits-only string is accepted too.
     */
    fun parseTimestampEpochMillis(raw: String?): Long? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null

        if (trimmed.length >= MIN_UNIX_MILLIS_DIGITS && trimmed.all { it in '0'..'9' }) {
            return trimmed.toLongOrNull()
        }

        val match = SqliteUtcPattern.matchEntire(trimmed) ?: return null
        val (year, month, day, hour, minute, second) = match.destructured
        return try {
            LocalDateTime.of(
                year.toInt(),
                month.toInt(),
                day.toInt(),
                hour.toInt(),
                minute.toInt(),
                second.toInt(),
            )
                .toInstant(ZoneOffset.UTC)
                .toEpochMilli()
        } catch (_: DateTimeException) {
            // Calendar-invalid values ("2026-02-31 00:00:00") parse as digits
            // but are not instants; a missing label beats a wrong one.
            null
        }
    }

    /** `JSONObject.optString` renders an explicit null as the text "null". */
    private fun JSONObject.stringField(name: String): String =
        if (isNull(name)) "" else optString(name).trim()

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    private val SqliteUtcPattern =
        Regex("""^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$""")

    /** Any integer at or above this is a plausible unix-seconds/millis stamp. */
    private const val MIN_UNIX_MILLIS_DIGITS = 10

    /**
     * Sentinel for a session whose every timestamp was missing. Distinct from
     * 0 so [ChatSummary.hasTimestamp] can tell "no data" from the epoch.
     */
    const val UNKNOWN_TIMESTAMP = 0L
}
