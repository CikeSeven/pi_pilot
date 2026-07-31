# 多设备连接与局域网发现 · 实现方案

> 目标:App 从「单 bridge 连接」升级为「多设备同时保活连接」;
> 设备页从「会话列表」升级为「设备列表 → 每台设备的会话列表」两级结构;
> 支持 mDNS 局域网自动发现;每台设备可选 直连 / P2P / 自动(直连失败回落 P2P)。

## 0. 现状盘点(为什么这样改)

| 现状 | 位置 | 约束 |
| --- | --- | --- |
| `PiSessionNotifier` 持有**一条** `PiConnection`,4327 行,全 app 消费单一 `piSessionProvider` | `lib/state/pi_session.dart:728` | 不能重写,只能实例化多份 |
| `_open()` 已实现 WS 直连(12s)→ P2P 打洞回落 | `lib/state/pi_session.dart:2004-2060` | 直接复用,按设备偏好加门控即可 |
| 设置里只有一组 `conn.host/port/token` + 一组 `p2p.*` | `lib/core/settings_repository.dart` | 需要 roster 列表 + 旧键迁移 |
| ICE 模式缓存已按 deviceId 分键(`p2p.icemode.{deviceId}`) | `lib/core/settings_repository.dart:47` | 多设备免费兼容 |
| bridge 只监听 WS + `/health`,无自我宣告 | `bridge/src/server.ts:2824` | mDNS 需要 bridge 侧加发布模块 |
| `SyncStore` WAL 以 clientId 为键 | `lib/core/sync_store.dart` | 多设备共用同一 clientId,op 账本需加 deviceId 维度 |
| `notification_controller` / `app_lifecycle` 假设单连接 | `lib/state/` | DeviceManager 需按设备扇出 |

## 1. 总体架构

```
┌──────────────────────────── App ────────────────────────────┐
│                                                             │
│  DeviceManagerNotifier (新增)                                │
│   ├─ roster: List<DeviceProfile>        ← SettingsRepository│
│   ├─ discovered: List<DiscoveredDevice> ← LanDiscovery      │
│   ├─ activeDeviceId: String                                 │
│   └─ for each device: ref.watch(piSessionProvider(id))  ←保活│
│                                                             │
│  piSessionProvider → NotifierProvider.family<..., String>   │
│   ├─ ("dev-a") PiSessionNotifier ─ PiConnection ─┐          │
│   ├─ ("dev-b") PiSessionNotifier ─ PiConnection ─┤ 各自直连/ │
│   └─ ("dev-c") PiSessionNotifier ─ PiConnection ─┘ P2P 回落 │
│                                                             │
│  currentSessionProvider = Provider<PiState>                  │
│   └─ ref.watch(piSessionProvider(activeDeviceId))  ←UI 统一入口│
│                                                             │
│  LanDiscovery (新增)                                         │
│   ├─ mobile: bonsoir 监听 _pipilot._tcp                     │
│   └─ desktop: 子网 /health 探测兜底                           │
└─────────────────────────────────────────────────────────────┘
        │ mDNS publish (_pipilot._tcp, TXT: hubId/name/v)
┌───────┴──────┐
│ bridge       │  + bridge/src/announce.ts (bonjour-service)
└──────────────┘
```

### 1.1 状态层:family + proxy,不动 4327 行 notifier 的内部逻辑

`PiSessionNotifier` 的配置**全部**经 `connect()` 里的 `_creds`/`_p2p` 快照注入
(`pi_session.dart:845-890`),天然支持参数化——每设备一份实例只是换一份配置。

```dart
// 改前
final piSessionProvider = NotifierProvider<PiSessionNotifier, PiState>(PiSessionNotifier.new);
// 改后
final piSessionProvider = NotifierProvider.family<PiSessionNotifier, PiState, String>(
  PiSessionNotifier.new,
);
```

三个关键配套:

1. **保活**:family 实例没人 watch 就会被销毁。`DeviceManagerNotifier.build()`
   里对 roster 每台设备 `ref.watch(piSessionProvider(device.id))`,连接即常驻。
2. **统一出口**:新增
   ```dart
   final currentSessionProvider = Provider<PiState>((ref) {
     final activeId = ref.watch(deviceManagerProvider.select((s) => s.activeDeviceId));
     if (activeId == null) return PiState.initial();
     return ref.watch(piSessionProvider(activeId));
   });
   ```
   UI 层把 `ref.watch(piSessionProvider)` 机械替换为 `ref.watch(currentSessionProvider)`
   (notifier 侧配一个 `currentSessionNotifierProvider` 暴露 `PiSessionNotifier?`)。
   chat / sessions / settings 的几十个消费点都是 grep-replace,不改逻辑。
