package com.pipilot.pi_pilot

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.TimeUnit
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

/// Phase 3 原生 LAN connection owner。
///
/// 与 BridgeWatcher 的分工:watcher 的生命周期由 Dart/Activity 驱动(后台才
/// start,前台就 stop);coordinator 持有持久目标,能独立重建、按系统网络事件
/// 自愈,不依赖 Dart 是否在跑。默认关(FeatureFlags.NATIVE_LAN_OWNER),
/// 打开后与 watcher 走同一 ready 上报通道,ready 前绝不抑制 Dart 兜底。
///
/// 已验证模式的复用与修正:
/// - 协议帧(subscribe/events/ack/cursor_expired)与 BridgeWatcher 完全一致;
/// - 选网按目标地址匹配(子网前缀/路由),不是 BridgeWatcher.routedClient 的
///   第一张 Wi-Fi——后者与 bindWifiForLan 旧缺陷同类,双 Wi-Fi 下会选错;
/// - 只用 network.socketFactory + network DNS,禁止 bindProcessToNetwork;
/// - 身份以认证后 bridge_hello 为准,mDNS bridgeId 永远只是提示。
object LanConnectionCoordinator {
    private const val tag = "LanCoordinator"

    private val baseClient = OkHttpClient.Builder()
        .pingInterval(15, TimeUnit.SECONDS)
        .build()

    /// 连续失败这么多次后触发 NSD 地址自愈。
    private const val NSD_TRIGGER_ATTEMPTS = 3

    private data class RoutedClient(val client: OkHttpClient, val route: String)

    private val handler = Handler(Looper.getMainLooper())
    private val states = LanConnectionStateHolder()
    private var reconnect = ReconnectController()

    private var appContext: Context? = null
    private var target: NativeLanTarget? = null
    private var plainToken: String? = null
    private var vibrate: Boolean = true
    private var cipher: TokenCipher = KeystoreTokenCipher()
    private var nsd: NsdDiscovery? = null
    private var nsdInFlight = false

    private var gate: NotificationGate? = null
    private var cursors: NativeCursorStore? = null
    private var prefix: ContiguousPrefix? = null

    private var webSocket: WebSocket? = null
    private var socketSeq: Long = 0L

    private var notificationProtocol = false
    private var bridgeInstallationId: String? = null
    private var eventEpoch: String? = null
    private var connectStartedAt: Long = 0L
    private var lastActiveAt: Long = 0L
    private var readyListener: ((Boolean) -> Unit)? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    /// Dart/服务给出的显式启动。token 只进内存,持久化的是 Keystore 密文。
    fun start(
        context: Context,
        target: NativeLanTarget,
        token: String,
        vibrate: Boolean = true,
        cipher: TokenCipher = KeystoreTokenCipher(),
    ) {
        synchronized(this) {
            val previous = this.target
            val sameTarget = previous != null &&
                previous.host == target.host &&
                previous.port == target.port &&
                previous.clientId == target.clientId &&
                this.plainToken == token
            val alive = reconnect.state == ReconnectController.State.RUNNING ||
                reconnect.state == ReconnectController.State.PENDING
            // 幂等保护:Dart 生命周期会连续调 startWatcher。没有这个快通道时
            // 每次调用都 generation++ 并新建 socket,旧 socket 只是回调失效、并未关闭,
            // 真机上当场泄了 4 条连接(mobileClients=5)。
            if (sameTarget && alive) {
                this.vibrate = vibrate
                WatcherDiagnostics.log(
                    "coordinator start(sameTarget=true keep gen=${reconnect.generation} socket=${webSocket != null})",
                )
                // socket 既不在也没排重连时才补一次,否则保持现状。
                if (webSocket == null && reconnect.pendingSchedule() == null) {
                    connectLocked(reconnect.generation)
                }
                return
            }
            appContext = context.applicationContext
            this.target = target
            this.plainToken = token
            this.vibrate = vibrate
            this.cipher = cipher
            // 换目标/换凭据:旧 socket 必须先关掉再开新世代。
            closeSocketLocked()
            WatcherDiagnostics.init(context.applicationContext)
            ensureNotificationLayer(context.applicationContext, target.clientId)
            val gen = reconnect.start()
            // 两个世代计数只在 start 内同步自增,值保持一致;回调防护统一用 gen。
            states.beginGeneration()
            registerNetworkCallback(context.applicationContext)
            WatcherDiagnostics.log("coordinator start(host=${target.host}:${target.port} gen=$gen)")
        }
        connectLocked(reconnect.generation)
    }

