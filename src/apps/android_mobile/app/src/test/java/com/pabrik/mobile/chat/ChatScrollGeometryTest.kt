package com.pabrik.mobile.chat

import androidx.compose.foundation.lazy.LazyListItemInfo
import androidx.compose.foundation.lazy.LazyListLayoutInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The geometry the jump control is decided on: how far the bottom of the
 * transcript is below the bottom of the viewport.
 *
 * Split from [ChatScrollPolicyTest] because this is a different kind of
 * statement. That file tests a rule — given a distance, offer or do not — and
 * the rule is a two-line comparison. This file is where the distance comes
 * from, and the distance is where a chat goes wrong in three different ways
 * that all read as a plausible number:
 *
 * - a transcript too short to fill the screen, which parks its last row near
 *   the *top* and so measures as most of a screen from the end;
 * - a reader scrolled into a turn taller than the screen, where the row
 *   straddling the viewport's bottom edge is the newest turn the whole time;
 * - a reader deep in the transcript, where that same row is a few dozen pixels
 *   of overhang regardless of how many turns are still below them.
 */
class ChatScrollGeometryTest {

    /**
     * The bottom edge of the viewport, in the coordinates `LazyColumn` reports
     * item offsets in. Set through [FakeLayout]'s viewport offsets, which is the
     * one thing every reading here is measured against.
     */
    private val viewportEnd = 2_000

    /**
     * A layout whose last visible row is at [lastIndex] — [lastOffset], [lastSize]
     * tall — out of [totalItems].
     *
     * [lastIndex] defaults to the final item so that a reading is a real
     * distance by default. The cases that need the end *off* screen say so.
     */
    private fun layoutOf(
        lastOffset: Int,
        lastSize: Int,
        lastIndex: Int = 9,
        totalItems: Int = 10,
        visible: List<LazyListItemInfo> = listOf(row(lastIndex, lastOffset, lastSize)),
    ): LazyListLayoutInfo = FakeLayout(
        visibleItemsInfo = visible,
        totalItemsCount = totalItems,
        viewportEndOffset = viewportEnd,
    )

    private fun row(index: Int, offset: Int, size: Int): LazyListItemInfo = FakeItem(
        index = index,
        offset = offset,
        size = size,
    )

    @Test
    fun aListLandedOnItsLastRowIsAtTheEnd() {
        // The last row's bottom sits exactly on the viewport's bottom — a
        // transcript with no trailing content padding, scrolled all the way
        // down. Nothing is below the fold.
        assertEquals(0, layoutOf(lastOffset = 1_960, lastSize = 40).distanceFromBottomPx())
    }

    @Test
    fun aTranscriptShorterThanTheViewportIsAtTheEnd() {
        // The trap. A two-turn chat ends 160px down a 2,000px viewport, so the
        // raw difference between the content's bottom and the viewport's bottom
        // is 1,840px — which read literally says the reader is nearly a screen
        // from the newest turn, having not moved at all.
        assertEquals(0, layoutOf(lastOffset = 60, lastSize = 100).distanceFromBottomPx())
    }

    @Test
    fun aReaderScrolledUpInATranscriptThatCannotScrollIsStillAtTheEnd() {
        // The last row straddles the viewport's *top* edge: the list is at its
        // maximum scroll, and being scrolled to the maximum is being at the end
        // even though the row is not fully on screen.
        assertEquals(0, layoutOf(lastOffset = -40, lastSize = 100).distanceFromBottomPx())
    }

    @Test
    fun theTrailingContentPaddingIsInsideTheFoldAndNotCountedAsDistance() {
        // `ChatView` pads the transcript, so a reader parked at the maximum
        // scroll has the content's bottom one padding's worth *above* the
        // viewport's edge — not level with it. A reading that counted that
        // padding as distance would keep a reader who is at the end
        // permanently inside the band, and the control would never withdraw.
        val padding = 24
        val rowSize = 100

        // At the maximum scroll, the last row's bottom is one padding short of
        // the viewport's edge — the padding is inside the fold, not below it.
        val bottomAtTheEnd = viewportEnd - padding
        assertEquals(
            0,
            layoutOf(lastOffset = bottomAtTheEnd - rowSize, lastSize = rowSize)
                .distanceFromBottomPx(),
        )

        // A row's bottom genuinely below the fold is a real distance, so the
        // zero above is the end of the transcript rather than a value the
        // function cannot produce.
        assertEquals(
            1,
            layoutOf(lastOffset = viewportEnd + 1 - rowSize, lastSize = rowSize)
                .distanceFromBottomPx(),
        )
    }

