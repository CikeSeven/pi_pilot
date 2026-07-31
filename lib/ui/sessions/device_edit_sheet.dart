import 'package:flutter/material.dart';

import '../../core/device_models.dart';
import '../../core/pi_connection.dart';
import '../theme/paper.dart';
import '../theme/shapes.dart';
import '../theme/squircle.dart';
import '../theme/typography.dart';

/// 添加 / 编辑设备的底部弹层。
///
/// 两条进入路径:
/// - **发现带入**([discovered] 非空):名称/主机/端口预填,用户只需输 token;
/// - **编辑**([existing] 非空):全字段预填,底部多一个「删除设备」。
/// 两者都传则按编辑处理(discovered 只作预填来源)。
///
/// 返回保存后的 [DeviceProfile];取消/删除返回 null
/// (删除通过 [DeviceEditSheetResult.deleted] 标记)。
class DeviceEditSheetResult {
  const DeviceEditSheetResult.saved(this.device) : deleted = false;
  const DeviceEditSheetResult.deleted()
    : deleted = true,
      device = null;

  final DeviceProfile? device;
  final bool deleted;
}

Future<DeviceEditSheetResult?> showDeviceEditSheet(
  BuildContext context, {
  DeviceProfile? existing,
  DiscoveredDevice? discovered,
}) {
  return showModalBottomSheet<DeviceEditSheetResult>(
    context: context,
    isScrollControlled: true,
    // 顶部大圆角弹层是 PiShape.sheet 的职责,主题里的 bottomSheetTheme 已接。
    backgroundColor: Colors.transparent,
    builder: (context) => Padding(
      // 键盘顶起时整层上移
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _DeviceEditSheet(existing: existing, discovered: discovered),
    ),
  );
}

class _DeviceEditSheet extends StatefulWidget {
  const _DeviceEditSheet({this.existing, this.discovered});

  final DeviceProfile? existing;
  final DiscoveredDevice? discovered;

  @override
  State<_DeviceEditSheet> createState() => _DeviceEditSheetState();
}

