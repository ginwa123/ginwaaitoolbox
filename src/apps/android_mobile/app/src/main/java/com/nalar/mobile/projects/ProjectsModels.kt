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
) {
    val displayName: String
        get() = name.trim().ifEmpty { "New Chat" }

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
