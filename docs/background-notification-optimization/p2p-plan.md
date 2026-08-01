# Android P2P 后台连接与通知优化执行计划

日期：2026-08-01
状态：待实施
分支：`background-notification-optimization`
范围：Android 客户端、P2P 前台连接、Bridge、通知 Relay、Rendezvous 引导鉴权
本分支约束：只新增计划文档，不修改实现代码

关联计划：[Android 局域网后台连接与通知优化执行计划](lan-plan.md)

> **本文已降级为远程/推送专项参考，不再作为独立实施计划。**
> 实施路径、可靠性口径、分期与验收以
> [统一稳定方案](stable-plan.md) 为准。本文的 Relay 引导鉴权、installation/publisher
> 凭据分离、密钥轮换等技术细节仍然有效并被新方案引用；但以下四处已被新方案修正，
> 阅读时请以 `stable-plan.md` 为准：
>
> 1. §2.3 的「同一 eventId 最多显示一次」exactly-once 口径不可实现（见 stable-plan §2）。
> 2. §5.2 的 envelope 未约束 FCM 4 KiB 上限，且用绝对 `expiresAt` 依赖设备时钟
>    （见 stable-plan §13.1、§5.4）。
> 3. §8.2 把 receipt 上传当作及时路径，未考虑 Android 16 的 job quota 约束
>    （见 stable-plan §4.3）。
> 4. §9/§15.3 只要求测试 FGS 6 小时 timeout，未定义 timeout 后的降级状态
>    （见 stable-plan §10.3）。
>
> 另外本文 §3.5 把 streaming 边沿标为 `bridge/src/server.ts:601-627`，实际
> `noteStreamingFromEvent()` 在 `:623`。

> 本文负责 P2P/远程场景及其云端推送兜底。局域网直连、原生 LAN connection
> owner、mDNS 地址自愈和纯局域网实时模式以 `lan-plan.md` 为准。两份计划共享同一套
> Bridge 持久事件、`eventId`、installation cursor 和 Android 原生去重实现，禁止各自
> 建立互不兼容的 outbox 或通知协议。

## 1. 执行摘要

本计划不承诺 Android 上不存在的“永久保活”。用户主动强制停止、Android 13+
Active apps 的 Stop、通知权限被拒绝、无 Google Play Services、设备重启后的启动限制，
以及部分 OEM 的额外冻结策略，都可能阻止进程、连接或通知继续工作。

P2P/远程场景的目标架构采用三层职责分离：

1. **P2P 负责前台低延迟数据通道**，不再作为后台通知的唯一来源。
2. **FCM 高优先级 data message 负责后台唤醒和用户可见通知**，由 Android 原生
   `FirebaseMessagingService` 直接解密、去重并显示，不依赖 Flutter engine。
3. **Bridge 持久事件 outbox 与事件 cursor 负责最终一致性**，即使推送延迟、重复、
   App 进程重启或临时离线，App 下次连接后也能补齐事件。

如果产品仍要求“用户开启持续连接后尽量常驻”，再把连接 owner 移入真正由 Android
Service 管理的生命周期，并在业务语义和 Google Play 政策允许时把 FGS 从
`dataSync` 迁移到 `connectedDevice`。只修改 `START_STICKY` 或 wake lock 不能解决
当前 Dart isolate 被 OEM 冻结的问题。

推荐优先级：

| 优先级 | 目标 | 结论 |
|---|---|---|
| P0 | 后台任务提醒可靠到达 | Bridge outbox + FCM + 原生通知 + cursor 补偿 |
| P1 | 前台服务生命周期正确 | 合规评估后迁移 `connectedDevice`，服务可重建状态 |
| P2 | 可选的持续后台双向连接 | 仅在指标证明必要时投入原生连接 owner |
| P3 | 收敛现有恢复缺陷 | 跨重连传输、建链超时、请求级进度、watcher 握手 |

## 2. 目标、非目标与可靠性口径

### 2.1 目标

1. App 在后台、锁屏、普通任务划掉或进程被系统回收后，只要未被用户强制停止、
   通知权限有效且 FCM 可用，任务完成和等待输入提醒仍可显示。
2. Bridge 在产生事件后必须先持久化，再尝试推送；进程重启不得静默丢事件。
3. 推送允许重复和乱序，但用户界面同一 `eventId` 最多显示一次通知。
4. App 恢复连接后按 cursor 补齐推送遗漏，并能识别 cursor 过期后需要 rebase。
5. 后台通知路径不依赖 Flutter isolate、WebRTC DataChannel 或持续 wake lock。
6. 用户明确开启“持续连接”时，FGS 有可见通知、停止入口、可恢复状态和明确诊断。
7. 整条链路可观测：能区分事件未生成、未入 outbox、Relay 失败、FCM 拒绝、
   Android 未显示、重复被抑制和恢复补偿。

### 2.2 非目标

以下场景不得对外承诺实时通知或永久在线：

- 用户在系统设置中执行“强制停止”。
- 用户在 Android 13+ Active apps 中点击 Stop。
- 用户拒绝或关闭 `POST_NOTIFICATIONS`。
- 设备没有可用 Google Play Services，且未安装后续可选推送适配器。
- OEM 明确禁止自启动、网络或后台执行，用户也未授权例外。
- 手机或 Bridge 均无网络、Relay/FCM 大范围故障。
- 通过静音音频、错误 FGS 类型、频繁 exact alarm、无限 wake lock 等方式规避平台政策。
- 初版将完整 P2P/WebRTC 数据面重写为 Kotlin。

