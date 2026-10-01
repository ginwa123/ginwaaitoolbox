package com.nalar.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Projects section's "something in here is working" indicator.
 *
 * The web derives it from the workspace tree — one `processingState[task.id]`
 * lookup per task, with the section header asking the same question across
 * every project (`ProjectsList.vue`'s `firstProcessingTaskIdInWorkspace`) and
 * each row asking it for itself (`WorkspaceItem.vue`'s
 * `firstProcessingTaskId`). The join works there because a task id *is* a
 * session id; this is the same join against the only task ids a phone holds.
 *
 * The interesting case is the one that used to have no answer at all: the
 * section had no indicator whatsoever, so a workspace with three live workers
 * looked identical to an idle one whenever the reader was looking at the
 * project rows rather than the recents.
 */
class ProjectsStateRunningTest {

    private fun page(vararg ids: String) = ProjectChatsPage(
        chats = ids.map { id ->
            ProjectChat(
                id = id,
                projectId = "p",
                name = "Chat $id",
                updatedAtEpochMillis = 0L,
            )
        },
        hasMore = false,
        nextCursor = null,
    )

    private fun state(
        projects: List<String> = listOf("p1", "p2"),
        chats: Map<String, ProjectChatsPage> = emptyMap(),
    ) = ProjectsState(
        expanded = true,
        items = projects.map { id ->
            ProjectSummary(id = id, workspaceId = "ws_1", itemType = "kanban", name = id)
        },
        expandedItemIds = emptySet(),
        chats = chats,
        isLoading = false,
        errorMessage = null,
    )

    @Test
    fun aRunningChatMarksItsProject() {
        val projects = state(chats = mapOf("p1" to page("t1", "t2"), "p2" to page("t3")))

        assertEquals(setOf("p1"), projects.runningProjectIds(setOf("t2")))
    }

    @Test
    fun twoProjectsCanBeRunningAtOnce() {
        // The reported situation, restated at the level this class can see:
        // three workers live, and no single row accounts for all of them.
        val projects = state(
            chats = mapOf("p1" to page("t1"), "p2" to page("t2", "t3")),
        )

        assertEquals(setOf("p1", "p2"), projects.runningProjectIds(setOf("t1", "t3")))
    }

    @Test
    fun anIdleWorkspaceLightsNothing() {
        val projects = state(chats = mapOf("p1" to page("t1"), "p2" to page("t2")))

        // Nothing in either project has a worker: the running set and the
        // loaded task ids are disjoint, which is the whole negative case.
        assertTrue(projects.runningProjectIds(setOf("t9", "t10")).isEmpty())
        assertTrue(projects.runningProjectIds(emptySet()).isEmpty())
    }

    @Test
    fun aProjectWithNoLoadedChatsIsNeverMarked() {
        // The honest limit, and the reason this cannot lie: a collapsed project
        // has no loaded page, so this class has no task ids to check and says
        // nothing. Reporting a spinner on a project the run cannot be
        // attributed to would be a worse answer than a dark row.
        val projects = state(chats = mapOf("p1" to page("t1")))

        assertTrue(projects.runningProjectIds(setOf("t2")).isEmpty())
    }

    @Test
    fun aRunningSessionNoClientHasLoadedLightsNothing() {
        val projects = state(chats = mapOf("p1" to page("t1")))

        assertTrue(projects.runningProjectIds(setOf("never-seen-1")).isEmpty())
    }
}
