import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/device_models.dart';
import '../core/pi_connection.dart';
import '../core/hub_channel.dart';
import '../core/lan_network_binding.dart';
import '../core/p2p_connector.dart';
import '../core/sync_store.dart';
import 'hub_models.dart';
import 'settings_provider.dart';
import 'source_cursor.dart';
import 'stream_derivation.dart';

export '../core/pi_connection.dart' show PiConnStatus;
export 'hub_models.dart';
// 当前设备代理:让旧调用点(import 本文件)继续用 piSessionProvider 这个名字,
// 语义从「唯一连接」变为「激活设备的连接」。
export 'device_manager.dart' show piSessionProvider, piSessionNotifierProvider;

// ---------------------------------------------------------------------------
// Chat items (mutable: the notifier mutates fields then bumps `revision`)
// ---------------------------------------------------------------------------

sealed class ChatItem {
  ChatItem(this.key);
  final String key;
}

class UserItem extends ChatItem {
  UserItem(super.key, {required this.text, required this.time});
  final String text;
  final DateTime time;

  /// pi entry id (needed by the fork command); filled when known.
  String? entryId;
}

class AssistantItem extends ChatItem {
  AssistantItem(super.key);
  String text = '';
  String thinking = '';
  bool complete = false;
  DateTime? time;

  /// 思考开始时刻(流式中第一次见 thinking 非空时记)。
  DateTime? thinkingStart;

  /// 思考累计时长。每次 thinking 更新顺手算一次,thinking 停止增长后
  /// 自然停在最终值 —— 不用找「思考结束」的精确时机。
  /// 历史回放由 relay 的 thinkingDurationMs 精确补上(见 _ingestMessage)。
  Duration thinkingDuration = Duration.zero;

  /// 上次见到的 thinking 长度:只在**增长**时推进 thinkingDuration,
  /// 正文流式不会把时长越拖越长。
  int thinkingLenSeen = 0;

  /// pi 的 message.stopReason:stop/length/toolUse/error/aborted。
  /// null 表示未知(历史回放可能缺失)。仅 error/aborted 需要向用户标记。
  String? stopReason;
  bool get isErrored => stopReason == 'error' || stopReason == 'aborted';
}

class ToolItem extends ChatItem {
  ToolItem(super.key, {required this.toolCallId, required this.name});
  final String toolCallId;
  final String name;
  String argsSummary = '';

  /// 原始工具参数(用于 diff/read 等结构化渲染);历史 toolResult 可能缺失。
  Map<String, dynamic>? args;
  String output = '';
  bool done = false;
  bool isError = false;
}

class BashItem extends ChatItem {
  BashItem(super.key, {this.command = ''});

  /// **不能是 final**:实时的 `bash_execution_update` 事件只带 `{id, delta}`,
  /// 根本没有命令字段(见 pi 的 rpc.md)。命令要等对应的 `bashExecution`
  /// 条目落盘后才补得上,以前 final 让它永远停在空串。
  String command;
  String output = '';
  bool done = false;
  int? exitCode;
  bool get isError => (exitCode ?? 0) != 0;
}

enum SystemKind { info, warning, error }

class SystemItem extends ChatItem {
  SystemItem(super.key, {required this.text, this.kind = SystemKind.info});
  final String text;
  final SystemKind kind;
}

/// 扩展注入的自定义消息(todo 列表等);details 保留原始数据,
/// 渲染层可按 customType 分发专用渲染器。
class CustomItem extends ChatItem {
  CustomItem(
    super.key, {
    required this.customType,
    required this.text,
    this.details,
  });
  final String customType;
  String text;
  Map<String, dynamic>? details;
}

/// 压缩/分支摘要。
class SummaryItem extends ChatItem {
  SummaryItem(super.key, {required this.kind, required this.summary});

  /// 'compaction' | 'branch'
  final String kind;
  final String summary;
}

// ---------------------------------------------------------------------------
// Session browsing (bridge-local commands)
// ---------------------------------------------------------------------------

class DirEntry {
  const DirEntry({
    required this.cwd,
    required this.sessionCount,
    this.lastActive,
  });
  final String cwd;
  final int sessionCount;
  final DateTime? lastActive;

  String get label {
    final parts = cwd.split('/').where((p) => p.isNotEmpty);
    return parts.isEmpty ? cwd : parts.last;
  }
}

class SessionEntry {
  const SessionEntry({
    required this.path,
    required this.id,
    this.name,
    required this.timestamp,
    required this.sizeBytes,
  });
  final String path;
  final String id;
  final String? name;
  final DateTime timestamp;
  final int sizeBytes;
}

class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.name,
    required this.provider,
    this.contextWindow,
  });
  final String id;
  final String name;
  final String provider;
  final int? contextWindow;
  String get key => '$provider:$id';
}

class SessionStats {
  const SessionStats({
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.costTotal,
    this.contextTokens,
    this.contextWindow,
    this.contextPercent,
  });
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final double? costTotal;
  final int? contextTokens;
  final int? contextWindow;
  final int? contextPercent;
}

/// 当前会话上下文占用。
class ContextUsage {
  const ContextUsage({this.tokens, this.contextWindow, this.percent});
  final int? tokens;
  final int? contextWindow;
  final int? percent;

  static ContextUsage? fromMap(Object? value) {
    if (value is! Map) return null;
    return ContextUsage(
      tokens: value['tokens'] as int?,
      contextWindow: value['contextWindow'] as int?,
      percent: (value['percent'] as num?)?.round(),
    );
  }
}

/// 可通过 prompt 调用的斜杠命令。
class SlashCommand {
  const SlashCommand({required this.name, this.description, this.source = ''});
  final String name;
  final String? description;

  /// 'extension' | 'prompt' | 'skill' | 'builtin'
  ///
  /// builtin 是 relay 补进来的 pi 内置命令(目前只有 compact)。这类命令
  /// **不能当文本发给模型** —— pi 的 session.prompt() 只解析扩展注册的命令,
  /// 内置命令发过去就是一句字面文本。
  final String source;

  bool get isBuiltin => source == 'builtin';
}

/// 输入文本里识别出的内置命令。
class BuiltinInvocation {
  const BuiltinInvocation({required this.name, this.argument});
  final String name;

  /// 命令名之后的余下部分(compact 拿它当自定义压缩要求)。
  final String? argument;
}

/// 会话内 entry 树节点(归一化后的 get_tree / treeSummary)。
class SessionTreeNode {
  const SessionTreeNode({
    required this.id,
    this.parentId,
    required this.type,
    this.time,
    this.preview = '',
    this.label,
    this.role,
    this.toolName,
    this.tools = const [],
    this.isError = false,
    this.collapsedBefore = 0,
    this.children = const [],
  });

  final String id;
  final String? parentId;
  final String type;
  final DateTime? time;
  final String preview;
  final String? label;

  /// message 节点的角色(user/assistant/toolResult)。
  final String? role;

  /// toolResult 节点对应的工具名。toolResult 没有文本预览,
  /// 工具名是区分它们的唯一信息。
  final String? toolName;

  /// assistant 节点这一回合调用的工具名。
  ///
  /// 只有 thinking + toolCall 的回合没有任何文本,预览是空的 ——
  /// 而「这一步调了 bash」恰恰是人回退时要找的锚点。
  final List<String> tools;

  /// 工具报错。
  final bool isError;

  /// 本节点与上一个保留节点之间被折叠掉的节点数。
  ///
  /// 桌面端的 treeSummary 有字节预算。目标是每条消息都能回退,所以剪枝是
  /// 最后才用的手段;真被剪时也不插占位节点(占位没有真实 entry id,
  /// 点下去会回退到错的地方),只把数量记在这里,由界面提示「省略 N 条」。
  final int collapsedBefore;
  final List<SessionTreeNode> children;

  /// 能否作为回退目标。
  ///
  /// 注意与入表类型(_navigableTreeTypes)刻意不同:compaction 会显示在
  /// 树里当锚点,但不是可落脚的回合边界(落到压缩点上,之前的明细在
  /// 当前分支里就只剩摘要了),所以它不可点。
  bool get canNavigate => type == 'message' || type == 'branch_summary';
}

class SessionTree {
  const SessionTree({required this.roots, this.leafId, this.isSummary = false});

  final List<SessionTreeNode> roots;
  final String? leafId;

  /// desktop 压缩形态(无完整消息内容)。
  final bool isSummary;

  /// 从根到当前 leaf 的路径上的节点 id 集合。
  ///
  /// **迭代而非递归**:会话树是一条长单链(没有分叉时深度 == 消息数),
  /// 千条会话按 children 递归会爆栈。先找到目标,再沿父指针回溯。
  Set<String> get currentPath {
    final target = leafId;
    if (target == null) return const {};
    final parentOf = <SessionTreeNode, SessionTreeNode?>{};
    final stack = <SessionTreeNode>[];
    for (final root in roots.reversed) {
      parentOf[root] = null;
      stack.add(root);
    }
    SessionTreeNode? found;
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node.id == target) {
        found = node;
        break;
      }
      for (final child in node.children.reversed) {
        parentOf[child] = node;
        stack.add(child);
      }
    }
    if (found == null) return const {};
    final path = <String>{};
    SessionTreeNode? cursor = found;
    while (cursor != null) {
      path.add(cursor.id);
      cursor = parentOf[cursor];
    }
    return path;
  }

  /// 有多个子分支的节点(fork 点)。
  List<SessionTreeNode> get forkPoints {
    final result = <SessionTreeNode>[];
    final stack = <SessionTreeNode>[];
    for (final root in roots.reversed) {
      stack.add(root);
    }
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node.children.length > 1) result.add(node);
      for (final child in node.children.reversed) {
        stack.add(child);
      }
    }
    return result;
  }
}

/// pi 扩展发起的等待用户输入的对话框请求。
class UiRequest {
  const UiRequest({
    required this.id,
    required this.method,
    required this.title,
    this.options = const [],
    this.message,
    this.placeholder,
    this.prefill,
    this.timeoutMs,
  });

  final String id;

  /// 'select' | 'confirm' | 'input' | 'editor'
  final String method;
  final String title;
  final List<String> options;
  final String? message;
  final String? placeholder;
  final String? prefill;
  final int? timeoutMs;
}

/// 问卷里的一个选项。
///
/// `preview` 的**内容**不过网:那是电脑上并排对比用的大段 markdown,
/// 手机上只标一下「含预览」。
class AskOption {
  const AskOption({
    required this.label,
    this.description,
    this.hasPreview = false,
  });

  final String label;
  final String? description;
  final bool hasPreview;
}

/// 问卷里的一道题。
class AskQuestion {
  const AskQuestion({
    required this.question,
    this.header,
    this.multiSelect = false,
    this.options = const [],
  });

  final String question;
  final String? header;
  final bool multiSelect;
  final List<AskOption> options;
}

/// 电脑端转过来的一份 `ask_user_question` 问卷,等着手机作答。
///
/// 插件 `@juicesharp/rpiv-ask-user-question` 把问卷画在电脑端 TUI 的覆盖层里
/// (`ctx.ui.custom()`),不走 pi 的 extension_ui_request 协议,也没有任何可编程
/// 应答入口。所以 relay 改用 `tool_call` 钩子在插件的 execute 之前把整次调用
/// 截下来,把题目经 hub 转到这里;手机答完再送回去,插件那套 TUI 从不出现。
class AskRequest {
  const AskRequest({
    required this.requestId,
    required this.toolCallId,
    required this.questions,
  });

  final String requestId;

  /// 对应的工具调用 id —— 问卷卡片要靠它认出自己该变成可作答的那张。
  final String toolCallId;
  final List<AskQuestion> questions;
}

/// 用户消息的投递语义。
enum PiDelivery {
  /// 插队:当前这一轮结束后立刻处理。**不是中断**,文案不要写成"打断"。
  steer,

  /// 排队:等全部处理完再处理。
  followUp,

  /// 中断当前生成再发送。
  ///
  /// 副作用要如实告知:桌面端 pi 的 abort 会把未发送的排队消息回填到
  /// 电脑端的输入框里。
  interrupt,
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// 业务就绪阶段:与传输状态(PiConnStatus)分离。
/// "传输在线"不等于"会话可用" —— 旧实现把两者混成一个 connected,
/// 才会出现"心跳正常但列表永远空白"的假象。
enum SyncPhase {
  offline,
  connecting,
  authenticated,
  catalogReady,
  selected,
  syncing,
  synced,
  degraded,
}

/// 当前实际承载协议流量的通道。与用户配置的 [DeviceTransport] 不同:
/// auto 会在两种通道之间自动迁移,UI 和重连策略都看这个运行时结果。
enum PiActiveTransport {
  lan('局域网直连'),
  p2p('P2P');

  const PiActiveTransport(this.label);
  final String label;
}

class PiState {
  const PiState({
    required this.status,
    this.activeTransport,
    this.sessionPhase = SyncPhase.offline,
    required this.items,
    required this.revision,
    required this.isStreaming,
    required this.isCompacting,
    required this.steeringQueue,
    required this.followUpQueue,
    required this.hasSession,
    required this.autoCompactionEnabled,
    required this.sources,
    required this.sessions,
    required this.isDriving,
    required this.lastSourceSeq,
    this.error,
    this.sessionId,
    this.cwd,
    this.modelId,
    this.modelName,
    this.thinkingLevel,
    this.sessionName,
    this.hubId,
    this.selectedSourceId,
    this.sourceEpoch,
    this.rttMs,
    this.pendingUiRequest,
    this.pendingAsk,
    this.contextUsage,
    this.pendingMessageCount,
    this.snapshotTruncated = false,
    this.hasMoreHistory = false,
    this.loadingEarlier = false,
    this.sessionBusyElsewhere = false,
    this.sessionWaking = false,
    this.transientNotice,
    this.composerFill,
    this.backgroundFinishTick = 0,
    this.backgroundFinishName,
    this.activityStatus,
  });

  factory PiState.initial() => const PiState(
    status: PiConnStatus.disconnected,
    items: [],
    revision: 0,
    isStreaming: false,
    isCompacting: false,
    steeringQueue: [],
    followUpQueue: [],
    hasSession: false,
    autoCompactionEnabled: false,
    sources: [],
    sessions: [],
    isDriving: false,
    lastSourceSeq: 0,
  );

  final PiConnStatus status;

  /// 最近一次成功连接使用的实际通道。断线重连期间保留,用于展示和 P2P 粘滞。
  final PiActiveTransport? activeTransport;

  /// 业务就绪阶段(transport→auth→catalog→selected→synced)。
  /// UI 的"连接中/同步中/已同步/降级"四态以此渲染,不看裸 status。
  final SyncPhase sessionPhase;
  final List<ChatItem> items;
  final int revision;
  final bool isStreaming;
  final bool isCompacting;
  final List<String> steeringQueue;
  final List<String> followUpQueue;
  final bool hasSession;
  final String? error;
  final String? sessionId;
  final String? cwd;
  final String? modelId;
  final String? modelName;
  final String? thinkingLevel;
  final String? sessionName;
  final bool autoCompactionEnabled;
  final String? hubId;
  final List<SourceInfo> sources;
  final String? selectedSourceId;
  final String? sourceEpoch;
  final int lastSourceSeq;

  /// 当前可用的会话(活跃 + 磁盘上的)。
  final List<HubSession> sessions;

  /// 本机是否持有当前源的租约。**纯内部信号**:只用来决定要不要自动重取,
  /// 绝不用来禁用输入框或按钮 —— 用户不该知道租约的存在。
  final bool isDriving;

  /// 选中的会话正在被另一端驱动(仅用于提示,不阻止发送)。
  final bool sessionBusyElsewhere;

  /// 正在唤醒休眠会话。
  final bool sessionWaking;

  /// 一次性提示(横幅),由 `_LivenessBanner` 渲染,用户点掉后调
  /// `dismissNotice()` 清空。
  final String? transientNotice;

  /// 一次性:回退到某条用户消息后,要把那条消息原文填回输入框(等同桌面
  /// pi 的 editorText 行为)。chat_body 监听它,填完调 consumeComposerFill
  /// 清掉 —— 不能常驻 state,否则下个会话了它还阴魂不散。
  final String? composerFill;

  /// 桌面 working-activity 插件推过来的实时状态行(TUI Working 行同源)。
  /// 非空时灵动岛直接显示它,不再用本地从 items 推导的二手状态。
  final String? activityStatus;

  /// 后台会话刚刚跑完:tick 自增用于触发监听,name 是会话显示名。
  /// (通知要不要真的弹由 NotificationController 按前后台状态决定。)
  final int backgroundFinishTick;
  final String? backgroundFinishName;

  /// 最近一次 bridge_ping 往返时延(连接健康指示)。
  final int? rttMs;

  /// 扩展等待用户输入的对话框(headless 源手机端可交互应答)。
  final UiRequest? pendingUiRequest;

  /// 电脑端转过来、等手机作答的 ask_user_question 问卷。
  final AskRequest? pendingAsk;

  /// 上下文占用(桌面快照直给;headless 由 get_session_stats 补拉)。
  final ContextUsage? contextUsage;
  final int? pendingMessageCount;

  /// 桌面快照因超限被截断(历史消息不完整)。
  final bool snapshotTruncated;

  /// 桥上还留着更早的历史,可以按需往前补。
  ///
  /// 与 [snapshotTruncated] 不是一回事:那个说的是**桌面 relay** 抓快照时就超限了,
  /// 更早的内容压根没到桥上;这个说的是桥为了不撞爆手机的 2MB 套接字缓冲而只发了
  /// 尾巴,更早的仍在桥上,`get_entries` 带 `before` 就能取回来。
  final bool hasMoreHistory;

  /// 正在往前补历史(用于「加载更早」按钮的加载态)。
  final bool loadingEarlier;

  SourceInfo? get selectedSource {
    final id = selectedSourceId;
    if (id == null) return null;
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  bool get hasSelectedSource => selectedSource != null;

  /// 当前选中会话是否可以直接收命令。
  ///
  /// 注意这里**没有租约条件**:租约是自动获取的,输入永远开放,
  /// 拿不到租约是 `_mutatingRequest` 内部重试的事,不是 UI 的门。
  bool get isLive =>
      status == PiConnStatus.connected && selectedSource?.connected == true;

  /// 休眠会话:选中了但进程没起来,发消息会顺带唤醒它。
  bool get isDormant =>
      status == PiConnStatus.connected &&
      selectedSource != null &&
      selectedSource!.connected == false;

  SessionLiveness get liveness {
    final source = selectedSource;
    if (source == null) return SessionLiveness.dormant;
    if (source.isDesktop) return SessionLiveness.desktop;
    return source.connected
        ? SessionLiveness.headless
        : SessionLiveness.dormant;
  }

  /// 目录/会话浏览:本地 bridge 会话才有磁盘上的兄弟会话可列。
  bool get canListSessions => selectedSource?.isHeadless != false;

  PiState copyWith({
    PiConnStatus? status,
    PiActiveTransport? activeTransport,
    SyncPhase? sessionPhase,
    List<ChatItem>? items,
    int? revision,
    bool? isStreaming,
    bool? isCompacting,
    List<String>? steeringQueue,
    List<String>? followUpQueue,
    bool? hasSession,
    String? error,
    String? sessionId,
    String? cwd,
    String? modelId,
    String? modelName,
    String? thinkingLevel,
    String? sessionName,
    bool? autoCompactionEnabled,
    String? hubId,
    List<SourceInfo>? sources,
    String? selectedSourceId,
    String? sourceEpoch,
    int? lastSourceSeq,
    List<HubSession>? sessions,
    bool? isDriving,
    bool? sessionBusyElsewhere,
    bool? sessionWaking,
    String? transientNotice,
    String? composerFill,
    int? backgroundFinishTick,
    String? backgroundFinishName,
    String? activityStatus,
    int? rttMs,
    UiRequest? pendingUiRequest,
    AskRequest? pendingAsk,
    ContextUsage? contextUsage,
    int? pendingMessageCount,
    bool? snapshotTruncated,
    bool? hasMoreHistory,
    bool? loadingEarlier,
    bool clearError = false,
    bool clearActiveTransport = false,
    bool clearSource = false,
    bool clearUiRequest = false,
    bool clearAsk = false,
    bool clearNotice = false,
    bool clearComposerFill = false,
    bool clearActivity = false,
  }) {
    return PiState(
      status: status ?? this.status,
      activeTransport: clearActiveTransport
          ? null
          : (activeTransport ?? this.activeTransport),
      sessionPhase: sessionPhase ?? this.sessionPhase,
      items: items ?? this.items,
      revision: revision ?? this.revision,
      isStreaming: isStreaming ?? this.isStreaming,
      isCompacting: isCompacting ?? this.isCompacting,
      steeringQueue: steeringQueue ?? this.steeringQueue,
      followUpQueue: followUpQueue ?? this.followUpQueue,
      hasSession: hasSession ?? this.hasSession,
      error: clearError ? null : (error ?? this.error),
      sessionId: clearSource ? null : (sessionId ?? this.sessionId),
      cwd: clearSource ? null : (cwd ?? this.cwd),
      modelId: clearSource ? null : (modelId ?? this.modelId),
      modelName: clearSource ? null : (modelName ?? this.modelName),
      thinkingLevel: clearSource ? null : (thinkingLevel ?? this.thinkingLevel),
      sessionName: clearSource ? null : (sessionName ?? this.sessionName),
      autoCompactionEnabled:
          autoCompactionEnabled ?? this.autoCompactionEnabled,
      hubId: hubId ?? this.hubId,
      sources: sources ?? this.sources,
      selectedSourceId: clearSource
          ? null
          : (selectedSourceId ?? this.selectedSourceId),
      sourceEpoch: clearSource ? null : (sourceEpoch ?? this.sourceEpoch),
      lastSourceSeq: clearSource ? 0 : (lastSourceSeq ?? this.lastSourceSeq),
      sessions: sessions ?? this.sessions,
      isDriving: clearSource ? false : (isDriving ?? this.isDriving),
      sessionBusyElsewhere: clearSource
          ? false
          : (sessionBusyElsewhere ?? this.sessionBusyElsewhere),
      sessionWaking: clearSource
          ? false
          : (sessionWaking ?? this.sessionWaking),
      transientNotice: clearNotice
          ? null
          : (transientNotice ?? this.transientNotice),
      composerFill: clearComposerFill
          ? null
          : (composerFill ?? this.composerFill),
      activityStatus: clearSource || clearActivity
          ? null
          : (activityStatus ?? this.activityStatus),
      backgroundFinishTick: backgroundFinishTick ?? this.backgroundFinishTick,
      backgroundFinishName: backgroundFinishName ?? this.backgroundFinishName,
      rttMs: rttMs ?? this.rttMs,
      pendingUiRequest: clearSource || clearUiRequest
          ? null
          : (pendingUiRequest ?? this.pendingUiRequest),
      pendingAsk: clearSource || clearAsk
          ? null
          : (pendingAsk ?? this.pendingAsk),
      contextUsage: clearSource ? null : (contextUsage ?? this.contextUsage),
      pendingMessageCount: clearSource
          ? null
          : (pendingMessageCount ?? this.pendingMessageCount),
      snapshotTruncated: clearSource
          ? false
          : (snapshotTruncated ?? this.snapshotTruncated),
      hasMoreHistory: clearSource
          ? false
          : (hasMoreHistory ?? this.hasMoreHistory),
      loadingEarlier: clearSource
          ? false
          : (loadingEarlier ?? this.loadingEarlier),
    );
  }
}

/// 每台设备一个实例:family 参数 = roster 设备的 [DeviceProfile.id],
/// 经构造函数注入(riverpod 3 的 family 传参方式)。
///
/// UI 一般**不直接用它**:聊天/会话页读「当前设备代理」`piSessionProvider`
/// (见 device_manager.dart,命名保留所以旧调用点零改动);
/// 设备列表页按设备 id 读对应实例。
final piSessionFamilyProvider =
    NotifierProvider.family<PiSessionNotifier, PiState, String>(
      PiSessionNotifier.new,
    );

// ---------------------------------------------------------------------------
// Notifier: owns the connection, applies the RPC event stream to state
// ---------------------------------------------------------------------------

/// 租约 TTL:hub 端 clamp 到 3–8s。短 TTL + 强制抢占 + ping/pong 三条路径,
/// 把"另一端掉线后本机要等多久才能驱动"从 31s 压到即时。
const int _leaseTtlMs = 8000;

enum _OpenRoute { configured, lanOnly, p2pOnly }

typedef _ConnectionScope = ({int generation, PiConnection connection});

class PiSessionNotifier extends Notifier<PiState> {
  /// family 注入:这台 notifier 负责的 roster 设备 id。
  /// 连接/重连/通知都按这个 id 各管各的,多设备互不干扰。
  PiSessionNotifier(this._deviceId);

