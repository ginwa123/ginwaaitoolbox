package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The chat header's two rules, without a device.
 *
 * Both were a `when` inside a composable, which meant the only thing that could
 * check them was an instrumented test — and the one case that mattered most, a
 * tool run that emits no deltas, is exactly the case a hand-driven instrumented
 * run reproduces least reliably. They are pure functions over booleans; nothing
 * about them needs a phone.
 */
class ChatStatusTest {

    @Test
    fun `a worker with no deltas is still working`() {
        // The case this change is for. A two-minute `spawn_sub_agent` produces
        // no chunks for most of its life, so the per-delta flag is false while
        // the agent is unambiguously busy.
        assertTrue(isChatWorking(isRunning = true, isStreaming = false))
    }

    @Test
    fun `a delta before the worker event is still working`() {
        // The other direction's gap: a send returns, the turn is queued, and
        // the `workers` frame has not arrived yet. Keyed on the worker alone,
        // the header would say "Live" for a turn that is visibly starting.
        assertTrue(isChatWorking(isRunning = false, isStreaming = true))
    }

    @Test
    fun `neither signal means idle`() {
        assertFalse(isChatWorking(isRunning = false, isStreaming = false))
    }

    @Test
    fun `a working run outranks a live stream`() {
        assertEquals("Working…", chatStatusLabel(isWorking = true, isLive = true))
    }

    @Test
    fun `a live stream with no run says so`() {
        assertEquals("Live", chatStatusLabel(isWorking = false, isLive = true))
    }

    @Test
    fun `a dead stream with no run says reconnecting`() {
        assertEquals("Reconnecting…", chatStatusLabel(isWorking = false, isLive = false))
    }

    @Test
    fun `a working run says so even when the stream is down`() {
        // The worker's own answer outlives the socket. A header that fell back
        // to "Reconnecting…" here would blame the network for a run the backend
        // has already confirmed.
        assertEquals("Working…", chatStatusLabel(isWorking = true, isLive = false))
    }
}
