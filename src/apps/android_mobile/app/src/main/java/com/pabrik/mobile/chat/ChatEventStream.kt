package com.pabrik.mobile.chat

import org.json.JSONObject

/** One dispatched server-sent event: the `event:` name and the joined `data:` payload. */
data class SseFrame(val event: String, val data: String)

/**
 * The SSE line parser, with no Android and no network in it, so the awkward part
 * is testable.
 *
 * Two things about this backend make a naive parser silently lose data:
 *
 * 1. **Payloads are pretty-printed.** The server serialises with
 *    `std.json.fmt(payload, .{ .whitespace = .indent_4 })` and then prefixes
 *    *every* resulting line with `data: `. Splitting the stream on newlines and
 *    parsing each chunk throws on the first indented line.
 * 2. **A frame dispatches on a blank line**, not on a complete JSON object. There
 *    is no length prefix and no `id:` line to anchor on.
 *
 * So data lines accumulate and join with a newline, which is what reconstitutes
 * the original document byte for byte.
 */
class SseFrameParser {
    private var eventName: String? = null
    private val data = StringBuilder()

    /**
     * Feeds one line (without its terminator) and returns a frame if that line
     * completed one. Returns null for everything else.
     */
    fun accept(line: String): SseFrame? {
        return when {
            // A comment; the heartbeat arrives as one.
            line.startsWith(":") -> null

            line.isEmpty() -> dispatch()

            // `field: value`, with an optional single leading space that the
            // spec says to strip. The server does not send `id:` at all, so
            // there is deliberately no last-event-id tracking here.
            line.contains(':') -> {
                val separator = line.indexOf(':')
                val field = line.substring(0, separator)
                val value = line.substring(separator + 1).removePrefix(" ")
                when (field) {
                    "event" -> eventName = value
                    "data" -> {
                        if (data.isNotEmpty()) data.append('\n')
                        data.append(value)
                    }
                    // `retry` and any unknown field are ignored on purpose:
                    // reconnect policy here is ours, not the server's.
                }
                null
            }

            // A bare field name means an empty value.
            else -> {
                when (line) {
                    "event" -> eventName = ""
                    "data" -> data.append('\n')
                }
                null
            }
        }
    }

    /**
     * Dispatches whatever is buffered at end of stream. A connection dropped
     * mid-frame would otherwise swallow a complete-looking payload.
     */
    fun flush(): SseFrame? = dispatch()

    private fun dispatch(): SseFrame? {
        if (eventName == null && data.isEmpty()) return null
        val frame = SseFrame(
            // A frame with no `event:` line is a bare `data:` dispatch, which
            // the spec names "message".
            event = eventName?.takeIf { it.isNotEmpty() } ?: DEFAULT_EVENT,
            data = data.toString(),
        )
        eventName = null
        data.setLength(0)
        return frame
    }

    companion object {
        const val DEFAULT_EVENT = "message"
    }
}

/** What a decoded frame means to the chat. */
sealed interface ChatStreamEvent {
    /** The handshake. The only liveness signal the server offers. */
    data object Connected : ChatStreamEvent

    /**
     * A raw delta. The backend sends provider deltas verbatim, so this must be
     * *appended*; replacing leaves only the last fragment visible.
     *
     * `reasoningContent` arrives on the same `type: "chunk"` as content — the
     * two are told apart by which field is present, not by the type.
     */
    data class Chunk(
        val sessionId: String,
        val index: Int,
        val content: String = "",
        val reasoningContent: String = "",
    ) : ChatStreamEvent

    /** End of a turn's stream. Carries no message; the `full` that follows does. */
    data class ChunkFinished(
        val sessionId: String,
        val totalTokens: Int?,
    ) : ChatStreamEvent

    /** The canonical, complete row. Upsert by [ChatMessage.id]. */
    data class Full(val sessionId: String, val message: ChatMessage) : ChatStreamEvent