  final String _deviceId;

  /// 本实例负责的 roster 设备 id(保活/账本对账用)。
  String get deviceId => _deviceId;

  /// remote_hint_v1:通知协议穿梭用的活动连接只读视图。
  /// 生命周期仍由 notifier 管理,调用方不得持有它跨重连使用。
  PiConnection? get activeConnection => _conn;

  /// remote_hint_v1:当前连接上收到的 bridge_hello 原文。
  /// 后台才启动的通知穿梭等不到下一条 hello(每连接只发一次),
  /// 启动时拿这份缓存先重放给原生引擎,否则引擎无法订阅。
  Map<String, dynamic>? get lastHelloFrame => _lastHelloFrame;
  Map<String, dynamic>? _lastHelloFrame;

  PiConnection? _conn;
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<PiConnStatus>? _statusSub;
  Timer? _reconnectTimer;
  Timer? _lanRecoveryTimer;
  Timer? _leaseRenewTimer;
  Timer? _healthTimer;
  int _reconnectAttempt = 0;
  bool _reconnectInFlight = false;
  bool _lanProbeInFlight = false;
  bool _transportSwitchInFlight = false;
  bool _preferP2pInAuto = false;
  PiActiveTransport? _activeTransport;
  int _connectionGeneration = 0;
  DateTime? _lastPongAt;
  final math.Random _jitterRandom = math.Random();

  static const _lanRecoveryInterval = Duration(seconds: 30);
  static const _lanProbeTimeout = Duration(seconds: 4);
  static const _lanRecoveryBusyDelay = Duration(seconds: 5);

  final List<ChatItem> _items = [];
  final Map<String, ChatItem> _itemsByKey = {};
  final Set<String> _seenEntryIds = {};
  final Set<String> _seenMsgKeys = {};
  final Map<String, ToolItem> _toolCards = {};
  final Map<String, BashItem> _bashCards = {};
  AssistantItem? _streamingAssistant;
  int _systemSeq = 0;

  final Map<String, Completer<Map<String, dynamic>?>> _pending = {};
  int _reqId = 0;

  String? _leafId;

  /// 已知最靠前那条 entry 的 id —— 往前分页的游标。
  String? _oldestEntryId;

  /// 非 null 时 [_addItem] 改成在这个下标插入并自增。
  ///
  /// 补回来的历史必须落在**头部**,而 _items 只有 add。不给个插入游标的话,
  /// 旧消息会排在新消息后面,时间线直接反了。逐条自增而不是固定插 0,
  /// 是为了保住这一批内部的先后顺序。
  int? _prependAt;
  ({String host, int port, String token, String? clientId})? _creds;

  /// 打洞配置快照(与 _creds 同生命周期):connect(DeviceProfile) 时按设备
  /// 快照;设备没配 P2P 或选了仅直连时为 null——_open() 据此决定直连
  /// 失败后是否落 P2P。
  ({String rendezvous, String deviceId, String secret})? _p2p;

  /// 传输偏好快照(与 _creds 同生命周期):auto=直连优先失败落 P2P;
  /// lan=仅直连;p2p=仅打洞。
  DeviceTransport _transport = DeviceTransport.auto;
  bool _intentionalDisconnect = false;
  bool _hubV2 = false;

  /// 每个 source 一份租约:并发会话下,手机可能同时驱动 A 和 B。
  ///
  /// 必须记 `expiresAt`:TTL 只有 8 秒,而后台会话的租约是不续的。
  /// 只看"map 里有没有"会拿一个早就死掉的 leaseId 去发命令。
  final Map<String, ({String leaseId, int fence, DateTime expiresAt})> _leases =
      {};

  ({String leaseId, int fence})? _liveLease(String sourceId) {
    final lease = _leases[sourceId];
    if (lease == null) return null;
    // 留 1 秒余量,免得命令在路上就过期了
    if (lease.expiresAt.isBefore(
      DateTime.now().add(const Duration(seconds: 1)),
    )) {
      _leases.remove(sourceId);
      return null;
    }
    return (leaseId: lease.leaseId, fence: lease.fence);
  }

  /// 同步代次令牌:陈旧的同步永远不许 drain 缓冲、不许覆盖新状态。
  /// 旧实现是个 bool,两次并发同步会互相踩。
  int _syncGeneration = 0;
  int _activeSyncGeneration = 0;
  Timer? _resyncTimer;

  /// 选中源从推送目录消失后的宽限复核定时器,见 [_scheduleSourceLossCheck]。
  Timer? _sourceLossTimer;
  int _resyncAttempt = 0;

  /// 事件页连续翻页轮数。bridge 的事件重放页有硬上限,落后很多时要翻几轮才
  /// 追平;有界是为了防止"每轮都被截断"时无限递归(例如单条事件本身超预算)。
  int _eventPageRounds = 0;
  static const _maxEventPageRounds = 50;
  bool _resyncRunning = false;

  /// 在一轮重同步执行期间被压下的请求原因(只留最早那个)。
  ///
  /// 空快照守卫的补货必然发生在同步过程中,直接丢掉就等于不修。
  String? _pendingResyncReason;
  int _inOrderStreak = 0;
  bool _bufferOverflowed = false;
  bool _gapNoticeShown = false;
  final List<Map<String, dynamic>> _bufferedSourceEvents = [];

  bool _disposed = false;

  /// `await` 之后写 state 必须走这里:provider 已释放时再写会抛异常。
  void _write(PiState next) {
    if (_disposed) return;
    state = next;
  }

  bool _connectionScopeCurrent(_ConnectionScope? scope) =>
      scope == null ||
      (scope.generation == _connectionGeneration &&
          !_disposed &&
          !_intentionalDisconnect &&
          identical(_conn, scope.connection) &&
          scope.connection.isOpen);

  bool _syncWorkCurrent({
    _ConnectionScope? connectionScope,
    int? syncGeneration,
    String? sourceId,
  }) =>
      _connectionScopeCurrent(connectionScope) &&
      (syncGeneration == null || syncGeneration == _syncGeneration) &&
      (sourceId == null || sourceId == state.selectedSourceId);

  @override
  PiState build() {
    ref.onDispose(() {
      _disposed = true;
      _tearDown();
    });
    // 连接生命周期由 DeviceManager 显式驱动(roster 加载/新增/编辑设备时
    // 调 connect)。不要在这里 listen settings 自动连接——N 个 family 实例
    // 都去听同一份设置会竞赛。
    unawaited(
      SyncStore.open().then((store) {
        if (!_disposed) _syncStore = store;
      }),
    );
    return PiState.initial();
  }

  // -- public API ------------------------------------------------------------

  /// 使用 roster 里一台设备的配置建立连接。
  ///
  /// 配置在调用时快照(_creds/_p2p/_transport),之后的断线重连都用这份
  /// 快照——用户在设备页改了配置,要显式再调 connect 才生效,重连不会
  /// 悄悄换参数。
  Future<void> connect(DeviceProfile device) async {
    // 新连接尝试:旧 hello 属于旧连接,作废,等新连接的 hello 再写。
    _lastHelloFrame = null;
    // clientId 是「这台手机」的全局身份(与设备无关),仍从设置读。
    final clientId = ref.read(settingsProvider).clientId;
    // token 两条路都要:直连经 ?token= 鉴权,打洞经首帧 auth 鉴权。
    final canLan =
        device.host.isNotEmpty && device.transport != DeviceTransport.p2p;
    final canP2p = device.hasP2p && device.transport != DeviceTransport.lan;
    if (device.token.isEmpty || (!canLan && !canP2p)) {
      state = state.copyWith(
        status: PiConnStatus.failed,
        error: '这台设备还没有可用的连接配置,请在设备页补全',
      );
      return;
    }
    final generation = ++_connectionGeneration;
    _syncGeneration++;
    _activeSyncGeneration = 0;
    _cancelLanRecovery();
    _preferP2pInAuto = false;
    _activeTransport = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _intentionalDisconnect = false;
    _transport = device.transport;
    _creds = (
      host: device.host,
      port: device.port,
      token: device.token,
      clientId: clientId.isNotEmpty ? clientId : null,
    );
    _p2p = canP2p
        ? (
            rendezvous: device.p2pRendezvous!,
            deviceId: device.p2pDeviceId!,
            secret: device.p2pSecret!,
          )
        : null;
    state = state.copyWith(
      status: PiConnStatus.connecting,
      sessionPhase: SyncPhase.connecting,
      clearError: true,
      clearActiveTransport: true,
    );

    bool ok;
    try {
      ok = await _open();
    } catch (_) {
      // 任何异常(如非法主机名)都不能让状态停在 connecting
      ok = false;
    }
    if (generation != _connectionGeneration ||
        _disposed ||
        _intentionalDisconnect) {
      return;
    }
    if (!ok) {
      state = state.copyWith(
        status: PiConnStatus.failed,
        error: '连接失败或鉴权被拒,请检查地址与 token',
      );
      // 首连失败也必须进入重试。原来这里直接 return,而 _onConnStatus 开头有
      // `!state.hasSession` 提前返回,于是自动重连只在「曾经连上过」之后才存在:
      // 冷启动时 Bridge 没就绪、Wi-Fi 刚切换、DHCP 还没拿到地址等任何瞬时失败,
      // 都会被固化成永久失败态,用户只能反复手动点重试(实测正是这个体感)。
      _scheduleReconnect();
      return;
    }
    state = state.copyWith(status: PiConnStatus.connected, hasSession: true);
    await _initializeAfterConnect(generation);
  }

  void disconnect() {
    _connectionGeneration++;
    _syncGeneration++;
    _activeSyncGeneration = 0;
    _cancelLanRecovery();
    _preferP2pInAuto = false;
    _activeTransport = null;
    _intentionalDisconnect = true;
    _clearAllLeases();
    _tearDown();
    _resetConversation(reason: 'disconnect');
    _leafId = null;
    _creds = null;
    _p2p = null;
    _transport = DeviceTransport.auto;
    _hubV2 = false;
    state = PiState.initial();
  }

  /// 发送一条用户消息。
  ///
  /// **任何时刻都可以输入**,但压缩期间 pi 0.82.1 没有消息队列,
  /// 必须先中断压缩才能发送。生成期间支持三种投递语义:
  /// - [PiDelivery.steer]  插队:当前这一轮结束后立刻处理(pi 的 steer)。**不是中断。**
  /// - [PiDelivery.followUp] 排队:全部处理完之后再处理。
  /// - [PiDelivery.interrupt] 中断当前生成或压缩,然后发送。
  ///
  /// 不传 [delivery] 时:空闲直接发,生成中默认 [PiDelivery.steer];
  /// 压缩中拒绝普通发送,由 UI 引导用户明确选择「中断并发送」。
  Future<void> sendPrompt(String text, {PiDelivery? delivery}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // 内置斜杠命令必须在这里被截住。pi 的 session.prompt() 只解析**扩展注册**的
    // 命令,内置命令(compact 等)发过去就是一句字面文本,模型会当普通话来读。
    // 拦在 sendPrompt 开头,快捷面板补全后回车、和用户自己把命令打全,两条路都覆盖。
    final builtin = parseBuiltinCommand(trimmed);
    if (builtin != null) {
      await _runBuiltinCommand(builtin);
      return;
    }

    // 目标源在整个流程里必须钉死:唤醒会话要几秒,期间用户可能已经切走了。
    // 用 `state.selectedSourceId` 重新解析会把消息发进另一个会话。
    final sourceId = state.selectedSourceId;

    // 休眠会话:发消息本身就是唤醒动作,不需要用户先"启动"
    if (_hubV2 &&
        sourceId != null &&
        state.selectedSource?.connected == false) {
      _write(state.copyWith(sessionWaking: true));
      if (!await _wakeSelectedSession(sourceId)) {
        _failSend(trimmed, '会话没能启动');
        return;
      }
    }
    // 用户在唤醒期间切走了 —— 不能把消息投进新会话
    if (sourceId != null && sourceId != state.selectedSourceId) {
      _failSend(trimmed, '会话已切换,消息没有发出');
      return;
    }

    final compacting = state.isCompacting;
    if (compacting && delivery != PiDelivery.interrupt) {
      _failSend(trimmed, '压缩中,请先中断再发送');
      return;
    }
    final streaming = state.isStreaming;
    final mode =
        delivery ?? (streaming ? PiDelivery.steer : PiDelivery.followUp);
    if (mode == PiDelivery.interrupt && (streaming || compacting)) {
      if (!await abort(sourceId: sourceId)) {
        _failSend(trimmed, '中断没能送达,消息没有发出');
        return;
      }
    }
    if (!await _sendMutating({
      'type': 'prompt',
      'message': trimmed,
      if (streaming && mode != PiDelivery.interrupt)
        'streamingBehavior': mode == PiDelivery.steer ? 'steer' : 'followUp',
    }, sourceId)) {
      _failSend(trimmed, '消息没有发出');
    }
  }

  /// 中断当前生成或压缩。请求必须等桌面端确认操作已经停下:
  /// 「中断并发送」随后才能安全地开始新一轮。
  Future<bool> abort({String? sourceId}) async {
    final target = sourceId ?? state.selectedSourceId;
    if (target != null && target != state.selectedSourceId) return false;
    final resp = await _mutatingRequest(
      'abort',
      const {},
      const Duration(seconds: 35),
    );
    if (resp?['success'] == true) return true;
    _write(state.copyWith(error: '中断没能送达,请重试'));
    return false;
  }

  /// 发一条 fire-and-forget 的写命令:确保租约 → 发送;
  /// 拿不到租约就**如实返回 false**,绝不假装发出去了。
  ///
  /// (`prompt`/`abort` 走的是无 id 的即发即忘通道,bridge 的拒绝会变成一条
  /// 无人认领的 response —— 用户只会看到"点了没反应",消息还被输入框清掉了。)
  Future<bool> _sendMutating(
    Map<String, dynamic> frame,
    String? sourceId,
  ) async {
    if (!_hubV2) return _conn?.send(frame) ?? false;
    if (sourceId == null) return false;
    if (!await _ensureLease(sourceId)) return false;
    final meta = _leaseMetadata(sourceId);
    if (meta.isEmpty) return false;
    // opId 幂等:发送前落 WAL,断线恢复后按 hub_op_status 对账,
    // 查不到的一律"结果未知"提示用户,绝不自动重放(防重复提交)。
    final opId = await _nextOpId();
    final sent = _conn?.send({...frame, ...meta, 'opId': ?opId}) ?? false;
    if (sent && opId != null) {
      unawaited(
        _syncStore?.insertOp(
          opId: opId,
          clientId: _creds?.clientId ?? '',
          // 多设备共用一个库:op 归到本设备名下,别的设备重连对账时看不到。
          deviceKey: _deviceId,
          type: frame['type'] as String? ?? 'unknown',
          sourceId: sourceId,
          sessionId: state.sessionId,
        ),
      );
    }
    return sent;
  }

  /// opId = {clientId}-op-{n},n 持久化递增,重发同一逻辑请求可用同 ID。
  Future<String?> _nextOpId() async {
    final clientId = _creds?.clientId;
    if (clientId == null || clientId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final n = (prefs.getInt('op.seq') ?? 0) + 1;
    await prefs.setInt('op.seq', n);
    return '$clientId-op-$n';
  }

  /// 重连后对账 pending 写操作:accepted/executed 标完成;
  /// unknown 一律提示"结果未知",禁止自动重放。
  Future<void> _reconcilePendingOps({
    _ConnectionScope? connectionScope,
    int? syncGeneration,
    String? sourceId,
  }) async {
    bool current() => _syncWorkCurrent(
      connectionScope: connectionScope,
      syncGeneration: syncGeneration,
      sourceId: sourceId,
    );
    final store = _syncStore;
    if (store == null || !_hubV2 || !current()) return;
    // 只对账本设备的 op(+ 单设备时代遗留的 NULL 行),
    // 不把别设备的排队写操作拿到这台 bridge 上问状态。
    final pending = await store.pendingOps(deviceKey: _deviceId);
    if (!current()) return;
    for (final op in pending) {
      if (!current() || _conn?.isOpen != true) return;
      final opId = op['op_id'] as String?;
      if (opId == null) continue;
      final resp = await _request('hub_op_status', {'opId': opId});
      if (!current()) return;
      final status = (resp?['data'] as Map?)?['status'] as String?;
      if (status == 'accepted' || status == 'executed') {
        await store.updateOpStatus(opId, status!);
        if (!current()) return;
      } else if (resp != null) {
        await store.updateOpStatus(opId, 'unknown');
        if (!current()) return;
        _addSystem('断线前的「${op['type']}」结果未知,请确认后手动重试', SystemKind.error);
        _write(state.copyWith());
      }
      // resp == null:桥没回,保持 pending,下次重连再对账。
    }
  }

  /// 发送失败:把原文交还给用户,而不是让它消失在被清空的输入框里。
  void _failSend(String text, String reason) {
    _addSystem('$reason:$text', SystemKind.error);
    _write(state.copyWith(error: reason));
  }

  /// 手机上可用的 pi 内置斜杠命令。
  ///
  /// 只有 compact。model / thinking / name / tree 在 App 里已经有原生入口;
  /// settings / hotkeys / export / share / login / quit 是电脑本地的事;
  /// new / resume / fork / clone 永不开放 —— 那会换掉人在电脑上正用的会话。
  static const builtinCommandNames = {'compact'};

  /// 从输入文本里识别内置命令;不是内置命令就返回 null。
  ///
  /// 存在的意义是守住边界:`/compacting` 不是 `/compact`,
  /// `/compact 保留报错信息` 要把后半句当自定义压缩要求传下去,
  /// 而 `请帮我 /compact` 这种普通句子绝不能被误判成命令。
  @visibleForTesting
  static BuiltinInvocation? parseBuiltinCommand(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('/')) return null;
    final body = trimmed.substring(1);
    if (body.isEmpty) return null;
    final space = body.indexOf(RegExp(r'\s'));
    final name = space < 0 ? body : body.substring(0, space);
    if (!builtinCommandNames.contains(name)) return null;
    final rest = space < 0 ? '' : body.substring(space).trim();
    return BuiltinInvocation(name: name, argument: rest.isEmpty ? null : rest);
  }

  Future<void> _runBuiltinCommand(BuiltinInvocation invocation) async {
    switch (invocation.name) {
      case 'compact':
        // 压缩期间再发一次只会被桌面端抢报错,提前抦下来说清楚。
        if (state.isCompacting) {
          _write(state.copyWith(transientNotice: '桌面端已经在压缩上下文了'));
          return;
        }
        _addSystem('已请求桌面端压缩上下文…');
        final ok = await compact(instructions: invocation.argument);
        // ctx.compact() 不 await 完成,所以这里的 ok 只代表「已受理」。
        // 真正的进展靠 session_before_compact / session_compact 事件流回来。
        if (!ok) {
          _addSystem('压缩请求没能发出去', SystemKind.error);
        }
      default:
        _addSystem('不支持的内置命令:/${invocation.name}', SystemKind.error);
    }
  }

  /// 唤醒当前选中的休眠会话(拉起 pi 进程)。
  Future<bool> _wakeSelectedSession(String sourceId) async {
    final source = state.sources
        .where((item) => item.id == sourceId)
        .firstOrNull;
    if (source == null || source.connected) {
      if (!_disposed) state = state.copyWith(sessionWaking: false);
      return true;
    }
    final resp = await _request('hub_open_session', {
      'sessionId': ?source.sessionId,
      'cwd': ?source.cwd,
      'spawn': true,
    });
    final ok = resp?['success'] == true;
    if (!_disposed) state = state.copyWith(sessionWaking: false);
    return ok;
  }

  // -- Source Hub -------------------------------------------------------------

  Future<List<SourceInfo>> refreshSources() => _refreshSources();

  Future<List<SourceInfo>> _refreshSources({
    _ConnectionScope? connectionScope,
  }) async {
    if (!_hubV2 || !_connectionScopeCurrent(connectionScope)) {
      return state.sources;
    }
    final resp = await _request('hub_list_sources');
    if (!_connectionScopeCurrent(connectionScope)) return state.sources;
    final raw = (resp?['data'] as Map?)?['sources'] as List?;
    if (resp?['success'] != true || raw == null) return state.sources;
    final parsed = [
      for (final source in raw)
        if (source is Map) SourceInfo.fromMap(source),
    ];
    _write(
      state.copyWith(sources: parsed, sessionPhase: SyncPhase.catalogReady),
    );
    return parsed;
  }

  /// 拉取会话总表(活跃 + 磁盘上的)。
  /// 失败返回 null(保留旧列表),成功返回新列表 —— 调用方据此重试,
  /// 不再把"加载失败"和"没有会话"混为一谈。
  Future<List<HubSession>?> refreshHubSessions({String? cwd}) =>
      _refreshHubSessions(cwd: cwd);

  Future<List<HubSession>?> _refreshHubSessions({
    String? cwd,
    _ConnectionScope? connectionScope,
  }) async {
    if (!_hubV2) return const [];
    if (!_connectionScopeCurrent(connectionScope)) return null;
    final resp = await _request('hub_list_sessions', {'cwd': ?cwd});
    if (!_connectionScopeCurrent(connectionScope)) return null;
    final raw = (resp?['data'] as Map?)?['sessions'] as List?;
    if (resp?['success'] != true || raw == null) {
      _logP2p(
        'hub_list_sessions failed(success=${resp?['success']}),keep stale',
      );
      return null;
    }
    final parsed = [
      for (final entry in raw)
        if (entry is Map) HubSession.fromMap(entry),
    ];
    _write(state.copyWith(sessions: parsed));
    return parsed;
  }

  /// catalog 加载的失败重试(1s/2s/4s):连接刚建立时 P2P 慢链路上
  /// 一次超时是常态,放弃重试就是"列表永远空白"。
  Future<void> refreshHubSessionsWithRetry({String? cwd}) =>
      _refreshHubSessionsWithRetry(cwd: cwd);

  Future<void> _refreshHubSessionsWithRetry({
    String? cwd,
    _ConnectionScope? connectionScope,
  }) async {
    const delays = <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ];
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      if (_disposed ||
          _conn?.isOpen != true ||
          !_connectionScopeCurrent(connectionScope)) {
        return;
      }
      final result = await _refreshHubSessions(
        cwd: cwd,
        connectionScope: connectionScope,
      );
      if (!_connectionScopeCurrent(connectionScope)) return;
      if (result != null) return;
      if (attempt < delays.length) {
        await Future<void>.delayed(delays[attempt]);
      }
    }
  }

