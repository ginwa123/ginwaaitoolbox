package com.pabrik.mobile.chat

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.pabrik.mobile.ui.PabrikTheme
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
 * attached. This is the same trick `PabrikNavGraphLaunchGateTest` uses.
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
        queuedMessages: List<QueuedChatMessage> = emptyList(),
        onRefreshQueue: () -> Unit = {},
        onUseQueuedMessage: (QueuedChatMessage) -> Unit = {},
    ) {
        compose.setContent {
            PabrikTheme {
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
                    queuedMessages = queuedMessages,
                    onRefreshQueue = onRefreshQueue,
                    onUseQueuedMessage = onUseQueuedMessage,
                )
            }
        }
    }

    // --- Typing ------------------------------------------------------------

    @Test
    fun theFieldTakesWhatWasTyped() {
        var draft = ""
        compose.setContent {
            PabrikTheme {
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

    // --- Queue -------------------------------------------------------------

    @Test
    fun aRunWithSomethingTypedOffersAQueueBesideTheStop() {
        // The gap this closes. Before it, a reader watching a three-minute
        // tool call had exactly one way to act on a follow-up thought: stop the
        // run and throw the work away.
        render(draft = "and then open a PR", isWorking = true)

        compose.onNodeWithTag("chat_queue").assertIsDisplayed()
        compose.onNodeWithTag("chat_stop").assertIsDisplayed()
        // Still one slot for the run's lifetime: send is not offered as well.
        compose.onNodeWithTag("chat_send").assertDoesNotExist()
    }

    @Test
    fun theQueueSendsTheTurnRatherThanStoppingTheRun() {
        // Same callback as the send button, because the server decides: a live
        // worker takes the message into `session_queue_messages`
        // (`workflow.zig:688`) and drains it when it finishes. A separate
        // "queue" endpoint would be a second wire contract for one action.
        var sent = 0
        var stopped = 0
        render(
            draft = "and then open a PR",
            isWorking = true,
            onSend = { sent++ },
            onStop = { stopped++ },
        )

        compose.onNodeWithTag("chat_queue").performClick()
        compose.waitForIdle()

        assertEquals(1, sent)
        assertEquals(0, stopped)
    }

    @Test
    fun anIdleChatHasNoQueueButton() {
        // With no run in progress the same tap starts a turn, and the send
        // button already says exactly that. Two controls for one action is a
        // control the reader has to think about.
        render(draft = "hello", isWorking = false)

        compose.onNodeWithTag("chat_queue").assertDoesNotExist()
        compose.onNodeWithTag("chat_send").assertIsDisplayed()
    }

    @Test
    fun thereIsNoQueueButtonOverAnEmptyBox() {
        // A queue button that cannot do anything teaches the reader the
        // composer is decoration. This is the same rule the model chip and the
        // cwd expander are held to.
        render(draft = "", isWorking = true)

        compose.onNodeWithTag("chat_queue").assertDoesNotExist()
    }

    @Test
    fun anImageWithNoTextIsSomethingToQueue() {
        render(attachments = listOf(attachment("a1")), isWorking = true)

        compose.onNodeWithTag("chat_queue").assertIsDisplayed()
    }

    @Test
    fun theQueueIsInertWhileASendIsInFlight() {
        render(draft = "hello", isWorking = true, isSending = true)

        compose.onNodeWithTag("chat_queue").assertDoesNotExist()
    }

    @Test
    fun anEmptyQueueDrawsNoStrip() {
        // The reader is in this state on almost every turn, and a permanent
        // "0 queued" would be telling them there is nothing on the one row
        // where something else might be.
        render(isWorking = true)

        compose.onNodeWithTag("chat_queued_strip").assertDoesNotExist()
    }

    @Test
    fun theStripNamesHowManyTurnsAreWaiting() {
        render(
            isWorking = true,
            queuedMessages = listOf(
                QueuedChatMessage("q1", "then run the tests"),
                QueuedChatMessage("q2", "and open a PR"),
            ),
        )

        compose.onNodeWithTag("chat_queued_strip").assertIsDisplayed()
        compose.onNodeWithText("2 queued").assertExists()
    }

    @Test
    fun theListIsClosedUntilItIsAskedFor() {
        render(isWorking = true, queuedMessages = listOf(QueuedChatMessage("q1", "then run the tests")))

        compose.onNodeWithTag("chat_queued_panel").assertDoesNotExist()

        compose.onNodeWithTag("chat_queued_toggle").performClick()
        compose.waitForIdle()

        compose.onNodeWithTag("chat_queued_panel").assertIsDisplayed()
        compose.onNodeWithTag("chat_queued_q1").assertIsDisplayed()
    }

    @Test
    fun openingTheListReReadsTheServer() {
        // The rows on screen are built from SSE frames the reader can watch
        // arrive; one that was drained while the socket was down would still be
        // listed, and tapping it would have them compose a duplicate of a turn
        // the agent is already answering.
        var refreshed = 0
        render(
            isWorking = true,
            queuedMessages = listOf(QueuedChatMessage("q1", "then run the tests")),
            onRefreshQueue = { refreshed++ },
        )

        compose.onNodeWithTag("chat_queued_toggle").performClick()
        compose.waitForIdle()

        assertEquals(1, refreshed)
    }

    @Test
    fun closingTheListDoesNotReReadIt() {
        var refreshed = 0
        render(
            isWorking = true,
            queuedMessages = listOf(QueuedChatMessage("q1", "then run the tests")),
            onRefreshQueue = { refreshed++ },
        )

        compose.onNodeWithTag("chat_queued_toggle").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("chat_queued_toggle").performClick()
        compose.waitForIdle()

        assertEquals(1, refreshed)
    }

    @Test
    fun tappingAQueuedTurnReportsWhichOne() {
        var used: QueuedChatMessage? = null
        render(
            isWorking = true,
            queuedMessages = listOf(
                QueuedChatMessage("q1", "then run the tests"),
                QueuedChatMessage("q2", "and open a PR"),
            ),
            onUseQueuedMessage = { used = it },
        )

        compose.onNodeWithTag("chat_queued_toggle").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("chat_queued_q2").performClick()
        compose.waitForIdle()

        assertEquals("q2", used?.id)
        assertEquals("and open a PR", used?.message)
    }

    @Test
    fun aQueuedTurnWithNoTextStillHasSomethingOnItsRow() {
        // The client sends `image_urls` on the same POST as `queue_message`,
        // and Migration 054 made the column nullable so those rows exist. A
        // blank row is a row the reader cannot aim at.
        render(
            isWorking = true,
            queuedMessages = listOf(QueuedChatMessage("q1", "")),
        )

        compose.onNodeWithTag("chat_queued_toggle").performClick()
        compose.waitForIdle()

        compose.onNodeWithText("Image only").assertExists()
    }

    @Test
    fun theCountIsSingularForOne() {
        // Split out of the composable so the plural has a rule with a test
        // rather than an inline `if` nobody re-runs.
        assertEquals("1 queued", queuedLabel(1))
        assertEquals("0 queued", queuedLabel(0))
        assertEquals("3 queued", queuedLabel(3))
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
