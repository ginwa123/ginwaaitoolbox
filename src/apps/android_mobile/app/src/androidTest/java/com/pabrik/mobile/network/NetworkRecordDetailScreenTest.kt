package com.pabrik.mobile.network

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pabrik.mobile.http.HttpHeader
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NetworkRecordDetailScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val loginBody = """{"email":"person@example.com","password":"hunter2"}"""

    private fun storeWith(
        method: String = "POST",
        requestHeaders: List<HttpHeader> = listOf(
            HttpHeader("Content-Type", "application/json"),
            HttpHeader("Cookie", "pabrik_session=super-secret"),
        ),
        requestBody: String? = loginBody,
    ): NetworkLogStore {
        val store = NetworkLogStore()
        store.record { id ->
            NetworkLogEntry(
                id = id,
                label = "Sign in",
                method = method,
                url = "https://agent.ginwa.site/api/auth/login",
                requestHeaders = requestHeaders,
                requestBody = requestBody,
                requestBodyBytes = requestBody?.length ?: 0,
                statusCode = 401,
                responseHeaders = listOf(HttpHeader("Content-Type", "application/json")),
                responseBody = """{"error":"InvalidCredentials"}""",
                responseBodyBytes = 32,
                startedAtEpochMillis = 1_800_000_000_000L,
                durationMillis = 180L,
            )
        }
        return store
    }

    @Test
    fun theRequestBodyIsMaskedUntilSecretsAreRevealed() {
        show(storeWith())

        composeTestRule.onNodeWithTag("network_request_body")
            .assertTextContains(RedactedPlaceholder, substring = true)
        composeTestRule.onNodeWithTag("network_request_body")
            .assertTextContains("person@example.com", substring = true)
        composeTestRule.onNodeWithText("hunter2").assertDoesNotExist()

        composeTestRule.onNodeWithTag("network_reveal_secrets_switch").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_request_body")
            .assertTextContains("hunter2", substring = true)
    }

    @Test
    fun credentialHeadersAreMaskedUntilSecretsAreRevealed() {
        show(storeWith())

        composeTestRule.onNodeWithTag("network_request_headers")
            .assertTextContains(RedactedPlaceholder, substring = true)
        composeTestRule.onNodeWithText("super-secret").assertDoesNotExist()

        composeTestRule.onNodeWithTag("network_reveal_secrets_switch").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_request_headers")
            .assertTextContains("super-secret", substring = true)
    }

    @Test
    fun theResponseTabShowsTheServerErrorBody() {
        show(storeWith())

        composeTestRule.onNodeWithTag("network_tab_response").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_response_body").assertIsDisplayed()
        composeTestRule.onNodeWithText("InvalidCredentials", substring = true).assertIsDisplayed()
    }

    @Test
    fun theCurlTabRendersAReplayableCommand() {
        show(storeWith())

        composeTestRule.onNodeWithTag("network_tab_curl").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_curl_command")
            .assertTextContains("curl -X POST", substring = true)
        composeTestRule.onNodeWithTag("network_curl_command")
            .assertTextContains("https://agent.ginwa.site/api/auth/login", substring = true)
        composeTestRule.onNodeWithTag("network_curl_command")
            .assertTextContains("--data-raw", substring = true)
    }

    @Test
    fun theCurlTabWarnsThatTheCommandCarriesLiveCredentials() {
        show(storeWith())

        composeTestRule.onNodeWithTag("network_tab_curl").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithText("live credentials", substring = true).assertIsDisplayed()
    }

    @Test
    fun replayingAMutationAsksForConfirmationFirst() {
        var replayed: NetworkLogEntry? = null
        show(storeWith()) { entry -> replayed = entry }

        composeTestRule.onNodeWithTag("network_replay").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_replay_confirm").assertIsDisplayed()
        assertEquals(null, replayed)

        composeTestRule.onNodeWithTag("network_replay_confirm_accept").performClick()
        composeTestRule.waitForIdle()

        assertEquals("Sign in", replayed?.label)
    }

    @Test
    fun dismissingTheReplayConfirmationSendsNothing() {
        var replayed: NetworkLogEntry? = null
        show(storeWith()) { entry -> replayed = entry }

        composeTestRule.onNodeWithTag("network_replay").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("network_replay_confirm_dismiss").performClick()
        composeTestRule.waitForIdle()

        assertEquals(null, replayed)
    }

    @Test
    fun replayingASafeMethodSkipsTheConfirmation() {
        val store = NetworkLogStore()
        store.record { id ->
            NetworkLogEntry(
                id = id,
                label = "Session restore",
                method = "GET",
                url = "https://agent.ginwa.site/api/auth/me",
                statusCode = 200,
                startedAtEpochMillis = 1_800_000_000_000L,
                durationMillis = 20L,
            )
        }
        var replayed: NetworkLogEntry? = null
        show(store) { entry -> replayed = entry }

        composeTestRule.onNodeWithTag("network_replay").performClick()
        composeTestRule.waitForIdle()

        assertTrue(replayed != null)
        composeTestRule.onNodeWithTag("network_replay_confirm").assertDoesNotExist()
    }

    @Test
    fun aRecordEvictedFromTheBufferExplainsItselfInsteadOfCrashing() {
        show(NetworkLogStore(), recordId = 7L)

        composeTestRule.onNodeWithTag("network_detail_missing").assertIsDisplayed()
        composeTestRule.onNodeWithText("no longer buffered", substring = true).assertIsDisplayed()
    }

    @Test
    fun aRecordWithNoSecretsHidesTheRevealToggle() {
        show(storeWith(requestHeaders = listOf(HttpHeader("Accept", "application/json")), requestBody = null))

        composeTestRule.onNodeWithTag("network_reveal_secrets").assertDoesNotExist()
    }

    private fun show(
        store: NetworkLogStore,
        recordId: Long? = 1L,
        onReplay: (NetworkLogEntry) -> Unit = {},
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                NetworkRecordDetailScreen(
                    onBack = {},
                    onReplay = onReplay,
                    recordId = recordId,
                    store = store,
                )
            }
        }
    }
}
