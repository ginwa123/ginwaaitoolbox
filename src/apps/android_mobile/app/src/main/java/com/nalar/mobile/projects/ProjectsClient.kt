package com.nalar.mobile.projects

import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.auth.HttpsAuthTransport
import com.nalar.mobile.auth.SessionStore
import com.nalar.mobile.recents.RecentsResult
import java.net.HttpURLConnection

/**
 * Reads the drawer's project lists over the same [AuthTransport] the auth flow
 * and [com.nalar.mobile.recents.RecentsClient] use, so the app keeps a single
 * call site and the in-app network inspector shows these requests alongside
 * sign-in.
 *
 * The plumbing is deliberately a copy of `RecentsClient`'s — same cookie-only
 * auth, same status mapping, same sealed result. The one thing that is *not*
 * copied is the wording, see [messageForStatus].
 */
class ProjectsClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    /** Every project in one workspace. Not paginated — the endpoint takes none. */
    fun loadProjects(workspaceId: String): RecentsResult<List<ProjectSummary>> = get(
        path = ProjectsApi.itemsPath(workspaceId),
        parse = ProjectsApi::parseItems,
    )

    /**
     * One page of [itemId]'s chats. Pass the previous page's `nextCursor` to get
     * the next one; leave it null for the first page.
     */
    fun loadProjectChats(
        workspaceId: String,
        itemId: String,
        cursor: String? = null,
        limit: Int = ProjectsApi.TASKS_PAGE_LIMIT,
    ): RecentsResult<ProjectChatsPage> = get(
        path = ProjectsApi.tasksPath(workspaceId, itemId, cursor, limit),
        parse = { body -> ProjectsApi.parseProjectChatsPage(body, itemId) },
    )

    /**
     * Create a task under a project — an ordinary chat, or a memory file.
     *
     * Returns the row the server just inserted, so the caller can paint it
     * without re-fetching the page it landed in. A create that "succeeds" with
     * no id is reported as [RecentsResult.Unavailable] rather than as an empty
     * [com.nalar.mobile.projects.ProjectChat]: there is nothing to open and
     * nothing to select, and pretending otherwise would drop the reader into a
     * chat route that cannot resolve.
     */
    fun createTask(
        workspaceId: String,
        itemId: String,
        request: CreateTaskRequest,
    ): RecentsResult<ProjectChat> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.post(
                path = ProjectsApi.createTaskPath(workspaceId, itemId),
                body = ProjectsApi.createTaskBody(request),
                headers = sessionCookie
                    ?.let { cookie ->
                        mapOf(
                            "Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie",
                            "Content-Type" to "application/json",
                        )
                    }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }

        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(createMessageForStatus(response.statusCode))
        }

        val created = try {
            ProjectsApi.parseCreatedTask(response.body, itemId)
        } catch (_: Exception) {
            null
        } ?: return RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)

        return RecentsResult.Loaded(created)
    }

    /**
     * Cold-start fallback for the drawer's "New Chat" row: the workspace's
     * default project, created server-side when there is none.
     *
     * Normally never called — `loadProjects` already went through
     * `GET /api/workspaces/{ws}/items`, which ensures the default on read, so
     * the list the ViewModel holds already carries it. This exists for the app
     * having been open when Migration 094 ran.
     *
     * Cookie-only auth, exactly like [createTask]: this app sends the session
     * cookie and no `Authorization` header.
     */
    suspend fun getOrCreateDefaultProject(
        workspaceId: String,
    ): RecentsResult<ProjectSummary> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.post(
                path = ProjectsApi.defaultProjectPath(workspaceId),
                // No body: this is a command ("give me the default"), and the
                // name and path are fixed by the invariant. The transport
                // signature takes a non-null String, and the server route
                // ignores the body, so an empty string is the honest
                // "no body" here.
                body = "",
                headers = sessionCookie
                    ?.let { cookie ->
                        mapOf(
                            "Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie",
                            "Content-Type" to "application/json",
                        )
                    }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }

        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        // 200 = the default already existed, 201 = this call created it. Both
        // are success; the body tells the caller which.
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(createMessageForStatus(response.statusCode))
        }

        val project = try {
            ProjectsApi.parseDefaultProject(response.body)
        } catch (_: Exception) {
            null
        } ?: return RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)

        return RecentsResult.Loaded(project)
    }

    private fun <T> get(
        path: String,
        parse: (String) -> T,
    ): RecentsResult<T> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.get(
                path = path,
                // The backend reads the session from this cookie and from
                // nowhere else, so it has to ride along on every call.
                headers = sessionCookie
                    ?.let { cookie -> mapOf("Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie") }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }

        // A 401 means the cookie is gone or expired; a retry cannot fix that.
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(messageForStatus(response.statusCode))
        }

        return try {
            RecentsResult.Loaded(parse(response.body))
        } catch (_: Exception) {
            RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)
        }
    }

    private fun unreachableMessage(): String =
        "Could not reach ${AuthConfig.BASE_URL}. Check your connection."

    /**
     * These say "projects", not "sidebar".
     *
     * `RecentsClient.messageForStatus` hard-codes "sidebar" into its 5xx and
     * default messages, and reusing it here would tell a user whose *projects*
     * failed to load that the server "could not load your sidebar". A wrong noun
     * in a user-facing error is a small lie about what is broken, and this
     * codebase's comments refuse exactly that kind of drift, so the wording is
     * restated rather than shared.
     */
    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not load your projects. Try again."
        else -> "Could not load your projects. Try again."
    }

    /**
     * The same statuses, said about a *write*.
     *
     * A distinct function rather than a parameter on [messageForStatus] because
     * the two sentences are about different promises: "could not load" is
     * describing a list the reader can still scroll, and "could not create"
     * is telling them the thing they just asked for did not happen. Reusing the
     * read wording on a failed create reads as though the create may have
     * worked, which is exactly the ambiguity that sends people looking for a
     * chat that was never made.
     */
    private fun createMessageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not create that. Try again."
        // 400 and 403 land here. The server's own message names the offending
        // field and this client cannot forward it safely — it is free text from
        // a handler that has changed wording across migrations — so the app says
        // what it can vouch for and the form re-asks.
        else -> "Could not create that. Check the name and try again."
    }

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not read the saved session. Try signing in again."
        const val UNREADABLE_RESPONSE_MESSAGE = "The server sent a response this app could not read."
    }
}
