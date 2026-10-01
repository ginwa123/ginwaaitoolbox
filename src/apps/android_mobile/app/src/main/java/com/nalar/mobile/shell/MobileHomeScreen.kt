@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.nalar.mobile.shell

import com.nalar.mobile.projects.ProjectsActions
import com.nalar.mobile.projects.ProjectsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.WorkspaceOption
import com.nalar.mobile.recents.formatRelativeTime
import com.nalar.mobile.recents.recentChatsForWorkspace
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarBackgroundRaised
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import com.nalar.mobile.ui.NalarTheme
import kotlinx.coroutines.launch

enum class MobileDrawerLayout {
    Auto,
    Modal,
    Permanent,
}

private val ExpandedDrawerBreakpoint = 720.dp

@Composable
fun MobileHomeScreen(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    modifier: Modifier = Modifier,
    initialWorkspaceId: String? = null,
    initialChatId: String? = null,
    onWorkspaceSelected: (String) -> Unit = {},
    onChatSelected: (String) -> Unit = {},
    /**
     * Opens a chat as its own destination. A chat is a view, so it lives on a
     * route rather than in a local selection flag — that is what makes it
     * survive process death and the system Back button.
     */
    onOpenChat: (String) -> Unit = {},
    onOpenNetworkInspector: () -> Unit = {},
    drawerLayout: MobileDrawerLayout = MobileDrawerLayout.Auto,
    isLoading: Boolean = false,
    errorMessage: String? = null,
    onRetry: () -> Unit = {},
    /**
     * Whether the workspace holds chats the drawer is not showing, and the
     * server's count of them all.
     *
     * Forwarded to both drawers from here rather than from each call site: they
     * are one drawer, and a `See all chats ›` row that one of them offers and
     * the other does not is a drawer that disagrees with itself.
     */
    hasMoreChats: Boolean = false,
    chatsTotal: Int = 0,
    /**
     * Leave the drawer for the full recents list.
     *
     * A destination, and the drawer closes on the way — for the same reason a
     * chat row does: the list behind it is somewhere to go, not a filter.
     */
    onOpenAllChats: () -> Unit = {},
    /**
     * Session ids with a live worker. Hoisted all the way down to each row, and
     * app-wide rather than per-view, because the shell and the chat are
     * separate routes and a run belongs to neither of them.
     */
    runningSessionIds: Set<String> = emptySet(),
    /**
     * The signed-in account, and the one action that ends it. Defaults keep the
     * screen renderable in previews and tests with no session to describe.
     */
    isAuthEnabled: Boolean = false,
    signedInEmail: String? = null,
    isLoggingOut: Boolean = false,
    onLogout: () -> Unit = {},
    /**
     * The Projects section, forwarded to both drawers.
     *
     * Two holders rather than eight more parameters, and threaded through
     * this one composable rather than into the two call sites below: the
     * shell's permanent drawer and the phone's modal drawer are the same
     * drawer, and a Projects section that only reached one of them would
     * look broken rather than absent.
     */
    projects: ProjectsState = ProjectsState.Empty,
    projectActions: ProjectsActions = ProjectsActions.None,
    /**
     * Whether the Recents section is folded, and the tap that folds it.
     *
     * Hoisted, not local, for the same reason [projects] is: the chat route
     * composes the *same* drawer through [RecentsDrawerContent] while this
     * screen composes it twice below. A fold held in a local here would be one
     * the reader loses the moment they open a chat — the drawer would spring
     * open again with the section they just closed.
     */
    recentsExpanded: Boolean = true,
    onToggleRecentsSection: () -> Unit = {},
    /**
     * The top-level "New Chat" row's busy flag and its tap.
     *
     * Threaded rather than owned here for the same reason the section fold is:
     * the shell's permanent drawer and the modal one are the same drawer, so a
     * row wired in only one of them is a row that does nothing in the other.
     */
    isCreatingChat: Boolean = false,
    onNewChat: () -> Unit = {},
) {
    val initialResolvedWorkspaceId = initialWorkspaceId
        ?.takeIf { requestedId -> workspaces.any { it.id == requestedId } }
        ?: workspaces.firstOrNull()?.id

    var selectedWorkspaceId by rememberSaveable {
        mutableStateOf(initialResolvedWorkspaceId)
    }
    val scopedChats = selectedWorkspaceId
        ?.let { workspaceId -> recentChatsForWorkspace(chats, workspaceId) }
        .orEmpty()

    var selectedChatId by rememberSaveable {
        mutableStateOf(
            initialChatId
                ?.takeIf { requestedId -> scopedChats.any { it.id == requestedId } }
                ?: scopedChats.firstOrNull()?.id,
        )
    }

    LaunchedEffect(workspaces, selectedWorkspaceId) {
        if (workspaces.none { it.id == selectedWorkspaceId }) {
            selectedWorkspaceId = workspaces.firstOrNull()?.id
        }
    }

    LaunchedEffect(scopedChats, selectedChatId, initialChatId) {
        // Already on a real row: nothing to decide. Reached on every refresh and
        // every tap, and short-circuiting is what stops a revalidation from
        // moving the highlight off the chat the user is reading.
        if (selectedChatId != null && scopedChats.any { it.id == selectedChatId }) {
            return@LaunchedEffect
        }
        // `initialChatId` is a *request*, not a seed. It arrives after the first
        // composition — the chat list is still loading then, so an id read at
        // construction time is either null or cannot be checked — and honouring
        // it only at construction is what lets the app resume a chat the drawer
        // does not highlight.
        val requested = initialChatId
        selectedChatId = if (requested != null && scopedChats.any { it.id == requested }) {
            requested
        } else {
            scopedChats.firstOrNull()?.id
        }
    }

    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val coroutineScope = rememberCoroutineScope()
    val closeDrawer: () -> Unit = {
        // A permanent drawer has no sheet to close, so asking anyway would
        // animate a drawer that was never open on every chat tap.
        if (drawerState.isOpen) {
            coroutineScope.launch {
                drawerState.close()
            }
        }
    }

    // D13: the top-level "New Chat" CLOSES the drawer, unlike the per-project
    // `+` beside it, which deliberately leaves it open so the reader watches
    // the new row appear under that project. Two rows that look alike and
    // behave oppositely is worse than either choice alone.
    //
    // The dismissal is fired BEFORE the create starts, not after. The create is
    // async — the navigation happens later, when HomeViewModel's createdChat
    // flow emits — so the close animation runs while the request is in flight
    // and the chat screen mounts into an already-closed drawer. Closing after
    // would be a visible flicker.
    val newChatAndClose: () -> Unit = {
        closeDrawer()
        onNewChat()
    }

    // The destination row, closed behind it. Same shape as `newChatAndClose`
    // and for the same reason: the list behind the row is a *place to go*, so
    // leaving the sheet open on top of it is the drawer hiding the page the
    // reader asked for.
    val openAllChatsAndClose: () -> Unit = {
        closeDrawer()
        onOpenAllChats()
    }
    val selectedWorkspace = workspaces.firstOrNull { it.id == selectedWorkspaceId }
    val selectedChat = scopedChats.firstOrNull { it.id == selectedChatId }

    val selectWorkspace: (String) -> Unit = { workspaceId ->
        selectedWorkspaceId = workspaceId
        selectedChatId = recentChatsForWorkspace(chats, workspaceId).firstOrNull()?.id
        onWorkspaceSelected(workspaceId)
    }
    val selectChat: (String) -> Unit = { chatId ->
        selectedChatId = chatId
        onChatSelected(chatId)
        onOpenChat(chatId)
    }

    BoxWithConstraints(
        modifier = modifier
            .fillMaxSize()
            .background(NalarBackground),
    ) {
        val usePermanentDrawer = when (drawerLayout) {
            MobileDrawerLayout.Auto -> maxWidth >= ExpandedDrawerBreakpoint
            MobileDrawerLayout.Modal -> false
            MobileDrawerLayout.Permanent -> true
        }

        if (usePermanentDrawer) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet(
                        modifier = Modifier
                            .width(320.dp)
                            .testTag("sidebar_sheet"),
                        drawerContainerColor = NalarBackground,
                        drawerContentColor = NalarText,
                    ) {
                        RecentsDrawerContent(
                            workspaces = workspaces,
                            chats = chats,
                            selectedWorkspaceId = selectedWorkspaceId,
                            selectedChatId = selectedChatId,
                            onWorkspaceSelected = selectWorkspace,
                            onChatSelected = selectChat,
                            onOpenChat = closeDrawer,
                            isLoading = isLoading,
                            errorMessage = errorMessage,
                            onRetry = onRetry,
                            hasMoreChats = hasMoreChats,
                            chatsTotal = chatsTotal,
                            onOpenAllChats = openAllChatsAndClose,
                            runningSessionIds = runningSessionIds,
                            isAuthEnabled = isAuthEnabled,
                            signedInEmail = signedInEmail,
                            isLoggingOut = isLoggingOut,
                            onLogout = onLogout,
                            projects = projects,
                            projectActions = projectActions,
                            recentsExpanded = recentsExpanded,
                            onToggleRecentsSection = onToggleRecentsSection,
                            isCreatingChat = isCreatingChat,
                            onNewChat = newChatAndClose,
                        )
                    }
                },
            ) {
                HomeContent(
                    workspaceName = selectedWorkspace?.displayName ?: "No workspace",
                    selectedChat = selectedChat,
                    showNavigationMenu = false,
                    onOpenNavigationMenu = {},
                    onOpenNetworkInspector = onOpenNetworkInspector,
                )
            }
        } else {
            ModalNavigationDrawer(
                drawerState = drawerState,
                drawerContent = {
                    ModalDrawerSheet(
                        modifier = Modifier.testTag("sidebar_sheet"),
                        drawerState = drawerState,
                        drawerContainerColor = NalarBackground,
                        drawerContentColor = NalarText,
                    ) {
                        RecentsDrawerContent(
                            workspaces = workspaces,
                            chats = chats,
                            selectedWorkspaceId = selectedWorkspaceId,
                            selectedChatId = selectedChatId,
                            onWorkspaceSelected = selectWorkspace,
                            onChatSelected = selectChat,
                            onOpenChat = closeDrawer,
                            isLoading = isLoading,
                            errorMessage = errorMessage,
                            onRetry = onRetry,
                            hasMoreChats = hasMoreChats,
                            chatsTotal = chatsTotal,
                            onOpenAllChats = openAllChatsAndClose,
                            runningSessionIds = runningSessionIds,
                            isAuthEnabled = isAuthEnabled,
                            signedInEmail = signedInEmail,
                            isLoggingOut = isLoggingOut,
                            onLogout = onLogout,
                            projects = projects,
                            projectActions = projectActions,
                            recentsExpanded = recentsExpanded,
                            onToggleRecentsSection = onToggleRecentsSection,
                            isCreatingChat = isCreatingChat,
                            onNewChat = newChatAndClose,
                        )
                    }
                },
            ) {
                HomeContent(
                    workspaceName = selectedWorkspace?.displayName ?: "No workspace",
                    selectedChat = selectedChat,
                    showNavigationMenu = true,
                    onOpenNavigationMenu = {
                        coroutineScope.launch {
                            drawerState.open()
                        }
                    },
                    onOpenNetworkInspector = onOpenNetworkInspector,
                )
            }
        }
    }
}

