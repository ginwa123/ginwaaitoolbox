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

    /** True when there is something to draw, so an empty row is never rendered. */
    val hasVisibleContent: Boolean
        get() = content.isNotBlank() ||
            reasoningContent.isNotBlank() ||
            toolName.isNotBlank() ||
            imageUrls.isNotEmpty() ||
            videoUrls.isNotEmpty() ||
            isError

    companion object {
        const val ROLE_USER = "user"
        const val ROLE_ASSISTANT = "assistant"
        const val ROLE_SYSTEM = "system"
        const val ROLE_TOOL = "tool"

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
