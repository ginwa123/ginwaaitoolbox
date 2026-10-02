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
    /**
     * The app's ONE event connection, shared with the sidebar.
     *
     * Subscribed once, in `init`, for the life of the ViewModel — which is the
     * life of the Activity. Previously this owned a second socket that was
     * stopped and started on every session switch; the bus is opened at sign-in
     * and never per chat, so "which chat is open" became a *filter* in
     * [handleBusEvent] rather than a reason to reconnect.
     */
    private val bus: SseBus,
    // Reads a picked `content://` image into an encoded attachment. Injected
    // because it is the only part of the send path that needs a `Bitmap`, and
    // threading a `Context` in for it would put the Android framework in the
    // middle of a rule that is really about a 10 MB cap.
    private val imageReader: PickedImageReader = PickedImageReader { null },
    // Injected so tests can drive the fetch on the same scheduler as the paint;
    // `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    private val _uiState = MutableStateFlow(ChatUiState())
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()

    private val _sessionExpired = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val sessionExpired: SharedFlow<Unit> = _sessionExpired.asSharedFlow()

    /**
     * Detaches from the root bus. Held because the subscription outlives every
     * session: this ViewModel is Activity-scoped, so unsubscribing is tied to
     * the Activity dying, not to the user leaving a chat.
     */
    private var unsubscribeFromBus: (() -> Unit)? = null

    init {
        unsubscribeFromBus = bus.subscribe(
            onEvent = { event -> handleBusEvent(event) },
            onState = { state -> handleBusState(state) },
        )
    }

    private var userId: String? = null
    private var loadJob: Job? = null
    private var cachePrimeJob: Job? = null
    private var olderPagePrimeJob: Job? = null
    private var olderJob: Job? = null
    private var sendJob: Job? = null
    /** The `GET .../queue_messages` behind the composer's queue panel. */
    private var queueJob: Job? = null
    private var attachJob: Job? = null
    private var stopJob: Job? = null
    private var answerJob: Job? = null
    /** The `GET /api/config/nalar` behind the composer's model picker. */
    private var profilesJob: Job? = null
    /** The `PUT /api/llm/session/{id}` that saves a picked profile. */
    private var profileJob: Job? = null

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
     * Whether a full descending page has already answered the older-page
     * question for the chat now open.
     *
     * Not the same question as "is [olderCursor] set", because the answer to
     * *this* one is sometimes "there is nothing older" — and that answer has no
     * cursor to show for itself. Without the flag, a restored cursor from a
     * previous chat could arrive after a fresh page had said there was nothing
     * and quietly re-arm scroll-back against a transcript that is complete.
     */
    private var olderPageIsSettled: Boolean = false

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

    /**
     * Has the bus dropped and come back since the open chat was opened?
     *
     * Reset in [openSession], so what it actually answers is "did this chat miss
     * anything?", which is the question that matters. That reading survived the
     * move to one shared socket: the first `Live` *after* a chat is open is
     * either a reconnect — in which case the refetch is the only repair, since
     * the server keeps no replay buffer — or a connect the chat was already
     * open for, in which case [openSession]'s own load covered the gap.
     */
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
            olderPageIsSettled = false
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
        olderPagePrimeJob?.cancel()
        sendJob?.cancel()
        queueJob?.cancel()
        stopJob?.cancel()
        answerJob?.cancel()
        // Nothing to detach: the bus is already carrying this chat's events and
        // the handlers below filter by the session the state says is open. The
        // socket is not re-pointed per chat — see [handleBusEvent].
        liveMessageIds.clear()
        subAgentBatches.clear()
        olderCursor = null
        olderPageIsSettled = false
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

        restoreOlderPage(sessionId, requestGeneration)

        revalidate(sessionId, requestGeneration)
        reattachInFlightTurn(sessionId, requestGeneration)
        loadProfiles(requestGeneration)
        revalidateQueue(sessionId, requestGeneration)
    }

    /**
     * Fetches the profile list the composer's picker offers.
     *
     * On the same [generation] guard as everything else in an open: a profile
     * list fetched for the chat the reader just left would otherwise land on
     * the new one, and since profiles are account-wide the two lists are the
     * same — but the *publish* is not, and a stale publish after a
     * sign-out is a stale account's data on screen.
     *
     * Failure is silent by design. A profile list is a dropdown, not the
     * transcript, and surfacing its failure through [ChatUiState.errorMessage]
     * would blank a chat that loaded perfectly well to complain about a menu
     * the reader may never open. The chip degrades to a plain label, which is
     * exactly the control it used to be.
     */
    private fun loadProfiles(requestGeneration: Int) {
        profilesJob?.cancel()
        profilesJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) { client.loadProfiles() }
            if (requestGeneration != generation) return@launch
            val page = (result as? ChatResult.Loaded)?.value ?: return@launch
            _uiState.update { state ->
                state.copy(
                    availableProfiles = page.profiles,
                    activeProfile = page.activeProfile,
                    isLoadingProfiles = false,
                )
            }
        }
    }

    /**
     * Reads the server's queue for this chat and *replaces* what is on screen.
     *
     * A replacement rather than a merge, deliberately, in both directions: the
     * local mirror is built from `queue_queued` / `queue_deleted` frames, and a
     * frame missed while the socket was down leaves it permanently wrong. This
     * is the only read that repairs that, and it is cheap — one row per waiting
     * turn — so it runs on every open and every reconnect.
     *
     * A failure publishes nothing. The mirror is still better than nothing for
     * the turns the stream *did* report, and replacing it with an empty list
     * because the network blipped would delete a message the reader can see
     * was queued.
     */
    private fun revalidateQueue(sessionId: String, requestGeneration: Int) {
        queueJob?.cancel()
        queueJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) { client.loadQueuedMessages(sessionId) }
            if (requestGeneration != generation) return@launch
            val queued = (result as? ChatResult.Loaded)?.value ?: return@launch
            _uiState.update { state ->
                if (state.sessionId != sessionId) {
                    state
                } else {
                    state.copy(queuedMessages = queued)
                }
            }
        }
    }

    /**
     * Puts a waiting turn back in the box, which is the reader's way of
     * editing it before the worker gets to it.
     *
     * The row **stays queued**: it is the server's turn, not the reader's
     * draft, and the only way to take it out of the queue is for the worker to
     * drain it. Copying the text out of a list the reader is about to send is
     * what the web does here too (`FileInput.vue:415`), and matching it means a
     * reader who learns the gesture on the phone is not surprised on the web.
     */
    fun useQueuedMessage(message: QueuedChatMessage) {
        _uiState.update { state ->
            state.copy(draft = message.message.trim())
        }
    }

    /**
     * Re-reads the queue behind an open panel.
     *
     * The panel is where the reader is deciding whether to wait or to compose
     * something else, so the list they are looking at is the one worth being
     * certain about — a locally-mirrored row that the worker already drained
     * would have them compose a turn that duplicates one they just sent.
     */
    fun refreshQueuedMessages() {
        val sessionId = _uiState.value.sessionId ?: return
        revalidateQueue(sessionId, generation)
    }

    /**
     * Put this chat on [profileName], and remember that it is there.
     *
     * Empty clears the override, which is a real choice — see
     * [ChatClient.updateSelectedProfile] — and is what the picker's "Default"
     * row sends.
     *
     * **The state changes only after the server agrees.** An optimistic write
     * here would be actively wrong: the chip would name a profile the next
     * turn does not use, and the reader's only evidence that the pick failed
     * would be a chip they already trusted. A failed pick leaves the chip
     * where it was and puts the reason on screen.
     */
    fun selectProfile(profileName: String) {
        val state = _uiState.value
        val sessionId = state.sessionId ?: return
        if (state.isUpdatingProfile) return

        profileJob?.cancel()
        _uiState.update { it.copy(isUpdatingProfile = true, errorMessage = null) }
        profileJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                client.updateSelectedProfile(sessionId, profileName)
            }
            when (result) {
                is ChatResult.Loaded -> _uiState.update {
                    // The server echoes the column it stored, which is the
                    // authority on what this chat will now use.
                    it.copy(
                        selectedProfileModel = result.value,
                        isUpdatingProfile = false,
                    )
                }

                is ChatResult.Rejected -> _uiState.update {
                    it.copy(isUpdatingProfile = false, errorMessage = result.message)
                }

                is ChatResult.Unavailable -> _uiState.update {
                    it.copy(isUpdatingProfile = false, errorMessage = result.message)
                }

                ChatResult.SignedOut -> {
                    _uiState.update { it.copy(isUpdatingProfile = false) }
                    _sessionExpired.tryEmit(Unit)
                }
            }
        }
    }

    /**
     * Puts the *older* paging boundary back, the way the transcript cache puts
     * the messages back.
     *
     * Without it, `hasMoreOlder` and [olderCursor] survive only inside the
     * view model instance, and the second open of a chat is a different one:
     * [revalidate] finds a stored *tail* cursor, takes the warm ascending path,
     * and the descending page that carried `next_cursor` and `has_more` is never
     * asked for again. The sentinel row that arms scroll-to-top is therefore
     * never rendered, [loadOlderMessages] returns on a null cursor, and a
     * long chat silently stops at the newest few hundred messages for the rest
     * of the app's life. The tail cursor and the older boundary are two
     * independent facts and the warm path can only answer for one of them.
     *
     * Skipped when a full descending page has already answered for this chat —
     * that one is authoritative, because the server has just produced it rather
     * than remembered it.
     */
    private fun restoreOlderPage(sessionId: String, requestGeneration: Int) {
        olderPagePrimeJob?.cancel()
        olderPagePrimeJob = viewModelScope.launch {
            val restored = withContext(ioDispatcher) { cache.readOlderPage(userId, sessionId) }
            if (requestGeneration != generation) return@launch
            if (olderPageIsSettled) return@launch
            olderCursor = restored?.cursor
            _uiState.update { state ->
                if (state.sessionId != sessionId) {
                    state
                } else {
                    state.copy(hasMoreOlder = restored?.hasMore == true)
                }
            }
        }
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
            val (result, runIsActive) = withContext(ioDispatcher) {
                // Two reads, one instant, because neither alone can tell a
                // finished run from a live one.
                //
                // The transcript knows which turns have been *written*; the
                // worker list knows whether anything is still *running*. The
                // frames that normally retire a streaming placeholder —
                // `chunk_final` and `llm_full` — are ordinary SSE frames on a
                // connection the server keeps no replay buffer for, so a phone
                // that was backgrounded, rotated or briefly offline across the
                // end of a run misses both and cannot tell. Asking again is the
                // only repair, and asking only one of these two questions is a
                // repair that cannot see the failure it exists for.
                val page = client.loadMessages(
                    sessionId = sessionId,
                    cursor = storedCursor,
                    // Cold (no cursor): a full descending load. Warm: only the
                    // tail past the cursor. The web switches the same way, and
                    // the reason is that a stored cursor is a *newest* row, not
                    // a page break.
                    direction = if (storedCursor == null) "desc" else "asc",
                )
                // A read that failed answers nothing, and the only safe answer
                // to "nothing" here is "still running" — same rule
                // `WorkerActivityViewModel` applies to its own set. Clearing a
                // live answer because the network blipped is the same lie as
                // never lighting one up.
                val active = (client.isSessionRunning(sessionId) as? ChatResult.Loaded)?.value
                page to (active ?: true)
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
                    runIsActive = runIsActive,
                )
            }
        }
    }

    /**
     * What one refetch has to say about the turn that was in flight.
     *
     * [rows] is the transcript with every placeholder settled;
     * [stillStreaming] is whether the header should go on claiming a run.
     */
    private class StreamingSettle(
        val rows: List<ChatMessage>,
        val stillStreaming: Boolean,
    )

    /**
     * Reconciles the streaming placeholder against what the server just said.
     *
     * A placeholder is a *claim* that a turn exists on the server but has not
     * been written yet. Two things mint one — the `llm_chunk` deltas and the
     * in-memory snapshot read by [reattachInFlightTurn] — and the frames that
     * normally retire it are delivered on a stream with no replay. Miss both
     * and the phone keeps claiming a run that finished minutes ago: the header
     * reads "Working…", the composer offers a Stop button for a worker that no
     * longer exists, and a `streaming…` hint hangs under a turn that is already
     * answered. Nothing else in the class can repair that — [ChatApi.mergeById]
     * keeps a row whose id never appears in a server page, and a `streaming-`
     * id by construction never does — so the refetch has to.
     *
     * Two facts arrive together and each settles a different half:
     *
     * - `incoming` is the authoritative transcript. A placeholder whose text is
     *   a **prefix** of the newest assistant row in it is a turn that has
     *   landed, and the row beside it is now the real one. This is the only
     *   test here that deletes a row, so it runs on positive evidence only.
     * - `runIsActive` is the backend's own answer to "is a worker on this
     *   session". No worker means no further `llm_chunk` can arrive, so a
     *   placeholder with no matching row is a turn that will never be written
     *   at all — a cancel before the first token, or a crash — and its partial
     *   text is the whole answer. It is unfrozen rather than dropped, which is
     *   exactly what a reader who pressed Stop is given.
     *
     * A live run is left completely alone: no row is touched and the flag stays
     * set, because a refetch during one is routine.
     */
    private fun settleStreaming(
        rows: List<ChatMessage>,
        incoming: List<ChatMessage>,
        runIsActive: Boolean,
    ): StreamingSettle {
        if (rows.none { it.isStreamingPlaceholder }) {
            // Nothing to settle, and nothing this refetch is entitled to
            // conclude about a run: no row is frozen, so the flag belongs to
            // whatever wrote it. Leaving it alone is the safe direction — the
            // one thing that must never happen here is un-setting a flag whose
            // cause this function cannot see.
            return StreamingSettle(rows, stillStreaming = true)
        }

        // The placeholder is always the newest turn, so the row that can retire
        // it is the newest assistant turn that is not itself a placeholder.
        // Scoping the search that way is what keeps a short partial from
        // matching some older answer that happens to start the same way.
        val newestAssistant = (incoming + rows.filterNot { it.isStreamingPlaceholder })
            .filter { it.role == ChatMessage.ROLE_ASSISTANT }
            .maxByOrNull { it.sortKeyNanos }

        val settled = rows.mapNotNull { row ->
            if (!row.isStreamingPlaceholder) return@mapNotNull row
            if (newestAssistant?.supersedesStreaming(row) == true) {
                // The turn landed. Drop the stub; the canonical row arrives
                // through the merge below and takes its place.
                null
            } else if (runIsActive) {
                row
            } else {
                // No worker, no row: the turn ended without being written, so
                // the text on screen is the answer and must stop claiming
                // otherwise.
                row.copy(isStreaming = false)
            }
        }
        return StreamingSettle(rows = settled, stillStreaming = runIsActive && settled.any { it.isStreaming })
    }

    private suspend fun applyPage(
        page: ChatPage,
        sessionId: String,
        isFullReload: Boolean,
        runIsActive: Boolean,
    ) {
        val incoming = page.messages.filterNot { message -> message.id in liveMessageIds }
        // Whatever the network just returned is newer than the cache, so the
        // prime must not be allowed to land on top of it.
        hasFreshContent = true

        _uiState.update { state ->
            val settle = settleStreaming(state.messages, incoming, runIsActive)
            state.copy(
                isLoading = false,
                messages = ChatApi.mergeById(settle.rows, incoming)
                    .sortedBy { message -> message.sortKeyNanos },
                isStreaming = state.isStreaming && settle.stillStreaming,
                selectedProfileModel = page.selectedProfileModel
                    .ifEmpty { state.selectedProfileModel },
                cwd = page.cwd.ifEmpty { state.cwd },
                errorMessage = null,
            )
        }
        if (isFullReload) {
            olderCursor = page.nextCursor
            olderPageIsSettled = true
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
                // Only a *full descending* page carries a boundary. A warm tail
                // fetch is short by definition, so its `next_cursor`/`has_more`
                // describe the delta, not the transcript, and persisting them
                // would point scroll-back at the newest row.
                if (isFullReload) {
                    cache.writeOlderPage(
                        userId,
                        sessionId,
                        page.nextCursor?.let { ChatOlderPage(cursor = it, hasMore = page.hasMore) },
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
                    olderPageIsSettled = true

                    // The boundary moved, so the one on disk is stale. Leaving
                    // it is not a smaller problem than the warm open it feeds:
                    // a reader who paged back to the start of a long chat and
                    // then reopened it would be shown a cursor that re-requests
                    // the page they have already read.
                    val moved = olderCursor?.let { ChatOlderPage(it, result.value.hasMore) }
                    withContext(ioDispatcher) {
                        if (older.isNotEmpty()) {
                            cache.writeMessages(
                                userId,
                                sessionId,
                                older.mapNotNull { message ->
                                    ChatCacheCodec.toCachedMessage(sessionId, rawObjectFor(message))
                                },
                            )
                        }
                        cache.writeOlderPage(userId, sessionId, moved)
                    }
                }
            }
        }
    }

    fun onDraftChanged(value: String) {
        _uiState.update { it.copy(draft = value) }
    }

    /**
     * Decode a picked image and add it to the turn being composed.
     *
     * The cap is checked **after** the decode and against the attachments
     * already on the turn, not against a guess made before it. The reader
     * downsamples and re-encodes, so the size that matters is only known once
     * the bytes exist — and checking a pre-decode estimate is how an app ends
     * up refusing a 200 KB screenshot it had room for.
     *
     * A refusal is a message, not a silent drop: the reader picked a file, and
     * the only honest answer to "nothing happened" is which rule said no.
     */
    fun attachImage(source: String) {
        if (_uiState.value.isAttaching) return
        attachJob?.cancel()
        _uiState.update { it.copy(isAttaching = true, errorMessage = null) }
        attachJob = viewModelScope.launch {
            val attachment = imageReader.read(source)
            val state = _uiState.value
            when {
                attachment == null -> _uiState.update {
                    it.copy(isAttaching = false, errorMessage = "That image could not be read.")
                }

                ChatAttachments.rejection(state.pendingAttachments, attachment.byteCount) != null ->
                    _uiState.update {
                        it.copy(
                            isAttaching = false,
                            errorMessage = ChatAttachments.rejection(
                                state.pendingAttachments,
                                attachment.byteCount,
                            ),
                        )
                    }

                // Re-picked the same photo. Its id is derived from the URI, so
                // this is a real duplicate rather than a near miss — and adding
                // it twice would spend the reader's budget on one image.
                state.pendingAttachments.any { it.id == attachment.id } ->
                    _uiState.update { it.copy(isAttaching = false) }

                else -> _uiState.update {
                    it.copy(
                        isAttaching = false,
                        pendingAttachments = it.pendingAttachments + attachment,
                    )
                }
            }
        }
    }

    /**
     * Drop one attached image.
     *
     * Immediate rather than round-tripped: a reader who taps the ✕ on a
     * picture they just chose expects the picture to go, and an optimistic
     * removal here has nothing to roll back — the bytes were never sent.
     */
    fun removeAttachment(id: String) {
        _uiState.update { state ->
            state.copy(pendingAttachments = state.pendingAttachments.filterNot { it.id == id })
        }
    }

    /**
     * Queues a turn.
     *
     * **"Queue" is this method's normal case, not a special one.** There is no
     * separate queue endpoint and no flag: the same `POST /llm/session` with a
     * `queue_message` starts a run when the session is idle and lands in
     * `session_queue_messages` when a worker is already live
     * (`workflow.zig:688`, drained by the loop check at `workflow.zig:1565`).
     * The composer's queue button therefore calls this, and the whole client-
     * side difference is whether the button is offered.
     *
     * There is no optimistic bubble. The web removed one deliberately: a local
     * push sits at the wrong end of the array and re-keys the grouped list,
     * which silently re-renders tool cards the user had just expanded. The
     * canonical row arrives over SSE instead, so the draft is cleared only once
     * the server has actually accepted the turn — and a *queued* turn produces
     * no row at all until the worker drains it, which is what
     * [ChatUiState.queuedMessages] is for.
     */
    fun sendMessage() {
        val state = _uiState.value
        val sessionId = state.sessionId ?: return
        val text = state.draft.trim()
        // An image on its own is a turn. "You can't send a message with no
        // message" is a rule from a client that had no attachments, and the
        // reader who attached a screenshot and wrote nothing is asking a
        // question the picture answers.
        val attachments = state.pendingAttachments
        if ((text.isEmpty() && attachments.isEmpty()) || state.isSending) return

        sendJob?.cancel()
        _uiState.update { it.copy(isSending = true, errorMessage = null) }
        sendJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                client.sendMessage(
                    sessionId = sessionId,
                    message = text,
                    cwd = state.cwd,
                    // Already-encoded data URLs. The backend splits this field
                    // on `|` and validates each segment is
                    // `data:image/*;base64,…`; base64's alphabet contains no
                    // pipe, so no escaping is needed or possible here.
                    imageUrls = ChatAttachments.dataUrls(attachments),
                    selectedProfileModel = state.selectedProfileModel,
                )
            }
            when (result) {
                is ChatResult.Loaded -> _uiState.update {
                    it.copy(isSending = false, draft = "", pendingAttachments = emptyList())
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
                // Cleared on the way out, not left to the frames that will
                // follow. A stop does not always produce a final chunk or a
                // completed row — the turn it interrupts is precisely the one
                // that never finishes — so waiting for one leaves the header
                // reading "Working…" with a Stop button against a run that is
                // already gone, and the only thing that clears it is opening
                // another chat.
                is ChatResult.Loaded -> stopStreaming()

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
        // The socket is not this ViewModel's to close any more -- `MainActivity`
        // closes the bus, which is what holds the cookie.
        userId = null
        liveMessageIds.clear()
        subAgentBatches.clear()
        olderCursor = null
        olderPageIsSettled = false
        _uiState.value = ChatUiState()
        hasFreshContent = false
        cachePrimeJob?.cancel()
        olderPagePrimeJob?.cancel()
        loadJob?.cancel()
        olderJob?.cancel()
        sendJob?.cancel()
        queueJob?.cancel()
        stopJob?.cancel()
        answerJob?.cancel()
        cache.clear()
    }

    override fun onCleared() {
        cachePrimeJob?.cancel()
        olderPagePrimeJob?.cancel()
        unsubscribeFromBus?.invoke()
        unsubscribeFromBus = null
        super.onCleared()
    }

    /**
     * Drops the claim that a turn is still arriving — in **both** the places it
     * is held, because the header and the transcript read different ones.
     *
     * [ChatUiState.isStreaming] drives `isChatWorking`, so it is what keeps the
     * "Working…" label and the Stop button on screen. [ChatMessage.isStreaming]
     * on the row drives `StreamingHint`, the "streaming…" line under the turn.
     * Clearing only the state flag leaves a terminal failure rendering as a
     * settled header over a turn that still claims to be mid-sentence — two
     * halves of one truth, disagreeing, which is the state a reader has no way
     * to interpret.
     *
     * The rows themselves are kept, unfrozen. The placeholder's text is real
     * output the reader watched arrive, and [ChatViewModel.upsertFullMessage]
     * still owns replacing it with the canonical row when that lands.
     */
    private fun stopStreaming(
        errorMessage: String? = null,
        isLive: Boolean? = null,
    ) {
        _uiState.update { state ->
            state.copy(
                isStreaming = false,
                messages = state.messages.map { message ->
                    if (message.isStreaming) message.copy(isStreaming = false) else message
                },
                errorMessage = errorMessage ?: state.errorMessage,
                isLive = isLive ?: state.isLive,
            )
        }
    }

    /**
     * The bus's connection state, narrowed to the chat that is open.
     *
     * One socket means one set of transitions for the whole process, so this
     * ignores them while no chat is open rather than letting a sidebar-driven
     * reconnect grey out a transcript that is perfectly fine.
     */
    private fun handleBusState(state: ChatStreamState) {
        val sessionId = _uiState.value.sessionId ?: return
        when (state) {
            is ChatStreamState.Live -> {
                _uiState.update { it.copy(isLive = true) }
                // A *re*connect means events were missed with no way to ask for
                // them, so the only repair is a refetch. The first connect needs
                // none — the load already in flight covers that window.
                if (hasConnectedStreamOnce) {
                    revalidate(sessionId, generation)
                    // Same reasoning, applied to the queue: frames lost while
                    // the socket was down are gone, and the list the reader is
                    // about to tap is built out of exactly those frames.
                    revalidateQueue(sessionId, generation)
                }
                hasConnectedStreamOnce = true
            }

            is ChatStreamState.Connecting,
            is ChatStreamState.Reconnecting,
            -> _uiState.update { it.copy(isLive = false) }

            // Terminal, so this is the last word on the turn. The pump
            // `return`s on a rejected handshake instead of retrying
            // (HttpChatEventStream: a non-2xx handshake is reported and the
            // pump exits), which means neither `chunk_final` nor `llm_full` is
            // ever coming for a turn that is still flagged as streaming. Left
            // set, `isChatWorking` keeps the Stop button and the "Working…"
            // label on screen for a run that cannot report anything again — the
            // same argument the `ChatStreamEvent.Failed` branch below makes for
            // an `is_error` frame.
            is ChatStreamState.Failed -> stopStreaming(
                errorMessage = state.message,
                isLive = false,
            )
        }
    }

    /**
     * One handler for every event on the shared bus, scoped to the open chat.
     *
     * The bus carries *all* sessions' `llm` and `queue` traffic — that is what
     * makes one socket enough — so `sessionId` is read from the state on every
     * event rather than captured when a stream was opened. Reading it live is
     * also what makes the two filters below equivalent: an event that arrives
     * between a session switch and the next paint is dropped by the state guard
     * before the per-event one is even reached.
     */
    private fun handleBusEvent(event: ChatStreamEvent) {
        val sessionId = _uiState.value.sessionId ?: return
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

            // Mirrored, not counted. A composer that can queue a turn has to
            // be able to show *which* turn is waiting — a turn that has left
            // the app and is now behind a two-minute tool call is a message
            // that looks lost, and "1 queued" does not tell the reader it is
            // their own.
            is ChatStreamEvent.QueueChanged ->
                if (event.sessionId == sessionId) applyQueueChange(event)

            // A diagnostic frame (`is_error`) is not a run in progress, so it
            // must clear the flag too — otherwise the header claims the agent
            // is still working after it has given up.
            is ChatStreamEvent.Failed -> stopStreaming(errorMessage = event.message)

            // Worker liveness is not this screen's state. It is kept for the
            // whole app in `RunningSessionsStore` and fed by
            // `WorkerActivityViewModel`, which is the *other* subscriber to this
            // same bus. Both now see every worker frame, so this branch exists to
            // say "deliberately not mine" rather than because the channel is
            // elsewhere.
            is ChatStreamEvent.WorkerChanged -> Unit
        }
    }

    /**
     * Folds one `queue_queued` / `queue_deleted` frame into the mirror.
     *
     * Matched by id rather than by count, and an id already present is
     * ignored: the same frame is delivered on the per-session key *and* on the
     * central `queue` broadcast (`insert_queue_message.zig`), so the same
     * queueing arrives twice and a blind append would show every queued turn
     * twice. The web has the same double delivery and the same guard
     * (`ChatView.vue:3716`).
     *
     * A delete for an id that is not in the list is a no-op for the same
     * reason: the frame is real, the mirror is behind, and the next
     * [revalidateQueue] is what settles it.
     */
    private fun applyQueueChange(event: ChatStreamEvent.QueueChanged) {
        _uiState.update { state ->
            when (event.action) {
                ChatStreamEvent.QueueChanged.ACTION_QUEUED -> {
                    if (state.queuedMessages.any { it.id == event.id }) {
                        state
                    } else {
                        state.copy(
                            queuedMessages = state.queuedMessages + QueuedChatMessage(
                                id = event.id,
                                message = event.message,
                            ),
                        )
                    }
                }

                else -> state.copy(
                    queuedMessages = state.queuedMessages.filterNot { it.id == event.id },
                )
            }
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
     *
     * **Appended, never re-sorted**, and that is the whole point.
     *
     * The backend's `llm_full` payload (`SseEventLLMHistory`,
     * `src/agentic_loop/sse_on_event_send_llm_history.zig:19-56`) declares no
     * `created_at` member, so a row decoded from a frame arrives with a sort key
     * of `0`. Sorting that against a transcript whose every other row carries a
     * real nanosecond timestamp files the turn the reader JUST SENT at **index
     * 0** — the top of the chat — while the viewport is pinned to the last index.
     * The reader watches a spinner appear over a conversation that never shows
     * their own words, and the defect then persists: `liveMessageIds` suppresses
     * the REST repair, and [rawObjectFor] writes `created_at = "0"` so a cold
     * start re-reads the same wrong position.
     *
     * An `llm_full` frame is by construction the row the worker has *just*
     * written, so arrival order *is* chronological order. The Vue web relies on
     * exactly that and pushes the frame with a local clock
     * (`ChatView.vue:3870-3873`); this mirrors it rather than inventing a second
     * ordering rule for the same wire.
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
                candidate.isStreamingPlaceholder ||
                    candidate.id == message.id
            }
            state.copy(
                messages = dropped + message.stampedForArrival(dropped),
                isStreaming = false,
                errorMessage = null,
            )
        }

        // The STAMPED row is what goes to disk, not the frame as it arrived.
        // `rawObjectFor` persists `created_at = sortKeyNanos`, so writing the
        // unstamped copy stores `"0"` and the next cold start re-sorts this turn
        // to the top of the chat — the exact defect this stamps it to prevent,
        // re-armed on every restart. `update` publishes synchronously, so the
        // stamped row is already in the state by the time this reads it back.
        val placed = _uiState.value.messages.lastOrNull { it.id == message.id }
            ?: message

        viewModelScope.launch {
            withContext(ioDispatcher) {
                cache.writeMessages(
                    userId,
                    sessionId,
                    listOfNotNull(
                        ChatCacheCodec.toCachedMessage(sessionId, rawObjectFor(placed)),
                    ),
                )
            }
        }
    }

    /**
     * Gives a frame-delivered row a sort key it can actually be ordered by.
     *
     * A row that already carries a server timestamp is left alone: that
     * timestamp is the authority, and a local clock must never outrank it.
     *
     * One that does not gets this phone's arrival clock — **floored just above
     * every row already on screen**. The floor is what makes the fix independent
     * of the phone's clock being right: a device whose clock is an hour behind
     * the server's would otherwise stamp its own turn with an older key than the
     * transcript around it and re-sort it back to where it just came from. The
     * floor is computed against the rows that survive the merge, and skips the
     * `Long.MAX_VALUE` sentinel the streaming placeholder uses, so it can never
     * overflow on the increment.
     */
    private fun ChatMessage.stampedForArrival(siblings: List<ChatMessage>): ChatMessage {
        if (sortKeyNanos > 0L) return this
        val millis = nowMillis()
        val newestSibling = siblings
            .map { it.sortKeyNanos }
            .filter { it in 1 until Long.MAX_VALUE }
            .maxOrNull() ?: 0L
        return copy(
            createdAtEpochMillis = millis,
            sortKeyNanos = maxOf(millis * ChatApi.NANOS_PER_MILLI, newestSibling + 1L),
        )
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
                            HttpsAuthTransport { AuthConfig.BASE_URL },
                        ),
                    ),
                    cache = RoomChatCache(application),
                    bus = SseBusHolder.get(sessionStore),
                    imageReader = BitmapPickedImageReader(application.contentResolver),
                )
            }
        }
    }
}
