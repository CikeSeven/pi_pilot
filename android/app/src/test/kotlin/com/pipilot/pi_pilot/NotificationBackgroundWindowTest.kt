package com.pipilot.pi_pilot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

private class InMemoryBackgroundWindowStorage : BackgroundWindowStorage {
    var record: BackgroundWindowRecord? = null

    override fun read(): BackgroundWindowRecord? = record

    override fun write(record: BackgroundWindowRecord) {
        this.record = record
    }

    override fun clear() {
        record = null
    }
}

class NotificationBackgroundWindowTest {
    @Test
    fun windowSurvivesStateMachineRecreationAndBeginIsIdempotent() {
        val storage = InMemoryBackgroundWindowStorage()
        var now = 1_000L
        val first = NotificationBackgroundWindowState(
            storage = storage,
            elapsedRealtime = { now },
            bootCount = { 7L },
        )
        assertEquals(1_000L, first.begin())

        now = 5_500L
        val recreated = NotificationBackgroundWindowState(
            storage = storage,
            elapsedRealtime = { now },
            bootCount = { 7L },
        )
        assertEquals(4_500L, recreated.elapsedMs())
        assertEquals(1_000L, recreated.begin())
        assertEquals(1_000L, storage.record?.startedAtElapsedMs)
    }

    @Test
    fun rebootInvalidatesPersistedWindowBeforeStartingANewOne() {
        val storage = InMemoryBackgroundWindowStorage().also {
            it.record = BackgroundWindowRecord(
                startedAtElapsedMs = 1_000L,
                bootCount = 7L,
            )
        }
        val state = NotificationBackgroundWindowState(
            storage = storage,
            elapsedRealtime = { 2_000L },
            bootCount = { 8L },
        )

        assertNull(state.elapsedMs())
        assertNull(storage.record)
        assertEquals(2_000L, state.begin())
        assertEquals(8L, storage.record?.bootCount)
    }

    @Test
    fun unreadableCurrentBootCountInvalidatesBootBoundWindow() {
        val storage = InMemoryBackgroundWindowStorage().also {
            it.record = BackgroundWindowRecord(
                startedAtElapsedMs = 1_000L,
                bootCount = 7L,
            )
        }
        val state = NotificationBackgroundWindowState(
            storage = storage,
            elapsedRealtime = { 2_000L },
            bootCount = { null },
        )

        assertNull(state.elapsedMs())
        assertNull(storage.record)
    }

    @Test
    fun legacyRecordWithoutBootCountIsInvalidOnceBootCountBecomesAvailable() {
        val storage = InMemoryBackgroundWindowStorage().also {
            it.record = BackgroundWindowRecord(
                startedAtElapsedMs = 1_000L,
                bootCount = null,
            )
        }
        val state = NotificationBackgroundWindowState(
            storage = storage,
            elapsedRealtime = { 2_000L },
            bootCount = { 8L },
        )

        assertNull(state.elapsedMs())
        assertNull(storage.record)
    }

    @Test
    fun elapsedRealtimeRollbackInvalidatesWindowWhenBootCountIsUnavailable() {
        val storage = InMemoryBackgroundWindowStorage().also {
            it.record = BackgroundWindowRecord(
                startedAtElapsedMs = 5_000L,
                bootCount = null,
            )
        }
        val state = NotificationBackgroundWindowState(
            storage = storage,
            elapsedRealtime = { 1_000L },
            bootCount = { null },
        )

        assertNull(state.elapsedMs())
        assertNull(storage.record)
    }

    @Test
    fun foregroundEndClearsThePersistedWindow() {
        val storage = InMemoryBackgroundWindowStorage()
        val state = NotificationBackgroundWindowState(
            storage = storage,
            elapsedRealtime = { 1_000L },
            bootCount = { 7L },
        )
        state.begin()

        state.end()

        assertNull(storage.record)
        assertNull(state.elapsedMs())
    }
}
