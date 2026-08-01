import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知封装(Android channel `agent_events`)。
///
/// 三条渠道:
/// - `agent_events_heads_up_quiet_v3`:任务事件,最高优先级,有声音、无震动。
/// - `agent_events_heads_up_vibrate_v3`:任务事件,最高优先级,有声音、有震动。
/// - `agent_events_keepalive`:前台服务常驻通知,低优先级、无声、无横幅。
///
/// Android 渠道的优先级和震动配置创建后不可修改,因此震动开关通过选择两条
/// 独立渠道实现。`_v3` 也确保之前已经锁定的渠道不会吞掉新的横幅配置。
///
/// 自有前台服务维持进程优先级和常驻通知,但不假设 Dart isolate 在所有系统上
/// 都会持续调度。Dart 被暂停时,原生 `BridgeWatcher` 独立维护局域网观察连接、
/// 对账任务状态并刷新完成提醒;瞬时断线期间服务继续运行,只有显式断开才停止。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  Future<void>? _initializing;
  bool _initialized = false;
  bool _permissionGranted = false;

  static const String _quietTaskChannelId = 'agent_events_heads_up_quiet_v3';
  static const String _vibratingTaskChannelId =
      'agent_events_heads_up_vibrate_v3';
  static const String _keepaliveChannelId = 'agent_events_keepalive';
  static const MethodChannel _systemChannel = MethodChannel(
    'com.pipilot.pi_pilot/system',
  );

  /// 原生 watcher 是否真正接管了后台通知。
  ///
  /// 这个值只由原生的 `watcherReady` 回调驱动,绝不由 `startWatcher` 的返回值
  /// 推断:后者只表示「异步启动已提交」,不代表 socket 已连上、已鉴权、已追平
  /// 事件。据返回值抑制 Dart 兜底通知,会在原生实际没接管的窗口里丢通知。
  final ValueNotifier<bool> watcherReady = ValueNotifier<bool>(false);

  bool _readyHandlerInstalled = false;

  /// 安装原生 -> Dart 的状态回调。幂等,可重复调用。
  void _installReadyHandler() {
    if (_readyHandlerInstalled) return;
    _readyHandlerInstalled = true;
    _systemChannel.setMethodCallHandler((call) async {
      if (call.method == 'watcherReady') {
        final args = call.arguments;
        final ready = args is Map ? args['ready'] == true : args == true;
        watcherReady.value = ready;
        await logDiagnostic('native watcher ready=$ready');
      }
      return null;
    });
  }

  /// FGS 常驻通知的 id(在 KeepAliveService.kt 里固定为 1)。全扫取消任务
  /// 通知时必须跳过它,否则前台服务可能因通知被撤而被系统降级。
  static const int _keepAliveNotificationId = 1;

  static const _quietTaskChannelDefinition = AndroidNotificationChannel(
    _quietTaskChannelId,
    '任务提醒（无震动）',
    description: 'pi 任务完成、扩展等待输入、连接中断等提醒',
    importance: Importance.max,
    playSound: true,
    enableVibration: false,
    enableLights: true,
    showBadge: true,
  );

  static const _vibratingTaskChannelDefinition = AndroidNotificationChannel(
    _vibratingTaskChannelId,
    '任务提醒（震动）',
    description: 'pi 任务完成、扩展等待输入、连接中断等提醒',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    enableLights: true,
    showBadge: true,
  );

  static const _keepaliveChannelDefinition = AndroidNotificationChannel(
    _keepaliveChannelId,
    '连接保活',
    description: '后台保持与 bridge 的连接(前台服务)',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
    showBadge: false,
  );

  static const _quietTaskChannel = AndroidNotificationDetails(
    _quietTaskChannelId,
    '任务提醒（无震动）',
    channelDescription: 'pi 任务完成、扩展等待输入、连接中断等提醒',
    importance: Importance.max,
    priority: Priority.max,
    playSound: true,
    enableVibration: false,
    enableLights: true,
    showWhen: true,
    visibility: NotificationVisibility.public,
    channelShowBadge: true,
    category: AndroidNotificationCategory.message,
    ticker: 'PiPilot 任务提醒',
  );

  static const _vibratingTaskChannel = AndroidNotificationDetails(
    _vibratingTaskChannelId,
    '任务提醒（震动）',
    channelDescription: 'pi 任务完成、扩展等待输入、连接中断等提醒',
    importance: Importance.max,
    priority: Priority.max,
    playSound: true,
    enableVibration: true,
    enableLights: true,
    showWhen: true,
    visibility: NotificationVisibility.public,
    channelShowBadge: true,
    category: AndroidNotificationCategory.message,
    ticker: 'PiPilot 任务提醒',
  );

  Future<void> init() async {
    if (_initialized) return;
    final pending = _initializing;
    if (pending != null) {
      await pending;
      return;
    }

    final future = _initialize();
    _initializing = future;
    try {
      await future;
    } finally {
      if (identical(_initializing, future)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return;

      // 显式创建渠道,避免首次连接事件与插件初始化竞态时既没有服务,
      // 也没有任何可供系统侧诊断的渠道。
      await android.createNotificationChannel(_quietTaskChannelDefinition);
      await android.createNotificationChannel(_vibratingTaskChannelDefinition);
      await android.createNotificationChannel(_keepaliveChannelDefinition);
      _permissionGranted =
          await android.requestNotificationsPermission() ?? true;
      _initialized = true;
      await logDiagnostic(
        'notifications initialized: permission=$_permissionGranted',
      );
    } catch (error) {
      debugPrint('[NotificationService] 初始化失败: $error');
      await logDiagnostic('notifications init failed: $error');
    }
  }

  Future<void> logDiagnostic(String message) async {
    try {
      await _systemChannel.invokeMethod<void>('log', {'message': message});
    } on PlatformException {
      // MethodChannel 在 engine teardown 期间可能不可用,诊断日志不能影响功能。
    }
  }

  Future<void> show({
    required int id,
    required String title,
    required bool vibrate,
    String? body,
  }) async {
    await init();
    if (!_initialized || !_permissionGranted) {
      await logDiagnostic(
        'notification skipped: id=$id initialized=$_initialized '
        'permission=$_permissionGranted',
      );
      return;
    }
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: vibrate ? _vibratingTaskChannel : _quietTaskChannel,
        ),
      );
      await logDiagnostic('notification posted: id=$id vibrate=$vibrate');
    } catch (error) {
      await logDiagnostic('notification failed: id=$id error=$error');
    }
  }

  /// 必须在应用前台时首次启动;后续重复调用是幂等的。
  Future<void> startForeground() async {
    await init();
    if (!_initialized) return;
    try {
      await _systemChannel.invokeMethod<void>('startKeepAlive');
      await logDiagnostic('keepalive start requested');
    } on PlatformException catch (error) {
      await logDiagnostic('keepalive start failed: $error');
    }
  }

  /// 只有用户显式断开会话时调用。瞬时网络故障不能停止服务,否则后台重连
  /// 会因为进程重新降级而进入自锁。
  Future<void> stopForeground() async {
    try {
      await _systemChannel.invokeMethod<void>('stopKeepAlive');
      await logDiagnostic('keepalive stop requested');
    } on PlatformException catch (error) {
      await logDiagnostic('keepalive stop failed: $error');
    }
  }

  /// 切后台时把连接参数交给原生层。
  ///
  /// MIUI 会在切后台数十秒后回收前台服务的 wake lock,Dart isolate 随即停止
  /// 调度,无法回应 bridge 的 10s 协议 ping,socket 被 20s 超时掐断 ——
  /// `agent_end` 送不到,完成通知也就不会触发。进程本身没被冻结,所以后台的
  /// 观察连接与通知改由原生线程持有。返回是否成功接管。
  Future<bool> startWatcher({
    required String host,
    required int port,
    required String token,
    required String sourceId,
    required bool vibrate,
    required String clientId,
    required bool wasStreaming,
    String? sessionName,
  }) async {
    await init();
    if (!_initialized || !_permissionGranted) return false;
    _installReadyHandler();
    try {
      await _systemChannel.invokeMethod<void>('startWatcher', {
        'host': host,
        'port': port,
        'token': token,
        'sourceId': sourceId,
        'vibrate': vibrate,
        'clientId': clientId,
        'wasStreaming': wasStreaming,
        'sessionName': sessionName ?? '',
      });
      // 注意:true 只代表原生已受理,不代表已接管通知。
      // 真正的接管由 watcherReady 通知,调用方必须等它。
      await logDiagnostic('watcher start submitted: source=$sourceId');
      return true;
    } on PlatformException catch (error) {
      await logDiagnostic('watcher start failed: $error');
      return false;
    }
  }

  /// 回前台后交还给 Dart 连接,避免两条连接同时收事件重复通知。
  Future<void> stopWatcher() async {
    try {
      await _systemChannel.invokeMethod<void>('stopWatcher');
      // 原生停了就一定没在接管,立刻收回所有权,不等回调。
      watcherReady.value = false;
      await logDiagnostic('watcher stopped');
    } on PlatformException catch (error) {
      await logDiagnostic('watcher stop failed: $error');
    }
  }

  /// 更新 FGS 常驻通知的标题与会话计数。服务未运行时原生只记录、不刷新,
  /// 下次启动服务时会用上最新值。
  Future<void> updateKeepAliveStatus({
    required bool connected,
    required int sessions,
    required int working,
  }) async {
    try {
      await _systemChannel.invokeMethod<void>('updateKeepAlive', {
        'connected': connected,
        'sessions': sessions,
        'working': working,
      });
    } on PlatformException {
      // engine teardown 期间通道可能不可用,状态刷新不该影响功能。
    }
  }

  /// 回前台时清掉所有任务通知:Dart 的 100+、原生 watcher 的 200+,
  /// 以及进程被杀后残留在通知栏的孤儿通知。只保留 FGS 常驻通知 id=1。
  Future<void> cancelTaskNotifications() async {
    await init();
    if (!_initialized) return;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final active =
          await android?.getActiveNotifications() ??
          const <ActiveNotification>[];
      for (final notification in active) {
        final id = notification.id;
        if (id == null || id == _keepAliveNotificationId) continue;
        await _plugin.cancel(id: id);
      }
    } catch (error) {
      await logDiagnostic('cancel task notifications failed: $error');
    }
  }

  Future<void> cancelById(int id) async {
    await init();
    if (!_initialized) return;
    try {
      await _plugin.cancel(id: id);
      await logDiagnostic('notification canceled: id=$id');
    } catch (error) {
      await logDiagnostic('notification cancel failed: id=$id error=$error');
    }
  }

  /// 打开 Android/MIUI 的应用通知设置。顶部横幅属于系统的"悬浮通知"
  /// 权限,应用只能请求最高优先级,不能越权替用户开启。
  Future<void> openSystemNotificationSettings({required bool vibrate}) async {
    try {
      await _systemChannel.invokeMethod<void>('openNotificationSettings', {
        'channelId': vibrate ? _vibratingTaskChannelId : _quietTaskChannelId,
      });
    } on PlatformException catch (error) {
      debugPrint('[NotificationService] 打开系统通知设置失败: $error');
    }
  }
}
