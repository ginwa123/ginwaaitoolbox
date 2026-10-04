package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The chat bar's `+`: which projects it will offer.
 *
 * The filter is the whole behaviour, and it is asserted as a function because
 * the alternative is a device test that proves a list of names appears — which
 * would still pass if a routine were in that list, since a routine *has* a
 * name and draws a perfectly good row.
 */
class NewChatProjectSheetTest {

    private fun project(id: String, type: String = ProjectTypes.KANBAN) =
        ProjectSummary(id = id, workspaceId = "ws_1", itemType = type, name = id)

    @Test
    fun everyOrdinaryProjectTakesAChat() {
        val projects = listOf(
            project("p1", ProjectTypes.KANBAN),
            project("p2", ProjectTypes.AGENT),
            project("p3", ProjectTypes.DESIGN),
        )

        assertEquals(projects, projectsThatTakeAChat(projects))
    }

    @Test
    fun aRoutineIsNeverOffered() {
        // A routine has no task list — per-task routines were deleted with
        // their table (Migration 084) and became first-class project types.
        // Offering one would POST into a parent the backend does not accept
        // tasks for, and the failure would arrive after the reader committed.
        val projects = listOf(project("p1"), project("r1", ProjectTypes.ROUTINE))

        assertEquals(listOf("p1"), projectsThatTakeAChat(projects).map { it.id })
    }

    @Test
    fun anUnrecognisedTypeIsStillOffered() {
        // Not defensive padding: the backend may ship a new `item_type`
        // tomorrow, and "I do not know this one" must not become "there is
        // nowhere to make a chat".
        val projects = listOf(project("p1", "something_new"))

        assertEquals(1, newChatProjectCount(projects))
    }

    @Test
    fun aWorkspaceOfNothingButRoutinesOffersNothing() {
        // Which is the case the sheet's empty state exists for — a list with
        // no rows under a "New chat" title is a bug report with no message.
        val projects = listOf(project("r1", ProjectTypes.ROUTINE))

        assertEquals(0, newChatProjectCount(projects))
    }

    @Test
    fun aProjectWithNoTypeIsOffered() {
        val projects = listOf(project("p1", type = ""))

        assertTrue(projectsThatTakeAChat(projects).isNotEmpty())
    }
}
