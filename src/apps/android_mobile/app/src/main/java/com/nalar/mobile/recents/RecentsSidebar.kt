package com.nalar.mobile.recents

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nalar.mobile.projects.ProjectChatRow
import com.nalar.mobile.projects.ProjectRow
import com.nalar.mobile.projects.CreateTaskRow
import com.nalar.mobile.projects.ProjectsActions
import com.nalar.mobile.projects.ProjectsState
import com.nalar.mobile.projects.ProjectTypes
import com.nalar.mobile.projects.SeeAllChatsRow
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarBackgroundRaised
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarField
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * How many rows from the end of the list arm the next page.
 *
 * A band rather than "the last row" so the fetch is already in flight by the
 * time the user reaches the end, rather than starting from a standstill with
 * the list visibly stopped. Two is about one screen of rows on a phone, which
 * is enough to cover the latency without paging pages the user never sees.
 */
private const val LOAD_MORE_INDEX_THRESHOLD = 2

/**
 * How many chats the Recents section shows before the reader asks for more.
 *
 * A drawer on a phone is a switchboard, not an archive: thirty rows of chat
 * titles push the Projects section — the part of this drawer people navigate
 * *by* — off the bottom of the screen, and the last thing a reader wants from
 * opening a drawer is to land in the middle of a list they did not scroll to.
 * Five is roughly one screenful on a tall phone, which is the whole point:
 * everything else in the drawer stays reachable without scrolling.
 *
 * The rest of the rows are one tap away ([RecentsSeeAllRow]) rather than gone,
 * so nothing is lost — it is only the *default* that is short. The header's
 * count keeps saying the true total, so a folded section still reports what is
 * in it.
 */
private const val RECENTS_PREVIEW_LIMIT = 5

/** Reserved key for the footer row, which is not a chat. */
private const val LOAD_MORE_KEY = "__chats_footer__"

/** Reserved key for the recents list's own loading/error/empty row. */
private const val CHATS_STATE_KEY = "__chats_state__"

/** Reserved key for the recents section header, which is also its sticky pin. */
private const val RECENTS_HEADER_KEY = "__recents_header__"

private const val PROJECTS_HEADER_KEY = "__projects_header__"

/** Reserved key for the row past the Recents preview limit, and back again. */
private const val SEE_ALL_KEY = "__recents_see_all__"

/**
 * The gap above the Projects header, as its own row.
 *
 * A row rather than padding on the header itself because the header is sticky:
 * a sticky row is pinned to the top of the list viewport, so a spacer drawn
 * inside it pins too and leaves a transparent band the chats scroll through.
 * The separation has to live above the pin.
 */
private const val PROJECTS_GAP_KEY = "__projects_gap__"

/**
 * How many rows the recents section spends on its own header.
 *
 * The header is a row in the list, not decoration around it, so it shifts every
 * chat index below it. The paging trigger counts indices and would otherwise
 * arm a page early — see `chatRegionEnd` in [SidebarBody].
 */
private const val RECENTS_HEADER_ROWS = 1

private const val CONTENT_TYPE_SENTINEL = "sentinel"

private const val CONTENT_TYPE_CHAT = "chat"

private const val CONTENT_TYPE_STATE = "state"

private const val CONTENT_TYPE_SECTION_HEADER = "section-header"

private const val CONTENT_TYPE_PROJECT = "project"

/**
 * Where the recents region ends in the drawer's one list: the index of its
 * footer row, the last row belonging to the chat list.
 *
 * Null when that region has nothing in it — folded away, or empty with nothing
 * to page. Null and not a number because a number would arm the paging trigger
 * on the *Projects* header below, paging a chat list the reader has either just
 * hidden or has none of.
 *
 * The header's row is inside the arithmetic deliberately. It is a row in the
 * list, so it shifts every chat index by one, and a trigger that counted only
 * the chats would arm a page early — firing while the reader is still a screen
 * of rows from the bottom, which is how the last page of a long list arrives
 * only after they have scrolled past it.
 *
 * [rowsAfterChats] counts the rows that sit between the last chat and that
 * footer — currently the "Show fewer" row, which is drawn only once the list is
 * open. It is a parameter rather than a `+ 1` folded in here because the row is
 * conditional, and a constant would arm the trigger one row early for every
 * reader who never opens the list.
 *
 * A pure function rather than an inline expression because this is the one
 * piece of the drawer's paging rule that a layout test cannot pin: proving a
 * one-row shift would need a viewport measured to the row, and a test that
 * depends on the exact row height silently stops testing anything the moment
 * the row's padding changes.
 */
internal fun chatRegionEndIndex(
    visibleChatCount: Int,
    recentsExpanded: Boolean,
    rowsAfterChats: Int = 0,
): Int? =
    if (!recentsExpanded || visibleChatCount <= 0) {
        null
    } else {
        RECENTS_HEADER_ROWS + visibleChatCount + rowsAfterChats
    }

