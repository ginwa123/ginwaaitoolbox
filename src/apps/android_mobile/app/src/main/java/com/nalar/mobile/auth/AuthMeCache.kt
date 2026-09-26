package com.nalar.mobile.auth

import android.content.Context
import com.nalar.mobile.storage.EncryptedPrefs
import java.security.MessageDigest
import org.json.JSONObject

/**
 * A 30s-TTL cache for `GET /api/auth/me`, mirroring `helpers/authMe.ts`.
 *
 * The app calls `/me` on every launch to decide between the app shell and the
 * login screen. The handler is cheap, but every SQLite read serialises on one
 * global mutex, so on a busy boot it can queue behind seconds of work and the
 * app sits on a spinner the whole time. A short TTL removes that from the
 * common case: relaunching within 30s (app switch, rotation, back from
 * recents) never touches the network.
 *
 * **Three deliberate divergences from the web.**
 *
 * 1. **A stale entry is a MISS, not a serve-and-revalidate.** The web's guard
 *    fails OPEN — it renders the view and lets subsequent data fetches 401.
 *    Failing open is only tolerable because the web is already authenticated by
 *    another mechanism. On mobile, failing open paints the app shell to someone
 *    who is not signed in, then bounces them when the sidebar 401s, so the user
 *    sees two screens instead of one. A stale answer is not worth that.
 * 2. **Only 2xx is cached.** The web also caches `!ok`, to collapse a retry
 *    storm. Android's primary recovery path is a "Try again" button, and
 *    serving it a cached 401 would make that button do nothing at all.
 * 3. **Namespaced by a fingerprint of the session cookie.** The web's entry is
 *    unscoped, which is safe only because a browser profile is effectively one
 *    user. A phone is far more likely to be shared, and the sidebar cache in
 *    this app is already per-user — two caches in one app disagreeing about
 *    isolation is worse than either choice alone. It also means signing out
 *    makes the old entry unreachable, since there is no cookie to derive the
 *    key from.
 */
interface AuthMeCache {
    /** A stored response, or null on miss / corrupt entry. */
    fun read(cookieFingerprint: String): CachedAuthMe?

    fun write(cookieFingerprint: String, responseBody: String, nowEpochMillis: Long)

    fun clear()
}

data class CachedAuthMe(
    val body: String,
    val storedAtEpochMillis: Long,
) {
    fun isFresh(nowEpochMillis: Long, ttlMillis: Long): Boolean =
        nowEpochMillis - storedAtEpochMillis < ttlMillis
}

/**
 * The pure half: key derivation, freshness and the envelope format. No Android
 * dependency, so the parts that can silently serve the wrong identity are the
 * parts the unit tests drive.
 */
object AuthMeCacheCodec {
    /**
     * Matches `AUTH_ME_TTL_MS` in `authMe.ts`. Short on purpose: the bound on
     * "the cookie died in the last 30 seconds and we have not noticed yet" has
     * to be small, because the sidebar's 401 is what actually catches it.
     */
    const val TTL_MILLIS = 30_000L

    private const val KEY_PREFIX = "me::c:"

    /**
     * A truncated SHA-256 of the session cookie. The cookie itself is a bearer
     * credential and must never become part of a storage key; a hash gives a
     * stable, non-reversible namespace so one account's cached identity is not
     * addressable with another account's cookie.
     */
    fun fingerprint(sessionCookie: String): String? {
        if (sessionCookie.isBlank()) return null
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(sessionCookie.toByteArray(Charsets.UTF_8))
        return digest.take(FINGERPRINT_BYTES)
            .joinToString("") { byte -> "%02x".format(byte) }
    }

    fun key(cookieFingerprint: String): String? =
        cookieFingerprint
            .takeIf { it.isNotBlank() }
            ?.let { "$KEY_PREFIX$it" }

    fun encode(body: String, storedAtEpochMillis: Long): String = JSONObject()
        .put("body", body)
        .put("at", storedAtEpochMillis)
        .toString()

    /** Null on any unrecognizable payload, so a corrupt entry reads as a miss. */
    fun decode(payload: String?): CachedAuthMe? {
        if (payload.isNullOrBlank()) return null
        return try {
            val json = JSONObject(payload)
            val body = json.optString("body")
            val at = json.optLong("at", Long.MIN_VALUE)
            // A body we could not store, or a timestamp that never happened,
            // means the envelope is not ours.
            if (body.isEmpty() || at == Long.MIN_VALUE) null else CachedAuthMe(body, at)
        } catch (_: Exception) {
            null
        }
    }

    private const val FINGERPRINT_BYTES = 16
}

class KeystoreAuthMeCache(context: Context) : AuthMeCache {
    private val prefs = EncryptedPrefs(
        context = context,
        preferencesName = PREFERENCES_NAME,
        keyAlias = KEY_ALIAS,
    )

    override fun read(cookieFingerprint: String): CachedAuthMe? {
        val key = AuthMeCacheCodec.key(cookieFingerprint) ?: return null
        return AuthMeCacheCodec.decode(prefs.get(key))
    }

    override fun write(cookieFingerprint: String, responseBody: String, nowEpochMillis: Long) {
        val key = AuthMeCacheCodec.key(cookieFingerprint) ?: return
        prefs.put(key, AuthMeCacheCodec.encode(responseBody, nowEpochMillis))
    }

    override fun clear() = prefs.clear()

    private companion object {
        const val PREFERENCES_NAME = "nalar_auth_me"
        // Distinct from the session-cookie and sidebar-cache aliases: this holds
        // an identity, which is a third kind of thing to rotate independently.
        const val KEY_ALIAS = "nalar_auth_me_key_v1"
    }
}
