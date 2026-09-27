package com.nalar.mobile.chat

import org.json.JSONObject
import java.net.URLEncoder
import java.time.DateTimeException
import java.time.LocalDateTime
import java.time.ZoneOffset

/**
 * One page of messages plus the session metadata the messages endpoint happens
 * to carry, which is how the web learns the session's cwd and profile without a
 * second request.
 */
data class ChatPage(
    val messages: List<ChatMessage>,
    val hasMore: Boolean,
    val nextCursor: String?,
    val selectedProfileModel: String,
    val cwd: String,
    val total: Int?,
)

/**
 * The chat endpoint and the wire shape that comes back.
 *
 * Auth is the `nalar_session` cookie and nothing else, exactly as for the
 * sidebar — the backend accepts no `Authorization` header and has no CSRF
 * token. See [ChatClient].
 *
 * Every quirk in here is load-bearing and mirrored from the backend rather than
 * from the desktop client, which gets at least one of them wrong (it reads
 * `total_count`, a key the server never emits).
 */
object ChatApi {
    /** The web's `PAGE_SIZE`; one page is the whole visible transcript. */
    const val MESSAGES_PAGE_LIMIT = 1000

    /**
     * The `/api/session` and `/api/llm/session` trees are the same handlers
     * registered twice. The `/api/llm/session` alias is the one the desktop and
     * the web client use, so it is the one pinned here.
     */
    fun messagesPath(
        sessionId: String,
        limit: Int = MESSAGES_PAGE_LIMIT,
        cursor: String? = null,
        direction: String = "asc",
    ): String = buildString {
        append("/api/llm/session/")
        append(encodeQueryValue(sessionId))
        append("/messages?limit=")
        append(limit.coerceIn(1, MAX_LIMIT))
        append("&sort_by=")
        // `sort_by=created_at` orders page 1 by the *session's* created_at (so
        // it degenerates to id order) and later pages by the message's. `id` is
        // the one key that is consistent across pages.
        append("id&direction=")
        append(if (direction == "desc") "desc" else "asc")
        if (!cursor.isNullOrBlank()) {
            append("&cursor=")
            append(encodeQueryValue(cursor))
        }
    }

