package com.nalar.mobile.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.WorkspaceOption
import com.nalar.mobile.shell.BackToChatsRow
import com.nalar.mobile.shell.RecentsDrawerContent
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import com.nalar.mobile.ui.NalarTheme
import kotlinx.coroutines.launch

/**
 * The chat as its own destination, with the recents drawer one tap away.
 *
 * A chat is a *view*, so it gets a route rather than living in a local
 * `selectedChatId` boolean. That is what makes it survive process death, work
 * with the system Back button, and be reachable from a shared
 * `nalar://chat/{sessionId}` link — the same contract the network inspector
 * already has.
 *
 * The top bar leads with a hamburger rather than a back arrow. A reader who
 * came here from the recents list is usually not trying to go back — they are
 * switching to the chat next to this one — and the drawer is the only place
 * that can offer a whole workspace of them plus a way to sign out. An arrow
 * could only ever offer one of those, and it offered it on a screen the reader
 * had to leave the transcript to use.
 *
 * The drawer is the same sidebar the shell shows, supplied by the caller: the
 * screen owns the sheet, the state and the swipe, and must not grow its own
 * idea of what a chat list is. The route supplies the content, including the
 * row that leads back to the chat list, because that row is navigation and
 * navigation belongs to the graph.
 *
 * The title, the live indicator and Stop live in the route's top bar rather than
 * in a second header above the transcript, so there is exactly one title bar and
 * the stop control is actually reachable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    state: ChatUiState,
    chatTitle: String,
    modifier: Modifier = Modifier,
    onDraftChanged: (String) -> Unit = {},
    onSend: () -> Unit = {},
    onStop: () -> Unit = {},
    onLoadOlder: () -> Unit = {},
    onDismissError: () -> Unit = {},
    onAnswer: (QuestionAnswer) -> Unit = {},
    /**
     * Whether a worker is registered for this session — the backend's own
     * definition of "the agent is working", and the one that holds between
     * turns. `state.isStreaming` is per-*delta*: it drops on `chunk_final` and
     * only returns with the next chunk, so a long tool run reads as a series of
     * separate silent pauses. This does not.
     */
    isRunning: Boolean = false,
    /**
     * What the hamburger opens, and the only way out of the chat into the rest
     * of the app.
     *
     * It is handed the drawer so it can close it: a chat picked from the list is
     * a destination the reader is moving to, and leaving the list open on top of
     * it would hide the very transcript they asked for. Required rather than
     * defaulted because a hamburger that opens an empty sheet is a control that
     * does nothing.
     */
    drawerContent: @Composable (dismissDrawer: () -> Unit) -> Unit,
) {
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val coroutineScope = rememberCoroutineScope()
    val dismissDrawer: () -> Unit = { coroutineScope.launch { drawerState.close() } }

    ModalNavigationDrawer(
        drawerState = drawerState,
        modifier = modifier
            .fillMaxSize()
            .testTag("chat_screen"),
        drawerContent = {
            ModalDrawerSheet(
                // Same tag as the shell's sheet: it is the same drawer, and a
                // test should not have to know which route opened it.
                modifier = Modifier.testTag("sidebar_sheet"),
                drawerState = drawerState,
                drawerContainerColor = NalarBackground,
                drawerContentColor = NalarText,
            ) {
                drawerContent(dismissDrawer)
            }
        },
    ) {
        Scaffold(
            containerColor = NalarBackground,
            topBar = {
                TopAppBar(
                    title = {
                        Column {
                            Text(
                                text = chatTitle,
                                color = NalarText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.testTag("chat_title"),
                            )
                            ChatStatusLine(
                                isLive = state.isLive,
                                isStreaming = state.isStreaming,
                                queuedCount = state.queuedCount,
                                subAgentsRunning = state.subAgentsRunning,
                                subAgentsTotal = state.subAgentsTotal,
                                subAgentsFailed = state.subAgentsFailed,
                                isRunning = isRunning,
                            )
                        }
                    },
                    navigationIcon = {
                        IconButton(
                            onClick = { coroutineScope.launch { drawerState.open() } },
                            modifier = Modifier.testTag("chat_drawer_menu"),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Menu,
                                contentDescription = "Open chats and workspaces",
                            )
                        }
                    },
                    actions = {
                        // Only while a run is actually going, so it is never a
                        // button that does nothing.
                        if (state.isStreaming) {
                            IconButton(
                                onClick = onStop,
                                modifier = Modifier.testTag("chat_stop"),
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.Stop,
                                    contentDescription = "Stop the run",
                                    tint = NalarError,
                                )
                            }
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
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(contentPadding),
            ) {
                ChatView(
                    state = state,
                    onDraftChanged = onDraftChanged,
                    onSend = onSend,
                    onLoadOlder = onLoadOlder,
                    onDismissError = onDismissError,
                    onAnswer = onAnswer,
                )
            }
        }
    }
}

@Composable
private fun ChatStatusLine(
    isLive: Boolean,
    isStreaming: Boolean,
    queuedCount: Int,
    subAgentsRunning: Int,
    subAgentsTotal: Int,
    subAgentsFailed: Int,
    isRunning: Boolean = false,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(if (isLive) NalarAccent else NalarDim)
                .testTag("chat_live_dot"),
        )
        Spacer(Modifier.size(6.dp))
        Text(
            text = buildString {
                append(
                    when {
                        isStreaming -> "Working…"
                        isLive -> "Live"
                        else -> "Reconnecting…"
                    },
                )
                // A turn that looks like it vanished is usually still queued,
                // and saying so is the difference between "slow" and "broken".
                if (queuedCount > 0) append(" · $queuedCount queued")
                // A fan-out emits no rows at all until every sub-agent is done,
                // so without this a two-minute spawn_sub_agent is
                // indistinguishable from a hang.
                if (subAgentsRunning > 0 || subAgentsFailed > 0) {
                    append(" · $subAgentsRunning/$subAgentsTotal agents")
                }
                // A fan-out that finished with failures and nothing left running
                // shows only this, or the header would go quiet right when the
                // reader is waiting to find out whether it worked.
                if (subAgentsRunning == 0 && subAgentsFailed > 0) {
                    append(" · $subAgentsFailed failed")
                }
            },
            style = MaterialTheme.typography.labelSmall,
            color = if (queuedCount > 0) NalarMuted else NalarDim,
            modifier = Modifier.testTag("chat_live_label"),
        )
        // Trailing, after the label rather than before it: the label is prose
        // that has to keep its position so the two lines of the top bar do not
        // dance, and a spinner is decoration on top of whatever it says.
        if (isRunning) {
            Spacer(Modifier.size(6.dp))
            CircularProgressIndicator(
                modifier = Modifier
                    .clearAndSetSemantics { }
                    .size(10.dp)
                    .testTag("chat_running_spinner"),
                strokeWidth = 1.5.dp,
                color = NalarAccent,
            )
        }
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun ChatScreenPreview() {
    // The preview carries the same drawer the route supplies, so the hamburger
    // in the bar is never a button that opens nothing.
    val previewNow = System.currentTimeMillis()
    NalarTheme {
        ChatScreen(
            state = ChatUiState(sessionId = "preview", isLoading = true, isLive = true),
            chatTitle = "Preview chat",
            drawerContent = { dismissDrawer ->
                RecentsDrawerContent(
                    workspaces = listOf(
                        WorkspaceOption("ws-preview", "Preview workspace"),
                    ),
                    chats = listOf(
                        ChatSummary(
                            id = "chat-preview-1",
                            workspaceId = "ws-preview",
                            title = "Preview chat",
                            updatedAtEpochMillis = previewNow,
                        ),
                    ),
                    selectedWorkspaceId = "ws-preview",
                    selectedChatId = "preview",
                    onWorkspaceSelected = {},
                    onChatSelected = {},
                    onOpenChat = dismissDrawer,
                    header = { BackToChatsRow(onClick = dismissDrawer) },
                )
            },
        )
    }
}
