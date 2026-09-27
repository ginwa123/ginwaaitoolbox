package com.nalar.mobile.recents

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import com.nalar.mobile.projects.ProjectSummary
import com.nalar.mobile.projects.ProjectTypes
import com.nalar.mobile.projects.ProjectsActions
import com.nalar.mobile.projects.ProjectsState
import com.nalar.mobile.shell.MobileDrawerLayout
import com.nalar.mobile.shell.MobileHomeScreen
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The sidebar's two sections, on the JVM.
 *
 * The instrumented `RecentsSidebarTest` and `ProjectsSectionTest` cover these
 * gestures too, but an instrumented test needs an emulator and CI has none, so
 * everything asserted there sat unrun. Under Robolectric the real drawer
 * composes, measures and scrolls, which is the only way to assert the part of
 * this feature that is actually about layout: **the section titles pin while
 * their rows scroll under them.** A unit test that only counted items would
 * pass just as happily for a plain `item` header, which is the bug.
 *
 * A phone-sized screen is pinned explicitly. Robolectric's default viewport is
 * small enough that a 320dp permanent drawer and two section headers do not
 * fit, and "displayed" would then be answering a layout-arithmetic question
 * instead of the one this file is asking.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class RecentsSidebarSectionsTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L
    private val workspaces = listOf(WorkspaceOption("workspace-a", "Workspace A"))
    private val chats = (1..3).map { index ->
        ChatSummary("chat-a$index", "workspace-a", "Chat $index", now - index * 60_000L)
    }

    private fun oneProject() = ProjectsState(
        expanded = true,
        items = listOf(
            ProjectSummary("item-a", "workspace-a", ProjectTypes.KANBAN, "sprint board"),
        ),
        expandedItemIds = emptySet(),
        chats = emptyMap(),
        isLoading = false,
        errorMessage = null,
    )

    private fun showDrawer(
        chats: List<ChatSummary> = this.chats,
        projects: ProjectsState = oneProject(),
        recentsOpen: MutableState<Boolean> = mutableStateOf(true),
        onToggleRecents: () -> Unit = {},
        hasMoreChats: Boolean = false,
        onLoadMore: () -> Unit = {},
    ) {
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    projects = projects,
                    projectActions = ProjectsActions(
                        onToggleSection = {},
                        onToggleItem = {},
                        onOpenAllChats = { _, _ -> },
                        onRetry = {},
                    ),
                    recentsExpanded = recentsOpen.value,
                    onToggleRecentsSection = onToggleRecents,
                    hasMoreChats = hasMoreChats,
                    onLoadMoreChats = onLoadMore,
                )
            }
        }
    }

    @Test
    fun bothSectionsAreNamedAndStartUnfolded() {
        showDrawer()

        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithText("Recent").assertIsDisplayed()
        composeTestRule.onNodeWithTag("projects_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithText("Projects").assertIsDisplayed()

        // Unfolded by default: a section the reader has to open before it shows
        // anything is a section most people never open.
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-a").assertIsDisplayed()
    }

    @Test
    fun theDrawerHasNoAllChatsRow() {
        showDrawer()

        // The hamburger opens the list that row used to lead to, so the row was
        // a second route to where the reader already stands. Asserted absent:
        // a test that only checked it existed could not have caught its removal.
        composeTestRule.onNodeWithText("All chats").assertDoesNotExist()
    }

    @Test
    fun theRecentsHeaderFoldsTheChatsAndFoldsThemBackOut() {
        var toggles = 0
        val recentsOpen = mutableStateOf(true)
        showDrawer(
            recentsOpen = recentsOpen,
            onToggleRecents = {
                toggles++
                recentsOpen.value = !recentsOpen.value
            },
        )

        composeTestRule.onNodeWithTag("recents_section_header").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, toggles)
        // Folded: the rows go, the section's own title stays, and the *other*
        // section is untouched — a fold belongs to its own section only.
        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chats_list_footer").assertDoesNotExist()
        composeTestRule.onNodeWithTag("projects_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-a").assertExists()

        composeTestRule.onNodeWithTag("recents_section_header").performClick()
        composeTestRule.waitForIdle()

        assertEquals(2, toggles)
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    @Test
    fun theRecentsTitlePinsWhileTheChatsScrollUnderIt() {
        showDrawer(chats = manyChats(60))

        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(30)
        composeTestRule.waitForIdle()

        // Scrolled well past the first rows, so a title still on screen can
        // only be the pin. Without `stickyHeader` this row would be gone.
        composeTestRule.onNodeWithTag("chat_row_chat-1").assertIsNotDisplayed()
        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
    }

    @Test
    fun theProjectsTitlePinsWhileItsOwnRowsScrollUnderIt() {
        // One chat, so the list is short enough that scrolling lands inside the
        // projects section — which is the only place the second pin shows.
        showDrawer(chats = manyChats(1))

        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(2)
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("projects_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-a").assertExists()
    }

    @Test
    fun aFoldedRecentsSectionDoesNotPage() {
        // The paging trigger is index arithmetic over the chat region. A folded
        // section renders no chat rows, so the region is empty — and a trigger
        // that armed on the Projects header below it would page a list the
        // reader has just hidden, forever.
        var loadMoreCalls = 0
        showDrawer(
            chats = manyChats(60),
            projects = ProjectsState.Empty,
            recentsOpen = mutableStateOf(false),
            hasMoreChats = true,
            onLoadMore = { loadMoreCalls++ },
        )

        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(2)
        composeTestRule.waitForIdle()

        assertEquals(0, loadMoreCalls)
    }

    @Test
    fun thePagingTriggerFiresAtTheEndAndNotInTheMiddle() {
        // The trigger is index arithmetic over the chat region, anchored on that
        // region's end rather than on the bottom of the whole list — so scrolling
        // *past* the chats, into the projects, still counts as reaching the end
        // of the chats. A trigger bounded above by the region's end missed every
        // scroll that landed past the footer rather than crossing it.
        var loadMoreCalls = 0
        showDrawer(
            chats = manyChats(60),
            projects = oneProject(),
            hasMoreChats = true,
            onLoadMore = { loadMoreCalls++ },
        )

        // Comfortably short of the end: nothing to ask for yet.
        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(30)
        composeTestRule.waitForIdle()
        assertEquals("the middle of the list must not page", 0, loadMoreCalls)

        // The last rows of the chat list. Index 60 is the final chat and 61 its
        // footer, so this is the end of the region, not the end of the drawer.
        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(61)
        composeTestRule.waitForIdle()
        assertEquals("reaching the end of the chat region must page", true, loadMoreCalls >= 1)
    }

    private fun manyChats(count: Int) = (1..count).map { index ->
        ChatSummary(
            id = "chat-$index",
            workspaceId = "workspace-a",
            title = "Chat $index",
            updatedAtEpochMillis = now - index * 60_000L,
        )
    }
}