    fun sessionPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}"

    /**
     * The profile list. Same tree as the web's `api.getNalarConfig()`
     * (`api/index.ts:4313`), which is the call `ChatView.vue`'s picker reads.
     */
    fun profilesPath(): String = "/api/config/nalar"

    /**
     * `PUT /api/llm/session/{id}` — the per-session profile choice.
     *
     * Field-for-field the desktop's `api.updateSession`
     * (`api/index.ts:1588`), including the two empty strings. They are not
     * padding: the backend treats an empty `name` and an empty
     * `is_auto_retry_until_stop` as "leave alone"
     * (`session_update.zig:92`), so omitting them would change the meaning
     * only if the handler ever stopped defaulting them to `""`. Sending them
     * is what makes the request say what it means instead of depending on a
     * struct default.
     *
     * An **empty** `selected_profile_model` is a real instruction, not an
     * absent field: `session_update.zig:84` writes the column unconditionally
     * precisely so a chat can be put back on the default profile. Clearing the
     * per-session override and keeping it are the same PUT with different text.
     */
    fun updateSessionBody(
        selectedProfileModel: String,
        name: String = "",
        isAutoRetryUntilStop: String = "",
    ): String = JSONObject()
        .put("selected_profile_model", selectedProfileModel)
        .put("name", name)
        .put("is_auto_retry_until_stop", isAutoRetryUntilStop)
        .toString()

    /**
     * The profile list, and the one the server calls active.
     *
     * `profiles` is a raw passthrough of `config.profiles_models` — an *object*
     * keyed by profile name, not the array the web's own type would suggest —
     * so it is read with `optJSONObject` and the keys are the names. Reading it
     * as an array yields an empty list, which renders as a picker saying "no
     * profiles configured" while the server has several.
     *
     * `active_profile` is `""` rather than null when unset, so it is normalised
     * to null here. That mirrors the web, which does the same coercion, and it
     * is what makes the effective-profile cascade a single `?:` instead of a
     * three-way branch every reader has to re-derive.
     */
    fun parseProfiles(body: String): ProfilesPage {
        val json = JSONObject(body)
        val profiles = json.optJSONObject("profiles")
        val names = profiles?.keys()?.asSequence()?.toList().orEmpty()
        return ProfilesPage(
            profiles = names.map { name ->
                val entry = profiles?.optJSONObject(name)
                ModelProfile(
                    name = name,
                    model = entry?.optNullableString("model").orEmpty(),
                    baseUrl = entry?.optNullableString("base_url").orEmpty(),
                )
            },
            activeProfile = json.optNullableString("active_profile")?.takeIf { it.isNotEmpty() },
        )
    }

    fun stopPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}/stop"

    /**
     * Settles a pending `ask_user` question.
     *
     * The `ask_user` tool *ends the turn* — it records a question and returns.
     * Nothing resumes until this is posted, which is why an unanswered question
     * is a stuck chat rather than a missing message.
     *
     * `question_id` is preferred and `tool_call_id` is the fallback the card
     * always has, because it is on the tool row. The endpoint is idempotent, so
     * a double tap or a retry after a timeout returns the stored status rather
     * than an error.
     */
    fun answerPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}/answer"

    fun answerQuestionBody(
        questionId: String? = null,
        toolCallId: String? = null,
        answer: String? = null,
        skip: Boolean = false,
    ): String = JSONObject().apply {
        if (!questionId.isNullOrBlank()) put("question_id", questionId)
        if (!toolCallId.isNullOrBlank()) put("tool_call_id", toolCallId)
        if (skip) put("skip", true) else put("answer", answer.orEmpty())
    }.toString()

    fun streamSnapshotPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}/stream"

    /**
     * The event stream. `channels` is required and an unknown token terminates
     * the stream, so it is spelled out here rather than assembled from a set.
     *
     * The backend emits no `id:` frames and keeps no replay buffer, so there is
     * no Last-Event-ID to resume from: every reconnect re-fetches the tail.
     */
    fun eventsPath(): String = "/api/events?channels=llm,sessions,queue"

    /**
     * Sending a message is the *same* endpoint that creates a session. Omitting
     * `session_id` mints one; supplying it queues a turn on the existing chat.
     * It returns 201 as soon as the work is enqueued — the reply never contains
     * the message, which is why the web waits for the SSE echo rather than
     * inserting an optimistic bubble.
     */
    fun sendMessageBody(
        sessionId: String,
        message: String,
        cwd: String = "",
        imageUrls: List<String> = emptyList(),
        videoUrls: List<String> = emptyList(),
        selectedProfileModel: String = "",
    ): String = JSONObject()
        .put("session_id", sessionId)
        .put("queue_message", message)
        .put("allowed_tools", DEFAULT_ALLOWED_TOOLS)
        .put("cwd_session", cwd)
        // Pipe-delimited, not a JSON array. This is the single most surprising
        // field in the contract and the backend stores it verbatim.
        .put("image_urls", imageUrls.joinToString("|"))
        .put("video_urls", videoUrls.joinToString("|"))
        .put("selected_profile_model", selectedProfileModel)
        .put("is_auto_retry_until_stop", "")
        .toString()

    /** Same tool set the web grants its chat box, so both clients can drive an agent. */
    const val DEFAULT_ALLOWED_TOOLS =
        "search_tool,view_tool,use_tool,command,search,load_memory," +
            "save_memory,list_skills,use_skill,used_tools,ask_user"

    fun parseMessages(body: String): ChatPage {
        val json = JSONObject(body)
        val rawMessages = json.optJSONArray("messages")
        val messages = buildList(rawMessages?.length() ?: 0) {
            for (index in 0 until (rawMessages?.length() ?: 0)) {
                val row = rawMessages?.optJSONObject(index) ?: continue
                toChatMessage(row)?.let { add(it) }
            }
        }
        return ChatPage(
            messages = messages,
            hasMore = json.optBoolean("has_more", false),
            nextCursor = json.optNullableString("next_cursor"),
            selectedProfileModel = json.optNullableString("selected_profile_model").orEmpty(),
            cwd = json.optNullableString("cwd").orEmpty(),
            // `total`, not `total_count`. The desktop reads the key the server
            // never emits and silently gets undefined.
            total = if (json.isNull("total")) null else json.optInt("total"),
        )
    }

    /**
     * The one mapper. Every message the app renders — fresh from the network,
     * replayed from the cache, or rebuilt from an SSE frame — goes through here.
     *
     * Returns null for a row with no id, because an idless row cannot be
     * merged, de-duplicated or keyed by the list, and a duplicate key is a crash
     * in `LazyColumn`.
     */
    fun toChatMessage(row: JSONObject): ChatMessage? {
        val id = row.optNullableString("id").orEmpty()
        if (id.isEmpty()) return null

        val nanos = parseCreatedAtNanos(row.optNullableString("created_at"))
        return ChatMessage(
            id = id,
            role = row.optNullableString("role").orEmpty()
                .ifEmpty { if (row.optNullableString("tool_call_id") != null) ChatMessage.ROLE_TOOL else ChatMessage.ROLE_ASSISTANT },
            content = row.optNullableString("content").orEmpty(),
            createdAtEpochMillis = nanos / NANOS_PER_MILLI,
            sortKeyNanos = nanos,
            toolName = row.optNullableString("tool_name").orEmpty(),
            toolCallId = row.optNullableString("tool_call_id").orEmpty(),
            reasoningContent = row.optNullableString("reasoning_content").orEmpty(),
            finishReason = row.optNullableString("finish_reason").orEmpty(),
            imageUrls = splitPipeDelimited(row.optNullableString("image_url")),
            videoUrls = splitPipeDelimited(row.optNullableString("video_url")),
            diffviewBefore = row.optNullableString("diffview_before").orEmpty(),
            diffviewAfter = row.optNullableString("diffview_after").orEmpty(),
            toolCallsJson = row.optNullableString("tool_calls_json").orEmpty(),
            isError = row.optBoolean("is_error", false),
        )
    }

    /** Re-parses a cached `raw` envelope through the same mapper as the network. */
    fun toChatMessage(rawJson: String): ChatMessage? = try {
        toChatMessage(JSONObject(rawJson))
    } catch (_: Exception) {
        null
    }

    /**
     * The backend's `created_at` is a JSON *string* holding a nanosecond
     * integer, but some writers store a SQLite UTC datetime in the same column
     * — so both shapes genuinely occur on the wire.
     *
     * Branching on "all digits" is not a shortcut: reading the datetime branch
     * as a number yields a nonsense epoch that sorts the row to the wrong end
     * of the transcript, which reads as a missing message rather than a bug.
     */
    fun parseCreatedAtNanos(raw: String?): Long {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return 0L
        if (trimmed.length >= MIN_NANO_DIGITS && trimmed.all { it in '0'..'9' }) {
            return trimmed.toLongOrNull() ?: 0L
        }
        val millis = parseSqliteUtcMillis(trimmed) ?: return 0L
        return millis * NANOS_PER_MILLI
    }

    fun parseSqliteUtcMillis(raw: String?): Long? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
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
            // Calendar-invalid values ("2026-02-31 00:00:00") match the pattern
            // but are not instants. A missing label beats a wrong one.
            null
        }
    }

    /**
     * Write-through merge: a same-id incoming row replaces the cached value.
     *
     * Order is not touched here — callers pass a list they already hold in
     * transcript order, and re-sorting mid-stream would fight the append that
     * is already correct.
     */
    fun mergeById(
        current: List<ChatMessage>,
        incoming: List<ChatMessage>,
    ): List<ChatMessage> {
        if (incoming.isEmpty()) return current
        val byId = LinkedHashMap<String, ChatMessage>(current.size + incoming.size)
        current.forEach { message -> byId[message.id] = message }
        incoming.forEach { message -> byId[message.id] = message }
        return byId.values.toList()
    }

    /**
     * `image_url` / `video_url` are pipe-delimited strings, not arrays. A blank
     * entry is dropped rather than rendered as an empty attachment.
     */
    fun splitPipeDelimited(raw: String?): List<String> =
        raw.orEmpty()
            .split('|')
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    private val SqliteUtcPattern =
        Regex("""^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$""")

    /**
     * No max clamp on the server, so the client picks one. Unix nanoseconds
     * since 2001 are 19 digits; 13 is a millisecond stamp, 10 a second stamp.
     * Anything shorter is a year, not a timestamp.
     */
    private const val MIN_NANO_DIGITS = 13
    private const val MAX_LIMIT = 1000
    private const val NANOS_PER_MILLI = 1_000_000L
}

/**
 * A string field, or null when it is absent or an explicit JSON null.
 *
 * `JSONObject.optString` renders an explicit null as the four-character text
 * `"null"`, so every field of an envelope the server marks optional would come
 * back as a string saying "null" rather than as nothing. This is top-level
 * rather than a member of [ChatApi] so the cache and the event stream — which
 * read the same wire shapes — share one rule instead of three copies of it.
 */
internal fun JSONObject.optNullableString(name: String): String? =
    if (!has(name) || isNull(name)) null else optString(name).takeIf { it != "null" }

/**
 * A nested object, or null when absent or an explicit JSON null.
 *
 * `usage` on a `chunk_final` frame is the reason this exists: the token counts
 * are nested one level down, and reading them from the top level yields nothing
 * on every single turn.
 */
internal fun JSONObject.optNullableObject(name: String): JSONObject? =
    if (!has(name) || isNull(name)) null else optJSONObject(name)
