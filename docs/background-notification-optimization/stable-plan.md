# Android 后台连接与通知稳定性方案（统一推荐版）

日期：2026-08-01
状态：Phase 1-2（局域网后台稳定性改造）已实施并完成真机验收，标记为**完善**；
      Phase 3 原生 LAN owner 已在 `native_lan_owner_v1` flag（默认关）后实施，
      待真机有限验收；Phase 4 已于 2026-08-01 重设计为**在线提示 + 按需 P2P 拉取**
      （复用 Rendezvous，废弃 Relay/FCM 方案，见 §G），实施未启动；
      connectedDevice 迁移与 Phase 5 按决策点暂不启动
分支：`background-notification-optimization`
范围：Bridge 事件持久化、Android 原生通知与连接 owner、LAN 直连、离网在线提示兜底、P2P 前台数据面
实施范围说明：本分支已落地 Phase 1-2 的实现代码与验收记录；Phase 3 代码已在 flag 后落地（默认路径行为不变），真机验收待跑；Phase 4 起仍遵循先决策后实施

## 0. 本文与既有文档的关系

| 文档 | 定位 |
|---|---|
| 本文 `stable-plan.md` | 唯一推荐实施路径，分期、口径、验收以本文为准 |
| `lan-plan.md` | LAN 专项参考：mDNS/NSD、NetworkCallback、地址自愈细节 |
| `p2p-plan.md` | 历史参考：其 Relay/FCM 架构已被本文 2026-08-01 的「在线提示 + 按需 P2P 拉取」设计取代（§G），仅保留其鉴权与威胁建模思路 |

两份旧文档不再作为独立实施计划。它们的技术细节仍然有效且可被引用，但只要与本文冲突，
以本文为准。本文同时修正它们的三处硬错误（可靠性口径、Bridge 身份迁移缺失、target SDK
事实错误），并补齐 FGS timeout 行为与 LAN/提示竞态语义。

改动这三份文档时的规则：技术细节下沉到专项文档，口径、分期和验收只在本文维护，避免同
一决策出现三份不一致的副本。

## 1. 执行摘要

### 1.1 一句话结论

先让 Bridge 的通知事件**持久化且可补齐**，再让 Android 的通知路径**幂等且可诊断**，最后
才考虑要不要为「后台持续连接」投入原生 connection owner。绝大部分用户能感知的丢通知，
根因是事件只存在内存里，而不是连接不够持久。

### 1.2 为什么要重写方案

旧方案的 P0 要求先上线一个全新的公网服务（Notification Relay）、接入 Firebase、实现
AES-GCM envelope 和 TS/Kotlin 跨端测试向量，才能修掉一个已经确诊的内存态 bug
（`lib/state/notification_controller.dart:158` 的 `_streamingWhenBackgrounded`
和 `android/.../BridgeWatcher.kt` 内的 `WatcherTaskState` 都只在进程内存中）。

这个顺序把最大的稳定性收益压在了最重的依赖后面。本文把顺序倒过来：**不引入任何新服务、
不依赖 GMS、不动 FGS 类型**的前提下，先拿到「事件不丢 + 恢复能补齐 + 通知不重复」。

### 1.3 分期与停止条件

```text
Phase 0  契约、指标、flag、威胁模型
   |
Phase 1  Bridge 持久 event store + 连续 cursor        <-- 修掉「事件只在内存」
   |
Phase 2  修好现有 BridgeWatcher + 统一通知入口          <-- 修掉「ready 假成功 / 重复通知」
   |
   +---- 若此处已满足 SLO ----> 停止。不做 Phase 3/4/5
   |
Phase 3  原生 LAN connection owner + connectedDevice FGS
   |
   +---- 若此处已满足 SLO ----> 停止。不做 Phase 4/5
   |
Phase 4  离网兜底：在线提示 + 按需 P2P 拉取（复用 Rendezvous，不依赖 GMS）
   |
   +---- 若此处已满足 SLO ----> 停止。不做 Phase 5
   |
Phase 5  Kotlin 原生 WebRTC owner（仅当确有后台亚秒级双向需求）
```

每个 Phase 都是可独立上线、可独立回滚的完整交付物，不允许打包成一次不可回滚的大改造。
Phase 5 默认不做，见第 14 节的停止条件。

### 1.4 平台诚实边界

以下场景本方案明确不承诺实时通知，且必须在 UI 上如实呈现，不得显示「后台实时已开启」：

- 用户在系统设置执行强制停止。
- 用户在 Android 13+ Active apps 点击 Stop。
- `POST_NOTIFICATIONS` 被拒绝或通知渠道被系统关闭。
- OEM 明确冻结应用后台运行，用户未授予厂商白名单。
- 手机与 Bridge 都无网络，或 Bridge 关机。
- Bridge 在任务全程离线，且上游 source 重连后只给最终快照、无法重放 start/end。

这些场景仍必须进入诊断状态并可导出，不能伪装成「已连接」。

## 2. 可靠性口径（对旧方案的关键修正）

### 2.1 旧口径为什么不可实现

`p2p-plan.md` §2.3 与 `lan-plan.md` §2.3 都把「每 installation 同一 eventId 最多显示一次」
写成硬验收项，而 `lan-plan.md` §12.2 同时要求 claim 后崩溃时「允许重试 stale pending，
不能永久吞通知」。这两条互斥。

Android 上 `NotificationDeduplicator.claim()`、`NotificationManager.notify()` 和
`displayed` 落盘是三个独立操作，无法置于同一原子事务。崩溃窗口里只有两种可能：

- claim 后先落盘再 notify：崩溃则通知永久丢失（违反「不能吞」）。
- claim 后先 notify 再落盘：崩溃则重启后重试，通知出现两次（违反「最多一次」）。

不存在第三种。继续按 exactly-once 验收，只会导致实施阶段被迫在文档和现实之间选一个。

### 2.2 新口径：分层承诺

把「事件不丢」和「提醒不吵」拆成两个不同层级的承诺：

| 层级 | 承诺 | 强度 |
|---|---|---|
| Bridge durable event | 保留期内已 fsync 的事件不丢，可通过 cursor 100% 补齐 | 硬保证 |
| 投递（LAN / 提示+P2P / Dart） | at-least-once，允许重复、乱序、延迟 | 显式允许重复 |
| 用户可见提醒 | 同一 eventId 最多打扰用户一次 | 工程保证，非原子保证 |
| 崩溃窗口 | 允许重复投递或重试，必须可观测 | 记入指标，不算缺陷 |

「最多打扰一次」不依赖原子性，而依赖三个机制叠加：

1. **稳定 notification ID**：`notificationId = stableHash(eventId)`，同一事件重复投递必然
   落到同一个通知槽位，系统行为是替换而非新增。
2. **`setOnlyAlertOnce(true)`**：同一 ID 的后续 `notify()` 只静默更新内容，不再震动、不再
   弹出横幅、不再响铃。用户不会被打扰第二次。
3. **去重表尽力抑制**：已确认 `display_confirmed` 的事件再次到达时直接记
   `suppressed_duplicate` 并跳过渲染，省掉无意义的系统调用。

结论：即使去重表在崩溃窗口失效，机制 1 和 2 仍能保证用户侧不出现第二次打扰。这是可实现
的工程保证，而 exactly-once 不是。

### 2.3 三态显示语义

旧方案把 `notify()` 调用等同于「用户已看到通知」，这会让指标虚高。改为三个独立阶段：

```text
display_requested   -- 已调用 NotificationManager.notify()
display_confirmed   -- notify() 返回且 activeNotifications 可见该 ID（或渠道确认未被拦截）
receipt_uploaded    -- 显示回执已送达 Bridge（允许显著延迟）
```

规则：

- `display_requested` 不代表成功。渠道被关闭、权限被撤销、系统限流都可能让通知不可见。
- `display_confirmed` 才计入 SLO 分子。
- `receipt_uploaded` 只用于 LAN/提示仲裁和指标，**不参与 cursor 推进**，允许延迟数分钟。
  理由见 §7.3：Android 16 起 FGS 内并发的 WorkManager/JobScheduler 作业仍受各自 job
  quota 约束，回执上传不能被当作可靠性前提。

### 2.4 SLO

计时起点统一为 Bridge 的 `persistedAt`，终点为 Android 的 `display_confirmed`。

| 指标 | 目标 | 前提 |
|---|---|---|
| 事件不丢 | 保留期内 100% 可 cursor 补齐 | 已 fsync 且 App 再次连接 |
| LAN 可见延迟 | P95 <= 1s，99% <= 5s | owner READY、权限正常、LAN 稳定 |
| 在线提示可见延迟 | P95 <= 15s，99% <= 60s | **PiPilot 进程与 Rendezvous socket 均存活**、后台豁免有效、Rendezvous 可达；不满足此前提时不适用 |
| 进程死亡后补齐 | best effort | WorkManager 只是恢复信号（最小调度间隔 15 分钟，可更晚），
实际拉取发生在 App 下次启动；近实时需模式二 system_push_wake_v1（通用通知） |
| 恢复延迟 | P95 <= 10s，99% <= 30s | 网络已可用、Bridge 可发现、凭据有效 |
| 重复打扰率 | 稳态 0；崩溃窗口单独统计 | 稳定 ID + onlyAlertOnce |
| 长时稳定 | 8h 无 silent stuck | Pixel / One UI / HyperOS 真机 |

崩溃窗口重复单独记 `crash_window_duplicate`，有预算（建议 < 0.1% 事件）但不计为口径违反。

## 3. Bridge 身份与迁移（旧方案完全缺失的部分）

### 3.1 问题

`lan-plan.md` §6.1 要求用持久 `bridgeInstallationId` 取代进程级 `hubId`，但没有写迁移方案。
实际代码里 `hubId` 已经深度绑定在三个地方：

- `bridge/src/source_registry.ts:78`：`readonly hubId = crypto.randomUUID()`，进程每次启动都变。
- `bridge/src/announce.ts:97`：mDNS TXT 广播的键就是 `hubId`，客户端靠它认 Bridge。
- `bridge/src/hub_protocol.ts:123`：`parseCursor()` 要求 cursor 必须带 `hubId` 才合法。

直接改名会造成：升级后的 Bridge 对旧客户端不可发现；旧客户端所有已保存 cursor 全部失效；
已配对的 DeviceProfile 认不出同一台机器。这是升级即断链。

### 3.2 双字段过渡方案

新增持久身份，但**不删除旧字段**，分三个版本窗口完成迁移。

第一步，Bridge 侧新增持久化身份，与 `hubId` 并存：

```ts
// bridge/src/identity.ts（新增）
interface BridgeIdentityV1 {
  schema: 1;
  bridgeInstallationId: string;  // 首次启动生成的高熵随机值，此后永不变
  createdAt: string;
}
// 落盘 ~/.pi/agent/pipilot/bridge-identity.json，目录 0700 / 文件 0600
// 沿用 bridge/src/config.ts 现有的 0600 权限约定
```

