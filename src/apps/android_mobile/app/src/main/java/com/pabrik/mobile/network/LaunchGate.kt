package com.pabrik.mobile.network

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import com.pabrik.mobile.auth.AuthRestoringScreen
import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.ui.PabrikBackground

/**
 * Whether an opaque gate is held over the whole graph while a launch finishes
 * deciding what to show.
 *
 * ### The three seconds this exists to remove
 *
 * Auth resolving is not the same moment as the app being ready. `/api/auth/me`
 * answers long before the workspace list and the chat list have settled, and
 * `ResumePlan` cannot answer "is the saved chat still there?" until they have.
 * So the shell used to paint an interactive sidebar immediately, hold it there
 * for however long the recents took, and *then* navigate into the chat the
 * reader had left — which is the shape of a bug the reader experiences as "my
 * app is slow", not as "my app opened somewhere else".
 *
 * There was a second drift behind it, and it is the reason this is not just a
 * spinner: the resume navigates before the transcript's first page is in, so
 * the route appears over an empty list and the auto-scroll to the newest turn
 * lands a frame or two later. Blocking only until the *navigation* is decided
 * would have swapped a visible sidebar for a visible jump.
 *
 * ### The rules
 *
 * 1. **The three unauthenticated phases never raise it.** `Restoring`,
 *    `NeedsLogin` and `NeedsRetry` are already a full-screen surface in the
 *    shell's own `when` — a launch screen, a sign-in form, a "Try again".
 *    Covering any of them with a second launch screen would hide the only
 *    controls that phase offers.
 * 2. **On the shell, the resume has to have answered.** While the plan is
 *    still waiting for a list, the shell would be showing a drawer the user can
 *    tap into, and every one of those taps is a position that beats the saved
 *    one. Holding the gate until [ResumePlan.isDecided] means the first frame
 *    the reader sees is the frame the app already knows what to show.
 * 3. **Off the shell, the resume is not this launch's business.** A
 *    `pabrik://` deep link put that destination on the back stack, and a restored
 *    back stack did the same. `ResumePlan` never answers for either — see
 *    [sessionToResume] — so waiting for it would block forever behind a splash
 *    the reader cannot leave. This is the difference between "the shell is
 *    still deciding" and "the app is somewhere the user put it".
 *
 *    A *null* route is not "somewhere else", though: it is the frame before
 *    `NavHost` has produced its start destination, which is the launch itself.
 *    The one place a null route can happen later is the empty back stack that
 *    [NavigationLostScreen] exists to catch, and that screen's one button must
 *    stay reachable — so the caller never draws the gate over it.
 * 4. **A resumed chat stays covered until its transcript is where it belongs.**
 *    Not until the state says loaded, and not until the route exists: until
 *    `ChatView` has actually issued the scroll, the first frame drawn is the top
 *    of the transcript and the second is the bottom. `ChatView` reports that
 *    moment itself, which is the only place that knows it.
 *
 * Free of Compose so the sequence — restoring, authenticated, still asking,
 * answered, resumed, settled — can be walked in a JVM test. A gate is a rule
 * about the *order* of five facts, and the order is the whole bug.
 */
internal fun launchGateIsUp(
    authPhase: SessionPhase,
    currentRoute: String?,
    resumeDecided: Boolean,
    resumedSessionId: String?,
    transcriptSettled: Boolean,
): Boolean = when (authPhase) {
    // Rule 1. The shell is already a splash, a form or a retry.
    SessionPhase.Restoring,
    SessionPhase.NeedsLogin,
    SessionPhase.NeedsRetry,
    -> false

    SessionPhase.Authenticated -> when {
        // Rule 4. This launch opened a chat, so this launch is not done until
        // that chat is standing where the reader left it.
        resumedSessionId != null -> !transcriptSettled

        // Rule 3. A destination that exists is one the user put there.
        currentRoute != null && currentRoute != PabrikRoutes.SHELL -> false

        // Rules 2 and 3. The shell, or the frame before the shell exists.
        else -> !resumeDecided
    }
}

/**
 * The gate itself: the app's own launch screen, held over the graph.
 *
 * **Over the `NavHost`, never inside it.** The chat the resume opened has to be
 * composed and laid out while this is up — that is what lets its first page
 * load and its auto-scroll run before anyone sees a pixel of it. A gate that
 * replaced the destinations would leave the transcript to be composed *after*
 * the reveal, which is the drift this is here to remove.
 *
 * **It swallows touches.** The content underneath is not just invisible, it is
 * live, and a tap landing on a chat row behind the gate would be a position the
 * user chose while the app was still restoring the previous one. One
 * `pointerInput` is enough to keep the underlying siblings out of the hit
 * test entirely — hit testing stops at the first child that answers — and
 * consuming at the `Initial` pass is what stops the gate's own subtree from
 * passing anything along.
 */
@Composable
internal fun LaunchGateScreen(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(PabrikBackground)
            .testTag("launch_gate")
            .swallowTouches(),
    ) {
        AuthRestoringScreen()
    }
}

/**
 * Consume every pointer event over this node, at the first pass, forever.
 *
 * Never completes: the gate is removed by leaving the composition, not by the
 * loop ending, so a coroutine that returned would hand the screen's touches
 * back to whatever is behind it.
 */
private fun Modifier.swallowTouches(): Modifier = pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) {
            awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
        }
    }
}