    /**
     * A sub-agent was launched, finished or failed.
     *
     * Synthetic and never persisted: the backend emits these on the `llm_full`
     * channel with `role: "subagent_progress"` and an empty body. They are the
     * only live signal that a fan-out is progressing — the `spawn_sub_agent`
     * result row does not arrive until every sub-agent is already done — so
     * dropping them makes a two-minute fan-out look like a hang.
     */
    data class SubAgentProgress(
        val sessionId: String,
        val toolCallId: String,
        val agentName: String,
        val status: String,
        val agentIndex: Int,
        val totalAgents: Int,
    ) : ChatStreamEvent {
        companion object {
            const val STATUS_LAUNCHED = "launched"
            const val STATUS_COMPLETED = "completed"
            const val STATUS_FAILED = "failed"
        }
    }

    data class SessionChanged(
        val sessionId: String,
        val action: String,
        val name: String,
    ) : ChatStreamEvent

    /**
     * A turn joined or left the queue behind the current run.
     *
     * Carries the **row**, not a +/- 1, and that is the whole point: a
     * composer that can queue a turn has to be able to show *which* turn went
     * where, and a delta can only ever answer "how many". The web made the same
     * move (`ChatView.vue:3716` pushes `{id, message}` on `queued` and filters
     * by `id` on `deleted`) for the same reason.
     *
     * [message] is empty on a delete — the backend's `queue_deleted` payload is
     * `{action, id, session_id}` and carries no text.
     */
    data class QueueChanged(
        val sessionId: String,
        val action: String,
        val id: String,
        val message: String = "",
    ) : ChatStreamEvent {
        companion object {
            const val ACTION_QUEUED = "queued"
            const val ACTION_DELETED = "deleted"
        }
    }

    /**
     * A worker was registered, heart-beat, or removed.
     *
     * The backend's definition of "the agent is working on this session", and
     * the only signal that covers a run this screen did not start: a chat
     * opened mid-run has no chunks of its own yet, and a multi-step loop goes
     * quiet between turns while the worker is very much still going.
     *
     * [sessionId] is already resolved from `session_id` *or* `id`, because the
     * heartbeat and delete paths send an empty `session_id` and carry the
     * session in the `id` slot — see [decodeChatFrame].
     */
    data class WorkerChanged(
        val sessionId: String,
        val action: String,
    ) : ChatStreamEvent {
        companion object {
            const val ACTION_CREATED = "created"
            const val ACTION_UPDATED = "updated"
            const val ACTION_DELETED = "deleted"
        }
    }

    /**
     * The stream was rejected. The backend cannot answer 401 here — the
     * `text/event-stream` response is already committed by the time auth runs —
     * so an unauthenticated client gets `auth_error` and a clean close, which
     * without this event looks identical to a flaky network.
     */
    data class Failed(val message: String) : ChatStreamEvent
}

sealed interface ChatStreamState {
    data object Connecting : ChatStreamState
    data object Live : ChatStreamState
    data object Reconnecting : ChatStreamState
    data class Failed(val message: String) : ChatStreamState
}

/**
 * Decodes a dispatched frame into a [ChatStreamEvent], or null when the frame
 * is not one this screen acts on.
 *
 * Filtering by `session_id` happens here rather than in the ViewModel so a
 * client that subscribed to the central `llm` channel cannot accidentally apply
 * another chat's turn.
 */
fun decodeChatFrame(frame: SseFrame): ChatStreamEvent? = try {
    decodeChatFrameUnsafe(frame)
} catch (_: Exception) {
    // A frame we cannot parse is dropped, not fatal — the stream carries on and
    // the next `full` refetches the authoritative row.
    null
}

