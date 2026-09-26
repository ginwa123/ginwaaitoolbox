package com.nalar.mobile.chat

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.WorkspaceOption
import com.nalar.mobile.shell.BackToChatsRow
import com.nalar.mobile.shell.RecentsDrawerContent
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The chat's top bar leads with a drawer rather than a back arrow.
 *
 * The screen itself is simple — a button, a sheet, and the sidebar inside it —
 * and what is worth asserting is the wiring around it: that the hamburger opens
 * the *same* drawer the shell shows, that a chat picked there is a destination
 * (so the sheet closes behind it), and that a workspace is still only a filter
 * (so the sheet does not).
 */
@RunWith(AndroidJUnit4::class)
class ChatDrawerTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L
    private val workspaces = listOf(
        WorkspaceOption("workspace-a", "Workspace A"),
        WorkspaceOption("workspace-b", "Workspace B"),
    )
    private val chats = listOf(
        ChatSummary("chat-a1", "workspace-a", "Android drawer", now - 5L * 60_000L),
        ChatSummary("chat-a2", "workspace-a", "Release checklist", now - 2L * 60L * 60_000L),
        ChatSummary("chat-b1", "workspace-b", "Router regression", now - 3L * 24L * 60L * 60_000L),
    )

    private var pickedChatId: String? = null
    private var backToChatsTaps = 0
    // State, not plain fields: the sidebar re-reads these on every
    // recomposition, and a field write would leave the drawer showing the
    // workspace the reader just left. The production wiring gets the same
    // recomposition from `HomeViewModel`.
    private lateinit var selectedWorkspaceId: MutableState<String?>
    private lateinit var selectedChatId: MutableState<String?>

    /**
     * The same drawer the shell shows, with the route's header in front of it —
     * the shape `NalarNavGraph` hands the screen.
     */
    private fun showChat() {
        selectedWorkspaceId = mutableStateOf("workspace-a")
        selectedChatId = mutableStateOf("chat-a1")
        composeTestRule.setContent {
            NalarTheme {
                ChatScreen(
                    state = ChatUiState(sessionId = "chat-a1", isLoading = false),
                    chatTitle = "Android drawer",
                    drawerContent = { dismissDrawer ->
                        RecentsDrawerContent(
                            workspaces = workspaces,
                            chats = chats,
                            selectedWorkspaceId = selectedWorkspaceId.value,
                            selectedChatId = selectedChatId.value,
                            onWorkspaceSelected = { selectedWorkspaceId.value = it },
                            onChatSelected = { pickedChatId = it },
                            onOpenChat = dismissDrawer,
                            header = { BackToChatsRow(onClick = { backToChatsTaps++ }) },
                        )
                    },
                )
            }
        }
    }

    private fun openDrawer() {
        composeTestRule.onNodeWithTag("chat_drawer_menu").performClick()
        composeTestRule.waitForIdle()
    }

    @Test
    fun theHamburgerOpensTheRecentsDrawer() {
        showChat()

        // The back affordance is gone: a reader who came here from the list
        // wants the list, not one more tap that returns them to where they
        // already were.
        composeTestRule.onNodeWithTag("chat_back").assertDoesNotExist()

        openDrawer()

        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("workspace_dropdown").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_all_chats").assertIsDisplayed()
        composeTestRule.onNodeWithText("Recent").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    @Test
    fun theHighlightedRowIsWhicheverChatTheRouteNames() {
        showChat()

        // A deep link, or a session opened from a push, puts a chat on screen
        // that the sidebar never marked as selected.
        composeTestRule.runOnIdle { selectedChatId.value = "chat-a2" }
        openDrawer()

        composeTestRule.onNodeWithTag("chat_row_chat-a2").assertIsSelected()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsNotSelected()
    }

    @Test
    fun pickingAChatClosesTheDrawerAndReportsTheDestination() {
        showChat()
        openDrawer()

        composeTestRule.onNodeWithTag("chat_row_chat-a2").performClick()
        composeTestRule.waitForIdle()

        assertEquals("chat-a2", pickedChatId)
        // A chat is a destination, so the sheet must not stay open on top of the
        // transcript the reader just asked for.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()
    }

    @Test
    fun switchingWorkspaceRescopesTheListAndKeepsTheDrawerOpen() {
        showChat()
        openDrawer()

        composeTestRule.onNodeWithTag("workspace_dropdown").performClick()
        composeTestRule.onNodeWithTag("workspace_option_workspace-b").performClick()
        composeTestRule.waitForIdle()

        assertEquals("workspace-b", selectedWorkspaceId.value)
        // A workspace is a filter. Closing here hides the chats they asked to
        // see and makes them reopen the menu to reach the row they were about
        // to tap.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-b1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertDoesNotExist()
    }

    @Test
    fun theDrawersOwnRowLeadsOutOfTheChat() {
        showChat()
        openDrawer()

        composeTestRule.onNodeWithTag("chat_all_chats").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, backToChatsTaps)
    }
}
