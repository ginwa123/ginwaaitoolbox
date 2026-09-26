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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
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
import kotlinx.coroutines.flow.first

/** Top-visible index that arms the older page, matching the web's load-more band. */
private const val LOAD_OLDER_INDEX_THRESHOLD = 2

/** Reserved key for the "earlier messages" row, which is not a message. */
private const val LOAD_OLDER_KEY = "__load_older__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

/**
 * Leading-edge rule that marks an unboxed diagnostic row, matching the web's
 * `.chat-tool-card` `border-left: 2px solid`.
 */
private val ruleWidth = 2.dp

/**
 * One sample of where the viewport is and whether the reader is driving it.
 *
 * A value class rather than three separate flows so a scroll and the position
 * it produced are always read from the same frame — splitting them let a
 * position arrive without the gesture that justified it.
 */
private data class ViewportReading(
    val lastVisibleIndex: Int,
    val totalItems: Int,
    val isScrolling: Boolean,
)

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
    onAnswer: (QuestionAnswer) -> Unit = {},
) {
    val groups = remember(state.messages) { groupMessages(state.messages) }
    val listState = rememberLazyListState()
    // Owned here, above the `LazyColumn`, because the per-card open/closed
    // state has to outlive the item being scrolled out of the viewport — a card
    // remembered inside the item would reset every time it is recycled.
    val toolExpansion = rememberToolExpansion()

    /**
     * The "earlier messages" row occupies index 0 when it is present, so a
     * group's LazyColumn index is its group index plus this. Getting it wrong
     * by one parks the auto-scroll on the second-to-last group and leaves the
     * newest turn below the fold.
     */
    val sentinelOffset = if (state.hasMoreOlder) 1 else 0

    /**
     * A fingerprint of the *tail* of the transcript.
     *
     * A streamed delta replaces the newest message in place: the same id in the
     * same group, the same number of items, taller by a line. Keyed on the
     * counts alone the list reports "nothing changed" while a live answer grows
     * out of the bottom of the viewport, which is why an answer used to stream
     * in under the fold and stay there.
     */
    val tailSignature = remember(state.messages) {
        val last = state.messages.lastOrNull()
        if (last == null) {
            ""
        } else {
            "${last.id}|${last.content.length}|${last.reasoningContent.length}|${last.isStreaming}"
        }
    }

    /**
     * Where the transcript belongs after each change, and whether it should
     * follow the end. One object rather than three `remember`ed values because
     * the three only mean anything together, and keeping them together is what
     * stops the "is the reader following?" flag from being recomputed against a
     * layout nobody has scrolled yet.
     */
    val chatScroll = remember { ChatScrollState() }
    val onLoadOlderNow by rememberUpdatedState(onLoadOlder)

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

    /**
     * Waits for the list to have measured the row a scroll is aimed at.
     *
     * `scrollToItem` resolves against measured item offsets, so a scroll issued
     * before the first layout has nothing to apply it to and is dropped. That
     * is exactly the frame a chat opens in: `openSession` paints an empty
     * transcript first when there is no cache, and the rows arrive a frame
     * later.
     */
    suspend fun awaitMeasuredItems() {
        if (listState.layoutInfo.totalItemsCount > 0) return
        snapshotFlow { listState.layoutInfo.totalItemsCount }.first { it > 0 }
    }

    suspend fun pinToNewest() {
        if (groups.isEmpty()) return
        awaitMeasuredItems()
        listState.scrollToItem(groups.lastIndex + sentinelOffset)
    }

    suspend fun restoreAnchor(action: ChatScrollAction.RestoreAnchor) {
        val groupIndex = groups.indexOfFirst { it.key == action.key }
        if (groupIndex < 0) {
            // The anchored turn is gone — grouped away, or paged out with the
            // page it came from. The newest turn beats a guess at an index.
            pinToNewest()
            return
        }
        awaitMeasuredItems()
        // The captured offset, not zero. The reader's message may have been
        // half scrolled past, and re-anchoring it by its top edge walks them a
        // little further up on every page they pull.
        listState.scrollToItem(groupIndex + sentinelOffset, action.offset)
    }

    // A new chat re-arms the backwards-page latch, so opening a transcript
    // whose top is on screen does not immediately request a page it already
    // holds.
    LaunchedEffect(state.sessionId) {
        loadOlderLatched = true
    }

    /**
     * Where the reader actually is.
     *
     * Keyed on the list alone. Re-creating this watcher every time the group
     * count changed re-delivered its first reading, and that first reading is a
     * layout of whatever the list was showing *before* the scroll that was
     * about to run — index 0 — so it read as "the reader has left the bottom"
     * and cancelled the very auto-scroll it was supposed to inform.
     *
     * It is the only thing that can clear the follow flag, and it does so only
     * for an interactive scroll. A programmatic scroll moves the viewport
     * exactly as much as a drag does and must not be mistaken for the reader
     * having left.
     */
    LaunchedEffect(listState) {
        snapshotFlow {
            ViewportReading(
                lastVisibleIndex = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1,
                totalItems = listState.layoutInfo.totalItemsCount,
                isScrolling = listState.isScrollInProgress,
            )
        }
            .distinctUntilChanged()
            .collect { reading ->
                chatScroll.onViewportMoved(
                    lastVisibleIndex = reading.lastVisibleIndex,
                    totalItems = reading.totalItems,
                    isScrolling = reading.isScrolling,
                )
            }
    }

    LaunchedEffect(listState, state.hasMoreOlder) {
        snapshotFlow { listState.firstVisibleItemIndex <= LOAD_OLDER_INDEX_THRESHOLD }
            .distinctUntilChanged()
            .collect { nearTop ->
                if (!nearTop) {
                    loadOlderLatched = false
                } else if (!loadOlderLatched) {
                    loadOlderLatched = true
                    if (state.hasMoreOlder && !state.isLoadingOlder) {
                        // Taken before the request, not after the response: the
                        // prepend renumbers every index above the reader, so an
                        // index captured afterwards names a different message.
                        chatScroll.armOlderPage(
                            listState.layoutInfo.visibleItemsInfo.firstOrNull()?.let { item ->
                                ChatScrollAnchor(item.key.toString(), item.offset)
                            },
                        )
                        onLoadOlderNow()
                    }
                }
            }
    }

    /**
     * The single effect that owns "the transcript changed, where does it
     * belong" — so a prepend, an append and an open can never fight over the
     * scroll position.
     *
     * Keyed on the session and on the tail, not on the counts. Two chats with
     * the same number of turns change neither count, so a count-keyed effect
     * never re-ran when the reader switched between them and the new chat
     * opened wherever the old one happened to be scrolled.
     */
    LaunchedEffect(
        state.sessionId,
        groups.size,
        state.messages.size,
        state.hasMoreOlder,
        tailSignature,
    ) {
        when (val action = chatScroll.onContentChanged(state.sessionId, groups.size)) {
            ChatScrollAction.Hold -> Unit
            is ChatScrollAction.PinToNewest -> pinToNewest()
            is ChatScrollAction.RestoreAnchor -> restoreAnchor(action)
        }
    }

    // Sending is an explicit "take me to the newest turn" — the reader is
    // looking at history, but the turn they just asked for lands at the end.
    LaunchedEffect(state.isSending) {
        if (state.isSending) {
            chatScroll.onTurnSent()
            pinToNewest()
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
                    ChatMessageGroupRow(groups[index], toolExpansion, onAnswer)
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
private fun ChatMessageGroupRow(
    group: ChatMessageGroup,
    toolExpansion: ToolExpansion,
    onAnswer: (QuestionAnswer) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_group_${group.role}"),
        horizontalAlignment = if (group.isUser) Alignment.End else Alignment.Start,
        // A boxed bubble brings its own separation; a flat paragraph does not,
        // so the gap carries it. See `groupGapDp`.
        verticalArrangement = Arrangement.spacedBy(groupGapDp(group).dp),
    ) {
        // Inside the group, not beside it. A tool call and the output that
        // answers it are one thing to look at, so the header for the calls
        // still in flight is the first line of the run rather than a list item
        // of its own. Empty unless [groupMessages] found a call with no card.
        if (group.unpairedToolCalls.isNotEmpty()) {
            ToolCallSummaryRow(
                calls = group.unpairedToolCalls,
                expansion = toolExpansion,
                // Namespaced: `group.key` is the first tool message's id, which
                // is also that card's expansion key, and sharing it would make
                // opening the header open the first card too.
                id = "tool-calls-${group.key}",
                modifier = Modifier.testTag("chat_tool_calls_${group.key}"),
            )
        }
        group.messages.forEach { message ->
            MessageRow(message, toolExpansion, onAnswer)
        }
    }
}

/**
 * One row, dispatched on what it is rather than what it looks like.
 *
 * Three kinds share the transcript: the reader's own bubble, the assistant's
 * paragraph, and a tool result. Deciding that here rather than at the call site
 * is what keeps a tool row from ever being drawn as a bubble — which is what it
 * did before, showing a label above a wall of raw JSON.
 *
 * A bare `tool_calls` declaration is *not* a third kind. [groupMessages] folds
 * it into the run that answers it and leaves what is left in
 * [ChatMessageGroup.unpairedToolCalls], so there is nothing here for it to
 * dispatch to.
 */
@Composable
private fun MessageRow(
    message: ChatMessage,
    toolExpansion: ToolExpansion,
    onAnswer: (QuestionAnswer) -> Unit,
) {
    when (messageChrome(message)) {
        MessageChrome.TOOL_CARD -> {
            // Parsed once per distinct row, not once per recomposition: a
            // streaming turn re-renders its card on every appended delta.
            val model = remember(message) { ToolCard.from(message) }
            ToolCardView(
                model = model,
                expanded = toolExpansion.isExpanded(model.id, model.defaultsExpanded),
                onToggle = { toolExpansion.toggle(model.id, model.defaultsExpanded) },
                onAnswer = onAnswer,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("chat_tool_${message.id}"),
            )
        }

        MessageChrome.BUBBLE -> UserMessageBubble(message)

        MessageChrome.PARAGRAPH -> AssistantMessageParagraph(message)
    }
}

/**
 * The reader's own turn — the one row that is a bubble.
 *
 * Tinted, outlined, rounded, right-aligned, and capped so a one-word "ok" does
 * not stretch a slab across the screen. This is the web's `max-w-[90%] w-fit
 * ml-auto` on a blue fill, and it is the only reason a reader can pick their own
 * questions out of a long transcript at a glance.
 */
@Composable
private fun UserMessageBubble(message: ChatMessage) {
    val contentColor = if (message.isError) NalarError else NalarText

    Column(
        modifier = Modifier.widthIn(max = 460.dp),
        horizontalAlignment = Alignment.End,
    ) {
        Surface(
            modifier = Modifier.testTag("chat_message_${message.id}"),
            color = NalarBackgroundRaised,
            contentColor = contentColor,
            shape = RoundedCornerShape(14.dp),
            border = BorderStroke(1.dp, NalarBorder),
        ) {
            Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                MessageBody(message, contentColor)
            }
        }

        StreamingHint(isStreaming = message.isStreaming)
    }
}

/**
 * Everything the assistant says, as a paragraph.
 *
 * No `Surface`, so no fill, no outline, no corner radius and none of the 12/10
 * dp bubble padding — the page background runs through behind the answer. That
 * is the whole point: a long assistant turn and the tool cards interleaved with
 * it then share one measure, so the transcript reads as a document instead of
 * alternating full-width prose with inset boxes. The web made this same call in
 * 2026-08-23 ("paragraph mode"), and the two are kept in step deliberately —
 * see `MessageChrome` for the rule.
 *
 * The width cap goes with the box for the same reason: it existed to stop a
 * bubble from spanning a tablet, and prose that runs to the margin is what the
 * web does (`flex-1 w-full max-w-full`).
 */
@Composable
private fun AssistantMessageParagraph(message: ChatMessage) {
    val contentColor = if (message.isError) NalarError else NalarText

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_message_${message.id}"),
        horizontalAlignment = Alignment.Start,
    ) {
        /**
         * An agentic-loop diagnostic frame carries prose like any other
         * assistant turn, so it gets no box either — but it still has to be
         * findable, and unboxed red text on a dark page is not. A 2dp rule down
         * the leading edge marks the row without wrapping it, which is the
         * web's `.chat-tool-card` marker (`border-left: 2px solid`, recoloured
         * for the error variant) used on the same page.
         */
        val diagnosticRule = if (message.isError) {
            Modifier.drawBehind {
                drawRect(color = NalarError, size = Size(ruleWidth.toPx(), size.height))
            }
        } else {
            Modifier
        }

        Column(
            modifier = diagnosticRule
                .fillMaxWidth()
                .padding(start = if (message.isError) 8.dp else 0.dp),
        ) {
            MessageBody(message, contentColor)
        }

        StreamingHint(isStreaming = message.isStreaming)
    }
}

