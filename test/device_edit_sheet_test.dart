import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/device_models.dart';
import 'package:pi_pilot/ui/sessions/device_edit_sheet.dart';

/// 弹层保存/删除的结果,由 openSheet 里的闭包回填。
DeviceEditSheetResult? _result;

void main() {
  const existing = DeviceProfile(
    id: 'dev-1',
    name: '书房的电脑',
    host: '192.168.1.100',
    port: 9377,
    token: 'tok123',
    transport: DeviceTransport.auto,
    p2pRendezvous: 'https://signal.example.com',
    p2pDeviceId: 'desktop-1',
    p2pSecret: 'secret-abc',
  );

  /// 打开设备编辑弹层并返回结果 Future。
  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                _result = await showDeviceEditSheet(
                  context,
                  existing: existing,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('仅局域网保存保留已配好的 P2P 三要素', (tester) async {
    _result = null;
    await openSheet(tester);
    // 切到仅局域网:P2P 字段区整段收起,但已填的三要素必须保留——
    // 之前按策略存 null,切回自动后 P2P 信息全没了。
    await tester.tap(find.text('仅局域网直连'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final device = _result?.device;
    expect(device, isNotNull);
    expect(device!.transport, DeviceTransport.lan);
    expect(device.p2pRendezvous, 'https://signal.example.com');
    expect(device.p2pDeviceId, 'desktop-1');
    expect(device.p2pSecret, 'secret-abc');
  });

  testWidgets('清空设备名/密钥后保存,P2P 信息正常删除', (tester) async {
    _result = null;
    await openSheet(tester);
    // 显式清除路径不能被「填全就存」误伤:两栏清空 = 不要 P2P。
    await tester.enterText(find.widgetWithText(TextField, '设备名(信令服上)'), '');
    await tester.enterText(find.widgetWithText(TextField, '配对密钥'), '');
    // enterText 会让弹层内容滚动,保存键可能出可视区,先拉回来再点。
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final device = _result?.device;
    expect(device, isNotNull);
    expect(device!.p2pRendezvous, isNull);
    expect(device.p2pDeviceId, isNull);
    expect(device.p2pSecret, isNull);
  });

  testWidgets('P2P 三要素填一半,任何模式都拦下不保存', (tester) async {
    _result = null;
    await openSheet(tester);
    // 只清空密钥一栏(设备名还在)= 半成品,必须拦下而非静默丢弃。
    await tester.enterText(find.widgetWithText(TextField, '配对密钥'), '');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(_result, isNull); // 弹层没关,保存没发生
    expect(find.textContaining('三要素要填全'), findsOneWidget);
  });
}
