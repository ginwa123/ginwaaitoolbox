package com.nalar.mobile.chat

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarBackgroundRaised
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarField
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import com.nalar.mobile.ui.NalarTheme
import kotlinx.coroutines.flow.distinctUntilChanged

/** Top-visible index that arms the older page, matching the web's load-more band. */
private const val LOAD_OLDER_INDEX_THRESHOLD = 2

/** Reserved key for the "earlier messages" row, which is not a message. */
private const val LOAD_OLDER_KEY = "__load_older__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

private data class ListAnchor(val key: String, val offset: Int)

/**
 * One chat: a virtualized transcript and a composer.
 *
 * **The transcript is a `LazyColumn`**, Compose's `RecyclerView`: only the rows
 * inside the viewport are composed, so a thousand-turn session costs the same
 * as a ten-turn one. Three things make that actually hold rather than being a
 * `LazyColumn` in name only, and all three are load-bearing:
 *
 * 1. **Stable keys** (`group.key`, the first message id of each group). An index
 *    key silently re-keys every row above an append, which throws away the
 *    per-item state — expanded tool cards, for one — and re-composes the whole
 *    list on every streamed delta. A duplicated key is worse: `LazyColumn`
 *    throws on it.
 * 2. **`contentType`**, so a run of tool cards reuses the same composable instead
 *    of alternating layouts down the whole list.
 * 3. **Grouping consecutive same-role turns** ([groupMessages]) *before* the
 *    list sees them. A long tool run is dozens of rows that would otherwise be
 *    dozens of list items, each one forcing a measure and a compose.
 *
 * Nothing here renders the full message list into a nested scrollable — a
 * `Column` inside a `Column` with `verticalScroll` would defeat the
 * virtualizer entirely and is the usual way a "virtualized" chat is not.
 */
