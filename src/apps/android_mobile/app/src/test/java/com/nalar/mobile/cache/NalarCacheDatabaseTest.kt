package com.nalar.mobile.cache

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.nalar.mobile.recents.RoomRecentsCache
import com.nalar.mobile.recents.WorkspaceOption
import com.nalar.mobile.testing.Base64CacheCipher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The database *builder*, as opposed to the caches on top of it.
 *
 * The other three test classes build an in-memory database directly, which is
 * the right way to test the DAOs and the wrong way to test this: everything
 * they share is the schema, and everything specific to production — the file,
 * the singleton, the three DAOs being wired to the same connection — lives in
 * exactly the code path they skip. Two caches opening two connections to two
 * files would pass every DAO test and lose half its writes on device.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NalarCacheDatabaseTest {

    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun allThreeCachesShareOneConnection() {
        val database = NalarCacheDatabase.get(context)

        assertNotNull(database.chatCacheDao())
        assertNotNull(database.recentsCacheDao())
        assertNotNull(database.authMeCacheDao())
        // The point of a single database: the two ViewModels that write caches
        // and the auth flow that writes the third are not racing two file
        // handles at the same WAL.
        assertSame(database, NalarCacheDatabase.get(context))
    }

    /**
     * The singleton is process-wide, so one test's rows would otherwise be
     * visible to the next. The caches never let that matter — a write replaces
     * its partition — but a leftover row in a test that counts rows would be a
     * flake, so the file is emptied between methods.
     */
    @After
    fun tearDown() {
        NalarCacheDatabase.get(context).openHelper.writableDatabase.apply {
            execSQL("DELETE FROM cached_workspaces")
            execSQL("DELETE FROM cached_chat_summaries")
            execSQL("DELETE FROM cached_messages")
            execSQL("DELETE FROM chat_cursors")
            execSQL("DELETE FROM chat_older_pages")
            execSQL("DELETE FROM cached_auth_me")
        }
    }

    @Test
    fun theFileDatabaseReallyIsAFileAndNotAnInMemoryStandIn() {
        // The production builder is what the caches in the other three test
        // classes deliberately do not exercise, so at least one of them has to
        // open the real thing — otherwise an `inMemoryDatabaseBuilder` typo in
        // `NalarCacheDatabase` would be invisible to the whole suite.
        val tables = mutableListOf<String>()
        NalarCacheDatabase.get(context)
            .openHelper.readableDatabase
            .query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'cached_%'")
            .use { cursor ->
                while (cursor.moveToNext()) tables += cursor.getString(0)
            }

        assertEquals(
            // `chat_cursors` is absent by design: it does not match the
            // `cached_%` filter, and this test is about the *cached* tables
            // specifically. The two project tables are here because the real
            // builder is the only thing that proves they exist at all — a
            // missing `projectsCacheDao` would otherwise only surface as a
            // runtime failure on first launch.
            listOf(
                "cached_auth_me",
                "cached_chat_summaries",
                "cached_messages",
                "cached_project_chats",
                "cached_projects",
                "cached_workspaces",
            ),
            tables.sorted(),
        )
    }

    @Test
    fun aWriteThroughOneCacheIsReadableThroughTheSharedFile() {
        // A round trip that only makes sense when it is one file: the sidebar
        // and the transcript are written by different ViewModels, and a
        // sign-out has to be able to purge both.
        val database = NalarCacheDatabase.get(context)
        RoomRecentsCache(database.recentsCacheDao(), Base64CacheCipher)
            .writeWorkspaces("user_a", listOf(WorkspaceOption("ws_1", "One")))

        val rows = database.openHelper.readableDatabase
            .query("SELECT workspace_id FROM cached_workspaces")
            .use { cursor ->
                buildList { while (cursor.moveToNext()) add(cursor.getString(0)) }
            }

        assertEquals(listOf("ws_1"), rows)
    }
}
