import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:pi_pilot/state/settings_provider.dart';
import 'package:pi_pilot/ui/settings/settings_screen.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点主题色点后状态变更且持久化', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late final ProviderContainer container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container = ProviderContainer(),
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const SettingsScreen(),
        ),
      ),
    );
    addTearDown(container.dispose);
    await tester.pump();

    expect(container.read(settingsProvider).accent, AppAccent.blue);

    // 设置从 2,100dp 的单页拆成了索引页 + 子页:先进「外观」
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();

    // 6 个色点中点第二个(purple);Tooltip message 即 label
    await tester.tap(find.byTooltip('紫色'));
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).accent, AppAccent.purple);
    expect((await SettingsRepository().load()).accent, 'purple');
  });
}
