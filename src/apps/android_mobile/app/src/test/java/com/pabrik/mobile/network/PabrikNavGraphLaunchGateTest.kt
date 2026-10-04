package com.pabrik.mobile.network

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import com.pabrik.mobile.auth.AuthUiState
import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.chat.ChatUiState
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.HomeUiState
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.ui.PabrikTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The launch gate, against the real `NavHost` — and on the JVM.
 *
 * `LaunchGateTest` pins the *rule*; this pins the thing the rule is for, which
 * is a rendering outcome: is there an opaque screen over the graph right now,
 * or not. No assertion on a pure function can see that, which is why this was
 * an instrumented test and why it sat unrun — an emulator was the only place it
 * could go, and an emulator is the one thing CI does not have. Under
 * Robolectric the real graph composes on the JVM, so the assertions that
 * mattered now run in `testDebugUnitTest`.
 *
 * The two halves are the pair. "The gate is up" alone passes just as happily
 * for a gate that is *always* up, which is a splash with no way out of it; the
 * second case is the one that fails when the callback stops firing.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PabrikNavGraphLaunchGateTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    private lateinit var controller: NavHostController

    @Test
    fun aResumedChatStaysBehindTheGateUntilItsTranscriptLands() {
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            // A cold open: the route is on the back stack and the first page has
            // not arrived. The reader must not see it yet, because the frame
            // they would see is the top of an empty list and the frame after it
            // is the bottom of a full one — the drift this exists to remove.
            chatState = MutableStateFlow(ChatUiState(sessionId = "sess_c", isLoading = true)),
        )

        // The navigation has already happened. Only the *showing* is held, which
        // is what lets the transcript load and scroll behind the gate at all —
        // a gate that replaced the destinations would move that work to after
        // the reveal, which is the bug.
        //
        // *Which* chat the route is on, read off the title bar rather than off
        // `currentDestination.route`. A destination's route is the *pattern* it
        // was declared with — `chat/{sessionId}` for every chat the app has
        // ever opened — so it cannot tell two resumes apart, and
        // `Bundle.getString` is not resolvable on the unit-test classpath. The
        // title is looked up in the same `homeState.chats` the route resolves
        // the session against, so this is the id the graph really navigated to.
        composeTestRule.onNodeWithTag("chat_title").assertTextEquals("Chat sess_c")
        composeTestRule.onNodeWithTag("launch_gate").assertIsDisplayed()
    }

    @Test
    fun theGateLiftsOnceTheResumedTranscriptHasLanded() {
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            // Loaded, and nothing to scroll because the transcript is empty —
            // which is also what a failed load looks like, and a gate that
            // waited for a scroll in that case would strand the reader.
            chatState = MutableStateFlow(ChatUiState(sessionId = "sess_c", isLoading = false)),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chat_drawer_menu").assertIsDisplayed()
    }

    @Test
    fun aFirstLaunchRevealsTheShellWithoutAnyChat() {
        // Nothing to resume is an *answer*, not a wait. If "no saved chat" left
        // the gate up, every first launch would be a splash with no exit.
        launch(saved = LastPosition())

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun aSavedChatTheListNoLongerHasStillRevealsTheShell() {
        // The answer is "no", for a reason. Treating it as "not yet" would hold
        // the gate for ever, on exactly the launch where the chat is gone.
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_deleted"),
            homeState = settledHome(chats = listOf(chat("sess_a"), chat("sess_c"))),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun aSignInScreenIsNeverCovered() {
        // The gate blocks by being opaque, and a gate over the sign-in form is
        // an app nobody can get into. The shell's own launch screen and retry
        // screen are the same argument, and all three are one test each because
        // `setContent` may only be called once per rule.
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            authState = AuthUiState(phase = SessionPhase.NeedsLogin),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
    }

    @Test
    fun theChatIsOpenedOnceAndLeavesTheShellUnderneathIt() {
        val opened = mutableListOf<String>()
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            onOpenSession = { opened += it },
        )

        // A second chat route for the same session is a second copy of the chat
        // under Back, and it is invisible until someone presses Back twice.
        assertEquals(listOf("sess_c"), opened)
        // The shell still underneath says the resume *pushed* a route rather
        // than replacing the whole stack, which would have left the reader with
        // nowhere to go. Without it, Back out of a resumed chat is a dead end.
        assertEquals(
            PabrikRoutes.SHELL,
            controller.previousBackStackEntry?.destination?.route,
        )
    }

    @Test
    fun aRestoringLaunchScreenIsNotCoveredByASecondOne() {
        // The shell already paints `AuthRestoringScreen` in this phase. A gate
        // on top would add nothing and put a second `auth_restoring` node in
        // the tree, which is a trap for any test that looks for that tag.
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            authState = AuthUiState(phase = SessionPhase.Restoring),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
    }

    @Test
    fun aRetryScreenIsNeverCovered() {
        // "Try again" and "Sign in" are the only way out of a rejected cookie.
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            authState = AuthUiState(
                phase = SessionPhase.NeedsRetry,
                errorMessage = "Cannot reach the server",
            ),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
    }

    private fun launch(
        saved: LastPosition,
        homeState: HomeUiState = settledHome(),
        authState: AuthUiState = AuthUiState(
            phase = SessionPhase.Authenticated,
            userId = "user_1",
        ),
        onOpenSession: (String) -> Unit = {},
        chatState: StateFlow<ChatUiState> = MutableStateFlow(ChatUiState(sessionId = "sess_c", isLoading = false)),
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                GateGraph(
                    navController = controller,
                    homeState = homeState,
                    positionStore = FixedLastPosition(saved),
                    authState = authState,
                    onOpenSession = onOpenSession,
                    chatState = chatState,
                )
            }
        }
        composeTestRule.waitForIdle()
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

/**
 * A store that answers one position and records nothing.
 *
 * A `PrefsLastPositionStore` would work too, but it needs a `Context` and writes
 * through `apply()`, and none of these tests are about persistence — they are
 * about what the graph does with an answer.
 */
internal class FixedLastPosition(private val position: LastPosition) : LastPositionStore {
    override fun read(userId: String?): LastPosition = position
    override fun save(userId: String?, position: LastPosition) = Unit
    override fun saveWorkspace(userId: String?, workspaceId: String) = Unit
    override fun clear() = Unit
}

/** The production graph, so the test drives the real effect and the real routes. */
@Composable
private fun GateGraph(
    navController: NavHostController,
    homeState: HomeUiState,
    positionStore: LastPositionStore,
    authState: AuthUiState,
    onOpenSession: (String) -> Unit,
    chatState: StateFlow<ChatUiState>,
) {
    PabrikNavGraph(
        authState = authState,
        onSignIn = { _, _ -> },
        onRetrySession = {},
        onUseAnotherAccount = {},
        navController = navController,
        homeState = homeState,
        chatState = chatState,
        positionStore = positionStore,
        onSelectWorkspace = {},
        onSelectChat = {},
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
