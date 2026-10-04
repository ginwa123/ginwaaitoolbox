package com.pabrik.mobile.network

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pabrik.mobile.http.HttpHeader
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NetworkInspectorScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L

    private fun entry(
        id: Long,
        method: String = "GET",
        path: String = "/api/auth/me",
        status: Int? = 200,
    ) = NetworkLogEntry(
        id = id,
        label = if (path == "/api/auth/login") "Sign in" else "Session restore",
        method = method,
        url = "https://agent.ginwa.site$path",
        statusCode = status,
        startedAtEpochMillis = now,
        durationMillis = 24L,
    )

    private fun seededStore(): NetworkLogStore {
        val store = NetworkLogStore()
        store.record { entry(it, path = "/api/auth/me") }
        store.record { entry(it, method = "POST", path = "/api/auth/login", status = 401) }
        return store
    }

    @Test
    fun listsCapturedRequestsWithMethodStatusAndPath() {
        show(seededStore())

        composeTestRule.onNodeWithTag("network_list").assertIsDisplayed()
        composeTestRule.onNodeWithTag("network_row_2").assertIsDisplayed()
        composeTestRule.onNodeWithText("POST").assertIsDisplayed()
        composeTestRule.onNodeWithText("401").assertIsDisplayed()
        composeTestRule.onNodeWithText("/api/auth/login").assertIsDisplayed()
    }

    @Test
    fun openingARowReportsItsId() {
        var opened: Long? = null
        show(seededStore(), onOpenRecord = { id -> opened = id })

        composeTestRule.onNodeWithTag("network_row_1").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1L, opened)
    }

    @Test
    fun failedFilterNarrowsToErrorsAndTransportFailures() {
        show(seededStore())

        composeTestRule.onNodeWithTag("network_filter_failed").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_row_2").assertIsDisplayed()
        composeTestRule.onNodeWithTag("network_row_1").assertDoesNotExist()
    }

    @Test
    fun searchTextHidesNonMatchingRows() {
        show(seededStore())

        composeTestRule.onNodeWithTag("network_search").performTextInput("login")
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_row_2").assertIsDisplayed()
        composeTestRule.onNodeWithTag("network_row_1").assertDoesNotExist()
    }

    @Test
    fun emptyStateExplainsWhereRecordsComeFrom() {
        show(NetworkLogStore())

        composeTestRule.onNodeWithTag("network_empty").assertIsDisplayed()
        composeTestRule.onNodeWithText("No requests captured yet").assertIsDisplayed()
    }

    @Test
    fun clearEmptiesTheCapturedBuffer() {
        val store = seededStore()
        show(store)

        composeTestRule.onNodeWithTag("network_clear").performClick()
        composeTestRule.waitForIdle()

        assertTrue(store.entries.value.isEmpty())
        composeTestRule.onNodeWithTag("network_empty").assertIsDisplayed()
    }

    @Test
    fun pauseStopsCapturingButTheExistingBufferStays() {
        val store = seededStore()
        show(store)

        composeTestRule.onNodeWithTag("network_toggle_recording").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithText("Paused").assertIsDisplayed()
        assertEquals(2, store.entries.value.size)
    }

    private fun show(
        store: NetworkLogStore,
        onOpenRecord: (Long) -> Unit = {},
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                NetworkInspectorScreen(
                    onBack = {},
                    onOpenRecord = onOpenRecord,
                    store = store,
                    nowEpochMillis = { now },
                )
            }
        }
    }
}
