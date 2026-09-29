package com.nalar.mobile.server

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import com.nalar.mobile.login.LoginScreen
import com.nalar.mobile.ui.NalarTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The change-server control, as a rendered tree.
 *
 * On the JVM under Robolectric, for the same reason the launch gate is: this is
 * Compose behaviour, and the only thing that has ever pinned it is what actually
 * gets composed. A unit test of a `validate`-style function would not have
 * caught the row being placed below the fold, the dialog opening over the
 * keyboard, or the error never reaching the screen.
 */
@RunWith(RobolectricTestRunner::class)
class LoginServerAddressTest {

    @get:Rule
    val compose = createComposeRule()

    /**
     * Opens the change-server dialog, scrolling the row into view first.
     *
     * The login screen is a `verticalScroll` column and the server row is the
     * last thing in it, so on the 320x470 screen Robolectric lays out, the row
     * sits at y=640 — below the window. A `performClick` without this injects a
     * touch at the node's centre, which is off-screen, the click reaches
     * nothing, and every assertion after it fails for a reason that has nothing
     * to do with the feature. Scrolling is also part of the contract: a row
     * that cannot be scrolled to is a row nobody can reach.
     */
    private fun openServerDialog() {
        compose.onNodeWithTag("server_address_change").performScrollTo().performClick()
    }

    @Test
    fun `the row shows the host the app is pointed at, without the scheme`() {
        // A self-hoster's first question after installing the app is "is this
        // even talking to my server", and the answer has to be readable from the
        // login screen without opening anything.
        compose.setContent {
            NalarTheme {
                LoginScreen(serverBaseUrl = "https://self.hosted.example:8443")
            }
        }

        // Exact, not "contains": the port has to survive (it is the difference
        // between two deployments on one machine) and the scheme has to be gone
        // (it is noise in a confirmation). Either half failing is the bug, and
        // a substring check would only ever catch one of them.
        compose.onNodeWithTag("server_address_host")
            .performScrollTo()
            .assertIsDisplayed()
            .assertTextEquals("self.hosted.example:8443")
    }

    @Test
    fun `Change opens the dialog seeded with the address in use`() {
        compose.setContent {
            NalarTheme {
                LoginScreen(serverBaseUrl = "https://self.hosted.example")
            }
        }

        openServerDialog()

        compose.onNodeWithTag("server_address_dialog").assertIsDisplayed()
        // Seeded, not blank: re-typing a 40-character URL to fix one character
        // of it is the other half of why this is a setting.
        compose.onNodeWithTag("server_address_input")
            .assertTextContains("https://self.hosted.example")
    }

    @Test
    fun `saving hands the raw text back and closes on an accepted change`() {
        // The dialog does not validate; the store owns the rule, and the dialog
        // renders whatever sentence comes back. The raw text is what goes up, so
        // a scheme-less `self.hosted.example` — valid, and the common case — is
        // not rejected here as a missing domain.
        var received: String? = null
        compose.setContent {
            NalarTheme {
                LoginScreen(
                    serverBaseUrl = "https://agent.ginwa.site",
                    onChangeServer = { raw ->
                        received = raw
                        ServerChange.Applied("https://$raw")
                    },
                )
            }
        }

        openServerDialog()
        compose.onNodeWithTag("server_address_input").performTextClearance()
        compose.onNodeWithTag("server_address_input").performTextInput("self.hosted.example")
        compose.onNodeWithTag("server_address_save").performClick()

        assertEquals("self.hosted.example", received)
        compose.onNodeWithTag("server_address_dialog").assertDoesNotExist()
    }

    @Test
    fun `a refused address stays on screen with the store's own sentence`() {
        // The rejection is the whole reason the dialog stays open. Closing it
        // on a refusal would leave the person with a dialog that vanished and a
        // server that did not change, which is indistinguishable from the app
        // having ignored them.
        compose.setContent {
            NalarTheme {
                LoginScreen(
                    serverBaseUrl = "https://agent.ginwa.site",
                    onChangeServer = {
                        ServerChange.Rejected("A server address cannot have a ?query or #fragment.")
                    },
                )
            }
        }

        openServerDialog()
        compose.onNodeWithTag("server_address_save").performClick()

        compose.onNodeWithTag("server_address_dialog").assertIsDisplayed()
        compose.onNodeWithText("A server address cannot have a ?query or #fragment.")
            .assertIsDisplayed()
    }

    @Test
    fun `the default-server escape hatch is absent when the app is already on it`() {
        // On a fresh install the current address *is* the default, and a "Use
        // the default server" button that changes nothing is worse than no
        // button: it advertises a way out that goes nowhere.
        compose.setContent {
            NalarTheme {
                LoginScreen(
                    serverBaseUrl = "https://agent.ginwa.site",
                    defaultServerBaseUrl = "https://agent.ginwa.site",
                )
            }
        }
        openServerDialog()

        compose.onNodeWithTag("server_address_default").assertDoesNotExist()
    }

    @Test
    fun `the escape hatch appears once the server has moved off the default`() {
        // The other half, and the one a person who cannot work out how to type
        // their own domain again is relying on.
        compose.setContent {
            NalarTheme {
                LoginScreen(
                    serverBaseUrl = "https://self.hosted.example",
                    defaultServerBaseUrl = "https://agent.ginwa.site",
                )
            }
        }
        openServerDialog()

        compose.onNodeWithTag("server_address_default").assertIsDisplayed()
    }

    @Test
    fun `a host label keeps the port and drops the path`() {
        // The row is a label, not a URL to copy — but a port is the difference
        // between two deployments on one machine, so it has to survive.
        assertEquals("self.hosted.example:8443", hostLabelFor("https://self.hosted.example:8443"))
        assertEquals("example.com", hostLabelFor("https://example.com/nalar"))
        assertEquals(
            "a value that never normalized still has to render as something",
            "agent.ginwa.site",
            hostLabelFor("agent.ginwa.site"),
        )
    }
}
