package com.pabrik.mobile.network

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.http.HttpHeader
import com.pabrik.mobile.http.HttpRequestSpec
import com.pabrik.mobile.http.HttpResponseSpec
import com.pabrik.mobile.http.HttpExchange
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingAuthTransportTest {
    private class StubTransport(
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

        override fun get(
            path: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            lastPath = path
            lastBody = null
            lastHeaders = headers
            failure?.let { throw it }
            return response
        }
    }

    private fun transport(
        stub: StubTransport = StubTransport(),
        store: NetworkLogStore = NetworkLogStore(),
    ) = RecordingAuthTransport(
        delegate = stub,
        store = store,
        baseUrlProvider = { "https://agent.ginwa.site" },
    )

    @Test
    fun successfulPostIsCapturedWithRequestAndResponse() {
        val store = NetworkLogStore()
        val stub = StubTransport(
            response = AuthHttpResponse(
                statusCode = 201,
                body = """{"user":{"id":"u1"}}""",
                setCookieHeaders = listOf("pabrik_session=token-1"),
                headers = listOf(HttpHeader("Content-Type", "application/json")),
            ),
        )

        transport(stub, store).post(
            path = "/api/auth/login",
            body = """{"email":"a@b.c","password":"hunter2"}""",
            headers = mapOf("Content-Type" to "application/json"),
        )

        val entry = store.entries.value.single()
        assertEquals("POST", entry.method)
        assertEquals("Sign in", entry.label)
        assertEquals("https://agent.ginwa.site/api/auth/login", entry.url)
        assertEquals(201, entry.statusCode)
        assertEquals("""{"user":{"id":"u1"}}""", entry.responseBody)
        assertEquals(NetworkOutcome.Responded, entry.outcome)
    }

    @Test
    fun capturedRequestHeadersMirrorWhatTheExchangeSends() {
        val store = NetworkLogStore()

        transport(store = store).get(
            path = "/api/auth/me",
            headers = mapOf("Cookie" to "pabrik_session=saved"),
        )

        val entry = store.entries.value.single()
        assertEquals("Session restore", entry.label)
        assertEquals(
            listOf(
                HttpHeader("Accept", "application/json"),
                HttpHeader("Cookie", "pabrik_session=saved"),
            ),
            entry.requestHeaders,
        )
    }

    @Test
    fun transportFailureIsCapturedAndRethrown() {
        val store = NetworkLogStore()
        val stub = StubTransport(failure = IOException("connection reset"))

        val thrown = runCatching {
            transport(stub, store).get("/api/auth/me", emptyMap())
        }.exceptionOrNull()

        assertTrue(thrown is IOException)
        val entry = store.entries.value.single()
        assertNull(entry.statusCode)
        assertEquals(NetworkOutcome.Failed, entry.outcome)
        assertTrue(entry.isFailure)
        assertEquals("ERR", entry.statusLabel)
        assertNotNull(entry.errorMessage)
        assertTrue(entry.errorMessage!!.contains("connection reset"))
    }

    @Test
    fun theCallerStillSeesTheOriginalResponse() {
        val stub = StubTransport(response = AuthHttpResponse(401, """{"error":"InvalidCredentials"}"""))

        val response = transport(stub).post("/api/auth/login", "{}", emptyMap())

        assertEquals(401, response.statusCode)
        assertEquals("""{"error":"InvalidCredentials"}""", response.body)
    }

    @Test
    fun oversizedBodiesAreClippedButTheFullSizeIsKept() {
        val store = NetworkLogStore()
        val huge = "y".repeat(NetworkLogStore.MAX_BODY_CHARS + 250)

        transport(store = store).post("/api/workspaces", huge, emptyMap())

        val entry = store.entries.value.single()
        assertEquals(NetworkLogStore.MAX_BODY_CHARS, entry.requestBody?.length)
        assertTrue(entry.requestBodyTruncated)
        assertEquals(huge.length, entry.requestBodyBytes)
    }

    @Test
    fun aPausedStoreCapturesNothingButTheCallStillSucceeds() {
        val store = NetworkLogStore().apply { setRecording(false) }
        val stub = StubTransport()

        val response = transport(stub, store).get("/api/auth/me", emptyMap())

        assertEquals(200, response.statusCode)
        assertTrue(store.entries.value.isEmpty())
    }

    @Test
    fun unknownPathsGetAFallbackLabel() {
        val store = NetworkLogStore()

        transport(store = store).get("/api/workspaces/w-1/agents", emptyMap())

        assertEquals("GET agents", store.entries.value.single().label)
    }

    @Test
    fun replayResendsTheRecordedRequestAndCapturesASecondRecord() {
        val store = NetworkLogStore()
        val sent = mutableListOf<HttpRequestSpec>()
        val exchange = HttpExchange { request ->
            sent += request
            HttpResponseSpec(
                statusCode = 200,
                headers = listOf(HttpHeader("Content-Type", "application/json")),
                body = """{"ok":true}""",
            )
        }
        val original = store.record { id ->
            NetworkLogEntry(
                id = id,
                label = "Sign in",
                method = "POST",
                url = "https://agent.ginwa.site/api/auth/login",
                requestHeaders = listOf(HttpHeader("Content-Type", "application/json")),
                requestBody = """{"email":"a@b.c"}""",
                requestBodyBytes = 19,
                statusCode = 401,
                startedAtEpochMillis = 1L,
                durationMillis = 5L,
            )
        }!!

        val replayed = replayNetworkEntry(original, store, exchange)

        assertEquals(1, sent.size)
        assertEquals("POST", sent.single().method)
        assertEquals(original.url, sent.single().url)
        assertEquals(original.requestHeaders, sent.single().headers)
        assertEquals(original.requestBody, sent.single().body)

        assertNotNull(replayed)
        assertTrue(replayed!!.isReplay)
        assertEquals("Replay · Sign in", replayed.label)
        assertEquals(200, replayed.statusCode)
        assertEquals(2, store.entries.value.size)
    }

    @Test
    fun aFailedReplayIsCapturedAsAFailureInsteadOfThrowing() {
        val store = NetworkLogStore()
        val exchange = HttpExchange { throw IOException("no route to host") }

        val replayed = replayNetworkEntry(
            entry = NetworkLogEntry(
                id = 1L,
                label = "Sign in",
                method = "POST",
                url = "https://agent.ginwa.site/api/auth/login",
                startedAtEpochMillis = 1L,
                durationMillis = 5L,
            ),
            store = store,
            exchange = exchange,
        )

        assertNotNull(replayed)
        assertNull(replayed!!.statusCode)
        assertTrue(replayed.isFailure)
        assertTrue(replayed.errorMessage!!.contains("no route to host"))
        assertFalse(store.entries.value.isEmpty())
    }
}
