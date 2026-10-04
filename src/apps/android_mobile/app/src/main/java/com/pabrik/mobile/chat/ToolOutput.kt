package com.pabrik.mobile.chat

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * `JSONObject` accessors that treat an explicit null, an absent key and a wrong
 * type the same way.
 *
 * `optString` is unusable for a wire this optional: it renders an explicit null
 * as the four-character text `"null"`, so every `?T = null` field the backend
 * emits — and the shell tool sets nearly all of them — would arrive looking like
 * a real value. The web's parser has the same problem and solves it with
 * `strField` / `strOrNullField` / `numOrNullField` / `boolField`; these are the
 * same four, for the same reason.
 */
internal fun JSONObject.stringOrNull(key: String): String? {
    if (isNull(key)) return null
    return when (val value = opt(key)) {
        is String -> value.takeIf { it.isNotEmpty() }
        is Number, is Boolean -> value.toString()
        else -> null
    }
}

internal fun JSONObject.string(key: String): String = stringOrNull(key).orEmpty()

internal fun JSONObject.intOrNull(key: String): Int? {
    if (isNull(key)) return null
    return when (val value = opt(key)) {
        is Number -> value.toInt()
        is String -> value.trim().toIntOrNull()
        is Boolean -> if (value) 1 else 0
        else -> null
    }
}

internal fun JSONObject.boolOr(key: String, fallback: Boolean): Boolean {
    if (isNull(key)) return fallback
    return when (val value = opt(key)) {
        is Boolean -> value
        is String -> when (value.trim().lowercase()) {
            "true", "1" -> true
            "false", "0" -> false
            else -> fallback
        }
        is Number -> value.toInt() != 0
        else -> fallback
    }
}

internal fun JSONObject.objectOrNull(key: String): JSONObject? =
    if (isNull(key)) null else optJSONObject(key)

internal fun JSONObject.arrayOrEmpty(key: String): JSONArray =
    if (isNull(key)) JSONArray() else optJSONArray(key) ?: JSONArray()

/** Each element of a JSON array, skipping anything that is not an object. */
internal inline fun <T> JSONArray.mapObjects(transform: (JSONObject) -> T): List<T> {
    val out = ArrayList<T>(length())
    for (index in 0 until length()) {
        val item = optJSONObject(index) ?: continue
        out.add(transform(item))
    }
    return out
}

/** Each element of a JSON array as a plain string, skipping the rest. */
internal fun JSONArray.stringList(): List<String> {
    val out = ArrayList<String>(length())
    for (index in 0 until length()) {
        val item = opt(index)
        if (item is String && item.isNotEmpty()) out.add(item)
    }
    return out
}

/**
 * A byte count, which is a `u64` on the wire and therefore arrives as a
 * `Double` through `org.json`. A file larger than 2^53 bytes is not a thing, so
 * a lossy conversion here is exact in practice; the null and non-numeric cases
 * are not, and are what this actually guards.
 */
internal fun Any?.toLongOrZero(): Long = when (this) {
    is Number -> toLong()
    is String -> trim().toLongOrNull() ?: 0L
    else -> 0L
}

/**
 * A parsed tool-result envelope.
 *
 * The wire shape is fixed by the backend (`agentic_loop/tools_wrap_output.zig`):
 *
 * ```json
 * {"tool":"read_file","parameters":{"path":"/x"},"success":true,
 *  "data":{"path":"/x","content":"…"},"error":null,"v":1}
 * ```
 *
 * [parametersJson] is a *string* because that is what the shared "Arguments"
 * block renders; the backend sends an object, so it is re-serialised here
 * exactly as `unwrapToolOutput.ts` does.
 */
data class ToolEnvelope(
    val name: String,
    val parametersJson: String,
    val success: Boolean,
    val error: String?,
    val data: JSONObject?,
) {
    /**
     * The backend emits a placeholder row with `success: true, data: null` the
     * instant the model asks for a tool, then re-emits the *same row id* with
     * real data when the tool finishes. `data: null` on a success is therefore
     * the only in-flight signal on the wire — `llm_history.is_loading` exists in
     * the database but no SSE struct exposes it.
     */
    val isPending: Boolean get() = success && data == null

    /**
     * `{"_raw": "<original>"}`. `normalizeDataFragment` rewrites any payload
     * whose top level is not an object this way, and `remove_file` still emits
     * XML, so this is a shape the client genuinely meets rather than a
     * theoretical one.
     */
    val rawPayload: String? get() = data?.stringOrNull("_raw")
}

