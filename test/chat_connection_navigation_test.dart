import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/chat_body.dart';
import 'package:pi_pilot/ui/sessions/devices_page.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('未连接空态把连接管理导向设备页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: buildLightTheme(), home: const ChatBody()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('前往设置'), findsNothing);
    expect(find.text('管理设备'), findsOneWidget);

    await tester.tap(find.text('管理设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(DevicesPage), findsOneWidget);
  });
}
