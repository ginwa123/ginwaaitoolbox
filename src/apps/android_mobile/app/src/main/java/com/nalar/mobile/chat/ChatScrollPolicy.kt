package com.nalar.mobile.chat

/** Why the transcript is being asked to move. */
enum class ChatPinReason {
    /** A chat was opened. Always lands on the newest turn. */
    SESSION_OPENED,

    /** Content below the viewport changed — an append, a prepend-free grow. */
    NEWER_CONTENT,

    /** The reader asked for a turn by sending one. */
    TURN_SENT,
}

/**
 * Where the reader was when a backwards page was requested.
 *
 * Keyed by the list item's key rather than its index, because prepending rows
 * renumbers every index above the reader and an index anchor lands on a
 * different message than the one they were reading.
 */
data class ChatScrollAnchor(val key: String, val offset: Int)

/** What the transcript should do about its scroll position. */
sealed interface ChatScrollAction {
    /** Leave the viewport alone. */
    data object Hold : ChatScrollAction

    /** Park the viewport on the newest turn. */
    data class PinToNewest(val reason: ChatPinReason) : ChatScrollAction

    /**
     * Put the reader back on the message a prepend pushed out of view.
     *
     * [offset] is the item's top relative to the viewport's top when the anchor
     * was taken, so replaying it restores the exact pixel row, not merely the
     * right message with its head chopped off.
     */
    data class RestoreAnchor(val key: String, val offset: Int) : ChatScrollAction
}

/**
 * Decides where the transcript goes when its content changes.
 *
 * A pure function of its inputs and free of Compose, because the failures that
 * matter here are *sequences* — open a chat, stream into it, page backwards,
 * scroll up — and a sequence is exactly what a one-shot composable test cannot
 * express. Every rule below is a rule about an interaction between two
 * consecutive states, and the interactions were where the bugs were.
 */
object ChatScrollPolicy {
    fun decide(
        sessionChanged: Boolean,
        groupCount: Int,
        previousGroupCount: Int,
        anchor: ChatScrollAnchor?,
        isFollowingNewest: Boolean,
    ): ChatScrollAction = when {
        // Nothing is rendered. There is no item to aim at, and scrolling to an
        // index past the end of a list is not a no-op — it parks the viewport
        // on blank space.
        groupCount == 0 -> ChatScrollAction.Hold

        // Opening a chat is an explicit "show me this conversation", and the
        // newest turn is where that starts. This is checked *before* the count
        // comparison on purpose: two chats that happen to hold the same number
        // of turns used to make the open a no-op, because the view only reacted
        // to counts changing.
        sessionChanged -> ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED)

        // A prepend is the reader's own scroll reaching the top. They asked to
        // read further back, not to jump to the end, so the anchor wins over
        // the follow flag no matter where the newest turn is.
        anchor != null && groupCount > previousGroupCount ->
            ChatScrollAction.RestoreAnchor(anchor.key, anchor.offset)

        // Fewer groups than before: the list shrank under the reader — a
        // streaming placeholder collapsing into the turn above it, or a page
        // replaced by a shorter one. The end of the list is all there is.
        groupCount < previousGroupCount -> ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT)

        // A streamed delta replaces the newest group in place, so neither count
        // moved and this is the only branch that can see it. The tail grows
        // below the fold; following it here is what keeps a live answer in
        // view, and holding here is what stops it yanking a reader who scrolled
        // up on purpose.
        isFollowingNewest -> ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT)

        else -> ChatScrollAction.Hold
    }
}

/**
 * The transcript's scroll bookkeeping: what the last known group count was,
 * which chat is on screen, and whether the reader is still following the end.
 *
 * Every one of those is state that outlives a single composition — and that is
 * the whole reason this is a class rather than three `remember`ed values in
 * the composable. Split across effects, "am I following the bottom" was
 * recomputed from a layout that had not been scrolled yet, so the answer
 * arrived as `false` precisely when a chat was being opened.
 */
class ChatScrollState {

    /**
     * Whether a new turn should pull the viewport down.
     *
     * Starts `true` because a transcript nobody has touched is at its end.
     */
    var isFollowingNewest: Boolean = true
        private set

    private var openedSessionId: String? = null
    private var lastGroupCount: Int = 0
    private var pendingAnchor: ChatScrollAnchor? = null

    /**
     * Set when a chat is opened and cleared by the first content change it
     * produces.
     *
     * A cold open with no cached transcript produces an *empty* list first, and
     * an empty list is not a scrollable state. Without carrying the intent
     * across that empty paint, the first page to arrive would be treated as an
     * ordinary append and answered with whatever the reader was doing in the
     * chat they just left.
     */
    private var sessionOpenPending: Boolean = false

    /** True while the reader is dragging or flinging. */
    private var readerIsScrolling: Boolean = false

    /**
     * Remembers where the reader was when a backwards page was requested, so the
     * response can put them back rather than at the end.
     */
    fun armOlderPage(anchor: ChatScrollAnchor?) {
        pendingAnchor = anchor
    }

    /** The transcript changed. Returns where it should now be. */
    fun onContentChanged(sessionId: String?, groupCount: Int): ChatScrollAction {
        val openedNow = openedSessionId != sessionId
        if (openedNow) {
            openedSessionId = sessionId
            sessionOpenPending = true
            // An anchor from the chat we just left points at a message that is
            // not in this one.
            pendingAnchor = null
            // Whatever the reader was doing, they asked for this chat.
            isFollowingNewest = true
        }

        val action = ChatScrollPolicy.decide(
            sessionChanged = sessionOpenPending,
            groupCount = groupCount,
            previousGroupCount = lastGroupCount,
            anchor = pendingAnchor,
            isFollowingNewest = isFollowingNewest,
        )
        // Only spent once it has actually moved something. An empty transcript
        // is a `Hold`, and a `Hold` is not an answer, so the open stays pending
        // until the first page of rows turns up to be scrolled to.
        if (action !is ChatScrollAction.Hold) sessionOpenPending = false

        when (action) {
            is ChatScrollAction.PinToNewest -> isFollowingNewest = true
            is ChatScrollAction.RestoreAnchor -> pendingAnchor = null
            ChatScrollAction.Hold -> Unit
        }

        lastGroupCount = groupCount
        return action
    }

    /**
     * The reader asked for a turn by sending one, so the newest turn is where
     * they want to be even if they were reading history when they hit send.
     */
    fun onTurnSent(): ChatScrollAction {
        isFollowingNewest = true
        pendingAnchor = null
        return ChatScrollAction.PinToNewest(ChatPinReason.TURN_SENT)
    }

    /**
     * The viewport moved.
     *
     * Only an *interactive* scroll updates [isFollowingNewest]. Deriving it from
     * the layout alone is the trap this replaced: the first layout of a chat
     * reports the top of the list, so a watcher that trusted it would report
     * "the reader has scrolled away" at the exact moment the transcript was
     * being opened, and the scroll that was meant to land on the newest turn
     * would decline to run.
     *
     * [wasScrolling] is the previous reading rather than the current one, so the
     * final frame of a fling — which settles and stops scrolling in the same
     * snapshot — still counts as the reader's own movement.
     */
    fun onViewportMoved(
        lastVisibleIndex: Int,
        totalItems: Int,
        isScrolling: Boolean,
    ) {
        val wasScrolling = readerIsScrolling
        readerIsScrolling = isScrolling
        if (!wasScrolling && !isScrolling) return
        if (totalItems <= 0) return
        isFollowingNewest = lastVisibleIndex >= totalItems - 1
    }
}
