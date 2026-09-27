package com.nalar.mobile.projects

import com.nalar.mobile.chat.optNullableString
import com.nalar.mobile.network.UriEncoding
import com.nalar.mobile.recents.RecentsApi
import com.nalar.mobile.recents.stringField
import org.json.JSONObject
import java.net.URLEncoder

/**
 * The drawer's two project endpoints, and the wire shapes that come back.
 *
 * `GET /api/workspaces/:workspace_id/items` for the section, and
 * `GET /api/workspaces/:workspace_id/items/:item_id/tasks` for one project's
 * chats. Both are read-only lists the desktop sidebar already consumes
 * (`api/index.ts:553-559` and `:677-728`), so neither is new to the server.
 *
 * `is_include_items` stays `false` on the workspaces call. Its server default
 * is `"true"` (`workspaces_list.zig:42`), which would return every workspace's
 * items *and* tasks in one round-trip — the whole feature in a single request.
 * We do not take it: it fans out to every workspace the user owns on every
 * refresh, to render one screen, and a phone is on a metered connection. The
 * desktop pays that cost; the two-call shape here does not.
 *
 * Auth is the `nalar_session` cookie and nothing else, same as
 * [com.nalar.mobile.recents.RecentsClient].
 */
object ProjectsApi {

    /**
     * Matches the server's own `DEFAULT_PAGE_SIZE` (`tasks_list.zig:33`).
     *
     * One page size serves both surfaces on purpose: the drawer renders a
     * 5-row preview out of this page and the project-chats screen renders the
     * whole of it, so opening "See all chats" after expanding a project costs
     * **zero** extra requests. Two page sizes would mean two cache entries per
     * project and a drawer-and-screen-disagree class of bug.
     */
    const val TASKS_PAGE_LIMIT = 20

    /**
     * How many of a project's chats the drawer shows before offering the rest.
     * A tuning value, not a wire one: on a 844dp phone five rows plus the
     * "See all chats" button fit without pushing the button off the bottom.
     */
    const val DRAWER_PREVIEW_ROWS = 5

    /**
     * `/api/workspaces/{id}/items` — the projects of one workspace.
     *
     * A function, not a `const` template, because the segment is encoded and
     * `UriEncoding.encode` is a function. An id containing `/` would otherwise
     * split into two path segments and land on a different route.
     */
    fun itemsPath(workspaceId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items")
    }

