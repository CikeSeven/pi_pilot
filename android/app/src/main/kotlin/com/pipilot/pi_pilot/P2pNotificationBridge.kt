package com.pipilot.pi_pilot

import android.content.Context
import org.json.JSONObject

/// P2P 路径的通知协议引擎持有器(remote_hint_v1)。
///
/// P2P DataChannel 由 Dart 的 PiConnection/P2pConnector 持有,原生侧摸不到
/// socket。所以职责反过来:Dart 只做传输,把 bridge_hello 与 notification_*
/// 帧经 MethodChannel 喂进来,引擎处理后的出站帧(subscribe/next_page/ack/
/// receipt)由 Dart 经 PiConnection 发回 Bridge。cursor、去重、展示逻辑
/// 仍然在原生侧,一份都不复制到 Dart(advisor 的硬性要求)。
///
/// 与 LAN 路径共存的关系:同一 installationId 共享 NativeCursorStore 与
/// 去重表,两条路径天然互斥(transport 选择决定走哪条),过渡期的重复由
/// 去重表与稳定通知 ID 吸收(stable-plan §8.2 承认的竞态)。
object P2pNotificationBridge {
    private var engine: NotificationProtocolEngine? = null
    private var engineInstallationId: String? = null

    @Volatile
    var readyListener: ((Boolean) -> Unit)? = null

    /// 每帧都带 installationId/vibrate:进程被杀后 Dart 重连时不需要记得
    /// 先调一个 init,第一帧到达即重建引擎,语义比显式 init 更简单。
    @Synchronized
    private fun ensureEngine(
        context: Context,
        installationId: String,
        vibrate: Boolean,
    ): NotificationProtocolEngine {
        val existing = engine
        if (existing != null && engineInstallationId == installationId) {
            existing.vibrate = vibrate
            return existing
        }
        existing?.reset()
        val created = NotificationProtocolEngine(
            context = context,
            installationId = installationId,
            diagPrefix = "p2p",
        )
        created.vibrate = vibrate
        created.readyListener = { ready -> readyListener?.invoke(ready) }
        engine = created
        engineInstallationId = installationId
        return created
    }

    /// Dart 喂入一帧。返回值给 Dart 决定后续动作:outbound 逐帧经
    /// PiConnection 发出;helloOutcome 仅在 bridge_hello 帧时有值。
    @Synchronized
    fun onFrame(
        context: Context,
        installationId: String,
        vibrate: Boolean,
        frameJson: String,
    ): Map<String, Any?> {
        val frame = try {
            JSONObject(frameJson)
        } catch (_: Exception) {
            return mapOf("consumed" to false, "outbound" to emptyList<String>())
        }
        val engine = ensureEngine(context, installationId, vibrate)
        val helloOutcome = if (frame.optString("type") == "bridge_hello") {
            // P2P 路径不做身份持久化(那是 LAN 自愈的事),suffix 只用于订阅 id。
            engine.onHello(frame, "p2p-${System.currentTimeMillis()}").name
        } else {
            null
        }
        val consumed = helloOutcome != null || engine.onFrame(frame)
        return mapOf(
            "consumed" to consumed,
            "outbound" to engine.pollOutbound(),
            "ready" to engine.isReady,
            "notificationProtocol" to engine.notificationProtocol,
            "helloOutcome" to helloOutcome,
        )
    }

    /// Dart 连接断开:立刻撤 ready,让 Dart 恢复兜底。
    @Synchronized
    fun onTransportClosed() {
        engine?.onTransportClosed()
    }

    /// 完整复位(前台接管/用户关停)。
    @Synchronized
    fun reset() {
        engine?.cancelPostedNotifications()
        engine?.reset()
    }

    fun isReady(): Boolean = engine?.isReady ?: false

    fun debugStatus(): Map<String, Any?> = mapOf(
        "ready" to isReady(),
        "notificationProtocol" to (engine?.notificationProtocol ?: false),
        "bridgeInstallationId" to ((engine?.bridgeInstallationId)?.take(8) ?: ""),
        "eventEpoch" to ((engine?.eventEpoch)?.take(8) ?: ""),
        "cursorThrough" to (engine?.cursorThroughForDebug() ?: -1L),
    )
}
