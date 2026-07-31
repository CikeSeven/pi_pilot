package com.pipilot.pi_pilot

/**
 * Thread-safe completion edge detector for the native background watcher.
 *
 * The socket generation is supplied by BridgeWatcher. A stale callback or a
 * callback racing with stop() must never turn into a completion notification.
 */
internal class WatcherTaskState {
    private var activeGeneration = Long.MIN_VALUE
    private var active = false
    private var taskRunning = false
    private var endNotified = false

    @Synchronized
    fun start(generation: Long, wasStreaming: Boolean) {
        activeGeneration = generation
        active = true
        taskRunning = wasStreaming
        endNotified = false
    }

    /** Strengthen a live watcher's baseline without resetting a task already seen. */
    @Synchronized
    fun updateBaseline(generation: Long, wasStreaming: Boolean) {
        if (!active || activeGeneration != generation) return
        if (wasStreaming && !endNotified) {
            taskRunning = true
        }
    }

    @Synchronized
    fun stop() {
        active = false
        taskRunning = false
        endNotified = false
    }

    /** Returns true exactly once for a valid streaming -> idle edge. */
    @Synchronized
    fun note(
        generation: Long,
        streaming: Boolean,
        notifyIfFinished: Boolean,
    ): Boolean {
        if (!active || activeGeneration != generation) return false
        if (streaming) {
            taskRunning = true
            endNotified = false
            return false
        }
        val shouldNotify = notifyIfFinished && taskRunning && !endNotified
        taskRunning = false
        if (shouldNotify) endNotified = true
        return shouldNotify
    }
}
