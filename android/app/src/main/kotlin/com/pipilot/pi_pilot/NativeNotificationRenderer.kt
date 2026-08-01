package com.pipilot.pi_pilot

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/// 通知事件的最小渲染输入。
///
/// 刻意不直接吃 Bridge 的 NotificationEventV1 JSON:渲染层只需要这几个字段,
/// 把解析留在调用方,渲染器本身可以被 LAN、FCM、Dart 三条路径复用。
data class RenderableEvent(
    val eventId: String,
    /// task_completed / input_required / input_resolved
    val type: String,
    val title: String,
    val body: String?,
    /// 同一 collapseKey 的事件复用通知槽位。input_resolved 靠它更新
    /// 或取消原来那条「等待输入」,而不是新弹一条。
    val collapseKey: String?,
    val vibrate: Boolean,
)

/// 所有平台通知的唯一出口。
///
/// 为什么必须统一:当前实现里 Dart 侧从 100 起递增
/// (notification_controller.dart:155),原生 watcher 从 200 起递增
/// (BridgeWatcher.kt:41),两条路径没有共同 eventId,所以同一个任务完成
/// 可能同时弹两条。统一到 eventId + stableNotificationId 之后,
/// 重复投递必然落到同一槽位,系统行为是替换而非新增。
///
/// 见 stable-plan.md §9.1。
class NativeNotificationRenderer(private val context: Context) {
    companion object {
        private const val TAG = "PiPilotNotifyRender"
        const val QUIET_CHANNEL_ID = "agent_events_heads_up_quiet_v3"
        const val VIBRATE_CHANNEL_ID = "agent_events_heads_up_vibrate_v3"
    }

    private val manager: NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    /// 通知渠道是否可用。runtime permission 与渠道开关是两回事 ——
    /// 用户可以授予 POST_NOTIFICATIONS 但单独关掉某个渠道,
    /// 只查 permission 会把「渠道被关」误报成「已显示」。
    fun channelBlocked(vibrate: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        ensureChannels()
        val id = if (vibrate) VIBRATE_CHANNEL_ID else QUIET_CHANNEL_ID
        val channel = manager.getNotificationChannel(id) ?: return false
        return channel.importance == NotificationManager.IMPORTANCE_NONE
    }

    fun notificationsEnabled(): Boolean = manager.areNotificationsEnabled()

    /// 渲染一条通知。返回实际使用的通知 ID。
    ///
    /// 关键:setOnlyAlertOnce(true) + 稳定 ID。同一 eventId 第二次到达时
    /// 系统只静默更新内容,不再震动、不再弹横幅、不再响铃 ——
    /// 这是「允许重复投递但只打扰一次」的实现基础。
    fun display(event: RenderableEvent, notificationId: Int): Int {
        ensureChannels()
        val channelId = if (event.vibrate) VIBRATE_CHANNEL_ID else QUIET_CHANNEL_ID
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(event.title)
            .setContentText(event.body ?: "点击查看结果")
            .setContentIntent(openAppIntent(event))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setPriority(Notification.PRIORITY_MAX)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            // 重复投递静默更新的开关。没有它,第二次 notify 会再震一次。
            .setOnlyAlertOnce(true)
            .build()
        manager.notify(notificationId, notification)
        Log.i(TAG, "displayed ${shortId(event.eventId)} as id=$notificationId type=${event.type}")
        return notificationId
    }

