package com.nalar.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wire contract for the chat endpoint.
 *
 * These are the traps in the backend's JSON that a client gets wrong silently
 * — no exception, just a transcript that is missing messages, sorted wrongly,
 * or carrying the literal text `null`. Every case here is one that actually
 * differs from what the desktop client does.
 */
class ChatApiTest {

    // A real payload shape, with the envelope fields the server always emits.
    private val messagesResponse = """
        {
          "messages": [
            {
              "id": "1789451234567890123",
              "session_id": "sess_1",
              "role": "user",
              "content": "Hai!",
              "created_at": "1789451234567890123",
              "is_input": true,
              "is_output": false,
              "tool_name": "",
              "finish_reason": "",
              "reasoning_content": "",
              "diffview_before": "",
              "diffview_after": "",
              "image_url": "",
              "video_url": "",
              "tool_call_id": "",
              "tool_calls_json": ""
            },
            {
              "id": "1789451234567890124",
              "session_id": "sess_1",
              "role": "tool",
              "content": "done",
              "created_at": "1789451234567890124",
              "is_input": false,
              "is_output": false,
              "tool_name": "command",
              "finish_reason": "",
              "reasoning_content": "",
              "diffview_before": "",
              "diffview_after": "",
              "image_url": "data:image/png;base64,AAA|data:image/jpeg;base64,BBB",
              "video_url": "data:video/mp4;base64,CCC",
              "tool_call_id": "call_1",
              "tool_calls_json": "{\"name\":\"command\"}"
            }
          ],
          "has_more": false,
          "next_cursor": null,
          "cwd": "/home/ginwa/ginwaaitoolbox",
          "git_worktree_cwd": "",
          "pr_url": null,
          "pr_provider": null,
          "selected_profile_model": "900ribu",
          "sub_agent_name": null,
          "parent_session_id": null,
          "max_total_tokens": 82679,
          "max_capacity_total_tokens": 900000,
          "total": 2,
          "skills": null
        }
    """.trimIndent()

    @Test
    fun `the message path sorts by id because created_at is inconsistent across pages`() {
        val path = ChatApi.messagesPath("sess_1", limit = 50, direction = "asc")

        // `sort_by=created_at` orders page 1 by the *session's* created_at —
        // identical for every row, so it degenerates to id order — and later
        // pages by the message's. `id` is the only consistent key.
        assertTrue(path, path.contains("sort_by=id"))
        assertTrue(path, path.contains("direction=asc"))
        assertTrue(path, path.contains("limit=50"))
        assertTrue(path, path.contains("/api/llm/session/sess_1/messages"))
    }

    @Test
    fun `a cursor is only sent when there is one`() {
        assertTrue(ChatApi.messagesPath("s", cursor = "1789451234567890123").contains("cursor=1789451234567890123"))
        assertTrue(ChatApi.messagesPath("s", cursor = null).endsWith("direction=asc"))
        assertTrue(ChatApi.messagesPath("s", cursor = "  ").endsWith("direction=asc"))
    }

    @Test
    fun `an absurd limit is clamped because the server does not clamp it`() {
        val path = ChatApi.messagesPath("s", limit = 100_000)
        assertTrue(path, path.contains("limit=1000"))
    }

    @Test
    fun `a session id is percent encoded so it cannot escape its path segment`() {
        val path = ChatApi.messagesPath("../admin")
        assertTrue(path, path.contains("/api/llm/session/..%2Fadmin/messages"))
    }

    @Test
    fun `parsing reads total and not the key the desktop client invented`() {
        val page = ChatApi.parseMessages(messagesResponse)

        assertEquals(2, page.messages.size)
        assertEquals(2, page.total)
        assertEquals("900ribu", page.selectedProfileModel)
        assertEquals("/home/ginwa/ginwaaitoolbox", page.cwd)
        assertEquals(false, page.hasMore)
        assertNull(page.nextCursor)
    }

    @Test
    fun `a null cursor stays null instead of becoming the text null`() {
        val page = ChatApi.parseMessages(
            """{"messages":[],"next_cursor":null,"has_more":false,"total":0}""",
        )
        assertNull(page.nextCursor)
    }

    @Test
    fun `created_at holding nanoseconds is read as a nanosecond stamp`() {
        val page = ChatApi.parseMessages(messagesResponse)
        val first = page.messages.first()

        assertEquals(1_789_451_234_567_890_123L, first.sortKeyNanos)
        assertEquals(1_789_451_234_567L, first.createdAtEpochMillis)
    }

    @Test
    fun `created_at holding a SQLite datetime is read as UTC, not device-local`() {
        // The same column is written both ways depending on the code path, so
        // this shape genuinely occurs. Reading it as a number would sort the row
        // to the wrong end of the transcript, which reads as a missing message
        // rather than as a bug.
        val page = ChatApi.parseMessages(
            """{"messages":[{"id":"a","role":"user","content":"x","created_at":"2026-09-26 05:07:34"}]}""",
        )
        val nanos = page.messages.single().sortKeyNanos

        assertEquals("2026-09-26T05:07:34Z", java.time.Instant.ofEpochMilli(nanos / 1_000_000).toString())
    }

