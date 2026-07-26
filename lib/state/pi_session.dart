import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/pi_connection.dart';
import 'hub_models.dart';
import 'settings_provider.dart';

export '../core/pi_connection.dart' show PiConnStatus;
export 'hub_models.dart';

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
}

class ToolItem extends ChatItem {
  ToolItem(super.key, {required this.toolCallId, required this.name});
  final String toolCallId;
  final String name;
  String argsSummary = '';
  String output = '';
  bool done = false;
  bool isError = false;
}

class BashItem extends ChatItem {
  BashItem(super.key, {required this.command});
  final String command;
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

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class PiState {
  const PiState({
    required this.status,
    required this.items,
    required this.revision,
    required this.isStreaming,
    required this.isCompacting,
    required this.steeringQueue,
    required this.followUpQueue,
    required this.hasSession,
    required this.autoCompactionEnabled,
    required this.sources,
    required this.ownsSource,
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
    ownsSource: false,
    lastSourceSeq: 0,
  );

  final PiConnStatus status;
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
  final bool ownsSource;

  SourceInfo? get selectedSource {
    final id = selectedSourceId;
    if (id == null) return null;
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  bool get hasSelectedSource => selectedSource != null;
  bool get canControl =>
      status == PiConnStatus.connected &&
      selectedSource?.connected == true &&
      ownsSource;
  bool get canBrowseSessions => selectedSource?.isHeadless == true;

  PiState copyWith({
    PiConnStatus? status,
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
    bool? ownsSource,
    bool clearError = false,
    bool clearSource = false,
  }) {
    return PiState(
      status: status ?? this.status,
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
      ownsSource: clearSource ? false : (ownsSource ?? this.ownsSource),
    );
  }
}

final piSessionProvider = NotifierProvider<PiSessionNotifier, PiState>(
  PiSessionNotifier.new,
);

// ---------------------------------------------------------------------------
// Notifier: owns the connection, applies the RPC event stream to state
// ---------------------------------------------------------------------------

class PiSessionNotifier extends Notifier<PiState> {
  PiConnection? _conn;
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<PiConnStatus>? _statusSub;
  Timer? _reconnectTimer;
  Timer? _leaseRenewTimer;

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
  ({String host, int port, String token})? _creds;
  bool _intentionalDisconnect = false;
  bool _hubV2 = false;
  String? _leaseId;
  int? _leaseFence;
  bool _syncingSource = false;
  bool _sourceResyncScheduled = false;
  final List<Map<String, dynamic>> _bufferedSourceEvents = [];

  bool _autoConnectAttempted = false;

  @override
  PiState build() {
    ref.onDispose(_tearDown);
    // 设置从磁盘加载完成后,若已有连接配置则自动连接(每次启动仅一次)。
    ref.listen(settingsProvider, (prev, next) {
      if (_autoConnectAttempted ||
          !next.loaded ||
          !next.hasConnection ||
          state.hasSession) {
        return;
      }
      _autoConnectAttempted = true;
      connect();
    });
    return PiState.initial();
  }

  // -- public API ------------------------------------------------------------

  /// 使用设置页保存的连接配置建立连接。
  Future<void> connect() async {
    final settings = ref.read(settingsProvider);
    if (!settings.hasConnection) {
      state = state.copyWith(
        status: PiConnStatus.failed,
        error: '请先在设置页填写主机与 token',
      );
      return;
    }
    _intentionalDisconnect = false;
    _creds = (host: settings.host, port: settings.port, token: settings.token);
    state = state.copyWith(status: PiConnStatus.connecting, clearError: true);

    bool ok;
    try {
      ok = await _open();
    } catch (_) {
      // 任何异常(如非法主机名)都不能让状态停在 connecting
      ok = false;
    }
    if (!ok) {
      state = state.copyWith(
        status: PiConnStatus.failed,
        error: '连接失败或鉴权被拒,请检查地址与 token',
      );
      return;
    }
    state = state.copyWith(status: PiConnStatus.connected, hasSession: true);
    await _initializeAfterConnect();
  }

  void disconnect() {
    _intentionalDisconnect = true;
    _clearLease();
    _tearDown();
    _resetConversation();
    _leafId = null;
    _creds = null;
    _hubV2 = false;
    state = PiState.initial();
  }

  void sendPrompt(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || (_hubV2 && !state.canControl)) return;
    final message = <String, dynamic>{
      'type': 'prompt',
      'message': trimmed,
      if (state.isStreaming) 'streamingBehavior': 'followUp',
      ..._leaseMetadata(),
    };
    _conn?.send(message);
  }

  void abort() {
    if (_hubV2 && !state.canControl) return;
    _conn?.send({'type': 'abort', ..._leaseMetadata()});
  }

  // -- Source Hub -------------------------------------------------------------

  Future<List<SourceInfo>> refreshSources() async {
    if (!_hubV2) return state.sources;
    final resp = await _request('hub_list_sources');
    final raw = (resp?['data'] as Map?)?['sources'] as List?;
    if (resp?['success'] != true || raw == null) return state.sources;
    final parsed = [
      for (final source in raw)
        if (source is Map) SourceInfo.fromMap(source),
    ];
    state = state.copyWith(sources: parsed);
    return parsed;
  }

  Future<bool> selectSource(String sourceId, {bool persist = true}) async {
    if (!_hubV2) return false;
    if (state.selectedSourceId != sourceId) await releaseControl();
    final resp = await _request('hub_select_source', {'sourceId': sourceId});
    if (resp?['success'] != true) return false;
    final raw = (resp?['data'] as Map?)?['source'];
    final selected = raw is Map
        ? SourceInfo.fromMap(raw)
        : state.sources.where((source) => source.id == sourceId).firstOrNull;
    if (selected == null) return false;

    _leafId = null;
    _resetConversation();
    state = state.copyWith(clearSource: true);
    state = state.copyWith(
      selectedSourceId: selected.id,
      sourceEpoch: selected.epoch,
      cwd: selected.cwd,
      sessionId: selected.sessionId,
      sessionName: selected.sessionName,
      ownsSource: false,
    );
    if (persist) {
      await ref
          .read(settingsProvider.notifier)
          .setPreferredSourceId(selected.id);
    }
    await _syncSelectedSource(forceFull: true);
    return true;
  }

  Future<bool> acquireControl() async {
    if (!_hubV2) return true;
    final source = state.selectedSource;
    if (source == null || (!source.connected && !source.isHeadless)) {
      return false;
    }
    final resp = await _request('hub_acquire_owner', {'ttlMs': 30000});
    final data = resp?['data'] as Map?;
    if (resp?['success'] != true || data == null) return false;
    _leaseId = data['leaseId'] as String?;
    _leaseFence = data['fence'] as int?;
    if (_leaseId == null || _leaseFence == null) {
      _clearLease();
      return false;
    }
    state = state.copyWith(ownsSource: true, clearError: true);
    _scheduleLeaseRenewal();
    return true;
  }

  Future<void> releaseControl() async {
    final leaseId = _leaseId;
    final fence = _leaseFence;
    if (_hubV2 && leaseId != null && fence != null && _conn?.isOpen == true) {
      await _request('hub_release_owner', {'leaseId': leaseId, 'fence': fence});
    }
    _clearLease();
  }

  void _scheduleLeaseRenewal() {
    _leaseRenewTimer?.cancel();
    _leaseRenewTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_renewLease()),
    );
  }

