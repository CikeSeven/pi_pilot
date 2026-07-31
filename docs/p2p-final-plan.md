# PiPilot P2P 稳定性与可用性最终实施方案（合并终版 v3）

> **实施状态（本会话已落地，双端测试全绿）**
> - ✅ **阶段 0 全部完成**：close code 透传（远端 1006/本地语义码）、发送队列毒化修复、`get_entries since` 正向翻页（+tipId/nextSinceId/limitBytes）、P2P 首载 96KB+UTF-8 字节预算、进度型超时（45s 无进展）+失败重试+晚到日志、真 ping/pong（双向）、catalog await 化+重试、hub_sync 计时日志
> - ✅ **阶段 1 全部完成**：`p2p_transport.ts` 三级分类+CreditController 自适应信用、DataChannelSocket 三级队列重写（双端）、Q1 准入控制（busy 拒答）、close(1013) 废除（P2P）、ICE 模式缓存（direct/relay 优选）、clientId 全链接线（settings→query/auth）、collectSessions 全目录扫描、sessionPhase 增量字段+迁移点。未做：ICE restart（实验位，需双端集成测试证明）
> - ✅ **阶段 2 全部完成**(本会话第二轮):SyncStore(sqflite,sourceKey=sessionId 与 hubId 解耦)+事务化提交(N4 修复)+快照/entry 持久化+首屏缓存渲染、cursor v2+entryId rebase、op_log(at-most-once+显式 unknown)、**msg-delta 接通**(双端实现原有已齐,补上 P2P 能力声明接线:RtcHubChannel.transportCapabilities 加 msg-delta)
> - ✅ **阶段 3 大部分完成**(本会话第三轮):
>   - ✅ **chunk-v2 二进制帧**:`p2p_frame_v2.dart/.ts` 逐字节镜像(30B 头:魔数/版本/类型/transferId/页索引/页数/meta 长度),`protocol/p2p_frame_v2_vectors.json` 双端共享向量(6 组,encode/decode 双向校验,生成脚本 `bridge/scripts/gen_frame_v2_vectors.ts`)
>   - ✅ **v2 传输层**:分页(36KB)+**gzip**(>16KB 且划算才压,JSON 实测线体积 <1/5)+发送方留存(60s/32MB,供 NACK 重发)+接收方重组(TTL/上限防膨胀)+**断线续传**(重连后接收方发 NACK{resume:true},发送方补 BEGIN+缺失页+DONE;BEGIN 保留已收页——测试抓出并修复了续传永不能完成的协议 bug)。双端镜像 `p2p_transfer_v2.dart/.ts`
>   - ✅ **v2 运行时挂接**:capability `p2p-chunk-v2` 门控(auth 声明+hello 通告),DataChannelSocket/RtcHubChannel 双端接入,retained/assembler host/connector 级持有跨 socket 存活,v1 路径原样保留作回退。socket 级集成测试:二进制分页端到端送达+ACK 释放留存+NACK 重发+未知 transfer 回 ABORT
>   - ❌ **ICE restart:否决(有证据)**。集成测试证明:werift 处理活链路上的重 offer(ICE 重启重协商)时,srd→answer→sld 全程正常,但 answer 发出后 ICE 代理进入重启周期**整个进程 CPU 自旋冻死**(30s 硬超时都无法触发)。裸 pc 对对照实验能完成,但 P2pHost 拓扑下不可复现地冻结——保留同 pc 重协商 handler 等于给远端一个冻结 bridge 的开关。结论:**handler 已回滚**(重 offer 维持"关旧 peer 换新"的安全降级),Flutter 端不接发起,重启一律降级为全量重连。证据见 p2p_host.ts offer 处理注释
>   - ⬜ 双 DataChannel:不实施。chunk-v2 的三级队列+信用制+二进制分页已解决 HOL 阻塞根因,双通道的增量收益不值得两套协商复杂度
> - ✅ **拆分评估**(不实施大拆,理由与替代):pi_session.dart 4155 行、server.ts 2728 行。经过三阶段改造,两者的热点路径(发送队列/信用/重组/游标/op_log/续传)都已抽成独立模块(p2p_transport、p2p_frame_v2、p2p_transfer_v2、sync_store、source_cursor),剩余体量是状态字段+事件 switch 的固有复杂度,强拆只会制造跨文件跳转成本。**替代**:新功能一律进独立模块,god object 只留编排
> - 测试:bridge **71/71**(p2p_transport 5、frame_v2 3、transfer_v2 6、socket v2 集成 2、since 正向翻页 1、原有 51+3),Flutter **300/300**(sync_store 5、settings ICE 缓存 3、frame_v2 3、transfer_v2 6、原有 283)

