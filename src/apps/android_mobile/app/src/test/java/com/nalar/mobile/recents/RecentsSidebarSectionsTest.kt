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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    /**
     * The recents preview is passed as *state*, for the same reason the fold
     * is: the tests that open the whole list have to open it without composing
     * the drawer twice, and `setContent` may only be called once.
     */
    private fun showDrawer(
        chats: List<ChatSummary> = this.chats,
        projects: ProjectsState = oneProject(),
        recentsOpen: MutableState<Boolean> = mutableStateOf(true),
        onToggleRecents: () -> Unit = {},
        showAll: MutableState<Boolean> = mutableStateOf(false),
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
                    recentsShowAll = showAll.value,
                    onToggleRecentsShowAll = { showAll.value = !showAll.value },
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
        val showAll = mutableStateOf(false)
        showDrawer(chats = manyChats(60), showAll = showAll)
        revealEveryRecentsRow()

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
        val showAll = mutableStateOf(false)
        showDrawer(
            chats = manyChats(60),
            projects = oneProject(),
            showAll = showAll,
            hasMoreChats = true,
            onLoadMore = { loadMoreCalls++ },
        )
        revealEveryRecentsRow()

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

    // ── The five-row preview ──────────────────────────────────────────
    //
    // The complaint: a phone drawer opened on thirty chat titles, with the
    // Projects section — the part people navigate by — pushed off the bottom.

    @Test
    fun aLongListShowsFiveRowsAndSaysHowManyAreBehindThem() {
        showDrawer(chats = manyChats(30))

        composeTestRule.onNodeWithTag("chat_row_chat-5").assertIsDisplayed()
        // Absent, not merely off-screen: the sixth row must not exist in the
        // tree, or a test could not tell a capped list from a scrolled one.
        composeTestRule.onNodeWithTag("chat_row_chat-6").assertDoesNotExist()

        // The header keeps the true total, so a capped section still reports
        // what is in it rather than quietly claiming five.
        composeTestRule.onNodeWithText("30").assertIsDisplayed()
        composeTestRule.onNodeWithTag("recents_see_all").assertIsDisplayed()
        composeTestRule.onNodeWithText("See 25 more chats").assertIsDisplayed()
    }

    @Test
    fun aCappedPreviewHasNoPagingFooterAndSaysNothingAboutScrolling() {
        showDrawer(chats = manyChats(30), hasMoreChats = true)

        // "Scroll for older chats" under a list that does not scroll is an
        // instruction the reader cannot follow, and "No older chats" would be
        // a lie: there are twenty-five of them.
        composeTestRule.onNodeWithTag("chats_list_footer").assertDoesNotExist()
        composeTestRule.onNodeWithText("Scroll for older chats").assertDoesNotExist()
        composeTestRule.onNodeWithText("No older chats").assertDoesNotExist()
    }

    @Test
    fun aCappedPreviewDoesNotPageTheChatList() {
        // The five rows fit on the screen, so the trigger had to be disarmed
        // with the footer rather than left waiting for a scroll that cannot
        // happen. Otherwise the drawer fetches page after page behind a row
        // nobody has tapped — the long drawer rebuilt out of network requests.
        var loadMoreCalls = 0
        showDrawer(
            chats = manyChats(30),
            projects = ProjectsState.Empty,
            hasMoreChats = true,
            onLoadMore = { loadMoreCalls++ },
        )

        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(6)
        composeTestRule.waitForIdle()

        assertEquals(0, loadMoreCalls)
    }

    @Test
    fun theSeeAllRowRevealsTheRowsBehindIt() {
        val showAll = mutableStateOf(false)
        showDrawer(chats = manyChats(30), projects = oneProject(), showAll = showAll)

        composeTestRule.onNodeWithTag("recents_see_all").performClick()
        composeTestRule.waitForIdle()

        assertTrue("the tap must reach the state the drawer renders from", showAll.value)
        // The row the cap was hiding, one line below the preview's last.
        composeTestRule.onNodeWithTag("chat_row_chat-6").assertIsDisplayed()
        composeTestRule.onNodeWithText("See 25 more chats").assertDoesNotExist()

        // The last row is reachable by scrolling, which is the whole claim. A
        // lazy list only composes what is on screen, so finding it means
        // scrolling for it — the same gesture the reader will use.
        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(30)
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("chat_row_chat-30").assertIsDisplayed()
    }

    @Test
    fun theOpenListNamesTheWayBackOnTheSameRow() {
        val showAll = mutableStateOf(false)
        showDrawer(chats = manyChats(30), projects = oneProject(), showAll = showAll)

        composeTestRule.onNodeWithTag("recents_see_all").performClick()
        composeTestRule.waitForIdle()
        scrollToSeeAllRow(chatCount = 30)

        // The same row names the way back, rather than a second control
        // competing with it in a column that has just been shortened — and the
        // label follows the reader down the list, because the row did.
        composeTestRule.onNodeWithText("Show fewer").assertIsDisplayed()
    }

    @Test
    fun theSeeAllRowPutsThePreviewBackAgain() {
        val showAll = mutableStateOf(false)
        showDrawer(chats = manyChats(30), projects = oneProject(), showAll = showAll)

        composeTestRule.onNodeWithTag("recents_see_all").performClick()
        composeTestRule.waitForIdle()
        // The row has moved to the bottom of the open list, so getting back to
        // it is a scroll — the same thing a reader who changes their mind has
        // to do, and the reason the row is one control rather than two.
        scrollToSeeAllRow(chatCount = 30)
        composeTestRule.onNodeWithTag("recents_see_all").performClick()
        composeTestRule.waitForIdle()

        assertFalse(showAll.value)
        composeTestRule.onNodeWithTag("chat_row_chat-6").assertDoesNotExist()
        composeTestRule.onNodeWithText("See 25 more chats").assertIsDisplayed()
        // Back to no end-of-list row: a preview whose bottom is an arbitrary
        // cut has no end to report.
        composeTestRule.onNodeWithTag("chats_list_footer").assertDoesNotExist()
    }

    @Test
    fun aShortListNeedsNoSeeAllRow() {
        // Three chats have nothing to reveal, so the row would be a control
        // with no effect — the reader taps it, nothing changes, and the drawer
        // has lied once.
        showDrawer(chats = manyChats(3))

        composeTestRule.onNodeWithTag("recents_see_all").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chat_row_chat-3").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chats_list_footer").assertExists()
    }

    @Test
    fun aWorkspaceShorterThanThePreviewOffersNoSeeAllRow() {
        // The reader opened the whole list in a workspace with thirty chats and
        // switched to one with three. The row has nothing to reveal and nothing
        // to put away here, and "See 0 more chats" would be a lie with a button
        // on it — so the state survives the switch and the row does not.
        val showAll = mutableStateOf(false)
        showDrawer(chats = manyChats(3), projects = oneProject(), showAll = showAll)

        composeTestRule.onNodeWithTag("recents_see_all").assertDoesNotExist()
        composeTestRule.runOnIdle { showAll.value = true }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("recents_see_all").assertDoesNotExist()
        composeTestRule.onNodeWithText("See 0 more chats").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chat_row_chat-3").assertIsDisplayed()
    }

    /**
     * Open the whole list through the row a reader would tap, rather than by
     * starting the screen in that state — so the tests below that are about
     * scrolling and paging are still about scrolling and paging.
     */
    private fun revealEveryRecentsRow() {
        composeTestRule.onNodeWithTag("recents_see_all").performClick()
        composeTestRule.waitForIdle()
    }

    /**
     * Scroll the "See all" row into view, wherever the open list put it.
     *
     * The index is the list's own arithmetic: the Recents header at 0, then one
     * row per chat, so the row after the last chat is `1 + chatCount`. Written
     * as arithmetic rather than a bare number for the same reason
     * `chatRegionEndIndex` is a function — a literal here would go quietly
     * stale the day the section gains a row above the chats.
     */
    private fun scrollToSeeAllRow(chatCount: Int) {
        composeTestRule.onNodeWithTag("sidebar_chat_list")
            .performScrollToIndex(1 + chatCount)
        composeTestRule.waitForIdle()
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
