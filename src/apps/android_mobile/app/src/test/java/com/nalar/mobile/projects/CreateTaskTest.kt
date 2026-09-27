package com.nalar.mobile.projects

import com.nalar.mobile.auth.AuthHttpResponse
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.auth.SessionStore
import com.nalar.mobile.recents.HomeViewModel
import com.nalar.mobile.recents.RecentsClient
import com.nalar.mobile.recents.RecentsResult
import com.nalar.mobile.testing.InMemoryLastPositionStore
import com.nalar.mobile.testing.InMemoryProjectsCache
import com.nalar.mobile.testing.InMemoryRecentsCache
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// ─── The wire shapes ───────────────────────────────────────────────────────────

/**
 * The request and response the create endpoint is read by.
 *
 * These are the assertions that would catch a backend change, because they
 * state the field *names* rather than the behaviour around them. `task_create.zig`
 * reads `name`, `task_type`, `memory_name` and `memory_content`; a client that
 * renames one of them compiles perfectly and 400s on a device.
 */
class CreateTaskWireTest {

    @Test
    fun theCreatePathIsTheSameRouteTheListReads() {
        // Creating does not get its own endpoint on the server — main.zig:815
        // registers one POST handler on the same path the drawer GETs. A
        // `/tasks/create` variant would 404 and look like a permissions problem.
        assertEquals(
            "/api/workspaces/ws_1/items/item_1/tasks",
            ProjectsApi.createTaskPath("ws_1", "item_1"),
        )
    }

    @Test
    fun thePathEncodesBothIds() {
        // An id containing `/` would split into two path segments and land on a
        // different route — a 404 that reads as "not found" rather than as a
        // client bug.
        assertEquals(
            "/api/workspaces/w%20s/items/a%2Fb/tasks",
            ProjectsApi.createTaskPath("w s", "a/b"),
        )
    }

    @Test
    fun aStandardChatSendsTheNameAndItsType() {
        val body = JSONObject(ProjectsApi.createTaskBody(CreateTaskRequest.StandardChat("New Chat")))

        assertEquals("New Chat", body.getString("name"))
        assertEquals(TaskTypes.STANDARD, body.getString("task_type"))
        // A standard chat carries nothing else. `memory_content` on a standard
        // task would be a field the handler ignores, and `is_auto_retry_until_stop`
        // would assert an unattended run the reader never asked for.
        assertFalse(body.has("memory_name"))
        assertFalse(body.has("memory_content"))
        assertFalse(body.has("is_auto_retry_until_stop"))
        assertFalse(body.has("tags"))
    }

    @Test
    fun theDefaultChatNameIsTheOnesTheDesktopUses() {
        // Sidebar.vue:82. A different string here would mean a chat created on a
        // phone is not named what a chat created on the web is, and the
        // rename-on-first-message convention is keyed off nothing in particular
        // — so the two would just disagree forever.
        assertEquals("New Chat", TaskTypes.DEFAULT_NEW_CHAT_NAME)
    }

    @Test
    fun aMemorySendsItsFilenameTwice() {
        // `name` is the display name and `memory_name` is the file, and the
        // handler reads them separately (task_create.zig:257). Sending only one
        // is a memory task with a null filename the server rejects.
        val body = JSONObject(
            ProjectsApi.createTaskBody(CreateTaskRequest.Memory("notes.md", "# hi")),
        )

        assertEquals("notes.md", body.getString("name"))
        assertEquals("notes.md", body.getString("memory_name"))
        assertEquals("# hi", body.getString("memory_content"))
        assertEquals(TaskTypes.MEMORY, body.getString("task_type"))
    }

    @Test
    fun theFilenameIsTrimmed() {
        // The desktop does not trim. The difference is only visible on a name
        // with stray spaces, where the trimmed one is what the reader meant and
        // an untrimmed `.md` file is one no `ls` output matches by eye.
        val body = JSONObject(
            ProjectsApi.createTaskBody(CreateTaskRequest.Memory("  notes.md  ", "x")),
        )
        assertEquals("notes.md", body.getString("memory_name"))
    }

