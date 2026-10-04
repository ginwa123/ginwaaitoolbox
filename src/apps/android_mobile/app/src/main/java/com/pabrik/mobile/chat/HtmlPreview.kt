package com.pabrik.mobile.chat

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikText
import java.io.ByteArrayInputStream

/**
 * What a turn looks like when it is a document rather than an answer.
 *
 * Prose runs go to the same [MarkdownText] every other paragraph uses, so an
 * answer that opens with a sentence and then hands back a page reads as both.
 * Document runs go to a `WebView` frame — the phone's equivalent of the
 * sandboxed `iframe` in the web's `ChatView.vue`.
 *
 * The split itself lives in [HtmlResponse] as a pure function; nothing here
 * decides what a document *is*.
 */
@Composable
fun HtmlResponseText(
    source: String,
    color: Color = PabrikText,
    modifier: Modifier = Modifier,
    isComplete: Boolean = true,
) {
    val segments = remember(source, isComplete) { HtmlResponse.segments(source, isComplete) }
    if (segments.isEmpty()) return

    // Counted here rather than picked in a list up front, because a turn
    // carrying five copies of the *same* document compares equal five times —
    // position is the only thing that counts what a reader would see.
    var documentsSeen = 0

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag("html_response"),
    ) {
        for (segment in segments) {
            when (segment) {
                is ResponseSegment.Prose -> MarkdownText(
                    source = segment.text,
                    color = color,
                )

                is ResponseSegment.Document ->
                    if (HtmlResponse.getsLiveFrame(documentsSeen++)) {
                        HtmlDocumentFrame(html = segment.html)
                    } else {
                        // Past the frame budget. Its own source, which is
                        // exactly what the reader had before any of this
                        // existed.
                        MarkdownText(source = segment.html, color = color)
                    }
            }
        }
    }
}

/**
 * One rendered document, in a frame the transcript can lay out.
 *
 * **The height is reported, never guessed.** A `WebView` has no intrinsic
 * height — give it one and it fills whatever it is given, give it none and it
 * is invisible — so a `WebView` inside a `LazyColumn` is unmeasurable unless
 * the document itself says how tall it is. The script appended to every frame
 * posts `documentElement.scrollHeight` back through a `@JavascriptInterface`
 * hook, and this composable sizes the `AndroidView` to it. Until the first
 * report lands the frame holds [MIN_FRAME_HEIGHT] rather than zero, because a
 * frame that is briefly invisible looks like a document that failed to load.
 *
 * The height is keyed on the document, not on the composable: a second
 * document in the same turn must not inherit the first one's measurement, and
 * `LazyColumn` re-runs this for a recycled row whose document has not changed.
 *
 * No cap and no inner scroller, on purpose. The transcript owns scrolling. A
 * clipped frame hides the bottom of a page behind a nested surface the reader
 * has to discover, which is the same complaint the web fixed by growing each
 * frame to its full content height.
 */
@Composable
private fun HtmlDocumentFrame(html: String, modifier: Modifier = Modifier) {
    var heightPx by remember(html) { mutableIntStateOf(0) }

    // The *state* is captured, not the value inside it. `rememberUpdatedState`
    // hands back a stable `State` whose value is a fresh lambda every
    // recomposition, so keying the holder on that value would tear the
    // WebView down and build a new one on every recomposition of a streaming
    // transcript — the exact per-delta cost the "wait for the finished
    // document" rule in [HtmlResponse] exists to avoid.
    val onHeight = rememberUpdatedState<(Int) -> Unit>({ px -> heightPx = px })
    val context = LocalContext.current
    val holder = remember(context) {
        HtmlFrameHolder(context) { px -> onHeight.value(px) }
    }

    DisposableEffect(holder) {
        onDispose { holder.destroy() }
    }

    val frameHeight = with(LocalDensity.current) { heightPx.toDp() }
        .coerceAtLeast(MIN_FRAME_HEIGHT)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = 6.dp, bottom = 10.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(PabrikField)
            .border(1.dp, PabrikBorder, RoundedCornerShape(8.dp)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "HTML preview",
                color = PabrikDim,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
        AndroidView(
            modifier = Modifier
                .fillMaxWidth()
                .height(frameHeight)
                .testTag("chat_html_frame"),
            factory = { holder.webView },
            update = { holder.load(html) },
        )
    }
}

/**
 * A `WebView`, its configuration, and the single document it has loaded.
 *
 * The loaded source is remembered here rather than compared in `AndroidView`'s
 * `update` block because `update` runs on *every* recomposition, and
 * `loadDataWithBaseURL` tears the document down and builds a new one. An
 * unguarded call re-parses the page — and flashes it to blank — on every frame
 * of every recomposition, which in a streaming transcript is every delta.
 * Comparing the source makes the load happen once per document.
 */
private class HtmlFrameHolder(context: Context, onHeight: (Int) -> Unit) {

    val webView: WebView = WebView(context).apply {
        configureForPreview()
        addJavascriptInterface(HeightReporter(onHeight), HEIGHT_BRIDGE)
    }

    private var loaded: String? = null

    fun load(html: String) {
        if (loaded == html) return
        loaded = html
        webView.loadDataWithBaseURL(
            null,
            htmlFrameSource(html),
            "text/html",
            "utf-8",
            null,
        )
    }

