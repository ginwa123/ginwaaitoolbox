package com.nalar.mobile.chat

/**
 * Finds the `<html>` payloads inside one assistant turn and splits the rest out
 * as prose.
 *
 * **This is the fix for the reported bug.** The phone showed a
 * `web-framework-html-benchmark` turn as a wall of literal
 * `<style>bmw-wrap{font-family:ui-sans-system…`, because nothing ever asked
 * whether the turn was a *document*. The markdown path stripped the
 * `<html>`/`</html>` envelope on its way to `Markdown.parse` and the whole
 * page then parsed as one paragraph of literal text. The web has had this
 * split since 2026-08-23 — `extractHtmlBlocks` in `ChatView.vue` cuts the turn
 * on `<html>…</html>` *before* the markdown renderer ever sees it, and each
 * block goes into a sandboxed iframe. The Android transcript had no
 * equivalent step, so every such turn was a wall of source.
 *
 * Three shapes reach this, and the benchmark turn is the one that needs all
 * three handled:
 *
 *   `<html>…</html>`      the wrapper the model emits; closed, so drawable
 *   ```` ```html ````     a whole-message fence, which is how the model
 *                         *also* hands a document back
 *   `<!doctype html>…`    bare — a fence that came off, or no wrapper at all
 *
 * A whole pure object rather than logic inline in the composable, for the same
 * reason `MessageChrome` is: "is this turn a document, and where do the
 * boundaries sit" is the decision a reviewer keeps asking about, and it is
 * checkable on the JVM in milliseconds rather than only by looking at a
 * device.
 *
 * **A document is only ever emitted once it is finished.** A half-arrived
 * document is [ResponseSegment.Prose], which takes the ordinary markdown path
 * and streams into it. That is a deliberate asymmetry with the web, which
 * swaps a streaming iframe for a sandboxed one: on a phone the WebView is a
 * real `View` with a real JS engine, and reloading it on every appended delta
 * is a re-layout and a re-parse per frame of a streaming answer. Holding the
 * frame back until the turn stops arriving costs nothing the reader can see
 * and removes the only way this change could make the transcript jank.
 */
internal object HtmlResponse {

    /**
     * How many live frames one turn may hold.
     *
     * A `WebView` is a real `View` holding a real renderer, and the
     * transcript is a `LazyColumn` that composes everything inside the
     * viewport. One frame per HTML block is fine for the one block a model
     * emits; a turn carrying ten of them is a page of frames, and the honest
     * fallback for the overflow is the source text, which is what the reader
     * had before this file existed. Blocks past the cap keep their prose
     * segments and simply render as text — see `liveDocuments`.
     */
    const val MAX_LIVE_FRAMES = 3

    /**
     * True when this turn carries at least one finished HTML payload.
     *
     * The cheap reject first: a turn that never opens an html tag cannot be a
     * document, and skipping the split on it is what keeps this affordable on
     * the transcript's hot path — [ChatMessage.hasRenderableContent] asks
     * this for every row of every group, and a group is rebuilt on every
     * streamed delta.
     */
    fun isHtmlTurn(content: String, isComplete: Boolean = true): Boolean {
        val trimmed = content.trim()
        if (trimmed.isEmpty()) return false
        if (!isCandidate(trimmed)) return false
        return segments(trimmed, isComplete).any { it is ResponseSegment.Document }
    }