    @Test
    fun theCreatedTaskBecomesAProjectChatKeyedByItsOwnId() {
        val created = ProjectsApi.parseCreatedTask(
            body = """{"id":"task_9","name":"New Chat","workspace_item_id":"item_1",""" +
                """"task_type":"standard","session_id":null,""" +
                """"created_at":"2026-09-26 05:12:37","updated_at":"2026-09-26 05:12:40"}""",
            projectId = "item_1",
        )

        // The task id IS the session id (http_response.zig says so in its own
        // comment), which is the only reason a created chat is navigable with no
        // second lookup.
        assertEquals("task_9", created?.id)
        assertEquals("item_1", created?.projectId)
        assertEquals("New Chat", created?.displayName)
        assertEquals(TaskTypes.STANDARD, created?.taskType)
        assertTrue(created!!.hasTimestamp)
        assertTrue(created.isOpenable)
    }

    @Test
    fun aCreatedMemoryIsNotOpenable() {
        // A memory task has no session. Rendering it as a chat and offering to
        // open it sends the reader to a transcript route that cannot resolve.
        val created = ProjectsApi.parseCreatedTask(
            body = """{"id":"task_3","name":"notes.md","task_type":"memory",""" +
                """"session_id":null,"created_at":"2026-09-26 05:12:37"}""",
            projectId = "item_1",
        )

        assertEquals(TaskTypes.MEMORY, created?.taskType)
        assertFalse(created!!.isOpenable)
    }

    @Test
    fun aRowWithoutAnIdIsRefusedRatherThanInvented() {
        // There would be nothing to open and nothing to select, and a blank row
        // in the drawer reads as a create that half-worked.
        assertNull(
            ProjectsApi.parseCreatedTask("""{"name":"New Chat"}""", projectId = "item_1"),
        )
    }

    @Test
    fun anUnreadableBodyIsRefusedRatherThanThrown() {
        assertNull(ProjectsApi.parseCreatedTask("<html>502</html>", projectId = "item_1"))
    }

    @Test
    fun aTaskListRowIsStillTreatedAsOpenable() {
        // The list endpoint reports no `task_type`, so it stays null — and null
        // has to mean "openable", or every existing chat becomes untappable.
        val parsed = ProjectsApi.parseProjectChatsPage(
            body = """{"tasks":[{"id":"t1","name":"chat","updated_at":"2026-09-26 05:12:37"}],""" +
                """"count":1,"has_more":false,"next_cursor":null}""",
            projectId = "item_1",
        )
        assertTrue(parsed.chats.single().isOpenable)
    }
}

// ─── The memory name rules ─────────────────────────────────────────────────────

/**
 * Mirrors of the server's `isValidMemoryName`, asserted branch by branch.
 *
 * The backend is the authority; this copy exists to turn a 400 into an
 * on-screen message. These tests exist so the copy is known to agree with it
 * today — the one place the two can drift is a rule added to the server without
 * being added here, and a test on this side is what a reviewer looks at when
 * that happens.
 */
class MemoryNameRulesTest {

    @Test
    fun aPlainMarkdownFilenameIsValid() {
        assertTrue(isValidMemoryName("notes.md"))
    }

    @Test
    fun theNameIsTrimmedFirst() {
        // The server trims before every check, so `"  a.md  "` is valid there.
        // Checking the untrimmed string here would reject a name the backend
        // would have accepted — the app refusing something that works.
        assertTrue(isValidMemoryName("   spaced.md \n"))
    }

    @Test
    fun anythingNotEndingInMdIsRefused() {
        assertFalse(isValidMemoryName("notes.txt"))
        assertFalse(isValidMemoryName("md"))
        assertFalse(isValidMemoryName("notes.MD"))
    }

    @Test
    fun pathSeparatorsAreRefused() {
        // The name is one path component under `.nalar/memories/`. A separator
        // would let a memory write outside that directory.
        assertFalse(isValidMemoryName("docs/notes.md"))
        assertFalse(isValidMemoryName("docs\\notes.md"))
    }

