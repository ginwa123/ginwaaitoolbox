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
     * The `mode` a kanban card create sends — the plain card, with no agent run.
     *
     * The route accepts three (`create`, `create_session`, `create_and_run`,
     * `kanban_tasks_create.zig:3-25`) and this app sends one. `create_and_run`
     * additionally needs a `queue_message` the reader never typed, and
     * `create_session` exists only to pair with it, so both would mean this app
     * inventing a prompt on the reader's behalf. See [createTaskBody].
     */
    const val KANBAN_MODE_CREATE = "create"

    /**
     * The other half of the web's split button.
     *
     * Not `create_session`: that mode exists so a card can be created *and* have
     * a sessions row stamped for a later run without a turn being queued, which
     * is not an action the form offers. The two the form offers are "create it"
     * and "create it and start the agent now".
     */
    const val KANBAN_MODE_CREATE_AND_RUN = "create_and_run"

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
    /**
     * Cold-start fallback for the drawer's "New Chat" row.
     *
     * `GET /api/workspaces/{ws}/items` already ensures the default on the
     * normal path, so this is rarely called — only when the app was open when
     * Migration 094 ran, so the loaded list predates `is_default`.
     */
    fun defaultProjectPath(workspaceId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/default-project")
    }

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
    /**
     * Parse the `POST /api/workspaces/{ws}/default-project` envelope:
     * `{"item": {…}, "created": true|false}`.
     *
     * Only the item is returned — the caller just needs a project to create
     * a chat in, and whether it had to be created is a detail of *how* it
     * arrived, not of what it is.
     */
    fun parseDefaultProject(body: String): ProjectSummary? {
        val item = JSONObject(body).optJSONObject("item") ?: return null
        val id = item.stringField("id")
        // A row without an id cannot be scoped to, so it is unusable.
        if (id.isEmpty()) return null
        return ProjectSummary(
            id = id,
            workspaceId = item.stringField("workspace_id"),
            itemType = item.stringField("item_type"),
            name = item.stringField("name"),
            path = item.stringField("path"),
            isDefault = item.optInt("is_default", 1) == 1,
        )
    }

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
                        // Migration 094 sends 0/1, not a JSON boolean, because
                        // the column is an INTEGER. Absent (a server older
                        // than the migration) reads as 0, i.e. an ordinary
                        // project — the safe default, since the row is still
                        // usable and the fallback endpoint can be called.
                        isDefault = item.optInt("is_default", 0) == 1,
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
     * `POST /api/workspaces/{ws}/items/{item}/kanban/tasks` — a card on a board.
     *
     * A *different* route, not a `task_type` on the ordinary one. The
     * kanban-scoped handler is what verifies the parent really is a kanban (404
     * otherwise), auto-assigns the card to the board's first column, and emits
     * the `kanban_task` SSE the board listens for
     * (`kanban_tasks_create.zig`). Posting a card to the plain `/tasks` route
     * would create the row and skip all three — a card that exists on the
     * server and never appears on the board until the next full reload.
     */
    fun createKanbanTaskPath(workspaceId: String, itemId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/kanban/tasks")
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
     *  - a kanban card carries `mode`, and carries **no** `task_type`: the
     *    kanban-scoped handler forces `standard` itself
     *    (`kanban_tasks_create.zig:169`), so sending one would be asserting a
     *    choice the reader never had.
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

            is CreateTaskRequest.KanbanTask -> {
                // `mode` is not optional and has no default: the handler
                // answers 400 without it (`kanban_tasks_create.zig:110`).
                // "create" is the plain card and does NOT start an agent;
                // "create_and_run" also inserts the sessions row and queues
                // `queue_message` as the first turn. Both are the web's two
                // halves of one split button.
                json.put(
                    "mode",
                    if (request.runAgent) KANBAN_MODE_CREATE_AND_RUN else KANBAN_MODE_CREATE,
                )
                json.put("name", request.name.trim())
                // Sent even when blank. The field is `?[]const u8` on the wire,
                // so omitting it and sending `""` are the same branch here — but
                // sending it makes the client's intent legible and keeps the body
                // identical to the desktop's for the same card.
                json.put("description", request.description)

                // The server's own rules, applied before the wire rather than
                // after: an invalid tag is a 400 that names no field, so the
                // form drops it and the reader never learns it existed.
                val tags = KanbanTags.normalize(request.tags)
                if (tags.isNotEmpty()) {
                    // A JSON *string* holding an array, not a nested array.
                    // `tags_validation.zig` parses `body.tags` as
                    // `std.json.Value` and refuses anything that is not an
                    // array; `JSONObject.put(key, JSONArray)` would be an array
                    // and `put(key, String)` is exactly what it expects.
                    json.put("tags", org.json.JSONArray(tags).toString())
                }

                // Migration 070 — the per-task project root. Sent even when
                // blank, because "" is the server's canonical "no override"
                // and omitting the key would mean NULL instead.
                json.put("cwd", request.cwd)

                // Migration 063. Always '0' or '1', never omitted and never a
                // boolean: the column is TEXT and the handler forwards it
                // verbatim (`kanban_tasks_create.zig:179`).
                json.put("is_auto_retry_until_stop", if (request.unattended) "1" else "0")

                if (request.runAgent) {
                    json.put("queue_message", request.queueMessage)
                    // The web sends this on create-and-run only ("Path A": the
                    // plain create has no sessions row of its own to stamp, so
                    // a profile sent there would be a choice the reader made
                    // and the server silently dropped).
                    json.put("selected_profile_model", request.profile)
                }

                // Base64 data URLs. `||` because that is the web's delimiter
                // (`api/index.ts` — `body.image_urls = images.join('||')`), and
                // the server splits on `|` filtering empty segments
                // (`image_urls_validation.zig:64`), so both spellings parse.
                val images = request.imageUrls.filter { it.isNotBlank() }
                if (images.isNotEmpty()) {
                    json.put("image_urls", images.joinToString("||"))
                }
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

    /**
     * `POST .../kanban/tasks` answers `201 {"task": {…}, "session": null}` — an
     * **envelope**, not a bare row.
     *
     * Unwrapping `task` is the whole job, and it has to happen here rather than
     * in the client: the two create routes share a response *type* on the
     * server (`http_response.TaskCreateResponse`) and differ only in whether
     * they wrap it. A parser that skipped the envelope would read a body whose
     * only keys are `task`/`session` as a row with no `id`, and report a
     * successful create as unreadable.
     *
     * Two fields [parseCreatedTask] can read are absent on this route, and both
     * are absorbed rather than invented:
     *
     *  - **no `updated_at` / `created_at`** — `TaskCreateResponse` carries
     *    neither (`kanban_tasks_create.zig:404-411`). The card therefore lands
     *    with `RecentsApi.UNKNOWN_TIMESTAMP`, which sorts it last. That is the
     *    honest answer: the server did not tell us when it was touched.
     *  - **no `task_type`** — the handler forced `standard` and does not echo
     *    it. Left null, which [ProjectChat.isOpenable] reads as openable, which
     *    is correct: `task_create.useCase` inserts the bare `sessions` row on
     *    this path (`task_create.zig:567`).
     */
    fun parseCreatedKanbanTask(body: String, projectId: String): ProjectChat? {
        val envelope = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }

        val task = envelope.optJSONObject("task") ?: return null
        val id = task.stringField("id")
        if (id.isEmpty()) return null

        return ProjectChat(
            id = id,
            projectId = projectId,
            name = task.stringField("name"),
            updatedAtEpochMillis = RecentsApi.UNKNOWN_TIMESTAMP,
        )
    }

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    /** The server clamps to 100 (`tasks_list.zig:37`); clamp again to be safe. */
    private const val MAX_LIMIT = 100
}
