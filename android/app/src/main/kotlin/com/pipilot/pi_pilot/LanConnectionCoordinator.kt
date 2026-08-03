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

    private var engine: NotificationProtocolEngine? = null

    private var webSocket: WebSocket? = null
    private var socketSeq: Long = 0L

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
        // Flutter 生命周期通常已经持久化后台窗口。进程被系统重建、没有
        // Dart 回调时这里只做幂等兜底；已有窗口绝不重置起点。
        NotificationBackgroundWindow.begin(context)
        start(context, stored, token)
        return true
    }

    fun stop(reason: String) {
        synchronized(this) {
            // 幂等守卫。Dart 侧一次前台/后台切换会连发多次 stopWatcher
            // (生命周期 inactive/paused/hidden 各一次,加 identity 监听器走 target=null
            // 分支),实测 100ms 内 3-6 次。无守卫时每次都重跑全流程并写日志,
            // 既污染诊断(真正的停止原因被淡化),也白做四项清理。
            // 与 BridgeWatcher.stop() 的守卫保持同一模式。
            val idle = reconnect.state == ReconnectController.State.STOPPED &&
                webSocket == null &&
                reconnect.pendingSchedule() == null
            if (idle) return
            val gen = reconnect.generation
            reconnect.stop(gen)
            states.transitionTo(gen, LanConnectionState.DISCONNECTED, reason)
            closeSocketLocked()
            engine?.reset()
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

    /// 诊断页用的状态快照。与 BridgeWatcher.debugStatus 保持同一套字段名,
    /// Dart 侧不需要关心当前是哪个 owner。token 绝不进入快照;
    /// 身份字段只截前 8 位。
    fun debugStatus(): Map<String, Any?> {
        val t = target
        val bridgeId = engine?.bridgeInstallationId
        val pending = reconnect.pendingSchedule()
        return mapOf(
            "state" to currentState().name,
            "ready" to isReady(),
            "notificationProtocol" to (engine?.notificationProtocol ?: false),
            "host" to (t?.host ?: ""),
            "port" to (t?.port ?: 0),
            "clientId" to (t?.clientId?.take(8) ?: ""),
            "bridgeInstallationId" to (bridgeId?.take(8) ?: ""),
            "eventEpoch" to ((engine?.eventEpoch)?.take(8) ?: ""),
            "reconnectAttempt" to reconnect.attempt,
            "reconnectPending" to (pending != null),
            "reconnectDelayMs" to (pending?.delayMs ?: 0L),
            "lastActiveAt" to lastActiveAt,
            "cursorThrough" to (engine?.cursorThroughForDebug() ?: -1L),
        )
    }

    /// 协议引擎装配:身份守卫以 NativeLanTarget 为准——认证身份与持久值不符
    /// 时引擎拒绝订阅且绝不改写 endpoint;首次连接学到身份才落盘。
    private fun ensureNotificationLayer(context: Context, clientId: String) {
        if (engine != null) {
            engine?.vibrate = vibrate
            return
        }
        val store = object : NotificationProtocolEngine.IdentityStore {
            override fun persistedBridgeId(): String? = target?.bridgeInstallationId

            override fun adopt(bridgeId: String) {
                val app = appContext ?: return
                val t = target ?: return
                val adopted = t.copy(bridgeInstallationId = bridgeId)
                if (NativeLanTarget.save(app, adopted, cipher)) {
                    target = adopted
                }
            }
        }
        engine = NotificationProtocolEngine(
            context = context,
            installationId = clientId,
            diagPrefix = "coordinator",
            identityStore = store,
        ).also { created ->
            created.vibrate = vibrate
            created.readyListener = { ready -> onEngineReady(ready) }
            created.cursorRebaseListener = { gap, oldest ->
                appContext?.let {
                    ConnectionMetrics.record(
                        it,
                        "cursor_recovery",
                        mapOf("rebaseGap" to gap, "oldest" to oldest),
                    )
                }
            }
        }
    }

    /// 引擎 ready 状态变化:ready=true 代表订阅追平,可以接管通知;
    /// ready=false 只通知 Dart 恢复兜底,状态机由 socket 路径自己管。
    private fun onEngineReady(ready: Boolean) {
        if (ready) {
            val gen = reconnect.generation
            reconnect.onConnected(gen)
            states.transitionTo(gen, LanConnectionState.READY, "ready")
            val latency = System.currentTimeMillis() - connectStartedAt
            appContext?.let { ConnectionMetrics.record(it, "ready", mapOf("latencyMs" to latency)) }
            WatcherDiagnostics.log("coordinator READY(gen=$gen latency=${latency}ms)")
            // 常驻通知必须跟真实连接走。coordinator 之前漏接,后台断连时
            // 通知栏还写着「已连接」。
            appContext?.let { KeepAliveService.updateConnection(it, true) }
        }
        readyListener?.invoke(ready)
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
                engine?.onTransportClosed()
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
        engine?.onTransportClosed()
        states.transitionTo(gen, LanConnectionState.DISCONNECTED, reason)
        // 如实下调常驻通知。FGS 通知带 setOnlyAlertOnce(true),只换文案不响铃,
        // 不会因为瀑布式重连而变成打扰。
        appContext?.let { KeepAliveService.updateConnection(it, false) }
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
    // 协议:全部交给 NotificationProtocolEngine,这里只剩传输接线
    // ------------------------------------------------------------------

    private fun handleFrame(gen: Long, socketId: Long, webSocket: WebSocket, text: String) {
        val frame = try {
            JSONObject(text)
        } catch (_: Exception) {
            return
        }
        if (frame.optString("type") == "bridge_hello") {
            handleHello(gen, socketId, webSocket, frame)
            return
        }
        val e = engine ?: return
        // response.data 首包解包在引擎内部;非通知帧 coordinator 没有业务,忽略。
        if (e.onFrame(frame)) {
            flushOutbound(webSocket)
        }
    }

    /// 引擎排队的出站帧(subscribe/next_page/ack/receipt)经当前 socket 发出。
    private fun flushOutbound(webSocket: WebSocket) {
        val e = engine ?: return
        for (payload in e.pollOutbound()) {
            webSocket.send(payload)
        }
    }

    private fun handleHello(gen: Long, socketId: Long, webSocket: WebSocket, frame: JSONObject) {
        val t = target ?: return
        val e = engine ?: return
        when (e.onHello(frame, "$gen-$socketId")) {
            NotificationProtocolEngine.HelloOutcome.SUBSCRIBED -> {
                reconnect.onConnected(gen)
                appContext?.let { ConnectionMetrics.record(it, "reconnect_ok") }
                states.transitionTo(gen, LanConnectionState.CATCHING_UP, "hello")
                flushOutbound(webSocket)
            }
            NotificationProtocolEngine.HelloOutcome.LEGACY -> {
                // coordinator 只接管新协议 Bridge。旧 Bridge 交还 watcher/Dart 路径。
                WatcherDiagnostics.log("coordinator: bridge lacks notification_events_v1, decline ownership")
                readyListener?.invoke(false)
            }
            NotificationProtocolEngine.HelloOutcome.IDENTITY_CONFLICT -> {
                // 身份守卫:认证身份与持久值不符,记冲突且绝不改写 endpoint。
                WatcherDiagnostics.log("coordinator identity_conflict closing(gen=$gen)")
                readyListener?.invoke(false)
                webSocket.close(4000, "identity conflict")
            }
        }
    }
}