    @Test
    fun parentReferencesAreRefused() {
        assertFalse(isValidMemoryName("../secrets.md"))
        assertFalse(isValidMemoryName("a..b.md"))
    }

    @Test
    fun blankIsRefused() {
        assertFalse(isValidMemoryName(""))
        assertFalse(isValidMemoryName("    "))
    }

    @Test
    fun theFormNeedsBothAValidNameAndSomeContent() {
        assertTrue(canSubmitMemory("notes.md", "something"))
        assertFalse(canSubmitMemory("notes.md", "   "))
        assertFalse(canSubmitMemory("notes.txt", "something"))
    }
}

// ─── Which projects get a picker ───────────────────────────────────────────────

/**
 * The rule that decides what `+` does, per `item_type`.
 *
 * Worth its own class because it is the one place the mobile flow can quietly
 * diverge from `Sidebar.vue`, and the divergences are all "mobile offers
 * something the web does not" or the reverse.
 */
class CreateTaskStartDecisionTest {

    @Test
    fun anAgentProjectSkipsThePickerAndMakesAChat() {
        // Sidebar.vue:895-906. An agent item IS a chat container, so the Memory
        // and Routine options would be noise — there is nothing to file a
        // memory under that is not already "the agent".
        val decision = createTaskStartDecision(ProjectTypes.AGENT)

        assertEquals(
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
            (decision as CreateTaskStartDecision.Create).request,
        )
    }

    @Test
    fun aRoutineProjectTakesNothing() {
        // A scheduler-owned item has no task list. The desktop hides the `+`
        // there and returns early; this is the same guard, so a programmatic
        // call cannot open a sheet over one.
        assertEquals(
            CreateTaskStartDecision.NotAllowed,
            createTaskStartDecision(ProjectTypes.ROUTINE),
        )
    }

    @Test
    fun aKanbanProjectGetsThePicker() {
        assertEquals(
            CreateTaskStartDecision.Pick,
            createTaskStartDecision(ProjectTypes.KANBAN),
        )
    }

    @Test
    fun anUnknownTypeGetsThePickerRatherThanAGuess() {
        // Offering both options is the recoverable mistake; picking one on the
        // reader's behalf and being wrong creates something they did not ask
        // for, which they then have to delete.
        assertEquals(CreateTaskStartDecision.Pick, createTaskStartDecision("something_new"))
    }

    @Test
    fun onlyAChatIsADestination() {
        assertTrue(CreateTaskRequest.StandardChat("x").opensChat)
        // A memory is a file on disk. Navigating to its id would land on a chat
        // route with no session behind it.
        assertFalse(CreateTaskRequest.Memory("x.md", "y").opensChat)
    }
}

// ─── The controller's state machine ────────────────────────────────────────────

/**
 * The two steps, and every way out of them.
 *
 * The transitions are asserted rather than the rendering, because the failure
 * this guards against is a *stuck* flow: a form that cannot be left, a sheet
 * that reopens behind the chat it just made, a Back that lands on the wrong
 * project. None of those are visible without a device, which is why they are
 * decided in a plain class with no Compose in it.
 */
class CreateTaskControllerTest {

    private val created = mutableListOf<Triple<String, String, CreateTaskRequest>>()

    private fun controller() = CreateTaskController { w, i, r -> created += Triple(w, i, r) }

    private fun item(type: String) = ProjectSummary(
        id = "item_1",
        workspaceId = "ws_1",
        itemType = type,
        name = "Sprint board",
    )

    @Test
    fun pickingStandardCreatesAChatAndCloses() {
        val c = controller()
        c.start(item(ProjectTypes.KANBAN))
        assertEquals(
            CreateTaskStep.Picking("ws_1", "item_1", "Sprint board"),
            c.step,
        )

        c.pickStandardChat()

        assertEquals(CreateTaskStep.Idle, c.step)
        assertEquals(1, created.size)
        assertEquals(
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
            created.single().third,
        )
    }

