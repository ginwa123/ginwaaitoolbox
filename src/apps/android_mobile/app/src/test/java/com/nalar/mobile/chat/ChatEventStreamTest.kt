package com.nalar.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The event-stream reader.
 *
 * The backend pretty-prints every SSE payload with a 4-space indent and then
 * prefixes *each resulting line* with `data: `. A parser that treats the stream
 * as a sequence of complete JSON documents throws on the very first indented
 * line and the chat silently never updates — so these cases are the ones that
 * decide whether streaming works at all.
 */
class SseFrameParserTest {

    private fun parse(raw: String): List<SseFrame> {
        val parser = SseFrameParser()
        val frames = mutableListOf<SseFrame>()
        raw.lines().forEach { line -> parser.accept(line)?.let { frames.add(it) } }
        parser.flush()?.let { frames.add(it) }
        return frames
    }

    @Test
    fun `the handshake is one frame`() {
        val frames = parse("event: connected\ndata: {\"connected\": true}\n\n")

        assertEquals(1, frames.size)
        assertEquals("connected", frames.single().event)
        assertEquals("""{"connected": true}""", frames.single().data)
    }

    @Test
    fun `a pretty-printed payload is rejoined across its data lines`() {
        val raw = """
            event: llm_full
            data: {
            data:     "content": "hello",
            data:     "session_id": "sess_1"
            data: }

        """.trimIndent()

        val frame = parse(raw).single()

        assertEquals("llm_full", frame.event)
        // Byte-for-byte what the server serialised, which is what makes the
        // result parseable as JSON.
        assertEquals("{\n    \"content\": \"hello\",\n    \"session_id\": \"sess_1\"\n}", frame.data)
    }

    @Test
    fun `a frame dispatches on the blank line, not on a complete object`() {
        val frames = parse("event: a\ndata: {\"x\":1}\n\nevent: b\ndata: {\"x\":2}\n\n")

        assertEquals(2, frames.size)
        assertEquals("a", frames[0].event)
        assertEquals("b", frames[1].event)
    }

    @Test
    fun `comment lines and the heartbeat are ignored`() {
        val frames = parse(": ping\n\nevent: connected\ndata: {}\n\n")

        assertEquals(1, frames.size)
        assertEquals("connected", frames.single().event)
    }

    @Test
    fun `a stream that ends mid-frame still dispatches what it has`() {
        // A connection dropped mid-frame must not swallow a complete-looking
        // payload, or the last turn before a network blip is lost.
        val parser = SseFrameParser()
        parser.accept("event: llm_full")
        parser.accept("""data: {"id":"m1"}""")

        val frame = parser.flush()

        assertNotNull(frame)
        assertEquals("llm_full", frame!!.event)
        assertEquals("""{"id":"m1"}""", frame.data)
    }

    @Test
    fun `a frame with no event line is dispatched under the default name`() {
        val frames = parse("data: {\"x\":1}\n\n")

        assertEquals(SseFrameParser.DEFAULT_EVENT, frames.single().event)
        assertEquals("""{"x":1}""", frames.single().data)
    }

    @Test
    fun `only the first space after the colon is stripped`() {
        val frames = parse("event: connected\ndata:  two spaces\n\n")

        assertEquals(" two spaces", frames.single().data)
    }

    @Test
    fun `an empty stream dispatches nothing`() {
        assertTrue(parse("").isEmpty())
        assertTrue(parse("\n\n\n").isEmpty())
        assertTrue(parse(": only comments\n").isEmpty())
    }
}

/** Decoding a frame into the meaning the chat acts on. */
class ChatStreamEventTest {

    private fun frame(event: String, data: String) = SseFrame(event, data)

    @Test
    fun `a content chunk is one event`() {
        val decoded = decodeChatFrame(
            frame(
                "llm_chunk",
                """{"type":"chunk","index":0,"session_id":"sess_1","content":"Hel"}""",
            ),
        ) as ChatStreamEvent.Chunk

        assertEquals("sess_1", decoded.sessionId)
        assertEquals("Hel", decoded.content)
        assertEquals("", decoded.reasoningContent)
    }

