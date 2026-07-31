package com.pipilot.pi_pilot

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

class KeepAliveService : Service() {
    companion object {
        private const val tag = "PiPilotKeepAlive"
        private const val channelId = "agent_events_keepalive"
        private const val notificationId = 1
        private const val actionStart = "com.pipilot.pi_pilot.KEEP_ALIVE_START"

        @Volatile private var running = false

        /// Dart 推下来的连接与会话计数。sessionCount=-1 表示还没收到过推送,
        /// 常驻通知保持初始文案。
        @Volatile private var hubConnected = false
        @Volatile private var sessionCount = -1
        @Volatile private var workingCount = 0

        fun start(context: Context) {
            val intent = Intent(context, KeepAliveService::class.java).setAction(actionStart)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        /// Dart 侧在连接状态或会话计数变化时调用。服务没跑就只记录,
        /// 下次 startForeground 时会用上最新值。
        fun updateStatus(context: Context, connected: Boolean, sessions: Int, working: Int) {
            hubConnected = connected
            sessionCount = sessions
            workingCount = working
            refreshNotification(context)
        }

        /// Native watcher updates connectivity while the Dart isolate is paused,
        /// without overwriting the last known session counts.
        fun updateConnection(context: Context, connected: Boolean) {
            hubConnected = connected
            refreshNotification(context)
        }

        private fun refreshNotification(context: Context) {
            if (!running) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.notify(notificationId, buildNotification(context))
        }

        private fun buildNotification(context: Context): Notification {
            val openApp = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                openApp,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, channelId)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val (title, text) = when {
                sessionCount < 0 ->
                    "PiPilot 连接中" to "保持与 bridge 的连接，后台可接收任务完成提醒"
                !hubConnected ->
                    "PiPilot 连接中" to "与 bridge 的连接已断开，正在自动重连…"
                workingCount > 0 ->
                    "已连接 PiPilot" to "${sessionCount}个会话已连接，${workingCount}个会话正在工作中"
                else ->
                    "已连接 PiPilot" to "${sessionCount}个会话已连接，所有会话均空闲中"
            }
            return builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(pendingIntent)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setPriority(Notification.PRIORITY_LOW)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val notification = buildNotification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                notificationId,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(notificationId, notification)
        }
        acquireWakeLock()
        running = true
        Log.i(tag, "started: wakeLock=${wakeLock?.isHeld == true}")
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(tag, "task removed; stopping keepalive")
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(tag, "foreground-service timeout: type=$fgsType")
        stopSelf(startId)
    }

    override fun onDestroy() {
        releaseWakeLock()
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        Log.i(tag, "stopped")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            channelId,
            "连接保活",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "后台保持与 bridge 的连接"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        manager.createNotificationChannel(channel)
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:bridge-connection",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }
}