    @Test
    fun pickingMemoryAsksForANameRatherThanCreating() {
        val c = controller()
        c.start(item(ProjectTypes.KANBAN))
        c.pickMemory()

        // Nothing sent yet — the form has to be filled in first.
        assertEquals(0, created.size)
        assertEquals(
            CreateTaskStep.NamingMemory("ws_1", "item_1", "Sprint board"),
            c.step,
        )
    }

    @Test
    fun submittingTheFormSendsTheTrimmedNameAndTheContent() {
        val c = controller()
        c.start(item(ProjectTypes.KANBAN))
        c.pickMemory()
        c.submitMemory("  notes.md  ", "# hello")

        assertEquals(CreateTaskStep.Idle, c.step)
        assertEquals(CreateTaskRequest.Memory("notes.md", "# hello"), created.single().third)
    }

    @Test
    fun anInvalidMemoryIsNotSent() {
        // The button is disabled for this, so this is the invariant behind the
        // affordance. A form that POSTs a name the server will reject spends a
        // round trip to be told what the label already said.
        val c = controller()
        c.start(item(ProjectTypes.KANBAN))
        c.pickMemory()
        c.submitMemory("notes.txt", "# hello")

        assertEquals(0, created.size)
        // Still open, so the reader can fix the name rather than start over.
        assertEquals(CreateTaskStep.NamingMemory("ws_1", "item_1", "Sprint board"), c.step)
    }

    @Test
    fun backFromTheFormReturnsToThePickerForTheSameProject() {
        val c = controller()
        c.start(item(ProjectTypes.KANBAN))
        c.pickMemory()
        c.backToPicker()

        assertEquals(CreateTaskStep.Picking("ws_1", "item_1", "Sprint board"), c.step)
    }

    @Test
    fun anAgentCreatesWithoutAnythingOpening() {
        val c = controller()
        c.start(item(ProjectTypes.AGENT))

        assertEquals(1, created.size)
        assertEquals(CreateTaskStep.Idle, c.step)
    }

    @Test
    fun aRoutineDoesNothingAtAll() {
        val c = controller()
        c.start(item(ProjectTypes.ROUTINE))

        assertEquals(0, created.size)
        assertEquals(CreateTaskStep.Idle, c.step)
    }

    @Test
    fun dismissingClosesWhateverIsOpen() {
        val c = controller()
        c.start(item(ProjectTypes.KANBAN))
        c.pickMemory()
        c.dismiss()

        assertEquals(CreateTaskStep.Idle, c.step)
    }

    @Test
    fun aPickingStepRefusesAMemorySubmission() {
        // Two steps, one controller. A submit arriving while the picker is up is
        // a bug in a caller, and acting on it would create a memory the reader
        // never named.
        val c = controller()
        c.start(item(ProjectTypes.KANBAN))
        c.submitMemory("notes.md", "x")

        assertEquals(0, created.size)
        assertEquals(CreateTaskStep.Picking("ws_1", "item_1", "Sprint board"), c.step)
    }
}

// ─── The client ────────────────────────────────────────────────────────────────

/** The POST itself, and what each status becomes. */
class ProjectsClientCreateTaskTest {

    private class MemorySessionStore(var value: String? = "tok-123") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    private class FakeTransport(
        var response: AuthHttpResponse = AuthHttpResponse(200, "{}"),
        var failure: Exception? = null,
    ) : AuthTransport {
        var lastPath: String? = null
        var lastBody: String? = null
        var lastHeaders: Map<String, String> = emptyMap()

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            lastPath = path
            lastBody = body
            lastHeaders = headers
            failure?.let { throw it }
            return response
        }

