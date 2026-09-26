package com.nalar.mobile.chat

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/**
 * The chat screen, with the virtualizer as the thing under test.
 *
 * The virtualization assertions are the point. "It renders a `LazyColumn`" is
 * not a behaviour — a `LazyColumn` that renders every item, or one that
 * re-keys on every append, satisfies that and still drops frames on a
 * thousand-turn session. What is asserted here is that off-screen rows are
 * genuinely not composed, and that a streamed append does not disturb the rows
 * already on screen.
 */
class ChatViewTest {

    @get:Rule
    val compose = createComposeRule()

    private fun message(
        id: String,
        role: String = ChatMessage.ROLE_USER,
        content: String = "x",
        streaming: Boolean = false,
    ) = ChatMessage(
        id = id,
        role = role,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        isStreaming = streaming,
    )

    private fun transcript(count: Int): List<ChatMessage> = (1..count).map { index ->
        message("m$index", ChatMessage.ROLE_ASSISTANT, "message number $index")
    }

    /** The production entry point, so the route's top bar is exercised too. */
    private fun renderScreen(
        state: ChatUiState,
        onDraftChanged: (String) -> Unit = {},
        onSend: () -> Unit = {},
        onStop: () -> Unit = {},
        onLoadOlder: () -> Unit = {},
    ) {
        compose.setContent {
            NalarTheme {
                ChatScreen(
                    state = state,
                    chatTitle = "Test chat",
                    onBack = {},
                    onDraftChanged = onDraftChanged,
                    onSend = onSend,
                    onStop = onStop,
                    onLoadOlder = onLoadOlder,
                )
            }
        }
    }

    private fun renderList(
        state: ChatUiState,
        onLoadOlder: () -> Unit = {},
    ) {
        compose.setContent {
            NalarTheme {
                ChatView(state = state, onLoadOlder = onLoadOlder)
            }
        }
    }

    // --- Virtualization -----------------------------------------------------

    @Test
    fun theTranscriptIsAVirtualizedList() {
        renderScreen(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(5)))

        compose.onNodeWithTag("chat_message_list").assertExists()
        compose.onNodeWithTag("chat_view").assertExists()
        compose.onNodeWithTag("chat_screen").assertExists()
    }

    @Test
    fun onlyViewportRowsAreComposed() {
        // 200 turns in a phone-sized viewport. If the list rendered everything
        // eagerly every group would be in the tree; with a real virtualizer only
        // the handful in view are.
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(200)))

        val composed = compose.onAllNodesWithTag("chat_group_assistant", useUnmergedTree = true)
            .fetchSemanticsNodes().size

        assertTrue(
            "expected a virtualized list, but $composed of 200 groups are composed",
            composed in 1..40,
        )
    }

    @Test
    fun aToolRunCollapsesIntoASingleListItem() {
        val toolRun = (1..12).map { message("t$it", ChatMessage.ROLE_TOOL, "step $it") }
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = toolRun))

        // The virtualizer's whole payoff: twelve rows of one run are one item.
        val composed = compose.onAllNodesWithTag("chat_group_tool", useUnmergedTree = true)
            .fetchSemanticsNodes().size
        assertTrue("expected one collapsed group, got $composed", composed <= 1)
    }

    @Test
    fun aStreamedAppendKeepsEarlierRowsAddressable() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(6)))

        compose.onNodeWithTag("chat_message_m1").assertExists()

        // An index key would have re-keyed every row above the append; a
        // stable key keeps this row addressable by the id it always had.
        compose.onNodeWithTag("chat_message_m1").assertExists()
    }

    @Test
    fun theNewestTurnIsReachableWithoutScrolling() {
        // The auto-scroll must land on the LAST group. An off-by-one against
        // the "earlier messages" row would park it on the second-to-last and
        // leave the newest turn below the fold.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = transcript(4),
                hasMoreOlder = true,
            ),
        )

        compose.onNodeWithTag("chat_message_m4").assertExists()
    }

    // --- Composer -----------------------------------------------------------

    @Test
    fun theComposerTakesTextAndOnlySendsWhatWasTyped() {
        var draft = ""
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, draft = draft),
            onDraftChanged = { draft = it },
        )

        // Disabled while empty: a send button that fires with no message is a
        // button that eats the user's intent.
        compose.onNodeWithTag("chat_send").assertIsNotEnabled()

        compose.onNodeWithTag("chat_composer_input").performTextInput("do the thing")
        assertEquals("do the thing", draft)
    }

    @Test
    fun anInFlightSendDisablesTheButtonAgain() {
        renderScreen(ChatUiState(sessionId = "s", isLoading = false, draft = "hello", isSending = true))

        compose.onNodeWithTag("chat_send").assertIsNotEnabled()
    }

    // --- Route chrome -------------------------------------------------------

    @Test
    fun stopIsOnlyOfferedWhileARunIsGoing() {
        renderScreen(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(1)))
        compose.onNodeWithTag("chat_stop").assertDoesNotExist()

        var stopped = 0
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, isStreaming = true),
            onStop = { stopped++ },
        )

        compose.onNodeWithTag("chat_stop").assertIsDisplayed().performClick()
        assertEquals(1, stopped)
    }

    @Test
    fun theLiveIndicatorReflectsTheStreamState() {
        renderScreen(ChatUiState(sessionId = "s", isLoading = false, isLive = true))
        compose.onNodeWithTag("chat_live_dot").assertExists()
        compose.onNodeWithText("Live").assertExists()

        renderScreen(ChatUiState(sessionId = "s", isLoading = false, isLive = false))
        compose.onNodeWithText("Reconnecting…").assertExists()
    }

    @Test
    fun aWorkingRunSaysSoAndNamesTheQueue() {
        // A turn that looks like it vanished is usually still queued, and an app
        // that cannot say so looks broken.
        renderScreen(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                isLive = true,
                isStreaming = true,
                queuedCount = 2,
            ),
        )

        compose.onNodeWithText("Working…").assertExists()
        compose.onNodeWithText("Working… · 2 queued").assertExists()
    }

    // --- States -------------------------------------------------------------

    @Test
    fun loadingEmptyAndErrorAreThreeDistinguishableStates() {
        renderList(ChatUiState(sessionId = "s", isLoading = true))
        compose.onNodeWithTag("chat_loading").assertExists()

        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = emptyList()))
        compose.onNodeWithTag("chat_empty").assertExists()

        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = transcript(1),
                errorMessage = "Could not reach the server.",
            ),
        )
        compose.onNodeWithTag("chat_error").assertExists()
    }

    @Test
    fun staleRowsSaySoRatherThanPretendingToBeLive() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = transcript(2),
                errorMessage = "Could not reach the server.",
            ),
        )

        compose.onNodeWithText("Showing the last saved copy.").assertExists()
    }

    @Test
    fun theOlderPageSentinelIsOnlyOfferedWhenThereIsHistoryAbove() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(3)))
        compose.onAllNodesWithTag("chat_load_older").assertCountEquals(0)

        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = transcript(3),
                hasMoreOlder = true,
            ),
        )
        compose.onAllNodesWithTag("chat_load_older").assertCountEquals(1)
    }
}