    /**
     * The turn as an ordered run of prose and documents.
     *
     * Text outside an html block is prose and stays prose, which is what the
     * web does with `seg.before` — an answer that opens with "Here is the
     * page:" and then hands back a document must still show the sentence.
     *
     * Never throws and never returns null. Blank content comes back as an
     * empty list, so a caller iterating it draws nothing rather than a null
     * check at every step.
     */
    fun segments(content: String, isComplete: Boolean = true): List<ResponseSegment> {
        val trimmed = content.trim()
        if (trimmed.isEmpty()) return emptyList()

        // Reasoning is not part of the payload, and a turn that thinks out
        // loud then renders a page carries the `<think>` block *outside* the
        // html wrapper. The web drops it in `stripTags` before splitting.
        val withoutThink = THINK_BLOCK.replace(trimmed, "").trim()
        if (withoutThink.isEmpty()) return emptyList()

        // A whole-message fence, tried first because a fence is the strongest
        // evidence there is: it can only be closed at the end of the turn, so
        // the document inside it is finished by construction and needs none
        // of the heuristics below.
        unfence(withoutThink)?.let { fenced ->
            if (isCandidate(fenced)) {
                return listOf(ResponseSegment.Document(fenced.trim()))
            }
            // A ```markdown fence is prose, not a document. Falling through
            // hands it back to the markdown renderer, which is right.
        }

        val blocks = HTML_BLOCK.findAll(withoutThink).toList()
        if (blocks.isNotEmpty()) {
            val segments = mutableListOf<ResponseSegment>()
            var cursor = 0
            blocks.forEach { match ->
                addProse(segments, withoutThink.substring(cursor, match.range.first))
                val inner = match.groupValues[1].trim()
                if (inner.isNotEmpty()) {
                    // A closed `<html>…</html>` is finished by construction,
                    // exactly like a closed fence.
                    segments += ResponseSegment.Document(inner)
                }
                cursor = match.range.last + 1
            }
            addProse(segments, withoutThink.substring(cursor))
            return segments
        }

        val bare = unwrapPlain(withoutThink)
        if (!isCandidate(bare)) return listOf(ResponseSegment.Prose(withoutThink))

        return if (isDrawableDocument(bare, isComplete)) {
            listOf(ResponseSegment.Document(bare.trim()))
        } else {
            // Still arriving. Prose, so it streams in as text and no frame is
            // rebuilt on every delta.
            listOf(ResponseSegment.Prose(withoutThink))
        }
    }

    /**
     * Whether the [documentIndex]-th document in one turn gets a live frame.
     *
     * A positional rule rather than a `List.contains` against the documents
     * chosen up front, and the difference is not cosmetic: a turn carrying
     * five copies of the *same* document compares equal five times, so an
     * identity-based budget hands out five frames to a turn that was supposed
     * to be capped at three. Counting position is the only thing that counts
     * what a reader would see.
     *
     * Kept as a function rather than a comparison inside the composable's loop
     * so the cap is a thing a test can pin — a budget that lives in a
     * `forEach` is a budget nobody checks, and what it prevents is a reader
     * losing frames to the frame cap rather than to the transcript.
     */
    fun getsLiveFrame(documentIndex: Int): Boolean = documentIndex < MAX_LIVE_FRAMES

    // ── Detection ───────────────────────────────────────────────────────────

    /**
     * The first non-blank line opens a document.
     *
     * A prose answer never starts with a tag, and this single rule is what
     * keeps the heuristic off ordinary messages: a markdown answer that
     * *mentions* `<div>` in the middle of a paragraph has a first line of
     * `Here is how:` and is rejected here before anything expensive runs.
     *
     * `<span`, `<p` and `<h1` are on the list for the same reason they are
     * trouble — a document that opens with one of those and nothing else is
     * still a document, and a fragment the model emitted without a wrapper is
     * exactly the shape worth catching.
     */
    private val DOCUMENT_OPENER = Regex(
        "^\\s*<(?:!doctype\\s+html|html|head|body|style|script|div|section|main|article|" +
            "header|footer|nav|aside|span|p|table|meta|link|template|figure|svg|canvas|" +
            "form|iframe|ul|ol|dl|h[1-6])\\b",
        RegexOption.IGNORE_CASE,
    )

    private fun isCandidate(text: String): Boolean =
        DOCUMENT_OPENER.containsMatchIn(text) ||
            HTML_BLOCK.containsMatchIn(text) ||
            UNFENCED.containsMatchIn(text)

