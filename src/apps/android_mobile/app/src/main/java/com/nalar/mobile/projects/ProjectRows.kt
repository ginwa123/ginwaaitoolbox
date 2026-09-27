package com.nalar.mobile.projects

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Brush
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material.icons.filled.ViewKanban
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nalar.mobile.recents.formatRelativeTime
import com.nalar.mobile.recents.formatRelativeTimeForAccessibility
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarField
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText

/**
 * Everything the Projects section draws, in one value.
 *
 * A holder rather than nine more parameters on [RecentsSidebar], which already
 * takes twenty-two. Same move the auth block made for the same reason: these
 * eight fields are only ever read together, and a caller passing half of them
 * is a caller with a half-rendered section.
 */
@Stable
class ProjectsState(
    val expanded: Boolean,
    val items: List<ProjectSummary>,
    val expandedItemIds: Set<String>,
    val chats: Map<String, ProjectChatsPage>,
    val isLoading: Boolean,
    val errorMessage: String?,
    /**
     * The project whose create is in flight, or null.
     *
     * Held here rather than passed down as its own parameter, for the reason
     * the whole holder exists: this composable already takes twenty-two and
     * this is only ever read by the `+` row, which is part of the Projects
     * section like everything else it draws.
     */
    val creatingTaskItemId: String? = null,
) {
    fun isProjectExpanded(itemId: String): Boolean = itemId in expandedItemIds

    fun chatsFor(itemId: String): ProjectChatsPage? = chats[itemId]

    /**
     * The rows the drawer unrolls under a project — the first
     * [ProjectsApi.DRAWER_PREVIEW_ROWS] of the page, never the whole thing.
     *
     * A cap rather than a scroll of its own: a 390dp drawer cannot host two
     * independently scrolling panes, and the full list is one tap away on a
     * screen of its own.
     */
    fun previewFor(itemId: String): List<ProjectChat> =
        chats[itemId]?.chats?.take(ProjectsApi.DRAWER_PREVIEW_ROWS).orEmpty()

    /**
     * Whether "See all chats" is worth offering: only when the drawer is
     * actually hiding rows. A project with three chats needs no detour to a
     * screen showing those same three.
     *
     * Note there is no count anywhere. The tasks endpoint's `count` is the page
     * length, not a filtered total, so any total means paging the whole list —
     * per project, per refresh. A button that says "See all 47 chats" when
     * there are 312 is a worse lie than no number.
     */
    fun shouldOfferSeeAllChats(itemId: String): Boolean {
        val page = chats[itemId] ?: return false
        return page.chats.size > ProjectsApi.DRAWER_PREVIEW_ROWS || page.hasMore
    }

    /** Nothing to show and nothing wrong — the workspace genuinely has none. */
    val isEmpty: Boolean
        get() = !isLoading && errorMessage == null && items.isEmpty()

    /** A fetch failed but rows survive. The section keeps them and says so. */
    val isShowingStaleData: Boolean
        get() = errorMessage != null && items.isNotEmpty()

    companion object {
        /**
         * Empty rather than all-defaults, so a caller that forgets to pass a
         * section gets an honest "nothing here" instead of a silent
         * default-to-expanded one.
         */
        val Empty = ProjectsState(
            expanded = false,
            items = emptyList(),
            expandedItemIds = emptySet(),
            chats = emptyMap(),
            isLoading = false,
            errorMessage = null,
        )
    }
}

/**
 * The things a reader can do to the Projects section.
 *
 * [onOpenAllChats] and [onCreateTask] are **destinations** (or lead to one) and
 * the rest are not. That split is the whole drawer contract: a project row and
 * the section header reshape the list in place, only "See all chats" leaves,
 * and only a chat row closes the drawer. Naming them together is a small way of
 * keeping that visible at the call site.
 */
@Stable
class ProjectsActions(
    /** Fold the whole section away, or unfold it. Stays in the drawer. */
    val onToggleSection: () -> Unit,
    /** Fold one project open or shut. Stays in the drawer. */
    val onToggleItem: (String) -> Unit,
    /**
     * Leave the drawer for the project-chats screen. Closes it, because the
     * reader asked for a destination rather than a filter.
     */
    val onOpenAllChats: (workspaceId: String, itemId: String) -> Unit,
    val onRetry: () -> Unit,
    /**
     * Open the create flow for a project. Does **not** close the drawer: the
     * sheet takes over on top of it, and a memory create has to leave the reader
     * looking at the list their new row just appeared in.
     *
     * Takes the whole [ProjectSummary] rather than two ids because the flow
     * needs the item's `item_type` to decide whether to show a picker at all —
     * see [createTaskStartDecision] — and passing ids would make the caller
     * look the type up in a list it does not own.
     */
    val onCreateTask: (ProjectSummary) -> Unit = {},
) {
    companion object {
        val None = ProjectsActions(
            onToggleSection = {},
            onToggleItem = {},
            onOpenAllChats = { _, _ -> },
            onRetry = {},
            onCreateTask = {},
        )
    }
}