`hubId` 保持现有语义（进程级、每次重启变），继续服务旧协议。新的通知协议只认
`bridgeInstallationId`。两者同时存在，职责不重叠。

第二步，mDNS TXT 与 `bridge_hello` 同时携带两个字段：

```text
# announce.ts TXT，在现有键之外追加
hubId=<进程级 UUID>              # 保留，旧客户端仍靠它工作
bridgeId=<bridgeInstallationId>  # 新增，跨重启稳定
notify=1                         # 新增，声明支持通知事件协议
v=<protocol version>
ipv4=<physical LAN IPv4>
```

第三步，客户端解析优先级与回退：

- 有 `bridgeId` 时以它为身份，`hubId` 仅用于兼容旧 cursor。
- 无 `bridgeId` 时（旧 Bridge）完全走现有逻辑，不发送任何通知协议帧。
- TXT 里的 `bridgeId` 只是发现提示，必须在已鉴权的 `bridge_hello` 中复核一致才可信任。
  mDNS 可被同网设备伪造，这一点与 `lan-plan.md` §15.3 一致。

### 3.3 cursor 命名空间隔离

**新通知 cursor 不复用旧 source cursor**，两者是不同的东西：

| cursor | 键 | 语义 |
|---|---|---|
| 旧 source cursor | `hubId + sourceId + sourceEpoch + seq` | UI 事件流，进程级，重启即失效 |
| 新通知 cursor | `bridgeInstallationId + eventEpoch + installationId` | 通知事件，跨重启稳定 |

`hub_protocol.ts:123` 的 `parseCursor()` 保持不变，不要为了通知去改它的校验规则。通知协议
使用独立的解析函数，避免一个改动同时影响 UI 同步和通知补偿两条链路。

### 3.4 迁移与孤立规则

| 情况 | 处理 |
|---|---|
| 旧 Bridge + 新客户端 | 无 `notify=1` 能力声明，客户端回退现有 watcher，不发新帧 |
| 新 Bridge + 旧客户端 | 旧客户端只读 `hubId`，行为与升级前完全一致 |
| 新 Bridge + 新客户端首次连接 | cursor 为 null，从 `oldestAvailable` 开始，不补历史 |
| Bridge 配置被清空 | 生成新 `bridgeInstallationId`，客户端标记旧 cursor 为 orphaned，要求用户确认重新配对 |
| event store 被重置 | 生成新 `eventEpoch`，不沿用旧 sequence，返回 `cursor_expired{reason: store_reset}` |
| 同一 bridgeId 被两个 DeviceProfile 引用 | 提示合并，禁止建立重复 socket |
| bridgeId 与已保存值冲突 | 以已鉴权 hello 为准，记 `identity_conflict` 诊断，不静默覆盖 roster |

孤立 cursor 不静默丢弃，也不静默接管。必须让用户看到「这台设备的身份变了，需要确认」。

## 4. 平台事实修正

### 4.1 target SDK 已经是 36

`lan-plan.md` §10.5 写「当前 target SDK 35 下继续使用现有权限行为」，这是错的。

实际配置：`android/app/build.gradle.kts:30` 用的是 `targetSdk = flutter.targetSdkVersion`，
而本机 Flutter 3.41.4 的 `FlutterExtension.kt:34` 默认值是 **36**，`compileSdkVersion` 同为 36。
也就是说 Android 16 的行为变更**已经生效**，不是待办事项。

影响：所有「以后再评估 Android 16」的表述都要改成「现在就必须测 API 36 的真实行为」。

### 4.2 Local Network Protection 的正确路线

`lan-plan.md` §10.5 把 `NEARBY_WIFI_DEVICES` 当成 LNP 的测试路径，这是错的。二者管的不是
同一件事：`NEARBY_WIFI_DEVICES` 覆盖 Wi-Fi 扫描/P2P 一类 API，不能替代 TCP/UDP/mDNS 的
本地网络授权。

正确路线：

| 阶段 | 要求 |
|---|---|
| Android 16（当前 target 36） | LNP 是 opt-in 准备阶段，用 compat flag 主动开启以提前暴露 EPERM/超时 |
| Android 17 / target 37+ | `ACCESS_LOCAL_NETWORK` 运行时权限强制生效，属 `NEARBY_DEVICES` 权限组 |

```bash
# 现在就应纳入回归，不要等 Android 17
adb shell am compat enable RESTRICT_LOCAL_NETWORK com.pipilot.pi_pilot
# 官方要求改动 compat flag 后重启设备
adb reboot
```

权限被拒绝或撤销必须进入独立的 `BLOCKED_LOCAL_NETWORK` 状态，并关闭 LAN socket 切换兜底
路径。不能把它混进普通网络超时——两者的用户操作完全不同。

### 4.3 Android 16 的 job quota 新约束

两份旧文档都漏了这条：Android 16 起，**FGS 运行期间并发的 JobScheduler / WorkManager 作业
仍需服从各自的 runtime quota**。

而 `p2p-plan.md` §8.2 和 `lan-plan.md` §8.5 都把 receipt 上传交给 WorkManager。因此：

- receipt 上传必须按「可延迟、不保证及时」设计。
- receipt 不得参与 cursor 推进（已在 §2.3 固化）。
- LAN/提示仲裁不能依赖 receipt 及时返回（见 §8）。
- 若确实需要及时的大流量传输，评估 user-initiated data transfer job，而不是普通 WorkManager。

## 5. 事件模型

### 5.1 不可变业务事件

事件与投递状态严格分离。业务事件一旦 fsync 就永不修改，投递状态单独记录。

```ts
interface NotificationEventV1 {
  schema: 1;
  bridgeInstallationId: string;
  eventEpoch: string;
  eventId: string;             // UUID v4，永久去重键
  sequence: number;            // eventEpoch 内单调递增的安全整数
  taskGenerationId?: string;   // agent_start/end/settled 共用的任务代次
  sourceId?: string;
  sessionId?: string;
  type: "task_completed" | "input_required" | "input_resolved";
  createdAt: string;           // ISO-8601 UTC，Bridge 时钟
  ttlSeconds: number;          // 相对 TTL，见 §5.4
  priority: "high" | "normal";
  collapseKey?: string;
  presentation: {
    title: string;
    body?: string;
    privacy: "generic" | "session_name";
  };
}
```

投递状态按 installation 拆开，可变、可重试，不污染业务事件：

```ts
interface InstallationDeliveryV1 {
  eventId: string;
  installationId: string;
  deliveryGeneration: number;  // 单飞与竞态仲裁用，见 §8.2
  lan: { state: "not_connected" | "queued" | "sent" | "received" | "displayed";
         sentAt?: string; receiptAt?: string };
  push: { state: "disabled" | "not_needed" | "pending" | "accepted" | "failed" | "expired";
          keyId?: string; attempts: number; nextAttemptAt?: string };
}
```

### 5.2 事件生成规则

- `task_completed`：以 Bridge 权威的 `isStreaming true -> false` 边沿生成。现有实现在
  `bridge/src/server.ts:623` 的 `noteStreamingFromEvent()`，本方案在此挂钩，而不是相信
  移动端上报的旧状态。
- `input_required`：以未回答的 `extension_ui_request` 按稳定 requestId 生成。
- `input_resolved`：request 被回答/取消/过期时生成，用于更新或取消原通知。
- `agent_end` 与 `agent_settled` 对同一 `taskGenerationId` 只生成一个 `task_completed`。
- 连接中断提醒是 installation 本地状态，用本地 collapse 通知，**不写成全局业务事件**，
  也不推进 cursor。

### 5.3 任务代次

- `agent_start` 创建并持久化新的 `taskGenerationId`。
- Bridge 重启后从 journal 恢复 in-flight generation，之后的结束事件沿用原 generation。
- 重启时若只有权威快照显示 streaming，创建带 `recovery` 标记的 generation。
- source epoch 切换必须显式结束或作废旧 generation，禁止串到新会话。

### 5.4 用相对 TTL，不用绝对时间戳

旧方案 envelope 里用 `expiresAt` 绝对时间。Android 侧不能信任自己的时钟来判断过期——设备
时钟可能被用户改动、时区错误或重启后未同步，会导致刚生成的事件被判定为过期而静默丢弃。

改为：

- Bridge 存 `ttlSeconds` 相对值，并在响应里带 Bridge 当前时间。
- Android 以 **本地接收时刻** 为基准计算剩余有效期，不与 `createdAt` 直接比较。
- 只有 Bridge 侧做绝对时间的 TTL 清理（Bridge 时钟是权威时钟）。
- `createdAt` 仅用于展示和诊断排序，不作为过期判据。

## 6. Bridge 持久事件存储（Phase 1 核心）

### 6.1 为什么不能复用现有 op-log

`lan-plan.md` §3.4 的判断准确，这里确认并补充精确位置。`bridge/src/server.ts:645` 定义
`OP_LOG_FILE`，`:647` 的 `recordOp()` 直接 `fs.appendFileSync()` 并把整段包在空 `catch {}`
里，写失败被完全吞掉；`:664` 的 `loadOpRegistry()` 同样静默失败。

它可以作为 append-only 的形态参考，但不能承载「事件不丢」的承诺。

### 6.2 存储实现

Bridge 目前无数据库依赖且是单进程 owner，P0 用有界 append-only JSONL，避免引入 native
SQLite 构建依赖：

- 路径：`~/.pi/agent/pipilot/notification-outbox-v1.jsonl`，目录 `0700`、文件 `0600`。
- 记录类型：immutable event / task generation state / per-installation ack /
  delivery transition / tombstone。
- 每条记录带 schema、字节长度和 checksum。
- **所有写入经过单一串行 writer**，禁止多个回调并发 append。
- 事件必须 append + `fsync` 成功后才能进入任何发送队列，也才能对客户端宣称 persisted。
- write/fsync 失败时保留内存 pending、**停止宣称 persisted**、持续结构化告警，不静默吞掉。
- 磁盘满或权限错误时进入显式 degraded 状态并在诊断页可见，不是静默降级。
- 超过 16 MiB / 10,000 条 / tombstone 占比 30% 时压缩：同目录临时文件 -> fsync ->
  原子 rename -> fsync 目录。
- 默认保留 7 天。未 ack 的 installation 不能无限阻止 TTL 回收。
- 启动时 replay，忽略损坏尾行并告警，**禁止整库清空**。

### 6.3 背压

事件生成速度可能超过落盘速度（例如任务风暴）。必须定义有界行为，否则内存无限增长：

- pending 队列上限默认 1,000 条。
- 超限时对 `normal` 优先级事件做 collapse 合并，`high` 优先级仍逐条保留。
- 仍超限时拒绝新的 `normal` 事件并记 `event_dropped_backpressure` 指标。
- 任何丢弃都必须可观测，不允许静默丢事件。

