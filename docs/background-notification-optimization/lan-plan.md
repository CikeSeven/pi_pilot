# Android 局域网后台连接与通知优化执行计划

日期：2026-08-01
状态：待实施
分支：`background-notification-optimization`
范围：Android 客户端、Bridge、局域网发现与直连、可选通知 Relay/FCM 兜底
本分支约束：只新增计划文档，不修改实现代码

关联计划：[Android P2P 后台连接与通知优化执行计划](p2p-plan.md)

> **本文已降级为 LAN 专项参考，不再作为独立实施计划。**
> 实施路径、可靠性口径、分期与验收以
> [统一稳定方案](stable-plan.md) 为准。本文的 mDNS/NsdManager 发现、NetworkCallback
> 地址自愈、原生 owner 组件拆分等技术细节仍然有效并被新方案引用；但以下三处已被新方案
> 修正，阅读时请以 `stable-plan.md` 为准：
>
> 1. §2.3 的「同一 eventId 最多显示一次」exactly-once 口径不可实现（见 stable-plan §2）。
> 2. §6.1 的 `bridgeInstallationId` 替换缺少迁移方案，会导致升级断链（见 stable-plan §3）。
> 3. §10.5 的 target SDK 35 与 `NEARBY_WIFI_DEVICES` 表述有误，实际 target 已是 36
>    （见 stable-plan §4）。

> 本文负责局域网直连、原生 LAN connection owner、地址自愈和纯局域网实时模式。
> P2P/远程通知、Relay、FCM 引导鉴权和可选原生 WebRTC owner 以 `p2p-plan.md` 为准。
> 两份计划共享同一套 Bridge 持久事件、`eventId`、installation cursor 和 Android
> 原生去重实现，不得分别建立两套事件协议或 outbox。

## 1. 执行摘要

局域网不需要把正常通知绕道云端。最合理的目标架构是“共享控制面、可替换传输面”：

1. **Bridge 权威事件与持久 outbox** 负责事件不丢、顺序和补偿，与 LAN/P2P 无关。
2. **Android 原生 LAN 直连** 负责同一局域网内的低延迟实时通知，不依赖 Flutter isolate。
3. **Relay/FCM 可选兜底** 只在离开局域网、LAN 不可达或进程被回收时负责唤醒。
4. **每 installation cursor** 负责最终一致性；两条实时路径都失败时，下次连接仍能补齐。
5. **统一 `eventId` 去重与原生渲染** 让 LAN、FCM、Dart 重叠投递也只显示一次。

```text
pi / extension event
        |
        v
Bridge authoritative event detector
        |
        v  append + fsync before delivery
Bridge notification event store
        |
        +--------------------+-------------------------+
        |                    |                         |
        v                    v                         v
LAN event gateway      optional Relay/FCM       notification_sync
        |                    |                         |
        v                    v                         |
Native LAN owner       FirebaseMessagingService       |
        |                    |                         |
        +----------+---------+-------------------------+
                   |
                   v
       atomic eventId dedupe + native renderer
                   |
                   v
          displayed receipt / cursor ack
```

产品应提供三种明确模式，而不是用一个含糊的“后台保活”开关覆盖所有语义：

| 模式 | 及时路径 | 最终补偿 | 互联网 | 常驻通知 | 结论 |
|---|---|---|---|---|---|
| 恢复补偿 | 无持续后台 socket | outbox + cursor | 不需要 | 不需要 | 只保证恢复后不漏 |
| 纯 LAN 实时 | 原生 LAN owner | outbox + cursor | 不需要 | 需要 | 无互联网实时的唯一可行主方案 |
| 混合可靠 | LAN 优先，FCM 兜底 | outbox + cursor | FCM 兜底需要 | 可选 | 默认推荐 |

默认决策：实现共享持久事件层，再实现原生 LAN owner；产品默认采用“LAN 优先 + FCM
可选兜底 + cursor 补偿”。用户明确要求无互联网后台实时并接受常驻通知时，才启用
`connectedDevice` FGS。没有 FGS 时不得承诺 Android 进程被回收后的纯 LAN 实时唤醒。

## 2. 目标、非目标与可靠性口径

### 2.1 目标

1. Bridge 已产生并持久化的任务完成、等待输入事件，在保留期内不得静默丢失。
2. Android 原生 LAN owner 已处于 `READY` 且网络稳定时，事件无需经过 Relay 即可显示。
3. Wi-Fi 切换、DHCP 换址或 AP 漫游后，原生层能按稳定 Bridge 身份重新发现并恢复。
4. 前后台连接交接允许短暂重叠，但不允许出现无人负责且无法补偿的空窗。
5. 同一 installation 上，同一 `eventId` 最多显示一次可见通知。
6. App、Service 或 Bridge 重启后，按连续 cursor 从最后安全位置补齐事件。
7. 多台 Bridge 各自维护凭据、订阅、cursor 和诊断，不再只监控当前 active device。
8. 纯局域网实时模式不依赖 GMS、Relay、Flutter engine 或长期 Dart timer。
9. 混合模式在 LAN 不可达时可切换 FCM，LAN 恢复后自动回到本地优先路径。
10. 每个失败都能定位到事件生成、落盘、发现、鉴权、同步、显示或回执阶段。

### 2.2 非目标

以下情况不承诺实时通知或永久在线：

- 用户执行系统“强制停止”或 Android 13+ Active apps 的 Stop。
- 用户关闭通知、局域网权限或产品中的后台实时开关。
- OEM 明确禁止应用后台运行，用户也未授予厂商要求的例外。
- 手机和 Bridge 不在同一可达网络，且没有启用或无法使用 FCM 兜底。
- AP 开启 client isolation、企业网络过滤 mDNS/端口，且没有可用已知地址或云端兜底。
- Bridge 在整个任务期间都未运行且上游 source 无法重放事件；outbox 不能凭空恢复未观察事件。
- 用 UDP 广播、周期 WorkManager、exact alarm、静音音频或无限 wake lock 绕过平台限制。
- 初版把完整聊天、控制租约、文件传输或 P2P 数据面迁移到 Kotlin。
- 本计划不建立 iOS/macOS 后台 LAN 实时保证；它们需要独立平台方案。

### 2.3 SLO 与验收前提

SLO 从 Bridge 的 `persistedAt` 开始计时，到 Android 原生层记录
`notification_displayed` 为止。以下数值是产品验收目标，不是 Android 平台保证。

| 指标 | 目标 | 适用前提 |
|---|---|---|
| LAN 可见通知延迟 | P95 <= 1s，99% <= 5s | Service `READY`、通知允许、稳定 LAN |
| LAN 恢复时间 | P95 <= 10s，99% <= 30s | Wi-Fi 已可用、Bridge 可发现且凭据有效 |
| 最终补偿 | 保留期内 100% 连续补齐 | Bridge 已持久化事件且 App 再次连接 |
| 可见去重 | 每 installation/eventId 最多 1 次 | 任意 LAN/FCM/Dart 乱序和重复 |
| 交接空窗 | 0 个不可补偿事件 | 前后台切换、Activity 销毁、回调乱序 |
| 长时稳定 | 8h 无 silent stuck | Pixel、One UI、HyperOS 真机 |
| 空闲资源 | 平均 CPU < 1%，8h 增量耗电 <= 4 个百分点 | 单 Bridge、屏幕关闭、无业务事件 |
| 空闲流量 | <= 15KiB/min/Bridge | 心跳、状态回执和必要发现流量 |

SLO 排除 force-stop、Active apps Stop、权限被拒、手机无可用网络、Bridge 关机和平台明确
阻止启动的场景。排除项也必须进入诊断状态，不能伪装成“已连接”。

## 3. 当前实现与缺口

### 3.1 当前路径

当前 Android 后台路径由三部分组成：

- Flutter `NotificationController` 在前台连接时启动 `dataSync` FGS。
- App 进入后台时，将当前 active device 的固定 host/token/source 交给 `BridgeWatcher`。
- `BridgeWatcher` 建立只读 OkHttp WebSocket，跟踪 `agent_start`、`agent_end`、
  `agent_settled` 和会话快照，并直接调用 `NotificationManager`。

可复用的基础包括：

- `BridgeWatcher` 已有 run/socket generation fence、1-15s 重连和 Wi-Fi 专用
  `socketFactory`。
