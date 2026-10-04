package com.pabrik.mobile.login

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LoginAuthStateTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun showsServerErrorAndKeepsFormVisible() {
        composeTestRule.setContent {
            PabrikTheme {
                LoginScreen(
                    authError = "Invalid email or password.",
                )
            }
        }

        composeTestRule.onNodeWithTag("login_error").assertIsDisplayed()
        composeTestRule.onNodeWithText("Invalid email or password.").assertIsDisplayed()
        composeTestRule.onNodeWithTag("login_email").assertIsDisplayed()
    }

    @Test
    fun disablesSubmitWhileRequestIsInFlight() {
        composeTestRule.setContent {
            PabrikTheme {
                LoginScreen(
                    isAuthenticating = true,
                )
            }
        }

        composeTestRule.onNodeWithTag("login_submit")
            .assertIsDisplayed()
            .assertIsNotEnabled()
        composeTestRule.onNodeWithText("Signing in…").assertIsDisplayed()
    }
}
