package com.nalar.mobile.auth

import com.nalar.mobile.BuildConfig
import java.io.IOException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthClientTest {
    private class MemorySessionStore(
        var value: String? = null,
    ) : SessionStore {
        override fun read(): String? = value

        override fun save(cookieValue: String) {
            value = cookieValue
        }

        override fun clear() {
            value = null
        }
    }

    private class FakeTransport(
        var response: AuthHttpResponse,
    ) : AuthTransport {
        var lastMethod: String? = null
        var lastPath: String? = null
        var lastBody: String? = null
        var lastHeaders: Map<String, String> = emptyMap()
        var throwIo: Boolean = false

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            record("POST", path, body, headers)
            if (throwIo) throw IOException("offline")
            return response
        }

        override fun get(
            path: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            record("GET", path, null, headers)
            if (throwIo) throw IOException("offline")
            return response
        }

        private fun record(
            method: String,
            path: String,
            body: String?,
            headers: Map<String, String>,
        ) {
            lastMethod = method
            lastPath = path
            lastBody = body
            lastHeaders = headers
        }
    }

    @Test
    fun loginSendsJsonAndPersistsSessionCookie() {
        val store = MemorySessionStore()
        val transport = FakeTransport(
            AuthHttpResponse(
                statusCode = 200,
                body = """
                    {"user":{"id":"user-1","email":"person@example.com","name":"Person","role":"admin"}}
                """.trimIndent(),
                setCookieHeaders = listOf(
                    "nalar_session=token-123; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000",
                ),
            ),
        )
        val client = AuthClient(sessionStore = store, httpTransport = transport)

        val result = client.login("person@example.com", "secret-password")

        assertTrue(result is AuthResult.Authenticated)
        assertEquals(
            AuthUser(
                id = "user-1",
                email = "person@example.com",
                name = "Person",
                role = "admin",
            ),
            (result as AuthResult.Authenticated).user,
        )
        assertEquals("/api/auth/login", transport.lastPath)
        assertEquals("POST", transport.lastMethod)
        assertEquals("token-123", store.value)
        assertEquals(
            "person@example.com",
            JSONObject(transport.lastBody!!).getString("email"),
        )
        assertEquals(
            "secret-password",
            JSONObject(transport.lastBody!!).getString("password"),
        )
    }

    @Test
    fun loginRejectsInvalidCredentialsWithoutStoringCookie() {
        val store = MemorySessionStore()
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(
                AuthHttpResponse(401, "{\"error\":\"InvalidCredentials\"}"),
            ),
        )

        val result = client.login("person@example.com", "wrong-password")

        assertTrue(result is AuthResult.Rejected)
        assertEquals("Invalid email or password.", (result as AuthResult.Rejected).message)
        assertNull(store.value)
    }

    @Test
    fun loginFailsClosedWhenServerOmitsSessionCookie() {
        val store = MemorySessionStore()
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(
                AuthHttpResponse(
                    statusCode = 200,
                    body = "{\"user\":{\"id\":\"user-1\",\"email\":\"person@example.com\"}}",
                ),
            ),
        )

        val result = client.login("person@example.com", "secret-password")

        assertTrue(result is AuthResult.Rejected)
        assertNull(store.value)
    }

    @Test
    fun restoreSessionSendsCookieAndReturnsAuthenticatedUser() {
        val store = MemorySessionStore("saved-token")
        val transport = FakeTransport(
            AuthHttpResponse(
                statusCode = 200,
                body = """
                    {"authenticated":true,"auth_enabled":true,
                     "user":{"id":"user-1","email":"person@example.com","name":"Person","role":"admin"}}
                """.trimIndent(),
            ),
        )
        val client = AuthClient(sessionStore = store, httpTransport = transport)

        val result = client.restoreSession()

        assertTrue(result is AuthResult.Authenticated)
        assertEquals("/api/auth/me", transport.lastPath)
        assertEquals("GET", transport.lastMethod)
        assertEquals("nalar_session=saved-token", transport.lastHeaders["Cookie"])
    }

    @Test
    fun restoreSessionClearsRejectedCookie() {
        val store = MemorySessionStore("expired-token")
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(AuthHttpResponse(401, "{\"error\":\"Unauthenticated\"}")),
        )

        val result = client.restoreSession()

        assertTrue(result == AuthResult.NoSession)
        assertNull(store.value)
    }

    @Test
    fun restoreSessionReturnsUnavailableWithoutDeletingCookieOnNetworkError() {
        val store = MemorySessionStore("saved-token")
        val transport = FakeTransport(AuthHttpResponse(200, "{}"))
        transport.throwIo = true
        val client = AuthClient(sessionStore = store, httpTransport = transport)

        val result = client.restoreSession()

        assertTrue(result is AuthResult.Unavailable)
        assertEquals("saved-token", store.value)
    }

    @Test
    fun logoutClearsLocalSessionEvenWhenServerIsUnavailable() {
        val store = MemorySessionStore("saved-token")
        val transport = FakeTransport(AuthHttpResponse(200, "{\"ok\":true}"))
        transport.throwIo = true
        val client = AuthClient(sessionStore = store, httpTransport = transport)

        client.logout()

        assertNull(store.value)
        assertEquals("/api/auth/logout", transport.lastPath)
    }

    @Test
    fun restoreSessionWhenAuthIsDisabledKeepsLocalCookie() {
        val store = MemorySessionStore("saved-token")
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(
                AuthHttpResponse(200, "{\"authenticated\":false,\"auth_enabled\":false}"),
            ),
        )

        val result = client.restoreSession()

        assertTrue(result == AuthResult.AuthDisabled)
        assertEquals("saved-token", store.value)
    }

    @Test
    fun loginStorageFailureFailsClosed() {
        val store = object : SessionStore {
            var cleared = false

            override fun read(): String? = null

            override fun save(cookieValue: String) {
                throw IllegalStateException("storage unavailable")
            }

            override fun clear() {
                cleared = true
            }
        }
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(
                AuthHttpResponse(
                    200,
                    "{\"user\":{\"id\":\"user-1\",\"email\":\"person@example.com\"}}",
                    setCookieHeaders = listOf("nalar_session=token-123"),
                ),
            ),
        )

        val result = client.login("person@example.com", "secret-password")

        assertTrue(result is AuthResult.Unavailable)
        assertTrue(store.cleared)
    }

    @Test
    fun parseSessionCookieIgnoresAttributesAndRejectsEmptyValues() {
        assertEquals(
            "token-123",
            parseSessionCookie(
                listOf("nalar_session=token-123; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"),
            ),
        )
        assertNull(parseSessionCookie(listOf("nalar_session=; Path=/; Max-Age=0")))
        assertNull(parseSessionCookie(listOf("other=value")))
        assertEquals(
            "valid-token",
            parseSessionCookie(
                listOf(
                    "nalar_session=; Path=/; Max-Age=0",
                    "nalar_session=valid-token; Path=/",
                ),
            ),
        )
    }

    @Test
    fun httpsTransportRejectsCleartextUnlessTheBuildPermitsIt() {
        // Release refuses a cleartext base URL outright. The debug variant
        // accepts one, because the functional UI suite points the app at a
        // nalar running on the machine that hosts the emulator and that hop is
        // plain HTTP. Asserting against the flag rather than against a fixed
        // expectation is what keeps this true in both variants; the release
        // half is pinned by `AuthConfigContractTest`, which reads the build
        // script, since these tests only ever run under debug.
        val cleartext = "http://agent.ginwa.site"

        if (BuildConfig.ALLOW_INSECURE_HTTP) {
            HttpsAuthTransport(cleartext)
        } else {
            assertThrows(IllegalArgumentException::class.java) {
                HttpsAuthTransport(cleartext)
            }
        }
    }

    @Test
    fun httpsTransportRejectsEverySchemeThatIsNotHttpOrHttps() {
        // The widening is for plain HTTP specifically, so the flag cannot be
        // used to smuggle in a scheme this client has no business opening.
        for (url in listOf("ftp://agent.ginwa.site", "file:///etc/hosts", "agent.ginwa.site")) {
            assertThrows(
                "$url must be refused in every build",
                IllegalArgumentException::class.java,
            ) {
                HttpsAuthTransport(url)
            }
        }
    }
}
