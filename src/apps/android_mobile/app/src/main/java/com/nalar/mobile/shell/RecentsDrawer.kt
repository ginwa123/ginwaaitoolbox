package com.nalar.mobile.shell

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.nalar.mobile.projects.ProjectsActions
import com.nalar.mobile.projects.ProjectsState
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.RecentsSidebar
import com.nalar.mobile.recents.WorkspaceOption

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
    /**
     * Whether the Recents section is folded, and the tap that folds it.
     *
     * Forwarded for the same reason [projects] is: the two drawers are one
     * drawer, so a fold the reader made in the shell has to still be a fold when
     * they open the drawer from inside a chat. Neither drawer may keep its own
     * copy of which section is open — that is how "I collapsed this and it came
     * back" happens.
     */
    recentsExpanded: Boolean = true,
    onToggleRecentsSection: () -> Unit = {},
) {
    RecentsSidebar(
        modifier = modifier.fillMaxSize(),
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
        recentsExpanded = recentsExpanded,
        onToggleRecents = onToggleRecentsSection,
    )
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
