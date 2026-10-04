package com.pabrik.mobile.auth

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionCookieStoreTest {
    private lateinit var context: Context
    private lateinit var store: SessionCookieStore

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        store = SessionCookieStore(context)
        store.clear()
    }

    @After
    fun tearDown() {
        store.clear()
    }

    @Test
    fun encryptedCookieRoundTripsAndClears() {
        assertNull(store.read())

        store.save("session-token-for-test")

        assertEquals("session-token-for-test", store.read())

        store.clear()

        assertNull(store.read())
    }

    @Test
    fun cookieIsNotStoredAsPlaintextAndTamperingFailsClosed() {
        store.save("session-token-for-test")

        val preferencesFile = File(
            context.applicationInfo.dataDir,
            "shared_prefs/nalar_auth.xml",
        )
        assertFalse(preferencesFile.readText().contains("session-token-for-test"))

        context.getSharedPreferences("nalar_auth", Context.MODE_PRIVATE)
            .edit()
            .putString("session_cookie", "tampered-payload")
            .commit()

        assertNull(store.read())
    }
}