    /**
     * True when [document] is finished.
     *
     * `isComplete` is the answer that is actually true: the turn has stopped
     * arriving. `</body>` and `</html>` are the two fallbacks for a document
     * persisted mid-write, and they are fallbacks rather than the rule because
     * a wrapper-less fragment has neither and would otherwise sit in the
     * transcript as unreadable text for good.
     */
    private fun isDrawableDocument(document: String, isComplete: Boolean): Boolean =
        isComplete ||
            CLOSING_HTML.containsMatchIn(document) ||
            CLOSING_BODY.containsMatchIn(document)

    /**
     * The body of a fence that wraps the *whole* turn, or null.
     *
     * Anchored at both ends, and the language has to be `html` or absent. Both
     * halves matter: a fence anchored at only one end is how a real code
     * block loses its closing marker and the answer renders as a paragraph of
     * shell commands, and a ```markdown fence is prose — a document check that
     * accepted it would turn every markdown answer on the phone into a
     * WebView.
     */
    private fun unfence(text: String): String? {
        val match = WHOLE_FENCE.find(text) ?: return null
        val language = match.groups["lang"]?.value.orEmpty()
        if (language.isNotEmpty() && !language.equals("html", ignoreCase = true)) return null
        return match.groups["body"]?.value
    }

    /** `<plain>…</plain>` off, so a wrapped document is seen bare. */
    private fun unwrapPlain(text: String): String = text
        .replace(PLAIN_OPEN, "")
        .replace(PLAIN_CLOSE, "")
        .trim()

    /**
     * Append a prose run, unless it is only whitespace.
     *
     * The gap between two adjacent documents is exactly this: an empty run
     * that would draw nothing. Filtering it is what makes a turn of three
     * documents three frames rather than five with two invisible spacers.
     */
    private fun addProse(into: MutableList<ResponseSegment>, raw: String) {
        val text = raw.trim()
        if (text.isNotEmpty()) into += ResponseSegment.Prose(text)
    }

    private val THINK_BLOCK = Regex("<think>([\\s\\S]*?)<\\/?think\\s*>", RegexOption.IGNORE_CASE)
    private val HTML_BLOCK =
        Regex("<html(?:\\s[^>]*)?>([\\s\\S]*?)</html\\s*>", RegexOption.IGNORE_CASE)
    private val UNFENCED = Regex("^\\s*<!doctype\\s+html", RegexOption.IGNORE_CASE)
    private val CLOSING_HTML = Regex("</html\\s*>", RegexOption.IGNORE_CASE)
    private val CLOSING_BODY = Regex("</body\\s*>", RegexOption.IGNORE_CASE)
    private val PLAIN_OPEN = Regex("<plain\\s*>", RegexOption.IGNORE_CASE)
    private val PLAIN_CLOSE = Regex("</plain\\s*>", RegexOption.IGNORE_CASE)
    private val WHOLE_FENCE = Regex(
        "^[ \\t]*(?<fence>`{3,}|~{3,})[ \\t]*(?<lang>[A-Za-z0-9_+.-]*)[ \\t]*\\r?\\n" +
            "(?<body>[\\s\\S]*?)\\r?\\n?[ \\t]*\\k<fence>[ \\t]*$",
    )
}

/**
 * One piece of an assistant turn.
 *
 * [Prose] goes to the markdown renderer and [Document] to a live frame, in
 * the order the model wrote them.
 */
internal sealed interface ResponseSegment {

    /** Text the reader reads as prose — everything outside an html block. */
    data class Prose(val text: String) : ResponseSegment

    /**
     * A finished html payload, drawn in a `WebView`.
     *
     * [html] is the document *as the model wrote it*, envelope and fence
     * removed and nothing else changed. No rewriting happens here; the shell
     * that supplies the theme is added later, in [htmlPreviewDocument], where
     * the two cases — a full document and a bare fragment — can be told
     * apart.
     */
    data class Document(val html: String) : ResponseSegment
}

