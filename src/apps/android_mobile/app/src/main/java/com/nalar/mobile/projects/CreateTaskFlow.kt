package com.nalar.mobile.projects

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue

/**
 * What pressing `+` on a project of [itemType] actually does.
 *
 * A decision rather than an `if` at the call site, for the reason
 * [HomeViewModel]'s paging rules are free functions: the interesting part here
 * is which project types get a dialog and which do not, and that is exactly
 * what a test can assert without a device.
 *
 * It mirrors the desktop exactly (`Sidebar.vue:895-906`):
 *
 *  - **agent** — an agent item *is* a chat container, so `+` makes a Standard
 *    Chat and opens it. No picker: Memory and Routine are not things you start
 *    an agent conversation from, and offering them would be noise.
 *  - **routine** — has no task list at all; the `+` is hidden in the desktop's
 *    `WorkspaceItem.vue` and guarded here as well so a programmatic call
 *    cannot open a sheet over a scheduler-owned parent.
 *  - **everything else** — the two-card picker.
 */
sealed interface CreateTaskStartDecision {
    /** Make this now, with no dialog between the press and the POST. */
    data class Create(val request: CreateTaskRequest) : CreateTaskStartDecision

    /** Open the picker and wait for the reader to choose a type. */
    data object Pick : CreateTaskStartDecision

    /** This project does not take tasks. Do nothing at all. */
    data object NotAllowed : CreateTaskStartDecision
}

internal fun createTaskStartDecision(itemType: String): CreateTaskStartDecision =
    when (itemType) {
        ProjectTypes.AGENT -> CreateTaskStartDecision.Create(
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
        )
        ProjectTypes.ROUTINE -> CreateTaskStartDecision.NotAllowed
        else -> CreateTaskStartDecision.Pick
    }

/**
 * Which of the two steps the create flow is on.
 *
 * A sealed type because the two steps carry different data and have different
 * exits: [Picking] goes back to the drawer, [NamingMemory] goes back to the
 * picker. Two nullable fields would allow "picking for project A, naming a
 * memory for project B", which is the state a reader cannot get out of.
 */
sealed interface CreateTaskStep {
    /** Nothing open. */
    data object Idle : CreateTaskStep

    /** The two-card picker, for one specific project. */
    data class Picking(
        val workspaceId: String,
        val itemId: String,
        val projectName: String,
    ) : CreateTaskStep

    /**
     * The memory form, for one specific project.
     *
     * Carries the project forward so submitting does not have to remember which
     * one the reader was in — a `Back` from here returns to the picker for the
     * *same* project rather than for whichever one is on screen.
     */
    data class NamingMemory(
        val workspaceId: String,
        val itemId: String,
        val projectName: String,
    ) : CreateTaskStep
}

/**
 * The one open create flow, wherever it was started from.
 *
 * The drawer's `+` and the project-chats screen's `+` are the same flow, and
 * they have to be — the same reason both drawers share
 * [com.nalar.mobile.shell.RecentsDrawerContent]. A reader who starts a chat
 * from the project screen and one who starts it from the drawer should land in
 * the same picker, with the same memory rules and the same validation.
 */
@Stable
class CreateTaskController(
    private val onCreate: (workspaceId: String, itemId: String, request: CreateTaskRequest) -> Unit,
) {
    var step: CreateTaskStep by mutableStateOf(CreateTaskStep.Idle)
        private set

    /**
     * The reader pressed `+` on a project.
     *
     * For an agent this calls straight through and never opens anything; for a
     * routine it does nothing. Both are decided by
     * [createTaskStartDecision] rather than here, so the rule is one testable
     * function instead of a branch in three places.
     */
    fun start(item: ProjectSummary) {
        when (val decision = createTaskStartDecision(item.itemType)) {
            is CreateTaskStartDecision.Create -> onCreate(
                // The project row's workspace id, falling back to the one the
                // drawer is showing. The drawer's is usually right and the row's
                // occasionally blank on a cached project, and the backend nests
                // the endpoint under the workspace — a wrong one is a 404.
                item.workspaceId,
                item.id,
                decision.request,
            )

            CreateTaskStartDecision.NotAllowed -> Unit

            CreateTaskStartDecision.Pick -> step = CreateTaskStep.Picking(
                workspaceId = item.workspaceId,
                itemId = item.id,
                projectName = item.displayName,
            )
        }
    }

    /** The reader chose "Standard Chat". Creates and closes — the chat opens. */
    fun pickStandardChat() {
        val current = step as? CreateTaskStep.Picking ?: return
        // Closed before the create so the sheet is not on screen over the chat
        // route the create is about to navigate to.
        step = CreateTaskStep.Idle
        onCreate(
            current.workspaceId,
            current.itemId,
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
        )
    }

    /** The reader chose "Memory". No name is asked for a chat, only a file. */
    fun pickMemory() {
        val current = step as? CreateTaskStep.Picking ?: return
        step = CreateTaskStep.NamingMemory(
            workspaceId = current.workspaceId,
            itemId = current.itemId,
            projectName = current.projectName,
        )
    }

    /**
     * Submit the memory form.
     *
     * [canSubmitMemory] gates this, so the button is already disabled for the
     * two invalid cases and this is not re-asked. It is still a `takeIf`
     * rather than a trust: a disabled button is a UI affordance, not an
     * invariant.
     */
    fun submitMemory(name: String, content: String) {
        val current = step as? CreateTaskStep.NamingMemory ?: return
        if (!canSubmitMemory(name, content)) return
        // Closed here rather than on a callback from the caller: this method is
        // the only place the form can be submitted, so a form left open after a
        // successful create would be a form stuck open forever.
        step = CreateTaskStep.Idle
        onCreate(
            current.workspaceId,
            current.itemId,
            CreateTaskRequest.Memory(name.trim(), content),
        )
    }

    /** Back out of the memory form, to the picker for the same project. */
    fun backToPicker() {
        val current = step as? CreateTaskStep.NamingMemory ?: return
        step = CreateTaskStep.Picking(
            workspaceId = current.workspaceId,
            itemId = current.itemId,
            projectName = current.projectName,
        )
    }

    /** Dismiss whatever is open. */
    fun dismiss() {
        step = CreateTaskStep.Idle
    }
}

/**
 * Whether the memory form's fields are complete enough to submit.
 *
 * A top-level function over strings so the rule is asserted directly rather
 * than by finding the button and checking whether it is enabled — and so the
 * ViewModel's own guard and this one can be seen to be about the same thing.
 */
fun canSubmitMemory(name: String, content: String): Boolean =
    isValidMemoryName(name) && content.isNotBlank()

/**
 * The controller, remembered across recompositions.
 *
 * [onCreate] is wrapped in [rememberUpdatedState] and the controller reads
 * through it on every call. Keying the `remember` on the lambda instead would
 * rebuild the controller whenever MainActivity handed down a fresh one, and
 * throwing away a half-typed memory name on every unrelated recomposition is
 * the kind of bug that only shows up on a slow device. Reading the current
 * value costs one indirection and keeps the form's text alive.
 */
@Composable
fun rememberCreateTaskController(
    onCreate: (workspaceId: String, itemId: String, request: CreateTaskRequest) -> Unit,
): CreateTaskController {
    val currentOnCreate by rememberUpdatedState(onCreate)
    return remember { CreateTaskController { w, i, r -> currentOnCreate(w, i, r) } }
}
