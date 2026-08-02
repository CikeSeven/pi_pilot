package com.pipilot.pi_pilot

import android.content.Context
import android.content.SharedPreferences

/// 结构化连接指标:计数器 + 原因码,持久化,可经诊断通道导出。
///
/// 为什么单独做一个而不是塞进 WatcherDiagnostics 的文本日志:决策点 A/B 要的是
/// 可聚合的数字(成功率、恢复耗时、断连原因分布),文本日志无法离线统计。
/// 计数器用 long 存 SharedPreferences,commit 写——指标丢一次无所谓,但进程死亡时
/// 丢一批会扭曲断连原因分布。
///
/// 原因码全集(新增时同步 stable-plan.md §19 开放项):
///   ready                 订阅达到 ready(带 latencyMs)
///   reconnect_scheduled   断连后调度重连(带 attempt/delayMs)
///   reconnect_ok          重连成功
///   cursor_recovery       cursor 追补完成(带 from/through/gap)
///   network_available     系统通告网络可用(触发全量 target 恢复)
///   network_lost          系统通告网络丢失
///   identity_conflict     认证后 bridgeInstallationId 与持久值不符
///   oem_freeze_suspected  回调线程恢复时发现时钟跳变(疑似 OEM 冻结)
///   half_open_killed      Bridge 判半开断开(由 watcher 侧 onFailure/onClosed 推断)
///   blocked_permission    通知权限被拒
///   blocked_local_network 本地网络权限/路由不可用(Android 16 LNP)
object ConnectionMetrics {
    private const val PREFS = "pipilot_connection_metrics_v1"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /// 记录一个带原因码的事件。details 只放短值(数字/短 hash),禁止正文/凭据。
    fun record(context: Context, reason: String, details: Map<String, Any?> = emptyMap()) {
        val p = prefs(context)
        val count = p.getLong("count:$reason", 0L) + 1
        val editor = p.edit()
            .putLong("count:$reason", count)
            .putLong("last:$reason", System.currentTimeMillis())
        for ((k, v) in details) {
            when (v) {
                is Long -> editor.putLong("detail:$reason:$k", v)
                is Int -> editor.putLong("detail:$reason:$k", v.toLong())
                is String -> editor.putString("detail:$reason:$k", v.take(64))
                is Boolean -> editor.putBoolean("detail:$reason:$k", v)
                else -> Unit
            }
        }
        editor.commit()
    }

    fun increment(context: Context, reason: String) = record(context, reason)

    /// 导出全部指标为可 JSON 化的 Map,供诊断通道读取后由 Dart 侧导出。
    fun dump(context: Context): Map<String, Any> {
        val out = mutableMapOf<String, Any>()
        for ((k, v) in prefs(context).all) {
            when (v) {
                is Long -> out[k] = v
                is Int -> out[k] = v.toLong()
                is Boolean -> out[k] = v
                is String -> out[k] = v
                else -> Unit
            }
        }
        return out
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().commit()
    }
}