    @Test
    fun `a reasoning chunk shares the chunk type and is told apart by its field`() {
        // `type: "chunk"` is overloaded across content and reasoning, so
        // branching on the type alone loses every thinking delta.
        val decoded = decodeChatFrame(
            frame(
                "llm_chunk",
                """{"type":"chunk","index":0,"session_id":"sess_1","reasoning_content":"thinking"}""",
            ),
        ) as ChatStreamEvent.Chunk

        assertEquals("thinking", decoded.reasoningContent)
        assertEquals("", decoded.content)
    }

    @Test
    fun `a chunk with neither field is not an event`() {
        assertNull(decodeChatFrame(frame("llm_chunk", """{"type":"chunk","index":0,"session_id":"s"}""")))
    }

    @Test
    fun `a final chunk carries no message`() {
        val decoded = decodeChatFrame(
            frame("llm_chunk", """{"type":"chunk_final","index":0,"session_id":"sess_1","total_tokens":42}"""),
        ) as ChatStreamEvent.ChunkFinished

        assertEquals("sess_1", decoded.sessionId)
        assertEquals(42, decoded.totalTokens)
    }

    @Test
    fun `a full frame becomes a canonical message`() {
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","id":"m1","session_id":"sess_1","role":"assistant",
                   "content":"done","created_at":"1789451234567890123"}""",
            ),
        ) as ChatStreamEvent.Full

        assertEquals("sess_1", decoded.sessionId)
        assertEquals("m1", decoded.message.id)
        assertEquals(ChatMessage.ROLE_ASSISTANT, decoded.message.role)
    }

    @Test
    fun `a contentless tool row is still a real turn`() {
        // Gating on content alone used to silently drop every tool result and
        // every image-only echo, which looked like the agent doing nothing.
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","id":"m1","session_id":"sess_1","tool_call_id":"call_1","tool_name":"command"}""",
            ),
        ) as ChatStreamEvent.Full

        assertEquals("command", decoded.message.toolName)
    }

    @Test
    fun `a truly empty row is dropped rather than rendering a blank bubble`() {
        assertNull(
            decodeChatFrame(frame("llm_full", """{"type":"full","id":"m1","session_id":"sess_1"}""")),
        )
    }

    @Test
    fun `an is_error frame is a diagnostic, not a chat turn`() {
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","id":"m1","session_id":"sess_1","content":"TooManyRetries","is_error":true}""",
            ),
        )

        assertTrue(decoded is ChatStreamEvent.Failed)
        assertEquals("TooManyRetries", (decoded as ChatStreamEvent.Failed).message)
    }

    @Test
    fun `an auth_error surfaces instead of looking like a flaky network`() {
        // The response is already committed as text/event-stream by the time
        // auth runs, so the server cannot answer 401 — it sends this and closes.
        // Without handling it, an expired cookie looks exactly like a dropped
        // connection and the app retries forever.
        val decoded = decodeChatFrame(frame("auth_error", """{"error":"Unauthenticated"}"""))

        assertEquals("Unauthenticated", (decoded as ChatStreamEvent.Failed).message)
    }

    @Test
    fun `session events report the action from the event name`() {
        val updated = decodeChatFrame(
            frame(
                "session_updated",
                """{"action":"updated","id":"sess_1","name":"Renamed by the auto-title pass"}""",
            ),
        ) as ChatStreamEvent.SessionChanged

        // `session_updated` is load-bearing: the auto-rename cascade used to
        // arrive as `session_unknown`, which nothing handled, so titles stayed
        // "New Chat" until a manual refresh.
        assertEquals("updated", updated.action)
        assertEquals("Renamed by the auto-title pass", updated.name)
    }

    @Test
    fun `queue events report the action too`() {
        val queued = decodeChatFrame(
            frame("queue_queued", """{"action":"queued","id":"q1","session_id":"sess_1"}"""),
        ) as ChatStreamEvent.QueueChanged

        assertEquals("queued", queued.action)
        assertEquals("sess_1", queued.sessionId)
    }

    @Test
    fun `an event this screen does not act on is dropped, not an error`() {
        assertNull(decodeChatFrame(frame("worker_created", """{"id":"w1"}""")))
        assertNull(decodeChatFrame(frame("kanban_task", """{"id":"t1"}""")))
    }

    @Test
    fun `an unparseable payload is dropped without killing the stream`() {
        assertNull(decodeChatFrame(frame("llm_full", "{not json")))
        assertNull(decodeChatFrame(frame("llm_chunk", "")))
    }
}