    /// notify() 之后确认该 ID 真的出现在通知栏里。
    ///
    /// 这一步区分 display_requested 与 display_confirmed:notify() 不抛异常
    /// 不代表通知可见,系统限流、渠道设置都可能让它静默消失。
    /// API 23 以下拿不到 activeNotifications,只能乐观视为已确认。
    fun confirmVisible(notificationId: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            manager.activeNotifications.any { it.id == notificationId }
        } catch (_: Exception) {
            // 某些 OEM 在此抛 SecurityException;拿不到证据时不谎报确认。
            false
        }
    }

    fun cancel(notificationId: Int) {
        manager.cancel(notificationId)
    }

    private fun openAppIntent(event: RenderableEvent): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            // 深链只带定位信息,绝不带 token。
            putExtra("pipilot_event_id", event.eventId)
            putExtra("pipilot_event_type", event.type)
        }
        return PendingIntent.getActivity(
            context,
            // requestCode 用稳定 ID,让同一事件的 PendingIntent 可被复用/更新。
            StableNotificationId.forEvent(event.eventId),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /// 与 Dart 侧 NotificationService 使用同一组渠道 id 与配置。
    /// Android 渠道创建后不可修改,重复创建同名渠道无副作用。
    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(QUIET_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    QUIET_CHANNEL_ID,
                    "任务提醒（无震动）",
                    NotificationManager.IMPORTANCE_MAX,
                ).apply {
                    description = "pi 任务完成、扩展等待输入、连接中断等提醒"
                    enableVibration(false)
                    enableLights(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
        if (manager.getNotificationChannel(VIBRATE_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    VIBRATE_CHANNEL_ID,
                    "任务提醒（震动）",
                    NotificationManager.IMPORTANCE_MAX,
                ).apply {
                    description = "pi 任务完成、扩展等待输入、连接中断等提醒"
                    enableVibration(true)
                    enableLights(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
    }
}

/// 把「去重 + 渲染 + 状态回写」串成一个原子性尽力而为的流程。
///
/// 三步不可能真原子(见 DeliveryState 的注释),所以这里的契约是:
///  - claim 成功才渲染,避免并发重复。
///  - 渲染后立刻回写 DISPLAY_REQUESTED,崩在这之前的下次会重试。
///  - 确认可见后再回写 DISPLAY_CONFIRMED,只有它计入 SLO。
class NotificationGate(
    private val deduplicator: NotificationDeduplicator,
    private val renderer: NativeNotificationRenderer,
) {
    companion object {
        private const val TAG = "PiPilotNotifyGate"
    }

    /// 处理一条事件。返回最终状态,便于调用方上报 receipt 与指标。
    fun deliver(scope: String, event: RenderableEvent): DeliveryState {
        val notificationId = notificationIdFor(event)
        val claimed = deduplicator.claim(scope, event.eventId, notificationId)
        if (claimed == null) {
            Log.i(TAG, "suppressed duplicate ${shortId(event.eventId)}")
            return DeliveryState.SUPPRESSED_DUPLICATE
        }
        if (!renderer.notificationsEnabled() || renderer.channelBlocked(event.vibrate)) {
            // 被阻塞是终态:再重试也不会显示。但 cursor 仍可安全推进,
            // 因为「已安全处理」不等于「用户看见了」。
            deduplicator.markState(scope, event.eventId, DeliveryState.BLOCKED)
            Log.w(TAG, "blocked ${shortId(event.eventId)}: notifications unavailable")
            return DeliveryState.BLOCKED
        }
        renderer.display(event, notificationId)
        deduplicator.markState(scope, event.eventId, DeliveryState.DISPLAY_REQUESTED)
        val visible = renderer.confirmVisible(notificationId)
        val finalState =
            if (visible) DeliveryState.DISPLAY_CONFIRMED else DeliveryState.DISPLAY_REQUESTED
        deduplicator.markState(scope, event.eventId, finalState)
        return finalState
    }

    /// input_resolved 到达时取消原来那条「等待输入」。
    fun resolve(scope: String, event: RenderableEvent) {
        val original = event.collapseKey?.let { deduplicator.read(scope, it) }
        val targetId = original?.notificationId ?: notificationIdFor(event)
        renderer.cancel(targetId)
    }

    /// collapseKey 优先:同一请求的多次更新必须落到同一槽位。
    /// 没有 collapseKey 时退回 eventId,保证不同任务不会互相 collapse。
    private fun notificationIdFor(event: RenderableEvent): Int =
        StableNotificationId.forEvent(event.collapseKey ?: event.eventId)
}
