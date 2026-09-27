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
    baseUrl: String = AuthConfig.BASE_URL,
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport = httpTransport ?: HttpsAuthTransport(baseUrl)

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
            RecentsResult.Unavailable("The server sent a response this app could not read.")
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

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not read the saved session. Try signing in again."
    }
}
