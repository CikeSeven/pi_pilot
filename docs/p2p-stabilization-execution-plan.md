# PiPilot P2P 稳定化执行计划（权威版）

日期：2026-07-30
状态：进行中
依据：`.pi-subagents/artifacts/p2p-audit-summary-2026-07-30.md`（运行时验证过的审计）+ 当前未提交工作树逐行核实

## 与既有文档的关系

`docs/p2p-final-plan.md` 是设计方案，它标注的"阶段 0-3 已完成、双端测试全绿"只代表**单元测试和本机 loopback 通过**，不代表对应能力在真实慢链路和真实重连下成立。审计已用代码证据和可复现探针推翻其中三项完成声明：

| p2p-final-plan.md 的声明 | 实际状态 | 证据 |
|---|---|---|
| chunk-v2 断线续传已完成 | 跨真实重连不成立 | `lib/state/pi_session.dart:2024` 每次 `_open()` 新建 `P2pConnector`，assembler/retained 随之丢弃；bridge 侧从未在新 socket 上调用 `pendingResumes()` |
| 三级队列 + 自适应信用已完成 | 记账与估速有确定缺陷 | `bulkQueuedBytes` 只减不加；`CreditController.sample` 平坦采样重置计时基线 |
| 进度型超时已完成 | 可被无关心跳永久续命 | `_withProgressTimeout` 只看全连接 `lastActivityAt`，而 `bridge_pong` 也会刷新它 |

本文件是执行与验收的权威来源。`p2p-final-plan.md` 保留为设计背景，不再作为完成度依据。

## 验收总目标

固定成 CI/演练验收线，而不是"能传完"：

1. 20MB / 5,000 entries 会话，在 50KB/s、RTT 300ms、2% loss 下最新尾页 3 秒内可见。
2. 5,000 个 entry ID 经游标分页恰好到达一次，无遗漏无重复。
3. P2P `hub_sync` 完整逻辑响应 ≤128KiB，history page ≤96KiB，event page ≤64KiB，v2 DATA 单页 ≤36KiB，全部按 UTF-8 线上字节校验。
4. 切网/断线只重试当前页或当前 transfer，已确认页不重传；游标不匹配返回明确 rebase，不静默清空。
5. bridge 不做完整历史唯一持有者；App 活跃窗口和 SQLite 字节均在预算内。
6. 健康慢链路不得被心跳误杀；零 1011/1013 死循环。

## 阶段划分与 release gate

### P0-A 传输正确性三项（已完成）

彼此独立、互不依赖。每项都做了"把实现换回缺陷版"的对照实验，确认测试真的能抓住问题。

1. **host 信令 per-peer 串行化**。`bridge/src/p2p_host.ts:650` 原本用 `void this.onSignal(...)` 并发派发；offer 分支先 `createPeer` 注册 peer，之后才 `await pc.setRemoteDescription`。该窗口内到达的 candidate 直接 `addIceCandidate`，绕过 `pendingCandidatesByPeer` 缓冲。

   已改为每 peerId 一条 Promise 链（`enqueueSignal`），单条信号抛错在链内收口不毒化后续，`stop()` 清理链状态。另加"remote description 未就位则缓冲"守卫与诊断计数 `candidatesAwaitingRemoteDescription`。

   **探针结论（重要）**：werift 在 remote description 未就位时 `addIceCandidate` 会**静默 resolve**，候选被无声丢弃且不报错。本机 loopback 能靠 peer-reflexive 候选救回（耗时从 557ms 涨到 2016ms），但真实网络上若只有单个 relay 候选，丢了就是建链失败——这正是"同一网络时成时败"的一个具体机制。因为不报错，测试不能断言异常，必须断言计数器为 0。

2. **CreditController 平坦采样修复（TS + Dart 镜像）**。原 `sample()` 在 `drained <= 0` 时仍更新计时基线，导致随后一次整片下降被除以约 20ms，把 50KB/s 误判成 MB/s 级。现改为测速窗口锚定在"上一次真实排空"，停滞超过 1s 则将估计值对折（不跌破 4KB/s 下限），缓冲变大不算负排空。初值也从 1MB/s 降到 128KB/s：首屏那几片是在完全没有测量数据时发出的，乐观初值会在慢 TURN 上一次压入 400KB（约 8s 队列）。