    /// 空 Intent 重建:只依赖持久目标。Keystore 在首次解锁前不可用时
    /// 返回 false——调用方保留兜底,不得声称 owner 已建立。
    fun startFromPersisted(context: Context): Boolean {
        val stored = NativeLanTarget.load(context) ?: return false
        val token = KeystoreTokenCipher().unwrap(stored.wrappedToken) ?: return false
        start(context, stored, token)
        return true
    }

    fun stop(reason: String) {
        synchronized(this) {
            val gen = reconnect.generation
            reconnect.stop(gen)
            states.transitionTo(gen, LanConnectionState.DISCONNECTED, reason)
            closeSocketLocked()
            setReadyLocked(false)
            unregisterNetworkCallback()
            WatcherDiagnostics.log("coordinator stop(reason=$reason)")
        }
    }

    fun setReadyListener(listener: ((Boolean) -> Unit)?) {
        readyListener = listener
        listener?.invoke(states.isReady())
    }

    fun isReady(): Boolean = states.isReady()

    fun currentState(): LanConnectionState = states.state

    private fun ensureNotificationLayer(context: Context, clientId: String) {
        if (gate == null) {
            val dedupe = NotificationDeduplicator.create(context)
            val renderer = NativeNotificationRenderer(context)
            gate = NotificationGate(dedupe, renderer)
        }
        if (cursors == null) cursors = NativeCursorStore.create(context, clientId)
    }

    // ------------------------------------------------------------------
    // 网络自愈:系统通告优先于退避定时器
    // ------------------------------------------------------------------

    private fun registerNetworkCallback(context: Context) {
        if (networkCallback != null) return
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val gen = reconnect.generation
                ConnectionMetrics.record(context, "network_available")
                // 只有真的没连上才借网络通告提前点火。正在连/已 ready 时插一脚
                // 只会制造第二条 socket——首次真机运行就是这样泄的。
                val idle = when (states.state) {
                    LanConnectionState.DISCONNECTED,
                    LanConnectionState.DEGRADED,
                    LanConnectionState.BLOCKED_LOCAL_NETWORK,
                    -> true
                    else -> false
                }
                if (!idle) {
                    WatcherDiagnostics.log("network available ignored(state=${states.state})")
                    return
                }
                val s = reconnect.onNetworkAvailable(gen) ?: return
                WatcherDiagnostics.log("network available -> immediate reconcile(gen=$gen)")
                handler.post { fireReconnect(gen, s.attempt) }
            }

