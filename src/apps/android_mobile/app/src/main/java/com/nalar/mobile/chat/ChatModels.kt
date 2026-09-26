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

    /**
     * True when there is something to draw, so an empty row is never rendered.
     *
     * A bare `tool_calls` declaration is deliberately *not* here, and neither is
     * its `tool_name`. That column holds every tool in the batch comma-joined —
     * `read_file,write_file` — which is a list, not a tool, so counting it as
     * drawable is what kept a fully-answered declaration alive as a row with
     * nothing in it. Whether an unanswered one is worth a row is a question
     * about the run it belongs to, not about the row: the answer is
     * [ChatMessageGroup.unpairedToolCalls].
     */
    val hasVisibleContent: Boolean
        get() = hasRenderableContent ||
            reasoningContent.isNotBlank() ||
            isDrawableToolRow ||
            imageUrls.isNotEmpty() ||
            videoUrls.isNotEmpty() ||
            hasDiff ||
            isError

    /** A tool row is drawable from its name alone; its body is an envelope. */
    private val isDrawableToolRow: Boolean
        get() = role == ROLE_TOOL && toolName.isNotBlank()

    /**
     * The row is a real turn the transcript keeps, whether or not it draws.
     *
     * Distinct from [hasVisibleContent] on purpose, because they answer
     * different questions and conflating them loses a turn. "Does this row draw
     * anything" is a layout question — a fully-answered declaration draws
     * nothing because its result card already says it. "Is this a real turn" is
     * a transport question, and the stream's frame gate asks it: dropping a
     * declaration there would mean [ChatMessageGroup.unpairedToolCalls] could
     * never be non-empty, because the live window the header exists for is
     * exactly the moment the result has not arrived yet.
     */
    val isRealTurn: Boolean
        get() = hasVisibleContent || isToolCallTurn

    /**
     * The content a renderer would actually show, which is not the raw column.
     *
     * An assistant turn wrapped in `<markdown>…</markdown>` is non-blank as a
     * string and draws as nothing once the envelope is off, so gating
     * visibility on raw `content` is how a visible-but-empty bubble gets into
     * the transcript. The web pins the same thing in `hasVisibleContent`.
     */
    val hasRenderableContent: Boolean
        get() = content.isNotBlank() && Markdown.hasContent(content)

    companion object {
        const val ROLE_USER = "user"
        const val ROLE_ASSISTANT = "assistant"
        const val ROLE_SYSTEM = "system"
        const val ROLE_TOOL = "tool"

        /**
         * Every role the wire can deliver a persisted turn under.
         *
         * Nothing dispatches off this list, so it is not a lookup table — it
         * exists so a test can assert the role -> frame mapping is complete.
         * Adding a role constant above without adding it here leaves the
         * renderer free to fall through to whatever its last branch was; adding
         * it here makes that a failing test instead of a quiet ship.
         */
        fun knownRoles(): List<String> = listOf(ROLE_USER, ROLE_ASSISTANT, ROLE_SYSTEM, ROLE_TOOL)

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
    /**
     * The tool calls of this run that no tool row has answered yet.
     *
     * Empty in the common case, and empty is the point: a call whose result is
     * already on screen as a card needs no second line above it saying so. What
     * is left here is a call with no result — the live window between the
     * declaration landing and the `tool` row arriving — and hiding those is how
     * a running tool call becomes invisible. See [groupMessages].
     */
    val unpairedToolCalls: List<ToolCallEntry> = emptyList(),
) {
    val isUser: Boolean get() = role == ChatMessage.ROLE_USER
}

/**
 * The bare call declarations this group carries.
 *
 * "Bare" is the whole test: a declaration that also carries prose is an
 * ordinary assistant turn with a tool run attached, and its text is the
 * sentence worth reading. Only the one that says nothing but `tool_calls_json`
 * is a header for a run rather than a turn of its own.
 */
private val ChatMessageGroup.bareDeclarations: List<ToolCallEntry>
    get() = if (role != ChatMessage.ROLE_ASSISTANT) {
        emptyList()
    } else {
        messages
            .filter { it.isToolCallTurn && it.content.isBlank() && it.reasoningContent.isBlank() }
            .flatMap { ToolCalls.parse(it.toolCallsJson) }
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
 * Collapses consecutive same-role turns into groups, folds a tool call into the
 * tool run that answers it, and drops any group that would render nothing.
 *
 * **Why a call and its output share a row.** The backend sends them as two
 * rows — an `assistant` turn whose only payload is `tool_calls_json`, then a
 * `role: 'tool'` row carrying the result — so a naive role-run grouping draws
 * the run as a stripe of interleaved cards and "1 TOOL command" lines, one per
 * step, which is the screenshot this replaces. But the call and its output are
 * one thing the reader looks at, and the output card already shows the call's
 * name and arguments. So a declaration with no prose is absorbed into the tool
 * group that follows it: same key, same `contentType`, one list item, and the
 * duplicate "1 TOOL command" line disappears because there is nothing left for
 * it to say.
 *
 * What survives is [ChatMessageGroup.unpairedToolCalls] — calls with no
 * matching `tool_call_id` in the run, which is the live window between the
 * declaration landing and the result arriving. Those keep their summary, keyed
 * on the call id, so a running tool call is never invisible. This is the same
 * rule the web reaches in `ChatView.vue`'s `groupToolNames`, whose `allRendered`
 * check suppresses the pill once every declared call has a card.
 *
 * The empty-group filter is load-bearing rather than cosmetic: an item with no
 * content still occupies the virtualizer's height estimate, so leaving one in
 * leaves a blank band in the viewport and the auto-scroll lands short of the
 * last message. That is also why a declaration with an unparseable
 * `tool_calls_json` is dropped — it is a row that would draw nothing.
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

    return attachUnpairedToolCalls(groups).filter { group ->
        group.unpairedToolCalls.isNotEmpty() || group.messages.any { it.hasVisibleContent }
    }
}

/**
 * The second grouping pass: work out which declared calls still need naming.
 *
 * A call is *answered* once some later tool row carries its `tool_call_id`, and
 * an answered call is dropped from the header. Not because the header is
 * hidden — because the result card is already on screen showing that call's
 * name and arguments, and a line above it repeating them is exactly the
 * duplication the report is about. What is left is a call whose result has not
 * landed, and the header is the only thing drawing it.
 *
 * Walking *forward* rather than matching a global set is deliberate: a global
 * set also suppresses a call whose result row precedes the declaration, which a
 * re-delivered or out-of-order row can produce, and suppressing on that is
 * showing nothing at all.
 */
private fun attachUnpairedToolCalls(
    groups: List<ChatMessageGroup>,
): List<ChatMessageGroup> {
    if (groups.none { it.bareDeclarations.isNotEmpty() }) return groups

    val attached = ArrayList<ChatMessageGroup>(groups.size)
    groups.forEachIndexed { index, group ->
        val declared = group.bareDeclarations
        if (declared.isEmpty()) {
            attached += group
            return@forEachIndexed
        }
        val answered = groups.asSequence()
            .drop(index + 1)
            .filter { it.role == ChatMessage.ROLE_TOOL }
            .flatMap { it.messages.asSequence() }
            .mapNotNull { it.toolCallId.takeIf(String::isNotBlank) }
            .toSet()
        attached += group.copy(unpairedToolCalls = declared.filter { it.id !in answered })
    }
    return attached
}
