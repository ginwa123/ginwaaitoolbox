package com.nalar.mobile.network

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
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
import com.nalar.mobile.shell.MobileHomeScreen
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
) {
    val coroutineScope = rememberCoroutineScope()
    val openInspector: () -> Unit = { navController.navigate(NalarRoutes.NETWORK) }

    NavHost(
        navController = navController,
        startDestination = NalarRoutes.SHELL,
        modifier = modifier,
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
                onBack = { navController.popBackStack() },
                onDraftChanged = onChatDraftChanged,
                onSend = onSendChatMessage,
                onStop = onStopChatRun,
                onLoadOlder = onLoadOlderChatMessages,
                onDismissError = onDismissChatError,
                onAnswer = onAnswerChatQuestion,
            )
        }

        composable(
            route = NalarRoutes.NETWORK,
            deepLinks = listOf(navDeepLink { uriPattern = "nalar://network" }),
        ) {
            NetworkInspectorScreen(
                onBack = { navController.popBackStack() },
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
                onBack = { navController.popBackStack() },
                onReplay = { entry ->
                    coroutineScope.launch {
                        withContext(Dispatchers.IO) { replayNetworkEntry(entry) }
                    }
                },
            )
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
