package com.nalar.mobile.network

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nalar.mobile.auth.AuthUiState
import com.nalar.mobile.auth.SessionPhase
import com.nalar.mobile.chat.ChatUiState
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.HomeUiState
import com.nalar.mobile.recents.WorkspaceOption
import com.nalar.mobile.storage.LastPosition
import com.nalar.mobile.storage.LastPositionStore
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * "Close the app, open it again, and it is where I was" — against a real
 * `NavController`.
 *
 * The JVM tests pin the *rule* ([SessionToResumeTest], [ResumePlanTest]) and
 * `HomeViewModelPositionTest` pins the workspace half, but the thing that makes
 * the feature work is a `navigate()` call from an effect on a real back stack,
 * and no assertion on a pure function can prove that call happens, happens
 * once, and lands somewhere Back can return from. That is what this is for.
 */
@RunWith(AndroidJUnit4::class)
class NalarNavGraphResumeInstrumentedTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private lateinit var controller: NavHostController

    private fun launch(
        saved: LastPosition,
        homeState: HomeUiState = settledHome(),
    ) {
        composeTestRule.setContent {
            NalarTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = homeState,
                    positionStore = FixedLastPosition(saved),
                )
            }
        }
        composeTestRule.waitForIdle()
    }

    @Test
    fun aRelaunchOpensTheSavedChat() {
        launch(LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        assertEquals(
            NalarRoutes.chat("sess_c"),
            controller.currentDestination?.route,
        )
        // The chat's way out is the hamburger's drawer, not an arrow.
        composeTestRule.onNodeWithTag("chat_drawer_menu").assertIsDisplayed()
    }

    @Test
    fun theResumeOpensTheSessionBeforeItNavigates() {
        // Otherwise Back lands on a chat route whose transcript was never
        // requested, and the user gets an empty screen with a title and no
        // explanation — the same failure the sidebar's own `onOpenChat` was fixed
        // for.
        val opened = mutableListOf<String>()
        composeTestRule.setContent {
            NalarTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                    onOpenSession = { opened += it },
                )
            }
        }
        composeTestRule.waitForIdle()

        assertEquals(listOf("sess_c"), opened)
    }

    @Test
    fun backFromAResumedChatReturnsToTheShell() {
        launch(LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        // Through the drawer, which is where the chat's way home now lives.
        composeTestRule.onNodeWithTag("chat_drawer_menu").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("chat_all_chats").performClick()
        composeTestRule.waitForIdle()

        // A `popUpTo` here would drop the shell and put the user on the recovery
        // screen, or nowhere at all.
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun aFirstLaunchStaysOnTheShell() {
        launch(LastPosition())

        assertEquals(NalarRoutes.SHELL, controller.currentDestination?.route)
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun aSavedChatTheListNoLongerHasIsNotOpened() {
        launch(
            LastPosition(workspaceId = "ws_b", sessionId = "sess_deleted"),
            homeState = settledHome(chats = listOf(chat("sess_a"), chat("sess_c"))),
        )

        // Opening a route whose session is gone gives an empty transcript, and
        // the shell is the truthful answer.
        assertEquals(NalarRoutes.SHELL, controller.currentDestination?.route)
    }

    @Test
    fun nothingIsRestoredBeforeTheSessionIsAuthenticated() {
        composeTestRule.setContent {
            NalarTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                    authState = AuthUiState(phase = SessionPhase.NeedsLogin),
                )
            }
        }
        composeTestRule.waitForIdle()

        // A chat opened here would 401, and a 401 signs the user out of an app
        // they were only ever trying to log into.
        assertEquals(NalarRoutes.SHELL, controller.currentDestination?.route)
    }

    @Test
    fun theChatIsOpenedOnceNotOncePerRecomposition() {
        val opened = mutableListOf<String>()
        composeTestRule.setContent {
            NalarTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                    onOpenSession = { opened += it },
                )
            }
        }
        composeTestRule.waitForIdle()

        // A second chat route for the same session is a second copy of the chat
        // under Back, and it is invisible until someone presses Back twice. The
        // session being opened once is the half that says it; the shell still
        // being underneath says the resume pushed a route rather than replacing
        // the whole stack, which would have left the user with nowhere to go.
        assertEquals(1, opened.size)
        assertEquals(NalarRoutes.chat("sess_c"), controller.currentDestination?.route)
        assertTrue(
            "the shell must still be under the chat",
            controller.previousBackStackEntry?.destination?.route == NalarRoutes.SHELL,
        )
    }

    private fun settledHome(chats: List<ChatSummary> = listOf(chat("sess_a"), chat("sess_c"))) =
        HomeUiState(
            isLoading = false,
            workspaces = listOf(WorkspaceOption("ws_b", "Two")),
            selectedWorkspaceId = "ws_b",
            chats = chats,
            selectedChatId = chats.firstOrNull()?.id,
        )

    private fun chat(id: String) = ChatSummary(
        id = id,
        workspaceId = "ws_b",
        title = "Chat $id",
        updatedAtEpochMillis = 1_000L,
    )
}

/** The production graph, so the test drives the real effect and the real routes. */
@Composable
private fun ResumeGraph(
    navController: NavHostController,
    homeState: HomeUiState,
    positionStore: LastPositionStore,
    authState: AuthUiState = AuthUiState(
        phase = SessionPhase.Authenticated,
        userId = "user_1",
    ),
    onOpenSession: (String) -> Unit = {},
) {
    NalarNavGraph(
        authState = authState,
        onSignIn = { _, _ -> },
        onRetrySession = {},
        onUseAnotherAccount = {},
        navController = navController,
        homeState = homeState,
        chatState = ChatUiState(isLoading = false),
        positionStore = positionStore,
        onSelectWorkspace = {},
        onSelectChat = {},
        onLoadMoreChats = {},
        onRetryHome = {},
        onOpenSession = onOpenSession,
        onChatDraftChanged = {},
        onSendChatMessage = {},
        onStopChatRun = {},
        onLoadOlderChatMessages = {},
        onDismissChatError = {},
        onAnswerChatQuestion = {},
    )
}
