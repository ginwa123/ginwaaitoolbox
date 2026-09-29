package com.nalar.mobile.chat

import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.AuthHttpResponse
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.auth.HttpsAuthTransport
import com.nalar.mobile.auth.SessionStore
import com.nalar.mobile.worker.WorkerApi
import org.json.JSONObject
import java.net.HttpURLConnection

sealed interface ChatResult<out T> {
    data class Loaded<out T>(val value: T) : ChatResult<T>

    /** The cookie is gone or expired — the caller has to sign in again. */
    data object SignedOut : ChatResult<Nothing>

    /** The server rejected the request. The message is worth keeping. */
    data class Rejected(val message: String) : ChatResult<Nothing>

    /** Transient: offline, or the server answered with something unusable. */
    data class Unavailable(val message: String) : ChatResult<Nothing>
}

/**
 * The chat endpoints, over the same [AuthTransport] the auth flow and the
 * sidebar use, so the in-app network inspector records the exact bytes the chat
 * sent rather than a parallel implementation.
 *
 * The event stream is the one exception: it is a long-lived connection with no
 * end of body, so it cannot go through a request/response transport at all.
 * See [ChatEventStream].
 */
class ChatClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    fun loadMessages(
        sessionId: String,
        limit: Int = ChatApi.MESSAGES_PAGE_LIMIT,
        cursor: String? = null,
        direction: String = "asc",
    ): ChatResult<ChatPage> = get(
        path = ChatApi.messagesPath(sessionId, limit, cursor, direction),
        parse = ChatApi::parseMessages,
    )

    /**
     * Queues a turn. Returns as soon as the server has enqueued it — the reply
     * carries no message, which is why the transcript waits for the SSE echo
     * instead of inserting a local bubble.
     */
    fun sendMessage(
        sessionId: String,
        message: String,
        cwd: String = "",
        imageUrls: List<String> = emptyList(),
        videoUrls: List<String> = emptyList(),
        selectedProfileModel: String = "",
    ): ChatResult<Unit> {
        val body = ChatApi.sendMessageBody(
            sessionId = sessionId,
            message = message,
            cwd = cwd,
            imageUrls = imageUrls,
            videoUrls = videoUrls,
            selectedProfileModel = selectedProfileModel,
        )
        val response = try {
            transport.post(
                path = SEND_PATH,
                body = body,
                headers = authenticatedHeaders(json = true),
            )
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretWrite(response, "Your message could not be sent. Try again.")
    }

    /**
     * Every configured profile, and the reader's active default.
     *
     * Read once when a session opens rather than per tap, because a profile
     * list cannot change from inside this app — it changes in the desktop's
     * settings dialog. See [ChatUiState.availableProfiles] for why that makes a
     * per-tap refetch pure waste rather than a refresh.
     */
    fun loadProfiles(): ChatResult<ProfilesPage> = get(
        path = ChatApi.profilesPath(),
        parse = ChatApi::parseProfiles,
    )

    /**
     * Saves which profile this chat runs on.
     *
     * A `PUT` and not a field on the next send, because the choice has to
     * outlive this process: the reader picks a profile on Tuesday, and the
     * reply that goes out on Wednesday is queued by a worker this phone is not
     * holding. Sending it with the turn would make the selection apply to
     * exactly one message.
     *
     * [profileName] empty clears the per-session override and puts the chat
     * back on the cascade's next step. That is a real instruction the server
     * honours (`session_update.zig:84` writes the column unconditionally), so
     * it is the same call with different text rather than a second method.
     */
    fun updateSelectedProfile(
        sessionId: String,
        profileName: String,
    ): ChatResult<String> {
        val response = try {
            transport.put(
                path = ChatApi.sessionPath(sessionId),
                body = ChatApi.updateSessionBody(selectedProfileModel = profileName),
                headers = authenticatedHeaders(json = true),
            )
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretWrite(
            response,
            "That model could not be saved. Try again.",
            parse = { body -> JSONObject(body).optNullableString("selected_profile_model").orEmpty() },
        )
    }

    /**
     * The turns waiting behind this chat's current run.
     *
     * The bootstrap for the composer's queue panel, and the only honest answer
     * to "did my message go anywhere" after a cold open: the `queue_queued`
     * frame for a turn queued while the app was closed was emitted to nobody,
     * and the stream keeps no replay to ask again.
     *
     * A failed read leaves the panel showing what the stream has said since,
     * which is why this returns a [ChatResult] rather than throwing — an
     * offline phone should still be able to see a message it queued a minute
     * ago on a connection that has since dropped.
     */
    fun loadQueuedMessages(sessionId: String): ChatResult<List<QueuedChatMessage>> = get(
        path = ChatApi.queueMessagesPath(sessionId),
        parse = ChatApi::parseQueuedMessages,
    )

    fun stopRun(sessionId: String): ChatResult<Unit> {
        val response = try {
            transport.post(
                path = ChatApi.stopPath(sessionId),
                body = "{}",
                headers = authenticatedHeaders(json = true),
            )
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretWrite(response, "Could not stop the run. Try again.")
    }

    /**
     * Answers a pending `ask_user` question, which is what resumes the run.
     *
     * The reply carries the new status rather than the rewritten tool row, so
     * the caller refetches the transcript: the authoritative row arrives over
     * SSE, and rewriting the card optimistically would fight that echo.
     */
    fun answerQuestion(
        sessionId: String,
        questionId: String? = null,
        toolCallId: String? = null,
        answer: String? = null,
        skip: Boolean = false,
    ): ChatResult<Unit> {
        val response = try {
            transport.post(
                path = ChatApi.answerPath(sessionId),
                body = ChatApi.answerQuestionBody(
                    questionId = questionId,
                    toolCallId = toolCallId,
                    answer = answer,
                    skip = skip,
                ),
                headers = authenticatedHeaders(json = true),
            )
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretWrite(response, "The answer could not be sent. Try again.")
    }

    /**
     * The in-flight partial text for a run that is still going.
     *
     * There is no SSE replay to re-attach from, so a reconnect or a process
     * death mid-run is repaired by reading this snapshot and then refetching the
     * transcript. It is in-memory on the server, so `active: false` after a
     * server restart is normal rather than an error.
     */
    fun loadStreamSnapshot(sessionId: String): ChatResult<String> = get(
        path = ChatApi.streamSnapshotPath(sessionId),
        parse = { body -> JSONObject(body).optNullableString("content").orEmpty() },
    )

    /**
     * The sessions with a live worker, as a bootstrap for the running set
     * that [com.nalar.mobile.worker.RunningSessionsStore] holds.
     *
     * The stream carries no replay, so a run that was already going when the app
     * opened produces no event at all — the list is the only way to learn about
     * it, and the only way to un-learn a run that stopped while the socket was
     * down.
     *
     * It answers with the *rows*, not a boolean per session: the backend
     * hardcodes `status: "running"` and `is_running: true` for everything it
     * returns, so [WorkerApi.parseRunningSessionIds] projects presence down to
     * the set of ids rather than trusting a field that is always true.
     */
    fun loadRunningSessions(): ChatResult<Set<String>> = get(
        path = WorkerApi.workersPath(),
        parse = WorkerApi::parseRunningSessionIds,
    )

    private fun <T> get(
        path: String,
        parse: (String) -> T,
    ): ChatResult<T> {
        val response = try {
            transport.get(path = path, headers = authenticatedHeaders(json = false))
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretRead(response, parse)
    }

    private fun <T> interpretRead(
        response: AuthHttpResponse,
        parse: (String) -> T,
    ): ChatResult<T> {
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return ChatResult.SignedOut
        }
        if (response.statusCode == HttpURLConnection.HTTP_NOT_FOUND) {
            // A 404 here means "not yours" as often as "does not exist" — the
            // backend collapses both. Saying "not found" keeps it neutral.
            return ChatResult.Rejected("That chat no longer exists.")
        }
        if (response.statusCode !in 200..299) {
            return ChatResult.Unavailable(messageForStatus(response.statusCode))
        }
        return try {
            ChatResult.Loaded(parse(response.body))
        } catch (_: Exception) {
            ChatResult.Unavailable("The server sent a response this app could not read.")
        }
    }

    /**
     * A write whose reply carries nothing this client needs.
     *
     * An overload rather than a defaulted `parse` on the generic one: a default
     * of `{ Unit }` leaves `T` unconstrained, so the compiler cannot infer it
     * at a call site and every existing caller would have to say
     * `interpretWrite<Unit>(...)`. Two functions keep each call site saying only
     * what it actually reads.
     */
    private fun interpretWrite(
        response: AuthHttpResponse,
        rejectionMessage: String,
    ): ChatResult<Unit> = interpretWrite(response, rejectionMessage, parse = { })

    /**
     * A write that answers with a value, run through [parse].
     *
     * The parse is *inside* the try-free region but guarded, so an unreadable
     * success body is [ChatResult.Unavailable] rather than an exception
     * escaping into a coroutine — the same rule [interpretRead] follows.
     */
    private fun <T> interpretWrite(
        response: AuthHttpResponse,
        rejectionMessage: String,
        parse: (String) -> T,
    ): ChatResult<T> {
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return ChatResult.SignedOut
        }
        // 4xx here means the request itself was wrong, so a retry sends the
        // same wrong request. 5xx and timeouts are worth retrying.
        if (response.statusCode in 400..499) {
            return ChatResult.Rejected(rejectionMessage)
        }
        if (response.statusCode !in 200..299) {
            return ChatResult.Unavailable(messageForStatus(response.statusCode))
        }
        return try {
            ChatResult.Loaded(parse(response.body))
        } catch (_: Exception) {
            ChatResult.Unavailable("The server sent a response this app could not read.")
        }
    }

    private fun authenticatedHeaders(json: Boolean): Map<String, String> {
        val cookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            null
        }
        return buildMap {
            if (json) put("Content-Type", "application/json")
            // The backend reads the session from this cookie and from nowhere
            // else — no bearer token, no CSRF token — so it rides on every call.
            cookie?.let { put("Cookie", "${AuthConfig.SESSION_COOKIE_NAME}=$it") }
        }
    }

    private fun unreachableMessage(): String =
        "Could not reach ${AuthConfig.BASE_URL}. Check your connection."

    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not load this chat. Try again."
        else -> "Could not load this chat. Try again."
    }

    companion object {
        /** Sending is a create-or-queue POST, so the path is the bare collection. */
        const val SEND_PATH = "/api/llm/session"
    }
}