    /**
     * `/api/workspaces/{ws}/items/{item}/tasks` — one page of a project's chats.
     *
     * [cursor] is the server's own `next_cursor`, handed back verbatim. On this
     * endpoint it is `"<sort_value>|<id>"` — parse it, compare it or synthesize
     * it and pagination silently degrades. Round-tripping it is the only
     * supported way to get page 2+.
     */
    fun tasksPath(
        workspaceId: String,
        itemId: String,
        cursor: String? = null,
        limit: Int = TASKS_PAGE_LIMIT,
    ): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/tasks?sort_by=updated_at&direction=desc")
        append("&limit=")
        append(limit.coerceIn(1, MAX_LIMIT))
        // A blank cursor is indistinguishable from "first page" to the server,
        // so sending it would restart the list and re-serve page 1 forever.
        if (!cursor.isNullOrBlank()) {
            append("&cursor=")
            append(encodeQueryValue(cursor))
        }
    }

    /**
     * `{"items":[…],"count":N}` — every item of one workspace. No pagination:
     * the endpoint takes none.
     */
    fun parseItems(body: String): List<ProjectSummary> {
        val items = JSONObject(body).optJSONArray("items") ?: return emptyList()

        return buildList(items.length()) {
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                val id = item.stringField("id")
                // A row without an id cannot be scoped to, so it is unusable.
                if (id.isEmpty()) continue
                add(
                    ProjectSummary(
                        id = id,
                        workspaceId = item.stringField("workspace_id"),
                        // Unknown types are kept, not dropped: the UI maps them
                        // to a fallback glyph. Dropping them would hide a
                        // project the web app can see.
                        itemType = item.stringField("item_type"),
                        // Both nullable server-side; `stringField` maps an
                        // explicit null to "", and `displayName` turns that
                        // into "Untitled project" rather than a blank row.
                        name = item.stringField("name"),
                        path = item.stringField("path"),
                    ),
                )
            }
        }
    }

    /**
     * `{"tasks":[…],"count":N,"has_more":B,"next_cursor":S}` — one page.
     *
     * The terminator is [ProjectChatsPage.hasMore] and **never** the cursor, for
     * the same reason the recents pager does it: `next_cursor` is emitted
     * whenever the page was non-empty, *including the last one*, so its
     * presence says nothing about there being more.
     *
     * There is no `total` backstop here the way `/api/session` has one, because
     * this endpoint's `count` is the page length. So the guard against paging
     * forever is the empty-page case: a page that carries no rows while the
     * server claims there are more is a cursor that has stopped advancing, and
     * continuing would re-request the same window on every scroll.
     */
    fun parseProjectChatsPage(body: String, projectId: String): ProjectChatsPage {
        val root = JSONObject(body)
        val tasks = root.optJSONArray("tasks")

        val chats = buildList {
            if (tasks == null) return@buildList
            for (index in 0 until tasks.length()) {
                val task = tasks.optJSONObject(index) ?: continue
                // The task id IS the session id, so this is also the key the
                // chat route takes.
                val id = task.stringField("id")
                if (id.isEmpty()) continue
                add(
                    ProjectChat(
                        id = id,
                        projectId = projectId,
                        name = task.stringField("name"),
                        updatedAtEpochMillis = RecentsApi.parseTimestampEpochMillis(
                            task.stringField("updated_at"),
                        ) ?: RecentsApi.parseTimestampEpochMillis(
                            task.stringField("created_at"),
                        ) ?: RecentsApi.UNKNOWN_TIMESTAMP,
                    ),
                )
            }
        }

        val serverHasMore =
            if (root.isNull("has_more")) false else root.optBoolean("has_more", false)

        return ProjectChatsPage(
            chats = chats,
            hasMore = serverHasMore && chats.isNotEmpty(),
            nextCursor = root.optNullableString("next_cursor")?.takeIf { it.isNotBlank() },
        )
    }

    /**
     * Write-through merge for a page append: a same-id incoming row replaces
     * the one already held, order is preserved.
     *
     * Not defensive paranoia — a chat touched while the reader is between
     * pages moves up the ordering, so a page boundary can legitimately hand
     * back a row already on screen. Mirrors [RecentsApi.mergeChatsById].
     */
    fun mergeProjectChatsById(
        current: List<ProjectChat>,
        incoming: List<ProjectChat>,
    ): List<ProjectChat> {
        if (incoming.isEmpty()) return current
        val byId = LinkedHashMap<String, ProjectChat>(current.size + incoming.size)
        current.forEach { chat -> byId[chat.id] = chat }
        incoming.forEach { chat -> byId[chat.id] = chat }
        return byId.values.toList()
    }

    /**
     * `POST /api/workspaces/{ws}/items/{item}/tasks` — create a task.
     *
     * The same path [tasksPath] reads, on the other method. Creating does not
     * get its own route on the server (`main.zig:815` registers one POST
     * handler for both the drawer and the web app), so a client that invented
     * `/tasks/create` here would 404.
     */
    fun createTaskPath(workspaceId: String, itemId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/tasks")
    }

    /**
     * The JSON body for one [CreateTaskRequest].
     *
     * Field-for-field what the desktop's `api.createTask` sends
     * (`api/index.ts:863-960`), because the backend reads one shape:
     *
     *  - `name` is the task's display name. For a memory it is *also* the
     *    filename, and the two are sent as `name` and `memory_name` because the
     *    handler reads them separately (`task_create.zig:257`).
     *  - `task_type` is always explicit, never omitted. The server's default is
     *    `standard`, so leaving it off would be equivalent — but a body whose
     *    type is absent is a body whose meaning depends on a column default, and
     *    the desktop sends it too.
     *  - `memory_content` is sent for a memory and **nothing else** is sent for
     *    a standard chat. No `description`, no `is_auto_retry_until_stop`, no
     *    `tags`: those all have defined server-side defaults and sending them
     *    would mean this client is asserting choices the reader was never asked.
     *
     * The name is trimmed here. The desktop does not trim, and the difference
     * is only visible on a name the reader typed with stray spaces — where the
     * trimmed one is what they meant, and an untrimmed `.md` filename is a
     * filename with spaces in it that no `ls` output ever matches by eye.
     */
    fun createTaskBody(request: CreateTaskRequest): String {
        val json = JSONObject()
        when (request) {
            is CreateTaskRequest.StandardChat -> {
                json.put("name", request.name.trim())
                json.put("task_type", TaskTypes.STANDARD)
            }

            is CreateTaskRequest.Memory -> {
                val fileName = request.name.trim()
                json.put("name", fileName)
                json.put("task_type", TaskTypes.MEMORY)
                json.put("memory_name", fileName)
                json.put("memory_content", request.content)
            }
        }
        return json.toString()
    }

    /**
     * The one task object `POST .../tasks` returns, as a [ProjectChat].
     *
     * Not an array: the create handler answers with the row it just inserted
     * (`task_create.zig`'s `MemoryResponse` / `StandardResponse`), so there is
     * no envelope to unwrap and no way to get two rows.
     *
     * A task id is also the session id, which is the whole reason a created
     * chat is navigable without a second lookup — see [ProjectChat].
     *
     * Returns null when the body carries no id. A row that cannot be opened or
     * selected is worse than a failure the caller can report, so this refuses
     * rather than inventing one.
     */
    fun parseCreatedTask(body: String, projectId: String): ProjectChat? {
        val task = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }

        val id = task.stringField("id")
        if (id.isEmpty()) return null

        return ProjectChat(
            id = id,
            projectId = projectId,
            name = task.stringField("name"),
            // Prefer `updated_at` and fall back the same way the list parser
            // does, so a created row and a listed row of the same task are
            // ordered the same way in a merged list.
            updatedAtEpochMillis = RecentsApi.parseTimestampEpochMillis(
                task.stringField("updated_at"),
            ) ?: RecentsApi.parseTimestampEpochMillis(
                task.stringField("created_at"),
            ) ?: RecentsApi.UNKNOWN_TIMESTAMP,
            taskType = task.optNullableString("task_type"),
        )
    }

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    /** The server clamps to 100 (`tasks_list.zig:37`); clamp again to be safe. */
    private const val MAX_LIMIT = 100
}