> 本文档是三轮双模型工作 + 一轮架构评审修正的最终合并：
> - 第一轮审查：sol（`sisct2/gpt-5.6-sol:xhigh`）、k3（`kimi-coding/k3:max`），汇总 `docs/p2p-review-synthesis.md`
> - 第二轮方案：k3 完整方案（`.pi-subagents/artifacts/progress/d8deb558/plan_final.md`）
> - 第三轮方案：sol 完整方案（resume 成功，逐行核实双端+extension，新增 5 项事实）
> - v3 修正：架构评审发现的 9 处矛盾已修订（见文末第七节）
> - 全程只读分析，未修改任何生产代码

## 〇、第三轮新发现（sol 逐行核实，超出此前所有审查）

| # | 新事实 | 影响 | 位置 |
|---|---|---|---|
| N1 | `get_entries since` 正向增量被 `clipEntriesForMobile` 按**尾部**裁剪（`bridge/src/server.ts:989-996`），前方增量被吞且 App 无感知 | **静默丢消息**，必须改正向翻页 | 模块 4、阶段 0 |
| N2 | `prompt/abort` 无请求 ID、fire-and-forget（`pi_session.dart:933-943`）；relay 去重缓存仅内存且换 epoch 清空（`relay.ts:591,1316`） | 写命令幂等只能靠 opId 持久化 | 模块 7、阶段 2 |
| N3 | `DataChannelSocket` close 时把 1000/1011/1001 全部重写成 1000（`p2p_host.ts:189-197,323-334`） | 观测性前提，**必须先修** | 模块 8、阶段 0 |
| N4 | 游标已有 v1 持久化（`pi_session.dart:2119-2173`），缺**数据实体**持久化；且 gap 分支在应用事件**之前**推进 `lastSourceSeq`（`:2669-2682`），进程被杀则游标超前于缓存 | 需事务化提交+实体落盘 | 模块 5、阶段 2 |
| N5 | `devices_page` 只列在线源是产品决策；但 `collectSessions()`（`server.ts:542-544`）与 `listSessions` 单目录匹配（`sessions.ts:126-142`）覆盖不足是真缺陷 | 列表不全的非传输根因 | 阶段 1 |

## 一、验收目标

| # | 目标 | 核心机制 |
|---|---|---|
| 1 | 慢 TURN（50KB/s、RTT 300ms、丢包）下 ≤10s 会话列表可用 | ICE 模式缓存+竞速；catalog 走 Q1；自适应在飞窗口保证 Q1 延迟 |
| 2 | 首屏消息 ≤15s 可见 | headPage 96KB（~2.6s 线耗）+ 本地缓存先渲染再对账 |
| 3 | 10MB+ 历史最终完整同步，期间交互不卡、心跳不断 | 三态分页（tip-token 一致性）+ QoS + 自适应信用流控；since 正向翻页零丢失 |
| 4 | 断网/切网/bridge 重启 ≤30s 恢复，不丢、不重、从游标续传 | clientId + 两级游标（seq + entryId rebase）+ ICE restart（实验位）+ v4 续传 |
| 5 | 写命令 **at-most-once + 显式 unknown**（不承诺 exactly-once） | opId WAL + 恢复时状态对账；对账不明一律"结果未知"提示用户，**禁止自动重放** |
| 6 | 杜绝 close(1011/1013) 死循环；任何失败可诊断 | 水位/信用停泵不杀链；close code 透传；双端日志+计数器 |

