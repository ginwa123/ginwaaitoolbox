package com.nalar.mobile.recents

import androidx.compose.foundation.BorderStroke
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

/** Reserved key for the footer row, which is not a chat. */
private const val LOAD_MORE_KEY = "__chats_footer__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

@Composable
fun RecentsSidebar(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    selectedChatId: String?,
    onWorkspaceSelected: (String) -> Unit,
    onChatSelected: (String) -> Unit,
    modifier: Modifier = Modifier,
    nowEpochMillis: Long = System.currentTimeMillis(),
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
 */
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

        Spacer(Modifier.height(24.dp))

        Text(
            text = "Recent",
            modifier = Modifier
                .padding(horizontal = 8.dp)
                .semantics { heading() },
            style = MaterialTheme.typography.labelLarge,
            color = NalarDim,
        )

        Spacer(Modifier.height(8.dp))

        val visibleChats = selectedWorkspaceId
            ?.let { workspaceId -> recentChatsForWorkspace(chats, workspaceId) }
            .orEmpty()

        if (visibleChats.isEmpty()) {
            when {
                isLoading -> SidebarPlaceholder(
                    modifier = Modifier.weight(1f),
                    testTag = "chats_loading",
                    title = "Loading chats",
                    detail = "Fetching the most recent chats in this workspace.",
                    showSpinner = true,
                )

                errorMessage != null -> SidebarError(
                    modifier = Modifier.weight(1f),
                    testTag = "chats_error",
                    message = errorMessage,
                    onRetry = onRetry,
                )

                else -> EmptyChats(
                    modifier = Modifier.weight(1f),
                )
            }
        } else {
            val listState = rememberLazyListState()

            // A workspace switch shows a different set of rows at the same
            // indices, so the old scroll offset would land the user mid-list in
            // a workspace they have not looked at yet.
            LaunchedEffect(selectedWorkspaceId) {
                listState.scrollToItem(0)
            }

            // One page per approach to the bottom.
            //
            // The latch is what keeps a short page from becoming a request
            // storm: if the new page does not fill the viewport, the trigger is
            // still armed on the very next layout, and without this the sidebar
            // would re-fire until it happened to overflow. The ViewModel's
            // in-flight guard covers concurrent calls; this one covers the
            // sequential ones, which are the common case.
            var loadMoreLatched by remember { mutableStateOf(true) }

            LaunchedEffect(listState, visibleChats.size, hasMoreChats, isLoadingMore) {
                snapshotFlow {
                    val info = listState.layoutInfo
                    val last = info.visibleItemsInfo.lastOrNull()?.index ?: -1
                    // Only a real overflow can be scrolled; an unlaid-out list
                    // reports 0/0 and would otherwise arm on the first frame.
                    info.totalItemsCount > 0 && last >= info.totalItemsCount - 1 - LOAD_MORE_INDEX_THRESHOLD
                }
                    .distinctUntilChanged()
                    .collect { nearBottom ->
                        if (!nearBottom) {
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
                items(
                    items = visibleChats,
                    key = { chat -> chat.id },
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

                item(key = LOAD_MORE_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                    ChatListFooter(
                        isLoading = isLoadingMore,
                        // Claiming the end while more may still exist is a lie
                        // the user reads first and then has to watch retracted.
                        hasReachedEnd = !hasMoreChats,
                    )
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
 * It is always present, rather than shown conditionally, so the list's total
 * item count is stable across a page append — otherwise appending shifts every
 * index and the scroll watcher re-evaluates mid-animation.
 */
@Composable
private fun ChatListFooter(
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
private fun SidebarPlaceholder(
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
