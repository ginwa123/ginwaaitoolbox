package com.nalar.mobile.chat

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

    data class SessionChanged(
        val sessionId: String,
        val action: String,
        val name: String,
    ) : ChatStreamEvent

    /**
     * A message sitting in the queue behind the current run. Worth surfacing
     * because the web shows the queue, and a turn that appears to have vanished
     * is usually still waiting.
     */
    data class QueueChanged(
        val sessionId: String,
        val action: String,
    ) : ChatStreamEvent {
        /** +1 for a queued turn, -1 for one that left the queue. */
        val queueDelta: Int get() = if (action == "queued") 1 else -1
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
                    totalTokens = if (payload.isNull("total_tokens")) {
                        null
                    } else {
                        payload.optInt("total_tokens")
                    },
                )

                else -> null
            }
        }

        "llm_full" -> {
            val sessionId = payload.optNullableString("session_id").orEmpty()
            // `is_error` marks an agentic-loop diagnostic (a retry notice, a
            // TooManyRetries), not a chat turn. It renders as an error card and
            // is never written to the transcript.
            if (payload.optBoolean("is_error", false)) {
                ChatStreamEvent.Failed(
                    payload.optNullableString("content")
                        ?: "The agent reported an error.",
                )
            } else {
                val message = ChatApi.toChatMessage(payload)
                if (message == null || !message.hasVisibleContent) {
                    // Accepting a contentless row used to silently drop every
                    // tool result and image-only echo. Anything with a finish
                    // reason or a tool identity is a real turn.
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
            action = if (frame.event == "queue_queued") "queued" else "deleted",
        )

        else -> null
    }
}