        override fun get(path: String, headers: Map<String, String>) = response
    }

    private fun client(transport: FakeTransport) =
        ProjectsClient(MemorySessionStore(), httpTransport = transport)

    private val createdBody =
        """{"id":"task_9","name":"New Chat","task_type":"standard","updated_at":"2026-09-26 05:12:40"}"""

    @Test
    fun itPostsToTheTasksRouteWithTheSessionAndTheContentType() {
        val transport = FakeTransport(AuthHttpResponse(200, createdBody))

        client(transport).createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertEquals("/api/workspaces/ws_1/items/item_1/tasks", transport.lastPath)
        // The backend reads the session from this cookie and from nowhere else,
        // and takes no Authorization header and no CSRF token.
        assertEquals("nalar_session=tok-123", transport.lastHeaders["Cookie"])
        assertEquals("application/json", transport.lastHeaders["Content-Type"])
    }

    @Test
    fun theCreatedRowIsReturnedRatherThanRefetched() {
        val result = client(FakeTransport(AuthHttpResponse(200, createdBody)))
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertTrue(result is RecentsResult.Loaded)
        assertEquals("task_9", (result as RecentsResult.Loaded).value.id)
    }

    @Test
    fun anUnauthorizedCreateSignsOut() {
        // A 401 on a write is the same dead cookie as a 401 on a read. A retry
        // cannot fix it, so the only correct answer is to hand off to sign-out
        // rather than show a Retry that would fail the same way.
        val result = client(FakeTransport(AuthHttpResponse(401, "")))
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertEquals(RecentsResult.SignedOut, result)
    }

    @Test
    fun aServerErrorSaysCreateRatherThanLoad() {
        // "Could not load your projects" on a failed create reads as though the
        // create may have worked — which is the ambiguity that sends people
        // looking for a chat that was never made.
        val result = client(FakeTransport(AuthHttpResponse(500, "")))
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        val message = (result as RecentsResult.Unavailable).message
        assertTrue(message, message.contains("create"))
        assertFalse(message, message.contains("load your projects"))
    }

    @Test
    fun aTwoHundredWithNoUsableRowIsAFailureNotAnEmptyChat() {
        // There is nothing here to open or select. Reporting success would put
        // the reader on a chat route that cannot resolve, which is a worse
        // failure than saying the create did not work.
        val result = client(FakeTransport(AuthHttpResponse(200, """{"ok":true}""")))
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun anUnreachableServerIsNotAValidationProblem() {
        val transport = FakeTransport(failure = java.io.IOException("no route"))
        val result = client(transport)
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertTrue(result is RecentsResult.Unavailable)
        assertNotNull(transport.lastPath)
    }

    @Test
    fun anUnreadableSessionDoesNotReachTheNetwork() {
        val result = ProjectsClient(
            sessionStore = object : SessionStore {
                override fun read(): String? = throw IllegalStateException("locked")
                override fun save(cookieValue: String) = Unit
                override fun clear() = Unit
            },
            httpTransport = FakeTransport(AuthHttpResponse(200, createdBody)),
        ).createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertTrue(result is RecentsResult.Unavailable)
    }
}

// ─── The ViewModel ─────────────────────────────────────────────────────────────

@OptIn(ExperimentalCoroutinesApi::class)
private class CreateSchedulers {
    val main = TestCoroutineScheduler()
    val io = TestCoroutineScheduler()
    val mainDispatcher = StandardTestDispatcher(main)
    val ioDispatcher = StandardTestDispatcher(io)

