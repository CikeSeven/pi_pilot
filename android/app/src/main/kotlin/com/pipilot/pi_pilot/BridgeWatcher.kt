package com.pipilot.pi_pilot

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import java.util.concurrent.TimeUnit
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
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

    private val baseClient = OkHttpClient.Builder()
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

    private data class RoutedClient(
        val client: OkHttpClient,
        val route: String,
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

    /// 每次 start/stop 都递增。旧 socket 的回调不能影响新连接。
    private var runGeneration = 0L
    private var socketGeneration = 0L
    private var reconnectPending = false
    private var reconnectRunnable: Runnable? = null

    /// 后台切换时从 Dart 带入的基线,以及断线重连后从 hub_sessions_changed
    /// / hub_list_sessions 对账出的当前状态。
    private val taskState = WatcherTaskState()

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    @Synchronized
    fun start(
        context: Context,
        host: String,
        port: Int,
        token: String,
        sourceId: String,
        vibrate: Boolean,
        clientId: String,
        wasStreaming: Boolean,
        sessionName: String,
    ) {
        appContext = context.applicationContext
        val next = Config(host, port, token, sourceId, vibrate, clientId, sessionName)
        if (running && config == next) {
            // Flutter may emit inactive/hidden/paused in quick succession. Keep
            // the existing watcher and only strengthen its streaming baseline.
            if (wasStreaming) {
                taskState.updateBaseline(runGeneration, wasStreaming = true)
            }
            if (socket == null && !reconnectPending) connectLocked(runGeneration)
            return
        }
        runGeneration++
        cancelReconnectLocked()
        config = next
        running = true
        attempt = 0
        taskState.start(runGeneration, wasStreaming)
        closeSocketLocked()
        connectLocked(runGeneration)
    }

    @Synchronized
    fun stop() {
        if (!running && socket == null && !reconnectPending) return
        runGeneration++
        running = false
        config = null
        attempt = 0
        taskState.stop()
        cancelReconnectLocked()
        closeSocketLocked()
        cancelPostedNotifications()
        Log.i(tag, "stopped")
    }

    private fun cancelPostedNotifications() {
        if (postedNotificationIds.isEmpty()) return
        val manager = appContext?.getSystemService(NotificationManager::class.java) ?: return
        for (id in postedNotificationIds) manager.cancel(id)
        postedNotificationIds.clear()
    }

    @Synchronized
    private fun cancelReconnectLocked() {
        reconnectRunnable?.let(handler::removeCallbacks)
        reconnectRunnable = null
        reconnectPending = false
    }

    @Synchronized
    private fun closeSocketLocked() {
        // Invalidate the callback before closing: OkHttp may synchronously call
        // onClosed/onFailure while close() is running.
        val old = socket
        socket = null
        socketGeneration++
        old?.let {
            try {
                it.close(1000, "watcher stopped")
            } catch (_: Exception) {
                it.cancel()
            }
        }
    }

    private fun isCurrent(run: Long, socketId: Long, webSocket: WebSocket): Boolean =
        synchronized(this) {
            running && run == runGeneration && socketId == socketGeneration && socket === webSocket
        }

    @Synchronized
    private fun connectLocked(run: Long) {
        val current = config ?: return
        if (!running || run != runGeneration) return
        // IPv6 地址必须带方括号才是合法 URL;Dart 侧存的 host 是不带括号的
        val urlHost = if (current.host.contains(':')) "[${current.host}]" else current.host
        val url = "ws://$urlHost:${current.port}/" +
            "?token=${java.net.URLEncoder.encode(current.token, "UTF-8")}" +
            "&clientId=${java.net.URLEncoder.encode(current.clientId, "UTF-8")}"
        val context = appContext ?: return
        val routed = routedClient(context)
        val socketId = ++socketGeneration
        Log.i(tag, "connecting host=${current.host}:${current.port} source=${current.sourceId} route=${routed.route}")
        val webSocket = routed.client.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (!isCurrent(run, socketId, webSocket)) return
                    Log.i(tag, "socket opened route=${routed.route}")
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (isCurrent(run, socketId, webSocket)) {
                        handleFrame(run, socketId, webSocket, text)
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (!isCurrent(run, socketId, webSocket)) return
                    Log.w(tag, "socket failure: ${t.message}")
                    scheduleReconnect(run, socketId, webSocket)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    if (!isCurrent(run, socketId, webSocket)) return
                    Log.i(tag, "socket closed: $code $reason")
                    scheduleReconnect(run, socketId, webSocket)
                }
            },
        )
        socket = webSocket
    }

    private fun routedClient(context: Context): RoutedClient {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val wifi = connectivity?.allNetworks?.firstOrNull { network ->
            val capabilities = connectivity.getNetworkCapabilities(network)
            val links = connectivity.getLinkProperties(network)?.linkAddresses
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                !links.isNullOrEmpty()
        } ?: return RoutedClient(baseClient, "default")

        return try {
            // Do not use bindProcessToNetwork here: Dart may be opening a P2P
            // signaling socket at the same time. Route only this OkHttp client.
            val client = baseClient.newBuilder()
                .socketFactory(wifi.socketFactory)
                .dns(object : Dns {
                    override fun lookup(hostname: String): List<java.net.InetAddress> =
                        wifi.getAllByName(hostname).toList()
                })
                .build()
            RoutedClient(client, "wifi")
        } catch (error: Exception) {
            Log.w(tag, "Wi-Fi route unavailable, using default network: ${error.message}")
            RoutedClient(baseClient, "default")
        }
    }

    private fun handleFrame(
        run: Long,
        socketId: Long,
        webSocket: WebSocket,
        text: String,
    ) {
        val frame = try {
            JSONObject(text)
        } catch (_: Exception) {
            return
        }
        when (frame.optString("type")) {
            // 握手完成后立刻订阅目标 source,否则 bridge 不会向本连接广播事件。
            // 同时拉一份轻量会话表,用来补判 watcher 断线期间错过的 agent_end。
            "bridge_hello" -> {
                val current = config ?: return
                synchronized(this) { attempt = 0 }
                appContext?.let { KeepAliveService.updateConnection(it, true) }
                val suffix = "$run-$socketId"
                webSocket.send(
                    JSONObject()
                        .put("type", "hub_select_source")
                        .put("id", "watcher-select-$suffix")
                        .put("sourceId", current.sourceId)
                        .toString(),
                )
                webSocket.send(
                    JSONObject()
                        .put("type", "hub_list_sessions")
                        .put("id", "watcher-sessions-$suffix")
                        .toString(),
                )
            }

            "response" -> {
                val id = frame.optString("id")
                if (id.startsWith("watcher-sessions-")) {
                    frame.optJSONObject("data")?.optJSONArray("sessions")?.let {
                        reconcileSessions(run, it)
                    }
                }
            }

            "hub_sessions_changed" -> {
                frame.optJSONArray("sessions")?.let { reconcileSessions(run, it) }
            }

            "hub_source_snapshot" -> {
                val current = config
                if (current != null && frame.optString("sourceId") == current.sourceId &&
                    frame.has("isStreaming")
                ) {
                    reconcileStreaming(run, frame.optBoolean("isStreaming"), true)
                }
            }

            "agent_start" -> reconcileStreaming(run, true, false)

            // agent_end 与 agent_settled 都代表本轮结束,取先到的那个。
            "agent_end", "agent_settled" -> reconcileStreaming(run, false, true)
        }
    }

    private fun reconcileSessions(run: Long, sessions: JSONArray) {
        val current = config ?: return
        var connected = 0
        var working = 0
        var selectedStreaming: Boolean? = null
        for (index in 0 until sessions.length()) {
            val session = sessions.optJSONObject(index) ?: continue
            if (session.optBoolean("connected")) connected++
            if (session.optBoolean("connected") && session.optBoolean("streaming")) working++
            if (session.optString("sourceId") == current.sourceId) {
                selectedStreaming = session.optBoolean("streaming")
            }
        }
        appContext?.let {
            KeepAliveService.updateStatus(it, true, connected, working)
        }
        selectedStreaming?.let { reconcileStreaming(run, it, true) }
    }

    private fun reconcileStreaming(
        run: Long,
        streaming: Boolean,
        notifyIfFinished: Boolean,
    ) {
        if (taskState.note(run, streaming, notifyIfFinished)) notifyTaskComplete()
    }

    @Synchronized
    private fun scheduleReconnect(run: Long, socketId: Long, webSocket: WebSocket) {
        if (!running || run != runGeneration || socketId != socketGeneration || socket !== webSocket) {
            return
        }
        socket = null
        socketGeneration++
        appContext?.let { KeepAliveService.updateConnection(it, false) }
        if (reconnectPending) return
        reconnectPending = true
        attempt += 1
        val delayMs = minOf(1000L * (1 shl minOf(attempt - 1, 4)), 15_000L)
        val runnable = Runnable {
            synchronized(this) {
                if (!running || run != runGeneration || !reconnectPending) return@synchronized
                reconnectPending = false
                reconnectRunnable = null
                connectLocked(runGeneration)
            }
        }
        reconnectRunnable = runnable
        handler.postDelayed(runnable, delayMs)
    }

    @Synchronized
    private fun notifyTaskComplete() {
        if (!running) return
        val current = config ?: return
        val context = appContext ?: return
        val vibrate = current.vibrate
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
        val name = current.sessionName
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