3. **Dart 发送队列/信用/泵抽成可测模块**。`RtcHubChannel` 构造依赖真实 `RTCPeerConnection`（30+ 抽象成员）与私有构造的 `GuestSignaling`，无法在单测里 fake。新增 `lib/core/p2p_send_pump.dart`（`P2pCreditController` + `P2pSendPump`，依赖注入），与 bridge 的 `p2p_transport.ts` 互为镜像，使纯时序逻辑能脱离原生层验证。

   **诚实修正**：先前把"泵尾部丢唤醒"列为确认缺陷，但对照实验表明我构造不出可复现的失败——`_drain` 每帧之间的 `await Future.delayed(Duration.zero)` 是 timer 任务，队列重检必然排在任何微任务 `add()` 之后，实际上已关上了窗口。保留 `finally` 重检是防御性加固与双端对称，**不应宣传为已证实的挂死修复**。真正被对照实验确认的缺陷是信用估速。

Gate（已达成）：bridge typecheck 干净，**75/75** 通过（原 71 + 新增 4）；`flutter analyze` 无 issue；`flutter test` **308/308** 通过（原 300 + 新增 8）；rendezvous 6/6；extension 40/40。

### P0-B 有界队列与失败传播

- bulk 入队补记账，但**必须按完整逻辑消息/transfer 原子预留**：容量不足时整条拒绝并回 ABORT/busy，禁止逐帧丢弃留下半条 transfer（丢 DONE 会让接收方连 NACK 都不发）。
- Flutter `_controlFrames/_normalFrames` 增加分类字节上限与总上限。
- `server.ts` 的 `respond` 必须处理 `sendRaw` 返回 false，不能静默丢弃已生成的响应。
- NACK 去重、限频、限页数，且不得绕过总积压检查。
- 心跳策略分档：`server.ts:2607` 附近实际只给一次 ping 约 10 秒，注释所称"连丢两次"与代码不符；relay 至少 3 次 miss 并校验 outstanding echo。

Gate：慢链路夹具下健康连接零误杀；队列字节峰值有上限证明；拒绝路径有显式日志与计数。

### P0-C 请求级进度超时与 Timer 生命周期

- 进度按 requestId/transferId 记录，排除 heartbeat/control。
- 增加总时长硬上限。
- 成功、断线、idle timeout、hard timeout 四条终止路径都必须 `cancel()` watchdog Timer。

不得只补 Timer 泄漏：那样仍会让心跳给已死 RPC 续命。

Gate：注入"响应永不到达 + 心跳正常"场景，RPC 必须在硬上限内失败且无残留 Timer。

### P0-D chunk-v2 资源校验与同连接 rollout

- 保留同连接 gzip + 分页（这是当前有效吞吐收益），置于可回滚 rollout flag 后。
- 严格校验：BEGIN 的 size/encoding schema、DATA 每页 ≤36KiB、累计压缩与解压输出上限、pageCount 语义、DONE 前的 size/hash 核对。
- retained/assembler 按认证 owner 隔离（当前 `p2p_host.ts:534-537,829-834` 全 guest 共享）。
- 主动到期清理：当前 60s TTL 只在 add 时 sweep，探针确认 60,001ms 后首次 NACK 仍命中并刷新留存。
- **跨重连 resume 保持门控**，直到 owner-scoped 持久化与真实换 socket 测试通过。

Gate：gzip bomb / 超大页 / 未知 transfer 均被明确 ABORT；两 guest 并发状态互不可见。

### P0-E extension 权威分页与硬上限

- `desktop_register/desktop_snapshot` 只发 state、revision、entryCount、tip/oldest cursor 和一个小尾页。
- 新增 `desktop_get_entries_page {before/since, tipId, limitBytes}` 转发给扩展，由扩展按稳定 revision/cursor 从权威 branch 返回页面。
- 首屏 128KiB / entries 页 96KiB / event 页 64KiB 硬上限，移除任何"最少 N 条"突破预算的规则。
- 超大单条内容改 preview + `contentRef`，按需范围请求。
- bridge 只做有界近期页 LRU（建议 8MiB/source、64MiB 全局）。

