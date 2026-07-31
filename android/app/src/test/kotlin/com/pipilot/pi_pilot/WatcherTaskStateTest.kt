package com.pipilot.pi_pilot

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WatcherTaskStateTest {
    @Test
    fun reconnectObservingIdleNotifiesOnceForBackgroundTask() {
        val state = WatcherTaskState()
        state.start(generation = 1L, wasStreaming = true)

        assertTrue(state.note(1L, streaming = false, notifyIfFinished = true))
        assertFalse(state.note(1L, streaming = false, notifyIfFinished = true))
    }

    @Test
    fun agentEndAndSettledAreOneCompletionEdge() {
        val state = WatcherTaskState()
        state.start(generation = 4L, wasStreaming = false)
        assertFalse(state.note(4L, streaming = true, notifyIfFinished = false))

        assertTrue(state.note(4L, streaming = false, notifyIfFinished = true))
        assertFalse(state.note(4L, streaming = false, notifyIfFinished = true))
    }

    @Test
    fun repeatedLifecycleBaselineCannotReopenCompletedTask() {
        val state = WatcherTaskState()
        state.start(generation = 3L, wasStreaming = true)
        assertTrue(state.note(3L, streaming = false, notifyIfFinished = true))

        state.updateBaseline(generation = 3L, wasStreaming = true)
        assertFalse(state.note(3L, streaming = false, notifyIfFinished = true))
    }

    @Test
    fun oldGenerationCallbackIsIgnored() {
        val state = WatcherTaskState()
        state.start(generation = 1L, wasStreaming = true)
        state.start(generation = 2L, wasStreaming = true)

        assertFalse(state.note(1L, streaming = false, notifyIfFinished = true))
        assertTrue(state.note(2L, streaming = false, notifyIfFinished = true))
    }

    @Test
    fun stopRacingWithCompletionSuppressesNotification() {
        val state = WatcherTaskState()
        state.start(generation = 7L, wasStreaming = true)
        state.stop()

        assertFalse(state.note(7L, streaming = false, notifyIfFinished = true))
    }
}