class _DeviceEditSheetState extends State<_DeviceEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _token;
  late final TextEditingController _rendezvous;
  late final TextEditingController _p2pDeviceId;
  late final TextEditingController _secret;

  late DeviceTransport _transport;
  bool _obscure = true;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final d = widget.discovered;
    _name = TextEditingController(text: e?.name ?? d?.name ?? '');
    _host = TextEditingController(text: e?.host ?? d?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? d?.port ?? 9377}');
    _token = TextEditingController(text: e?.token ?? '');
    _rendezvous = TextEditingController(text: e?.p2pRendezvous ?? '');
    _p2pDeviceId = TextEditingController(text: e?.p2pDeviceId ?? '');
    _secret = TextEditingController(text: e?.p2pSecret ?? '');
    _transport = e?.transport ?? DeviceTransport.auto;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _token.dispose();
    _rendezvous.dispose();
    _p2pDeviceId.dispose();
    _secret.dispose();
    super.dispose();
  }

  void _save() {
    // 主机栏兼容误粘贴完整 URL(http://…/path),与设置页同一套纠正。
    final parsed = parseHostInput(_host.text);
    if (parsed == null) {
      setState(() => _error = '主机地址格式不正确,示例:192.168.1.100');
      return;
    }
    final port = int.tryParse(_port.text.trim()) ?? 9377;
    if (_token.text.trim().isEmpty) {
      setState(() => _error = 'Token 不能为空——发现只解决「找得到」,鉴权仍要 token');
      return;
    }
    final wantsP2p = _transport != DeviceTransport.lan;
    final p2pComplete =
        _rendezvous.text.trim().isNotEmpty &&
        _p2pDeviceId.text.trim().isNotEmpty &&
        _secret.text.trim().isNotEmpty;
    if (_transport == DeviceTransport.p2p && !p2pComplete) {
      setState(() => _error = '仅 P2P 模式下,信令服 / 设备名 / 配对密钥都要填');
      return;
    }

    final device = DeviceProfile(
      id: widget.existing?.id ?? generateDeviceId(),
      name: _name.text.trim().isEmpty
          ? (widget.discovered?.name ?? parsed.host)
          : _name.text.trim(),
      host: parsed.host,
      port: parsed.port ?? port,
      token: _token.text.trim(),
      transport: _transport,
      // 填全了才存;残缺的三要素等于没配(避免「以为有回落其实没有」)。
      p2pRendezvous: wantsP2p && p2pComplete
          ? _rendezvous.text.trim()
          : null,
      p2pDeviceId: wantsP2p && p2pComplete ? _p2pDeviceId.text.trim() : null,
      p2pSecret: wantsP2p && p2pComplete ? _secret.text.trim() : null,
      lastHubId: widget.existing?.lastHubId ?? widget.discovered?.hubId,
    );
    Navigator.of(context).pop(DeviceEditSheetResult.saved(device));
  }

  void _delete() {
    Navigator.of(context).pop(const DeviceEditSheetResult.deleted());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Container(
      decoration: ShapeDecoration(
        color: colors.surface,
        shape: PiShape.sheet,
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _isEdit ? '编辑设备' : '添加设备',
                    style: AppType.displayTitle(
                      size: 22,
                      color: colors.onSurface,
                    ),
                  ),
                ),
                if (widget.discovered != null && !_isEdit)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(PiShape.sm),
                    ),
                    child: Text(
                      '局域网发现',
                      style: AppType.eyebrow(color: colors.primary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            _field(
              _name,
              label: '名称',
              hint: '书房的 Mac',
              icon: Icons.badge_outlined,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _field(
                    _host,
                    label: '主机',
                    hint: '192.168.1.100',
                    icon: Icons.dns_outlined,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: _field(
                    _port,
                    label: '端口',
                    icon: Icons.numbers,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Token',
                prefixIcon: const Icon(Icons.key_outlined),
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示' : '隐藏',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Eyebrow(text: '连接方式', color: colors.primary, withRule: true),
            const SizedBox(height: 6),
            _transportOption(
              DeviceTransport.auto,
              title: '自动',
              subtitle: '局域网直连优先,失败自动转 P2P(与现在一样)',
            ),
            _transportOption(
              DeviceTransport.lan,
              title: '仅局域网直连',
              subtitle: '不走公网;不在家时这台设备显示离线',
            ),
            _transportOption(
              DeviceTransport.p2p,
              title: '仅 P2P 远程',
              subtitle: '经信令服打洞;局域网里也不直连',
            ),
            // P2P 字段区:仅直连时整段收起(那台设备不需要)。
            if (_transport != DeviceTransport.lan) ...[
              const SizedBox(height: 14),
              _field(
                _rendezvous,
                label: '信令服',
                hint: 'signal.example.com',
                icon: Icons.hub_outlined,
              ),
              const SizedBox(height: 12),
              _field(
                _p2pDeviceId,
                label: '设备名(信令服上)',
                icon: Icons.memory,
              ),
              const SizedBox(height: 12),
              _field(_secret, label: '配对密钥', icon: Icons.lock_outline),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.error,
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.link),
              label: Text(_isEdit ? '保存' : '保存并连接'),
            ),
            if (_isEdit) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _delete,
                icon: Icon(Icons.delete_outline, color: colors.error),
                label: Text('删除设备', style: TextStyle(color: colors.error)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller, {
    required String label,
    String? hint,
    IconData? icon,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon),
      ),
    );
  }

  Widget _transportOption(
    DeviceTransport value, {
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = _transport == value;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: 0.10)
            : colors.surfaceContainerLowest,
        shape: SquircleBorder(
          borderRadius: BorderRadius.circular(PiShape.md),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _transport = value),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
