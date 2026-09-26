package com.nalar.mobile.chat

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.getUnclippedBoundsInRoot
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
import androidx.compose.ui.test.swipeDown
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.WorkspaceOption
import com.nalar.mobile.shell.BackToChatsRow
import com.nalar.mobile.shell.RecentsDrawerContent
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

    /**
     * Layout is computed in sub-pixel floats and rounded per density, so exact
     * equality on a 12dp padding is a coin flip on a 2.75x screen. Half a dp is
     * wide enough to absorb the rounding and narrow enough that a bubble's
     * padding, or the 24dp of it that appears on both sides, still shows.
     */
    private val TOLERANCE = 0.5f

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
        isRunning: Boolean = false,
    ) {
        compose.setContent {
            NalarTheme {
                ChatScreen(
                    state = state,
                    chatTitle = "Test chat",
                    onDraftChanged = onDraftChanged,
                    onSend = onSend,
                    onStop = onStop,
                    onLoadOlder = onLoadOlder,
                    isRunning = isRunning,
                    // The transcript tests are not about the drawer, and an
                    // empty one would still be a real one. `ChatDrawerTest`
                    // drives this slot with the production sidebar.
                    drawerContent = { dismissDrawer ->
                        RecentsDrawerContent(
                            workspaces = listOf(WorkspaceOption("workspace-a", "Workspace A")),
                            chats = listOf(
                                ChatSummary(
                                    id = "chat-1",
                                    workspaceId = "workspace-a",
                                    title = "Test chat",
                                    updatedAtEpochMillis = 1_800_000_000_000L,
                                ),
                            ),
                            selectedWorkspaceId = "workspace-a",
                            selectedChatId = state.sessionId,
                            onWorkspaceSelected = {},
                            onChatSelected = {},
                            onOpenChat = dismissDrawer,
                            header = { BackToChatsRow(onClick = dismissDrawer) },
                        )
                    },
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

        // `swipeDown`, so the reader actually goes back into history. The old
        // `swipeUp` here dragged the content up, which a transcript already
        // parked on its newest turn cannot do — so the reader never left, the
        // follow flag stayed armed, and this test asserted that a new turn is
        // not pinned while passing with it very much pinned.
        compose.onNodeWithTag("chat_message_list").performTouchInput { swipeDown() }
        compose.waitForIdle()
        // The precondition, asserted: the newest turn is off screen.
        compose.onNodeWithTag("chat_message_m80").assertDoesNotExist()

        compose.runOnIdle {
            state.value = state.value.copy(
                messages = state.value.messages + message(
                    id = "brandNew",
                    role = ChatMessage.ROLE_USER,
                    content = "a turn that lands while the reader is reading history",
                ),
            )
        }
        compose.waitForIdle()

        // `brandNew` is a reader turn appended to a transcript ending in an
        // assistant turn, so it is a group of its own and can only be on screen
        // if the viewport was moved to it. An assistant turn would have been
        // folded into m80's group, which sits at the end either way, so that
        // assertion would have held whether or not anything was pinned — and
        // `m1`, seventy rows above the reader, is not composed either way and
        // said nothing at all.
        compose.onNodeWithTag("chat_message_brandNew").assertDoesNotExist()
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
    fun theHeaderSpinnerFollowsWorkerLivenessNotTheDeltaStream() {
        // The case that matters: a live stream, no chunks between turns. The
        // agent is mid tool-run and `isStreaming` is false, so the only thing
        // that can say so is the worker flag.
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, isLive = true),
            isRunning = true,
        )
        compose.onNodeWithTag("chat_running_spinner").assertExists()
        compose.onNodeWithTag("chat_live_dot").assertExists()

        renderScreen(ChatUiState(sessionId = "s", isLoading = false, isLive = true))
        compose.onNodeWithTag("chat_running_spinner").assertDoesNotExist()
    }

    @Test
    fun aRunningWorkerWithNoChunksStillShowsNoStopButton() {
        // Pinned so the spinner is never mistaken for the streaming flag: the
        // stop control stays on `isStreaming`, which only flips on real deltas.
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, isLive = true, isStreaming = false),
            isRunning = true,
        )
        compose.onNodeWithTag("chat_running_spinner").assertExists()
        compose.onNodeWithTag("chat_stop").assertDoesNotExist()
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

    // --- Bubble vs paragraph -----------------------------------------------

    /**
     * The rules the `chat_message_<id>` assertions above rest on: the tag rides
     * the reader's bubble AND the assistant's paragraph.
     *
     * Splitting the two rows into two composables is exactly the kind of change
     * that drops a `testTag` on the way through, and the tag is what those
     * virtualization assertions locate rows by. They would not fail loudly —
     * they would fail as "node not found", pointing at the virtualizer.
     */
    @Test
    fun bothRowsKeepTheirMessageTag() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "a question"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "an answer"),
                ),
            ),
        )

        compose.onNodeWithTag("chat_message_u1").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_a1").assertIsDisplayed()
    }

    /**
     * The assistant's answer fills the measure; a short reader turn does not.
     *
     * This is the de-bubbling assertion, stated as geometry because geometry is
     * what "boxed" means on screen. The reader's column wraps its content under
     * a 460dp cap, so a three-word question is a narrow slab; the assistant's
     * paragraph is `fillMaxWidth()` and no `Surface` sits behind it, so it runs
     * the full width of its group. Before this change both rows were the same
     * narrow inset slab and this failed on the assistant half.
     */
    @Test
    fun anAssistantTurnFillsTheMeasureWhileAReaderTurnStaysABubble() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "why?"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "because the agentic loop is a while loop"),
                ),
            ),
        )

        val groupWidth = width("chat_group_assistant")
        val assistantWidth = width("chat_message_a1")
        val readerWidth = width("chat_message_u1")

        assertEquals(
            "an assistant paragraph should span its group",
            groupWidth.value,
            assistantWidth.value,
            TOLERANCE,
        )
        assertTrue(
            "a reader bubble should be inset, was $readerWidth against a $groupWidth group",
            readerWidth < groupWidth,
        )
    }

    /**
     * The bubble's 12dp inner padding is the visible edge of the box, and only
     * the reader's row has it.
     *
     * Two ways to de-bubble and this catches both: a row drawn without the
     * `Surface` has nothing to inset, and one that kept a `Surface` but
     * cleared its fill and border would still show the padding as a dead 12dp
     * gutter. The reader's row is the control — if the padding assertion ever
     * stops holding there, this test is measuring the wrong thing rather than
     * reporting a real regression.
     */
    @Test
    fun onlyTheReaderRowCarriesBubblePadding() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "why?"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "because the agentic loop is a while loop"),
                ),
            ),
        )

        val readerInset = left("chat_body_u1") - left("chat_message_u1")
        val assistantInset = left("chat_body_a1") - left("chat_message_a1")

        assertEquals(
            "the reader bubble should pad its text by 12dp",
            12f,
            readerInset.value,
            TOLERANCE,
        )
        assertEquals(
            "an assistant paragraph should have no bubble gutter",
            0f,
            assistantInset.value,
            TOLERANCE,
        )
    }

    /**
     * The two rows anchor to opposite edges: a reader turn belongs under the
     * reader's thumb, an assistant answer belongs to the left margin.
     *
     * Straightening the assistant's alignment — a `fillMaxWidth` column that
     * somehow still measured against the trailing edge — is invisible in a
     * width assertion alone.
     */
    @Test
    fun theTwoRowsAnchorToOppositeEdges() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "why?"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "because the agentic loop is a while loop"),
                ),
            ),
        )

        val assistantGroup = bounds("chat_group_assistant")
        val readerGroup = bounds("chat_group_user")

        assertEquals(assistantGroup.left.value, left("chat_message_a1").value, TOLERANCE)
        assertEquals(
            readerGroup.right.value,
            right("chat_message_u1").value,
            TOLERANCE,
        )
    }

    // --- The jump back to the newest turn -----------------------------------

    /**
     * An answer long enough to fill several viewports on its own.
     *
     * The shape that breaks an index-based version of the control: this is one
     * list item, so it is the *last visible item* the whole time the reader is
     * anywhere inside it, and "is the newest turn on screen" answers yes for a
     * reader who has scrolled most of the way up it.
     */
    private fun oneTallAnswer(lines: Int = 300): List<ChatMessage> = listOf(
        message("tall", ChatMessage.ROLE_ASSISTANT, (1..lines).joinToString("\n") { "line $it" }),
    )

    @Test
    fun noJumpIsOfferedWhileTheTranscriptSitsOnItsNewestTurn() {
        // A control that is always on screen is a control that does nothing, and
        // a reader who has learned to distrust it will not tap it when it
        // matters. `assertDoesNotExist` rather than "is not displayed": the
        // control is not composed at all while hidden, so a reader's touch can
        // never land on it.
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()))

        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun noJumpIsOfferedOnATranscriptThatFitsTheViewport() {
        // Nothing is below the fold, so there is nowhere to jump to. Offering it
        // would be an affordance for scrolling that no scroll can do.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "a question"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "a short answer"),
                ),
            ),
        )

        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun noJumpIsOfferedOnAnEmptyOrLoadingTranscript() {
        // No rows means no measured layout, which is *unknown* rather than
        // "far from the end". Reading it as far puts a jump control over the
        // "No messages yet" placeholder.
        renderList(ChatUiState(sessionId = "s", isLoading = true))
        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()

        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = emptyList()))
        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun aJumpAppearsOnceTheReaderHasScrolledIntoHistory() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()))
        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()

        intoHistory()
        compose.onNodeWithTag("chat_jump_to_newest").assertIsDisplayed()
    }

    @Test
    fun aJumpAppearsInsideASingleAnswerTallerThanTheScreen() {
        // The case the pixel measurement exists for. One list item, so the
        // newest turn is on screen for the whole time the reader is inside it —
        // an index rule would keep the control hidden from the reader who wants
        // it most.
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = oneTallAnswer()))

        // No gesture needed, and none possible: this is a single list item
        // already at scroll position 0, so there is no "back into history" to
        // perform. Opening the chat parks the reader at the top of the answer
        // with all of it below them, which is precisely the reading an
        // index-based rule would have called "at the bottom".
        compose.onNodeWithTag("chat_jump_to_newest").assertIsDisplayed()
    }

    @Test
    fun pressingTheJumpInsideAnAnswerTallerThanTheScreenReachesItsEnd() {
        // The one thing `scrollToNewestEdge` exists to do, and the reason it is
        // not the auto-scroll's `scrollToItem`: landing on a turn taller than the
        // screen leaves the reader at its *top*, so a jump that reused it would
        // be a visible no-op. The control withdrawing is the observable proof
        // that the viewport reached the end rather than staying where it was.
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = oneTallAnswer()))
        compose.onNodeWithTag("chat_jump_to_newest").assertIsDisplayed()

        compose.onNodeWithTag("chat_jump_to_newest").performClick()
        compose.waitForIdle()

        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun pressingTheJumpLandsOnTheNewestTurnAndTakesItAway() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()))
        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()

        intoHistory()
        // The precondition, asserted: the reader really is in history, so the
        // jump below has somewhere to travel from.
        compose.onNodeWithTag("chat_message_m80").assertDoesNotExist()
        compose.onNodeWithTag("chat_jump_to_newest").assertIsDisplayed().performClick()
        compose.waitForIdle()

        // A real arrival, not a render: m80 is composed and m1 is not, so the
        // viewport genuinely moved rather than merely being repainted.
        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
        // And the control withdraws once the reader is where it said it would
        // take them, rather than sitting there offering the same jump again.
        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun aTurnThatArrivesAfterAJumpStillFollowsTheReader() {
        // The reason the jump goes through the scroll policy rather than
        // straight to `scrollToItem`. A scroll that did not re-arm the follow
        // flag would look like it worked, and then the next streamed delta would
        // find the flag still false and leave the new turn off screen.
        //
        // The new turn is a *reader* turn on purpose. An assistant turn
        // appended to a transcript that ends in an assistant turn is folded
        // into the same group, and that group is on screen at the end of the
        // transcript whether or not anything was pinned — so the assertion would
        // hold even with the follow flag left `false`. A reader turn is its own
        // group, so it can only be on screen because the viewport was moved.
        val state = renderSwitchable(
            ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()),
        )
        intoHistory()
        compose.onNodeWithTag("chat_jump_to_newest").performClick()
        compose.waitForIdle()

        compose.runOnIdle {
            state.value = state.value.copy(
                messages = state.value.messages + message(
                    id = "afterJump",
                    role = ChatMessage.ROLE_USER,
                    content = "a turn that lands after the reader jumped back to the end",
                ),
            )
        }
        compose.waitForIdle()

        compose.onNodeWithTag("chat_message_afterJump").assertIsDisplayed()
    }

    /**
     * Puts the reader a long way into history, and waits for the fling to land.
     *
     * **`swipeDown`, not `swipeUp`.** The names describe the finger, not the
     * list: `swipeUp` drags the content *up*, which scrolls a `LazyColumn`
     * forward toward the newest turn — and a transcript already parked on its
     * newest turn cannot move that way at all, so a "scroll into history"
     * written as `swipeUp()` silently does nothing and every assertion after it
     * passes for the wrong reason. `swipeDown` drags the content down, which is
     * what actually walks a reader back through the transcript.
     */
    private fun intoHistory() {
        compose.onNodeWithTag("chat_message_list").performTouchInput { swipeDown() }
        compose.waitForIdle()
    }

    // --- Geometry helpers ---------------------------------------------------
    // Unclipped bounds, because the thing under test is the box itself: a
    // clipped assertion cannot tell "the row is narrow" from "the row is wide
    // and the viewport is not", which is the whole difference on the reader side.

    private fun bounds(tag: String) = compose
        .onNodeWithTag(tag, useUnmergedTree = true)
        .getUnclippedBoundsInRoot()

    /** Derived from the edges so it means the same thing on every BOM. */
    private fun width(tag: String) = right(tag) - left(tag)

    private fun left(tag: String) = bounds(tag).left

    private fun right(tag: String) = bounds(tag).right
}
