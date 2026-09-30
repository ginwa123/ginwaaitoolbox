package com.nalar.mobile.server

import android.content.Context

/**
 * Where the chosen server survives process death.
 *
 * An interface because the only thing worth testing about persistence is that
 * the holder *asks* for the right things in the right order — adopt on install,
 * write on change, clear on reset — and that a JVM test cannot do against
 * `SharedPreferences` without Robolectric. With this seam, the whole of
 * `ServerUrl`'s persistence policy is a plain fake.
 */
interface BaseUrlStore {
    /** The saved address, or null when there is none or it is unreadable. */
    fun read(): String?

    /** Persists [baseUrl]. False means the device refused to write it. */
    fun write(baseUrl: String): Boolean

    fun clear()
}

/**
 * The base URL in `SharedPreferences`.
 *
 * **Not** encrypted, and unlike the session cookie that is a decision rather
 * than an oversight: a hostname is not a secret, it is the thing a person
 * types into a settings screen and has to be able to read back, and a
 * self-hoster debugging a deployment needs to see it in an adb dump as much as
 * in the app. What this value *is* sensitive about — which account the app is
 * signed in to — is the cookie's job, and switching servers drops that cookie
 * anyway.
 *
 * Separate preference file from the other two stores, so "forget the server" is
 * one `clear()` here and cannot be a half-applied wipe of a cache.
 */
class PrefsBaseUrlStore(context: Context) : BaseUrlStore {

    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    override fun read(): String? = try {
        preferences.getString(KEY_BASE_URL, null)?.takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        // A corrupt preferences file is a miss, never a crash on a launch path.
        // The app opens on the build default, which is where it would have
        // opened anyway.
        runCatching { preferences.edit().clear().commit() }
        null
    }

    /**
     * `commit()` rather than `apply()`, despite being on the main thread.
     *
     * The return value is the point: [ServerUrl.update] reports *applied* or
     * *rejected* to the person who just pressed Save, and with `apply()` the
     * write has not been attempted yet, so a failure could not be reported and
     * the app would be showing a server it has not saved. One synchronous write
     * on an explicit, deliberate, rare user action is the right trade for an
     * answer that is honest.
     */
    override fun write(baseUrl: String): Boolean = try {
        preferences.edit().putString(KEY_BASE_URL, baseUrl).commit()
    } catch (_: Exception) {
        false
    }

    override fun clear() {
        runCatching { preferences.edit().remove(KEY_BASE_URL).commit() }
    }

    private companion object {
        const val PREFERENCES_NAME = "nalar_server"
        const val KEY_BASE_URL = "base_url"
    }
}
