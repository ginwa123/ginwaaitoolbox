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
import androidx.compose.foundation.lazy.LazyListLayoutInfo
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
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
import kotlinx.coroutines.launch

/** Top-visible index that arms the older page, matching the web's load-more band. */
private const val LOAD_OLDER_INDEX_THRESHOLD = 2

/** Reserved key for the "earlier messages" row, which is not a message. */
private const val LOAD_OLDER_KEY = "__load_older__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

/**
 * How close to the end counts as being at it.
 *
 * A transcript parked on its newest turn measures zero (the geometry clamps
 * content that is not below the fold), so this band is not about the end
 * position — it is about a reader one or two lines above it. Without it the
 * control flickers on and off under a slow drag; with it, it appears once a
 * reader has genuinely left the end rather than every time they twitch.
 */
private val JUMP_TO_NEWEST_BAND = 24.dp

/**
 * How far the bottom of the transcript is below the bottom of the viewport, in
 * pixels: zero at the end, larger the further away, [DISTANCE_FAR] when the end
 * is not on screen at all, [DISTANCE_UNMEASURED] when nothing has been laid out.
 *
 * **Pixels rather than item indices.** The index reading answers a different
 * question: a single answer taller than the screen keeps its group as the last
 * visible item for the whole time it is being read, so "is the newest turn on
 * screen" answers yes to a reader who has scrolled most of the way up it. See
 * [ChatScrollPolicy.shouldOfferJumpToNewest].
 *
 * Two things this cannot be naively computed from `visibleItemsInfo`, and both
 * of them were wrong before they were written down:
 *
 * 1. **`lastOrNull()` is the row straddling the viewport's bottom edge, not the
 *    last row in the list.** Subtracting only that row gives a number bounded by
 *    one row's height, which resets at every row boundary — the control would
 *    flicker on and off however far the reader had actually gone, and vanish at
 *    their resting position. A `LazyColumn` cannot tell us how far the end is
 *    when the end has not been composed, so it does not pretend to: any turn
 *    still below the fold is [DISTANCE_FAR].
 * 2. **A transcript that does not fill the viewport** — a two-turn chat, a fresh
 *    one — parks its last row near the *top* of the screen, so the raw
 *    difference between the two is most of the screen's height and reads as "a
 *    long way from the end" for a reader who has not moved. Content that is not
 *    below the fold is zero.
 */
internal fun LazyListLayoutInfo.distanceFromBottomPx(): Int {
    if (totalItemsCount == 0) return DISTANCE_UNMEASURED
    val lastVisible = visibleItemsInfo.lastOrNull() ?: return DISTANCE_UNMEASURED
    if (lastVisible.index != totalItemsCount - 1) return DISTANCE_FAR
    val contentBottom = lastVisible.offset + lastVisible.size
    if (contentBottom <= viewportEndOffset) return 0
    return contentBottom - viewportEndOffset
}

/**
 * How far into the last turn the viewport must be scrolled for the very end of
 * the transcript — trailing content padding included — to be on screen. Zero when
 * landing on the turn's top already achieves that.
 *
 * An *absolute* offset into the item, which is what `scrollToItem` takes, and
 * never negative: `LazyListState` rejects a negative scroll offset outright, so
 * a turn too short to need one has to clamp to zero rather than ask for one.
 *
 * The geometry: scrolling by `x` leaves the turn's top `x` above the viewport's
 * top, so its bottom — plus the trailing padding, which is part of the end —
 * lands on the viewport's bottom edge when
 * `-x + lastItemSize + afterContentPadding == viewportEndOffset`. The same
 * [viewportEndOffset] frame as [distanceFromBottomPx], deliberately, so the
 * offset that reaches the end and the reading that says the reader has arrived
 * cannot disagree.
 */
