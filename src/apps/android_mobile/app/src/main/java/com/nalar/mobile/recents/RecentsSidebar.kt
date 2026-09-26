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
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
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
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarField
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText

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
    onNavigate: () -> Unit = {},
    isLoading: Boolean = false,
    errorMessage: String? = null,
    onRetry: () -> Unit = {},
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(NalarBackground)
            .padding(horizontal = 12.dp),
    ) {
        Spacer(Modifier.height(12.dp))

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
            onNavigate = onNavigate,
        )

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
            LazyColumn(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
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
                        nowEpochMillis = nowEpochMillis,
                        onClick = {
                            onChatSelected(chat.id)
                            onNavigate()
                        },
                    )
                }

                item {
                    Spacer(Modifier.height(12.dp))
                }
            }
        }
    }
}

@Composable
private fun WorkspaceDropdown(
    workspaces: List<WorkspaceOption>,
    selectedWorkspaceId: String?,
    onWorkspaceSelected: (String) -> Unit,
    onNavigate: () -> Unit,
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
                            expanded = false
                            onWorkspaceSelected(workspace.id)
                            onNavigate()
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
                        append(formatRelativeTimeForAccessibility(chat.updatedAtEpochMillis, nowEpochMillis))
                    }
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
                // rather than a fabricated one.
                if (chat.hasTimestamp) {
                    Text(
                        text = formatRelativeTime(chat.updatedAtEpochMillis, nowEpochMillis),
                        style = MaterialTheme.typography.labelMedium,
                        color = NalarMuted,
                    )
                }
            }

            if (selected) {
                Box(
                    modifier = Modifier
                        .padding(start = 10.dp)
                        .size(7.dp)
                        .background(NalarAccent, CircleShape),
                )
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
