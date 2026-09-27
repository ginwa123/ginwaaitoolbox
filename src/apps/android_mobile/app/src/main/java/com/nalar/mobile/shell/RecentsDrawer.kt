package com.nalar.mobile.shell

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.nalar.mobile.projects.ProjectsActions
import com.nalar.mobile.projects.ProjectsState
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.RecentsSidebar
import com.nalar.mobile.recents.WorkspaceOption
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarText

/**
 * The drawer both screens show: the workspace picker, the recents list and the
 * account footer.
 *
 * It lives here rather than inside the screen that happens to draw it now
 * because there are two of them — the shell's own drawer, and the one the chat
 * route's hamburger opens — and a second copy of this wiring would be a second
 * copy of every drawer bug. The caller supplies the sheet (modal over a chat,
 * permanent beside the home content) because that is the part that differs, and
 * everything inside is here.
 */
@Composable
fun RecentsDrawerContent(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    selectedChatId: String?,
    onWorkspaceSelected: (String) -> Unit,
    onChatSelected: (String) -> Unit,
    /**
     * Fired once a chat has been picked, because a chat is a destination. Kept
     * separate from [onChatSelected] for the same reason the sidebar keeps them
     * apart: switching the workspace is a filter and must not leave.
     */
    onOpenChat: () -> Unit,
    modifier: Modifier = Modifier,
    /**
     * Space above the list, for a screen that is *not* the chat list and
     * therefore needs its own way back to it. See [BackToChatsRow].
     */
    header: @Composable (ColumnScope.() -> Unit)? = null,
    isLoading: Boolean = false,
    errorMessage: String? = null,
    onRetry: () -> Unit = {},
    isLoadingMore: Boolean = false,
    hasMoreChats: Boolean = false,
    onLoadMore: () -> Unit = {},
    /**
     * Forwarded, not interpreted: the set is app-wide and the row that draws
     * the busy dot lives in the sidebar. Swallowing it here would silently drop
     * the indicator from whichever drawer forgot to pass it.
     */
    runningSessionIds: Set<String> = emptySet(),
    isAuthEnabled: Boolean = false,
    signedInEmail: String? = null,
    isLoggingOut: Boolean = false,
    onLogout: () -> Unit = {},
    /**
     * The Projects section, forwarded to both drawers from here rather than
     * from each call site.
     *
     * That is the whole reason this file exists: the shell's drawer and the
     * chat route's drawer are two of the same drawer, and wiring this into
     * `MobileHomeScreen` instead would have left the Projects section missing
     * from whichever one a caller forgot.
     */
    projects: ProjectsState = ProjectsState.Empty,
    projectActions: ProjectsActions = ProjectsActions.None,
) {
    Column(
        modifier = modifier.fillMaxSize(),
    ) {
        if (header != null) {
            header()
            HorizontalDivider(color = NalarBorder)
        }

        RecentsSidebar(
            // Weighted rather than `fillMaxSize` so the sidebar takes what is
            // left under a header rather than the whole sheet, which would push
            // the account footer off the bottom of the drawer.
            modifier = Modifier.weight(1f),
            workspaces = workspaces,
            chats = chats,
            selectedWorkspaceId = selectedWorkspaceId,
            selectedChatId = selectedChatId,
            onWorkspaceSelected = onWorkspaceSelected,
            onChatSelected = onChatSelected,
            onOpenChat = onOpenChat,
            isLoading = isLoading,
            errorMessage = errorMessage,
            onRetry = onRetry,
            isLoadingMore = isLoadingMore,
            hasMoreChats = hasMoreChats,
            onLoadMore = onLoadMore,
            runningSessionIds = runningSessionIds,
            isAuthEnabled = isAuthEnabled,
            signedInEmail = signedInEmail,
            isLoggingOut = isLoggingOut,
            onLogout = onLogout,
            projects = projects,
            projectActions = projectActions,
        )
    }
}

/**
 * "All chats", at the top of the chat route's drawer.
 *
 * The chat's top bar has no back arrow any more — the hamburger opens the
 * drawer instead — so a chat opened from a `nalar://chat/…` link, which is the
 * one entry on the back stack, would have no in-app route to the shell at all:
 * system Back would close the app instead. That is the dead end
 * `goBackToPreviousOrShell` exists to prevent, moved rather than created.
 *
 * Placed at the top because that is where a navigation drawer's own hierarchy
 * lives, so it reads as "back out of here" rather than as a chat.
 */
@Composable
fun BackToChatsRow(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .selectable(selected = false, onClick = onClick)
            .testTag("chat_all_chats")
            .padding(horizontal = 8.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
            contentDescription = null,
            tint = NalarDim,
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = "All chats",
            style = MaterialTheme.typography.bodyLarge,
            color = NalarText,
        )
    }
}

/**
 * The chat row the chat route's drawer highlights.
 *
 * The route wins over the list's own selection for the same reason the title
 * does: a `nalar://chat/…` link, or a session opened from a push, puts a chat
 * on screen that the sidebar never marked as selected. Highlighting the list's
 * memory instead would leave the reader looking at a chat the drawer claims
 * they are not in. A blank route falls back to it, because that is the only
 * case where the route knows nothing.
 */
internal fun chatDrawerSelectedChatId(
    routeSessionId: String,
    homeSelectedChatId: String?,
): String? = routeSessionId.takeIf { it.isNotBlank() } ?: homeSelectedChatId
