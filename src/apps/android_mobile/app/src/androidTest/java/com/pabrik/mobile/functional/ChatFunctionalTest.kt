package com.pabrik.mobile.functional

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.SemanticsNodeInteractionCollection
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.pabrik.mobile.BuildConfig
import com.pabrik.mobile.MainActivity
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runner.RunWith

/**
 * The phone, rendering rows it did not invent.
 *
 * This is the layer nothing else in the module covers. The 1019 JVM tests decide
 * what a renderer should do with a shape — `ToolOutput` decoding a shell
 * envelope, `Markdown` splitting a fenced block, `HtmlResponse` segmenting a
 * document — and they build that shape by hand, in Kotlin. The 154 instrumented
 * tests drive real Compose on a real device, but every one of them also hands
 * the composable hand-built data. So "a real server wrote this row and the phone
 * drew it" was the one cell with nobody in it, and these ten scenarios fill it:
 * a real `pabrik` binary, an isolated tmpdir HOME, rows seeded straight into that
 * instance's own `agent.db`, and the real `MainActivity` — real ViewModels, real
 * network, real `NavHost` — pointed at it.
 *
 * ### The app, not a composable
 *
 * `createEmptyComposeRule` rather than `createAndroidComposeRule<MainActivity>`:
 * the rule variant launches the Activity with no intent, and the only way into a
 * *specific* seeded chat is a deep link. The drawer cannot be used — its list is
 * scoped to a workspace (`RecentsApi.chatsPath` always sends a `workspace_id`)
 * and seeded sessions have none, so the server fails closed and the drawer is
 * empty by design. So each test launches `MainActivity` itself, with
 * `pabrik://chat/<session>`, and the Compose rule attaches to whatever
 * composition that produces.
 *
 * ### Ordering
 *
 * `ClearAppStateRule` is chained *outer*, so it runs before the Activity is
 * launched. It has to: `PabrikNavGraph` reads the saved position on launch and
 * navigates to the chat it names, so a leftover position would take a test
 * somewhere other than the deep link it asked for.
 *
 * ### Assertions are on tags, never on text
 *
 * An assertion on a test tag is built from an id, and `drift_test.py` proves
 * both sides agree on the ids. Asserting on rendered *text* would pin the
 * renderer's decisions in a second place, and those already have a fast home.
 * What is asserted here is the thing only this suite can see: the row arrived,
 * reached the tree, and produced the node it should have.
 */
@RunWith(AndroidJUnit4::class)
class ChatFunctionalTest {

    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext

    private val composeRule: ComposeTestRule = createEmptyComposeRule()

    @get:Rule
    val chain: TestRule = RuleChain.outerRule(ClearAppStateRule(context)).around(composeRule)

    private var launched: ActivityScenario<MainActivity>? = null

    /**
     * Refuse to run against anything but a local server.
     *
     * The point of this suite is that a *harness* wrote the rows. Run it against
     * the production host and the seeded sessions do not exist, so every test
     * fails for a reason that has nothing to do with the app — and, worse, a
     * silent pass is impossible to distinguish from a real one if the deep link
     * ever landed on a cached chat. Failing here with the actual base URL says
     * which `-PpabrikBaseUrl` was forgotten.
     */
    @Before
    fun requireALocalServer() {
        val base = BuildConfig.API_BASE_URL
        assertTrue(
            "this suite must run against a local pabrik, but the APK was built " +
                "with API_BASE_URL=$base — pass " +
                "-PpabrikBaseUrl=http://10.0.2.2:<port> to Gradle",
            base.startsWith("http://"),
        )
    }

    @After
    fun closeTheApp() {
        launched?.close()
        launched = null
    }

    // ─── the scenarios ─────────────────────────────────────────────────────

    @Test
    fun empty() {
        open(FunctionalScenario.EMPTY)

        assertPresent("chat_empty")
    }

