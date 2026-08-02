package com.pipilot.pi_pilot

/// 重连状态机,纯逻辑无 Android 依赖,可 JVM 单测。
///
/// 为什么把这块从 BridgeWatcher 的 handler.postDelayed 里抽出来:Advisor 要求的
/// 六类回归(失败后持续重试/onFailure+onClosed 只排一次/stop 取消/网络恢复重置
/// 退避/旧世代回调不覆盖新状态/空 Intent 重建)全都落在这台状态机上,
/// 它必须能在没有 Looper 的 JVM 里跑。
class ReconnectController(
    private val now: () -> Long = { System.currentTimeMillis() },
    private val baseDelayMs: Long = 1_000L,
    private val maxDelayMs: Long = 15_000L,
    private val maxShift: Int = 4,
) {
    enum class State { IDLE, RUNNING, PENDING, STOPPED }

    data class Schedule(val attempt: Int, val delayMs: Long, val generation: Long)

    var state: State = State.IDLE
        private set
    var attempt: Int = 0
        private set
    var generation: Long = 0L
        private set
    private var pending: Schedule? = null

    /// 开始一轮所有权。每次 start 都是新世代:旧 socket 的迟到回调拿着旧
    /// generation,会被 isCurrent 挡掉,不可能覆盖新状态。
    fun start(): Long {
        generation++
        attempt = 0
        pending = null
        state = State.RUNNING
        return generation
    }

    /// 连接失败/关闭后的唯一入口。onFailure 与 onClosed 可能成对到达,
    /// 只允许排一个 pending(第二次调用发现已有 pending 直接返回它)。
    fun onConnectionLost(gen: Long): Schedule? {
        if (gen != generation || state == State.STOPPED || state == State.IDLE) return null
        pending?.let { return it }
        attempt++
        val shift = minOf(attempt - 1, maxShift)
        val delay = minOf(baseDelayMs shl shift, maxDelayMs)
        val s = Schedule(attempt, delay, gen)
        pending = s
        state = State.PENDING
        return s
    }

    /// 定时器到点,准备真正发起重连。返回 null 表示这次点火已失效
    /// (stop 过/世代变了/不在 PENDING),调用方必须放弃。
    fun fire(gen: Long, fireAttempt: Int): Long? {
        val s = pending ?: return null
        if (gen != generation || state != State.PENDING) return null
        if (s.attempt != fireAttempt) return null
        pending = null
        state = State.RUNNING
        return generation
    }

    /// 重连成功:退避清零,回到 RUNNING,清掉可能残留的 pending。
    fun onConnected(gen: Long) {
        if (gen != generation || state == State.STOPPED || state == State.IDLE) return
        attempt = 0
        pending = null
        state = State.RUNNING
    }

    /// 系统通告网络恢复:退避清零并立即给一次点火机会。
    /// 这是「Wi-Fi 关掉再打开后不再傻等 15s」的修复点——旧 watcher 只有
    /// 退避定时器,永远不知道网络已经回来。
    fun onNetworkAvailable(gen: Long): Schedule? {
        if (gen != generation || state == State.STOPPED || state == State.IDLE) return null
        attempt = 0
        val s = Schedule(attempt = 0, delayMs = 0L, generation = gen)
        pending = s
        state = State.PENDING
        return s
    }

    /// 主动停止:一切后续回调失效。
    fun stop(gen: Long) {
        if (gen != generation) return
        pending = null
        state = State.STOPPED
    }

    fun pendingSchedule(): Schedule? = pending
}
