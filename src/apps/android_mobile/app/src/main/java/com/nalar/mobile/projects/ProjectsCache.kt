package com.nalar.mobile.projects

import android.content.Context
import com.nalar.mobile.cache.CachedProjectChatEntity
import com.nalar.mobile.cache.CachedProjectEntity
import com.nalar.mobile.cache.NalarCacheDatabase
import com.nalar.mobile.cache.ProjectsCacheDao
import com.nalar.mobile.recents.orNull
import com.nalar.mobile.storage.KeystoreSealingCipher
import com.nalar.mobile.storage.SealingCipher

/**
 * Last-known project data, so a cold boot or an offline launch paints real
 * project rows instead of an empty section.
 *
 * **A separate interface from [com.nalar.mobile.recents.RecentsCache], on
 * purpose.** That one's KDoc scopes it to exactly two endpoints and says adding
 * a third "should be a deliberate change to this interface, not a side effect of
 * some new caller". This is that deliberate change — so it arrives as a new,
 * honestly-scoped interface rather than as a quiet widening of one that promised
 * otherwise. The reasoning behind the rules below is the same; only the scope
 * is different.
 *
 * The four rules, all load-bearing on a phone:
 *
 * 1. **Namespaced per user.** `logout()` only clears the session cookie, so an
 *    unscoped cache would put the previous account's project names on screen for
 *    the next person who signs in on a shared device. Every read and write
 *    requires a non-blank `userId`.
 * 2. **Partitioned per workspace, then per project.** A project's chats are only
 *    meaningful next to the project they belong to, and the drawer's section is
 *    scoped to one workspace at a time. Painting workspace A's projects under
 *    workspace B's name is the failure this prevents.
 * 3. **Encrypted at rest.** A project name and a chat title are the most
 *    identifying strings in the app, and a SQLite file is plaintext on disk, so
 *    both are sealed with a Keystore AES-GCM key under its own alias. The
 *    `item_type` and timestamp columns stay in the clear because the query needs
 *    them — `ORDER BY position` cannot run on ciphertext.
 * 4. **Fail-silent.** A corrupt payload, an undecryptable entry or a Keystore
 *    that refuses to open degrades to a plain cache miss. A broken cache must
 *    never be the reason the app fails.
 *
 * There is **no TTL**, matching `RecentsCache`: that is only safe because every
 * paint is immediately followed by a live fetch, an invariant
 * [com.nalar.mobile.recents.HomeViewModel] enforces by construction.
 */
interface ProjectsCache {
    /**
     * A null or blank `userId` is a miss, never an unscoped read — see
     * [com.nalar.mobile.recents.RecentsCache.readWorkspaces] for why the
     * desktop's looser fallback is the wrong default on a phone.
     */
    fun readProjects(userId: String?, workspaceId: String): List<ProjectSummary>?

    fun writeProjects(userId: String?, workspaceId: String, projects: List<ProjectSummary>)

    fun readProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
    ): List<ProjectChat>?

    fun writeProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
        chats: List<ProjectChat>,
    )

    /** Drops every cached entry for every user. Called on sign-out. */
    fun clear()
}

/**
 * [ProjectsCache] on Room, one row per project and per project chat, sealed
 * with a Keystore key wherever the content is user text.
 *
 * A read therefore decrypts one column per row. That is the price of keeping the
 * database a plain SQLite file the JVM tests can open for real; see
 * [SealingCipher] for why SQLCipher was not used instead.
 */
