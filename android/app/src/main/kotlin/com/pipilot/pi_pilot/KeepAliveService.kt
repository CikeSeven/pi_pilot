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

        /// 后台实时能力的降级状态。
        ///
        /// Android 15+ 对 dataSync 类型的前台服务有每 24 小时累计 6 小时的限制。
        /// 配额耗尽时系统调用 onTimeout(),此后不允许该类型继续以前台服务运行。
        /// 原来的实现只是 stopSelf(),服务静默消失、常驻通知也一并撤掉,
        /// 用户看到的现象就是「后台通知偶发失效」且无从诊断。
        ///
        /// 现在改为显式状态:进入 QUOTA_EXHAUSTED 后如实更新通知文案,
        /// 并记录配额窗口起点供诊断页展示。见 stable-plan.md §10.3。
        enum class BackgroundMode {
            /// 前台服务正常运行,原生 watcher 持有实时连接。
            REALTIME,

            /// dataSync 配额耗尽。已无实时连接,只能等下次打开 App 或
            /// (将来接入 FCM 后)靠推送唤醒,再按 cursor 补齐。
            QUOTA_EXHAUSTED,
        }

        @Volatile private var mode = BackgroundMode.REALTIME

        /// 配额耗尽的时刻。Android 的 24h 窗口是滚动的,这里只用于
        /// 给用户一个「大约何时恢复」的估计,不作为精确判据。
        @Volatile private var quotaExhaustedAt = 0L

        /// 供诊断页读取当前降级状态。
        fun backgroundMode(): BackgroundMode = mode

        fun quotaExhaustedAtMillis(): Long = quotaExhaustedAt

        /// 诊断页用:FGS 视角的桥接连接状态。它由两个 owner 与 Dart 各自上报,
        /// 三方可能短暂不一致,展示时以 owner 状态为准。
        fun isHubConnected(): Boolean = hubConnected

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
                // 降级状态优先展示。绝不能在配额耗尽后还显示「已连接」——
                // 那会让用户以为通知仍然实时,直到错过一次重要提醒才发现。
                mode == BackgroundMode.QUOTA_EXHAUSTED ->
                    "PiPilot 后台实时已暂停" to
                        "系统后台时长配额已用完，打开应用即可补齐错过的提醒"
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
        // 重新启动意味着配额窗口已恢复(或用户手动重开),回到实时模式。
        mode = BackgroundMode.REALTIME
        quotaExhaustedAt = 0L
        Log.i(tag, "started: wakeLock=${wakeLock?.isHeld == true}")
        // START_NOT_STICKY 是有意的:本服务目前还不能从空 Intent 重建
        // 连接 owner(目标设备、凭据、cursor 都在 Dart 侧)。改成 STICKY
        // 会留下「有常驻通知但没人在监听」的空服务,比不重启更糟。
        // 迁移顺序见 stable-plan.md §10.2。
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(tag, "task removed; stopping keepalive")
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    /// dataSync 配额耗尽。
    ///
    /// 必须在系统给的短暂窗口内完成收尾,否则会被判为 ANR。这里做三件事:
    ///  1. 停掉原生 watcher 并释放 wake lock —— 已经没有实时连接了。
    ///  2. 把常驻通知改成如实的降级文案,不再显示「已连接」。
    ///  3. 记录配额窗口起点供诊断。
    ///
    /// 刻意不做的事:不重启 dataSync 服务。那属于规避平台限制,
    /// 会被系统持续拦截,且违反 Play 政策。
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(tag, "foreground-service timeout: type=$fgsType; degrading to quota-exhausted")
        mode = BackgroundMode.QUOTA_EXHAUSTED
        quotaExhaustedAt = System.currentTimeMillis()
        hubConnected = false
        // 原生 watcher 失去前台服务庇护后无法可靠维持 socket,主动收掉,
        // 让 Dart 侧的 ready 状态也随之撤下,恢复兜底通知所有权。
        BridgeWatcher.stop()
        releaseWakeLock()
        // 先把降级文案发出去,再脱离前台。顺序反了通知就撤掉了,
        // 用户会失去唯一的诊断线索。
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(notificationId, buildNotification(this))
        // STOP_FOREGROUND_DETACH:保留通知但脱离前台服务。
        // 用 REMOVE 会连降级提示一起撤掉。
        stopForeground(STOP_FOREGROUND_DETACH)
        running = false
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