    @Test
    fun aReaderJustAboveTheEndIsMeasuredInPixels() {
        // The last row is the newest turn, and 100 of its pixels are below the
        // fold. This is the only band where the reading is a real number rather
        // than "the end is off screen", and it is what stops the control from
        // appearing under a reader who is still at the newest turn.
        assertEquals(100, layoutOf(lastOffset = 1_860, lastSize = 240).distanceFromBottomPx())
    }

    @Test
    fun aTranscriptWhoseEndIsNotOnScreenIsTheFurthestReading() {
        // The reader is a long way up the list, so the row straddling the
        // viewport's bottom edge is turn 4 of 10 and its 100px of overhang says
        // nothing about the six turns below it. `DISTANCE_FAR` is the honest
        // answer, and it is why the control does not flicker on and off at every
        // row boundary the reader crosses.
        assertEquals(
            DISTANCE_FAR,
            layoutOf(lastIndex = 3, lastOffset = 1_900, lastSize = 100).distanceFromBottomPx(),
        )
    }

    @Test
    fun anAnswerTallerThanTheScreenIsMeasuredRatherThanCalledFar() {
        // The reader is inside a single turn several screens long, and it *is*
        // the last item — so the reading is a real one, and it is the furthest a
        // real reading can be. An index rule would call this "at the bottom"
        // (the newest turn is on screen) and hide the control from the reader
        // with the most use for it.
        val distance = layoutOf(
            lastIndex = 0,
            lastOffset = 0,
            lastSize = 9_000,
            totalItems = 1,
        ).distanceFromBottomPx()

        assertEquals(7_000, distance)
        assertTrue(
            "a reader inside a long answer is offered the control",
            ChatScrollPolicy.shouldOfferJumpToNewest(distanceFromBottomPx = distance, bandPx = 24),
        )
    }

    @Test
    fun anEmptyTranscriptHasNothingToBeAwayFrom() {
        assertEquals(
            DISTANCE_UNMEASURED,
            layoutOf(
                lastOffset = 0,
                lastSize = 0,
                totalItems = 0,
                visible = emptyList(),
            ).distanceFromBottomPx(),
        )
    }

    @Test
    fun aCountedButUncomposedTranscriptIsAlsoUnmeasured() {
        // The cold open: `totalItemsCount` is known before a single row has been
        // measured. A rule that assumed "counted implies measured" would put a
        // control over a transcript that has not drawn one turn.
        assertEquals(
            DISTANCE_UNMEASURED,
            layoutOf(lastOffset = 0, lastSize = 0, visible = emptyList()).distanceFromBottomPx(),
        )
    }

    @Test
    fun aTranscriptAtItsEndIsNeverOfferedAJump() {
        // The two halves joined up, for the two shapes a phone actually shows:
        // a long transcript parked on its last turn, and a short one that never
        // had anything to scroll.
        val parked = layoutOf(lastOffset = 1_960, lastSize = 40).distanceFromBottomPx()
        val short = layoutOf(lastOffset = 60, lastSize = 100).distanceFromBottomPx()

        assertFalse(ChatScrollPolicy.shouldOfferJumpToNewest(parked, bandPx = 24))
        assertFalse(ChatScrollPolicy.shouldOfferJumpToNewest(short, bandPx = 24))
    }

    // --- Landing on the very end of the newest turn --------------------------
    //
    // The other half of the jump. `scrollToItem` aligns a turn's *top* with the
    // viewport's top, which is right for the auto-scroll and wrong for a button
    // labelled "jump to the newest message": on a turn taller than the screen it
    // leaves the reader exactly where they were, and the control does nothing.

