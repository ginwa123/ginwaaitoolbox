package com.nalar.mobile.recents

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * How many rows from the end arm the next page.
 *
 * The fetch should already be in flight by the time the reader reaches the
 * bottom, rather than starting from a standstill with the list visibly
 * stopped.
 */
internal const val LOAD_MORE_INDEX_THRESHOLD = 2

/**
 * What the paging trigger saw this frame, in the two words it acts on.
 *
 * [fitsViewport] and [atEnd] are separate because they are different failures
 * and a single boolean would have to lie about one of them. The bug this type
 * exists to prevent is a screen that asks for its next page only when the
 * reader scrolls, opened on a list that is *shorter than the screen* — there
 * is no scroll to make, so the reader's only control is a footer reading
 * "Scroll for older chats" and the list never grows.
 */
internal data class ChatListPagingState(
    /**
     * Every row the list has is on screen, so the list cannot scroll and the
     * reader has no way to ask for the next page by hand.
     */
    val fitsViewport: Boolean,
    /** The last row is within [LOAD_MORE_INDEX_THRESHOLD] of the bottom. */
    val atEnd: Boolean,
    /**
     * How many chat rows the list holds.
     *
     * Carried so the trigger can tell "the reader is still parked at the end
     * of the list they have already paged" from "the reader is at the end of
     * a list that has since grown" — the second is a new list, and a new list
     * has a new end nobody has asked about yet.
     */
    val rowCount: Int,
)

/**
 * Read a `LazyListState`'s layout as the two questions the paging trigger asks.
 *
 * A pure function over primitives rather than over [androidx.compose.foundation.lazy.LazyListInfo]
 * so the arithmetic — which is the whole of the bug — is assertable without a
 * laid-out screen, and so both screens ask it identically instead of each
 * growing its own copy of the arithmetic.
 */
internal fun chatListPagingState(
    canPage: Boolean,
    totalItemsCount: Int,
    visibleItemCount: Int,
    lastVisibleIndex: Int,
    rowCount: Int,
    threshold: Int = LOAD_MORE_INDEX_THRESHOLD,
): ChatListPagingState {
    // Nothing to read. An unlaid-out list reports 0/0, and an empty one holds
    // a single placeholder row at index 0 — which is inside any band, so
    // without this a screen that just opened would arm a fetch that appends
    // onto nothing.
    if (!canPage || totalItemsCount <= 0 || visibleItemCount <= 0) {
        return ChatListPagingState(
            fitsViewport = false,
            atEnd = false,
            rowCount = rowCount,
        )
    }

    // Every row is already on screen. A `LazyColumn` with no overflow has no
    // scroll offset, so no scroll can ever move it out of this state — which
    // is exactly the state the drawer's five-row preview opens in.
    val fitsViewport = totalItemsCount <= visibleItemCount

    return ChatListPagingState(
        fitsViewport = fitsViewport,
        // `false` while the list fits: there is no "bottom" left to approach,
        // and [fitsViewport] is the honest answer for that screen. Letting the
        // band answer it too would make one unreachable condition look like
        // two.
        atEnd = !fitsViewport && lastVisibleIndex >= totalItemsCount - 1 - threshold,
        rowCount = rowCount,
    )
}

/**
 * Ask for the next page of a chat list when the reader has run out of things
 * they can do about it.
 *
 * Two independent reasons, each with its own latch, because they re-arm on
 * different events:
 *
 * - **the list does not fill the screen** — the reader cannot scroll, so the
 *   only honest way to reach the next page is to ask for it. This re-arms
 *   whenever the list *grows*, which is what makes it stop: an appended page
 *   pushes rows below the viewport, the list overflows, and this reason goes
 *   away on its own. A page that arrives empty changes nothing, so the latch
 *   holds and a failed request does not become a retry loop.
 * - **the reader reached the bottom** — the ordinary case. This re-arms when
 *   the reader leaves the band, and additionally when the list grows while
 *   they are still in it, so an append that leaves the reader standing on the
 *   new end is a second approach rather than a swallowed one.
 *
 * Shared by [RecentsChatsScreen] and [com.nalar.mobile.projects.ProjectChatsScreen]
 * on purpose: the two are the same control over two lists, and the bug this
 * fixes lived in *both* copies.
 */
@Composable
internal fun ChatListLoadMoreTrigger(
    listState: LazyListState,
    canPage: Boolean,
    rowCount: Int,
    onLoadMore: () -> Unit,
) {
    // Deliberately separate latches, and deliberately not shared between the
    // two screens: one flag driving two scrollers would let a list that fits
    // the screen here suppress the fetch another screen is waiting for.
    var atEndLatched by remember { mutableStateOf(false) }
    var atEndLatchedRowCount by remember { mutableIntStateOf(0) }
    var filledToRowCount by remember { mutableIntStateOf(-1) }

    // Keyed on the row count as well as on `canPage` so a page that lands
    // restarts the observer and is re-read: a longer list is a different
    // list, and whether it still fits the screen is a new question, not a
    // repeat of the one just answered.
    LaunchedEffect(listState, canPage, rowCount) {
        snapshotFlow {
            val info = listState.layoutInfo
            chatListPagingState(
                canPage = canPage,
                totalItemsCount = info.totalItemsCount,
                visibleItemCount = info.visibleItemsInfo.size,
                lastVisibleIndex = info.visibleItemsInfo.lastOrNull()?.index ?: -1,
                rowCount = rowCount,
            )
        }
            .distinctUntilChanged()
            .collect { paging ->
                if (!paging.atEnd) {
                    atEndLatched = false
                } else if (!atEndLatched || atEndLatchedRowCount != paging.rowCount) {
                    atEndLatched = true
                    atEndLatchedRowCount = paging.rowCount
                    onLoadMore()
                }

                if (paging.fitsViewport && paging.rowCount != filledToRowCount) {
                    filledToRowCount = paging.rowCount
                    onLoadMore()
                }
            }
    }
}
