package com.nalar.mobile.projects

import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.auth.HttpsAuthTransport
import com.nalar.mobile.auth.SessionStore
import com.nalar.mobile.recents.RecentsResult
import java.net.HttpURLConnection

/**
 * The three reads and one write the "New task" form needs that are **not** the
 * create POST: the board's columns, the profiles it can run under, the server's
 * home for the worktree prefill, and the move that puts the new card in the
 * column the reader picked.
 *
 * Separate from [ProjectsClient] on purpose. That one is "the drawer's lists",
 * its [AuthTransport] instance is the same one, and merging them would make
 * [ProjectsClient.createTask] — the function every project type goes through —
 * sit in a file whose name says "board". The four methods here share nothing
 * with it but the cookie, and each is a single request with no paging.
 */
class KanbanClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    /**
     * The board's columns, for the form's column chip.
     *
     * An empty list is a real answer, not a failure: a board with no columns
     * yet returns `{"columns":[]}`, and the form renders no chip and lets the
     * server auto-assign. [RecentsResult.Unavailable] therefore means "we could
     * not find out", which the caller renders as a form with no column picker
     * rather than as an error the reader has to dismiss — an unavailable read
     * must not block a create that does not need it.
     */
    fun loadColumns(
        workspaceId: String,
        itemId: String,
    ): RecentsResult<List<KanbanColumn>> = get(KanbanApi.columnsPath(workspaceId, itemId)) {
        // `parseColumns` returns null for a body that is not a columns list, and
        // the generic `get` turns a thrown parse error into Unavailable — so
        // the failure has to be a throw, not a value, or "unreadable" would
        // arrive here as "this board has no columns".
        KanbanApi.parseColumns(it)
            ?: throw IllegalStateException("Response was not a kanban columns list")
    }

    /**
     * The profiles a card can be created under, as raw names.
     *
     * Names and not [com.nalar.mobile.chat.ModelProfile] rows: the create form
     * only needs the `selected_profile_model` string the backend stores, and
     * the chat package's own type would make a board's form depend on a chat
     * screen's model. The profile picker is one line of help text under the
     * name, exactly as the web draws it.
     *
     * Parsed with the chat's own [com.nalar.mobile.chat.ChatApi.parseProfiles]
     * so the two readers of `GET /api/config/nalar` cannot disagree about
     * `profiles_models` being an object keyed by name rather than an array —
     * which is the mistake that makes a configured profile list come back empty.
     */
    fun loadProfileNames(): RecentsResult<List<String>> =
        get(com.nalar.mobile.chat.ChatApi.profilesPath()) { body ->
            com.nalar.mobile.chat.ChatApi.parseProfiles(body).profiles.map { it.name }
        }

    /**
     * The backend user's `$HOME`, used only to prefill the worktree path.
     *
     * Empty on failure rather than an error: this is a nicety, and a form whose
     * one field is prefillable must still submit when the nicety fails.
     */
    fun loadServerHome(): RecentsResult<String> = get(KanbanApi.serverHomePath()) { body ->
        KanbanApi.parseServerHome(body)
    }

    /**
     * Move a freshly created card into the column the reader chose.
     *
     * The second half of a create the backend splits in two: `POST
     * .../kanban/tasks` takes no `column_id`, so this is what makes the card
     * land where they asked. Failure is reported rather than swallowed, but the
     * caller decides what it means — the card exists either way, and only its
     * column is wrong, which is a different promise from "the create failed".
     */
    fun moveTaskToColumn(
        workspaceId: String,
        itemId: String,
        taskId: String,
        columnId: String,
        position: Int = 0,
    ): RecentsResult<Unit> {
        if (columnId.isBlank()) return RecentsResult.Loaded(Unit)

        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.patch(
                path = KanbanApi.moveTaskPath(workspaceId, itemId, taskId),
                body = KanbanApi.moveTaskBody(columnId, position),
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
            return RecentsResult.Unavailable(moveMessageForStatus(response.statusCode))
        }
        return RecentsResult.Loaded(Unit)
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
                // The backend reads the session from this cookie and nowhere
                // else, so it rides along on every call.
                headers = sessionCookie
                    ?.let { cookie -> mapOf("Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie") }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }

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
     * Says "board", not "projects" and not "sidebar".
     *
     * The same reason [ProjectsClient] restates its own wording: reusing a
     * neighbouring feature's message here would tell a reader whose board failed
     * that the server "could not load your sidebar".
     */
    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not load this board. Try again."
        else -> "Could not load this board. Try again."
    }

    /**
     * The failed *move*, said as its own promise.
     *
     * Distinct from [messageForStatus] because the card exists: what failed is
     * where it went, and saying "could not create that" would send the reader
     * off to look for a card that is already on their board.
     */
    private fun moveMessageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The task was created, but the server could not move it to that column."
        else -> "The task was created, but could not be moved to that column."
    }

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not read the saved session. Try signing in again."
        const val UNREADABLE_RESPONSE_MESSAGE = "The server sent a response this app could not read."
    }
}