- Bridge 已在 `bridge/src/server.ts:621-636` 维护 authoritative streaming 边沿。
- Dart 已有 mDNS、子网扫描、`hubId` 匹配和前台 DHCP 地址自愈。
- 客户端已有 source cursor、gap 检测、分页重放和全量 snapshot 回退。
- Android 已有通知渠道、通知权限、FGS 常驻通知和任务通知入口。
- 多设备 roster 已能同时维护多台 Bridge 的前台连接。

### 3.2 当前 watcher 的可靠性缺口

1. `lib/state/notification_controller.dart:43` 明确排除 P2P，只覆盖 active LAN device。
2. `notification_controller.dart:158` 的后台 streaming 基线只在 Dart 内存中。
3. `BridgeWatcher.kt:82-84` 的 task baseline 同样只在进程内存中。
4. watcher 断线期间任务若完整经历 `idle -> streaming -> idle`，重连后的
   `hub_list_sessions` 只有最终 idle，无法证明发生过完成事件。
5. watcher 持有切后台时传入的固定 host；Dart 被暂停后不会继续 mDNS/DHCP 自愈。
6. `MainActivity.kt:43-66` 在提交 `BridgeWatcher.start()` 后立即返回成功，不代表已收到
   `bridge_hello`、完成 source 订阅或追平事件。
7. `notification_controller.dart:371` 可能因此过早抑制 Dart 的完成通知。
8. Dart、watcher 分别使用 100/200 段递增通知 ID，没有共同 `eventId`，无法跨路径去重。
9. watcher 只订阅 selected source，其他 source、其他设备和等待输入仍依赖 Dart。
10. 断线重连只有状态快照补判，没有独立通知事件序列和 ack cursor。

### 3.3 当前 FGS 不是连接 owner

- `KeepAliveService` 只保存内存计数、常驻通知和 partial wake lock。
- `KeepAliveService.kt:125` 返回 `START_NOT_STICKY`。
- `KeepAliveService.kt:128-131` 在任务从最近任务列表移除时主动停止。
- Manifest 使用 `stopWithTask="true"` 和 `foregroundServiceType="dataSync"`。
- Service 无法在空 Intent 重启时重建目标设备、凭据、cursor 或 WebSocket。
- 真正 owner 仍是 Activity 内 Flutter 生命周期和一个进程级 `BridgeWatcher` object。

因此只改 `START_STICKY` 或 `stopWithTask` 会产生“有常驻通知但没有真实 owner”的空服务。

### 3.4 Bridge 事件与身份不够持久

- `SourceRegistry.hubId` 每次 Bridge 进程启动都会重新生成 UUID。
- source 事件 ring、`streamingBySource` 和 generation 状态都在内存中。
- 当前 op-log 只是结构参考：`appendFileSync` 后未 `fsync`，写入错误被吞掉。
- 现有 `hub_sync` 面向完整 source 状态，不等价于持久、低敏、可见通知事件流。
- 没有 per-installation delivery state、连续 notification cursor 或 display receipt。

### 3.5 Android 平台边界

- Android 15+ 对 `dataSync` FGS 有每 24 小时累计 6 小时限制。
- `connectedDevice` 适用于通过网络与外部设备持续交互，但必须真实符合业务语义、声明
  `FOREGROUND_SERVICE_CONNECTED_DEVICE` 并完成 Play Console 申报。
- 当前 Manifest 已声明 `CHANGE_NETWORK_STATE` 和 `CHANGE_WIFI_MULTICAST_STATE`，满足
  `connectedDevice` 官方运行前提之一，但仍缺 service type 权限和合规审查。
- Android 16 可通过兼容开关试运行 Local Network Protection。
- Android 17、target SDK 37+ 将强制 `ACCESS_LOCAL_NETWORK` 运行时权限；TCP、UDP、
  mDNS、`.local`、OkHttp 和 `NsdManager` 上层访问都必须正确处理授权或系统 picker。
- 进程被杀且没有合规运行的 FGS 时，普通 WebSocket、UDP 广播和 WorkManager 都不能提供
  可靠实时唤醒。

官方依据：

- <https://developer.android.com/develop/background-work/services/fgs/service-types>
- <https://developer.android.com/develop/background-work/services/fgs/timeout>
- <https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping>
- <https://developer.android.com/privacy-and-security/local-network-permission>
- <https://developer.android.com/develop/connectivity/wifi/use-nsd>
- <https://developer.android.com/training/monitoring-device-state/doze-standby>

## 4. 目标架构与职责边界

### 4.1 共享控制面、可替换传输面

LAN 与 P2P 只在投递方式上不同。以下内容必须共用一份实现：

- Bridge event detector、task generation 和稳定 sequence。
- 持久 notification event store、compaction、TTL 和 crash recovery。
- `notification_sync/events/ack/cursor_expired` 协议。
- Android installation identity、cursor store、eventId dedupe 和 native renderer。
- 可观测阶段、错误码、feature flags 和兼容策略。

以下内容是 LAN 专属适配器：

- Android `NsdManager`/mDNS 发现、地址候选与 NetworkCallback。
- 按 Android `Network.socketFactory` 路由的 OkHttp WebSocket。
- 原生 LAN connection owner、FGS 生命周期和 Flutter handoff。
- LAN receipt 优先与 FCM fallback 仲裁。

### 4.2 组件职责

| 组件 | 权威职责 | 不负责 |
|---|---|---|
| Bridge event detector | 从 source 事件生成唯一业务通知事件 | 猜测 Android 是否显示成功 |
| Notification event store | sequence、append/fsync、replay、TTL、cursor | 维持手机进程 |
| LAN event gateway | 鉴权、订阅、固定 tip 补偿、实时推送、ack | 控制租约和写命令 |
| Native LAN owner | 发现、路由、连接、同步、心跳、恢复 | 聊天数据面和 P2P/WebRTC |
| Native deduplicator | 原子 claim、显示状态、稳定 notification ID | 依赖 Flutter 才工作 |
| Native renderer | 渠道、隐私、通知点击和取消 | 生成业务事件 |
| Flutter | 设置、前台数据连接、诊断 UI、交接协调 | 后台通知唯一 owner |
| Relay/FCM | LAN 失败时可选唤醒与投递 | LAN 正常时的默认绕路 |

### 4.3 三层保证

1. **LAN direct** 提供低延迟，不经过公网。
2. **FCM fallback** 提供进程唤醒和离网兜底，但只在已配置时可用。
3. **durable cursor** 提供最终一致性，不把实时路径的成功当作删除事件的依据。

三层使用同一 `eventId`。任何一层都不能通过创建另一条“近似完成事件”绕过去重。

## 5. 产品模式与状态机

### 5.1 恢复补偿模式

适用：用户不接受常驻通知，或设备不满足 FGS/推送条件。

- App 前台使用现有 Dart LAN 连接。
- App 进入后台后不承诺持续 socket。
- Bridge 继续持久化事件。
- App 下次打开或可运行时按 cursor 补齐。
- 可以显示“后台期间有 N 个事件”，但不得伪装成实时到达。

### 5.2 纯 LAN 实时模式

适用：用户要求无互联网仍实时，并主动开启“持续局域网连接”。

- 原生 Service 成为 LAN notification connection owner。
- 使用合规的 `connectedDevice` FGS 和持续可见通知。
- 不依赖 Relay、FCM、GMS 或 Flutter isolate。
- Service 被允许运行时直接显示；被系统回收后按平台允许条件重启并 cursor 补偿。
- force-stop、Active apps Stop 和 OEM 硬冻结仍不保证。

### 5.3 混合可靠模式

适用：大多数有 GMS/互联网的 Android 安装，默认推荐。

- LAN `READY` 时先走本地直连。
- 无 `READY` 订阅或 LAN receipt 超时后走 FCM。
- LAN 和 FCM 同时到达时，原生 eventId 去重。
- 两者都失败时，下一次连接按 cursor 补齐。
- Relay 不可用不影响本地 LAN 路径。

### 5.4 原生连接状态