/**
 * How many chat rows the Recents section renders.
 *
 * The cap and the override in one function because they are one decision, and
 * two call sites computing "show five, unless the reader asked for all" is two
 * places for the list to disagree with itself — the count the rows are built
 * from and the count the paging trigger counts.
 *
 * `showAll` only ever wins when there *is* something more: a workspace with
 * three chats renders three either way, so there is no second shape for a
 * short list to fall into.
 */
internal fun recentsVisibleChatCount(totalChats: Int, showAll: Boolean): Int =
    if (showAll) totalChats else minOf(totalChats, RECENTS_PREVIEW_LIMIT)

/**
 * Whether this view of the section draws the paging footer — and therefore
 * whether scrolling it can ask for the next page.
 *
 * False exactly when rows are being held back behind the "See all" row. That
 * view has nothing to scroll: its trigger would arm on the very first layout
 * and fetch page after page behind a row the reader has not tapped, which is
 * the 60-row drawer complaint this cap exists to answer, rebuilt out of network
 * requests. The rows beyond the cap are one tap away, and the tap is the fetch.
 */
internal fun recentsShowsChatFooter(totalChats: Int, showAll: Boolean): Boolean =
    showAll || totalChats <= RECENTS_PREVIEW_LIMIT

@Composable
fun RecentsSidebar(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    selectedChatId: String?,
    onWorkspaceSelected: (String) -> Unit,
    onChatSelected: (String) -> Unit,
    modifier: Modifier = Modifier,
    /**
     * Read once per composition, not once per recomposition.
     *
     * This default used to be a bare `System.currentTimeMillis()`, which is a
     * *new value every time the sidebar recomposes*. Compose compares
     * parameters to decide what may be skipped, so a parameter that changes
     * every frame means no row is ever skippable: opening the drawer, and
     * switching chat, re-ran `formatRelativeTime`, the accessibility string and
     * two colour copies for every visible row.
     *
     * `remember` is legal in a default argument — it is evaluated inside the
     * composable — so callers that pin the clock (tests, previews) are
     * unaffected and the default stops being a moving target. The trade is that
     * "2 hours ago" is as old as the composition; the sidebar is re-entered
     * constantly and the string is only ever a hint.
     */
    nowEpochMillis: Long = remember { System.currentTimeMillis() },
    /**
     * Leave the sidebar because a chat was opened — a chat is a destination.
     *
     * Switching the workspace is not, so it must not fire this: the whole
     * point of picking a workspace is to then pick a chat inside it, and
     * dismissing the drawer throws that second tap away.
     */
    onOpenChat: () -> Unit = {},
    isLoading: Boolean = false,
    errorMessage: String? = null,
    onRetry: () -> Unit = {},
    isLoadingMore: Boolean = false,
    hasMoreChats: Boolean = false,
    onLoadMore: () -> Unit = {},
    /**
     * Session ids with a live worker, so a chat the user is not in can still be
     * seen to be busy.
     *
     * Not derivable from anything on this screen: `isLoading` is about this
     * fetch, and a chat that was already running when the list loaded looks
     * identical to an idle one. The set is app-wide — see
     * `com.nalar.mobile.worker.RunningSessionsStore` — and defaulted so previews
     * and tests need no running worker to render a row.
     */
    runningSessionIds: Set<String> = emptySet(),
    /**
     * False when the server runs without `--auth`. There is no session to end
     * then, so the sign-out footer is hidden — the same gate the desktop
     * sidebar's `v-if="authEnabled"` applies.
     */
    isAuthEnabled: Boolean = false,
    signedInEmail: String? = null,
    isLoggingOut: Boolean = false,
    onLogout: () -> Unit = {},
    /**
     * The Projects section, and the four things a reader can do to it.
     *
     * Two holders rather than eight more parameters: this composable already
     * takes twenty-two, and these eight fields are only ever read together, so
     * a caller passing half of them is a caller with a half-rendered section.
     */
    projects: ProjectsState = ProjectsState.Empty,
    projectActions: ProjectsActions = ProjectsActions.None,
    /**
     * Whether the Recents section is unfolded, and the tap that folds it.
     *
     * State and action rather than a holder because neither half means anything
     * without the other, and both are forwarded verbatim from
     * [com.nalar.mobile.shell.RecentsDrawerContent] to here — the graph's
     * drawer and the shell's drawer are the same drawer and must not be able to
     * disagree about which section is open.
     */
    recentsExpanded: Boolean = true,
    onToggleRecents: () -> Unit = {},
    /**
     * Whether the reader has asked to see past the [RECENTS_PREVIEW_LIMIT]-row
     * preview, and the tap that asks (or un-asks).
     *
     * Hoisted beside [recentsExpanded] for the same reason, and the same
     * consequence if it were not: the shell's drawer and the chat route's are
     * one drawer, so a preview the reader had expanded in one and lost in the
     * other is a drawer that forgets what they asked for.
     */
    recentsShowAll: Boolean = false,
    onToggleRecentsShowAll: () -> Unit = {},
    /**
     * The top-level "New Chat" row: create a chat in the workspace's default
     * project and open it.
     *
     * State and action rather than a holder because neither half means anything
     * without the other, and both are forwarded verbatim from
     * [com.nalar.mobile.shell.RecentsDrawerContent] — the graph's drawer and
     * the shell's drawer are the same drawer.
     */
    isCreatingChat: Boolean = false,
    onNewChat: () -> Unit = {},
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(NalarBackground)
            .padding(horizontal = 12.dp),
    ) {
        Spacer(Modifier.height(12.dp))

        SidebarBody(
            modifier = Modifier.weight(1f),
            workspaces = workspaces,
            chats = chats,
            selectedWorkspaceId = selectedWorkspaceId,
            selectedChatId = selectedChatId,
            onWorkspaceSelected = onWorkspaceSelected,
            onChatSelected = onChatSelected,
            nowEpochMillis = nowEpochMillis,
            onOpenChat = onOpenChat,
            isLoading = isLoading,
            errorMessage = errorMessage,
            onRetry = onRetry,
            isLoadingMore = isLoadingMore,
            hasMoreChats = hasMoreChats,
            onLoadMore = onLoadMore,
            runningSessionIds = runningSessionIds,
            projects = projects,
            projectActions = projectActions,
            recentsExpanded = recentsExpanded,
            onToggleRecents = onToggleRecents,
            recentsShowAll = recentsShowAll,
            onToggleRecentsShowAll = onToggleRecentsShowAll,
            isCreatingChat = isCreatingChat,
            onNewChat = onNewChat,
        )

        // Deliberately outside the body. The "no workspaces" story is an early
        // return in there, and that is exactly the state in which the user would
        // otherwise have no route back to signing in.
        if (isAuthEnabled) {
            AccountFooter(
                email = signedInEmail,
                isLoggingOut = isLoggingOut,
                onLogout = onLogout,
            )
        }
    }
}