    fun destroy() {
        webView.removeJavascriptInterface(HEIGHT_BRIDGE)
        webView.stopLoading()
        // `destroy()` on a WebView that is still loading is how a recycled
        // frame's page keeps running against a dead renderer; blanking it
        // first is the order `WebView`'s own docs ask for.
        webView.loadUrl("about:blank")
        webView.destroy()
    }
}

/**
 * The JS bridge the frame's reporter calls into.
 *
 * Two details are load-bearing. `Math.ceil`, because a fractional
 * `scrollHeight` truncated down to a dp is a document whose last line is cut
 * off. And a `post` to the main thread: a `WebView` invokes
 * `@JavascriptInterface` methods on its own private "JavaBridge" thread, and
 * writing Compose state from there throws rather than working by luck.
 */
private class HeightReporter(private val onHeight: (Int) -> Unit) {

    private val main = Handler(Looper.getMainLooper())

    @JavascriptInterface
    fun reportHeight(px: Int) {
        if (px <= 0) return
        main.post { onHeight(px.coerceAtMost(MAX_FRAME_HEIGHT_PX)) }
    }
}

/**
 * Configure a `WebView` that is about to be handed model-authored HTML.
 *
 * The threat model is worth stating plainly: this HTML is written by an LLM
 * that was asked to produce a page, so it is untrusted input that is
 * *expected* to be executed. JavaScript therefore stays on — it is what
 * reports the height, and a great deal of what the model produces is not a
 * page without it — and everything the script could reach is taken away
 * instead:
 *
 *  - **No network.** Every scheme other than `data:` and `about:` is answered
 *    with an empty body by [PreviewWebViewClient], so the document cannot
 *    phone home, cannot pull a tracking pixel, and cannot see a cookie the
 *    app's session carries. The app's own HTTP lives on a separate client;
 *    nothing is shared with this one.
 *  - **No filesystem.** `allowFileAccess` and `allowContentAccess` off, plus
 *    the two legacy `…FromFileURLs` flags, so there is no path from the
 *    document to app storage.
 *  - **No navigation.** `shouldOverrideUrlLoading` returns true for
 *    everything, so a link tap cannot replace the transcript with another
 *    page or hand the document to an external app.
 *  - **No storage, no location, no new windows, no debugging.**
 *
 * What is deliberately *not* done is stripping the model's own `<style>` and
 * `<script>`. The point of the frame is to show the page the model wrote;
 * sanitising it into a mangled approximation is a different product, and the
 * boundaries above are the ones that matter.
 */
@SuppressLint("SetJavaScriptEnabled")
private fun WebView.configureForPreview() {
    settings.apply {
        javaScriptEnabled = true
        domStorageEnabled = false
        javaScriptCanOpenWindowsAutomatically = false
        setSupportMultipleWindows(false)
        setGeolocationEnabled(false)
        allowFileAccess = false
        allowContentAccess = false
        @Suppress("DEPRECATION")
        allowFileAccessFromFileURLs = false
        @Suppress("DEPRECATION")
        allowUniversalAccessFromFileURLs = false
        mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        cacheMode = WebSettings.LOAD_NO_CACHE
        mediaPlaybackRequiresUserGesture = true
    }
    isVerticalScrollBarEnabled = false
    isHorizontalScrollBarEnabled = false
    overScrollMode = View.OVER_SCROLL_NEVER
    isLongClickable = false
    // The transcript is not the only focusable thing on the screen: the
    // composer sits a row or two below, and a `WebView` that takes focus on
    // tap pops the keyboard over the page the reader just opened. Focus is
    // taken off the frame entirely — horizontal scrolling inside a wide `pre`
    // is touch, not focus, so nothing inside the page is lost by it.
    isFocusable = false
    isFocusableInTouchMode = false
    webViewClient = PreviewWebViewClient()
}

/**
 * A client that lets the document exist and nothing else.
 *
 * `shouldInterceptRequest` is the boundary. It is consulted for every
 * subresource, so a `<img src="https://…">` and a `fetch()` are both answered
 * here, and an empty body is the strongest answer available — the document's
 * own error handling never sees a status it could retry.
 */
private class PreviewWebViewClient : WebViewClient() {

    override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
    ): WebResourceResponse? {
        val scheme = request.url?.scheme?.lowercase() ?: return BLOCKED
        return if (scheme == "data" || scheme == "about") null else BLOCKED
    }

    override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
    ): Boolean = true

    private companion object {
        val BLOCKED = WebResourceResponse(
            "text/plain",
            "utf-8",
            ByteArrayInputStream(ByteArray(0)),
        )
    }
}

/** Tall enough to read a heading into; short enough not to be a blank slab. */
private val MIN_FRAME_HEIGHT = 160.dp

/**
 * A ceiling on what one report may move the frame by, in pixels.
 *
 * Not a cap on the document — a cap on a single measurement. A page whose own
 * script reports nonsense, or a document that mounts tens of thousands of
 * nodes, would otherwise hand a `LazyColumn` an unbounded row and take the
 * whole transcript down with it. Far above any real page, so it never binds on
 * one.
 */
private const val MAX_FRAME_HEIGHT_PX = 200_000
