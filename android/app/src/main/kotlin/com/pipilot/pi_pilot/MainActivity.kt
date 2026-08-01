package com.pipilot.pi_pilot

import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val systemChannel = "com.pipilot.pi_pilot/system"
    private val lanNetworkChannel = "com.pipilot.pi_pilot/lan_network"

    /// 持有 system channel,用于把原生 ready 状态主动推给 Dart。
    private var systemMethodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemChannel)
        systemMethodChannel = channel
        // 原生订阅 ready 变化时通知 Dart。
        //
        // 这是修掉「提交即成功」的关键:startWatcher 返回只代表异步启动已提交,
        // 不代表 socket 已连上、已鉴权、已追平事件。Dart 若据此立刻抑制自己的
        // 兜底通知,就会在原生实际没接管的窗口里丢通知。
        BridgeWatcher.setReadyListener { ready ->
            runOnUiThread {
                systemMethodChannel?.invokeMethod("watcherReady", mapOf("ready" to ready))
            }
        }
        // Phase 3:coordinator 走同一 ready 通道。任意时刻只有一个 owner 活跃,
        // 未启动的一方永远不报告,Dart 无需感知背后是 watcher 还是 coordinator。
        LanConnectionCoordinator.setReadyListener { ready ->
            runOnUiThread {
                systemMethodChannel?.invokeMethod("watcherReady", mapOf("ready" to ready))
            }
        }
        channel
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startKeepAlive" -> {
                        KeepAliveService.start(applicationContext)
                        result.success(null)
                    }
                    "stopKeepAlive" -> {
                        BridgeWatcher.stop()
                        KeepAliveService.stop(applicationContext)
                        result.success(null)
                    }
                    // Dart 在连接状态或会话计数变化时推送,常驻通知跟着刷新
                    "updateKeepAlive" -> {
                        KeepAliveService.updateStatus(
                            applicationContext,
                            call.argument<Boolean>("connected") ?: false,
                            call.argument<Int>("sessions") ?: -1,
                            call.argument<Int>("working") ?: 0,
                        )
                        result.success(null)
                    }
                    // 切后台时由 Dart 交出连接参数,之后连接由原生线程独立维护
                    "startWatcher" -> {
                        val host = call.argument<String>("host")
                        val port = call.argument<Int>("port")
                        val token = call.argument<String>("token")
                        val sourceId = call.argument<String>("sourceId")
                        val clientId = call.argument<String>("clientId")
                        val wasStreaming = call.argument<Boolean>("wasStreaming") ?: false
                        if (host.isNullOrEmpty() || port == null || token.isNullOrEmpty() ||
                            sourceId.isNullOrEmpty() || clientId.isNullOrEmpty()
                        ) {
                            result.error("invalid_args", "watcher config incomplete", null)
                        } else {
                            val vibrate = call.argument<Boolean>("vibrate") ?: false
                            // 无论哪个 owner 活跃都先持久化目标:flag 切换或服务重建
                            // 时 coordinator 才能凭 noBackup 里的数据独立接管。
                            val cipher = KeystoreTokenCipher()
                            val previous = NativeLanTarget.load(applicationContext)
                            val target = NativeLanTarget(
                                deviceId = previous?.deviceId ?: host,
                                host = host,
                                port = port,
                                wrappedToken = cipher.wrap(token),
                                clientId = clientId,
                                bridgeInstallationId = previous?.bridgeInstallationId,
                                savedAtMillis = System.currentTimeMillis(),
                            )
                            NativeLanTarget.save(applicationContext, target, cipher)
                            if (FeatureFlags.isEnabled(applicationContext, FeatureFlags.NATIVE_LAN_OWNER)) {
                                LanConnectionCoordinator.start(
                                    context = applicationContext,
                                    target = target,
                                    token = token,
                                    vibrate = vibrate,
                                )
                                result.success(mapOf("submitted" to true, "ready" to LanConnectionCoordinator.isReady()))
                            } else {
                                BridgeWatcher.start(
                                    context = applicationContext,
                                    host = host,
                                    port = port,
                                    token = token,
                                    sourceId = sourceId,
                                    vibrate = vibrate,
                                    clientId = clientId,
                                    wasStreaming = wasStreaming,
                                    sessionName = call.argument<String>("sessionName").orEmpty(),
                                )
                                // 返回值只表示「已提交」,真正的接管由 watcherReady 回调宣布。
                                result.success(mapOf("submitted" to true, "ready" to BridgeWatcher.isSubscriptionReady()))
                            }
                        }
                    }
                    "stopWatcher" -> {
                        BridgeWatcher.stop()
                        LanConnectionCoordinator.stop("stopWatcher")
                        result.success(null)
                    }
                    "watcherReadyState" -> {
                        val ready = if (FeatureFlags.isEnabled(applicationContext, FeatureFlags.NATIVE_LAN_OWNER)) {
                            LanConnectionCoordinator.isReady()
                        } else {
                            BridgeWatcher.isSubscriptionReady()
                        }
                        result.success(ready)
                    }
                    "setFeatureFlag" -> {
                        val flag = call.argument<String>("flag")
                        val enabled = call.argument<Boolean>("enabled")
                        if (flag.isNullOrEmpty() || enabled == null) {
                            result.error("invalid_args", "flag and enabled required", null)
                        } else {
                            FeatureFlags.setEnabled(applicationContext, flag, enabled)
                            // 切换立即生效:停掉当前 owner,ready=false 会让 Dart 恢复
                            // 兜底通知;下一次 startWatcher(后台切换)启动新路径。
                            if (flag == FeatureFlags.NATIVE_LAN_OWNER) {
                                BridgeWatcher.stop()
                                LanConnectionCoordinator.stop("flag_toggle:$enabled")
                            }
                            result.success(true)
                        }
                    }
                    "connectionMetrics" -> {
                        result.success(ConnectionMetrics.dump(applicationContext))
                    }
                    "clearConnectionMetrics" -> {
                        ConnectionMetrics.clear(applicationContext)
                        result.success(null)
                    }
                    "log" -> {
                        Log.i("PiPilotDart", call.argument<String>("message").orEmpty())
                        result.success(null)
                    }
                    // 后台稳定性取证用:这台验收机的 logcat 对应用自身标签不可靠
                    // (实测全量日志里应用行数为 0),诊断只能落到应用私有文件再读回。
                    "watcherDiagnostics" -> {
                        WatcherDiagnostics.init(applicationContext)
                        result.success(WatcherDiagnostics.dump())
                    }
                    "clearWatcherDiagnostics" -> {
                        WatcherDiagnostics.init(applicationContext)
                        WatcherDiagnostics.clear()
                        result.success(null)
                    }
                    "openNotificationSettings" -> {
                        openNotificationSettings(call.argument<String>("channelId"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, lanNetworkChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindWifiForLan" -> {
                        try {
                            result.success(bindWifiForLan(call.argument<String>("host")))
                        } catch (error: Exception) {
                            result.error("wifi_bind_failed", error.message, null)
                        }
                    }
                    "unbindNetwork" -> {
                        try {
                            result.success(unbindNetwork())
                        } catch (error: Exception) {
                            result.error("network_unbind_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 按目标地址选择要绑定的 Wi-Fi 网络。
    ///
    /// 旧实现取 allNetworks 里「第一张有 IPv4 的 Wi-Fi」,完全不看能否路由到
    /// 目标。实测在双 Wi-Fi 手机上直接失效:wlan0=192.168.1.9/24 与
    /// wlan2=10.183.39.216/24 同时在线时,firstOrNull 可能选中 wlan0,而
    /// bindProcessToNetwork 是进程级的,于是整个 App 的新 socket 都被钉在
    /// 到不了 Bridge 的网卡上 —— connect() 直接 ENETUNREACH,内核连 SYN 都
    /// 不发,Bridge 侧零连接记录,而未绑定的 curl 走系统默认策略却是通的。
    ///
    /// 现在要求候选网络的 LinkProperties 能真正涵盖目标地址:优先同子网直连
    /// (按前缀匹配),其次接受带默认路由的网络。拿不到 host 时退回旧的宽松
    /// 选择,以免让不传参的调用方彻底失去绑定能力。
    private fun bindWifiForLan(host: String?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val connectivity = getSystemService(ConnectivityManager::class.java)
            ?: return false

        val target = resolveTargetAddress(host)
        val candidates = connectivity.allNetworks.filter { network ->
            val capabilities = connectivity.getNetworkCapabilities(network)
            val linkAddresses = connectivity.getLinkProperties(network)?.linkAddresses
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                linkAddresses?.any { it.address is java.net.Inet4Address } == true
        }
        if (candidates.isEmpty()) return false

        val chosen = if (target == null) {
            candidates.first()
        } else {
            // 同子网直连优先:目标在某张网卡的 LinkAddress 前缀内。
            candidates.firstOrNull { network ->
                connectivity.getLinkProperties(network)?.linkAddresses?.any { link ->
                    val local = link.address
                    local is java.net.Inet4Address &&
                        sameIpv4Subnet(local, target, link.prefixLength)
                } == true
            }
                // 其次:该网络自己声明了能到目标的路由。
                ?: candidates.firstOrNull { network ->
                    connectivity.getLinkProperties(network)?.routes?.any { route ->
                        runCatching { route.matches(target) }.getOrDefault(false)
                    } == true
                }
                // 都不匹配时不要乱绑:错绑等于把 App 钉在死路上,
                // 不绑定至少能让系统按默认策略选路。
                ?: return false
        }
        return connectivity.bindProcessToNetwork(chosen)
    }

    private fun resolveTargetAddress(host: String?): java.net.InetAddress? {
        val trimmed = host?.trim()?.trim('[', ']')
        if (trimmed.isNullOrEmpty()) return null
        // 只接受字面量地址:这一步在建链前跑,不能在主线程做 DNS 解析。
        return runCatching {
            if (trimmed.any { it != '.' && it != ':' && !it.isDigit() && it.lowercaseChar() !in 'a'..'f' }) {
                null
            } else {
                java.net.InetAddress.getByName(trimmed)
            }
        }.getOrNull()
    }

    private fun sameIpv4Subnet(
        local: java.net.Inet4Address,
        target: java.net.InetAddress,
        prefixLength: Int,
    ): Boolean {
        if (target !is java.net.Inet4Address) return false
        if (prefixLength <= 0 || prefixLength > 32) return false
        val a = local.address
        val b = target.address
        if (a.size != 4 || b.size != 4) return false
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

    private fun unbindNetwork(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val connectivity = getSystemService(ConnectivityManager::class.java)
            ?: return false
        return connectivity.bindProcessToNetwork(null)
    }

    private fun openNotificationSettings(channelId: String?) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && channelId != null) {
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
            }
        } else {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            }
        }

        try {
            startActivity(intent)
        } catch (_: Exception) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                ),
            )
        }
    }
}
