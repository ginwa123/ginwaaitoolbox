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
import androidx.compose.material.icons.filled.Add
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.recents.WorkspaceOption
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
 * Whether the agent is working, from the two signals that can say so.
 *
 * Neither alone is right, and the gap each one leaves is the same shape — a
 * reader told the agent is idle while it is plainly busy.
 *
 * - [isRunning] is the backend's own answer and it holds between turns, so it
 *   is the one that survives a long tool run that emits no deltas at all. It
 *   arrives over the `workers` channel, so there is a window after a send
 *   returns and before that frame lands.
 * - [isStreaming] is instantaneous, and so covers exactly that window — but it
 *   drops on `chunk_final` and only returns with the next chunk, which turns a
 *   two-minute tool call into a series of silent pauses.
 *
 * The disjunction is also the safe direction for both mistakes: a header that
 * says "Working…" for a moment after a run ended costs a glance, and a header
 * that says "Live" for a two-minute tool call is a report the reader learns to
 * stop believing, which is the failure that actually has to be avoided.
 */
fun isChatWorking(isRunning: Boolean, isStreaming: Boolean): Boolean = isRunning || isStreaming

/**
 * The header's word for the run, with no queue or agent counts attached.
 *
 * Split out of [ChatStatusLine] so the mapping is testable without a device —
 * which matters because this is a composable whose whole surface is a
 * `when` over two booleans, and a one-line rule that only instrumented tests
 * can reach is a rule that quietly stops being true.
 */
fun chatStatusLabel(isWorking: Boolean, isLive: Boolean): String = when {
    isWorking -> "Working…"
    isLive -> "Live"
    else -> "Reconnecting…"
}

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
 * idea of what a chat list is. It carries no "all chats" row of its own — the
 * list it opens *is* the list that row used to lead to, so a row that returns
 * the reader to the top of a list already in front of them is a second route to
 * where they are standing. The one way out that is not the drawer is the system
 * Back button, and the graph owns that: see
 * [com.nalar.mobile.network.NalarNavGraph].
 *
 * The title and the live indicator live in the route's top bar, and the stop
 * control lives in the composer — beside the send it replaces, so the row
 * never offers "start a turn" and "end a turn" at the same time. There is
 * exactly one title bar and one way to interrupt a run.
 *
 * The bar's `actions` slot carries the one thing a reader inside a chat wants
 * that is not this chat: a new one. Everything else the web puts in a bar —
 * renaming, compacting, the worktree menu — either has no place on a phone
 * bar or is a per-account setting the desktop's settings screen already owns.
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
    /**
     * Start a new chat, and put this one behind it.
     *
     * A callback and not a navigation, because the graph owns navigation *and*
     * the create: a chat belongs to a project, so the press has to become
     * "which project?" before it can become a `POST`. See
     * [com.nalar.mobile.network.NalarNavGraph].
     */
    onNewChat: () -> Unit = {},
    /**
     * A create is in flight.
     *
     * The affordance only. [com.nalar.mobile.recents.HomeViewModel.createTask]
     * refuses a second one, so this is what stops the reader being offered a
     * button that silently does nothing rather than saying "busy".
     */
    isCreatingChat: Boolean = false,
    /**
     * Put this chat on a different profile, or clear the override with `""`.
     */
    onSelectModel: (String) -> Unit = {},
    /**
     * A picked image, as the picker's own string.
     *
     * The picker launcher itself lives in `ChatView`, which owns the
     * composer — this slot only carries the result down to whoever decodes
     * it, so the paperclip cannot be wired to a picker that does not open.
     */
    onAttachmentPicked: (String) -> Unit = {},
    /** Drop one pending attachment, by the id its row carries. */
    onRemoveAttachment: (String) -> Unit = {},
    onLoadOlder: () -> Unit = {},
    onDismissError: () -> Unit = {},
    onAnswer: (QuestionAnswer) -> Unit = {},
    /**
     * The transcript is standing where it belongs and there is nothing left to
     * wait for.
     *
     * A launch holds a screen over this one until this fires, because a chat
     * that is on screen a frame before its auto-scroll has run shows the top of
     * the transcript and then jumps to the bottom — the one thing a reader who
     * just reopened their last chat would notice. See
     * [com.nalar.mobile.network.launchGateIsUp].
     */
    onTranscriptSettled: (String?) -> Unit = {},
    /**
     * Whether a worker is registered for this session — the backend's own
     * definition of "the agent is working", and the one that holds between
     * turns. `state.isStreaming` is per-*delta*: it drops on `chunk_final` and
     * only returns with the next chunk, so a long tool run reads as a series of
     * separate silent pauses. This does not.
     *
     * It now drives the status line's word and the stop control as well as the
     * spinner, because a header that knows a run is going and a header that
     * will not offer to stop it are telling the reader two different things.
     * See [isChatWorking] for how the two signals combine.
     */
    isRunning: Boolean = false,
    /**
     * What the hamburger opens, and the widest way out of the chat into the
     * rest of the app.
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
    // One answer for the label and the stop control, so they can never disagree
    // about whether there is a run to interrupt.
    val isWorking = isChatWorking(isRunning = isRunning, isStreaming = state.isStreaming)

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
                                isWorking = isWorking,
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
                        // The one thing the bar offers, and it is *not* the
                        // stop control: that lives in the composer beside the
                        // send it replaces, so there is exactly one answer to
                        // "can I end this run" and it is on the control the
                        // reader is already holding.
                        //
                        // A new chat, because a reader who has finished with
                        // this one should not have to walk back through the
                        // drawer, find the right project, and tap its `+` — the
                        // drawer already has that path, and this is the one
                        // that starts from where they are standing.
                        IconButton(
                            onClick = onNewChat,
                            // Inert while a create is in flight. The ViewModel
                            // guards it too; this is the affordance, that is
                            // the invariant. Two chats from one tap is the
                            // failure this exists to prevent.
                            enabled = !isCreatingChat,
                            modifier = Modifier
                                .testTag("chat_new_chat")
                                .semantics { contentDescription = "New chat" },
                        ) {
                            if (isCreatingChat) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(18.dp),
                                    strokeWidth = 2.dp,
                                    color = NalarDim,
                                )
                            } else {
                                Icon(
                                    imageVector = Icons.Filled.Add,
                                    contentDescription = null,
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
                    onStop = onStop,
                    onSelectModel = onSelectModel,
                    isRunning = isRunning,
                    onAttachmentPicked = onAttachmentPicked,
                    onRemoveAttachment = onRemoveAttachment,
                    onLoadOlder = onLoadOlder,
                    onDismissError = onDismissError,
                    onAnswer = onAnswer,
                    onTranscriptSettled = onTranscriptSettled,
                )
            }
        }
    }
}

@Composable
private fun ChatStatusLine(
    isLive: Boolean,
    isWorking: Boolean,
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
                append(chatStatusLabel(isWorking = isWorking, isLive = isLive))
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
                )
            },
        )
    }
}
