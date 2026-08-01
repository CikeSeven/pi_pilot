package com.pipilot.pi_pilot

/**
 * 后台通知 ready 仲裁器。
 *
 * watcher / coordinator / p2p 三个 owner 共享同一条 watcherReady 通道,
 * 但任意时刻可以有多个 owner 处于过渡态(LAN↔P2P 切换、stop 与引擎
 * ready 回调交错)。若各自直报,后到的 false 会踩掉另一 owner 刚建立
 * 的 true——实测表现:P2P 引擎已 ready,一次迟到的 stopWatcher 把
 * Dart 侧 ready 清掉,Dart 兜底与原生引擎同时弹通知(重复)。
 *
 * 仲裁规则:有效 ready = 任一 owner ready,只在有效值变化时上报。
 * owner 从未报告过等价于 false。
 */
object ReadyArbitrator {
    private val states = HashMap<String, Boolean>(3)

    @Volatile
    var listener: ((Boolean) -> Unit)? = null

    @Synchronized
    fun report(owner: String, ready: Boolean) {
        val prevEffective = states.values.any { it }
        if (ready) {
            states[owner] = true
        } else {
            states.remove(owner)
        }
        val effective = states.values.any { it }
        if (effective != prevEffective) {
            listener?.invoke(effective)
        }
    }

    /** 当前有效值,供 watcherReadyState 通道读。 */
    @Synchronized
    fun effective(): Boolean = states.values.any { it }

    @Synchronized
    fun reset() {
        states.clear()
    }
}
