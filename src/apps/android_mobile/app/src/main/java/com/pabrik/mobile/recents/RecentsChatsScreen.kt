package com.pabrik.mobile.recents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikText

/** Reserved key for the footer row, which is not a chat. */
private const val LOAD_MORE_KEY = "__recents_chats_footer__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

private const val CONTENT_TYPE_CHAT = "chat"

private const val CONTENT_TYPE_STATE = "state"

/**
 * Every chat in one workspace, full-screen, paging on scroll.
 *
 * The destination behind the drawer's `See all chats ›` row, and the third
 * piece of the shape the project section already uses: five rows inline, a
 * button, a page behind it. Copied rather than reinvented so the two sections
 * cannot drift apart.
 *
 * **It reads [chats] and nothing else.** The state is owned by `HomeViewModel`
 * — shared with the drawer on purpose, so opening this page costs one request
 * for the rows the drawer already has and no second copy of the list. Handing
 * this screen the whole `HomeUiState` would work just as well and recompose
 * this `LazyColumn` on every unrelated emission, including a *projects* page
 * the reader is not looking at. A narrow slice whose `List` reference is
 * unchanged does not rebuild.
 *
 * **No `+` in the app bar, unlike the project screen's.** That one opens a
 * create flow scoped to a single project. There is no project here, and the
 * drawer's "New Chat" already creates in the workspace's default project — so
 * copying the button would mean inventing a "which project" question this
 * screen has no honest answer to. Left out on purpose, not forgotten.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecentsChatsScreen(
    workspaceName: String,
    chats: List<ChatSummary>,
    selectedChatId: String?,
    runningSessionIds: Set<String>,
    /**
     * The ViewModel's own answer to "is there another page?" — its
     * `canLoadMoreChats`, not a bare `has_more` re-derived here.
     *
     * Passed in rather than read from a state object because the ViewModel is
     * the only place that knows whether a page is already in flight and
     * whether the list has covered the server's count. Two independent notions
     * of "done" are the drift this keeps out.
     */
    hasMore: Boolean,
    /** A later page is in flight, so the footer spins instead of claiming an end. */
    isLoadingMore: Boolean,
    /** The first page is in flight and the list is empty, so the body is a placeholder. */
    isLoading: Boolean,
    onChatSelected: (String) -> Unit,
    /**
     * Open a chat from this screen. Takes the session id rather than being
     * zero-argument so the caller has to say *which* chat it is navigating to,
     * and so this screen's contract is the same shape as the drawer's
     * `onOpenChat` — the same gesture, the same route, one definition.
     */
    onOpenChat: (String) -> Unit,
    onLoadMore: () -> Unit,
    /**
     * Why the last page failed, or null.
     *
     * Shown as a tappable row rather than left to the scroll trigger, because
     * the list this screen opens on is the drawer's five-row preview and five
     * rows do not fill a phone — so a failed page would otherwise be invisible
     * and its only advertised recovery, scrolling, would be a gesture the
     * screen cannot accept.
     */
    loadMoreError: String? = null,
    nowEpochMillis: Long = remember { System.currentTimeMillis() },
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // One reading of "there is more", shared by the footer and the trigger.
    val canPage = recentsChatsCanPage(chats, hasMore, isLoadingMore)
    val listState = rememberLazyListState()

    // One page per approach to the end — *and* one when the reader cannot
    // approach the end at all, which is the state this screen opens in: the
    // drawer hands over five rows, five rows do not fill a phone, and a
    // `LazyColumn` with no overflow has no scroll offset to change. Shared with
    // the project screen rather than copied, because the copy of this trigger
    // is where the bug lived.
    ChatListLoadMoreTrigger(
        listState = listState,
        canPage = canPage,
        rowCount = chats.size,
        onLoadMore = onLoadMore,
    )

    Scaffold(
        modifier = modifier.testTag("recents_chats_screen"),
        containerColor = PabrikBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = workspaceName,
                        style = MaterialTheme.typography.titleMedium,
                        color = PabrikText,
                    )
                },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = Modifier.testTag("recents_chats_back"),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = PabrikAccent,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PabrikBackground,
                ),
            )
        },
    ) { padding ->
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .testTag("recents_chats_list"),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (chats.isEmpty()) {
                item(key = "recents_chats_state", contentType = CONTENT_TYPE_STATE) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    ) {
                        SidebarPlaceholder(
                            testTag = if (isLoading) {
                                "recents_chats_loading"
                            } else {
                                "recents_chats_empty"
                            },
                            title = if (isLoading) "Loading chats" else "No chats in this workspace yet",
                            detail = if (isLoading) {
                                "Fetching every chat in this workspace."
                            } else {
                                // A workspace with no history is a fact, not a
                                // failure, so it reads as a state and not as
                                // an error.
                                "Start one from the web app and it will show up here."
                            },
                            showSpinner = isLoading,
                        )
                    }
                }
                return@LazyColumn
            }

            items(
                items = chats,
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
                        // A chat is a destination. Same gesture, same route as
                        // the drawer's — the session id needs no translating.
                        onOpenChat(chat.id)
                    },
                )
            }

            item(key = LOAD_MORE_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                ChatListFooter(
                    isLoading = isLoadingMore,
                    // Claiming the end while more may still exist is a lie the
                    // reader sees first and then watches get retracted — and
                    // `canPage` is false while the first page is still in
                    // flight, which is why the spinner is checked first.
                    hasReachedEnd = !hasMore,
                    errorMessage = loadMoreError,
                    // The same call the trigger makes, so a tap and a scroll
                    // cannot disagree about what to ask for.
                    onRetry = onLoadMore,
                )
            }
        }
    }
}

/**
 * Whether this screen's scroll should ask for another page.
 *
 * A predicate rather than a bare `hasMore` read, so the two places that need
 * it cannot disagree: the footer and the scroll trigger both ask, and the
 * scroll fires on *position* — a footer claiming "no more" under a trigger
 * that still fetches would put the two out of step on the reader's screen.
 *
 * An empty list stops too. With nothing on screen the LazyColumn holds one
 * placeholder row, so `last` is 0 and the band would arm immediately: a page
 * request that appends onto nothing, on a screen the reader just opened.
 */
internal fun recentsChatsCanPage(
    chats: List<ChatSummary>,
    hasMore: Boolean,
    isLoadingMore: Boolean,
): Boolean = hasMore && chats.isNotEmpty() && !isLoadingMore