/**
 * The glyph for an `item_type`.
 *
 * The fallback is the point: a type the backend ships tomorrow must render as
 * *some* named row, never as a blank line the reader cannot tap.
 */
internal fun projectGlyph(itemType: String): ImageVector = when (itemType) {
    ProjectTypes.KANBAN -> Icons.Filled.ViewKanban
    ProjectTypes.AGENT -> Icons.Filled.SmartToy
    ProjectTypes.ROUTINE -> Icons.Filled.Autorenew
    ProjectTypes.DESIGN -> Icons.Filled.Brush
    // `folder` and anything unrecognised both land here.
    else -> Icons.Filled.Folder
}

/**
 * One project row: a glyph, a name, and a chevron.
 *
 * No count, on purpose — see [ProjectsState.shouldOfferSeeAllChats].
 */
@Composable
internal fun ProjectRow(
    project: ProjectSummary,
    expanded: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .testTag("project_row_${project.id}")
            .semantics {
                role = Role.Button
                contentDescription = "${project.displayName}. ${project.itemType} project"
                stateDescription = if (expanded) "Expanded" else "Collapsed"
            },
        // The same selected treatment a chat row uses, so "the thing you are
        // inside" looks the same whichever list you found it in.
        shape = RoundedCornerShape(12.dp),
        color = if (expanded) NalarField else Color.Transparent,
        contentColor = NalarText,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = projectGlyph(project.itemType),
                contentDescription = null,
                tint = NalarMuted,
                modifier = Modifier.size(16.dp),
            )
            Text(
                text = project.displayName,
                style = MaterialTheme.typography.bodyLarge,
                color = NalarText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = NalarDim,
                modifier = Modifier.size(16.dp),
                // Rotated rather than swapped for a different icon, so the row's
                // right-hand edge does not change width as it opens.
                // (No rotation applied: the glyph reads as a chevron either way
                // and rotating Compose's `Icon` needs a modifier the icon does
                // not take, so the expanded state is carried by semantics and
                // the row's fill.)
            )
        }
    }
}

/**
 * One chat under a project, or one chat on the project-chats screen.
 *
 * The same gesture as a recents row and the same call: `onChatSelected` then
 * `onOpenChat`. That is why a project needs no route of its own for the common
 * case — a task id *is* a session id, so this row opens the identical
 * destination the Recent list opens.
 */
@Composable
internal fun ProjectChatRow(
    chat: ProjectChat,
    selected: Boolean,
    isRunning: Boolean,
    nowEpochMillis: Long,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .testTag("project_chat_row_${chat.id}")
            .semantics(mergeDescendants = true) {
                contentDescription = buildString {
                    append(chat.displayName)
                    if (chat.hasTimestamp) {
                        append(", ")
                        append(formatRelativeTimeForAccessibility(chat.updatedAtEpochMillis, nowEpochMillis))
                    }
                    if (isRunning) append(", agent is working")
                }
            }
            .selectable(selected, role = Role.Tab, onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        color = if (selected) NalarAccent.copy(alpha = 0.16f) else Color.Transparent,
        contentColor = NalarText,
        border = if (selected) BorderStroke(1.dp, NalarAccent.copy(alpha = 0.36f)) else null,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = chat.displayName,
                    style = MaterialTheme.typography.bodyLarge,
                    color = NalarText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (chat.hasTimestamp) {
                    Text(
                        text = formatRelativeTime(chat.updatedAtEpochMillis, nowEpochMillis),
                        style = MaterialTheme.typography.labelMedium,
                        color = NalarMuted,
                    )
                }
            }

            if (isRunning) {
                androidx.compose.material3.CircularProgressIndicator(
                    // Decorative: "agent is working" is already in the merged
                    // content description, and announcing it twice is worse
                    // than not announcing it.
                    modifier = Modifier
                        .clearAndSetSemantics { }
                        .size(14.dp)
                        .testTag("project_chat_running_${chat.id}"),
                    strokeWidth = 2.dp,
                    color = NalarAccent,
                )
            }
        }
    }
}

/**
 * The one control in this feature that leaves the drawer.
 *
 * Words and a chevron, never a count. Two jobs in one row: it tells the reader
 * the list continues, and it is the route to reading it. A chevron is the
 * right affordance for both — the row goes somewhere.
 */
@Composable
internal fun SeeAllChatsRow(
    projectId: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .testTag("project_see_all_$projectId")
            .semantics {
                role = Role.Button
                contentDescription = "See all chats in this project"
            },
        shape = RoundedCornerShape(10.dp),
        color = NalarAccent.copy(alpha = 0.10f),
        contentColor = NalarText,
        border = BorderStroke(1.dp, NalarBorder),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "See all chats",
                style = MaterialTheme.typography.labelLarge,
                color = NalarAccent,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = NalarAccent,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
