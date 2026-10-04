package com.pabrik.mobile.network

import com.pabrik.mobile.http.HttpHeader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkLogStoreTest {
    private fun entry(id: Long, path: String = "/api/auth/me", status: Int? = 200) = NetworkLogEntry(
        id = id,
        label = "test",
        method = "GET",
        url = "https://agent.ginwa.site$path",
        statusCode = status,
        startedAtEpochMillis = 1_700_000_000_000L + id,
        durationMillis = 12L,
    )

    @Test
    fun recordStoresNewestFirst() {
        val store = NetworkLogStore()

        store.record { entry(1, path = "/first") }
        store.record { entry(2, path = "/second") }

        assertEquals(listOf("/second", "/first"), store.entries.value.map { it.path })
    }

    @Test
    fun bufferDropsOldestEntriesPastTheCap() {
        val store = NetworkLogStore(maxEntries = 3)

        repeat(10) { index -> store.record { entry(index.toLong()) } }

        val stored = store.entries.value
        assertEquals(3, stored.size)
        assertEquals(listOf(9L, 8L, 7L), stored.map { it.id })
    }

    @Test
    fun pausedStoreRecordsNothing() {
        val store = NetworkLogStore()
        store.setRecording(false)

        val recorded = store.record { entry(1L) }

        assertNull(recorded)
        assertTrue(store.entries.value.isEmpty())
        assertFalse(store.isRecording.value)
    }

    @Test
    fun clearEmptiesTheBuffer() {
        val store = NetworkLogStore()
        store.record { entry(1L) }

        store.clear()

        assertTrue(store.entries.value.isEmpty())
    }

    @Test
    fun findReturnsTheEntryWithThatId() {
        val store = NetworkLogStore()
        store.record { entry(41L, path = "/api/auth/login") }

        assertEquals("/api/auth/login", store.find(41L)?.path)
        assertNull(store.find(99L))
    }

    @Test
    fun idsStayUniqueAfterClear() {
        val store = NetworkLogStore()
        val first = store.record { id -> entry(id) }?.id
        store.clear()
        val second = store.record { id -> entry(id) }?.id

        assertNotNull(first)
        assertNotNull(second)
        assertTrue(second!! > first!!)
    }

    @Test
    fun clipBodyKeepsShortBodiesIntact() {
        val (body, truncated) = clipBody("{\"ok\":true}")

        assertEquals("{\"ok\":true}", body)
        assertFalse(truncated)
    }

    @Test
    fun clipBodyCapsOversizedPayloads() {
        val huge = "x".repeat(NetworkLogStore.MAX_BODY_CHARS + 500)

        val (body, truncated) = clipBody(huge)

        assertEquals(NetworkLogStore.MAX_BODY_CHARS, body?.length)
        assertTrue(truncated)
    }

    @Test
    fun clipBodyPassesNullThrough() {
        assertNull(clipBody(null).first)
    }

    @Test
    fun concurrentRecordersDoNotLoseOrDuplicateEntries() {
        val store = NetworkLogStore(maxEntries = 500)
        val threads = (1..8).map { worker ->
            Thread {
                repeat(25) { index -> store.record { entry((worker * 1000 + index).toLong()) } }
            }
        }

        threads.forEach(Thread::start)
        threads.forEach(Thread::join)

        val ids = store.entries.value.map { it.id }
        assertEquals(200, ids.size)
        assertEquals(200, ids.toSet().size)
    }

    @Test
    fun containsSecretsDetectsCookieAndPasswordCarriers() {
        val withCookie = entry(1L).copy(
            requestHeaders = listOf(HttpHeader("Cookie", "pabrik_session=token")),
        )
        val withPassword = entry(2L).copy(
            requestBody = "{\"email\":\"a@b.c\",\"password\":\"hunter2\"}",
        )
        val clean = entry(3L).copy(
            requestHeaders = listOf(HttpHeader("Content-Type", "application/json")),
            requestBody = "{\"email\":\"a@b.c\"}",
        )

        assertTrue(withCookie.containsSecrets)
        assertTrue(withPassword.containsSecrets)
        assertFalse(clean.containsSecrets)
    }
}