```text
DISABLED
   |
   | user enables / valid paired target
   v
STARTING -> DISCOVERING -> CONNECTING -> AUTHENTICATING -> SYNCING -> READY
   ^             |             |              |              |        |
   |             +-------------+--------------+--------------+--------+
   |                          recoverable failure
   |
   +-- BLOCKED_PERMISSION / BLOCKED_POLICY / STOPPED_BY_USER
```

约束：

- 只有 `bridge_hello` 身份校验、订阅成功并追平固定 tip 后才能进入 `READY`。
- `socket.onOpen` 不是 `READY`。
- 每个状态带 `generation`；旧连接回调不能覆盖新 generation。
- 超过恢复预算后进入显式 degraded 状态，不能一直显示“已连接”。

## 6. 身份、订阅与交接

### 6.1 身份模型

| 身份 | 生成与存储 | 用途 |
|---|---|---|
| `bridgeInstallationId` | Bridge 首次启动生成高熵随机值，0600 持久化 | DHCP 后识别同一 Bridge、事件命名空间 |
| `eventEpoch` | notification store 创建时生成并持久化 | 检测事件库重置，避免 cursor 误接 |
| `installationId` | Android 原生首次安装生成，no-backup 加密存储 | 每安装 cursor、去重和投递状态 |
| `DeviceProfile.id` | Flutter roster 本地稳定 ID | UI/profile 映射，不作为 Bridge 身份 |
| `sourceId` | Bridge source registry | 事件来源与深链定位 |
| `sessionId` | Pi session | 会话定位，不作为 delivery owner |
| `clientId` | 连接/租约身份 | 现有 hub 协议，不替代 installationId |

规则：

- 不再把进程级随机 `hubId` 当作跨重启 Bridge 身份。
- mDNS TXT 的 `bridgeInstallationId` 只是发现提示，必须在已鉴权 `bridge_hello` 中复核。
- Bridge 配置被清空后生成新 ID；Android 将旧 cursor 标记 orphaned，并要求重新确认配对。
- 每个 cursor 键为 `bridgeInstallationId + eventEpoch + installationId`。
- 多台 Bridge 的 token、endpoint、cursor 和 eventId store 严格隔离。

### 6.2 订阅范围

通知订阅不应等同于 UI 当前 selected source。建议 schema：

```json
{
  "installationId": "inst-...",
  "scopeVersion": 3,
  "scopes": {
    "sourceIds": ["source-a", "source-b"],
    "eventTypes": ["task_completed", "input_required"]
  }
}
```

- 默认订阅该 Bridge 上用户授权的所有 source，而不是只订阅当前页面。
- source 新增/删除时生成新的 scopeVersion，但不重置全局 event cursor。
- cursor 遍历 Bridge 的全局 sequence；被当前 scope 排除的 sequence 由 Bridge 标记为
  server-side skipped，并纳入响应的 `through/skippedRanges`，Android 不把它误判为丢包。
- Android 只 ack 已收到的事件与 Bridge 明确声明的 skipped range 组成的连续前缀。
- 订阅收窄后不再显示被排除事件，但历史 cursor 继续推进。
- scope 扩大默认只对新 scopeVersion 生效后的未来事件生效；若产品需要补发旧事件，必须
  创建独立 replay 请求或 cursor namespace，不能偷偷回退现有 cursor。
- Bridge 必须先做权限过滤，再构造 installation 可见事件页；skipped range 不能泄露
  被过滤事件的正文、类型或 source。

### 6.3 前后台 handoff

后台交接：

1. Flutter 在仍可见且连接有效时，将 target、scope 和最后 cursor 写入原生持久 store。
2. 用户已启用实时模式时，确保 Service 在前台资格窗口内启动。
3. Native owner 建连、鉴权、固定 tip catch-up 并进入 `READY`。
4. 通过 MethodChannel/event stream 回报 `ready(generation, bridgeId, tip)`。
5. Flutter 只在收到匹配 generation 的 ready 后停止自己的后台通知 ownership。
6. 交接期间允许两条连接重叠；eventId dedupe 处理重复，不允许先断 Dart 再等 Native。

回前台交接：

1. Dart 连接并按 cursor/snapshot 恢复 UI 状态。
2. Dart 确认已追平后声明 foreground ready。
3. Native 停止该订阅或降为 standby；旧回调受 generation fence 丢弃。
4. 若 Dart 恢复失败，Native 保持 owner，不制造通知空窗。

Activity 在交接中被销毁时，Service 继续使用已持久化 target，不能依赖未完成的 MethodChannel。

## 7. 事件模型与生成规则

### 7.1 不可变业务事件

```ts
interface NotificationEventV1 {
  schema: 1;
  bridgeInstallationId: string;
  eventEpoch: string;
  eventId: string;             // UUID v4，永久去重键
  sequence: number;            // eventEpoch 内单调递增、安全整数
  taskGenerationId?: string;   // 同一轮 agent_start/end/settled 去重
  sourceId?: string;
  sessionId?: string;
  type: "task_completed" | "input_required" | "input_resolved";
  createdAt: string;
  expiresAt: string;
  priority: "high" | "normal";
  collapseKey?: string;
  presentation: {
    title: string;
    body?: string;
    privacy: "generic" | "session_name";
  };
}
```

业务事件不可混入 installation 投递状态。多 installation 状态单独保存：

```ts
interface InstallationDeliveryV1 {
  eventId: string;
  installationId: string;
  lan: {
    state: "not_connected" | "queued" | "sent" | "received" | "displayed";
    sentAt?: string;
    receiptAt?: string;
  };
  push: {
    state: "disabled" | "pending" | "accepted" | "failed" | "expired";
    keyId?: string;
    encryptedPayload?: string;
    attempts: number;
    nextAttemptAt?: string;
  };
}
```

### 7.2 task generation

- `agent_start` 创建并持久化新的 `taskGenerationId`。
- 同一 generation 的 `agent_end` 和 `agent_settled` 只生成一个 `task_completed`。
- 重复 desktop/source 事件不得生成新 eventId。
- Bridge 重启后从 journal 恢复 in-flight generation；随后结束事件沿用原 generation。
- 若重启时只有 authoritative snapshot 显示 streaming，创建带 recovery 标记的 generation。
- source epoch 切换必须显式结束或作废旧 generation，不能串到新会话。

### 7.3 等待输入

- `extension_ui_request` 以稳定 requestId 生成 `input_required`。
- request 被回答、取消或过期时生成 `input_resolved`，用于更新/取消原通知。
- 重复 request frame 使用同一 eventId 或同一 collapseKey，不刷多条通知。
- presentation 默认不包含用户输入、完整 agent 输出、文件路径或敏感正文。

### 7.4 本地连接提醒

“连接中断”是 installation 本地状态，不作为 Bridge 业务完成事件：

- Native owner 连续失败超过阈值后生成本地 collapse 通知。
- 恢复后取消同一 notification ID。
- 短暂网络切换不弹高优先级通知。
- 本地状态不得推进 Bridge event cursor。

### 7.5 无法恢复的源缺口

Bridge outbox 只能保护 Bridge 已观察到的事件。如果 Bridge 在整个任务期间离线，且 source
重连后只给最终快照而不能重放 start/end，则系统必须记录 `source_event_gap`，不能伪造一个
完成通知。后续可通过持久 source log 或 session entry 重新建立 generation，这是独立 Gate。

## 8. LAN 通知协议

### 8.1 能力协商

`bridge_hello` 增加：

```json
{
  "type": "bridge_hello",
  "bridgeInstallationId": "bridge-...",
  "capabilities": ["notification_events_v1", "notification_receipts_v1"]
}
```

旧 Bridge 不支持能力时，Native owner 回退当前 watcher 或恢复补偿模式，不发送未知帧。

### 8.2 订阅与固定 tip catch-up

```text
native -> bridge
notification_subscribe {
  id,
  schema: 1,
  installationId,
  cursor: { eventEpoch, sequence } | null,
  scopes,
  scopeVersion,
  pageLimit: 100
}

bridge -> native
notification_events {
  id,
  eventEpoch,
  scopeVersion,
  fromExclusive,
  through,
  tip,
  events: [...],
  skippedRanges: [{ from, through }],
  hasMore
}
```

规则：

- Bridge 处理 subscribe 时先捕获固定 `tip`，再注册实时缓冲。
- catch-up 遍历 cursor 之后、tip 以内的连续全局 sequence；匹配 scope 的事件进入
  `events`，被 scope 排除的部分合并为 `skippedRanges`，两者共同覆盖到 `through`。