3. **生命周期收口**:把 `build()` 里的 `ref.listen(settingsProvider)` 自动连接
   (`pi_session.dart:824-832`)移出——N 个实例都去听 settings 会竞赛。
   改为 `DeviceManagerNotifier` 在 roster 加载完成后对每台设备显式调
   `connect(device)`;notifier 的 `connect()` 签名改为接收 `DeviceProfile`
   而不是读全局 settings(见 §3.2)。

### 1.2 传输策略:复用 `_open()` 的两段式,加门控

`_open()` 现状(`pi_session.dart:2004-2060`):

```
hello = await conn.connect(host, port, token, timeout: 12s)   // ① WS 直连
if (hello == null && p2p != null) {                            // ② P2P 回落
  channel = await P2pConnector().connect(rendezvous, deviceId, secret, modeCache)
  hello = await conn.connectViaChannel(channel, token)
}
```

新增 `DeviceTransport { auto, lan, p2p }`,在 `_open()` 外层包一个 switch:

| 偏好 | ① WS 直连 | ② P2P 回落 |
| --- | --- | --- |
| `auto`(默认,与现状一致) | 尝试 | 失败则尝试 |
| `lan`(仅局域网直连) | 尝试 | 跳过 |
| `p2p`(仅远程打洞) | 跳过 | 尝试 |

ICE 模式缓存按 `device.p2p.deviceId` 分键,天然多设备隔离,零改动。

### 1.3 发现层:mDNS 为主,子网探测兜底

**bridge 侧**(新增 `bridge/src/announce.ts`):

```ts
import Bonjour from "bonjour-service";
// server.ts 启动 HTTP server 后调用 startAnnounce(config),退出前 stopAnnounce()
export function startAnnounce(config: BridgeConfig): () => void {
  const bonjour = new Bonjour.default();
  const service = bonjour.publish({
    name: config.deviceName ?? hostname(),   // 「书房的 Mac」
    type: "pipilot",                          // → _pipilot._tcp.local
    port: config.port,
    txt: {
      hubId: sources.hubId,
      v: String(HUB_PROTOCOL_VERSION),
      auth: "token",                          // 宣告需要 token,不携带 token 本身
    },
  });
  return () => { service.stop?.(); bonjour.destroy(); };
}
```

- 选 `bonjour-service`:纯 JS 实现,无原生编译(对比 `mdns` 需要 node-gyp)。
- TXT 只放**非机密**元数据。token 永远不上广播——发现只解决「找得到」,
  「连得上」仍要走添加流程输入 token(见 §4 UI 流程)。

**App 侧**(新增 `lib/core/lan_discovery.dart`):

```dart
abstract class LanDiscovery {
  Stream<List<DiscoveredDevice>> get devices;  // 去重后的在线列表
  Future<void> start();
  Future<void> stop();
}
// 两实现:
//  BonsoirLanDiscovery   — Android/iOS/macOS,bonsoir 插件 resolve _pipilot._tcp
//  SubnetScanLanDiscovery— Windows/Linux 兜底:取本机 IPv4 子网,
//                          并发 GET http://{ip}:9377/health(300ms 超时),
//                          ok:true 的即为 bridge(/health 已带 hubId,无需鉴权)
```

| 平台 | 实现 | 说明 |
| --- | --- | --- |
| Android / iOS / macOS | `bonsoir` | 系统 NSD;Android 需 `INTERNET`+`CHANGE_WIFI_MULTICAST_STATE`,iOS 需 `NSBonjourServices` |
| Windows / Linux | 子网 `/health` 扫描 | bonsoir 不支持;`/health` 裸奔可用但只暴露 hubId/cwd,无机密 |

**DHCP 换 IP 自愈**:roster 存 `lastHubId`。发现结果里 hubId 命中某台已存设备
但 host 不同 → DeviceManager 静默更新该设备的 host/port 并触发重连。
用户在咖啡店/家里切换网络不再手动改 IP。

## 2. 数据模型与持久化

### 2.1 `DeviceProfile`(新增 `lib/core/device_models.dart`)

