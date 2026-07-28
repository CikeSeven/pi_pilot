import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知封装(Android channel `agent_events`)。
/// 注意:依赖存活的后台 isolate,Doze/进程被杀时收不到——
/// 前台服务保活是后续可选项。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _permissionGranted = false;

  static const _channel = AndroidNotificationDetails(
    'agent_events',
    '任务事件',
    channelDescription: 'pi 任务完成、扩展等待输入、连接中断等提醒',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    enableLights: true,
    showWhen: true,
    visibility: NotificationVisibility.public,
    channelShowBadge: true,
  );

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    _permissionGranted =
        await android?.requestNotificationsPermission() ?? false;
    debugPrint('[NotificationService] 初始化完成, 权限: $_permissionGranted');
  }

  Future<void> show({
    required int id,
    required String title,
    String? body,
  }) async {
    debugPrint('[NotificationService] show 被调用: id=$id, title=$title, body=$body');
    debugPrint('[NotificationService] _initialized=$_initialized, _permissionGranted=$_permissionGranted');
    if (!_initialized || !_permissionGranted) {
      debugPrint('[NotificationService] 跳过通知: 未初始化或无权限');
      return;
    }
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(android: _channel),
    );
    debugPrint('[NotificationService] 通知已发送');
  }

  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }
}