- Android 必须校验 events + skippedRanges 从 `fromExclusive + 1` 连续覆盖到 `through`；
  有未知缺口时停止 ack 并请求 resync。
- scopeVersion 与客户端请求不一致时返回显式 `scope_changed`，禁止用旧过滤规则推进 cursor。
- 新产生的事件进入该 subscription 的 live buffer，不能插入当前分页中间。
- `hasMore=false` 后先排空 live buffer，再发 `notification_ready`。
- 单页默认最多 100 条且 JSON 编码后不超过 64KiB；至少允许一条超预算事件返回显式错误。
- live buffer 默认最多 256 条或 1MiB；溢出返回 `resync_required`，禁止静默丢头部。

### 8.3 Ready 语义

```json
{
  "type": "notification_ready",
  "subscriptionId": "...",
  "bridgeInstallationId": "...",
  "eventEpoch": "...",
  "through": 130,
  "generation": 42
}
```

只有以下条件全部满足才发送：

- mobile token 鉴权成功并校验 Bridge 身份。
- notification subscription 已注册。
- 固定 tip catch-up 完成。
- Android 已确认所有 `through` 之前事件安全落入本地 dedupe store。
- 发送端已建立实时事件缓冲，catch-up 与 live 之间无空窗。

### 8.4 连续 ack

```text
native -> bridge
notification_ack {
  installationId,
  eventEpoch,
  through: 130
}
```

- ack 只表示 `<= through` 的所有可见事件已被 Android 安全处理或明确过滤。
- 先收到 130、缺少 129 时不得 ack 130。
- 旧 ack 幂等，不能回退 server cursor。
- 超过当前 tip、epoch 不匹配或 installation 不匹配时返回显式错误。
- ack 与用户点击/阅读无关，不能用 read receipt 替代。

### 8.5 显示 receipt

```text
native -> bridge
notification_receipt {
  installationId,
  eventId,
  state: "received" | "displayed" | "suppressed_duplicate" | "blocked_permission",
  at
}
```

receipt 用于 LAN/FCM 仲裁和指标，不负责推进连续 cursor。网络暂时不可用时先在本地持久化，
随后通过 LAN 或 WorkManager 上传。

### 8.6 Cursor 过期与事件库重置

```text
bridge -> native
notification_cursor_expired {
  eventEpoch,
  oldestAvailable,
  currentTip,
  reason: "retention" | "store_reset" | "identity_changed"
}
```

- retention 过期时从 `oldestAvailable` rebase，并显示可诊断的历史缺口计数。
- event store 重置必须生成新 `eventEpoch`，不能沿用旧 sequence。
- authoritative session snapshot 只能恢复当前状态，不能声称恢复已过期的完成边沿。
- rebase 后将本地 cursor 原子写入，不得在崩溃窗口跳过未处理事件。

### 8.7 心跳与断线

- OkHttp `pingInterval` 建议 15s，服务端协议心跳继续保留。
- 任意有效 pong/业务帧更新 `lastInboundAt`，但无关帧不能延长 request-level timeout。
- 35s 无有效 inbound 或 socket failure 时进入恢复状态。
- 断线不清空本地 cursor、eventId 表或 endpoint 候选。

## 9. Bridge 持久事件存储

### 9.1 与 P2P 计划共用一个 store

不得为 LAN 再建第二套 outbox。建议共享模块：

```text
bridge/src/notification_event.ts
bridge/src/notification_event_store.ts
bridge/src/notification_protocol.ts
bridge/src/notification_delivery.ts
bridge/test/notification_event_store.test.ts
bridge/test/notification_protocol.test.ts
```

存储路径沿用 P2P 计划约定的
`~/.pi/agent/pipilot/notification-outbox-v1.jsonl`，但 journal 内区分：

- immutable event record
- task generation state
- per-installation ack
- per-installation delivery transition
- tombstone/expiry

### 9.2 持久化要求

- 目录权限 `0700`，文件权限 `0600`。
- 所有写入经过单一串行 writer，禁止多个回调直接并发 append。
- event 必须 append、校验并 `fsync/fdatasync` 成功后才能进入 LAN/Relay 发送队列。
- 每条记录带 schema、长度和 checksum；尾部半条记录可忽略但必须告警。
- write/fsync 失败必须保留内存 pending、停止宣称 persisted，并持续结构化诊断。
- 超过 16MiB、10,000 条或 tombstone 30% 时压缩。
- 压缩使用同目录临时文件、fsync、原子 rename，再 fsync 目录。
- 默认事件保留 7 天；未 ack installation 也不能无限阻止 TTL。
- 默认保留最近 2,048 条 eventId 去重元数据，避免重放生成新 ID。

### 9.3 重启恢复

启动时按顺序恢复：

1. `bridgeInstallationId`、`eventEpoch` 和最后 sequence。
2. in-flight task generation。
3. 未过期业务事件。
4. installation ack 与 delivery state。
5. LAN subscription 从空开始；客户端重连后按 cursor 补齐。
6. Relay pending publisher 独立恢复，不阻塞 LAN gateway 启动。

### 9.4 不能复用当前 op-log 的原因

当前 `bridge/data/op-log.jsonl` 没有 fsync、checksum、原子 compaction 和显式写失败处理。
它可作为 append-only 形态参考，但不能直接承载通知可靠性承诺。

## 10. 原生发现、地址与网络路由

### 10.1 Bridge mDNS 广告

沿用 `_pipilot._tcp`，建议 TXT 只包含非秘密元数据：

```text
bridgeId=<bridgeInstallationId>
v=<bridge protocol version>
notify=1
ipv4=<physical LAN IPv4, optional>
tlsKeyId=<optional pinned identity key id>
```

禁止放入 mobile token、pairing secret、session 名称、路径或 installationId。

### 10.2 原生发现策略

Native owner 不复用依赖 Flutter engine 的 `bonsoir` 实例，使用 Android `NsdManager`：

1. 优先尝试上次已验证 endpoint，避免每次都启动昂贵 discovery。
2. 首次失败、Network 变化或身份不匹配时启动 `_pipilot._tcp` discovery。
3. 只接受 TXT/hello 的 `bridgeInstallationId` 与目标一致的服务。
4. resolve 后保存多个 IPv4/IPv6 candidate，不把 service name 当身份。
5. 成功鉴权后原子更新 last-known endpoint。
6. 进入 `READY` 后停止持续 NSD；只保留 NetworkCallback，故障时再短期开启发现。
7. mDNS 不可用时继续有界重试 last-known endpoint；后台不执行持续 `/24` 扫描。
8. 子网扫描只允许用户在前台显式触发，避免后台耗电和网络告警。

### 10.3 DHCP 与网络变化

注册 `ConnectivityManager.NetworkCallback` 观察：

- Wi-Fi available/lost
- `LinkProperties` 地址、DNS 和 interface 变化
- NetworkCapabilities 的 Wi-Fi/VPN 变化

处理规则：

- 相同 callback burst 500ms 防抖。
- Wi-Fi 丢失立即关闭绑定该 Network 的 socket，旧 generation 作废。
- 新 Wi-Fi 可用时跳过普通退避，立即尝试 last-known endpoint 并启动 mDNS。
- mDNS 发现同一 bridgeId 的新 host/port 时立即切换，不等待旧地址 30s timeout。
- endpoint 来自 Wi-Fi NSD 时，只给该 OkHttp client 使用 `network.socketFactory` 和 DNS。
- 不调用全进程 `bindProcessToNetwork`，避免影响 Flutter P2P、Relay 和其他 Bridge。
- 手工配置的 VPN/Tailscale 地址按实际 route 选择，不应强制绑定物理 Wi-Fi。
- IPv6 URL 正确加方括号；link-local 地址保留 Android scope，不持久化无 scope 的裸地址。

### 10.4 重连节奏

普通连接失败使用 full jitter：

```text
0s, 1s, 2s, 4s, 8s, 15s, 30s cap
```

以下事件重置退避并立即尝试：

- 新 Network available
- mDNS resolve 到新 endpoint
- token/profile 更新
- Service 从系统重启恢复
- 用户主动点击重连