  Future<void> _renewLease() async {
    final leaseId = _leaseId;
    final fence = _leaseFence;
    if (!_hubV2 || leaseId == null || fence == null) return;
    final resp = await _request('hub_renew_owner', {
      'leaseId': leaseId,
      'fence': fence,
      'ttlMs': 30000,
    });
    if (resp?['success'] != true) _clearLease();
  }

  void _clearLease() {
    _leaseRenewTimer?.cancel();
    _leaseRenewTimer = null;
    _leaseId = null;
    _leaseFence = null;
    if (state.ownsSource) state = state.copyWith(ownsSource: false);
  }

  Map<String, dynamic> _leaseMetadata() {
    if (!_hubV2 || _leaseId == null || _leaseFence == null) return const {};
    return {
      '_hub': {'leaseId': _leaseId, 'fence': _leaseFence},
    };
  }

  bool _sourceSupports(String command) =>
      !_hubV2 || (state.selectedSource?.supports(command) ?? false);

  Future<Map<String, dynamic>?> _mutatingRequest(
    String type, [
    Map<String, dynamic> extra = const {},
  ]) {
    if (_hubV2 && !state.canControl) {
      return Future.value({
        'type': 'response',
        'command': type,
        'success': false,
        'error': '请先取得当前 source 的控制权',
      });
    }
    return _request(type, {...extra, ..._leaseMetadata()});
  }

