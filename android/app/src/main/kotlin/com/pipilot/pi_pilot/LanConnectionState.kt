package com.pipilot.pi_pilot

/// LAN 连接状态。与 BridgeWatcher 内部的 ready 布尔不同,这里把完整生命周期
/// 显式建模——诊断页与 handoff 仲裁都需要区分「在连」「在追补」「真 ready」。
enum class LanConnectionState {
    /// 无连接,也没有正在进行的尝试。
    DISCONNECTED,

    /// TCP/WebSocket 建立中。
    CONNECTING,

    /// socket 已开,等待 bridge_hello 完成认证与能力协商。
    AUTHENTICATING,

    /// 已认证,正在 cursor 追补到固定 tip(此阶段不声称 ready)。
    CATCHING_UP,

    /// 订阅 ready:可以接管通知所有权,允许抑制 Dart 兜底。
    READY,

    /// 网络丢失或服务降额,等待恢复;事件仍由 Bridge 持久层兜底。
    DEGRADED,

    /// Android 16+ 本地网络保护/路由不可用,需用户或系统解除。
    BLOCKED_LOCAL_NETWORK,
}

/// 带世代的连接状态持有者。旧 socket 的迟到回调携带旧 generation,
/// transitionTo 直接拒绝——这是「断连回调不覆盖新连接状态」的硬保证。
class LanConnectionStateHolder {
    @Volatile
    var state: LanConnectionState = LanConnectionState.DISCONNECTED
        private set

    @Volatile
    var generation: Long = 0L
        private set

    @Volatile
    var stateSinceMillis: Long = 0L
        private set

    @Volatile
    var lastReason: String? = null
        private set

    @Synchronized
    fun beginGeneration(): Long {
        generation++
        transitionLocked(LanConnectionState.DISCONNECTED, "begin")
        return generation
    }

    @Synchronized
    fun transitionTo(
        gen: Long,
        next: LanConnectionState,
        reason: String? = null,
    ): Boolean {
        if (gen != generation) return false
        transitionLocked(next, reason)
        return true
    }

    private fun transitionLocked(next: LanConnectionState, reason: String?) {
        state = next
        lastReason = reason
        stateSinceMillis = System.currentTimeMillis()
    }

    fun isReady(): Boolean = state == LanConnectionState.READY
}
