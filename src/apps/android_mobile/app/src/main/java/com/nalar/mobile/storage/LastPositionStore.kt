package com.nalar.mobile.storage

import android.content.Context

/**
 * Where the user was: the workspace they had selected and the chat they had
 * open.
 *
 * Two ids and nothing else — no title, no message, no timestamp. A position is
 * a *pointer* to something the caches already hold, which is also why it is not
 * sealed the way chat titles are: [com.nalar.mobile.recents.RoomRecentsCache]
 * leaves its id columns in the clear for the same reason, and sealing a
 * 22-character session id would buy nothing but a key to rotate.
 */
data class LastPosition(
    val workspaceId: String? = null,
    val sessionId: String? = null,
) {
    /** Nothing worth resuming — a first launch, or a sign-out wiped the store. */
    val isEmpty: Boolean
        get() = workspaceId.isNullOrBlank() && sessionId.isNullOrBlank()
}

/**
 * The user's last position, across process death.
 *
 * ### Why this is not the nav back stack
 *
 * `rememberNavController` does restore a saved back stack, but only when the
 * process is recreated *with* its saved instance state. The case this exists for
 * is the other one: the app is closed and opened again, the controller starts
 * empty at the shell, and the user's chat is gone from the screen even though
 * the server still has it. No amount of nav plumbing recovers that — the
 * position has to outlive the process, which is what these two keys do.
 *
 * ### Rules
 *
 * 1. **One account at a time.** Every key is namespaced, and sign-out calls
 *    [clear], so the next person to sign in on a shared device does not land in
 *    the previous person's chat. This is the rule the Room caches follow too.
 * 2. **A workspace switch drops the session.** [saveWorkspace] is what the
 *    sidebar calls when the user picks a different workspace; the chat they were
 *    reading belonged to the one they just left, so keeping it would resume into
 *    a chat that is not in the resumed workspace. Restoring a saved position
 *    therefore must *not* go through [saveWorkspace] — it is the same user
 *    action seen from the other end, and it needs the session this method drops.
 * 3. **Fail silent.** A missing or unreadable value is a miss, never an
 *    exception on a launch path. The worst outcome is the app opening on the
 *    shell, which is exactly where it would have opened anyway.
 */
interface LastPositionStore {
    /** The saved position for an account, or an empty one when there is none. */
    fun read(userId: String?): LastPosition

    /**
     * Writes a position, leaving any field left null as it is — null means
     * "not part of this update", never "forget it". [saveWorkspace] is the only
     * way to drop the session, and it does so deliberately.
     */
    fun save(userId: String?, position: LastPosition)

    /**
     * Records an explicit workspace switch. The session is dropped on purpose —
     * see rule 2 above.
     */
    fun saveWorkspace(userId: String?, workspaceId: String)

    /** Drops every account's position. Called on sign-out. */
    fun clear()
}

/**
 * [LastPositionStore] on `SharedPreferences`.
 *
 * **Unsealed, unlike [EncryptedPrefs].** The value is a pair of opaque ids, not
 * a credential and not user prose; the alternative would be a third Keystore
 * alias to rotate for content nobody can act on. The cache rows this points at
 * hold the actual chat titles, and those are sealed.
 *
 * **Writes use `commit()`, not `apply()`.** The whole feature turns on a write
 * surviving the process, and `apply()` only guarantees reaching *memory* — a
 * force-stop in the same instant the user taps a chat is exactly the case this
 * class exists for. The writes happen on user actions (a workspace tap, a chat
 * tap) rather than per frame, so the synchronous write is not a hot path.
 */
class PrefsLastPositionStore(context: Context) : LastPositionStore {

    private val preferences by lazy {
        context.applicationContext.getSharedPreferences(
            PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
    }

    override fun read(userId: String?): LastPosition = quietly(LastPosition()) {
        LastPosition(
            workspaceId = preferences.readString(workspaceKey(userId)),
            sessionId = preferences.readString(sessionKey(userId)),
        )
    }

    override fun save(userId: String?, position: LastPosition) {
        val workspaceId = position.workspaceId
        val sessionId = position.sessionId
        // A blank id is not a position, and writing one would erase the workspace
        // the user is actually in. Null already means "leave it alone".
        if (workspaceId == null && sessionId == null) return
        runCatching {
            val editor = preferences.edit()
            workspaceId?.takeIf { it.isNotBlank() }
                ?.let { editor.putString(workspaceKey(userId), it) }
            sessionId?.takeIf { it.isNotBlank() }
                ?.let { editor.putString(sessionKey(userId), it) }
            editor.commit()
        }
    }

    override fun saveWorkspace(userId: String?, workspaceId: String) {
        if (workspaceId.isBlank()) return
        runCatching {
            preferences.edit()
                .putString(workspaceKey(userId), workspaceId)
                .remove(sessionKey(userId))
                .commit()
        }
    }

    override fun clear() {
        runCatching { preferences.edit().clear().commit() }
    }

    private fun android.content.SharedPreferences.readString(key: String): String? =
        getString(key, null)?.takeIf { it.isNotBlank() }

    private fun workspaceKey(userId: String?): String = "workspace:${scopeOf(userId)}"

    private fun sessionKey(userId: String?): String = "session:${scopeOf(userId)}"

    /**
     * The namespace this position belongs to.
     *
     * A resolved account gets its own namespace; an unresolved one — a server
     * running without `--auth`, where `AuthResult.AuthDisabled` leaves
     * `AuthUiState.userId` null because there is no account to attribute
     * anything to — shares a single well-known one. That is a deliberate
     * difference from [com.nalar.mobile.recents.RecentsCache], which treats a
     * null user as a miss: refusing to persist there loses a cache the next
     * fetch rebuilds, whereas refusing to persist here would silently switch
     * this feature off for every self-hosted install. A position is not content,
     * and [clear] on sign-out still bounds what a shared device can leak.
     */
    private fun scopeOf(userId: String?): String =
        userId?.takeIf { it.isNotBlank() } ?: UNSCOPED

    private inline fun <T> quietly(fallback: T, block: () -> T): T = try {
        block()
    } catch (_: Exception) {
        fallback
    }

    private companion object {
        const val PREFERENCES_NAME = "nalar_position"
        const val UNSCOPED = "unscoped"
    }
}
