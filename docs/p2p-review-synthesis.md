# P2P 连接问题双模型审查汇总与综合方案

> 来源：两个独立 reviewer subagent 对 PiPilot P2P 子系统的只读架构审查（未修改任何代码）。
> - 报告 A：`sisct2/gpt-5.6-sol:xhigh`（artifact: `.pi-subagents/artifacts/1b47f87f_reviewer_0_output.md`）
> - 报告 B：`kimi-coding/k3:max`（artifact: `.pi-subagents/artifacts/1b47f87f_reviewer_1_output.md`）
>
> 症状：P2P 连接成功后会话列表加载不出、只能看到电脑 pi 状态（心跳/pong 正常）、偶尔能加载出一次消息。

## 一、两份报告的共识（高置信结论）

两份独立审查在最可能根因上完全一致，可视为高置信结论：

1. **主根因（H1）**：`hub_sync` 的 MB 级快照响应在慢速 TURN 链路上的传输时间系统性超过 Flutter 端统一 20s 请求超时（`lib/state/pi_session.dart:2421-2424`），超时后请求上下文被删除，晚到响应被静默丢弃（`pi_session.dart:2925`），且 `_syncSelectedSource` 失败后静默 return、无重试（`pi_session.dart:2203`）。
2. **第二个独立失败阈值**：分片重组 TTL 从首片起固定 30s（双端 `p2p_chunking.*`），慢链路大快照必丢；工作区已有未提交的"改为空闲 TTL"修复，方向正确但未消除 20s RPC 超时。
3. **队头阻塞假象**：控制帧/列表/快照/流式事件共用单一有序 DataChannel 的 FIFO，只有 `bridge_pong` 走优先队列（`bridge/src/p2p_host.ts`）→ 心跳一直正常，掩盖数据面已死。
4. **"偶尔成功一次"的解释一致**：链路偶然变快 / direct 打洞偶然成功绕过 TURN / 快照较小时，大响应能在 20s 内到达。
5. 重构方向一致：流量分级、快照分页/差分、修超时与重试、可观测性、拆 god object、双端协议参数统一。

## 二、两份报告的差异与优劣

| 维度 | 报告 A（gpt-5.6-sol:xhigh） | 报告 B（kimi-coding/k3:max） |
|---|---|---|
| 传输层根因链 | 正确但止于"超时+静默丢弃" | 更完整：8MB bufferedAmount→close(1013) 自我放大重连死循环、30s/片 drain→close(1011)、Flutter 发送队列毒化（`_sendQueue.then` 无 onError，一次失败后后续发送全部蒸发，`p2p_connector.dart:112-115`）、bridge 对 P2P 的 ping 本地自答 pong 导致活性检查失效 |
| 量化分析 | 较少 | 充分：1MB→~30 片×48KB、TURN 30–100KB/s→15s~数分钟、direct 7s 空等 |
| 非传输层解释（会话列表为空） | **独有**：列表加载是 unawaited 且失败只留旧空列表（1358/1031）；UI 过滤 headless/dormant（devices_page.dart:105）；`collectSessions()` 只扫部分目录（server.ts:542） | 未覆盖 |
| 协议/工程设计 | **独有**：stable clientId 未接线（1908）；负载上限用字符数而非 UTF-8 字节数，中文/emoji 可越界关通道；desktop relay 不在本仓库的诚实边界声明 | 双端平行实现参数漂移 + 共享测试向量方案 |
| P0 可操作性 | 偏保守（90s 超时+分页 256–512KiB） | 更具体：首载预算降到 ~128KB（≈3 片）+ `get_entries before` 分页补历史 + RPC 响应进优先队列 |
| 验证闭环 | 无 | **独有**：一行验证法（bridge 日志 close code 1011/1013 + `hub_sync` 计时 >20s 即确诊） |

**评价**：
- 报告 B 在传输层明显更深、更可执行，附诊断闭环，适合作为修复主框架。
- 报告 A 的独有发现补齐了"非传输层"解释维度（即使传输修好，目录收集/UI 过滤问题仍会让列表为空），且 clientId、字节预算两个工程问题很实在。
- 两份报告都基于静态审查，P0 前应先做日志验证。

