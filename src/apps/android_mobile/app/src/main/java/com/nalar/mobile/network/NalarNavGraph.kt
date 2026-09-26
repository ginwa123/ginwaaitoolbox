package com.nalar.mobile.network

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
import androidx.compose.runtime.rememberCoroutineScope
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
import com.nalar.mobile.shell.BackToChatsRow
import com.nalar.mobile.shell.MobileHomeScreen
import com.nalar.mobile.shell.RecentsDrawerContent
import com.nalar.mobile.shell.chatDrawerSelectedChatId
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import kotlinx.coroutines.Dispatchers
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

    fun chat(sessionId: String): String = "chat/${UriEncoding.encode(sessionId)}"

    fun recordDetail(recordId: Long): String = "network/record/$recordId"
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
    chatState: ChatUiState,
    onSelectWorkspace: (String) -> Unit,
    onSelectChat: (String) -> Unit,
    onLoadMoreChats: () -> Unit,
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
) {
    val coroutineScope = rememberCoroutineScope()
    val openInspector: () -> Unit = { navController.navigate(NalarRoutes.NETWORK) }

    // A `nalar://` link or a `popUpTo(SHELL)` navigation can leave a leaf as the
    // only destination on the back stack. The back arrow there used to call the
    // inclusive `popBackStack()`, which emptied the back stack and left `NavHost`
    // drawing nothing at all. See [BackAction]. The chat's own way out is now
    // the drawer's "All chats" row, which lands here.
    val goBack: () -> Unit = { navController.goBackToPreviousOrShell() }

    // A chat picked from the chat route's drawer *replaces* the one on screen
    // rather than stacking on it. Pushing would make system Back walk back
    // through every chat opened this session, and the reader is switching
    // between chats, not moving through a history of them.
    //
    // On a deep-linked chat the shell is not underneath, so the popUpTo finds
    // nothing and the new chat lands on top of the old one. Back then returns
    // to the chat that was open, which is a route onwards rather than a dead
    // end — and "All chats" still reaches the shell.
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

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(NalarBackground),
    ) {
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
                    isAuthEnabled = authState.isAuthEnabled,
                    signedInEmail = authState.userEmail,
                    isLoggingOut = authState.isLoggingOut,
                    onLogout = signOut,
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

            ChatScreen(
                state = chatState,
                chatTitle = chatTitleFor(sessionId, homeState.chats),
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
                        // The chat has no back arrow to leave by, and a deep-linked
                        // one has nothing beneath it for the system Back button to
                        // pop, so the drawer carries the route home itself.
                        header = {
                            BackToChatsRow(
                                onClick = {
                                    dismissDrawer()
                                    goBack()
                                },
                            )
                        },
                        isLoading = homeState.isLoading,
                        errorMessage = homeState.errorMessage,
                        onRetry = onRetryHome,
                        isLoadingMore = homeState.isLoadingMoreChats,
                        hasMoreChats = homeState.hasMoreChats,
                        onLoadMore = onLoadMoreChats,
                        isAuthEnabled = authState.isAuthEnabled,
                        signedInEmail = authState.userEmail,
                        isLoggingOut = authState.isLoggingOut,
                        onLogout = signOut,
                    )
                },
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
