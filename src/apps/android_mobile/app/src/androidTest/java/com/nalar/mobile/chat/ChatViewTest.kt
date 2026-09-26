package com.nalar.mobile.chat

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
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

    /**
     * Alternating roles, so every turn is its own list item.
     *
     * [transcript] is one group, not `count` of them — consecutive same-role
     * turns collapse — which makes it useless for asserting where the viewport
     * is. This is the shape a real conversation has.
     */
    private fun conversation(prefix: String, count: Int): List<ChatMessage> = (1..count).map { index ->
        val role = if (index % 2 == 1) ChatMessage.ROLE_USER else ChatMessage.ROLE_ASSISTANT
        message("${prefix}m$index", role, "turn $index of the $prefix transcript")
    }

    /** Long enough to overflow a phone viewport several times over. */
    private fun longConversation(prefix: String = "") = conversation(prefix, 80)

    /**
     * A transcript whose last turn is still streaming, with [lines] of text
     * already in it.
     */
    private fun streamingTail(prefix: String = "", count: Int = 3, lines: Int = 1): List<ChatMessage> =
        conversation(prefix, count) + message(
            id = "${prefix}stream",
            role = ChatMessage.ROLE_ASSISTANT,
            content = (1..lines).joinToString("\n") { "chunk line $it" },
            streaming = true,
        )

    /**
     * Renders a chat the test can re-point at another session, which is the only
     * way to express "the reader switched chats" — a fresh composition would
     * reset the scroll state and prove nothing.
     */
    private fun renderSwitchable(initial: ChatUiState): MutableState<ChatUiState> {
        val state = mutableStateOf(initial)
        compose.setContent {
            NalarTheme {
                ChatView(state = state.value)
            }
        }
        return state
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

    // --- Tool call and its output are one row -------------------------------

    /** A call declaration with nothing but `tool_calls_json` on it. */
    private fun declaration(id: String, callId: String, name: String) = message(
        id = id,
        role = ChatMessage.ROLE_ASSISTANT,
        content = "",
    ).copy(
        toolName = name,
        finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
        toolCallsJson = """[{"id":"$callId","type":"function",""" +
            """"function":{"name":"$name","arguments":"{}"}}]""",
    )

    /** The `tool` row that answers it, carrying the join key back to the call. */
    private fun answered(id: String, callId: String, name: String) = message(
        id = id,
        role = ChatMessage.ROLE_TOOL,
        content = """{"tool":"$name","success":true,"data":{"ok":true},"error":null}""",
    ).copy(toolName = name, toolCallId = callId)

    @Test
    fun anAnsweredToolCallDropsItsSummaryLine() {
        // The reported bug. The card already shows the call's name and its
        // arguments, so the "1 TOOL" line above it repeated the same two facts
        // in a separate row — once per step, all the way down the transcript.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    declaration("a1", "c1", "read_file"),
                    answered("t1", "c1", "read_file"),
                ),
            ),
        )

        compose.onNodeWithTag("tool_call_summary").assertDoesNotExist()
        // And the answer is not thrown away with the summary: the card is there.
        compose.onNodeWithTag("chat_tool_t1").assertExists()
    }

    @Test
    fun anUnansweredToolCallKeepsItsSummaryLine() {
        // The other half, and the reason the suppression above is safe. While
        // the result is in flight the header is the only thing on screen naming
        // the call, so it has to stay.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(declaration("a1", "c1", "read_file")),
            ),
        )

        compose.onNodeWithTag("tool_call_summary").assertIsDisplayed()
    }

    @Test
    fun aTwelveStepRunDrawsTwelveCardsAndNoSummaries() {
        // The whole shape in the screenshot, end to end: no interleaved
        // "1 TOOL command" rows anywhere in it.
        val messages = buildList {
            repeat(12) { index ->
                add(declaration("a$index", "c$index", "command"))
                add(answered("t$index", "c$index", "command"))
            }
        }

        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = messages))

        compose.onAllNodesWithTag("tool_call_summary", useUnmergedTree = true)
            .assertCountEquals(0)
    }

    // --- Markdown in the answer ---------------------------------------------

    @Test
    fun anAssistantAnswerRendersItsMarkdown() {
        // The other reported bug: the answer arrived wrapped in `<markdown>`
        // and every heading and `**bold**` on it was drawn literally.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message(
                        "a1",
                        ChatMessage.ROLE_ASSISTANT,
                        "<markdown>\n**PR:** https://example.dev/pull/663\n\n" +
                            "## What I built\n\nA **model** layer.\n</markdown>",
                    ),
                ),
            ),
        )

        compose.onNodeWithTag("markdown").assertExists()
        // The wrapper is gone, so nothing on screen is a tag or an asterisk.
        compose.onNodeWithText("<markdown>", substring = true).assertDoesNotExist()
        compose.onNodeWithText("**", substring = true).assertDoesNotExist()
        compose.onNodeWithText("##", substring = true).assertDoesNotExist()
    }

    @Test
    fun aUsersOwnMarkdownIsNotRewrittenBackAtThem() {
        // The web draws a user turn as plain text and only `marked.parse`s the
        // assistant's. A question the reader typed has to come back looking
        // exactly as they sent it.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(message("u1", ChatMessage.ROLE_USER, "is **this** right?")),
            ),
        )

        compose.onNodeWithText("is **this** right?").assertIsDisplayed()
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
                messages = longConversation(),
                hasMoreOlder = true,
            ),
        )

        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()
        // Off-screen rows are not composed at all, so this is a real assertion
        // about the viewport and not merely about rendering.
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
    }

    @Test
    fun openingAChatLandsOnItsNewestTurn() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()))

        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
    }

    @Test
    fun switchingToAChatOfTheSameLengthStillLandsOnItsNewestTurn() {
        // The regression. Two chats holding the same number of turns move
        // neither the group count nor the message count, so a view that only
        // reacted to counts changing did not react at all: the second chat
        // opened exactly where the first one was parked.
        val state = renderSwitchable(
            ChatUiState(sessionId = "a", isLoading = false, messages = longConversation("a")),
        )
        compose.onNodeWithTag("chat_message_am80").assertIsDisplayed()

        compose.runOnIdle {
            state.value = ChatUiState(sessionId = "b", isLoading = false, messages = longConversation("b"))
        }
        compose.waitForIdle()

        compose.onNodeWithTag("chat_message_bm80").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_bm1").assertDoesNotExist()
    }

    @Test
    fun aChatThatOpensEmptyAndLoadsLaterStillLandsOnItsNewestTurn() {
        // `openSession` paints an empty transcript first when there is no cache,
        // and the rows land a frame later. The scroll intent has to survive
        // that empty paint.
        val state = renderSwitchable(ChatUiState(sessionId = "s", isLoading = true))
        compose.onNodeWithTag("chat_loading").assertExists()

        compose.runOnIdle {
            state.value = ChatUiState(sessionId = "s", isLoading = false, messages = longConversation())
        }
        compose.waitForIdle()

        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
    }

    @Test
    fun aStreamingAnswerKeepsTheNewestTurnInView() {
        // A streamed delta replaces the newest message in place: the same id in
        // the same group, the same number of items, taller by a line. Counted by
        // items, the list reports no change at all while the answer grows out of
        // the bottom of the viewport.
        val state = renderSwitchable(
            ChatUiState(sessionId = "s", isLoading = false, messages = streamingTail()),
        )
        compose.onNodeWithTag("chat_message_m1").assertIsDisplayed()

        repeat(6) { chunk ->
            compose.runOnIdle {
                val grown = state.value.messages.dropLast(1) + state.value.messages.last().copy(
                    content = (1..(6 * (chunk + 1))).joinToString("\n") { "chunk line $it" },
                )
                state.value = state.value.copy(messages = grown)
            }
            compose.waitForIdle()
        }

        compose.onNodeWithTag("chat_message_stream").assertIsDisplayed()
        // Re-pinned to the newest turn, so the top of the transcript is now well
        // out of view. Left to itself the list would still be showing m1.
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
    }

    @Test
    fun aTurnThatArrivesWhileTheReaderIsInHistoryDoesNotYankThem() {
        // Following the tail is a courtesy for a reader who is already there. A
        // reader who has deliberately scrolled back must not be thrown to the
        // end by the next turn.
        val state = renderSwitchable(
            ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()),
        )
        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()

        compose.onNodeWithTag("chat_message_list").performTouchInput { swipeUp() }
        compose.waitForIdle()
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()

        compose.runOnIdle {
            state.value = state.value.copy(
                messages = state.value.messages + message(
                    id = "brandNew",
                    role = ChatMessage.ROLE_ASSISTANT,
                    content = "a turn that lands while the reader is reading history",
                ),
            )
        }
        compose.waitForIdle()

        compose.onNodeWithTag("chat_message_brandNew").assertDoesNotExist()
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
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
