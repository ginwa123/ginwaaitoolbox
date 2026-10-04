package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bubble rule: a bubble is the reader's own turn and nothing else.
 *
 * This is the only assertion standing between "the assistant answers as flat
 * prose" and "the assistant answers as flat prose again in three months",
 * because the thing that regresses is a `Surface` parameter quietly coming back
 * on a row, and a filled, bordered, rounded box is not something a JVM test
 * can see. The composable that consumed the old shared bubble is gone; what is
 * left to regress is this dispatch, so this is where the rule is pinned.
 *
 * The web it mirrors is `ChatView.vue`'s 2026-08-23 paragraph mode, where the
 * bubble chrome is bound to `group.role === 'user'` and the assistant side
 * renders bare. If the two clients are ever meant to diverge, this is the test
 * that has to be deleted rather than quietly relaxed.
 */
class MessageChromeTest {

    private fun message(
        role: String,
        id: String = "m1",
        isError: Boolean = false,
        toolName: String = "",
    ) = ChatMessage(
        id = id,
        role = role,
        content = "text",
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        isError = isError,
        toolName = toolName,
    )

    private fun group(role: String, vararg messages: ChatMessage) = ChatMessageGroup(
        key = messages.firstOrNull()?.id ?: "g1",
        role = role,
        messages = messages.toList(),
        timestampEpochMillis = 0L,
    )

    @Test
    fun `a reader turn is the one row that keeps the bubble`() {
        assertEquals(MessageChrome.BUBBLE, messageChrome(message(ChatMessage.ROLE_USER)))
    }

    @Test
    fun `an assistant turn is flat prose, not a bubble`() {
        assertEquals(
            MessageChrome.PARAGRAPH,
            messageChrome(message(ChatMessage.ROLE_ASSISTANT)),
        )
    }

    @Test
    fun `a tool result is a card and never a bubble`() {
        assertEquals(
            MessageChrome.TOOL_CARD,
            messageChrome(message(ChatMessage.ROLE_TOOL, toolName = "read_file")),
        )
    }

    /**
     * `system` is a role the wire can deliver and nothing in this app renders it
     * as a conversation turn, so it belongs on the prose side. Naming it here
     * is the point: it is the role most likely to be added to the `when` by
     * someone reasoning "well, it's not the user, so bubble it".
     */
    @Test
    fun `a system turn is prose, not a bubble`() {
        assertEquals(
            MessageChrome.PARAGRAPH,
            messageChrome(message(ChatMessage.ROLE_SYSTEM)),
        )
    }

    /**
     * The regression this whole file exists for: `isError` frames are the
     * agentic-loop's own diagnostics, and the instinct when styling one is to
     * wrap it in a raised box so it stands out. It carries assistant prose, so
     * it gets the same flat frame — the red text and the leading rule do the
     * marking instead.
     */
    @Test
    fun `a diagnostic frame is prose too, not a raised bubble`() {
        assertEquals(
            MessageChrome.PARAGRAPH,
            messageChrome(message(ChatMessage.ROLE_ASSISTANT, isError = true)),
        )
    }

    /**
     * Role wins over `isError`, in the other direction. A user row flagged as
     * an error is still something the reader typed, so it still bubbles.
     */
    @Test
    fun `a flagged user turn still bubbles`() {
        assertEquals(
            MessageChrome.BUBBLE,
            messageChrome(message(ChatMessage.ROLE_USER, isError = true)),
        )
    }

    /**
     * Exhaustiveness, stated as a test. `messageChrome` is a `when` whose last
     * branch is `else`, so a role added to [ChatMessage] later lands in
     * `PARAGRAPH` without a line anywhere saying that was a decision. Pinning
     * the whole role → frame table means a new role fails this test rather than
     * quietly shipping as a paragraph.
     */
    @Test
    fun `the role to frame table is pinned`() {
        assertEquals(
            mapOf(
                ChatMessage.ROLE_USER to MessageChrome.BUBBLE,
                ChatMessage.ROLE_ASSISTANT to MessageChrome.PARAGRAPH,
                ChatMessage.ROLE_SYSTEM to MessageChrome.PARAGRAPH,
                ChatMessage.ROLE_TOOL to MessageChrome.TOOL_CARD,
            ),
            ChatMessage.knownRoles().associateWith { messageChrome(message(it)) },
        )
    }

    /**
     * A flat paragraph has to be spaced by something other than its box.
     *
     * The web sets `.assistant-item + .assistant-item { margin-top: 0.625rem }`
     * for exactly this reason, and 6dp is what a boxed bubble was already
     * getting — so the assistant gap has to be strictly the roomier of the two,
     * or stripping the box silently collapses consecutive assistant rows
     * together.
     */
    @Test
    fun `flat paragraphs get more room than bubbles`() {
        val assistant = groupGapDp(group(ChatMessage.ROLE_ASSISTANT, message(ChatMessage.ROLE_ASSISTANT)))
        val user = groupGapDp(group(ChatMessage.ROLE_USER, message(ChatMessage.ROLE_USER)))
        assertTrue(
            "assistant gap $assistant should exceed bubble gap $user",
            assistant > user,
        )
        assertEquals(10, assistant)
        assertEquals(6, user)
    }
}