    fun drain() {
        repeat(20) {
            main.advanceUntilIdle()
            io.advanceUntilIdle()
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
private fun createTest(body: suspend TestScope.(CreateSchedulers) -> Unit) = runTest {
    val s = CreateSchedulers()
    Dispatchers.setMain(s.mainDispatcher)
    try {
        body(s)
    } finally {
        Dispatchers.resetMain()
    }
}

/**
 * Answers the reads the ViewModel makes on launch, and scripts the POST.
 *
 * The POST response is derived from the request's `task_type`, because the
 * server does exactly that (`task_create.zig` branches on it and returns a
 * `MemoryResponse` or a `StandardResponse`). A fake that always answered
 * `standard` would make a memory create look like a chat, and the test that
 * asserts memories are not openable would be asserting against a lie.
 */
private class CreateTransport(
    private val createStatus: Int = 200,
    private val existingChatIds: List<String> = listOf("t1", "t2"),
) : AuthTransport {
    val posts = mutableListOf<String>()
    var postBody: String? = null

    override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
        posts += path
        postBody = body
        val isMemory = runCatching { JSONObject(body).optString("task_type") }.getOrNull() ==
            TaskTypes.MEMORY
        val name = runCatching { JSONObject(body).optString("name") }.getOrNull().orEmpty()
        return AuthHttpResponse(
            createStatus,
            """{"id":"task_9","name":"$name","task_type":"${if (isMemory) "memory" else "standard"}",""" +
                """"updated_at":"2026-09-26 05:12:40"}""",
        )
    }

    override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
        return when {
            path.startsWith("/api/workspaces/") && path.endsWith("/items") ->
                AuthHttpResponse(
                    200,
                    """{"items":[{"id":"item_1","workspace_id":"ws_1",""" +
                        """"item_type":"kanban","name":"sprint board"}],"count":1}""",
                )

            path.contains("/items/") && path.contains("/tasks") -> {
                val tasks = existingChatIds.joinToString(",") {
                    "{\"id\":\"$it\",\"name\":\"chat $it\",\"updated_at\":\"2026-09-26 05:12:37\"}"
                }
                AuthHttpResponse(
                    200,
                    """{"tasks":[$tasks],"count":${existingChatIds.size},""" +
                        """"has_more":false,"next_cursor":null}""",
                )
            }

            path.startsWith("/api/session") ->
                AuthHttpResponse(200, """{"sessions":[],"has_more":false,"next_cursor":null,"total":0}""")

            else -> AuthHttpResponse(200, """{"workspaces":[{"id":"ws_1","name":"Kabelweb"}]}""")
        }
    }
}

private fun createViewModel(
    ioDispatcher: kotlinx.coroutines.CoroutineDispatcher,
    transport: AuthTransport,
    cache: InMemoryProjectsCache = InMemoryProjectsCache(),
) = HomeViewModel(
    client = RecentsClient(EmptySessionStore(), httpTransport = transport),
    cache = InMemoryRecentsCache(),
    projectsClient = ProjectsClient(EmptySessionStore(), httpTransport = transport),
    projectsCache = cache,
    positionStore = InMemoryLastPositionStore(),
    ioDispatcher = ioDispatcher,
)

private class EmptySessionStore : SessionStore {
    override fun read(): String? = "tok"
    override fun save(cookieValue: String) = Unit
    override fun clear() = Unit
}

/**
 * The ViewModel half: what a successful create does to the list, and the three
 * ways it can decide to do nothing.
 */
class HomeViewModelCreateTaskTest {

    private suspend fun TestScope.launchedWith(
        s: CreateSchedulers,
        transport: AuthTransport,
    ): Pair<HomeViewModel, InMemoryProjectsCache> {
        val cache = InMemoryProjectsCache()
        val model = createViewModel(s.ioDispatcher, transport, cache)
        model.onUserChanged("user_a")
        s.drain()
        // Unfold the project so there is a page for the create to land in.
        model.toggleProjectExpanded("item_1")
        s.drain()
        return model to cache
    }

    @Test
    fun aCreatedChatGoesToTheFrontOfItsProject() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        val chats = model.uiState.value.projectChats["item_1"]?.chats.orEmpty()
        // The list is `updated_at desc`, and this row is the newest thing in it.
        assertEquals("task_9", chats.firstOrNull()?.id)
        assertEquals(3, chats.size)
        assertEquals(1, transport.posts.size)
    }