设计前提：DataChannel reliable/ordered，通道存活期间不丢片不乱序；"丢数据"来自通道死亡、超时互斥、N1/N2/N4 应用层缺陷。**另注意：单条 SCTP 关联内，任何入站缓冲都是全序的——Q0/Q1 的延迟上界由"已压入 SCTP 缓冲的 bulk 字节数"决定，队列分级只能决定"谁先进入缓冲"，不能绕过已在缓冲中的数据**（v3 修正核心，见模块 2）。

## 二、链路总览

```
手机 Flutter                                                   电脑
┌────────────────────────────────────────────────────────────┐
│ UI: phase=offline/transport/catalog/selected/synced/degraded│
│ ConnectionLifecycle(拆出): 状态机+分类/进度型超时+兜底重试     │
│ SyncStore(sqflite): 事件+游标+缓存原子提交(键与 hubId 解耦)   │
│ op_log WAL: 写命令发送前落盘, 恢复时对账不盲重放               │
│ TransportHub(新): Q0 控制 / Q1 交互(≤8KB,准入控制busy拒答)    │
│   / Q2 批量(同key合并) + 自适应信用: in-flight bulk ≤ drain×0.4s│
│ RtcHubChannel: v1 文本分片 ↔ v4 二进制帧(协商)                │
└──────────────┬─────────────────────────────────────────────┘
   信令 wss rendezvous │ 媒体 DataChannel SCTP/DTLS（阶段3可拆 control+bulk 双通道）
┌──────────────┴─────────────────────────────────────────────┐
│ bridge: P2pHost → DataChannelSocket(close code 透传) →       │
│   TransportHub(对称) → server.ts(分页/tip-token/降级) →      │
│   SourceRegistry(快照+replay环+delta) ｜ extension: delta双轨+opId幂等│
└────────────────────────────────────────────────────────────┘
```

## 三、分模块设计

### 1. 信令与打洞
- **模式缓存+竞速**：`p2p.lastGoodTransport={mode, networkKey, savedAt, failCount}`（networkKey=deviceId+网络类型，不取 SSID）。冷启动 direct(5s)→relay(20s)；缓存命中 relay 时 direct 3s 与 relay 并行竞速，先到者胜；连败 2-3 次作废。
- **ICE restart（实验位）**：`iceState=disconnected` 5s → 原信令会话 `iceRestart:true` 重协商，15s 未 open 回退全量重连。**前提：flutter_webrtc/werift 双端 same-PC restart 集成测试通过**（重复 offer 重建 peer 的现有逻辑不等于真 ICE restart），测试未过则该位默认关闭，仅保留全量重连路径。
- **TURN 凭据**：默认 600s 不变；部署验证后建议调 1800s（可配置，**不写死 3600**）；bridge 提前 `min(剩余/4,60s)` 刷新（已有）；`ok` 帧加 `turnCredentialExpiresAt`。

