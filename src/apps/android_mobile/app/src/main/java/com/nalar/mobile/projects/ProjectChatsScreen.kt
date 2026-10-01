package com.nalar.mobile.projects

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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.HourglassTop
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
import com.nalar.mobile.recents.ChatListFooter
import com.nalar.mobile.recents.ChatListLoadMoreTrigger
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarText

/** Reserved key for the footer row, which is not a chat. */
private const val LOAD_MORE_KEY = "__project_chats_footer__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

private const val CONTENT_TYPE_CHAT = "chat"

private const val CONTENT_TYPE_STATE = "state"

/**
 * Every chat in one project, full-screen, paging on scroll.
 *
 * This is the destination behind the drawer's "See all chats" row. The drawer
 * shows a 5-row preview; when that is not enough, the reader comes here rather
 * than the drawer growing a second scroller it cannot fit on a 390dp screen.
 *
 * **It reads [page] and nothing else.** The state is owned by
 * `HomeViewModel` — shared with the drawer on purpose, so expanding a project
 * and then tapping "See all" costs one request rather than two. Handing this
 * screen the whole `HomeUiState` would work just as well and recompose this
 * `LazyColumn` on every unrelated emission, including a recents page append the
 * reader is not looking at. A narrow slice whose `List` reference is unchanged
 * does not rebuild.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectChatsScreen(
    projectName: String,
    page: ProjectChatsPage?,
    selectedChatId: String?,
    runningSessionIds: Set<String>,
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
     * Open the create flow for *this* project.
     *
     * The same flow the drawer's `+` opens, handed in rather than built here: a
     * reader who makes a chat from the project screen and one who makes one from
     * the drawer should get the same picker, the same memory rules and the same
     * validation. Two implementations is how they stop agreeing.
     */
    onCreateTask: () -> Unit = {},
    /** Whether a create for this project is in flight, for the `+`'s busy state. */
    isCreatingTask: Boolean = false,
    nowEpochMillis: Long = remember { System.currentTimeMillis() },
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val chats = page?.chats.orEmpty()
    val hasMore = page?.hasMore ?: false
    val listState = rememberLazyListState()

    // One page per approach to the end — *and* one when the reader cannot
    // approach the end at all. A project the drawer previewed is five rows
    // long, five rows do not fill a phone, and a `LazyColumn` with no overflow
    // has no scroll offset to change, so a scroll-only trigger leaves a project
    // with more than five chats permanently unreadable. Same trigger as the
    // workspace list, so the two cannot drift back apart.
    ChatListLoadMoreTrigger(
        listState = listState,
        canPage = hasMore && chats.isNotEmpty() && !isLoading,
        rowCount = chats.size,
        onLoadMore = onLoadMore,
    )

    Scaffold(
        modifier = modifier.testTag("project_chats_screen"),
        containerColor = NalarBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = projectName,
                        style = MaterialTheme.typography.titleMedium,
                        color = NalarText,
                    )
                },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = Modifier.testTag("project_chats_back"),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = NalarAccent,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NalarBackground,
                ),
                actions = {
                    // The one place on this screen that creates something.
                    // It sits here rather than as a floating button because the
                    // list is a plain `LazyColumn` with a footer, and a FAB
                    // would float over the last chat a reader is trying to tap.
                    IconButton(
                        onClick = onCreateTask,
                        // Disabled while the create is in flight, so a
                        // double-tap cannot make two chats. The ViewModel
                        // refuses a second create too; this is the affordance.
                        enabled = !isCreatingTask,
                        modifier = Modifier.testTag("project_chats_create"),
                    ) {
                        Icon(
                            imageVector = if (isCreatingTask) {
                                Icons.Filled.HourglassTop
                            } else {
                                Icons.Filled.Add
                            },
                            contentDescription = "New chat in this project",
                            tint = if (isCreatingTask) NalarDim else NalarAccent,
                        )
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .testTag("project_chats_list"),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (chats.isEmpty()) {
                item(key = "project_chats_state", contentType = CONTENT_TYPE_STATE) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    ) {
                        com.nalar.mobile.recents.SidebarPlaceholder(
                            testTag = if (isLoading) "project_chats_loading" else "project_chats_empty",
                            title = if (isLoading) "Loading chats" else "No chats in this project yet",
                            detail = if (isLoading) {
                                "Fetching the chats in this project."
                            } else {
                                // A fresh kanban or agent legitimately has
                                // none. That is a fact about the project, not a
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
                ProjectChatRow(
                    chat = chat,
                    selected = chat.id == selectedChatId,
                    isRunning = chat.id in runningSessionIds,
                    nowEpochMillis = nowEpochMillis,
                    onClick = {
                        onChatSelected(chat.id)
                        // A chat is a destination. Same gesture, same route as
                        // the drawer's — the task id is the session id, so there
                        // is nothing to translate.
                        onOpenChat(chat.id)
                    },
                )
            }

            item(key = LOAD_MORE_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                ChatListFooter(
                    isLoading = isLoading,
                    // Claiming the end while more may still exist is a lie the
                    // reader sees first and then watches get retracted.
                    hasReachedEnd = !hasMore,
                )
            }
        }
    }
}
