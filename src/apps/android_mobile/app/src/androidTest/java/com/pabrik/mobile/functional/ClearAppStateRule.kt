package com.pabrik.mobile.functional

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.pabrik.mobile.auth.RoomAuthMeCache
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.chat.RoomChatCache
import com.pabrik.mobile.projects.RoomProjectsCache
import com.pabrik.mobile.recents.RoomRecentsCache
import com.pabrik.mobile.storage.PrefsLastPositionStore
import org.junit.rules.ExternalResource

/**
 * Puts the app back to "installed and never used" around each test.
 *
 * The whole instrumentation run shares one app process and one data directory,
 * so without this every test starts wearing whatever the previous one left on
 * it — and the app writes a surprising amount before the reader sees anything:
 * a session cookie, the position it last resumed to, and four Room caches that
 * paint before the network answers.
 *
 * ### Why a rule and not `@Before`
 *
 * `@Before` is too late. `ActivityScenarioRule` — and therefore
 * `createAndroidComposeRule` — launches the Activity while the rule's own
 * `before()` runs, and rules wrap the whole test including its `@Before`
 * methods. The app reads all of this state during that launch, so a reset that
 * happens in `@Before` resets the state of a process that has already decided
 * what to show. Chained *outer* of the Compose rule, this runs first.
 *
 * ### The one that actually breaks runs
 *
 * The saved position. `PabrikNavGraph` reads it on launch and navigates to the
 * chat it names, so a test that opens a deep link and inherits a position from
 * an earlier test lands somewhere else entirely — and the failure reads as "the
 * deep link is broken", which is the wrong place to go looking.
 *
 * ### The caches are cleared through their own API, not by deleting the file
 *
 * `PabrikCacheDatabase.get()` is a process-wide singleton holding an open
 * connection, and it survives from one test to the next. Deleting
 * `pabrik_cache.db` would therefore leave that connection pointing at an
 * unlinked inode: the wipe would look like it worked and change nothing, and
 * the next test would read the previous test's rows out of a file that no
 * longer exists. `clear()` on each cache issues a real `DELETE`, so the rows
 * are actually gone.
 */
class ClearAppStateRule(
    private val context: Context =
        InstrumentationRegistry.getInstrumentation().targetContext,
) : ExternalResource() {

    override fun before() = clearNow()

    override fun after() = clearNow()

    /**
     * Clears every kind of state that outlives a test in this process.
     *
     * Public so a test can drive the clear directly and assert what it removed;
     * the contract above is about *when* this happens, not about hiding it.
     */
    fun clearNow() {
        // Nothing is signed in here — the harness runs pabrik with auth off — but
        // a cookie left by an earlier test would be sent to the harness on every
        // request, and the app treats a 401 from any call as "sign out", which
        // would empty the screen mid-assertion.
        SessionCookieStore(context).clear()

        // The resumer. See the class comment: this is the one whose absence
        // turns a deep link into a mystery.
        PrefsLastPositionStore(context).clear()

        // The four caches that can paint before the network answers. Each is
        // cleared by name rather than in a loop, because they share no interface
        // and a wrong one would otherwise be a silent no-op.
        RoomChatCache(context).clear()
        RoomRecentsCache(context).clear()
        RoomAuthMeCache(context).clear()
        RoomProjectsCache(context).clear()
    }
}
