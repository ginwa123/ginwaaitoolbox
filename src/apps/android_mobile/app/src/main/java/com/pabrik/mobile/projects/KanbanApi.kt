package com.pabrik.mobile.projects

import com.pabrik.mobile.network.UriEncoding
import com.pabrik.mobile.recents.stringField
import org.json.JSONObject

/**
 * The routes and the wire shapes the "New task" form needs **besides** the
 * create POST, which lives in [ProjectsApi.createTaskBody].
 *
 * Split out rather than folded into [ProjectsApi] because they belong to a
 * different concern: `ProjectsApi` is "the drawer's list of projects and the
 * chats under one", and a column is neither. What they share is the board, and
 * a second file is what stops the next reader from looking for a board's
 * columns under "projects".
 */
object KanbanApi {
    /**
     * `GET /api/workspaces/{ws}/items/{item}/kanban/columns` — the board's
     * columns, in board order.
     *
     * Fetched when the create form opens rather than with the project list,
     * because the drawer never needs a board's columns and this is the only
     * screen that does. One call per open, not per render.
     */
    fun columnsPath(workspaceId: String, itemId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/kanban/columns")
    }

    /**
     * `PATCH /api/workspaces/{ws}/items/{item}/tasks/{taskId}/move` — put a card
     * in a chosen column.
     *
     * A second request, and the reason is the backend's: `POST .../kanban/tasks`
     * has **no** `column_id` field, so the create auto-assigns the card to the
     * board's first column and the move is what overrides it. The web does
     * exactly the same two-step and says so (`KanbanView.vue:1176-1181`: "the
     * extra round trip is acceptable; the move is cheap").
     */
    fun moveTaskPath(workspaceId: String, itemId: String, taskId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/tasks/")
        append(UriEncoding.encode(taskId))
        append("/move")
    }

    /**
     * The move's body.
     *
     * [position] is the index inside the destination column, and 0 means "top
     * of the column" — which is what the reader means by picking a column on a
     * create form: the new card lands where the board is worked from.
     */
    fun moveTaskBody(columnId: String, position: Int = 0): String {
        val json = JSONObject()
        json.put("column_id", columnId)
        json.put("position", position)
        return json.toString()
    }

    /**
     * `GET /api/system/folder?action=list` — the **server's** home directory.
     *
     * Fetched only to prefill the git-worktree path, and it is the one endpoint
     * in this feature that is not under the board's workspace. It cannot be
     * replaced by the phone's own home: the agent that runs the worktree lives
     * on the backend's machine, so a phone-local `$HOME` would propose a path
     * that does not exist where the directory has to be created.
     */
    fun serverHomePath(): String = "/api/system/folder?action=list"

    /**
     * The board's columns, in the order the server gave them.
     *
     * `{"columns":[…], "count": N}` — the count is the array's own length
     * (`makeKanbanColumnListResponse` sets `count = cols.len`), so it is not a
     * total and must not be used to tell "all of them" from "some of them".
     *
     * A row with no id is dropped rather than rendered: a column the form
     * cannot move a card into is not a choice, and offering it produces a
     * create that silently lands in the wrong column.
     *
     * **null means "this is not a columns body"**, and it is deliberately not
     * the same as an empty list. `[]` is a board with no columns — a real answer
     * the form renders by showing no picker — while an HTML error page from a
     * proxy in front of the server is the absence of an answer, and collapsing
     * the two would report "this board is empty" when the truth is "we could
     * not ask". The caller turns null into an error and empty into a form.
     */
    fun parseColumns(body: String): List<KanbanColumn>? {
        val json = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }
        val array = json.optJSONArray("columns") ?: return null
        val columns = mutableListOf<KanbanColumn>()
        for (index in 0 until array.length()) {
            val entry = array.optJSONObject(index) ?: continue
            val id = entry.stringField("id")
            if (id.isEmpty()) continue
            columns += KanbanColumn(
                id = id,
                name = entry.stringField("name"),
                position = entry.optInt("position", index),
            )
        }
        return columns
    }

    /**
     * The `home` string out of the folder listing, or "" when the body carries
     * none.
     *
     * "" rather than null so the caller has one "unknown" value to branch on and
     * the prefill falls back to the `~` display instead of posting a literal
     * tilde to the agent's path validator.
     */
    fun parseServerHome(body: String): String {
        val json = try {
            JSONObject(body)
        } catch (_: Exception) {
            return ""
        }
        return json.stringField("home").trim()
    }
}
