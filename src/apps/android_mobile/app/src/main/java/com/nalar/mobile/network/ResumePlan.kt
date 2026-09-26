package com.nalar.mobile.network

import com.nalar.mobile.auth.SessionPhase
import com.nalar.mobile.recents.ChatSummary
import com.nalar.mobile.storage.LastPosition

/**
 * What a relaunch should open, decided once, from the position the last run
 * saved and the data that has loaded since.
 *
 * ### Why the decision lives here
 *
 * The alternative is to put the restore in the nav graph's effect, where it
 * reads as three lines of `if`. What makes it dangerous is not the navigation —
 * it is the *waiting*. The saved id cannot be checked until the list it belongs
 * to has arrived, and the answer must not be acted on twice, because a second
 * `navigate()` onto the chat route is a second destination on the back stack,
 * which is how one chat ends up twice under Back. Both are rules about state
 * over time, so they belong to a class that owns the state, not to three
 * booleans threaded through a composable.
 *
 * The workspace half of the position is not here on purpose: a workspace is
 * sidebar state, so it is applied by [com.nalar.mobile.recents.HomeViewModel]
 * while it is still choosing which list to paint, before the first fetch. See
 * `selectWorkspaceId` in that file.
 *
 * ### The rules it enforces
 *
 * 1. **Nothing to resume is not a failure.** No saved position, or one whose
 *    chat has been deleted, leaves the app on the shell — which is where it
 *    would have been anyway.
 * 2. **Only ever resume what still exists.** The saved id is validated against
 *    the loaded list. Resuming a deleted chat would open a route whose session
 *    no longer exists, and the transcript would come back empty with nothing to
 *    explain why.
 * 3. **Decide once.** Every answer latches, so a recomposition, a second refresh
 *    or a trip through the network inspector cannot re-apply it.
 * 4. **Wait for the list.** `settled` is what separates "this chat is gone" (a
 *    decision, `null`) from "the list has not arrived yet" (no decision, also
 *    `null`). Guessing early would make the restore depend on which of the
 *    cached paint or the live fetch happened to win the race.
 */
internal class ResumePlan(private val saved: LastPosition) {

    private var sessionResolved = false

    /**
     * The chat to open, or null while the question is still open.
     *
     * Only the shell may resume, and that rule is the caller's to keep: a
     * `nalar://` deep link, or a back stack restored from saved instance state,
     * is a position the user has just chosen, and a persisted one must not
     * override it. Only the nav graph knows the current destination.
     */
    fun resolveSession(
        chats: List<ChatSummary>,
        selectedWorkspaceId: String?,
        settled: Boolean,
    ): String? {
        if (sessionResolved || !settled) return null
        val sessionId = saved.sessionId
        // Latched even when the answer is null: "no chat was saved" cannot stop
        // being true, so leaving it open would make every later recomposition
        // re-decide it.
        if (sessionId.isNullOrBlank() || selectedWorkspaceId == null) {
            sessionResolved = true
            return null
        }
        // An empty list is NOT an answer, and this is the line that decides
        // whether the feature works on a cold launch at all.
        //
        // `HomeViewModel.isLoading` covers the *workspace* list, and the chat list
        // for the workspace it selects is fetched after that — so there is a real
        // moment where the app has settled, holds no chats, and is about to
        // receive them. Latching here would answer "nothing to resume" for the
        // whole launch, and a launch with no cache to prime from is exactly the
        // one this feature exists for.
        //
        // Staying open costs nothing: a workspace that genuinely has no chats
        // keeps answering null, which is what it would have answered anyway. What
        // must not stay open is a *decision*, and that is the line below.
        if (chats.isEmpty()) return null
        sessionResolved = true
        return sessionId.takeIf { id -> chats.any { chat -> chat.id == id } }
    }
}

/**
 * The chat a relaunch should open right now, or null for "not yet, or not at
 * all".
 *
 * Everything the resume needs to be true is in one pure function so the effect
 * that calls it holds no policy of its own — the same split [goBackToPreviousOrShell]
 * makes for Back, and for the same reason: the conditions are the part that is
 * easy to get subtly wrong, and they are untestable inside a composable.
 *
 * Two of the four conditions are here and two live in [ResumePlan], split by
 * what they need to know:
 *
 * - **Authenticated.** The sidebar is still fetching while the auth phase
 *   settles, and a chat opened before it settles loads against a session that
 *   does not exist yet — an empty transcript, or a 401 that signs the user out.
 * - **On the shell.** A `nalar://` deep link, or a back stack restored from
 *   saved instance state, is a position the user chose a moment ago. Resuming
 *   over it would pull them out of the link they followed, and this is the
 *   desktop's own precedence: a URL beats the persisted workspace.
 * - **Settled** and **still listed** are [ResumePlan]'s, because only it knows
 *   whether it has already answered. "Still listed" means listed by the list the
 *   drawer is currently painting — cached or live — because that is the same list
 *   the user is being offered rows from. Restoring a chat the drawer is showing
 *   is no more of a leap than tapping it.
 *
 * [isLoading] is passed as the state field it is rather than as an inverted
 * `settled`, so the caller has no way to get the sense of the flag wrong.
 */
internal fun sessionToResume(
    authPhase: SessionPhase,
    currentRoute: String?,
    plan: ResumePlan?,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    isLoading: Boolean,
): String? {
    if (authPhase != SessionPhase.Authenticated) return null
    if (currentRoute != NalarRoutes.SHELL) return null
    return plan?.resolveSession(
        chats = chats,
        selectedWorkspaceId = selectedWorkspaceId,
        settled = !isLoading,
    )
}
