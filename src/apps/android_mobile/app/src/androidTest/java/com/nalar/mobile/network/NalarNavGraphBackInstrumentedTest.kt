package com.nalar.mobile.network

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.espresso.Espresso
import androidx.navigation.NavGraph
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nalar.mobile.auth.AuthUiState
import com.nalar.mobile.auth.SessionPhase
import com.nalar.mobile.chat.ChatUiState
import com.nalar.mobile.recents.HomeUiState
import com.nalar.mobile.storage.LastPosition
import com.nalar.mobile.storage.LastPositionStore
import com.nalar.mobile.ui.NalarTheme
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The blank screen, reproduced.
 *
 * A `nalar://` link that reaches the activity without `FLAG_ACTIVITY_NEW_TASK`
 * goes through `handleDeepLink`'s "another app's task" branch, which navigates
 * with `popUpTo(graph, inclusive = true)` — so the shell is never pushed and the
 * deep-linked leaf is the only destination on the back stack. The back arrow on
 * that screen used to call the no-argument `popBackStack()`, which is inclusive:
 * it emptied the back stack, reported `false` while doing it, and left `NavHost`
 * with no visible entry, which it renders as *nothing*. The process stayed alive
 * and the activity stayed resumed, so the reader got a window with no content,
 * no way out, and a Back button that quit the app.
 *
 * These tests put the real `NavHost` into that state and assert that an in-app
 * affordance leaves something on screen. On the chat route that affordance is no
 * longer a back arrow, and no longer the drawer's "All chats" row either — the
 * drawer opens the list that row led to, so keeping it would have been a second
 * route to where the reader already stands. What is left is the system Back
 * button, which the chat destination claims with a `BackHandler`. This is the
 * only thing standing between a deep-linked chat and "Back quits the app", so it
 * is driven for real here rather than simulated.
 */
@RunWith(AndroidJUnit4::class)
class NalarNavGraphBackInstrumentedTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private lateinit var controller: NavHostController

    private fun setUpGraph() {
        composeTestRule.setContent {
            NalarTheme {
                controller = rememberNavController()
                TestNavGraph(navController = controller)
            }
        }
        composeTestRule.waitForIdle()
    }

    /** Leaves a leaf as the *only* destination, which is the deep-link shape. */
    private fun navigateToDeepLinkedLeaf() {
        composeTestRule.runOnUiThread {
            controller.navigate(NalarRoutes.chat("sess_1")) {
                popUpTo(controller.graph.id) { inclusive = true }
            }
        }
        composeTestRule.waitForIdle()
        assertFalse(
            "precondition: the leaf should be the only destination",
            controller.previousBackStackEntry.let { it == null || it.destination is NavGraph },
        )
    }

    /**
     * The chat's way out: the system Back button, which the route claims.
     *
     * The drawer is opened first and closed again on purpose. `ModalNavigationDrawer`
     * registers its own, deeper `BackHandler`, and the dispatcher runs the
     * most-recently-added enabled callback first — so an open drawer has to eat
     * the press, and only a closed one can be relied on to reach the route's.
     */
    private fun leaveChatWithTheSystemBackButton() {
        composeTestRule.onNodeWithTag("chat_drawer_menu").performClick()
        composeTestRule.waitForIdle()
        Espresso.pressBack()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()

        Espresso.pressBack()
        composeTestRule.waitForIdle()
    }

    @Test
    fun systemBackLeavesTheShellOnScreenFromASingleDestinationStack() {
        setUpGraph()
        navigateToDeepLinkedLeaf()

        leaveChatWithTheSystemBackButton()

        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun theInspectorBackArrowLeavesTheShellOnScreenFromASingleDestinationStack() {
        setUpGraph()
        composeTestRule.runOnUiThread {
            controller.navigate(NalarRoutes.NETWORK) {
                popUpTo(controller.graph.id) { inclusive = true }
            }
        }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_back").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun systemBackReturnsToTheShellFromAChatPushedOverIt() {
        setUpGraph()
        composeTestRule.runOnUiThread { controller.navigate(NalarRoutes.chat("sess_1")) }
        composeTestRule.waitForIdle()

        leaveChatWithTheSystemBackButton()

        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun anEmptiedBackStackShowsTheRecoveryScreenRatherThanNothing() {
        setUpGraph()
        // Empty the back stack the way the inclusive pop did, and assert the graph
        // answers it rather than leaving a bare window. This is the guard that
        // turns any future way into that state into one tap.
        composeTestRule.runOnUiThread {
            controller.popBackStack(controller.graph.id, inclusive = true)
        }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("navigation_lost").assertIsDisplayed()
        composeTestRule.onNodeWithTag("navigation_lost_home").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }
}

/**
 * The production graph with inert data, so the test exercises the real routes and
 * the real back affordances rather than a stand-in for them.
 */
@Composable
private fun TestNavGraph(navController: NavHostController) {
    NalarNavGraph(
        authState = AuthUiState(phase = SessionPhase.Authenticated, userId = "user_1"),
        onSignIn = { _, _ -> },
        onRetrySession = {},
        onUseAnotherAccount = {},
        navController = navController,
        homeState = HomeUiState(isLoading = false),
        chatState = MutableStateFlow(ChatUiState(sessionId = "sess_1", isLoading = false)),
        // Nothing saved: the back stack is what this file is about, and a
        // position that resumed would navigate out from under the test.
        positionStore = NoLastPosition,
        onSelectWorkspace = {},
        onSelectChat = {},
        onLoadMoreChats = {},
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
 * A store with nothing in it: a first launch.
 *
 * Defined here rather than shared with the JVM tests because `src/test` is not on
 * the instrumented classpath. Every test that composes the graph needs one, and
 * only the resume tests care what it holds.
 */
internal object NoLastPosition : LastPositionStore {
    override fun read(userId: String?): LastPosition = LastPosition()
    override fun save(userId: String?, position: LastPosition) = Unit
    override fun saveWorkspace(userId: String?, workspaceId: String) = Unit
    override fun clear() = Unit
}

/** A store that always reports the same saved position. */
internal class FixedLastPosition(private val position: LastPosition) : LastPositionStore {
    override fun read(userId: String?): LastPosition = position
    override fun save(userId: String?, position: LastPosition) = Unit
    override fun saveWorkspace(userId: String?, workspaceId: String) = Unit
    override fun clear() = Unit
}
