package com.pipilot.pi_pilot

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.SystemClock
import android.provider.Settings

internal data class BackgroundWindowRecord(
    val startedAtElapsedMs: Long,
    val bootCount: Long?,
)

internal interface BackgroundWindowStorage {
    fun read(): BackgroundWindowRecord?
    fun write(record: BackgroundWindowRecord)
    fun clear()
}

private class PrefsBackgroundWindowStorage(context: Context) : BackgroundWindowStorage {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(
        NotificationBackgroundWindow.PREFS,
        Context.MODE_PRIVATE,
    )

    override fun read(): BackgroundWindowRecord? {
        if (!prefs.contains(KEY_STARTED_AT)) return null
        val startedAt = prefs.getLong(KEY_STARTED_AT, -1L)
        val bootCount = if (prefs.contains(KEY_BOOT_COUNT)) {
            prefs.getLong(KEY_BOOT_COUNT, -1L).takeIf { it >= 0L }
        } else {
            null
        }
        return BackgroundWindowRecord(startedAt, bootCount)
    }

    override fun write(record: BackgroundWindowRecord) {
        val editor = prefs.edit().putLong(KEY_STARTED_AT, record.startedAtElapsedMs)
        if (record.bootCount == null) {
            editor.remove(KEY_BOOT_COUNT)
        } else {
            editor.putLong(KEY_BOOT_COUNT, record.bootCount)
        }
        editor.commit()
    }

    override fun clear() {
        prefs.edit().remove(KEY_STARTED_AT).remove(KEY_BOOT_COUNT).commit()
    }

    private companion object {
        const val KEY_STARTED_AT = "started_at_elapsed_ms"
        const val KEY_BOOT_COUNT = "boot_count"
    }
}

/**
 * Pure state machine behind [NotificationBackgroundWindow]. It is separate from
 * Android storage so process recreation and reboot validation stay JVM-testable.
 */
internal class NotificationBackgroundWindowState(
    private val storage: BackgroundWindowStorage,
    private val elapsedRealtime: () -> Long,
    private val bootCount: () -> Long?,
) {
    @Synchronized
    fun begin(): Long {
        val now = elapsedRealtime().coerceAtLeast(0L)
        val currentBoot = bootCount()
        val existing = validRecord(now, currentBoot)
        if (existing != null) return existing.startedAtElapsedMs
        storage.write(BackgroundWindowRecord(now, currentBoot))
        return now
    }

    @Synchronized
    fun end() {
        storage.clear()
    }

    @Synchronized
    fun elapsedMs(): Long? {
        val now = elapsedRealtime().coerceAtLeast(0L)
        val record = validRecord(now, bootCount()) ?: return null
        return now - record.startedAtElapsedMs
    }

    private fun validRecord(now: Long, currentBoot: Long?): BackgroundWindowRecord? {
        val record = storage.read() ?: return null
        val elapsedInvalid = record.startedAtElapsedMs < 0L || record.startedAtElapsedMs > now
        val bootInvalid = record.bootCount != currentBoot
        if (elapsedInvalid || bootInvalid) {
            storage.clear()
            return null
        }
        return record
    }
}

/**
 * One background window shared by every notification owner and persisted across
 * process recreation. Only the Flutter app lifecycle ends it; transport resets,
 * owner switches and reconnects must leave it intact.
 */
object NotificationBackgroundWindow {
    const val PREFS = "pipilot_notification_background_window_v1"

    @Volatile
    private var sharedState: NotificationBackgroundWindowState? = null

    fun begin(context: Context): Long = state(context).begin()

    fun end(context: Context) = state(context).end()

    fun elapsedMs(context: Context): Long? = state(context).elapsedMs()

    private fun state(context: Context): NotificationBackgroundWindowState {
        sharedState?.let { return it }
        return synchronized(this) {
            sharedState ?: NotificationBackgroundWindowState(
                storage = PrefsBackgroundWindowStorage(context.applicationContext),
                elapsedRealtime = SystemClock::elapsedRealtime,
                bootCount = { readBootCount(context.applicationContext) },
            ).also { sharedState = it }
        }
    }

    private fun readBootCount(context: Context): Long? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return null
        return runCatching {
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT).toLong()
        }.getOrNull()
    }
}