    @Test
    fun exchange() {
        open(FunctionalScenario.EXCHANGE)

        assertPresent("chat_message_${FunctionalScenario.EXCHANGE_USER}")
        assertPresent("chat_message_${FunctionalScenario.EXCHANGE_ASSISTANT}")
    }

    @Test
    fun multiturn() {
        open(FunctionalScenario.MULTITURN)

        // The tail, not the head: the list is virtualized, and the transcript
        // scrolls to the newest turn, so the first exchange is legitimately not
        // composed. Asserting on it would be asserting against virtualization.
        assertPresent("chat_message_${FunctionalScenario.MULTITURN_IDS.last()}")
        assertTrue(
            "the transcript composed no assistant group at all",
            nodes("chat_group_assistant").fetchSemanticsNodes().isNotEmpty(),
        )
    }

    @Test
    fun toolcalls() {
        open(FunctionalScenario.TOOL_CALLS)

        // `chat_tool_<id>` names the card for a tool *result*. An assistant row
        // that called a tool and never got an answer renders the collapsed
        // summary instead, keyed by the group's first message id — which is
        // the assistant row itself. Asserting the result card here was this
        // test's first mistake, and the device said so.
        assertPresent("chat_tool_calls_${FunctionalScenario.TOOL_CALLS_ASSISTANT}")
    }

    @Test
    fun toolresult() {
        open(FunctionalScenario.TOOL_RESULT)

        assertPresent("chat_tool_${FunctionalScenario.TOOL_RESULT_TOOL}")
        // Collapsed by default, so the tool's *name* is the part that is always
        // on screen. The stdout lives behind the expand affordance.
        assertPresent("tool_card_name")
    }

    @Test
    fun markdown() {
        open(FunctionalScenario.MARKDOWN)

        // A fenced block has to have been recognised as one; if `Markdown` fell
        // back to plain paragraphs this tag would not exist.
        assertPresent("markdown_code")
    }

    @Test
    fun images() {
        open(FunctionalScenario.IMAGES)

        assertPresent("chat_message_${FunctionalScenario.IMAGES_USER}")
        assertPresent("chat_attachments")
    }

    @Test
    fun reasoning() {
        open(FunctionalScenario.REASONING)

        assertPresent("chat_reasoning_${FunctionalScenario.REASONING_ASSISTANT}")
    }

    @Test
    fun html() {
        open(FunctionalScenario.HTML)

        // The scenario with no JVM equivalent at all: `HtmlPreview` takes its
        // height from a script running inside a real `WebView`, and
        // Robolectric's `WebView` is a shadow that never runs one.
        //
        // `chat_html_frame` rather than `html_response`: the frame is what the
        // document was actually drawn into, and it is the node whose height
        // depends on that script having run. `markdown_p` being present too is
        // the other half of the contract — the real payload is prose *then* a
        // document, and the segmenter has to split it.
        assertPresent("chat_html_frame")
        assertPresent("markdown_p")
    }

    @Test
    fun presentfiles() {
        open(FunctionalScenario.PRESENT_FILES)

        // `chat_tool_<id>` names the card for the tool *result* row, and the
        // result here is the `present_files` envelope.
        assertPresent("chat_tool_${FunctionalScenario.PRESENT_FILES_TOOL}")
        assertPresent("tool_card_name")

        // KNOWN GAP, and it is a gap in this test rather than in the app.
        //
        // The file rows live in the card's body, which starts collapsed — that
        // is deliberate production behaviour, and the collapsed card is what is
        // asserted above. Expanding it needs the card's own toggle, and
        // `performClick()` on `tool_card_chevron` does not reach it: a device run
        // with the click in place still composed no body at all (neither
        // `present_file_row` nor even `present_file_loading` appeared in the
        // unmerged tree). The clickable is an ancestor, so the fix is to find the
        // node that carries the click action rather than the chevron inside it.
        //
        // Left as a gap rather than papered over, because the assertion that
        // matters here is what the *body* does: those rows are the only path
        // through `HttpsBinaryExchange`, which has its own copy of the connection
        // policy, and a file download that disagreed with the API calls about
        // plain HTTP would be invisible everywhere else.
    }

