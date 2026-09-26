package com.nalar.mobile.chat

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cache contract: namespacing, the `raw` envelope, and the cursor rule.
 *
 * The bugs this pins are the ones that leak or silently lose history, and none
 * of them throw — a cross-account read and a cursor wiped to null both just
 * render the wrong thing.
 */
class ChatCacheCodecTest {

    private fun row(
        id: String,
        nanos: Long = 1_000L,
        role: String = ChatMessage.ROLE_USER,
        content: String = "hello",
    ): JSONObject = JSONObject()
        .put("id", id)
        .put("session_id", "sess_1")
        .put("role", role)
        .put("content", content)
        .put("created_at", nanos.toString())

    private fun rowWithExtras(id: String, nanos: Long = 1_000L): JSONObject =
        row(id, nanos)
            .put("tool_calls_json", """{"name":"command"}""")
            .put("diffview_before", "a")
            .put("is_output", true)

    private fun cached(
        id: String,
        nanos: Long = 1_000L,
        raw: String = row(id, nanos).toString(),
    ) = CachedChatMessage(
        id = id,
        sortKeyNanos = nanos,
        sessionId = "sess_1",
        role = ChatMessage.ROLE_USER,
        content = "hello",
        raw = raw,
    )

    // --- Namespacing -------------------------------------------------------

    @Test
    fun `an unresolved identity cannot be expressed as a key at all`() {
        // Stricter than the web's `userScopedKey`, which falls back to an
        // unscoped key when identity is unknown. On a phone that fallback is
        // exactly the case where one account's chat shows up for the next.
        assertNull(ChatCacheCodec.messagesKey(null, "sess_1"))
        assertNull(ChatCacheCodec.messagesKey("   ", "sess_1"))
        assertNull(ChatCacheCodec.messagesKey("user_a", "   "))
        assertNull(ChatCacheCodec.cursorKey(null, "sess_1"))
    }

    @Test
    fun `two accounts on one device get different keys for the same chat`() {
        assertNotEquals(
            ChatCacheCodec.messagesKey("user_a", "sess_1"),
            ChatCacheCodec.messagesKey("user_b", "sess_1"),
        )
    }

    @Test
    fun `two chats in the same account get different keys`() {
        assertNotEquals(
            ChatCacheCodec.messagesKey("user_a", "sess_1"),
            ChatCacheCodec.messagesKey("user_a", "sess_2"),
        )
    }

    @Test
    fun `the messages key and the cursor key never collide`() {
        // They are written by different code and must not be readable as one
        // another — a cursor read through the messages decoder would look like
        // a cache miss forever.
        assertNotEquals(
            ChatCacheCodec.messagesKey("user_a", "sess_1"),
            ChatCacheCodec.cursorKey("user_a", "sess_1"),
        )
    }

    @Test
    fun `the key is versioned so a shape change invalidates instead of misreading`() {
        assertTrue(ChatCacheCodec.messagesKey("user_a", "sess_1")!!.contains(":v1:"))
    }

    // --- The raw envelope --------------------------------------------------

    @Test
    fun `a cached row keeps the whole server object, not a projection`() {
        val original = rowWithExtras("m1")

        val cachedRow = ChatCacheCodec.toCachedMessage("sess_1", original)!!
        val roundTripped = JSONObject(cachedRow.raw)

        assertEquals("""{"name":"command"}""", roundTripped.getString("tool_calls_json"))
        assertEquals("a", roundTripped.getString("diffview_before"))
        assertTrue(roundTripped.getBoolean("is_output"))
    }

    @Test
    fun `a row without an id cannot be cached`() {
        assertNull(ChatCacheCodec.toCachedMessage("sess_1", JSONObject().put("content", "x")))
    }

    @Test
    fun `the hoisted sort key comes from created_at, in both of its wire shapes`() {
        assertEquals(
            1_789_451_234_567_890_123L,
            ChatCacheCodec.toCachedMessage("s", row("m", 1_789_451_234_567_890_123L))!!.sortKeyNanos,
        )
        assertEquals(
            ChatApi.parseCreatedAtNanos("2026-09-26 05:07:34"),
            ChatCacheCodec.toCachedMessage(
                "s",
                JSONObject().put("id", "m").put("created_at", "2026-09-26 05:07:34"),
            )!!.sortKeyNanos,
        )
    }