### 6.4 重启恢复顺序

1. `bridgeInstallationId`（`bridge-identity.json`）、`eventEpoch`、最后 sequence。
2. in-flight task generation。
3. 未过期业务事件。
4. installation ack 与 delivery state。
5. LAN subscription 从空开始，等客户端重连后按 cursor 补齐。
6. 提示 pending 独立恢复，**不阻塞** LAN 与本地路径启动。

### 6.5 建议文件

```text
bridge/src/identity.ts                       # bridgeInstallationId 持久化
bridge/src/notification_event.ts             # 事件类型与校验
bridge/src/notification_event_store.ts       # append/fsync/replay/compact/TTL
bridge/src/notification_generation.ts        # task generation 去重
bridge/src/notification_protocol.ts          # sync/events/ack/receipt/cursor_expired
bridge/src/notification_delivery.ts          # per-installation 投递状态与单飞
bridge/test/notification_event_store.test.ts
bridge/test/notification_generation.test.ts
bridge/test/notification_protocol.test.ts
bridge/test/notification_recovery.integration.test.ts
```

## 7. 协议

### 7.1 能力协商

`bridge_hello` 追加字段，旧客户端忽略未知字段，新客户端只在能力存在时发新帧：

```json
{
  "type": "bridge_hello",
  "hubId": "<进程级 UUID，保留>",
  "bridgeInstallationId": "<跨重启稳定>",
  "capabilities": ["notification_events_v1", "notification_receipts_v1"]
}
```

### 7.2 订阅与固定 tip 补偿

```text
client -> bridge
notification_subscribe {
  id, schema: 1, installationId,
  cursor: { eventEpoch, sequence } | null,
  scopes: { sourceIds: [...], eventTypes: [...] },
  scopeVersion, pageLimit: 100
}

bridge -> client
notification_events {
  id, eventEpoch, scopeVersion, bridgeNow,
  fromExclusive, through, tip,
  events: [...],
  skippedRanges: [{ from, through }],
  hasMore
}
```

规则：

- Bridge 处理 subscribe 时**先捕获固定 `tip`，再注册实时缓冲**，两者之间不留空窗。
- catch-up 遍历 cursor 之后、tip 以内的连续全局 sequence。匹配 scope 的进 `events`，被
  scope 排除的合并进 `skippedRanges`，两者共同连续覆盖到 `through`。
- 客户端必须校验 `events + skippedRanges` 从 `fromExclusive + 1` 连续覆盖到 `through`；
  有无法解释的缺口时停止 ack 并请求 resync。
- 分页期间新产生的事件进 live buffer，**不得插入当前分页中间**改变上界。
- `hasMore=false` 后先排空 live buffer，再发 `notification_ready`。
- 单页最多 100 条且编码后不超过 64 KiB；单条超预算返回显式错误而非静默截断。
- live buffer 上限 256 条或 1 MiB，溢出返回 `resync_required`，禁止静默丢头部。
- `scopeVersion` 不一致时返回 `scope_changed`，禁止用旧过滤规则推进 cursor。
- Bridge 必须先做权限过滤再构造页；`skippedRanges` 不得泄露被过滤事件的类型、正文或 source。

### 7.3 ready 语义

只有全部满足才发 `notification_ready`：token 鉴权通过、`bridgeInstallationId` 复核一致、
subscription 已注册、固定 tip catch-up 完成、客户端已确认 `through` 之前事件安全落入本地
去重表、实时缓冲已建立。

`socket.onOpen` **不是** ready。这正是当前实现的缺陷：`MainActivity.kt` 在提交
`BridgeWatcher.start()` 后立即 `result.success(null)`，而
`lib/state/notification_controller.dart:263` 据此设置 `_watcherActive = true`，随后
`:371` 的 `if (_watcherActive) return;` 会过早抑制 Dart 通知——此时原生 socket 可能还没连上。

### 7.4 连续 ack 与 receipt

```text
client -> bridge
notification_ack { installationId, eventEpoch, through }
notification_receipt { installationId, eventId, state, at }
```

- ack 只表示 `<= through` 的可见事件已安全处理或被明确过滤，**只推进连续前缀**：先收到
  130 但缺 129 时不得 ack 130。
- 旧 ack 幂等且不得回退 server cursor；越界、epoch 或 installation 不匹配返回显式错误。
- ack 与用户点击/已读无关，不能用 read receipt 替代。
- receipt 的 state 取 `received | display_requested | display_confirmed |
  suppressed_duplicate | blocked_permission | blocked_channel`。
- receipt 只服务仲裁与指标，**不推进 cursor**，允许显著延迟（§4.3）。

### 7.5 cursor 过期

```text
bridge -> client
notification_cursor_expired {
  eventEpoch, oldestAvailable, currentTip,
  reason: "retention" | "store_reset" | "identity_changed"
}
```

- retention 过期从 `oldestAvailable` rebase，并显示可诊断的历史缺口计数。
- store 重置必须生成新 `eventEpoch`，不沿用旧 sequence。
- 权威 session snapshot 只能恢复当前状态，**不能声称恢复已过期的完成边沿**。
- rebase 后本地 cursor 原子写入，不得在崩溃窗口跳过未处理事件。

## 8. LAN / 提示仲裁（承认竞态存在）

### 8.1 旧方案的问题

`lan-plan.md` §14.1 的 direct-first 策略假设「2 秒内收到 receipt 就不发 FCM」，把 receipt
延迟当成不会发生的例外。实际上它是常态：receipt 上传走 WorkManager，而 Android 16 起 FGS
内的 job 仍受 quota 约束（§4.3），2 秒返回不是可依赖的行为。

结果就是「LAN 已经显示了，FCM 又发一遍」。旧方案没有为这种情况定义语义。

### 8.2 新语义：竞态是允许的，重复不是缺陷

明确承认：**LAN 已显示但 receipt 迟到时，提示信号仍可能被发出，这是允许的行为。**

Bridge 侧规则：

- 对每个 `eventId + installationId + deliveryGeneration` 做**单飞调度**，同一组合永不并发
  排两次提示。
- 收到 `display_requested` 或 `display_confirmed` receipt 时，取消**尚未发出**的 fallback。
- 已经发出的提示**不撤回**，也不视为错误。
- fallback 触发原因必须记录原因码：`no_ready_subscription` / `lan_send_failed` /
  `receipt_timeout` / `installation_offline`。

Android 侧规则：

- 迟到的提示只是多触发一次按需 P2P 回连与 cursor 拉取；事件落到同一
  `stableHash(eventId)` 通知 ID，配合 `onlyAlertOnce` 静默更新。
- 去重表命中 `display_confirmed` 时记 `suppressed_duplicate` 并跳过渲染。
- 用户侧观测结果：一条通知、一次提醒。

### 8.3 fallback 窗口取值

2 秒是初始猜测值，必须由实测校准，且**校准前不写进产品文案**：

- 初期设为 P95 LAN receipt 延迟的 3 倍，无数据时取 3 秒。
- 有 1,000 个真机 LAN 事件样本后再收敛。
- 窗口过短会增加无谓的提示与 P2P 建连消耗，过长会拖慢离网场景，两侧都要有指标。

### 8.4 不默认双发

LAN 正常时并行发送提示信号会浪费 P2P 建连与电量，并且大量提示因本地已显示而只触发一次
空拉取。因此采用 receipt 驱动的有界 fallback，而非永久双发。

## 9. Android 通知路径

### 9.1 统一渲染入口

所有路径（原生 LAN、提示回连、Dart）统一走同一入口，不再各自分配递增 ID：

```text
NotificationGate.deliver(event)
  -> claim(installationId + bridgeInstallationId + eventId)
  -> render(notificationId = stableHash(eventId), onlyAlertOnce = true)
  -> markDisplayRequested / markDisplayConfirmed
```

当前实现里 ID 是分段递增的：`notification_controller.dart:155` 从 99 起（任务通知 100+），
`BridgeWatcher.kt:41` 的 `notificationIdBase = 200`。两条路径没有共同 eventId，所以无法跨
路径去重。Dart 侧应通过 MethodChannel 携带 eventId 调用同一原生入口。非 Android 平台保留
各自插件实现。

### 9.2 去重表

- 唯一键 `installationId + bridgeInstallationId + eventId`。
- 状态机 `pending -> display_requested -> display_confirmed`，另有 `suppressed` / `blocked`。
- claim 与状态写入各自原子，但**不假设三者整体原子**（§2.1）。
- claim 后崩溃、display 前崩溃：重启后允许重试 stale pending，可能重复投递，由稳定 ID 与
  `onlyAlertOnce` 吸收，记 `crash_window_duplicate`。
- 保留 7 天或 2,048 条；清理时保留仍在通知栏中的 ID 映射。

### 9.3 通知 ID 与 collapse

- FGS 常驻通知固定 ID `1`（`KeepAliveService.kt:21` 已是此值）保留，业务通知必须避开。
- 业务通知 ID 由 eventId 稳定 hash 生成，配 collision map 处理极小概率碰撞。
- 同一 task 的状态更新复用 ID；不同 task 的完成事件**不 collapse**，否则会吞通知。
- `input_resolved` 用原 eventId/collapseKey 更新或取消等待输入通知。
- 点击 PendingIntent 带 bridge/profile/source/session 深链，**不带 token**。

### 9.4 权限与隐私

- `POST_NOTIFICATIONS` 被拒时记 `blocked_permission`，仍可推进已安全处理的 cursor。
- 通知渠道被系统单独关闭必须独立诊断，不能只查 runtime permission。
- `generic` 模式只显示「PiPilot 有新事件」。
- `session_name` 模式可显示会话名，但不显示提示词、agent 输出和文件路径。
- FGS 常驻通知用 private visibility（`KeepAliveService.kt:100` 已是 `VISIBILITY_PRIVATE`）。

## 10. FGS 生命周期与 timeout（旧方案缺口）

### 10.1 当前状态

- `KeepAliveService.kt:125` 返回 `START_NOT_STICKY`。
- `KeepAliveService.kt:128-131` 在任务移除时主动 `stopSelf()`。
- `KeepAliveService.kt:134` 的 `onTimeout()` 只有 `stopSelf(startId)`，没有任何降级或告知。
- Manifest 声明 `dataSync` 与 `stopWithTask="true"`。

`onTimeout` 的现状意味着：Android 15+ 的 6 小时配额用尽后，服务静默消失，用户不知道后台
实时已失效。这是当前最容易被误认为「偶发丢通知」的原因之一。

### 10.2 迁移顺序不可颠倒

先修 owner，再放宽生命周期。顺序错了会留下「有常驻通知但没有真实 owner」的空服务：

