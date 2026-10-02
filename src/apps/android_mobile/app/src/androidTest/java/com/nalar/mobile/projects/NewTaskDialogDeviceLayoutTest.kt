package com.nalar.mobile.projects

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The board's "New task" form on a device that has a navigation bar.
 *
 * This is the half of the bug Robolectric cannot see. The form used to be a
 * platform `Dialog` opened with `usePlatformDefaultWidth = false`, which
 * compose-ui measures against the whole display and then resizes its window to
 * the measured child — so the pinned "▶ Create task & run agent" row was drawn
 * underneath the navigation bar and the screen edge cut it in half. A JVM test
 * with no bars passes against that layout; this one reads the real inset and
 * refuses a commit row that does not clear it.
 *
 * Read the inset from the *activity's* window rather than assuming a size: a
 * device with gesture navigation and one with three buttons disagree, and
 * neither is the answer.
 */
@RunWith(AndroidJUnit4::class)
class NewTaskDialogDeviceLayoutTest {

    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private var submitted: KanbanTaskForm? = null

    private fun render() {
        compose.setContent {
            NalarTheme {
                NewTaskDialog(
                    projectName = "sprint board",
                    defaultCwd = "/home/ginwa/ginwaaitoolbox",
                    data = NewTaskDialogData(
                        columns = listOf(KanbanColumn("col-1", "todo", 0)),
                    ),
                    isSubmitting = false,
                    errorMessage = null,
                    onSubmit = { submitted = it },
                    onClose = {},
                )
            }
        }
    }

    @Test
    fun the_commit_row_clears_the_navigation_bar() {
        render()

        val density = compose.activity.resources.displayMetrics.density
        val root = compose.onRoot().getUnclippedBoundsInRoot()
        val commit = compose.onNodeWithTag("create_task_create_and_run")
            .getUnclippedBoundsInRoot()

        val navigationBarPx = ViewCompat.getRootWindowInsets(
            compose.activity.window.decorView,
        )?.getInsets(WindowInsetsCompat.Type.systemBars())?.bottom ?: 0
        val commitBottomPx = commit.bottom.value * density
        val rootBottomPx = root.bottom.value * density

        assertTrue(
            "commit row bottom ($commitBottomPx px) runs into the navigation bar " +
                "($navigationBarPx px) inside a window of $rootBottomPx px — this is " +
                "the clipped-button bug, back again",
            commitBottomPx <= rootBottomPx - navigationBarPx + 1f,
        )
        compose.onNodeWithTag("create_task_create_and_run").assertIsDisplayed()
    }

    /** The header is the other half of the same inset, at the other end. */
    @Test
    fun the_header_clears_the_status_bar() {
        render()

        val density = compose.activity.resources.displayMetrics.density
        val statusBarPx = ViewCompat.getRootWindowInsets(
            compose.activity.window.decorView,
        )?.getInsets(WindowInsetsCompat.Type.systemBars())?.top ?: 0
        val headerTopPx = compose.onNodeWithTag("create_task_back")
            .getUnclippedBoundsInRoot().top.value * density

        assertTrue(
            "the Back control sits under the status bar ($headerTopPx px < " +
                "$statusBarPx px)",
            headerTopPx >= statusBarPx - 1f,
        )
        compose.onNodeWithTag("create_task_back").assertIsDisplayed()
    }

    /** The button is not merely drawn — it is the thing that starts the agent. */
    @Test
    fun the_run_agent_button_commits_with_runAgent_set() {
        render()

        compose.onNodeWithTag("create_task_name").performTextInput("ship the drawer")
        compose.waitForIdle()
        compose.onNodeWithTag("create_task_create_and_run").assertIsEnabled()
        compose.onNodeWithTag("create_task_create_and_run").performClick()
        compose.waitForIdle()

        assertTrue(
            "the Run agent button did not ask for mode=create_and_run",
            submitted?.runAgent == true,
        )
    }
}