### 2. 传输层（v3 修正：信用制 + 准入控制）
- **三级队列（新模块 `p2p_transport.{ts,dart}`，双端对称）**：Q0 control（ping/ack/ctl，≤2KB）；Q1 interactive（response ≤8KB + 小广播）；Q2 bulk（分片/大响应/流式事件）。分类在编码前按 type+大小判定，大响应永远不进 Q1。
- **自适应在飞信用（替代固定水位作为主要机制）**：`creditTarget = clamp(drainRateEMA × 0.4s, 1 片, 2MB 硬顶)`。发送循环维持"已压入 SCTP 缓冲的 bulk ≤ creditTarget"；drainRateEMA 由 bufferedAmount 下降速率实测。效果：快链路（10MB/s）信用顶到 2MB 保持流水线；慢链路（50KB/s）信用收缩到 ~20KB，**Q0/Q1 到达时前方最多 ~0.4s+1 片的 bulk**，交互 SLA 成立。`bufferedAmount` 2MB/256KB 水位降级为**安全天花板**（防实现误差），不再是常规批控目标。
- **Q1 准入控制（禁止丢响应）**：可丢弃/可合并的**只有**可替代通知（重复 `hub_sessions_changed`、同 key message_update）。RPC 侧：Q1 排队字节超阈值时，bridge 在**执行前**即回 `{error:'busy', retryAfterMs}`（走 Q0 小帧），客户端按 retryAfter+jitter 重试；响应帧本身始终允许入队（≤8KB 有界），响应容量预留，绝不静默拒——杜绝"超时-重发-更堵"的回旋镖。
- **废除 close(1011/1013)**：drain 超时与积压上限都不再杀链；唯一主动 close 是协议违例(1002)/鉴权(4001)/长时间无进度（连续 120s 无任何字节推进，此时链路事实上已死）。
- **v1 期**：重组器 idle 回收记日志 + Q0 `transfer_drop{msgId,received,total}`，由 RPC 层超时重试驱动重发。idle TTL 合入未提交修复（每片刷新）保持 30s + 护栏（8 并发/32MB/16MB）；**idle-drop 计数显著再调 120s**。
- **v4 期（阶段 3）**：32B 二进制帧头（transferId/offset/total/crc32c）免 base64；页级 `transfer_ack/nack(have ranges)` + `transfer_resume_offer/have` 跨连接续传；gzip 仅 Q2 ≥64KB JSON；**双 DataChannel（control+bulk 物理隔离）作为 Q0 延迟的终态答案在阶段 3 落地**，需 per-message 因果标记（seq）解决跨通道乱序。
- **发送队列毒化修复**：`_sendQueue` 错误恢复 + 通道死立即失败（`p2p_connector.dart:112-138`）。

### 3. 连接生命周期状态机
`PiConnStatus`（传输）与 `sessionPhase`（业务）分离：`offline→transport→authenticated→catalogReady→selected→syncing→synced`，失败态 `degraded`（可交互+横幅）。迁移逻辑拆入 `lib/state/connection_lifecycle.dart`。各态失败：transport 退避+切网立即重试；auth 失败终态；catalog 重试 3 次→degraded 显示缓存列表（`hub_list_sessions` 改 await 化，修 `:1358/:1031`）；selected/syncing 失败走 `_scheduleSourceResync`（修 `:2203`）。UI 五处 `status==connected` 判断改按 phase（`settings_widgets.dart:234/282/306`、`devices_page.dart:78/103`、`island_bar.dart:74/493`、`notification_controller.dart:147-170`）。

### 4. 同步协议（v3 修正：tip-token 一致性 + 缓存身份解耦）
- **三态分页**：`hub_sync` 响应 headPage ≤96KB（含 `oldestId/hasMoreOlder/branchTipEntryId/tipSeq`）→ 正向增量（seq 窗口+`hasMoreEvents`）+ 反向历史（`get_entries before` 扩 `limitBytes=256KB`，标 `clipped`）。
- **N1 修复+快照一致性**：`get_entries since` 改**从头正向翻页**，且每次翻页 run 绑定**源端 tip token**：`get_entries{since, tipToken}`——服务端在 run 开始时固定 tip（entryId+seq），所有页以该 tip 为界返回 `{nextSinceId, hasMore, tipToken}`；run 结束后客户端按 `tipSeq` 之后的实时事件对账（去重/补洞），**杜绝翻页过程中源变动导致的漏/重**。未协商 `hub-sync-pages` 保持旧行为。
- **预算按 UTF-8 字节**：`server.ts:930` 改 `Buffer.byteLength`。
- **两级游标（cursor v2）**：`{v:2, sourceKey, hubId, sourceEpoch, seq, sessionId, leafId, branchTipEntryId, lastEntryId, savedAt}`。在线用 epoch/seq；跨 bridge 重启（hubId 必变）用 `branchTipEntryId` rebase：命中→since 正向补增量；未命中→回 headPage+本地缓存拼历史。
- **缓存身份与 hubId 解耦（v3 修正 v2 自相矛盾）**：本地 sources/sessions/entries/cursor 一律以 **`sourceKey = deviceId + sourceId`（不含 hubId）** 为主键；hubId 变化时**标 stale 而非删除**，rebase 成功即刷新 hubId/epoch 继续用，**只有 rebase 失败才清**。另设阶段 2 验证任务：确认 entryId 在 compact/fork/relay 重建后的稳定性（不稳定则 rebase 降级为"分页快照+缓存去重合并"）。
- **clientId 接线**：`conn.clientId=app-{16hex}` 持久化；`pi_session.dart:1908` 传入；WS 路径拼 query；bridge 已有 4010 旧连接替换。
- **msg-delta（v3 修正：禁用时间戳拼 key）**：使用**源端生成的稳定 messageId**（relay/pi 侧消息自带 id；若无则在 relay 首次见到时分配并随事件持久传播），携带 `baseRev`+内容 hash 校验；校验失败/key 首见/结构变更/compact → 回退全量 `message_update`；Q2 同 messageId 入队合并；pending 2s 未等到 full 则 reconcile。