### 2.3 可靠性口径

将“实时性”和“最终一致性”分开验收：

- **最终一致性**：在事件保留期内，只要 App 再次连接 Bridge，已持久化事件必须
  100% 可通过 cursor 补齐，不因 FCM 投递结果而删除。
- **可见通知去重**：每个 installation 上，同一 `eventId` 最多显示一次。
- **推送时延 SLO**：在设备在线、通知允许、GMS 健康的真机样本中，至少 99% 的
  高优先级事件在 60 秒内显示，P95 不高于 10 秒。该值是产品 SLO，不是 FCM SLA。
- **恢复时延 SLO**：App 回前台或可恢复的 Service 重启后，15 秒内开始连接或明确
  显示不可恢复原因；不得停留在虚假的“已连接”。
- **资源预算**：Bridge outbox 默认不超过 16 MiB 或 10,000 条未过期记录；Android
  去重表默认不超过 2,048 条或 7 天。

## 3. 当前状态与缺口

### 3.1 Android 前台服务不是连接 owner

- `android/app/src/main/AndroidManifest.xml:14-17` 声明 FGS、`dataSync` 和 wake lock。
- `android/app/src/main/AndroidManifest.xml:47-51` 设置
  `android:stopWithTask="true"` 和 `foregroundServiceType="dataSync"`。
- `android/app/src/main/kotlin/com/pipilot/pi_pilot/KeepAliveService.kt:112-125`
  只建立常驻通知、持有 partial wake lock，并返回 `START_NOT_STICKY`。
- `KeepAliveService.kt:128-131` 在任务移除时主动 `stopSelf()`。
- P2P owner 仍在 `lib/state/pi_session.dart:2257` 每次 `_open()` 新建的 Dart
  `P2pConnector` 中。Service 存活不等于 Flutter engine 或 DataChannel 存活。

### 3.2 原生 watcher 只覆盖局域网的窄场景

- `lib/state/notification_controller.dart:43` 对实际 P2P transport 返回 null。
- 原生 `BridgeWatcher` 只能接管当前激活设备、当前选中 source 的完成边沿。
- 扩展等待输入、其他设备/会话、显式断线提醒仍依赖 Dart。
- `notification_controller.dart:248-263` 在 MethodChannel 返回后设置
  `_watcherActive`，但 `MainActivity.kt:43-68` 只表示异步 start 已提交，不代表 socket
  已认证连接。随后 `notification_controller.dart:371` 可能过早抑制 Dart 通知。

### 3.3 进程死亡没有持久补偿

- `notification_controller.dart:158` 的 `_streamingWhenBackgrounded` 是内存字段。
- 进程重启后它会归零，无法证明后台期间发生过 `streaming -> idle`。
- 当前没有独立于 session snapshot 的持久通知 eventId、sequence 或 ack cursor。

### 3.4 Android 平台硬约束

- targetSdk 35+ 的 `dataSync` FGS 在 Android 15+ 后台总时长受 6 小时/24 小时限制。
- Doze 会暂停普通网络访问并忽略 wake lock；持续 socket 不是可靠唤醒机制。
- Android 13+ Active apps Stop 会终止整个 App，FGS 不能阻止。
- `connectedDevice` 适用于需要网络连接与外部设备持续交互的场景，但必须真实符合
  产品语义、声明 `FOREGROUND_SERVICE_CONNECTED_DEVICE`，并在 Play Console 申报。
- `remoteMessaging` 只适用于跨设备延续文本消息任务，不得作为绕过时限的通用类型。

官方依据：

- <https://developer.android.com/develop/background-work/services/fgs/service-types>
- <https://developer.android.com/develop/background-work/services/fgs/timeout>
- <https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping>
- <https://developer.android.com/training/monitoring-device-state/doze-standby>
- <https://firebase.google.com/docs/cloud-messaging/android/message-priority>

### 3.5 已有可复用基础

- Android 已有通知渠道、运行时权限和原生通知渲染入口。
- Bridge 已在 `bridge/src/server.ts:601-627` 维护 authoritative streaming 边沿，
  可作为任务完成事件生成点，而不是相信移动端旧状态。
- Bridge 已有 append-only 操作日志模式：`bridge/src/server.ts:655-678`。
- Bridge 配置使用 `0600` 文件权限：`bridge/src/config.ts:70-92`。
- 客户端已有连接恢复、event/session 同步、通知去重 ID 和设备 roster。
- Rendezvous 已校验 pairing key，适合在已认证会话中签发一次性 Push 引导票据，
  但不应直接持有 Firebase service account。

## 4. 目标架构

```text
pi / extension event
        |
        v
Bridge authoritative event detector
        |
        v  append + fsync before publish
Bridge notification outbox
        |
        v  scoped publisher credential, HTTPS
Notification Relay --------------------+
        |                               |
        | FCM HTTP v1                   | receipts / token state
        v                               |
Google Play services                   |
        |                               |
        v                               |
Android FirebaseMessagingService ------+
        |
        +--> decrypt + validate + dedupe + post native notification
        |
        +--> persist receipt; later upload with WorkManager

App foreground / reconnect
        |
        +--> notification_sync(afterCursor)
        +<-- retained events / cursor_expired
        +--> notification_ack(throughCursor)
```

