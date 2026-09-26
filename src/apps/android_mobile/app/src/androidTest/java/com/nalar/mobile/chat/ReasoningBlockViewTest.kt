package com.nalar.mobile.chat

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.nalar.mobile.ui.NalarTheme
import org.junit.Rule
import org.junit.Test

/**
 * The reasoning fold, as drawn.
 *
 * The unit tests pin which turns draw it; only a composed tree can show the
 * three things that actually broke before. That it starts **closed** — the
 * stated default, and the reason reasoning was unreadable on a phone: rendered
 * flat, a chain of thought is a wall of monospace between the reader and the
 * answer. That tapping the header opens and closes it. And that the fold sits
 * *above* the answer rather than after it, the order the web reads in.
 */
class ReasoningBlockViewTest {

    @get:Rule
    val compose = createComposeRule()

    private fun assistantTurn(
        id: String = "m1",
        content: String = "Here is the answer.",
        reasoning: String = "First I weigh the options, then I pick one.",
    ) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_ASSISTANT,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        reasoningContent = reasoning,
    )

    private fun render(messages: List<ChatMessage>) {
        compose.setContent {
            NalarTheme {
                ChatView(
                    state = ChatUiState(
                        sessionId = "s",
                        isLoading = false,
                        messages = messages,
                    ),
                )
            }
        }
    }

    @Test
    fun theFoldIsClosedByDefault() {
        render(listOf(assistantTurn()))

        compose.onNodeWithTag("chat_reasoning_header_m1").assertIsDisplayed()
        // The default. The reasoning text is not on the tree at all when the
        // fold is closed — not merely clipped — so a collapsed turn costs
        // nothing to lay out.
        compose.onAllNodesWithTag("chat_reasoning_body_m1").assertCountEquals(0)
    }

    @Test
    fun tappingTheHeaderOpensTheReasoning() {
        render(listOf(assistantTurn()))

        compose.onNodeWithTag("chat_reasoning_header_m1").performClick()

        compose.onNodeWithTag("chat_reasoning_body_m1").assertIsDisplayed()
        compose.onNodeWithText("First I weigh the options, then I pick one.").assertIsDisplayed()
    }

    @Test
    fun tappingTheHeaderAgainClosesIt() {
        render(listOf(assistantTurn()))

        compose.onNodeWithTag("chat_reasoning_header_m1").performClick()
        compose.onNodeWithTag("chat_reasoning_header_m1").performClick()

        compose.onAllNodesWithTag("chat_reasoning_body_m1").assertCountEquals(0)
    }

    /**
     * The header is the only affordance, so it has to survive collapsed — an
     * answer sitting under an unexplained gap is how this shipped the first
     * time, when the reasoning was drawn flat with nothing to tap.
     */
    @Test
    fun theAnswerIsStillVisibleWhileTheFoldIsClosed() {
        render(listOf(assistantTurn()))

        compose.onNodeWithTag("chat_body_m1").assertIsDisplayed()
        compose.onNodeWithText("Thought").assertIsDisplayed()
    }

    @Test
    fun aTurnWithoutReasoningHasNoFold() {
        render(listOf(assistantTurn(reasoning = "")))

        compose.onAllNodesWithTag("chat_reasoning_m1").assertCountEquals(0)
        compose.onNodeWithTag("chat_body_m1").assertIsDisplayed()
    }

    /** Two turns, two independent folds — opening one must not open the other. */
    @Test
    fun foldsAreIndependentPerTurn() {
        render(
            listOf(
                assistantTurn(id = "m1", content = "First answer."),
                assistantTurn(id = "m2", content = "Second answer."),
            ),
        )

        compose.onNodeWithTag("chat_reasoning_header_m1").performClick()

        compose.onNodeWithTag("chat_reasoning_body_m1").assertIsDisplayed()
        compose.onAllNodesWithTag("chat_reasoning_body_m2").assertCountEquals(0)
    }

    @Test
    fun aReasoningOnlyTurnStillRenders() {
        // A thinking model can emit reasoning and no final text. The turn has
        // to stay on screen — a collapsed fold is still something to open.
        render(listOf(assistantTurn(content = "", reasoning = "Still thinking.")))

        compose.onNodeWithTag("chat_reasoning_header_m1").assertIsDisplayed()

        compose.onNodeWithTag("chat_reasoning_header_m1").performClick()

        compose.onNodeWithText("Still thinking.").assertIsDisplayed()
    }
}
