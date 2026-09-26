package com.nalar.mobile.network

import com.nalar.mobile.auth.SessionPhase
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.storage.LastPosition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The four conditions that have to hold before a relaunch is allowed to open a
 * chat, and nothing else.
 *
 * Two of them are about *timing* and two are about *precedence*, and the
 * precedence is the one worth stating: whatever this decides, it must never
 * override a position the user has just chosen by hand. A deep link and a
 * restored back stack are both that, and both of them have a route on the stack
 * by the time the effect runs — which is why the test names routes rather than
 * talking about "somewhere else".
 */
class SessionToResumeTest {

    @Test
    fun `a plain relaunch on the shell opens the saved chat`() {
        assertEquals("sess_c", resume())
    }

    @Test
    fun `nothing opens before the session is authenticated`() {
        // The sidebar's data lands while the auth phase is still settling, and
        // the launch screen is what is on screen then. Opening a chat there loads
        // a transcript against a session that may not exist yet — and a 401 on
        // that load signs the user out of an app they never signed into.
        SessionPhase.entries
            .filter { it != SessionPhase.Authenticated }
            .forEach { phase ->
                assertNull("resumed during $phase", resume(authPhase = phase))
            }
    }

    @Test
    fun `a deep link wins over the saved chat`() {
        // `nalar://chat/sess_x` put that route on the stack and the user is
        // looking at it. Restoring over it would replace a link they followed
        // with a chat from a previous run.
        assertNull(resume(currentRoute = NalarRoutes.chat("sess_x")))
        assertNull(resume(currentRoute = NalarRoutes.NETWORK))
        assertNull(resume(currentRoute = NalarRoutes.recordDetail(7L)))
    }

    @Test
    fun `an empty back stack is not treated as somewhere else`() {
        // `NavHost` with no destination renders nothing, and the graph answers
        // that with its own recovery screen. The user is on the shell in every
        // sense that matters, so the resume is exactly as allowed as it is for
        // the real shell route. See `NavigationLostScreen`.
        assertEquals("sess_c", resume(currentRoute = NalarRoutes.SHELL))
    }

    @Test
    fun `nothing opens while the chat list is still loading`() {
        // The cached paint is a picture of a list that may since have lost the
        // chat. Waiting one fetch validates against the freshest list there is.
        assertNull(resume(isLoading = true))
    }

    @Test
    fun `a chat the server no longer lists is not opened`() {
        val plan = plan(session = "sess_deleted")
        assertNull(
            sessionToResume(
                authPhase = SessionPhase.Authenticated,
                currentRoute = NalarRoutes.SHELL,
                plan = plan,
                chats = CHATS,
                selectedWorkspaceId = "ws_b",
                isLoading = false,
            ),
        )
    }

    @Test
    fun `nothing opens before the store has been read`() {
        // The read is on IO, so for the first frames of a launch there is no
        // plan to act on. That is not "resume the shell's own chat" and it is not
        // a crash: it is nothing at all, and the effect re-runs when the plan
        // arrives because it is one of its keys.
        assertNull(
            sessionToResume(
                authPhase = SessionPhase.Authenticated,
                currentRoute = NalarRoutes.SHELL,
                plan = null,
                chats = CHATS,
                selectedWorkspaceId = "ws_b",
                isLoading = false,
            ),
        )
    }

    private fun resume(
        authPhase: SessionPhase = SessionPhase.Authenticated,
        currentRoute: String? = NalarRoutes.SHELL,
        isLoading: Boolean = false,
    ) = sessionToResume(
        authPhase = authPhase,
        currentRoute = currentRoute,
        plan = plan(session = "sess_c"),
        chats = CHATS,
        selectedWorkspaceId = "ws_b",
        isLoading = isLoading,
    )

    private fun plan(session: String?) = ResumePlan(
        LastPosition(workspaceId = "ws_b", sessionId = session),
    )

    private companion object {
        val CHATS = listOf("sess_a", "sess_c", "sess_b").mapIndexed { index, id ->
            ChatSummary(
                id = id,
                workspaceId = "ws_b",
                title = "Chat $id",
                updatedAtEpochMillis = 1_000L + index,
            )
        }
    }
}
