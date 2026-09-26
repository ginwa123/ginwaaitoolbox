package com.nalar.mobile.chat

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.HttpsAuthTransport
import com.nalar.mobile.auth.SessionCookieStore
import com.nalar.mobile.network.RecordingAuthTransport
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Owns one chat's real data.
 *
 * The shape is the web's cache-then-revalidate: paint from disk, then fetch the
 * tail, then write through. It lives in one function ([openSession]) rather than
 * being something every call site has to remember to do in the right order,
 * because there is deliberately no TTL to catch a caller that forgets — a cached
 * paint with no fetch behind it is permanently stale and nothing will ever
 * correct it.
 *
 * The disk read and the JSON parse are on [ioDispatcher], not on the caller.
 * [openSession] is called from a tap handler, and the cache holds the *verbatim*
 * server row, so a 400-row window is megabytes to read and parse — work that
 * used to land on the UI thread before the navigation even started, and which
 * read on the phone as a freeze.
 *
 * There is no preview or mock data here. A transcript that quietly renders demo
 * turns is indistinguishable from a working one.
 */
class ChatViewModel(
    private val client: ChatClient,
    private val cache: ChatCache,
    private val eventStream: ChatEventStream,
    // Injected so tests can drive the fetch on the same scheduler as the paint;
    // `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    private val _uiState = MutableStateFlow(ChatUiState())
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()

    private val _sessionExpired = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val sessionExpired: SharedFlow<Unit> = _sessionExpired.asSharedFlow()

    private var userId: String? = null
    private var loadJob: Job? = null
    private var cachePrimeJob: Job? = null
    private var olderJob: Job? = null
    private var sendJob: Job? = null
    private var stopJob: Job? = null
    private var answerJob: Job? = null

    /**
     * Ids delivered live over SSE in this session view. A REST response skips
     * these, because a tail fetch that started before a tool finished still
     * carries that row's placeholder content — writing it back would roll a
     * finished tool result into a spinner.
     */
    private val liveMessageIds = mutableSetOf<String>()

    /**
     * Sub-agent pings seen so far, keyed by the spawning `tool_call_id`.
     *
     * The backend keys its own progress map the same way, so two concurrent
     * fan-outs never cross-contaminate — and neither do they here. Cleared on
     * every session change for the same reason: the map is only meaningful
     * within one run.
     */
    private val subAgentBatches = mutableMapOf<String, MutableSet<SubAgentPing>>()

    /** One sub-agent's latest known lifecycle state, keyed within its batch. */
    private data class SubAgentPing(
        val key: String,
        val status: String,
    )

    /** Cursor for the next *older* page, from the server's `has_more`. */
    private var olderCursor: String? = null

    /**
     * Bumped on every session change so a fetch that finishes late can tell it
     * belongs to a chat the user already left.
     */
    private var generation: Int = 0

    /**
     * Whether anything *newer than the cache* has painted for this generation.
     *
     * Set the moment a page, a live frame or a paged-older response lands. The
     * cache prime reads and parses on an IO dispatcher now, so it can finish
     * *after* a tail fetch that left first — and the cache, by definition, is
     * older than what that fetch returned. Publishing it then would roll a
     * finished turn back to whatever placeholder the cache holds, which is the
     * one thing paint-from-cache is never allowed to do.
     *
     * `@Volatile` because the writes are not all on the same thread: a live
     * frame arrives on the SSE pump thread, and the read is on the main thread
     * where the prime resumes. Without it the main thread is entitled to serve
     * itself a stale `false` from a register.
     */
    @Volatile
    private var hasFreshContent: Boolean = false

    private var hasConnectedStreamOnce = false

    /**
     * Monotonic suffix for streaming placeholder ids.
     *
     * A wall-clock id is not safe here: two chunks of consecutive turns landing
     * in the same millisecond mint the same id, and two messages sharing an id
     * means two groups with one LazyColumn key — which throws, not warns.
     */
    private var streamingCounter: Long = 0

    /**
     * The signed-in account namespaces the transcript cache. Called before any
     * session is opened, so the very first paint is already in the right scope.
     */
    fun onUserChanged(newUserId: String?) {
        val accountChanged = newUserId != userId
        userId = newUserId
        if (accountChanged) {
            // Blank rather than keep: the old transcript belongs to someone else.
            _uiState.value = ChatUiState()
            liveMessageIds.clear()
            subAgentBatches.clear()
            olderCursor = null
            hasFreshContent = false
        }
    }

    /**
     * Opens a chat: paint from cache, then attach the stream, then revalidate.
     *
     * **Returns immediately.** This runs from a tap handler, so everything it
     * can do to the caller is bounded: it resets the state, publishes the empty
     * loading paint, and hands the rest to coroutines. The cache read, the
     * parse, the fetch and the stream attach all run behind it. The transcript
     * is correct for whichever of them lands first: the cache never overwrites
     * something newer (see [hasFreshContent]), and a fetch that lands first
     * simply becomes the state the cache declines to touch.
     *
     * The stream is attached *before* the fetch, deliberately. A tool call can
     * finish while the first REST load is still in flight, and an event that
     * arrives in that window with nobody listening is gone for good — the
     * backend has no replay buffer to ask again.
     */
    fun openSession(sessionId: String) {
        if (sessionId.isBlank()) return
        if (_uiState.value.sessionId == sessionId && !_uiState.value.isLoading) return

        generation++
        val requestGeneration = generation
        loadJob?.cancel()
        olderJob?.cancel()
        sendJob?.cancel()
        stopJob?.cancel()
        answerJob?.cancel()
        // A stream that is already up would keep delivering the PREVIOUS
        // chat's events into the handlers captured for it, and this chat would
        // sit there showing "connected" while never receiving a turn.
        stopEventStream()
        liveMessageIds.clear()
        subAgentBatches.clear()
        olderCursor = null
        hasConnectedStreamOnce = false
        hasFreshContent = false

        // The empty paint is the *only* part of the prime that stays on the
        // caller's thread, and it is a field assignment. It has to be here: the
        // navigation that follows reads `sessionId` to decide whether this chat
        // is open yet, and the transcript needs a state to render its spinner
        // against.
        _uiState.value = ChatUiState(sessionId = sessionId, isLoading = true)

        // The read and the parse are the expensive half, and they are not cheap
        // because of the SQL: the cache keeps the *verbatim* server row, so a
        // 400-row window is megabytes of `diffview_before`/`diffview_after` and
        // double-escaped `tool_calls_json` to pull off disk and JSON-parse, per
        // session switch. Doing that in the tap handler is what froze the phone
        // on a long transcript, so it now runs on the IO pool and publishes when
        // it lands.
        cachePrimeJob?.cancel()
        cachePrimeJob = viewModelScope.launch {
            val painted = withContext(ioDispatcher) { readCachedTranscript(sessionId) }
            if (requestGeneration != generation) return@launch
            if (painted == null || hasFreshContent) return@launch
            // The cache reads newest-first; a transcript reads oldest-first.
            // Sorting by the hoisted nano key is what lets the auto-scroll target
            // "the last item" without the view knowing anything about sort order.
            _uiState.update { state ->
                if (state.sessionId != sessionId) {
                    state
                } else {
                    state.copy(messages = painted.sortedBy { it.sortKeyNanos })
                }
            }
        }

        startEventStream(sessionId)
        revalidate(sessionId, requestGeneration)
        reattachInFlightTurn(sessionId, requestGeneration)
    }

    /**
     * Re-attaches the partial text of a run that is already going.
     *
     * An in-progress turn has no row yet — the backend writes `llm_history`
     * only when the turn completes — so a cold open mid-run shows a transcript
     * that stops one message short of the live answer. The snapshot is the only
     * way to show that text: the stream carries no replay, so chunks already
     * sent are gone.
     *
     * Skipped when a placeholder is already on screen, which is the case
     * whenever this is a reconnect rather than a fresh open.
     */
    private fun reattachInFlightTurn(sessionId: String, requestGeneration: Int) {
        viewModelScope.launch {
            val result = withContext(ioDispatcher) { client.loadStreamSnapshot(sessionId) }
            if (requestGeneration != generation) return@launch
            // A failed snapshot must not disturb a transcript that loaded fine.
            val content = (result as? ChatResult.Loaded)?.value.orEmpty()
            if (content.isBlank()) return@launch
            hasFreshContent = true

            _uiState.update { state ->
                if (state.messages.any { message -> message.isStreaming }) {
                    state
                } else {
                    state.copy(
                        messages = state.messages + ChatMessage(
                            id = "${ChatMessage.STREAMING_ID_PREFIX}reattached",
                            role = ChatMessage.ROLE_ASSISTANT,
                            content = content,
                            createdAtEpochMillis = nowMillis(),
                            // Sorts last: the turn has not been written yet, so
                            // there is no server timestamp to order it by.
                            sortKeyNanos = Long.MAX_VALUE,
                            isStreaming = true,
                        ),
                        isStreaming = true,
                    )
                }
            }
        }
    }

    /**
     * The last-known transcript, oldest-first, or null when there is none.
     *
     * **Off the main thread, deliberately.** This is the single most expensive
     * thing a session switch does: [ChatViewModel.CACHED_MESSAGE_LIMIT] rows of
     * verbatim server JSON, each one a full `JSONObject` parse, with the tool
     * rows carrying both sides of a diff. Room is opened with
     * `allowMainThreadQueries()` so this *may* run inline, and it used to — from
     * inside the tap handler, before the navigation even started. A phone paid
     * hundreds of milliseconds of UI-thread time per switch there, which reads
     * to the user as the app freezing.
     *
     * The cost of moving it is one spinner frame on a warm cache. The cost of
     * leaving it was the whole freeze.
     */
    private fun readCachedTranscript(sessionId: String): List<ChatMessage>? {
        val cached = cache.readMessages(userId, sessionId, CACHED_MESSAGE_LIMIT)
        if (cached.isNullOrEmpty()) return null
        return cached.mapNotNull { ChatApi.toChatMessage(it.raw) }
    }

    /**
     * [isFullReload] is true only for a cold load, i.e. one with no stored
     * cursor. A warm tail fetch is short by definition, so the server reports
     * `has_more=false` and `next_cursor=null` for it — letting that reset the
     * paging state would permanently disable scroll-back after any session
     * rename or reconnect, even though the transcript visibly has history above
     * it.
     */
    private fun revalidate(sessionId: String, requestGeneration: Int) {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val storedCursor = withContext(ioDispatcher) { cache.readCursor(userId, sessionId) }
            val isFullReload = storedCursor == null
            val result = withContext(ioDispatcher) {
                // Cold (no cursor): a full descending load. Warm: only the tail
                // past the cursor. The web switches the same way, and the reason
                // is that a stored cursor is a *newest* row, not a page break.
                client.loadMessages(
                    sessionId = sessionId,
                    cursor = storedCursor,
                    direction = if (storedCursor == null) "desc" else "asc",
                )
            }

            if (requestGeneration != generation) return@launch

            when (result) {
                is ChatResult.SignedOut -> expireSession()

                is ChatResult.Rejected -> _uiState.update {
                    it.copy(isLoading = false, errorMessage = result.message)
                }

                is ChatResult.Unavailable -> _uiState.update {
                    // Keep whatever is on screen — cached or not. A stale
                    // transcript beats a blank one when the network blips.
                    it.copy(isLoading = false, errorMessage = result.message)
                }

                is ChatResult.Loaded -> applyPage(
                    page = result.value,
                    sessionId = sessionId,
                    isFullReload = isFullReload,
                )
            }
        }
    }

    private suspend fun applyPage(
        page: ChatPage,
        sessionId: String,
        isFullReload: Boolean,
    ) {
        val incoming = page.messages.filterNot { message -> message.id in liveMessageIds }
        // Whatever the network just returned is newer than the cache, so the
        // prime must not be allowed to land on top of it.
        hasFreshContent = true

        _uiState.update {
            it.copy(
                isLoading = false,
                messages = ChatApi.mergeById(it.messages, incoming)
                    .sortedBy { message -> message.sortKeyNanos },
                selectedProfileModel = page.selectedProfileModel
                    .ifEmpty { it.selectedProfileModel },
                cwd = page.cwd.ifEmpty { it.cwd },
                errorMessage = null,
            )
        }
        if (isFullReload) {
            olderCursor = page.nextCursor
            _uiState.update { it.copy(hasMoreOlder = page.hasMore) }
        }

        withContext(ioDispatcher) {
            // The cursor advance is skipped when any row was filtered out as
            // live: advancing past a row that was deliberately not written
            // leaves a hole the next tail fetch can never fill.
            if (incoming.size == page.messages.size) {
                val rows = incoming.mapNotNull { message ->
                    ChatCacheCodec.toCachedMessage(sessionId, rawObjectFor(message))
                }
                if (rows.isNotEmpty()) {
                    cache.writeMessages(userId, sessionId, rows)
                    val previous = cache.readCursor(userId, sessionId)
                    cache.writeCursor(
                        userId,
                        sessionId,
                        ChatCacheCodec.newestCursor(rows, page.nextCursor, previous),
                    )
                }
            }
        }
    }

    /**
     * A scroll to the top pages backwards.
     *
     * The server pages a *cursor* in one direction only, so "older than what I
     * have" is a descending request seeded with the page cursor. The response
     * comes back newest-first and is reversed before it is prepended.
     */
    fun loadOlderMessages() {
        val state = _uiState.value
        val sessionId = state.sessionId ?: return
        if (state.isLoadingOlder || !state.hasMoreOlder) return
        val cursor = olderCursor ?: return
        if (state.messages.isEmpty()) return

        val requestGeneration = generation
        olderJob?.cancel()
        olderJob = viewModelScope.launch {
            _uiState.update { it.copy(isLoadingOlder = true) }
            val result = withContext(ioDispatcher) {
                client.loadMessages(
                    sessionId = sessionId,
                    limit = OLDER_PAGE_LIMIT,
                    cursor = cursor,
                    direction = "desc",
                )
            }
            if (requestGeneration != generation) return@launch

            when (result) {
                is ChatResult.SignedOut -> {
                    _uiState.update { it.copy(isLoadingOlder = false) }
                    expireSession()
                }

                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> _uiState.update { it.copy(isLoadingOlder = false) }

                is ChatResult.Loaded -> {
                    hasFreshContent = true
                    val older = result.value.messages
                        .filterNot { message -> message.id in liveMessageIds }
                        .asReversed()
                    _uiState.update { current ->
                        // A tail fetch may have appended while this page was in
                        // flight, so merge by id rather than prepending blindly.
                        val known = current.messages.map { message -> message.id }.toSet()
                        current.copy(
                            messages = ChatApi.mergeById(
                                older.filterNot { message -> message.id in known },
                                current.messages,
                            ),
                            isLoadingOlder = false,
                            hasMoreOlder = result.value.hasMore,
                        )
                    }
                    // An empty page means we reached the start of the transcript;
                    // holding the old cursor would re-request it forever.
                    olderCursor = result.value.nextCursor?.takeIf { older.isNotEmpty() }

                    if (older.isNotEmpty()) {
                        withContext(ioDispatcher) {
                            cache.writeMessages(
                                userId,
                                sessionId,
                                older.mapNotNull { message ->
                                    ChatCacheCodec.toCachedMessage(sessionId, rawObjectFor(message))
                                },
                            )
                        }
                    }
                }
            }
        }
    }

    fun onDraftChanged(value: String) {
        _uiState.update { it.copy(draft = value) }
    }

    /**
     * Queues a turn.
     *
     * There is no optimistic bubble. The web removed one deliberately: a local
     * push sits at the wrong end of the array and re-keys the grouped list,
     * which silently re-renders tool cards the user had just expanded. The
     * canonical row arrives over SSE instead, so the draft is cleared only once
     * the server has actually accepted the turn.
     */
    fun sendMessage() {
        val state = _uiState.value
        val sessionId = state.sessionId ?: return
        val text = state.draft.trim()
        if (text.isEmpty() || state.isSending) return

        sendJob?.cancel()
        _uiState.update { it.copy(isSending = true, errorMessage = null) }
        sendJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                client.sendMessage(
                    sessionId = sessionId,
                    message = text,
                    cwd = state.cwd,
                    selectedProfileModel = state.selectedProfileModel,
                )
            }
            when (result) {
                is ChatResult.Loaded -> _uiState.update {
                    it.copy(isSending = false, draft = "")
                }

                is ChatResult.SignedOut -> {
                    _uiState.update { it.copy(isSending = false) }
                    expireSession()
                }

                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> _uiState.update {
                    // The draft survives, so a failed send is one tap to retry
                    // rather than a retyped message.
                    it.copy(isSending = false, errorMessage = messageFor(result))
                }
            }
        }
    }

    fun stopRun() {
        val sessionId = _uiState.value.sessionId ?: return
        val requestGeneration = generation
        stopJob?.cancel()
        stopJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) { client.stopRun(sessionId) }
            // A stop for a chat the user already left must not surface its
            // error, or sign out on, the chat now on screen.
            if (requestGeneration != generation) return@launch
            when (result) {
                is ChatResult.SignedOut -> expireSession()
                is ChatResult.Loaded -> Unit
                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> _uiState.update { it.copy(errorMessage = messageFor(result)) }
            }
        }
    }

    /**
     * Settles a pending `ask_user` question.
     *
     * `ask_user` ends the run, so an unanswered question is a chat that is
     * stopped rather than one that is waiting — the composer would queue a turn
     * behind a run that is not going to continue. Answering is therefore the
     * only way out, which is why the card carries the affordance rather than
     * leaving the reader to discover the desktop client.
     */
    fun answerQuestion(
        questionId: String?,
        toolCallId: String,
        answer: String? = null,
        skip: Boolean = false,
    ) {
        val sessionId = _uiState.value.sessionId ?: return
        if (answer.isNullOrBlank() && !skip) return
        val requestGeneration = generation
        answerJob?.cancel()
        answerJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                client.answerQuestion(
                    sessionId = sessionId,
                    questionId = questionId,
                    toolCallId = toolCallId,
                    answer = answer,
                    skip = skip,
                )
            }
            if (requestGeneration != generation) return@launch
            when (result) {
                is ChatResult.Loaded -> {
                    // The rewritten tool row arrives over SSE; refetching too
                    // covers the case where the stream is down, which is exactly
                    // when the reader most needs the answer to have landed.
                    revalidate(sessionId, requestGeneration)
                }

                is ChatResult.SignedOut -> expireSession()
                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> _uiState.update { it.copy(errorMessage = messageFor(result)) }
            }
        }
    }

    fun clearError() {
        _uiState.update { it.copy(errorMessage = null) }
    }

    /**
     * Sign-out. The cached transcript is purged rather than left namespaced: the
     * user asked to switch accounts, the device may be shared, and refetching
     * costs one request.
     */
    fun onSignedOut() {
        generation++
        stopEventStream()
        userId = null
        liveMessageIds.clear()
        subAgentBatches.clear()
        olderCursor = null
        _uiState.value = ChatUiState()
        hasFreshContent = false
        cachePrimeJob?.cancel()
        loadJob?.cancel()
        olderJob?.cancel()
        sendJob?.cancel()
        stopJob?.cancel()
        answerJob?.cancel()
        cache.clear()
    }

    override fun onCleared() {
        cachePrimeJob?.cancel()
        stopEventStream()
        super.onCleared()
    }

    private fun startEventStream(sessionId: String) {
        eventStream.start(
            onEvent = { event -> handleStreamEvent(sessionId, event) },
            onState = { state -> handleStreamState(sessionId, state) },
        )
    }

    private fun stopEventStream() = eventStream.stop()

    private fun handleStreamState(sessionId: String, state: ChatStreamState) {
        if (_uiState.value.sessionId != sessionId) return
        when (state) {
            is ChatStreamState.Live -> {
                _uiState.update { it.copy(isLive = true) }
                // A *re*connect means events were missed with no way to ask for
                // them, so the only repair is a refetch. The first connect needs
                // none — the load already in flight covers that window.
                if (hasConnectedStreamOnce) revalidate(sessionId, generation)
                hasConnectedStreamOnce = true
            }

            is ChatStreamState.Connecting,
            is ChatStreamState.Reconnecting,
            -> _uiState.update { it.copy(isLive = false) }

            is ChatStreamState.Failed -> _uiState.update {
                it.copy(isLive = false, errorMessage = state.message)
            }
        }
    }

    private fun handleStreamEvent(sessionId: String, event: ChatStreamEvent) {
        if (_uiState.value.sessionId != sessionId) return
        when (event) {
            is ChatStreamEvent.Connected -> Unit

            is ChatStreamEvent.Chunk ->
                if (event.sessionId == sessionId) appendStreamingChunk(event)

            is ChatStreamEvent.ChunkFinished ->
                if (event.sessionId == sessionId) finishStreaming()

            is ChatStreamEvent.Full ->
                if (event.sessionId == sessionId) upsertFullMessage(sessionId, event)

            // A fan-out that reports nothing for two minutes looks like a hang.
            // These never become turns, so the state they drive is a separate
            // line in the header rather than a row in the transcript.
            is ChatStreamEvent.SubAgentProgress ->
                if (event.sessionId == sessionId) recordSubAgentProgress(event)

            is ChatStreamEvent.SessionChanged ->
                if (event.sessionId == sessionId) revalidate(sessionId, generation)

            // Surfaced, not dropped: a turn that looks like it vanished is
            // almost always still waiting behind the current run.
            is ChatStreamEvent.QueueChanged -> {
                if (event.sessionId != sessionId) return
                _uiState.update {
                    it.copy(queuedCount = (it.queuedCount + event.queueDelta).coerceAtLeast(0))
                }
            }

            // A diagnostic frame (`is_error`) is not a run in progress, so it
            // must clear the flag too — otherwise the header claims the agent
            // is still working after it has given up.
            is ChatStreamEvent.Failed -> _uiState.update {
                it.copy(errorMessage = event.message, isStreaming = false)
            }

            // Worker liveness is not this screen's state. It is kept for the
            // whole app in `RunningSessionsStore`, because the chat stream does
            // not exist until a chat is opened and the sidebar is on screen
            // precisely when no chat is open. `WorkerActivityViewModel` owns it
            // off its own `workers` subscription, so nothing here needs this
            // branch to do anything.
            is ChatStreamEvent.WorkerChanged -> Unit
        }
    }

    /**
     * The backend sends *raw provider deltas*, so this appends. Assigning would
     * leave only the last fragment on screen.
     */
    private fun appendStreamingChunk(event: ChatStreamEvent.Chunk) {
        hasFreshContent = true
        _uiState.update { state ->
            val existing = state.messages.lastOrNull { message -> message.isStreaming }
            val placeholder = ChatMessage(
                id = existing?.id ?: nextStreamingId(),
                role = ChatMessage.ROLE_ASSISTANT,
                content = (existing?.content.orEmpty()) + event.content,
                createdAtEpochMillis = nowMillis(),
                // Sorts last, so the placeholder is never spliced into the
                // middle of a transcript whose later turns already arrived.
                sortKeyNanos = existing?.sortKeyNanos ?: Long.MAX_VALUE,
                reasoningContent = (existing?.reasoningContent.orEmpty()) +
                    event.reasoningContent,
                isStreaming = true,
            )
            state.copy(
                messages = state.messages.filterNot { message -> message.isStreaming } + placeholder,
                isStreaming = true,
            )
        }
    }

    private fun nextStreamingId(): String =
        "${ChatMessage.STREAMING_ID_PREFIX}${++streamingCounter}"

    private fun finishStreaming() {
        // The placeholder deliberately stays: the canonical row has not arrived
        // yet, and dropping it here flashes an empty bubble between the last
        // delta and the completed turn. The `full` frame removes it.
        _uiState.update { state ->
            val placeholder = state.messages.lastOrNull { message -> message.isStreaming }
                ?: return@update state.copy(isStreaming = false)
            state.copy(
                messages = state.messages.map { message ->
                    if (message.id == placeholder.id) message.copy(isStreaming = false) else message
                },
                isStreaming = false,
            )
        }
    }

    /**
     * The canonical row for a turn. It replaces any row with the same id and
     * drops the streaming placeholder, then goes straight into the cache so a
     * cold start after this turn reads the completed text rather than a stub.
     */
    private fun upsertFullMessage(sessionId: String, event: ChatStreamEvent.Full) {
        val message = event.message
        liveMessageIds += message.id
        hasFreshContent = true

        _uiState.update { state ->
            // Match the placeholder by its RESERVED ID, not just by
            // `isStreaming`: `finishStreaming` has already cleared that flag by
            // the time the canonical row lands, so flag-matching alone leaves
            // the stub on screen next to the real turn.
            val dropped = state.messages.filterNot { candidate ->
                candidate.isStreaming ||
                    candidate.id.startsWith(ChatMessage.STREAMING_ID_PREFIX) ||
                    candidate.id == message.id
            }
            state.copy(
                messages = (dropped + message).sortedBy { it.sortKeyNanos },
                isStreaming = false,
                errorMessage = null,
            )
        }

        viewModelScope.launch {
            withContext(ioDispatcher) {
                cache.writeMessages(
                    userId,
                    sessionId,
                    listOfNotNull(
                        ChatCacheCodec.toCachedMessage(sessionId, rawObjectFor(message)),
                    ),
                )
            }
        }
    }

    /**
     * Folds one sub-agent lifecycle ping into the header counters.
     *
     * The running count is *derived* by replaying the batch rather than by
     * incrementing and decrementing. A `completed` for an agent whose `launched`
     * ping was missed — which is exactly what a reconnect in the middle of a
     * fan-out produces — would otherwise decrement a count that was never
     * incremented and drive it below zero.
     */
    private fun recordSubAgentProgress(event: ChatStreamEvent.SubAgentProgress) {
        // A ping with no `agent_name` still happened, and still has to count.
        // Keying the batch on the name alone collapsed every nameless ping onto
        // one entry, so an N-agent fan-out reported "1 of N" the whole way
        // through — wrong in both directions at once, which is the only kind of
        // wrong that tells the reader nothing.
        val key = event.agentName.ifBlank { "#${event.agentIndex}" }
        val batch = subAgentBatches.getOrPut(event.toolCallId) { mutableSetOf() }
        batch.removeIf { it.key == key }
        batch.add(SubAgentPing(key = key, status = event.status))

        val launched = batch.size
        val finished = batch.count { it.status != ChatStreamEvent.SubAgentProgress.STATUS_LAUNCHED }
        val failed = batch.count { it.status == ChatStreamEvent.SubAgentProgress.STATUS_FAILED }

        // A batch the backend never told us the size of is pruned once every
        // member it *did* report has finished, so a session that runs a hundred
        // fan-outs does not retain a hundred sets.
        val complete = finished > 0 && (
            finished == launched &&
                (event.totalAgents <= 0 || finished >= event.totalAgents)
            )

        _uiState.update { state ->
            state.copy(
                subAgentsTotal = maxOf(event.totalAgents, launched),
                subAgentsRunning = (launched - finished).coerceAtLeast(0),
                subAgentsFailed = failed,
            )
        }
        if (complete) {
            subAgentBatches.remove(event.toolCallId)
            _uiState.update { it.copy(subAgentsRunning = 0) }
        }
    }

    private fun messageFor(result: ChatResult<*>): String = when (result) {
        is ChatResult.Rejected -> result.message
        is ChatResult.Unavailable -> result.message
        is ChatResult.SignedOut -> "Your session expired. Sign in again."
        is ChatResult.Loaded -> ""
    }

    /**
     * Rebuilds the wire object for a message.
     *
     * The cache stores the *verbatim* server row so a cached paint and a live
     * paint cannot disagree. A message that originated as an SSE frame never
     * carried a stored raw, so it is reconstructed from the fields the frame
     * had — same key names, same JSON-in-a-string and pipe-delimited
     * conventions, so the two paths stay interchangeable.
     */
    private fun rawObjectFor(message: ChatMessage): JSONObject = JSONObject()
        .put("id", message.id)
        .put("session_id", _uiState.value.sessionId.orEmpty())
        .put("role", message.role)
        .put("content", message.content)
        .put("created_at", message.sortKeyNanos.toString())
        .put("is_input", message.role == ChatMessage.ROLE_USER)
        .put("is_output", message.role == ChatMessage.ROLE_ASSISTANT)
        .put("tool_name", message.toolName)
        .put("finish_reason", message.finishReason)
        .put("reasoning_content", message.reasoningContent)
        .put("tool_call_id", message.toolCallId)
        .put("image_url", message.imageUrls.joinToString("|"))
        .put("video_url", message.videoUrls.joinToString("|"))
        .put("diffview_before", message.diffviewBefore)
        .put("diffview_after", message.diffviewAfter)
        .put("tool_calls_json", message.toolCallsJson)

    private fun expireSession() {
        _uiState.update {
            it.copy(isLoading = false, isSending = false, isLoadingOlder = false)
        }
        _sessionExpired.tryEmit(Unit)
    }

    companion object {
        /**
         * Bounded so the cache read in [readCachedTranscript] is a bounded
         * amount of JSON on a background dispatcher rather than an unbounded
         * one. Older turns stay reachable by scrolling, which pages them from
         * the network.
         */
        const val CACHED_MESSAGE_LIMIT = 400

        const val OLDER_PAGE_LIMIT = 200

        fun factory(application: Application): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val sessionStore = SessionCookieStore(application)
                ChatViewModel(
                    client = ChatClient(
                        sessionStore = sessionStore,
                        // Recorded like auth, so the inspector shows the exact
                        // bytes the chat sent.
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport(AuthConfig.BASE_URL),
                        ),
                    ),
                    cache = RoomChatCache(application),
                    eventStream = HttpChatEventStream(sessionStore),
                )
            }
        }
    }
}