### 4.1 职责边界

| 组件 | 权威职责 | 不负责 |
|---|---|---|
| Bridge | 识别业务事件、分配 sequence、持久化 outbox、重试发布、提供补偿分页 | 保存 FCM service account |
| Notification Relay | installation 注册、publisher 鉴权、token 生命周期、调用 FCM、限流与指标 | 解密通知正文、保存 pairing key |
| Rendezvous | 在已认证 pairing 会话中签发短期单次 bootstrap ticket | 长期保存 FCM token 或事件正文 |
| Android 原生层 | 接收 FCM、解密、去重、立即显示通知、保存 receipt | 依赖 Flutter engine 才能通知 |
| Flutter | 设置界面、前台连接、cursor 同步、展示完整状态 | 后台通知的唯一触发器 |

## 5. 事件模型与协议

### 5.1 Bridge 事件记录

Bridge 使用与 LAN 计划完全相同的不可变业务事件；sequence 属于稳定
`bridgeInstallationId + eventEpoch` 命名空间。installation 的加密、发送和重试状态必须
与业务事件分离：

```ts
interface NotificationEventV1 {
  schema: 1;
  bridgeInstallationId: string;
  eventEpoch: string;
  eventId: string;             // UUID v4，永久去重键
  sequence: number;            // eventEpoch 内单调递增
  taskGenerationId?: string;   // agent_end/settled 共用的任务代次
  sourceId?: string;
  sessionId?: string;
  type: "task_completed" | "input_required" | "input_resolved";
  createdAt: string;           // ISO-8601 UTC
  expiresAt: string;
  priority: "high" | "normal";
  collapseKey?: string;
  presentation: {
    title: string;
    body?: string;
    privacy: "generic" | "session_name";
  };
}

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
    encryptedPayload?: string; // 该 installation 的 AES-GCM envelope
    attempts: number;
    nextAttemptAt?: string;
  };
}
```

规则：

- `task_completed`：以 Bridge authoritative `isStreaming true -> false` 边沿生成。
- `input_required`：以尚未回答的 `extension_ui_request` 生成；回答、取消或过期后生成
  `input_resolved`，不依赖系统通知一定能被远程撤回。
- 连接中断提醒属于 installation 本地状态，使用 collapse notification，不写成全局业务事件。
- `agent_end` 和 `agent_settled` 对同一 task generation 只能生成一个完成事件。
- 业务事件必须先落盘并 fsync，再生成各 installation 的 delivery/envelope。
- 多 installation 共用一个 eventId，但分别维护密文、keyId、发送状态和 cursor。
- FCM 接受不等于业务事件已消费；不得据此立即删除 outbox 记录。

### 5.2 推送 envelope

FCM 使用 data message，所有值为字符串。payload 必须足够让 Android 不发起网络请求就
能立刻显示通知：

```json
{
  "schema": "1",
  "event_id": "uuid",
  "sequence": "123",
  "event_type": "task_completed",
  "created_at": "2026-08-01T00:00:00Z",
  "expires_at": "2026-08-01T01:00:00Z",
  "key_id": "notify-key-v1",
  "nonce": "base64url",
  "ciphertext": "base64url"
}
```

加密与密钥配置约定：

- 每个 installation 使用独立、随机生成的 256-bit notification key；不得直接从当前
  pairing secret 派生。现有 pairing policy 只保证长度和字符类别，不能证明高熵。
- notification key 只能在 mobile token 已完成 hub 鉴权后配置。P2P 路径可通过已建立的
  DTLS DataChannel 交付；若配置通道不具备机密性，则使用 Android installation 公钥包装。
- 若公钥包装使用 ECDH + HKDF，HKDF 的输入必须是高熵 ECDH shared secret，salt/AAD 绑定
  `bridgeInstallationId + installationId + keyId`，不能使用用户输入的 pairing secret。
- payload 使用 AES-256-GCM，nonce 为随机 96 bit 且同 key 下绝不复用。
- AAD 绑定 `schema + eventId + sequence + bridgeInstallationId + installationId +
  eventType + expiresAt`。
- Bridge 以 `0600` 保存 installation key material；Android 只保存由 Keystore 包装后的 key。
- envelope 带 `key_id`；轮换时保留前一 key 到最大事件 TTL 结束。
- Relay 和 FCM 只能看到 routing metadata 与 ciphertext。
- 严禁上传 hub token、pairing secret、notification key、完整会话正文或用户输入。

### 5.3 Cursor 补偿协议

新增移动端和 Bridge 间协议：

```text
mobile -> bridge
notification_sync {
  installationId,
  cursor: { eventEpoch, sequence } | null,
  scopes,
  scopeVersion,
  limit: 100
}

bridge -> mobile
notification_events {
  eventEpoch,
  scopeVersion,
  events: [...],
  skippedRanges: [{ from, through }],
  through: 130,
  tip: 150,
  hasMore: false,
  oldestAvailable: 40
}

mobile -> bridge
notification_ack { installationId, eventEpoch, through: 130 }
```

约束：

- cursor 是排他的已消费 `{eventEpoch, sequence}`，不是仅存在内存中的 source cursor。
- 响应固定 tip 边界，分页期间新增事件不得改变当前 run 的上界。
- cursor 遍历 Bridge 全局 sequence；scope 排除项由 Bridge 合并为 `skippedRanges`，与
  events 一起连续覆盖到 `through`，不得制造无法解释的 sequence gap。