## 三、综合后的更合理方案（推荐执行顺序）

### 第 0 步：先确诊（半天，不改代码逻辑）
- bridge 日志观察是否反复出现 DataChannel close code **1011**（drain 超时）/ **1013**（>8MB 积压）。
- 手机端给 `_request('hub_sync')` 计时：稳定 >20s 即确诊 H1。
- 同时确认当前连接走的是 direct 还是 TURN relay。

### P0 止血（1–2 天）
1. 合入未提交的分片 TTL 修复（首片计时→每片刷新的空闲 TTL），双端 idle timeout 30s→120s。**安全护栏**：同时给重组器加上限——最大并发组装数、总缓冲字节数、单条逻辑消息大小上限——防止长 TTL 导致内存滞留或被恶意/异常对端放大。
2. `hub_sync`/`hub_open_session`/`hub_select_source` 超时提到 60s；`_syncSelectedSource` 失败改走 `_scheduleSourceResync` 兜底重试（不再静默 return）。
3. P2P 通道下 `hub_sync` 首载 entries 预算降到 ~128KB（≈3 片），历史用已有的 `get_entries before` 游标分页补。
4. 优先队列只放行**有界小帧**（pong、控制帧、小 RPC 响应，设严格字节阈值）；快照等分页大帧在编码前就归类为 bulk 入普通队列——不能把所有 `type:response` 都提级，否则大 hub_sync 响应会反过来占死交互队列。
5. 并行排查非传输因素（报告 A 独有）：`collectSessions()` 目录扫描范围、UI 对 headless/dormant 的过滤、列表加载 unawaited 失败吞没。

### P1 根因修复（约 1 周）
1. 三级流量分级发送器：liveness > interactive（RPC 响应/小事件）> bulk（快照分片、message_update）。
2. 快照差量化 + 首载分页协议化；`message_update` 改 delta（或超阈值才全量）。
3. 修 Flutter 发送队列毒化（`_sendQueue` 加错误恢复 + 通道死立即返回失败）。
4. 可观测性：close code、快照传输耗时、队列峰值、`_request` 超时、重组失败全部落日志。
5. 接线 stable clientId；快照预算按 UTF-8 字节数对齐；直连/relay 成功模式缓存（跳过 7s direct 空等）。

### P2 架构重构（2–4 周）
1. 分片/重组/背压/优先级收敛为独立 ReliableChannel 模块，Dart/TS 共享协议常量表与测试向量，杜绝双端漂移。
2. 协议 v4：显式帧分级（control/rpc/event/bulk）+ 分类流控窗口 + 请求取消语义；评估 control+bulk 双 DataChannel。
3. 拆分 `PiSessionNotifier`（3700 行）与 `server.ts`（2400 行）：连接生命周期 / 同步游标 / reducer / 租约各自独立，同步状态机显式化。
4. 慢网回归测试：50KB/s 限速 + 丢包注入下断言"快照传输中 hub_list_sessions 仍 <2s 响应"。

## 四、结论

- **最强共同诊断**：数据面队头阻塞 + 各层超时时限互不匹配（请求 20s / 分片 30s / 逐片 drain 30s / 测试 60s），最可能由大 `hub_sync` 快照在慢速 TURN 链路上触发 → 心跳/状态正常，数据面饿死，偶快偶成。
- **重要保留**：`hub_sync` 超时不能单独解释"会话列表为空"——`hub_list_sessions` 响应是 KB 级小帧，理应能到达。报告 A 发现的目录收集不全（`collectSessions` 只扫部分目录）、UI 过滤 headless/dormant、列表加载 unawaited 且失败吞没，是**独立的并列候选根因**。因此运行日志验证（hub_sync 计时、队列深度、direct-vs-TURN、close code 1011/1013）是确诊的必要步骤，不能跳过。
- **执行建议**：以报告 B 的根因链与 P0 为传输层执行主框架，吸收报告 A 的非传输层排查项（collectSessions/UI 过滤/unawaited）与 clientId、UTF-8 字节预算两个工程修复。提高超时只是临时止血；分页、有界 QoS、可重试的初始化状态机、可观测性才是真正的 P1 修复。
