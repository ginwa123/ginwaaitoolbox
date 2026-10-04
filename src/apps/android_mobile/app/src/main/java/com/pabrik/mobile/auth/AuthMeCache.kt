package com.pabrik.mobile.auth

import android.content.Context
import com.pabrik.mobile.cache.AuthMeCacheDao
import com.pabrik.mobile.cache.CachedAuthMeEntity
import com.pabrik.mobile.cache.PabrikCacheDatabase
import com.pabrik.mobile.storage.KeystoreSealingCipher
import com.pabrik.mobile.storage.SealingCipher
import java.security.MessageDigest

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
 * The pure half: the key derivation and the freshness rule. No Android
 * dependency, so the two things that can silently serve the wrong identity —
 * deriving one account's namespace from another's cookie, and calling a stale
 * answer fresh — are the two the unit tests drive.
 *
 * The envelope format is gone: a row has a column per field, so there is no
 * JSON shape left to get wrong and no decode step to fail.
 */
object AuthMeCacheCodec {
    /**
     * Matches `AUTH_ME_TTL_MS` in `authMe.ts`. Short on purpose: the bound on
     * "the cookie died in the last 30 seconds and we have not noticed yet" has
     * to be small, because the sidebar's 401 is what actually catches it.
     */
    const val TTL_MILLIS = 30_000L

    private const val FINGERPRINT_BYTES = 16

    /**
     * A truncated SHA-256 of the session cookie. The cookie itself is a bearer
     * credential and must never become part of a storage key; a hash gives a
     * stable, non-reversible namespace so one account's cached identity is not
     * addressable with another account's cookie.
     *
     * This is the primary key of `cached_auth_me` now rather than a key prefix,
     * which is the whole difference the move made: there is no longer a string
     * in which a user id could be confused with a separator.
     */
    fun fingerprint(sessionCookie: String): String? {
        if (sessionCookie.isBlank()) return null
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(sessionCookie.toByteArray(Charsets.UTF_8))
        return digest.take(FINGERPRINT_BYTES)
            .joinToString("") { byte -> "%02x".format(byte) }
    }
}

/**
 * [AuthMeCache] on Room: one row per cookie fingerprint, body sealed with a
 * Keystore key.
 *
 * The body is sealed whole, unlike the sidebar's per-column sealing, because
 * nothing in this table is filtered or sorted on — it is looked up by one
 * primary key and returned. There is no reason to leave any part of it in the
 * clear.
 */
class RoomAuthMeCache(
    private val dao: AuthMeCacheDao,
    private val cipher: SealingCipher,
) : AuthMeCache {

    constructor(context: Context) : this(
        dao = PabrikCacheDatabase.get(context).authMeCacheDao(),
        cipher = KeystoreSealingCipher(KEY_ALIAS),
    )

    override fun read(cookieFingerprint: String): CachedAuthMe? {
        val fingerprint = cookieFingerprint.orNull() ?: return null
        return quietly(null) {
            val row = dao.find(fingerprint) ?: return@quietly null
            val body = cipher.open(row.bodySealed)
            if (body == null) {
                // Written under a retired key alias, or a GCM tag that no
                // longer verifies. Drop it rather than re-attempting the same
                // failing decryption on every launch.
                dao.delete(fingerprint)
                return@quietly null
            }
            CachedAuthMe(body = body, storedAtEpochMillis = row.storedAtEpochMillis)
        }
    }

    override fun write(cookieFingerprint: String, responseBody: String, nowEpochMillis: Long) {
        val fingerprint = cookieFingerprint.orNull() ?: return
        val sealed = quietly(null) { cipher.seal(responseBody) } ?: return
        quietly(Unit) {
            dao.put(
                CachedAuthMeEntity(
                    cookieFingerprint = fingerprint,
                    bodySealed = sealed,
                    storedAtEpochMillis = nowEpochMillis,
                ),
            )
        }
    }

    override fun clear() = quietly(Unit) { dao.deleteAll() }

    private inline fun <T> quietly(fallback: T, block: () -> T): T = try {
        block()
    } catch (_: Exception) {
        fallback
    }

    private companion object {
        // Distinct from the session-cookie and sidebar-cache aliases: this holds
        // an identity, which is a third kind of thing to rotate independently.
        const val KEY_ALIAS = "nalar_auth_me_key_v1"
    }
}

private fun String?.orNull(): String? = this?.takeIf { it.isNotBlank() }
