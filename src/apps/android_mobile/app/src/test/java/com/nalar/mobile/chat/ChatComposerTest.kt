package com.nalar.mobile.chat

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
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
        modelProfiles: List<ModelProfile> = emptyList(),
        activeModel: String? = "space bunny free",
        isSavingModel: Boolean = false,
        onSelectModel: (String) -> Unit = {},
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
                    modelProfiles = modelProfiles,
                    activeModelProfile = activeModel,
                    isSavingModel = isSavingModel,
                    onSelectModel = onSelectModel,
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
        // control that is not there. `activeModel` is nulled too: the chip
        // falls back to the account default, so leaving it set would render a
        // model this test is specifically saying should not be there.
        render(model = "", activeModel = null, cwd = "")

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

    // --- The model picker --------------------------------------------------

    @Test
    fun tappingTheModelOpensThePicker() {
        // The whole point of the change: the `Model` fact used to be text, and
        // tapping it did nothing at all.
        render(modelProfiles = listOf(profile("space bunny free", "gpt-5")))

        compose.onNodeWithTag("chat_model_menu").assertDoesNotExist()
        compose.onNodeWithTag("chat_footer_model").performClick()
        compose.waitForIdle()

        compose.onNodeWithTag("chat_model_menu").assertIsDisplayed()
    }

    @Test
    fun thePickerNamesEveryProfileAndTheDefault() {
        render(
            modelProfiles = listOf(
                profile("space bunny free", "gpt-5"),
                profile("work key", "claude"),
            ),
        )

        compose.onNodeWithTag("chat_footer_model").performClick()
        compose.waitForIdle()

        compose.onNodeWithTag("chat_model_default").assertIsDisplayed()
        compose.onNodeWithTag("chat_model_space bunny free").assertIsDisplayed()
        compose.onNodeWithTag("chat_model_work key").assertIsDisplayed()
    }

    @Test
    fun pickingAProfileReportsItsName() {
        var picked: String? = null
        render(
            modelProfiles = listOf(profile("space bunny free"), profile("work key")),
            onSelectModel = { picked = it },
        )

        compose.onNodeWithTag("chat_footer_model").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("chat_model_work key").performClick()
        compose.waitForIdle()

        assertEquals("work key", picked)
    }

    @Test
    fun theDefaultRowSendsEmptyToClearTheOverride() {
        // The same encoding the `PUT` uses. Anything else would make "Default"
        // mean "the profile called Default".
        var picked: String? = null
        render(
            model = "space bunny free",
            modelProfiles = listOf(profile("space bunny free"), profile("work key")),
            onSelectModel = { picked = it },
        )

        compose.onNodeWithTag("chat_footer_model").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("chat_model_default").performClick()
        compose.waitForIdle()

        assertEquals("", picked)
    }

    @Test
    fun aPickClosesTheMenu() {
        // A menu left open over the transcript after the choice landed is the
        // same menu the reader has to dismiss before reading the answer.
        render(modelProfiles = listOf(profile("space bunny free"), profile("work key")))

        compose.onNodeWithTag("chat_footer_model").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("chat_model_work key").performClick()
        compose.waitForIdle()

        compose.onNodeWithTag("chat_model_work key").assertDoesNotExist()
    }

    @Test
    fun theChipIsInertWhileASaveIsInFlight() {
        // A second pick would race the first, and the winner would be
        // whichever response landed last rather than whichever was tapped.
        var picked: String? = null
        render(
            modelProfiles = listOf(profile("space bunny free"), profile("work key")),
            isSavingModel = true,
            onSelectModel = { picked = it },
        )

        compose.onNodeWithTag("chat_footer_model").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("chat_model_work key").performClick()
        compose.waitForIdle()

        assertEquals(null, picked)
    }

    @Test
    fun withNoProfilesTheChipIsALabelAndOpensNothing() {
        // A menu that opens onto an empty list is a control that teaches the
        // reader the footer is decoration. This is the one case that reaches
        // it: a name to show (the account default) but nothing to choose.
        render(model = "", activeModel = "space bunny free", modelProfiles = emptyList())

        compose.onNodeWithTag("chat_footer_model").assertIsDisplayed()
        compose.onNodeWithTag("chat_footer_model").performClick()
        compose.waitForIdle()

        compose.onNodeWithTag("chat_model_menu").assertDoesNotExist()
    }

    @Test
    fun aChatWithNoProfileAtAllShowsNoModelFact() {
        // No per-session choice and no active default is genuinely nothing to
        // say — a "Model" label with no value is a label for a missing control.
        render(model = "", activeModel = null, cwd = "/home/ginwa/ginwaaitoolbox")

        compose.onNodeWithTag("chat_footer_model").assertDoesNotExist()
        compose.onNodeWithTag("chat_footer_cwd").assertIsDisplayed()
    }

    @Test
    fun aChatWithNoOverrideShowsTheAccountsActiveProfile() {
        // The regression the chip exists to prevent: the raw column is `""`
        // here, but the server will run this chat on the active profile.
        render(model = "", activeModel = "space bunny free")

        compose.onNodeWithTag("chat_footer_model").assertIsDisplayed()
        compose.onNodeWithText("space bunny free").assertIsDisplayed()
    }

    // --- Test helpers ------------------------------------------------------

    private fun profile(name: String, model: String = "gpt-5") =
        ModelProfile(name = name, model = model, baseUrl = "https://api.example/v1")

    private fun attachment(id: String) = ChatAttachment(
        id = id,
        mimeType = ChatAttachments.STORED_MIME,
        byteCount = 64,
        // Not a decodable image on purpose: this file is about the composer's
        // rules, and a real thumbnail would make every test a bitmap decode.
        dataUrl = ChatAttachments.dataUrl(ChatAttachments.STORED_MIME, ByteArray(64) { 1 }),
    )
}
