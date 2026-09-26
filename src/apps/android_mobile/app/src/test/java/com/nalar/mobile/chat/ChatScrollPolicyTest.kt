package com.nalar.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where a transcript puts its viewport, and — more to the point — where it
 * refuses to.
 *
 * Every case here is a *sequence* rather than a frame, because that is the
 * level at which this went wrong. "Does the chat scroll to the bottom when I
 * open it" is not a property of any one frame: it is a property of what the
 * viewer believed about the reader at the moment the open happened, and about
 * what the previous chat left behind.
 */
class ChatScrollPolicyTest {

    // --- The decision table --------------------------------------------------

    @Test
    fun openingAChatLandsOnTheNewestTurn() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = true,
            groupCount = 12,
            previousGroupCount = 40,
            anchor = null,
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED), action)
    }

    @Test
    fun openingAChatLandsOnTheNewestTurnEvenWhenTheCountsAreIdentical() {
        // The regression this whole file exists for. Two chats with the same
        // number of turns move neither count, and a view that only reacted to
        // counts changing therefore never scrolled at all: the new chat opened
        // exactly where the old one was parked.
        val action = ChatScrollPolicy.decide(
            sessionChanged = true,
            groupCount = 12,
            previousGroupCount = 12,
            anchor = null,
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED), action)
    }

    @Test
    fun openingAChatLandsOnTheNewestTurnEvenWithAnAnchorStrandedFromTheLastOne() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = true,
            groupCount = 3,
            previousGroupCount = 0,
            anchor = ChatScrollAnchor(key = "m99", offset = -14),
            isFollowingNewest = true,
        )

        // An anchor names a message in the chat that was just left. Honouring it
        // would scroll to an index that means something else entirely.
        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED), action)
    }

    @Test
    fun anEmptyTranscriptIsNeverScrolled() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = true,
            groupCount = 0,
            previousGroupCount = 0,
            anchor = null,
            isFollowingNewest = true,
        )

        assertEquals(ChatScrollAction.Hold, action)
    }

    @Test
    fun aPrependPutsTheReaderBackOnTheMessageTheyWereReading() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 21,
            previousGroupCount = 9,
            anchor = ChatScrollAnchor(key = "m7", offset = -12),
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.RestoreAnchor(key = "m7", offset = -12), action)
    }

    @Test
    fun aPrependBeatsTheFollowFlag() {
        // The reader asked to read further back; following the tail here would
        // throw away the page they just pulled.
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 21,
            previousGroupCount = 9,
            anchor = ChatScrollAnchor(key = "m7", offset = 0),
            isFollowingNewest = true,
        )

        assertEquals(ChatScrollAction.RestoreAnchor(key = "m7", offset = 0), action)
    }

    @Test
    fun anAppendFollowsTheTailWhileTheReaderIsAtTheEnd() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 10,
            previousGroupCount = 9,
            anchor = null,
            isFollowingNewest = true,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    @Test
    fun anAppendLeavesARewerInHistoryAlone() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 10,
            previousGroupCount = 9,
            anchor = null,
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.Hold, action)
    }

    @Test
    fun aGrownTailFollowsTheReaderEvenThoughNoCountMoved() {
        // A streamed delta replaces the newest message in place: same group
        // count, same message count, taller by a line. This branch is the only
        // one that can see it.
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 10,
            previousGroupCount = 10,
            anchor = null,
            isFollowingNewest = true,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    @Test
    fun aShrunkListLandsOnTheNewestTurn() {
        // The streaming placeholder collapsing into the turn above it removes a
        // group, and the reader must not be left hanging past a shorter list.
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 9,
            previousGroupCount = 10,
            anchor = null,
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    // --- The bookkeeping around it -------------------------------------------

    @Test
    fun aColdOpenWithNoCacheStillLandsOnTheNewestTurnWhenTheFirstPageArrives() {
        // `openSession` paints an empty transcript first when there is nothing
        // cached, and the rows land a frame later. The intent to land on the
        // newest turn has to survive that empty paint, or the first page is
        // treated as an ordinary append and answered with whatever the reader
        // was doing in the chat they just left.
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = 30, totalItems = 40, isScrolling = true)
        assertFalse("precondition: the reader left the end in the previous chat", scroll.isFollowingNewest)

        assertEquals(ChatScrollAction.Hold, scroll.onContentChanged(sessionId = "s2", groupCount = 0))

        val action = scroll.onContentChanged(sessionId = "s2", groupCount = 25)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED), action)
    }

    @Test
    fun switchingChatsReArmsTheFollowFlagWhateverTheReaderWasDoing() {
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        assertFalse(scroll.isFollowingNewest)

        scroll.onContentChanged(sessionId = "s2", groupCount = 4)

        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun aSettledLayoutIsNotAReaderLeaving() {
        // The trap the old watcher walked into. Opening a chat lays the list out
        // at index 0 before anything has been scrolled, and reading that layout
        // as "the reader has scrolled away" cancelled the scroll that was about
        // to run. A layout nobody is driving is not a gesture.
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = 0, totalItems = 40, isScrolling = false)

        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun theFirstLayoutOfAListWithNothingInItChangesNothing() {
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = -1, totalItems = 0, isScrolling = false)
        scroll.onViewportMoved(lastVisibleIndex = -1, totalItems = 0, isScrolling = true)

        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun aDragAwayFromTheEndStopsTheTranscriptFollowing() {
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = 9, totalItems = 10, isScrolling = true)
        assertTrue(scroll.isFollowingNewest)

        scroll.onViewportMoved(lastVisibleIndex = 4, totalItems = 10, isScrolling = true)
        assertFalse(scroll.isFollowingNewest)
    }

    @Test
    fun theSettlingFrameOfAFlingStillCountsAsTheReadersOwnMovement() {
        // A fling settles and stops reporting an in-progress scroll in the same
        // snapshot, so gating on the *current* reading alone would discard the
        // position the fling actually reached.
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = 8, totalItems = 10, isScrolling = true)
        scroll.onViewportMoved(lastVisibleIndex = 3, totalItems = 10, isScrolling = false)

        assertFalse(scroll.isFollowingNewest)
    }

    @Test
    fun scrollingBackToTheEndResumesFollowing() {
        val scroll = ChatScrollState()
        scroll.onViewportMoved(lastVisibleIndex = 3, totalItems = 10, isScrolling = true)
        assertFalse(scroll.isFollowingNewest)

        scroll.onViewportMoved(lastVisibleIndex = 9, totalItems = 10, isScrolling = true)
        scroll.onViewportMoved(lastVisibleIndex = 9, totalItems = 10, isScrolling = false)

        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun sendingATurnTakesTheReaderToTheNewestTurn() {
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 1, totalItems = 10, isScrolling = true)

        val action = scroll.onTurnSent()

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.TURN_SENT), action)
        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun anAnchorIsConsumedExactlyOnce() {
        // Consumed once, because a stale anchor replayed on a later append would
        // yank the reader back to an old message with no gesture to explain it.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.armOlderPage(ChatScrollAnchor(key = "m7", offset = -8))

        assertEquals(
            ChatScrollAction.RestoreAnchor(key = "m7", offset = -8),
            scroll.onContentChanged(sessionId = "s1", groupCount = 20),
        )
        assertEquals(
            ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT),
            scroll.onContentChanged(sessionId = "s1", groupCount = 21),
        )
    }

    @Test
    fun anArmedAnchorThatNeverArrivesIsDroppedByTheNextOpen() {
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.armOlderPage(ChatScrollAnchor(key = "m7", offset = 0))
        // The reader left before the page came back.
        scroll.onContentChanged(sessionId = "s2", groupCount = 5)

        val action = scroll.onContentChanged(sessionId = "s2", groupCount = 6)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }
}
