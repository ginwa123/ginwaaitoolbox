package com.pabrik.mobile.network

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import com.pabrik.mobile.auth.AuthUiState
import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.chat.ChatMessage
import com.pabrik.mobile.chat.ChatUiState
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.HomeUiState
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.ui.PabrikTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The chat route has to *observe* the transcript, not be handed a sample of it.
 *
 * ### The bug this pins
 *
 * `PabrikNavGraph` used to take `chatState: () -> ChatUiState` and call it in the
 * chat destination. That looks like a lazy read and behaves like a value: a
 * `StateFlow.value` read during composition subscribes to nothing, so the
 * destination only repainted when some *other* collected state happened to
 * change — the home state, or the worker set.
 *
 * Everything with a second source kept working, which is exactly why it
 * shipped. A run registers a worker, so streaming repainted. A send moves the
 * chat list, so the composer cleared itself after a send. Typing had no second
 * source at all, so the controlled text field never received a new `value` and
 * every keystroke was swallowed — the reported "input message cannot typing".
 *
 * ### Why this is a rendered-tree test and not a source-grep
 *
 * A `ChatScreen` test cannot catch it: rendering the screen with a draft and
 * typing into it passes whether or not the graph hands it a live flow. The
 * failure is one level up — whether a *new emission* of the flow reaches a
 * destination that is already composed. That is observable only by rendering
 * the graph, pushing a value into the flow, and asserting the tree changed.
 * Which is what this does, with a `MutableStateFlow` standing in for the
 * ViewModel and a resume position to get the graph onto the chat route.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w390dp-h844dp")
class PabrikNavGraphChatStateTest {

    @get:Rule
    val compose = createComposeRule()

    private val chatState = MutableStateFlow(ChatUiState(sessionId = "sess_1", isLoading = false))

    /**
     * The production graph, resumed straight onto the chat route.
     *
     * A saved position rather than a tap: the resume is the path that puts the
     * chat on the back stack without a drawer interaction, which keeps this
     * file about one thing — whether the route follows the flow.
     */
    private fun renderChatRoute() {
        compose.setContent {
            PabrikTheme {
                val controller: NavHostController = rememberNavController()
                GraphWithChatState(
                    navController = controller,
                    chatState = chatState,
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun theRouteStartsOnTheChatTheResumeOpened() {
        // The precondition every other test here rests on: without this, a
        // failing assertion below could just be a route that never opened.
        renderChatRoute()

        compose.onNodeWithTag("chat_title").assertIsDisplayed()
        compose.onNodeWithTag("chat_composer_input").assertIsDisplayed()
    }

    @Test
    fun anEmissionReachesTheChatAlreadyOnScreen() {
        renderChatRoute()

        // This is the whole bug in one line. Before the fix the destination
        // read `chatState.value` once during composition and never again, so
        // this assignment changed the flow and nothing on screen.
        chatState.value = chatState.value.copy(
            messages = listOf(
                ChatMessage(
                    id = "m1",
                    role = ChatMessage.ROLE_USER,
                    content = "a turn that arrived live",
                    createdAtEpochMillis = 1_800_000_000_000L,
                    sortKeyNanos = 1_800_000_000_000_000_000L,
                ),
            ),
        )
        compose.waitForIdle()

        compose.onNodeWithText("a turn that arrived live").assertIsDisplayed()
    }

    @Test
    fun aDraftEmissionReachesTheComposerAlreadyOnScreen() {
        renderChatRoute()

        // Typing is the reported symptom, and it is the one emission with no
        // second source: nothing else in the tree changes when a keystroke is
        // written to the draft.
        chatState.value = chatState.value.copy(draft = "hello")
        compose.waitForIdle()

        compose.onNodeWithText("hello").assertIsDisplayed()
    }

    @Test
    fun anErrorEmissionReachesTheBannerAlreadyOnScreen() {
        renderChatRoute()

        chatState.value = chatState.value.copy(errorMessage = "the send did not land")
        compose.waitForIdle()

        compose.onNodeWithText("the send did not land").assertIsDisplayed()
    }
}

/**
 * The production graph, so the test drives the real destination and the real
 * resume. A copy of the graph would pass with the bug in place — the bug is in
 * the graph's own parameter, and a copy would be a different signature.
 */
@androidx.compose.runtime.Composable
private fun GraphWithChatState(
    navController: NavHostController,
    chatState: StateFlow<ChatUiState>,
) {
    PabrikNavGraph(
        authState = AuthUiState(phase = SessionPhase.Authenticated, userId = "user_a"),
        onSignIn = { _, _ -> },
        onRetrySession = {},
        onUseAnotherAccount = {},
        navController = navController,
        homeState = HomeUiState(
            isLoading = false,
            workspaces = listOf(WorkspaceOption("ws_a", "One")),
            selectedWorkspaceId = "ws_a",
            chats = listOf(
                ChatSummary(
                    id = "sess_1",
                    workspaceId = "ws_a",
                    title = "Chat sess_1",
                    updatedAtEpochMillis = 1_000L,
                ),
            ),
            selectedChatId = "sess_1",
        ),
        chatState = chatState,
        positionStore = FixedPosition(LastPosition(workspaceId = "ws_a", sessionId = "sess_1")),
        onSelectWorkspace = {},
        onSelectChat = {},
        onRetryHome = {},
        onOpenSession = {},
        onChatDraftChanged = {},
        onSendChatMessage = {},
        onStopChatRun = {},
        onLoadOlderChatMessages = {},
        onDismissChatError = {},
        onAnswerChatQuestion = {},
    )
}

/**
 * A store that answers one position and records nothing.
 *
 * A `PrefsLastPositionStore` would work too, but it needs a `Context` and writes
 * through `apply()`, and nothing here is about persistence — it is about what
 * the graph does with an answer.
 */
private class FixedPosition(private val position: LastPosition) : LastPositionStore {
    override fun read(userId: String?): LastPosition = position
    override fun save(userId: String?, position: LastPosition) = Unit
    override fun saveWorkspace(userId: String?, workspaceId: String) = Unit
    override fun clear() = Unit
}