class RoomProjectsCache(
    private val dao: ProjectsCacheDao,
    private val cipher: SealingCipher,
) : ProjectsCache {

    constructor(context: Context) : this(
        dao = NalarCacheDatabase.get(context).projectsCacheDao(),
        cipher = KeystoreSealingCipher(KEY_ALIAS),
    )

    override fun readProjects(
        userId: String?,
        workspaceId: String,
    ): List<ProjectSummary>? {
        val user = userId.orNull() ?: return null
        val workspace = workspaceId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.projectsFor(user, workspace)
            when {
                // A row store cannot tell "never fetched" from "this workspace
                // has no projects", and `HomeViewModel` cannot either: it treats
                // both as "nothing to paint, go and fetch", and the fetch is
                // what decides which of the two it was.
                rows.isEmpty() -> null

                // One unopenable row invalidates the whole list. A half-readable
                // section would paint a subset and call it truth; a miss shows
                // the loading state until the fetch lands.
                else -> {
                    val names = rows.map { cipher.open(it.nameSealed) }
                    if (names.any { it == null }) {
                        dao.deleteProjectsFor(user, workspace)
                        null
                    } else {
                        rows.mapIndexed { index, row ->
                            ProjectSummary(
                                id = row.projectId,
                                workspaceId = row.workspaceId,
                                itemType = row.itemType,
                                name = names[index].orEmpty(),
                                // The path is not stored. Nothing in this feature
                                // reads it, and a filesystem path is user
                                // content on a shared device.
                                path = "",
                            )
                        }
                    }
                }
            }
        }
    }

    override fun writeProjects(
        userId: String?,
        workspaceId: String,
        projects: List<ProjectSummary>,
    ) {
        val user = userId.orNull() ?: return
        val workspace = workspaceId.orNull() ?: return
        val rows = quietly(null) { projects.toEntities(user, workspace) } ?: return
        // This deletes the chats of projects that have just disappeared, in the
        // same transaction — see ProjectsCacheDao.deleteChatsForWorkspace.
        quietly(Unit) { dao.deleteChatsForWorkspace(user, workspace, rows) }
    }

    override fun readProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
    ): List<ProjectChat>? {
        val user = userId.orNull() ?: return null
        val workspace = workspaceId.orNull() ?: return null
        val project = projectId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.projectChatsFor(user, workspace, project)
            when {
                rows.isEmpty() -> null
                else -> {
                    val names = rows.map { cipher.open(it.nameSealed) }
                    if (names.any { it == null }) {
                        dao.deleteProjectChatsFor(user, workspace, project)
                        null
                    } else {
                        rows.mapIndexed { index, row ->
                            ProjectChat(
                                id = row.chatId,
                                projectId = row.projectId,
                                name = names[index].orEmpty(),
                                updatedAtEpochMillis = row.updatedAtEpochMillis,
                            )
                        }
                    }
                }
            }
        }
    }

    override fun writeProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
        chats: List<ProjectChat>,
    ) {
        val user = userId.orNull() ?: return
        val workspace = workspaceId.orNull() ?: return
        val project = projectId.orNull() ?: return
        val rows = quietly(null) { chats.toEntities(user, workspace, project) } ?: return
        quietly(Unit) { dao.replaceProjectChats(user, workspace, project, rows) }
    }

    override fun clear() = quietly(Unit) { dao.clearAll() }

    /**
     * Sealing, all-or-nothing.
     *
     * A list where one row failed to seal would paint a project under its real
     * name next to one under a blank, and the correction would then depend on
     * the user noticing rather than on the next fetch. Half a list is worse than
     * none, so one failure drops the whole write — and returning null rather
     * than throwing is what turns that into "skip this write", the fail-silent
     * contract above.
     */
    private fun List<ProjectSummary>.toEntities(
        userId: String,
        workspaceId: String,
    ): List<CachedProjectEntity>? {
        val out = ArrayList<CachedProjectEntity>(size)
        forEachIndexed { index, project ->
            val sealed = cipher.seal(project.name) ?: return null
            out.add(
                CachedProjectEntity(
                    userId = userId,
                    workspaceId = workspaceId,
                    projectId = project.id,
                    position = index,
                    itemType = project.itemType,
                    nameSealed = sealed,
                ),
            )
        }
        return out
    }

    private fun List<ProjectChat>.toEntities(
        userId: String,
        workspaceId: String,
        projectId: String,
    ): List<CachedProjectChatEntity>? {
        val out = ArrayList<CachedProjectChatEntity>(size)
        forEachIndexed { index, chat ->
            val sealed = cipher.seal(chat.name) ?: return null
            out.add(
                CachedProjectChatEntity(
                    userId = userId,
                    workspaceId = workspaceId,
                    projectId = projectId,
                    chatId = chat.id,
                    position = index,
                    updatedAtEpochMillis = chat.updatedAtEpochMillis,
                    nameSealed = sealed,
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
         * Its own alias, distinct from the recents cache's and the session
         * cookie's. A suspected project-cache leak and a suspected credential
         * leak have to stay separate investigations that can be rotated
         * separately, and project names are their own third kind of thing.
         */
        const val KEY_ALIAS = "nalar_projects_cache_key_v1"
    }
}
