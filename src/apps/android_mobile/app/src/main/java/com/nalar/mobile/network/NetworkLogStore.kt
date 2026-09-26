package com.nalar.mobile.network

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * In-memory ring buffer of captured exchanges, newest first.
 *
 * Deliberately not persisted: a captured sign-in carries the session cookie, and
 * writing it to disk would put that cookie into backups and log files. The buffer
 * dies with the process.
 */
class NetworkLogStore(
    private val maxEntries: Int = MAX_ENTRIES,
) {
    private val lock = Any()
    private val sequence = AtomicLong()
    private val _entries = MutableStateFlow<List<NetworkLogEntry>>(emptyList())
    val entries: StateFlow<List<NetworkLogEntry>> = _entries.asStateFlow()

    private val _isRecording = MutableStateFlow(true)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    fun setRecording(recording: Boolean) {
        _isRecording.value = recording
    }

    /**
     * Stores the built entry under a freshly allocated id. Returns null while
     * recording is paused, so callers can treat "not captured" and "captured" as
     * the same code path as not recording at all.
     */
    fun record(build: (id: Long) -> NetworkLogEntry): NetworkLogEntry? {
        if (!_isRecording.value) return null

        val entry = build(sequence.incrementAndGet())
        synchronized(lock) {
            _entries.value = (listOf(entry) + _entries.value).take(maxEntries)
        }
        return entry
    }

    fun find(recordId: Long): NetworkLogEntry? =
        _entries.value.firstOrNull { entry -> entry.id == recordId }

    fun clear() {
        synchronized(lock) {
            _entries.value = emptyList()
        }
    }

    companion object {
        const val MAX_ENTRIES = 200

        /** A 2 MB download must not be able to OOM the app from the capture buffer alone. */
        const val MAX_BODY_CHARS = 32 * 1024

        val default: NetworkLogStore = NetworkLogStore()
    }
}

/** Returns the stored prefix plus whether anything was dropped. */
internal fun clipBody(body: String?): Pair<String?, Boolean> {
    if (body == null) return null to false
    if (body.length <= NetworkLogStore.MAX_BODY_CHARS) return body to false
    return body.take(NetworkLogStore.MAX_BODY_CHARS) to true
}
