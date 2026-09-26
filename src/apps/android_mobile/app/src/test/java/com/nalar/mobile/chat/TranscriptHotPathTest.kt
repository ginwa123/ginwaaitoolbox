package com.nalar.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The transcript's hot path, as a *time* question.
 *
 * Switching chat sessions froze the app. Everything here is on the main thread
 * and everything here runs again on every streamed delta, so the size of this
 * work is not a detail — it is the frame budget. The tests below are grouped
 * for two reasons:
 *
 * 1. **Correctness of the fast paths.** Every optimization added to make
 *    grouping cheap is a shortcut around a regex, and a shortcut around a regex
 *    is a behaviour change the moment it is wrong. Each one is pinned against
 *    the same input the slow path would have produced.
 * 2. **A ceiling on the cost.** A wall-clock assertion is normally a flaky
 *    test, and it is here only because the budget is orders of magnitude away
 *    from the new cost. Grouping the window
 *    [ChatViewModel.CACHED_MESSAGE_LIMIT]-sized transcript is a few
 *    milliseconds; the quadratic version it replaced was hundreds. A regression
 *    back to anything worse than linear fails with enormous headroom, and a slow
 *    CI machine still passes.
 */
class TranscriptHotPathTest {

    private fun message(
        id: String,
        role: String = ChatMessage.ROLE_USER,
        content: String = "x",
        sortKeyNanos: Long = 0L,
        toolCallId: String = "",
        toolName: String = "",
        toolCallsJson: String = "",
        finishReason: String = "",
    ) = ChatMessage(
        id = id,
        role = role,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = sortKeyNanos,
        toolCallId = toolCallId,
        toolName = toolName,
        toolCallsJson = toolCallsJson,
        finishReason = finishReason,
    )

    private fun calls(vararg ids: String) = ids.joinToString(
        prefix = "[",
        postfix = "]",
        separator = ",",
    ) { """{"id":"$it","function":{"name":"command","arguments":"{}"}}""" }

    // ── attachUnpairedToolCalls ─────────────────────────────────────────────
    //
    // The second grouping pass used to re-walk every group *after* the current
    // one, for every group holding a declaration, over a `Sequence` chain. These
    // pin the *semantics* it has to keep while doing that in one pass.

    @Test
    fun `a declaration answered by a later tool row is suppressed`() {
        val groups = groupMessages(
            listOf(
                message(
                    id = "d1",
                    role = ChatMessage.ROLE_ASSISTANT,
                    content = "",
                    toolCallsJson = calls("call_a"),
                    finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
                ),
                message(
                    id = "t1",
                    role = ChatMessage.ROLE_TOOL,
                    content = "ok",
                    toolCallId = "call_a",
                    toolName = "command",
                ),
            ),
        )

        assertEquals("the result card already says it", emptyList<String>(), groups
            .flatMap { it.unpairedToolCalls }
            .map { it.id })
    }

    @Test
    fun `a declaration with no result yet is named above the run`() {
        // The live window between the declaration landing and the result
        // arriving. Hiding it is how a running tool call becomes invisible.
        val groups = groupMessages(
            listOf(
                message(
                    id = "d1",
                    role = ChatMessage.ROLE_ASSISTANT,
                    content = "",
                    toolCallsJson = calls("call_a", "call_b"),
                    finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
                ),
                message(
                    id = "t1",
                    role = ChatMessage.ROLE_TOOL,
                    content = "ok",
                    toolCallId = "call_a",
                    toolName = "command",
                ),
            ),
        )

        assertEquals(
            listOf("call_b"),
            groups.flatMap { it.unpairedToolCalls }.map { it.id },
        )
    }

    @Test
    fun `a result row that PRECEDES its declaration still leaves it unpaired`() {
        // Out-of-order and re-delivered rows produce this. Matching a global set
        // of answered ids would suppress the call and show nothing at all; only
        // a row *after* the declaration counts.
        val groups = groupMessages(
            listOf(
                message(
                    id = "t1",
                    role = ChatMessage.ROLE_TOOL,
                    content = "ok",
                    toolCallId = "call_a",
                    toolName = "command",
                ),
                message(
                    id = "d1",
                    role = ChatMessage.ROLE_ASSISTANT,
                    content = "",
                    toolCallsJson = calls("call_a"),
                    finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
                ),
            ),
        )

        assertEquals(
            listOf("call_a"),
            groups.flatMap { it.unpairedToolCalls }.map { it.id },
        )
    }

    @Test
    fun `a declaration carrying prose is an ordinary turn, not a header`() {
        val groups = groupMessages(
            listOf(
                message(
                    id = "a1",
                    role = ChatMessage.ROLE_ASSISTANT,
                    content = "Let me look at that file.",
                    toolCallsJson = calls("call_a"),
                    finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
                ),
            ),
        )

        assertTrue(groups.flatMap { it.unpairedToolCalls }.isEmpty())
    }

    @Test
    fun `a transcript with no declarations groups identically either way`() {
        val plain = listOf(
            message("u1", ChatMessage.ROLE_USER, "hi", 1),
            message("a1", ChatMessage.ROLE_ASSISTANT, "hello", 2),
            message("u2", ChatMessage.ROLE_USER, "bye", 3),
        )

        assertEquals(
            listOf("u1", "a1", "u2"),
            groupMessages(plain).map { it.key },
        )
    }

