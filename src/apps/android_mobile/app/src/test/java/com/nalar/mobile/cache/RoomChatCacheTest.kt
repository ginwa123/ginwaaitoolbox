package com.nalar.mobile.cache

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.nalar.mobile.chat.CachedChatMessage
import com.nalar.mobile.chat.ChatCacheCodec
import com.nalar.mobile.chat.RoomChatCache
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The transcript cache against a **real** SQLite database.
 *
 * Every assertion here is about something the move to Room made structural, and
 * which therefore has to be tested against the SQL rather than against a
 * re-implementation of it: a composite primary key that *cannot* be escaped,
 * `ORDER BY … LIMIT` that does not parse every row to answer "give me the
 * newest five", and `INSERT … ON CONFLICT REPLACE` as the write-through merge.
 *
 * A JVM test against an in-memory `ChatCache` would prove none of that, which
 * is why this runs on Robolectric — it opens the same `android.database.sqlite`
 * the device does.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RoomChatCacheTest {

    private lateinit var database: NalarCacheDatabase
    private lateinit var cache: RoomChatCache

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            NalarCacheDatabase::class.java,
        ).allowMainThreadQueries().build()
        cache = RoomChatCache(database.chatCacheDao())
    }

    @After
    fun tearDown() {
        database.close()
    }

    private fun message(
        id: String,
        nanos: Long,
        raw: JSONObject? = null,
    ): CachedChatMessage {
        val row = raw ?: JSONObject()
            .put("id", id)
            .put("role", "user")
            .put("content", "hi $id")
            .put("created_at", nanos.toString())
        return CachedChatMessage(
            id = id,
            sortKeyNanos = nanos,
            sessionId = SESSION,
            role = row.optString("role"),
            content = row.optString("content"),
            raw = row.toString(),
        )
    }

    private fun ids(messages: List<CachedChatMessage>?) = messages?.map { it.id }

    // --- Per-user and per-session isolation ---------------------------------

    @Test
    fun anUnresolvedIdentityIsAMissRatherThanAnUnscopedRead() {
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100)))

        // Stricter than the web's `userScopedKey`, which falls back to an
        // UNSCOPED key when identity is unresolved. On a phone that fallback is
        // exactly the case where one account's chat shows up for the next, so
        // the fallback has to be inexpressible rather than merely discouraged.
        assertNull(cache.readMessages(null, SESSION, 10))
        assertNull(cache.readMessages("   ", SESSION, 10))
        assertNull(cache.readMessages(USER, "   ", 10))
        assertNull(cache.readCursor(null, SESSION))
    }

    @Test
    fun aBlankIdentityCannotWriteEither() {
        cache.writeMessages(null, SESSION, listOf(message("m1", 100)))
        cache.writeMessages("   ", SESSION, listOf(message("m2", 200)))
        cache.writeMessages(USER, "", listOf(message("m3", 300)))

        assertNull(cache.readMessages(USER, SESSION, 10))
    }

    @Test
    fun twoAccountsOnOneDeviceNeverSeeEachOthersTranscript() {
        cache.writeMessages("user_a", SESSION, listOf(message("a1", 100)))
        cache.writeMessages("user_b", SESSION, listOf(message("b1", 100)))

        assertEquals(listOf("a1"), ids(cache.readMessages("user_a", SESSION, 10)))
        assertEquals(listOf("b1"), ids(cache.readMessages("user_b", SESSION, 10)))
    }

    @Test
    fun twoSessionsInOneAccountNeverSeeEachOther() {
        cache.writeMessages(USER, "sess_1", listOf(message("one", 100)))
        cache.writeMessages(USER, "sess_2", listOf(message("two", 100)))

        assertEquals(listOf("one"), ids(cache.readMessages(USER, "sess_1", 10)))
        assertEquals(listOf("two"), ids(cache.readMessages(USER, "sess_2", 10)))
    }

    // --- Ordering and limiting ----------------------------------------------

    @Test
    fun readsComeBackNewestFirstAndCapped() {
        cache.writeMessages(
            USER,
            SESSION,
            (1L..5L).map { message("m$it", it * 100) },
        )

        // Newest first, and the cap takes the newest — the two halves of the
        // IndexedDB `getAll` contract the paint-from-cache path depends on.
        assertEquals(listOf("m5", "m4", "m3"), ids(cache.readMessages(USER, SESSION, 3)))
        assertEquals(listOf("m5", "m4", "m3", "m2", "m1"), ids(cache.readMessages(USER, SESSION, 50)))
    }

    @Test
    fun rowsSharingATimestampBreakTiesByIdSoThePaintIsDeterministic() {
        // The backend stamps by whole seconds often enough that ties are the
        // normal case, not the exotic one. Without a total order two launches
        // of the same transcript would paint the same turns in a different
        // order, which reads as the list shuffling itself.
        cache.writeMessages(USER, SESSION, listOf(message("b", 100), message("a", 100)))

        assertEquals(listOf("b", "a"), ids(cache.readMessages(USER, SESSION, 10)))
    }

    @Test
    fun aLimitOfZeroStillReturnsSomethingUsable() {
        // The old cache did `.take(limit.coerceAtLeast(1))`. A negative limit
        // reaching SQLite would make `LIMIT -1` mean "no limit", which is the
        // exact opposite of what a caller passing 0 was asking for.
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100), message("m2", 200)))

        assertEquals(listOf("m2"), ids(cache.readMessages(USER, SESSION, 0)))
    }

    // --- Write-through merge ------------------------------------------------

    @Test
    fun aSameIdWriteReplacesTheRowInsteadOfDuplicatingIt() {
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100), message("m2", 200)))

        val revised = message(
            "m1",
            100,
            raw = JSONObject().put("id", "m1").put("content", "revised").put("created_at", "100"),
        )
        cache.writeMessages(USER, SESSION, listOf(revised))

        val stored = cache.readMessages(USER, SESSION, 10)!!
        assertEquals(2, stored.size)
        assertEquals("revised", JSONObject(stored.single { it.id == "m1" }.raw).getString("content"))
    }

    @Test
    fun writingNothingLeavesTheCacheAlone() {
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100)))

        // "The page came back empty" is a normal tail-fetch answer. Treating it
        // as "this session has no messages" would blank the transcript the
        // moment the reader reached the top of it.
        cache.writeMessages(USER, SESSION, emptyList())

        assertEquals(listOf("m1"), ids(cache.readMessages(USER, SESSION, 10)))
    }

    @Test
    fun aRowKeepsTheWholeServerObjectNotAProjection() {
        // A field this client has never heard of must survive the round trip,
        // or the cached paint and the live paint disagree about a transcript.
        val wire = JSONObject()
            .put("id", "m1")
            .put("content", "hi")
            .put("created_at", "100")
            .put("tool_calls_json", """{"name":"command"}""")
            .put("is_output", true)
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100, raw = wire)))

        val roundTripped = JSONObject(cache.readMessages(USER, SESSION, 10)!!.single().raw)
        assertEquals("""{"name":"command"}""", roundTripped.getString("tool_calls_json"))
        assertTrue(roundTripped.getBoolean("is_output"))
    }

    @Test
    fun aRowBuiltByTheCodecRoundTripsThroughTheDatabase() {
        // The end-to-end shape: wire object → codec → storage → read → codec.
        val row = JSONObject().put("id", "m1").put("created_at", "1789451234567890123")
        val built = ChatCacheCodec.toCachedMessage(SESSION, row)!!

        cache.writeMessages(USER, SESSION, listOf(built))
        val read = cache.readMessages(USER, SESSION, 10)!!.single()

        assertEquals(built, read)
    }

    @Test
    fun aRowIsStoredInThePartitionItWasWrittenIntoNotTheOneItClaims() {
        // `CachedChatMessage` carries its own `sessionId`, and the two agree in
        // every current call site. If they ever disagreed the row would be
        // written where the caller never looks, and would silently consume the
        // retention budget of a session nobody is reading.
        val mislabelled = message("m1", 100).copy(sessionId = "some_other_session")

        cache.writeMessages(USER, SESSION, listOf(mislabelled))

        assertEquals(listOf("m1"), ids(cache.readMessages(USER, SESSION, 10)))
        assertNull(cache.readMessages(USER, "some_other_session", 10))
    }

    // --- Retention ----------------------------------------------------------

    @Test
    fun aSessionStopsGrowingPastTheRetentionCeiling() {
        val small = RoomChatCache(database.chatCacheDao(), retainedRowsPerSession = 3)
        small.writeMessages(
            USER,
            SESSION,
            (1L..5L).map { message("m$it", it * 100) },
        )

        // A row store is append-only by nature, and the file cache it replaced
        // was rewritten whole on every write. Without a ceiling, opening a long
        // session and scrolling through it would leave a row per turn on the
        // device forever. The newest are the ones kept, because those are the
        // ones a cold boot paints.
        assertEquals(listOf("m5", "m4", "m3"), ids(small.readMessages(USER, SESSION, 50)))
    }

    @Test
    fun retentionIsPerSessionSoASmallOneIsNotStarvedByABigOne() {
        val small = RoomChatCache(database.chatCacheDao(), retainedRowsPerSession = 1)
        small.writeMessages(USER, "sess_1", (1L..4L).map { message("a$it", it * 100) })
        small.writeMessages(USER, "sess_2", listOf(message("b1", 100)))

        assertEquals(listOf("a4"), ids(small.readMessages(USER, "sess_1", 10)))
        assertEquals(listOf("b1"), ids(small.readMessages(USER, "sess_2", 10)))
    }

    // --- The cursor ---------------------------------------------------------

    @Test
    fun theCursorIsStoredPerUserAndPerSession() {
        cache.writeCursor(USER, SESSION, "500")
        cache.writeCursor(USER, "sess_2", "600")
        cache.writeCursor("user_b", SESSION, "700")

        assertEquals("500", cache.readCursor(USER, SESSION))
        assertEquals("600", cache.readCursor(USER, "sess_2"))
        assertEquals("700", cache.readCursor("user_b", SESSION))
    }

    @Test
    fun aBlankCursorClearsTheStoredOne() {
        cache.writeCursor(USER, SESSION, "500")

        // "There is no cursor any more" is a real state — it is what makes the
        // next open a full descending load instead of a tail fetch — so it has
        // to be expressible as a delete and not just as an absent write.
        cache.writeCursor(USER, SESSION, null)
        assertNull(cache.readCursor(USER, SESSION))

        cache.writeCursor(USER, SESSION, "900")
        cache.writeCursor(USER, SESSION, "   ")
        assertNull(cache.readCursor(USER, SESSION))
    }

    @Test
    fun aStoredCursorIsReplacedRatherThanDuplicated() {
        repeat(3) { cache.writeCursor(USER, SESSION, "$it") }

        assertEquals("2", cache.readCursor(USER, SESSION))
    }

    // --- Sign-out -----------------------------------------------------------

    @Test
    fun clearPurgesEveryUserAndEverySession() {
        cache.writeMessages(USER, SESSION, listOf(message("a1", 100)))
        cache.writeMessages("user_b", "sess_2", listOf(message("b1", 100)))
        cache.writeCursor(USER, SESSION, "500")
        cache.writeCursor("user_b", "sess_2", "500")

        cache.clear()

        // Sign-out only clears the cookie, so anything left behind here would be
        // painted for whoever signs in next on a shared device.
        assertNull(cache.readMessages(USER, SESSION, 10))
        assertNull(cache.readMessages("user_b", "sess_2", 10))
        assertNull(cache.readCursor(USER, SESSION))
        assertNull(cache.readCursor("user_b", "sess_2"))
    }

    @Test
    fun aFirstReadOnAnEmptyDatabaseIsAMissNotAFailure() {
        assertNull(cache.readMessages(USER, SESSION, 10))
        assertNull(cache.readCursor(USER, SESSION))
    }

    private companion object {
        const val USER = "user_a"
        const val SESSION = "sess_1"
    }
}
