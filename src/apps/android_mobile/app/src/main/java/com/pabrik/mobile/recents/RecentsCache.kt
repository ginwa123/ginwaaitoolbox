package com.pabrik.mobile.recents

import android.content.Context
import com.pabrik.mobile.cache.CachedChatSummaryEntity
import com.pabrik.mobile.cache.CachedWorkspaceEntity
import com.pabrik.mobile.cache.PabrikCacheDatabase
import com.pabrik.mobile.cache.RecentsCacheDao
import com.pabrik.mobile.storage.KeystoreSealingCipher
import com.pabrik.mobile.storage.SealingCipher

/**
 * Last-known sidebar data, so a cold boot or an offline launch paints real rows
 * instead of an error screen.
 *
 * **Scope: exactly two endpoints**, deliberately — `GET /api/workspaces?is_include_items=false`
 * and `GET /api/session?workspace_id=…`. These are the two the sidebar renders and the
 * two the Vue web's sidebar primitives mirror (`workspacesCache.ts`, `SessionEngineDb`).
 * The web also caches git status, task media, auth/me and message history, but none of
 * those are on this screen, and a general-purpose cache would be harder to reason about
 * than two named accessors. Adding a third endpoint here should be a deliberate change
 * to this interface, not a side effect of some new caller.
 *
 * Three rules make this safe on a phone, and all three are load-bearing:
 *
 * 1. **Namespaced per user.** `logout()` only clears the session
 *    cookie, so an unscoped cache would put the previous account's workspaces
 *    and chat titles on screen for the next person who signs in on a shared
 *    device. Every read and write requires a non-blank `userId`.
 * 2. **Partitioned per workspace.** Recents are scoped server-side, so the cache
 *    is keyed the same way. Painting workspace A's rows under workspace B's name
 *    is the failure this prevents.
 * 3. **Encrypted at rest.** Chat titles are user content and a SQLite file is
 *    plaintext on disk, so the title column is sealed with a Keystore AES-GCM
 *    key under its own alias. This mirrors
 *    [com.pabrik.mobile.auth.SessionCookieStore], so a suspected cache leak and
 *    a suspected credential leak stay separate investigations that can be
 *    rotated separately.
 *
 * Every operation is fail-silent: a corrupt payload, an undecryptable entry or
 * a Keystore that refuses to open degrades to a plain cache miss. A broken
 * cache must never be the reason the app fails.
 *
 * There is **no TTL**, matching `workspacesCache.ts`. That is only safe because
 * every paint is immediately followed by a live fetch — an invariant
 * [HomeViewModel] enforces by construction, not by convention.
 */
interface RecentsCache {
    /**
     * A null or blank `userId` is a miss, never an unscoped read. That is
     * stricter than the desktop's `userScopedKey`, which falls back to an
     * UNSCOPED key when identity is unresolved; on a phone that fallback is
     * precisely the case where one account's rows leak to the next, so callers
     * cannot opt into it.
     */
    fun readWorkspaces(userId: String?): List<WorkspaceOption>?

    fun writeWorkspaces(userId: String?, workspaces: List<WorkspaceOption>)

    fun readChats(userId: String?, workspaceId: String): List<ChatSummary>?

    fun writeChats(userId: String?, workspaceId: String, chats: List<ChatSummary>)

    /** Drops every cached entry for every user. Called on sign-out. */
    fun clear()
}

/**
 * [RecentsCache] on Room, one row per workspace and per chat, sealed with a
 * Keystore key wherever the content is user text.
 *
 * ### What SQL took over
 *
 * The old store keyed each list by a hand-built string
 * (`chats::u:<userId>::w:<workspaceId>`) and held a JSON array as the value.
 * Both of the ways that could go wrong are now structural:
 *
 * - **Isolation** is the primary key. A user id is a column, so it cannot be
 *   confused with a separator, spliced into a neighbour's namespace, or reach
 *   another partition by any spelling of it.
 * - **Order** is a `position` column. A JSON array carried its order for free;
 *   rows do not, and `ORDER BY name` would have re-sorted the drawer into
 *   alphabetical order under a user who never asked for it.
 *
 * ### What sealing costs, stated plainly
 *
 * Only `name` and `title` are sealed. The id, position and timestamp columns
 * stay in the clear because the query needs them — `ORDER BY position` cannot
 * run on ciphertext. A read therefore decrypts one column per row, which is
 * the price of keeping the database a plain SQLite file the JVM tests can open
 * for real; `SealingCipher` explains why SQLCipher was not used instead.
 */