### 5. 手机端本地持久化（sqflite）
`lib/core/sync_store.dart`：表 `meta/sources/sessions/entries(idx seq)/cursors/op_log/diagnostics`，主键用 sourceKey（模块 4）。**事务规则（修 N4）**：应用 sequenced event = 单事务 {upsert entries → update cursor → upsert sessions}，游标永不先于数据落盘。启动：catalogReady 前读缓存渲染，首屏读最近 200 条。失效：**hubId 变化只标 stale**；epoch 变或 rebase 失败才清 entries/cursor；entries 每 source 20MB 从最旧删（不删 leafId 之后分支）；op_log 7 天/1000 条；diagnostics 2000 行 ring；失败降级纯内存。

### 6. 活性检测
删假 pong（`p2p_host.ts:310-313`）→ Q0 真发 `bridge_ping`，Flutter 对称回 pong。分档（RTT 中位数+滞回）：direct 5s×2；relay 10s×3；阈值 ≥3×RTT。RTT EMA 供超时缩放与信用计算。`iceState=disconnected` 5s 联动提前 ICE restart（实验位）/全量重连。

### 7. 重连与续传（v3 修正：at-most-once 语义）
退避 `min(30s,2^n)×jitter` + 网络变化重置；host_offline 5s 起步。**30s SLA 分解**：信令 ≤3s → open ≤5s → auth ≤2s → `hub_sync(cursor v2)`：hubId 同→replay 增量 ~10s；hubId 变→entryId rebase。in-flight：通道死 `_pending` 以可重试错误完成；幂等读自动重发；稳定请求 ID `clientId-op-{n}` 持久化 n，重发同 ID，bridge/relay 按 ID 去重。**写命令**：发送前写 `op_log(pending, payload_hash)`，恢复后 `hub_op_status{opId}` 对账：accepted/executed→完成；unknown→**UI"结果未知"，禁止自动重放**。**明确语义边界：`appendEntry` 记录与 prompt 执行不是原子操作，崩溃窗口内只能保证 at-most-once + 显式 unknown，不承诺 exactly-once**；若未来 extension 执行点与幂等记录可事务化，再升级为 exactly-once。headless 走 bridge 侧车 `data/op-log.json`（0600，10k ring）；desktop 用 `ctx.appendEntry('pipilot-op',…)`（`types.d.ts:916`）+ relay 重启扫描重建去重表。

### 8. 观测性
**第 0 步先修 close code 透传**（N3）。bridge：peer_open/close(code+reason+queuedBytes)、queue_depth 分类、transfer 耗时、chunk_idle_drop、hub_sync 耗时与裁剪量、get_entries 方向/页字节/tipToken、replay_fallback 原因、ping_rtt、halfopen、ice 结果、creditTarget/drainEMA 采样。Flutter：conn_phase、rpc_timeout/retry、late_response 计数（`:2925` 不再静默）、sync{cursorHit}、cursor_rebase 命中、send_fail、queue_poison_recovered、busy 拒答计数。指标两端对齐：close code 分布、页耗时 p50/p95、Q1/Q2 深度峰值、超时计数(按 type)、resync(按 reason)、RTT EMA、rebase 命中率、op unknown 率、idle-drop 计数、**Q1 延迟 p95（信用制效果验证）**。测试钩子：`debugStats()` + 假 DataChannel 限速/丢包注入。