    @Test
    fun aTurnThatFitsInTheWindowNeedsNoFurtherScroll() {
        // Landing on its top already shows all of it and the padding after it.
        assertEquals(0, scrollOffsetToShowTheEndOf(
            lastItemSize = 200,
            viewportEndOffset = 2_000,
            afterContentPadding = 24,
        ))
    }

    @Test
    fun aTurnTallerThanTheWindowIsScrolledIntoToItsEnd() {
        // 3,000px of turn, 24px of padding after it, a 2,000px viewport. Landing
        // on the turn's top leaves its bottom at 3,000, which is 1,024px below
        // where it has to be.
        assertEquals(1_024, scrollOffsetToShowTheEndOf(
            lastItemSize = 3_000,
            viewportEndOffset = 2_000,
            afterContentPadding = 24,
        ))
    }

    @Test
    fun theBoundaryIsTheViewportLessTheTrailingPadding() {
        // A turn exactly as tall as the window, once the padding after it is
        // discounted, is already showing its end; one pixel more is not. This is
        // the whole reason the offset is arithmetic rather than a guess at a row
        // height, and it is also where the trailing padding has to be counted.
        assertEquals(0, scrollOffsetToShowTheEndOf(
            lastItemSize = 1_976,
            viewportEndOffset = 2_000,
            afterContentPadding = 24,
        ))
        assertEquals(1, scrollOffsetToShowTheEndOf(
            lastItemSize = 1_977,
            viewportEndOffset = 2_000,
            afterContentPadding = 24,
        ))
    }

    @Test
    fun theOffsetNeverAsksForABackwardScroll() {
        // `LazyListState` throws on a negative scroll offset, so a turn shorter
        // than the window has to clamp rather than hand the arithmetic its own
        // negative answer.
        assertEquals(0, scrollOffsetToShowTheEndOf(
            lastItemSize = 1,
            viewportEndOffset = 2_000,
            afterContentPadding = 0,
        ))
    }

    @Test
    fun theOffsetAndTheReadingAgreeOnWhereTheEndIs() {
        // The two halves of the jump, tied together. After scrolling by the
        // offset, the reading must be zero — or the control would sit on screen
        // at the very end of the transcript offering to take the reader
        // somewhere they already are. Both functions answer in the same frame,
        // and this is what says they got the same answer.
        val padding = 24
        val turnSize = 9_000
        val intoTheTurn = scrollOffsetToShowTheEndOf(
            lastItemSize = turnSize,
            viewportEndOffset = viewportEnd,
            afterContentPadding = padding,
        )

        // Scrolling by `intoTheTurn` leaves the turn's top that far above the
        // viewport's top, so its bottom — plus the padding after it — lands on
        // the viewport's bottom edge. `LazyColumn` reports the resulting layout
        // with the turn's offset measured from that same top.
        val contentBottom = -intoTheTurn + turnSize
        val reading = layoutOf(
            lastOffset = -intoTheTurn,
            lastSize = turnSize,
            lastIndex = 0,
            totalItems = 1,
        ).distanceFromBottomPx()

        assertEquals(viewportEnd - padding, contentBottom)
        assertEquals(0, reading)
    }

    /**
     * The minimum that satisfies the two interfaces, and nothing more.
     *
     * Everything else is left at its interface defaults, which is the point: a
     * member set here is a member the readings could accidentally be taken
     * against instead of the one they are, and one of them — `viewportSize` —
     * defaults to `IntSize.Zero`, so a reading that reached for it would be
     * measuring against a zero-height viewport. Nothing here reads one, and a
     * future case that needs one should set it in the open rather than quietly
     * assuming it.
     */
    private class FakeLayout(
        override val visibleItemsInfo: List<LazyListItemInfo>,
        override val totalItemsCount: Int,
        override val viewportEndOffset: Int,
        override val viewportStartOffset: Int = 0,
    ) : LazyListLayoutInfo

    private class FakeItem(
        override val index: Int,
        override val offset: Int,
        override val size: Int,
        override val key: Any = index,
        override val contentType: Any? = null,
    ) : LazyListItemInfo
}
