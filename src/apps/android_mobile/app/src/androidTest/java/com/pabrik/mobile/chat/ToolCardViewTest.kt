package com.pabrik.mobile.chat

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/**
 * Tool cards, as drawn.
 *
 * The unit tests cover the parsing; these cover the two things only a composed
 * tree can show. First, that a tool row renders as a *card* and not as a chat
 * bubble — the regression this feature exists to fix, and one no parser test
 * can catch. Second, that expansion survives the `LazyColumn` recycling a card
 * through an off-screen pass, which is the whole reason the open/closed state
 * is hoisted above the list.
 */
class ToolCardViewTest {

    @get:Rule
    val compose = createComposeRule()

    private fun toolRow(
        id: String,
        toolName: String,
        data: String,
        parameters: String = "{}",
    ) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_TOOL,
        content = """{"tool":"$toolName","parameters":$parameters,"success":true,""" +
            """"data":$data,"error":null,"v":1}""",
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        toolName = toolName,
        toolCallId = "call_$id",
        finishReason = ChatMessage.FINISH_REASON_TOOL,
    )

    private fun render(
        state: ChatUiState,
        onAnswer: (QuestionAnswer) -> Unit = {},
    ) {
        compose.setContent {
            PabrikTheme {
                ChatView(state = state, onAnswer = onAnswer)
            }
        }
    }

    @Test
    fun aToolRowRendersAsACardNotABubble() {
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    toolRow(
                        "t1",
                        "read_file",
                        """{"path":"/etc/hosts","content":"127.0.0.1 localhost\n"}""",
                    ),
                ),
            ),
        )

        compose.onNodeWithTag("chat_tool_t1").assertIsDisplayed()
        // The old rendering: a bubble carrying the tool name as a caption and
        // the raw envelope as its body.
        compose.onAllNodesWithTag("chat_message_t1").assertCountEquals(0)
    }

    @Test
    fun aCardIsCollapsedUntilItIsTapped() {
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    toolRow("t1", "read_file", """{"path":"/x","content":"hello\n"}"""),
                ),
            ),
        )

        compose.onAllNodesWithTag("read_file_body").assertCountEquals(0)

        compose.onNodeWithTag("tool_card_name").performClick()

        compose.onNodeWithTag("read_file_body").assertIsDisplayed()
    }

    @Test
    fun theHeaderNamesTheToolAndItsArgument() {
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    toolRow("t1", "read_file", """{"path":"/etc/hosts","content":"x"}"""),
                ),
            ),
        )

        compose.onNodeWithTag("tool_card_name").assertIsDisplayed()
        compose.onNodeWithText("/etc/hosts", substring = true).assertIsDisplayed()
    }

    /**
     * The one bit of state a card owns. Hoisted above the `LazyColumn` in
     * `ChatView`, so scrolling a card off screen and back must not close it.
     */
    @Test
    fun anExpandedCardStaysOpen() {
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    toolRow("t1", "read_file", """{"path":"/a","content":"aaa\n"}"""),
                    toolRow("t2", "read_file", """{"path":"/b","content":"bbb\n"}"""),
                ),
            ),
        )

        compose.onAllNodesWithTag("tool_card_chevron")[0].performClick()
        compose.onAllNodesWithTag("read_file_body").assertCountEquals(1)

        // The other card is independent, so tapping its own chevron must not
        // disturb the first.
        compose.onAllNodesWithTag("tool_card_chevron")[1].performClick()
        compose.onAllNodesWithTag("read_file_body").assertCountEquals(2)
    }

    @Test
    fun aStillRunningCardSaysSoAndTakesItsPathFromTheArguments() {
        // The placeholder row has no result at all, so the path can only come
        // from `parameters`. Without it the card reads "unknown" for the whole
        // time the tool takes.
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    ChatMessage(
                        id = "t1",
                        role = ChatMessage.ROLE_TOOL,
                        content = """{"tool":"bash","parameters":{"command":"sleep 30"},""" +
                            """"success":true,"data":null,"error":null,"v":1}""",
                        createdAtEpochMillis = 0L,
                        sortKeyNanos = 0L,
                        toolName = "bash",
                    ),
                ),
            ),
        )

        compose.onNodeWithTag("tool_card_running").assertIsDisplayed()
        compose.onNodeWithText("sleep 30", substring = true).assertIsDisplayed()
    }

    @Test
    fun aFailingCardShowsItsError() {
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    ChatMessage(
                        id = "t1",
                        role = ChatMessage.ROLE_TOOL,
                        content = """{"tool":"read_file","parameters":{"path":"/nope"},""" +
                            """"success":false,"data":null,"error":"No such file","v":1}""",
                        createdAtEpochMillis = 0L,
                        sortKeyNanos = 0L,
                        toolName = "read_file",
                    ),
                ),
            ),
        )

        compose.onNodeWithTag("tool_card_chevron").performClick()
        compose.onNodeWithTag("tool_card_error").assertIsDisplayed()
        compose.onNodeWithText("No such file", substring = true).assertIsDisplayed()
    }

    /**
     * A diff is the one body with real layout, and the gutter is the part that
     * silently drifts: line numbers that do not line up with their text read as
     * corruption rather than as an off-by-one.
     */
    @Test
    fun aTextReplaceCardDrawsADiff() {
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    toolRow(
                        "t1",
                        "text_replace",
                        """{"path":"/x","before":"a\nb\n","after":"a\nc\n",
                           "lines_changed":1}""",
                    ),
                ),
            ),
        )

        compose.onNodeWithTag("tool_card_chevron").performClick()
        compose.onNodeWithTag("diff_view").assertIsDisplayed()
        compose.onNodeWithText("b", substring = true).assertIsDisplayed()
        compose.onNodeWithText("c", substring = true).assertIsDisplayed()
    }

    /**
     * A call with no result yet is the only thing drawing that call, so it gets
     * a header — and nothing else. No bubble: the row says "I am going to call
     * this", which is not something worth a message.
     *
     * The paired half is in `ChatViewTest`: once the result lands, this header
     * disappears, because the card already shows the same call.
     */
    @Test
    fun anUnansweredToolCallRendersAsASummary() {
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    ChatMessage(
                        id = "a1",
                        role = ChatMessage.ROLE_ASSISTANT,
                        // The body is empty on such a turn; only the call list
                        // says anything happened.
                        content = "",
                        createdAtEpochMillis = 0L,
                        sortKeyNanos = 0L,
                        toolName = "read_file,write_file",
                        finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
                        toolCallsJson = """[{"id":"c1","type":"function",""" +
                            """"function":{"name":"read_file","arguments":"{\"path\":\"/x\"}"}}]""",
                    ),
                ),
            ),
        )

        compose.onNodeWithTag("tool_call_summary").assertIsDisplayed()
        compose.onNodeWithText("1 TOOL").assertIsDisplayed()
        compose.onAllNodesWithTag("chat_message_a1").assertCountEquals(0)
    }

    @Test
    fun aPendingQuestionStartsOpenAndCanBeAnswered() {
        val answers = mutableListOf<QuestionAnswer>()
        render(
            state = ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    toolRow(
                        "t1",
                        "ask_user",
                        """{"status":"pending","question_id":"q1",
                           "question":"Which database?","answer":null,
                           "answers_count":0,"header":null,"allow_free_text":true,
                           "multi_select":false,"recommended":null,
                           "options":["postgres","sqlite"],"instruction":null}""",
                    ),
                ),
            ),
            onAnswer = { answers.add(it) },
        )

        // `ask_user` ends the run, so this card defaults to open — a collapsed
        // blocking question is a chat that looks hung.
        compose.onNodeWithTag("question_text").assertIsDisplayed()
        compose.onNodeWithTag("question_blocked_note").assertIsDisplayed()
        // Nothing selected yet, so the send affordance does nothing.
        compose.onNodeWithTag("question_send").assertIsNotEnabled()

        compose.onAllNodesWithTag("question_option")[0].performClick()
        compose.onNodeWithTag("question_send").performClick()

        assertEquals(1, answers.size)
        assertEquals("q1", answers[0].questionId)
        assertEquals("call_t1", answers[0].toolCallId)
        assertEquals("postgres", answers[0].answer)
        assertTrue(!answers[0].skip)
    }

    @Test
    fun aQuestionCanBeSkipped() {
        val answers = mutableListOf<QuestionAnswer>()
        render(
            state = ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    toolRow(
                        "t1",
                        "ask_user",
                        """{"status":"pending","question_id":"q1",
                           "question":"Which database?","answer":null,
                           "answers_count":0,"header":null,"allow_free_text":true,
                           "multi_select":false,"recommended":null,
                           "options":["postgres","sqlite"],"instruction":null}""",
                    ),
                ),
            ),
            onAnswer = { answers.add(it) },
        )

        compose.onNodeWithTag("question_skip").performClick()

        assertEquals(1, answers.size)
        assertTrue(answers[0].skip)
    }

    @Test
    fun anAnsweredQuestionIsReadOnly() {
        render(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    toolRow(
                        "t1",
                        "ask_user",
                        """{"status":"answered","question_id":"q1",
                           "question":"Which database?","answer":"sqlite",
                           "answers_count":1,"header":null,"allow_free_text":true,
                           "multi_select":false,"recommended":null,
                           "options":["postgres","sqlite"],"instruction":null}""",
                    ),
                ),
            ),
        )

        compose.onNodeWithTag("question_text").assertIsDisplayed()
        // Offering an answer to a settled question would post a second one, and
        // the endpoint would silently return the stored status.
        compose.onAllNodesWithTag("question_send").assertCountEquals(0)
    }
}
