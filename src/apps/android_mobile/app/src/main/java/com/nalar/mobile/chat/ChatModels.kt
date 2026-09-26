package com.nalar.mobile.chat

/**
 * The render model for one chat turn.
 *
 * This is deliberately the *same* shape the web's `ChatView.vue` builds, and it
 * is built by exactly one function — [ChatApi.toChatMessage] — for both the
 * network rows and the rows replayed out of [ChatCache]. Two mappers for one
 * endpoint is how a cached mount and a live mount drift apart, and on a phone
 * the cached mount is the first thing the user sees.
 *
 * The backend sends `created_at` as a *string* that carries nanoseconds, so the
 * two numeric fields are deliberately separate: [sortKeyNanos] is the
 * monotonic ordering key the cache cursor is built from, and
 * [createdAtEpochMillis] is only for rendering a clock.
 */
data class ChatMessage(
    val id: String,
    val role: String,
    val content: String,
    val createdAtEpochMillis: Long,
    val sortKeyNanos: Long,
    val toolName: String = "",
    val toolCallId: String = "",
    val reasoningContent: String = "",
    val finishReason: String = "",
    val imageUrls: List<String> = emptyList(),
    val videoUrls: List<String> = emptyList(),
    /**
     * The two sides of a file edit, present only on a completed tool result.
     *
     * The backend stores them next to the row rather than inside the envelope,
     * so a `text_replace` card has two possible sources for a diff and this
     * pair is the one that survives a cache round-trip and an SSE re-emit.
     */
    val diffviewBefore: String = "",
    val diffviewAfter: String = "",
    /**
     * The tool calls an assistant turn declared, as a JSON *string* holding an
     * OpenAI-style array.
     *
     * An assistant turn that only calls tools carries an empty [content], so
     * without this the row has nothing to render and either disappears or shows
     * an empty bubble labelled with a comma-joined list of tool names.
     */
    val toolCallsJson: String = "",
    /** The agentic-loop diagnostic frame, which is not a chat turn. */
    val isError: Boolean = false,
    /**
     * True only for the in-flight assistant placeholder the SSE `chunk` frames
     * append to. It is a reserved id namespace (`streaming-`), matching the web,
     * so a REST response can never clobber text that is still arriving.
     */
    val isStreaming: Boolean = false,
) {
    val isUser: Boolean get() = role == ROLE_USER

    /**
     * An assistant turn whose whole content is "I am going to call these tools".
     *
     * Such a row has an empty [content] and a `tool_name` holding a
     * comma-joined list of every tool in the batch, so nothing about it looks
     * like a single tool. It is rendered as its own summary row rather than as a
     * tool card, which is what the web does with the same data.
     */
    val isToolCallTurn: Boolean
        get() = role == ROLE_ASSISTANT &&
            finishReason == FINISH_REASON_TOOL_CALLS &&
            toolCallsJson.isNotBlank()

    /** True when either side of a file edit is present. */
    val hasDiff: Boolean
        get() = diffviewBefore.isNotEmpty() || diffviewAfter.isNotEmpty()

    /** True when there is something to draw, so an empty row is never rendered. */
    val hasVisibleContent: Boolean
        get() = content.isNotBlank() ||
            reasoningContent.isNotBlank() ||
            toolName.isNotBlank() ||
            imageUrls.isNotEmpty() ||
            videoUrls.isNotEmpty() ||
            hasDiff ||
            isToolCallTurn ||
            isError

    companion object {
        const val ROLE_USER = "user"
        const val ROLE_ASSISTANT = "assistant"
        const val ROLE_SYSTEM = "system"
        const val ROLE_TOOL = "tool"

        /** The only `finish_reason` that means "this turn declared tool calls". */
        const val FINISH_REASON_TOOL_CALLS = "tool_calls"

        /** The `finish_reason` on a tool row, both its placeholder and its result. */
        const val FINISH_REASON_TOOL = "tool"

        /**
         * The synthetic role the backend uses for sub-agent lifecycle pings. It
         * is not a turn: the row is never persisted and its content is empty.
         */
        const val ROLE_SUBAGENT_PROGRESS = "subagent_progress"

        /**
         * Reserved prefix for the placeholder the stream appends to. The web
         * keeps the same namespace so a live row is recognisable as live in one
         * place, whichever screen wrote it.
         */
        const val STREAMING_ID_PREFIX = "streaming-"
    }
}