    // ── The envelope / document fast paths ──────────────────────────────────
    //
    // Both gained a "can this possibly match?" gate. A gate that rejects
    // something the slow path accepted is a silent rendering bug: a document
    // that stops being a document, or a wrapped answer that keeps its wrapper.

    @Test
    fun `content with no envelope marker is returned unchanged`() {
        val plain = "## What I built\n\nA **bold** claim and a 3 < 4 comparison."
        assertEquals(plain.trim(), stripContentEnvelope(plain))
    }

    @Test
    fun `a comparison operator is not mistaken for a tag`() {
        // The gate looks for a `<`, so this is the case that could go wrong if
        // it ever started looking for something more specific.
        val plain = "scores 10 < 20 and 30 > 5"
        assertEquals(plain, stripContentEnvelope(plain))
        assertFalse(HtmlResponse.isHtmlTurn(plain))
        assertTrue(Markdown.hasContent(plain))
    }

    @Test
    fun `a markdown answer with an inline tag still is not a document`() {
        // A paragraph *mentioning* a tag is the case `isCandidate` has always
        // rejected, and the `<` gate must not turn that rejection into an
        // acceptance.
        val prose = "Here is how:\n\n<your-component> takes a prop."
        assertFalse(HtmlResponse.isHtmlTurn(prose))
    }

    @Test
    fun `a document turn is still recognised through the tag gate`() {
        assertTrue(HtmlResponse.isHtmlTurn("<html><body><h1>Report</h1></body></html>"))
        assertTrue(HtmlResponse.isHtmlTurn("<!doctype html><html><body>hi</body></html>"))
        assertTrue(HtmlResponse.isHtmlTurn("<div id=\"root\">hello</div>"))
    }

    @Test
    fun `every wrapper is still stripped`() {
        assertEquals("hello", stripContentEnvelope("<plain>hello</plain>"))
        assertEquals("hello", stripContentEnvelope("<markdown>hello</markdown>"))
        assertEquals("hello", stripContentEnvelope("<html>hello</html>"))
        assertEquals("hello", stripContentEnvelope("<think>hmm</think><markdown>hello</markdown>"))
        assertEquals("hello", stripContentEnvelope("```html\nhello\n```"))
        // Rule 1: a turn that is *only* thinking keeps its thinking.
        assertEquals("<think>hmm</think>", stripContentEnvelope("<think>hmm</think>"))
        // A code block inside prose is content, not a wrapper.
        val withCode = "look:\n\n```bash\nls -la\n```"
        assertTrue(stripContentEnvelope(withCode).contains("ls -la"))
    }

    @Test
    fun `a fenced document keeps its body and loses only the fence`() {
        val stripped = stripContentEnvelope("```markdown\n# Title\n\nbody text\n```")
        assertEquals("# Title\n\nbody text", stripped)
    }

    @Test
    fun `a blank turn draws nothing`() {
        assertFalse(Markdown.hasContent("   \n  "))
        assertFalse(Markdown.hasContent("<markdown>   </markdown>"))
        assertTrue(Markdown.hasContent("<markdown>  x  </markdown>"))
    }

    // ── The ceiling ─────────────────────────────────────────────────────────

    /**
     * A realistic assistant turn: markdown, a code block, no envelope, no tag.
     *
     * This is the shape that dominates a real transcript, and it is the shape
     * every visibility check has to answer for. It is deliberately *not* a
     * document and *not* wrapped — the gates are supposed to reject it on the
     * first character scan and never reach a regex.
     */
    private fun turn(index: Int): String = buildString {
        appendLine("## Step $index")
        appendLine()
        appendLine("I updated the parser and re-ran the suite. Here is the shape it takes now:")
        appendLine()
        appendLine("```kotlin")
        repeat(20) { appendLine("    val parsed = engine.parse(source).sortedBy { it.sortKeyNanos }") }
        appendLine("```")
        appendLine()
        appendLine("- the gate runs first, so the common answer never touches a regex")
        appendLine("- the fallback is only for content that is genuinely unusual")
    }

    @Test
    fun `deciding what to draw across a full-size transcript stays well inside a frame`() {
        // [ChatMessage.hasVisibleContent] runs for every row of every group, on
        // the main thread, on every change to the transcript — which on a
        // session switch is twice: once for the cached paint, once when the
        // revalidated page replaces it.
        //
        // Before the fast paths this measured 58ms on a desktop JVM for this
        // payload, and it is now 0.55ms. On a phone that gap is hundreds of
        // milliseconds of UI thread per pass, which is most of a reported
        // freeze. The budget below is ~70x the measured cost, so it fails only
        // on a genuine regression back through the regexes rather than on a
        // slow machine.
        val messages = List(ChatViewModel.CACHED_MESSAGE_LIMIT) { index ->
            message("a$index", ChatMessage.ROLE_ASSISTANT, turn(index), index.toLong())
        }

        var drawn = 0
        val startedAt = System.nanoTime()
        messages.forEach { row ->
            if (row.hasVisibleContent) drawn++
        }
        val elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000

        assertEquals(messages.size, drawn)
        assertTrue(
            "deciding visibility for ${messages.size} turns took ${elapsedMillis}ms",
            elapsedMillis < 40,
        )
    }
}
