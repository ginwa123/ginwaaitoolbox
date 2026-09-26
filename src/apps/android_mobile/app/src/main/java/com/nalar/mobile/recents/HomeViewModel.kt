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
     */
    private fun loadChats(workspaceId: String) {
        primeChatsFromCache(workspaceId)

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
                    val chats = result.value
                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) {
                            cache.writeChats(id, workspaceId, chats)
                        }
                    }
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
                            )
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
                    cache = KeystoreRecentsCache(application),
                )
            }
        }
    }
}