/**
 * Envelope parsing, plus the pretty-printer for the Arguments block.
 *
 * No Android and no Compose in here on purpose: this is the layer where a wire
 * misunderstanding shows up as a blank card, so the unit tests drive it
 * directly rather than through a screenshot.
 */
object ToolOutput {
    /** The only schema version the backend emits. */
    const val ENVELOPE_VERSION = 1

    /**
     * Parses an envelope, or returns null when the content is not one.
     *
     * Null is the load-bearing case, not the exception: `mcp_*` tools bypass the
     * envelope entirely on success and store the server's raw text, a tool
     * interrupted by a server restart is rewritten to a legacy XML string, and a
     * blank placeholder is not JSON at all. All three have to render *something*,
     * so an unparseable row falls back to its raw text rather than disappearing.
     */
    fun tryUnwrap(content: String?): ToolEnvelope? {
        val trimmed = content?.trim().orEmpty()
        if (!trimmed.startsWith("{")) return null
        val envelope = try {
            JSONObject(trimmed)
        } catch (_: Throwable) {
            // `Throwable`, not `Exception`: `JSONObject` parses lazily, so the
            // stack blow-up happens later — inside `reStringifyParameters`'s
            // `toString`, on a deeply nested `parameters` blob. That is an
            // `Error`, and every `catch (Exception)` here would let it through
            // and take the app down on a tool the model chose to shape.
            return null
        }

        val tool = envelope.stringOrNull("tool") ?: return null
        if (tool.isBlank()) return null
        if (!envelope.has("success") || envelope.isNull("success")) return null
        if (!envelope.has("parameters")) return null

        // The version is checked, not merely documented. An unknown `v` means
        // the payload's *meaning* may have changed, and rendering it with v1
        // rules produces a confident, wrong card — the same failure a strict
        // parser is meant to prevent. Refusing it falls back to raw text, which
        // is at least honest.
        val version = envelope.intOrNull("v") ?: return null
        if (version != ENVELOPE_VERSION) return null

        val success = envelope.boolOr("success", fallback = false)
        return ToolEnvelope(
            name = tool,
            parametersJson = reStringifyParameters(envelope.opt("parameters")),
            success = success,
            // `success` and `error` are mutually exclusive on the wire, so a
            // success never has one. A failure with no message still needs
            // something to show.
            error = if (success) {
                null
            } else {
                envelope.stringOrNull("error") ?: "tool failed"
            },
            data = if (success) envelope.objectOrNull("data") else null,
        )
    }

    /**
     * `parameters` is an object on the wire, so it is re-serialised for the
     * Arguments block. A malformed payload reaches us as `{"_raw": …}`, which is
     * already an object, so there is no second fallback to write.
     */
    private fun reStringifyParameters(raw: Any?): String = try {
        when (raw) {
            null -> "{}"
            is String -> raw
            is JSONObject -> raw.toString()
            else -> JSONObject().put("_raw", raw).toString()
        }
    } catch (_: Throwable) {
        // Same reasoning as the parse above: serialising an arbitrarily nested
        // object is a recursive walk, and the arguments are model-authored.
        // An unprintable argument set degrades to no arguments, never to a crash.
        "{}"
    }

    /** A readable body for a payload this client has no specific renderer for. */
    fun fallbackBodyText(data: JSONObject?): String = when {
        data == null -> ""
        else -> JsonPretty.pretty(data.toString())
    }
}

/**
 * `JSON.stringify(value, null, 2)`.
 *
 * Hand-rolled rather than `JSONObject.toString(2)` because the built-in renders
 * an empty object as `{ }`, and the Arguments block hides itself on the literal
 * string `"{}"` — so the built-in would show an Arguments section for every tool
 * that takes no arguments.
 */
object JsonPretty {
    /**
     * Nesting past this renders as the original text rather than as an outline.
     *
     * The argument blob is the model's own tool call, so its depth is
     * attacker-influenced, and `render` is recursive: a few thousand levels is
     * enough to overflow the stack. Every `catch (Exception)` around this
     * misses that, because `StackOverflowError` is an `Error`. Refusing to
     * descend past the cap is the one failure mode this function can have that
     * does not end in a crash.
     */
    const val MAX_DEPTH = 32

