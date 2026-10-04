package com.pabrik.mobile.chat

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

    // --- Offering the reader a way back to the end --------------------------

    /**
     * The band the control uses, in pixels. Stand-in for the composable's 24dp
     * so these cases read as distances rather than as densities.
     */
    private val band = 24

    @Test
    fun aTranscriptParkedOnItsNewestTurnOffersNoJump() {
        // A control that is always there is a control that does nothing, and a
        // reader who has learned to distrust it will not tap it when it matters.
        assertFalse(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = 0,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aReaderInsideThePaddingBandIsStillAtTheEnd() {
        // Zero is a transcript parked on its newest turn, and a reader a line or
        // two above it reads a small positive distance. Offering the control
        // there would make it flicker on and off under a slow drag.
        assertFalse(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = 12,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aReaderWhoHasLeftTheEndIsOfferedAJump() {
        assertTrue(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = 500,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aReaderScrolledUpInsideOneTallAnswerIsStillOfferedAJump() {
        // Why the distance is measured in pixels. A single assistant turn taller
        // than the screen is *the last visible item* for the whole time it is
        // being read, so an index rule reports "at the bottom" to a reader who
        // has scrolled most of the way up it — and the control they need most is
        // the one that never appears.
        assertTrue(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = 900,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aTranscriptWhoseEndIsNotOnScreenIsOfferedAJump() {
        // `DISTANCE_FAR` is a real answer and the furthest one, not a synonym
        // for "unknown". A `LazyColumn` cannot measure a turn it has not
        // composed, so the distance to the end is uncomputable there — and
        // refusing to offer the control for want of a number would hide it from
        // every reader more than a screen from the newest turn.
        assertTrue(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = DISTANCE_FAR,
                bandPx = band,
            ),
        )
    }

    @Test
    fun anUnmeasuredLayoutOffersNoJump() {
        // A cold open lays the list out before the first row arrives. "Unknown"
        // is not "far from the end", and reading it as far would put a jump
        // control over an empty transcript.
        //
        // The sentinel is asserted as well as the behaviour, because *which*
        // value it is is a contract with the geometry: a measured distance is
        // never negative, so the sentinel has to be a value no layout produces.
        assertTrue(
            "the unmeasured sentinel must be negative, and no reading is",
            DISTANCE_UNMEASURED < 0,
        )
        assertFalse(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = DISTANCE_UNMEASURED,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aJumpTakesTheReaderToTheNewestTurn() {
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        assertFalse("precondition: the reader is in history", scroll.isFollowingNewest)

        val action = scroll.onReaderJumpedToNewest()

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.READER_JUMPED), action)
        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun aJumpKeepsTheTranscriptFollowingTheStream() {
        // The reason the jump goes through the policy rather than straight to
        // `scrollToItem`. Scrolling without re-arming the follow flag leaves the
        // next streamed delta to find `false` there and pin the reader straight
        // back to history — a control that appears to work and then undoes
        // itself a second later.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        scroll.onReaderJumpedToNewest()

        val action = scroll.onContentChanged(sessionId = "s1", groupCount = 10)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    @Test
    fun aJumpDiscardsAnOlderPageAnchorThatIsStillInFlight() {
        // The subtle one. A backwards page is armed *before* its request goes
        // out, so the reader can easily give up on history and press the button
        // while it is in flight. Replaying that anchor on arrival puts them
        // straight back where they just pressed the button to leave, which reads
        // as the button not working.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.armOlderPage(ChatScrollAnchor(key = "m7", offset = -8))
        scroll.onViewportMoved(lastVisibleIndex = 1, totalItems = 10, isScrolling = true)
        scroll.onReaderJumpedToNewest()

        val action = scroll.onContentChanged(sessionId = "s1", groupCount = 20)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    @Test
    fun anEmptyTranscriptIsNeverOfferedAJump() {
        // Nothing measured is [DISTANCE_UNMEASURED], and there is no newest turn
        // to take anybody to.
        assertEquals(
            ChatScrollAction.Hold,
            ChatScrollState().onContentChanged(sessionId = "s1", groupCount = 0),
        )
        assertFalse(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = DISTANCE_UNMEASURED,
                bandPx = band,
            ),
        )
    }

    @Test
    fun sendingATurnFromHistoryFollowsTheTurnWhenItLands() {
        // The reported behaviour, in its plainest form: the reader is reading
        // history, they ask for a turn, and the turn they asked for is the one
        // on screen when it arrives.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        assertFalse("precondition: the reader is in history", scroll.isFollowingNewest)

        val sent = scroll.onTurnSent()

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.TURN_SENT), sent)
        assertTrue(
            "asking for a turn re-arms the follow before the turn exists",
            scroll.isFollowingNewest,
        )
        // There is no optimistic bubble, so the row arrives over SSE a frame or
        // two later. That is the frame the follow has to still be armed for.
        assertEquals(
            ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT),
            scroll.onContentChanged(sessionId = "s1", groupCount = 11),
        )
    }

    @Test
    fun aScrollInFlightWhenTheTurnWasSentDoesNotDisarmTheFollow() {
        // The race. A fling that was already running when the reader hit send
        // keeps reporting frames for a few more milliseconds, and the pin the
        // send asked for has its own settling frames on top. Both arrive as
        // "the viewport moved away from the end".
        //
        // Read literally, that is the reader leaving — and taking the follow
        // with it. But neither of those movements is the reader's, and the
        // turn they just asked for lands a frame later and is answered with
        // `Hold`: the send appears to do nothing.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        assertFalse("precondition: the reader is in history", scroll.isFollowingNewest)
        scroll.onTurnSent()

        // The fling's trailing frame, still reading the pre-send position.
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)

        assertEquals(
            "a movement that was already in flight when the turn was sent is not " +
                "the reader leaving, and must not cancel the follow they asked for",
            ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT),
            scroll.onContentChanged(sessionId = "s1", groupCount = 11),
        )
    }

    @Test
    fun aQueuedTurnFollowsTheTranscriptWhenTheWorkerDrainsIt() {
        // A queue is a send that produces no row: nothing lands between asking
        // and the worker draining the turn, so the follow has to survive a
        // stretch of unrelated content and a reader who is sitting at the end
        // waiting. What it must not survive is the reader deliberately leaving.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        scroll.onTurnSent()

        // The reader arrives at the end: the pin did what it was asked to.
        scroll.onViewportMoved(lastVisibleIndex = 9, totalItems = 10, isScrolling = true)
        // The run they queued behind streams while they wait.
        scroll.onContentChanged(sessionId = "s1", groupCount = 11)
        // And then the queued turn is drained into the transcript.
        val drained = scroll.onContentChanged(sessionId = "s1", groupCount = 12)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), drained)
    }

    @Test
    fun leavingAfterTheTurnLandedStillStopsTheTranscriptFollowing() {
        // The other side of the same latch, and the reason it has to be spent.
        // Arming the follow on a send is not a promise to drag the reader back
        // for the rest of the session: once the turn they asked for is on
        // screen, a reader who scrolls away is followed no more.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        scroll.onTurnSent()
        scroll.onContentChanged(sessionId = "s1", groupCount = 11)

        // A fresh gesture, after the sent turn is already on screen.
        scroll.onViewportMoved(lastVisibleIndex = 3, totalItems = 11, isScrolling = true)

        assertFalse(
            "a deliberate scroll away after the turn landed must disengage the follow",
            scroll.isFollowingNewest,
        )
        assertEquals(
            ChatScrollAction.Hold,
            scroll.onContentChanged(sessionId = "s1", groupCount = 12),
        )
    }
}
