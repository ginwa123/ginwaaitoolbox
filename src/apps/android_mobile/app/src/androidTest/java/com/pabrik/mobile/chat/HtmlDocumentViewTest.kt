package com.pabrik.mobile.chat

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/**
 * The document turn, on a device.
 *
 * `HtmlResponseTest` pins the split — which is pure, and is the whole of the
 * bug. What it cannot reach is the wiring: that a turn which *is* a document
 * reaches the frame, and a turn which is not reaches markdown. Getting that
 * backwards is invisible to every JVM test in the module, because both paths
 * still produce a row.
 *
 * So the assertions are about the frame existing at all, not about what is
 * painted inside it. A `WebView`'s pixels are not reachable from a Compose
 * test, and asserting on them would be a test that passes on an emulator with
 * one renderer and fails on a device with another.
 */
class HtmlDocumentViewTest {

    @get:Rule
    val compose = createComposeRule()

    /**
     * The reported session: a `web-framework-html-benchmark` turn, which
     * arrives wrapped and opens with a stylesheet.
     */
    private val benchmarkTurn =
        "<html><head><style>.bmw-wrap{background:#1D1C19;color:#c5c9c5}</style></head>" +
            "<body><main class=\"bmw-wrap\"><h1>BMW M4 Competition</h1></main></body></html>"

    private fun show(content: String, streaming: Boolean = false) {
        val message = mutableStateOf(
            ChatMessage(
                id = "m1",
                role = ChatMessage.ROLE_ASSISTANT,
                content = content,
                createdAtEpochMillis = 0L,
                sortKeyNanos = 0L,
                isStreaming = streaming,
            ),
        )
        // `setContent` may be called once per rule, so the turn is held in
        // state and swapped in place — the same thing the SSE stream does to a
        // live turn, which is the transition under test.
        compose.setContent {
            PabrikTheme {
                ChatView(
                    state = ChatUiState(
                        sessionId = "s1",
                        isLoading = false,
                        messages = listOf(message.value),
                    ),
                )
            }
        }
    }

    private fun frameCount(): Int =
        compose.onAllNodesWithTag("chat_html_frame").fetchSemanticsNodes().size

    @Test
    fun aDocumentTurnIsDrawnInAFrame() {
        show(benchmarkTurn)

        compose.onNodeWithTag("chat_html_frame").assertIsDisplayed()
    }

    @Test
    fun aDocumentTurnDoesNotShowItsOwnSource() {
        // The screenshot this replaces: the transcript showed the reader the
        // literal `<style>bmw-wrap{font-family:ui-sans-system…` instead of the
        // page. If the source is on screen as text, the split did not happen
        // and the frame is being drawn *as well as* the text.
        show(benchmarkTurn)

        compose.onNodeWithText("bmw-wrap{font-family", substring = true)
            .assertDoesNotExist()
    }

    @Test
    fun aDocumentTurnKeepsTheProseAroundIt() {
        show("Here is the page.\n$benchmarkTurn")

        compose.onNodeWithText("Here is the page.").assertIsDisplayed()
        compose.onNodeWithTag("chat_html_frame").assertIsDisplayed()
    }

    @Test
    fun anOrdinaryAnswerDrawsNoFrame() {
        show("## What I built\n\nMoved the card.")

        compose.onNodeWithTag("chat_html_frame").assertDoesNotExist()
        compose.onNodeWithTag("markdown").assertIsDisplayed()
    }

    @Test
    fun aDocumentStillStreamingDrawsNoFrame() {
        // The per-delta cost this guards. A `WebView` is a real `View` with a
        // real JS engine, and reloading one on every appended delta is a
        // re-layout and a re-parse per frame. While the turn is arriving it
        // stays prose, which streams in as text and costs nothing.
        show("<html><body><main><h1>Half a pag", streaming = true)

        assertEquals(0, frameCount())
    }

    @Test
    fun theSameTurnDrawsAFrameOnceItStopsStreaming() {
        val live = mutableStateOf(
            ChatMessage(
                id = "m1",
                role = ChatMessage.ROLE_ASSISTANT,
                content = "<html><body><main><h1>Half a pag",
                createdAtEpochMillis = 0L,
                sortKeyNanos = 0L,
                isStreaming = true,
            ),
        )
        compose.setContent {
            PabrikTheme {
                ChatView(
                    state = ChatUiState(
                        sessionId = "s1",
                        isLoading = false,
                        messages = listOf(live.value),
                    ),
                )
            }
        }
        assertEquals(0, frameCount())

        // The turn finishes: the same row, the same id, no longer streaming.
        live.value = live.value.copy(
            content = "<html><body><main><h1>Half a page</h1></main></body></html>",
            isStreaming = false,
        )
        compose.waitForIdle()

        assertEquals(1, frameCount())
    }

    @Test
    fun pastTheFrameBudgetTheRestFallsBackToText() {
        val blocks = (1..HtmlResponse.MAX_LIVE_FRAMES + 1).joinToString("") {
            "<html><body><h1>Block $it</h1></body></html>"
        }
        show(blocks)

        // Three frames, not four. The budget is a real limit: a `LazyColumn`
        // composing more live `WebView`s than this is a memory cliff on a
        // phone, and a block past the budget is far better as text than as a
        // page that silently never appears.
        assertEquals(HtmlResponse.MAX_LIVE_FRAMES, frameCount())
    }
}