internal fun scrollOffsetToShowTheEndOf(
    lastItemSize: Int,
    viewportEndOffset: Int,
    afterContentPadding: Int,
): Int = (lastItemSize + afterContentPadding - viewportEndOffset).coerceAtLeast(0)

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

    /**
     * The end of the transcript, for a reader who *asked* to be put there.
     *
     * [pinToNewest] aligns the newest turn's top with the viewport's top, which
     * is the right answer while a reply is streaming — the reader is reading
     * the answer from the start and it grows downward in front of them. It is
     * the wrong answer for a button labelled "jump to the newest message": when
     * that turn is itself taller than the screen, aligning its top leaves the
     * reader exactly where they already were, and the control visibly does
     * nothing.
     *
     * So the last turn is landed on, and only then — once it has been measured
     * — checked for the case where landing on it is not the same as reaching
     * its end. Two scrolls, because the item's height is only known after the
     * list has composed it, and a reader eighty turns up the transcript has not
     * composed it yet.
     */
    suspend fun scrollToNewestEdge() {
        if (groups.isEmpty()) return
        awaitMeasuredItems()
        val index = groups.lastIndex + sentinelOffset
        listState.scrollToItem(index)
        val layout = listState.layoutInfo
        val landed = layout.visibleItemsInfo.lastOrNull() ?: return
        if (landed.index != index) return
        val intoTheTurn = scrollOffsetToShowTheEndOf(
            lastItemSize = landed.size,
            viewportEndOffset = layout.viewportEndOffset,
            afterContentPadding = layout.afterContentPadding,
        )
        if (intoTheTurn > 0) {
            listState.scrollToItem(index, intoTheTurn)
        }
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

    /**
     * Performs a decision the *transcript* asked for — a content change, a turn
     * sent.
     *
     * The only code in this composable that moves the viewport on its own
     * initiative, so a prepend, an append and an open cannot fight over the
     * scroll position. The reader's jump control is the one exception, and it is
     * an exception with a reason: it goes through the same policy, but lands on
     * the *end* of the newest turn rather than its top. See [jumpToNewest].
     */
    suspend fun applyScroll(action: ChatScrollAction) {
        when (action) {
            ChatScrollAction.Hold -> Unit
            is ChatScrollAction.PinToNewest -> pinToNewest()
            is ChatScrollAction.RestoreAnchor -> restoreAnchor(action)
        }
    }

    /**
     * Whether the transcript is offering to take the reader to the newest turn.
     *
     * Snapshot state rather than a field on [chatScroll], because that class is
     * deliberately free of Compose and a composable that reads a plain `var`
     * would never learn the value changed.
     */
    var offerJumpToNewest by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val jumpBandPx = with(density) { JUMP_TO_NEWEST_BAND.roundToPx() }

    /**
     * The reader pressed the jump control.
     *
     * The decision is taken by the policy class first, so a press and an
     * arriving delta are answered by the same bookkeeping — see
     * [applyScroll]. What the press does *not* do is go through
     * [ChatScrollAction.PinToNewest]'s auto-scroll path: a reader who asked to
     * be put at the newest message means the end of it, which is
     * [scrollToNewestEdge] rather than [pinToNewest].
     */
    fun jumpToNewest() {
        // Decided by the policy first, so a press carries the same bookkeeping
        // an arriving delta does: re-arm following, and drop an in-flight
        // backwards-page anchor that would otherwise put the reader back in
        // history the moment that page lands.
        when (val action = chatScroll.onReaderJumpedToNewest()) {
            ChatScrollAction.Hold -> Unit
            is ChatScrollAction.PinToNewest -> scope.launch { scrollToNewestEdge() }
            // Unreachable today — a jump has nothing to anchor to — but a
            // compiler-checked `when` beats an `else` that would drop a future
            // decision on the floor.
            is ChatScrollAction.RestoreAnchor -> scope.launch { applyScroll(action) }
        }
    }

    /**
     * Whether the jump control should be on screen.
     *
     * Deliberately *not* keyed on [ChatScrollState.isFollowingNewest], which is
     * the other signal that the reader has left the end. That flag is an index
     * question — "is the last group visible" — and it is the right question for
     * deciding whether a new turn may pull the viewport. It is the wrong
     * question for this: a single answer taller than the screen keeps its group
     * visible the whole time it is being read, so a reader who had scrolled a
     * long way up one would be told they were at the bottom and never be offered
     * the control. The control measures pixels; the flag counts rows. Where they
     * disagree, the pixel reading is the honest one, and it is the one a reader
     * can see.
     */
    LaunchedEffect(listState, jumpBandPx, state.sessionId) {
        snapshotFlow { listState.layoutInfo.distanceFromBottomPx() }
            .distinctUntilChanged()
            .collect { distancePx ->
                offerJumpToNewest = ChatScrollPolicy.shouldOfferJumpToNewest(
                    distanceFromBottomPx = distancePx,
                    bandPx = jumpBandPx,
                )
            }
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
        applyScroll(chatScroll.onContentChanged(state.sessionId, groups.size))
    }

    // Sending is an explicit "take me to the newest turn" — the reader is
    // looking at history, but the turn they just asked for lands at the end.
    LaunchedEffect(state.isSending) {
        if (state.isSending) {
            applyScroll(chatScroll.onTurnSent())
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

            // Over the transcript, not in it. The control reports where the
            // reader is in the list, so it belongs to the list's viewport — and
            // as an overlay it costs the transcript no row, which matters in a
            // `LazyColumn` where a permanent item would be composed and measured
            // on every frame of every drag.
            JumpToNewestButton(
                visible = offerJumpToNewest,
                onClick = { jumpToNewest() },
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 12.dp),
            )
        }

        ChatComposer(
            draft = state.draft,
            isSending = state.isSending,
            onDraftChanged = onDraftChanged,
            onSend = onSend,
        )
    }
}

