package com.nalar.mobile.auth

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AuthRestoringScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun networkErrorOffersRetryAndSignInRecovery() {
        var retried = false
        var usedAnotherAccount = false

        composeTestRule.setContent {
            NalarTheme {
                AuthRestoringScreen(
                    errorMessage = "Could not verify your saved session. Try signing in again.",
                    onRetry = { retried = true },
                    onUseAnotherAccount = { usedAnotherAccount = true },
                )
            }
        }

        composeTestRule.onNodeWithTag("auth_restore_message").assertIsDisplayed()
        composeTestRule.onNodeWithTag("auth_retry").performClick()
        composeTestRule.onNodeWithTag("auth_use_another_account").performClick()

        assertTrue(retried)
        assertTrue(usedAnotherAccount)
    }

    @Test
    fun restoringStateShowsProgress() {
        composeTestRule.setContent {
            NalarTheme {
                AuthRestoringScreen()
            }
        }

        composeTestRule.onNodeWithTag("auth_restoring").assertIsDisplayed()
        composeTestRule.onNodeWithText("Restoring your session…").assertIsDisplayed()
    }
}