- 客户端只 ack 已安全处理事件与明确 skipped range 构成的最高连续前缀。
- scope 扩大默认只影响新 scopeVersion 生效后的未来事件；历史补发使用独立 replay，
  不能回退现有 cursor。
- cursor 早于保留窗口时返回
  `cursor_expired {eventEpoch, oldestAvailable, currentTip}`，客户端执行 authoritative
  session snapshot rebase 并记录历史缺口，不静默跳过。
- 旧 ack 幂等且不得回退；越界、epoch 或 installation 不匹配必须显式失败。
- 多个 Android installation 分别维护消费 cursor、delivery 和通知去重记录。
- LAN subscribe/live buffer 的完整 ready 与过滤语义以 `lan-plan.md` 第 6、8 节为准。

## 6. Bridge 持久化与发布

### 6.1 P0 存储选择

Bridge 当前没有数据库依赖，且是单进程 owner。P0 采用有界 append-only JSONL，避免
引入 native SQLite 构建依赖：

- 路径：`~/.pi/agent/pipilot/notification-outbox-v1.jsonl`。
- 权限：目录 `0700`，文件 `0600`。
- 每条记录带 schema、CRC32 或 SHA-256 checksum。
- append 后调用 `fsync`，再进入发送队列。
- ack/状态变化追加 tombstone，不原地改写。
- 启动时 replay，忽略损坏尾行并记录诊断，禁止整库清空。
- 超过 16 MiB、10,000 条或 tombstone 比例 30% 时压缩：写临时文件、fsync、原子 rename。
- 默认保留 7 天；超过 TTL 后标记 expired，并保留最小诊断统计。
- 后续并发写入或多进程需求出现时，再迁移 SQLite，并保留版本化 importer。

### 6.2 建议文件

```text
bridge/src/notification_event.ts
bridge/src/notification_outbox.ts
bridge/src/notification_publisher.ts
bridge/src/notification_crypto.ts
bridge/test/notification_outbox.test.ts
bridge/test/notification_publisher.test.ts
bridge/test/notification_recovery.integration.test.ts
```

### 6.3 重试策略

- 只对网络错误、429 和 5xx 重试。
- 指数退避：1s、2s、4s、8s，随后上限 5min，并带 full jitter。
- Relay 明确返回无效 publisher credential 时暂停该 target，等待重新配对或刷新。
- 事件过期后停止高优先级推送，但保留到 cursor retention 截止，以支持前台补偿。
- 同一 `eventId` 的并发 publish 由单飞锁去重。
- Bridge 退出前无需等待所有网络请求，但必须保证记录已 fsync。

## 7. Notification Relay

### 7.1 独立服务而非扩展 Rendezvous

新增顶层 `notification-relay/` 服务，避免把 Firebase 凭据、持久化 token 和推送限流
塞进当前只做临时信令转发的 Rendezvous。两者可部署在同一主机，但进程、配置和密钥
权限分离。

建议模块：

```text
notification-relay/src/server.ts
notification-relay/src/config.ts
notification-relay/src/store.ts
notification-relay/src/fcm_client.ts
notification-relay/src/auth.ts
notification-relay/src/rate_limit.ts
notification-relay/test/*.test.ts
```

生产存储使用 PostgreSQL；本机测试使用内存 store 或临时数据库。不得把生产 token
落在仓库或普通日志中。

### 7.2 Bootstrap 与长期凭据

Relay 不保存 pairing secret。采用一次性 capability bootstrap + 长期 installation 凭据：

1. Android guest 和 Bridge host 已经通过 Rendezvous pairing challenge。
2. 已认证连接请求一次性 bootstrap ticket。
3. Rendezvous 用独立签名密钥签发 5 分钟 ticket，claims 至少包含：
   `bridgeInstallationId`、`role`、`installationId`、`scope`、`jti`、`iat`、`exp`。
4. Android 用 `register` ticket 向 Relay 首次注册 FCM token 和 installation public key；
   Relay 返回随机 256-bit `installationCredential`，只返回一次并只保存其 SHA-256 摘要。
5. Android 用 Keystore 包装 installation credential；ticket 过期后的 token refresh、receipt、
   permission 状态和撤销都使用该长期 credential 或 installation 私钥签名鉴权。
6. Bridge 用 `publish` ticket 换取随机 256-bit、设备级 publisher credential。
7. Bridge 以 `0600` 保存 publisher credential；Relay 只保存其 SHA-256 摘要。随机高熵
   token 使用快速哈希即可，比较必须 timing-safe。
8. installation credential 与 publisher credential 分 scope、可独立轮换和撤销。
9. ticket 的 `jti` 单次消费；重放返回 409。

需要新增的接口：

```text
POST /v1/installations/register
POST /v1/installations/refresh-token
DELETE /v1/installations/{installationId}
POST /v1/publish
POST /v1/receipts
GET  /health
```

### 7.3 Relay 数据边界

Relay 保存：

- opaque device routing ID
- installation ID
- 加密后的 FCM registration token
- token generation、状态、更新时间
- installation credential/public-key hash、scope、轮换和撤销时间
- publisher credential hash、scope、撤销时间
- 发送结果和匿名化延迟指标

Relay 不保存：

- pairing secret 或 hub token
- 解密后的通知标题、正文、session 内容
- SDP、ICE、会话历史

### 7.4 FCM 规则