  Future<void> _initializeAfterConnect() async {
    if (!_hubV2) {
      await _sync();
      await _applyPreferences();
      return;
    }
    final available = await refreshSources();
    final preferred = ref.read(settingsProvider).preferredSourceId;
    SourceInfo? target;
    if (preferred != null) {
      target = available
          .where((source) => source.id == preferred && source.connected)
          .firstOrNull;
    } else {
      final desktops = available
          .where((source) => source.isDesktop && source.connected)
          .toList();
      if (desktops.length == 1) target = desktops.single;
    }
    if (target != null) {
      await selectSource(target.id, persist: preferred == null);
    } else {
      _resetConversation();
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

  /// Fork the current branch from a previous user message entry.
  Future<bool> forkFrom(String entryId) =>
      _afterSwitch(_mutatingRequest('fork', {'entryId': entryId}));

  /// Switch pi to a different working directory (bridge restarts the process).
  Future<bool> switchDir(String cwd, {String? sessionPath}) async {
    final resp = await _mutatingRequest('bridge_switch_dir', {
      'cwd': cwd,
      'sessionPath': ?sessionPath,
    });
    if (resp?['success'] != true) return false;
    final data = resp?['data'] as Map?;
    state = state.copyWith(
      cwd: data?['cwd'] as String? ?? cwd,
      sessionId: data?['sessionId'] as String? ?? state.sessionId,
      isStreaming: false,
    );
    _leafId = null;
    _resetConversation();
    await _sync(forceFull: true);
    return true;
  }

  Future<bool> _afterSwitch(Future<Map<String, dynamic>?> requestFuture) async {
    final resp = await requestFuture;
    if (resp?['success'] != true) return false;
    final data = resp?['data'];
    if (data is Map && data['cancelled'] == true) return false;
    _leafId = null;
    _resetConversation();
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
    final cost = data['cost'] as Map?;
    final ctx = data['contextUsage'] as Map?;
    return SessionStats(
      inputTokens: tokens?['input'] as int?,
      outputTokens: tokens?['output'] as int?,
      totalTokens: tokens?['total'] as int?,
      costTotal: (cost?['total'] as num?)?.toDouble(),
      contextTokens: ctx?['tokens'] as int?,
      contextWindow: ctx?['contextWindow'] as int?,
      contextPercent: ctx?['percent'] as int?,
    );
  }

  /// Export the session as HTML on the desktop; returns the file path.
  Future<String?> exportHtml() async {
    final resp = await _mutatingRequest('export_html');
    if (resp?['success'] != true) return null;
    return (resp?['data'] as Map?)?['path'] as String?;
  }

  /// Re-apply persisted preferences (model / thinking / auto-retry) that pi
  /// does not itself restore for a fresh process.
  Future<void> _applyPreferences() async {
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
      if (resp?['success'] == true) {
        state = state.copyWith(thinkingLevel: level);
      }
    }
    if (_sourceSupports('set_auto_retry')) {
      await _mutatingRequest('set_auto_retry', {'enabled': settings.autoRetry});
    }
  }

  // -- connection plumbing ----------------------------------------------------

  Future<bool> _open() async {
    await _closeConn();
    final creds = _creds;
    if (creds == null) return false;

    final conn = PiConnection();
    _conn = conn;
    _msgSub = conn.messages.listen(_handleEvent);
    _statusSub = conn.status.listen(_onConnStatus);

    final hello = await conn.connect(
      host: creds.host,
      port: creds.port,
      token: creds.token,
    );
    if (hello == null) return false;

    final version = hello['version'] as int? ?? 1;
    final hubId = hello['hubId'] as String?;
    _hubV2 = version >= 2 && hubId != null;
    if (_hubV2) {
      _clearLease();
      state = state.copyWith(hubId: hubId);
    } else {
      state = state.copyWith(
        sessionId: hello['sessionId'] as String?,
        cwd: hello['cwd'] as String?,
      );
    }
    return true;
  }

  Future<void> _closeConn() async {
    _clearLease();
    await _msgSub?.cancel();
    await _statusSub?.cancel();
    _msgSub = null;
    _statusSub = null;
    _conn?.disconnect(notify: false);
    _conn = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pending.clear();
  }

  void _onConnStatus(PiConnStatus status) {
    if (_intentionalDisconnect || !state.hasSession) return;
    if (status == PiConnStatus.disconnected || status == PiConnStatus.failed) {
      state = state.copyWith(status: PiConnStatus.connecting);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _attemptReconnect);
  }

  Future<void> _attemptReconnect() async {
    if (_intentionalDisconnect || _creds == null) return;
    bool ok;
    try {
      ok = await _open();
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      _scheduleReconnect();
      return;
    }
    state = state.copyWith(status: PiConnStatus.connected);
    await _initializeAfterConnect();
  }

  void _tearDown() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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

  Future<void> _loadLeafId() async {
    if (state.sessionId == null) return;
    final prefs = await SharedPreferences.getInstance();
    _leafId = prefs.getString(_leafStorageKey);
  }

  Future<void> _saveLeafId() async {
    final leafId = _leafId;
    if (state.sessionId == null || leafId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_leafStorageKey, leafId);
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

  Future<void> _saveHubCursor() async {
    final key = _cursorStorageKey;
    final hubId = state.hubId;
    final sourceId = state.selectedSourceId;
    final epoch = state.sourceEpoch;
    if (key == null || hubId == null || sourceId == null || epoch == null) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(
        HubCursor(
          hubId: hubId,
          sourceId: sourceId,
          sourceEpoch: epoch,
          seq: state.lastSourceSeq,
        ).toMap(),
      ),
    );
  }

  Future<void> _syncSelectedSource({bool forceFull = false}) async {
    if (!_hubV2 || state.selectedSourceId == null) return;
    _syncingSource = true;
    try {
      final cursor = forceFull ? null : await _loadHubCursor();
      if (cursor != null && cursor.sourceId == state.selectedSourceId) {
        state = state.copyWith(
          sourceEpoch: cursor.sourceEpoch,
          lastSourceSeq: cursor.seq,
        );
      }
      final resp = await _request('hub_sync', {
        if (cursor != null) 'cursor': cursor.toMap(),
      });
      final data = resp?['data'] as Map?;
      if (resp?['success'] != true || data == null) return;
      final mode = data['mode'];
      if (mode == 'snapshot') {
        final snapshot = data['snapshot'];
        if (snapshot is Map) _applyHubSnapshot(snapshot);
      } else if (mode == 'rpc') {
        await _sync(forceFull: forceFull);
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
      await _saveHubCursor();
    } finally {
      _syncingSource = false;
      final buffered = [..._bufferedSourceEvents]
        ..sort((a, b) => _hubSeq(a).compareTo(_hubSeq(b)));
      _bufferedSourceEvents.clear();
      for (final event in buffered) {
        _applySequencedEvent(event, fromSync: true);
      }
    }
  }

  void _applyHubSnapshot(Map<dynamic, dynamic> snapshot) {
    final stateData = snapshot['state'];
    if (stateData is Map) {
      _applyStateData(Map<String, dynamic>.from(stateData));
    }
    _resetConversation();
    final entries = snapshot['entries'] as List? ?? const [];
    for (final entry in entries) {
      if (entry is Map) _ingestEntry(Map<String, dynamic>.from(entry));
    }
    _leafId = snapshot['leafId'] as String?;
    state = state.copyWith(
      sourceEpoch: snapshot['epoch'] as String?,
      lastSourceSeq: snapshot['baseSeq'] as int? ?? 0,
    );
    _emit();
    final inFlight = snapshot['inFlightMessage'];
    if (inFlight is Map) {
      _onMessageUpdate({
        'type': 'message_update',
        'message': Map<String, dynamic>.from(inFlight),
      });
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
      isStreaming: data['isStreaming'] as bool? ?? false,
      isCompacting: data['isCompacting'] as bool? ?? false,
      autoCompactionEnabled: data['autoCompactionEnabled'] as bool? ?? false,
    );
  }

  Future<void> _sync({bool forceFull = false}) async {
    final stateResp = await _request('get_state');
    if (stateResp != null && stateResp['success'] == true) {
      final data = stateResp['data'];
      if (data is Map) _applyStateData(Map<String, dynamic>.from(data));
    }

    if (_leafId == null) await _loadLeafId();
    Map<String, dynamic>? entriesResp;
    var incremental = false;
    final leafId = forceFull ? null : _leafId;
    if (leafId != null) {
      entriesResp = await _request('get_entries', {'since': leafId});
      incremental = entriesResp != null && entriesResp['success'] == true;
    }
    if (!incremental) {
      _resetConversation();
      entriesResp = await _request('get_entries');
    }

    final data = entriesResp?['data'] as Map?;
    final entries = data?['entries'] as List? ?? const [];
    for (final entry in entries) {
      if (entry is Map) _ingestEntry(Map<String, dynamic>.from(entry));
    }
    _emit();
    await _saveLeafId();
  }

  Future<Map<String, dynamic>?> _request(
    String type, [
    Map<String, dynamic> extra = const {},
  ]) {
    final conn = _conn;
    if (conn == null || !conn.isOpen) return Future.value(null);
    final id = 'r${++_reqId}';
    final completer = Completer<Map<String, dynamic>?>();
    _pending[id] = completer;
    conn.send({'id': id, 'type': type, ...extra});
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _pending.remove(id);
        return null;
      },
    );
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
    }
    if (event['_hub'] is Map) {
      _applySequencedEvent(event);
      return;
    }
    _applyPiEvent(event);
  }

  void _onSourcesChanged(Map<String, dynamic> event) {
    final raw = event['sources'] as List?;
    if (raw == null) return;
    final previous = state.selectedSource;
    final parsed = [
      for (final source in raw)
        if (source is Map) SourceInfo.fromMap(source),
    ];
    final selected = parsed
        .where((source) => source.id == state.selectedSourceId)
        .firstOrNull;
    if (selected == null && state.selectedSourceId != null) {
      _clearLease();
      state = state.copyWith(clearSource: true, sources: parsed);
      return;
    }
    if (sourceEpochChanged(previous, selected)) {
      _clearLease();
      _leafId = null;
      _bufferedSourceEvents.clear();
      _resetConversation();
      state = state.copyWith(
        sources: parsed,
        ownsSource: false,
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
      ownsSource: selected?.ownedByYou ?? false,
      cwd: selected?.cwd,
      sessionId: selected?.sessionId,
      sessionName: selected?.sessionName,
      sourceEpoch: selected?.epoch,
    );
    if (selected != null && !selected.ownedByYou && _leaseId != null) {
      _clearLease();
    }
    if (previous?.connected == false && selected?.connected == true) {
      unawaited(_syncSelectedSource(forceFull: true));
    }
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
      ownsSource: updated.id == state.selectedSourceId
          ? updated.ownedByYou
          : state.ownsSource,
    );
    if (updated.id == state.selectedSourceId && !updated.ownedByYou) {
      _clearLease();
    }
  }

  int _hubSeq(Map<String, dynamic> event) {
    final hub = event['_hub'];
    return hub is Map ? hub['seq'] as int? ?? 0 : 0;
  }

  void _applySequencedEvent(
    Map<String, dynamic> event, {
    bool fromSync = false,
  }) {
    if (_syncingSource && !fromSync) {
      _bufferedSourceEvents.add(event);
      return;
    }
    final hub = event['_hub'];
    if (hub is! Map) return;
    final sourceId = hub['sourceId'] as String?;
    final epoch = hub['sourceEpoch'] as String?;
    final seq = hub['seq'] as int?;
    if (sourceId == null || epoch == null || seq == null) return;
    if (sourceId != state.selectedSourceId) return;
    if (state.sourceEpoch != null && state.sourceEpoch != epoch) {
      if (!fromSync) _bufferedSourceEvents.add(event);
      _scheduleSourceResync();
      return;
    }
    if (seq <= state.lastSourceSeq) return;
    if (seq != state.lastSourceSeq + 1) {
      if (!fromSync) _bufferedSourceEvents.add(event);
      _scheduleSourceResync();
      return;
    }
    state = state.copyWith(sourceEpoch: epoch, lastSourceSeq: seq);
    _applyPiEvent(event);
    unawaited(_saveHubCursor());
  }

  void _scheduleSourceResync() {
    if (_sourceResyncScheduled || !_hubV2) return;
    _sourceResyncScheduled = true;
    Future<void>(() async {
      try {
        await _syncSelectedSource(forceFull: true);
      } finally {
        _sourceResyncScheduled = false;
      }
    });
  }

  void _applyPiEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'agent_start':
        state = state.copyWith(isStreaming: true);
      case 'agent_end':
      case 'agent_settled':
        state = state.copyWith(isStreaming: false);
      case 'message_start':
      case 'message_end':
        _onMessageBoundary(event);
      case 'message_update':
        _onMessageUpdate(event);
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
      case 'compaction_start':
        state = state.copyWith(isCompacting: true);
        _addSystem('正在压缩上下文…');
      case 'compaction_end':
        state = state.copyWith(isCompacting: false);
        final result = event['result'];
        if (result is Map<String, dynamic>) {
          final before = result['tokensBefore'];
          final after = result['estimatedTokensAfter'];
          _addSystem('上下文已压缩 ($before → ~$after tokens)');
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
      case 'extension_error':
        _addSystem('扩展错误: ${event['error']}', SystemKind.error);
      case 'extension_ui_request':
        _onExtensionUi(event);
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
          state = state.copyWith(
            cwd: event['cwd'] as String?,
            sessionId: sid,
            isStreaming: false,
          );
          _leafId = null;
          _resetConversation();
          unawaited(
            _hubV2
                ? _syncSelectedSource(forceFull: true)
                : _sync(forceFull: true),
          );
        }
      case 'bridge_pi_start':
        _addSystem('pi 进程已启动');
      case 'bridge_pi_exit':
        state = state.copyWith(isStreaming: false);
        _addSystem(
          'pi 进程退出 (code ${event['code']}),bridge 正在重启…',
          SystemKind.warning,
        );
      case 'bridge_error':
        _addSystem('bridge: ${event['error']}', SystemKind.error);
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
    }
  }

  void _onMessageBoundary(Map<String, dynamic> event) {
    final message = event['message'];
    if (message is! Map<String, dynamic>) return;
    final role = message['role'];

    if (role == 'user') {
      _ingestMessage(message);
      _emit();
      return;
    }

    if (role == 'assistant') {
      if (event['type'] == 'message_start') {
        final current = _streamingAssistant;
        if (current != null && !current.complete) return;
        final key = 'assistant:${message['timestamp']}';
        final item = AssistantItem(key);
        _seenMsgKeys.add(key);
        _addItem(item);
        _streamingAssistant = item;
      } else {
        // message_end: finalize the streaming bubble
        final bubble = _streamingAssistant;
        if (bubble != null) {
          final (text, thinking) = _textAndThinking(message['content']);
          bubble.text = text;
          bubble.thinking = thinking;
          bubble.complete = true;
          _streamingAssistant = null;
        } else {
          _ingestMessage(message);
        }
      }
      _emit();
    }
  }

  void _onMessageUpdate(Map<String, dynamic> event) {
    final message = event['message'];
    if (message is! Map<String, dynamic> || message['role'] != 'assistant') {
      return;
    }
    var bubble = _streamingAssistant;
    if (bubble == null || bubble.complete) {
      // Joined mid-stream: synthesize the bubble from the partial message.
      final key = 'assistant:${message['timestamp']}';
      final existing = _itemsByKey[key];
      if (existing is AssistantItem) {
        bubble = existing;
      } else {
        bubble = AssistantItem(key);
        _seenMsgKeys.add(key);
        _addItem(bubble);
      }
      _streamingAssistant = bubble;
    }
    final (text, thinking) = _textAndThinking(message['content']);
    bubble.text = text;
    bubble.thinking = thinking;
    _emit();
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
    card.done = false;
    _emit();
  }

  void _onToolUpdate(Map<String, dynamic> event) {
    final card = _toolCards[event['toolCallId']];
    if (card == null) return;
    card.output = _toolOutputFrom(event['partialResult']);
    _emit();
  }

  void _onToolEnd(Map<String, dynamic> event) {
    final card = _toolCards[event['toolCallId']];
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
        _addSystem('扩展请求了 $method 交互(移动端暂不支持,请在电脑上处理)', SystemKind.warning);
      default:
        break; // setStatus/setWidget/setTitle/set_editor_text: ignore
    }
  }

  // -- entries ------------------------------------------------------------------

  void _ingestEntry(Map<String, dynamic> entry) {
    final id = entry['id'] as String?;
    if (id != null) {
      if (!_seenEntryIds.add(id)) {
        _leafId = id;
        return;
      }
      _leafId = id;
    }
    if (entry['type'] == 'message') {
      final message = entry['message'];
      if (message is Map<String, dynamic>) {
        _ingestMessage(message, entryId: entry['id'] as String?);
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
        final existing = _itemsByKey[key];
        if (existing is AssistantItem) {
          existing.text = text;
          existing.thinking = thinking;
          existing.complete = true;
        } else if (_seenMsgKeys.add(key)) {
          final item = AssistantItem(key)
            ..text = text
            ..thinking = thinking
            ..complete = true;
          _addItem(item);
        }
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
        final key = 'bashExec:$ts';
        if (_seenMsgKeys.add(key)) {
          final item =
              BashItem(key, command: message['command'] as String? ?? '')
                ..output = message['output'] as String? ?? ''
                ..done = true
                ..exitCode = message['exitCode'] as int?;
          _addItem(item);
        }
      default:
        break; // custom messages (todo state etc.) are not rendered in MVP
    }
  }

  // -- helpers ------------------------------------------------------------------

  void _addItem(ChatItem item) {
    _items.add(item);
    _itemsByKey[item.key] = item;
  }

  void _addSystem(String text, [SystemKind kind = SystemKind.info]) {
    _addItem(SystemItem('sys:${++_systemSeq}', text: text, kind: kind));
    _emit();
  }

  void _emit() {
    state = state.copyWith(
      items: List<ChatItem>.unmodifiable(_items),
      revision: state.revision + 1,
    );
  }

  void _resetConversation() {
    _items.clear();
    _itemsByKey.clear();
    _seenEntryIds.clear();
    _seenMsgKeys.clear();
    _toolCards.clear();
    _bashCards.clear();
    _streamingAssistant = null;
  }

  static List<String> _stringList(dynamic value) =>
      value is List ? value.whereType<String>().toList() : const [];

  static DateTime _timeFrom(dynamic ts) =>
      ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now();

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

  static String _summarizeArgs(dynamic args) {
    if (args is Map) {
      final command = args['command'];
      if (command is String) return command;
      final path = args['path'];
      if (path is String) return path;
      if (args.isNotEmpty) {
        final first = args.entries.first;
        return '${first.key}: ${first.value}';
      }
    }
    if (args == null) return '';
    final encoded = args.toString();
    return encoded.length > 120 ? '${encoded.substring(0, 120)}…' : encoded;
  }
}