  /// 打开一个会话:订阅它,并按需拉起进程。
  ///
  /// **不会打断任何一端的生成** —— hub 侧是 attach-or-spawn,从不 kill。
  /// 传 `sessionId: null` 表示新建一个会话。
  Future<bool> openSession({
    String? sessionId,
    String? cwd,
    String? sessionPath,
    bool spawn = true,
    bool persist = true,
  }) async {
    if (!_hubV2) return false;
    final gen = ++_syncGeneration;
    _activeSyncGeneration = gen;
    _bufferedSourceEvents.clear();
    _leafId = null;
    _resetConversation(reason: 'open-session');
    state = state.copyWith(clearSource: true, sessionWaking: true);

    final resp = await _request('hub_open_session', {
      'sessionId': ?sessionId,
      'cwd': ?cwd,
      'sessionPath': ?sessionPath,
      'spawn': spawn,
    });
    // 被更新的一次打开取代:那一次会负责收尾,这里安静退出。
    // 注意返回 true —— 从调用方看,"打开"这个动作并没有失败。
    if (gen != _syncGeneration) return true;
    if (resp?['success'] != true) {
      _activeSyncGeneration = 0;
      _bufferedSourceEvents.clear();
      _write(
        state.copyWith(
          sessionWaking: false,
          error: (resp?['error'] as String?) ?? '打开会话失败',
        ),
      );
      return false;
    }
    final data = resp?['data'] as Map?;
    final raw = data?['source'];
    final resolvedId = data?['sourceId'] as String? ?? '';
    final selected = raw is Map
        ? SourceInfo.fromMap(raw)
        : state.sources.where((source) => source.id == resolvedId).firstOrNull;
    if (selected == null) {
      _activeSyncGeneration = 0;
      _bufferedSourceEvents.clear();
      _write(state.copyWith(sessionWaking: false));
      return false;
    }
    if (_disposed) return false;
    state = state.copyWith(
      selectedSourceId: selected.id,
      sourceEpoch: selected.epoch,
      cwd: selected.cwd,
      sessionId: selected.sessionId,
      sessionName: selected.sessionName,
      isDriving: _liveLease(selected.id) != null,
      sessionWaking: false,
      sessionBusyElsewhere: false,
      clearError: true,
    );
    if (persist) {
      unawaited(
        ref
            .read(settingsProvider.notifier)
            .setPreferredSource(selected.id, selected.sessionId),
      );
    }
    await _syncSelectedSource(forceFull: true, generation: gen);
    unawaited(refreshSources());
    unawaited(refreshHubSessionsWithRetry());
    return true;
  }

  Future<bool> selectSource(String sourceId, {bool persist = true}) =>
      _selectSource(sourceId, persist: persist);

  Future<bool> _selectSource(
    String sourceId, {
    bool persist = true,
    _ConnectionScope? connectionScope,
  }) async {
    if (!_hubV2 || !_connectionScopeCurrent(connectionScope)) return false;

    // hub 在响应之前就开始向本客户端广播事件,所以必须先武装缓冲、
    // 先设 selectedSourceId,否则这段窗口里的事件会触发并发重同步。
    final gen = ++_syncGeneration;
    _activeSyncGeneration = gen;
    _bufferedSourceEvents.clear();
    _leafId = null;
    // 同源重连不清列表。
    //
    // 网络切换会走 network_changed → transport_open → _selectSource(同一个
    // sourceId) 这条链。这里原来无条件清空,于是一次 Wi-Fi/移动网切换就能把
    // 几百条消息瞬间清掉,再等快照灌回来 —— 中间那段空窗一旦撞上流式 token,
    // 就发布出「只剩正在生成的那一条」。
    //
    // 同源的旧内容本来就是对的:留着它,让随后的快照做原子替换/对账。真正
    // 需要清的是**换源**(下面那句 clearSource 也只在换源时才有意义)。
    final sameSource = sourceId == state.selectedSourceId;
    if (!sameSource) {
      _resetConversation(reason: 'select-source(switch)');
      state = state.copyWith(clearSource: true);
    }
    state = state.copyWith(
      selectedSourceId: sourceId,
      sessionPhase: SyncPhase.syncing,
    );

    final resp = await _request('hub_select_source', {'sourceId': sourceId});
    if (gen != _syncGeneration || !_connectionScopeCurrent(connectionScope)) {
      return false;
    }
    if (resp?['success'] != true) {
      _activeSyncGeneration = 0;
      return false;
    }
    final raw = (resp?['data'] as Map?)?['source'];
    final selected = raw is Map
        ? SourceInfo.fromMap(raw)
        : state.sources.where((source) => source.id == sourceId).firstOrNull;
    if (selected == null) {
      _activeSyncGeneration = 0;
      return false;
    }

    state = state.copyWith(
      selectedSourceId: selected.id,
      sourceEpoch: selected.epoch,
      cwd: selected.cwd,
      sessionId: selected.sessionId,
      sessionName: selected.sessionName,
      isDriving: _liveLease(selected.id) != null,
      sessionBusyElsewhere: false,
      sessionWaking: false,
    );
    // 磁盘 IO 不能挡在 select 与 sync 之间
    if (persist) {
      unawaited(
        ref
            .read(settingsProvider.notifier)
            .setPreferredSource(selected.id, selected.sessionId),
      );
    }
    await _syncSelectedSource(
      forceFull: true,
      generation: gen,
      connectionScope: connectionScope,
    );
    return _connectionScopeCurrent(connectionScope);
  }

  /// 确保持有某个源的租约。**自动、静默、可强制抢占** —— 用户永远看不到这一步。
  ///
  /// 租约在新模型里只剩两个作用:fencing(作废掉线客户端的在途命令)和归因。
  /// 它不再决定"谁能说话",所以默认 `force: true`:活人不该等一个死客户端的 TTL。
  Future<bool> _ensureLease(String sourceId, {bool force = true}) async {
    if (!_hubV2) return true;
    if (_liveLease(sourceId) != null) return true;
    // hub 用 client.selectedSourceId 解析目标,所以只能为**当前选中**的源取租约。
    // 拿着别的 sourceId 调会把租约记到错的键上,命令随后带着错的 fence 发出去。
    if (sourceId != state.selectedSourceId) return false;
    final resp = await _request('hub_acquire_owner', {
      'ttlMs': _leaseTtlMs,
      'force': force,
    });
    final data = resp?['data'] as Map?;
    if (resp?['success'] != true || data == null) return false;
    final leaseId = data['leaseId'] as String?;
    final fence = data['fence'] as int?;
    if (leaseId == null || fence == null) return false;
    _leases[sourceId] = (
      leaseId: leaseId,
      fence: fence,
      expiresAt: DateTime.now().add(const Duration(milliseconds: _leaseTtlMs)),
    );
    if (!_disposed && sourceId == state.selectedSourceId) {
      state = state.copyWith(isDriving: true, clearError: true);
    }
    _scheduleLeaseRenewal();
    return true;
  }

  /// 丢弃本地租约记录(不通知 hub;hub 端由 TTL 或强制抢占收尾)。
  void _dropLease(String sourceId) {
    _leases.remove(sourceId);
    if (_leases.isEmpty) {
      _leaseRenewTimer?.cancel();
      _leaseRenewTimer = null;
    }
    if (!_disposed && sourceId == state.selectedSourceId && state.isDriving) {
      state = state.copyWith(isDriving: false);
    }
  }

