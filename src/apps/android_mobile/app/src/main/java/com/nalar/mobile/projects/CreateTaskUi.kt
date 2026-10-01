package com.nalar.mobile.projects

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Description
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackgroundRaised
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarField
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText

/**
 * The `+` that opens the create flow, drawn at the top of an unfolded project.
 *
 * A full-width row rather than a small glyph on the project row itself. The
 * project row is already a 48dp tap target that folds the list, so a second
 * target on it would either be too small to hit reliably or would swallow taps
 * meant for the fold; on a phone a 24dp `+` inside a row that also collapses is
 * a coin flip. The row below it is 44dp tall and does exactly one thing.
 */
@Composable
internal fun CreateTaskRow(
    projectName: String,
    isBusy: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        // Disabled while the create is in flight, so a second tap cannot become
        // a second "New Chat". The HomeViewModel guards this too — this is the
        // affordance, that is the invariant.
        enabled = !isBusy,
        modifier = modifier
            .fillMaxWidth()
            .testTag("create_task_row_$projectName")
            .semantics {
                role = Role.Button
                contentDescription = "Add a chat or a memory to $projectName"
            },
        shape = RoundedCornerShape(10.dp),
        color = Color.Transparent,
        contentColor = NalarText,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (isBusy) {
                CircularProgressIndicator(
                    modifier = Modifier
                        .size(16.dp)
                        .testTag("create_task_busy_$projectName"),
                    strokeWidth = 2.dp,
                    color = NalarAccent,
                )
            } else {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = null,
                    tint = NalarAccent,
                    modifier = Modifier.size(16.dp),
                )
            }
            Text(
                text = if (isBusy) "Creating…" else "New chat",
                style = MaterialTheme.typography.labelLarge,
                color = NalarAccent,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/**
 * The two cards, and nothing else.
 *
 * Two is the whole set, and the third that used to exist is deliberately not
 * here: per-task routines were deleted with their table (Migration 084) and
 * routines are now their own project type, so a "Routine" card would POST a
 * value the backend answers `400 RoutineTasksRemoved` for. The desktop's
 * `AddTaskPickerDialog` carries the same two.
 *
 * A bottom sheet rather than a dialog because the reader reached it from a
 * drawer that is still behind it, and a sheet that leaves its context visible is
 * the one a thumb can back out of without thinking.
 */
@Composable
fun CreateTaskPickerSheet(
    projectName: String,
    onPickStandardChat: () -> Unit,
    onPickMemory: () -> Unit,
    onDismiss: () -> Unit,
) = PickerSheetScaffold(projectName = projectName, onDismiss = onDismiss) {
    PickerCard(
        title = "Standard Chat",
        detail = "Starts a conversation you can write in right away.",
        glyph = Icons.Filled.ChatBubbleOutline,
        testTag = "create_task_pick_standard",
        onClick = onPickStandardChat,
    )
    PickerCard(
        title = "Memory",
        detail = "Saves a markdown file the agent reads on its next run here.",
        glyph = Icons.Filled.Description,
        testTag = "create_task_pick_memory",
        onClick = onPickMemory,
    )
}

/**
 * The sheet chrome both pickers share: the "Add to …" heading, the card list,
 * and the drag handle a `ModalBottomSheet` puts above them.
 *
 * @param sheetTestTag lets a UI test name the sheet it is driving. Only one
 *   sheet is left, but the tag is still named rather than inlined so the test
 *   that drives it reads the same way as every other test tag in this file.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickerSheetScaffold(
    projectName: String,
    onDismiss: () -> Unit,
    sheetTestTag: String = "create_task_picker",
    cards: @Composable ColumnScope.() -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = NalarBackgroundRaised,
        modifier = Modifier.testTag(sheetTestTag),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "Add to $projectName",
                style = MaterialTheme.typography.titleMedium,
                color = NalarText,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            cards()
        }
    }
}

@Composable
private fun PickerCard(
    title: String,
    detail: String,
    glyph: ImageVector,
    testTag: String,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .testTag(testTag)
            .semantics {
                role = Role.Button
                contentDescription = "$title. $detail"
            },
        shape = RoundedCornerShape(12.dp),
        color = NalarField,
        contentColor = NalarText,
        border = BorderStroke(1.dp, NalarBorder),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                imageVector = glyph,
                contentDescription = null,
                tint = NalarAccent,
                modifier = Modifier.size(20.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = NalarText,
                )
                Text(
                    text = detail,
                    style = MaterialTheme.typography.labelMedium,
                    color = NalarMuted,
                )
            }
        }
    }
}

/**
 * The memory form: a file name and a body.
 *
 * The name is the **filename**, not a title, and the field says so. The backend
 * writes `<project.path>/.nalar/memories/<name>` and stores that same string as
 * the task's display name, so asking for a separate title would mean two names
 * for one file and a row in the drawer whose label is not the file the reader
 * will later look for. The desktop's `AddMemoryDialog` asks for the same thing
 * the same way.
 *
 * The `.md` requirement is in the label rather than in an error that appears
 * after a failed submit: every one of these three rules is knowable before
 * typing, and a rule the reader can read is better than a rule they discover.
 */
@Composable
fun NewMemoryDialog(
    projectName: String,
    isSubmitting: Boolean,
    errorMessage: String?,
    onSubmit: (name: String, content: String) -> Unit,
    onBack: () -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var content by remember { mutableStateOf("") }
    val canSubmit = canSubmitMemory(name, content) && !isSubmitting

    androidx.compose.material3.AlertDialog(
        onDismissRequest = { if (!isSubmitting) onDismiss() },
        modifier = Modifier.testTag("create_memory_dialog"),
        containerColor = NalarBackgroundRaised,
        title = {
            Text(
                text = "New memory in $projectName",
                style = MaterialTheme.typography.titleMedium,
                color = NalarText,
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    // Not `enabled = !isSubmitting`: a field that goes dead the
                    // instant Submit is pressed loses focus and the keyboard,
                    // and on a slow network that is a visible hiccup on a form
                    // that is about to close anyway. Read-only says the same
                    // thing without the flicker.
                    readOnly = isSubmitting,
                    singleLine = true,
                    label = { Text("File name (must end in .md)") },
                    placeholder = { Text("my-memory.md") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("create_memory_name"),
                    colors = fieldColors(),
                )
                OutlinedTextField(
                    value = content,
                    onValueChange = { content = it },
                    readOnly = isSubmitting,
                    label = { Text("Content") },
                    modifier = Modifier
                        .fillMaxWidth()
                        // Tall enough to write in. A one-line field for a body
                        // the agent will read in full is a field nobody fills in.
                        .heightIn(min = 120.dp)
                        .testTag("create_memory_content"),
                    colors = fieldColors(),
                )
                if (errorMessage != null) {
                    Text(
                        text = errorMessage,
                        style = MaterialTheme.typography.labelMedium,
                        color = NalarError,
                        modifier = Modifier.testTag("create_task_error"),
                    )
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { onSubmit(name, content) },
                enabled = canSubmit,
                modifier = Modifier.testTag("create_memory_submit"),
                colors = ButtonDefaults.buttonColors(
                    containerColor = NalarAccent,
                    contentColor = NalarBackgroundRaised,
                ),
            ) {
                Text(if (isSubmitting) "Creating…" else "Create")
            }
        },
        dismissButton = {
            // "Back" rather than "Cancel": there is a step behind this form, and
            // a button labelled Cancel invites the reader to close the flow when
            // what they mean is "not this one, the other one".
            TextButton(
                onClick = onBack,
                enabled = !isSubmitting,
                modifier = Modifier.testTag("create_memory_back"),
            ) {
                Text("Back", color = NalarMuted)
            }
        },
    )
}

@Composable
private fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = NalarText,
    unfocusedTextColor = NalarText,
    focusedBorderColor = NalarAccent,
    unfocusedBorderColor = NalarBorder,
    focusedLabelColor = NalarAccent,
    unfocusedLabelColor = NalarMuted,
    cursorColor = NalarAccent,
)

/**
 * Renders whichever step [controller] is on, over whatever is already there.
 *
 * One host for both entry points — the drawer's `+` and the project screen's
 * `+` — so there is a single create flow in the app rather than two that agree
 * today. It composes nothing when the flow is [CreateTaskStep.Idle], so calling
 * it unconditionally costs one state read.
 *
 * Every step gets a case here, so a step added to [CreateTaskStep] without a
 * branch is a compile error rather than a form that silently does not open.
 *
 * @param kanbanData what the board's form needs that the form cannot fetch for
 *   itself. Empty is fine: a create needs none of it.
 * @param onRequestKanbanData fired once per open of the board's form, so the
 *   columns, the profiles and the server home arrive while the reader is typing
 *   a title rather than after they press commit. Keyed on the step, so a form
 *   that is already open is not re-fetched on every recomposition.
 */
@Composable
fun CreateTaskHost(
    controller: CreateTaskController,
    isSubmitting: Boolean,
    errorMessage: String?,
    kanbanData: NewTaskDialogData = NewTaskDialogData(),
    onRequestKanbanData: (workspaceId: String, itemId: String) -> Unit = { _, _ -> },
) {
    when (val step = controller.step) {
        CreateTaskStep.Idle -> Unit

        is CreateTaskStep.Picking -> CreateTaskPickerSheet(
            projectName = step.projectName,
            onPickStandardChat = controller::pickStandardChat,
            onPickMemory = controller::pickMemory,
            onDismiss = controller::dismiss,
        )

        is CreateTaskStep.NamingTask -> {
            LaunchedEffect(step.workspaceId, step.itemId) {
                onRequestKanbanData(step.workspaceId, step.itemId)
            }
            NewTaskDialog(
                projectName = step.projectName,
                defaultCwd = step.projectPath,
                data = kanbanData,
                isSubmitting = isSubmitting,
                errorMessage = errorMessage,
                onSubmit = controller::submitTaskForm,
                onClose = controller::dismiss,
            )
        }

        is CreateTaskStep.NamingMemory -> NewMemoryDialog(
            projectName = step.projectName,
            isSubmitting = isSubmitting,
            errorMessage = errorMessage,
            onSubmit = controller::submitMemory,
            onBack = controller::backToPicker,
            onDismiss = controller::dismiss,
        )
    }
}