1. 定义并持久化 `BackgroundConnectionState`。
2. `onCreate/onStartCommand` 能从持久状态独立重建 owner，或明确降级为仅等待兜底。
3. 才可以设 `stopWithTask=false`、移除 `onTaskRemoved()` 的主动停止、评估 `START_STICKY`。
4. 最后才评估切换 `connectedDevice` 类型。

### 10.3 timeout 后的显式降级状态机

```text
LAN_READY  --(dataSync 6h 配额耗尽, onTimeout)-->  QUOTA_EXHAUSTED
                                                        |
                          +-----------------------------+
                          |                             |
                  Rendezvous 可达                 Rendezvous 不可达
                          v                             v
                     WAKE_ONLY                     CURSOR_ONLY
```

`onTimeout()` 必须完成而不是简单 `stopSelf()`：

- 关闭 LAN socket 并释放 wake lock，进入上述状态之一。
- **更新常驻/诊断通知文案**，如实告知「后台实时已暂停，将在配额恢复后重连」，不得继续
  显示「已连接」。
- 记录配额窗口起点，估算恢复时间并在诊断页展示。
- **不得因 timeout 无限重启 `dataSync` 服务**——这属于规避平台限制，且会被系统持续拦截。
- 配额窗口恢复后，仅在用户仍开启实时模式且前台资格窗口允许时重新启动。
- 若已迁移 `connectedDevice`，该类型不受 6 小时限制，此路径不触发；但仍需保留代码路径以
  应对类型回退。

### 10.4 connectedDevice 合规 Gate

`connectedDevice` 不受 `dataSync` 的 6 小时限制，且其官方运行前提之一（manifest 声明
`CHANGE_NETWORK_STATE`）当前已满足——`AndroidManifest.xml:11` 已声明该权限。但仍必须全部
满足以下条件才可迁移：

- 用户在前台明确开启「持续连接」，且存在已配对的外部桌面设备。
- 服务的实际工作是与该设备保持网络交互，不是空壳、也不是单纯等待云端推送。
- 声明 `FOREGROUND_SERVICE_CONNECTED_DEVICE`，运行时 `startForeground()` 传入匹配 type。
- 常驻通知明确说明连接的设备与停止方式。
- Play Console 完成 FGS 类型申报，附可复现视频与用户触发路径。
- 法务/发布审核确认不构成「换标签规避 dataSync 限时」。

Gate 不通过就保留 `dataSync` + 兜底架构，不用错误类型换取表面常驻。

### 10.5 用户控制与 wake lock

- 持续连接必须由用户在前台显式开启，默认关闭。
- FGS 通知提供「断开并停止」action；用户 Stop 后记 `stoppedByUser=true`，系统不得自动重启。
- 无有效 target、无通知权限或 Gate 失败时立即停止，不保留空服务。
- 不把无限 `PARTIAL_WAKE_LOCK` 当作可靠性根基。当前 `KeepAliveService.kt:167` 的
  `acquireWakeLock()` 应改为仅在批量 catch-up、重连和落盘时申请**带明确 timeout** 的短期锁。
- MIUI/HyperOS 上 FGS wake lock 可能在数十秒后被限制，真机验收必须包含 OEM 禁用 wake lock
  后的路径。
- P0 不实现开机自启。后续若加 `BOOT_COMPLETED`，需单独评估 Android 版本限制、用户 opt-in、
  FGS 后台启动资格和 OEM 行为。

## 11. 产品模式状态机

用一个含糊的「后台保活」开关覆盖所有语义是当前设计的根源问题。改为三种语义明确的模式，
UI 文案必须与实际承诺一致。

| 模式 | 及时路径 | 最终补偿 | 需互联网 | 需常驻通知 | 承诺 |
|---|---|---|---|---|---|
| 恢复补偿 | 无持续后台 socket | outbox + cursor | 否 | 否 | 只承诺恢复后不漏 |
| 纯 LAN 实时 | 原生 LAN owner | outbox + cursor | 否 | 是 | 无互联网下唯一可行的实时方案 |
| 混合可靠 | LAN 优先，提示+P2P 兜底 | outbox + cursor | 兜底需要 | 可选 | 默认推荐 |

### 11.1 恢复补偿（Phase 1-2 的默认）

- 前台用现有 Dart LAN/P2P 连接。
- 进入后台不承诺持续 socket。
- Bridge 继续持久化事件。
- 下次打开或可运行时按 cursor 补齐，可显示「后台期间有 N 个事件」。
- **不得伪装成实时到达。**

### 11.2 纯 LAN 实时（Phase 3）

- 原生 Service 成为 LAN 通知连接 owner。
- 需要合规的 `connectedDevice` FGS 与持续可见通知。
- 不依赖 Rendezvous、推送通道、GMS 或 Flutter isolate。
- 被系统回收后按平台允许条件重启并 cursor 补偿。
- force-stop、Active apps Stop、OEM 硬冻结仍不保证。

### 11.3 混合可靠（Phase 4，默认推荐）

- LAN `READY` 时先走本地直连。
- 无 ready subscription、发送失败或 receipt 超时时，Bridge 经 Rendezvous 发出提示信号，
  手机进程存活时按需 P2P 回连拉取事件。
- 两条路径共用 eventId，由 §9 的统一入口去重。
- 都失败时下次连接按 cursor 补齐；进程已死时由 WorkManager 周期轮询兜底。
- Rendezvous 不可用不影响本地 LAN 路径。

### 11.4 P2P 定位

P2P 保持**按需**数据面：不承诺后台持续 WebRTC，但离网场景的后台通知内容由「在线提示 +
按需 P2P 回连」拉取——提示信号只负责告知「有事件」，DataChannel 在提示到达后临时建立、
拉完即走。
这是对 2026-08-01 之前「远程后台通知由 FCM 兜底」结论的显式修改，原因见 §G。

### 11.5 连接状态机

```text
DISABLED
   |  user enables + valid paired target
   v
STARTING -> DISCOVERING -> CONNECTING -> AUTHENTICATING -> SYNCING -> READY
   ^             |             |              |              |         |
   |             +-------------+--------------+--------------+---------+
   |                          recoverable failure (backoff)
   |
   +-- BLOCKED_PERMISSION / BLOCKED_LOCAL_NETWORK / BLOCKED_POLICY
   +-- QUOTA_EXHAUSTED -> PUSH_ONLY | CURSOR_ONLY        (§10.3)
   +-- STOPPED_BY_USER
```

约束：只有 §7.3 的全部条件满足才进入 `READY`；每个状态带 `generation`，旧连接回调不得覆盖
新 generation；超过恢复预算后进入显式 degraded，**不得持续显示「已连接」**。

## 12. 分期实施

### Phase 0：契约、指标、flag、威胁模型

> 实施状态（2026-08-01）：契约/schema/双字段过渡协议已随 Phase 1 一并落地为代码
> （`notification_event.ts` / `notification_protocol.ts` / `notification_identity.ts`）；
> feature flag、现网指标基线、威胁模型三项治理工作**未做**，保留为实施前欠债，
> Phase 3 启动前必须补齐。

- [ ] 固定事件 schema、sequence、cursor、相对 TTL、collapse 与 receipt 状态。
- [ ] 固定 `bridgeInstallationId` 双字段过渡协议（§3.2）与迁移规则（§3.4）。
- [ ] 定义只读通知 role 与能力协商。
- [ ] 建立现网基线：后台通知成功率、重复率、P50/P95/P99、恢复耗时、断线原因分布。
- [ ] 敏感字段日志红线与威胁模型（含明文 `ws://` 的边界）。
- [ ] feature flags：`notification_events_v1`、`unified_notification_gate_v1`、
      `native_lan_owner_v1`、`connected_device_fgs_v1`、`push_fallback_v1`、
      `multi_device_owner_v1`。

Gate：协议、安全、产品与 Android/Play 评审通过；未决项有明确 owner，不以 TODO 混入实现。

### Phase 1：Bridge 持久事件与 cursor（不动客户端行为）

> 实施状态（2026-08-01）：**已完成并通过验收**，证据见文末「实施与验收记录」§A。

- [x] `bridge/src/identity.ts` 持久化 `bridgeInstallationId`，与 `hubId` 并存。
- [x] event store：单一串行 writer、append/fsync/replay/checksum/compact/TTL/背压。
- [x] task generation 去重与 in-flight 恢复。
- [x] 权威事件生成挂在 `server.ts:623` 的 streaming 边沿与 extension 输入状态。
- [x] `notification_subscribe/events/ack/receipt/cursor_expired` 协议。
- [x] mDNS TXT 与 `bridge_hello` 追加 `bridgeId` + `notify=1`。
- [x] crash-at-every-write-boundary 故障注入。
- [x] **shadow 模式**：只生成事件与指标，不驱动任何可见通知。

Gate：随机 kill/restart 1,000 次无已 fsync 事件丢失；同一 generation 不产生重复 eventId；
cursor 分页在乱序、断线、buffer 溢出下零静默遗漏；旧客户端行为完全不变。

### Phase 2：修好现有 watcher + 统一通知入口

这一期是**收益/成本比最高**的一期：不引入新服务、不依赖 GMS、不改 FGS 类型，只修既有缺陷。

> 实施状态（2026-08-01）：**已完成并通过验收**（仅「网络变化触发恢复」留待 Phase 3
> 与原生 owner 一并实施），证据见文末「实施与验收记录」§A/§B。

- [x] `NotificationGate`：稳定 ID + `onlyAlertOnce` + 去重表 + 三态显示语义（§9.1）。
- [x] Dart 通知经 MethodChannel 带 eventId 走同一入口，废弃 100+/200+ 分段递增 ID。
- [x] `BridgeWatcher.start` 增加 connected/authenticated/ready 回调，**只有真正 ready 才
      抑制 Dart 通知**，修掉 `notification_controller.dart:263` 与 `:371` 的过早抑制。
- [x] watcher 订阅 Bridge 通知事件流，替代只订阅 selected source 的窄路径。
- [x] 用持久 cursor 替代内存基线，修掉 `notification_controller.dart:158` 的
      `_streamingWhenBackgrounded` 与 `WatcherTaskState` 的进程内存态。
- [x] 网络变化对所有保持连接的设备触发恢复，不只 active device
      （已在 Phase 3 原生 owner 落地：`registerDefaultNetworkCallback` 通告即清零
      退避并立即重连；watcher 路径仍靠 1s-15s 退避，已在 45 分钟真机测试中验证
      可从冻结/断连恢复）。
- [x] `onTimeout()` 实现 §10.3 的显式降级与文案更新。

Gate：断线期间完整 `idle -> streaming -> idle` 可从 cursor 补回；1,000 次重复/乱序注入无
重复打扰；Flutter engine 未启动时原生仍能显示；ready 未达成时 Dart 兜底不被抑制。

**决策点 A**：此处复测 SLO。若「恢复补偿 + 修好的 watcher」已满足产品需求，停止，不进入
Phase 3。