/**
 * The workspace picker, the stale-data notice and the recents list.
 *
 * Split out for one reason: [RecentsSidebar] needs an account footer below it
 * that no branch of this may swallow.
 *
 * Opted into `ExperimentalFoundationApi` for `stickyHeader` alone. It is the
 * only experimental call here, and both section titles are pinned with it — a
 * sidebar whose sections are named by a row that scrolls off is a list of rows
 * with no headings, which is the problem this drawer already had.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SidebarBody(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    selectedChatId: String?,
    onWorkspaceSelected: (String) -> Unit,
    onChatSelected: (String) -> Unit,
    nowEpochMillis: Long,
    /**
     * Leave the sidebar because a chat was opened — a chat is a destination.
     *
     * Same name as the public parameter and for the same reason: a filter has
     * nowhere to navigate to, and naming this one `onNavigate` is what invited
     * the workspace dropdown to call it.
     */
    onOpenChat: () -> Unit,
    isLoading: Boolean,
    errorMessage: String?,
    onRetry: () -> Unit,
    isLoadingMore: Boolean,
    hasMoreChats: Boolean,
    onLoadMore: () -> Unit,
    runningSessionIds: Set<String>,
    projects: ProjectsState,
    projectActions: ProjectsActions,
    recentsExpanded: Boolean,
    onToggleRecents: () -> Unit,
    /**
     * Whether the recents show every loaded chat or only the first few, and the
     * tap that changes it. See [recentsVisibleChatCount] for the count and
     * [recentsShowsChatFooter] for why a short preview does not page.
     */
    recentsShowAll: Boolean,
    onToggleRecentsShowAll: () -> Unit,
    /**
     * The top-level "New Chat" row's busy flag and its tap. No defaults, like
     * the two above: this is a private composable with exactly one caller, and
     * a default here would only let that caller forget to wire the action.
     */
    isCreatingChat: Boolean,
    onNewChat: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        if (workspaces.isEmpty()) {
            // No workspace means no scope, so there is nothing to scope chats
            // to. Loading, failed and genuinely-empty are three different
            // stories and the user needs to be able to tell them apart.
            when {
                isLoading -> SidebarPlaceholder(
                    modifier = Modifier.weight(1f),
                    testTag = "sidebar_loading",
                    title = "Loading workspaces",
                    detail = "Fetching your workspaces from Nalar.",
                    showSpinner = true,
                )

                errorMessage != null -> SidebarError(
                    modifier = Modifier.weight(1f),
                    testTag = "sidebar_error",
                    message = errorMessage,
                    onRetry = onRetry,
                )

                else -> SidebarPlaceholder(
                    modifier = Modifier.weight(1f),
                    testTag = "sidebar_no_workspaces",
                    title = "No workspaces yet",
                    detail = "Create a workspace on the web app and it will show up here.",
                )
            }
            return@Column
        }

        WorkspaceDropdown(
            workspaces = workspaces,
            selectedWorkspaceId = selectedWorkspaceId,
            onWorkspaceSelected = onWorkspaceSelected,
        )

        // Top-level "New Chat", above the scroller. Deliberately NOT an item in
        // the LazyColumn below: chatRegionEndIndex is index arithmetic that
        // assumes a fixed number of rows above the chats inside that list, and
        // a row in here would shift every chat index — arming the full-page
        // fetch early, with no error and no layout test that can see it.
        //
        // Placed BEFORE the conditional stale-data notice (not after) so it does
        // not move down when a refresh fails.
        if (selectedWorkspaceId != null) {
            NewChatRow(
                isBusy = isCreatingChat,
                onClick = onNewChat,
            )
        }

        // Rows survived a failed refresh. Say so — a stale list that looks live
        // is its own kind of lie.
        if (errorMessage != null && !isLoading) {
            Spacer(Modifier.height(10.dp))
            StaleDataNotice(
                modifier = Modifier.testTag("sidebar_stale_notice"),
                message = errorMessage,
                onRetry = onRetry,
            )
        }

        // Half of what this was. 24dp of nothing between "New Chat" and the
        // first section read as two unrelated blocks on a phone, and a drawer
        // whose sections cannot be seen together is a drawer that has to be
        // scrolled to be *read*. 12dp still separates them as sections.
        Spacer(Modifier.height(12.dp))

        val visibleChats = selectedWorkspaceId
            ?.let { workspaceId -> recentChatsForWorkspace(chats, workspaceId) }
            .orEmpty()

        // The rows this view renders, which is not the number loaded: past the
        // preview limit the rest waits behind the "See all" row. Both the row
        // count and the paging arithmetic below read these, so they cannot
        // drift apart.
        val renderedChatCount = recentsVisibleChatCount(visibleChats.size, recentsShowAll)
        // The inverse of the footer rule, named for what it means rather than
        // what it is not: rows are being held back behind the "See all" row.
        val chatsAreCapped = !recentsShowsChatFooter(visibleChats.size, recentsShowAll)
        // Whether the "See all" row has anything to do at all. A short list has
        // nothing to reveal and nothing to put away, so the row is absent in
        // *both* directions — including in a workspace the reader had opened the
        // list in elsewhere, where "See 0 more chats" would be a lie with a
        // button attached to it.
        val canRevealOrHideRecents = visibleChats.size > RECENTS_PREVIEW_LIMIT

        val listState = rememberLazyListState()

        // A workspace switch shows a different set of rows at the same indices,
        // so the old scroll offset would land the user mid-list in a workspace
        // they have not looked at yet.
        LaunchedEffect(selectedWorkspaceId) {
            listState.scrollToItem(0)
        }

        // Index of the recents footer, which is the last row belonging to the
        // chat list. Everything after it is the Projects section. Null when
        // there is nothing there to page.
        // Null whenever the footer is not drawn — the preview, and a folded
        // section. The preview's five rows fit on the screen, so its trigger
        // would arm immediately and page a list the reader is one tap away
        // from asking for.
        val chatRegionEnd = if (chatsAreCapped) {
            null
        } else {
            chatRegionEndIndex(
                visibleChatCount = renderedChatCount,
                recentsExpanded = recentsExpanded,
                // The "Show fewer" row, when the list is open: it is between the
                // last chat and the footer, and the footer is what this index
                // means.
                rowsAfterChats = if (canRevealOrHideRecents) 1 else 0,
            )
        }

        // One page per approach to the end of the *chat* region.
        //
        // The latch is what keeps a short page from becoming a request storm:
        // if the new page does not fill the viewport, the trigger is still
        // armed on the very next layout, and without this the sidebar would
        // re-fire until it happened to overflow. The ViewModel's in-flight
        // guard covers concurrent calls; this one covers the sequential ones,
        // which are the common case.
        var loadMoreLatched by remember { mutableStateOf(true) }

        LaunchedEffect(listState, visibleChats.size, hasMoreChats, isLoadingMore, chatRegionEnd) {
            snapshotFlow {
                val info = listState.layoutInfo
                val last = info.visibleItemsInfo.lastOrNull()?.index ?: -1
                val end = chatRegionEnd
                // Only a real overflow can be scrolled; an unlaid-out list
                // reports 0/0 and would otherwise arm on the first frame.
                //
                // Scoped to the chat region on purpose. One scroller holds both
                // lists, so the old "last index is near totalItemsCount" test
                // would fire only once the reader had scrolled past every
                // project row — i.e. never, for anyone who stops at the chats.
                //
                // A one-sided band, and that is the whole subtlety: the condition
                // used to also require `last <= end`, on the theory that being
                // *past* the footer means the reader is reading projects. But a
                // scroll that *lands* past the footer — a fling, a `scrollToItem`,
                // or just a fast drag on a short page — jumps the band instead of
                // crossing it, and the page never came. The upper bound could
                // only be a belt-and-braces guard against a storm, and the latch
                // above is already that guard: holding `last` at or past the end
                // keeps the latch engaged, so nothing re-fires while the reader
                // is down among the projects.
                info.totalItemsCount > 0 &&
                    end != null &&
                    last >= end - LOAD_MORE_INDEX_THRESHOLD
            }
                .distinctUntilChanged()
                .collect { nearEndOfChats ->
                    if (!nearEndOfChats) {
                        loadMoreLatched = false
                    } else if (!loadMoreLatched) {
                        loadMoreLatched = true
                        onLoadMore()
                    }
                }
        }

        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                // Not the transcript's `chat_message_list`. The chat route
                // composes this drawer *and* the transcript at once — a
                // closed sheet stays in the tree — so a shared tag made
                // every `onNodeWithTag` on either list fail on "multiple
                // nodes", which is two lists that cannot be told apart.
                .testTag("sidebar_chat_list")
                .selectableGroup(),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // ── Recents ───────────────────────────────────────────────────
            //
            // Sticky like every header in this list, and for the same reason the
            // two section titles have to be one shared composable: the section's
            // name is the only thing on screen saying which list the rows under
            // it belong to, and the name is the first thing a scroll throws away.
            stickyHeader(key = RECENTS_HEADER_KEY, contentType = CONTENT_TYPE_SECTION_HEADER) {
                SidebarSectionHeader(
                    title = "Recent",
                    itemCount = visibleChats.size,
                    unit = "chats",
                    expanded = recentsExpanded,
                    onClick = onToggleRecents,
                    testTag = "recents_section_header",
                )
            }

            if (recentsExpanded) {
                if (visibleChats.isEmpty()) {
                    // A row in the list, not a weighted placeholder beside it.
                    // The Projects section has to stay reachable while the recents
                    // are loading, empty or broken — a weighted placeholder would
                    // take the whole remaining height and push Projects off-screen
                    // exactly when the reader most wants somewhere else to go.
                    item(key = CHATS_STATE_KEY, contentType = CONTENT_TYPE_STATE) {
                        when {
                            isLoading -> SidebarPlaceholder(
                                testTag = "chats_loading",
                                title = "Loading chats",
                                detail = "Fetching the most recent chats in this workspace.",
                                showSpinner = true,
                            )

                            errorMessage != null -> SidebarError(
                                testTag = "chats_error",
                                message = errorMessage,
                                onRetry = onRetry,
                            )

                            else -> EmptyChats()
                        }
                    }
                } else {
                    val renderedChats = visibleChats.take(renderedChatCount)

                    items(
                        items = renderedChats,
                        key = { chat -> chat.id },
                        contentType = { CONTENT_TYPE_CHAT },
                    ) { chat ->
                        ChatRow(
                            chat = chat,
                            selected = chat.id == selectedChatId,
                            isRunning = chat.id in runningSessionIds,
                            nowEpochMillis = nowEpochMillis,
                            onClick = {
                                onChatSelected(chat.id)
                                onOpenChat()
                            },
                        )
                    }

                    // The way past the cap, and the way back. It replaces the
                    // paging footer rather than sitting above it: with rows
                    // held back there is no end of the list to report, and a
                    // "Scroll for older chats" hint under a list that does not
                    // scroll is an instruction that cannot be followed.
                    if (canRevealOrHideRecents) {
                        item(key = SEE_ALL_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                            RecentsSeeAllRow(
                                hiddenChatCount = visibleChats.size - renderedChatCount,
                                showingAll = recentsShowAll,
                                onClick = onToggleRecentsShowAll,
                            )
                        }
                    }

                    if (!chatsAreCapped) {
                        item(key = LOAD_MORE_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                            ChatListFooter(
                                isLoading = isLoadingMore,
                                // Claiming the end while more may still exist is
                                // a lie the user reads first and then has to
                                // watch retracted.
                                hasReachedEnd = !hasMoreChats,
                            )
                        }
                    }
                }
            }

            // ── Projects ──────────────────────────────────────────────────
            // 20dp here, plus the 4dp `spacedBy` above it and the header's own
            // 6dp, put a 30dp canyon between the last chat and the word
            // "Projects" — the largest gap in a drawer whose rows are 40dp
            // apart. 8dp leaves the sections visibly separate and nothing more.
            item(key = PROJECTS_GAP_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                Spacer(Modifier.height(8.dp))
            }

            stickyHeader(key = PROJECTS_HEADER_KEY, contentType = CONTENT_TYPE_SECTION_HEADER) {
                SidebarSectionHeader(
                    title = "Projects",
                    itemCount = projects.items.size,
                    unit = "projects",
                    expanded = projects.expanded,
                    onClick = projectActions.onToggleSection,
                    testTag = "projects_section_header",
                )
            }

            if (!projects.expanded) return@LazyColumn

            if (projects.isEmpty && !projects.isLoading && projects.errorMessage == null) {
                item(key = "projects_empty", contentType = CONTENT_TYPE_STATE) {
                    SidebarPlaceholder(
                        testTag = "projects_empty",
                        title = "No projects yet",
                        // Vue's copy points at the "+" it has and this does not
                        // have, so it would send the reader looking for a
                        // button that is not on this screen.
                        detail = "Create one on the web app and it will show up here.",
                    )
                }
                return@LazyColumn
            }

            if (projects.isLoading && projects.items.isEmpty()) {
                item(key = "projects_loading", contentType = CONTENT_TYPE_STATE) {
                    SidebarPlaceholder(
                        testTag = "projects_loading",
                        title = "Loading projects",
                        detail = "Fetching the projects in this workspace.",
                        showSpinner = true,
                    )
                }
                return@LazyColumn
            }

            if (projects.errorMessage != null && projects.items.isEmpty()) {
                item(key = "projects_error", contentType = CONTENT_TYPE_STATE) {
                    SidebarError(
                        testTag = "projects_error",
                        message = projects.errorMessage,
                        onRetry = projectActions.onRetry,
                    )
                }
                return@LazyColumn
            }

            items(
                items = projects.items,
                key = { project -> project.id },
                contentType = { CONTENT_TYPE_PROJECT },
            ) { project ->
                val expanded = projects.isProjectExpanded(project.id)
                Column {
                    ProjectRow(
                        project = project,
                        expanded = expanded,
                        onClick = { projectActions.onToggleItem(project.id) },
                    )

                    if (expanded) {
                        val preview = projects.previewFor(project.id)
                        Column(
                            modifier = Modifier
                                .padding(start = 12.dp)
                                .padding(start = 12.dp),
                        ) {
                            // Above the rows, not below: the thing the reader
                            // just made should be the first thing they see, and
                            // the list grows downward, so a create affordance
                            // at the bottom of it would be pushed off screen
                            // by the very rows it creates.
                            //
                            // Hidden for routine projects, matching the desktop
                            // (`WorkspaceItem.vue` hides the `+` there, and
                            // `createTaskStartDecision` refuses one anyway) —
                            // a scheduler-owned project has no task list for
                            // this row to add to.
                            if (project.itemType != ProjectTypes.ROUTINE) {
                                CreateTaskRow(
                                    projectName = project.id,
                                    isBusy = projects.creatingTaskItemId == project.id,
                                    onClick = {
                                        // Same fallback "See all chats" uses one
                                        // row below: a project read back from
                                        // cache can carry a blank workspace, and
                                        // the create endpoint is nested under it
                                        // — so a blank here is a 404, not a
                                        // defaulted success.
                                        projectActions.onCreateTask(
                                            project.copy(
                                                workspaceId = project.workspaceId
                                                    .ifEmpty { selectedWorkspaceId.orEmpty() },
                                            ),
                                        )
                                    },
                                )
                            }

                            preview.forEach { chat ->
                                ProjectChatRow(
                                    chat = chat,
                                    selected = chat.id == selectedChatId,
                                    isRunning = chat.id in runningSessionIds,
                                    nowEpochMillis = nowEpochMillis,
                                    onClick = {
                                        onChatSelected(chat.id)
                                        // A chat is a destination, and this row
                                        // opens the identical one the Recent
                                        // list opens — the task id IS the
                                        // session id.
                                        onOpenChat()
                                    },
                                )
                            }

                            if (projects.shouldOfferSeeAllChats(project.id)) {
                                SeeAllChatsRow(
                                    projectId = project.id,
                                    onClick = {
                                        projectActions.onOpenAllChats(
                                            project.workspaceId.ifEmpty { selectedWorkspaceId.orEmpty() },
                                            project.id,
                                        )
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Who is signed in, and the one control that ends it.
 *
 * The account line comes first on purpose: "Log out" is unambiguous as a verb
 * and easy to tap by accident next to the recents list, and naming the account
 * is what turns an accidental read into a deliberate one. The button says
 * "Logging out…" and refuses further presses while the call is in flight, so a
 * slow network cannot produce two sign-outs.
 */
@Composable
private fun AccountFooter(
    email: String?,
    isLoggingOut: Boolean,
    onLogout: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
    ) {
        HorizontalDivider(
            modifier = Modifier.testTag("sidebar_account_divider"),
            color = NalarBorder,
        )

        Spacer(Modifier.height(10.dp))

        Text(
            text = "SIGNED IN AS",
            modifier = Modifier.padding(horizontal = 8.dp),
            style = MaterialTheme.typography.labelMedium,
            color = NalarDim,
        )

        Text(
            text = email?.takeIf { it.isNotBlank() } ?: "Your account",
            modifier = Modifier
                .padding(horizontal = 8.dp)
                .testTag("sidebar_account_email"),
            style = MaterialTheme.typography.bodyMedium,
            color = NalarText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        Spacer(Modifier.height(4.dp))

        TextButton(
            onClick = onLogout,
            enabled = !isLoggingOut,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("sidebar_logout"),
        ) {
            Text(
                text = if (isLoggingOut) "Logging out…" else "Log out",
                color = NalarDim,
            )
        }

        Spacer(Modifier.height(4.dp))
    }
}

/**
 * The row under the last chat: a spinner while the next page is in flight, and
 * an end-of-list marker only once the server has said there is nothing more.
 *
 * It is always present *for as long as it is the last row of the chat region*,
 * rather than shown and hidden, so the list's total item count is stable across
 * a page append — otherwise appending shifts every index and the scroll watcher
 * re-evaluates mid-animation. The one exception is the capped preview, which
 * does not end in a list at all: there the "See all" row stands in for it, and
 * the reason is in `recentsShowsChatFooter`.
 */
/**
 * The recents list's footer, reused verbatim by the project-chats screen.
 *
 * `internal` rather than `private` because the project screen pages the same
 * way and needs the same three states — spinner, "more to come", "no more" —
 * and a second copy of that wording is a second thing to forget to update.
 */
@Composable
internal fun ChatListFooter(
    isLoading: Boolean,
    hasReachedEnd: Boolean,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(56.dp)
            .testTag("chats_list_footer"),
        contentAlignment = Alignment.Center,
    ) {
        when {
            isLoading -> CircularProgressIndicator(
                modifier = Modifier
                    .size(18.dp)
                    .testTag("chats_load_more_spinner"),
                strokeWidth = 2.dp,
                color = NalarMuted,
            )

            hasReachedEnd -> Text(
                text = "No older chats",
                modifier = Modifier.testTag("chats_list_end"),
                style = MaterialTheme.typography.labelSmall,
                color = NalarDim,
            )

            // More may exist and nothing is in flight. Naming the behaviour
            // makes an automatic load readable rather than surprising, and gives
            // the row something to assert on.
            else -> Text(
                text = "Scroll for older chats",
                modifier = Modifier.testTag("chats_load_more_hint"),
                style = MaterialTheme.typography.labelSmall,
                color = NalarDim,
            )
        }
    }
}

@Composable
private fun WorkspaceDropdown(
    workspaces: List<WorkspaceOption>,
    selectedWorkspaceId: String?,
    onWorkspaceSelected: (String) -> Unit,
) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val selectedWorkspace = workspaces.firstOrNull { it.id == selectedWorkspaceId }
    val selectedName = selectedWorkspace?.displayName ?: "Select workspace"

    Box(modifier = Modifier.fillMaxWidth()) {
        Surface(
            onClick = { expanded = true },
            modifier = Modifier
                .fillMaxWidth()
                .testTag("workspace_dropdown")
                .semantics {
                    role = Role.Button
                    contentDescription = "Select workspace. Current: $selectedName"
                    stateDescription = if (expanded) "Expanded" else "Collapsed"
                },
            shape = RoundedCornerShape(14.dp),
            color = NalarField,
            contentColor = NalarText,
            border = BorderStroke(1.dp, NalarBorder),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        text = "WORKSPACE",
                        style = MaterialTheme.typography.labelMedium,
                        color = NalarDim,
                    )
                    Text(
                        text = selectedName,
                        style = MaterialTheme.typography.titleMedium,
                        color = NalarText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                Icon(
                    imageVector = Icons.Filled.ExpandMore,
                    contentDescription = null,
                    tint = NalarMuted,
                )
            }
        }

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.testTag("workspace_menu"),
        ) {
            if (workspaces.isEmpty()) {
                DropdownMenuItem(
                    text = { Text("No workspaces yet") },
                    onClick = {},
                )
            } else {
                workspaces.forEach { workspace ->
                    val isSelected = workspace.id == selectedWorkspaceId
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = workspace.displayName,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        onClick = {
                            // Only the dropdown closes here. Dismissing the
                            // drawer as well would dump the user back on the
                            // main content with the new workspace's chats
                            // hidden behind the menu button they just used.
                            expanded = false
                            onWorkspaceSelected(workspace.id)
                        },
                        trailingIcon = if (isSelected) {
                            {
                                Icon(
                                    imageVector = Icons.Filled.Check,
                                    contentDescription = null,
                                )
                            }
                        } else {
                            null
                        },
                        modifier = Modifier
                            .testTag("workspace_option_${workspace.id}")
                            .semantics { selected = isSelected },
                    )
                }
            }
        }
    }
}

@Composable
private fun ChatRow(
    chat: ChatSummary,
    selected: Boolean,
    isRunning: Boolean,
    nowEpochMillis: Long,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_row_${chat.id}")
            .semantics(mergeDescendants = true) {
                contentDescription = buildString {
                    append(chat.displayTitle)
                    if (chat.hasTimestamp) {
                        append(", ")
                        // The label key, not the order key: this row can be at
                        // the top of the list because the *agent* is working it,
                        // and "updated just now" would be a claim about the
                        // human that is not true.
                        append(
                            formatRelativeTimeForAccessibility(
                                chat.lastHumanTouchedAtEpochMillis,
                                nowEpochMillis,
                            ),
                        )
                    }
                    // Spoken as part of the row rather than left to the spinner.
                    // A bare "progress indicator" tells a screen-reader user
                    // that something is animating, not *which* chat is busy —
                    // and this row's own description is the only place that
                    // answer can live.
                    if (isRunning) append(", agent is working")
                }
            }
            .selectable(
                selected = selected,
                role = Role.Tab,
                onClick = onClick,
            ),
        shape = RoundedCornerShape(12.dp),
        color = if (selected) NalarAccent.copy(alpha = 0.16f) else Color.Transparent,
        contentColor = NalarText,
        border = if (selected) {
            BorderStroke(1.dp, NalarAccent.copy(alpha = 0.36f))
        } else {
            null
        },
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = chat.displayTitle,
                    style = MaterialTheme.typography.bodyLarge,
                    color = NalarText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                // A session with no parseable timestamp gets no time pill
                // rather than a fabricated one. The pill reads the human-touch
                // key, so a running session at the top of the list still says
                // when the human was last actually there.
                if (chat.hasTimestamp) {
                    Text(
                        text = formatRelativeTime(chat.lastHumanTouchedAtEpochMillis, nowEpochMillis),
                        style = MaterialTheme.typography.labelMedium,
                        color = NalarMuted,
                    )
                }
            }

            // One trailing slot for both markers, so they cannot overlap and so
            // the selected dot keeps the position it already had.
            Row(
                modifier = Modifier.padding(start = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (selected) {
                    Box(
                        modifier = Modifier
                            .size(7.dp)
                            .background(NalarAccent, CircleShape),
                    )
                }
                if (isRunning) {
                    // Gaps rather than a fixed offset: the running spinner is
                    // the only marker on an unselected row and the one that
                    // matters most, so it is not pushed away from the title for
                    // the sake of a dot the user is not looking for.
                    Spacer(Modifier.size(if (selected) 6.dp else 0.dp))
                    CircularProgressIndicator(
                        modifier = Modifier
                            // Cleared *before* the tag: `clearAndSetSemantics`
                            // discards everything a preceding modifier set, and
                            // the row above merges descendants, so an
                            // un-cleared progress node would be announced as a
                            // second, meaningless thing inside the row.
                            .clearAndSetSemantics { }
                            .size(14.dp)
                            .testTag("chat_row_running_${chat.id}"),
                        strokeWidth = 2.dp,
                        color = NalarAccent,
                    )
                }
            }
        }
    }
}

