package com.pipilot.pi_pilot

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

/// 后台期间由原生层持有的**只读观察连接**。
///
/// 为什么需要它:MIUI 在应用切后台约 20-50 秒后会强制回收前台服务申请的
/// PARTIAL_WAKE_LOCK(dumpsys 中显示为 DISABLED),Dart isolate 随即停止调度,
/// 无法回应 bridge 的 10s 协议 ping,socket 在 ~20s 超时被 terminate。
/// `agent_end` 因此永远送不到手机,`isStreaming` 不翻转,完成通知不触发。
/// 进程本身没有被冻结(PolicyMaker 持续记录 reason=fgservice),所以把连接
/// 搬到 JVM 线程上就能存活。
///
/// 这个连接只做三件事:订阅所选 source、跟踪 streaming 事件、发完成通知。
/// 它从不申请租约、从不发送变更命令,因此不会和前台的 Dart 连接争抢控制权。
/// 它使用独立 clientId —— bridge 对同一 clientId 的新连接会踢掉旧连接。
object BridgeWatcher {
    private const val tag = "PiPilotWatcher"
    private const val quietChannelId = "agent_events_heads_up_quiet_v3"
    private const val vibrateChannelId = "agent_events_heads_up_vibrate_v3"

    /// 原生通知 id 从 200 起,避开 FGS 常驻通知(1)与 Dart 任务通知(100+)。
    private const val notificationIdBase = 200

    private val client = OkHttpClient.Builder()
        // OkHttp 会自动回应服务端 ping,同时主动 ping 保活 NAT 映射
        .pingInterval(15, TimeUnit.SECONDS)
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private data class Config(
        val host: String,
        val port: Int,
        val token: String,
        val sourceId: String,
        val vibrate: Boolean,
        val clientId: String,
        val sessionName: String,
    )

    private var config: Config? = null
    private var socket: WebSocket? = null
    private var appContext: Context? = null
    private var running = false
    private var attempt = 0
    private var notificationId = notificationIdBase

    /// 已发出的任务完成通知 id,stop 时逐个取消 —— 用户回到 App 后通知栏里
    /// 不该还躺着「任务完成」。
    private val postedNotificationIds = mutableSetOf<Int>()

    /// 已经为当前一轮生成发过完成通知,避免 agent_end 与 agent_settled 重复触发。
    private var endNotified = false

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var reconnectPending = false

    @Synchronized
    fun start(
        context: Context,
        host: String,
        port: Int,
        token: String,
        sourceId: String,
        vibrate: Boolean,
        clientId: String,
        sessionName: String,
    ) {
        appContext = context.applicationContext
        val next = Config(host, port, token, sourceId, vibrate, clientId, sessionName)
        if (running && config == next && socket != null) {
            Log.i(tag, "already watching source=$sourceId")
            return
        }
        config = next
        running = true
        attempt = 0
        endNotified = false
        closeSocket()
        connect()
    }

    @Synchronized
    fun stop() {
        if (!running && socket == null && postedNotificationIds.isEmpty()) return
        running = false
        config = null
        attempt = 0
        reconnectPending = false
        closeSocket()
        cancelPostedNotifications()
        Log.i(tag, "stopped")
    }

    private fun cancelPostedNotifications() {
        if (postedNotificationIds.isEmpty()) return
        val manager = appContext?.getSystemService(NotificationManager::class.java) ?: return
        for (id in postedNotificationIds) {
            manager.cancel(id)
        }
        postedNotificationIds.clear()
    }

    private fun closeSocket() {
        socket?.let {
            try {
                it.close(1000, "watcher stopped")
            } catch (_: Exception) {
                it.cancel()
            }
        }
        socket = null
    }

    private fun connect() {
        val current = config ?: return
        if (!running) return
        // IPv6 地址必须带方括号才是合法 URL;Dart 侧存的 host 是不带括号的
        val urlHost = if (current.host.contains(':')) "[${current.host}]" else current.host
        val url = "ws://$urlHost:${current.port}/" +
            "?token=${java.net.URLEncoder.encode(current.token, "UTF-8")}" +
            "&clientId=${java.net.URLEncoder.encode(current.clientId, "UTF-8")}"
        Log.i(tag, "connecting host=${current.host}:${current.port} source=${current.sourceId}")
        socket = client.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    attempt = 0
                    Log.i(tag, "connected")
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    handleFrame(webSocket, text)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    Log.w(tag, "socket failure: ${t.message}")
                    scheduleReconnect()
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    Log.i(tag, "socket closed: $code $reason")
                    scheduleReconnect()
                }
            },
        )
    }

    private fun handleFrame(webSocket: WebSocket, text: String) {
        val frame = try {
            JSONObject(text)
        } catch (_: Exception) {
            return
        }
        when (frame.optString("type")) {
            // 握手完成后立刻订阅目标 source,否则 bridge 不会向本连接广播事件
            "bridge_hello" -> {
                val sourceId = config?.sourceId ?: return
                val select = JSONObject()
                    .put("type", "hub_select_source")
                    .put("id", "watcher-select")
                    .put("sourceId", sourceId)
                webSocket.send(select.toString())
            }

            "agent_start" -> endNotified = false

            // agent_end 与 agent_settled 都代表本轮结束,取先到的那个
            "agent_end", "agent_settled" -> {
                if (endNotified) return
                endNotified = true
                notifyTaskComplete()
            }
        }
    }

    private fun scheduleReconnect() {
        socket = null
        if (!running || reconnectPending) return
        reconnectPending = true
        attempt += 1
        val delayMs = minOf(1000L * (1 shl minOf(attempt - 1, 4)), 15_000L)
        handler.postDelayed({
            reconnectPending = false
            if (running) connect()
        }, delayMs)
    }

    private fun notifyTaskComplete() {
        val context = appContext ?: return
        val vibrate = config?.vibrate ?: false
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        createTaskChannels(manager)

        val openApp = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            1,
            openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val channelId = if (vibrate) vibrateChannelId else quietChannelId
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val id = ++notificationId
        val name = config?.sessionName.orEmpty()
        // 与 Dart 侧 _notifyTaskComplete 同一格式:「<会话名> 已完成 / 点击查看结果」
        val title = if (name.isNotEmpty()) "$name 已完成" else "PiPilot 任务完成"
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText("点击查看结果")
            .setContentIntent(pendingIntent)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setPriority(Notification.PRIORITY_MAX)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .build()
        manager.notify(id, notification)
        postedNotificationIds.add(id)
        Log.i(tag, "task complete notification posted: id=$id vibrate=$vibrate")
    }

    /// 与 Dart 侧 NotificationService 使用同一组渠道 id 与配置。
    /// Android 渠道创建后不可修改,重复创建同名渠道是无副作用的。
    private fun createTaskChannels(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(quietChannelId) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    quietChannelId,
                    "任务提醒（无震动）",
                    NotificationManager.IMPORTANCE_MAX,
                ).apply {
                    description = "pi 任务完成、扩展等待输入、连接中断等提醒"
                    enableVibration(false)
                    enableLights(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
        if (manager.getNotificationChannel(vibrateChannelId) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    vibrateChannelId,
                    "任务提醒（震动）",
                    NotificationManager.IMPORTANCE_MAX,
                ).apply {
                    description = "pi 任务完成、扩展等待输入、连接中断等提醒"
                    enableVibration(true)
                    enableLights(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
    }
}
