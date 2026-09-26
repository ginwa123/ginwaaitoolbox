package com.nalar.mobile.recents

import com.nalar.mobile.chat.optNullableString
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
     *
     * [cursor] is the server's own `next_cursor`, handed back verbatim. It is
     * a raw sort-field value (`'2026-09-26 05:12:37'` when sorting by
     * `updated_at`), not an opaque token and not an id — parse it, compare it or
     * synthesize it and pagination silently degrades. Round-tripping it is the
     * only supported way to get page 2+.
     */
    fun chatsPath(
        workspaceId: String,
        cursor: String? = null,
        limit: Int = CHATS_PAGE_LIMIT,
    ): String = buildString {
        append("/api/session?sort_by=updated_at&direction=desc")
        append("&limit=")
        append(limit.coerceIn(1, MAX_LIMIT))
        append("&workspace_id=")
        append(encodeQueryValue(workspaceId))
        // A blank cursor is indistinguishable from "first page" to the server,
        // so sending it would restart the list and re-serve page 1 forever.
        if (!cursor.isNullOrBlank()) {
            append("&cursor=")
            append(encodeQueryValue(cursor))
        }
    }

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
    ): List<ChatSummary> = parseChatsPage(body, workspaceId).chats

    /**
     * One page of recents plus everything the scroll needs to know whether to
     * ask for another one.
     *
     * Two of those fields are traps, and both are the server's contract rather
     * than this client's choice (`buildSessionListJson` in
     * `llm_history.zig`):
     *
     * - **`has_more` means "the page came back full"** (`len == limit`), not
     *   "there is at least one more row". A final page that happens to be
     *   exactly full therefore reports `true` and costs one extra round-trip.
     *   [total] is the full filtered count, so it is the cheap way to avoid it.
     * - **`nextCursor` is non-null even on the last page** — it is the last
     *   row's sort value whenever the page was non-empty. Nothing about it
     *   signals the end of the list, so the *only* terminator is `hasMore`.
     */
    fun parseChatsPage(
        body: String,
        workspaceId: String,
    ): ChatsPage {
        val root = JSONObject(body)
        val sessions = root.optJSONArray("sessions")

        val chats = buildList {
            if (sessions == null) return@buildList
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

        val total = if (root.isNull("total")) 0 else root.optInt("total", 0)
        val serverHasMore = if (root.isNull("has_more")) false else root.optBoolean("has_more", false)

        return ChatsPage(
            chats = chats,
            // `total` is a backstop, not the primary signal. An older server
            // that omits it reports 0, and reading that as "we have them all"
            // would silently truncate every list to page 1.
            hasMore = serverHasMore && (total <= 0 || chats.size < total),
            // A blank cursor is worse than none: it would restart the list at
            // page 1 and hand back rows the sidebar already shows.
            nextCursor = root.optNullableString("next_cursor")?.takeIf { it.isNotBlank() },
            total = total,
        )
    }

    /**
     * Write-through merge for a page append: a same-id incoming row replaces
     * the one already held, order is preserved.
     *
     * Dedupe is not defensive paranoia — a session that gets touched while the
     * user is between pages moves to the head of the ordering, so a page
     * boundary can legitimately hand back a row that is already on screen.
     * Without this, the sidebar grows duplicate rows that select the same chat
     * twice. Mirrors `ChatApi.mergeById`.
     */
    fun mergeChatsById(
        current: List<ChatSummary>,
        incoming: List<ChatSummary>,
    ): List<ChatSummary> {
        if (incoming.isEmpty()) return current
        val byId = LinkedHashMap<String, ChatSummary>(current.size + incoming.size)
        current.forEach { chat -> byId[chat.id] = chat }
        incoming.forEach { chat -> byId[chat.id] = chat }
        return byId.values.toList()
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

    /** No upper clamp on the server, so the client picks one. */
    private const val MAX_LIMIT = 1000

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