Gate：12MiB 以上会话的旧历史可达；单页线上字节不超限；bridge 常驻内存有上限证明。

### P1 可观测性、弱网基准、持久化

- selected ICE candidate pair、candidate type、direct/relay、协议 UDP/TCP/TLS；各阶段耗时；分类队列字节、native bufferedAmount、credit target、实测 drain rate；transfer 原始/压缩字节与耗时；ping RTT/miss；RPC timeout/late/busy/resync。
- 固定 20MB/5,000 entries 弱网夹具（50KB/s、300ms RTT、2% loss）。
- 100MB 不可压缩数据双向基准矩阵：裸 DataChannel → credit pump → chunk-v2 无 gzip → 加 gzip → 完整 `hub_sync`，各自跑强制 direct 与强制 TURN。用于区分网络瓶颈、TURN 瓶颈、应用排队和 werift 发送路径。
- App 持久化已加载历史页，启用按字节 SQLite LRU（`SyncStore.pruneEntries` 目前无生产调用点）。

Gate：能从运行日志判定真实走 direct 还是 TURN；基准矩阵可复现。

### P2 架构收敛

- control/interactive 与 bulk 拆双 DataChannel，加跨流 sequence/barrier。单条 reliable/ordered SCTP 流内，应用层优先级只能改变尚未提交数据的顺序，这是硬约束。
- 帧分类改结构化：按顶层 `type` 与 `Buffer.byteLength` 判定，control 另设 ≤2KB 硬上限。当前子串匹配可被普通 payload 里嵌套的 `{"type":"bridge_ping"}` 骗过（10,072B 响应被判 control 已复现）。
- transport Happy Eyeballs、connectivity change 即时重连、网络感知缓存。
- coturn UDP/TCP/TLS 443 多入口、地域与带宽压测。

## 绝不能做成表面修补的项

- bulk 记账：只加 `bulkQueuedBytes += bytes` 会得到"半条 transfer"语义，比现在更难诊断。必须原子准入。
- 进度超时：只补 `cancel()` 不改进度来源，心跳仍会给死 RPC 续命。
- 跨重连 resume：不做 owner-scoped 持久化就打开，等于把丢数据换成状态串台。
- 大会话：提高 socket 上限或把整场会话交给 chunk-v2 都不解决 12MiB 截断导致的历史不可达。

## 验证命令

```bash
cd bridge && npm run typecheck && npm test
cd rendezvous && npm run typecheck && npm test
cd extension && npm run typecheck && npm test
flutter analyze
flutter test
```

注意：仓库根目录没有 package.json，npm 命令必须在 `bridge/`、`rendezvous/`、`extension/` 各自目录内执行。

## 回归测试必须做对照实验

本批实现里有两条测试最初写得"看起来对"但根本抓不住缺陷：

- 泵丢唤醒测试最初断言 `isPumping`/`pending`，而缺陷版实现里根本没有这个旗标，于是测试"刚好"通过。改成与实现无关的"跑够多轮事件循环后帧必须已发出"。
- 信号竞态测试最初断言"不报错 + 能建链"，但 werift 静默丢候选，且 loopback 能靠 peer-reflexive 救回，所以缺陷版也通过。改成断言诊断计数器为 0。

结论：**每一条声称修了缺陷的回归测试，都要把实现换回缺陷版跑一次，确认它真的失败**。测试全绿不等于测试有效。

## 大会话验证结论（2026-07-31，无头 P2P 探针 + 真实 TURN）

前一轮真机验证只覆盖了约 100 条的小会话。这一轮用**无头 P2P 探针**打开本机最大的
50.40MB 会话（9554 条 entries），走与手机完全相同的路径：真实 rendezvous 挑战应答、
真实 TURN 中继、真实 DataChannel、相同的 `p2p-chunk-v1/v2` 能力声明。

探针存在的理由：App 的自动分页依赖滚动阈值与 `maxScrollExtent`，adb 滑动触发不到，
所以真机 UI 测不出「加载更早」的耗时。探针绕过 UI，但不绕过任何传输层。

