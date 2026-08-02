import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/island_bar.dart';

/// 「自动压缩时手机不显示压缩中」的回归测试。
///
/// 自动压缩不流式(isStreaming == false),而 working-activity 插件的
/// Working 文案可能还挂着旧值 —— 旧判定顺序先看 activityStatus、
/// 再看 isStreaming,「压缩中」被整个遮掉。
void main() {
  test('压缩中压过残留的 Working 文案与非流式状态', () {
    final state = PiState.initial().copyWith(
      isCompacting: true,
      isStreaming: false,
      activityStatus: 'Working · 总30s',
    );
    expect(islandWorkStatus(state), '压缩中');
  });

  test('压缩中也压过流式状态(自动压缩撞上一回合尾巴)', () {
    final state = PiState.initial().copyWith(
      isCompacting: true,
      isStreaming: true,
    );
    expect(islandWorkStatus(state), '压缩中');
  });

  test('无压缩时优先用插件推来的 Working 文案', () {
    final state = PiState.initial().copyWith(
      isStreaming: true,
      activityStatus: '思考中 · 总5s',
    );
    expect(islandWorkStatus(state), '思考中 · 总5s');
  });

  test('既没压缩又没在生成:不显示工作状态,回落到会话名', () {
    expect(islandWorkStatus(PiState.initial()), isNull);
  });

  test('生成中无插件状态:空列表显示生成中', () {
    final state = PiState.initial().copyWith(isStreaming: true);
    expect(islandWorkStatus(state), '生成中');
  });
}
