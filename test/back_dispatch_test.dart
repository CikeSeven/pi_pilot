import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/back_dispatch.dart';

/// 返回键优先级链:抽屉 > 切回对话页 > 灵动岛 > 模型选择器 > 退出。
void main() {
  test('啥都没开且在对话页:放行退出', () {
    expect(
      resolveBackTarget(
        drawerOpen: false,
        pageIndex: 0,
        islandExpanded: false,
        modelPickerExpanded: false,
      ),
      BackTarget.exit,
    );
  });

  test('抽屉开着:优先级最高,盖过切页与所有展开态', () {
    expect(
      resolveBackTarget(
        drawerOpen: true,
        pageIndex: 1,
        islandExpanded: true,
        modelPickerExpanded: true,
      ),
      BackTarget.drawer,
    );
  });

  test('设备/设置页:先切回对话页,不收看不见的展开态', () {
    expect(
      resolveBackTarget(
        drawerOpen: false,
        pageIndex: 2,
        islandExpanded: true,
        modelPickerExpanded: true,
      ),
      BackTarget.chatPage,
    );
  });

  test('对话页上:先收灵动岛,再收模型选择器', () {
    expect(
      resolveBackTarget(
        drawerOpen: false,
        pageIndex: 0,
        islandExpanded: true,
        modelPickerExpanded: true,
      ),
      BackTarget.island,
    );
    expect(
      resolveBackTarget(
        drawerOpen: false,
        pageIndex: 0,
        islandExpanded: false,
        modelPickerExpanded: true,
      ),
      BackTarget.modelPicker,
    );
  });
}