```dart
enum DeviceTransport { auto, lan, p2p }

class DeviceProfile {
  final String id;            // app 内稳定 id:uuid,与 hubId 解耦(hubId 可能重建)
  final String name;          // 用户可改,默认取发现时的 mDNS name 或 host
  final String host;
  final int port;
  final String token;
  final DeviceTransport transport;
  // P2P 四要素(整组可空:未配置即无回落,等价 lan)
  final String? p2pRendezvous;
  final String? p2pDeviceId;
  final String? p2pSecret;
  final String? lastHubId;    // 上次握手拿到的 hubId,用于 DHCP 自愈匹配
}
```

### 2.2 存储迁移(`SettingsRepository`)

新键 `devices.list`(JSON 数组)。首次 `load()` 时若 `devices.list` 不存在且
旧键 `conn.host` 非空 → 合成一台设备:

```json
[{
  "id": "<uuid>", "name": "默认设备",
  "host": "<conn.host>", "port": 9377, "token": "<conn.token>",
  "transport": "auto",
  "p2p": { "rendezvous": "<p2p.rendezvous>", "deviceId": "<p2p.deviceId>", "secret": "…" }
}]
```

迁移后旧键**只读不写**(保留一个版本做回滚保险),下个版本删除。
`p2p.icemode.*` 前缀不动。`conn.clientId` 全局唯一,所有设备共用——
它是「这台手机」的身份,不是「某条连接」的身份。

### 2.3 `SyncStore` WAL 加设备维度(必须做,否则串账)

`_nextOpId()` 的 opId 以 clientId 为键(`pi_session.dart` `_sendMutating`)。
多设备后同一 clientId 向 A、B 两台 bridge 各发 op,断线恢复时 A 的 op 会被
拿去问 B 的 `hub_op_status` → 误判「结果未知」。

改动:`ops` 表加 `deviceId` 列(或复合键 `(deviceId, opId)`),
`_sendMutating` / 对账逻辑带上传入的 device id。family 化后 notifier 从
`arg` 拿自己的 deviceId,改动局限在 sync_store.dart 一处 schema 迁移
(`ALTER TABLE … ADD COLUMN deviceId TEXT NOT NULL DEFAULT ''`)与调用点。

## 3. 逐文件改动清单

### 3.1 App 侧

| 文件 | 改动 | 量级 |
| --- | --- | --- |
| `lib/core/device_models.dart` | **新增**:DeviceProfile / DiscoveredDevice / DeviceTransport / JSON 序列化 | 小(本次交付) |
| `lib/core/settings_repository.dart` | `devices.list` 读写 + 旧键迁移 + roster CRUD | 小(本次交付) |
| `lib/core/lan_discovery.dart` | **新增**:LanDiscovery 抽象 + Bonsoir / SubnetScan 两实现 | 中 |
| `lib/state/device_manager.dart` | **新增**:DeviceManagerNotifier(roster/discovered/activeDeviceId/保活/扇出通知) | 中(本次交付占位骨架) |
| `lib/state/pi_session.dart` | ① provider 改 family;② `connect(DeviceProfile)` 替掉读 settings;③ `_open()` 加 transport 门控;④ 移除 build() 内 settings 自动连接;⑤ `_sendMutating` 带 deviceId | 中,机械化 |
| `lib/state/settings_provider.dart` | 连接/P2P 字段从 AppSettings 摘除(迁入 DeviceProfile),保留外观/行为设置 | 小 |
| `lib/core/sync_store.dart` | ops 表加 deviceId 列 + schema 迁移 | 小 |
| `lib/state/notification_controller.dart` | 事件源从单连接改为 DeviceManager 扇出(每设备一条流,通知带设备名前缀) | 小 |
| `lib/ui/sessions/devices_page.dart` | **重写为两级**:设备列表页 + 每设备会话页(复用现有 _DeviceCard/_HistoryCard) | 中(本次交付) |
| `lib/ui/sessions/device_edit_sheet.dart` | **新增**:添加/编辑设备底部弹层(host/token/transport 三段选择/P2P 折叠区) | 中(本次交付) |
| 全 UI 消费点 | `piSessionProvider` → `currentSessionProvider` 机械替换 | 大但无脑 |
| `pubspec.yaml` | +`bonsoir`, +`uuid` | 小 |
| Android/iOS 平台配置 | 组播权限 / NSBonjourServices | 小 |

### 3.2 bridge 侧

| 文件 | 改动 |
| --- | --- |
| `bridge/src/announce.ts` | **新增**:bonjour-service 发布 `_pipilot._tcp`(见 §1.3) |
| `bridge/src/server.ts` | listen 成功后 `startAnnounce(config)`,SIGTERM 前 stop |
| `bridge/src/config.ts` | 可选 `deviceName` 配置项(默认 hostname) |
| `bridge/package.json` | +`bonjour-service` |