/** The "still arriving" note, hung below the row it belongs to, never inside it. */
@Composable
private fun StreamingHint(isStreaming: Boolean) {
    if (!isStreaming) return
    Text(
        text = "streaming…",
        style = MaterialTheme.typography.labelSmall,
        color = NalarDim,
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}

/**
 * The content of a turn, with no frame around it.
 *
 * Shared by the bubble and the paragraph so the two cannot drift apart. The
 * web draws the same split in the *content* as in the chrome: an assistant
 * turn is `marked.parse`d into `.markdown-content`, a reader turn is plain
 * `{{ text }}` in a `whitespace-pre-wrap` bubble — a question the reader typed
 * has to come back looking exactly as it was sent, and parsing their `**` and
 * `_` would change their own words back at them.
 */
@Composable
private fun MessageBody(message: ChatMessage, contentColor: Color) {
    if (message.reasoningContent.isNotBlank()) {
        Text(
            text = message.reasoningContent,
            style = MaterialTheme.typography.bodySmall,
            color = NalarDim,
            fontFamily = FontFamily.Monospace,
        )
        Spacer(Modifier.height(6.dp))
    }
    if (message.hasRenderableContent) {
        if (message.isUser) {
            Text(
                text = message.content,
                style = MaterialTheme.typography.bodyMedium,
                color = contentColor,
                modifier = Modifier.testTag("chat_body_${message.id}"),
            )
        } else {
            MarkdownText(
                source = message.content,
                color = contentColor,
                modifier = Modifier.testTag("chat_body_${message.id}"),
            )
        }
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
            // The bytes are data URLs held in a cache row; a real image loader
            // renders them, this is the count.
            modifier = Modifier.testTag("chat_attachments"),
        )
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
