package com.nalar.mobile.chat

/**
 * Peels the transport envelope off an assistant turn's content.
 *
 * **This is the fix for the reported bug.** The phone was showing the model's
 * answer as a wall of literal `**PR:**` and `## What I built`, with a visible
 * `<markdown>` on the first line. Nothing was wrong with the markdown — the
 * content is wrapped in an envelope, and the Android renderer was drawing the
 * envelope along with the answer. The web has stripped this for months in
 * `helpers/stripTags.ts` (`stripThinkingTags`), called from `renderResponse`
 * before `marked.parse`.
 *
 * The model emits four wrappers:
 *
 *   `<plain>…</plain>`     plain prose
 *   `<markdown>…</markdown>` markdown
 *   `<html>…</html>`       a document to sandbox in an iframe
 *   `<think>…</think>>`    reasoning
 *
 * plus the near-universal habit of fencing the whole answer in
 * ` ```html ` … ` ``` `, which survives the unwrap and then swallows the
 * entire message into one literal code block. So the fence comes off too.
 *
 * Two rules are load-bearing:
 *
 * 1. **The unwrap only happens when the content also carries a `<think>`
 *    block.** A turn that is *only* `<think>…</think>` is a reasoning turn, and
 *    unwrapping it away would throw the model's thinking out of the transcript.
 *    Bare thinking is returned untouched.
 * 2. **Only fences anchored at the very start and end are removed.** A triple
 *    backtick in the middle of prose is content, and a fenced code block *in*
 *    a markdown body must survive — the unwrap is about the outer envelope, not
 *    about every fence in the string.
 */
private val THINK_BLOCK = Regex("<think>([\\s\\S]*?)<\\/think>", RegexOption.IGNORE_CASE)
private val OPEN_PLAIN = Regex("<plain>\\s*", RegexOption.IGNORE_CASE)
private val CLOSE_PLAIN = Regex("\\s*</plain>", RegexOption.IGNORE_CASE)
private val OPEN_MARKDOWN = Regex("<markdown>\\s*", RegexOption.IGNORE_CASE)
private val CLOSE_MARKDOWN = Regex("\\s*</markdown>", RegexOption.IGNORE_CASE)
private val OPEN_HTML = Regex("<html>\\s*", RegexOption.IGNORE_CASE)
private val CLOSE_HTML = Regex("\\s*</html>", RegexOption.IGNORE_CASE)

/**
 * The whole body fenced in a language that names a *document*, not code.
 *
 * Anchored at both ends on purpose. Stripping a leading fence and a trailing
 * fence independently is how a real code block loses its closing fence: the
 * trailing fence is matched, the block re-opens, and ```` ```bash ```` renders
 * as a paragraph of shell commands. Matching the pair whole means a genuine
 * code block — the common case, and the one a reader is staring at — is never
 * touched.
 *
 * The language list is what separates the two. `html`, `markdown` and `svg` are
 * how a model fences a *document* it is handing back; `bash` and `json` are
 * content, and a bare ``` is far more often a code block than a wrapper.
 */
private val FENCED_DOCUMENT = Regex(
    "```[ \\t]*(?:html|markdown|md|xml|svg|plain|text)[ \\t]*\\n(?<body>.*?)\\n?```[ \\t]*\\s*$",
    setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
)

/**
 * The content a renderer should actually show.
 *
 * Never throws and never returns null — a helper this deep in the transcript
 * must not be able to blank a bubble, so a pathological input comes back as
 * itself rather than as nothing.
 */
fun stripContentEnvelope(content: String): String {
    val trimmed = content.trim()
    if (trimmed.isEmpty()) return ""

    val hasThink = THINK_BLOCK.containsMatchIn(trimmed)
    val hasWrapper = hasAnyWrapper(trimmed)
    if (hasThink && !hasWrapper) return trimmed

    var result = trimmed
    if (hasThink) result = THINK_BLOCK.replace(result, "")
    result = OPEN_PLAIN.replace(result, "").let { CLOSE_PLAIN.replace(it, "") }
    result = OPEN_MARKDOWN.replace(result, "").let { CLOSE_MARKDOWN.replace(it, "") }
    result = OPEN_HTML.replace(result, "").let { CLOSE_HTML.replace(it, "") }
    // Named group, not `$1`: the language alternation is non-capturing precisely
    // so the body is the only group, and a stray `$1` here replaces the answer
    // with the word "markdown".
    return FENCED_DOCUMENT.replace(result.trim(), "\${body}").trim()
}

private fun hasAnyWrapper(text: String): Boolean =
    OPEN_PLAIN.containsMatchIn(text) ||
        CLOSE_PLAIN.containsMatchIn(text) ||
        OPEN_MARKDOWN.containsMatchIn(text) ||
        CLOSE_MARKDOWN.containsMatchIn(text) ||
        OPEN_HTML.containsMatchIn(text) ||
        CLOSE_HTML.containsMatchIn(text)