鉴权失败不进入无限快速重试；暂停该 target，并要求重新配对或刷新 token。

### 10.5 Android 16/17 局域网权限

- 当前 target SDK 35 下继续使用现有权限行为。
- Android 16 测试阶段启用 `RESTRICT_LOCAL_NETWORK` compat flag，提前发现超时/EPERM。
- target SDK 36 opt-in 测试 `NEARBY_WIFI_DEVICES` 路径。
- target SDK 37+ 声明并运行时请求 `ACCESS_LOCAL_NETWORK`，或评估系统 NSD picker。
- 权限拒绝/撤销进入 `BLOCKED_PERMISSION`，关闭 LAN socket 并切换 FCM/cursor；不能把它
  记录为普通网络超时。
- 设置页显示局域网权限状态和跳转入口，不反复弹请求。

## 11. Android 原生 connection owner

### 11.1 组件拆分

建议文件：

```text
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeLanConnectionService.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/LanConnectionCoordinator.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/LanConnectionState.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeLanDiscovery.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeCredentialStore.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeCursorStore.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NotificationDeduplicator.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeNotificationRenderer.kt
```

职责：

- Service 管生命周期、FGS 和用户 Stop action。
- Coordinator 管多 target 状态机、generation、WebSocket 和 handoff。
- Discovery 管 NSD、NetworkCallback 和 endpoint candidates。
- Credential/Cursor store 提供原子、no-backup、Keystore-backed 持久化。
- Deduplicator/Renderer 被 LAN、FCM 和 Dart 共用。

`BridgeWatcher` 最终迁移为这些组件的兼容适配器，不继续扩张单例 object。

### 11.2 持久 BackgroundLanState

```kotlin
data class BackgroundLanTarget(
    val profileId: String,
    val bridgeInstallationId: String,
    val host: String,
    val port: Int,
    val tokenRef: String,
    val scopes: Set<String>,
    val enabled: Boolean,
)
```

- token 正文不直接放普通 SharedPreferences；使用 Android Keystore 包装的加密 store。
- target 更新采用临时文件/transaction 后原子替换。
- Service 只保存 token reference，日志永不输出 token。
- 删除设备或重新配对时撤销旧 target、cursor 和 subscription。

### 11.3 FGS Gate

只有以下条件全部满足才启用 `connectedDevice`：

- 用户在前台明确开启“持续局域网连接”。
- 至少一台已配对 Bridge 启用后台监控。
- Service 实际维护与外部桌面设备的网络交互，不是空壳或只等 FCM。
- 声明 `FOREGROUND_SERVICE_CONNECTED_DEVICE` 和匹配 service type。
- 运行前提和 Local Network 权限满足。
- 常驻通知展示目标设备数、连接状态和“停止”操作。
- Play Console FGS 类型申报与审核材料通过。

`connectedDevice` 不能只是规避 `dataSync` 6 小时限制的标签替换。

### 11.4 Service 启动与重建

1. 用户启用或前台连接成功时，在 Activity 可见窗口启动 Service。
2. `onStartCommand` 后立即创建准确的 FGS 通知并在时限内 `startForeground()`。
3. 加载持久 targets/cursors，校验权限，再启动 owner。
4. 只有 owner 能从空 Intent 重建后才返回 `START_STICKY`。
5. `stopWithTask=false` 只在上述重建能力完成后启用。
6. 用户点击 Stop 时记录 `stoppedByUser=true`、关闭 socket、清理 ongoing 通知并
   `stopSelf()`；系统不得自动重启。
7. 没有有效 target、通知权限或 FGS Gate 失败时立即停止，不保留空服务。
8. `onDestroy` 关闭 discovery、NetworkCallback、socket 和短期 wake lock，但保留 cursor。

P0 不实现开机自动启动。后续若增加 `BOOT_COMPLETED`，必须重新评估后台 FGS 启动资格、
用户 opt-in 和 OEM 行为。

### 11.5 Wake lock 策略

- 不把无限 `PARTIAL_WAKE_LOCK` 当作连接可靠性的根基。
- FGS + 原生 scheduler 管正常 WebSocket 回调和心跳。
- 仅在处理批量 catch-up、重连或落盘时申请有明确 timeout 的短期 wake lock。
- 所有 acquire/release 进入诊断；异常退出不得遗留引用。
- 真机验收必须包含 OEM 禁用 wake lock 后的路径。

### 11.6 无 FGS 时的明确降级

没有运行 FGS 时：

- 可以在进程仍存活期间临时维护 native watcher。
- 进程被系统杀死后，纯 LAN 没有可靠实时唤醒机制。
- WorkManager 只适合延后 cursor sync/receipt，不是实时 socket owner。
- UDP/mDNS 广播不能可靠拉起已死亡进程，也不应新增 exported receiver 扩大攻击面。
- UI 必须写成“恢复后补齐”，不能显示“后台实时已开启”。

## 12. 原生通知、去重与隐私

### 12.1 统一渲染入口

Android 上所有路径统一调用：

```text
NotificationDeduplicator.claim(event)
        -> NativeNotificationRenderer.display(event)
        -> markDisplayed(eventId)
```

Dart 后台通知也应通过 MethodChannel 携带 eventId 调用同一入口，不再自己分配递增 ID。
非 Android 平台保留各自插件实现。

### 12.2 原子去重状态

本地表以 `installationId + bridgeInstallationId + eventId` 为唯一键，状态为：

```text
pending -> displayed
        -> suppressed
        -> blocked
```

- claim 和状态写入必须原子。
- 崩溃发生在 claim 后、display 前时，重启后允许重试 stale pending，不能永久吞通知。
- displayed 事件再次到达时记录 `suppressed_duplicate`，不再次震动或弹横幅。
- 默认保留 7 天或 2,048 条；清理时保留仍在通知栏中的 ID 映射。

### 12.3 Notification ID

- FGS 固定 ID `1` 保留。
- 业务通知 ID 由 eventId 稳定 hash + collision map 生成。
- 相同 task 状态更新复用 ID；不同 task completion 不 collapse。
- input resolved 使用原 eventId/collapseKey 更新或取消等待输入通知。
- 点击 PendingIntent 带 bridge/profile/source/session 深链，但不带 token。

### 12.4 权限和锁屏隐私

- `POST_NOTIFICATIONS` 被拒时记录 `blocked_permission`，仍可推进已安全处理的 cursor。
- 用户选择 `generic` 时只显示“PiPilot 有新事件”。
- `session_name` 模式可显示会话名，但不显示提示词、agent 输出和路径。
- FGS 常驻通知使用 private visibility；任务通知按产品隐私设置决定。
- 通知渠道被系统关闭必须单独诊断，不能只检查 runtime permission。

## 13. 多设备策略

### 13.1 一项 Service、多个 target

- 全 App 只运行一个 `NativeLanConnectionService`，内部管理连接池。
- 每台 DeviceProfile 有独立“后台监控”开关、Bridge ID、token、cursor 和状态。
- 默认 active device 开启；其他设备由用户明确开启或迁移现有通知偏好。
- 不为每台 Bridge 启动独立 FGS 和常驻通知。

### 13.2 资源预算

P0 默认最多同时维护 4 条 `READY/CONNECTING` LAN socket：

- active device 优先。
- 正在运行任务的设备优先。
- 其余已启用设备按最近活跃排序。
- 超出上限的设备进入 FCM fallback 或 cursor-only，并在设置页显示原因。
- 上限必须通过 8h 功耗测试后再调整，不能随 roster 无界增长。

### 13.3 每 Bridge 全 source 事件

Native owner 订阅 Bridge 生成的低敏 notification events，而不是复制每个 source 的完整
source event 流。这样一条 Bridge socket 可以覆盖该 Bridge 上所有授权 source，并避免因 UI
selected source 切换而漏通知。

### 13.4 删除、重配与冲突

- 删除 DeviceProfile 时停止 target、撤销 push installation 映射并归档 cursor。
- 同一 bridgeId 被两个 profile 引用时提示合并，禁止重复 socket。
- token 更新使用 profile generation；旧鉴权失败不能覆盖新配置。
- Bridge identity 与 endpoint 冲突时以已鉴权 hello 为准，并记录疑似 spoof/重装诊断。

## 14. LAN 与 FCM 的仲裁

### 14.1 Direct-first 策略

