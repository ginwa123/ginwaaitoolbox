package com.nalar.mobile.chat

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The composer, rendered.
 *
 * The layout questions — is the strip above the text, is there one stop rather
 * than a stop and a send, does the paperclip go quiet at the cap — are
 * questions about a rendered tree, and a tree is what
 * `createComposeRule` under Robolectric gives us on a box with no device
 * attached. This is the same trick `NalarNavGraphLaunchGateTest` uses.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w390dp-h844dp")
class ChatComposerTest {

    @get:Rule
    val compose = createComposeRule()

    private fun render(
        draft: String = "",
        attachments: List<ChatAttachment> = emptyList(),
        isSending: Boolean = false,
        isAttaching: Boolean = false,
        isWorking: Boolean = false,
        model: String = "space bunny free",
        cwd: String = "/home/ginwa/ginwaaitoolbox",
        onDraftChanged: (String) -> Unit = {},
        onAttach: () -> Unit = {},
        onRemoveAttachment: (String) -> Unit = {},
        onSend: () -> Unit = {},
        onStop: () -> Unit = {},
    ) {
        compose.setContent {
            NalarTheme {
                ChatComposer(
                    draft = draft,
                    attachments = attachments,
                    isSending = isSending,
                    isAttaching = isAttaching,
                    isWorking = isWorking,
                    model = model,
                    cwd = cwd,
                    onDraftChanged = onDraftChanged,
                    onAttach = onAttach,
                    onRemoveAttachment = onRemoveAttachment,
                    onSend = onSend,
                    onStop = onStop,
                )
            }
        }
    }

    // --- Typing ------------------------------------------------------------

    @Test
    fun theFieldTakesWhatWasTyped() {
        var draft = ""
        compose.setContent {
            NalarTheme {
                ChatComposer(
                    draft = draft,
                    attachments = emptyList(),
                    isSending = false,
                    isAttaching = false,
                    isWorking = false,
                    model = "",
                    cwd = "",
                    onDraftChanged = { draft = it },
                    onAttach = {},
                    onRemoveAttachment = {},
                    onSend = {},
                    onStop = {},
                )
            }
        }

        compose.onNodeWithTag("chat_composer_input").performTextInput("do the thing")
        compose.waitForIdle()

        assertEquals("do the thing", draft)
    }

    // --- Send / stop -------------------------------------------------------

    @Test
    fun sendIsDisabledWithNothingToSend() {
        render()
        compose.onNodeWithTag("chat_send").assertIsNotEnabled()
    }

    @Test
    fun anImageWithNoTextIsSomethingToSend() {
        render(attachments = listOf(attachment("a1")))
        compose.onNodeWithTag("chat_send").assertIsEnabled()
    }

    @Test
    fun anInFlightSendDisablesTheButtonAgain() {
        render(draft = "hello", isSending = true)
        compose.onNodeWithTag("chat_send").assertIsNotEnabled()
    }

    @Test
    fun aRunReplacesTheSendWithTheStop() {
        // One slot, two controls. Both on screen at once tells the reader the
        // app does not know whether a run is going.
        render(draft = "hello", isWorking = true)

        compose.onNodeWithTag("chat_stop").assertIsDisplayed()
        compose.onNodeWithTag("chat_send").assertDoesNotExist()
    }

    @Test
    fun theStopFiresTheStopAndNotASend() {
        var stopped = 0
        var sent = 0
        render(draft = "hello", isWorking = true, onStop = { stopped++ }, onSend = { sent++ })

        compose.onNodeWithTag("chat_stop").performClick()
        compose.waitForIdle()

        assertEquals(1, stopped)
        assertEquals(0, sent)
    }

    // --- Attachments -------------------------------------------------------

    @Test
    fun noStripIsComposedWithNothingAttached() {
        render()
        compose.onNodeWithTag("chat_attachments_strip").assertDoesNotExist()
    }

    @Test
    fun eachAttachedImageGetsItsOwnRow() {
        render(attachments = listOf(attachment("a1"), attachment("a2")))

        compose.onNodeWithTag("chat_attachment_a1").assertIsDisplayed()
        compose.onNodeWithTag("chat_attachment_a2").assertIsDisplayed()
    }

    @Test
    fun removingAnImageReportsWhichOne() {
        var removed = ""
        render(
            attachments = listOf(attachment("a1"), attachment("a2")),
            onRemoveAttachment = { removed = it },
        )

        compose.onNodeWithTag("chat_attachment_remove_a2").performClick()
        compose.waitForIdle()

        assertEquals("a2", removed)
    }

    @Test
    fun thePaperclipOpensThePicker() {
        var opened = 0
        render(onAttach = { opened++ })

        compose.onNodeWithTag("chat_attach").performClick()
        compose.waitForIdle()

        assertEquals(1, opened)
    }

    @Test
    fun thePaperclipIsRefusedWhileADecodeIsRunning() {
        // Without this the reader taps it a second time on a quarter-second
        // delay and picks the same photo twice.
        var opened = 0
        render(isAttaching = true, onAttach = { opened++ })

        compose.onNodeWithTag("chat_attach").assertIsNotEnabled()
        compose.onNodeWithTag("chat_attach").performClick()
        compose.waitForIdle()

        assertEquals(0, opened)
    }

    @Test
    fun thePaperclipIsRefusedOnceTheTurnIsFull() {
        render(
            attachments = (1..ChatAttachments.MAX_COUNT).map { attachment("a$it") },
        )

        compose.onNodeWithTag("chat_attach").assertIsNotEnabled()
    }

    // --- The footer --------------------------------------------------------

    @Test
    fun theFooterStatesTheTurnsFacts() {
        render(model = "space bunny free", cwd = "/home/ginwa/ginwaaitoolbox")

        compose.onNodeWithTag("chat_footer_model").assertIsDisplayed()
        compose.onNodeWithTag("chat_footer_cwd").assertIsDisplayed()
    }

    @Test
    fun aFactWithNoValueIsNotRendered() {
        // A footer showing "Model" with nothing after it is a label for a
        // control that is not there.
        render(model = "", cwd = "")

        compose.onNodeWithTag("chat_footer_model").assertDoesNotExist()
        compose.onNodeWithTag("chat_footer_cwd").assertDoesNotExist()
    }

    @Test
    fun thereIsNoExpanderWhenThereIsNothingToExpand() {
        // A chevron that toggles one line when both lines already show is a
        // control that does nothing.
        render(cwd = "")

        compose.onNodeWithTag("chat_footer_expand").assertDoesNotExist()
    }

    @Test
    fun theExpanderIsThereWhenThereIsACwd() {
        render(cwd = "/home/ginwa/ginwaaitoolbox")

        compose.onNodeWithTag("chat_footer_expand").assertIsDisplayed()
    }

    // --- Test helpers ------------------------------------------------------

    private fun attachment(id: String) = ChatAttachment(
        id = id,
        mimeType = ChatAttachments.STORED_MIME,
        byteCount = 64,
        // Not a decodable image on purpose: this file is about the composer's
        // rules, and a real thumbnail would make every test a bitmap decode.
        dataUrl = ChatAttachments.dataUrl(ChatAttachments.STORED_MIME, ByteArray(64) { 1 }),
    )
}