### 9. 兼容与发布（v3 修正：版本不动、能力依赖表）
- **`HUB_PROTOCOL_VERSION` 保持 3**：分页/QoS/delta/opId 全部 capability 门控，旧端不感知；仅当未来引入不可回避的不兼容基线（如移除 v1 文本帧）才升 4。bridge 先发布不会打破旧 App。
- **能力依赖（替代"任意 2^n 组合"）**：`msg-delta` ⊂ `hub-sync-pages`；`p2p-compress-gzip` ⊂ `p2p-chunk-v2`；`op-idempotent` 独立；测试矩阵只覆盖**依赖闭包内的合法组合**。
- 双端常量：`protocol/p2p_constants.json` 生成 TS/Dart + `protocol/test_vectors/*.json` 进 CI。
- 回滚单位=单能力位（`PIPILOT_P2P_V4=off`、`PIPILOT_SYNC_PAGES=off`、App 隐藏开关）。发布顺序：bridge → extension → App；rendezvous 独立。

## 四、分阶段路线与验收（v3 重排：被证实的阻塞点全部前置）

| 阶段 | 周期 | 内容 | 验收（可量化） |
|---|---|---|---|
| **0 止血（全是已证实阻塞点）** | 0.5-2d | 合入 idle TTL 修复；**close code 透传**；**发送队列毒化修复**；**since 正向翻页（含 tip-token）**；P2P 首载 96KB+UTF-8 字节预算；**进度型超时**（有进展重置，无进展 45s）+2203 重试+2925 日志；**真 ping/pong**；catalog await 化+重试 | 50KB/s 夹具首载 ≤6s；分片 >30s 仍重组成功；传输中 ping RTT 劣化 <20%；since 翻页 300 条零丢失；双端测试全绿 |
| **1 传输与状态机** | 1-1.5w | TransportHub 三级队列+**自适应信用**+Q1 准入(busy 拒答)；删 1013；sessionPhase/ConnectionLifecycle；模式缓存+竞速；ICE restart（实验位+集成测试）；clientId；collectSessions/listSessions 修复 | 50KB/s/300ms/2% 丢包：catalogReady ≤6s、首屏 ≤10s；批量传输中 Q1 延迟 p95 <2s（含 hub_list_sessions）；断网 20s replay 恢复 ≤10s；零 1011/1013；零静默丢响应（busy 全有日志） |
| **2 持久化与增量** | 1-2w | sqflite SyncStore（sourceKey 主键+事务化游标）；cursor v2+entryId rebase+**entryId 稳定性验证**；msg-delta（规范 messageId+baseRev 校验）；op_log+hub_op_status（at-most-once）；切网立即重连 | 10MB 历史最终完整（id 集合一致）且首屏 ≤10s；流式线体积降 ≥70%；断线发 prompt 恢复后 **opId 至多出现一次**，对账不明一律 unknown 提示；杀进程重启缓存首屏 <500ms 且游标不超前 |
| **3 v4 与架构收敛** | 2-4w | chunk-v2 二进制+页级 ACK/NACK+transfer 续传；gzip；常量共享+测试向量 CI；**control+bulk 双 DataChannel**（因果标记）；拆 server.ts/PiSessionNotifier（<1200 行） | 同 256KB 页 v4 耗时 ≤v1 的 70%；90% 断链续传跳过 ≥95% 已收字节；CI 向量全绿；双通道下 bulk 洪水中 Q0 延迟 <100ms |

## 五、关键参数表

