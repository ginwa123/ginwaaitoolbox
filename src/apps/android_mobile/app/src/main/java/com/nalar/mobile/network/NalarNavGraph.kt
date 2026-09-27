package com.nalar.mobile.network

import com.nalar.mobile.projects.CreateTaskHost
import com.nalar.mobile.projects.CreateTaskRequest
import com.nalar.mobile.projects.ProjectChatsScreen
import com.nalar.mobile.projects.ProjectSummary
import com.nalar.mobile.projects.ProjectsActions
import com.nalar.mobile.projects.ProjectsState
import com.nalar.mobile.projects.rememberCreateTaskController
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraph
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import com.nalar.mobile.auth.AuthRestoringScreen
import com.nalar.mobile.auth.AuthUiState
import com.nalar.mobile.auth.SessionPhase
import com.nalar.mobile.chat.ChatScreen
import com.nalar.mobile.chat.ChatUiState
import com.nalar.mobile.chat.QuestionAnswer
import com.nalar.mobile.login.LoginCredentials
import com.nalar.mobile.login.LoginScreen
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.HomeUiState
import com.nalar.mobile.shell.MobileHomeScreen
import com.nalar.mobile.shell.RecentsDrawerContent
import com.nalar.mobile.shell.chatDrawerSelectedChatId
import com.nalar.mobile.storage.LastPositionStore
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Every view in the app is a route, so each one survives a process restart and
 * `adb shell am start -a android.intent.action.VIEW -d nalar://…` lands on it
 * directly — the Android equivalent of opening DevTools, and of sharing a link
 * to a specific chat.
 */
object NalarRoutes {
    const val SHELL = "app"
    const val CHAT = "chat/{sessionId}"
    const val ARG_SESSION_ID = "sessionId"
    const val NETWORK = "network"
    const val RECORD_DETAIL = "network/record/{recordId}"
    const val ARG_RECORD_ID = "recordId"

    /**
     * One project's chats, full-screen.
     *
     * Two ids, not one, and that is forced by the wire rather than chosen: every
     * item endpoint in the backend is nested under
     * `/api/workspaces/:workspace_id/items/…` — including the read one — so
     * there is no endpoint anywhere that resolves a project from its id alone.
     * A short `nalar://project/{itemId}` would arrive on a *cold process* with
     * no `HomeViewModel` state to resolve the workspace from, and the only way
     * to learn it would be the every-workspace-every-task fetch. `chat` gets
     * away with one id because
     * `GET /api/llm/session/{id}/messages?limit=1` genuinely needs nothing but
     * the session id. One id where the wire allows one, two where it does not.
     *
     * Registered as a *sibling* of [CHAT], not nested under it: a project is
     * not a chat, and nesting would make Back from one mean "pop the other".
     */
    const val PROJECT = "project/{workspaceId}/{itemId}"
    const val ARG_WORKSPACE_ID = "workspaceId"
    const val ARG_ITEM_ID = "itemId"

    fun chat(sessionId: String): String = "chat/${UriEncoding.encode(sessionId)}"

    fun recordDetail(recordId: Long): String = "network/record/$recordId"

    fun project(workspaceId: String, itemId: String): String =
        "project/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}"
}

/**
 * What one back action should do.
 *
 * The distinction is not a nicety. `NavController.popBackStack()` with no
 * argument is **inclusive** — it pops the current destination *and* stops at the
 * graph, and `dispatchOnDestinationChanged()` then drops that graph from the top
 * of the queue as well. At a one-destination depth that single call therefore
 * leaves the controller with no destination at all, reports `false` while doing
 * it, and `NavHost` renders *nothing* for an empty back stack: no destination,
 * no screen, nothing to press, just the theme's window background. Checking the
 * return value is not a defence, because the damage is already done by the time
 * the call returns.
 *
 * The system Back button cannot cause this: `updateOnBackPressedCallbackEnabled`
 * keeps the callback disabled while `destinationCountOnBackStack <= 1`. Only an
 * app-initiated pop reaches that depth, which is what the back arrows here are.
 */
internal enum class BackAction {
    /** A real destination sits under this one, so pop back onto it. */
    PopPrevious,

    /**
     * Nothing but the graph sits underneath — a `popUpTo(SHELL)` navigation, or a
     * deep link that never pushed the shell. Rebuild onto the shell rather than
     * leave `NavHost` with nothing to draw.
     */
    ReturnToShell,
}

/**
 * [hasDestinationBelow] is "is there a non-graph entry under the current one",
 * which is false both on the shell and on a leaf with no shell beneath it. The
 * two want different answers, so the caller has to tell them apart; see
 * [goBackToPreviousOrShell].
 */