- `task_completed`、`input_required` 使用 high priority，并且 Android 必须立即产生用户
  可见通知，否则 FCM 可能降级后续消息。
- 普通状态同步使用 normal priority。
- `collapseKey` 只用于可替代状态，不用于必须逐条可见的 task completion。
- 设置合理 TTL：输入等待建议 1h，任务完成建议 24h，连接状态建议 5min。
- 无效/未注册 token 立即禁用该 installation，并要求下次 App 启动刷新。
- FCM HTTP v1 service account 只存在 Relay secret manager 中。

## 8. Android 原生通知路径

### 8.1 建议文件

```text
android/app/src/main/kotlin/com/pipilot/pi_pilot/PushMessagingService.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/PushCredentialStore.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NotificationDeduplicator.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NativeNotificationRenderer.kt
android/app/src/main/kotlin/com/pipilot/pi_pilot/NotificationReceiptWorker.kt
android/app/src/test/kotlin/com/pipilot/pi_pilot/PushEnvelopeTest.kt
android/app/src/test/kotlin/com/pipilot/pi_pilot/NotificationDeduplicatorTest.kt
```

Flutter 建议新增：

```text
lib/core/push_registration.dart
lib/state/push_registration_controller.dart
test/push_registration_test.dart
```

### 8.2 `onMessageReceived` 严格时序

`PushMessagingService.onMessageReceived()` 只做有界同步工作：

1. 校验必需字段、schema、时间戳和 TTL。
2. 从 Keystore-backed store 读取 `keyId` 对应密钥。
3. AES-GCM 解密并校验 AAD/tag。
4. 在本地去重表中原子 claim `eventId`。
5. 立即通过已有 high-importance channel 显示通知。
6. 持久化 `displayedAt` receipt。
7. 网络回执交给 WorkManager，不在消息回调内等待网络。

任一步失败都记录结构化错误码，但不得记录 ciphertext、token 或解密正文。解密失败不显示
伪造内容；可用通用低敏提示的策略必须单独经过产品和安全评审。

### 8.3 去重与通知 ID

- 本地表以 `installationId + eventId` 为唯一键。
- Android notification ID 由稳定 hash 映射，但要避开 FGS 固定 ID `1`。
- 同一 task 的状态更新使用相同 notification ID；不同 task completion 不 collapse。
- 表保留 7 天或 2,048 条，清理不得删除仍在通知栏中的事件映射。
- App 启动时把 native receipt 合并到 Flutter/Bridge cursor ack。

### 8.4 Token 生命周期

- 首次授权后注册 token。
- `onNewToken()` 只持久化 pending token，并安排有网络约束的 WorkManager 刷新 Relay。
- 登出、删除设备、重新配对时撤销旧 installation。
- 重新安装产生新 `installationId`，旧 token 由 Relay 的 FCM 错误或过期任务清理。
- 通知权限被拒绝时仍可注册 normal state，但禁止发送 high-priority 用户提醒，避免
  FCM 因看不到可见通知而降级。Relay 必须知道 `notificationsEnabled` 状态。

## 9. FGS 生命周期迁移

### 9.1 必须先修复 owner，再放宽生命周期

当前 `KeepAliveService` 只保存静态计数和 wake lock。若先改成 sticky 且允许任务划掉后
继续运行，会留下没有 Flutter engine、没有连接 owner 的“空服务”。迁移顺序必须是：

1. 先定义并持久化 `BackgroundConnectionState`。
2. Service `onCreate/onStartCommand` 能独立重建所需 owner 或明确降级到“仅等待推送”。
3. 再设置 `stopWithTask=false`、移除 `onTaskRemoved()` 的主动停止、返回 `START_STICKY`。
4. 最后评估并切换 `connectedDevice` 类型。

### 9.2 `connectedDevice` 合规 Gate

只有以下条件同时满足才迁移：

- 用户明确开启“持续连接”，且有已配对外部桌面设备。
- Service 的实际工作是与该设备保持网络交互，而非单纯等待云端通知。
- Manifest 声明 `FOREGROUND_SERVICE_CONNECTED_DEVICE`，运行时调用使用匹配 type。
- 常驻通知明确说明连接的设备和停止方式。
- Play Console 提交可复现的视频、产品说明和用户触发路径。
- 法务/发布审核确认不属于错误分类规避 `dataSync` 限时。

如果 Gate 不通过，保留 FCM + cursor 架构，不用错误 FGS 类型换取表面常驻。

### 9.3 用户控制

- 持续连接必须由用户在前台显式开启。
- FGS 通知提供“断开并停止” action。
- App 设置页显示通知权限、FGS 状态、最后 push、最后 receipt、最后 cursor。
- 只提供跳转电池优化设置的说明；除非满足 Android/Play 可接受用例，不直接请求豁免。
- P0 不实现开机自动拉起。后续若增加 `BOOT_COMPLETED`，必须单独验证 Android 版本限制、
  用户 opt-in、FGS 后台启动资格和 OEM 行为。

## 10. 后台连接 owner 决策

