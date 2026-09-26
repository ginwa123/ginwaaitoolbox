package com.nalar.mobile.recents

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nalar.mobile.shell.MobileDrawerLayout
import com.nalar.mobile.shell.MobileHomeScreen
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

    @Test
    fun theFooterReportsTheEndOfTheListOnlyOnceTheServerHasSaidSo() {
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    hasMoreChats = true,
                )
            }
        }

        // While more may exist, claiming "you're all caught up" and then having
        // to walk it back would be a lie the user reads first.
        composeTestRule.onNodeWithTag("chats_list_footer").assertIsDisplayed()
        composeTestRule.onNodeWithText("No older chats").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chats_load_more_hint").assertIsDisplayed()
    }

    @Test
    fun anExhaustedListSaysSoAtTheEnd() {
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    hasMoreChats = false,
                )
            }
        }

        composeTestRule.onNodeWithText("No older chats").assertIsDisplayed()
    }

    @Test
    fun aPageInFlightShowsASpinnerInsteadOfTheEndMarker() {
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isLoadingMoreChats = true,
                    hasMoreChats = true,
                )
            }
        }

        // The rows already on screen are real; the footer has to say "working"
        // rather than "done" or "nothing here".
        composeTestRule.onNodeWithTag("chats_load_more_spinner").assertIsDisplayed()
        composeTestRule.onNodeWithText("No older chats").assertDoesNotExist()
    }

    @Test
    fun reachingTheBottomAsksForTheNextPage() {
        var loadMoreCalls = 0
        val manyChats = (1..60).map { index ->
            ChatSummary(
                id = "chat-$index",
                workspaceId = "workspace-a",
                title = "Chat $index",
                updatedAtEpochMillis = now - index * 60_000L,
            )
        }
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = manyChats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    hasMoreChats = true,
                    onLoadMoreChats = { loadMoreCalls++ },
                )
            }
        }

        // 60 rows cannot fit a phone viewport, so the list starts well clear of
        // the trigger and only reaching the end can arm it.
        assertEquals(0, loadMoreCalls)

        composeTestRule.onNodeWithTag("chat_message_list")
            .performScrollToIndex(55)
        composeTestRule.waitForIdle()

        assertTrue("scrolling to the end must page", loadMoreCalls >= 1)
    }

    @Test
    fun theSidebarNamesTheAccountAndOffersToEndTheSession() {
        var logoutCalls = 0
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isAuthEnabled = true,
                    signedInEmail = "ada@example.com",
                    onLogout = { logoutCalls++ },
                )
            }
        }

        // The account line is what turns "Log out" from a label into a
        // decision: the user can see whose session they are about to end.
        composeTestRule.onNodeWithTag("sidebar_account_email")
            .assertIsDisplayed()
        composeTestRule.onNodeWithText("ada@example.com").assertIsDisplayed()

        composeTestRule.onNodeWithTag("sidebar_logout").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, logoutCalls)
    }

    @Test
    fun anOpenServerShowsNoSignOutRow() {
        // `auth_enabled=false`: the server is running without --auth, so there
        // is no session. A row that did nothing but clear caches would be a
        // control that lies about what it controls.
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isAuthEnabled = false,
                    signedInEmail = null,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_logout").assertDoesNotExist()
        composeTestRule.onNodeWithTag("sidebar_account_divider").assertDoesNotExist()
    }

    @Test
    fun aSignOutInFlightDisablesTheRowAndSaysSo() {
        // Two presses would be two POSTs and two cache purges; the label has to
        // admit the wait or the button looks broken on a slow connection.
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isAuthEnabled = true,
                    signedInEmail = "ada@example.com",
                    isLoggingOut = true,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_logout").assertIsNotEnabled()
        composeTestRule.onNodeWithText("Logging out…").assertIsDisplayed()
    }

    @Test
    fun theSignOutRowSurvivesTheNoWorkspacesState() {
        // The branch that matters most: with no workspaces there is nothing to
        // navigate to, so hiding the only route back to signing in would strand
        // the user on a screen with no controls at all.
        var logoutCalls = 0
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = emptyList(),
                    chats = emptyList(),
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isAuthEnabled = true,
                    signedInEmail = "ada@example.com",
                    onLogout = { logoutCalls++ },
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_no_workspaces").assertIsDisplayed()
        composeTestRule.onNodeWithTag("sidebar_logout").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, logoutCalls)
    }

    @Test
    fun theSignOutRowIsReachableFromTheModalDrawerToo() {
        // The phone layout is the one people actually use, and it renders the
        // sidebar through a different call site than the wide layout.
        var logoutCalls = 0
        composeTestRule.setContent {
            NalarTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Modal,
                    isAuthEnabled = true,
                    signedInEmail = "ada@example.com",
                    onLogout = { logoutCalls++ },
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_logout").assertDoesNotExist()

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("sidebar_logout").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, logoutCalls)
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