/**
 * The transcript's "take me to the newest turn" control.
 *
 * Shown only while something is below the fold, so it is never a button that
 * does nothing. That is the whole design constraint: a permanently mounted jump
 * control on a chat that is already at the bottom is a control that lies about
 * where the reader is, and a reader who has learned to distrust it will not tap
 * it when it matters.
 *
 * "Below the fold" is literal, and it includes a case worth naming: a newest
 * turn that is itself taller than the screen. The auto-scroll lands on such a
 * turn's *top*, so the control is offered from the moment such a chat is opened,
 * and what it does is skip to the end of the answer rather than to the first
 * line of it. That is the honest reading of "there is more below you" and it is
 * what every phone chat does with a very long last message — but it is not the
 * same as "the reader scrolled away", and the two are documented separately in
 * [ChatScrollPolicy.shouldOfferJumpToNewest] so nobody later reads this as
 * promising the control only appears after a gesture.
 *
 * `AnimatedVisibility` rather than an `if`, because the control arrives and
 * leaves during a drag and snapping it in mid-gesture is startling. It also
 * composes nothing at all while hidden, which is what lets a test assert the
 * control is *absent* — `assertDoesNotExist` — instead of merely transparent.
 *
 * A filled circle with a border rather than a bare icon, because it floats over
 * message text: the reader needs to see where the control is before they commit
 * a thumb to it, and an icon on an assistant's paragraph is invisible.
 */
@Composable
private fun JumpToNewestButton(
    visible: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AnimatedVisibility(
        visible = visible,
        modifier = modifier,
    ) {
        Surface(
            modifier = Modifier
                // 48dp, not a tighter 40. M3's `IconButton` is a 40dp state
                // layer inside a 48dp minimum touch target, so the target is the
                // larger of the two — and fixing the surface below 48 would cap
                // it, taking the control under the size a thumb can be trusted
                // to hit.
                .size(48.dp)
                .clip(CircleShape)
                .testTag("chat_jump_to_newest"),
            color = NalarBackgroundRaised,
            shape = CircleShape,
            border = BorderStroke(1.dp, NalarBorder),
        ) {
            IconButton(
                onClick = onClick,
                modifier = Modifier.fillMaxSize(),
            ) {
                Icon(
                    imageVector = Icons.Filled.ArrowDownward,
                    contentDescription = "Jump to the newest message",
                    tint = NalarAccent,
                )
            }
        }
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

        MessageChrome.PARAGRAPH -> AssistantMessageParagraph(message, toolExpansion)
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
 *
 * The [ReasoningBlock] goes above the answer rather than being inlined into it,
 * because that is the order the web draws it in: the reasoning is the context
 * the reply follows from, so it reads first, not as a footnote under the thing
 * it explains.
 */
@Composable
private fun AssistantMessageParagraph(
    message: ChatMessage,
    toolExpansion: ToolExpansion,
) {
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
            // Inside the diagnostic rule, not outside it. A reasoning turn that
            // is *also* a loop diagnostic is still one row, and a rule that
            // stops at the answer would leave the fold above it unmarked.
            ReasoningBlock(message = message, expansion = toolExpansion)
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
 *
 * Reasoning is *not* drawn here. It used to be, inline above the text, and
 * sharing it was the wrong half of the arrangement: the block is a fold, and a
 * fold is a separate control with its own tap target and its own open/closed
 * state, so it belongs to the assistant paragraph that owns the row rather than
 * to a body the reader's bubble also calls. See [ReasoningBlock].
 */
@Composable
private fun MessageBody(message: ChatMessage, contentColor: Color) {
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
