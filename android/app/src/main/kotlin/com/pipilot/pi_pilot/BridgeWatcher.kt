package com.pipilot.pi_pilot

import android.app.NotificationManager
import android.content.Context
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

    /// 通知协议引擎:帧处理、cursor、去重、展示全在里面,这里只剩传输
    /// 与 legacy streaming 边沿判定。
    private var engine: NotificationProtocolEngine? = null

    /// ready 状态变化回调。Dart 侧据此决定是否让出通知所有权。
    private var readyListener: ((Boolean) -> Unit)? = null

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
        WatcherDiagnostics.init(context)
        val next = Config(host, port, token, sourceId, vibrate, clientId, sessionName)
        WatcherDiagnostics.log("start(running=$running sameConfig=${config == next})")
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
        ensureNotificationLayer(context, clientId, next.vibrate)
        closeSocketLocked()
        connectLocked(runGeneration)
    }

    /// 注册 ready 监听。Dart 只有在收到匹配 generation 的 ready 之后
    /// 才让出通知所有权 —— 这修掉了「提交即成功」导致的过早抑制。
    @Synchronized
    fun setReadyListener(listener: ((Boolean) -> Unit)?) {
        readyListener = listener
        // 立刻回放当前状态,避免注册时机晚于 ready 而漏掉一次通知。
        listener?.invoke(engine?.isReady ?: false)
    }

    @Synchronized
    fun isSubscriptionReady(): Boolean = engine?.isReady ?: false

    /// 诊断页用的状态快照。token 绝不进入快照;
    /// 身份字段只截前 8 位 —— 它们经 mDNS 广播不算机密,
    /// 但完整值对诊断没有增量价值,还会撑大导出的 JSON。
    fun debugStatus(): Map<String, Any?> {
        val cfg = config
        val bridgeId = engine?.bridgeInstallationId
        return mapOf(
            "running" to running,
            "ready" to (engine?.isReady ?: false),
            "notificationProtocol" to (engine?.notificationProtocol ?: false),
            "host" to (cfg?.host ?: ""),
            "port" to (cfg?.port ?: 0),
            "clientId" to (cfg?.clientId?.take(8) ?: ""),
            "bridgeInstallationId" to (bridgeId?.take(8) ?: ""),
            "eventEpoch" to ((engine?.eventEpoch)?.take(8) ?: ""),
            "reconnectAttempt" to attempt,
            "reconnectPending" to reconnectPending,
            "cursorThrough" to (engine?.cursorThroughForDebug() ?: -1L),
        )
    }

    private fun ensureNotificationLayer(context: Context, clientId: String, vibrate: Boolean) {
        if (engine == null) {
            engine = NotificationProtocolEngine(
                context = context,
                installationId = clientId,
                diagPrefix = "watcher",
            ).also { created ->
                created.readyListener = { ready -> setReady(ready) }
            }
        }
        engine?.vibrate = vibrate
    }

    private fun setReady(value: Boolean) {
        Log.i(tag, "subscription ready=$value")
        readyListener?.invoke(value)
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
        engine?.cancelPostedNotifications()
        engine?.reset()
        WatcherDiagnostics.log(
            "stop() by " +
                Throwable().stackTrace.drop(1).take(5)
                    .joinToString(" <- ") { "${it.className.substringAfterLast('.')}.${it.methodName}" },
        )
        Log.i(tag, "stopped")
    }

    private fun cancelPostedNotifications() {
        engine?.cancelPostedNotifications()
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
                    WatcherDiagnostics.log("onOpen(cur=${isCurrent(run, socketId, webSocket)} route=${routed.route})")
                    if (!isCurrent(run, socketId, webSocket)) return
                    Log.i(tag, "socket opened route=${routed.route}")
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (isCurrent(run, socketId, webSocket)) {
                        handleFrame(run, socketId, webSocket, text)
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    WatcherDiagnostics.log("onFailure(cur=${isCurrent(run, socketId, webSocket)} msg=${t.message})")
                    if (!isCurrent(run, socketId, webSocket)) return
                    Log.w(tag, "socket failure: ${t.message}")
                    scheduleReconnect(run, socketId, webSocket)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    WatcherDiagnostics.log("onClosed(cur=${isCurrent(run, socketId, webSocket)} code=$code)")
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
            // 握手完成后按能力分流:新协议由引擎订阅,旧 Bridge 才走
            // hub_select_source + 会话表补判 agent_end。
            "bridge_hello" -> {
                val current = config ?: return
                synchronized(this) { attempt = 0 }
                appContext?.let { KeepAliveService.updateConnection(it, true) }
                val suffix = "$run-$socketId"
                val e = engine ?: return
                when (e.onHello(frame, suffix)) {
                    NotificationProtocolEngine.HelloOutcome.SUBSCRIBED -> flushOutbound(webSocket)
                    NotificationProtocolEngine.HelloOutcome.LEGACY -> {
                        // 旧 Bridge:回退到 streaming 边沿判定。此时不发新帧,
                        // 也不宣布 ready —— 让 Dart 保持兜底所有权更安全。
                        // 注意:新协议时刻意不发 hub_select_source,选中 source 会招来
                        // MB 级 hub_source_snapshot(实测约 1 MiB),大帧占住 OkHttp
                        // 读线程,Bridge 10s 协议 ping 连丢 3 次后判半开 terminate。
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
                        Log.i(tag, "bridge lacks notification_events_v1; using legacy edge detection")
                    }
                    NotificationProtocolEngine.HelloOutcome.IDENTITY_CONFLICT -> {
                        // watcher 不持久化身份,理论到不了这里;防御性关闭。
                        webSocket.close(4000, "identity conflict")
                    }
                }
            }

            "response" -> {
                val id = frame.optString("id")
                if (id.startsWith("watcher-sessions-")) {
                    frame.optJSONObject("data")?.optJSONArray("sessions")?.let {
                        reconcileSessions(run, it)
                    }
                    return
                }
                // notification_* 首包在 response.data 里,引擎内部解包。
                val e = engine ?: return
                if (e.onFrame(frame)) flushOutbound(webSocket)
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

            "agent_start" -> {
                // 有通知协议时完成事件由 Bridge 权威生成,这里不再自己判边沿,
                // 否则同一次完成会被两条路径各算一次。
                if (engine?.notificationProtocol != true) reconcileStreaming(run, true, false)
            }

            // agent_end 与 agent_settled 都代表本轮结束,取先到的那个。
            // 例外一:agent_end 带 willRetry 时(API 报错后电脑端会自动重试)
            // 本轮还没结束,收口交给重试后的最终 agent_end / agent_settled。
            // 例外二:agent_end 带 aborted 时(用户中断)轮次结束但不是
            // 「完成」—— 翻 streaming 但不弹通知。
            "agent_end", "agent_settled" -> {
                val type = frame.optString("type")
                val willRetry = type == "agent_end" && frame.optBoolean("willRetry", false)
                val aborted = type == "agent_end" && frame.optBoolean("aborted", false)
                if (engine?.notificationProtocol != true && !willRetry) {
                    reconcileStreaming(run, false, !aborted)
                }
            }

            else -> {
                // notification_events / notification_ready / cursor_expired /
                // resync_required / scope_changed 全部由引擎消费。
                val e = engine ?: return
                if (e.onFrame(frame)) flushOutbound(webSocket)
            }
        }
    }

    /// 引擎排队的出站帧(subscribe/next_page/ack/receipt)经当前 socket 发出。
    private fun flushOutbound(webSocket: WebSocket) {
        val e = engine ?: return
        for (payload in e.pollOutbound()) {
            webSocket.send(payload)
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
            WatcherDiagnostics.log(
                "reconnect BLOCKED(running=$running run=$run/$runGeneration sock=$socketId/$socketGeneration same=${socket === webSocket})",
            )
            return
        }
        socket = null
        socketGeneration++
        appContext?.let { KeepAliveService.updateConnection(it, false) }
        // 断线立刻撤下 ready:否则 Dart 会继续以为原生层在负责通知,
        // 而实际上没人在监听 —— 这正是通知空窗的来源。
        engine?.onTransportClosed()
        if (reconnectPending) return
        reconnectPending = true
        attempt += 1
        val delayMs = minOf(1000L * (1 shl minOf(attempt - 1, 4)), 15_000L)
        WatcherDiagnostics.log("reconnect scheduled(attempt=$attempt delay=${delayMs}ms)")
        val runnable = Runnable {
            synchronized(this) {
                if (!running || run != runGeneration || !reconnectPending) {
                    WatcherDiagnostics.log("reconnect ABORTED(running=$running pending=$reconnectPending)")
                    return@synchronized
                }
                WatcherDiagnostics.log("reconnect firing")
                reconnectPending = false
                reconnectRunnable = null
                connectLocked(runGeneration)
            }
        }
        reconnectRunnable = runnable
        handler.postDelayed(runnable, delayMs)
    }

    /// 旧路径的完成通知。仅在 Bridge 不支持 notification_events_v1 时使用 ——
    /// 此时没有权威 eventId,只能用「host:port:source + 完成时刻」合成一个稳定键,
    /// 让同一次完成在重复投递时仍落到同一个通知槽位。
    @Synchronized
    private fun notifyTaskComplete() {
        if (!running) return
        val current = config ?: return
        val engine = engine ?: return
        val name = current.sessionName
        val title = if (name.isNotEmpty()) "$name 已完成" else "PiPilot 任务完成"
        // 合成 eventId:同一轮完成只会调用一次(WatcherTaskState 保证边沿唯一),
        // 用秒级时间戳让重试落到同一槽位,而不是每次新弹一条。
        val syntheticId =
            "legacy:${current.host}:${current.port}:${current.sourceId}:${System.currentTimeMillis() / 1000}"
        val scope = "${current.clientId}\u0000legacy"
        val state = engine.deliverSynthesized(
            scope,
            RenderableEvent(
                eventId = syntheticId,
                type = "task_completed",
                title = title,
                body = "点击查看结果",
                // 与协议路径一致:完成通知共享同一槽位,多会话完成只更新不新弹。
                collapseKey = "task_completed",
                vibrate = current.vibrate,
            ),
        )
        Log.i(tag, "legacy task complete notification: state=$state")
    }
}
