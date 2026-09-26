package com.nalar.mobile.network

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The back rule, and the shape of the fix that keeps a blank window unreachable.
 *
 * The hazard is a property of AndroidX Navigation 2.8.5 rather than of any one
 * screen, so it is asserted against that behaviour and not against a rendering:
 * the no-argument `NavController.popBackStack()` pops the current destination
 * *and* stops at the graph, `dispatchOnDestinationChanged()` then drops that
 * graph, and `NavHost` renders nothing at all for the resulting empty back stack.
 * Reading that call's return value cannot catch it, because the queue is already
 * gone by the time it returns `false`.
 *
 * `NalarNavGraphBackInstrumentedTest` drives the real `NavHost` into the state
 * this rule exists for; this file keeps the rule and the shape of the fix
 * honest on a JVM, where CI can run it without a device.
 */
class NalarNavGraphBackTest {

    @Test
    fun `a destination under the current one is popped onto`() {
        assertEquals(BackAction.PopPrevious, backActionFor(hasDestinationBelow = true))
    }

    @Test
    fun `nothing under the current one goes back to the shell instead of popping`() {
        // The graph alone underneath is what a `nalar://` link that arrives
        // without FLAG_ACTIVITY_NEW_TASK leaves behind: `handleDeepLink` navigates
        // with popUpTo(graph, inclusive = true), so the shell is never pushed and
        // the deep-linked leaf is the only destination. Popping there is exactly
        // the call that empties the back stack and blanks the window.
        assertEquals(BackAction.ReturnToShell, backActionFor(hasDestinationBelow = false))
    }

    @Test
    fun `no back affordance pops unconditionally`() {
        val source = navGraphSource()
        // A bare `navController.popBackStack()` behind a back arrow is the defect
        // itself; the guarded form inside `goBack` is the fix. This keeps the two
        // from being confused when the file is next edited.
        assertEquals(
            "a back affordance must not call the inclusive pop unconditionally: at a " +
                "one-destination depth it empties the back stack and NavHost then " +
                "renders nothing at all",
            0,
            Regex("""onBack\s*=\s*\{\s*navController\.popBackStack\(\)\s*}""")
                .findAll(source)
                .count(),
        )
        // There is more than one place that pops to the shell now — the chat
        // route's drawer switches chats in place as well as `goBack` rebuilding
        // onto it — so the invariant is about how each one pops, not how many
        // there are. An inclusive pop of the shell is the blank window.
        assertEquals(
            "popping the shell inclusively is the blank-screen defect: the shell " +
                "is the one entry that has to survive",
            0,
            Regex("""popUpTo\(NalarRoutes\.SHELL\)\s*\{\s*inclusive\s*=\s*true""")
                .findAll(source)
                .count(),
        )
        assertTrue(
            "the shell must stay reachable as the floor of the back stack",
            source.contains("popUpTo(NalarRoutes.SHELL) { inclusive = false }"),
        )
    }

    @Test
    fun `an empty back stack is answered with a screen instead of nothing`() {
        val source = navGraphSource()
        assertTrue(
            "NavHost renders nothing for an empty back stack, so the graph has to " +
                "render something of its own when there is no visible destination",
            source.contains("visibleDestinations.isEmpty()") &&
                source.contains("NavigationLostScreen"),
        )
    }

    /**
     * The module's own source, or null when the test runs from somewhere that
     * cannot see it. The behavioural tests above stand on their own; only the two
     * shape assertions need the file.
     */
    private fun navGraphSource(): String =
        sequenceOf(
            "src/main/java/com/nalar/mobile/network/NalarNavGraph.kt",
            "app/src/main/java/com/nalar/mobile/network/NalarNavGraph.kt",
        )
            .map(::File)
            .firstOrNull(File::isFile)
            ?.readText()
            ?: error("NalarNavGraph.kt not reachable from ${File(".").absolutePath}")
}
