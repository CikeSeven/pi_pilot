import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pi_session.dart';

/// 观察应用生命周期与网络接口变化:回前台、切网时立即重连(跳过退避)。
class AppLifecycleHandler extends ConsumerStatefulWidget {
  const AppLifecycleHandler({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLifecycleHandler> createState() =>
      _AppLifecycleHandlerState();
}

class _AppLifecycleHandlerState extends ConsumerState<AppLifecycleHandler>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// 上一次看到的接口集合。只有真的变了才通知 —— connectivity_plus 在部分
  /// 机型上会为同一状态重复发事件。
  List<ConnectivityResult>? _lastResults;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 切网(WiFi↔蜂窝)时 app 一直在前台,没有任何生命周期回调,而旧连接此时
    // 已经死了:ICE consent freshness 要 5~10s 才判 disconnected,健康心跳要
    // 30s+ 才判半开。期间用户看到的就是"卡住不动"。
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      final previous = _lastResults;
      _lastResults = results;
      // 首个事件是当前状态快照,不是"变化",不触发重连。
      if (previous == null) return;
      if (_sameInterfaces(previous, results)) return;
      // 完全离网时不必重连:等它回来再连,否则只是白烧退避计数。
      if (results.every((r) => r == ConnectivityResult.none)) {
        return;
      }
      ref
          .read(piSessionNotifierProvider)
          ?.onNetworkChanged(results.map((r) => r.name).join('+'));
    });
  }

  static bool _sameInterfaces(
    List<ConnectivityResult> a,
    List<ConnectivityResult> b,
  ) {
    if (a.length != b.length) return false;
    final left = a.map((r) => r.name).toList()..sort();
    final right = b.map((r) => r.name).toList()..sort();
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    unawaited(_connectivitySub?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 前台标志给问卷认领做门控:手机在口袋里时不能认领,否则电脑会白等
    // 几分钟才回落到插件自己的桌面问卷。
    final notifier = ref.read(piSessionNotifierProvider);
    notifier?.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      notifier?.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
