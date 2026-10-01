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
 * It mirrors the desktop's own rule as written at `Sidebar.vue:925-926`:
 *
 * > Kanban items handle "+ Add" locally inside KanbanView.vue (no picker —
 * > **kanban cards are always standard chats**; the picker is for non-kanban
 * > parents where the user might want a routine / memory / chat task).
 *
 * So:
 *
 *  - **agent** — an agent item *is* a chat container, so `+` makes a Standard
 *    Chat and opens it. No picker: Memory and Routine are not things you start
 *    an agent conversation from, and offering them would be noise.
 *  - **kanban** — [NameTask], the card form itself, with no step in between.
 *    Not [Pick]: a board has no memory files and no chat-versus-memory choice
 *    to make, so a sheet offering either is a sheet whose only option is the
 *    thing you already pressed `+` to reach. The web opens this form directly
 *    too — `KanbanView.vue` binds `+ Add` to `handleViewCreateTask`, which sets
 *    the column and opens the dialog with nothing between the press and the
 *    form (`KanbanView.vue:1213-1217`).
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

    /**
     * Open a form and wait for the reader to fill it in.
     *
     * Distinct from [Pick] rather than a flag on it, because a kanban form and
     * a two-card picker share no field and no exit. Naming the case forces the
     * render to say which set it meant.
     */
    data object NameTask : CreateTaskStartDecision

    /** This project does not take tasks. Do nothing at all. */
    data object NotAllowed : CreateTaskStartDecision
}

internal fun createTaskStartDecision(itemType: String): CreateTaskStartDecision =
    when (itemType) {
        ProjectTypes.AGENT -> CreateTaskStartDecision.Create(
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
        )
        ProjectTypes.KANBAN -> CreateTaskStartDecision.NameTask
        ProjectTypes.ROUTINE -> CreateTaskStartDecision.NotAllowed
        else -> CreateTaskStartDecision.Pick
    }

/**
 * Which step the create flow is on.
 *
 * A sealed type because the steps carry different data and have different
 * exits: [Picking] goes back to the drawer, [NamingMemory] goes back to the
 * picker, and [NamingTask] has nothing behind it at all. Two nullable fields
 * would allow "picking for project A, naming a memory for project B", which is
 * the state a reader cannot get out of.
 *
 * [NamingTask] is a separate case rather than a flag on [NamingMemory] for the
 * same reason the decisions are: a board's card form and a project's memory form
 * have no field in common, and a `when` that rendered one for the other would
 * be a create posted to the wrong endpoint.
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

    /**
     * The board card form, for one specific kanban project.
     *
     * [projectPath] is the board's own on-disk path, carried so the form can
     * prefill "Project root" with it — which is what the web does
     * (`KanbanTaskDetail.vue`: "Pre-populated from the parent kanban's path in
     * create mode"). Fetching it again inside the form would mean the dialog
     * renders once with no root and again with one, and a reader who typed a
     * title in between would be looking at a field that changed under them.
     */
    data class NamingTask(
        val workspaceId: String,
        val itemId: String,
        val projectName: String,
        val projectPath: String = "",
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

            CreateTaskStartDecision.NameTask -> step = CreateTaskStep.NamingTask(
                workspaceId = item.workspaceId,
                itemId = item.id,
                projectName = item.displayName,
                projectPath = item.path,
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
     * Submit the board card form.
     *
     * The whole [KanbanTaskForm] crosses here rather than a name and a
     * description, because the web's dialog collects nine more things and the
     * controller is the only place that knows which project the card belongs
     * to. A narrower signature would have every new field threaded through this
     * class as another parameter.
     *
     * The description is passed through untouched — the server stores it as the
     * card's prompt body and shows it verbatim on the card, so trimming it would
     * quietly edit what the reader wrote. The title is trimmed, matching every
     * other name in this flow and for the same reason
     * ([ProjectsApi.createTaskBody]).
     *
     * [canSubmitKanbanTask] gates this, so the button is already disabled for an
     * untitled card and this is not re-asked. It is still a `takeIf` rather than
     * a trust: a disabled button is a UI affordance, not an invariant.
     */
    fun submitTaskForm(form: KanbanTaskForm) {
        val current = step as? CreateTaskStep.NamingTask ?: return
        if (!canSubmitKanbanTask(form)) return
        // Closed here, not on a callback, for the reason [submitMemory] is:
        // this method is the only place the form can be submitted, so a form
        // left open after a successful create is a form stuck open forever.
        step = CreateTaskStep.Idle
        onCreate(
            current.workspaceId,
            current.itemId,
            form.toRequest(),
        )
    }

    /**
     * The two-field shorthand, for callers that have nothing else to say.
     *
     * Not the general path and not what the dialog uses — it exists so a
     * programmatic create of a bare card is one call rather than a constructed
     * form, and so the memory/chat forms and the card form read alike at the
     * call site.
     */
    fun submitTask(name: String, description: String) =
        submitTaskForm(KanbanTaskForm(name = name, description = description))

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
 * Whether a title alone is enough to create a card.
 *
 * The two-argument spelling of [canSubmitKanbanTask], kept because it is the
 * rule the *button* is bound to and a button should not have to build a whole
 * form to ask whether it is allowed to be bright.
 */
fun canSubmitTask(name: String): Boolean = canSubmitKanbanTask(KanbanTaskForm(name = name))

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
