package com.nalar.mobile.recents

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nalar.mobile.shell.MobileDrawerLayout
import com.nalar.mobile.shell.MobileHomeScreen
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecentsSidebarTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L
    private val workspaces = listOf(
        WorkspaceOption("workspace-a", "Workspace A"),
        WorkspaceOption("workspace-b", "Workspace B"),
    )
    private val chats = listOf(
        ChatSummary("chat-a1", "workspace-a", "Android sidebar", now - 5L * 60_000L),
        ChatSummary("chat-a2", "workspace-a", "Release checklist", now - 2L * 60L * 60_000L),
        ChatSummary("chat-b1", "workspace-b", "Router regression", now - 3L * 24L * 60L * 60_000L),
    )

    @Test
    fun opensDrawerWithWorkspaceDropdownAndRecentChats() {
        showModalScreen()

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("workspace_dropdown").assertIsDisplayed()
        composeTestRule.onNodeWithText("Recent").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    @Test
    fun workspaceSelectionScopesRecentsAndClosesDrawer() {
        var selectedWorkspaceId: String? = null
        showModalScreen(
            onWorkspaceSelected = { selectedWorkspaceId = it },
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("workspace_dropdown").performClick()
        composeTestRule.onNodeWithTag("workspace_option_workspace-b").performClick()
        composeTestRule.waitForIdle()

        assertEquals("workspace-b", selectedWorkspaceId)
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()
        composeTestRule.onNodeWithTag("home_chat_title").assertIsDisplayed()
        composeTestRule.onNodeWithText("Router regression").assertIsDisplayed()

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-b1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertDoesNotExist()
    }

    @Test
    fun selectingChatUpdatesActiveRowAndClosesDrawer() {
        var selectedChatId: String? = null
        showModalScreen(
            onChatSelected = { selectedChatId = it },
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsSelected()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").assertIsNotSelected()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").performClick()
        composeTestRule.waitForIdle()

        assertEquals("chat-a2", selectedChatId)
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()
        composeTestRule.onNodeWithText("Release checklist").assertIsDisplayed()

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").assertIsSelected()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsNotSelected()
    }

    @Test
    fun chatListRefreshKeepsTheCurrentSelection() {
        val currentChats = androidx.compose.runtime.mutableStateOf(chats)
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = currentChats.value,
                    drawerLayout = MobileDrawerLayout.Modal,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.runOnIdle {
            currentChats.value = listOf(
                ChatSummary("chat-new", "workspace-a", "New arrival", now + 1_000L),
            ) + chats
        }

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-new").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").assertIsSelected()
    }

    @Test
    fun wideLayoutShowsPermanentSidebarWithoutMenuButton() {
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("sidebar_open_menu").assertDoesNotExist()
        composeTestRule.onNodeWithTag("workspace_dropdown").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    private fun showModalScreen(
        onWorkspaceSelected: (String) -> Unit = {},
        onChatSelected: (String) -> Unit = {},
    ) {
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    onWorkspaceSelected = onWorkspaceSelected,
                    onChatSelected = onChatSelected,
                    drawerLayout = MobileDrawerLayout.Modal,
                )
            }
        }
    }
}