            override fun onLost(network: Network) {
                ConnectionMetrics.record(context, "network_lost")
                states.transitionTo(
                    reconnect.generation,
                    LanConnectionState.DEGRADED,
                    "network_lost",
                )
                setReadyLocked(false)
            }
        }
        runCatching {
            connectivity.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        }.onFailure { Log.w(tag, "registerDefaultNetworkCallback failed: ${it.message}") }
    }

    private fun unregisterNetworkCallback() {
        val connectivity = appContext?.getSystemService(ConnectivityManager::class.java)
        networkCallback?.let { runCatching { connectivity?.unregisterNetworkCallback(it) } }
        networkCallback = null
    }

    // ------------------------------------------------------------------
    // 连接与重连
    // ------------------------------------------------------------------

    private fun isCurrent(gen: Long, socketId: Long, ws: WebSocket): Boolean =
        gen == reconnect.generation && socketId == socketSeq && ws === webSocket

    private fun connectLocked(gen: Long) {
        val context = appContext ?: return
        val t = target ?: return
        val token = plainToken ?: return
        if (reconnect.state == ReconnectController.State.STOPPED) return

        states.transitionTo(gen, LanConnectionState.CONNECTING, "connect")
        connectStartedAt = System.currentTimeMillis()
        // 无论为何重连,开新 socket 前必须关掉旧的:仅靠世代判断只能让旧回调
        // 失效,TCP 连接会一直活到 Bridge 判它半开(约 30s),期间事件会被推到
        // 没人读的旧 socket 上。
        val stale = webSocket
        if (stale != null) {
            webSocket = null
            WatcherDiagnostics.log("coordinator closing stale socket before reconnect")
            runCatching { stale.close(1000, "superseded") }
        }
        val routed = routedClientFor(context, t.host)
        val wsUrl = buildString {
            append("ws://")
            append(t.host)
            append(':')
            append(t.port)
            append("/mobile?token=")
            append(java.net.URLEncoder.encode(token, "UTF-8"))
            append("&clientId=")
            append(java.net.URLEncoder.encode(t.clientId, "UTF-8"))
        }
        val request = Request.Builder().url(wsUrl).build()
        val socketId = ++socketSeq
        WatcherDiagnostics.log("coordinator connect(gen=$gen socket=$socketId route=${routed.route})")
        val ws = routed.client.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (!isCurrent(gen, socketId, webSocket)) return
                    noteActivity(gen)
                    states.transitionTo(gen, LanConnectionState.AUTHENTICATING, "open")
                    WatcherDiagnostics.log("coordinator onOpen(gen=$gen socket=$socketId route=${routed.route})")
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (!isCurrent(gen, socketId, webSocket)) return
                    noteActivity(gen)
                    handleFrame(gen, socketId, webSocket, text)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (!isCurrent(gen, socketId, webSocket)) return
                    WatcherDiagnostics.log("coordinator onFailure(gen=$gen msg=${t.message})")
                    onSocketLost(gen, "failure:${t.message?.take(48)}")
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    if (!isCurrent(gen, socketId, webSocket)) return
                    WatcherDiagnostics.log("coordinator onClosed(gen=$gen code=$code)")
                    onSocketLost(gen, "closed:$code")
                }
            },
        )
        webSocket = ws
    }

    private fun onSocketLost(gen: Long, reason: String) {
        webSocket = null
        setReadyLocked(false)
        states.transitionTo(gen, LanConnectionState.DISCONNECTED, reason)
        val s = reconnect.onConnectionLost(gen) ?: return
        ConnectionMetrics.record(
            appContext ?: return,
            "reconnect_scheduled",
            mapOf("attempt" to s.attempt, "delayMs" to s.delayMs),
        )
        WatcherDiagnostics.log("coordinator reconnect scheduled(attempt=${s.attempt} delay=${s.delayMs})")
        handler.postDelayed({ fireReconnect(gen, s.attempt) }, s.delayMs)
        // 连续失败说明 endpoint 可能已失效(DHCP 换址/换路由):触发一轮 NSD
        // 重新发现,身份匹配才允许改写目标——这是地址自愈的唯一来源。
        if (s.attempt >= NSD_TRIGGER_ATTEMPTS) {
            discoverEndpoint(gen)
        }
    }

    /// NSD 地址自愈。TXT bridgeId 只是提示:与持久身份不符的候选记冲突跳过,
    /// 绝不静默改写 endpoint;持久身份为空(尚未连上过)才接受候选并在 hello 学习。
    private fun discoverEndpoint(gen: Long) {
        val context = appContext ?: return
        val current = target ?: return
        if (nsdInFlight) return
        nsdInFlight = true
        val discovery = NsdDiscovery(context)
        nsd = discovery
        WatcherDiagnostics.log("coordinator nsd discover start(gen=$gen)")
        discovery.discoverOnce { candidates ->
            nsdInFlight = false
            if (gen != reconnect.generation) return@discoverOnce
            val t = target ?: return@discoverOnce
            val persistedId = t.bridgeInstallationId
            val match = candidates.firstOrNull { candidate ->
                when {
                    !candidate.notify -> false
                    persistedId == null -> true
                    candidate.bridgeId == persistedId -> true
                    else -> {
                        ConnectionMetrics.record(context, "identity_conflict")
                        WatcherDiagnostics.log(
                            "coordinator nsd identity_conflict(candidate=${candidate.bridgeId?.take(14)} persisted=${persistedId?.take(14)})",
                        )
                        false
                    }
                }
            } ?: run {
                WatcherDiagnostics.log("coordinator nsd no matching candidate(${candidates.size} found)")
                return@discoverOnce
            }
            if (match.host == t.host && match.port == t.port) {
                WatcherDiagnostics.log("coordinator nsd same endpoint, no update")
                return@discoverOnce
            }
            val updated = t.copy(host = match.host, port = match.port)
            if (!NativeLanTarget.save(context, updated, cipher)) {
                WatcherDiagnostics.log("coordinator nsd target persist failed, keep old")
                return@discoverOnce
            }
            target = updated
            ConnectionMetrics.record(
                context,
                "network_available",
                mapOf("nsd" to "${match.host}:${match.port}"),
            )
            WatcherDiagnostics.log("coordinator nsd endpoint updated -> ${match.host}:${match.port}")
            // 目标变了立即重连,不等退避定时器。
            val immediate = reconnect.onNetworkAvailable(gen) ?: return@discoverOnce
            handler.post { fireReconnect(gen, immediate.attempt) }
        }
    }

    private fun fireReconnect(gen: Long, attempt: Int) {
        val current = reconnect.fire(gen, attempt) ?: run {
            WatcherDiagnostics.log("coordinator reconnect fire aborted(gen=$gen attempt=$attempt)")
            return
        }
        connectLocked(current)
    }

    private fun closeSocketLocked() {
        socketSeq++
        val ws = webSocket
        webSocket = null
        if (ws != null) runCatching { ws.close(1000, "coordinator stop") }
    }

    /// OEM 冻结探针:回调线程恢复时若距上次活跃超过 90s,而期间 socket 一直
    /// 被认为存活,极可能是进程被整体冻结过(实测 MIUI 后台约 60s 即冻结)。
    private fun noteActivity(gen: Long) {
        val now = System.currentTimeMillis()
        val last = lastActiveAt
        if (last > 0 && now - last > 90_000L) {
            ConnectionMetrics.record(
                appContext ?: return,
                "oem_freeze_suspected",
                mapOf("gapMs" to (now - last)),
            )
            WatcherDiagnostics.log("coordinator activity gap ${now - last}ms(oem freeze suspected)")
        }
        lastActiveAt = now
    }

    // ------------------------------------------------------------------
    // 目标感知选网:只用 socketFactory,绝不进程级绑定
    // ------------------------------------------------------------------

    private fun routedClientFor(context: Context, host: String): RoutedClient {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
            ?: return RoutedClient(baseClient, "default")
        val literal = runCatching {
            if (host.any { it != '.' && it != ':' && !it.isDigit() && it.lowercaseChar() !in 'a'..'f' }) {
                null
            } else {
                java.net.InetAddress.getByName(host)
            }
        }.getOrNull()

        val candidates = connectivity.allNetworks.filter { network ->
            val caps = connectivity.getNetworkCapabilities(network)
            val links = connectivity.getLinkProperties(network)?.linkAddresses
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                links?.any { it.address is java.net.Inet4Address } == true
        }
        if (candidates.isEmpty()) return RoutedClient(baseClient, "default")

        val chosen = if (literal == null) {
            candidates.first()
        } else {
            candidates.firstOrNull { network ->
                connectivity.getLinkProperties(network)?.linkAddresses?.any { link ->
                    val local = link.address
                    local is java.net.Inet4Address && sameSubnet(local, literal, link.prefixLength)
                } == true
            } ?: candidates.firstOrNull { network ->
                connectivity.getLinkProperties(network)?.routes?.any { route ->
                    runCatching { route.matches(literal) }.getOrDefault(false)
                } == true
            }
        } ?: run {
            // 没有任何已登记网络能到目标:记 LNP 阻塞指标,仍走默认让系统尽力。
            ConnectionMetrics.record(appContext ?: context, "blocked_local_network")
            states.transitionTo(
                reconnect.generation,
                LanConnectionState.BLOCKED_LOCAL_NETWORK,
                "no_route:$host",
            )
            return RoutedClient(baseClient, "default")
        }

        return try {
            val client = baseClient.newBuilder()
                .socketFactory(chosen.socketFactory)
                .dns(object : Dns {
                    override fun lookup(hostname: String): List<java.net.InetAddress> =
                        chosen.getAllByName(hostname).toList()
                })
                .build()
            RoutedClient(client, "wifi-matched")
        } catch (error: Exception) {
            Log.w(tag, "matched route unavailable, default: ${error.message}")
            RoutedClient(baseClient, "default")
        }
    }

    private fun sameSubnet(local: java.net.Inet4Address, targetAddr: java.net.InetAddress, prefixLength: Int): Boolean {
        if (targetAddr !is java.net.Inet4Address) return false
        if (prefixLength <= 0 || prefixLength > 32) return false
        val a = local.address
        val b = targetAddr.address
        var bitsLeft = prefixLength
        for (i in 0 until 4) {
            if (bitsLeft <= 0) break
            val maskBits = if (bitsLeft >= 8) 8 else bitsLeft
            val mask = (0xFF shl (8 - maskBits)) and 0xFF
            if ((a[i].toInt() and mask) != (b[i].toInt() and mask)) return false
            bitsLeft -= maskBits
        }
        return true
    }

    // ------------------------------------------------------------------
    // 协议(与 BridgeWatcher 通知协议一致)
    // ------------------------------------------------------------------

    private fun handleFrame(gen: Long, socketId: Long, webSocket: WebSocket, text: String) {
        val frame = try {
            JSONObject(text)
        } catch (_: Exception) {
            return
        }
        when (frame.optString("type")) {
            "bridge_hello" -> handleHello(gen, socketId, webSocket, frame)
            "response" -> handleResponse(gen, socketId, webSocket, frame)
            "notification_events" -> handleNotificationEvents(webSocket, frame)
            "notification_ready" -> {
                reconnect.onConnected(gen)
                states.transitionTo(gen, LanConnectionState.READY, "ready")
                val latency = System.currentTimeMillis() - connectStartedAt
                ConnectionMetrics.record(
                    appContext ?: return,
                    "ready",
                    mapOf("latencyMs" to latency),
                )
                WatcherDiagnostics.log("coordinator READY(gen=$gen latency=${latency}ms)")
                setReadyLocked(true)
                ackCursor(webSocket)
            }
            "notification_cursor_expired" -> {
                val oldest = frame.optLong("oldestAvailable", 0L)
                val bridgeId = bridgeInstallationId ?: return
                val epoch = frame.optString("eventEpoch").takeIf { it.isNotEmpty() } ?: eventEpoch ?: return
                val gap = cursors?.rebase(bridgeId, epoch, oldest) ?: 0L
                ConnectionMetrics.record(
                    appContext ?: return,
                    "cursor_recovery",
                    mapOf("rebaseGap" to gap, "oldest" to oldest),
                )
                subscribeNotifications(webSocket, "rebase-${System.currentTimeMillis()}", bridgeId, epoch)
            }
            "notification_resync_required", "notification_scope_changed" -> {
                setReadyLocked(false)
                val bridgeId = bridgeInstallationId ?: return
                val epoch = eventEpoch ?: return
                subscribeNotifications(webSocket, "resync-${System.currentTimeMillis()}", bridgeId, epoch)
            }
            else -> Unit
        }
    }

    /// 首包藏在 response.data 里——这是 BridgeWatcher 曾踩过的坑,直接复用结论。
    private fun handleResponse(gen: Long, socketId: Long, webSocket: WebSocket, frame: JSONObject) {
        val data = frame.optJSONObject("data") ?: return
        when (data.optString("type")) {
            "notification_events" -> handleNotificationEvents(webSocket, data)
            "notification_ready" -> handleFrame(gen, socketId, webSocket, data.toString())
            "notification_cursor_expired",
            "notification_resync_required",
            "notification_scope_changed",
            -> handleFrame(gen, socketId, webSocket, data.toString())
            else -> Unit
        }
    }

    private fun handleHello(gen: Long, socketId: Long, webSocket: WebSocket, frame: JSONObject) {
        val t = target ?: return
        val caps = frame.optJSONArray("capabilities")
        val supportsEvents = (0 until (caps?.length() ?: 0))
            .any { caps?.optString(it) == "notification_events_v1" }
        val helloBridgeId = frame.optString("bridgeInstallationId").takeIf { it.isNotEmpty() }
        val helloEpoch = frame.optString("eventEpoch").takeIf { it.isNotEmpty() }

        notificationProtocol = supportsEvents && helloBridgeId != null && helloEpoch != null
        if (!notificationProtocol || helloBridgeId == null || helloEpoch == null) {
            // coordinator 只接管新协议 Bridge。旧 Bridge 交还 watcher/Dart 路径。
            WatcherDiagnostics.log("coordinator: bridge lacks notification_events_v1, decline ownership")
            setReadyLocked(false)
            return
        }

        // 身份守卫:认证身份与持久值不符,记冲突且绝不改写 endpoint。
        // 首次连接(持久值为空)才允许学习并落盘。
        val persistedId = t.bridgeInstallationId
        if (persistedId != null && persistedId != helloBridgeId) {
            ConnectionMetrics.record(appContext ?: return, "identity_conflict")
            WatcherDiagnostics.log("coordinator identity_conflict(persisted=${persistedId.take(14)} hello=${helloBridgeId.take(14)})")
            setReadyLocked(false)
            webSocket.close(4000, "identity conflict")
            return
        }

        bridgeInstallationId = helloBridgeId
        eventEpoch = helloEpoch
        // 首次连上学到的身份落盘:之后 NSD 自愈与冲突检测都以它为准。
        if (persistedId == null) {
            val context = appContext
            if (context != null) {
                val adopted = t.copy(bridgeInstallationId = helloBridgeId)
                if (NativeLanTarget.save(context, adopted, cipher)) {
                    target = adopted
                    WatcherDiagnostics.log("coordinator identity adopted(${helloBridgeId.take(14)})")
                }
            }
        }
        reconnect.onConnected(gen)
        ConnectionMetrics.record(appContext ?: return, "reconnect_ok")
        states.transitionTo(gen, LanConnectionState.CATCHING_UP, "hello")
        subscribeNotifications(webSocket, "$gen-$socketId", helloBridgeId, helloEpoch)
    }

    private fun subscribeNotifications(webSocket: WebSocket, suffix: String, bridgeId: String, epoch: String) {
        val t = target ?: return
        val saved = cursors?.read(bridgeId)
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
            .put("id", "coordinator-notify-$suffix")
            .put("installationId", t.clientId)
            .put("scopeVersion", 1)
            .put("pageLimit", 100)
        if (cursorJson != null) payload.put("cursor", cursorJson)
        webSocket.send(payload.toString())
        WatcherDiagnostics.log("coordinator subscribe(from=${saved?.through ?: 0})")
    }

    private fun handleNotificationEvents(webSocket: WebSocket, frame: JSONObject) {
        val accumulator = prefix ?: return
        val t = target ?: return
        val bridgeId = bridgeInstallationId ?: return

        if (frame.has("fromExclusive")) {
            accumulator.rebaseTo(frame.optLong("fromExclusive"))
        }
        val skipped = frame.optJSONArray("skippedRanges")
        for (i in 0 until (skipped?.length() ?: 0)) {
            val range = skipped?.optJSONObject(i) ?: continue
            accumulator.acceptSkipped(range.optLong("from"), range.optLong("through"))
        }
        val events = frame.optJSONArray("events")
        for (i in 0 until (events?.length() ?: 0)) {
            val event = events?.optJSONObject(i) ?: continue
            val eventId = event.optString("eventId").takeIf { it.isNotEmpty() } ?: continue
            val sequence = event.optLong("sequence", -1L)
            if (sequence < 0) continue
            deliverEvent("${t.clientId}\u0000$bridgeId", event)
            accumulator.accept(sequence)
        }
        if (frame.optBoolean("hasMore")) {
            webSocket.send(
                JSONObject()
                    .put("type", "notification_next_page")
                    .put("id", "coordinator-notify-page-${System.currentTimeMillis()}")
                    .put("scopeVersion", 1)
                    .toString(),
            )
            return
        }
        ackCursor(webSocket)
    }

    private fun deliverEvent(scope: String, event: JSONObject) {
        val notificationGate = gate ?: return
        val eventId = event.optString("eventId").takeIf { it.isNotEmpty() } ?: return
        val presentation = event.optJSONObject("presentation")
        val type = event.optString("type")
        val renderable = RenderableEvent(
            eventId = eventId,
            type = type,
            title = presentation?.optString("title")?.takeIf { it.isNotEmpty() } ?: "PiPilot",
            body = presentation?.optString("body")?.takeIf { it.isNotEmpty() },
            collapseKey = event.optString("collapseKey").takeIf { it.isNotEmpty() },
            vibrate = vibrate,
        )
        val started = System.currentTimeMillis()
        if (type == "input_resolved") {
            // 等待输入已被处理:撤掉原来那条提醒,不新弹一条。
            notificationGate.resolve(scope, renderable)
            WatcherDiagnostics.log(
                "coordinator deliver(id=${eventId.take(8)} state=RESOLVED ms=${System.currentTimeMillis() - started})",
            )
            return
        }
        val state = notificationGate.deliver(scope, renderable)
        if (state == DeliveryState.BLOCKED) {
            ConnectionMetrics.record(appContext ?: return, "blocked_permission")
        }
        WatcherDiagnostics.log(
            "coordinator deliver(id=${eventId.take(8)} state=$state ms=${System.currentTimeMillis() - started})",
        )
        val t = target ?: return
        webSocket?.send(
            JSONObject()
                .put("type", "notification_receipt")
                .put("installationId", t.clientId)
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

    private fun ackCursor(webSocket: WebSocket) {
        val accumulator = prefix ?: return
        val bridgeId = bridgeInstallationId ?: return
        val epoch = eventEpoch ?: return
        val t = target ?: return
        val through = accumulator.current()
        if (through <= 0) return
        cursors?.advance(NotificationCursor(bridgeId, epoch, through))
        webSocket.send(
            JSONObject()
                .put("type", "notification_ack")
                .put("installationId", t.clientId)
                .put("eventEpoch", epoch)
                .put("through", through)
                .toString(),
        )
    }

    private fun setReadyLocked(value: Boolean) {
        val listener = readyListener
        if (listener != null) {
            handler.post { listener.invoke(value) }
        }
    }
}