| 方案 | 优点 | 缺点 | 结论 |
|---|---|---|---|
| 保留 UI Flutter engine | 改动最小 | Activity 销毁/OEM 冻结后无 owner | 不满足持续连接 |
| Headless Flutter engine | 复用 Dart 协议和 `flutter_webrtc` | plugin 生命周期复杂，仍可能被 OEM 冻结，双 engine 状态交接风险高 | 仅限实验 flag |
| Kotlin Service + 原生 WebRTC | 独立于 UI/Flutter，生命周期和诊断最清晰 | 需实现信令、协议、transfer 镜像，成本和双端漂移风险最高 | 真正持续 P2P 的推荐终态 |
| 不维持后台 P2P，FCM 后按需重连 | 最符合 Android 电源模型，成本和耗电最低 | 后台无持续低延迟双向数据面 | P0/P1 默认推荐 |

决策：先完成 FCM 和 cursor。上线指标若证明“用户收到通知后按需重连”满足体验，就不做
原生 WebRTC 重写。只有明确存在后台亚秒级双向操作需求，才进入 native owner 项目。

若进入 native owner，必须先定义 transport-neutral `BridgeChannel` 协议测试向量，让 Dart
和 Kotlin 共用帧样例、认证、心跳、分页和错误码，禁止复制逻辑后各自演化。

## 11. 分阶段实施清单

### Phase 0：基线、契约和 feature flags

- [ ] 固定事件类型、schema、sequence、cursor、TTL 和 collapse 规则。
- [ ] 增加 flags：`bridge_notification_outbox_v1`、`push_notifications_v1`、
  `notification_cursor_v1`、`connected_device_fgs_v1`、`native_background_connection_v1`。
- [ ] 记录现网基线：后台通知成功率、重复率、P50/P95/P99 时延、前台恢复耗时。
- [ ] 建立敏感字段日志红线和 threat model。

Gate：协议评审、安全评审和 Android/Play FGS 类型评审通过。

### Phase 1：Bridge outbox 与 cursor

- [ ] 实现 append/fsync/replay/compact/TTL/checksum。
- [ ] 在 authoritative streaming 边沿和 extension input 状态生成 event。
- [ ] 实现 publisher 单飞、退避、过期和显式错误分类。
- [ ] 实现 `notification_sync/notification_events/notification_ack/cursor_expired`。
- [ ] 增加 crash-at-every-write-boundary 故障注入测试。

Gate：随机 kill/restart 1,000 次无已 fsync 事件丢失；重复 publish 不产生不同 eventId；
cursor 分页零遗漏、零重复、tip 固定。

### Phase 2：Relay、引导票据与 FCM

- [ ] 建立独立 Relay 服务和最小数据库 schema。
- [ ] Rendezvous 签发单次 bootstrap ticket，并支持签名 key rotation。
- [ ] Android installation 注册、Bridge publisher credential 交换和撤销。
- [ ] FCM HTTP v1、token 失效、限流、TTL、priority 与 receipts。
- [ ] 本地测试用 fake FCM client；生产配置只从 secret manager 读取。

Gate：Relay 看不到明文事件；ticket 重放失败；错误 token 自动失效；service account 不进入
Bridge、Android 包、日志或仓库。

### Phase 3：Android 原生接收与通知

- [ ] 接入 Firebase Messaging，完成 Gradle/Manifest 配置。
- [ ] 实现 Keystore-backed notification key、AES-GCM envelope 校验。
- [ ] 实现原生去重、notification ID 映射和 receipt store。
- [ ] 高优先级回调内立即显示，不等待网络或 Flutter。
- [ ] WorkManager 上传 receipt 和刷新 token。
- [ ] Flutter 设置页呈现权限和诊断状态。

Gate：Flutter engine 未创建、Activity 已销毁、App 普通任务划掉、强制 Doze 四种情况下，
测试事件仍能在符合前提的设备上显示一次；notification denial 有明确 UI 状态且不滥发 high
priority。

### Phase 4：FGS 生命周期纠正

- [ ] 先实现可恢复的 Service 状态 owner 或明确 push-only 降级。
- [ ] 合规 Gate 通过后迁移 `connectedDevice` permission/type。
- [ ] 改为 `stopWithTask=false`，移除 task removed 主动停止，评估 `START_STICKY`。
- [ ] 添加 notification Stop action 和显式用户 opt-in。
- [ ] App/Service generation fence，旧回调不得覆盖新连接。
- [ ] 记录 Service create/start/destroy/taskRemoved/timeout/restart reason。

Gate：任务划掉后没有空服务；系统 kill 后 Service 要么恢复 owner，要么保持 push-only 并在
通知中准确显示；用户 Stop 后不自启。

### Phase 5：现有恢复缺陷

- [ ] 把 chunk-v2 retained/assembler 提升到 session/device owner，真实换 socket 后可 resume。
- [ ] Bridge 对未打开 DataChannel 的 PeerConnection 增加 establishment timeout。
- [ ] RPC progress 改为 requestId/transferId 级，排除无关消息和 ACK/NACK。
- [ ] `BridgeWatcher.start` 增加 connected/authenticated 回调，只有接管成功才抑制 Dart 通知。
- [ ] 网络变化对所有保持连接的设备触发恢复，不只 active device。

Gate：每个缺陷都有生产生命周期回归测试，并把实现临时换回缺陷版证明测试会失败。

### Phase 6：可选 native background connection

只有 Phase 1-5 的指标仍不能满足产品需求时启动：

- [ ] 定义 Kotlin/Dart 共享协议向量和版本协商。
- [ ] Kotlin Service 持有 signaling、PeerConnection、DataChannel、心跳和重连。
- [ ] Flutter UI 通过 Binder/MethodChannel 附着到现有 owner，不创建第二条竞争连接。
- [ ] 前后台 owner handoff 有 generation fence、原子状态迁移和超时回滚。
- [ ] 传输队列、认证、分片和完整性限制与 Bridge/Dart 完全一致。