    @Test
    fun `a message round trips through the codec`() {
        val original = ChatCacheCodec.toCachedMessage("sess_1", row("m1", 5_000L))!!
        val decoded = ChatCacheCodec.decodeMessages(ChatCacheCodec.encodeMessages(listOf(original)))!!

        assertEquals(1, decoded.size)
        assertEquals(original, decoded.single())
    }

    @Test
    fun `a corrupt or foreign payload reads as a miss rather than as partial data`() {
        assertNull(ChatCacheCodec.decodeMessages(null))
        assertNull(ChatCacheCodec.decodeMessages(""))
        assertNull(ChatCacheCodec.decodeMessages("not json"))
        assertNull(ChatCacheCodec.decodeMessages("""{"messages":42}"""))
        // A row with no id, or with no stored raw, makes the whole document
        // suspect rather than half-trustworthy.
        assertNull(ChatCacheCodec.decodeMessages("""{"messages":[{"content":"x"}]}"""))
        assertNull(ChatCacheCodec.decodeMessages("""{"messages":[{"id":"m1"}]}"""))
        assertNull(ChatCacheCodec.decodeMessages("""{"messages":[{"id":"m1","raw":""}]}"""))
    }

    // --- The cursor rule ---------------------------------------------------

    @Test
    fun `the cursor advances to the newest row seen`() {
        assertEquals(
            "300",
            ChatCacheCodec.newestCursor(
                listOf(cached("a", 100), cached("b", 300), cached("c", 200)),
                nextCursor = null,
                previousCursor = null,
            ),
        )
    }

    @Test
    fun `an empty delta keeps the previous cursor instead of wiping it to null`() {
        // The server only sends `next_cursor` when `has_more` is true, so
        // persisting it would null out a good cursor after every small delta
        // and force a full descending reload on the next mount.
        assertEquals(
            "500",
            ChatCacheCodec.newestCursor(emptyList(), nextCursor = null, previousCursor = "500"),
        )
    }

    @Test
    fun `the cursor never regresses when an older page arrives`() {
        assertEquals(
            "900",
            ChatCacheCodec.newestCursor(
                listOf(cached("old", 100)),
                nextCursor = "100",
                previousCursor = "900",
            ),
        )
    }

    @Test
    fun `with nothing cached and nothing to advance to, the server cursor is used`() {
        assertEquals(
            "123",
            ChatCacheCodec.newestCursor(emptyList(), nextCursor = "123", previousCursor = null),
        )
    }

    @Test
    fun `a row with no usable timestamp cannot drag the cursor backwards`() {
        assertEquals(
            "400",
            ChatCacheCodec.newestCursor(
                listOf(cached("a", 0)),
                nextCursor = null,
                previousCursor = "400",
            ),
        )
    }

    // --- Ordering and merging ---------------------------------------------

    @Test
    fun `reads come back newest first, matching the store's own read order`() {
        val sorted = ChatCacheCodec.sortNewestFirst(
            listOf(cached("a", 100), cached("c", 300), cached("b", 200)),
        )
        assertEquals(listOf("c", "b", "a"), sorted.map { it.id })
    }

    @Test
    fun `a same-id write replaces the cached row in place`() {
        val merged = ChatCacheCodec.mergeReplacing(
            listOf(cached("a", 100), cached("b", 200)),
            listOf(cached("b", 200, raw = row("b", 200).put("content", "revised").toString())),
        )

        assertEquals(2, merged.size)
        assertEquals(1, merged.count { it.id == "b" })
        assertTrue(JSONObject(merged.first { it.id == "b" }.raw).getString("content") == "revised")
    }

    @Test
    fun `writing nothing leaves the cache alone`() {
        val existing = listOf(cached("a"))
        assertEquals(existing, ChatCacheCodec.mergeReplacing(existing, emptyList()))
    }
}