internal fun backActionFor(hasDestinationBelow: Boolean): BackAction =
    if (hasDestinationBelow) BackAction.PopPrevious else BackAction.ReturnToShell

/**
 * One back action, for an app with a single activity.
 *
 * Top level and free of Compose so it can be driven against a real
 * `NavController` on a device: the whole defect is a property of the controller,
 * not of how the screens are drawn.
 */
internal fun NavHostController.goBackToPreviousOrShell() {
    val below = previousBackStackEntry?.destination
    when (backActionFor(below != null && below !is NavGraph)) {
        BackAction.PopPrevious -> popBackStack()

        // Non-inclusive: the shell is the one entry that must survive. When it is
        // not on the stack the library logs and skips the pop, and the shell is
        // pushed on top — the user lands on the home screen either way instead of
        // on nothing.
        BackAction.ReturnToShell -> navigate(NalarRoutes.SHELL) {
            popUpTo(NalarRoutes.SHELL) { inclusive = false }
            launchSingleTop = true
        }
    }
}

/**
 * Minimal percent-encoding for a path segment.
 *
 * Session ids are server-generated (`sess_<ts>_<hex>`) and contain nothing that
 * needs escaping, but a deep link is attacker-shaped input and `navDeepLink`
 * matches patterns literally — an unescaped `/` or `?` in a hand-written
 * `nalar://chat/…` URI would otherwise split the path and navigate somewhere
 * unintended.
 */
internal object UriEncoding {
    fun encode(value: String): String = buildString {
        value.toByteArray(Charsets.UTF_8).forEach { byte ->
            val code = byte.toInt() and 0xFF
            val isUnreserved = code in 'a'.code..'z'.code ||
                code in 'A'.code..'Z'.code ||
                code in '0'.code..'9'.code ||
                code == '-'.code || code == '_'.code || code == '.'.code || code == '~'.code
            if (isUnreserved) {
                append(code.toChar())
            } else {
                append('%').append(HEX[(code shr 4) and 0xF]).append(HEX[code and 0xF])
            }
        }
    }

    private const val HEX = "0123456789ABCDEF"
}

