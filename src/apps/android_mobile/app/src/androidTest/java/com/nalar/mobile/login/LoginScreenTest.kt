package com.nalar.mobile.login

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LoginScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersWelcomeMessage() {
        composeTestRule.setContent {
            NalarTheme {
                LoginScreen()
            }
        }

        composeTestRule
            .onNodeWithText("Welcome back")
            .assertIsDisplayed()
    }

    @Test
    fun showsValidationMessagesForEmptyForm() {
        composeTestRule.setContent {
            NalarTheme {
                LoginScreen()
            }
        }

        composeTestRule.onNodeWithTag("login_submit").performClick()

        composeTestRule
            .onNodeWithText("Enter your email address.")
            .assertIsDisplayed()
        composeTestRule
            .onNodeWithText("Enter your password.")
            .assertIsDisplayed()
    }

    @Test
    fun doesNotForwardInvalidCredentials() {
        var received: LoginCredentials? = null
        composeTestRule.setContent {
            NalarTheme {
                LoginScreen(onSignIn = { received = it })
            }
        }

        composeTestRule.onNodeWithTag("login_submit").performClick()

        assertFalse(received != null)
    }

    @Test
    fun forwardsValidCredentialsToIntegrationCallback() {
        var received: LoginCredentials? = null
        composeTestRule.setContent {
            NalarTheme {
                LoginScreen(onSignIn = { received = it })
            }
        }

        composeTestRule
            .onNodeWithTag("login_email")
            .performTextInput("person@example.com")
        composeTestRule
            .onNodeWithTag("login_password")
            .performTextInput("secret")
        composeTestRule.onNodeWithTag("login_submit").performClick()

        assertEquals(LoginCredentials("person@example.com", "secret"), received)
        composeTestRule
            .onNodeWithText("Credentials ready · authentication will be connected in the next step.")
            .assertIsDisplayed()
    }
}
