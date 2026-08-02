package com.pipilot.pi_pilot

import android.content.Context
import android.content.SharedPreferences

/// 功能开关。Phase 3 原生 LAN owner 在 flag 后开发:默认全关,只有显式打开
/// 才启用新路径,且任何时刻关闭都能无损退回 BridgeWatcher/Dart 旧路径
/// (cursor 与事件 ID 不重置)。
///
/// 为什么是 SharedPreferences 而不是 BuildConfig:验收需要在真机上不重新编译
/// 就切换路径做 A/B;release 构建同样允许切换,但入口只暴露给诊断页。
object FeatureFlags {
    const val NATIVE_LAN_OWNER = "native_lan_owner_v1"

    private const val PREFS = "pipilot_feature_flags_v1"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isEnabled(context: Context, flag: String): Boolean =
        prefs(context).getBoolean(flag, false)

    fun setEnabled(context: Context, flag: String, enabled: Boolean) {
        // commit 而非 apply:Phase 3 handoff 判定在读写之间不能出现半持久状态,
        // 宁可阻塞调用线程也不接受进程死亡时丢一次切换。
        prefs(context).edit().putBoolean(flag, enabled).commit()
    }

    fun all(context: Context): Map<String, Boolean> = mapOf(
        NATIVE_LAN_OWNER to isEnabled(context, NATIVE_LAN_OWNER),
    )
}