@Composable
fun ChatView(
    state: ChatUiState,
    modifier: Modifier = Modifier,
    onDraftChanged: (String) -> Unit = {},
    onSend: () -> Unit = {},
    onLoadOlder: () -> Unit = {},
    onDismissError: () -> Unit = {},
) {
    val groups = remember(state.messages) { groupMessages(state.messages) }
    val listState = rememberLazyListState()

    /**
     * The "earlier messages" row occupies index 0 when it is present, so a
     * group's LazyColumn index is its group index plus this. Getting it wrong
     * by one parks the auto-scroll on the second-to-last group and leaves the
     * newest turn below the fold.
     */
    val sentinelOffset = if (state.hasMoreOlder) 1 else 0

    /**
     * Whether new content should pull the viewport. Tracks the reader's own
     * position so an append never yanks them out of the history they are
     * reading — the web's `isAtBottom`, minus the hysteresis it needs for
     * measured (non-virtualized) rows.
     */
    var followBottom by remember { mutableStateOf(true) }
    var lastItemCount by remember { mutableIntStateOf(0) }

    /**
     * The top visible item's key and offset, captured when an older page is
     * requested. Re-anchoring by key rather than by index is what keeps the
     * reader on the same message after rows are prepended above them.
     */
    var pendingAnchor by remember { mutableStateOf<ListAnchor?>(null) }

    /**
     * One page per approach to the top.
     *
     * Without this latch, the prepend leaves the anchor near the top, the
     * watcher re-arms, and a single flick pulls the entire session back to the
     * beginning with no further input — the exact opposite of paging. Initial
     * state is `true` so the very first layout, which reports index 0 before
     * anything has been scrolled, does not fetch either.
     */
    var loadOlderLatched by remember { mutableStateOf(true) }

    LaunchedEffect(state.sessionId) {
        listState.scrollToItem(0)
        followBottom = true
        lastItemCount = 0
        loadOlderLatched = true
    }

    LaunchedEffect(listState, groups.size) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1 }
            .distinctUntilChanged()
            .collect { lastVisible ->
                val total = listState.layoutInfo.totalItemsCount
                if (total > 0) followBottom = lastVisible >= total - 1
            }
    }

    LaunchedEffect(listState, groups.size, state.hasMoreOlder) {
        snapshotFlow { listState.firstVisibleItemIndex <= LOAD_OLDER_INDEX_THRESHOLD }
            .distinctUntilChanged()
            .collect { nearTop ->
                if (!nearTop) {
                    loadOlderLatched = false
                } else if (!loadOlderLatched) {
                    loadOlderLatched = true
                    if (state.hasMoreOlder && !state.isLoadingOlder) {
                        pendingAnchor = listState.layoutInfo.visibleItemsInfo
                            .firstOrNull()
                            ?.let { ListAnchor(it.key.toString(), it.offset) }
                        onLoadOlder()
                    }
                }
            }
    }

    // One effect owns "the list changed", so a prepend and an append can never
    // fight over the scroll position.
    LaunchedEffect(groups.size, state.messages.size) {
        val anchor = pendingAnchor
        val delta = groups.size - lastItemCount
        when {
            anchor != null && delta > 0 -> {
                val restored = groups.indexOfFirst { it.key == anchor.key } + sentinelOffset
                listState.scrollToItem(restored.coerceIn(0, groups.lastIndex.coerceAtLeast(0)))
                pendingAnchor = null
            }

            // A brand-new session should land on the newest turn even if the
            // reader was scrolled up in the previous one.
            delta < 0 -> {
                listState.scrollToItem(groups.lastIndex.coerceAtLeast(0) + sentinelOffset)
                followBottom = true
            }

            followBottom && groups.isNotEmpty() -> {
                listState.scrollToItem(groups.lastIndex + sentinelOffset)
            }
        }
        lastItemCount = groups.size
    }

    // Sending is an explicit "take me to the newest turn" — the reader is
    // looking at history, but the turn they just asked for lands at the end.
    LaunchedEffect(state.isSending) {
        if (state.isSending && groups.isNotEmpty()) {
            listState.scrollToItem(groups.lastIndex + sentinelOffset)
            followBottom = true
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(NalarBackground)
            .testTag("chat_view"),
    ) {
        AnimatedVisibility(visible = state.errorMessage != null) {
            ChatErrorBanner(
                message = state.errorMessage.orEmpty(),
                isShowingStaleData = state.isShowingStaleData,
                onDismiss = onDismissError,
            )
        }

        Box(modifier = Modifier.weight(1f)) {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .testTag("chat_message_list"),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (state.hasMoreOlder) {
                    item(key = LOAD_OLDER_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                        LoadOlderSentinel(isLoading = state.isLoadingOlder)
                    }
                }

                items(
                    count = groups.size,
                    // A stable identity, never the index: an index key re-keys
                    // every row above an append and discards per-item state.
                    key = { index -> groups[index].key },
                    contentType = { index -> groups[index].role },
                ) { index ->
                    ChatMessageGroupRow(groups[index])
                }
            }

            when {
                state.isLoading && state.messages.isEmpty() -> Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.testTag("chat_loading"),
                        color = NalarAccent,
                    )
                }

                state.isEmptyConversation -> Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "No messages yet. Say something to start.",
                        modifier = Modifier.testTag("chat_empty"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = NalarMuted,
                    )
                }
            }
        }

        ChatComposer(
            draft = state.draft,
            isSending = state.isSending,
            onDraftChanged = onDraftChanged,
            onSend = onSend,
        )
    }
}

@Composable
private fun ChatErrorBanner(
    message: String,
    isShowingStaleData: Boolean,
    onDismiss: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .testTag("chat_error"),
        color = NalarField,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, NalarBorder),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (isShowingStaleData) "$message Showing the last saved copy." else message,
                style = MaterialTheme.typography.bodySmall,
                color = NalarMuted,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onDismiss) { Text("Dismiss", color = NalarMuted) }
        }
    }
}

@Composable
private fun LoadOlderSentinel(isLoading: Boolean) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_load_older"),
        contentAlignment = Alignment.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = NalarAccent,
            )
        } else {
            Text(
                text = "Scroll for earlier messages",
                style = MaterialTheme.typography.labelSmall,
                color = NalarDim,
            )
        }
    }
}

@Composable
private fun ChatMessageGroupRow(group: ChatMessageGroup) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_group_${group.role}"),
        horizontalAlignment = if (group.isUser) Alignment.End else Alignment.Start,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        group.messages.forEach { message ->
            MessageBubble(message)
        }
    }
}