  void _scheduleLeaseRenewal() {
    if (_leaseRenewTimer != null) return;
    // TTL 已缩到 8s 量级,续约必须快于它的一半
    _leaseRenewTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_renewLeases()),
    );
  }

  Future<void> _renewLeases() async {
    if (!_hubV2 || _leases.isEmpty) return;
    final selected = state.selectedSourceId;
    // 只续当前选中源的租约:后台会话的租约让它自然过期,
    // 免得手机长期占着一个自己并没有在驱动的会话。
    if (selected == null) return;
    final lease = _leases[selected];
    if (lease == null) return;
    final resp = await _request('hub_renew_owner', {
      'leaseId': lease.leaseId,
      'fence': lease.fence,
      'ttlMs': _leaseTtlMs,
    });
    if (resp?['success'] != true) {
      _dropLease(selected);
      return;
    }
    _leases[selected] = (
      leaseId: lease.leaseId,
      fence: lease.fence,
      expiresAt: DateTime.now().add(const Duration(milliseconds: _leaseTtlMs)),
    );
  }

  void _clearAllLeases() {
    _leaseRenewTimer?.cancel();
    _leaseRenewTimer = null;
    _leases.clear();
    if (!_disposed && state.isDriving) {
      state = state.copyWith(isDriving: false);
    }
  }

  Map<String, dynamic> _leaseMetadata([String? sourceId]) {
    final id = sourceId ?? state.selectedSourceId;
    if (!_hubV2 || id == null) return const {};
    final lease = _liveLease(id);
    if (lease == null) return const {};
    return {
      '_hub': {'leaseId': lease.leaseId, 'fence': lease.fence},
    };
  }

  bool _sourceSupports(String command) =>
      !_hubV2 || (state.selectedSource?.supports(command) ?? false);

  /// 发出一条会改动会话的命令。
  ///
  /// 流程固定为:确保租约 → 发送 → **如果失败是租约问题就强制重取并重试一次**。
  /// 不存在"没有控制权"的早退分支 —— 那正是用户抱怨的"接管"模型。
  Future<Map<String, dynamic>?> _mutatingRequest(
    String type, [
    Map<String, dynamic> extra = const {},
    Duration? timeout,
  ]) async {
    final sourceId = state.selectedSourceId;
    if (!_hubV2 || sourceId == null) return _request(type, extra, timeout);

    await _ensureLease(sourceId);
    final first = await _request(type, {
      ...extra,
      ..._leaseMetadata(sourceId),
    }, timeout);
    if (!_isLeaseError(first)) return first;

    // 租约被别人抢走或过期:强制重取,重试恰好一次。
    _dropLease(sourceId);
    if (!await _ensureLease(sourceId)) return first;
    return _request(type, {...extra, ..._leaseMetadata(sourceId)}, timeout);
  }

  /// bridge 侧四种"你已经不在驱动了"的说法,少认一种就等于少一次自动重试。
  /// 见 bridge/src/owner_lease.ts 与 bridge/src/server.ts 的错误串。
  static const _leaseErrorMarkers = [
    'lease', // "a valid owner lease is required" / "lease is missing, expired, or stale"
    'owner', // "source is controlled by another client" 之外的 owner 系
    'controlled by another client',
    'took over this session',
  ];

  /// 测试入口:这条判定决定了"控制被抢走"能不能自动恢复,值得单独钉住。
  @visibleForTesting
  static bool debugIsLeaseError(Map<String, dynamic>? resp) =>
      _isLeaseError(resp);

  static bool _isLeaseError(Map<String, dynamic>? resp) {
    if (resp == null || resp['success'] == true) return false;
    final error = resp['error'];
    if (error is! String) return false;
    return _leaseErrorMarkers.any(error.contains);
  }

  Future<void> _initializeAfterConnect(int generation) async {
    final connection = _conn;
    if (connection == null) return;
    final connectionScope = (generation: generation, connection: connection);
    if (!_connectionScopeCurrent(connectionScope)) return;

    _reconnectAttempt = 0;
    _startHealthMonitor();
    _scheduleLanRecovery();
    if (!_hubV2) {
      await _sync(connectionScope: connectionScope);
      if (!_connectionScopeCurrent(connectionScope)) return;
      await _applyPreferences(connectionScope: connectionScope);
      return;
    }
    final available = await _refreshSources(connectionScope: connectionScope);
    if (!_connectionScopeCurrent(connectionScope)) return;
    final settings = ref.read(settingsProvider);
    final preferred = settings.preferredSourceId;
    final preferredSession = settings.preferredSessionId;
    final connectedDesktops = available
        .where((source) => source.isDesktop && source.connected)
        .toList();

    // sourceId 嵌着桌面 pi 的 PID,桌面重启后必然失配。以前失配就直接 clearSource,
    // App 停在“连接中”且 selectedSourceId 永远为空 —— 后台 watcher 也因此起不来。
    // 改为逐级回退,并把命中结果重新写回偏好实现自愈。
    SourceInfo? target;
    var healPreference = false;

    // 1) 精确命中原 sourceId
    if (preferred != null) {
      target = available
          .where((source) => source.id == preferred && source.connected)
          .firstOrNull;
    }
    // 2) 回退到同一会话:sessionId 跳过重启仍然稳定
    if (target == null && preferredSession != null) {
      target = available
          .where(
            (source) =>
                source.connected && source.sessionId == preferredSession,
          )
          .firstOrNull;
      if (target != null) healPreference = true;
    }
    // 3) 只有一个桌面端时直接用它(无歧义)——但跨会话命中只是代打:
    //    偏好只能为「同会话」重写,否则跳一次改错一次,
    //    用户的会话回来之后,恢复照样落到这个错误窗口。
    if (target == null && connectedDesktops.length == 1) {
      target = connectedDesktops.single;
      healPreference = shouldPersistAutoSwitch(target, preferredSession);
    }

    unawaited(_refreshHubSessionsWithRetry(connectionScope: connectionScope));
    if (target != null) {
      await _selectSource(
        target.id,
        persist: healPreference || preferred == null,
        connectionScope: connectionScope,
      );
    } else if (_connectionScopeCurrent(connectionScope)) {
      _resetConversation(reason: 'connect-no-source');
      state = state.copyWith(clearSource: true, sources: available);
    }
  }

  // -- session management ------------------------------------------------------

  /// Working directories that have pi sessions (bridge-local command).
  Future<List<DirEntry>> listDirs() async {
    final resp = await _request('bridge_list_dirs');
    final dirs = (resp?['data'] as Map?)?['dirs'] as List?;
    if (dirs == null) return const [];
    return [
      for (final d in dirs)
        if (d is Map)
          DirEntry(
            cwd: d['cwd'] as String? ?? '',
            sessionCount: d['sessionCount'] as int? ?? 0,
            lastActive: DateTime.tryParse(d['lastActive'] as String? ?? ''),
          ),
    ];
  }

  /// Sessions inside one working directory, most recent first.
  Future<List<SessionEntry>> listSessions(String cwd) async {
    final resp = await _request('bridge_list_sessions', {'cwd': cwd});
    final sessions = (resp?['data'] as Map?)?['sessions'] as List?;
    if (sessions == null) return const [];
    return [
      for (final s in sessions)
        if (s is Map)
          SessionEntry(
            path: s['path'] as String? ?? '',
            id: s['id'] as String? ?? '',
            name: s['name'] as String?,
            timestamp:
                DateTime.tryParse(s['timestamp'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
            sizeBytes: s['sizeBytes'] as int? ?? 0,
          ),
    ];
  }

  /// Switch to another session in the CURRENT directory (in-process).
  Future<bool> switchSession(String sessionPath) => _afterSwitch(
    _mutatingRequest('switch_session', {'sessionPath': sessionPath}),
  );

  /// Create a fresh session in the current directory.
  Future<bool> newSession() => _afterSwitch(_mutatingRequest('new_session'));

  /// 回到会话树上的某个节点(**三种回退共用的唯一原语**)。
  ///
  /// - 回到某条消息重开:传那条用户消息的 entryId
  /// - 撤销上一轮:`undoLastTurn()`(等价于传当前分支最后一条用户消息)
  /// - 分支间自由切换:传目标分支上任意节点的 entryId
  ///
  /// 结果不在本地推演,而是等 `session_tree` 事件回来 —— 两端因此收敛到同一状态。
  Future<bool> navigateTo(String? entryId) async {
    final resp = await _mutatingRequest('navigate_tree', {'entryId': ?entryId});
    if (resp?['success'] != true) {
      _write(state.copyWith(error: (resp?['error'] as String?) ?? '回退失败'));
      return false;
    }
    // 桌面端会把被回退掉的用户消息原文返回(editorText)——填回手机
    // 输入框,跟桌面 pi 的行为对齐:回退=把那条消息拿回来重新编辑。
    final editorText = (resp?['data'] as Map?)?['editorText'];
    if (editorText is String && editorText.isNotEmpty) {
      _write(state.copyWith(composerFill: editorText));
    }
    await _syncSelectedSource(forceFull: true);
    return true;
  }

  /// 输入框已经吃下了回退填充的文本,清掉这个一次性信号。
  void consumeComposerFill() {
    if (state.composerFill != null) {
      state = state.copyWith(clearComposerFill: true);
    }
  }

  /// 清掉一次性提示(用户点了横幅上的关闭)。
  void dismissNotice() {
    if (state.transientNotice != null || state.error != null) {
      state = state.copyWith(clearNotice: true, clearError: true);
    }
  }

  /// 撤销上一轮:回到当前分支的最后一条用户消息。
  Future<bool> undoLastTurn() => navigateTo(null);

  /// 当前可撤销的那条用户消息(为 null 说明没有可撤销的回合)。
  String? get undoTargetEntryId => undoTarget(state.items);

  /// Fork the current branch from a previous user message entry.
  Future<bool> forkFrom(String entryId) =>
      _afterSwitch(_mutatingRequest('fork', {'entryId': entryId}));

  /// 切换工作目录 = 在 hub 侧打开那个目录的会话。
  /// **不再重启任何进程** —— 当前会话若在生成,它会继续跑完。
  Future<bool> switchDir(String cwd, {String? sessionPath}) async {
    final resp = await _mutatingRequest('bridge_switch_dir', {
      'cwd': cwd,
      'sessionPath': ?sessionPath,
    });
    if (resp?['success'] != true || _disposed) return false;
    final data = resp?['data'] as Map?;
    state = state.copyWith(
      cwd: data?['cwd'] as String? ?? cwd,
      sessionId: data?['sessionId'] as String? ?? state.sessionId,
      isStreaming: false,
    );
    unawaited(ref.read(settingsProvider.notifier).touchRecentDir(cwd));
    _leafId = null;
    _resetConversation(reason: 'open-dir');
    await _sync(forceFull: true);
    return true;
  }

  /// 重命名当前会话(名称写入会话文件,列表刷新可见)。
  Future<bool> renameSession(String name) async {
    if (!_sourceSupports('set_session_name')) return false;
    final resp = await _mutatingRequest('set_session_name', {'name': name});
    if (resp?['success'] != true) return false;
    state = state.copyWith(sessionName: name);
    return true;
  }

  List<SlashCommand>? _commandsCache;
  String? _commandsCacheKey;

  /// 可用斜杠命令(按 source+session 缓存)。
  Future<List<SlashCommand>> getCommands() async {
    final cacheKey = '${state.selectedSourceId}:${state.sessionId}';
    if (_commandsCache != null && _commandsCacheKey == cacheKey) {
      return _commandsCache!;
    }
    final resp = await _request('get_commands');
    final data = resp?['data'] as Map?;
    if (resp?['success'] != true || data == null) return const [];
    final raw = data['commands'];
    if (raw is! List) return const [];
    final commands = [
      for (final command in raw)
        if (command is Map && command['name'] is String)
          SlashCommand(
            name: command['name'] as String,
            description: command['description'] as String?,
            source: command['source'] as String? ?? 'extension',
          ),
    ];
    _commandsCache = commands;
    _commandsCacheKey = cacheKey;
    return commands;
  }

  /// 正规 fork 选点数据源:可分叉的用户消息列表。
  Future<List<({String entryId, String text})>> getForkMessages() async {
    final resp = await _request('get_fork_messages');
    final data = resp?['data'] as Map?;
    if (resp?['success'] != true || data == null) return const [];
    final raw = data['messages'];
    if (raw is! List) return const [];
    return [
      for (final message in raw)
        if (message is Map &&
            message['entryId'] is String &&
            message['text'] is String)
          (
            entryId: message['entryId'] as String,
            text: message['text'] as String,
          ),
    ];
  }

  /// 会话树(headless 全量;desktop 走快照 treeSummary 压缩形态)。
  Future<SessionTree?> getTree() async {
    final resp = await _request('get_tree');
    final data = resp?['data'] as Map?;
    if (resp?['success'] != true || data == null) return null;
    final raw = data['tree'];
    if (raw is! List) return null;
    final isSummary = data['summary'] == true;
    return SessionTree(
      roots: _normalizeTree(raw, isSummary),
      leafId: data['leafId'] as String?,
      isSummary: isSummary,
    );
  }

  /// 会话树里**能作为回退目标**的 entry 类型。
  ///
  /// pi 的会话里还有大量 model_change / thinking_level_change / custom 节点,
  /// 它们不是回退目标,列在树里只是把真正的消息冲淡。desktop 快照侧已经
  /// 过滤过一道(省下的预算用来保住每条消息的 id),这里再过滤一道是为了
  /// headless 全量路径也有一致的形态。
  static const _navigableTreeTypes = {
    'message',
    'compaction',
    'branch_summary',
  };

  /// 归一化会话树。
  ///
  /// **迭代而非递归**:会话树是一条长单链(没有分叉时深度 == 消息数),
  /// 千条会话按 children 递归解析会爆栈。
  List<SessionTreeNode> _normalizeTree(List<dynamic> raw, bool summary) {
    // 第一趟:展平,记下每个节点的父下标(-1 为根)。非可回退类型不入表,
    // 它的子节点直接接到最近的保留祖先上。
    final nodes = <Map<dynamic, dynamic>>[];
    final parents = <int>[];
    final stack = <(Map<dynamic, dynamic>, int)>[];
    for (final node in raw.reversed) {
      if (node is Map) stack.add((node, -1));
    }
    while (stack.isNotEmpty) {
      final (node, parent) = stack.removeLast();
      final entry = _treeEntryOf(node, summary);
      var childParent = parent;
      if (entry != null &&
          entry['id'] is String &&
          _navigableTreeTypes.contains(entry['type'])) {
        childParent = nodes.length;
        nodes.add(node);
        parents.add(parent);
      }
      final children = node['children'];
      if (children is List) {
        for (final child in children.reversed) {
          if (child is Map) stack.add((child, childParent));
        }
      }
    }

    // 第二趟:倒序构建。DFS 先序保证子节点下标恒大于父节点,所以倒着走时
    // 子节点已经建好 —— 这正好绕开了“节点不可变、子节点必须先存在”的顺序问题。
    final kids = List<List<SessionTreeNode>>.generate(
      nodes.length,
      (_) => <SessionTreeNode>[],
    );
    final roots = <SessionTreeNode>[];
    for (var i = nodes.length - 1; i >= 0; i--) {
      // 入表时是倒序淌进去的,这里翻回原顺序
      final node = _treeNodeFrom(nodes[i], summary, kids[i].reversed.toList());
      final parent = parents[i];
      if (parent >= 0) {
        kids[parent].add(node);
      } else {
        roots.add(node);
      }
    }
    return roots.reversed.toList();
  }

  /// 取节点对应的 entry。summary 形态已经是扁的,全量形态包在 `entry` 里。
  Map<dynamic, dynamic>? _treeEntryOf(
    Map<dynamic, dynamic> node,
    bool summary,
  ) {
    if (summary) return node;
    final inner = node['entry'];
    return inner is Map ? inner : null;
  }

  SessionTreeNode _treeNodeFrom(
    Map<dynamic, dynamic> node,
    bool summary,
    List<SessionTreeNode> children,
  ) {
    final entry = _treeEntryOf(node, summary)!;
    final message = entry['message'] as Map?;
    final role = summary
        ? entry['role'] as String?
        : message?['role'] as String?;
    return SessionTreeNode(
      id: entry['id'] as String,
      parentId: entry['parentId'] as String?,
      type: entry['type'] as String? ?? 'unknown',
      time: entry['timestamp'] != null ? _timeFrom(entry['timestamp']) : null,
      preview: summary
          ? entry['preview'] as String? ?? ''
          : _treePreview(entry),
      label: node['label'] as String? ?? entry['label'] as String?,
      role: role,
      toolName: summary
          ? entry['toolName'] as String?
          : message?['toolName'] as String?,
      tools: summary
          ? _splitTools(entry['tools'])
          : _toolCallNames(message?['content']),
      isError: summary ? entry['isError'] == true : message?['isError'] == true,
      collapsedBefore: (node['collapsedBefore'] as num?)?.toInt() ?? 0,
      children: children,
    );
  }

  static List<String> _splitTools(dynamic raw) {
    if (raw is! String || raw.isEmpty) return const [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  /// assistant 回合里调用的工具名(去重)。
  ///
  /// 只有 thinking + toolCall 的回合没有任何文本,预览是空的,界面上就只剩一个
  /// 类型字样 —— 而「这一步调了 bash」恰恰是人回退时要找的锚点。
  static List<String> _toolCallNames(dynamic content) {
    if (content is! List) return const [];
    final names = <String>[];
    for (final block in content) {
      if (block is! Map || block['type'] != 'toolCall') continue;
      final name = block['name'];
      if (name is String && name.isNotEmpty && !names.contains(name)) {
        names.add(name);
      }
      if (names.length >= 4) break;
    }
    return names;
  }

  String _treePreview(Map<dynamic, dynamic> entry) {
    switch (entry['type']) {
      case 'message':
        final message = entry['message'];
        if (message is Map) {
          final text = _textFromContent(message['content']);
          return text.length > 120 ? '${text.substring(0, 120)}…' : text;
        }
        return '';
      case 'compaction':
        return '上下文压缩';
      case 'branch_summary':
        return '分支摘要';
      case 'model_change':
        return '模型切换: ${entry['modelId'] ?? ''}';
      case 'session_info':
        return '重命名: ${entry['name'] ?? ''}';
      default:
        return '${entry['type']}';
    }
  }

  Future<bool> _afterSwitch(Future<Map<String, dynamic>?> requestFuture) async {
    final resp = await requestFuture;
    if (resp?['success'] != true) return false;
    final data = resp?['data'];
    if (data is Map && data['cancelled'] == true) return false;
    _leafId = null;
    _resetConversation(reason: 'after-switch');
    await _sync(forceFull: true);
    return true;
  }

  // -- model & behaviour -------------------------------------------------------

  Future<List<ModelInfo>> getAvailableModels() async {
    final resp = await _request('get_available_models');
    final models = (resp?['data'] as Map?)?['models'] as List?;
    if (models == null) return const [];
    return [
      for (final m in models)
        if (m is Map)
          ModelInfo(
            id: m['id'] as String? ?? '',
            name: m['name'] as String? ?? m['id'] as String? ?? '',
            provider: m['provider'] as String? ?? '',
            contextWindow: m['contextWindow'] as int?,
          ),
    ];
  }

  Future<List<String>> getThinkingLevels() async {
    final resp = await _request('get_available_thinking_levels');
    final levels = (resp?['data'] as Map?)?['levels'] as List?;
    final parsed = levels?.whereType<String>().toList();
    return (parsed == null || parsed.isEmpty)
        ? const ['off', 'minimal', 'low', 'medium', 'high']
        : parsed;
  }

  /// Switch model; persists the choice as the default for future connects.
  Future<bool> setModel(String provider, String modelId) async {
    final resp = await _mutatingRequest('set_model', {
      'provider': provider,
      'modelId': modelId,
    });
    if (resp?['success'] != true) return false;
    final model = resp?['data'] as Map?;
    state = state.copyWith(
      modelId: model?['id'] as String? ?? modelId,
      modelName: model?['name'] as String? ?? state.modelName,
    );
    await ref
        .read(settingsProvider.notifier)
        .setModelPreference(provider: provider, modelId: modelId);
    return true;
  }

  Future<bool> setThinkingLevel(String level) async {
    final resp = await _mutatingRequest('set_thinking_level', {'level': level});
    if (resp?['success'] != true) return false;
    state = state.copyWith(thinkingLevel: level);
    await ref
        .read(settingsProvider.notifier)
        .setModelPreference(thinkingLevel: level);
    return true;
  }

  Future<bool> setAutoCompaction(bool enabled) async {
    final resp = await _mutatingRequest('set_auto_compaction', {
      'enabled': enabled,
    });
    if (resp?['success'] != true) return false;
    state = state.copyWith(autoCompactionEnabled: enabled);
    return true;
  }

  /// Auto-retry state isn't exposed by get_state, so the desired value is
  /// persisted app-side and re-applied on every connect.
  Future<bool> setAutoRetry(bool enabled) async {
    final resp = await _mutatingRequest('set_auto_retry', {'enabled': enabled});
    if (resp?['success'] != true) return false;
    await ref.read(settingsProvider.notifier).setAutoRetry(enabled);
    return true;
  }

  Future<SessionStats?> getSessionStats() async {
    final resp = await _request('get_session_stats');
    final data = resp?['data'] as Map?;
    if (resp?['success'] != true || data == null) return null;
    final tokens = data['tokens'] as Map?;
    // pi 的 cost 是纯数值;兼容旧的 {total} 形状
    final cost = data['cost'];
    final costTotal = cost is num
        ? cost.toDouble()
        : ((cost is Map ? cost['total'] : null) as num?)?.toDouble();
    final usage = ContextUsage.fromMap(data['contextUsage']);
    if (usage != null && !_disposed) {
      state = state.copyWith(contextUsage: usage);
    }
    return SessionStats(
      inputTokens: tokens?['input'] as int?,
      outputTokens: tokens?['output'] as int?,
      totalTokens: tokens?['total'] as int?,
      costTotal: costTotal,
      contextTokens: usage?.tokens,
      contextWindow: usage?.contextWindow,
      contextPercent: usage?.percent,
    );
  }

  /// 手动压缩会话上下文(耗时较长,走 4 分钟超时)。
  ///
  /// [instructions] 对应 pi 的 CompactOptions.customInstructions。
  Future<bool> compact({String? instructions}) async {
    final extra = instructions == null || instructions.trim().isEmpty
        ? const <String, dynamic>{}
        : {'instructions': instructions.trim()};
    final resp = await _mutatingRequest(
      'compact',
      extra,
      const Duration(seconds: 240),
    );
    return resp?['success'] == true;
  }

  /// headless 源没有快照级 contextUsage,在回合结束后补拉一次统计。
  void _scheduleContextRefresh() {
    if (state.selectedSource?.isHeadless != true) return;
    unawaited(getSessionStats());
  }

  /// Export the session as HTML on the desktop; returns the file path.
  Future<String?> exportHtml() async {
    final resp = await _mutatingRequest(
      'export_html',
      const {},
      const Duration(seconds: 60),
    );
    if (resp?['success'] != true) return null;
    return (resp?['data'] as Map?)?['path'] as String?;
  }

  /// Re-apply persisted preferences (model / thinking / auto-retry) that pi
  /// does not itself restore for a fresh process.
  Future<void> _applyPreferences({_ConnectionScope? connectionScope}) async {
    if (!_connectionScopeCurrent(connectionScope)) return;
    final settings = ref.read(settingsProvider);
    final provider = settings.modelProvider;
    final modelId = settings.modelId;
    if (provider != null &&
        modelId != null &&
        modelId != state.modelId &&
        _sourceSupports('set_model')) {
      final resp = await _mutatingRequest('set_model', {
        'provider': provider,
        'modelId': modelId,
      });
      if (!_connectionScopeCurrent(connectionScope)) return;
      final model = resp?['data'] as Map?;
      if (resp?['success'] == true) {
        state = state.copyWith(
          modelId: model?['id'] as String? ?? modelId,
          modelName: model?['name'] as String? ?? state.modelName,
        );
      }
    }
    final level = settings.thinkingLevel;
    if (level != null &&
        level != state.thinkingLevel &&
        _sourceSupports('set_thinking_level')) {
      final resp = await _mutatingRequest('set_thinking_level', {
        'level': level,
      });
      if (!_connectionScopeCurrent(connectionScope)) return;
      if (resp?['success'] == true) {
        state = state.copyWith(thinkingLevel: level);
      }
    }
    if (_connectionScopeCurrent(connectionScope) &&
        _sourceSupports('set_auto_retry')) {
      await _mutatingRequest('set_auto_retry', {'enabled': settings.autoRetry});
    }
  }

  // -- connection plumbing ----------------------------------------------------

  Future<bool> _open({_OpenRoute route = _OpenRoute.configured}) async {
    final generation = _connectionGeneration;
    await _closeConn();
    if (generation != _connectionGeneration ||
        _disposed ||
        _intentionalDisconnect) {
      return false;
    }
    final creds = _creds;
    if (creds == null) return false;

    final conn = PiConnection();
    _conn = conn;
    _msgSub = conn.messages.listen(_handleEvent);
    _statusSub = conn.status.listen(_onConnStatus);
    bool currentAttempt() =>
        generation == _connectionGeneration &&
        !_disposed &&
        !_intentionalDisconnect &&
        identical(_conn, conn);

    // auto 首次仍给 LAN 完整 12s 握手窗口;一旦回落 P2P 成功,后续重连
    // 直接走 P2P。LAN 恢复由独立匿名探测负责,不再阻塞主连接重建。
    final p2p = _p2p;
    final transport = _transport;
    final stickyP2p =
        route == _OpenRoute.configured &&
        transport == DeviceTransport.auto &&
        _preferP2pInAuto;
    final tryLan = switch (route) {
      _OpenRoute.lanOnly => true,
      _OpenRoute.p2pOnly => false,
      _OpenRoute.configured => transport != DeviceTransport.p2p && !stickyP2p,
    };
    final tryP2p =
        p2p != null &&
        switch (route) {
          _OpenRoute.lanOnly => false,
          _OpenRoute.p2pOnly => true,
          _OpenRoute.configured => transport != DeviceTransport.lan,
        };

    PiActiveTransport? openedVia;
    final hello = await LanNetworkBinding.serializeOpen<Map<String, dynamic>?>(
      () async {
        if (!currentAttempt()) return null;
        Map<String, dynamic>? hello;
        if (tryLan) {
          hello = await LanNetworkBinding.withWifiBinding(
            () => conn.connect(
              host: creds.host,
              port: creds.port,
              token: creds.token,
              clientId: creds.clientId,
              capabilities: const [msgDeltaCapability],
              timeout: const Duration(seconds: 12),
            ),
            host: creds.host,
          );
          if (!currentAttempt()) {
            await conn.disconnectAndWait(notify: false);
            return null;
          }
          if (hello != null) openedVia = PiActiveTransport.lan;
        }
        if (hello == null && tryP2p && currentAttempt()) {
          final settings = ref.read(settingsProvider.notifier);
          final channel = await P2pConnector(onLog: _logP2p).connect(
            rendezvousUrl: p2p.rendezvous,
            deviceId: p2p.deviceId,
            secret: p2p.secret,
            modeCache: (
              read: () async {
                final mode = await settings.p2pIceMode(p2p.deviceId);
                return switch (mode) {
                  'direct' => P2pIceMode.direct,
                  'relay' => P2pIceMode.relay,
                  _ => null,
                };
              },
              onSuccess: (mode) =>
                  settings.setP2pIceMode(p2p.deviceId, mode.name),
              onFailure: () => settings.failP2pIceMode(p2p.deviceId),
            ),
          );
          if (!currentAttempt()) {
            await channel?.close();
            await conn.disconnectAndWait(notify: false);
            return null;
          }
          if (channel != null) {
            hello = await conn.connectViaChannel(
              channel,
              token: creds.token,
              clientId: creds.clientId,
            );
            if (!currentAttempt()) {
              await conn.disconnectAndWait(notify: false);
              return null;
            }
            if (hello != null) openedVia = PiActiveTransport.p2p;
          }
        }
        return hello;
      },
    );
    if (!currentAttempt()) {
      await conn.disconnectAndWait(notify: false);
      return false;
    }
    final activeTransport = openedVia;
    if (hello == null || activeTransport == null) return false;

    _applyHello(hello);
    if (transport == DeviceTransport.auto) {
      if (activeTransport == PiActiveTransport.lan) {
        _preferP2pInAuto = false;
        _cancelLanRecovery();
      } else {
        _preferP2pInAuto = true;
      }
    }
    _activeTransport = activeTransport;
    state = state.copyWith(activeTransport: activeTransport);
    _logP2p(
      'transport_open{route:${activeTransport.name},policy:${route.name},'
      'sticky:$_preferP2pInAuto}',
    );
    return true;
  }

  void _applyHello(Map<String, dynamic> hello) {
    _lastHelloFrame = hello;
    final version = hello['version'] as int? ?? 1;
    final hubId = hello['hubId'] as String?;
    _hubV2 = version >= 2 && hubId != null;
    if (_hubV2) {
      _clearAllLeases();
      state = state.copyWith(hubId: hubId);
    } else {
      state = state.copyWith(
        sessionId: hello['sessionId'] as String?,
        cwd: hello['cwd'] as String?,
      );
    }
  }

  bool get _shouldRecoverLan =>
      !_disposed &&
      !_intentionalDisconnect &&
      _transport == DeviceTransport.auto &&
      _preferP2pInAuto &&
      _activeTransport == PiActiveTransport.p2p &&
      _creds != null &&
      _p2p != null;

  bool get _transportSwitchBusy =>
      state.status == PiConnStatus.connected &&
      (state.isStreaming || _pending.isNotEmpty);

  void _cancelLanRecovery() {
    _lanRecoveryTimer?.cancel();
    _lanRecoveryTimer = null;
  }

  void _scheduleLanRecovery({Duration? delay, bool replace = false}) {
    if (!_shouldRecoverLan) {
      _cancelLanRecovery();
      return;
    }
    if (_lanRecoveryTimer?.isActive == true) {
      if (!replace) return;
      _lanRecoveryTimer?.cancel();
    }
    _lanRecoveryTimer = Timer(delay ?? _lanRecoveryInterval, () {
      _lanRecoveryTimer = null;
      unawaited(_attemptLanRecovery());
    });
  }

  Future<void> _attemptLanRecovery() async {
    if (!_shouldRecoverLan) return;
    if (_lanProbeInFlight ||
        _transportSwitchInFlight ||
        _reconnectInFlight ||
        _transportSwitchBusy) {
      _scheduleLanRecovery(delay: _lanRecoveryBusyDelay, replace: true);
      return;
    }
    final creds = _creds;
    if (creds == null) return;
    final generation = _connectionGeneration;
    final expectedHubId = state.hubId;
    final probe = PiConnection();
    Map<String, dynamic>? hello;
    _lanProbeInFlight = true;
    try {
      hello = await LanNetworkBinding.serializeOpen<Map<String, dynamic>?>(
        () async {
          if (generation != _connectionGeneration || !_shouldRecoverLan) {
            return null;
          }
          return LanNetworkBinding.withWifiBinding(
            host: creds.host,
            () => probe.connect(
              host: creds.host,
              port: creds.port,
              token: creds.token,
              // 稳定 clientId 会让 bridge 踢掉正在工作的 P2P 连接。
              // 匿名探测握手后立刻关闭,只验证 LAN 路由与鉴权。
              clientId: null,
              timeout: _lanProbeTimeout,
            ),
          );
        },
      );
    } catch (_) {
      hello = null;
    } finally {
      await probe.disconnectAndWait(notify: false);
      _lanProbeInFlight = false;
    }

    if (generation != _connectionGeneration || !_shouldRecoverLan) return;
    final probeHubId = hello?['hubId'] as String?;
    final wrongHub = expectedHubId != null && probeHubId != expectedHubId;
    if (hello == null || wrongHub) {
      _scheduleLanRecovery(replace: true);
      if (state.status != PiConnStatus.connected &&
          !_reconnectInFlight &&
          !_transportSwitchInFlight) {
        _scheduleReconnect();
      }
      return;
    }
    if (_transportSwitchBusy) {
      _scheduleLanRecovery(delay: _lanRecoveryBusyDelay, replace: true);
      return;
    }
    _logP2p('lan_recovery_probe{success:true,hubId:$probeHubId}');
    await _switchToLan(generation);
  }

  Future<void> _switchToLan(int generation) async {
    if (generation != _connectionGeneration || !_shouldRecoverLan) return;
    if (_transportSwitchInFlight ||
        _reconnectInFlight ||
        _transportSwitchBusy) {
      _scheduleLanRecovery(delay: _lanRecoveryBusyDelay, replace: true);
      return;
    }

    _transportSwitchInFlight = true;
    _cancelLanRecovery();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopHealthMonitor();
    var connectionRestored = false;
    try {
      state = state.copyWith(
        status: PiConnStatus.connecting,
        sessionPhase: SyncPhase.connecting,
        clearError: true,
      );
      bool lanOk;
      try {
        lanOk = await _open(route: _OpenRoute.lanOnly);
      } catch (_) {
        lanOk = false;
      }
      if (generation != _connectionGeneration || _intentionalDisconnect) {
        return;
      }
      if (lanOk) {
        connectionRestored = true;
        state = state.copyWith(status: PiConnStatus.connected);
        await _initializeAfterConnect(generation);
        return;
      }

      // 探测与正式建链之间仍可能发生网络竞态。LAN 失败就立刻恢复 P2P,
      // 粘滞标记保持不变,用户不会因后台优化永久掉线。
      bool p2pOk;
      try {
        p2pOk = await _open(route: _OpenRoute.p2pOnly);
      } catch (_) {
        p2pOk = false;
      }
      if (generation != _connectionGeneration || _intentionalDisconnect) {
        return;
      }
      if (p2pOk) {
        connectionRestored = true;
        state = state.copyWith(status: PiConnStatus.connected);
        await _initializeAfterConnect(generation);
        return;
      }
      state = state.copyWith(
        status: PiConnStatus.connecting,
        sessionPhase: SyncPhase.offline,
      );
    } finally {
      final connectionStillOpen =
          connectionRestored &&
          state.status == PiConnStatus.connected &&
          _conn?.isOpen == true;
      _transportSwitchInFlight = false;
      if (generation == _connectionGeneration && !_intentionalDisconnect) {
        if (!connectionStillOpen) _scheduleReconnect();
        _scheduleLanRecovery();
      }
    }
  }

  Future<void> _closeConn() async {
    _clearAllLeases();
    _syncGeneration++;
    _activeSyncGeneration = 0;
    _bufferedSourceEvents.clear();
    final messageSub = _msgSub;
    final statusSub = _statusSub;
    final conn = _conn;
    _msgSub = null;
    _statusSub = null;
    _conn = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pending.clear();
    final statusCancel = statusSub?.cancel();
    final messageCancel = messageSub?.cancel();
    await statusCancel;
    await messageCancel;
    await conn?.disconnectAndWait(notify: false);
  }

  void _onConnStatus(PiConnStatus status) {
    if (_disposed) return;
    if (_intentionalDisconnect || !state.hasSession) return;
    if (status == PiConnStatus.disconnected || status == PiConnStatus.failed) {
      _stopHealthMonitor();
      state = state.copyWith(
        status: PiConnStatus.connecting,
        sessionPhase: SyncPhase.offline,
      );
      _scheduleReconnect();
    }
  }

  /// 指数退避:min(30s, 1s·2^attempt) × jitter(0.8–1.2)。
  void _scheduleReconnect() {
    if (_disposed ||
        _reconnectInFlight ||
        _transportSwitchInFlight ||
        _reconnectTimer?.isActive == true) {
      return;
    }
    final baseSeconds = math.min(
      30.0,
      math.pow(2, _reconnectAttempt).toDouble(),
    );
    final jitter = 0.8 + _jitterRandom.nextDouble() * 0.4;
    _reconnectAttempt++;
    _reconnectTimer = Timer(
      Duration(milliseconds: (baseSeconds * jitter * 1000).round()),
      () {
        _reconnectTimer = null;
        unawaited(_attemptReconnect());
      },
    );
  }

  void _scheduleReconnectAfterContention() {
    if (_disposed ||
        _intentionalDisconnect ||
        _reconnectInFlight ||
        _transportSwitchInFlight ||
        _reconnectTimer?.isActive == true) {
      return;
    }
    _reconnectTimer = Timer(_lanRecoveryBusyDelay, () {
      _reconnectTimer = null;
      unawaited(_attemptReconnect());
    });
  }

  Future<void> _attemptReconnect() async {
    final generation = _connectionGeneration;
    if (_disposed ||
        _intentionalDisconnect ||
        _creds == null ||
        _reconnectInFlight) {
      return;
    }
    if (_transportSwitchInFlight) return;
    if (_lanProbeInFlight) {
      _scheduleReconnectAfterContention();
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectInFlight = true;
    bool ok;
    try {
      ok = await _open();
    } catch (_) {
      ok = false;
    } finally {
      _reconnectInFlight = false;
    }
    if (generation != _connectionGeneration ||
        _disposed ||
        _intentionalDisconnect) {
      return;
    }
    if (!ok) {
      _scheduleReconnect();
      return;
    }
    _reconnectAttempt = 0;
    // hasSession 必须一起置真。首连失败后是这条路径把连接建起来的,若只置
    // status,_onConnStatus 开头的 `!state.hasSession` 守卫会继续拦着,之后
    // 真掉线又不会重连 —— 等于把首连失败的设备永久留在「一次性连接」状态。
    state = state.copyWith(status: PiConnStatus.connected, hasSession: true);
    await _initializeAfterConnect(generation);
  }

  /// App 回前台:若状态不是 connected,或最后一个 pong 已经过期,跳过退避
  /// 立即重连。不能只信状态字段:后台 isolate 暂停时 socket 可能已被 hub 清掉,
  /// 但 onDone 尚未得到调度。
  void onAppResumed() {
    if (_disposed) return;
    if (_intentionalDisconnect || _creds == null || !state.hasSession) return;
    if (_shouldRecoverLan) {
      _scheduleLanRecovery(delay: Duration.zero, replace: true);
    }
    final lastPong = _lastPongAt;
    final connectionFresh =
        state.status == PiConnStatus.connected &&
        _conn?.isOpen == true &&
        lastPong != null &&
        DateTime.now().difference(lastPong) <=
            _healthInterval * 2 + const Duration(seconds: 5);
    if (connectionFresh) {
      _healthTick();
      return;
    }
    state = state.copyWith(status: PiConnStatus.connecting);
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(_attemptReconnect());
  }

  /// 网络接口发生变化(WiFi↔蜂窝切换、重新入网)。
  ///
  /// 与 [onAppResumed] 的区别:切网时 app 一直在前台,不会有生命周期回调。
  /// 而旧连接此时已经死了 —— 但对端和本地都还不知道:
  /// - ICE consent freshness 要 5~10s 才判定 disconnected;
  /// - 健康心跳要 2 个周期(30s+)才判半开。
  /// 期间用户看到的就是"卡住不动"。拿到即时信号后主动重连能省掉这段空等。
  ///
  /// 注意不能无脑重连:切网事件在某些机型上会连发数次(WiFi 掉→蜂窝起→
  /// WiFi 回),每次都推倒重连反而更慢。所以先探活,确实死了才重连。
  void onNetworkChanged(String reason) {
    if (_disposed) return;
    if (_intentionalDisconnect || _creds == null || !state.hasSession) return;
    if (_shouldRecoverLan) {
      _scheduleLanRecovery(delay: Duration.zero, replace: true);
    }
    _logP2p('network_changed{reason:$reason,status:${state.status.name}}');
    // 已经在连了就不打断:重复推倒会把退避计数器清零并反复重建 PeerConnection。
    if (state.status == PiConnStatus.connecting) return;
    final lastPong = _lastPongAt;
    final connectionFresh =
        state.status == PiConnStatus.connected &&
        _conn?.isOpen == true &&
        lastPong != null &&
        DateTime.now().difference(lastPong) <= _healthInterval;
    if (connectionFresh) {
      // 看起来还活着:立刻探一次活。真死了心跳路径会在下个周期收口,
      // 不必在这里就推倒一条可能仍然可用的连接。
      _healthTick();
      return;
    }
    // 旧连接大概率已随接口消失而失效:立即重连,跳过退避。
    state = state.copyWith(status: PiConnStatus.connecting);
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(_attemptReconnect());
  }

  // -- connection health ------------------------------------------------------

  static const _healthInterval = Duration(seconds: 15);

  void _startHealthMonitor() {
    _stopHealthMonitor();
    _lastPongAt = DateTime.now();
    _healthTimer = Timer.periodic(_healthInterval, (_) => _healthTick());
  }

  void _stopHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _lastPongAt = null;
  }

  void _healthTick() {
    if (_disposed) return;
    final conn = _conn;
    if (conn == null || !conn.isOpen) return;
    final lastPong = _lastPongAt;
    // 连续 2 个周期没有 pong → 视为半开连接,主动断开触发重连。
    if (lastPong != null &&
        DateTime.now().difference(lastPong) >
            _healthInterval * 2 + const Duration(seconds: 5)) {
      _stopHealthMonitor();
      // disconnect() 会通过 status stream 触发 _onConnStatus;这里不能再手动
      // 调一次,否则同一次超时会重复增长退避并重排计时器。
      conn.disconnect();
      return;
    }
    conn.send({
      'type': 'bridge_ping',
      'echo': DateTime.now().millisecondsSinceEpoch,
    });
    // 每个健康周期打一行传输层遥测。慢链路上这是区分「网络背压」与
    // 「应用排队」的唯一依据:buffered 高说明卡在 SCTP,normalQ 高说明
    // 卡在应用队列,drainBps 说明实测吞吐到底是多少。
    unawaited(
      conn.transportTelemetry().then((line) {
        if (line != null && !_disposed) _logP2p(line);
      }),
    );
  }

  /// hub 存下新快照后的提示帧。这是卡死客户端的兜底自愈通道:
  /// 只要 baseSeq 领先于本地已应用序号,就重新同步一次。
  void _onSourceSnapshotAnnounced(Map<String, dynamic> event) {
    if (event['sourceId'] != state.selectedSourceId) return;
    final epoch = event['epoch'];
    final baseSeq = event['baseSeq'];
    final currentEpoch = state.sourceEpoch;
    final epochChanged =
        epoch is String && currentEpoch != null && epoch != currentEpoch;
    final stale = baseSeq is int && baseSeq < state.lastSourceSeq;
    // 快照提示和事件流走同一条 socket,但重同步/重连会让旧提示晚到。
    // 旧的「压缩中」绝不能盖回已经应用的 compaction_end。
    if (epochChanged || stale) {
      if (epochChanged) _scheduleSourceResync(reason: 'announce');
      return;
    }
    if (event['isStreaming'] is bool) {
      _snapshotStreaming = event['isStreaming'] as bool;
      _syncStreamingFlag();
    }
    if (event['isCompacting'] is bool &&
        event['isCompacting'] != state.isCompacting) {
      state = state.copyWith(isCompacting: event['isCompacting'] as bool);
    }
    final behind = (baseSeq as int? ?? 0) > state.lastSourceSeq;
    final leafMoved = event['leafId'] is String && event['leafId'] != _leafId;
    final sessionMoved =
        event['sessionId'] is String && event['sessionId'] != state.sessionId;
    if (behind || leafMoved || sessionMoved) {
      _scheduleSourceResync(reason: 'announce');
    }
  }

  void _onBridgePong(Map<String, dynamic> event) {
    if (_disposed) return;
    _lastPongAt = DateTime.now();
    final echo = event['echo'];
    if (echo is int) {
      final rtt = DateTime.now().millisecondsSinceEpoch - echo;
      if (rtt >= 0 && rtt < 60000) {
        state = state.copyWith(rttMs: rtt);
      }
    }
  }

  void _tearDown() {
    _cancelLanRecovery();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _resyncTimer?.cancel();
    _resyncTimer = null;
    _sourceLossTimer?.cancel();
    _sourceLossTimer = null;
    _uiRequestTimer?.cancel();
    _uiRequestTimer = null;
    _stopHealthMonitor();
    unawaited(_closeConn());
  }

  // -- sync -------------------------------------------------------------------

  String get _leafStorageKey {
    final scope = _hubV2
        ? '${state.hubId}:${state.selectedSourceId}'
        : 'legacy';
    return 'sess.leafId:$scope:${state.sessionId}';
  }

  String? get _cursorStorageKey {
    final hubId = state.hubId;
    final sourceId = state.selectedSourceId;
    if (hubId == null || sourceId == null) return null;
    return 'hub.cursor:$hubId:$sourceId';
  }

  Future<void> _loadLeafId({
    _ConnectionScope? connectionScope,
    int? syncGeneration,
    String? sourceId,
  }) async {
    bool current() => _syncWorkCurrent(
      connectionScope: connectionScope,
      syncGeneration: syncGeneration,
      sourceId: sourceId,
    );
    if (state.sessionId == null || !current()) return;
    final key = _leafStorageKey;
    final prefs = await SharedPreferences.getInstance();
    if (!current()) return;
    _leafId = prefs.getString(key);
  }

  Future<void> _saveLeafId({
    _ConnectionScope? connectionScope,
    int? syncGeneration,
    String? sourceId,
  }) async {
    bool current() => _syncWorkCurrent(
      connectionScope: connectionScope,
      syncGeneration: syncGeneration,
      sourceId: sourceId,
    );
    if (!current()) return;
    final leafId = _leafId;
    if (state.sessionId == null || leafId == null) return;
    final key = _leafStorageKey;
    final prefs = await SharedPreferences.getInstance();
    if (!current()) return;
    await prefs.setString(key, leafId);
  }

  Future<HubCursor?> _loadHubCursor() async {
    final key = _cursorStorageKey;
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(key);
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      return decoded is Map ? HubCursor.fromMap(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveHubCursor({
    _ConnectionScope? connectionScope,
    int? syncGeneration,
    String? expectedSourceId,
  }) async {
    bool current() => _syncWorkCurrent(
      connectionScope: connectionScope,
      syncGeneration: syncGeneration,
      sourceId: expectedSourceId,
    );
    if (!current()) return;
    final key = _cursorStorageKey;
    final hubId = state.hubId;
    final sourceId = state.selectedSourceId;
    final epoch = state.sourceEpoch;
    final seq = state.lastSourceSeq;
    final sessionId = state.sessionId;
    final leafId = _leafId;
    final store = _syncStore;
    final sourceKey = _syncSourceKey;
    if (key == null || hubId == null || sourceId == null || epoch == null) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!current()) return;
    await prefs.setString(
      key,
      jsonEncode(
        HubCursor(
          hubId: hubId,
          sourceId: sourceId,
          sourceEpoch: epoch,
          seq: seq,
        ).toMap(),
      ),
    );
    if (!current()) return;
    // cursor v2:附带 entryId rebase 锚点。bridge 重启(hubId 必变)后
    // 事件游标作废,但可从最后一条 entry 正向补齐,历史不用重拉。
    if (store != null && sourceKey != null) {
      unawaited(
        store.commitEventWithCursor(
          sourceKey: sourceKey,
          cursor: <String, dynamic>{
            'v': 2,
            'hubId': hubId,
            'sourceId': sourceId,
            'sourceEpoch': epoch,
            'seq': seq,
            'sessionId': sessionId,
            'lastEntryId': leafId,
            'savedAt': DateTime.now().millisecondsSinceEpoch,
          },
        ),
      );
    }
  }

  /// cursor v2(含 lastEntryId rebase 锚点):按 sessionId 主键查,
  /// bridge/桌面重启后仍可命中。
  Future<Map<String, dynamic>?> _loadHubCursorV2() async {
    final sourceKey = _syncSourceKey;
    if (sourceKey == null) return null;
    return _syncStore?.loadCursor(sourceKey);
  }

  Future<void> _syncSelectedSource({
    bool forceFull = false,
    bool reconcile = false,
    int? generation,
    _ConnectionScope? connectionScope,
  }) async {
    if (!_hubV2 || state.selectedSourceId == null) return;
    final sourceId = state.selectedSourceId;
    final gen = generation ?? ++_syncGeneration;
    _activeSyncGeneration = gen;
    // 每个 await 之后都要确认自己还是最新一代、source 没换且连接没被替代。
    bool stale() =>
        _disposed ||
        gen != _syncGeneration ||
        !_connectionScopeCurrent(connectionScope) ||
        state.selectedSourceId != sourceId;
    try {
      final cursor = forceFull ? null : await _loadHubCursor();
      if (stale()) return;
      if (cursor != null && cursor.sourceId == state.selectedSourceId) {
        state = state.copyWith(
          sourceEpoch: cursor.sourceEpoch,
          lastSourceSeq: cursor.seq,
        );
      }
      // bridge 重启(hubId 变)时本地事件游标必然失配:加载 v2 拿 rebase
      // 锚点,并先用本地缓存渲染首屏,再对账(慢链路下 10s 内可见上次内容)。
      String? rebaseEntryId;
      if (cursor == null && !forceFull) {
        final v2 = await _loadHubCursorV2();
        if (stale()) return;
        final anchor = v2?['lastEntryId'];
        if (anchor is String && anchor.isNotEmpty) rebaseEntryId = anchor;
        final store = _syncStore;
        final sourceKey = _syncSourceKey;
        if (store != null && sourceKey != null) {
          final cached = await store.loadRecentEntries(sourceKey);
          if (stale()) return;
          if (cached.isNotEmpty) {
            _resetConversation(reason: 'cache-render');
            for (final entry in cached) {
              _ingestEntry(entry);
            }
            _emit();
          }
        }
      }
      final resp = await _request('hub_sync', {
        if (cursor != null) 'cursor': cursor.toMap(),
      });
      if (stale()) return;
      final data = resp?['data'] as Map?;
      if (resp?['success'] != true || data == null) {
        // 旧实现在这里静默 return:初次同步失败后只有 seq 缺口/epoch 变化
        // 才会再来一次 —— 链路差到事件也排在后面时,会话永远空白。
        _logP2p('hub_sync failed(success=${resp?['success']}),schedule resync');
        state = state.copyWith(sessionPhase: SyncPhase.degraded);
        _scheduleSourceResync(reason: 'sync-failed');
        return;
      }
      final mode = data['mode'];
      if (mode == 'snapshot') {
        final snapshot = data['snapshot'];
        if (snapshot is Map) {
          final snapshotEntries = snapshot['entries'] as List? ?? const [];
          final anchorHit =
              rebaseEntryId != null &&
              snapshotEntries.any((e) => e is Map && e['id'] == rebaseEntryId);
          if (rebaseEntryId == null || anchorHit) {
            // 分页元数据要跟着快照一起进替换事务 —— 见 _applyHubSnapshot。
            _applyHubSnapshot(
              snapshot,
              reconcile: reconcile || anchorHit,
              entriesHasMore: data['entriesHasMore'] == true,
              entriesOldestId: data['entriesOldestId'] is String
                  ? data['entriesOldestId'] as String
                  : null,
            );
          } else {
            // rebase:快照头与本地历史接不上 —— 只取会话状态,
            // entries 从锚点正向补齐,历史不整段重拉。
            final stateData = snapshot['state'];
            if (stateData is Map) {
              _applyStateData(Map<String, dynamic>.from(stateData));
            }
            state = state.copyWith(
              sourceEpoch: snapshot['epoch'] as String?,
              lastSourceSeq: snapshot['baseSeq'] as int? ?? 0,
            );
            // rebase 分支自己不做替换事务,分页元数据在这里补。
            // (走 _applyHubSnapshot 的那一支已经在事务内设好,见其文档。)
            final oldest = data['entriesOldestId'];
            if (data['entriesHasMore'] == true &&
                oldest is String &&
                oldest.isNotEmpty) {
              _oldestEntryId = oldest;
              state = state.copyWith(hasMoreHistory: true);
            }
            unawaited(
              _rebaseFromEntry(
                rebaseEntryId,
                generation: gen,
                connectionScope: connectionScope,
              ),
            );
          }
        }
      } else if (mode == 'rpc') {
        await _sync(
          forceFull: forceFull,
          connectionScope: connectionScope,
          syncGeneration: gen,
          sourceId: sourceId,
        );
        if (stale()) return;
        state = state.copyWith(
          sourceEpoch: data['sourceEpoch'] as String?,
          lastSourceSeq: data['baseSeq'] as int? ?? 0,
        );
      }
      final events =
          (data['events'] as List?)
              ?.whereType<Map>()
              .map((event) => Map<String, dynamic>.from(event))
              .toList() ??
          const <Map<String, dynamic>>[];
      events.sort((a, b) => _hubSeq(a).compareTo(_hubSeq(b)));
      for (final event in events) {
        _applySequencedEvent(event, fromSync: true);
      }
      // hub 明确告知已连续 → 补齐成功,重置退避与提示
      if (data['continuous'] == true) {
        _resyncAttempt = 0;
        _gapNoticeShown = false;
      }
      // bridge 的事件重放页有 64KiB 硬上限:手机离开很久后回来,cursor 之后
      // 那段事件本身可能几 MB,一帧发不下。被截断时 bridge 置 eventsTruncated,
      // 这里必须立刻带着已推进的 cursor 再来一轮 —— 否则客户端会误以为已经
      // 追平,后面那段事件永远不会被应用。
      if (data['eventsTruncated'] == true && events.isNotEmpty) {
        await _saveHubCursor(
          connectionScope: connectionScope,
          syncGeneration: gen,
          expectedSourceId: sourceId,
        );
        if (stale()) return;
        if (_eventPageRounds++ < _maxEventPageRounds) {
          _logP2p(
            'events_truncated{remaining:${data['eventsRemaining']},'
            'round:$_eventPageRounds}',
          );
          // 交回当前一代继续翻:cursor 已前进,下一轮取后续事件页。
          await _syncSelectedSource(
            reconcile: reconcile,
            generation: gen,
            connectionScope: connectionScope,
          );
          return;
        }
        _logP2p('events_truncated: 连续翻页超过 $_maxEventPageRounds 轮,改走全量');
        _eventPageRounds = 0;
        await _syncSelectedSource(
          forceFull: true,
          generation: gen,
          connectionScope: connectionScope,
        );
        return;
      }
      _eventPageRounds = 0;
      state = state.copyWith(sessionPhase: SyncPhase.synced);
      unawaited(
        _reconcilePendingOps(
          connectionScope: connectionScope,
          syncGeneration: gen,
          sourceId: sourceId,
        ),
      );
      await _saveHubCursor(
        connectionScope: connectionScope,
        syncGeneration: gen,
        expectedSourceId: sourceId,
      );
    } finally {
      if (gen == _syncGeneration) {
        _activeSyncGeneration = 0;
        _drainBufferedEvents();
      }
    }
  }

  /// bridge 重启后的 entryId rebase:从本地最后一条 entry 正向分页补齐,
  /// 历史不整段重拉。失败回退全量快照。
  Future<void> _rebaseFromEntry(
    String anchorEntryId, {
    int? generation,
    _ConnectionScope? connectionScope,
  }) async {
    final gen = generation ?? _syncGeneration;
    final sourceId = state.selectedSourceId;
    bool stale() =>
        _disposed ||
        gen != _syncGeneration ||
        !_connectionScopeCurrent(connectionScope) ||
        state.selectedSourceId != sourceId;
    String? since = anchorEntryId;
    String? tipId;
    var guard = 0;
    while (!stale()) {
      if (guard++ > 200) {
        _logP2p('rebase: 翻页超过 200 次,中止');
        return;
      }
      final resp = await _request('get_entries', {
        'since': ?since,
        'forward': true,
        // 与 bridge 的 MAX_ENTRIES_PAGE_BYTES 硬上限对齐(96KiB)。
        // 50KB/s 下单页约 2s,能连续翻页而不撞请求超时;要更大也会被
        // bridge 端 clamp 回去,这里保持双端一致便于对账。
        'limitBytes': maxEntriesPageBytes,
        'tipId': ?tipId,
      });
      if (stale()) return;
      final data = resp?['data'] as Map?;
      if (resp?['success'] != true || data == null) {
        _logP2p('rebase: get_entries 失败,回退全量快照');
        await _syncSelectedSource(
          forceFull: true,
          generation: gen,
          connectionScope: connectionScope,
        );
        return;
      }
      tipId = data['tipId'] as String?;
      final entries = data['entries'] as List? ?? const [];
      for (final entry in entries) {
        if (entry is Map) _ingestEntry(Map<String, dynamic>.from(entry));
      }
      _emit();
      if (data['hasMore'] != true) break;
      since = data['nextSinceId'] as String?;
      if (since == null) break;
    }
    if (!stale()) {
      _logP2p('rebase: entryId 锚点补齐完成');
      state = state.copyWith(sessionPhase: SyncPhase.synced);
      unawaited(
        _saveHubCursor(
          connectionScope: connectionScope,
          syncGeneration: gen,
          expectedSourceId: sourceId,
        ),
      );
    }
  }

  /// 应用一份 hub 快照。
  ///
  /// 这是一个**替换事务**:清空 → 灌入 → 一次 `_emit()`。中途绝不发布中间
  /// 状态 —— 清空之后、灌回之前只要发布一次,撞上流式 token 就会让界面变成
  /// 「只剩正在生成的那一条」。
  ///
  /// [entriesHasMore] / [entriesOldestId] 是桥给的**权威**分页元数据(桥只发
  /// entries 的尾巴,更早的留在会话文件里)。它们必须在这个事务内、跟条目
  /// 一起落地:游标与 `hasMoreHistory` 成对才有意义。只设标志不设游标 →
  /// 「加载更早」永远转圈;只设游标不设标志 → 那一行根本不出现。
  void _applyHubSnapshot(
    Map<dynamic, dynamic> snapshot, {
    bool reconcile = false,
    bool entriesHasMore = false,
    String? entriesOldestId,
  }) {
    final stateData = snapshot['state'];
    final leafId = snapshot['leafId'] as String?;
    final sessionId = stateData is Map
        ? stateData['sessionId'] as String?
        : null;
    // 补齐式重同步:同一会话、且新 leaf 已在本地历史里 → 就地对账,不清空对话。
    // 否则(换会话/换分支)才重建,避免每秒清屏重渲染。
    final sameBranch =
        reconcile &&
        sessionId != null &&
        sessionId == state.sessionId &&
        leafId != null &&
        _seenEntryIds.contains(leafId);

    final entries = snapshot['entries'] as List? ?? const [];
    // staged replacement:空快照不许清列表。
    //
    // 这条路径原来是「先清空,再灌 entries」。快照没带 entries(字段缺失被
    // ?? const [] 兜成空、或桥在会话切换间隙返回了空批)时,列表就被清成
    // 空白 —— 而且这里**自己不安排补货**,只能等下次碰巧触发同步,严重时
    // 一直空到重启 App。这就是「消息列表莫名其妙没了」。
    //
    // full-sync 路径此前已按同样思路加固过(先拉到完整数据再替换,失败保留
    // 旧列表 + 退避重试),但 hub v2 快照这条漏了。
    //
    // 判据要严:只在「同一会话、本地有内容、快照却是空的」时保留。换会话
    // /换分支时快照本就该是空的(那是真的没消息),这时候必须照常清空,
    // 否则会把上一个会话的消息留在界面上冒充新会话的内容。
    final sameSession = sessionId != null && sessionId == state.sessionId;
    if (entries.isEmpty && sameSession && _items.isNotEmpty) {
      _logP2p('快照 entries 为空但本地有 ${_items.length} 条(同一会话),保留现有列表并调度重同步');
      if (stateData is Map) {
        _applyStateData(Map<String, dynamic>.from(stateData));
      }
      // 游标一并保留:本地内容没动,往前翻的能力也不该被这次空快照抹掉。
      _emit();
      // 走 scheduleSyncRecovery 这个缝隙而不是直接调 _scheduleSourceResync:
      // 两者在生产里等价,但缝隙可以被测试桩接住 —— 「空快照必须排补货」
      // 这条约束才断言得到。
      scheduleSyncRecovery(reason: 'empty-snapshot');
      return;
    }

    if (!sameBranch) _resetConversation(reason: 'snapshot-rebuild');
    if (stateData is Map) {
      _applyStateData(Map<String, dynamic>.from(stateData));
    }
    for (final entry in entries) {
      if (entry is Map) _ingestEntry(Map<String, dynamic>.from(entry));
    }
    // 快照可能不带 leafId(协议允许 null)。别用 null 覆盖已知的 leaf,
    // 否则随后的 session_tree 会被误判成"分支变了"。
    if (leafId != null && leafId.isNotEmpty) _leafId = leafId;
    // 分页游标与标志:成对落地,且只认桥给的权威元数据。
    //
    // 重建路径上 _resetConversation 已经把 _oldestEntryId 清成 null,所以
    // 这里必须重新设 —— 否则「加载更早」要么不出现(标志假),要么一直转圈
    // (标志真但游标空)。
    // 对账路径(sameBranch)不动既有游标:那次快照只是补齐尾部,凭它把往前
    // 翻的能力抹掉是错的;除非桥这次带了权威元数据。
    final cursorFromBridge =
        entriesOldestId != null && entriesOldestId.isNotEmpty
        ? entriesOldestId
        : null;
    if (!sameBranch || cursorFromBridge != null) {
      if (cursorFromBridge != null) _oldestEntryId = cursorFromBridge;
      state = state.copyWith(
        hasMoreHistory: entriesHasMore && _oldestEntryId != null,
      );
    }
    state = state.copyWith(
      loadingEarlier: false,
      sourceEpoch: snapshot['epoch'] as String?,
      lastSourceSeq: snapshot['baseSeq'] as int? ?? 0,
    );
    _emit();
    // 快照 entries 落盘:下次打开(尤其 bridge 重启后)先渲染缓存再对账。
    final store = _syncStore;
    final sourceKey = _syncSourceKey;
    if (store != null && sourceKey != null) {
      final rows = <({String id, int? seq, Map<String, dynamic> payload})>[
        for (final entry in entries)
          if (entry is Map && entry['id'] is String)
            (
              id: entry['id'] as String,
              seq: null,
              payload: Map<String, dynamic>.from(entry),
            ),
      ];
      if (rows.isNotEmpty) {
        // 覆盖后立刻修剪:pruneEntries 此前没有任何生产调用点,持久化历史
        // 实际上是无界的。20MB 量级会话累积几场就能吃光手机存储。
        unawaited(
          store
              .replaceEntries(sourceKey, rows)
              .then(
                (_) => store.pruneEntries(
                  sourceKey,
                  SyncStore.maxPersistedEntries,
                ),
              ),
        );
      }
    }
    final inFlight = snapshot['inFlightMessage'];
    _sawInFlightMessage = inFlight is Map;
    if (inFlight is Map) {
      _onMessageUpdate({
        'type': 'message_update',
        'message': Map<String, dynamic>.from(inFlight),
      });
    }
    _syncStreamingFlag();
  }

  // -- 流式状态派生 -------------------------------------------------------------

  bool _snapshotStreaming = false;
  bool _eventStreaming = false;
  bool _sawInFlightMessage = false;

  void _syncStreamingFlag() {
    final next = deriveStreaming(
      snapshotStreaming: _snapshotStreaming,
      eventStreaming: _eventStreaming,
      hasOpenAssistantBubble:
          _streamingAssistant != null && !_streamingAssistant!.complete,
      hasInFlightMessage: _sawInFlightMessage,
    );
    if (next != state.isStreaming) {
      state = state.copyWith(isStreaming: next);
    }
  }

  void _applyStateData(Map<String, dynamic> data) {
    final model = data['model'] as Map?;
    state = state.copyWith(
      modelId: model?['id'] as String?,
      modelName: model?['name'] as String?,
      thinkingLevel: data['thinkingLevel'] as String?,
      sessionName: data['sessionName'] as String?,
      sessionId: data['sessionId'] as String? ?? state.sessionId,
      cwd: data['cwd'] as String? ?? state.cwd,
      isCompacting: data['isCompacting'] as bool? ?? false,
      autoCompactionEnabled: data['autoCompactionEnabled'] as bool? ?? false,
      contextUsage: ContextUsage.fromMap(data['contextUsage']),
      pendingMessageCount: data['pendingMessageCount'] as int?,
      snapshotTruncated: data['snapshotTruncated'] as bool?,
    );
    _snapshotStreaming = data['isStreaming'] as bool? ?? false;
    _syncStreamingFlag();
  }

  Future<void> _sync({
    bool forceFull = false,
    _ConnectionScope? connectionScope,
    int? syncGeneration,
    String? sourceId,
  }) async {
    bool stale() => !_syncWorkCurrent(
      connectionScope: connectionScope,
      syncGeneration: syncGeneration,
      sourceId: sourceId,
    );
    if (stale()) return;
    final stateResp = await _request('get_state');
    if (stale()) return;
    if (stateResp != null && stateResp['success'] == true) {
      final data = stateResp['data'];
      if (data is Map) _applyStateData(Map<String, dynamic>.from(data));
    }

    if (_leafId == null) {
      await _loadLeafId(
        connectionScope: connectionScope,
        syncGeneration: syncGeneration,
        sourceId: sourceId,
      );
      if (stale()) return;
    }
    Map<String, dynamic>? entriesResp;
    var incremental = false;
    final leafId = forceFull ? null : _leafId;
    if (leafId != null) {
      entriesResp = await syncRequest('get_entries', {'since': leafId});
      if (stale()) return;
      incremental = entriesResp != null && entriesResp['success'] == true;
    }
    if (!incremental) {
      if (stale()) return;
      // staged replacement:先拉到完整数据再替换。「先清后拉」遇上网络抖动
      // 会把空白列表直接 emit 出去,且这条路径自己不安排补货 —— 列表一直
      // 空到下次碰巧触发重同步(严重时只能重启 App)。失败就保留现有列表,
      // 交给退避重试兜底。
      final fullResp = await syncRequest('get_entries');
      if (stale()) return;
      if (fullResp == null || fullResp['success'] != true) {
        _logP2p(
          'get_entries 全量失败(success=${fullResp?['success']}),保留现有列表并调度重试',
        );
        scheduleSyncRecovery(reason: 'entries-fetch-failed');
        return;
      }
      _resetConversation(reason: 'full-sync');
      entriesResp = fullResp;
    }

    final data = entriesResp?['data'] as Map?;
    final entries = data?['entries'] as List? ?? const [];
    for (final entry in entries) {
      if (entry is Map) _ingestEntry(Map<String, dynamic>.from(entry));
    }
    // 桥对每一批 entries 都封了字节上限,更早的留在桥上按需取。
    final more = data?['hasMore'] == true;
    if (more) {
      final oldest = data?['oldestId'];
      if (oldest is String && oldest.isNotEmpty) _oldestEntryId = oldest;
    }
    // 增量路径(since)不该动 hasMoreHistory:它取的是 leaf 之后的新消息,
    // 与「更早的历史还在不在」无关,覆盖掉会让「加载更早」凭空消失。
    state = state.copyWith(hasMoreHistory: incremental ? null : more);
    _emit();
    await _saveLeafId(
      connectionScope: connectionScope,
      syncGeneration: syncGeneration,
      sourceId: sourceId,
    );
  }

  /// 往前补一段历史。
  ///
  /// 桥只给手机发 entries 的尾巴(全量快照实测到过 10.27MB,而手机套接字缓冲上限
  /// 是 2MB,巨包会让下一次发送触发 close(1013),表现成约 2 秒一轮地重连)。
  /// 更早的仍在桥上,靠 `get_entries` 的 `before` 游标取回来。
  Future<bool> loadEarlierHistory() async {
    final cursor = _oldestEntryId;
    if (cursor == null || state.loadingEarlier || !state.hasMoreHistory) {
      return false;
    }
    state = state.copyWith(loadingEarlier: true);
    try {
      final resp = await _request('get_entries', {'before': cursor});
      final data = resp?['data'] as Map?;
      if (resp?['success'] != true || data == null) {
        // 取不到就别把按钮永久留在那儿骗人:游标可能已经随分支切换失效了。
        state = state.copyWith(loadingEarlier: false, hasMoreHistory: false);
        return false;
      }
      final entries = data['entries'] as List? ?? const [];
      // 头插:这些是更早的消息,追加到尾部会让时间线直接反过来。
      _prependAt = 0;
      try {
        for (final entry in entries) {
          if (entry is Map) _ingestEntry(Map<String, dynamic>.from(entry));
        }
      } finally {
        _prependAt = null;
      }
      final oldest = data['oldestId'];
      if (oldest is String && oldest.isNotEmpty) _oldestEntryId = oldest;
      state = state.copyWith(
        loadingEarlier: false,
        hasMoreHistory: data['hasMore'] == true,
      );
      _emit();
      return entries.isNotEmpty;
    } catch (_) {
      state = state.copyWith(loadingEarlier: false);
      return false;
    }
  }

  int _lateResponseCount = 0;

  /// 本地同步存储(entries/cursor/op_log)。打开失败为 null,降级纯内存。
  SyncStore? _syncStore;

  /// 自上次修剪以来新增的 entry 数。
  ///
  /// 每条增量都 prune 会让长会话在流式输出期间反复扫全表;按批修剪即可 ——
  /// 上限本身是软目标,超出几百条不影响正确性,只影响存储占用。
  int _entriesSincePrune = 0;
  static const _pruneEveryEntries = 200;

  /// 增量写入路径的按批修剪。与快照覆盖路径一起,补上 pruneEntries 此前
  /// 完全没有生产调用点的缺口(持久化历史实际无界)。
  Future<void> _maybePruneEntries(SyncStore store, String sourceKey) async {
    if (++_entriesSincePrune < _pruneEveryEntries) return;
    _entriesSincePrune = 0;
    try {
      await store.pruneEntries(sourceKey, SyncStore.maxPersistedEntries);
    } catch (_) {
      // 修剪失败不影响正确性:下一批还会再试。
    }
  }

  /// 持久化主键:与 hubId/sourceId 解耦 —— bridge 重启 hubId 必变、
  /// 桌面 pi 重启 sourceId 必变,只有 sessionId 跨重启稳定。
  String? get _syncSourceKey => state.sessionId ?? state.selectedSourceId;

  void _logP2p(String message) {
    debugPrint('[p2p] $message');
  }

  /// 慢速 P2P 上 hub_sync 等大数据响应的合法传输时间远超固定 20s。
  /// 这些请求改用进度型超时:通道仍有字节推进(分片级活动)就续命,
  /// 连续无进展才判超时 —— 固定 20s 是"心跳正常但数据永远不来"的根因。
  static const _progressTimeoutTypes = <String>{
    'hub_sync',
    'get_entries',
    'hub_open_session',
    'hub_select_source',
  };
  static const _noProgressTimeout = Duration(seconds: 45);

  /// 请求总时长硬上限。进度型超时只能避免"慢但在动"被误杀,不能当作
  /// 无上限等待:一个永远满不了的传输(对端反复重发同一页)会一直有数据进度,
  /// 却永远不完成。按 50KB/s 估,20MB 会话大约 7 分钟,给 10 分钟余量。
  static const _hardRequestTimeout = Duration(minutes: 10);

  /// 测试缝隙:get_entries 走这里,便于脚本化失败/成功。
  @visibleForTesting
  Future<Map<String, dynamic>?> syncRequest(
    String type, [
    Map<String, dynamic> extra = const {},
  ]) => _request(type, extra);

  /// 测试缝隙:同步失败后的兜底重试(生产:退避重同步;测试:记录后手动驱动)。
  @visibleForTesting
  void scheduleSyncRecovery({required String reason}) =>
      _scheduleSourceResync(reason: reason);

  /// 测试缝隙:直接驱动一次 _sync。
  @visibleForTesting
  Future<void> debugSync({bool forceFull = false}) =>
      _sync(forceFull: forceFull);

  /// 测试缝隙:设置本地 leaf(决定 _sync 走增量还是全量)。
  @visibleForTesting
  set debugLeafId(String? value) => _leafId = value;

  /// 测试缝隙:直接喂一份 hub 快照。
  @visibleForTesting
  void debugApplyHubSnapshot(
    Map<dynamic, dynamic> snapshot, {
    bool reconcile = false,
    bool entriesHasMore = false,
    String? entriesOldestId,
  }) => _applyHubSnapshot(
    snapshot,
    reconcile: reconcile,
    entriesHasMore: entriesHasMore,
    entriesOldestId: entriesOldestId,
  );

  /// 测试缝隙:直接喂一条轻量快照通知,验证压缩状态与序号防倒灌。
  @visibleForTesting
  void debugApplySourceSnapshotAnnouncement(Map<String, dynamic> event) =>
      _onSourceSnapshotAnnounced(event);

  /// 测试缝隙:直接喂一条 pi 事件,验证压缩成功/失败/中断的 UI 收口。
  @visibleForTesting
  void debugApplyPiEvent(Map<String, dynamic> event) => _applyPiEvent(event);

  /// 测试缝隙:读往前分页游标(断言「标志为真时游标必须存在」)。
  @visibleForTesting
  String? get debugOldestEntryId => _oldestEntryId;

  /// 测试缝隙:构造「桥说过还有更早的」这个前置状态。
  @visibleForTesting
  void debugSetHasMoreHistory(bool value) =>
      state = state.copyWith(hasMoreHistory: value);

  /// 测试缝隙:构造「正在加载更早」这个前置状态。
  @visibleForTesting
  void debugSetLoadingEarlier(bool value) =>
      state = state.copyWith(loadingEarlier: value);

  /// 测试缝隙:同时设回游标和标志 —— 模拟 entriesHasMore 分支做的事。
  ///
  /// 成对设置是这条路径的正确性要求:只设一个就是那个卡住状态。
  @visibleForTesting
  void debugSetEarlierCursor(String oldestId, {required bool hasMore}) {
    _oldestEntryId = oldestId;
    state = state.copyWith(hasMoreHistory: hasMore);
  }

  /// 测试缝隙:驱动一次流式 assistant 更新(复现「清空窗口撞上 token」)。
  @visibleForTesting
  void debugMessageUpdate({required String timestamp, required String text}) {
    _onMessageUpdate({
      'message': {
        'role': 'assistant',
        'timestamp': timestamp,
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });
    _emit();
  }

  /// 测试缝隙:观察每一次对外发布的 items 长度。
  ///
  /// 「只剩正在生成的那一条」这类事故的关键不在最终态,而在**中间发布**:
  /// 清空之后、灌回之前只要发布一次就会被 UI 看到。只断言最终 items 长度
  /// 是抓不到的,必须记录发布序列。
  @visibleForTesting
  List<int> get debugEmittedLengths => List.unmodifiable(_emittedLengths);
  final List<int> _emittedLengths = [];

  /// 测试缝隙:把条目灌进本地历史(构造「本地已有内容」的前置状态)。
  ///
  /// 跟着 emit 一次 —— 真实的 entry_appended 路径就是 ingest + emit,
  /// 只 ingest 不 emit 会得到「_items 有内容但 state.items 是空的」这种
  /// 现实中不存在的状态。
  @visibleForTesting
  void debugIngestEntry(Map<String, dynamic> entry) {
    _ingestEntry(entry);
    _emit();
  }

  Future<Map<String, dynamic>?> _request(
    String type, [
    Map<String, dynamic> extra = const {},
    Duration? timeout,
  ]) {
    final conn = _conn;
    if (conn == null || !conn.isOpen) return Future.value(null);
    final id = 'r${++_reqId}';
    final completer = Completer<Map<String, dynamic>?>();
    _pending[id] = completer;
    conn.send({'id': id, 'type': type, ...extra});

    // 端到端 RPC 耗时。这是唯一能反映**传输时间**的量:bridge 侧日志里的
    // ms 只是组包时间(实测 12ms),不含线上传输。慢链路诊断必须看这个数 ——
    // 128KiB 首屏在 50KB/s 上要 2.6s,在服务端看却只有 12ms。
    final started = DateTime.now();
    void logDuration(Map<String, dynamic>? value) {
      if (!_measuredRpcTypes.contains(type)) return;
      final ms = DateTime.now().difference(started).inMilliseconds;
      _logP2p('rpc_done{type:$type,id:$id,ok:${value != null},ms:$ms}');
    }

    if (timeout == null && _progressTimeoutTypes.contains(type)) {
      final result = _withProgressTimeout(id, type, conn, completer);
      return result.then((value) {
        logDuration(value);
        return value;
      });
    }
    return completer.future
        .timeout(
          timeout ?? const Duration(seconds: 20),
          onTimeout: () {
            _pending.remove(id);
            _logP2p('rpc_timeout{type:$type,id:$id}');
            return null;
          },
        )
        .then((value) {
          logDuration(value);
          return value;
        });
  }

  /// 需要记录端到端耗时的请求类型(大数据路径 + 会话打开路径)。
  static const _measuredRpcTypes = <String>{
    'hub_sync',
    'get_entries',
    'hub_open_session',
    'hub_select_source',
    'hub_list_sessions',
  };

  /// 请求级进度型超时。
  ///
  /// 三个关键点(对应三个已确认的缺陷):
  /// 1. 进度源是 `conn.dataProgressTicks` 而不是 `conn.lastActivityAt`。后者会被
  ///    周期 bridge_pong 刷新,于是一个卡死的大 RPC 只要心跳正常就永远不超时。
  /// 2. 加总时长硬上限:否则"一直有进度但永远不完成"仍会无限等待。
  /// 3. 四条终止路径(成功/断线/无进度/硬超时)全部 cancel watchdog。原实现只在
  ///    completer 完成时 cancel,而 watchdog 自己先完成 result 后,原请求可能永远
  ///    不完成 —— Timer 就每 5 秒醒一次永不停止。
  Future<Map<String, dynamic>?> _withProgressTimeout(
    String id,
    String type,
    PiConnection conn,
    Completer<Map<String, dynamic>?> completer,
  ) {
    final result = Completer<Map<String, dynamic>?>();
    final startedAt = DateTime.now();
    var lastTicks = conn.dataProgressTicks;
    var lastProgressAt = startedAt;
    Timer? watchdog;

    void finish(Map<String, dynamic>? value) {
      // 单一收口:无论哪条终止路径,Timer 都在这里被 cancel。
      watchdog?.cancel();
      watchdog = null;
      if (!result.isCompleted) result.complete(value);
    }

    watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (result.isCompleted) {
        // 防御:result 已完成但 Timer 还活着(不应发生),立即自杀。
        watchdog?.cancel();
        watchdog = null;
        return;
      }
      // 连接已换/已死:立即放行,不等满无进展时长。
      if (!identical(_conn, conn) || !conn.isOpen) {
        _pending.remove(id);
        _logP2p('rpc_abort_disconnected{type:$type,id:$id}');
        finish(null);
        return;
      }
      final now = DateTime.now();
      final ticks = conn.dataProgressTicks;
      if (ticks != lastTicks) {
        lastTicks = ticks;
        lastProgressAt = now;
      }
      final total = now.difference(startedAt);
      if (total > _hardRequestTimeout) {
        _pending.remove(id);
        _logP2p(
          'rpc_hard_timeout{type:$type,id:$id,totalMs:${total.inMilliseconds}}',
        );
        finish(null);
        return;
      }
      final silence = now.difference(lastProgressAt);
      if (silence > _noProgressTimeout) {
        _pending.remove(id);
        _logP2p(
          'rpc_no_progress{type:$type,id:$id,silenceMs:${silence.inMilliseconds}}',
        );
        finish(null);
      }
    });

    completer.future.then(finish, onError: (Object _) => finish(null));
    return result.future;
  }

  // -- event handling -----------------------------------------------------------

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'response':
        _handleResponse(event);
        return;
      case 'hub_sources_changed':
        _onSourcesChanged(event);
        return;
      case 'hub_owner_changed':
        _onOwnerChanged(event);
        return;
      case 'hub_source_offline':
        unawaited(refreshSources());
        return;
      case 'hub_source_snapshot':
        _onSourceSnapshotAnnounced(event);
        return;
      case 'hub_sessions_changed':
        _onSessionsChanged(event);
        return;
      case 'hub_session_died':
        _onSessionDied(event);
        return;
      case 'hub_control_moved':
        _onControlMoved(event);
        return;
      case 'bridge_ping':
        // bridge 侧活性探测(真 ping):对称回 pong,双向半开检测才成立。
        _conn?.send(<String, dynamic>{
          'type': 'bridge_pong',
          't': DateTime.now().millisecondsSinceEpoch,
          if (event['echo'] != null) 'echo': event['echo'],
        });
        return;
      case 'bridge_pong':
        _onBridgePong(event);
        return;
    }
    if (event['_hub'] is Map) {
      _applySequencedEvent(event);
      return;
    }
    _applyPiEvent(event);
  }

  void _onSessionsChanged(Map<String, dynamic> event) {
    final raw = event['sessions'] as List?;
    if (raw == null) return;
    final parsed = [
      for (final entry in raw)
        if (entry is Map) HubSession.fromMap(entry),
    ];
    _notifyFinishedBackgroundSessions(parsed);
    state = state.copyWith(sessions: parsed);
  }

  /// 后台会话跑完了就记一笔 —— 并发会话最直接的收益。
  /// 真正弹不弹通知由 NotificationController 按前后台状态决定。
  void _notifyFinishedBackgroundSessions(List<HubSession> next) {
    final selected = state.selectedSourceId;
    final wasStreaming = {
      for (final entry in state.sessions)
        if (entry.streaming) entry.sessionId,
    };
    for (final entry in next) {
      if (entry.streaming || entry.sourceId == selected) continue;
      if (!wasStreaming.contains(entry.sessionId)) continue;
      state = state.copyWith(
        backgroundFinishTick: state.backgroundFinishTick + 1,
        backgroundFinishName: entry.displayName,
      );
      return;
    }
  }

  void _onSessionDied(Map<String, dynamic> event) {
    final sourceId = event['sourceId'] as String?;
    if (sourceId != null) _dropLease(sourceId);
    unawaited(refreshSources());
    if (sourceId == state.selectedSourceId) {
      state = state.copyWith(transientNotice: '会话进程已退出,发送消息会重新启动它');
    }
  }

  /// 另一端强制取走了驱动权:作废本地租约,下一条命令会自动重取。
  void _onControlMoved(Map<String, dynamic> event) {
    final sourceId = event['sourceId'] as String?;
    if (sourceId == null) return;
    if (event['youAreDriving'] == true) return;
    _dropLease(sourceId);
    if (sourceId == state.selectedSourceId) {
      state = state.copyWith(sessionBusyElsewhere: true);
    }
  }

  void _onSourcesChanged(Map<String, dynamic> event) {
    final raw = event['sources'] as List?;
    if (raw == null) return;
    handleSourcesChanged([
      for (final source in raw)
        if (source is Map) SourceInfo.fromMap(source),
    ]);
  }

  /// 推送目录变化的核心判定,抽成公共方法让测试直接喂列表。
  @visibleForTesting
  void handleSourcesChanged(List<SourceInfo> parsed) {
    final previous = state.selectedSource;
    final selected = parsed
        .where((source) => source.id == state.selectedSourceId)
        .firstOrNull;
    if (selected == null && state.selectedSourceId != null) {
      // 推送目录少了选中源 ≠ 它真死了:registry 是内存态,bridge 重启后各
      // 桌面 pi 要懒重注册,缺席可能只是重注册还没轮到它。列表照更、选择
      // 留住,宽限复核确认没了才清选择+跟随 —— 不能把用户从还活着的
      // 会话上拽走(一次传输抖动就换台,就是「会话自己切来切去」。)
      _scheduleSourceLossCheck(previous);
      state = state.copyWith(sources: parsed);
      return;
    }
    // 选中源还在(或本就无选中):撤销可能挂着的失联复核。
    _sourceLossTimer?.cancel();
    _sourceLossTimer = null;
    if (sourceEpochChanged(previous, selected)) {
      // 换 epoch 只是事件流重来了;hub 现在会保留租约,所以这里也不丢
      _leafId = null;
      _bufferedSourceEvents.clear();
      _resetConversation(reason: 'epoch-changed');
      state = state.copyWith(
        sources: parsed,
        cwd: selected?.cwd,
        sessionId: selected?.sessionId,
        sessionName: selected?.sessionName,
        sourceEpoch: selected?.epoch,
        lastSourceSeq: 0,
      );
      _emit();
      unawaited(_syncSelectedSource(forceFull: true));
      return;
    }
    state = state.copyWith(
      sources: parsed,
      isDriving: selected?.ownedByYou ?? false,
      sessionBusyElsewhere:
          selected != null && selected.ownerPresent && !selected.ownedByYou,
      cwd: selected?.cwd,
      sessionId: selected?.sessionId,
      sessionName: selected?.sessionName,
      sourceEpoch: selected?.epoch,
    );
    if (selected != null && !selected.ownedByYou) _dropLease(selected.id);
    if (previous?.connected == false && selected?.connected == true) {
      unawaited(_syncSelectedSource(forceFull: true));
    }
    // 桌面源判死:桌面 TUI 不像 headless 会话那样能被发消息唤醒(进程已被冻住
    // 或退出),继续停在它身上永远等不到事件。
    if (selected != null && selected.isDesktop && !selected.connected) {
      unawaited(followLiveDesktop(parsed, selected));
    }
  }

  /// 选中源从推送目录里消失后的宽限复核:2.5s 后按权威 list 再对一次账,
  /// 仍缺席才当真死亡处理(清选择、走跟随)。复核期间若有推送把源带回来,
  /// [handleSourcesChanged] 会撤销这个定时器。
  void _scheduleSourceLossCheck(SourceInfo? previous) {
    _sourceLossTimer?.cancel();
    _sourceLossTimer = Timer(const Duration(milliseconds: 2500), () async {
      _sourceLossTimer = null;
      if (_disposed) return;
      final goneId = state.selectedSourceId;
      if (goneId == null) return;
      final fresh = await refreshSources();
      if (_disposed || state.selectedSourceId != goneId) return;
      if (fresh.any((source) => source.id == goneId)) return; // 虚惊一场
      _dropLease(goneId);
      state = state.copyWith(clearSource: true);
      // 源被 hub 摘掉了(桌面 pi 关掉/长期离线回收)。留在空选中态等于卡死,
      // 有替代窗口就跟过去(写不写偏好由 followLiveDesktop 自己决定)。
      unawaited(followLiveDesktop(fresh, previous));
    });
  }

  /// 选中的桌面窗口没了之后,自动跟到还活着的那个窗口。
  ///
  /// 电脑上 Ctrl+Z 挂起再开一个 pi 时,新进程的 sourceId 里嵌着新的 PID,必然与
  /// 旧的不同。以前只有 [_initializeAfterConnect] 会做回退选源,所以运行期换窗口
  /// 时 App 就一直钉在那个已经死掉的源上,要杀掉重开才恢复。
  @visibleForTesting
  Future<void> followLiveDesktop(
    List<SourceInfo> sources,
    SourceInfo? previous,
  ) async {
    if (_disposed || !_hubV2) return;
    final target = pickFollowTarget(sources, previous);
    if (target == null || target.id == state.selectedSourceId) return;
    final persist = shouldPersistAutoSwitch(
      target,
      ref.read(settingsProvider).preferredSessionId,
    );
    if (!await selectSource(target.id, persist: persist)) return;
    if (_disposed) return;
    _write(state.copyWith(transientNotice: '原窗口已断开,已切到 ${target.label}'));
  }

  /// 自动换源(跟随/回退)能不能写偏好:只有「同会话」窗口才配 —— 用户在
  /// 电脑上 fg 回了原会话,PID 变了,绑定的 sourceId 该更新。跨会话命中只是
  /// 代打,写进去的话跳一次就把偏好改错一次,之后每次恢复都落错窗口。
  @visibleForTesting
  static bool shouldPersistAutoSwitch(
    SourceInfo target,
    String? preferredSession,
  ) => target.sessionId != null && target.sessionId == preferredSession;

  /// 旧桌面源失联后该跟到哪个窗口。
  ///
  /// 优先同一会话(用户在电脑上 `fg` 回原会话,或另开一个跑同一会话),否则只在
  /// 剩一个候选时才跟随 —— 多个候选时擅自挑一个,等于替用户改了他正在看的会话。
  ///
  /// 抽成纯函数是因为挑错窗口会把用户的对话换掉,这个判断值得单独钉住。
  @visibleForTesting
  static SourceInfo? pickFollowTarget(
    List<SourceInfo> sources,
    SourceInfo? previous,
  ) {
    final candidates = sources
        .where((source) => source.isDesktop && source.connected)
        .toList();
    if (candidates.isEmpty) return null;
    final previousSession = previous?.sessionId;
    if (previousSession != null) {
      final sameSession = candidates
          .where((source) => source.sessionId == previousSession)
          .firstOrNull;
      if (sameSession != null) return sameSession;
    }
    return candidates.length == 1 ? candidates.single : null;
  }

  void _onOwnerChanged(Map<String, dynamic> event) {
    final raw = event['source'];
    if (raw is! Map) return;
    final updated = SourceInfo.fromMap(raw);
    final list = [
      for (final source in state.sources)
        if (source.id == updated.id) updated else source,
    ];
    state = state.copyWith(
      sources: list,
      isDriving: updated.id == state.selectedSourceId
          ? updated.ownedByYou
          : state.isDriving,
      sessionBusyElsewhere: updated.id == state.selectedSourceId
          ? updated.ownerPresent && !updated.ownedByYou
          : state.sessionBusyElsewhere,
    );
    if (!updated.ownedByYou) _dropLease(updated.id);
  }

  int _hubSeq(Map<String, dynamic> event) {
    final hub = event['_hub'];
    return hub is Map ? hub['seq'] as int? ?? 0 : 0;
  }

  void _applySequencedEvent(
    Map<String, dynamic> event, {
    bool fromSync = false,
  }) {
    if (_activeSyncGeneration != 0 && !fromSync) {
      _bufferSourceEvent(event);
      return;
    }
    final hub = event['_hub'];
    if (hub is! Map) return;
    final sourceId = hub['sourceId'] as String?;
    final epoch = hub['sourceEpoch'] as String?;
    final seq = hub['seq'] as int?;
    final cursor = SourceCursor(
      sourceId: state.selectedSourceId,
      epoch: state.sourceEpoch,
      seq: state.lastSourceSeq,
    );
    switch (cursor.classify(sourceId: sourceId, epoch: epoch, seq: seq)) {
      case SourceApply.wrongSource:
      case SourceApply.duplicate:
        return;
      case SourceApply.epochChanged:
        // epoch 变了,缓冲这条已无意义(历史整体作废)
        _scheduleSourceResync(reason: 'epoch');
        return;
      case SourceApply.gap:
        // 采纳前进:先把能看到的显示出来,再后台补齐。
        // 旧实现在这里永久拒绝,导致客户端彻底卡死。
        _noteSyncGap();
        state = state.copyWith(sourceEpoch: epoch, lastSourceSeq: seq);
        _applyPiEvent(event);
        _scheduleSourceResync(reason: 'gap');
        unawaited(_saveHubCursor());
        _inOrderStreak = 0;
        return;
      case SourceApply.apply:
        state = state.copyWith(sourceEpoch: epoch, lastSourceSeq: seq);
        _applyPiEvent(event);
        // entry 型事件与游标同一事务落盘:游标永不先于数据,
        // 进程在两步之间被杀也不会出现"游标超前于缓存"的静默丢段。
        final appendedEntry = event['type'] == 'entry_appended'
            ? event['entry']
            : null;
        final store = _syncStore;
        final sourceKey = _syncSourceKey;
        if (appendedEntry is Map && store != null && sourceKey != null) {
          unawaited(
            store
                .commitEventWithCursor(
                  sourceKey: sourceKey,
                  entry: Map<String, dynamic>.from(appendedEntry),
                  entryId: appendedEntry['id'] as String?,
                  seq: seq,
                  epoch: epoch,
                  cursor: <String, dynamic>{
                    'v': 2,
                    'hubId': state.hubId,
                    'sourceId': sourceId,
                    'sourceEpoch': epoch,
                    'seq': seq,
                    'sessionId': state.sessionId,
                    'lastEntryId': _leafId,
                    'savedAt': DateTime.now().millisecondsSinceEpoch,
                  },
                )
                .then((_) => _maybePruneEntries(store, sourceKey)),
          );
        }
        unawaited(_saveHubCursor());
        if (++_inOrderStreak >= 32) {
          _inOrderStreak = 0;
          _resyncAttempt = 0;
        }
    }
  }

  static const _maxBufferedSourceEvents = 2048;

  void _bufferSourceEvent(Map<String, dynamic> event) {
    _bufferedSourceEvents.add(event);
    if (_bufferedSourceEvents.length > _maxBufferedSourceEvents) {
      _bufferedSourceEvents.removeRange(
        0,
        _bufferedSourceEvents.length - _maxBufferedSourceEvents,
      );
      _bufferOverflowed = true;
    }
  }

  void _drainBufferedEvents() {
    if (_disposed) {
      _bufferedSourceEvents.clear();
      return;
    }
    if (_bufferedSourceEvents.isEmpty) {
      if (_bufferOverflowed) {
        _bufferOverflowed = false;
        _scheduleSourceResync(reason: 'buffer-overflow');
      }
      return;
    }
    final buffered = [..._bufferedSourceEvents]
      ..sort((a, b) => _hubSeq(a).compareTo(_hubSeq(b)));
    _bufferedSourceEvents.clear();
    for (final event in buffered) {
      _applySequencedEvent(event, fromSync: true);
    }
    if (_bufferOverflowed) {
      _bufferOverflowed = false;
      _scheduleSourceResync(reason: 'buffer-overflow');
    }
  }

  void _noteSyncGap() {
    if (_gapNoticeShown) return;
    _gapNoticeShown = true;
    _addSystem('与电脑端有消息缺口,正在补齐…', SystemKind.warning);
  }

  /// 单飞 + 指数退避(250ms→8s, ±20% 抖动)。
  /// 旧实现每个被拒事件都触发一次全量重拉,峰值 ~40 次/秒。
  void _scheduleSourceResync({required String reason}) {
    if (_disposed || _resyncTimer != null) return;
    // 正在跑的那一轮不能顶替,但**也不能把请求丢掉**。
    //
    // 这里原来直接 return,于是「当前这轮同步的结果本身有问题、需要再来一次」
    // 的请求会被静默吞掉 —— 空快照守卫排的补货正是这种:它必然在一轮同步
    // 的执行过程中发出。丢了就等下一次碰巧的触发,列表在那之前一直是残缺的。
    if (_resyncRunning) {
      _pendingResyncReason ??= reason;
      return;
    }
    // 断线期间重同步只会空转失败:重连流程自己会触发首次同步。
    if (_conn?.isOpen != true) return;
    final base = math.min(8000, 250 * math.pow(2, _resyncAttempt).toInt());
    final delay = (base * (0.8 + _jitterRandom.nextDouble() * 0.4)).round();
    _resyncAttempt++;
    _logP2p('调度兜底重同步(reason=$reason, delay=${delay}ms, hub=$_hubV2)');
    _resyncTimer = Timer(Duration(milliseconds: delay), () async {
      _resyncTimer = null;
      _resyncRunning = true;
      try {
        // hub 模式走源级对账;直连模式重跑一次全量 _sync。
        if (_hubV2) {
          await _syncSelectedSource(reconcile: true);
        } else {
          await _sync(forceFull: true);
        }
      } finally {
        _resyncRunning = false;
        // 这一轮跑的时候被压下的请求,现在补上。
        final pending = _pendingResyncReason;
        if (pending != null) {
          _pendingResyncReason = null;
          _scheduleSourceResync(reason: pending);
        }
      }
    });
  }

  /// 会话树变了(任意一端回退/切分支)。
  ///
  /// 不去猜要删哪几条 —— 直接按新的 leaf 全量重建。回退在会话文件里是
  /// append-only 的"移动 leaf",本地增量推演一定会跟真实分支跑偏。
  void _onSessionTree(Map<String, dynamic> event) {
    // 桌面扩展归一化后带 leafId;pi 原生事件(未归一化的旧扩展、无头源
    // 直通)带的是 newLeafId。两个键都认 —— 手机 APK 和桌面扩展各自独立
    // 更新,哪侧旧都得能收敛。
    final explicit =
        event.containsKey('leafId') || event.containsKey('newLeafId');
    final raw = event['leafId'] ?? event['newLeafId'];
    final leaf = raw is String && raw.isNotEmpty ? raw : null;
    if (leaf == null) {
      // 显式给了空 leaf = 回到了根(目标消息的 parent 是根):同样是分支
      // 变了,必须重置重建。只有事件完全没带 leaf 字段(不该发生)才不清
      // —— 否则每条事件都触发一次清空+全量重同步,永远收敛不了。
      if (explicit) {
        _leafId = null;
        _resetConversation(reason: 'branch-fallback');
        _addSystem('会话已回退到另一个分支');
      }
      unawaited(_syncSelectedSource(forceFull: true));
      return;
    }
    if (leaf == _leafId) return;
    _leafId = leaf;
    _resetConversation(reason: 'branch-fallback');
    _addSystem('会话已回退到另一个分支');
    unawaited(_syncSelectedSource(forceFull: true));
  }

  /// 桌面端正在 fork/新建/切换会话:短暂离线不要拆掉界面。
  void _noteSessionTransition(Map<String, dynamic> event) {
    final reason = event['reason'];
    state = state.copyWith(
      transientNotice: switch (reason) {
        'fork' => '电脑端正在开新分支…',
        'switch' => '电脑端正在切换会话…',
        _ => '电脑端正在切换…',
      },
    );
  }

  void _applyPiEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'agent_start':
        _eventStreaming = true;
        _syncStreamingFlag();
      case 'agent_end':
        _eventStreaming = false;
        _snapshotStreaming = false;
        _sawInFlightMessage = false;
        _syncStreamingFlag();
        _scheduleContextRefresh();
      case 'agent_settled':
        _eventStreaming = false;
        _snapshotStreaming = false;
        _sawInFlightMessage = false;
        _syncStreamingFlag();
        // compaction_end 可能在断线窗口丢失;settled 是宿主确认所有自动压缩、
        // 重试和排队工作都结束的最终边界,不能让按钮永久停在停止态。
        if (state.isCompacting) state = state.copyWith(isCompacting: false);
        _scheduleContextRefresh();
      case 'extension_ui_answered':
        if (state.pendingUiRequest?.id == event['requestId']) {
          _clearUiRequest();
        }
      case 'message_start':
      case 'message_end':
        _onMessageBoundary(event);
      case 'message_update':
        _onMessageUpdate(event);
      case 'message_delta':
        _onMessageDelta(event);
      case 'tool_execution_start':
        _onToolStart(event);
      case 'tool_execution_update':
        _onToolUpdate(event);
      case 'tool_execution_end':
        _onToolEnd(event);
      case 'bash_execution_update':
        _onBashUpdate(event);
      case 'queue_update':
        state = state.copyWith(
          steeringQueue: _stringList(event['steering']),
          followUpQueue: _stringList(event['followUp']),
        );
      // 桌面 working-activity 插件的 Working 行镜像:手机灵动岛直接显示。
      case 'working_activity':
        final text = event['text'] as String?;
        if (text == null || text.isEmpty) {
          state = state.copyWith(clearActivity: true);
        } else {
          state = state.copyWith(activityStatus: text);
        }
      // pi 内部事件流用 compaction_start/compaction_end,而桌面 relay 的
      // emitBoundary 转发的是扩展钩子事件 session_before_compact/session_compact。
      // 两套名字都要认 —— 只认前者的话,桌面压缩时 app 一条提示都收不到。
      case 'compaction_start':
      case 'session_before_compact':
        if (!state.isCompacting) {
          state = state.copyWith(isCompacting: true);
          _addSystem('桌面端正在压缩上下文,可随时中断');
        }
      case 'compaction_end':
      case 'session_compact':
        final wasCompacting = state.isCompacting;
        state = state.copyWith(isCompacting: false);
        if (event['aborted'] == true) {
          if (wasCompacting) _addSystem('上下文压缩已中断');
          break;
        }
        final errorMessage = event['errorMessage'];
        if (errorMessage is String && errorMessage.isNotEmpty) {
          _addSystem('上下文压缩失败:$errorMessage', SystemKind.error);
          break;
        }
        final result = event['result'];
        if (result is Map<String, dynamic>) {
          final before = result['tokensBefore'];
          final after = result['estimatedTokensAfter'];
          _addSystem('上下文已压缩 ($before → ~$after tokens)');
        } else if (wasCompacting) {
          // session_compact 钩子事件没有 result 字段,至少给个收尾提示
          _addSystem('上下文压缩完成');
        }
      case 'auto_retry_start':
        _addSystem(
          '请求失败,自动重试 (${event['attempt']}/${event['maxAttempts']})',
          SystemKind.warning,
        );
      case 'auto_retry_end':
        if (event['success'] != true) {
          _addSystem(
            '重试失败: ${event['finalError'] ?? '未知错误'}',
            SystemKind.error,
          );
        }
      // 任意一端的回退(手机点、或电脑上直接跑 /tree)都会落到这里 ——
      // 两端走同一条路径重建,不各自本地改 items,这样才不会分叉。
      case 'session_tree':
        _onSessionTree(event);
      case 'pipilot_nav_result':
        if (event['ok'] != true) {
          _addSystem('回退失败: ${event['error'] ?? '未知错误'}', SystemKind.error);
        }
      case 'pipilot_session_transition':
        _noteSessionTransition(event);
      case 'pipilot_notice':
        final text = event['message'];
        if (text is String && text.isNotEmpty) _addSystem(text);
      case 'extension_error':
        _addSystem('扩展错误: ${event['error']}', SystemKind.error);
      case 'extension_ui_request':
        _onExtensionUi(event);
      case 'ask_user_question_request':
        _onAskRequest(event);
      case 'ask_user_question_retracted':
        // 电脑那侧已经接手(超时、断线、或已由其他客户端答完)。
        if (state.pendingAsk?.requestId == event['requestId']) _clearAsk();
      case 'entry_appended':
        final entry = event['entry'];
        if (entry is Map<String, dynamic>) {
          _ingestEntry(entry);
          _emit();
          _saveLeafId();
        }
      case 'bridge_dir_switched':
        // Another client switched the working directory; follow along.
        final sid = event['sessionId'] as String?;
        if (sid != null && sid != state.sessionId) {
          _eventStreaming = false;
          _snapshotStreaming = false;
          _sawInFlightMessage = false;
          state = state.copyWith(
            cwd: event['cwd'] as String?,
            sessionId: sid,
            isStreaming: false,
          );
          _leafId = null;
          _resetConversation(reason: 'session-changed');
          unawaited(
            _hubV2
                ? _syncSelectedSource(forceFull: true)
                : _sync(forceFull: true),
          );
        }
      case 'bridge_pi_start':
        _addSystem('pi 进程已启动');
      case 'bridge_pi_exit':
        _eventStreaming = false;
        _snapshotStreaming = false;
        _sawInFlightMessage = false;
        state = state.copyWith(isStreaming: false);
        _addSystem(
          'pi 进程退出 (code ${event['code']}),bridge 正在重启…',
          SystemKind.warning,
        );
      case 'bridge_error':
        _addSystem('bridge: ${event['error']}', SystemKind.error);
      case 'system_message':
        final kind = switch (event['level']) {
          'warning' => SystemKind.warning,
          'error' => SystemKind.error,
          _ => SystemKind.info,
        };
        final text = event['message'] ?? event['text'] ?? '';
        if (text is String && text.isNotEmpty) {
          _addSystem(text, kind);
        }
    }
  }

  void _handleResponse(Map<String, dynamic> event) {
    final id = event['id'] as String?;
    if (id != null && _pending.containsKey(id)) {
      _pending.remove(id)!.complete(event);
      return;
    }
    if (event['success'] == false) {
      _addSystem(
        '${event['command'] ?? 'command'} 失败: ${event['error']}',
        SystemKind.error,
      );
      return;
    }
    // 晚到的成功响应:请求已超时/被取消,不能再应用,但必须留痕 ——
    // 这是慢链路诊断的关键计数(旧实现静默丢弃)。
    if (id != null) {
      _lateResponseCount++;
      _logP2p(
        'late_response{id:$id,type:${event['command'] ?? event['type']},count:$_lateResponseCount}',
      );
    }
  }

  void _onMessageBoundary(Map<String, dynamic> event) {
    final message = event['message'];
    if (message is! Map<String, dynamic>) return;
    final role = message['role'];
    if (event['type'] == 'message_end') {
      // 流式结束,该键的 msg-delta 基线不再需要。
      _deltaBaseByKey.remove('assistant:${message['timestamp']}');
    }

    if (role == 'user') {
      _ingestMessage(message);
      _emit();
      return;
    }

    if (role == 'assistant') {
      if (event['type'] == 'message_start') {
        // 按时间戳键定位:若上一条的 message_end 在断层里丢了,
        // 旧实现会直接丢弃新气泡,导致后续内容全部覆盖到那条僵尸气泡上。
        final key = 'assistant:${message['timestamp']}';
        final existing = _itemsByKey[key];
        if (existing is AssistantItem) {
          _streamingAssistant = existing;
          _emit();
          return;
        }
        final current = _streamingAssistant;
        if (current != null && !current.complete) current.complete = true;
        final item = AssistantItem(key)..time = _timeFrom(message['timestamp']);
        _seenMsgKeys.add(key);
        _addItem(item);
        _streamingAssistant = item;
      } else {
        // message_end: finalize the streaming bubble
        final bubble = _streamingAssistant;
        final stopReason = message['stopReason'] as String?;
        if (bubble != null) {
          final (text, thinking) = _textAndThinking(message['content']);
          bubble.text = text;
          bubble.thinking = thinking;
          bubble.stopReason = stopReason;
          bubble.complete = true;
          // relay 实测时长优先于手机现算(手机只能算自己连着的窗口)。
          final relayMs = message['thinkingDurationMs'];
          if (relayMs is num && relayMs > 0) {
            bubble.thinkingDuration = Duration(milliseconds: relayMs.round());
            bubble.thinkingLenSeen = thinking.length;
          }
          _streamingAssistant = null;
          _noteAssistantError(item: bubble, stopReason: stopReason);
        } else {
          _ingestMessage(message);
        }
      }
      _emit();
    }
  }

  /// msg-delta 基线:每个流式 assistant 键最近一次完整 message。
  /// 键规则与 bridge 一致(assistant:{timestamp}),fork/压缩换键自动回退全量。
  final Map<String, Map<String, dynamic>> _deltaBaseByKey = {};

  /// 应用一条 message_delta:把增量追加到基线 message 的对应块上,
  /// 然后复用完整更新路径刷新气泡。基线缺失/块结构不符一律走重同步对账,
  /// 绝不把对不上的半截文本当成真内容显示。
  void _onMessageDelta(Map<String, dynamic> event) {
    final key = event['key'] as String?;
    final blockIndex = event['blockIndex'] as int?;
    final field = event['field'] as String?;
    final appendText = event['appendText'] as String?;
    if (key == null ||
        blockIndex == null ||
        field == null ||
        appendText == null) {
      return;
    }
    final base = _deltaBaseByKey[key];
    final content = base?['content'];
    if (base == null ||
        content is! List ||
        blockIndex < 0 ||
        blockIndex >= content.length) {
      _logP2p('msg-delta: 基线缺失 key=$key,走重同步对账');
      _scheduleSourceResync(reason: 'delta-base-missing');
      return;
    }
    final block = content[blockIndex];
    if (block is! Map || block[field] is! String) {
      _logP2p('msg-delta: 块结构不符 key=$key,走重同步对账');
      _scheduleSourceResync(reason: 'delta-block-invalid');
      return;
    }
    block[field] = (block[field] as String) + appendText;
    _onMessageUpdate({'message': base});
  }

  void _onMessageUpdate(Map<String, dynamic> event) {
    final message = event['message'];
    if (message is! Map<String, dynamic> || message['role'] != 'assistant') {
      return;
    }
    // msg-delta 基线:记录该流式键最近一次完整 message(FIFO 8 条)。
    final deltaKey = 'assistant:${message['timestamp']}';
    _deltaBaseByKey
      ..remove(deltaKey)
      ..[deltaKey] = message;
    while (_deltaBaseByKey.length > 8) {
      _deltaBaseByKey.remove(_deltaBaseByKey.keys.first);
    }
    var bubble = _streamingAssistant;
    if (bubble == null || bubble.complete) {
      // Joined mid-stream: synthesize the bubble from the partial message.
      final key = 'assistant:${message['timestamp']}';
      final existing = _itemsByKey[key];
      if (existing is AssistantItem) {
        bubble = existing;
      } else {
        bubble = AssistantItem(key)..time = _timeFrom(message['timestamp']);
        _seenMsgKeys.add(key);
        _addItem(bubble);
      }
      _streamingAssistant = bubble;
    }
    final (text, thinking) = _textAndThinking(message['content']);
    bubble.text = text;
    bubble.thinking = thinking;
    // 思考时长:只在 thinking **增长**时推进 —— 停下后定格,
    // 正文生成时间不会被拖进「思考了 Xs」。
    if (thinking.isNotEmpty && thinking.length != bubble.thinkingLenSeen) {
      bubble.thinkingStart ??= DateTime.now();
      bubble.thinkingDuration = DateTime.now().difference(
        bubble.thinkingStart!,
      );
      bubble.thinkingLenSeen = thinking.length;
    }
    // 流式 error delta:reason 为 aborted/error。message_end 可能随后到
    // 也可能在断层里丢掉,这里先标记并提示,避免错误被吞。
    final delta = event['assistantMessageEvent'];
    if (delta is Map<String, dynamic> && delta['type'] == 'error') {
      final reason = delta['reason'] as String?;
      bubble.stopReason = reason ?? 'error';
      _noteAssistantError(item: bubble, stopReason: bubble.stopReason);
    }
    _emit();
  }

  /// assistant 消息因 error/aborted 终止时发一条系统提示,避免静默失败。
  /// 用 _erroredAssistantKeys 去重,同一气泡只提示一次。
  final Set<String> _erroredAssistantKeys = {};
  void _noteAssistantError({AssistantItem? item, String? stopReason}) {
    if (item == null) return;
    final isErr = stopReason == 'error' || stopReason == 'aborted';
    if (!isErr) return;
    if (!_erroredAssistantKeys.add(item.key)) return; // 已提示
    final label = stopReason == 'aborted' ? '已中断' : '出错';
    _addSystem(
      '助手响应$label${item.text.isEmpty ? "(无输出)" : ""}',
      SystemKind.error,
    );
  }

  void _onToolStart(Map<String, dynamic> event) {
    final id = event['toolCallId'] as String?;
    if (id == null) return;
    var card = _toolCards[id];
    if (card == null) {
      card = ToolItem(
        'tool:$id',
        toolCallId: id,
        name: event['toolName'] as String? ?? 'tool',
      );
      _toolCards[id] = card;
      _addItem(card);
    }
    card.argsSummary = _summarizeArgs(event['args']);
    final args = event['args'];
    if (args is Map<String, dynamic>) card.args = args;
    card.done = false;
    _emit();
  }

  /// 惰性创建工具卡:若 tool_execution_start 在断层里丢了,
  /// 也不能把后续输出与结果一起吞掉(与 _onBashUpdate 的做法对齐)。
  ToolItem? _toolCardFor(Map<String, dynamic> event) {
    final id = event['toolCallId'] as String?;
    if (id == null) return null;
    return _toolCards.putIfAbsent(id, () {
      final item = ToolItem(
        'tool:$id',
        toolCallId: id,
        name: event['toolName'] as String? ?? 'tool',
      );
      _addItem(item);
      return item;
    });
  }

  void _onToolUpdate(Map<String, dynamic> event) {
    final card = _toolCardFor(event);
    if (card == null) return;
    card.output = _toolOutputFrom(event['partialResult']);
    _emit();
  }

  void _onToolEnd(Map<String, dynamic> event) {
    final card = _toolCardFor(event);
    if (card == null) return;
    card.output = _toolOutputFrom(event['result']);
    card.done = true;
    card.isError = event['isError'] == true;
    _emit();
  }

  void _onBashUpdate(Map<String, dynamic> event) {
    final id = event['id'] as String?;
    if (id == null) return;
    final card = _bashCards.putIfAbsent(id, () {
      final item = BashItem('bash:$id', command: '');
      _addItem(item);
      return item;
    });
    card.output += event['delta'] as String? ?? '';
    _emit();
  }

  void _onExtensionUi(Map<String, dynamic> event) {
    final method = event['method'] as String?;
    switch (method) {
      case 'notify':
        final kind = switch (event['notifyType']) {
          'warning' => SystemKind.warning,
          'error' => SystemKind.error,
          _ => SystemKind.info,
        };
        _addSystem('${event['message'] ?? ''}', kind);
      case 'select' || 'confirm' || 'input' || 'editor':
        final id = event['id'] as String?;
        // desktop TUI 的对话框不可拦截,仍提示回电脑处理
        if (id == null || state.selectedSource?.isDesktop == true) {
          _addSystem('扩展请求了 $method 交互,请在电脑上处理', SystemKind.warning);
          return;
        }
        _setUiRequest(
          UiRequest(
            id: id,
            method: method!,
            title: event['title'] as String? ?? '扩展请求输入',
            options: _stringList(event['options']),
            message: event['message'] as String?,
            placeholder: event['placeholder'] as String?,
            prefill: event['prefill'] as String?,
            timeoutMs: switch (event['timeout']) {
              final int t when t > 0 => t,
              _ => null,
            },
          ),
        );
      default:
        break; // setStatus/setWidget/setTitle/set_editor_text: ignore
    }
  }

  Timer? _uiRequestTimer;

  void _setUiRequest(UiRequest request) {
    _uiRequestTimer?.cancel();
    state = state.copyWith(pendingUiRequest: request);
    final timeoutMs = request.timeoutMs;
    if (timeoutMs != null) {
      // pi 侧超时会自行落默认值,本地到点撤掉卡片即可
      _uiRequestTimer = Timer(Duration(milliseconds: timeoutMs), () {
        if (state.pendingUiRequest?.id == request.id) _clearUiRequest();
      });
    }
  }

  void _clearUiRequest() {
    _uiRequestTimer?.cancel();
    _uiRequestTimer = null;
    if (state.pendingUiRequest != null) {
      state = state.copyWith(clearUiRequest: true);
    }
  }

  /// 应答扩展对话框(仅 owner;headless 源)。
  Future<bool> respondUi({
    String? value,
    bool? confirmed,
    bool cancelled = false,
  }) async {
    final request = state.pendingUiRequest;
    if (request == null) return false;
    final resp = await _mutatingRequest('extension_ui_response', {
      'uiRequestId': request.id,
      'value': ?value,
      'confirmed': ?confirmed,
      if (cancelled) 'cancelled': true,
    });
    if (resp?['success'] == true) {
      _clearUiRequest();
      return true;
    }
    return false;
  }

  // -- ask_user_question -------------------------------------------------------

  /// App 是否在前台。问卷认领的门控 —— 手机在口袋里时不能认领,
  /// 让电脑白等几分钟比立刻回落到插件自己的桌面问卷糟糕得多。
  bool _foreground = true;

  /// 由 AppLifecycleHandler 推过来。不在 notifier 里读
  /// `WidgetsBinding.instance.lifecycleState`:纯 `test()` 里没有 binding 会抛。
  bool get debugForeground => _foreground;

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    // 回到前台时手上正好有一份问卷,补一次认领(桥对重复认领是幂等的)。
    final ask = state.pendingAsk;
    if (value && ask != null) unawaited(_claimAsk(ask.requestId));
  }

  /// 电脑端转来一份问卷。
  void _onAskRequest(Map<String, dynamic> event) {
    final requestId = event['requestId'];
    if (requestId is! String || requestId.isEmpty) return;
    final questions = _parseAskQuestions(event['questions']);
    // 读不出题目时宁可不接:画一张空白可作答卡片比回落到桌面问卷更糟。
    if (questions.isEmpty) return;
    final toolCallId = event['toolCallId'];
    state = state.copyWith(
      pendingAsk: AskRequest(
        requestId: requestId,
        toolCallId: toolCallId is String ? toolCallId : '',
        questions: questions,
      ),
    );
    if (_foreground) unawaited(_claimAsk(requestId));
  }

  /// 告诉电脑「卡片已在前台、有人在看」,它才把秒级的认领窗口换成分钟级的作答窗口。
  Future<void> _claimAsk(String requestId) async {
    final resp = await _request('ask_claim', {'requestId': requestId});
    if (state.pendingAsk?.requestId != requestId) return;
    // 只有桥**明确回绝**时才撤卡 —— 那意味着这份问卷已经不在了。
    //
    // resp == null 是传输层没结果(socket 没开、超时、重连中),不能当回绝:
    // 问卷仍在重放环里,下一次重同步会把它再放出来,于是变成
    // 「可选 → 认领超时撤卡 → 重同步再画 → 又超时」的来回跳。
    if (resp != null && resp['success'] != true) _clearAsk();
  }

  void _clearAsk() {
    if (state.pendingAsk != null) state = state.copyWith(clearAsk: true);
  }

  /// 提交问卷答案。
  ///
  /// 不要求控制权(租约):这份问卷是电脑主动推给这台手机的,按 requestId
  /// 认账就够;要租约反而会在没自动取到控制权时把「作答」变成一句报错。
  Future<bool> respondAsk(List<Map<String, dynamic>> answers) async {
    final ask = state.pendingAsk;
    if (ask == null || answers.isEmpty) return false;
    final resp = await _request('ask_response', {
      'requestId': ask.requestId,
      'answers': answers,
    });
    if (resp?['success'] == true) {
      _clearAsk();
      return true;
    }
    return false;
  }

  /// 交还给电脑作答。relay 收到后立刻放行,插件在电脑上弹它那套完整问卷。
  Future<bool> declineAsk() async {
    final ask = state.pendingAsk;
    if (ask == null) return false;
    final resp = await _request('ask_decline', {'requestId': ask.requestId});
    // 无论成败都撤卡:用户已经表达了「我去电脑上答」。
    _clearAsk();
    return resp?['success'] == true;
  }

  @visibleForTesting
  static List<AskQuestion> debugParseAskQuestions(dynamic raw) =>
      _parseAskQuestions(raw);

  static List<AskQuestion> _parseAskQuestions(dynamic raw) {
    if (raw is! List) return const [];
    final questions = <AskQuestion>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final text = entry['question'];
      if (text is! String || text.isEmpty) continue;
      final options = <AskOption>[];
      final rawOptions = entry['options'];
      if (rawOptions is List) {
        for (final opt in rawOptions) {
          if (opt is! Map) continue;
          final label = opt['label'];
          if (label is! String || label.isEmpty) continue;
          final description = opt['description'];
          final preview = opt['preview'];
          options.add(
            AskOption(
              label: label,
              description: description is String && description.isNotEmpty
                  ? description
                  : null,
              hasPreview: preview is String && preview.isNotEmpty,
            ),
          );
        }
      }
      // 无选项的题无法作答,丢掉。
      if (options.isEmpty) continue;
      final header = entry['header'];
      questions.add(
        AskQuestion(
          question: text,
          header: header is String && header.isNotEmpty ? header : null,
          multiSelect: entry['multiSelect'] == true,
          options: options,
        ),
      );
    }
    return questions;
  }

  // -- entries ------------------------------------------------------------------

  void _ingestEntry(Map<String, dynamic> entry) {
    final id = entry['id'] as String?;
    if (id != null) {
      // 不再对重复 id 早退:补齐式重同步需要就地更新已有条目
      // (_ingestMessage 对 user/assistant/custom 本就是幂等更新)。
      _seenEntryIds.add(id);
      _leafId = id;
    }
    switch (entry['type']) {
      case 'message':
        final message = entry['message'];
        if (message is Map<String, dynamic>) {
          _ingestMessage(message, entryId: entry['id'] as String?);
        }
      case 'custom_message':
        _ingestMessage({
          'role': 'custom',
          'customType': entry['customType'],
          'content': entry['content'],
          'display': entry['display'],
          'details': entry['details'],
          'timestamp': entry['timestamp'],
        });
      case 'compaction':
        _ingestMessage({
          'role': 'compactionSummary',
          'summary': entry['summary'],
          'timestamp': entry['timestamp'],
        });
      case 'branch_summary':
        _ingestMessage({
          'role': 'branchSummary',
          'summary': entry['summary'],
          'timestamp': entry['timestamp'],
        });
      case 'session_info':
        // 会话重命名沿 session_info entry 传播
        final name = entry['name'] as String?;
        if (name != null && name.isNotEmpty) {
          state = state.copyWith(sessionName: name);
        }
      case 'model_change':
        final modelId = entry['modelId'] as String?;
        if (modelId != null) {
          final key = 'modelchange:${entry['id'] ?? entry['timestamp']}';
          if (_seenMsgKeys.add(key)) {
            _addItem(SystemItem(key, text: '模型已切换: $modelId'));
          }
        }
    }
  }

  void _ingestMessage(Map<String, dynamic> message, {String? entryId}) {
    final role = message['role'];
    final ts = message['timestamp'];
    switch (role) {
      case 'user':
        final key = 'user:$ts';
        final existing = _itemsByKey[key];
        if (existing is UserItem) {
          existing.entryId ??= entryId;
        } else if (_seenMsgKeys.add(key)) {
          _addItem(
            UserItem(
              key,
              text: _textFromContent(message['content']),
              time: _timeFrom(ts),
            )..entryId = entryId,
          );
        }
      case 'assistant':
        final key = 'assistant:$ts';
        final (text, thinking) = _textAndThinking(message['content']);
        final stopReason = message['stopReason'] as String?;
        // relay 在 pi 进程里按 delta 实测的思考时长(精确值)。
        // 断线重连/锁屏后一次性到位的消息靠它补上,
        // 否则手机只能显示「已思考」。
        final relayMs = message['thinkingDurationMs'];
        final relayDuration = relayMs is num && relayMs > 0
            ? Duration(milliseconds: relayMs.round())
            : null;
        final existing = _itemsByKey[key];
        if (existing is AssistantItem) {
          existing.text = text;
          existing.thinking = thinking;
          existing.stopReason = stopReason;
          existing.complete = true;
          if (relayDuration != null) {
            existing.thinkingDuration = relayDuration;
            existing.thinkingLenSeen = thinking.length;
          }
        } else if (_seenMsgKeys.add(key)) {
          final item = AssistantItem(key)
            ..text = text
            ..thinking = thinking
            ..stopReason = stopReason
            ..complete = true
            ..time = _timeFrom(ts);
          if (relayDuration != null) {
            item.thinkingDuration = relayDuration;
            item.thinkingLenSeen = thinking.length;
          }
          _addItem(item);
        }
        _noteAssistantError(
          item: _itemsByKey[key] as AssistantItem?,
          stopReason: stopReason,
        );
        // 工具参数只存在于 assistant 条目的 toolCall 块上,**不在** toolResult 上。
        // 以前这里只取 text/thinking,toolCall 块被整个丢掉,于是历史回放出来的
        // 工具卡没有命令摘要 —— bash 卡的命令是一片空白。
        _ingestToolCalls(message['content']);
      case 'toolResult':
        final callId = message['toolCallId'] as String?;
        if (callId == null) return;
        final key = 'toolResult:$callId';
        if (!_seenMsgKeys.add(key)) return;
        final output = _toolOutputFrom(message);
        final isError = message['isError'] == true;
        final existing = _toolCards[callId];
        if (existing != null) {
          existing.output = output;
          existing.done = true;
          existing.isError = isError;
        } else {
          final card =
              ToolItem(
                  'tool:$callId',
                  toolCallId: callId,
                  name: message['toolName'] as String? ?? 'tool',
                )
                ..output = output
                ..done = true
                ..isError = isError;
          _toolCards[callId] = card;
          _addItem(card);
        }
      case 'bashExecution':
        final command = message['command'] as String? ?? '';
        // 实时流已经建过卡但拿不到命令(事件里没有这个字段)——先认领它,
        // 而不是再追加一张重复的卡。命令为空时按输出配对。
        final live = _bashCards.values
            .where((card) => card.command.isEmpty)
            .firstOrNull;
        if (live != null) {
          live.command = command;
          live.done = true;
          live.exitCode = message['exitCode'] as int?;
          if (live.output.isEmpty) {
            live.output = message['output'] as String? ?? '';
          }
          _seenMsgKeys.add('bashExec:$ts');
          return;
        }
        final key = 'bashExec:$ts';
        if (_seenMsgKeys.add(key)) {
          final item = BashItem(key, command: command)
            ..output = message['output'] as String? ?? ''
            ..done = true
            ..exitCode = message['exitCode'] as int?;
          _addItem(item);
        }
      case 'custom':
        // 扩展注入的自定义消息(todo 状态等);display=false 不渲染
        if (message['display'] == false) return;
        final customType = message['customType'] as String? ?? 'custom';
        final key = 'custom:$customType:$ts';
        final text = _textFromContent(message['content']);
        final details = message['details'];
        final existing = _itemsByKey[key];
        if (existing is CustomItem) {
          existing.text = text;
          if (details is Map<String, dynamic>) existing.details = details;
        } else if (_seenMsgKeys.add(key)) {
          _addItem(
            CustomItem(
              key,
              customType: customType,
              text: text,
              details: details is Map<String, dynamic> ? details : null,
            ),
          );
        }
      case 'compactionSummary':
        final key = 'compaction:$ts';
        if (_seenMsgKeys.add(key)) {
          _addItem(
            SummaryItem(
              key,
              kind: 'compaction',
              summary: message['summary'] as String? ?? '',
            ),
          );
        }
      case 'branchSummary':
        final key = 'branch:$ts';
        if (_seenMsgKeys.add(key)) {
          _addItem(
            SummaryItem(
              key,
              kind: 'branch',
              summary: message['summary'] as String? ?? '',
            ),
          );
        }
      default:
        break;
    }
  }

  // -- helpers ------------------------------------------------------------------

  void _addItem(ChatItem item) {
    final at = _prependAt;
    if (at != null && at <= _items.length) {
      _items.insert(at, item);
      _prependAt = at + 1;
    } else {
      _items.add(item);
    }
    _itemsByKey[item.key] = item;
  }

  void _addSystem(String text, [SystemKind kind = SystemKind.info]) {
    _addItem(SystemItem('sys:${++_systemSeq}', text: text, kind: kind));
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    _emittedLengths.add(_items.length);
    state = state.copyWith(
      items: List<ChatItem>.unmodifiable(_items),
      revision: state.revision + 1,
    );
  }

  void _resetConversation({required String reason}) {
    // 列表清空的全部触发点都过这里,带原因进诊断日志 —— 「消息列表突然
    // 没了」类事故的取证就靠这行。
    _logP2p('清空对话列表(reason=$reason, items=${_items.length})');
    _items.clear();
    _itemsByKey.clear();
    _seenEntryIds.clear();
    _seenMsgKeys.clear();
    _toolCards.clear();
    _bashCards.clear();
    _streamingAssistant = null;
    _clearUiRequest();
    _commandsCache = null;
    _commandsCacheKey = null;
    _eventStreaming = false;
    _snapshotStreaming = false;
    _sawInFlightMessage = false;
    _inOrderStreak = 0;
    _gapNoticeShown = false;
    // 历史被清空了,往前分页的游标随之作废;头插游标必须归位,
    // 否则下一批正常消息会被插到列表中间。
    _oldestEntryId = null;
    _prependAt = null;
    // **这里绝对不能碰 state。**
    //
    // 本方法是纯内部暂存操作:清 _items,然后由调用方灌入替换条目、最后
    // 统一 _emit() 一次。曾经在这里加过
    //   state = state.copyWith(hasMoreHistory: false, loadingEarlier: false);
    // 想让游标和标志同生同死 —— 结果打破了那个「一次发布」的原子性,开出
    // 一个能对外发布半成品的窗口:清空之后、灌回之前,只要有一个流式 token
    // 到达就会 _emit() 出一个只含当前 assistant 的列表。真机症状是「所有
    // 消息全没了,只剩正在生成的那一条」,而且**不会再多打一条清空日志**,
    // 取证时极容易误判成「清空后没填回来」。
    //
    // 游标与 hasMoreHistory 的成对性由替换事务负责(见 _applyHubSnapshot
    // 与 _sync 的全量分支):在它们各自那一次 _emit() 之前一起设好。
  }

  static List<String> _stringList(dynamic value) =>
      value is List ? value.whereType<String>().toList() : const [];

  /// entry / 消息时间戳 → DateTime。
  ///
  /// pi 在不同位置用两种形态:流式事件里是 epoch 毫秒 int,而会话文件里的
  /// entry.timestamp 是 ISO 字符串。以前只认 int,字符串一律退成 `DateTime.now()`,
  /// 导致会话树里**每一条都显示「刚刚」**。
  static DateTime _timeFrom(dynamic ts) {
    if (ts is int) return DateTime.fromMillisecondsSinceEpoch(ts);
    if (ts is double) return DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    if (ts is String) {
      final parsed = DateTime.tryParse(ts);
      if (parsed != null) return parsed.toLocal();
    }
    return DateTime.now();
  }

  static String _textFromContent(dynamic content) {
    if (content is String) return content;
    if (content is List) {
      final buf = StringBuffer();
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          buf.write(block['text'] ?? '');
        }
      }
      return buf.toString();
    }
    return '';
  }

  static (String, String) _textAndThinking(dynamic content) {
    final text = StringBuffer();
    final thinking = StringBuffer();
    if (content is String) return (content, '');
    if (content is List) {
      for (final block in content) {
        if (block is Map) {
          if (block['type'] == 'text') text.write(block['text'] ?? '');
          if (block['type'] == 'thinking') {
            thinking.write(block['thinking'] ?? '');
          }
        }
      }
    }
    return (text.toString(), thinking.toString());
  }

  /// 从 assistant 条目的 `toolCall` 块里恢复工具卡的名字与参数。
  ///
  /// 这是历史回放唯一能拿到工具参数的地方 —— `toolResult` 条目只有输出。
  /// 注意持久化的字段名和实时事件**不一样**:
  ///
  /// | | 实时事件 | 会话文件 |
  /// |---|---|---|
  /// | id | `toolCallId` | `id` |
  /// | 名字 | `toolName` | `name` |
  /// | 参数 | `args` | `arguments` |
  ///
  /// assistant 条目总是排在它的 toolResult 之前,所以这里先建卡,
  /// 随后 `case 'toolResult'` 会找到它并补上输出。
  void _ingestToolCalls(dynamic content) {
    if (content is! List) return;
    for (final block in content) {
      if (block is! Map || block['type'] != 'toolCall') continue;
      final callId = block['id'] as String?;
      if (callId == null || callId.isEmpty) continue;
      final args = block['arguments'];
      final card = _toolCards[callId];
      if (card != null) {
        // 已经有卡(实时建的)就只补参数,不要覆盖已有输出
        if (card.argsSummary.isEmpty) card.argsSummary = _summarizeArgs(args);
        card.args ??= args is Map<String, dynamic>
            ? args
            : (args is Map ? Map<String, dynamic>.from(args) : null);
        continue;
      }
      final fresh =
          ToolItem(
              'tool:$callId',
              toolCallId: callId,
              name: block['name'] as String? ?? 'tool',
            )
            ..argsSummary = _summarizeArgs(args)
            ..args = args is Map<String, dynamic>
                ? args
                : (args is Map ? Map<String, dynamic>.from(args) : null);
      _toolCards[callId] = fresh;
      _addItem(fresh);
    }
  }

  static String _toolOutputFrom(dynamic result) {
    if (result is Map) {
      final content = result['content'];
      if (content is List) {
        final buf = StringBuffer();
        for (final block in content) {
          if (block is Map && block['type'] == 'text') {
            buf.write(block['text'] ?? '');
          }
        }
        return buf.toString();
      }
    }
    return '';
  }

  /// 工具卡副行显示的参数摘要。
  ///
  /// **每个分支都要截断**。之前只有最后的 JSON 兜底截了 120,`command` 和
  /// `path` 是原样返回的 —— 一条长 bash 命令能撑出几百 dp 的固有宽度,
  /// 直接把消息卡的头部 Row 撑爆。
  static String _summarizeArgs(dynamic args) {
    if (args is Map) {
      final command = args['command'];
      if (command is String) return _clip(command);
      final path = args['path'];
      if (path is String) return _clip(path);
      // 问卷的第一个键是 questions,一个嵌套 List<Map>。落到下面那条
      // 通用分支会把整个 Dart Map 的 toString 堵进副行 —— 一堆 {label: ...,
      // description: ...} 噪声。这里只取题目的 header 当摘要。
      final summary = _summarizeQuestions(args['questions']);
      if (summary != null) return _clip(summary);
      if (args.isNotEmpty) {
        final first = args.entries.first;
        return _clip('${first.key}: ${first.value}');
      }
    }
    if (args == null) return '';
    return _clip(args.toString());
  }

  /// `ask_user_question` 的副行摘要:题目的 header 依次拼接,
  /// 没有 header 就退回计数。不是问卷时返回 null 交回通用分支。
  static String? _summarizeQuestions(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final headers = <String>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final header = entry['header'];
      if (header is String && header.isNotEmpty) headers.add(header);
    }
    if (headers.isNotEmpty) return headers.join(' · ');
    return '${raw.length} 个问题';
  }

  /// 参数摘要的长度上限。换行压成空格(多行脚本变单行逻辑流)。
  /// 300:当年截 120 是怕撑爆头部单行 Row;现在副行独立一行+自然换行,
  /// 长路径/常见命令要显示完整。真·长脚本(heredoc)仍截断,展开看输出。
  static String _clip(String value, [int max = 300]) {
    final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > max ? '${flat.substring(0, max)}…' : flat;
  }

  /// 测试入口:截断规则决定工具卡会不会撑爆,值得钉住。
  @visibleForTesting
  static String debugClip(String value, [int max = 300]) => _clip(value, max);

  /// 测试入口:副行摘要是问卷卡上唯一的一行状态文字,
  /// 回落到通用分支就会变成一坨 Dart Map 的 toString。
  @visibleForTesting
  static String debugSummarizeArgs(dynamic args) => _summarizeArgs(args);
}
