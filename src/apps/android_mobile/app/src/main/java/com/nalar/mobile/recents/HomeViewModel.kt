package com.nalar.mobile.recents

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

data class HomeUiState(
    val isLoading: Boolean = true,
    val workspaces: List<WorkspaceOption> = emptyList(),
    val selectedWorkspaceId: String? = null,
    val chats: List<ChatSummary> = emptyList(),
    val selectedChatId: String? = null,
    val errorMessage: String? = null,
    /**
     * A *later* page is in flight. Kept apart from [isLoading] on purpose: the
     * first page blanks the list with a spinner, a later page must not — the
     * rows already on screen are real and stay put while the next page loads.
     */
    val isLoadingMoreChats: Boolean = false,
    /** Whether the server says another page exists. False ends the scroll. */
    val hasMoreChats: Boolean = false,
    /** Full filtered row count for the selected workspace; 0 when unreported. */
    val chatsTotal: Int = 0,
) {
    /** Nothing to show and nothing wrong — the account genuinely has no workspaces. */
    val isEmpty: Boolean
        get() = !isLoading && errorMessage == null && workspaces.isEmpty()

    /**
     * Rows are on screen but the last refresh failed. The sidebar keeps showing
     * the data and says so, rather than blanking a working list.
     */
    val isShowingStaleData: Boolean
        get() = errorMessage != null && workspaces.isNotEmpty()

    /**
     * The scroll should keep asking. True whenever there is something left to
     * fetch, so the sidebar and the ViewModel agree on when to stop — the

     * alternative is two independent notions of "done" that drift.
     *
     * [chatsTotal] is a belt-and-braces check on top of the server's own
     * `has_more`: once the list physically holds as many rows as the server
     * said exist, there is nothing left to ask for even if `has_more` still
     * says otherwise. A non-positive [chatsTotal] means the server did not
     * report a count, in which case only `has_more` can say.
     */
    val canLoadMoreChats: Boolean
        get() = hasMoreChats && !isLoadingMoreChats && !isLoading && !hasReachedTotal

    private val hasReachedTotal: Boolean
        get() = chatsTotal > 0 && chats.size >= chatsTotal
}

/**
 * Owns the sidebar's real data. There is no preview fallback here on purpose:
 * a list that quietly renders demo rows is indistinguishable from a working
 * one, which is exactly how the mock survived review.
 *
 * Cached rows are painted first and then revalidated — the same
 * stale-while-revalidate shape the desktop's `workspacesCache` uses, and
 * deliberately with no TTL, because every paint is followed by a live fetch.
 */