@Composable
private fun StaleDataNotice(
    message: String,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        color = NalarBackgroundRaised,
        contentColor = NalarDim,
        border = BorderStroke(1.dp, NalarBorder),
    ) {
        Row(
            modifier = Modifier.padding(start = 10.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Showing saved data · $message",
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.labelMedium,
                color = NalarDim,
            )
            TextButton(
                onClick = onRetry,
                modifier = Modifier.testTag("sidebar_stale_retry"),
            ) {
                Text(text = "Retry", color = NalarAccent)
            }
        }
    }
}

@Composable
internal fun SidebarPlaceholder(
    title: String,
    detail: String,
    testTag: String,
    modifier: Modifier = Modifier,
    showSpinner: Boolean = false,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .testTag(testTag),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 24.dp),
        ) {
            if (showSpinner) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp,
                    color = NalarMuted,
                )
            }
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                color = NalarMuted,
                textAlign = TextAlign.Center,
            )
            Text(
                text = detail,
                style = MaterialTheme.typography.bodyMedium,
                color = NalarDim,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun SidebarError(
    message: String,
    onRetry: () -> Unit,
    testTag: String,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .testTag(testTag),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(horizontal = 24.dp),
        ) {
            Text(
                text = "Could not load your sidebar",
                style = MaterialTheme.typography.titleMedium,
                color = NalarMuted,
                textAlign = TextAlign.Center,
            )
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = NalarDim,
                textAlign = TextAlign.Center,
            )
            TextButton(
                onClick = onRetry,
                modifier = Modifier.testTag("sidebar_retry"),
            ) {
                Text(text = "Retry", color = NalarAccent)
            }
        }
    }
}

@Composable
private fun EmptyChats(modifier: Modifier = Modifier) {
    SidebarPlaceholder(
        modifier = modifier,
        testTag = "chats_empty",
        title = "No recent chats",
        detail = "Chats in this workspace will appear here.",
    )
}
