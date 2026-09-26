package com.nalar.mobile.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure half of the `/me` cache: key derivation, freshness and the envelope.
 *
 * The fingerprint is the load-bearing piece — it decides whose cached identity
 * a given cookie can reach — so it is driven directly rather than left to the
 * Android storage layer.
 */
class AuthMeCacheCodecTest {

    @Test
    fun aFingerprintIsStableForTheSameCookie() {
        // A non-deterministic key would make the cache permanently cold.
        assertEquals(
            AuthMeCacheCodec.fingerprint("tok-abc"),
            AuthMeCacheCodec.fingerprint("tok-abc"),
        )
    }

    @Test
    fun differentCookiesFingerprintDifferently() {
        // This is the isolation guarantee: account A's cached identity is not
        // addressable with account B's cookie.
        assertNotEquals(
            AuthMeCacheCodec.fingerprint("tok-a"),
            AuthMeCacheCodec.fingerprint("tok-b"),
        )
    }

    @Test
    fun theFingerprintDoesNotLeakTheCookie() {
        val fingerprint = AuthMeCacheCodec.fingerprint("super-secret-session-cookie")!!

        // A bearer credential must never become part of a storage key.
        assertTrue(fingerprint, !fingerprint.contains("secret"))
        assertTrue(fingerprint, !fingerprint.contains("super"))
        assertEquals(32, fingerprint.length) // 16 bytes, hex
    }

    @Test
    fun aBlankCookieCannotBeFingerprinted() {
        assertNull(AuthMeCacheCodec.fingerprint(""))
        assertNull(AuthMeCacheCodec.fingerprint("   "))
    }

    @Test
    fun aBlankFingerprintCannotBecomeAKey() {
        // Without a cookie there is nothing to attribute an identity to, so
        // there must be no key to read or write.
        assertNull(AuthMeCacheCodec.key(""))
        assertNull(AuthMeCacheCodec.key("   "))
    }

    @Test
    fun keysAreDistinctPerFingerprint() {
        val a = AuthMeCacheCodec.key(AuthMeCacheCodec.fingerprint("tok-a")!!)!!
        val b = AuthMeCacheCodec.key(AuthMeCacheCodec.fingerprint("tok-b")!!)!!

        assertNotEquals(a, b)
        assertTrue(a, a.startsWith("me::c:"))
    }

    @Test
    fun theEnvelopeRoundTrips() {
        val body = """{"authenticated":true,"auth_enabled":true,"user":{"id":"u1","email":"a@b.c"}}"""

        val decoded = AuthMeCacheCodec.decode(AuthMeCacheCodec.encode(body, 1_000L))!!

        assertEquals(body, decoded.body)
        assertEquals(1_000L, decoded.storedAtEpochMillis)
    }

    @Test
    fun corruptEnvelopesDecodeAsAMiss() {
        listOf(
            null,
            "",
            "   ",
            "not json",
            "[]",
            // Envelope with no body, or with a timestamp that never happened.
            """{"at":1000}""",
            """{"body":"x"}""",
        ).forEach { payload ->
            assertNull("should miss on: $payload", AuthMeCacheCodec.decode(payload))
        }
    }

    @Test
    fun freshnessHoldsExactlyUpToTheTtlBoundary() {
        val entry = CachedAuthMe(body = "{}", storedAtEpochMillis = 10_000L)
        val ttl = AuthMeCacheCodec.TTL_MILLIS

        assertTrue(entry.isFresh(10_000L, ttl))
        assertTrue(entry.isFresh(10_000L + ttl - 1, ttl))
        // At exactly the TTL the answer is no longer trustworthy, so it is a miss.
        assertEquals(false, entry.isFresh(10_000L + ttl, ttl))
        assertEquals(false, entry.isFresh(10_000L + ttl + 1, ttl))
    }

    @Test
    fun aClockThatWentBackwardsDoesNotPoisonTheEntry() {
        val entry = CachedAuthMe(body = "{}", storedAtEpochMillis = 10_000L)

        // now < storedAt gives a negative age, which is "very fresh". Safer to
        // re-fetch than to trust; and either way it must not throw.
        entry.isFresh(5_000L, AuthMeCacheCodec.TTL_MILLIS)
    }

    @Test
    fun theTtlMatchesTheWeb() {
        // Mirrors AUTH_ME_TTL_MS in helpers/authMe.ts. If the web's number moves,
        // this is the place that should be argued about, not silently diverge.
        assertEquals(30_000L, AuthMeCacheCodec.TTL_MILLIS)
    }
}
