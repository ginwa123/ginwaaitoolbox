package com.nalar.mobile.network

import com.nalar.mobile.http.HttpHeader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CurlCommandTest {
    private fun entry(
        method: String = "GET",
        url: String = "https://agent.ginwa.site/api/auth/me",
        headers: List<HttpHeader> = emptyList(),
        body: String? = null,
    ) = NetworkLogEntry(
        id = 1L,
        label = "Session restore",
        method = method,
        url = url,
        requestHeaders = headers,
        requestBody = body,
        statusCode = 200,
        startedAtEpochMillis = 1_700_000_000_000L,
        durationMillis = 30L,
    )

    @Test
    fun getProducesMethodAndUrlOnly() {
        val command = buildCurlCommand(entry())

        assertEquals("curl -X GET 'https://agent.ginwa.site/api/auth/me'", command)
        assertFalse(command.contains("--data-raw"))
    }

    @Test
    fun theCommandStaysOnOneLineSoAPasteIntoAnyTerminalSurvives() {
        val command = buildCurlCommand(
            entry(
                method = "POST",
                headers = listOf(HttpHeader("Accept", "application/json")),
                body = """{"a":1}""",
            ),
        )

        assertFalse(command.contains("\n"))
    }

    @Test
    fun postRendersHeadersAndBody() {
        val command = buildCurlCommand(
            entry(
                method = "POST",
                url = "https://agent.ginwa.site/api/auth/login",
                headers = listOf(
                    HttpHeader("Content-Type", "application/json"),
                    HttpHeader("Cookie", "nalar_session=abc"),
                ),
                body = """{"email":"a@b.c","password":"hunter2"}""",
            ),
        )

        assertTrue(command.startsWith("curl -X POST 'https://agent.ginwa.site/api/auth/login'"))
        assertTrue(command.contains("-H 'Content-Type: application/json'"))
        assertTrue(command.contains("-H 'Cookie: nalar_session=abc'"))
        assertTrue(command.contains("--data-raw '{\"email\":\"a@b.c\",\"password\":\"hunter2\"}'"))
    }

    @Test
    fun singleQuotesInsideValuesAreEscapedPosixStyle() {
        val command = buildCurlCommand(
            entry(headers = listOf(HttpHeader("X-Note", "it's fine"))),
        )

        assertTrue(command.contains("""-H 'X-Note: it'\''s fine'"""))
    }

    @Test
    fun newlinesInValuesCannotInjectASecondShellCommand() {
        val command = buildCurlCommand(
            entry(headers = listOf(HttpHeader("X-Evil", "a\nrm -rf /"))),
        )

        assertFalse(command.contains("\nrm"))
        assertTrue(command.contains("""-H 'X-Evil: a\nrm -rf /'"""))
    }

    @Test
    fun emptyBodyIsOmittedRatherThanSentAsAnEmptyPost() {
        val command = buildCurlCommand(entry(method = "POST", body = ""))

        assertFalse(command.contains("--data-raw"))
    }

    @Test
    fun lowerCaseMethodsAreUpperCased() {
        assertTrue(buildCurlCommand(entry(method = "get")).contains("-X GET"))
    }

    @Test
    fun shellQuoteWrapsPlainValuesInSingleQuotes() {
        assertEquals("'plain'", shellQuote("plain"))
        assertEquals("''", shellQuote(""))
    }
}