**协议零改动**:mDNS 只是带外发现,hub 协议帧、鉴权、租约全部原样。
老版本 App + 新版本 bridge、新 App + 老 bridge(手动添加)都兼容。

### 3.3 连接握手细节(无变化,仅备查)

- 直连:`ws://host:port/?token=…&clientId=…&caps=msg-delta` → 等 `bridge_hello`
- P2P:DataChannel 首帧 `auth` → 等 `bridge_hello`;`hello.hubId` 写回
  `device.lastHubId`(DHCP 自愈的匹配依据)

## 4. UI 设计(遵循 Editorial Retro 词汇)

### 4.1 设备页 = 两级

**第一级 · 设备列表**(底栏「设备」tab / 左滑抽屉共用 `_DevicesBody`,沿用现状双壳):

```
┌──────────────────────────────┐
│ 设备 ✦                  ↻    │  ← displayTitle(27) + auto_awesome + 刷新
│ 每台电脑是一个工作台          │  ← serifItalic(14, onSurfaceVariant)
│ 在线 · 2                     │  ← Eyebrow(primary, withRule)
│ ┌──────────────────────────┐ │
│ │ ▣ 书房的 Mac          当前 │ │  ← 陶土橙实心卡(active device)
│ │   直连 · 3 个窗口          │ │    monoLabel(onPrimary 78%)
│ └──────────────────────────┘ │
│ ┌──────────────────────────┐ │
│ │ ▣ 公司台式机          P2P ›│ │  ← surfaceContainerLow + outlineVariant
│ │   打洞 · 中继              │ │    传输徽标 monoLabel
│ └──────────────────────────┘ │
│ 局域网发现 · 1                │  ← Eyebrow(onSurfaceVariant, withRule)
│ ┌──────────────────────────┐ │
│ │ ◌ garage-pc           ＋  │ │  ← surfaceContainerLowest(更轻一档,
│ │   192.168.1.53 · 待添加    │ │    与历史卡对设备卡的轻量关系一致)
│ └──────────────────────────┘ │
└──────────────────────────────┘
```

视觉分层沿用现有约定,不发明新语言:
- **active 设备 = 陶土橙实心卡** —— 照搬 `_DeviceCard` 的 isCurrent 处理,
  「当前」chip 原样;
- **其余已添加设备 = `surfaceContainerLow` + `outlineVariant` 描边卡**;
- **发现未添加 = `surfaceContainerLowest`** —— 复刻 `_HistoryCard` 比
  `_DeviceCard` 轻一档的手法(虚线感图标 `Icons.radar`/`Icons.wifi_find`),
  右端 `＋` 而不是 chevron,语义是「还不是你的设备」;
- 传输徽标:「直连 / P2P / 中继 / 离线」用 `AppType.monoLabel`,
  离线时整卡 fg 降 `onSurfaceVariant`;
- 正在生成 → 卡右侧 18dp 双圈 spinner(与现状一致)。

**第二级 · 某台设备的会话页**:点设备卡 push 进入,`Scaffold + BackdropPaper`,
内容**原样复用**现有 `_DeviceCard`(此处显示该设备的 pi 窗口)与
`_HistoryCard`(该设备的历史会话)——样式、文案、唤醒逻辑零改动,
只是数据源从 `piSessionProvider` 换成 `piSessionProvider(deviceId)`。

**「设为当前」**:第二级页头右侧 `IconButton(Icons.swap_horiz)` 或在第一级
长按/点非 active 卡直接 `DeviceManager.setActive(id)`。聊天页永远读
`currentSessionProvider`,切换即时(连接早已保活,无重连等待)。

### 4.2 添加 / 编辑设备 sheet(`PiShape.sheet` 顶部大圆角底部弹层)

```
┌──────────────────────────────┐
│ 添加设备                      │  ← displayTitle(22)
│ ┌──────────────────────────┐ │
│ │ 名称   [书房的 Mac      ] │ │  ← 发现带入时预填
│ │ 主机   [192.168.1.53    ] │ │  ← 发现带入时锁定可改
│ │ 端口   [9377            ] │
│ │ Token  [••••••••      👁] │
│ └──────────────────────────┘ │
│ 连接方式                      │  ← Eyebrow
│  ◉ 自动(直连优先,失败转 P2P)│  ← 三段选择,默认 auto
│  ○ 仅局域网直连              │
│  ○ 仅 P2P 远程               │
│ ▾ P2P 设置(自动/P2P 时展开) │  ← 折叠区:信令服/设备名/配对密钥
│ [  保存并连接  ]              │  ← FilledButton 全宽
└──────────────────────────────┘
```