@Composable
private fun MessageBubble(message: ChatMessage) {
    val isError = message.isError
    val container = if (isError || message.isUser) NalarBackgroundRaised else NalarField
    val contentColor = if (isError) NalarError else NalarText

    Column(
        modifier = Modifier.widthIn(max = 460.dp),
        horizontalAlignment = if (message.isUser) Alignment.End else Alignment.Start,
    ) {
        // The tool name is the row's label, so a run of tool cards reads as a
        // sequence rather than as a wall of identical bubbles.
        if (message.toolName.isNotBlank()) {
            Text(
                text = message.toolName,
                style = MaterialTheme.typography.labelSmall,
                color = NalarDim,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }

        Surface(
            modifier = Modifier.testTag("chat_message_${message.id}"),
            color = container,
            contentColor = contentColor,
            shape = RoundedCornerShape(14.dp),
            border = BorderStroke(1.dp, NalarBorder),
        ) {
            Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                if (message.reasoningContent.isNotBlank()) {
                    Text(
                        text = message.reasoningContent,
                        style = MaterialTheme.typography.bodySmall,
                        color = NalarDim,
                        fontFamily = FontFamily.Monospace,
                    )
                    Spacer(Modifier.height(6.dp))
                }
                if (message.content.isNotBlank()) {
                    Text(
                        text = message.content,
                        style = MaterialTheme.typography.bodyMedium,
                        color = contentColor,
                    )
                }
                if (message.imageUrls.isNotEmpty() || message.videoUrls.isNotEmpty()) {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = buildString {
                            if (message.imageUrls.isNotEmpty()) {
                                append("${message.imageUrls.size} image(s)")
                            }
                            if (message.videoUrls.isNotEmpty()) {
                                if (isNotEmpty()) append(" · ")
                                append("${message.videoUrls.size} video(s)")
                            }
                        },
                        style = MaterialTheme.typography.labelSmall,
                        color = NalarDim,
                        // The bytes are data URLs held in a cache row; a real
                        // image loader renders them, this is the count.
                        modifier = Modifier.testTag("chat_attachments"),
                    )
                }
            }
        }

        if (message.isStreaming) {
            Text(
                text = "streaming…",
                style = MaterialTheme.typography.labelSmall,
                color = NalarDim,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}

@Composable
private fun ChatComposer(
    draft: String,
    isSending: Boolean,
    onDraftChanged: (String) -> Unit,
    onSend: () -> Unit,
) {
    val onDraft by rememberUpdatedState(onDraftChanged)
    val canSend = draft.isNotBlank() && !isSending

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .imePadding()
            .background(NalarBackground)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        TextField(
            value = draft,
            onValueChange = onDraft,
            modifier = Modifier
                .weight(1f)
                .testTag("chat_composer_input"),
            placeholder = {
                Text("Message", style = MaterialTheme.typography.bodyMedium)
            },
            textStyle = MaterialTheme.typography.bodyMedium,
            maxLines = 5,
            shape = RoundedCornerShape(20.dp),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = NalarField,
                unfocusedContainerColor = NalarField,
                focusedTextColor = NalarText,
                unfocusedTextColor = NalarText,
                focusedPlaceholderColor = NalarDim,
                unfocusedPlaceholderColor = NalarDim,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
            ),
        )

        Spacer(Modifier.size(8.dp))

        Surface(
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .testTag("chat_send"),
            color = if (canSend) NalarAccent else NalarField,
            shape = CircleShape,
        ) {
            IconButton(
                onClick = onSend,
                enabled = canSend,
                modifier = Modifier.fillMaxSize(),
            ) {
                Icon(
                    imageVector = Icons.Filled.ArrowUpward,
                    contentDescription = "Send message",
                    tint = if (canSend) NalarBackground else NalarDim,
                )
            }
        }
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun ChatViewPreview() {
    NalarTheme {
        ChatView(
            state = ChatUiState(
                sessionId = "preview",
                isLoading = false,
                isLive = true,
                messages = listOf(
                    ChatMessage(
                        id = "m1",
                        role = ChatMessage.ROLE_USER,
                        content = "Add a ChatView to the Android app.",
                        createdAtEpochMillis = 1_789_000_000_000,
                        sortKeyNanos = 1_789_000_000_000_000_000,
                    ),
                    ChatMessage(
                        id = "m2",
                        role = ChatMessage.ROLE_ASSISTANT,
                        content = "On it — a LazyColumn keeps the transcript virtualized.",
                        createdAtEpochMillis = 1_789_000_001_000,
                        sortKeyNanos = 1_789_000_001_000_000_000,
                    ),
                ),
            ),
        )
    }
}