### Phase 3：原生 LAN connection owner

> 实施状态（2026-08-01）：**已在 `native_lan_owner_v1` flag（默认关）后实施，待真机
> 有限验收**。默认路径仍是 Phase 2 的 watcher + Dart 兜底，行为不变；证据见文末 §E。
> connectedDevice 迁移与 8h 功耗明确不声称。

- [x] `LanConnectionCoordinator` / `LanConnectionState`（独立 socket + 显式状态机 +
      世代防护；`NativeLanConnectionService` 未建——coordinator 由 startWatcher 驱动，
      Service 托管留待 stopWithTask 评估一并做）。
- [x] `NsdManager` 发现、endpoint 持久化与 `NetworkCallback` 地址自愈（连续 3 次失败
      触发一轮 NSD；TXT `ipv4` 优先于解析地址；TXT `bridgeId` 只做提示，与持久身份
      不符记 `identity_conflict` 且不改写 endpoint）。
- [x] Keystore-backed 凭据与 cursor store，no-backup（`NativeLanTarget` 存
      `noBackupFilesDir`，token 只存 Keystore AES/GCM 密文；无依赖序列化可 JVM 测）。
- [x] 前后台 handoff：与 watcher 共用 `watcherReady` 通道，ready 前绝不抑制 Dart；
      `startFromPersisted` 提供空 Intent 重建入口（Activity 销毁兜底待 Service 托管）。
- [x] 禁止后台 `/24` 扫描与进程级 `bindProcessToNetwork`（coordinator 只用
      `network.socketFactory` + 目标子网/路由匹配选网）。
- [ ] Service 能从持久状态独立重建 owner 后，才设 `stopWithTask=false` 并评估 `START_STICKY`。
- [ ] `connectedDevice` 合规 Gate（§10.4）通过后迁移类型。
- [~] Android 16 LNP compat flag 纳入回归（§4.2）：`BLOCKED_LOCAL_NETWORK` 状态与
      `blocked_local_network` 指标已落地；compat flag 真机回归待跑。

技术细节以 `lan-plan.md` §10-11 为准。

Gate：DHCP 换址、Wi-Fi 切换、Activity 销毁均无不可补偿空窗；身份不符不静默改 host；任务
划掉后无空服务；用户 Stop 后不自启；8h 真机功耗与稳定性达标。

**决策点 B**：若纯 LAN 实时已满足需求且用户群不需要离网场景，可停止。

### Phase 4：离网兜底（2026-08-01 重设计，废弃 Relay/FCM envelope 方案；同日经 advisor 纠偏后拆为两个可选模式）

设计转向的动机与决策记录见 §G。核心原则不变：**任何第三方/中转通道只携带无内容的
提示信号，事件内容永远走已有 P2P/LAN 加密通道拉取**——因此不需要 envelope 加密、
密钥轮换、bootstrap ticket 或新建公网内容服务。

**必须诚实的分层**（advisor 纠偏，2026-08-01）：

1. Rendezvous WebSocket 只能在 **PiPilot 进程与 socket 都活着**时送达提示；它不能叫醒
   已被杀死或 OEM 冻结的进程。
2. WorkManager 周期任务的 15 分钟是**最小调度间隔**，不是送达保证；Doze、待机桶、
   quota 与 OEM 策略可使其更晚。
3. 进程已死还要近实时通知，**唯一可信路径是 OS 级推送通道**（FCM 或 MiPush/个推/极光
   等厂商/聚合通道）。推送用**纯数据**载荷：系统把载荷递给 PiPilot 进程，PiPilot 自己
   经 P2P 拉取内容、经 NotificationGate 弹通知——通知自始至终是 PiPilot 发的。

#### 模式一 `remote_hint_v1`（默认先做，零新设施）

- [ ] Rendezvous 提示路由：复用现有 host/guest 信令角色，新增无内容 `wake` 帧
  （仅 installation 域提示 nonce + bridgeId 短前缀 + 时间戳；**不放 eventId**，见 §13.1）。
- [ ] Bridge fallback 触发器：无 READY 订阅 / 发送失败 / receipt 超时 → 发提示；
  单飞与竞态语义同 §8.2，原因码不变。
- [ ] Android 后台信令长连 owner：复用 Phase 3 的 ReconnectController / 网络回调 /
  诊断模式；依赖「后台无限制」豁免保活，豁免缺失时明确降级为轮询。
- [ ] 提示到达后按需 P2P 回连：走已有 WebRTC 配对通道连回 Bridge，cursor 拉取事件，
  经 NotificationGate 统一入口展示——这条链 Phase 1-3 已建好，**零新代码**。
- [ ] WorkManager 周期任务（最小调度间隔 15 分钟，实际可能更晚）：**只是调度/恢复信号**。
  WebRTC 客户端在 Dart 里（`PiConnection`/`P2pConnector`），原生 worker 没有 headless
  Flutter 引擎或原生 WebRTC 客户端就做不了 P2P 拉取，只能记录「待恢复」，等 App
  下次启动后走正常 P2P/LAN 补偿。
- **定位**：在线提示，不是进程唤醒机制。进程活着时近实时；进程死亡时退回轮询 +
  下次打开 App 补齐。

#### 模式二 `system_push_wake_v1`（可选升级，唯一进程死亡后近实时路径）

- [ ] 接入 FCM 或国内厂商/聚合推送通道（MiPush/个推/极光，按目标设备与 Play 政策选择），
  仅发送**纯数据**唤醒载荷（installation 域 nonce），不携带任何内容。
- [ ] 推送到达 → 系统拉起 PiPilot 原生组件 → **立刻弹 PiPilot 自己的通用通知**
  「PiPilot 有新事件」（经 NotificationGate，不含详情）；详情在用户打开 App 后由正常
  P2P/LAN 补偿补齐。**注意**：叫醒后的进程同样用不了 Dart P2P 栈拉详情——死亡进程下
  直接弹详情需 headless Flutter+P2P / 原生 WebRTC / 推送载荷加密三选一，复杂度重回
  原方案量级，本设计明确不做。
- [ ] 无推送凭据/无 GMS/未配置时明确回退模式一，不得静默无兜底。

Gate：LAN 正常时不发提示；进程活着且 Rendezvous 可达时提示→展示端到端达到 §2.4
在线提示 SLO；进程死亡场景如实按轮询/推送模式各自口径验收；任意竞态下无重复打扰；
Rendezvous 与推送通道都看不到事件内容、pairing secret 与 hub token。

### Phase 5：Kotlin 原生 WebRTC owner（默认不做）

仅当 Phase 1-4 指标仍不满足，且**确有后台亚秒级双向操作需求**时启动。前置条件是先定义
transport-neutral `BridgeChannel` 协议测试向量，让 Dart 与 Kotlin 共用帧样例、认证、心跳、
分页和错误码，禁止复制逻辑后各自演化。

Gate：MIUI/One UI/Pixel 8 小时锁屏测试满足 SLO 且功耗流量达标；否则不上线。

## 13. 提示信号安全边界与锁定期行为

> 本节原为「FCM envelope 预算与密钥可用性」，随 Phase 4 重设计整体改写。
> 原 4 KiB 预算、minimal envelope 降级、notification key 轮换体系不再需要：
> 内容不经过任何第三方通道，唯一跨网传输的是无内容提示信号。

### 13.1 提示信号内容上限

提示帧只允许携带：

| 字段 | 上限 | 说明 |
|---|---|---|
| schema | 固定值 | 帧版本 |
| nonce | 16 字符 | installation 域一次性提示凭证，**不是 eventId**——避免把事件身份暴露给中转 |
| bridgeId 短前缀 | 8 字符 | 用于路由核对 |
| timestamp | 毫秒 | 用于过期丢弃 |

禁止出现：title/body、会话名、sourceId、token、任何 pairing 材料。提示信号泄密的最坏
后果是「有人知道某时刻有个事件」，不泄露任何内容；伪造提示的最坏后果是手机多收一次
提示做一次空拉取，有速率限制兜底（§13.3）。

### 13.2 锁定期与凭据不可用

设备重启后首次解锁前，Keystore 包装的 P2P/LAN 凭据不可读，按需回连无法建立。处理规则：

- 提示到达时只持久化 routing metadata（nonce、到达时间），**不落任何内容**。
- 显示不含敏感内容的通用占位通知，或按产品选择先不显示。
- 监听 `ACTION_USER_UNLOCKED`，解锁后重试回连拉取，走 §9.1 统一入口（稳定 ID 保证是
  更新而非新增打扰）。
- WorkManager 周期任务在凭据不可用时同样跳过并留待解锁后执行（它只是恢复信号，见
  Phase 4 模式一）。
- 凭据永久失效（撤销配对）时提示应被忽略，记 `wake_ignored_unpaired`。

### 13.3 Rendezvous 侧边界

- Rendezvous 只做转发，不存储提示帧，不记录 nonce 之外的任何上下文。
- 提示帧按 `installationId` 速率限制（如 30 次/小时）并做 nonce 重放抑制，超限丢弃并记
  指标——无内容信号仍存在耗电 DoS 面。
- guest 长连鉴权**拟**复用现有 P2P pairing 的设备身份；`rendezvous/src/server.ts` 核查结论
  （2026-08-01，advisor 第 5 点）：
  - `signal` 帧 `data` 为不透明透传，提示可搭现有协议，Rendezvous 零代码改动；
  - 但 guest 加入房间要求 host 在线（`host_offline` 直接拒绝），且 host 掉线会踢掉所有
    guest（close 4001）——**Bridge 必须新增长驻 host 房间行为**（当前 P2P 是按需连，
    没有常驻 host），手机端提示 socket 也要容忍被踢后重连等 host 回归；
  - 服务端无 nonce 存储与时间戳校验，**重放抑制必须在接收端做**（Android 用有界
    nonce 去重集）；
  - 同一手机多条连接会拿多个 peerId 重复收提示，同样由 nonce 去重吸收；
  - 授权边界 = pairing key（`timingSafeEqual`），与现有 P2P 同级信任；服务端无速率
    限制，房间内均为用户自有设备，DoS 面可控，但 Bridge 单飞与 Android 去重之外
    保留后续加服务端限流的口子；
  - deviceId 可被先行占用（`device_id_in_use` 蹲守），个人自用可接受，记录为已知面。
- 严禁经 Rendezvous 传输 hub token、pairing secret、会话正文或用户输入。

## 14. 停止条件（本方案的核心约束）

旧方案把 LAN owner、Relay、FCM 和 Kotlin WebRTC 重写绑成一条必须走完的路。本方案要求在每
个决策点用**实测指标**决定是否继续投入（Phase 4 已于 2026-08-01 重设计为在线提示 +
按需 P2P 拉取，见 §G）。