### 修复前后对比（真实 TURN 中继路径）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 打开 50.40MB 会话 | `code=1011 p2p send failed`，**永远打不开** | 可打开 |
| `get_entries` 首屏 | 22599ms / 2.8 KB/s | **1361ms**（回环 327ms） |
| 「加载更早」第 1 页 | 17215ms，**与上一页完全相同** | 1295ms，内容不同 |
| 「加载更早」第 2 页 | 不存在（永远同一批） | 1384ms，游标继续推进 |
| 单页线上字节 | 52,845,816B → 裁到 78KiB | 37.4KiB（落在 96KiB 预算内） |
| 通道 1011 关闭 | 每次请求一次 | **0 次** |

回环路径下同一操作是 327ms / 301ms / 324ms，说明剩下的约 1 秒是 TURN 的 434ms RTT
本身，不是代码。

### 真机/探针暴露并修掉的 4 个缺陷

这 4 个都是静态审计、单测、弱网夹具全部跑通之后才暴露的：

1. **载荷过大会杀通道**（`bridge/src/p2p_host.ts`）
   `trySend` 用同一个 `catch` 处理「编码抛异常」和「通道故障」，一律
   `shutdown(1011)`。50MB 会话的 `get_entries` 让 `encodeTransferV2` 抛
   "P2P message exceeds 16MB" → 通道被杀 → 连超时响应都发不回去 → 手机重连 →
   再次请求 → 循环。这就是「连上就断」的直接机制。
   现在编码单独 `try`：载荷过大只拒这条消息，通道保持可用，回一条明确失败。

2. **转发型只读响应没有任何字节预算**（`bridge/src/server.ts`）
   `handleDesktopRead` 里的页预算与单条硬上限**只作用于 desktop 源**。无头源的
   `get_entries` / `get_tree` 走 `forwardSourceCommand` → pi → `resolvePending`，
   把 pi 返回的原始 JSON 一字节不改地转给手机。实测 52,845,816B 直接过线。
   现在 `resolvePending` 对只读命令统一过预算，并在发送失败时区分「载荷过大」
   与「队列满」回不同的明确错误。

3. **单条硬上限对没有 `message` 的 entry 完全失效**（`bridge/src/server.ts`）
   `capEntryForMobile` 与 `hardCapEntryForMobile` 都只看 `entry.message`，而
   `compaction` 类型**根本没有 message 字段** —— 体积全在顶层 `summary`
   （实测单条 259KB 字符串）和 `details.observations/reflections`（实测 316KB 数组）。
   真机日志 `entries_before{entries:1/1728,bytes:212673}`：单条 207KiB 把 96KiB
   页预算顶穿 2.2 倍。50.40MB 会话里有 **35 条**这样的 entry，最大 576,630B。
   现在加了形状无关的 `degradeOversizedFields`：按顶层字段体积降序逐个削，
   保留结构性字段与 `summary` 可读开头（手机端唯一会显示的内容），
   仍超限则只留结构性字段骨架。

4. **无头源的「加载更早」功能不成立**（新增 `bridge/src/session_entries.ts`）
   pi 的 RPC `get_entries` **只有 `since`，没有 `limit`，也不认 `before`**
   （见 pi 的 `rpc-types.d.ts`）。所以 bridge 把 `before` 转发过去后 pi 忽略它、
   返回全部，bridge 再裁尾巴 —— 每页都是同一批最新的 33 条。探针实测
   「第1页与上一页完全相同=true」。这不是慢，是功能坏的。
   现在无头源的 `get_entries` **直接流式读会话文件**，不打 pi：
   - 正确性：`before`/`since`/`forward`/`tipId` 全部在本地解析，翻页真的推进。
   - 性能：一遍扫 50MB 约 300ms，比 22.8s 快约 70 倍。
   - 内存：滚动窗口，O(单页) 而不是 O(会话)（整份缓存实测仍有 30.77MB/会话）。
   前提已验证：会话文件是 append-only jsonl，9555 行 = 1 行会话头 + 9554 条 entry，
   与 pi 返回的 9554 条逐一匹配，id 全唯一，解析零失败。

