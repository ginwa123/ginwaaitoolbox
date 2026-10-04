package com.pabrik.mobile.projects

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

/**
 * The board's "New task" form, as a window.
 *
 * This file exists because of one bug. The form was a platform `Dialog` opened
 * with `usePlatformDefaultWidth = false`, and compose-ui sizes such a window
 * from `Configuration.screenHeightDp` — the whole display, system bars
 * included — before calling `window.setLayout()` with the child's measured size
 * (`DialogLayout.internalOnMeasure` / `internalOnLayout`). A `fillMaxSize()`
 * surface therefore filled the raw display, and the pinned commit row at the
 * bottom of the form was drawn underneath the navigation bar: "▶ Create task &
 * run agent" was cut in half by the screen edge, so the control the whole form
 * exists for could neither be read nor tapped.
 *
 * Robolectric has no system bars and no window manager to clip against, so it
 * cannot reproduce the visible symptom. What it *can* hold is the cause: the
 * form must not open a platform dialog window at all, and its commit row must
 * live inside the composition root rather than at its edge. The insets-aware
 * half of the contract — the commit row clearing the real navigation bar —
 * needs real bars and is asserted on a device in
 * `NewTaskDialogDeviceLayoutTest`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w411dp-h891dp")
class NewTaskDialogLayoutTest {

    @get:Rule
    val compose = createComposeRule()

    private var submitted: KanbanTaskForm? = null
    private var closed = false

    private fun render(
        isSubmitting: Boolean = false,
        errorMessage: String? = null,
    ) {
        compose.setContent {
            PabrikTheme {
                NewTaskDialog(
                    projectName = "sprint board",
                    defaultCwd = "/home/ginwa/ginwaaitoolbox",
                    data = NewTaskDialogData(
                        columns = listOf(KanbanColumn("col-1", "todo", 0)),
                    ),
                    isSubmitting = isSubmitting,
                    errorMessage = errorMessage,
                    onSubmit = { submitted = it },
                    onClose = { closed = true },
                )
            }
        }
    }

    /**
     * The regression itself, stated as the cause rather than the symptom.
     *
     * `ShadowDialog` is the honest witness on a box with no bars: a dialog
     * window is a `Dialog` no matter which insets it managed to read, so a form
     * that still opens one has kept the sizing bug even if a test device without
     * a navigation bar happens not to show it.
     */
    @Test
    fun the_form_does_not_open_a_platform_dialog_window() {
        render()

        assertNull(
            "the form must be drawn in the activity's composition, not a Dialog " +
                "window — see the class doc for why that word is load-bearing",
            ShadowDialog.getLatestDialog(),
        )
    }

    /**
     * "Where is the Run agent button?" — the complaint this fixes.
     *
     * Asserted on geometry rather than on existence: a button the reader cannot
     * see is still in the tree, so `assertIsDisplayed` on its own would pass
     * against the clipped layout that caused this.
     */
    @Test
    fun the_commit_row_sits_inside_the_window_with_room_to_spare() {
        render()

        val root = compose.onRoot().getUnclippedBoundsInRoot()
        val commit = compose.onNodeWithTag("create_task_create_and_run")
            .getUnclippedBoundsInRoot()

        assertTrue(
            "commit row starts at $commit but the form is $root",
            commit.left >= root.left && commit.right <= root.right,
        )
        assertTrue(
            "commit row runs off the bottom of the window: $commit in $root",
            commit.bottom <= root.bottom,
        )
        compose.onNodeWithTag("create_task_create_and_run").assertIsDisplayed()
    }

    /**
     * The button stays disabled until there is something to create, then arms.
     *
     * Asserted through the semantics action rather than an injected tap:
     * under Robolectric a touch on this particular button never reaches its
     * handler — reproducible on unmodified `origin/main`, so it predates this
     * change — while the caret beside it, Cancel and Back all take taps. Whether
     * that survives on real touch is
     * [NewTaskDialogDeviceLayoutTest.the_run_agent_button_commits_with_runAgent_set]'s
     * job, and rewriting the button to make a JVM test green is not a fix.
     */
    @Test
    fun the_run_agent_button_arms_once_the_form_has_a_name() {
        render()

        compose.onNodeWithTag("create_task_create_and_run").assertIsNotEnabled()
        compose.onNodeWithTag("create_task_name").performTextInput("ship the drawer")
        compose.waitForIdle()

        compose.onNodeWithTag("create_task_create_and_run").assertIsEnabled()
        compose.onNodeWithTag("create_task_create_and_run")
            .performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        assertEquals(true, submitted?.runAgent)
        assertEquals("ship the drawer", submitted?.name)
    }

    /** The caret's "Create task only" is the other half of the split button. */
    @Test
    fun the_caret_offers_create_task_only() {
        render()

        compose.onNodeWithTag("create_task_name").performTextInput("just a card")
        compose.waitForIdle()
        compose.onNodeWithTag("create_task_commit_menu").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("create_task_create_only").performClick()
        compose.waitForIdle()

        assertEquals(false, submitted?.runAgent)
    }

    @Test
    fun back_and_close_both_leave_the_form() {
        render()

        compose.onNodeWithTag("create_task_back").performClick()
        compose.waitForIdle()

        assertTrue("Back must leave the form now that it owns the window", closed)
    }

    /**
     * A failed create keeps the form open with what was typed still in it, and
     * the banner has to stay above the scroll rather than at the bottom of it.
     */
    @Test
    fun a_failed_create_keeps_the_form_open_with_its_error_visible() {
        render(errorMessage = "The server refused the create.")

        compose.onNodeWithTag("create_task_error").assertIsDisplayed()
        compose.onNodeWithTag("create_task_name").assertIsDisplayed()
        assertTrue("a failed create must not close the form", !closed)
    }
}
