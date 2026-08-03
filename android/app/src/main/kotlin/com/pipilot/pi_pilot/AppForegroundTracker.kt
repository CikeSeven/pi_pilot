package com.pipilot.pi_pilot

/// App 进程级的前台标志。
///
/// 用途只有一个:用户正在 App 里看着当前会话时,任务完成的系统通知
/// 纯属打扰(结果就在屏幕上),NotificationGate 据此抑制 task_completed。
///
/// 为什么不用 Dart 上报:引擎/watcher/FCM 三条投递路径都可能绕过 Dart
/// 直接渲染(Dart 退到后台或引擎已接管),只有进程内标志覆盖得了全部路径。
/// 为什么默认 false:进程被 FGS 拉起而 UI 未启动时必须按后台处理,
/// 否则后台完成通知会被整个吞掉。
object AppForegroundTracker {
    @Volatile
    var resumed: Boolean = false
}
