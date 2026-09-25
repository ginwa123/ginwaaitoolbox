package com.nalar.mobile.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkFilterTest {
    private fun entry(
        id: Long,
        method: String = "GET",
        path: String = "/api/auth/me",
        status: Int? = 200,
        label: String = "Session restore",
        durationMillis: Long = 20L,
        requestBytes: Int = 0,
        responseBytes: Int = 120,
        error: String? = null,
    ) = NetworkLogEntry(
        id = id,
        label = label,
        method = method,
        url = "https://agent.ginwa.site$path",
        requestBodyBytes = requestBytes,
        responseBodyBytes = responseBytes,
        statusCode = status,
        errorMessage = error,
        startedAtEpochMillis = 1_700_000_000_000L + id,
        durationMillis = durationMillis,
    )

    private val entries = listOf(
        entry(1L, method = "GET", path = "/api/auth/me", label = "Session restore"),
        entry(
            2L,
            method = "POST",
            path = "/api/auth/login",
            status = 401,
            label = "Sign in",
            requestBytes = 64,
            durationMillis = 210L,
        ),
        entry(3L, method = "POST", path = "/api/workspaces/w-1/chat", status = 201, label = "POST chat"),
        entry(4L, method = "GET", path = "/api/files/blob", status = null, error = "timed out"),
    )

    @Test
    fun allFilterKeepsEveryEntry() {
        assertEquals(4, filterNetworkEntries(entries, NetworkEntryFilter.All, "").size)
    }

    @Test
    fun mutationsFilterKeepsOnlyWriteMethods() {
        val filtered = filterNetworkEntries(entries, NetworkEntryFilter.Mutations, "")

        assertEquals(listOf(2L, 3L), filtered.map { it.id })
    }

    @Test
    fun failedFilterKeepsHttpErrorsAndTransportFailures() {
        val filtered = filterNetworkEntries(entries, NetworkEntryFilter.Failed, "")

        assertEquals(listOf(2L, 4L), filtered.map { it.id })
    }

    @Test
    fun searchMatchesPathMethodHostAndStatus() {
        assertEquals(listOf(1L), filterNetworkEntries(entries, NetworkEntryFilter.All, "auth/me").map { it.id })
        assertEquals(listOf(2L, 3L), filterNetworkEntries(entries, NetworkEntryFilter.All, "post").map { it.id })
        assertEquals(listOf(2L), filterNetworkEntries(entries, NetworkEntryFilter.All, "401").map { it.id })
        assertEquals(listOf(4L), filterNetworkEntries(entries, NetworkEntryFilter.All, "timed out").map { it.id })
    }

    @Test
    fun searchIsCaseInsensitiveAndTrimmed() {
        val filtered = filterNetworkEntries(entries, NetworkEntryFilter.All, "  SIGN IN  ")

        assertEquals(listOf(2L), filtered.map { it.id })
    }

    @Test
    fun filterAndSearchCombine() {
        val filtered = filterNetworkEntries(entries, NetworkEntryFilter.Failed, "auth")

        assertEquals(listOf(2L), filtered.map { it.id })
    }

    @Test
    fun summaryCountsRequestsFailuresBytesAndTheSlowestCall() {
        val summary = summarizeNetworkEntries(entries)

        assertEquals(4, summary.requestCount)
        assertEquals(2, summary.failedCount)
        // 0+120, 64+120, 0+120, 0+120
        assertEquals(544, summary.totalBytes)
        assertEquals(210L, summary.slowestMillis)
    }

    @Test
    fun summaryOfAnEmptyBufferIsZeroed() {
        val summary = summarizeNetworkEntries(emptyList())

        assertEquals(0, summary.requestCount)
        assertEquals(0L, summary.slowestMillis)
    }

    @Test
    fun statusClassSplitsSuccessRedirectAndFailureBands() {
        assertEquals(NetworkStatusClass.Success, statusClassOf(entry(1L, status = 204)))
        assertEquals(NetworkStatusClass.Redirect, statusClassOf(entry(1L, status = 302)))
        assertEquals(NetworkStatusClass.ClientError, statusClassOf(entry(1L, status = 404)))
        assertEquals(NetworkStatusClass.ServerError, statusClassOf(entry(1L, status = 503)))
        assertEquals(NetworkStatusClass.Failure, statusClassOf(entry(1L, status = null)))
    }

    @Test
    fun entryExposesHostPathAndQueryForTheListRow() {
        val withQuery = entry(1L, path = "/api/chats?workspace=w-1")

        assertEquals("agent.ginwa.site", withQuery.host)
        assertEquals("/api/chats", withQuery.path)
        assertEquals("workspace=w-1", withQuery.query)
        assertEquals("/api/chats?workspace=w-1", withQuery.displayPath)
    }

    @Test
    fun formattersCoverBytesDurationsAndLabels() {
        assertEquals("0 B", formatBytes(0))
        assertEquals("512 B", formatBytes(512))
        assertEquals("1.0 kB", formatBytes(1024))
        assertEquals("1.5 MB", formatBytes(1024 * 1536))

        assertEquals("<1 ms", formatDuration(0))
        assertEquals("250 ms", formatDuration(250))
        assertEquals("1.50 s", formatDuration(1500))
    }

    @Test
    fun mutationFlagMatchesTheMethodList() {
        assertTrue(entry(1L, method = "POST").isMutation)
        assertTrue(entry(1L, method = "delete").isMutation)
        assertFalse(entry(1L, method = "GET").isMutation)
    }

    @Test
    fun knownAuthPathsGetReadableLabels() {
        assertEquals("Sign in", labelForExchange("POST", "/api/auth/login"))
        assertEquals("Session restore", labelForExchange("GET", "/api/auth/me"))
        assertEquals("POST workspaces", labelForExchange("POST", "/api/workspaces"))
        assertEquals("GET request", labelForExchange("GET", "/"))
    }

    @Test
    fun transportFailuresShowErrInsteadOfAStatusCode() {
        assertEquals("ERR", entry(1L, status = null).statusLabel)
        assertEquals("201", entry(1L, status = 201).statusLabel)
    }
}