对已注册 FCM 的 installation：

1. LAN subscription `READY` 时先发送 LAN event。
2. 等待最多 2s 的 `received/displayed` receipt。
3. receipt 成功则不发送 FCM。
4. 没有 READY subscription、socket send 失败或 receipt 超时，立即进入 FCM publish。
5. FCM 后续与迟到 LAN event 使用相同 eventId，由 Android 去重。
6. 无 FCM/GMS 时保持 event pending，等待 LAN/cursor 恢复。

2s 是初始产品参数，必须由 P95 LAN receipt 数据校准。

### 14.2 不默认双发 high priority

LAN 正常时并行发送 high-priority FCM 会：

- 浪费配额和电量。
- 让大量高优先级消息因本地已显示而被 dedupe，可能影响 FCM 对“可见通知”的评估。
- 增加重复路径和诊断噪声。

因此采用 receipt 驱动的 bounded fallback，而不是永久双发。

### 14.3 与 P2P 计划的边界

- Relay bootstrap、FCM token、加密 envelope、publisher credential 和 WorkManager receipt
  以 `p2p-plan.md` 为准。
- LAN 计划只定义何时需要 fallback 和如何共享 eventId/delivery state。
- Relay 故障不得阻塞 LAN event gateway 或 Bridge 本地 cursor。
- FCM 不可用时，纯 LAN FGS 模式仍应独立通过验收。

## 15. 认证、安全与本地网络威胁

### 15.1 Read-only notification role

Native LAN owner 使用独立 clientId/role：

```text
role = native_lan_notifier
capabilities = notification_subscribe, notification_ack, notification_receipt
```

Bridge 拒绝该 role 的租约、prompt、abort、文件和 session 变更命令。即使 native client
被错误调用，也不能成为写操作 owner。

### 15.2 凭据存储

- mobile token 从 Flutter 配对结果一次性交给原生 encrypted store。
- 使用 Android Keystore 生成不可导出的 wrapping key。
- token、cursor 和 endpoint 备份策略明确为 no-backup，避免安装克隆身份。
- 日志只记录 profileId/bridgeId 的短 hash，不记录 token、完整 event payload 或 FCM token。
- 删除设备时擦除 token 和 subscription material。

### 15.3 mDNS 不能作为信任根

- mDNS service name、TXT 和 IP 都可被同网设备伪造。
- 必须通过 mobile token 鉴权并核对 `bridgeInstallationId`。
- 身份不符时关闭 socket，不自动覆盖 roster 中的 Bridge ID。
- 连续冲突进入安全诊断，不无限切换两个 endpoint。

### 15.4 明文 LAN 的边界

当前 Bridge 使用 `ws://`，token 和事件对同网被动监听者不提供传输机密性。实施时必须明确：

- 内部/兼容阶段可复用现有 token 鉴权，但不得宣称可防御恶意 LAN。
- 生产安全 Gate 应评估 `wss://` + Bridge 持久证书指纹 pinning，或应用层 AEAD。
- pin 通过配对通道保存；mDNS 只广播 key ID，不直接成为可信 fingerprint 来源。
- IP/DHCP 变化不影响证书 pin，Bridge 重装/换 key 必须由用户重新确认。

TLS hardening 可以独立 rollout，但不得与连接可靠性改造混成无法回滚的一次切换。

### 15.5 输入与资源边界

- WebSocket 单帧、事件页、title/body 和 JSON 深度都有硬上限。
- 不接受未知 schema、过期 event、非法 sequence 或跨 Bridge cursor。
- ack/receipt 按 installation 限速。
- mDNS TXT 长度和字符集严格校验。
- 任何解析失败都不得让 Service 崩溃或进入快速重连循环。

## 16. 失败模式与预期行为

| 失败 | 预期行为 |
|---|---|
| Bridge append 后立即崩溃 | 重启 replay 同一 eventId，不重复生成 |
| outbox fsync 失败 | 不宣称 persisted；保留 pending 并告警 |
| Android 在 claim 前崩溃 | 重连后从旧 cursor 重发 |
| Android 在 claim 后、display 前崩溃 | stale pending 恢复并重试显示 |
| LAN event 重复/乱序 | eventId 去重，cursor 只推进连续前缀 |
| watcher 断线期间任务完整开始并结束 | 持久 event 在重连 cursor 中补回 |
| DHCP 地址变化 | NetworkCallback + NSD 找到同一 bridgeId 并立即切换 |
| mDNS 被 AP 屏蔽 | last-known 有界重试；前台扫描；可选 FCM fallback |
| Wi-Fi -> 蜂窝 | 关闭 LAN socket，切 FCM/cursor，不绑定全进程网络 |
| 蜂窝 -> Wi-Fi | 立即发现/连接，不等待旧退避 |
| token 失效 | target 暂停，提示重新配对；不无限鉴权重试 |
| Bridge identity 变化 | 拒绝静默接管，要求用户确认 |
| cursor retention 过期 | 显式 cursor_expired/rebase，报告历史缺口 |
| Local Network 权限撤销 | BLOCKED_PERMISSION，停止 LAN 并切 fallback |
| 通知渠道关闭 | 不显示，记录 blocked_channel，cursor 仍安全推进 |
| Service 被系统 kill | 平台允许时 sticky 重建并 sync；否则 FCM/下次启动补偿 |
| 普通任务划掉 | realtime 模式 Service 继续；恢复模式不承诺实时 |
| Active apps Stop/force-stop | 明确不保证；用户下次启动后 cursor 补偿 |
| 超过连接池上限 | 低优先 target 降级 push/cursor，并显示诊断 |
| LAN 与 FCM 同时到达 | 原生 dedupe 只显示一次 |
| Relay 离线 | LAN 不受影响；push pending 有界重试 |
| Bridge 整个任务期间离线且 source 不重放 | 记录 source_event_gap，不伪造完成事件 |

## 17. 可观测性与诊断

### 17.1 统一事件阶段

```text
created -> persisted -> lan_queued -> lan_sent -> native_received
        -> notification_displayed -> receipt_sent -> cursor_acked

                         +-> fallback_scheduled -> fcm_accepted -> native_received
```

每个阶段带 `eventId` 的短 hash、bridgeId 短 hash、installationId 短 hash、时间和错误码，
不记录通知正文或凭据。

### 17.2 Bridge 指标

- event_store pending/bytes/oldest_age/compaction/corrupt_tail
- events created by type/source/task generation
- LAN subscriptions ready/connecting/stale/buffered
- LAN send/receipt latency and fallback trigger reason
- cursor page count/gap/expired/rebase/ack lag
- source_event_gap and event generation dedupe

### 17.3 Android 指标

- Service create/start/destroy/restart/taskRemoved/stop reason
- target state/generation/last endpoint/route
- NSD start/resolve/failure/duration
- NetworkCallback cause and address change
- socket open/hello/auth/sync/ready timestamps
- receive/dedupe/display/permission/channel result
- last cursor, pending receipt count, catch-up event count
- FGS type、notification、local network permission 状态
- wake lock duration and reconnect attempts

### 17.4 用户诊断页

每台设备展示：

- 后台模式：恢复补偿 / 纯 LAN 实时 / 混合可靠
- 当前 owner：Flutter / Native LAN / FCM fallback / 无
- LAN 状态和最后 ready 时间
- 已验证 endpoint 与 bridge identity
- 最后 event、display、receipt、cursor
- 通知、局域网、FGS 权限阻塞原因
- 最近一次降级和恢复原因

支持导出脱敏 JSON，不依赖用户截取 logcat。

## 18. 建议实现文件

### 18.1 Bridge 共享基础

```text
bridge/src/notification_event.ts
bridge/src/notification_event_store.ts
bridge/src/notification_generation.ts
bridge/src/notification_protocol.ts
bridge/src/notification_delivery.ts
bridge/test/notification_event_store.test.ts
bridge/test/notification_generation.test.ts
bridge/test/notification_protocol.test.ts
bridge/test/notification_recovery.integration.test.ts
```

### 18.2 Android LAN 路径