@Composable
private fun HomeContent(
    workspaceName: String,
    selectedChat: ChatSummary?,
    showNavigationMenu: Boolean,
    onOpenNavigationMenu: () -> Unit,
    onOpenNetworkInspector: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // One clock for the whole composition rather than a fresh read inside the
    // body below. A `System.currentTimeMillis()` in a composition body is a
    // parameter that changes on every recomposition, which is what makes every
    // row of a list built here unskippable.
    val nowEpochMillis = remember { System.currentTimeMillis() }

    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .testTag("home_screen"),
        containerColor = NalarBackground,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = "Nalar",
                            style = MaterialTheme.typography.titleMedium,
                            color = NalarText,
                        )
                        Text(
                            text = workspaceName,
                            style = MaterialTheme.typography.labelMedium,
                            color = NalarDim,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
                navigationIcon = {
                    if (showNavigationMenu) {
                        IconButton(
                            onClick = onOpenNavigationMenu,
                            modifier = Modifier.testTag("sidebar_open_menu"),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Menu,
                                contentDescription = "Open navigation menu",
                            )
                        }
                    }
                },
                actions = {
                    IconButton(
                        onClick = onOpenNetworkInspector,
                        modifier = Modifier.testTag("home_open_network_inspector"),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Insights,
                            contentDescription = "Open network inspector",
                            tint = NalarMuted,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NalarBackground,
                    navigationIconContentColor = NalarText,
                    titleContentColor = NalarText,
                ),
            )
        },
    ) { contentPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .padding(24.dp),
            contentAlignment = Alignment.Center,
        ) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(24.dp),
                color = NalarBackgroundRaised,
                contentColor = NalarText,
                border = BorderStroke(1.dp, NalarBorder),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 28.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .background(NalarAccent, RoundedCornerShape(14.dp)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "N",
                            style = MaterialTheme.typography.titleLarge,
                            color = NalarBackground,
                        )
                    }

                    Spacer(Modifier.height(2.dp))

                    Text(
                        text = selectedChat?.displayTitle ?: "No chat selected",
                        modifier = Modifier.testTag("home_chat_title"),
                        style = MaterialTheme.typography.headlineSmall,
                        color = NalarText,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text = selectedChat?.let { chat ->
                            if (chat.hasTimestamp) {
                                // Human-touch key, matching the sidebar pill.
                                // The order key is what put the row at the top
                                // of the list; it moves while the agent works
                                // and says nothing about the human.
                                formatRelativeTime(
                                    chat.lastHumanTouchedAtEpochMillis,
                                    nowEpochMillis,
                                )
                            } else {
                                "No timestamp for this chat yet."
                            }
                        } ?: "Choose a workspace to see its recent chats.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = NalarMuted,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text = "Open a chat from the list to read and reply to it.",
                        style = MaterialTheme.typography.labelMedium,
                        color = NalarDim,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun MobileHomeScreenPreview() {
    // The fixtures live here rather than in a shared `Preview*` top-level so
    // nothing outside the IDE's preview renderer can reach them — that shared
    // indirection is how demo data ended up as the app's default parameter.
    val previewNow = System.currentTimeMillis()
    NalarTheme {
        MobileHomeScreen(
            workspaces = listOf(
                WorkspaceOption("ws-preview", "Preview workspace"),
                WorkspaceOption("ws-other", "Another workspace"),
            ),
            chats = listOf(
                ChatSummary("chat-preview-1", "ws-preview", "Preview chat", previewNow - 5L * 60_000L),
                ChatSummary("chat-preview-2", "ws-preview", "Second preview chat", previewNow - 3L * 60L * 60_000L),
            ),
        )
    }
}