/**
 * Consecutive same-role turns rendered as one list item.
 *
 * Mirrors the web's `MessageGroup`: a long tool run can produce dozens of
 * `tool` rows, and one list item per row both bloats the list and forces the
 * virtualizer to re-measure on every append. The group's key is the *first*
 * message id rather than the index, so an append at the end does not re-key the
 * whole list — an index key silently re-keys every item above the insertion.
 */
data class ChatMessageGroup(
    val key: String,
    val role: String,
    val messages: List<ChatMessage>,
    val timestampEpochMillis: Long,
) {
    val isUser: Boolean get() = role == ChatMessage.ROLE_USER
}

data class ChatUiState(
    val sessionId: String? = null,
    val isLoading: Boolean = true,
    val messages: List<ChatMessage> = emptyList(),
    val selectedProfileModel: String = "",
    val cwd: String = "",
    val errorMessage: String? = null,
    /**
     * The composer's text, owned here rather than by the composable so it can
     * survive a failed send. Clearing it is a *success* signal, not a side
     * effect of tapping send — otherwise a rejected turn silently eats what the
     * user typed.
     */
    val draft: String = "",
    val isSending: Boolean = false,
    val isStreaming: Boolean = false,
    val isLoadingOlder: Boolean = false,
    val hasMoreOlder: Boolean = false,
    /** Whether the SSE stream is currently open, shown as a live dot. */
    val isLive: Boolean = false,
    /**
     * Turns waiting behind the current run.
     *
     * Tracked from the `queue` channel because a turn that appears to have
     * vanished is almost always still queued, and an app that cannot say so
     * looks broken.
     */
    val queuedCount: Int = 0,
    /**
     * Sub-agents launched but not yet reported finished.
     *
     * Bounded by the newest spawn: the backend keys progress by `tool_call_id`,
     * so a second fan-out is a separate set, and merging them would show the
     * first batch still running while the second one is on screen.
     */
    val subAgentsRunning: Int = 0,
    val subAgentsTotal: Int = 0,
    val subAgentsFailed: Int = 0,
) {
    /**
     * Rows are on screen and the revalidation failed. A chat that blanks
     * because the network blipped is worse than a stale one.
     */
    val isShowingStaleData: Boolean
        get() = errorMessage != null && messages.isNotEmpty()

    /** Nothing cached and nothing loaded — a genuinely empty conversation. */
    val isEmptyConversation: Boolean
        get() = !isLoading && errorMessage == null && messages.isEmpty()
}

/**
 * Collapses consecutive same-role turns into groups, dropping any group that
 * would render nothing.
 *
 * The empty-group filter is load-bearing rather than cosmetic: an item with no
 * content still occupies the virtualizer's height estimate, so leaving one in
 * leaves a blank band in the viewport and the auto-scroll lands short of the
 * last message.
 */
fun groupMessages(messages: List<ChatMessage>): List<ChatMessageGroup> {
    val groups = ArrayList<ChatMessageGroup>()
    var current = mutableListOf<ChatMessage>()

    fun flush() {
        if (current.isEmpty()) return
        val first = current.first()
        groups.add(
            ChatMessageGroup(
                key = first.id,
                role = first.role,
                messages = current.toList(),
                timestampEpochMillis = first.createdAtEpochMillis,
            ),
        )
        current = mutableListOf()
    }

    messages.forEach { message ->
        // A streaming placeholder must never be glued to the turn above it —
        // it belongs visually to the assistant column and carries its own key.
        val startsGroup = current.isEmpty() ||
            current.first().role != message.role ||
            message.isStreaming ||
            current.first().isStreaming
        if (startsGroup) flush()
        current.add(message)
    }
    flush()

    return groups.filter { group ->
        group.messages.any { message -> message.hasVisibleContent }
    }
}