| 决策点 | 位置 | 若满足则 | 停止条件 |
|---|---|---|---|
| A | Phase 2 后 | 不做 Phase 3/4/5 | 恢复补偿模式下事件零丢失，用户可接受「打开 App 补齐」 |
| B | Phase 3 后 | 不做 Phase 4/5 | 纯 LAN 实时达标，且用户群不需要离网/远程通知 |
| C | Phase 4 后 | 不做 Phase 5 | 混合模式达 SLO，无后台亚秒级双向操作需求 |

**明确结论**：如果「持久事件 + cursor + 按需重连（含 Rendezvous 提示）」已满足产品 SLO，就不实施
原生 WebRTC 后台 owner。Phase 5 的成本是双端协议漂移风险，收益仅在后台亚秒级双向交互这一
个场景，绝大多数产品需求不在此列。

每个决策点必须有书面的指标结论，不允许以「感觉还不够稳」为由跳过 Gate 直接进下一期。

## 15. 故障注入与验收

### 15.1 崩溃点覆盖

Bridge 侧，每个写边界前后各 kill 一次：

- append 前 / append 后 / fsync 前 / fsync 后
- compaction 临时文件写入后 / rename 前 / rename 后
- cursor ack 处理前 / 后
- delivery 状态转换前 / 后

Android 侧：

- claim 前 / claim 后 display 前 / display 后 receipt 前
- cursor 原子写入前 / 后
- rebase 过程中

预期：已 fsync 事件零丢失，eventId 与 sequence 不变；claim/display 之间崩溃允许重复，但必须
落在 `crash_window_duplicate` 预算内。

### 15.2 竞态场景

- LAN receipt 延迟到 fallback 窗口之后，提示与 LAN 同时到达（全部到达顺序组合）。
- 分页 catch-up 期间持续产生新事件，验证固定 tip 不被改写。
- live buffer 溢出返回 `resync_required`，不静默丢头部。
- 前后台 handoff 回调乱序、Activity 在 handoff 中被销毁。
- 多 installation ack 互不推进。
- 同一 eventId 的并发 publish 被单飞拦截。

### 15.3 网络与设备场景

```bash
adb shell dumpsys deviceidle force-idle
adb shell dumpsys deviceidle unforce
adb shell am kill com.pipilot.pi_pilot            # 近似系统回收
adb shell cmd activity stop-app com.pipilot.pi_pilot  # 明确不保证场景
adb shell am set-inactive com.pipilot.pi_pilot true
adb shell am compat enable RESTRICT_LOCAL_NETWORK com.pipilot.pi_pilot
```

网络：同 AP 锁屏 30min/2h/8h；DHCP 换址但 bridgeId 不变；Wi-Fi A -> B -> A；
Wi-Fi -> 蜂窝 -> Wi-Fi；AP roaming；IPv4/IPv6；VPN/Tailscale 开关；mDNS 被阻断但 IP 可达；
client isolation；高丢包高延迟；Bridge 重启与主机休眠唤醒。

权限：通知允许/拒绝/渠道单独关闭；局域网权限允许/拒绝/撤销。

生命周期：任务划掉、系统 low-memory kill、FGS timeout、Active apps Stop、force-stop、
App 升级、设备重启。

**force-stop 与 Active apps Stop 只验证诊断准确性与下次恢复，不得记为通知缺陷。**

### 15.4 真机矩阵

覆盖 Android 13、14、15、16（本地验收机为小米 13 / Android 16 / API 36）：

- Pixel：接近 AOSP 基线。
- Samsung One UI：后台限制与通知渠道行为。
- Xiaomi/Redmi HyperOS：wake lock 与 Dart 冻结重点对象。
- 至少一台低内存设备。
- 无后台豁免设备只验证明确降级为轮询兜底，不套用在线提示 SLO。

每个关键故障场景至少 100 个事件；发布候选累计至少 1,000 个高优先级事件；8h 场景连续 3 轮
并记录电量、CPU、流量、socket、通知与 cursor。

### 15.5 验收清单

共享事件层：

- [ ] 已 fsync 事件在 crash/restart 后 eventId、sequence 不变。
- [ ] 同一 task generation 的 end/settled 只生成一个 completion。
- [ ] 断线期间完整 `idle -> streaming -> idle` 可从 cursor 补回。
- [ ] 多页 sync 固定 tip，实时新事件零遗漏零插队。
- [ ] 乱序接收不能越过缺口 ack。
- [ ] `cursor_expired` 明确 rebase 并报告历史缺口，不伪装完整恢复。
- [ ] 写失败/磁盘满时不宣称 persisted，且诊断可见。

通知路径：

- [ ] Flutter engine 未启动时原生仍能显示。
- [ ] 1,000 次 LAN/提示/Dart 重复乱序注入无重复打扰。
- [ ] 崩溃窗口重复落在预算内且被单独统计。
- [ ] ready 未达成时 Dart 兜底不被抑制。
- [ ] 权限/渠道关闭有准确诊断，不滥发 high priority。

FGS：

- [ ] Service 能从持久状态重建真实 owner 后才用 `START_STICKY`。
- [ ] 任务划掉后无空服务、无虚假「已连接」。
- [ ] `onTimeout` 后进入 `PUSH_ONLY`/`CURSOR_ONLY` 且通知文案如实更新。
- [ ] 用户 Stop 后不自动重启。
- [ ] `connectedDevice` 的产品语义、权限与 Play 申报通过。

身份迁移：

- [ ] 旧客户端连新 Bridge 行为不变。
- [ ] 新客户端连旧 Bridge 回退且不发新帧。
- [ ] bridgeId 冲突/重置有明确用户确认流程，不静默接管。

工程质量：

- [ ] Bridge、Rendezvous typecheck/test 全绿。
- [ ] `flutter analyze` / `flutter test` 全绿。
- [ ] Android JVM 单元测试全绿。
- [ ] 日志与诊断通过敏感字段扫描。
- [ ] PiPilot 主 worktree 未被本分支修改。

## 16. 可观测性

### 16.1 统一阶段时间线

```text
created -> persisted -> lan_queued -> lan_sent -> native_received
        -> display_requested -> display_confirmed -> receipt_uploaded -> cursor_acked
                                          |
        +-> fallback_scheduled -> fcm_accepted -> native_received -> (同上)
```

每阶段记录 eventId/bridgeId/installationId 的**短 hash**、时间、原因码，不记录正文与凭据。

### 16.2 关键指标

Bridge：pending/bytes/oldest_age/compaction/corrupt_tail、背压丢弃数、按类型的事件生成、
LAN subscription ready/stale、fallback 触发原因分布、cursor gap/expired/rebase/ack lag、
`source_event_gap`。

Android：Service create/start/destroy/restart/taskRemoved/timeout/stop reason、target
state/generation/endpoint、NSD 与 NetworkCallback 事件、socket open/hello/auth/sync/ready
时间戳、`crash_window_duplicate`、`envelope_downgraded`、`decrypt_failed_after_unlock`、
权限与渠道状态、wake lock 持有时长、配额窗口剩余。

### 16.3 用户诊断页

每台设备展示：当前模式、当前 owner（Flutter / Native LAN / 提示回连 / 无）、LAN 状态与最后 ready
时间、已验证 endpoint 与 bridge identity、最后 event/display/receipt/cursor、通知与局域网
权限阻塞原因、最近一次降级原因与恢复时间、FGS 配额剩余。

支持导出脱敏 JSON，不依赖用户抓 logcat。

## 17. 发布与回滚

### 17.1 顺序

1. Phase 1 shadow 上线：只生成事件与指标，客户端行为不变。
2. Phase 2 统一入口内部启用，旧路径保留，通过 event ownership 仲裁确保单 owner 显示。
3. 5% / 25% / 50% / 100% 逐步放量，每档至少 7 天或达到约定样本量（以较晚者为准）。
4. Phase 3 的 FGS 生命周期独立放量，**禁止与通知路径同版本切换**。
5. Phase 4 的提示兜底再独立放量。

### 17.2 回滚

- 各 flag 可独立关闭；关闭后保留 event store、cursor 与去重数据，不删除、不清空。
- 回滚后同一业务事件继续使用原 eventId，避免重新生成造成重复。
- schema 至少支持 N-1 解码；密钥轮换保留前一 key 到最大 TTL。
- 旧客户端忽略未知帧；Bridge 仅向宣告能力的客户端发送新帧。
- `bridgeInstallationId` 双字段过渡至少保留两个版本窗口才可移除 `hubId`（且需单独评估）。

## 18. 安全边界

1. mDNS 不是信任根：service name、TXT、IP 都可被同网设备伪造，必须以已鉴权 `bridge_hello`
   核对 `bridgeInstallationId` 为准，冲突时不自动覆盖 roster。
2. 明文 `ws://` 的现状必须写进威胁模型。`AndroidManifest.xml:21` 的
   `usesCleartextTraffic="true"` 与 Bridge 当前的 `ws://` 意味着 token 与事件对同网被动监听
   者不具备传输机密性。内部阶段可接受，但**不得宣称可防御恶意 LAN**。
3. WSS + 证书指纹 pinning 或应用层 AEAD 必须进入 Phase 3 或 Phase 4 的 checklist，不能只
   停在「待确认项」——长期挂在待确认里等于永不实施。pin 通过配对通道保存，mDNS 只广播
   key ID。
4. 原生通知 client 使用只读 role，Bridge 拒绝其租约、prompt、abort、文件与 session 变更命令。
5. 凭据用 Android Keystore 包装的不可导出 key，标记 no-backup，避免安装克隆身份。
6. 日志只记 profileId/bridgeId 的短 hash，不记 token、完整 payload 或设备身份凭据。
7. 帧大小、事件页、title/body 长度与 JSON 深度都有硬上限；解析失败不得让 Service 崩溃或
   进入快速重连循环。
8. 删除设备时撤销 target、cursor、installation 与 publisher 凭据。

## 19. 未决项与 owner

| # | 待确认 | 阻塞哪一期 |
|---|---|---|
| 1 | 默认模式是恢复补偿还是混合可靠；是否首次连接时让用户显式选择 | Phase 0 |
| 2 | 通知默认只显示通用提示还是允许会话名 | Phase 0 |
| 3 | `connectedDevice` 的 Play 合规结论与审核材料 | Phase 3 |
| 4 | ~~Relay 的部署主体、数据库、域名、TLS、备份与 on-call 归属~~ **已解决**（2026-08-01）：Phase 4 重设计为在线提示 + P2P 拉取，复用现有 Rendezvous，不新建 Relay（§G） | Phase 4 |
| 5 | ~~哪些渠道允许依赖 GMS；无 GMS 是否只提供纯 LAN 模式~~ **已解决**（2026-08-01）：新设计天然不依赖 GMS（§G） | Phase 4 |
| 6 | `ws://` 的生产安全边界与 WSS pinning 排期 | Phase 3/4 |
| 7 | 默认后台监控设备数与并发 socket 上限（旧方案的 4 未经实测） | Phase 3 |
| 8 | fallback 窗口最终取值与调整责任人 | Phase 4 |
| 11 | Rendezvous 部署的可用性 owner、提示帧速率限制取值与 guest 长连鉴权细节 | Phase 4 |
| 9 | Bridge 全程离线时是否需要从 session/source 持久日志恢复完成事件 | 独立 Gate |
| 10 | Android 17 走广泛 `ACCESS_LOCAL_NETWORK` 还是 NSD system picker | Android 17 前 |