### 回归测试与对照实验

每条修复都按项目规则对着「回退成缺陷版」跑了对照实验，证明测试真的会失败：

| 修复 | 测试 | 对照实验结果 |
|---|---|---|
| 无头分页正确性 | `test/session_entries.test.ts`（7 条） | `before` 忽略游标 → 2 条失败 |
| 形状无关硬上限 | `test/protocol_ext.integration.test.ts` | 只认 message → 失败于 `实际 560717B` |
| 载荷过大不杀通道 | `test/p2p_host.test.ts` | 共用 catch → 失败于「必须标记为载荷过大」 |

### 一个先前结论的更正

前一轮我写过「bridge 没有任何子进程，无头 pi 根本没被创建」。**这是错的** ——
我查的是 npm 包装进程的子进程，真实 node 进程在它下面一层。无头 pi 一直活着。
`mode:rpc` + `entries:0` 也不是缺陷：`source_registry` 在没有快照记录时就返回
`mode:"rpc"`，无头会话的内容本就该由客户端发 RPC 取，是探针轮询错了对象。

### 设备端端到端验证（2026-07-31，release APK / 2211133C / TURN 中继）

探针验证过传输层之后，又发现一个产品层缺陷：**这条能力在 App 上根本不可达**。

`lib/ui/sessions/devices_page.dart` 原注释写着「刻意*不*枚举
`~/.pi/agent/sessions/` 里的历史会话文件（沿用原设计决策）。手机的职责只有一个：
连到**已经开着的窗口**上去」。于是设备页只渲染 `isDesktop && connected` 的源。
那个 50.40MB 会话只在磁盘上、电脑端没开着它，所以无论 bridge 分页做到多快，
用户都找不到入口打开它。

数据其实早就到手机了，只缺列表 UI：

| 层 | 状态 |
|---|---|
| bridge `hub_list_sessions` | 正常返回 63 个（含那个 50MB 的） |
| `HubSession.fromMap` | 不丢任何会话，`sizeBytes`/`path` 都在 |
| `openSession()` | 早就能唤醒（探针走的就是这条） |
| 设备页列表 | **只渲染开着的窗口** ← 挡在这里 |

推翻了那条设计决策，理由记在代码注释里。连带修掉两处：

- `_refresh()` 原来只调 `refreshSources()`，不调 `refreshHubSessions()` —— 就算加了
  列表 UI，设备页也拿不到磁盘会话数据，两处必须一起改。
- 第一版历史段只收 `dormant`，而窗口段只收 `isDesktop`。会话被唤醒变成 `headless`
  之后两段都不要它，这一行会**凭空消失**。现在历史段收 `!= desktop`，`headless`
  显示「运行中」，当前选中的标「当前」并禁用点击。

### release APK 实测（用户在真机上手动切到 50.40MB 会话）

新分页器接手 14 次，**0 次落回转发给 pi**：

```
mode:tail   entries:37  bytes:81093  ms:358
mode:before entries:35  bytes:96579  ms:620
mode:before entries:30  bytes:98219  ms:333
mode:before entries:12  bytes:58836  ms:352
mode:before entries:6   bytes:95376  ms:334
mode:before entries:23  bytes:67205  ms:359
mode:before entries:2   bytes:73068  ms:345
mode:before entries:18  bytes:94548  ms:367
mode:before entries:22  bytes:83717  ms:346
mode:before entries:22  bytes:88366  ms:341
```

- **连续 9 页 `before` 每页都在推进** —— 修复前这 9 页会是同一批最新 33 条，每页约 17s。
- 每页 entry 数差异很大（2～37）而字节数都贴着 96KiB —— 预算按**封顶后**真实字节算，
  不是按条数猜。只有 2 条那页说明那两条本身就胖（compaction）。
  最大一页 98219B = 95.9KiB，落在 98304B 预算内。
- 手机端 `get_entries` 在 TURN 上 1748 / 1854 / 1772 / 1772ms，`hub_open_session` 508ms。
- **0 次超时、0 次重连、0 次 1011 关闭**，0 个 App 层异常。

### 一个已知特性（非缺陷，但别当成已解决）

