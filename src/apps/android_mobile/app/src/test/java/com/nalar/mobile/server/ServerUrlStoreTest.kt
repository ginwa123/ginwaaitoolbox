package com.nalar.mobile.server

import androidx.test.core.app.ApplicationProvider
import com.nalar.mobile.BuildConfig
import com.nalar.mobile.auth.AuthConfig
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The holder's persistence policy, against a real `SharedPreferences` file.
 *
 * Two things are worth proving and neither is `normalizeBaseUrl`, which
 * [ServerUrlTest] already has:
 *
 *  1. **A refusal changes nothing.** A rejected value must not reach the store
 *     *or* the in-memory value, or a person who typed a typo and pressed Save
 *     would find the app silently pointed at the typo for the rest of the
 *     process — the one outcome worse than the rejection.
 *  2. **A stored value that no longer normalizes is dropped, not obeyed.** The
 *     build it was written under may have been more permissive than this one,
 *     and a release APK must not inherit a debug-only `http://10.0.2.2:8080`.
 */
@RunWith(RobolectricTestRunner::class)
class ServerUrlStoreTest {

    private lateinit var store: PrefsBaseUrlStore

    @Before
    fun setUp() {
        // The holder is a process singleton, so every test starts from the
        // build default and an unbound store — the same escape hatch
        // `SseBusHolder.reset()` exists for.
        ServerUrl.reset()
        store = PrefsBaseUrlStore(ApplicationProvider.getApplicationContext())
        store.clear()
        // `MainActivity.onCreate` does this before anything can reach the UI, and
        // `update` has nowhere to write without it — the same ordering the app
        // depends on, asserted here rather than assumed.
        ServerUrl.install(store)
    }

    @After
    fun tearDown() {
        store.clear()
        ServerUrl.reset()
    }

    @Test
    fun `an uninstalled holder answers with the build default`() {
        // What every transport sees before `MainActivity.onCreate` has
        // installed anything. It has to be the build's own host, because it is
        // also the value the functional UI suite drives with `-PnalarBaseUrl`.
        assertEquals(BuildConfig.API_BASE_URL, ServerUrl.value)
        assertEquals(BuildConfig.API_BASE_URL, AuthConfig.BASE_URL)
    }

    @Test
    fun `an update is adopted and persisted, and survives a reinstall`() {
        assertTrue(ServerUrl.update("self.hosted.example") is ServerChange.Applied)
        assertEquals("https://self.hosted.example", ServerUrl.value)
        assertEquals("https://self.hosted.example", store.read())

        // The reinstall is the point: a new holder, the same file.
        ServerUrl.reset()
        assertEquals(BuildConfig.API_BASE_URL, ServerUrl.value)

        ServerUrl.install(store)
        assertEquals("https://self.hosted.example", ServerUrl.value)
        assertEquals("https://self.hosted.example", AuthConfig.BASE_URL)
    }

    @Test
    fun `a refusal changes neither the holder nor the file`() {
        ServerUrl.update("https://first.example")
        assertEquals("https://first.example", ServerUrl.value)

        val refusal = ServerUrl.update("ftp://not-a-server")
        assertTrue("expected a refusal, got $refusal", refusal is ServerChange.Rejected)
        assertEquals("https://first.example", ServerUrl.value)
        assertEquals("https://first.example", store.read())
    }

    @Test
    fun `an install with nothing saved falls back to the build default`() {
        assertNull(store.read())

        ServerUrl.install(store)

        assertEquals(BuildConfig.API_BASE_URL, ServerUrl.value)
    }

    @Test
    fun `a stored value this build cannot use is dropped rather than obeyed`() {
        // Two different real situations, one per variant, and the stored value
        // has to be unusable in whichever variant is running or the test proves
        // nothing. Debug: a hostname that is not one of the three loopback
        // addresses, which the platform refuses cleartext to. Release: any
        // cleartext URL at all, which is the "a release APK restoring a device
        // last used by a debug build pointed at a local nalar" case.
        val unusable = if (BuildConfig.ALLOW_INSECURE_HTTP) {
            "http://stale-host.example:8080"
        } else {
            "http://10.0.2.2:8080"
        }
        assertTrue(
            "`$unusable` must be unusable in this variant for this test to mean anything",
            normalizeBaseUrl(unusable) is ServerChange.Rejected,
        )
        store.write(unusable)

        ServerUrl.install(store)

        assertEquals(
            "an unusable stored value must not be adopted",
            BuildConfig.API_BASE_URL,
            ServerUrl.value,
        )
        assertNull("and it must not be left in the file to fail again", store.read())
    }

    @Test
    fun `reset goes back to the build default and forgets the saved one`() {
        ServerUrl.update("https://second.example")

        assertTrue(ServerUrl.resetToBuildDefault() is ServerChange.Applied)

        assertEquals(BuildConfig.API_BASE_URL, ServerUrl.value)
        assertNull(store.read())
    }

    @Test
    fun `the flow emits so a screen showing the host can redraw`() = runBlocking {
        // `MainActivity` collects this; without an emission the server row
        // would keep showing the previous host after a change, which is the one
        // piece of information the person who just typed it is checking.
        val seen = mutableListOf<String>()
        val collector = launch(start = CoroutineStart.UNDISPATCHED) {
            ServerUrl.current.collect { seen += it }
        }

        ServerUrl.update("https://third.example")
        // `StateFlow.value =` *resumes* the collector; it does not run it on the
        // setter's thread. Without a yield the cancel below wins the race and
        // the assertion would pass against a list that never had the chance to
        // grow — which is the test that proves nothing while looking green.
        yield()
        ServerUrl.resetToBuildDefault()
        yield()
        collector.cancel()

        assertEquals(
            "the collector must see each adopted value",
            listOf(BuildConfig.API_BASE_URL, "https://third.example", BuildConfig.API_BASE_URL),
            seen,
        )
    }
}
