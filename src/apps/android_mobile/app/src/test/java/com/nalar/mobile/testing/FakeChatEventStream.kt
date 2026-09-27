package com.nalar.mobile.testing

import com.nalar.mobile.chat.ChatEventStream
import com.nalar.mobile.chat.ChatStreamEvent
import com.nalar.mobile.chat.ChatStreamState

/**
 * A transport-shaped double: the *socket*, not the bus.
 *
 * Distinct from [FakeSseBus] on purpose. `RootSseBus` takes a
 * [ChatEventStream] — the one socket — and fans it out itself, so a test of the
 * bus needs a double underneath it that has a single pair of callbacks. A test
 * of a *subscriber* needs the other shape, and conflating the two is how a
 * shared-bus refactor ends up tested only against itself.
 */
class FakeChatEventStream : ChatEventStream {
    var onEvent: ((ChatStreamEvent) -> Unit)? = null
    var onState: ((ChatStreamState) -> Unit)? = null
    var startCount = 0
        private set
    var stopCount = 0
        private set

    override fun start(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ) {
        startCount++
        this.onEvent = onEvent
        this.onState = onState
    }

    override fun stop() {
        stopCount++
    }

    /** What the real pump would do with a decoded frame. */
    fun emit(event: ChatStreamEvent) = onEvent?.invoke(event) ?: Unit

    /** What the real pump would do on a connection transition. */
    fun state(next: ChatStreamState) = onState?.invoke(next) ?: Unit
}