```text
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeLanConnectionService.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/LanConnectionCoordinator.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/LanConnectionState.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeLanDiscovery.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeCredentialStore.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeCursorStore.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NotificationDeduplicator.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeNotificationRenderer.kt
android/app/src/test/kotlin/com/pipilot/pi_pilot/LanConnectionStateTest.kt
android/app/src/test/kotlin/com/pipilot/pi_pilot/NativeCursorStoreTest.kt
android/app/src/test/kotlin/com/pipilot/pi_pilot/NotificationDeduplicatorTest.kt
```

### 18.3 Flutter 设置与 handoff

```text
lib/core/background_lan_bridge.dart
lib/state/background_lan_controller.dart
lib/state/background_notification_settings.dart
test/background_lan_controller_test.dart
test/background_notification_settings_test.dart
```

旧 `BridgeWatcher.kt`、`KeepAliveService.kt` 和 `notification_controller.dart` 分阶段迁移，
不要一次删除旧路径，确保 feature flag 可回滚。

## 19. 分阶段实施计划

### Phase 0：契约、指标与产品 Gate

- [ ] 确定三种模式的产品文案、默认值和迁移行为。
- [ ] 固定 bridgeInstallationId/eventEpoch/eventId/sequence/cursor schema。
- [ ] 固定 task generation、事件类型、TTL、presentation 和 receipt 状态。
- [ ] 定义 read-only native notifier role 和 capability negotiation。
- [ ] 建立现有 watcher 的成功率、重复率、延迟、功耗和断线基线。
- [ ] 完成 connectedDevice FGS、Play 申报和 Android 17 局域网权限评审。
- [ ] 建立 feature flags：
  `notification_events_v1`、`native_lan_owner_v1`、`native_lan_display_v1`、
  `connected_device_fgs_v1`、`lan_push_fallback_v1`、`lan_multi_device_v1`。

Gate：协议、产品、安全、Android/Play 评审通过；未决项有明确 owner，不以 TODO 混入实现。

### Phase 1：共享 Bridge event store 与 cursor

- [ ] 实现稳定 bridgeInstallationId 和 eventEpoch。
- [ ] 实现 task generation 与 authoritative event detector。
- [ ] 实现串行 append/fsync/replay/checksum/compaction/TTL。
- [ ] 实现 installation ack 与 immutable event/per-target delivery 分离。
- [ ] 实现 subscribe、固定 tip pages、live buffer、ack、receipt、cursor_expired。
- [ ] 增加 crash-at-every-write-boundary 故障注入。
- [ ] shadow 模式只生成事件和指标，不驱动可见通知。

Gate：随机 kill/restart 1,000 次无已 fsync 事件丢失；同一 generation 不产生重复 eventId；
cursor 分页在乱序、断线和 buffer overflow 下零静默遗漏。

### Phase 2：原生 LAN client 与统一去重

- [ ] 实现 native installationId、credential/cursor/dedupe store。
- [ ] 实现 read-only WebSocket、hello 身份核对、subscribe/catch-up/ready。
- [ ] 实现 NotificationDeduplicator 和 NativeNotificationRenderer。
- [ ] Dart 通知通过 eventId 接入同一原生去重入口。
- [ ] 实现 generation-fenced MethodChannel 状态回报。
- [ ] 先以 shadow receive 运行，不显示通知、不改变 FGS。

Gate：Activity/Flutter engine 不参与时 native fixture 能完整 sync；1,000 次重复/乱序只产生一次
claim；崩溃点覆盖 claim 前、claim 后和 display 后。

### Phase 3：原生发现、地址自愈与 handoff

- [ ] 实现 NsdManager、NetworkCallback 和 endpoint candidate store。
- [ ] 实现 DHCP/IP、Wi-Fi/AP/VPN route 变化的即时恢复。
- [ ] 禁止后台 `/24` 持续扫描和 process-wide network bind。
- [ ] 实现 background/foreground overlap handoff 与 ready Gate。
- [ ] 修复旧 `startWatcher` 提交即成功的问题。
- [ ] 先让新 native owner 接管 active device，旧 watcher 保留 flag 回滚。

Gate：DHCP 换址、Wi-Fi 切换和 Activity 销毁均无不可补偿空窗；身份不符不静默改 host；
网络恢复后达到 10s/30s SLO。

### Phase 4：纯 LAN `connectedDevice` FGS

- [ ] Service 能从原生持久 state 独立重建 owner。
- [ ] 添加 `FOREGROUND_SERVICE_CONNECTED_DEVICE`、service type 和匹配常量。
- [ ] 合规 Gate 通过后设置 `stopWithTask=false`，评估 `START_STICKY`。
- [ ] 增加用户显式 opt-in、准确常驻通知和 Stop action。
- [ ] 移除无限 wake lock 依赖，改为短期有界处理锁。
- [ ] 没有有效 target/权限时不留下空 FGS。
- [ ] 实现系统 kill 后 restore 与 cursor catch-up。

Gate：任务划掉后 Service 仍有真实 owner；系统 kill 后恢复或明确降级；用户 Stop 后不自启；
8h 真机功耗和稳定性达标，Play 合规材料完成。

### Phase 5：混合 LAN + FCM fallback

依赖 `p2p-plan.md` 中 Relay/FCM 基础完成：

- [ ] 实现 LAN ready/receipt 驱动的 direct-first 仲裁。
- [ ] receipt 超时或无 LAN subscription 时触发 FCM。
- [ ] LAN/FCM/Dart 使用同一 eventId 和 delivery state。
- [ ] 验证 FCM 失败不阻塞 LAN，Relay 停机不影响本地事件同步。
- [ ] 校准 2s fallback 窗口和高优先级策略。
- [ ] 无 GMS installation 明确降级到纯 LAN/cursor。

Gate：LAN 正常时不常态双发 FCM；LAN 故障时达到推送 SLO；任意竞态无重复可见通知。

### Phase 6：多设备与生产硬化

- [ ] 一项 Service 管理多 target 连接池和 4 socket 默认预算。
- [ ] 每设备独立模式、scope、cursor、凭据和诊断。
- [ ] 超预算 target 确定性降级到 push/cursor。
- [ ] 完成 Android 16 compat 和 Android 17 local network permission 路径。
- [ ] 完成 ws 明文威胁评审，决定 WSS pinning/应用层加密路线。
- [ ] 加入结构化指标、脱敏导出和运维 runbook。
- [ ] Pixel/One UI/HyperOS 8h 矩阵通过。

Gate：4 Bridge 长时测试满足功耗、流量、恢复和去重预算；权限撤销与身份冲突有明确 UI；
生产安全评审通过。

## 20. 测试矩阵

### 20.1 Bridge 单元与故障注入

- event sequence 单调、task generation 去重、end/settled 顺序互换。
- append 前/后、fsync 前/后、compaction rename 前/后 kill。
- 损坏尾行、checksum 错误、磁盘满、权限错误和 fsync 异常。
- cursor 首次、连续、旧 ack、越界 ack、epoch mismatch、retention expiry。
- 固定 tip 分页期间持续产生事件。
- live buffer 满后 resync_required，不静默丢弃。
- 多 installation ack 不互相推进。
- delivery state 不修改 immutable event。

### 20.2 Android JVM 单元测试

- 连接状态机全部合法/非法 transition。
- run/socket/network/profile generation fence。
- endpoint 候选排序、bridgeId 核对、IPv4/IPv6 URL。
- 重连 backoff/jitter 和 NetworkCallback 立即重试。
- cursor 连续推进、乱序缓存、epoch reset。
- dedupe pending/displayed/stale pending crash recovery。
- notification ID collision map。
- permission/channel/FGS blocked 状态。
- 多 target 连接池优先级和降级。

### 20.3 集成测试

- fake Bridge：hello -> subscribe -> multipage -> live -> ready 无缝衔接。
- 在 catch-up 每一页、ready 前后和 receipt 前后断 socket。
- Bridge 重启后同 bridgeId/eventEpoch replay。
- event store reset 后 cursor_expired。
- mDNS 报旧地址、恶意 bridgeId、重复 service name 和 resolve 失败。
- LAN 与 fake FCM 同 eventId 的所有到达顺序。
- Flutter background/foreground handoff 回调乱序。
- Activity 销毁且 Flutter engine 未启动时 native 仍可显示。
- Relay 故障时 LAN 路径保持可用。

### 20.4 ADB 与网络场景

至少覆盖 Android 13、14、15、16；Android 17 可用后加入：

