package com.nalar.mobile.testing

import com.nalar.mobile.chat.ChatStreamEvent
import com.nalar.mobile.chat.ChatStreamState
import com.nalar.mobile.chat.SseBus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * A bus-shaped stand-in for the app's one real socket.
 *
 * Multi-subscriber on purpose. The single-callback `FakeEventStream` that
 * replaced it could only ever serve one owner, which is precisely the property
 * the move to a shared bus removed: a test that emitted an event was asserting
 * about the *only* listener, and there is no longer such a thing.
 *
 * The counts are here so a test can assert the *root's* lifecycle — one open
 * per sign-in, one close per sign-out — instead of the per-ViewModel
 * start/stop counters that encoded the old two-socket architecture.
 */
class FakeSseBus : SseBus {

    private class Subscriber(
        val onEvent: (ChatStreamEvent) -> Unit,
        val onState: (ChatStreamState) -> Unit,
    )

    private val subscribers = mutableListOf<Subscriber>()
    private val _state = MutableStateFlow<ChatStreamState>(ChatStreamState.Connecting)

    override val state: StateFlow<ChatStreamState> = _state.asStateFlow()

    var openCount = 0
        private set
    var closeCount = 0
        private set
    var isOpen = false
        private set

    val subscriberCount: Int get() = subscribers.size

    override fun subscribe(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ): () -> Unit {
        val subscriber = Subscriber(onEvent, onState)
        subscribers.add(subscriber)
        onState(_state.value)
        return { subscribers.remove(subscriber) }
    }

    override fun open() {
        openCount++
        isOpen = true
    }

    override fun close() {
        closeCount++
        isOpen = false
        state(ChatStreamState.Connecting)
    }

    /** Delivers one event to every listener, as the real fan-out does. */
    fun emit(event: ChatStreamEvent) {
        for (subscriber in subscribers.toList()) subscriber.onEvent(event)
    }

    /** Publishes a connection state to every listener. */
    fun state(next: ChatStreamState) {
        _state.value = next
        for (subscriber in subscribers.toList()) subscriber.onState(next)
    }
}