class HomeViewModel(
    private val client: RecentsClient,
    private val cache: RecentsCache,
    // Injected so tests can drive the fetch on the same scheduler as the paint;
    // `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {
    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    private val _sessionExpired = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val sessionExpired: SharedFlow<Unit> = _sessionExpired.asSharedFlow()

    private var userId: String? = null
    private var hasStarted = false
    private var workspacesJob: Job? = null
    private var chatsJob: Job? = null

    /**
     * A later page's fetch. Deliberately a *separate* job from [chatsJob]: a
     * refresh must be able to cancel page 1 without a stale load-more landing
     * on top of it, and the two have to be cancellable independently.
     */
    private var moreChatsJob: Job? = null

    /**
     * The server's resume value for the next page, held here rather than in
     * [HomeUiState] because it is protocol, not view state: nothing renders it
     * and a rotation must not be able to perturb it.
     */
    private var chatsCursor: String? = null

    /**
     * Bumped whenever the recents list is replaced from scratch. A page that
     * was in flight for the previous generation is dropped on arrival rather
     * than merged into a list it no longer belongs to — the same guard the
     * workspace-id check gives for a slow response, but covering the harder
     * case where the same workspace is reloaded underneath the user.
     */
    private var chatsGeneration = 0

    /**
     * The single entry point. Driven by the auth state: every change of account
     * re-scopes the cache and reloads, so no rows ever painted for the previous
     * account survive into the new one's session.
     */
    fun onUserChanged(newUserId: String?) {
        if (hasStarted && newUserId == userId) return
        hasStarted = true

        val accountChanged = newUserId != userId
        userId = newUserId
        if (accountChanged) {
            // Blank rather than keep: the old rows belong to someone else.
            _uiState.value = HomeUiState()
        }
        refresh()
    }

    fun refresh() {
        primeWorkspacesFromCache()
        // The workspace the prime above selected needs its own paint, and it
        // must happen NOW — waiting for the workspaces fetch to return first
        // would put a spinner over recents we already have on disk.
        _uiState.value.selectedWorkspaceId?.let { primeChatsFromCache(it) }

        workspacesJob?.cancel()
        workspacesJob = viewModelScope.launch {
            when (val result = withContext(ioDispatcher) { client.loadWorkspaces() }) {
                is RecentsResult.SignedOut -> expireSession()

                is RecentsResult.Unavailable -> _uiState.update {
                    // Keep whatever is on screen — cached or not. A stale sidebar
                    // beats a blank one when the network blips.
                    it.copy(isLoading = false, errorMessage = result.message)
                }

                is RecentsResult.Loaded -> {
                    val workspaces = result.value
                    // Hold the current selection across a refresh so the drawer
                    // does not jump back to the top on every pull-to-refresh.
                    val selected = workspaces
                        .firstOrNull { it.id == _uiState.value.selectedWorkspaceId }
                        ?.id
                        ?: workspaces.firstOrNull()?.id

                    _uiState.update {
                        it.copy(
                            isLoading = false,
                            workspaces = workspaces,
                            selectedWorkspaceId = selected,
                            errorMessage = null,
                        )
                    }

                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) { cache.writeWorkspaces(id, workspaces) }
                    }
                    if (selected != null) loadChats(selected)
                }
            }
        }
    }

    /**
     * Paints the last-known workspace list synchronously, before any network
     * call. Chat priming lives in [loadChats] so that priming and revalidating
     * cannot be separated by a future caller.
     */
    private fun primeWorkspacesFromCache() {
        val cachedWorkspaces = cache.readWorkspaces(userId).orEmpty()

        if (cachedWorkspaces.isEmpty()) {
            // A genuine first launch has nothing to paint; the spinner is honest.
            _uiState.update { it.copy(isLoading = true, errorMessage = null) }
            return
        }

        val current = _uiState.value
        val selected = cachedWorkspaces
            .firstOrNull { it.id == current.selectedWorkspaceId }
            ?.id
            ?: cachedWorkspaces.firstOrNull()?.id

        _uiState.value = current.copy(
            isLoading = true,
            workspaces = cachedWorkspaces,
            selectedWorkspaceId = selected,
            errorMessage = null,
        )
    }

    fun selectWorkspace(workspaceId: String) {
        if (_uiState.value.selectedWorkspaceId == workspaceId) return
        // Clear first: leaving the old workspace's chats under the new
        // workspace's name for the length of the fetch reads as real data.
        _uiState.update {
            it.copy(
                selectedWorkspaceId = workspaceId,
                chats = emptyList(),
                selectedChatId = null,
                isLoading = true,
                errorMessage = null,
                // The cursor belongs to the workspace we are leaving. Carrying
                // it over would page the new workspace from a position in the
                // old one's history.
                isLoadingMoreChats = false,
                hasMoreChats = false,
                chatsTotal = 0,
            )
        }
        loadChats(workspaceId)
    }

    fun selectChat(chatId: String) {
        _uiState.update { it.copy(selectedChatId = chatId) }
    }

    /**
     * Paints one workspace's cached recents, if any survive. Always followed by
     * the fetch in [loadChats].
     */
    private fun primeChatsFromCache(workspaceId: String) {
        val cached = cache.readChats(userId, workspaceId)
            ?.filter { chat -> chat.workspaceId == workspaceId }
            ?: return

        _uiState.update { state ->
            // A paint for a workspace the user already left is not ours to apply.
            if (state.selectedWorkspaceId != workspaceId) {
                state
            } else {
                state.copy(
                    chats = cached,
                    selectedChatId = cached.firstOrNull()?.id,
                )
            }
        }
    }

    /**
     * Paint this workspace's cached recents, then revalidate. Both halves live
     * in one function on purpose: a cache paint with no live fetch behind it
     * would be permanently stale, and there is deliberately no TTL to catch
     * that. The web relies on every call site remembering to follow up; making
     * it structural here means no caller can get it wrong.
     *
     * This is page 1. Everything it learns about pagination (the cursor and
     * whether another page exists) is recorded here so [loadMoreChats] has a
     * correct starting point, and a full reload deliberately discards any pages
     * the user had already scrolled in.
     */
    private fun loadChats(workspaceId: String) {
        primeChatsFromCache(workspaceId)

        // A page-1 reload invalidates both the cursor and any page in flight:
        // that page was cut from a list which no longer exists.
        chatsGeneration++
        moreChatsJob?.cancel()
        chatsCursor = null
        _uiState.update {
            it.copy(isLoadingMoreChats = false, hasMoreChats = false, chatsTotal = 0)
        }

        val generation = chatsGeneration
        chatsJob?.cancel()
        chatsJob = viewModelScope.launch {
            when (val result = withContext(ioDispatcher) { client.loadChats(workspaceId) }) {
                is RecentsResult.SignedOut -> expireSession()

                is RecentsResult.Unavailable -> _uiState.update { state ->
                    // A slow response for a workspace the user has already left
                    // must not land under the new one.
                    if (state.selectedWorkspaceId != workspaceId) {
                        state
                    } else {
                        state.copy(isLoading = false, errorMessage = result.message)
                    }
                }

                is RecentsResult.Loaded -> {
                    val page = result.value
                    val chats = page.chats
                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) {
                            cache.writeChats(id, workspaceId, chats)
                        }
                    }
                    if (generation != chatsGeneration) return@launch
                    _uiState.update { state ->
                        if (state.selectedWorkspaceId != workspaceId) {
                            state
                        } else {
                            state.copy(
                                isLoading = false,
                                chats = chats,
                                selectedChatId = state.selectedChatId
                                    ?.takeIf { chatId -> chats.any { it.id == chatId } }
                                    ?: chats.firstOrNull()?.id,
                                hasMoreChats = page.hasMore,
                                chatsTotal = page.total,
                            )
                        }
                    }
                    // Set only after the state applied, so the scroll can never
                    // fire against a cursor the list does not match.
                    chatsCursor = page.nextCursor
                }
            }
        }
    }

    /**
     * Append the next page of recents. Called by the sidebar when the user
     * reaches the bottom of the list.
     *
     * A no-op in every state where asking again would be wrong — already
     * loading, nothing left, a first page still in flight — because the scroll
     * fires on *position*, and a short page that does not fill the viewport
     * leaves the trigger armed on every recomposition. The guard is what turns
     * that into a bounded sequence of fetches instead of a request storm.
     */
    fun loadMoreChats() {
        val state = _uiState.value
        if (!state.canLoadMoreChats) return
        val workspaceId = state.selectedWorkspaceId ?: return
        // An empty list means page 1 has not landed yet; paging from here would
        // append onto nothing.
        if (state.chats.isEmpty()) return
        val cursor = chatsCursor ?: return

        val generation = chatsGeneration
        moreChatsJob?.cancel()
        moreChatsJob = viewModelScope.launch {
            _uiState.update { it.copy(isLoadingMoreChats = true) }

            val result = withContext(ioDispatcher) {
                client.loadChats(workspaceId = workspaceId, cursor = cursor)
            }
            if (generation != chatsGeneration) return@launch
            // The workspace changed (or the list was reloaded) while the request
            // was out. Dropping it is correct: merging would splice another
            // workspace's rows into this one, or resurrect rows just deleted by
            // the reload.
            if (_uiState.value.selectedWorkspaceId != workspaceId) return@launch

            when (result) {
                is RecentsResult.SignedOut -> {
                    _uiState.update { it.copy(isLoadingMoreChats = false) }
                    expireSession()
                }

                is RecentsResult.Unavailable -> _uiState.update { current ->
                    // Keep the rows we already have and keep `hasMore` true, so
                    // scrolling again retries the same page. Blanking the
                    // sidebar, or silently ending the list, would both be
                    // worse than a page that did not arrive.
                    current.copy(isLoadingMoreChats = false)
                }

                is RecentsResult.Loaded -> {
                    val page = result.value
                    val known = _uiState.value.chats
                    val fresh = page.chats.filterNot { chat -> known.any { it.id == chat.id } }

                    _uiState.update { current ->
                        current.copy(
                            isLoadingMoreChats = false,
                            chats = RecentsApi.mergeChatsById(current.chats, page.chats),
                            // A page that added nothing new means the cursor is
                            // not advancing — either the end of the list or a
                            // server that keeps replaying rows. Either way,
                            // continuing would loop on the same page forever.
                            hasMoreChats = page.hasMore && fresh.isNotEmpty(),
                        )
                    }

                    // An empty page must not advance the cursor: holding the old
                    // one is what lets a retry re-request the same window.
                    if (fresh.isNotEmpty()) {
                        chatsCursor = page.nextCursor
                    } else {
                        chatsCursor = null
                    }

                    if (page.chats.isNotEmpty()) {
                        val id = userId
                        if (id != null) {
                            // Write the *merged* list, not this page: the cache
                            // is what a cold boot paints, and writing only the
                            // page would replace the rows above it.
                            withContext(ioDispatcher) {
                                cache.writeChats(id, workspaceId, _uiState.value.chats)
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * Sign-out. The cached rows are purged rather than left namespaced: the
     * user asked to switch accounts, the device may be shared, and rebuilding
     * the list costs one request.
     */
    fun onSignedOut() {
        userId = null
        hasStarted = false
        _uiState.value = HomeUiState()
        workspacesJob?.cancel()
        chatsJob?.cancel()
        // A page in flight belongs to the session that just ended; letting it
        // land would repopulate a sidebar for an account that is signed out.
        moreChatsJob?.cancel()
        chatsCursor = null
        chatsGeneration++
        cache.clear()
    }

    /**
     * A 401 means the cookie the auth flow saved is no longer valid. Sign-out
     * is the only correct response, so this hands off to the auth ViewModel
     * rather than showing a retry that cannot succeed.
     */
    private fun expireSession() {
        _uiState.update { it.copy(isLoading = false) }
        _sessionExpired.tryEmit(Unit)
    }

    companion object {
        fun factory(application: Application): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                HomeViewModel(
                    client = RecentsClient(
                        sessionStore = SessionCookieStore(application),
                        // Recorded like auth, so the inspector shows the exact
                        // bytes the sidebar sent.
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport(AuthConfig.BASE_URL),
                        ),
                    ),
                    cache = RoomRecentsCache(application),
                )
            }
        }
    }
}
