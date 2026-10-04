package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

/**
 * The `GET /api/auth/me` cache: one row per session-cookie fingerprint.
 *
 * The TTL is *not* enforced here. It is a property of "is this entry fresh
 * enough to skip the network", and that decision belongs to
 * `AuthClient.restoreSession`, which is the only thing that knows whether a
 * retry is bypassing the cache on purpose. Baking an expiry into the query
 * would make a stale read indistinguishable from a miss and move a policy
 * decision two layers down.
 */
@Dao
interface AuthMeCacheDao {

    @Query("SELECT * FROM cached_auth_me WHERE cookie_fingerprint = :cookieFingerprint")
    fun find(cookieFingerprint: String): CachedAuthMeEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun put(row: CachedAuthMeEntity)

    /**
     * Drops one entry, for the entry that turned out to be unopenable — a row
     * written under a retired key alias, or one the GCM tag rejects. Leaving it
     * would mean re-attempting the same failing decryption on every launch.
     */
    @Query("DELETE FROM cached_auth_me WHERE cookie_fingerprint = :cookieFingerprint")
    fun delete(cookieFingerprint: String)

    @Query("DELETE FROM cached_auth_me")
    fun deleteAll()
}
