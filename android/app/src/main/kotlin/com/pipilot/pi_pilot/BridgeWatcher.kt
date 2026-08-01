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

    /// 已发出的任务完成通知 id,stop 时逐个取消 —— 用户回到 App 后通知栏里
    /// 不该还躺着「任务完成」。
    private val postedNotificationIds = mutableSetOf<Int>()

    /// 统一通知入口。所有路径(原生 watcher、FCM、Dart)共用同一套稳定 id
    /// 与去重表,这样重复投递只更新同一条通知而不是叠加。
    private var gate: NotificationGate? = null
    private var cursors: NativeCursorStore? = null

    /// 本次连接的 Bridge 身份与事件世代。来自已鉴权的 bridge_hello ——
    /// mDNS TXT 里的同名字段只是发现提示,不能作为信任根。
    private var bridgeInstallationId: String? = null
    private var eventEpoch: String? = null

    /// 通知事件协议是否可用。旧 Bridge 不声明该能力时回退到
    /// 原有的 streaming 边沿判定,不发任何新帧。
    private var notificationProtocol = false

    /// 连续前缀累加器。只 ack 已收到事件与 Bridge 声明的 skipped range
    /// 构成的最高连续前缀,有缺口就停下并请求 resync。
    private var prefix: ContiguousPrefix? = null

    /// 订阅是否已 ready。socket 打开不等于 ready ——
    /// 必须鉴权、订阅、追平固定 tip 之后才算,否则会过早抑制 Dart 兜底通知。
    private var subscriptionReady = false

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
        ensureNotificationLayer(context, clientId)
        closeSocketLocked()
        connectLocked(runGeneration)
    }

    /// 注册 ready 监听。Dart 只有在收到匹配 generation 的 ready 之后
    /// 才让出通知所有权 —— 这修掉了「提交即成功」导致的过早抑制。
    @Synchronized
    fun setReadyListener(listener: ((Boolean) -> Unit)?) {
        readyListener = listener
        // 立刻回放当前状态,避免注册时机晚于 ready 而漏掉一次通知。
        listener?.invoke(subscriptionReady)
    }

    @Synchronized
    fun isSubscriptionReady(): Boolean = subscriptionReady

    private fun ensureNotificationLayer(context: Context, clientId: String) {
        val app = context.applicationContext
        if (gate == null) {
            gate = NotificationGate(
                NotificationDeduplicator.create(app),
                NativeNotificationRenderer(app),
            )
        }
        // installationId 用 clientId:它已是每安装稳定值(nativeWatcherClientId
        // 由 appClientId + deviceId 派生),重装后会换,正符合 cursor 隔离语义。
        if (cursors == null) cursors = NativeCursorStore.create(app, clientId)
    }

    private fun setReady(value: Boolean) {
        val listener = synchronized(this) {
            if (subscriptionReady == value) return
            subscriptionReady = value
            readyListener
        }
        Log.i(tag, "subscription ready=$value")
        listener?.invoke(value)
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
        bridgeInstallationId = null
        eventEpoch = null
        notificationProtocol = false
        prefix = null
        cancelReadyLocked()
        WatcherDiagnostics.log(
            "stop() by " +
                Throwable().stackTrace.drop(1).take(5)
                    .joinToString(" <- ") { "${it.className.substringAfterLast('.')}.${it.methodName}" },
        )
        Log.i(tag, "stopped")
    }

    private fun cancelPostedNotifications() {
        if (postedNotificationIds.isEmpty()) return
        val manager = appContext?.getSystemService(NotificationManager::class.java) ?: return
        for (id in postedNotificationIds) manager.cancel(id)
        postedNotificationIds.clear()
    }

    /// 撤下 ready。必须在断线、stop、resync 时调用 ——
    /// 让 Dart 立刻恢复兜底通知所有权,不留空窗。
    private fun cancelReadyLocked() {
        if (!subscriptionReady) return
        subscriptionReady = false
        val listener = readyListener
        handler.post { listener?.invoke(false) }
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
            // 握手完成后立刻订阅目标 source,否则 bridge 不会向本连接广播事件。
            // 同时拉一份轻量会话表,用来补判 watcher 断线期间错过的 agent_end。
            "bridge_hello" -> {
                val current = config ?: return
                synchronized(this) { attempt = 0 }
                appContext?.let { KeepAliveService.updateConnection(it, true) }
                val suffix = "$run-$socketId"

                // 身份以已鉴权的 hello 为准。mDNS TXT 里的 bridgeId 只是发现提示,
                // 同网设备可以伪造它,不能作为信任根。
                val caps = frame.optJSONArray("capabilities")
                val supportsEvents = (0 until (caps?.length() ?: 0))
                    .any { caps?.optString(it) == "notification_events_v1" }
                val helloBridgeId = frame.optString("bridgeInstallationId").takeIf { it.isNotEmpty() }
                val helloEpoch = frame.optString("eventEpoch").takeIf { it.isNotEmpty() }

                synchronized(this) {
                    notificationProtocol = supportsEvents && helloBridgeId != null && helloEpoch != null
                    bridgeInstallationId = helloBridgeId
                    eventEpoch = helloEpoch
                }

                if (notificationProtocol && helloBridgeId != null && helloEpoch != null) {
                    // 通知协议可用时刻意不发 hub_select_source。
                    //
                    // 选中 source 会招来 MB 级 hub_source_snapshot(实测约 1 MiB),
                    // 而 watcher 只需要其中的 isStreaming 一个布尔值。大帧会把
                    // OkHttp 读线程占住,Bridge 每 10s 一次的协议层 ping 连丢 3 次后
                    // 判定半开并 terminate —— 订阅和 ready 全部白做,cursor 永远停在 0。
                    // 完成事件此时由 Bridge 权威生成,不需要这条边沿判定。
                    subscribeNotifications(webSocket, suffix, helloBridgeId, helloEpoch)
                } else {
                    // 旧 Bridge 才需要靠 source 快照与会话表补判 agent_end。
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
                    // 旧 Bridge:回退到 streaming 边沿判定。此时不发新帧,
                    // 也不宣布 ready —— 让 Dart 保持兜底所有权更安全。
                    Log.i(tag, "bridge lacks notification_events_v1; using legacy edge detection")
                }
            }

            "response" -> {
                val id = frame.optString("id")
                if (id.startsWith("watcher-sessions-")) {
                    frame.optJSONObject("data")?.optJSONArray("sessions")?.let {
                        reconcileSessions(run, it)
                    }
                }
                // notification_subscribe / notification_next_page 的首页数据包在
                // response.data 里,不是独立的 notification_events 帧。
                //
                // 漏掉这里的后果是致命的:首页里的 fromExclusive/through 拿不到,
                // 本地连续前缀停在 0,实时推送的 seq=N 永远与 0 不连续,ack 因
                // through<=0 被跳过 —— cursor 永久卡死,每次重连都从头再来。
                val data = frame.optJSONObject("data")
                if (data != null) {
                    when (data.optString("type")) {
                        "notification_events" -> handleNotificationEvents(webSocket, data)
                        "notification_ready" -> {
                            setReady(true)
                            ackCursor(webSocket)
                        }
                        "notification_cursor_expired",
                        "notification_resync_required",
                        "notification_scope_changed",
                        -> handleFrame(run, socketId, webSocket, data.toString())
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

            "agent_start" -> {
                // 有通知协议时完成事件由 Bridge 权威生成,这里不再自己判边沿,
                // 否则同一次完成会被两条路径各算一次。
                if (!notificationProtocol) reconcileStreaming(run, true, false)
            }

            // agent_end 与 agent_settled 都代表本轮结束,取先到的那个。
            "agent_end", "agent_settled" -> {
                if (!notificationProtocol) reconcileStreaming(run, false, true)
            }

            // --- 通知事件协议(stable-plan.md §7)---------------------------
            "notification_events" -> handleNotificationEvents(webSocket, frame)

            "notification_ready" -> {
                // 只有这一帧才代表原生层真正接管了通知。
                setReady(true)
                ackCursor(webSocket)
            }

            "notification_cursor_expired" -> {
                val bridgeId = bridgeInstallationId ?: return
                val epoch = frame.optString("eventEpoch").takeIf { it.isNotEmpty() } ?: return
                val oldest = frame.optLong("oldestAvailable", 1L)
                // rebase 意味着中间一段历史永久丢失,如实记录缺口而不是假装补齐。
                val gap = cursors?.rebase(bridgeId, epoch, oldest) ?: 0L
                synchronized(this) {
                    eventEpoch = epoch
                    prefix = ContiguousPrefix(maxOf(0L, oldest - 1))
                }
                Log.w(
                    tag,
                    "cursor expired reason=${frame.optString("reason")} gap=$gap; rebased to ${oldest - 1}",
                )
                // rebase 后重新订阅,拿到新的固定 tip。
                val suffix = "rebase-${System.currentTimeMillis()}"
                subscribeNotifications(webSocket, suffix, bridgeId, epoch)
            }

            "notification_resync_required", "notification_scope_changed" -> {
                // 服务端要求重来:先撤 ready 让 Dart 恢复兜底,再重新订阅。
                cancelReadyLocked()
                val bridgeId = bridgeInstallationId ?: return
                val epoch = eventEpoch ?: return
                Log.w(tag, "resync required: ${frame.optString("type")}")
                subscribeNotifications(webSocket, "resync-${System.currentTimeMillis()}", bridgeId, epoch)
            }
        }
    }

    /// 发起通知订阅。cursor 为 null 时 Bridge 从最早可用位点开始,
    /// 不会补发全部历史 —— 首次安装不该被几百条旧通知淹没。
    private fun subscribeNotifications(
        webSocket: WebSocket,
        suffix: String,
        bridgeId: String,
        epoch: String,
    ) {
        val current = config ?: return
        val saved = cursors?.read(bridgeId)
        // epoch 不匹配说明 Bridge 事件库被重置过,旧 sequence 无意义。
        val cursorJson = if (saved != null && saved.eventEpoch == epoch) {
            JSONObject().put("eventEpoch", saved.eventEpoch).put("sequence", saved.through)
        } else {
            null
        }
        synchronized(this) {
            prefix = ContiguousPrefix(if (cursorJson != null) saved!!.through else 0L)
        }
        val payload = JSONObject()
            .put("type", "notification_subscribe")
            .put("id", "watcher-notify-$suffix")
            .put("installationId", current.clientId)
            .put("scopeVersion", 1)
            .put("pageLimit", 100)
        if (cursorJson != null) payload.put("cursor", cursorJson)
        webSocket.send(payload.toString())
        Log.i(tag, "notification_subscribe from=${saved?.through ?: 0} epoch=${shortId(epoch)}")
    }

    /// 处理一页事件(catch-up 或实时推送)。
    ///
    /// 关键:skippedRanges 必须计入连续性。被 scope 排除或已被 TTL 回收的
    /// sequence 永远不会到达,不计入的话 cursor 会永久卡住。
    private fun handleNotificationEvents(webSocket: WebSocket, frame: JSONObject) {
        val accumulator = prefix
        val current = config
        val scope = notificationScope()
        if (accumulator == null || current == null || scope == null) {
            Log.w(
                tag,
                "notification_events dropped: prefix=${accumulator != null} " +
                    "config=${current != null} scope=${scope != null} " +
                    "bridgeId=${bridgeInstallationId != null} epoch=${eventEpoch != null}",
            )
            return
        }
        WatcherDiagnostics.log(
            "events(from=${frame.optLong("fromExclusive", -1)} through=${frame.optLong("through", -1)} " +
                "count=${frame.optJSONArray("events")?.length() ?: 0} hasMore=${frame.optBoolean("hasMore")})",
        )
        Log.i(tag, "notification_events count=${frame.optJSONArray("events")?.length() ?: 0} hasMore=${frame.optBoolean("hasMore")}")

        // 先按 Bridge 声明的页起点对齐。实时推送(live=true)的帧不带
        // fromExclusive,此时保持本地位点不动。
        if (frame.has("fromExclusive")) {
            accumulator.rebaseTo(frame.optLong("fromExclusive"))
        }

        val skipped = frame.optJSONArray("skippedRanges")
        for (i in 0 until (skipped?.length() ?: 0)) {
            val range = skipped?.optJSONObject(i) ?: continue
            accumulator.acceptSkipped(range.optLong("from"), range.optLong("through"))
        }

        val events = frame.optJSONArray("events")
        val total = events?.length() ?: 0
        // 批量追补只打扰一次:除末页最后一条外全部静默入栈。
        // 与 coordinator 保持一致——否则关掉 flag 就退回逐条轰炸。
        val hasMore = frame.optBoolean("hasMore")
        for (i in 0 until total) {
            val event = events?.optJSONObject(i) ?: continue
            val eventId = event.optString("eventId").takeIf { it.isNotEmpty() } ?: continue
            val sequence = event.optLong("sequence", -1L)
            if (sequence < 0) continue
            deliverEvent(scope, event, current.vibrate, silent = hasMore || i < total - 1)
            accumulator.accept(sequence)
        }

        // 还有分页就继续拉,不能停在半路 —— 停下等于漏掉后面的完成事件。
        if (hasMore) {
            webSocket.send(
                JSONObject()
                    .put("type", "notification_next_page")
                    .put("id", "watcher-notify-page-${System.currentTimeMillis()}")
                    .put("scopeVersion", 1)
                    .toString(),
            )
            return
        }
        ackCursor(webSocket)
    }

    private fun deliverEvent(
        scope: String,
        event: JSONObject,
        vibrate: Boolean,
        silent: Boolean = false,
    ) {
        val gate = gate ?: return
        val eventId = event.optString("eventId")
        val type = event.optString("type")
        val deliverStartedAt = System.currentTimeMillis()
        WatcherDiagnostics.log("deliver start(seq=${event.optLong("sequence", -1)} id=${eventId.take(8)})")
        val presentation = event.optJSONObject("presentation")
        val title = presentation?.optString("title").orEmpty().ifEmpty { "PiPilot" }
        val body = presentation?.optString("body")?.takeIf { it.isNotEmpty() }
        val collapseKey = event.optString("collapseKey").takeIf { it.isNotEmpty() }
        val renderable = RenderableEvent(
            eventId = eventId,
            type = type,
            title = title,
            body = body,
            collapseKey = collapseKey,
            vibrate = vibrate,
            silent = silent,
        )
        if (type == "input_resolved") {
            // 等待输入已被处理:撤掉原来那条提醒,不新弹一条。
            gate.resolve(scope, renderable)
            WatcherDiagnostics.log("deliver end(id=${eventId.take(8)} state=RESOLVED ms=${System.currentTimeMillis() - deliverStartedAt})")
            return
        }
        val state = gate.deliver(scope, renderable)
        WatcherDiagnostics.log(
            "deliver end(id=${eventId.take(8)} state=$state silent=$silent ms=${System.currentTimeMillis() - deliverStartedAt})",
        )
        if (state == DeliveryState.DISPLAY_REQUESTED || state == DeliveryState.DISPLAY_CONFIRMED) {
            postedNotificationIds.add(StableNotificationId.forEvent(collapseKey ?: eventId))
        }
        // receipt 只服务仲裁与指标,不推进 cursor,失败也不影响正确性。
        socket?.send(
            JSONObject()
                .put("type", "notification_receipt")
                .put("installationId", config?.clientId.orEmpty())
                .put("eventId", eventId)
                .put("state", receiptStateName(state))
                .put("at", java.time.Instant.now().toString())
                .toString(),
        )
    }

    private fun receiptStateName(state: DeliveryState): String = when (state) {
        DeliveryState.PENDING -> "received"
        DeliveryState.DISPLAY_REQUESTED -> "display_requested"
        DeliveryState.DISPLAY_CONFIRMED -> "display_confirmed"
        DeliveryState.SUPPRESSED_DUPLICATE -> "suppressed_duplicate"
        DeliveryState.BLOCKED -> "blocked_permission"
    }

    /// 去重表的作用域键。必须同时含 installationId 与 bridgeInstallationId,
    /// 否则换 Bridge 或多设备会互相抑制通知。
    private fun notificationScope(): String? {
        val installation = config?.clientId ?: return null
        val bridgeId = bridgeInstallationId ?: return null
        return "$installation\u0000$bridgeId"
    }

    /// ack 到最高连续前缀。有缺口就不 ack —— 那会让缺口里的事件永久丢失。
    private fun ackCursor(webSocket: WebSocket) {
        val accumulator = prefix ?: return
        val bridgeId = bridgeInstallationId ?: return
        val epoch = eventEpoch ?: return
        val installation = config?.clientId ?: return
        val through = accumulator.current()
        if (through <= 0) {
            WatcherDiagnostics.log("ack skipped(through=$through)")
            return
        }
        val advanced = cursors?.advance(NotificationCursor(bridgeId, epoch, through)) ?: false
        if (!advanced && accumulator.hasGap()) {
            Log.w(tag, "cursor has a gap; holding ack at $through")
        }
        WatcherDiagnostics.log("ack send(through=$through advanced=$advanced gap=${accumulator.hasGap()})")
        webSocket.send(
            JSONObject()
                .put("type", "notification_ack")
                .put("installationId", installation)
                .put("eventEpoch", epoch)
                .put("through", through)
                .toString(),
        )
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
        cancelReadyLocked()
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
        val context = appContext ?: return
        val gate = gate ?: return
        val name = current.sessionName
        val title = if (name.isNotEmpty()) "$name 已完成" else "PiPilot 任务完成"
        // 合成 eventId:同一轮完成只会调用一次(WatcherTaskState 保证边沿唯一),
        // 用秒级时间戳让重试落到同一槽位,而不是每次新弹一条。
        val syntheticId =
            "legacy:${current.host}:${current.port}:${current.sourceId}:${System.currentTimeMillis() / 1000}"
        val scope = "${current.clientId}\u0000legacy"
        val state = gate.deliver(
            scope,
            RenderableEvent(
                eventId = syntheticId,
                type = "task_completed",
                title = title,
                body = "点击查看结果",
                collapseKey = null,
                vibrate = current.vibrate,
            ),
        )
        if (state == DeliveryState.DISPLAY_REQUESTED || state == DeliveryState.DISPLAY_CONFIRMED) {
            postedNotificationIds.add(StableNotificationId.forEvent(syntheticId))
        }
        Log.i(tag, "legacy task complete notification: state=$state")
    }
}
