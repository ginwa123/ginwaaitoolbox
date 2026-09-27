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
import com.nalar.mobile.projects.CreateTaskRequest
import com.nalar.mobile.projects.ProjectsApi
import com.nalar.mobile.projects.ProjectsCache
import com.nalar.mobile.projects.ProjectChatsPage
import com.nalar.mobile.projects.ProjectsClient
import com.nalar.mobile.projects.RoomProjectsCache
import com.nalar.mobile.projects.ProjectSummary
import com.nalar.mobile.projects.isValidMemoryName
import com.nalar.mobile.storage.LastPosition
import com.nalar.mobile.storage.LastPositionStore
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
    // ── Projects (the sidebar's Projects section) ──────────────────────────
    /**
     * Whether the Recents section is unfolded.
     *
     * Expanded by default, same as [isProjectsExpanded] and for the same reason:
     * the recents list is the drawer's reason for existing, so making the reader
     * open it before it shows anything is a fold nobody asked for. Held beside
     * the projects flag rather than in the composable because it has to survive
     * the drawer closing — a section that re-opens itself every time the reader
     * looks at a chat is a setting that is not a setting.
     */
    val isRecentsExpanded: Boolean = true,
    /**
     * Whether the Projects section is unfolded. Expanded by default, matching
     * the desktop's `sidebarStore.projectsExpanded` — a section that has to be
     * opened before it is useful is a section most people never open.
     */
    val isProjectsExpanded: Boolean = true,
    val projects: List<ProjectSummary> = emptyList(),
    val isLoadingProjects: Boolean = false,
    /**
     * The projects fetch failed while rows are on screen. Kept separate from
     * [errorMessage] — that one is the recents/workspace refresh, and the two
     * can fail independently. A stale project list is worth showing; a stale
     * project list that replaced the recents error would be a lie about which
     * list is broken.
     */
    val projectsError: String? = null,
    /** Which project rows are unfolded. View-model state, not composable state. */
    val expandedProjectIds: Set<String> = emptySet(),
    /** One page per expanded project, keyed by project id. See [ProjectChatsPage]. */
    val projectChats: Map<String, ProjectChatsPage> = emptyMap(),
    /** Which projects have a later page in flight. */
    val isLoadingMoreProjectChats: Set<String> = emptySet(),
    // ── Creating a chat / task under a project ─────────────────────────────
    /**
     * The project whose create is in flight, or null.
     *
     * One id and not a set, because the entry point is a single `+` on one
     * expanded project: a reader cannot have two creates in the air from one
     * project row, and a second press on the same `+` while the first is open
     * is the double-tap this value exists to swallow.
     */
    val creatingTaskInProjectId: String? = null,
    /**
     * Why the last create failed, or null.
     *
     * Held apart from [projectsError] and [errorMessage] on purpose: those say a
     * *list* could not be loaded and the rows on screen are stale, which is
     * still true. This says the thing the reader just asked for did not happen,
     * and it has to be dismissible on its own — a reader who gave up on a memory
     * name should not have to retry the project fetch to clear the complaint.
     */
    val taskCreateError: String? = null,
) {
    fun isProjectExpanded(itemId: String): Boolean = itemId in expandedProjectIds

    fun projectChatsFor(itemId: String): ProjectChatsPage? = projectChats[itemId]

    /**
     * The scroll should keep asking for another page of this project.
     *
     * Mirrors [canLoadMoreChats]'s shape: the ViewModel owns the decision and
     * the UI just reports position, so there is only one notion of "done" and
     * the two cannot drift.
     */
    fun canLoadMoreProjectChats(itemId: String): Boolean {
        val page = projectChats[itemId] ?: return false
        return page.hasMore &&
            itemId !in isLoadingMoreProjectChats &&
            !isLoadingProjects &&
            page.chats.isNotEmpty()
    }

    /**
     * Whether the drawer should offer "See all chats" under this project.
     *
     * Only when the drawer is actually hiding something. A project with three
     * chats shows no button, because the drawer already showed all three and
     * the button would be a detour to the same three rows.
     *
     * Note what is *not* here: a count. The tasks endpoint's `count` is the
     * length of the page just returned, not a filtered total, so no total is
     * knowable without paging the whole list — per project, per refresh. A
     * button reading "See all 47 chats" when there are 312 is a worse lie than
     * no number.
     */
    fun shouldOfferSeeAllChats(itemId: String): Boolean {
        val page = projectChats[itemId] ?: return false
        return page.chats.size > ProjectsApi.DRAWER_PREVIEW_ROWS || page.hasMore
    }
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
    /**
     * A second client, not a widened [RecentsClient]. `RecentsApi`'s own KDoc
     * scopes it to "the sidebar's two endpoints", and its error strings say
     * "sidebar" in them — a projects failure reusing them would tell the user
     * the wrong list is broken. See [ProjectsClient].
     */
    private val projectsClient: ProjectsClient,
    /**
     * Separate from [cache] on purpose. `RecentsCache`'s KDoc scopes it to
     * exactly two endpoints and says adding a third "should be a deliberate
     * change to this interface, not a side effect of some new caller". This is
     * that deliberate change, so it gets its own interface and the existing
     * warning stays true.
     */
    private val projectsCache: ProjectsCache,
    /**
     * Where the position outlives the process. Injected rather than reached for
     * so the seed on the first launch, and the two writes a user action causes,
     * are observable in a test without a device.
     */
    private val positionStore: LastPositionStore,
    // Injected so tests can drive the fetch on the same scheduler as the paint;
    // `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {
    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    private val _sessionExpired = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val sessionExpired: SharedFlow<Unit> = _sessionExpired.asSharedFlow()

    /**
     * Session ids of chats this app just created, for the nav graph to open.
     *
     * An event and not a piece of [HomeUiState], because it is a one-shot
     * *navigation* with no resting place: a "navigate here" flag left in state
     * is re-read by every recomposition, so the chat would be reopened after
     * the reader navigated away. A flow is emitted once and forgotten.
     *
     * `extraBufferCapacity = 1` rather than a suspend send, because the create
     * has already finished by the time anyone might be collecting, and a
     * `MutableSharedFlow` with zero buffer drops an emission made with no
     * subscriber — which would silently cost the reader the chat they asked
     * for.
     */
    private val _createdChat = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val createdChat: SharedFlow<String> = _createdChat.asSharedFlow()

    private var userId: String? = null
    private var hasStarted = false
    private var workspacesJob: Job? = null
    private var chatsJob: Job? = null

    /**
     * The workspace the last run ended on, read once per launch.
     *
     * It is a *seed*, not a selection: the two lists this ViewModel paints can
     * arrive with and without that workspace in them, and the live list is what
     * decides — a workspace deleted on the server must not survive in a store
     * the app keeps consulting. So it is spent the moment the authoritative list
     * has been weighed (see [selectWorkspaceId]), which is also why a refresh
     * later in the session cannot resurrect it.
     */
    private var resumeWorkspaceSeed: String? = null

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

    // ── Projects ───────────────────────────────────────────────────────────
    private var projectsJob: Job? = null

    /**
     * Per-project resume values, held here rather than in [HomeUiState] for the
     * same reason [chatsCursor] is: it is protocol, not view state. Nothing
     * renders it and a rotation must not be able to perturb it.
     */
    private val projectCursors = mutableMapOf<String, String>()

    /** A later page per project. Separate job per project, like [moreChatsJob]. */
    private val moreProjectChatsJobs = mutableMapOf<String, Job>()

    /**
     * Per-project generation counter, bumped whenever a project's page 1 is
     * replaced from scratch.
     *
     * One counter for the whole list is not enough here the way [chatsGeneration]
     * is for chats: a page in flight for project A must not be dropped because
     * project B was refetched, but it *must* be dropped if A itself was — and
     * the drawer now has two independent scrollers reaching for the same map
     * (the inline preview and the project-chats screen), so a "See all" tap can
     * hand A to the screen while a drawer-initiated fetch is still in the air.
     * Without this, that late page lands on top of a list it no longer belongs
     * to.
     */
    private val projectGenerations = mutableMapOf<String, Int>()

    /** A page-1 reload invalidates every project, so one job for the section. */
    private var projectsGeneration = 0

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
        // Read before the first paint, not after: the drawer has to open on the
        // workspace the user left, and a seed applied once the list is already on
        // screen is a visible jump plus a wasted fetch for the wrong workspace.
        // Synchronous, because `SharedPreferences` is already in memory and this
        // runs once per launch, not per frame.
        resumeWorkspaceSeed = positionStore.read(newUserId).workspaceId
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
                    val selected = selectWorkspaceId(
                        workspaces = workspaces,
                        currentSelection = _uiState.value.selectedWorkspaceId,
                        resumeSeed = resumeWorkspaceSeed,
                    )
                    // The live list has now had its say on the seed: either it was
                    // applied just above, or the workspace is gone. Consulting it
                    // again on a later refresh would resurrect a dead id.
                    resumeWorkspaceSeed = null

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
                    // After loadChats, so the section's state clears and paints
                    // behind the recents it belongs to rather than in front of
                    // a spinner the reader is still waiting on.
                    if (selected != null) loadProjects(selected)
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
        val selected = selectWorkspaceId(
            workspaces = cachedWorkspaces,
            currentSelection = current.selectedWorkspaceId,
            resumeSeed = resumeWorkspaceSeed,
        )

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
                // The same rule for the same reason: the old workspace's
                // projects, and which of them were unfolded, belong to the
                // workspace we are leaving.
                isLoadingProjects = false,
                projectsError = null,
                expandedProjectIds = emptySet(),
                projectChats = emptyMap(),
                isLoadingMoreProjectChats = emptySet(),
            )
        }
        loadChats(workspaceId)
        loadProjects(workspaceId)
        // After the state, not before: a tap that lands somewhere the app cannot
        // recover from must not leave a position behind that the next launch
        // would try to resume.
        positionStore.saveWorkspace(userId, workspaceId)
    }

    /**
     * The user is now in this chat, which is the other half of the position. Both
     * halves are written together because a session id only means anything next to
     * the workspace it was opened from, and the workspace may have moved on since
     * the last write.
     *
     * A blank id is not a position, so it is not written; the caller is
     * highlighting a row, and an empty one is not a row.
     */
    fun selectChat(chatId: String) {
        if (chatId.isBlank()) return
        _uiState.update { it.copy(selectedChatId = chatId) }
        positionStore.save(
            userId,
            LastPosition(
                workspaceId = _uiState.value.selectedWorkspaceId,
                sessionId = chatId,
            ),
        )
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

    // ── Projects ───────────────────────────────────────────────────────────

    /**
     * Paint one workspace's projects, then revalidate — the same
     * cache-then-revalidate shape as [loadChats], and deliberately in one
     * function so a cache paint with no live fetch behind it cannot be written
     * by a future caller.
     *
     * A section reload invalidates every project's expanded state and every
     * page, because the set of projects itself may have changed: a project that
     * was deleted on the server must not survive as an expandable row.
     */
    private fun loadProjects(workspaceId: String) {
        primeProjectsFromCache(workspaceId)

        projectsGeneration++
        moreProjectChatsJobs.values.forEach { it.cancel() }
        moreProjectChatsJobs.clear()
        projectCursors.clear()
        projectGenerations.clear()
        _uiState.update {
            it.copy(
                isLoadingProjects = true,
                projectsError = null,
                expandedProjectIds = emptySet(),
                projectChats = emptyMap(),
                isLoadingMoreProjectChats = emptySet(),
            )
        }

        val generation = projectsGeneration
        projectsJob?.cancel()
        projectsJob = viewModelScope.launch {
            when (val result = withContext(ioDispatcher) { projectsClient.loadProjects(workspaceId) }) {
                is RecentsResult.SignedOut -> expireSession()

                is RecentsResult.Unavailable -> _uiState.update { state ->
                    // A slow response for a workspace the user has already left
                    // must not land under the new one.
                    if (state.selectedWorkspaceId != workspaceId) {
                        state
                    } else {
                        state.copy(isLoadingProjects = false, projectsError = result.message)
                    }
                }

                is RecentsResult.Loaded -> {
                    val projects = result.value
                    if (generation != projectsGeneration) return@launch
                    _uiState.update { state ->
                        if (state.selectedWorkspaceId != workspaceId) {
                            state
                        } else {
                            state.copy(
                                isLoadingProjects = false,
                                projects = projects,
                                projectsError = null,
                            )
                        }
                    }
                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) {
                            projectsCache.writeProjects(id, workspaceId, projects)
                        }
                    }
                }
            }
        }
    }

    /** Paints cached projects synchronously, before the network call. */
    private fun primeProjectsFromCache(workspaceId: String) {
        val cached = projectsCache.readProjects(userId, workspaceId) ?: return
        if (cached.isEmpty()) return

        _uiState.update { state ->
            // A paint for a workspace the user already left is not ours to apply.
            if (state.selectedWorkspaceId != workspaceId) {
                state
            } else {
                state.copy(projects = cached)
            }
        }
    }

    /**
     * Re-fetch just this section, for its own error surface's Retry.
     *
     * Not [refresh]: that re-runs the workspace fetch, and a projects
     * failure while the recents are perfectly fine would then be reported
     * against a list the reader never had a problem with.
     */
    fun retryProjects() {
        val workspaceId = _uiState.value.selectedWorkspaceId ?: return
        loadProjects(workspaceId)
    }

    /** Fold the whole section away, or unfold it. The state lives here, not in a composable. */
    fun toggleProjectsSection() {
        _uiState.update { it.copy(isProjectsExpanded = !it.isProjectsExpanded) }
    }

    /**
     * Fold the Recents section away, or unfold it.
     *
     * No fetch on re-opening, and no clearing on fold: the rows are already
     * paged into memory and the cached list is what a re-opened section should
     * show. Only the *visibility* changes, which is what makes folding cheap
     * enough to be worth doing at all.
     */
    fun toggleRecentsSection() {
        _uiState.update { it.copy(isRecentsExpanded = !it.isRecentsExpanded) }
    }

    /**
     * Fold one project open or shut.
     *
     * Opening fetches page 1 **once**. A second open replays from
     * [HomeUiState.projectChats] and does not refetch, because the drawer's
     * whole point is to be instantaneous to open.
     */
    fun toggleProjectExpanded(itemId: String) {
        val wasExpanded = _uiState.value.isProjectExpanded(itemId)
        _uiState.update { state ->
            state.copy(
                expandedProjectIds = if (wasExpanded) {
                    state.expandedProjectIds - itemId
                } else {
                    state.expandedProjectIds + itemId
                },
            )
        }
        if (wasExpanded) return
        ensureProjectChatsLoaded(itemId)
    }

    /**
     * Fetch page 1 for [itemId] if it is not already held.
     *
     * This is the seam that makes "See all chats" free: the drawer expands a
     * project (which calls this), the reader taps through to the project-chats
     * screen (which calls it again), and the second call is a no-op because the
     * first one already put the page in [HomeUiState.projectChats].
     *
     * A deep link into `nalar://project/…` with nothing cached falls through to
     * a real fetch, which is the case that actually needs it.
     */
    fun ensureProjectChatsLoaded(itemId: String) {
        val state = _uiState.value
        val workspaceId = state.selectedWorkspaceId ?: return
        // A page already held — from the cache, from the drawer, or from the
        // screen itself. Refetching here would be the second request the
        // shared-ViewModel decision exists to avoid.
        if (state.projectChats.containsKey(itemId)) return
        if (state.isLoadingMoreProjectChats.contains(itemId)) return

        val generation = (projectGenerations[itemId] ?: 0) + 1
        projectGenerations[itemId] = generation
        projectCursors.remove(itemId)

        moreProjectChatsJobs.remove(itemId)?.cancel()
        moreProjectChatsJobs[itemId] = viewModelScope.launch {
            when (
                val result = withContext(ioDispatcher) {
                    projectsClient.loadProjectChats(workspaceId, itemId)
                }
            ) {
                is RecentsResult.SignedOut -> expireSession()

                is RecentsResult.Unavailable -> _uiState.update { current ->
                    current.copy(
                        isLoadingMoreProjectChats = current.isLoadingMoreProjectChats - itemId,
                    )
                }

                is RecentsResult.Loaded -> {
                    val page = result.value
                    if (projectGenerations[itemId] != generation) return@launch
                    if (_uiState.value.selectedWorkspaceId != workspaceId) return@launch

                    _uiState.update { current ->
                        current.copy(
                            projectChats = current.projectChats + (itemId to page),
                            isLoadingMoreProjectChats = current.isLoadingMoreProjectChats - itemId,
                        )
                    }
                    // Set only after the state applied, so a scroll can never
                    // fire against a cursor the list does not match.
                    projectCursors[itemId] = page.nextCursor.orEmpty()

                    if (page.chats.isNotEmpty()) {
                        val id = userId
                        if (id != null) {
                            withContext(ioDispatcher) {
                                projectsCache.writeProjectChats(
                                    id,
                                    workspaceId,
                                    itemId,
                                    page.chats,
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * Append the next page of one project's chats. Called when the reader
     * reaches the bottom — of the project-chats screen, or of a project unfolded
     * inline in the drawer.
     *
     * A no-op wherever asking again would be wrong, for the reason
     * [loadMoreChats] gives: the scroll fires on *position*, and a short page
     * that does not fill the viewport leaves the trigger armed on every
     * recomposition.
     */
    fun loadMoreProjectChats(itemId: String) {
        val state = _uiState.value
        if (!state.canLoadMoreProjectChats(itemId)) return
        val workspaceId = state.selectedWorkspaceId ?: return
        val cursor = projectCursors[itemId]?.takeIf { it.isNotBlank() } ?: return

        val generation = projectGenerations[itemId] ?: return

        moreProjectChatsJobs.remove(itemId)?.cancel()
        moreProjectChatsJobs[itemId] = viewModelScope.launch {
            _uiState.update { it.copy(isLoadingMoreProjectChats = it.isLoadingMoreProjectChats + itemId) }

            val result = withContext(ioDispatcher) {
                projectsClient.loadProjectChats(
                    workspaceId = workspaceId,
                    itemId = itemId,
                    cursor = cursor,
                )
            }
            if (projectGenerations[itemId] != generation) return@launch
            if (_uiState.value.selectedWorkspaceId != workspaceId) return@launch

            when (result) {
                is RecentsResult.SignedOut -> {
                    _uiState.update { it.copy(isLoadingMoreProjectChats = it.isLoadingMoreProjectChats - itemId) }
                    expireSession()
                }

                is RecentsResult.Unavailable -> _uiState.update { current ->
                    // Keep the rows we already have and keep `hasMore` true, so
                    // scrolling again retries the same page. Blanking the list,
                    // or silently ending it, would both be worse than a page
                    // that did not arrive.
                    current.copy(isLoadingMoreProjectChats = current.isLoadingMoreProjectChats - itemId)
                }

                is RecentsResult.Loaded -> {
                    val page = result.value
                    val known = _uiState.value.projectChats[itemId]?.chats.orEmpty()
                    val fresh = page.chats.filterNot { chat -> known.any { it.id == chat.id } }

                    _uiState.update { current ->
                        val existing = current.projectChats[itemId]
                        current.copy(
                            projectChats = current.projectChats + (
                                itemId to ProjectChatsPage(
                                    chats = ProjectsApi.mergeProjectChatsById(
                                        existing?.chats.orEmpty(),
                                        page.chats,
                                    ),
                                    // A page that added nothing new means the
                                    // cursor is not advancing. Continuing would
                                    // loop on the same page forever.
                                    hasMore = page.hasMore && fresh.isNotEmpty(),
                                    nextCursor = page.nextCursor,
                                )
                                ),
                            isLoadingMoreProjectChats = current.isLoadingMoreProjectChats - itemId,
                        )
                    }

                    // An empty page must not advance the cursor: holding the old
                    // one is what lets a retry re-request the same window.
                    if (fresh.isNotEmpty()) {
                        projectCursors[itemId] = page.nextCursor.orEmpty()
                    } else {
                        projectCursors.remove(itemId)
                    }

                    if (page.chats.isNotEmpty()) {
                        val id = userId
                        if (id != null) {
                            withContext(ioDispatcher) {
                                projectsCache.writeProjectChats(
                                    id,
                                    workspaceId,
                                    itemId,
                                    _uiState.value.projectChats[itemId]?.chats.orEmpty(),
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Creating a chat / task under a project ─────────────────────────────

    /**
     * Create a chat or a memory under [itemId], and paint the result.
     *
     * The mobile twin of the desktop's `handleAddTaskPick` (`Sidebar.vue:920`):
     * a standard chat is created and then opened, a memory is created and then
     * *not* opened, because a memory has no session to open.
     *
     * Three things happen on success, and all three are load-bearing:
     *
     *  1. The new row is written into [HomeUiState.projectChats] for that
     *     project, at the **front**. The list is ordered `updated_at desc`, and
     *     a row created a second ago belongs above rows touched yesterday; a
     *     refetch to discover the row this call already returned would be a
     *     second request whose result could arrive in either order.
     *  2. The project is forced open, so the row the reader just made is
     *     visible. Creating from a collapsed project and having to expand it to
     *     find the result is the one outcome that reads as "it didn't work".
     *  3. The write-through cache gets the merged list, for the same reason
     *     [loadMoreChats] writes merged rather than the page.
     *
     * A memory's name is validated here, before the POST, so the reader gets
     * the rule on screen rather than a `400` rendered as a generic failure. The
     * server validates again regardless.
     */
    fun createTask(itemId: String, request: CreateTaskRequest) {
        val state = _uiState.value
        val workspaceId = state.selectedWorkspaceId ?: return
        // One create at a time. A second press on a `+` that is already working
        // is a double-tap, and a double-tap on "create" is how two "New Chat"
        // rows get made from one intent.
        if (state.creatingTaskInProjectId != null) return

        if (request is CreateTaskRequest.Memory && !isValidMemoryName(request.name)) {
            _uiState.update { it.copy(taskCreateError = INVALID_MEMORY_NAME_MESSAGE) }
            return
        }
        if (request is CreateTaskRequest.Memory && request.content.isBlank()) {
            _uiState.update { it.copy(taskCreateError = EMPTY_MEMORY_CONTENT_MESSAGE) }
            return
        }

        _uiState.update { it.copy(creatingTaskInProjectId = itemId, taskCreateError = null) }

        // Capture the generation now. A projects reload under this call
        // invalidates the page this result would merge into, and merging a
        // freshly created row into a list the server has since replaced is how a
        // deleted project's chat survives on screen.
        val generation = (projectGenerations[itemId] ?: 0) + 1
        projectGenerations[itemId] = generation

        viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                projectsClient.createTask(workspaceId, itemId, request)
            }
            if (projectGenerations[itemId] != generation) return@launch
            if (_uiState.value.selectedWorkspaceId != workspaceId) return@launch

            when (result) {
                is RecentsResult.SignedOut -> {
                    _uiState.update { it.copy(creatingTaskInProjectId = null) }
                    expireSession()
                }

                is RecentsResult.Unavailable -> _uiState.update {
                    // The rows survive: a failed create changed nothing.
                    it.copy(creatingTaskInProjectId = null, taskCreateError = result.message)
                }

                is RecentsResult.Loaded -> {
                    val created = result.value
                    _uiState.update { current ->
                        val existing = current.projectChats[itemId]
                        current.copy(
                            creatingTaskInProjectId = null,
                            taskCreateError = null,
                            // A project with no page yet — a `+` on a project the
                            // reader never expanded, or one whose fetch failed —
                            // gets a first page holding just the new row rather
                            // than staying absent, which would make the create
                            // look like it vanished.
                            projectChats = current.projectChats + (
                                itemId to ProjectChatsPage(
                                    chats = listOf(created) +
                                        existing?.chats.orEmpty().filterNot { it.id == created.id },
                                    // Unchanged: this says nothing about whether
                                    // more pages exist, and the create told us
                                    // nothing about a cursor.
                                    hasMore = existing?.hasMore ?: false,
                                    nextCursor = existing?.nextCursor,
                                )
                                ),
                            expandedProjectIds = current.expandedProjectIds + itemId,
                        )
                    }

                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) {
                            projectsCache.writeProjectChats(
                                id,
                                workspaceId,
                                itemId,
                                _uiState.value.projectChats[itemId]?.chats.orEmpty(),
                            )
                        }
                    }

                    // Only a chat is a destination. A memory is a file on disk
                    // with nothing to open, and navigating to its id would land
                    // on a transcript route with no session behind it.
                    if (request.opensChat) {
                        _createdChat.tryEmit(created.id)
                    }
                }
            }
        }
    }

    /**
     * Clear the last create's complaint, and only that.
     *
     * Deliberately not a `refresh()`: a reader who mistyped a memory filename
     * has a form to go back to, and making them re-fetch their projects to
     * un-stick the screen would be punishment for a typo.
     */
    fun dismissTaskCreateError() {
        _uiState.update { it.copy(taskCreateError = null) }
    }

    /** Drop every project, expanded or paged, on sign-out. */
    private fun clearProjects() {
        projectsJob?.cancel()
        moreProjectChatsJobs.values.forEach { it.cancel() }
        moreProjectChatsJobs.clear()
        projectCursors.clear()
        projectGenerations.clear()
        projectsGeneration++
        projectsCache.clear()
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
        clearProjects()
        // The saved position goes with the rows. Keeping it would be the same
        // leak with a smaller payload: the next account to sign in on this device
        // would open straight into the previous one's chat.
        resumeWorkspaceSeed = null
        cache.clear()
        positionStore.clear()
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
        /**
         * [positionStore] is passed in rather than built here so the caller
         * controls its lifetime: `MainActivity` holds one instance for the whole
         * process, and the nav graph reads the same one to decide what to resume.
         * Two instances of a store over one preference file would be two caches
         * disagreeing about the same two keys.
         */
        fun factory(
            application: Application,
            positionStore: LastPositionStore,
        ): ViewModelProvider.Factory = viewModelFactory {
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
                    // Recorded like the recents calls, so the inspector shows
                    // the exact bytes the drawer sent for the project endpoints
                    // too — for free, by construction.
                    projectsClient = ProjectsClient(
                        sessionStore = SessionCookieStore(application),
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport(AuthConfig.BASE_URL),
                        ),
                    ),
                    projectsCache = RoomProjectsCache(application),
                    positionStore = positionStore,
                )
            }
        }
    }
}

/**
 * Which workspace the drawer should show, in the one precedence that decides.
 *
 * Three candidates, in order, and the order is the whole point:
 *
 * 1. **The current selection**, so a pull-to-refresh or a background revalidate
 *    does not move the user out of the workspace they are reading. This is also
 *    what a workspace the user just tapped looks like, which is why a tap is
 *    never overridden by the seed below.
 * 2. **The saved position**, the workspace the previous run ended on. It only
 *    applies when the current selection is not in the list at all — the first
 *    launch, before anything has been chosen — and only if the workspace is
 *    *still there*. A workspace deleted on the server fails the second test and
 *    falls through, so a stale id cannot put the user in a room that is not
 *    there any more.
 * 3. **The first workspace**, so the drawer always has a target once any
 *    workspace exists. The desktop's `activeWorkspace` getter has the same
 *    fallback chain, and reaches it through the same question.
 *
 * Top level and free of Compose so the precedence can be asserted directly,
 * rather than inferred from which workspace a rendered drawer happened to show.
 */
internal fun selectWorkspaceId(
    workspaces: List<WorkspaceOption>,
    currentSelection: String?,
    resumeSeed: String?,
): String? = workspaces.firstOrNull { it.id == currentSelection }?.id
    ?: workspaces.firstOrNull { it.id == resumeSeed }?.id
    ?: workspaces.firstOrNull()?.id

/**
 * The two messages a form can earn *before* the request leaves.
 *
 * Stated here rather than in the composable so the same wording is asserted in
 * a test that does not need a UI, and so the validation the ViewModel performs
 * and the sentence it reports are the same object rather than two descriptions
 * of each other.
 */
private const val INVALID_MEMORY_NAME_MESSAGE =
    "The file name must end in .md, and cannot contain /, \\ or .."
private const val EMPTY_MEMORY_CONTENT_MESSAGE = "A memory needs some content."
