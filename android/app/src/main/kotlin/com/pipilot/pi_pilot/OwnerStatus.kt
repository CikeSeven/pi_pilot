package com.pipilot.pi_pilot

import android.content.Context

/// 诊断页的原生状态聚合。
///
/// 为什么单独抽一个 object:诊断页要的字段横跨四个组件(两个 owner、
/// KeepAliveService、FeatureFlags),MainActivity 不该逐个拼;而且 Dart 侧
/// 只需要一个 method 调用,减少 MethodChannel 往返。
///
/// 快照里**永远没有 token**:wrappedToken 是 Keystore 密文也不进快照,
/// 诊断导出可能被粘贴到 issue 里,凭据一概不出现。身份字段只截前 8 位,
/// 与 WatcherDiagnostics 里的日志口径一致,两边能对上。
object OwnerStatus {

    fun dump(context: Context): Map<String, Any?> {
        val app = context.applicationContext
        val nativeOwner = FeatureFlags.isEnabled(app, FeatureFlags.NATIVE_LAN_OWNER)
        val watcher = BridgeWatcher.debugStatus()
        val coordinator = LanConnectionCoordinator.debugStatus()

        // 当前生效的 owner 由 flag 决定;两个 owner 同时上报状态,
        // 方便诊断「flag 切换后旧 owner 是否真的停了」。
        val active = if (nativeOwner) coordinator else watcher

        return mapOf(
            "activeOwner" to if (nativeOwner) "coordinator" else "watcher",
            "nativeLanOwnerFlag" to nativeOwner,
            "ready" to (active["ready"] == true),
            "watcher" to watcher,
            "coordinator" to coordinator,
            "keepAlive" to mapOf(
                "backgroundMode" to KeepAliveService.backgroundMode().name,
                "hubConnected" to KeepAliveService.isHubConnected(),
                "quotaExhaustedAt" to KeepAliveService.quotaExhaustedAtMillis(),
            ),
        )
    }
}
