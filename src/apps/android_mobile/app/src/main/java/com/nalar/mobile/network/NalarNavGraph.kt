package com.nalar.mobile.network

import androidx.compose.runtime.Composable
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
import com.nalar.mobile.login.LoginCredentials
import com.nalar.mobile.login.LoginScreen
import com.nalar.mobile.recents.HomeUiState
import com.nalar.mobile.shell.MobileHomeScreen
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Every view in the app is a route, so the inspector survives a process restart
 * and `adb shell am start -a android.intent.action.VIEW -d nalar://network`
 * lands on it directly — the Android equivalent of opening DevTools.
 */
object NalarRoutes {
    const val SHELL = "app"
    const val NETWORK = "network"
    const val RECORD_DETAIL = "network/record/{recordId}"
    const val ARG_RECORD_ID = "recordId"

    fun recordDetail(recordId: Long): String = "network/record/$recordId"
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
    onSelectWorkspace: (String) -> Unit,
    onSelectChat: (String) -> Unit,
    onRetryHome: () -> Unit,
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
                    onOpenNetworkInspector = openInspector,
                    isLoading = homeState.isLoading,
                    errorMessage = homeState.errorMessage,
                    onRetry = onRetryHome,
                )
            }
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