private fun decodeChatFrameUnsafe(frame: SseFrame): ChatStreamEvent? {
    val payload = JSONObject(frame.data)
    return when (frame.event) {
        "connected" -> ChatStreamEvent.Connected

        "auth_error" -> ChatStreamEvent.Failed(
            payload.optNullableString("error") ?: "The event stream was rejected.",
        )

        "llm_chunk" -> {
            val sessionId = payload.optNullableString("session_id").orEmpty()
            val content = payload.optNullableString("content")
            val reasoning = payload.optNullableString("reasoning_content")
            when (payload.optNullableString("type")) {
                "chunk" -> {
                    if (content == null && reasoning == null) {
                        null
                    } else {
                        ChatStreamEvent.Chunk(
                            sessionId = sessionId,
                            index = payload.optInt("index", 0),
                            content = content.orEmpty(),
                            reasoningContent = reasoning.orEmpty(),
                        )
                    }
                }

                "chunk_final" -> ChatStreamEvent.ChunkFinished(
                    sessionId = sessionId,
                    // Nested under `usage`, not top level. Reading it from the
                    // top level yields null on every turn — and the old fixture
                    // that put it there is the only reason the bug was green.
                    totalTokens = payload.optNullableObject("usage")
                        ?.let { if (it.isNull("total_tokens")) null else it.optInt("total_tokens") },
                )

                else -> null
            }
        }

        "llm_full" -> {
            val sessionId = payload.optNullableString("session_id").orEmpty()
            // Sub-agent lifecycle pings ride this same channel, distinguished
            // only by a synthetic role. They must be routed before the generic
            // row handling: their content is empty and they are never
            // persisted, so treating one as a turn writes a phantom row into
            // the transcript that the next revalidate then has to erase.
            if (payload.optNullableString("role") == ChatMessage.ROLE_SUBAGENT_PROGRESS) {
                ChatStreamEvent.SubAgentProgress(
                    sessionId = sessionId,
                    toolCallId = payload.optNullableString("tool_call_id").orEmpty(),
                    agentName = payload.optNullableString("agent_name").orEmpty(),
                    status = payload.optNullableString("status").orEmpty(),
                    agentIndex = payload.optInt("agent_index", 0),
                    totalAgents = payload.optInt("total_agents", 0),
                )
            } else if (payload.optBoolean("is_error", false)) {
                // `is_error` marks an agentic-loop diagnostic (a retry notice, a
                // TooManyRetries), not a chat turn. It renders as an error card
                // and is never written to the transcript.
                ChatStreamEvent.Failed(
                    payload.optNullableString("content")
                        ?: "The agent reported an error.",
                )
            } else {
                val message = ChatApi.toChatMessage(payload)
                if (message == null || !message.isRealTurn) {
                    // Accepting a contentless row used to silently drop every
                    // tool result and image-only echo. Anything with a finish
                    // reason or a tool identity is a real turn — including a
                    // call declaration, which draws nothing once its result has
                    // landed but is the only trace of a call still in flight.
                    null
                } else {
                    ChatStreamEvent.Full(sessionId, message)
                }
            }
        }

        "session_created", "session_updated", "session_deleted" -> {
            val action = frame.event.removePrefix("session_")
            ChatStreamEvent.SessionChanged(
                sessionId = payload.optNullableString("id").orEmpty(),
                action = action,
                name = payload.optNullableString("name").orEmpty(),
            )
        }

        "queue_queued", "queue_deleted" -> ChatStreamEvent.QueueChanged(
            sessionId = payload.optNullableString("session_id").orEmpty(),
            action = if (frame.event == "queue_queued") {
                ChatStreamEvent.QueueChanged.ACTION_QUEUED
            } else {
                ChatStreamEvent.QueueChanged.ACTION_DELETED
            },
            // Both emitters stamp the row id, and it is the only handle a
            // later delete can be matched against. An empty one cannot be, so
            // it is dropped here rather than published as a row that can be
            // appended and never removed.
            id = payload.optNullableString("id").orEmpty().takeIf { it.isNotEmpty() }
                ?: return null,
            // Only `queue_queued` carries the text; `queue_deleted` does not.
            message = payload.optNullableString("message").orEmpty(),
        )

        "worker_created", "worker_updated", "worker_deleted" -> {
            // The emitters disagree about which id field to fill.
            // `updateWorker` (the upsert behind `created`/`updated`) sends
            // both, but `updateWorkerActivityWithDescription` and all three
            // delete emitters send `session_id: ""` and put the session in
            // `id`. Reading `session_id` alone means a `deleted` removes
            // nothing and the spinner stays lit for a run that has finished.
            val sessionId = payload.optNullableString("session_id").orEmpty()
                .ifEmpty { payload.optNullableString("id").orEmpty() }
            if (sessionId.isEmpty()) {
                null
            } else {
                ChatStreamEvent.WorkerChanged(
                    sessionId = sessionId,
                    action = frame.event.removePrefix("worker_"),
                )
            }
        }

        else -> null
    }
}