    fun pretty(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return raw
        if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return raw
        val parsed = try {
            org.json.JSONTokener(trimmed).nextValue()
        } catch (_: Throwable) {
            return raw
        }
        return render(parsed, 0, StringBuilder(), raw).toString()
    }

    private fun render(
        value: Any?,
        depth: Int,
        out: StringBuilder,
        fallback: String,
    ): String {
        // Past the cap the value is spliced in *raw*, so the reader still sees
        // the top of the structure and the whole deep payload is preserved —
        // just not outlined. Returning the document whole from here is not
        // possible, because `render` is already mid-way through building it.
        if (depth > MAX_DEPTH) return fallback
        return when (value) {
            null, JSONObject.NULL -> out.append("null").toString()
            is JSONObject -> {
                if (value.length() == 0) return out.append("{}").toString()
                out.append("{\n")
                val keys = value.keys()
                var first = true
                while (keys.hasNext()) {
                    val key = keys.next()
                    if (!first) out.append(",\n")
                    first = false
                    out.append(INDENT.repeat(depth + 1))
                    quote(key, out)
                    out.append(": ")
                    render(value.opt(key), depth + 1, out, fallback)
                }
                out.append('\n').append(INDENT.repeat(depth)).append('}')
                out.toString()
            }

            is JSONArray -> {
                if (value.length() == 0) return out.append("[]").toString()
                out.append("[\n")
                for (index in 0 until value.length()) {
                    if (index > 0) out.append(",\n")
                    out.append(INDENT.repeat(depth + 1))
                    render(value.opt(index), depth + 1, out, fallback)
                }
                out.append('\n').append(INDENT.repeat(depth)).append(']')
                out.toString()
            }

            is String -> quote(value, out).toString()
            is Number, is Boolean -> out.append(value.toString()).toString()
            // org.json also hands back a Map for a JSONTokener-constructed
            // document; serialising it whole beats dropping it.
            else -> quote(value.toString(), out).toString()
        }
    }

    private fun quote(value: String, out: StringBuilder) {
        out.append('"')
        value.forEach { char ->
            when (char) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '' -> out.append("\\f")
                else -> if (char < ' ') {
                    // `Locale.ROOT` is load-bearing: Java's formatter takes the
                    // zero digit from the locale's numbering system, so under
                    // `th-TH-u-nu-thai` this emits `\u0` followed by a Thai digit
                    // and the Arguments block stops being valid JSON.
                    out.append(String.format(Locale.ROOT, "\\u%04x", char.code))
                } else {
                    out.append(char)
                }
            }
        }
        out.append('"')
    }

    private const val INDENT = "  "
}

/**
 * One tool call declared by an assistant turn.
 *
 * `tool_calls_json` is a JSON *string* holding an OpenAI-style array, and each
 * element's `arguments` is itself a JSON string — so it is parsed twice. The
 * backend serialises it that way deliberately: an array on the wire crashed
 * every live assistant row that carried tool calls
 * (`msg.tool_calls_json?.trim is not a function`).
 */
data class ToolCallEntry(
    val id: String,
    val name: String,
    val argumentsJson: String,
) {
    /** The one-line form used in the collapsed pill. */
    val summary: String
        get() = argumentsJson
            .takeIf { it.isNotBlank() && it != "{}" }
            ?.let { JsonPretty.pretty(it).replace('\n', ' ') }
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: ""
}

/** The `tool_calls_json` of an assistant turn, parsed. */
object ToolCalls {
    fun parse(raw: String?): List<ToolCallEntry> {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty() || !trimmed.startsWith("[")) return emptyList()
        val array = try {
            JSONArray(trimmed)
        } catch (_: Exception) {
            return emptyList()
        }
        return array.mapObjects { call ->
            val function = call.objectOrNull("function")
            ToolCallEntry(
                id = call.string("id"),
                name = function?.string("name").orEmpty().ifEmpty { call.string("name") },
                argumentsJson = function?.string("arguments").orEmpty()
                    .ifEmpty { call.string("arguments") },
            )
        }
    }
}
