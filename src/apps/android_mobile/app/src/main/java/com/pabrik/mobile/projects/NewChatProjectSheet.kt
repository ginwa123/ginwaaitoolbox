package com.pabrik.mobile.projects

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/**
 * The projects a new chat can be created in, from [projects].
 *
 * A pure function so the rule is asserted without a device — and there is a
 * rule, which is the point. A chat is a `workspace_item_tasks` row, so it
 * belongs to a project, and the one project type that has no task list at all
 * is [ProjectTypes.ROUTINE] (a routine is scheduled, not conversed with).
 * Offering it would POST into a parent the backend does not accept tasks for.
 *
 * **The filter is applied here rather than at the row**, for the same reason
 * the drawer's own `+` is guarded in
 * [createTaskStartDecision]: a row that is filtered by the caller is a row
 * that a future caller forgets to filter.
 */
fun projectsThatTakeAChat(projects: List<ProjectSummary>): List<ProjectSummary> =
    projects.filterNot { it.itemType == ProjectTypes.ROUTINE }

/**
 * Which project, if any, a new chat can start in.
 *
 * A count, not a list, because the two callers want opposite things from the
 * same fact: the sheet needs to know whether to draw a chooser or an
 * explanation, and the button needs to know whether it is worth being
 * tappable. Both are `isNotEmpty()` over the same list, so this exists to
 * make that one reading.
 */
fun newChatProjectCount(projects: List<ProjectSummary>): Int =
    projectsThatTakeAChat(projects).size

/**
 * "Which project?" — the one step between pressing `+ New chat` and a `POST`.
 *
 * A new chat cannot be created "in the app": it is a task row, and every task
 * endpoint in the backend is nested under `/api/workspaces/:id/items/:id`. So
 * the press has to become a choice, and this is that choice.
 *
 * Every row creates a **standard chat directly** — no Standard/Memory picker
 * in between, unlike the drawer's `+`. The button is labelled "New chat", so
 * asking "chat or memory?" after it would be answering a question the label
 * already settled. The drawer's `+` has no such label, which is why it keeps
 * the two-card picker.
 *
 * A bottom sheet rather than a dialog for the same reason
 * [CreateTaskPickerSheet] is one: the reader came from a chat, and a sheet
 * leaves that transcript visible behind it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewChatProjectSheet(
    projects: List<ProjectSummary>,
    onProjectPicked: (ProjectSummary) -> Unit,
    onDismiss: () -> Unit,
) {
    val candidates = projectsThatTakeAChat(projects)
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = PabrikBackgroundRaised,
        modifier = Modifier.testTag("new_chat_project_sheet"),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = "New chat in…",
                style = MaterialTheme.typography.titleMedium,
                color = PabrikText,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )

            if (candidates.isEmpty()) {
                // The honest answer when there is nothing to choose from. A
                // sheet with an empty list under a "New chat" title is a bug
                // report with no error message attached.
                Text(
                    text = "No projects here yet. Create one in the desktop app, " +
                        "then come back for a new chat.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = PabrikMuted,
                    modifier = Modifier
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                        .testTag("new_chat_no_projects"),
                )
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 360.dp)
                        .testTag("new_chat_project_list"),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    items(candidates, key = { it.id }) { project ->
                        NewChatProjectRow(
                            project = project,
                            onClick = { onProjectPicked(project) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun NewChatProjectRow(
    project: ProjectSummary,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .testTag("new_chat_project_${project.id}")
            .semantics {
                role = Role.Button
                contentDescription = "New chat in ${project.displayName}"
            },
        shape = RoundedCornerShape(12.dp),
        color = PabrikField,
        contentColor = PabrikText,
        border = BorderStroke(1.dp, PabrikBorder),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.ChatBubbleOutline,
                contentDescription = null,
                tint = PabrikAccent,
                modifier = Modifier.size(20.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = project.displayName,
                    style = MaterialTheme.typography.bodyLarge,
                    color = PabrikText,
                )
                // The type is shown because two projects can share a name
                // across types in a workspace, and "which one" is exactly the
                // question this sheet is asking.
                Text(
                    text = project.itemType.ifBlank { "project" },
                    style = MaterialTheme.typography.labelMedium,
                    color = PabrikDim,
                )
            }
        }
    }
}