class RoomRecentsCache(
    private val dao: RecentsCacheDao,
    private val cipher: SealingCipher,
) : RecentsCache {

    constructor(context: Context) : this(
        dao = PabrikCacheDatabase.get(context).recentsCacheDao(),
        cipher = KeystoreSealingCipher(KEY_ALIAS),
    )

    override fun readWorkspaces(userId: String?): List<WorkspaceOption>? {
        val user = userId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.workspacesFor(user)
            when {
                // Nothing cached. A row store cannot tell "never fetched" from
                // "this account has no workspaces", and `HomeViewModel` cannot
                // either: it treats both as "nothing to paint, go and fetch",
                // and the fetch is what decides which of the two it was.
                rows.isEmpty() -> null

                // One unopenable row invalidates the whole list, exactly as one
                // undecryptable preference did before. A half-readable drawer
                // would paint a subset of the user's workspaces and call it
                // truth; a miss shows the loading state until the fetch lands.
                else -> {
                    val names = rows.map { cipher.open(it.nameSealed) }
                    if (names.any { it == null }) {
                        dao.deleteWorkspacesFor(user)
                        null
                    } else {
                        rows.mapIndexed { index, row ->
                            WorkspaceOption(id = row.workspaceId, name = names[index].orEmpty())
                        }
                    }
                }
            }
        }
    }

    override fun writeWorkspaces(userId: String?, workspaces: List<WorkspaceOption>) {
        val user = userId.orNull() ?: return
        val rows = quietly(null) { workspaces.toEntities(user) } ?: return
        quietly(Unit) { dao.replaceWorkspaces(user, rows) }
    }

    override fun readChats(userId: String?, workspaceId: String): List<ChatSummary>? {
        val user = userId.orNull() ?: return null
        val workspace = workspaceId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.chatsFor(user, workspace)
            when {
                rows.isEmpty() -> null

                else -> {
                    val titles = rows.map { cipher.open(it.titleSealed) }
                    if (titles.any { it == null }) {
                        dao.deleteChatsFor(user, workspace)
                        null
                    } else {
                        rows.mapIndexed { index, row ->
                            ChatSummary(
                                id = row.chatId,
                                workspaceId = row.workspaceId,
                                title = titles[index].orEmpty(),
                                updatedAtEpochMillis = row.updatedAtEpochMillis,
                                lastHumanTouchedAtEpochMillis = row.lastHumanTouchedAtEpochMillis,
                            )
                        }
                    }
                }
            }
        }
    }

    override fun writeChats(userId: String?, workspaceId: String, chats: List<ChatSummary>) {
        val user = userId.orNull() ?: return
        val workspace = workspaceId.orNull() ?: return
        val rows = quietly(null) { chats.toEntities(user, workspace) } ?: return
        quietly(Unit) { dao.replaceChats(user, workspace, rows) }
    }

    override fun clear() = quietly(Unit) { dao.clearAll() }

    /**
     * Sealing, all-or-nothing.
     *
     * A list where one row failed to seal would paint a workspace under its
     * real name next to one under a blank, and the correction would then depend
     * on the user noticing rather than on the next fetch. Half a list is worse
     * than none, so one failure drops the whole write.
     *
     * Returns null rather than throwing: the caller turns that into "skip this
     * write", which is the fail-silent contract above.
     */
    private fun List<WorkspaceOption>.toEntities(userId: String): List<CachedWorkspaceEntity>? {
        val out = ArrayList<CachedWorkspaceEntity>(size)
        forEachIndexed { index, workspace ->
            val sealed = cipher.seal(workspace.name) ?: return null
            out.add(
                CachedWorkspaceEntity(
                    userId = userId,
                    workspaceId = workspace.id,
                    position = index,
                    nameSealed = sealed,
                ),
            )
        }
        return out
    }

    private fun List<ChatSummary>.toEntities(
        userId: String,
        workspaceId: String,
    ): List<CachedChatSummaryEntity>? {
        val out = ArrayList<CachedChatSummaryEntity>(size)
        forEachIndexed { index, chat ->
            val sealed = cipher.seal(chat.title) ?: return null
            out.add(
                CachedChatSummaryEntity(
                    userId = userId,
                    workspaceId = workspaceId,
                    chatId = chat.id,
                    position = index,
                    updatedAtEpochMillis = chat.updatedAtEpochMillis,
                    lastHumanTouchedAtEpochMillis = chat.lastHumanTouchedAtEpochMillis,
                    titleSealed = sealed,
                ),
            )
        }
        return out
    }

    private inline fun <T> quietly(fallback: T, block: () -> T): T = try {
        block()
    } catch (_: Exception) {
        fallback
    }

    private companion object {
        /**
         * Distinct from the session cookie's and the `/me` cache's aliases:
         * chat titles are a third kind of thing to rotate independently, and
         * the value of keeping the old SharedPreferences store's alias is that
         * an upgrade rotates nothing.
         */
        const val KEY_ALIAS = "pabrik_cache_key_v1"
    }
}

/**
 * A null or blank identity cannot address a partition, so it is not a partition.
 *
 * `internal` rather than file-private so the projects cache enforces the same
 * rule from the same definition — a second copy is a second chance to spell the
 * guard differently, and the whole point is that it has exactly one spelling.
 */
internal fun String?.orNull(): String? = this?.takeIf { it.isNotBlank() }