日志里每页都是 `scanned:9558/50.4MB`：**每翻一页都重扫整个文件**，约 340ms 本机 CPU。
内存仍是 O(单页)，功能完全正确，但时间复杂度是 O(文件) 而非 O(页)。
要做到 O(页) 需要 id→字节偏移的索引缓存。340ms 当前够用，所以没做。

另外 `hub_sync` 观察到两次偏慢（3865ms / 3296ms），属快照同步路径，与这轮分页改动无关，未追查。

### 自动化验证的边界

这台 2211133C（HyperOS）默认禁止 adb 注入输入：
`SecurityException: INJECT_EVENTS`，要开「USB 调试(安全设置)」才行，
而那需要登录小米账号。截图可取、点击不可注入，所以最终的 UI 交互确认由用户手动完成。
App 的自动分页依赖滚动阈值与 `maxScrollExtent`，本来也测不了。

### 仍未做的项

- **`get_state` 对刚拉起的无头大会话要 2.7s**：这是 pi 首次加载 50MB 会话文件的
  一次性代价（会话已热时同一调用是 10ms），不是每请求代价，也不在 bridge 侧。
- **转发裁剪（缺陷 2）没有独立回归测试**：`test/fixtures/fake_pi.mjs` 只支持
  `get_state`，要测得先扩夹具支持 `get_entries`。当前由真机探针实测覆盖。
- **链路真实吞吐上限仍未知**：`drainBps` 全程停在初值，说明 payload 太小、
  `bufferedAmount` 从未堆起来。要知道上限得建 100MB 不可压缩数据的基准矩阵。
- **extension 权威分页**（`desktop_get_entries_page`）未实现。它只在会话超过扩展
  12MiB 线上限时才必要 —— 那时被丢弃的旧历史对手机永久不可达。

## 真机验证结论（2026-07-31，Android 16 / 2211133C / TURN 中继）

测量环境：bridge 作为 host 注册到 `wss://pi-pilot.sisct.xyz`，手机经 TURN 中继接入，
被测会话是本机 1616 条 entries 的真实大会话。

### 实测数字

| 指标 | 数值 |
|---|---|
| 选中候选对 | `local:relay/udp remote:relay/udp viaRelay:true` |
| TURN 实测 RTT | **434~447ms** |
| 建链总耗时 | **4476ms**（三轮迭代：8317 → 6068 → 4476） |
| 首屏 `hub_sync` 线上字节 | **130,595B**（裁掉 1538 条） |
| 首屏端到端耗时 | **845~1634ms** |
| 端到端实测吞吐 | **约 108KB/s** |
| RPC 超时/无进度 | **0 次** |
| 队列积压峰值 | 0（`normalQ`/`controlQ` 全程为 0） |

结论：**首屏与增量同步已不慢**。服务端组包只要 11~15ms，端到端约 1.2s，
瓶颈是 434ms RTT 的中继链路本身，不是代码。

### 真机暴露并已修复的四个缺陷

这四个都是静态审计与单测没能发现、只有真机遥测才暴露出来的：

1. **`selected_pair{pair:none}`** — getStats 解析只认 `selected`/`nominated+succeeded`，
   真机上取不到候选对。改为多级回退（transport 的 `selectedCandidatePairId` →
   `selected` → `googActiveConnection` → `nominated+succeeded` → 任一 `succeeded`），
   并在仍失败时打印实际 report 类型，避免盲改。

2. **空闲期信用衰减到地板** — `drainBps` 从初值 128KB/s 一路衰减到 4KB/s 地板。
   根因是 `buffered == 0` 时也走停滞衰减分支：缓冲是空的说明没有东西要排空，
   这不是链路慢的证据。

3. **跨越整段空闲的测速窗口**（写回归测试时才发现的更深一层）— 热态残留 80KB，
   空闲 15s 后心跳触发一次采样，`80KB ÷ 15s` 被当成一次有效测速算出 5.4KB/s。
   加 `DRAIN_SAMPLE_MAX_MS = 2000`：窗口跨度过大说明中间没人采样，重置基线而不据此算速率。