    // ─── finding nodes ─────────────────────────────────────────────────────

    /**
     * Every lookup goes through the **unmerged** tree.
     *
     * `onNodeWithTag` searches the merged tree by default, and a `testTag` on a
     * node that Compose merges into an ancestor is then invisible — the first
     * device run failed four scenarios with the tag plainly present
     * ("the unmerged tree contains '1' node that matches"). Merging is a
     * *semantics* convenience for accessibility; it has nothing to do with
     * whether the renderer produced the node, which is the only question here.
     * The unmerged tree is a superset, so this cannot hide a node that the
     * merged tree would have found.
     */
    private fun node(tag: String): SemanticsNodeInteraction =
        composeRule.onNodeWithTag(tag, useUnmergedTree = true)

    private fun nodes(tag: String): SemanticsNodeInteractionCollection =
        composeRule.onAllNodesWithTag(tag, useUnmergedTree = true)

    /**
     * Asserts a tag reached the tree, and lists what did when it did not.
     *
     * A bare `assertExists` on a transcript says "no node with this tag",
     * which is indistinguishable between the renderer picking a different
     * node for this shape and the renderer not drawing the shape at all.
     * The two need opposite fixes, so the failure carries the answer.
     */
    private fun assertPresent(tag: String, timeoutMillis: Long = TAG_TIMEOUT_MILLIS) {
        try {
            composeRule.waitUntil(timeoutMillis) {
                nodes(tag).fetchSemanticsNodes().isNotEmpty()
            }
        } catch (timedOut: Throwable) {
            throw AssertionError(
                "no node with testTag '$tag' after ${timeoutMillis}ms. " +
                    "Tags present: ${renderedTags()}",
                timedOut,
            )
        }
    }

    private fun renderedTags(): List<String> =
        composeRule.onAllNodes(SemanticsMatcher("every node") { true }, useUnmergedTree = true)
            .fetchSemanticsNodes()
            .mapNotNull { it.config.getOrNull(SemanticsProperties.TestTag) }
            .sorted()

    // ─── driving the app ───────────────────────────────────────────────────

    /**
     * Launches the app on one seeded chat.
     *
     * The explicit component is not redundant with the deep link: `pabrik://chat`
     * is also claimed by the manifest's VIEW filter, and an implicit intent
     * would leave the target to the resolver. Naming `MainActivity` makes this
     * the launch path rather than a chooser.
     */
    private fun open(sessionId: String) {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("pabrik://chat/$sessionId"))
            .setClassName(context, MainActivity::class.java.name)

        launched = ActivityScenario.launch(intent)
        awaitTranscript()
    }

    /**
     * Waits for the transcript, and says what it saw when it never arrives.
     *
     * A bare timeout here is the worst failure in this file: "the chat did not
     * open" is consistent with a broken deep link, a launch gate that never
     * opened, a request that went to the wrong host, and a seeded session the
     * server does not have. So the wait reports which of those it can rule out.
     */
    private fun awaitTranscript() {
        composeRule.waitUntil(timeoutMillis = TRANSCRIPT_TIMEOUT_MILLIS) {
            nodes("chat_message_list").fetchSemanticsNodes().isNotEmpty()
        }

        assertTrue(
            "the launch gate is still on screen after waiting for the transcript — " +
                "the app never reached a session at all (base URL ${BuildConfig.API_BASE_URL})",
            nodes("launch_gate").fetchSemanticsNodes().isEmpty(),
        )
    }

    private companion object {
        /** Generous: a cold app against a local server, on a loaded device. */
        const val TRANSCRIPT_TIMEOUT_MILLIS = 30_000L

        /**
         * Per-tag. Not a formality: the list container composes while the
         * transcript is still loading, so a scenario that only waits for the
         * container can assert against an empty screen. That is exactly how
         * the markdown scenario failed once and passed either side of it.
         */
        const val TAG_TIMEOUT_MILLIS = 20_000L
    }
}