未决项必须有 owner 与截止时间，不允许以 TODO 形式混进实现代码。

## 20. 验证命令

实现阶段：

```bash
cd bridge && npm run typecheck && npm test
cd rendezvous && npm run typecheck && npm test
flutter analyze
flutter test
./android/gradlew -p android app:testDebugUnitTest
```

本机执行注意：Bridge 全量集成测试会与已在运行的 `pipilot-bridge.service` 抢 9377 端口，
执行前先查残留进程与端口占用，并保持单实例、低并发、硬超时。ADB 命令前先
`adb devices -l` 确认真机在线，超时优先诊断环境而不是当作代码缺陷。

文档分支自检：

```bash
git diff --check
git status --short --branch
rg -n "^## " docs/background-notification-optimization/stable-plan.md
```

## 21. 与旧方案的差异摘要

| 项 | 旧方案 | 本方案 |
|---|---|---|
| 通知口径 | exactly-once（不可实现） | 事件不丢 + 允许重复投递 + 稳定 ID/onlyAlertOnce 保证只打扰一次 |
| 显示语义 | `notify()` 即成功 | `display_requested` / `display_confirmed` / `receipt_uploaded` 三态分离 |
| 首期范围 | Relay + Firebase + envelope + 跨端向量 | Bridge 持久事件层，无新服务、不依赖 GMS |
| Bridge 身份 | 直接换用新 ID（会断链） | 双字段过渡 + cursor 命名空间隔离 + 孤立规则 |
| target SDK | 记为 35 | 实际 36，Android 16 行为变更已生效 |
| LNP 路线 | 误用 `NEARBY_WIFI_DEVICES` | Android 16 compat opt-in，Android 17 `ACCESS_LOCAL_NETWORK` |
| FGS timeout | 只说要测 | 显式 `QUOTA_EXHAUSTED -> PUSH_ONLY/CURSOR_ONLY` 状态机与文案更新 |
| WorkManager | 假设 receipt 及时 | Android 16 job quota 约束，receipt 允许延迟且不推进 cursor |
| FCM payload | 无上限 | 已废弃：内容不过第三方通道，提示信号无内容（§13） |
| 离网兜底 | FCM + 新建 Relay + envelope 加密 | Rendezvous 在线提示 + 按需 P2P 拉取（§G） |
| TTL | 绝对 `expiresAt` | 相对 `ttlSeconds`，不信任设备时钟 |
| LAN/提示竞态 | 假设不发生 | 承认允许重复，单飞 + 稳定 ID 吸收 |
| 分期 | 一条必经长路径 | 三个决策点，任一达标即停止 |
| 原生 WebRTC | 终态目标 | 默认不做，仅在确有后台亚秒级需求时启动 |

## 22. 实施与验收记录（2026-08-01）

### §A 实施清单

**Phase 1（Bridge 持久事件层，shadow 模式接线）**

- `bridge/src/notification_identity.ts`：`bridgeInstallationId` 持久化（0700 目录 / 0600 文件，
  原子写 + 目录 fsync），`rotateEventEpoch` 支持 store 重置换世代。
- `bridge/src/notification_event.ts`：不可变 `NotificationEventV1` + 可变 `InstallationDeliveryV1`，
  相对 `ttlSeconds`，标题/正文截断上限。
- `bridge/src/notification_event_store.ts`：JSONL outbox，单串行 writer、append+fsync、
  per-record checksum、崩溃跳过损坏行不抹库、compaction 原子 rename、TTL、背压（普通事件
  collapse、高优先级独立、超限显式拒收无静默丢弃）。
- `bridge/src/notification_detector.ts`：streaming 边沿 → 事件，task generation 去重
  （`agent_end` + `agent_settled` 只出一条），in-flight 恢复，recovery- 前缀收养代次。
- `bridge/src/notification_protocol.ts`：固定 tip 订阅、分页（100 事件 / 64 KiB）、
  live buffer（256 事件 / 1 MiB 溢出 `resync_required`）、连续前缀 ack、`cursor_expired`。
- `bridge/src/server.ts`：启动加载四层模块，`noteStreamingFromEvent` 驱动 detector，
  `notification_*` 帧路由（**不经过 source 选择**——后台手机没有选中 source），
  `bridge_hello` 携带 `bridgeInstallationId` + `eventEpoch` + 能力声明。
- `bridge/src/announce.ts`：mDNS TXT 追加 `bridgeId` + `notify=1`（`hubId`/`v`/`ipv4` 保留）。

**Phase 2（修好现有 watcher + 统一通知入口）**

- `android/.../NotificationGate.kt`：去重表（SharedPreferences，免依赖序列化）、
  稳定通知 ID（FNV-1a(eventId)，保留 1=FGS）、状态机只前进不回退、崩溃后 stale PENDING 重试。
- `android/.../NativeNotificationRenderer.kt`：`setOnlyAlertOnce(true)`、channel 阻塞检测、
  `activeNotifications` 可见性确认（OEM 抛异常时宁死不谎报）、collapseKey 复用槽位。
- `android/.../NativeCursorStore.kt`：持久 cursor（commit 同步写）+ `ContiguousPrefix`
  （乱序缓冲、skipped 区间计入连续性、`rebaseTo` 修游标停滞）。
- `android/.../BridgeWatcher.kt`：通知协议客户端——能力协商（旧 Bridge 自动回退 legacy）、
  response.data 首包分发、`cursor_expired/resync/scope_changed` 处理、只 ack 连续前缀。
- `MainActivity.kt` + Dart 侧：`watcherReady` 真回调，只有 ready 才抑制 Dart 兜底
  （修掉「提交即抑制」链）；`watcherDiagnostics` 持久环形诊断（本机 logcat 对 app tag 不可靠）。
- `KeepAliveService.kt`：`onTimeout()` 显式降级（QUOTA_EXHAUSTED → 关 socket、放 wake lock、
  持久通知改文案、不违规重启 dataSync）。
- 验收期修复（真机发现）：
  - `MainActivity.bindWifiForLan`：盲选第一张 Wi-Fi → 按目标地址做子网前缀/路由匹配选网卡，
    匹配不到不绑定（进程级错绑 = 钉死在无路由网卡，连 SYN 都不发）。
  - `pi_session.dart`：首连失败也进指数退避重试（原 `!state.hasSession` 守卫使自动重连只在
    「连上过一次」后存在，瞬时失败固化成永久失败）；`_attemptReconnect` 成功补 `hasSession`。

### §B 验证结果

- Bridge：`npm run typecheck` 干净；全量 **173/173**（含 200 轮随机 kill/restart 零丢失，
  为 1,000 门槛的子集，后续可扩量）；协议路由集成测试覆盖 notification_* 帧。
- Flutter：`flutter analyze` 无问题；`flutter test` **360/360**。
- Android JVM：`app:testDebugUnitTest` **45/45**（NotificationGate/Cursor/ContiguousPrefix 等）。
- 真机（Xiaomi 13 / Android 16 / API 36）逐项：能力协商回退、单事件后台投递、
  `am crash` 进程死亡后 cursor 追补、深 Doze 恢复、30 事件突发（localhost）零遗漏。

### §C 45 分钟真实局域网后台挂机测试（16:42–17:26，最终验收）

环境：手机与桌面同网段（192.168.1.0/24）直连，无 adb reverse 等任何临时绕道；
60 秒/条共 30 条（加前置轮次合计 38 事件），用户正常使用其他 App（锁屏/解锁/切应用）。

| 维度 | 结果 |
|---|---|
| Bridge 落库 | 38 事件，seq 1–38 连续无洞，eventId 38/38 唯一 |
| 手机 cursor | 最高 ack=38，**积压 0** |
| 手机投递 | 38 次 deliver 与事件一一对应，**重复打扰 0** |
| 投递耗时 | 中位 18ms，P95 104ms，最大 258ms |
| 断连与恢复 | 15 次半开断连（冻结所致）→ watcher 8 次自动重连全部恢复 |
| OEM 冻结 | MIUI 后台约 60s 后冻结 App（内核 CPU 计数停走，FGS 亦不免），~5.5 分钟后随用户交互解冻，自动重连 + cursor 追补**全量恢复，零丢失** |

测试桩自身修复（非产品缺陷）：外部 desktop 客户端必须每 ~10s 发 `desktop_heartbeat`
（`desktopSweeper` 30s 静默判死，协议级 ping 不计入 lastSeen）。

### §D 诚实的剩余边界

- **纯 LAN 实时（§11.2）在 MIUI 后台冻结下不成立**：冻结期无实时投递是平台行为，
  事件由 outbox 持久化兜底、解冻后追补——这正是「恢复补偿默认 + 实时是加分项」的设计依据，
  也是决策点 A 支持暂不进入 Phase 3 的实测数据。若未来要后台亚秒级实时，按 §Phase 5 评估。
- 「网络变化触发恢复」已在 Phase 3 原生 owner 落地（NetworkCallback 通告即清零退避
  并立即重连）；watcher 路径仍靠 1s–15s 退避，已在实测中证明可从冻结/断连恢复。
- `DISPLAY_REQUESTED` 与 `DISPLAY_CONFIRMED` 存在差额（同 collapseKey 复用槽位时
  `activeNotifications` 读不到可见证据）：按设计不谎报确认，且允许 cursor 推进。
- 故障注入量级为 200 轮（门槛 1,000 的子集）；1,000 高优先级事件发布候选与 8h 续航按用户
  决定不执行。

### §E Phase 3 实施记录（2026-08-01，flag 后实施，待真机有限验收）

新增（全部仅 `native_lan_owner_v1`=true 时生效，默认关）：

- `LanConnectionCoordinator.kt`：独立 socket 的原生 owner，复用 `NativeCursorStore` /
  `NotificationGate`，协议帧与 watcher 一致；目标子网/路由匹配选网修掉
  `BridgeWatcher.routedClient` 的第一张 Wi-Fi 盲选；90s 活跃空洞记 `oem_freeze_suspected`。
- `ReconnectController.kt`：纯逻辑重连状态机（1s-15s 封顶退避、onFailure/onClosed
  去重、stop 取消、世代防护、网络通告立即点火）。
- `LanConnectionState.kt`：DISCONNECTED→CONNECTING→AUTHENTICATING→CATCHING_UP→READY
  显式状态机 + DEGRADED / BLOCKED_LOCAL_NETWORK，世代防旧回调覆盖。