Gate：在 MIUI/One UI/Pixel 的 8 小时锁屏测试中满足 SLO，且功耗和流量预算通过；否则
保持 FCM 按需重连架构，不上线 native owner。

## 12. 失败模式与预期行为

| 失败 | 预期行为 |
|---|---|
| Bridge 产生事件后立即崩溃 | outbox replay 后使用同一 eventId 重试 |
| Relay 离线 | Bridge 有界退避，事件保留，前台 cursor 仍可补齐 |
| FCM 接受但未送达 | 不删除业务事件；App 下次连接补齐并记录 missed-push 指标 |
| FCM 重复/乱序 | Android eventId 去重；sequence 只用于补偿排序 |
| FCM token 失效 | Relay 禁用 installation，App 下次启动重新注册 |
| notification key 轮换 | envelope 带 keyId；保留前一 key 到最大 TTL 结束 |
| 通知权限关闭 | 不发送 high priority；设置页显示阻塞原因；前台仍补齐 |
| App 普通任务划掉 | push receiver 仍可工作；持续连接取决于用户设置和 FGS owner |
| Active apps Stop/强制停止 | 明确不保证；下次用户启动后 cursor 补齐 |
| 事件风暴 | 非关键状态 collapse；任务和输入事件按限流队列保留 |
| Relay 被重放攻击 | 单次 ticket jti、publisher nonce/timestamp、eventId 幂等 |
| outbox 尾行损坏 | 忽略不完整尾行并告警，之前已校验记录继续 replay |

## 13. 安全与隐私

1. Firebase service account 只存在 Relay secret manager，最小 IAM 权限，定期轮换。
2. FCM token 视为凭据，在数据库加密，日志只显示不可逆短 hash。
3. pairing secret、hub token、随机 notification key 不发送给 Relay 或 FCM；notification
   key 不从用户输入的 pairing secret 直接派生。
4. 所有 Relay API 强制 TLS；publisher credential 有 device scope、速率限制和撤销能力。
5. envelope 使用 AES-GCM；nonce 不得复用；AAD 防止跨设备、跨事件类型替换。
6. Android 密钥由 Keystore 包装，备份策略明确禁止把密钥同步到其他设备。
7. Relay 限制单设备、单 installation 和单来源的 QPS/日配额，防止推送轰炸。
8. 通知正文遵循锁屏隐私设置；默认不包含用户输入、完整 agent 输出或路径。
9. 所有结构化日志默认不含 ciphertext、token、标题、正文和 pairing 信息。
10. 删除设备时撤销 installation、publisher credential 和未过期 routing 映射。

## 14. 可观测性

### 14.1 统一阶段

每个 eventId 记录以下 stage，不记录敏感正文：

```text
created -> persisted -> publish_attempted -> relay_accepted
        -> fcm_accepted -> android_received -> notification_displayed
        -> receipt_uploaded -> cursor_acked
```

### 14.2 Bridge 指标

- outbox pending/bytes/oldest_age/compaction_count/corrupt_tail_count
- publish attempts/result/status/latency
- event generation by type/source
- cursor gap/rebase/page latency

### 14.3 Relay 指标

- installations active/token refresh/token invalidation
- publish accepted/rejected/rate-limited
- FCM response code、original/delivered priority（可用时）
- receipt latency、missing receipt、per-device storm protection

### 14.4 Android 诊断

- FCM original/delivered priority
- receive/decrypt/dedupe/display result
- notification permission/channel enabled state
- Service lifecycle、owner generation、last reconnect reason
- last push、last receipt、last cursor、last catch-up count

诊断页应支持导出脱敏 JSON，方便真机问题定位，不依赖用户截取 logcat。

## 15. 测试矩阵

### 15.1 单元测试

- Bridge：outbox crash recovery、checksum、compaction、TTL、退避、幂等、cursor。
- Relay：ticket 单次消费、scope、token rotation、FCM 错误分类、限流、撤销。
- Android：envelope vectors、坏 tag/nonce/schema、过期、去重、通知 ID、token refresh。
- 跨端：TS 与 Kotlin 对同一 installation key provisioning/wrapping、AES-GCM envelope
  和 AAD 测试向量逐字节一致。

### 15.2 集成测试

- fake FCM client 驱动 Bridge -> Relay -> Android receiver fixture。
- Bridge 在 append、fsync、publish 前后各 kill 一次，验证 eventId 和最终状态。
- Relay 429/5xx/timeout/invalid token 注入。
- FCM 重复、乱序、延迟和 priority 降级模拟。
- Flutter 未启动时，原生 receiver 仍可显示通知。
- App 启动后 native receipts 与 Bridge cursor 合并。

### 15.3 Android ADB 场景

至少覆盖 Android 13、14、15、16：

```bash
adb shell dumpsys deviceidle force-idle
adb shell dumpsys deviceidle unforce
adb shell dumpsys battery reset
adb shell am set-inactive com.pipilot.pi_pilot true
adb shell am set-inactive com.pipilot.pi_pilot false
adb shell cmd activity stop-app com.pipilot.pi_pilot
```

另测：