    @Test
    fun theProjectIsOpenedSoTheNewRowIsVisible() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        // Creating and then having to unfold a project to find the result is the
        // one outcome that reads as "it didn't work".
        assertTrue(model.uiState.value.isProjectExpanded("item_1"))
    }

    @Test
    fun aCreatedChatIsAnnouncedSoTheGraphCanOpenIt() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport())
        val opened = mutableListOf<String>()
        val collector = CoroutineScope(s.mainDispatcher).launch {
            model.createdChat.collect { opened += it }
        }

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()
        collector.cancel()

        assertEquals(listOf("task_9"), opened)
    }

    @Test
    fun aMemoryIsCreatedButNotAnnouncedAndNotOpenable() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport())
        val opened = mutableListOf<String>()
        val collector = CoroutineScope(s.mainDispatcher).launch {
            model.createdChat.collect { opened += it }
        }

        model.createTask("item_1", CreateTaskRequest.Memory("notes.md", "# hi"))
        s.drain()
        collector.cancel()

        // A memory is a file. Navigating to its id would land on a chat route
        // with no session behind it.
        assertTrue(opened.isEmpty())
        val row = model.uiState.value.projectChats["item_1"]?.chats?.first()
        assertFalse(row!!.isOpenable)
    }

    @Test
    fun aMemoryWithABadNameIsRefusedBeforeTheRequest() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.Memory("notes.txt", "# hi"))
        s.drain()

        // No round trip to be told what the label already said.
        assertTrue(transport.posts.isEmpty())
        assertEquals(2, model.uiState.value.projectChats["item_1"]?.chats?.size)
        assertTrue(model.uiState.value.taskCreateError!!.contains(".md"))
    }

    @Test
    fun aMemoryWithNoContentIsRefusedBeforeTheRequest() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.Memory("notes.md", "   "))
        s.drain()

        assertTrue(transport.posts.isEmpty())
        assertTrue(model.uiState.value.taskCreateError!!.contains("content"))
    }

    @Test
    fun aSecondCreateWhileOneIsInFlightIsRefused() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        // The first call leaves the busy flag set; a double-tap on `+` is this.
        model.createTask("item_1", CreateTaskRequest.StandardChat("first"))
        model.createTask("item_1", CreateTaskRequest.StandardChat("second"))
        s.drain()

        // Two "New Chat" rows from one tap is the bug this guard exists for.
        assertEquals(1, transport.posts.size)
    }

    @Test
    fun aFailedCreateKeepsEveryRowAndSaysSo() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport(createStatus = 500))

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        val state = model.uiState.value
        // Nothing changed: a failed write is not a reason to blank a list.
        assertEquals(2, state.projectChats["item_1"]?.chats?.size)
        assertNotNull(state.taskCreateError)
        assertNull(state.creatingTaskInProjectId)
    }

    @Test
    fun anUnauthorizedCreateSignsOutRatherThanShowingARetryThatCannotWork() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport(createStatus = 401))
        var expired = false
        val collector = CoroutineScope(s.mainDispatcher).launch {
            model.sessionExpired.collect { expired = true }
        }

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()
        collector.cancel()

        assertTrue(expired)
    }

    @Test
    fun theMergeIsWrittenThroughToTheCache() = createTest { s ->
        // The cache is what a cold boot paints, so writing only the new row
        // would replace everything above it on the next launch.
        val (model, cache) = launchedWith(s, CreateTransport())

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        val cached = cache.readProjectChats("user_a", "ws_1", "item_1").orEmpty()
        assertEquals(3, cached.size)
        assertEquals("task_9", cached.first().id)
    }

    @Test
    fun dismissingTheErrorClearsOnlyThat() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport(createStatus = 500))
        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()
        assertNotNull(model.uiState.value.taskCreateError)

        model.dismissTaskCreateError()

        // No refetch: a reader who mistyped a filename should not have to reload
        // their projects to un-stick the screen.
        assertNull(model.uiState.value.taskCreateError)
        assertEquals(2, model.uiState.value.projectChats["item_1"]?.chats?.size)
    }

    @Test
    fun aCreateOnACollapsedProjectStillProducesAVisibleRow() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport())
        // Fold it back up, and drop the page, so the create has nothing to
        // merge into.
        model.toggleProjectExpanded("item_1")
        s.drain()

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        val state = model.uiState.value
        assertTrue(state.isProjectExpanded("item_1"))
        assertEquals("task_9", state.projectChats["item_1"]?.chats?.firstOrNull()?.id)
    }
}