- `NativeLanTarget.kt`：noBackupFilesDir 持久目标；`TokenCipher` 接口隔离 Keystore
  （生产 AES/GCM，测试明文直通）；无依赖序列化可 JVM 测。
- `NsdDiscovery.kt`：`_pipilot._tcp` 一轮发现，TXT `ipv4` 优先、`notify=1` 过滤。
- `MainActivity`：startWatcher 按 flag 路由、每次持久化目标、双 owner ready 通道、
  `setFeatureFlag` / `connectionMetrics` / `clearConnectionMetrics` 通道。

验证：`ReconnectControllerTest` 7 + `LanConnectionStateTest` 3 + `NativeLanTargetTest` 5
覆盖持续重试/成对回调只排一次/stop 取消/网络恢复清零并立即重连/旧世代全拒/持久往返与
损坏拒绝；三端回归全绿（Bridge typecheck + 测试、flutter analyze 零问题、flutter test 360、
Android JVM 60）。

明确不声称：connectedDevice 迁移（合规 Gate 未过，保留 dataSync）；8h 功耗（用户已豁免）；
真机有限验收（45 分钟日常使用 + Wi-Fi 切换 + DHCP 换址 + 进程死亡恢复）待跑；
Dart 侧 flag 开关 UI 未做（验收期用 `setFeatureFlag` 通道或 run-as 改 prefs）。

### §F 后台豁免发现与多厂商适配（2026-08-01）

**决定性变量**：用户在小米 13 上授予「后台无限制」后，复测 5 分钟 7 条事件全部实时送达
（延迟 7–43ms、零丢失、零半开击杀、CPU jiffies 持续增长）——MIUI 整体冻结由「必然」变为
「未授予时的默认行为」。此前四次冻结实测（92s / 5m27s / 6m21s / 6m21s）均发生在未授予状态。

**实测校正厂商文档**：小米文档只承诺「无限制」映射到 `isBackgroundRestricted()`，但 HyperOS
V816 / Android 16 上它同时把包名写入 deviceidle 白名单（`user,com.pipilot.pi_pilot`），标准 API
`isIgnoringBatteryOptimizations()` 在该机上即可作为检测信号，无需私有逆向。

**已落地**（三端回归全绿：Kotlin 编译、Android JVM 76、flutter analyze、flutter test 360）：

- `BackgroundPermissionState.kt`：三公开 API 并集判定（deviceidle 白名单 + 用户显式限制 +
  standby bucket），判定逻辑抽成纯函数供 junit4 覆盖；中间档 bucket 不参与判定
  （官方「Don't try to influence which bucket」+ 充电时无视 bucket）。
- `OemVendor.kt` + `BackgroundPermissionIntents.kt`：小米/三星/vivo/OPPO/一加/华为/荣耀/魅族
  各一组候选组件名逐个 try，全失败退回标准页——私有组件名无一稳定 API，Android 11+ 包可见性
  使 `resolveActivity` 不可作为判据，只能 try/catch 降级。三星 deeplink 是唯一有官方文档的。
- 设置页「通知与快捷指令」新增「后台运行」入口：未授予时先弹厂商对应路径说明再跳设置，
  回前台自动刷新。
- 有意不用 `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 弹框：Play Device and Network Abuse
  政策禁止不符合豁免条件者绕过电源管理，有真实拒审案例；只用不需权限的列表页 Intent。

**对路线图的影响**：决策点 B 的第一条「纯 LAN 实时达标」在用户授权后即可满足，Phase 4
的定位从「绕过冻结」回归本来的「跨网络送达」（离网/远程/不同 LAN）。
是否仍做 Phase 4 取决于产品是否需要跨网络通知，而非冻结问题。
（编者注：Phase 4 已于同日晚些时候重设计为在线提示 + 按需 P2P 拉取，见 §G。）

**未验证**：三星/vivo/OPPO 等厂商组件名来自社区维护列表，新系统上存活率无真机可测，
靠降级链宪底 + 层级名文案让用户自行辨认。荣耀 MagicOS 缺少一手证据（dontkillmyapp 无独立页）。

### §G Phase 4 设计转向：废弃 Relay/FCM envelope，改用「在线提示 + 按需 P2P 拉取」（2026-08-01）

**起因**：用户明确否决原 Phase 4 的复杂度（「这些我都不想弄」），并要求通知必须由
PiPilot 自己弹出（「我要的是我这个app通知」）。原设计复杂的根源是一个架构选择——
让不可信的第三方 Relay 运送**加密内容**，因此才需要 envelope 加密、每设备密钥、
密钥轮换、bootstrap ticket、PostgreSQL 与 Relay 运维。

**设计**（中转通道只按门铃、不送信）：

```text
任务完成 → Bridge 先试 LAN（READY 订阅，秒级）
              ↓ LAN 送不到（手机不在同一网络）
         Bridge 经 Rendezvous 转发无内容提示信号（仅 installation 域 nonce）
              ↓
         手机进程存活时收到提示 → 走已有 WebRTC P2P 按需回连 Bridge
              ↓
         cursor 从 outbox 拉取事件（Phase 1）→ NotificationGate 展示（Phase 2）
              ↓
         通知自始至终由 PiPilot 自己发出
```

**砍掉的全部组件**：notification-relay 服务、PostgreSQL、AES-GCM envelope
与 4 KiB 预算、每设备 notification key 与轮换、bootstrap ticket 凭据体系、Keystore
notification key 锁定期处理。内容不过任何第三方通道，加密层整个消失。

**保留不变的**：§8 单飞/竞态语义、fallback 窗口与原因码、receipt 驱动仲裁；
Phase 1-3 的全部代码（outbox、cursor、NotificationGate、原生 owner）零修改复用。

**Advisor 纠偏（同日，必须如实记录的三条事实）**：

1. Rendezvous 提示**只能在 PiPilot 进程与 socket 都活着时送达**——它不是进程唤醒
   机制，最初版文档的「手机被唤醒」措辞不成立，已全文改为「在线提示」。
2. WorkManager 的 15 分钟是**最小调度间隔**而非送达保证，Doze/配额/OEM 可使其更晚。
3. 进程已死还要近实时，**唯一可信路径是 OS 级推送**（FCM 或 MiPush/个推/极光）。
   因此 Phase 4 拆为两个可选模式：`remote_hint_v1`（在线提示，零新设施，默认先做）
   与 `system_push_wake_v1`（纯数据推送叫醒，可选升级）。推送用纯数据载荷时，
   系统只是把载荷递给 PiPilot 进程，**通知仍由 PiPilot 自己经 NotificationGate 弹出**——
   这与「第三方 App 代弹通知」有本质区别，满足用户「我这个app通知」的要求。

**新增的三块**（两模式共享，仅唤醒传输不同）：Rendezvous 提示路由、
Bridge fallback 触发器、Android 后台信令长连 owner（复用 Phase 3 ReconnectController
模式）+ WorkManager 周期轮询兜底。

**诚实代价**：进程活着时提示+P2P 建连比 FCM 推送慢，SLO P95 ≤15s（§2.4）；
手机端保活依赖「后台无限制」豁免（§F 已验证豁免有效）；豁免缺失或进程死亡时降级为
best-effort 恢复信号（WorkManager 只是调度信号，拉取要等 App 启动）与下次打开 App 补齐；
死亡进程下的近实时通知需要模式二，且只能先弹通用通知、详情等前台补齐——死亡进程下
直接弹详情需 headless/原生 WebRTC/加密载荷，明确不做。
Rendezvous 需要公网可达（P2P 配对本来就用它，已存在）。

**未决项变化**：#4（Relay 部署主体）与 #5（GMS 决策）随旧方案一并关闭；新增 #11
（Rendezvous 可用性 owner、提示帧速率限制取值、guest 长连鉴权细节），阻塞 Phase 4 实施。

## 23. LAN 威胁模型与合规记录（Phase 0 治理欠债补账，2026-08-01）

### §A 威胁模型（LAN 范围）

1. **传输明文边界（现状）**：`ws://` + `usesCleartextTraffic=true`，token 与事件对
   **被动同网观察者**无机密性。内部接受此边界，但**禁止**对外声称可防御恶意 LAN。
   WSS + 证书指纹固定或应用层 AEAD 仍在 Phase 3/4 检查单中，指纹经配对通道下发，
   mDNS 只放 key id。
2. **mDNS TXT 不可信**：同网任何设备可伪造。`bridgeId`/`notify=1` 只是发现提示，
   **不是信任根**；客户端必须以认证后 `bridge_hello` 内的 `bridgeInstallationId` 为准，
   认证身份与持久值不符时记 `identity_conflict` 且**不得静默改写 endpoint**。
3. **凭据与 cursor 存储**：Phase 3 起持久于 `noBackupFilesDir`（不进云备份/设备迁移），
   凭据经 Android Keystore 包装；Keystore 在重启后首次解锁前不可用时只保留路由元数据，
   不落明文。
4. **通知内容隐私**：`presentation` 默认 generic（不含会话名/正文），`session_name`
   需用户显式开启；receipt/diagnostic 只记短 hash 与原因码，禁止正文与凭据。
5. **离线伪造面**：Bridge 未认证前不执行任何来自 socket 的写操作；通知事件以
   Bridge 持久层为唯一权威来源，客户端不根据未认证数据生成提醒。

### §B 合规与验收豁免记录

1. **8 小时锁屏续航测试：用户已豁免（2026-08-01）**。后果：Phase 3 gate 中
   「8h 真机功耗与稳定性达标」一项**不能以原口径声称通过**；本阶段只报
   「flag 后已实施 / 有限验收（45 分钟后台 + 切应用 + 锁屏 + Wi-Fi 切换 +
   进程死亡追补）」。若要发布为默认路径，8h 测试仍需补做或正式降级验收标准。
2. **connectedDevice FGS 合规 Gate：未通过，保留 `dataSync`**。迁移需：前台用户
   显式开启 + 真实已配对桌面设备 + `FOREGROUND_SERVICE_CONNECTED_DEVICE` 与匹配权限 +
   通知指明设备与停止路径 + Play Console 声明与可复现审核视频 + 法务/发布确认。
   未批准前不得以 connectedDevice 规避 dataSync 6h 限额。
3. **MIUI 进程冻结**：实测（2026-08-01，Xiaomi 13 / Android 16）App 后台约 60s 后
   进程被整体冻结（内核 CPU 计数停走，FGS 亦不免），约 5.5 分钟随用户交互解冻，
   解冻后自动重连 + cursor 追补全量恢复。**Dart→Kotlin 迁移不改变进程级冻结**；
   Phase 3 的收益是 Flutter isolate 独立、DHCP/Wi-Fi 自愈与生命周期可重建，
   不是冻结免疫。