    @Test
    fun `an absent or garbage timestamp sorts to the start rather than to 1970`() {
        assertEquals(0L, ChatApi.parseCreatedAtNanos(null))
        assertEquals(0L, ChatApi.parseCreatedAtNanos(""))
        assertEquals(0L, ChatApi.parseCreatedAtNanos("   "))
        assertEquals(0L, ChatApi.parseCreatedAtNanos("not a timestamp"))
        // Calendar-invalid: matches the shape but is not an instant.
        assertEquals(0L, ChatApi.parseCreatedAtNanos("2026-02-31 00:00:00"))
    }

    @Test
    fun `image and video urls are pipe delimited, not arrays`() {
        val page = ChatApi.parseMessages(messagesResponse)
        val toolRow = page.messages[1]

        assertEquals(
            listOf("data:image/png;base64,AAA", "data:image/jpeg;base64,BBB"),
            toolRow.imageUrls,
        )
        assertEquals(listOf("data:video/mp4;base64,CCC"), toolRow.videoUrls)
    }

    @Test
    fun `a blank entry between pipes is dropped rather than rendered as an attachment`() {
        assertEquals(
            listOf("a", "b"),
            ChatApi.splitPipeDelimited("a||b|"),
        )
        assertEquals(emptyList<String>(), ChatApi.splitPipeDelimited(""))
        assertEquals(emptyList<String>(), ChatApi.splitPipeDelimited(null))
    }

    @Test
    fun `tool_calls_json stays the JSON string the server sent`() {
        val page = ChatApi.parseMessages(messagesResponse)
        // The desktop client types this as `any`, which quietly invites a
        // caller to treat it as an object. It is a string containing JSON.
        assertEquals("command", page.messages[1].toolName)
        assertEquals("call_1", page.messages[1].toolCallId)
    }

    @Test
    fun `a row with no id is dropped because it cannot be merged or keyed`() {
        // A duplicate key crashes LazyColumn outright, so an idless row is not
        // something to paper over with a synthetic id.
        val page = ChatApi.parseMessages(
            """{"messages":[{"role":"user","content":"no id"},{"id":"","content":"blank id"},{"id":"ok","content":"fine"}]}""",
        )
        assertEquals(listOf("ok"), page.messages.map { it.id })
    }

    @Test
    fun `a role-less tool row is recognised as a tool row`() {
        val page = ChatApi.parseMessages(
            """{"messages":[{"id":"a","content":"x","tool_call_id":"call_9"}]}""",
        )
        assertEquals(ChatMessage.ROLE_TOOL, page.messages.single().role)
    }

    @Test
    fun `the same mapper renders a cached raw envelope and a network row identically`() {
        // The web's hard-won rule: two mappers for one endpoint is how a cached
        // mount and a live mount drift. Cached rows go through the same call.
        val network = ChatApi.parseMessages(messagesResponse).messages.first()
        val cached = ChatApi.toChatMessage(network.rawEnvelope())

        assertNotNull(cached)
        assertEquals(network, cached)
    }

    @Test
    fun `a corrupt cached envelope is a miss, not a crash`() {
        assertNull(ChatApi.toChatMessage("{not json"))
        assertNull(ChatApi.toChatMessage(""))
    }

    @Test
    fun `an envelope that omits every optional field still parses`() {
        val page = ChatApi.parseMessages("""{"messages":[]}""")
        assertEquals(0, page.messages.size)
        assertEquals(null, page.total)
        assertEquals("", page.cwd)
    }

    @Test
    fun `merging replaces by id and keeps transcript order`() {
        val a = message("1", "first")
        val b = message("2", "second")
        val updatedB = message("2", "second, revised")

        val merged = ChatApi.mergeById(listOf(a, b), listOf(updatedB))

        assertEquals(listOf("1", "2"), merged.map { it.id })
        assertEquals("second, revised", merged.last().content)
    }

    @Test
    fun `merging nothing leaves the list untouched`() {
        val messages = listOf(message("1", "a"))
        assertEquals(messages, ChatApi.mergeById(messages, emptyList()))
    }

    @Test
    fun `the send body carries the web's tool grant and pipe-joins attachments`() {
        val body = org.json.JSONObject(
            ChatApi.sendMessageBody(
                sessionId = "sess_1",
                message = "hello",
                cwd = "/tmp",
                imageUrls = listOf("img1", "img2"),
                videoUrls = listOf("vid1"),
                selectedProfileModel = "900ribu",
            ),
        )

        assertEquals("sess_1", body.getString("session_id"))
        assertEquals("hello", body.getString("queue_message"))
        assertEquals("/tmp", body.getString("cwd_session"))
        assertEquals("img1|img2", body.getString("image_urls"))
        assertEquals("vid1", body.getString("video_urls"))
        assertEquals("900ribu", body.getString("selected_profile_model"))
        assertTrue(body.getString("allowed_tools").contains("ask_user"))
    }

    private fun message(id: String, content: String) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_USER,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
    )

    /** Rebuilds the wire object a row came from, the way the cache stores it. */
    private fun ChatMessage.rawEnvelope(): String = org.json.JSONObject()
        .put("id", id)
        .put("role", role)
        .put("content", content)
        .put("created_at", sortKeyNanos.toString())
        .toString()
}
