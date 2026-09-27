package com.nalar.mobile.projects

/**
 * The known `item_type` values, kept as plain strings because that is what the
 * wire sends and what the UI has to tolerate.
 *
 * A project row is rendered from [ProjectSummary.itemType] through a `when` in
 * the UI with a fallback for anything unrecognised. That fallback is not
 * defensive padding: a new `item_type` shipped by the backend tomorrow must
 * render as *some* named row, never as a blank line the user cannot tap.
 */
object ProjectTypes {
    const val KANBAN = "kanban"
    const val AGENT = "agent"
    const val ROUTINE = "routine"
    const val DESIGN = "design"

    /**
     * Legacy. The Vue sidebar still special-cases it (it lists files on disk
     * through `GET /api/system/folder?action=list&path=…`), but the menu row
     * that creates one is disabled with the tooltip "Coming soon"
     * (`ProjectsList.vue:421-434`) — nothing can make one any more. Here it is
     * simply a project whose chats expand the same as any other's.
     */
    const val FOLDER = "folder"
}

/**
 * One row of the drawer's Projects section: a `workspace_items` row.
 *
 * Deliberately *not* called a "folder" or a "board" — the five types are one
 * list here, and the UI only distinguishes them by glyph.
 */
data class ProjectSummary(
    val id: String,
    val workspaceId: String,
    val itemType: String,
    val name: String,
    /** On-disk cwd. Empty when the server sent null; unused by this feature. */
    val path: String = "",
) {
    /**
     * The server's `name` is nullable, and `stringField` maps an explicit JSON
     * null to `""`. A nameless row that renders as a blank line is invisible
     * and untappable, so it gets the same wording Vue uses
     * (`WorkspaceItem.vue:628-630`).
     */
    val displayName: String
        get() = name.trim().ifEmpty { "Untitled project" }
}

/**
 * One chat belonging to a project — a `workspace_item_tasks` row.
 *
 * [id] **is the session id.** The backend joins the two tables on it and says
 * so in its own comment (`http_response.zig`, "where `task.id == session.id`
 * per the project convention"); the Vue sidebar relies on it by routing a task
 * tap to `/app/{ws}/projects/{pid}/chat/{taskId}`. That is why a project
 * expands straight into openable chats with no join and no second lookup, and
 * why opening one calls the *same* `onChatSelected(sessionId)` a recents row
 * calls.
 */
data class ProjectChat(
    val id: String,
    val projectId: String,
    val name: String,
    val updatedAtEpochMillis: Long,
    /**
     * The server's `task_type`. `null` for a chat this app learned about from a
     * list endpoint that does not report the column.
     *
     * A created memory task is **not** a chat and has no session id, so the
     * list and this row cannot tell them apart on any other field: both carry a
     * name, an id and a timestamp. Without this the drawer would render a
     * memory file as a chat and offer to open it, and tapping it would take the
     * reader to a transcript that cannot exist.
     */
    val taskType: String? = null,
) {
    val displayName: String
        get() = name.trim().ifEmpty { TaskTypes.DEFAULT_NEW_CHAT_NAME }

    /**
     * Whether this row is a destination.
     *
     * False for a memory task, which is a `.md` file on disk: the agent reads
     * it on its next run and there is nothing to open.
     */
    val isOpenable: Boolean
        get() = taskType == null || taskType == TaskTypes.STANDARD

    /**
     * False when no timestamp parsed, so the row renders without a relative
     * label rather than claiming the chat is decades old. Mirrors
     * [com.nalar.mobile.recents.ChatSummary.hasTimestamp].
     */
    val hasTimestamp: Boolean
        get() = updatedAtEpochMillis > 0L
}

/**
 * One page of a project's chats, plus the two fields the scroll needs.
 *
 * There is deliberately **no `total`**. The backend's `count` on this endpoint
 * is the length of the page just returned, not a filtered row count (unlike
 * `/api/session`, where `total` really is a total) — so no count is knowable
 * without paging the whole list, which is why this feature prints no numbers.
 * See the plan's "The one number we refuse to print".
 */
data class ProjectChatsPage(
    val chats: List<ProjectChat>,
    val hasMore: Boolean,
    /** The server's own resume value. Hand it back verbatim; never synthesize. */
    val nextCursor: String?,
)

/**
 * The `task_type` values `POST .../tasks` accepts, and the one name this app
 * creates chats under.
 *
 * A third type used to exist. Per-task routines were deleted with their table
 * (Migration 084) and routines became first-class workspace items instead, so
 * `routine` is not offered here — offering it would POST a value the backend
 * answers `400 RoutineTasksRemoved` for. The desktop's picker carries the same
 * two cards for the same reason.
 */
object TaskTypes {
    const val STANDARD = "standard"
    const val MEMORY = "memory"

    /**
     * The name a chat is created under when the reader did not type one.
     *
     * Matches the desktop's `DEFAULT_NEW_CHAT_NAME` (`Sidebar.vue:82`) exactly.
     * It is deliberately not a timestamp: the reader is going to see this string
     * again after their first message, and the backend's own rename-on-first-
     * message convention replaces it either way.
     */
    const val DEFAULT_NEW_CHAT_NAME = "New Chat"
}

/**
 * What the reader asked to create under a project.
 *
 * A sealed type rather than nullable fields, because the two variants have
 * genuinely different shapes: a standard chat needs a name, a memory needs a
 * filename *and* a body, and a memory must never navigate. Encoding that in one
 * `CreateTaskRequest(name, memoryName?, content?)` is how a memory ends up
 * created with no body because the caller left a field null.
 */
sealed interface CreateTaskRequest {
    /**
     * An ordinary chat. Creates and opens a session, exactly like the desktop's
     * `createAndOpenStandardChat`.
     */
    data class StandardChat(val name: String) : CreateTaskRequest

    /**
     * A local memory file scoped to the project's directory.
     *
     * [name] is the `.md` filename and doubles as the task's display name —
     * the backend writes `<project.path>/.nalar/memories/<name>` and inserts a
     * row carrying that same string, so there is no second label to keep in
     * step. A memory task has no session and is never opened.
     */
    data class Memory(val name: String, val content: String) : CreateTaskRequest

    /** Whether a successful create is a destination the reader should be sent to. */
    val opensChat: Boolean
        get() = this is StandardChat
}

/**
 * The memory filename rules, mirrored from the backend's `isValidMemoryName`
 * (`src/modules/agent/tools/memories.zig:425`).
 *
 * Reimplemented here rather than imported — the two are in different languages
 * and different processes — so the drift risk is real and worth the comment
 * naming the exact source. Every branch is the server's, including the trim:
 * `"  a.md  "` is valid there because it trims first, and validating the
 * untrimmed string here would reject a name the server would have accepted.
 *
 * Checking this before the POST buys a same-screen error message instead of a
 * round trip to be told what was already obvious; the server still validates,
 * because a native client is not a trusted one.
 */
fun isValidMemoryName(name: String): Boolean {
    val trimmed = name.trim()
    if (trimmed.isEmpty()) return false
    if (!trimmed.endsWith(".md")) return false
    if (trimmed.contains('/') || trimmed.contains('\\')) return false
    if (trimmed.contains("..")) return false
    return true
}