/**
 * The transcript's dark palette, as CSS.
 *
 * A `WebView` loads a separate document with its own null origin, so the
 * Compose colours do not cascade into it and cannot be read from Kotlin. They
 * are therefore written out here, each tied to the token it mirrors in
 * `ui/Color.kt` — the Android values, not the web's, because the frame sits
 * on *this* page's background. A hardcoded white body turned an LLM's HTML
 * report into a bright slab in the middle of a dark transcript.
 */
private object HtmlFramePalette {
    /** `NalarCard` — the surface a frame sits on, so the page has no seam. */
    const val BG = "#1D1C19"

    /** `NalarText`. */
    const val FG = "#c5c9c5"

    /** `NalarMuted` — quotes, captions, de-emphasised meta. */
    const val MUTED = "#a6a69c"

    /** `NalarBorder` — table rules and horizontal rules. */
    const val BORDER = "#393836"

    /** `NalarAccentSoft` — links. */
    const val LINK = "#B7C0D8"

    /** `NalarField` — the chip behind `code`, `pre` and table cells. */
    const val CHIP = "#24221F"

    /** `NalarAqua` — inline `code` ink, matching the markdown renderer. */
    const val CODE_INK = "#8EA4A2"
}

/**
 * No scrollbars inside the frame.
 *
 * The frame is sized to its content by the height reporter, and the
 * transcript's own `LazyColumn` is what scrolls — an inner scrollbar is a
 * second scroll surface the reader has to fight, and it is the reason the web
 * keeps a parallel copy of this rule in `helpers/iframeAutoResize.ts`
 * (`FRAME_NO_SCROLLBAR_STYLE`). Wide `pre` blocks still scroll horizontally;
 * `overflow-x` is left alone.
 */
private const val NO_SCROLLBAR_STYLE =
    "html,body{overflow:hidden!important;scrollbar-width:none!important}" +
        "html::-webkit-scrollbar,body::-webkit-scrollbar{display:none!important}"

/**
 * True when [html] is a whole document rather than a fragment.
 *
 * A whole document is passed through untouched — it brings its own `head`,
 * its own `charset`, its own stylesheet, and rewriting any of that is how a
 * working page stops working. A fragment gets the shell below, because a
 * fragment knows nothing about the theme it is about to be drawn on.
 */
internal fun isFullHtmlDocument(html: String): Boolean =
    Regex("^\\s*(?:<!doctype\\s+html|<html[\\s>])", RegexOption.IGNORE_CASE).containsMatchIn(html)

/**
 * The document handed to the `WebView`.
 *
 * Two cases, the same split the web makes in `buildHtmlSrcdoc`:
 *
 * 1. **A whole document passes through**, with only the no-scrollbar rule and
 *    the height reporter injected. Everything else the model wrote is
 *    left alone.
 * 2. **A fragment is wrapped** in a shell that supplies the three things a
 *    fragment cannot know: the theme above, `color-scheme: dark` (or the
 *    frame's own form controls and scrollbars render light), and the reporter
 *    that tells the transcript how tall the frame is.
 *
 * Text surfaces are forced with `!important`, and that is not politeness. The
 * model authors this HTML blind — it has no idea the transcript is dark — so
 * it writes for a light page. GitHub's light `background:#f6f8fa` on every
 * `<pre>` is a real payload from this project. An inline style beats a
 * stylesheet, which is how the frame's light ink ended up on the payload's
 * own light chip: measured 1.57:1. Forcing the chip *and* the ink keeps every
 * block readable while leaving the rest of the payload's styling — layout,
 * spans, callout colours — exactly as written.
 */
