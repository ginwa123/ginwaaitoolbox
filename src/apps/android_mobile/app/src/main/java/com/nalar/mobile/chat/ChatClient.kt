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
    baseUrl: String = AuthConfig.BASE_URL,
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport = httpTransport ?: HttpsAuthTransport(baseUrl)

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
     * The sessions with a live worker, as a bootstrap for [WorkerApi.eventsPath].
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

    private fun interpretWrite(
        response: AuthHttpResponse,
        rejectionMessage: String,
    ): ChatResult<Unit> {
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
        return ChatResult.Loaded(Unit)
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