4. **首屏预算溢出 13%** — 实测整帧 148,217B，超过 128KiB 硬上限。根因是预算只加在
   `entries` 数组上，而 `state`/`events`/元数据同样要过线。改为先算响应外壳字节数，
   再把剩余额度给 entries。修复后实测 130,595B，落进上限。

5. **往前翻历史用了 WS 的 1MB 预算** — loopback 探针实测单页 **1023.6KiB**。
   `get_entries` 的 `before` 与增量路径都用 `clipEntriesForMobile` 的默认值，不区分传输。
   按实测 108KB/s，一页要 9.7s；50KB/s 的慢 TURN 上约 20s，直接超过请求超时 ——
   「加载更早」于是表现为转圈很久然后失败。已改为按传输选预算（P2P 96KiB / WS 1MB）。

### 按基准数据降级的项

**双 DataChannel 硬隔离**（原 P2 第 1 项）不再是必需项。弱网夹具实测：50KB/s 下
控制帧排队 **1978ms**，远小于心跳窗口（3 次 miss ≈ 30s）。硬隔离要引入跨流
sequence/barrier 的复杂度，而它要解决的心跳误杀问题已由信用窗口收敛 + 心跳分档解决。

弱网基准另外暴露一个真实结论：**未协商分片能力时，单条大帧完全绕过信用制流控**
（控制帧排队 4780ms，整条 400KB 一次灌进 SCTP）。生产路径上手机会声明
`p2p-chunk-v1/v2`，所以夹具必须启用分片才测得到真实形态。

### 仍未做的项

- **extension 权威分页**（P0-E 剩余部分）：`desktop_get_entries_page` RPC 尚未实现。
  它解决的是「超过扩展 12MiB 线上限的会话，被丢弃的旧历史永久不可达」，
  不是首屏慢。当前 1616 条会话的历史仍在 bridge 上，分页可达。
- **100MB 不可压缩数据的双向基准矩阵**：需要专门夹具，尚未建。
- **coturn 多入口/地域压测**：运维范畴。

## 下一步

P0-A 到 P2 的代码级实现均已完成并通过真机验证（bridge 98/98、Flutter 338/338、
`flutter analyze` 无 issue）。按当前证据，剩余工作按这个顺序：

1. **验证「加载更早」在真机上的实际耗时**。分页预算缺陷刚修（1023.6KiB → ≤96KiB），
   已有 P2P 集成测试覆盖，但还没在真机 UI 上量过端到端耗时。UI 的自动分页依赖
   滚动阈值与 `maxScrollExtent`，adb 滑动不可靠；需要能稳定触发的入口才好测。
2. **建 100MB 不可压缩数据的双向基准矩阵**（裸 DataChannel → credit pump →
   chunk-v2 无 gzip → 加 gzip → 完整 `hub_sync`，各跑强制 direct 与强制 TURN）。
   这是把「网络瓶颈 / TURN 瓶颈 / 应用排队 / werift 发送路径」四者分开的唯一办法。
   当前实测吞吐约 108KB/s，但从未跑满过链路 —— `drainBps` 全程停在初值，
   说明 payload 太小、`bufferedAmount` 没堆起来，真实上限仍未知。
3. **extension 权威分页**（`desktop_get_entries_page`）。只在会话超过扩展 12MiB
   线上限时才必要 —— 那时被丢弃的旧历史对手机永久不可达。当前 1616 条会话未触及此限。
4. **coturn 多入口与地域压测**（运维范畴）。434ms 的 RTT 是当前首屏耗时的主要构成，
   换更近的中继节点比继续改代码收益更大。

## 教训：只有真机遥测能发现的缺陷

本轮 P0-A 到 P2 的静态审计 + 单测 + 弱网夹具都跑通之后，真机第一轮就暴露了 5 个
缺陷（见上）。其中两个（空闲期信用衰减、跨空闲测速窗口）是**修复引入的新缺陷**，
两个（首屏预算溢出、分页用 WS 预算）是**"上限"实际没生效**。

共同点：它们都需要「真实时间流动 + 真实网络形态 + 真实会话规模」三者同时成立才会显形。
所以插桩优先于优化 —— `P2pConnector` 此前完全没有日志出口，任何吞吐问题都只能靠猜。