| 参数 | 定值 | 依据 |
|---|---|---|
| 首屏 headPage / 回填页 | 96KB / 256KB | 2.6s 线耗与页数开销折中 |
| Q1 帧上限 / 准入 | 8KB；Q1 排队 >2MB 时请求执行前回 busy+retryAfterMs | 响应永不丢；拒在执行前 |
| 在飞信用 | `clamp(drainEMA×0.4s, 1 片, 2MB)`；安全水位 2MB/256KB | Q0/Q1 延迟 ≤~0.5s+1 片；快链路保持流水线 |
| 杀链判据 | 仅连续 120s 无字节推进 / 协议违例 / 鉴权 | 慢链路合法大消息可持续数分钟 |
| 重组 idle TTL | 30s（每片刷新）+护栏；idle-drop 计数驱动再调 | 观测驱动调参 |
| RPC 超时 | 控制 15s；交互 30s；同步/分页=进度型（无进展 45s）；compact 300s | 进度型根除 H1 |
| 心跳 | direct 5s×2；relay 10s×3；≥3×RTT | 高 RTT 不误杀 |
| direct/relay | 冷 5s→20s；relay 缓存命中 3s 竞速 | 省 7s 空等 |
| TURN TTL | 默认 600s；验证后 1800s（可配置） | 安全审查前不写死更高 |
| ICE restart | disconnected 5s 触发；15s 未 open 全量重连；**实验位** | 双端兼容性需集成测试证明 |
| 本地缓存 | sqflite；entries 20MB/source；op_log 7 天/1000 条 | N4 需事务化提交 |
| delta/gzip 阈值 | 32KB / 64KB | 小消息不压 |

## 六、风险与缓解（Top 9）

| 风险 | 缓解 |
|---|---|
| 信用制 drain 测量失真（werift/flutter_webrtc bufferedAmount 精度） | 阶段 0 实测曲线；失真则用"已发未 ack 字节"自记账；水位硬顶兜底 |
| entryId 在 compact/fork/relay 重建后不稳定 | 阶段 2 验证任务；不稳定则 rebase 降级为"分页快照+缓存去重合并" |
| appendEntry 与执行非原子 | 只承诺 at-most-once+unknown；崩溃窗口由用户确认兜底 |
| ICE restart 双端不兼容 | 实验位默认关；集成测试不过则只用全量重连 |
| delta 合并错序/丢片段 | seq 定序兜底；baseRev+hash 校验；pending reconcile；v3 客户端回滚全量 |
| since 正向翻页影响旧客户端 | 能力位门控，未协商保持旧行为；双路径集成断言 |
| 二进制帧新缺陷 | 阶段 1/2 不依赖；能力位整体可关；测试向量双端一致 |
| sqflite 启动成本/迁移 | 只读小表启动；版本迁移器；失败降级纯内存 |
| 状态机/god object 重构回归 | sessionPhase 增量先行；拆分放阶段 3；行为测试先就位 |

## 七、v3 修正记录（架构评审 9 条 → 落点）

| # | 评审指出的矛盾 | 修正 |
|---|---|---|
| 1 | 单通道 Q0 无法绕过 SCTP 缓冲积压（2MB@50KB/s≈40s），"绕过背压"不成立 | 改**自适应在飞信用**（drain×0.4s，2MB 硬顶），Q0/Q1 延迟上界 ~0.5s+1 片；双通道物理隔离作为阶段 3 终态 |
| 2 | Q1 满时丢 RPC 响应会制造超时回旋镖 | **响应永不丢**；执行前 busy+retryAfterMs 拒答+响应容量预留 |
| 3 | 缓存按 hubId 清除与跨重启 entryId rebase 自相矛盾 | 缓存主键改 sourceKey 与 hubId 解耦；hubId 变只标 stale，rebase 失败才清 |
| 4 | nextSinceId 翻页在源变动时会漏/重 | 翻页 run 绑定 tip-token，结束按 tipSeq 对账 |
| 5 | exactly-once 承诺过头 | 语义改为 **at-most-once + 显式 unknown**；验收同步修改 |
| 6 | 时间戳拼 messageKey 不安全 | 改源端稳定 messageId + baseRev/hash 校验 + 全量回退 |
| 7 | 全局升 v4 会打破"bridge 先发"兼容性 | **版本保持 3**，全特性能力门控；能力依赖表替代 2^n 组合 |
| 8 | ICE restart/TURN 3600 缺验证 | ICE restart 列实验位（集成测试+全量回退）；TURN 默认 600、验证后 1800 可配置 |
| 9 | 阶段顺序 | 被证实的阻塞点（close code/毒化/since/小页/进度型超时/真 ping/catalog）全部提到阶段 0；QoS/SQLite/delta/opId/二进制依次随后 |