```bash
adb shell dumpsys deviceidle force-idle
adb shell dumpsys deviceidle unforce
adb shell am kill com.pipilot.pi_pilot
adb shell cmd activity stop-app com.pipilot.pi_pilot
adb shell am compat enable RESTRICT_LOCAL_NETWORK com.pipilot.pi_pilot
adb shell am compat disable RESTRICT_LOCAL_NETWORK com.pipilot.pi_pilot
```

说明：

- `am kill` 用于近似系统回收；`force-stop/stop-app` 属明确不保证场景，测试的是诊断和下次恢复。
- Local Network compat flag 变更后按官方要求重启设备。
- 不用 force-stop 成功后的“未收到通知”记作产品缺陷。

网络场景：

- 同 AP 稳定连接、锁屏 30min/2h/8h。
- DHCP lease 更新，Bridge IP 改变但 bridgeId 不变。
- Wi-Fi A -> Wi-Fi B -> Wi-Fi A。
- Wi-Fi -> 蜂窝 -> Wi-Fi。
- AP roaming、IPv4/IPv6、VPN/Tailscale 开关。
- mDNS 被阻断但 IP 可达。
- client isolation、端口过滤和高丢包/高延迟。
- Bridge 进程重启、主机休眠唤醒和网卡地址变化。
- 通知允许/拒绝/渠道关闭，局域网权限允许/拒绝/撤销。
- App 升级、Service 系统 kill、任务划掉、Active apps Stop。

### 20.5 真机与样本量

- Pixel：AOSP 基线。
- Samsung One UI：后台限制和通知渠道。
- Xiaomi/Redmi MIUI 或 HyperOS：JVM 调度、FGS 和 OEM 策略重点。
- 至少一台低内存设备和一台 Android 16 设备。
- 无 GMS 设备验证纯 LAN 模式，不套用 FCM SLO。

每个关键故障场景至少 100 个事件；发布候选累计至少 1,000 个 LAN event；8h 场景至少
连续运行 3 轮并记录电量、CPU、流量、socket、通知和 cursor。

## 21. 发布、兼容与回滚

### 21.1 Rollout 顺序

1. Bridge event store shadow 上线，不改变客户端行为。
2. Native client shadow 连接，只记录 sync/ready，不显示通知。
3. 内部 installation 启用 native display，旧 watcher 保留但通过 event ownership 仲裁。
4. 5%、25%、50%、100% rollout active-device LAN owner。
5. 独立 rollout `connectedDevice` FGS，不与 FCM fallback 同版本全量切换。
6. 最后 rollout 多设备连接池和 Android 17 权限路径。

每一阶段至少观察 7 天或达到约定事件样本量，以较晚者为准。

### 21.2 兼容

- 旧 Bridge 不宣告 capability，客户端回退旧 watcher/cursor-only。
- 新 Bridge 仅向宣告能力的客户端发送 notification frames。
- schema 至少支持 N-1 解码。
- Android 新版本可读取旧 DeviceProfile，但原生 installationId/cursor 单独迁移。
- P2P 与 LAN 共用 eventId；任一 transport flag 关闭不重建事件。

### 21.3 回滚

- `native_lan_display_v1` 关闭后停止新 native 可见通知，但保留 cursor/dedupe 数据。
- `native_lan_owner_v1` 关闭后回退旧 watcher或恢复补偿，不删除 outbox。
- `connected_device_fgs_v1` 关闭后停止 Service，保留用户设置并准确显示 degraded。
- `lan_push_fallback_v1` 可独立关闭，不影响 LAN direct。
- Bridge 协议 flag 关闭后保留 event store 只读 sync，禁止清空未过期事件。
- 回滚后同一业务事件继续使用原 eventId，不能重新生成造成重复。

## 22. 验收标准

### 22.1 共享事件与 cursor

- [ ] 已 fsync event 在 Bridge crash/restart 后 eventId、sequence 不变。
- [ ] 同一 task generation 的 end/settled 只生成一个 completion。
- [ ] 断线期间完整 `idle -> streaming -> idle` 可从 cursor 补回。
- [ ] 多页 sync 固定 tip，实时新事件零遗漏、零插队。
- [ ] 乱序 Android 接收不能越过缺口 ack。
- [ ] cursor_expired 明确 rebase，不伪装成完整恢复。

### 22.2 原生 LAN owner

- [ ] `READY` 只在鉴权、身份校验、订阅和 catch-up 全部完成后报告。
- [ ] DHCP 地址变化后按 bridgeId 恢复，不需打开 App。
- [ ] NetworkCallback、mDNS 和旧 socket 回调全部受 generation fence。
- [ ] Activity 销毁/Flutter engine 未启动时仍能接收、去重和显示。
- [ ] 前后台 handoff 没有不可补偿空窗。
- [ ] 权限撤销、token 失效和身份冲突显示准确 degraded 原因。

### 22.3 FGS

- [ ] Service 从持久 state 重建真实 owner 后才使用 START_STICKY。
- [ ] 任务划掉后没有空服务或虚假“已连接”。
- [ ] 常驻通知准确并提供 Stop action。
- [ ] 用户 Stop/Active apps Stop 后不自动重启。
- [ ] connectedDevice 的产品语义、权限和 Play 申报通过。
- [ ] 8h 功耗、CPU、流量和稳定性达到 SLO。

### 22.4 通知与混合路径

- [ ] 1,000 次 LAN/FCM/Dart 重复乱序没有重复可见通知。
- [ ] claim/display 崩溃窗口不会吞通知。
- [ ] LAN READY 时不常态发送 FCM。
- [ ] LAN receipt 超时后 FCM fallback 可用且仍按 eventId 去重。
- [ ] 无 GMS、无互联网时纯 LAN 实时模式独立工作。
- [ ] 通知权限或渠道关闭有准确诊断，不滥发 high-priority FCM。

### 22.5 工程质量

- [ ] Bridge typecheck/test 全绿。
- [ ] Flutter analyze/test 全绿。
- [ ] Android JVM/instrumentation test 全绿。
- [ ] feature flag、迁移、兼容、回滚和运维 runbook 齐全。
- [ ] 所有日志和诊断通过敏感字段扫描。
- [ ] PiPilot 主 worktree 和无关源码没有被计划分支修改。

## 23. 实现阶段验证命令

```bash
cd bridge && npm run typecheck && npm test
flutter analyze
flutter test
./android/gradlew -p android app:testDebugUnitTest
./android/gradlew -p android app:connectedDebugAndroidTest
```

文档分支至少执行：

```bash
git diff --check
git status --short --branch
wc -l docs/background-notification-optimization/p2p-plan.md \
      docs/background-notification-optimization/lan-plan.md
rg -n "^## " docs/background-notification-optimization/*.md
```

## 24. 关键决策与待确认项

实施前必须明确：

1. 默认模式是混合可靠还是恢复补偿；是否由用户首次连接时显式选择。
2. 哪些用户/发行渠道允许依赖 GMS，国内或无 GMS 是否只提供纯 LAN 模式。
3. `connectedDevice` FGS 的 Play 合规结论、审核材料和用户 Stop 语义。
4. Android 17 使用广泛 `ACCESS_LOCAL_NETWORK` 还是可行的 NSD system picker。
5. 默认后台监控设备数和 4 socket 资源上限是否符合产品预期。
6. 通知默认只显示通用提示，还是允许显示会话名。
7. Bridge `ws://` 的生产安全边界，以及 WSS pinning/应用层 AEAD 的排期。
8. Bridge 整段离线时是否需要从 session/source 持久日志恢复完成事件。
9. 是否允许开机后恢复纯 LAN FGS；P0 默认不实现。
10. Relay、FCM 和 LAN receipt 的 2s fallback 窗口由谁基于指标调整。

默认决策：先实现一次共享的 Bridge event store、eventId、installation cursor 和 Android
native dedupe；LAN 以原生直连为主，FCM 只做可选 fallback。纯 LAN 无 FGS 时只承诺恢复后
补齐；用户明确开启持续连接且合规 Gate 通过后，才启用可重建 owner 的
`connectedDevice` FGS。该架构同时保留低延迟、无互联网可用性和最终一致性，且不会让
LAN 与 P2P 演化成两套互不兼容的通知系统。