发现的设备点 `＋` → 打开此 sheet,名称/主机/端口预填,只需输 token;
「手动添加」入口在第一级页尾(描边虚线卡 `+ 手动添加设备`)。

### 4.3 设置页联动

`ConnectionPage` 的 host/token/P2P 卡**整段移除**,改为「设备管理」入口
(跳转设备页);设置页只留外观/通知/行为/关于。旧单设备心智在 UI 层彻底退场。

## 5. 关键流程时序

### 5.1 启动

```
SettingsNotifier._hydrate()
  └─ SettingsRepository.load()
      └─ devices.list 缺失且有旧 conn.* → 迁移合成 device[0]
DeviceManagerNotifier.build()
  ├─ 读 roster
  ├─ for d in roster: ref.watch(piSessionProvider(d.id)) → connect(d)   ← 保活+并发连接
  ├─ activeDeviceId = prefs.devices.activeId ?? roster.first
  └─ LanDiscovery.start() → discovered 流
```

### 5.2 点「发现卡」添加

```
发现卡(hubId=H, host=H1) → sheet 预填 → 输 token → 保存
  → roster += DeviceProfile(lastHubId: H, …)
  → DeviceManager 立即 connect(新 device)
  → _open(): WS(H1) ✗(12s 内失败) → P2P 已配? → 打洞 → bridge_hello
  → hello.hubId 写回 lastHubId
```

### 5.3 DHCP 换 IP 自愈

```
LanDiscovery 发现 hubId=H 出现在 host=H2(H2≠H1)
  → DeviceManager 匹配 roster.lastHubId == H
  → 更新 device.host = H2,持久化
  → 若该设备当前未 connected:触发重连(新地址)
```

### 5.4 断线重连(每设备独立)

沿用各 notifier 自己的 `_scheduleReconnect()`(指数退避 1s→30s + jitter,
`pi_session.dart:2095+`)——family 化后天然每设备一份,互不干扰。
`DeviceManager` 只在「设备被删除」时 `ref.invalidate(piSessionProvider(id))`。

## 6. 风险与对策

| 风险 | 对策 |
| --- | --- |
| family 实例无人 watch 被销毁,连接掉线 | DeviceManager build() 里对 roster 全量 `ref.watch`(§1.1) |
| N 个 notifier 竞听 settings 自动连接 | 自动连接收口到 DeviceManager(§1.1-3) |
| opId 账本跨设备串账 | sync_store 加 deviceId 列(§2.3) |
| bonsoir 不支持 Windows/Linux | desktop 兜底子网 `/health` 扫描(§1.3) |
| iOS 本地网络权限(iOS 14+) | Info.plist `NSLocalNetworkUsageDescription` + `NSBonjourServices=[_pipilot._tcp.]` |
| 通知从多台设备涌入分不清来源 | 通知 title 前缀设备名:「书房的 Mac · 任务完成」 |
| 多连接电量/流量 | 心跳由 bridge 侧控制;P2P 设备未激活时无可观流量(DataChannel 空闲近零) |
| 旧版单设备设置残留 | 一次性迁移 + 旧键只读保留一版(§2.2) |

## 7. 实施顺序(每步可独立编译验证)

1. ✅ `docs/multi-device-plan.md`(本文档)
2. ✅ `lib/core/device_models.dart` — 纯模型 + JSON,零依赖
3. ✅ `SettingsRepository` roster CRUD + 迁移
4. ✅ 设备页两级 UI + 添加/编辑 sheet(DeviceManager 占位骨架,数据走 mock/单设备)
5. ⬜ DeviceManager 正式版 + `pi_session.dart` family 化 + UI 消费点机械替换
6. ⬜ `lib/core/lan_discovery.dart`(bonsoir + 子网扫描)+ 平台权限配置
7. ⬜ bridge `announce.ts` + config
8. ⬜ sync_store deviceId 列迁移 + notification 扇出
9. ⬜ 端到端:两台 bridge(一台 LAN 一台 P2P)同时在线、切换、DHCP 自愈

本次交付 = 1–4(方案 + 模型/存储骨架 + UI 代码);5–9 为后续迭代。