internal fun htmlPreviewDocument(html: String): String {
    val trimmed = html.trim()
    if (isFullHtmlDocument(trimmed)) {
        val shell = "<style>$NO_SCROLLBAR_STYLE</style>"
        val closingBody = Regex("</body\\s*>", RegexOption.IGNORE_CASE)
        if (closingBody.containsMatchIn(trimmed)) {
            return closingBody.replaceFirst(trimmed, "$shell</body>")
        }
        return trimmed + shell
    }
    val p = HtmlFramePalette
    return buildString {
        append("<!DOCTYPE html><html><head><meta charset=\"utf-8\">")
        append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
        append("<style>:root{color-scheme:dark}")
        append("html,body{margin:0;padding:0}")
        append("body{font-family:system-ui,sans-serif;background:${p.BG};color:${p.FG};margin:8px}")
        append("a{color:${p.LINK}}")
        append("img{max-width:100%}")
        append("pre,code,th,td{background:${p.CHIP}!important;color:${p.FG}!important}")
        append("code{font-family:ui-monospace,monospace;padding:.1em .3em;border-radius:3px}")
        append("code{color:${p.CODE_INK}!important}")
        append("pre{font-family:ui-monospace,monospace;padding:.6em .8em;")
        append("border-radius:4px;overflow-x:auto}")
        append("pre code{background:transparent!important;padding:0}")
        append("pre code{color:${p.FG}!important}")
        append("table{border-collapse:collapse}")
        append("th,td{border:1px solid ${p.BORDER};padding:4px 8px}")
        append("hr{border:none;border-top:1px solid ${p.BORDER}}")
        append("blockquote{margin:.6em 0;padding-left:.8em;border-left:3px solid ${p.BORDER};")
        append("color:${p.MUTED}}")
        append(NO_SCROLLBAR_STYLE)
        append("</style></head><body>")
        append(trimmed)
        append("</body></html>")
    }
}

/**
 * The name a frame's page calls in.
 *
 * Shared with the `WebView` that registers the bridge, and pinned by a test
 * rather than left to convention: the reporter is a string template resolved
 * at compile time, so a rename on one side alone would leave a frame that
 * silently never reports a height and therefore sits at its minimum forever.
 */
internal const val HEIGHT_BRIDGE = "NalarHtmlPreview"

/**
 * Append the height reporter to a document.
 *
 * Inside `</body>` when there is one, so the script runs after the page's own
 * markup is parsed and the first measurement is of the finished document
 * rather than of an empty body.
 */
internal fun withHeightReporter(document: String): String {
    val script = "<script>$HEIGHT_REPORTER_SCRIPT</script>"
    val closingBody = Regex("</body\\s*>", RegexOption.IGNORE_CASE)
    return if (closingBody.containsMatchIn(document)) {
        closingBody.replaceFirst(document, "$script</body>")
    } else {
        document + script
    }
}

/**
 * The reporter itself.
 *
 * Reports immediately, on load, on every resize, and once more on two late
 * timers: a page that re-lays itself out from a script or a late-arriving web
 * font is taller than it was at parse time, and a frame sized to its
 * parse-time height clips the bottom of its own content. `ResizeObserver` is
 * guarded because a document is free to be older than it is new.
 */
private val HEIGHT_REPORTER_SCRIPT = """
(function () {
  function report() {
    try {
      var root = document.documentElement;
      var body = document.body;
      var height = Math.max(
        root ? root.scrollHeight : 0,
        root ? root.offsetHeight : 0,
        body ? body.scrollHeight : 0,
        body ? body.offsetHeight : 0
      );
      if (height > 0) $HEIGHT_BRIDGE.reportHeight(Math.ceil(height));
    } catch (e) {}
  }
  report();
  window.addEventListener('load', report);
  if (window.ResizeObserver) {
    try { new ResizeObserver(report).observe(document.documentElement); } catch (e) {}
  }
  setTimeout(report, 250);
  setTimeout(report, 1500);
})();
""".trimIndent()

/**
 * The exact bytes a frame is loaded with: themed shell, then reporter.
 *
 * One function rather than two calls at the one call site, so what the frame
 * receives is a thing a JVM test can assert on whole.
 */
internal fun htmlFrameSource(html: String): String =
    withHeightReporter(htmlPreviewDocument(html))