@Composable
fun NalarNavGraph(
    authState: AuthUiState,
    onSignIn: (String, String) -> Unit,
    onRetrySession: () -> Unit,
    onUseAnotherAccount: () -> Unit,
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
    homeState: HomeUiState,
    /**
     * The chat transcript, *read on demand* rather than handed in as a value.
     *
     * A `ChatUiState` parameter is a `StateFlow` sample taken at the top of
     * the tree, and every emission of it — every stream delta, every page, every
     * keystroke in the composer's draft — then recomposes the whole
     * `NalarNavGraph`: the drawer, the `NavHost` builder, and every composed
     * destination. The transcript is the only thing that changed, and it is the
     * one thing that is already virtualized.
     *
     * A lambda reads the flow *inside* the chat destination, so only that
     * composable observes it. It is a provider rather than a `StateFlow` so the
     * graph still has no opinion about where the value comes from, and so a
     * test can hand over a fixed state the same way it always did.
     */
    chatState: () -> ChatUiState,
    /**
     * The position the last run left behind. Read once per launch and never
     * written from here — a persisted position that the app edits as it resumes
     * is a position it can no longer be sure about.
     */
    positionStore: LastPositionStore,
    onSelectWorkspace: (String) -> Unit,
    onSelectChat: (String) -> Unit,
    onLoadMoreChats: () -> Unit,
    /**
     * The four project actions the drawer and the project screen share.
     *
     * Passed in rather than reached for, so a graph rendered with inert data in
     * a test needs no `HomeViewModel` behind it.
     */
    onToggleProjectsSection: () -> Unit = {},
    onToggleProjectExpanded: (String) -> Unit = {},
    onEnsureProjectChatsLoaded: (String) -> Unit = {},
    onLoadMoreProjectChats: (String) -> Unit = {},
    onRetryProjects: () -> Unit = {},
    /**
     * Create a chat or a memory under a project.
     *
     * A three-argument callback rather than the whole flow, because the graph
     * owns navigation and a create's *result* is a navigation; the sheet's own
     * state stays with the UI, and this is the one thing it needs from the
     * ViewModel.
     */
    onCreateTask: (String, String, CreateTaskRequest) -> Unit = { _, _, _ -> },
    /**
     * Session ids of chats that were just created, to open.
     *
     * A flow, not a callback into the graph, because the create finishes on a
     * coroutine the graph does not own and the navigation has to happen after
     * the row is painted. Collected once here so the chat opens from wherever
     * the flow was started — the drawer, or the project screen.
     */
    createdChats: Flow<String>? = null,
    /** Clear the last create's complaint. */
    onDismissTaskCreateError: () -> Unit = {},
    /**
     * Fold the sidebar's Recents section away, or unfold it.
     *
     * The chat route's drawer and the shell's drawer are one drawer, so this
     * reaches both — a fold made in one and forgotten in the other is a drawer
     * that springs open on the reader every time they switch screens.
     */
    onToggleRecentsSection: () -> Unit = {},
    onRetryHome: () -> Unit,
    onOpenSession: (String) -> Unit,
    onChatDraftChanged: (String) -> Unit,
    onSendChatMessage: () -> Unit,
    onStopChatRun: () -> Unit,
    onLoadOlderChatMessages: () -> Unit,
    onDismissChatError: () -> Unit,
    onAnswerChatQuestion: (QuestionAnswer) -> Unit,
    /**
     * Sign-out from the sidebar. A separate parameter from
     * [onUseAnotherAccount] only because the two start from different screens —
     * the caller is expected to point both at the same action.
     */
    onLogout: () -> Unit = {},
    /**
     * Session ids with a live worker, for the two places that can say so: the
     * sidebar row and the chat header.
     *
     * One hoisted set for both because they are on different routes and would
     * otherwise each need their own copy of the same fact. Defaulted so a graph
     * rendered with inert data needs no worker behind it.
     */
    runningSessionIds: Set<String> = emptySet(),
) {
    val coroutineScope = rememberCoroutineScope()
    val openInspector: () -> Unit = { navController.navigate(NalarRoutes.NETWORK) }

    // The one create flow in the app, built here because the graph is the only
    // thing both entry points can reach: the drawer's `+` and the project
    // screen's `+`. Two controllers would be two pickers that agree today and
    // not tomorrow.
    val createTask = rememberCreateTaskController(onCreateTask)

    // A `nalar://` link or a `popUpTo(SHELL)` navigation can leave a leaf as the
    // only destination on the back stack. The back arrow on those screens used to
    // call the inclusive `popBackStack()`, which emptied the back stack and left
    // `NavHost` drawing nothing at all. See [BackAction]. The chat route has no
    // back arrow and no "All chats" row — its way out is the system Back button,
    // which the chat destination claims with a [BackHandler] for exactly that
    // reason.
    val goBack: () -> Unit = { navController.goBackToPreviousOrShell() }

    // Built once, here, and handed to both drawers and the project screen.
    //
    // The holder exists so the wiring is a single expression the reader can
    // check against the four actions above: three that stay in the drawer
    // (reshape the list in place) and one that leaves it (a destination). The
    // split is the whole drawer contract, and naming the actions in one place
    // is what keeps a fourth caller from being added without a decision about
    // which side of that line it falls on.
    val projectActions = ProjectsActions(
        onToggleSection = onToggleProjectsSection,
        onToggleItem = onToggleProjectExpanded,
        onOpenAllChats = { workspaceId, itemId ->
            navController.navigate(NalarRoutes.project(workspaceId, itemId))
        },
        onRetry = onRetryProjects,
        onCreateTask = createTask::start,
    )

    // Rebuilt from the state on every emission rather than held, so it cannot
    // fall one frame behind the rows it describes. It is a value class over
    // immutable data, so Compose treats an unchanged list as unchanged and skips
    // recomposing every row below it.
    val projectState = remember(homeState) {
        ProjectsState(
            expanded = homeState.isProjectsExpanded,
            items = homeState.projects,
            expandedItemIds = homeState.expandedProjectIds,
            chats = homeState.projectChats,
            isLoading = homeState.isLoadingProjects,
            errorMessage = homeState.projectsError,
            creatingTaskItemId = homeState.creatingTaskInProjectId,
        )
    }

    // A chat this app just created is opened here, and nowhere else.
    //
    // Collected at the graph rather than inside a destination because the create
    // can be started from the drawer on the shell and the navigation has to
    // work from wherever the reader happens to be — including from inside the
    // project screen, where a plain `navigate` would leave the project list
    // underneath the new chat and make Back return to a screen the reader has
    // already finished with.
    LaunchedEffect(createdChats) {
        createdChats?.collect { sessionId ->
            if (sessionId.isBlank()) return@collect
            onSelectChat(sessionId)
            onOpenSession(sessionId)
            navController.navigate(NalarRoutes.chat(sessionId)) {
                // Replace the shell rather than stacking on it: a chat the
                // reader just made is where they want to be, and Back from
                // there should leave the app's list rather than walk back
                // through a chat they never opened.
                popUpTo(NalarRoutes.SHELL) { inclusive = false }
                launchSingleTop = true
            }
        }
    }

    // A chat picked from the chat route's drawer *replaces* the one on screen
    // rather than stacking on it. Pushing would make system Back walk back
    // through every chat opened this session, and the reader is switching
    // between chats, not moving through a history of them.
    //
    // On a deep-linked chat the shell is not underneath, so the popUpTo finds
    // nothing and the new chat lands on top of the old one. Back then returns
    // to the chat that was open, which is a route onwards rather than a dead
    // end — and the system Back button still reaches the shell.
    val switchChat: (String) -> Unit = { chatId ->
        onOpenSession(chatId)
        navController.navigate(NalarRoutes.chat(chatId)) {
            popUpTo(NalarRoutes.SHELL) { inclusive = false }
            launchSingleTop = true
        }
    }

    // Signing out is app-wide, but only the shell reads the auth phase — the
    // chat route would happily keep painting a transcript the user can no
    // longer act on. Coming back to the shell is what lets the login screen
    // replace the app instead of that.
    val signOut: () -> Unit = {
        onLogout()
        if (navController.currentDestination?.route != NalarRoutes.SHELL) {
            goBack()
        }
    }

    // `NavHost` emits nothing at all when the controller has no destination, and
    // the window then shows only the theme's background. This guard is not a
    // substitute for [goBack] — it is what turns any future way into that state
    // into one tap instead of a dead window.
    val visibleDestinations by navController.visibleEntries.collectAsState()
    val currentBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = currentBackStackEntry?.destination?.route

    // The launch's own state, hoisted here because two different things need it:
    // the effect below that resumes, and the gate that decides whether any of
    // this is on screen yet. It is state *over time* — read on IO, answered
    // when a list lands, confirmed when a transcript has been scrolled — and
    // the third of those is reported by a composable several frames away.
    //
    // `plan` is null for the first frames of a launch. That is its own state,
    // neither decided nor undecided: the read is on IO, and "not read yet" is
    // not "there is nothing to resume".
    var plan by remember(authState.userId) { mutableStateOf<ResumePlan?>(null) }
    // Re-read when the account changes, not on every recomposition: the store is
    // keyed by account, and a plan built for the previous one would resume the
    // previous one's chat.
    LaunchedEffect(authState.userId) {
        // Off the main thread: this is a launch path, and the first screen is not
        // up yet, so there is nothing to drop a frame for.
        plan = withContext(Dispatchers.IO) {
            ResumePlan(positionStore.read(authState.userId))
        }
    }

    // Whether the resume has answered, as something Compose can see.
    //
    // **`ResumePlan` is not observable**, and that is the whole reason this is a
    // separate piece of state rather than a read of `plan.isDecided` during
    // composition. The plan latches its answer from inside the effect below —
    // mutating a plain object, which invalidates nothing. The gate would go on
    // rendering the value it last composed, so an answered "there is nothing to
    // open" would leave it up for ever, on every launch that has no chat to
    // resume. So the answer is copied into state every time the plan is asked.
    var resumeDecided by remember { mutableStateOf(false) }

    // The chat this launch navigated to, if it navigated to one. Set once, by
    // the resume, and the difference between "this launch still has a screen to
    // build" and "this launch is the shell".
    var resumedSessionId by remember { mutableStateOf<String?>(null) }

    // The resumed transcript has been put where the reader left it.
    //
    // **One-way, and the latch is the point.** `ChatView` reports it for the
    // session it is showing, and a reader who has already landed in a chat and
    // switched to another one would otherwise put a launch gate back over a
    // screen they are using — a worse bug than the drift it was added to stop.
    // A launch reveals; it does not re-close.
    var transcriptSettled by remember { mutableStateOf(false) }
    val onTranscriptSettled: (String?) -> Unit = { sessionId ->
        // Matched, not just recorded: a report about the chat that was open
        // before the resume — or about no chat at all, which is what a stale
        // state paints on the route's first frame — must not pass for the
        // resumed one settling.
        if (sessionId != null && sessionId == resumedSessionId) {
            transcriptSettled = true
        }
    }

    ResumeLastPosition(
        authState = authState,
        homeState = homeState,
        navController = navController,
        // Read from the hoisted destination, not from
        // `navController.currentDestination` inside the effect. Those are the
        // same value a frame later, but the *first* run of that effect happens
        // before `NavHost` has set the graph, so the current destination is
        // still null and `sessionToResume` — which only resumes on the shell —
        // answers "not on the shell" and the resume is skipped for good. Nothing
        // else in the key list changes afterwards to bring it back, so the app
        // sat on the shell (or, once there was a gate, behind it) for ever.
        currentRoute = currentRoute,
        plan = plan,
        onSelectChat = onSelectChat,
        onOpenSession = onOpenSession,
        onResumed = { sessionId -> resumedSessionId = sessionId },
        // Every consultation, answered or not — see [resumeDecided].
        onPlanConsulted = { resumeDecided = it },
    )

    // Auth answering `/api/auth/me` is not the app being ready. This is the
    // difference, and the whole reason the shell used to be on screen for three
    // seconds before the chat the reader had left appeared over it.
    val gateIsUp = launchGateIsUp(
        authPhase = authState.phase,
        currentRoute = currentRoute,
        resumeDecided = resumeDecided,
        resumedSessionId = resumedSessionId,
        transcriptSettled = transcriptSettled,
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(NalarBackground),
    ) {
    // Inside the `Box` rather than beside it, so the sheet is drawn over the
    // `NavHost` and not behind whatever the current destination paints. It
    // composes nothing while the flow is idle.
    CreateTaskHost(
        controller = createTask,
        isSubmitting = homeState.creatingTaskInProjectId != null,
        errorMessage = homeState.taskCreateError,
    )

    NavHost(
        navController = navController,
        startDestination = NalarRoutes.SHELL,
        modifier = Modifier.fillMaxSize(),
    ) {
        composable(NalarRoutes.SHELL) {
            when (authState.phase) {
                SessionPhase.Restoring -> AuthRestoringScreen()

                // `onRetrySession` bypasses the /me cache: the user pressed "Try
                // again" to re-check, so it has to reach the network.
                SessionPhase.NeedsRetry -> AuthRestoringScreen(
                    errorMessage = authState.errorMessage,
                    onRetry = onRetrySession,
                    onUseAnotherAccount = onUseAnotherAccount,
                )

                SessionPhase.NeedsLogin -> LoginScreen(
                    authError = authState.errorMessage,
                    isAuthenticating = authState.isAuthenticating,
                    onSignIn = { credentials: LoginCredentials ->
                        onSignIn(credentials.email, credentials.password)
                    },
                    onOpenNetworkInspector = openInspector,
                )

                SessionPhase.Authenticated -> MobileHomeScreen(
                    workspaces = homeState.workspaces,
                    chats = homeState.chats,
                    initialWorkspaceId = homeState.selectedWorkspaceId,
                    initialChatId = homeState.selectedChatId,
                    onWorkspaceSelected = onSelectWorkspace,
                    onChatSelected = onSelectChat,
                    onOpenChat = { sessionId ->
                        // Open the session before navigating: the route stays
                        // on the back stack, so returning to it must not show
                        // an empty transcript waiting on a load that never ran.
                        onOpenSession(sessionId)
                        navController.navigate(NalarRoutes.chat(sessionId))
                    },
                    onOpenNetworkInspector = openInspector,
                    isLoading = homeState.isLoading,
                    errorMessage = homeState.errorMessage,
                    onRetry = onRetryHome,
                    isLoadingMoreChats = homeState.isLoadingMoreChats,
                    hasMoreChats = homeState.hasMoreChats,
                    onLoadMoreChats = onLoadMoreChats,
                    runningSessionIds = runningSessionIds,
                    isAuthEnabled = authState.isAuthEnabled,
                    signedInEmail = authState.userEmail,
                    isLoggingOut = authState.isLoggingOut,
                    onLogout = signOut,
                    // The shell's drawer is the same drawer the chat route's
                    // hamburger opens, so it gets the same sections and the same
                    // fold state. It used to get neither, which is why the
                    // Projects section appeared only once the reader had already
                    // opened a chat.
                    projects = projectState,
                    projectActions = projectActions,
                    recentsExpanded = homeState.isRecentsExpanded,
                    onToggleRecentsSection = onToggleRecentsSection,
                )
            }
        }

        composable(
            route = NalarRoutes.CHAT,
            arguments = listOf(
                navArgument(NalarRoutes.ARG_SESSION_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(
                navDeepLink { uriPattern = "nalar://chat/{sessionId}" },
            ),
        ) { backStackEntry ->
            val sessionId = backStackEntry.arguments?.getString(NalarRoutes.ARG_SESSION_ID).orEmpty()
            val chatState = chatState()
            // The id in the route is the truth. When it disagrees with what is
            // loaded — a deep link, or a session that failed to open — the route
            // wins, or the screen would show the previous chat under this one's
            // title.
            // Opening a session is a side effect, so it belongs in an effect —
            // running it in the composition body would re-open on every
            // recomposition and on every Back-and-forth through this route.
            LaunchedEffect(sessionId) {
                if (sessionId.isNotBlank() && chatState.sessionId != sessionId) {
                    onOpenSession(sessionId)
                }
            }

            // The chat's only way out, and the reason it is not a dead end.
            //
            // Without this the route has no in-app navigation at all — the top
            // bar leads with a hamburger and the drawer carries no "all chats"
            // row — and `updateOnBackPressedCallbackEnabled` leaves the system's
            // callback *disabled* while `destinationCountOnBackStack <= 1`. A
            // `nalar://chat/…` link lands exactly there, so Back would quit the
            // app from a screen the reader never navigated into and cannot
            // otherwise leave.
            //
            // Registered here rather than in `ChatScreen` because this is
            // navigation and the graph owns navigation. It is also scoped to the
            // destination, so the shell behind it keeps the default
            // "Back leaves the app" behaviour.
            //
            // `ModalNavigationDrawer` registers its own handler deeper in the
            // tree, and the dispatcher runs the most-recently-added enabled
            // callback first — so an open drawer still closes on Back and only
            // falls through to here once it is shut.
            BackHandler { goBack() }

            ChatScreen(
                state = chatState,
                chatTitle = chatTitleFor(sessionId, homeState.chats),
                // The only signal that the launch has somewhere to show. The
                // graph holds a gate over the whole route until the transcript
                // has been scrolled to where the reader left it — see
                // [launchGateIsUp] — and this is the report that lifts it.
                onTranscriptSettled = onTranscriptSettled,
                // The route's id, not `chatState.sessionId`: a deep link that
                // has not finished opening yet still has to report the run it
                // is about to show.
                isRunning = sessionId in runningSessionIds,
                onDraftChanged = onChatDraftChanged,
                onSend = onSendChatMessage,
                onStop = onStopChatRun,
                onLoadOlder = onLoadOlderChatMessages,
                onDismissError = onDismissChatError,
                onAnswer = onAnswerChatQuestion,
                // The hamburger opens the same sidebar the shell shows — a
                // workspace's chats, a workspace picker and sign-out — because a
                // reader in a chat is far more often on their way to a
                // *different* chat than on their way back to the list.
                //
                // `onOpenChat` is the drawer's own signal that a chat was
                // picked, so closing it hangs off that rather than off the
                // row's click: the sidebar fires both, and wiring only one
                // leaves the sheet open on top of the transcript the reader
                // just asked for.
                drawerContent = { dismissDrawer ->
                    RecentsDrawerContent(
                        workspaces = homeState.workspaces,
                        chats = homeState.chats,
                        selectedWorkspaceId = homeState.selectedWorkspaceId,
                        // The route's session, not the list's memory: a deep link
                        // opens a chat the sidebar never marked as selected.
                        selectedChatId = chatDrawerSelectedChatId(sessionId, homeState.selectedChatId),
                        onWorkspaceSelected = onSelectWorkspace,
                        onChatSelected = { chatId ->
                            onSelectChat(chatId)
                            switchChat(chatId)
                        },
                        onOpenChat = dismissDrawer,
                        isLoading = homeState.isLoading,
                        errorMessage = homeState.errorMessage,
                        onRetry = onRetryHome,
                        isLoadingMore = homeState.isLoadingMoreChats,
                        hasMoreChats = homeState.hasMoreChats,
                        onLoadMore = onLoadMoreChats,
                        // The same set the shell's drawer shows it in: a chat
                        // busy in the background is busy in both copies of the
                        // list, and this is the one the reader is looking at.
                        runningSessionIds = runningSessionIds,
                        isAuthEnabled = authState.isAuthEnabled,
                        signedInEmail = authState.userEmail,
                        isLoggingOut = authState.isLoggingOut,
                        onLogout = signOut,
                        projects = projectState,
                        projectActions = projectActions,
                        // Straight off `homeState` rather than a local: the
                        // reader folded these sections in the shell's drawer, and
                        // a copy held here would forget it the moment they opened
                        // a chat.
                        recentsExpanded = homeState.isRecentsExpanded,
                        onToggleRecentsSection = onToggleRecentsSection,
                    )
                },
            )
        }

        composable(
            route = NalarRoutes.PROJECT,
            arguments = listOf(
                navArgument(NalarRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
                navArgument(NalarRoutes.ARG_ITEM_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(
                navDeepLink { uriPattern = "nalar://project/{workspaceId}/{itemId}" },
            ),
        ) { backStackEntry ->
            val itemId = backStackEntry.arguments?.getString(NalarRoutes.ARG_ITEM_ID).orEmpty()

            // Same rule as the chat route, same reason: this route sits on the
            // back stack, so returning to it must not find a project whose
            // chats were never asked for. An effect, not the composition body —
            // in the body it would re-fetch on every recomposition.
            LaunchedEffect(itemId) {
                if (itemId.isNotBlank()) onEnsureProjectChatsLoaded(itemId)
            }

            ProjectChatsScreen(
                // The route's ids, not the loaded list's memory: a deep link
                // names a project the drawer never touched.
                projectName = homeState.projects
                    .firstOrNull { it.id == itemId }
                    ?.displayName
                    ?: "Project",
                // A narrow slice, not the whole `HomeUiState`. Sharing the
                // state with the drawer is what makes "See all" free — one
                // fetch instead of two — but handing the whole object to this
                // screen would recompose its `LazyColumn` on every unrelated
                // emission, including a recents page the reader is not looking
                // at. A slice whose `List` reference is unchanged does not
                // rebuild.
                page = homeState.projectChats[itemId],
                selectedChatId = homeState.selectedChatId,
                runningSessionIds = runningSessionIds,
                isLoading = itemId in homeState.isLoadingMoreProjectChats ||
                    (homeState.isLoadingProjects && homeState.projectChats[itemId] == null),
                onChatSelected = onSelectChat,
                onOpenChat = { sessionId ->
                    // The shell's own `onOpenChat` navigates normally, because
                    // there is no project list under it. Here there is: pushing
                    // the chat normally would make Back return to this project,
                    // which is where the reader came from.
                    onOpenSession(sessionId)
                    navController.navigate(NalarRoutes.chat(sessionId))
                },
                onLoadMore = { onLoadMoreProjectChats(itemId) },
                onCreateTask = {
                    // The same `start` the drawer's `+` uses, with a summary
                    // rebuilt from this route's ids. A deep link names a project
                    // the drawer may never have loaded, so the row is
                    // synthesised rather than looked up — and its `item_type` is
                    // empty, which lands on the picker, the safe default: a
                    // project whose type is unknown gets both options offered
                    // rather than one guessed.
                    createTask.start(
                        ProjectSummary(
                            id = itemId,
                            workspaceId = backStackEntry.arguments
                                ?.getString(NalarRoutes.ARG_WORKSPACE_ID)
                                .orEmpty(),
                            itemType = homeState.projects
                                .firstOrNull { it.id == itemId }
                                ?.itemType
                                .orEmpty(),
                            name = homeState.projects
                                .firstOrNull { it.id == itemId }
                                ?.name
                                .orEmpty(),
                        ),
                    )
                },
                isCreatingTask = homeState.creatingTaskInProjectId == itemId,
                onBack = goBack,
            )
        }

        composable(
            route = NalarRoutes.NETWORK,
            deepLinks = listOf(navDeepLink { uriPattern = "nalar://network" }),
        ) {
            NetworkInspectorScreen(
                onBack = goBack,
                onOpenRecord = { recordId -> navController.navigate(NalarRoutes.recordDetail(recordId)) },
            )
        }

        composable(
            route = NalarRoutes.RECORD_DETAIL,
            arguments = listOf(
                navArgument(NalarRoutes.ARG_RECORD_ID) { type = NavType.LongType },
            ),
            deepLinks = listOf(
                navDeepLink { uriPattern = "nalar://network/record/{recordId}" },
            ),
        ) { backStackEntry ->
            val recordId = backStackEntry.arguments?.getLong(NalarRoutes.ARG_RECORD_ID)
            NetworkRecordDetailScreen(
                recordId = recordId,
                onBack = goBack,
                onReplay = { entry ->
                    coroutineScope.launch {
                        withContext(Dispatchers.IO) { replayNetworkEntry(entry) }
                    }
                },
            )
        }
    }

        if (visibleDestinations.isEmpty()) {
            NavigationLostScreen(onReturnHome = goBack)
        }

        // Over the graph, and *after* the recovery screen, so a dead back stack
        // keeps the one button that fixes it. A gate over `NavigationLostScreen`
        // would turn "the app lost track of where it was" into a splash with no
        // way out, which is the one thing that screen is not allowed to become.
        //
        // It covers the `NavHost` rather than replacing it, and that ordering is
        // the fix rather than a detail of the layout: the chat the resume just
        // navigated to is composed, measured and scrolled underneath this, so
        // the frame the reader finally sees is the frame the transcript is
        // already standing at the end of. Drawing nothing here instead would
        // move that work to *after* the reveal, which is the drift.
        if (gateIsUp && visibleDestinations.isNotEmpty()) {
            LaunchGateScreen()
        }
    }
}

/**
 * Reopens the chat the user was last in, when the app was closed and opened
 * again.
 *
 * The workspace half of the position is not here — `HomeViewModel` applies it
 * before its first fetch, so the drawer opens on the right workspace without a
 * wasted request. Only the chat is a route, and a route needs a destination to
 * navigate to, so it is navigated to from here.
 *
 * All of the policy is in [sessionToResume]; what is left here is reading the
 * current values and acting on the answer. That split is deliberate — the
 * conditions (authenticated, on the shell, the list settled, the chat still
 * there) are what is easy to get subtly wrong, and none of them can be asserted
 * from inside a composable.
 *
 * The auth phase is a *key* of the effect, not just a value it reads: the
 * sidebar's data often settles while the phase is still `Restoring`, and an
 * effect that only re-ran on the data would never revisit that answer.
 */
@Composable
private fun ResumeLastPosition(
    authState: AuthUiState,
    homeState: HomeUiState,
    navController: NavHostController,
    /**
     * Hoisted, because the launch gate above reads whether it has answered.
     * Passing it in rather than building it here is what lets the two be
     * answered from the same frame — the gate deciding "still asking" while the
     * effect is deciding "here is the chat" is a one-frame hole in the launch.
     */
    plan: ResumePlan?,
    /**
     * The current destination, hoisted from `currentBackStackEntryAsState`.
     *
     * **A key of the effect below, not a value it reads for itself.** The
     * destination is null for the frame or two before `NavHost` sets the graph,
     * and the effect's first run lands in that window. Reading
     * `navController.currentDestination` there is the same null the policy would
     * reject, and because the destination is in no other key, the effect never
     * runs again and the resume is dropped for the rest of the launch. Hoisting
     * it puts the arrival of the start destination into the key list, so the
     * question is re-asked the moment there is somewhere to ask it from.
     */
    currentRoute: String?,
    onSelectChat: (String) -> Unit,
    onOpenSession: (String) -> Unit,
    /**
     * The chat that was navigated to, handed up so the gate can wait for its
     * transcript. A `LaunchedEffect` cannot return a value, and a session id is
     * a fact the next composable has to act on rather than one it can re-derive.
     */
    onResumed: (String) -> Unit,
    /**
     * Called every time the plan is asked, with whether it has answered.
     *
     * Not only when it answers: `ResumePlan` latches its own decision and is
     * not observable, so nothing would tell the gate that the answer changed.
     * Every consultation reports, because a report that only arrived *with* an
     * answer would leave "there is nothing to resume" invisible to the one
     * thing waiting on it.
     */
    onPlanConsulted: (Boolean) -> Unit,
) {
    LaunchedEffect(
        authState.phase,
        currentRoute,
        homeState.selectedWorkspaceId,
        homeState.chats,
        homeState.isLoading,
        plan,
    ) {
        val sessionId = sessionToResume(
            authPhase = authState.phase,
            currentRoute = currentRoute,
            plan = plan,
            chats = homeState.chats,
            selectedWorkspaceId = homeState.selectedWorkspaceId,
            isLoading = homeState.isLoading,
        )
        // Read *after* the question, because `resolveSession` is what latches.
        onPlanConsulted(plan?.isDecided == true)
        if (sessionId == null) return@LaunchedEffect

        // The session is opened before the navigation for the same reason the
        // sidebar's own `onOpenChat` is: the route stays on the back stack, so
        // returning to it must not show an empty transcript waiting on a load
        // that never ran.
        onSelectChat(sessionId)
        onOpenSession(sessionId)
        // Before the navigation, so the frame the gate lifts in already knows
        // which transcript it is waiting for. Reversed, the gate would read a
        // null id on its first pass and keep waiting.
        onResumed(sessionId)
        navController.navigate(NalarRoutes.chat(sessionId))
    }
}

/**
 * The app is showing no destination at all.
 *
 * A `NavHost` with an empty back stack composes nothing, so without this the
 * window keeps the theme's background and the reader has no way out: Back exits
 * the app because there is no entry to pop. The reason is never worth making the
 * reader guess at, so it is stated and one tap is offered.
 */
@Composable
internal fun NavigationLostScreen(
    onReturnHome: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(NalarBackground)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(24.dp)
            .testTag("navigation_lost"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = "This screen is not available",
            style = MaterialTheme.typography.titleMedium,
            color = NalarText,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "The app lost track of where it was. Nothing is missing from your chats.",
            style = MaterialTheme.typography.bodyMedium,
            color = NalarMuted,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))
        Button(
            onClick = onReturnHome,
            modifier = Modifier.testTag("navigation_lost_home"),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = NalarAccent,
                contentColor = NalarBackground,
            ),
        ) {
            Text(text = "Back to chats")
        }
    }
}

/**
 * The title for a chat route.
 *
 * The session-detail endpoint carries the name too, but the route can be opened
 * by deep link before any list has loaded, so the sidebar is the only source
 * that can be consulted synchronously. Falling back to the raw id beats a blank
 * bar.
 */
private fun chatTitleFor(sessionId: String, chats: List<ChatSummary>): String =
    chats.firstOrNull { chat -> chat.id == sessionId }?.displayTitle
        ?: sessionId.ifBlank { "Chat" }
