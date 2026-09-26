package com.nalar.mobile.chat

/**
 * How one transcript row is framed: as a chat bubble, as flat prose, or as a
 * tool card.
 *
 * The rule is one line — **a bubble is the reader's own turn and nothing
 * else**. Everything the assistant says is prose that flows with the page
 * background, the way a document does rather than the way a messenger does.
 * The web made the same call in 2026-08-23 (its "paragraph mode"): the bubble
 * chrome is bound to `group.role === 'user'` and the assistant side renders
 * `flex-1 w-full max-w-full` with no background, no border and no padding.
 *
 * This lives apart from the composables on purpose. "Is this row boxed?" is
 * the one decision a screenshot review keeps asking about, and a decision
 * buried inside a `Surface` parameter list can only be checked by rendering it
 * — which needs an emulator. As a pure function over a [ChatMessage] it is
 * pinned by a JVM unit test, so the rule is checked on every build that runs
 * `./gradlew test`, not only on the ones that boot a device.
 */
enum class MessageChrome {
    /**
     * A tool result: a card, never a bubble.
     *
     * Listed here rather than left implicit so [messageChrome] is total over
     * the roles the wire can deliver. A tool row used to be drawn as a bubble,
     * which put a label above a wall of raw JSON; dispatching it to its own
     * card is what keeps that from creeping back.
     */
    TOOL_CARD,

    /** The reader's own turn: tinted, rounded, right-aligned, width-capped. */
    BUBBLE,

    /**
     * An assistant turn: transparent, borderless, full-width prose.
     *
     * No `Surface`, so no fill, no outline and no corner radius — the page
     * background shows through and the text sits on the same measure as the
     * surrounding transcript.
     */
    PARAGRAPH,
}

/**
 * Which frame [message] is drawn in.
 *
 * Role decides, and only role. A reader turn is a bubble; a tool result is a
 * card; everything else is prose. Note what is *not* here: [ChatMessage.isError].
 * An agentic-loop diagnostic frame carries prose like any other assistant turn
 * and is coloured to stand out, but it is still not something the reader said,
 * so boxing it would put the one row that must not read as conversation back
 * into a conversation frame.
 */
fun messageChrome(message: ChatMessage): MessageChrome = when {
    message.role == ChatMessage.ROLE_TOOL -> MessageChrome.TOOL_CARD
    message.isUser -> MessageChrome.BUBBLE
    else -> MessageChrome.PARAGRAPH
}

/**
 * Vertical gap between the rows of one group, in dp.
 *
 * A bubble supplies its own separation — the fill and the 10dp padding either
 * side of the text are what tell two reader turns apart. Strip the box from an
 * assistant turn and that separation goes with it, so the gap has to come
 * from somewhere or a reasoning block runs straight into the answer it
 * belongs to. The web hit the same thing in paragraph mode and set
 * `.assistant-item + .assistant-item { margin-top: 0.625rem }` for it, so the
 * assistant side gets 10dp and the bubble side keeps the tighter 6dp it was
 * drawn with.
 */
fun groupGapDp(group: ChatMessageGroup): Int = if (group.isUser) 6 else 10
