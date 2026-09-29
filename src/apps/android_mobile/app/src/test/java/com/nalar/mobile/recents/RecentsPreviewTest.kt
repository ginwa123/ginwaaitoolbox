package com.nalar.mobile.recents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How many rows the Recents section shows, and when the drawer is allowed to
 * ask for the next page.
 *
 * Two pure functions, tested apart from the layout for the same reason
 * `ChatRegionEndIndexTest` tests its one: a phone drawer is ~40dp per row, so
 * "the list is longer than the screen" is arithmetic, and proving it through
 * Robolectric would be a test whose answer changes the day someone touches the
 * row's padding — while still going green.
 */
class RecentsPreviewTest {

    @Test
    fun aLongListShowsOnlyTheFirstFewRows() {
        // 30 chats in a phone drawer: the complaint the cap answers. Five rows
        // is one screenful, which is what leaves the Projects section reachable.
        assertEquals(5, recentsVisibleChatCount(totalChats = 30, showAll = false))
    }

    @Test
    fun theReaderCanAskForEveryLoadedRow() {
        assertEquals(30, recentsVisibleChatCount(totalChats = 30, showAll = true))
    }

    @Test
    fun aListAtTheLimitIsNotTruncated() {
        // Exactly five is a list, not a preview. Cutting it to four would make
        // the cap invisible until a sixth chat arrived, so the two states would
        // look identical until the moment they mattered.
        assertEquals(5, recentsVisibleChatCount(totalChats = 5, showAll = false))
    }

    @Test
    fun aShortListIsTheSameShapeWhicheverWayItIsAsked() {
        // Nothing is being held back, so "see all" has nothing to do. Returning
        // five here would invent rows the workspace does not have.
        assertEquals(3, recentsVisibleChatCount(totalChats = 3, showAll = false))
        assertEquals(3, recentsVisibleChatCount(totalChats = 3, showAll = true))
    }

    @Test
    fun anEmptyWorkspaceRendersNoRows() {
        assertEquals(0, recentsVisibleChatCount(totalChats = 0, showAll = true))
    }

    @Test
    fun theFooterIsMissingExactlyWhileRowsAreHeldBack() {
        // The footer says "scroll for older chats" / "no older chats". Under a
        // preview neither is true — the list does not scroll and its end is an
        // arbitrary cut — so the row has to be absent, and the "See all" row
        // takes its place.
        assertFalse(recentsShowsChatFooter(totalChats = 30, showAll = false))
        assertTrue(recentsShowsChatFooter(totalChats = 30, showAll = true))
    }

    @Test
    fun aListAtTheLimitIsWholeSoItStillPages() {
        // The boundary, and the one that would be easy to get wrong in the
        // other direction: five chats are five chats, nothing is held back, and
        // the Projects section below them *is* scrollable — so suppressing the
        // footer here would make the last page unreachable for a workspace that
        // happens to have exactly the limit.
        assertTrue(recentsShowsChatFooter(totalChats = 5, showAll = false))
        assertTrue(recentsShowsChatFooter(totalChats = 4, showAll = false))
    }

    @Test
    fun aLongListPagesOnlyOnceItIsOpen() {
        // The invariant worth a test of its own: the preview fits on the
        // screen, so a paging trigger left armed would fire on the first layout
        // and fetch page after page behind a row nobody has tapped — the long
        // drawer, rebuilt out of network requests.
        assertFalse(recentsShowsChatFooter(totalChats = 6, showAll = false))
        assertTrue(recentsShowsChatFooter(totalChats = 6, showAll = true))
    }
}
