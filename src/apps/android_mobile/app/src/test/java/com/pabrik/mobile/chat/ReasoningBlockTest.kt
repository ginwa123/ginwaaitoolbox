package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which turns get a reasoning fold, and under what key.
 *
 * These are the two decisions the composed tree makes per assistant row, and
 * both are the kind that no screenshot review catches: a fold that never draws
 * looks identical to a turn that had no reasoning, and a key collision looks
 * like a tool card that opens when you did not tap it. Pulled out as plain
 * functions so `./gradlew test` pins them without an emulator, which is the
 * same bargain `MessageChrome` makes.
 */
class ReasoningBlockTest {

    private fun assistant(
        id: String = "m1",
        content: String = "Here is the answer.",
        reasoning: String = "Let me work through it.",
    ) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_ASSISTANT,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        reasoningContent = reasoning,
    )

    @Test
    fun `an assistant turn with reasoning draws the fold`() {
        assertTrue(showsReasoning(assistant()))
    }

    @Test
    fun `a turn with no reasoning draws nothing`() {
        assertFalse(showsReasoning(assistant(reasoning = "")))
    }

    /**
     * `isNotBlank`, not `isNotEmpty`, because the stream delivers a reasoning
     * chunk as a delta: between the turn being created and its first real
     * delta the field is present and empty, and a fold that appears for one
     * frame and then vanishes is worse than never appearing.
     */
    @Test
    fun `a whitespace-only reasoning draws nothing`() {
        assertFalse(showsReasoning(assistant(reasoning = "   \n\t ")))
    }

    @Test
    fun `the reader's own turn never gets a fold`() {
        val reader = assistant().copy(role = ChatMessage.ROLE_USER)

        assertFalse(showsReasoning(reader))
    }

    /**
     * The regression this namespacing exists to prevent. A tool card is filed
     * under its `ToolCardModel.id`, which is the message id verbatim, so an
     * unprefixed reasoning key would share a slot with that turn's card and the
     * two toggles would be one.
     */
    @Test
    fun `the key is namespaced away from the tool card key`() {
        assertNotEquals("m1", reasoningKey("m1"))
        assertEquals("reasoning-m1", reasoningKey("m1"))
    }

    @Test
    fun `two turns do not share a reasoning key`() {
        assertNotEquals(reasoningKey("m1"), reasoningKey("m2"))
    }

    /**
     * The default the whole feature is specified around: folded. `ToolExpansion`
     * with no `defaultsToOpen` is what produces it, and it is asserted here
     * through the real key function so the two cannot drift apart silently.
     */
    @Test
    fun `a reasoning fold is collapsed until the reader opens it`() {
        val expansion = ToolExpansion()

        assertFalse(expansion.isExpanded(reasoningKey("m1")))

        expansion.toggle(reasoningKey("m1"))

        assertTrue(expansion.isExpanded(reasoningKey("m1")))
    }

    /**
     * The header says what the web's `<summary>` says. The two clients are
     * kept word-for-word in step on purpose, so this is a contract rather than
     * a preference.
     */
    @Test
    fun `the folded header reads Thought`() {
        assertEquals("Thought", REASONING_LABEL)
    }
}
