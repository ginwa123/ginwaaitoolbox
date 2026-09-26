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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import com.nalar.mobile.ui.NalarTheme

/**
 * The chat as its own destination, with a back affordance.
 *
 * A chat is a *view*, so it gets a route rather than living in a local
 * `selectedChatId` boolean. That is what makes it survive process death, work
 * with the system Back button, and be reachable from a shared
 * `nalar://chat/{sessionId}` link — the same contract the network inspector
 * already has.
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
    onBack: () -> Unit,
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
) {
    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .testTag("chat_screen"),
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
                        onClick = onBack,
                        modifier = Modifier.testTag("chat_back"),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back to chats",
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
    NalarTheme {
        ChatScreen(
            state = ChatUiState(sessionId = "preview", isLoading = true, isLive = true),
            chatTitle = "Preview chat",
            onBack = {},
        )
    }
}