- 前台、后台、锁屏 30min/2h/8h。
- Wi-Fi -> 蜂窝 -> Wi-Fi、VPN 开关、无网 10min 后恢复。
- 普通任务划掉、系统 low-memory kill、Active apps Stop、强制停止。
- 通知允许/拒绝/渠道关闭。
- FGS 6 小时 timeout 用缩短 device config 的方式测试旧 `dataSync` 行为。
- App 升级、设备重启、FCM token rotation、重新配对和删除设备。

### 15.4 真机矩阵

- Pixel：接近 AOSP 行为基线。
- Samsung One UI：后台限制和通知渠道。
- Xiaomi/Redmi MIUI 或 HyperOS：已知 wake lock/Dart 冻结重点对象。
- 至少一台低内存设备。
- 一台无 GMS 设备只验证明确降级，不把 FCM SLO 套用其上。

每个场景至少 100 个事件；发布候选阶段累计至少 1,000 个高优先级事件。

## 16. 发布、回滚与兼容

### 16.1 Rollout

1. Relay 和 Bridge outbox 先上线但不发 push，只做 shadow event/指标。
2. 内部安装启用 `push_notifications_v1`，保留旧 Dart/native watcher 路径。
3. 通过 event ownership 仲裁，确保同一 eventId 只有 push 或 watcher 一个 owner 显示。
4. 依次 5%、25%、50%、100% rollout，观察 7 天窗口。
5. P0 稳定后再独立 rollout FGS lifecycle；禁止同一版本同时切 push 和连接 owner。

### 16.2 回滚

- Relay 可按 installation/device/global 关闭 publish。
- Bridge flag 关闭后停止新 event 发布，但保留 outbox 和 cursor 读取。
- Android flag 关闭 push 显示时仍保存 token/receipt 兼容数据，不崩溃。
- 旧客户端忽略未知协议帧；Bridge 根据 capability 才发送 cursor 协议。
- schema 至少保留 N-1 解码；密钥轮换保留前一 key 到最大事件 TTL。
- 回滚不得删除 outbox；重新启用后继续同一 eventId，避免重复生成。

## 17. 验收标准

### 17.1 P0 通知链路

- [ ] Bridge 事件 append/fsync 后 crash，重启可恢复且 eventId 不变。
- [ ] Flutter engine 未启动时，原生 FCM receiver 能显示一次通知。
- [ ] 1,000 次重复/乱序注入没有重复可见通知。
- [ ] FCM 全丢时，App 下次连接能从 cursor 100% 补齐 retained 事件。
- [ ] Relay/FCM 看不到通知明文、pairing secret 或 hub token。
- [ ] 真机样本达到 99%/60s、P95 10s 的推送 SLO，未达标可定位阶段。

### 17.2 FGS

- [ ] 业务和 Play 审核确认 `connectedDevice` 合规后才启用。
- [ ] 任务划掉后不存在无连接 owner 的空 FGS。
- [ ] Service 被系统 kill 后能恢复 owner 或准确降级为 push-only。
- [ ] 用户 Stop/显式断开后不会自动重启。
- [ ] 常驻通知始终准确反映连接状态并提供停止操作。

### 17.3 稳定性

- [ ] 8 小时锁屏测试无 silent stuck；所有断线有 reason 和恢复记录。
- [ ] 网络切换后 15 秒内恢复或显示明确失败。
- [ ] 部分 chunk-v2 传输换真实 socket 后从已确认页恢复。
- [ ] 未打开 DataChannel 的 PeerConnection 在超时后释放。
- [ ] 无关事件不能延长卡死 RPC 的 request-level timeout。

### 17.4 工程质量

- [ ] Bridge、Relay、Rendezvous typecheck/test 全绿。
- [ ] Flutter analyze/test 全绿。
- [ ] Android unit/instrumentation test 全绿。
- [ ] 所有安全测试向量有 TS/Kotlin 跨端一致性证明。
- [ ] 文档、feature flags、迁移、回滚和运维 runbook 同步完成。

## 18. 验证命令

实现阶段至少执行：

```bash
cd bridge && npm run typecheck && npm test
cd rendezvous && npm run typecheck && npm test
cd notification-relay && npm run typecheck && npm test
flutter analyze
flutter test
./android/gradlew -p android app:testDebugUnitTest
```

文档分支本身执行：

```bash
git diff --check
git status --short --branch
find . -type d -printf '%f\n' | grep -i p2p
```

最后一条在新增工作树名和计划目录名范围内必须无输出；仓库既有历史目录不在本约束范围。

## 19. 关键决策与待确认项

实施前必须明确：

1. 生产是否允许依赖 Google Play Services；无 GMS 是否需要 UnifiedPush 等适配器。
2. Notification Relay 的部署、数据库、域名、TLS、备份和 on-call 归属。
3. 推送正文可显示的隐私级别：通用提示、会话名、还是加密后的任务摘要。
4. 多个 Android installation 的默认 fan-out、撤销和 owner 语义。
5. `connectedDevice` FGS 的 Play 合规结论及审核材料。
6. P0 指标能否满足体验；只有不能满足时才批准 native WebRTC owner 的成本。

默认决策：先实施 Bridge outbox、Relay、FCM 原生通知和 cursor 补偿；保持前台 P2P；
暂不承诺后台持续 WebRTC，也不申请电池优化豁免。该路径能以最小平台对抗换取最高的通知
可靠性，并为后续持续连接保留可测量的决策依据。
