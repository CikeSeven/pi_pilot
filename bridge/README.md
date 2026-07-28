# PiPilot Source Hub

`bridge/` 是手机与 pi source 之间的路由和所有权层。它管理两类 source：

- `desktop`：由 `extension/` 在本机 pi TUI 中注册，默认路径。
- `headless`：由 Hub 启动的 `pi --mode rpc` 子进程，只在用户显式选择并 acquire 时启动。

## 启动

```bash
npm install
PIPILOT_TOKEN='强随机手机 token' npm start
```

默认端口为 `9377`，健康检查为：

```bash
curl http://127.0.0.1:9377/health
```

响应示例：

```json
{
  "ok": true,
  "hubId": "...",
  "piAlive": false,
  "mobileClients": 1,
  "desktopSources": 1,
  "cwd": "/path/to/headless/cwd"
}
```

## 安装 desktop relay

```bash
npm run install:extension
```

该命令：

1. 生成独立 desktop token 并持久化到 `bridge/config.json`（0600）。
2. 写入 `~/.pi/agent/pipilot-sync.json`（0600）。
3. 备份 `~/.pi/agent/settings.json`。
4. 执行 `pi install ../extension`。

只生成配置、不安装 package：

```bash
npm run configure:extension
```

安装后在目标 pi TUI 中执行 `/reload`。详细安全边界见 `../extension/README.md`。

## Endpoint 与鉴权

| Endpoint | 角色 | 鉴权 | 网络边界 |
|---|---|---|---|
| `/` | Flutter/mobile client | `PIPILOT_TOKEN` | LAN 或 Tailscale |
| `/desktop` | pi TUI relay | 独立 desktop token | 强制 loopback |
| `/health` | 健康检查 | 无 | 部署时应仅放在可信网络 |

WebSocket token 可放在 `?token=` 或 `Authorization: Bearer`。比较使用 constant-time equality。

## Source Hub 协议

握手：

```json
{
  "type": "bridge_hello",
  "version": 3,
  "hubId": "...",
  "clientId": "...",
  "capabilities": [
    "sources", "replay", "snapshot", "owner-lease", "desktop-relay",
    "sessions", "concurrent-sessions", "navigate-tree"
  ]
}
```

客户端可以带 `?clientId=<稳定 id>` 连接。同一个 clientId 的旧连接会被顶掉,
重连后仍被视为同一个"驱动者",不必等旧租约 TTL 过期。

### Hub 命令

| 命令 | 说明 |
|---|---|
| `hub_list_sources` | 列出 desktop/headless sources、在线状态和公开 owner 状态 |
| `hub_select_source {sourceId}` | 为当前 mobile socket 选择 source；离线 headless 也可选择 |
| `hub_sync {cursor?}` | cursor 可重放时返回 replay；否则返回 snapshot；headless 返回 RPC snapshot barrier |
| `hub_list_sessions {cwd?}` | 会话总表:活跃进程 + 磁盘上的休眠会话,带 `liveness` 与 `streaming` |
| `hub_open_session {sessionId?,cwd?,sessionPath?,spawn?}` | 订阅一个会话并按需 attach/spawn。**从不 kill 任何进程**;不传 `sessionId` 表示新建 |
| `hub_close_session {sourceId}` | 关掉一个 headless 会话的进程(正在生成时拒绝) |
| `hub_acquire_owner {ttlMs,force?}` | 获取 owner lease。**默认强制抢占**(`force:false` 才尊重现有持有者);**没有任何进程副作用** |
| `hub_renew_owner {leaseId,fence,ttlMs}` | 延长 lease |
| `hub_release_owner {leaseId,fence}` | 释放 lease |

主动推送帧:`hub_sources_changed`、`hub_sessions_changed`(150ms 防抖)、
`hub_owner_changed`、`hub_control_moved`、`hub_source_snapshot`、
`hub_source_offline`、`hub_session_died`。

每个 source event 保留原 Pi RPC payload，并增加：

```json
{
  "_hub": {
    "hubId": "...",
    "sourceId": "...",
    "sourceEpoch": "...",
    "seq": 42
  }
}
```

response 私有回给请求者，不占 source sequence。客户端 request ID 会在 Hub 内改写为 UUID，避免多个 mobile client 使用相同 ID 时串包。

### 租约(对用户不可见)

租约只做两件事:**fencing**(作废掉线客户端的在途命令)和归因。它**不再决定谁能说话**
——两端随时都能发消息和打断,客户端自动获取租约、失败就强制重取一次。

只读命令:`get_state`、`get_entries`、`get_available_models`、
`get_available_thinking_levels`、`get_session_stats`、`get_tree`、`get_commands`、
`get_fork_messages`、`get_last_assistant_text`。

其他命令视为写入,必须携带:

```json
{
  "_hub": {
    "leaseId": "...",
    "fence": 3
  }
}
```

Desktop relay 只接受 `prompt`、`abort`、`set_model`、`set_thinking_level`、
`set_session_name`、`compact`、`navigate_tree`。
`fork` / `new_session` / `switch_session` **永远不开放给桌面** —— 那会把人正在用的
会话从电脑上抽走。未知 desktop 命令即使有 lease 也会拒绝。

写命令落到一个**休眠的 headless 会话**上时,hub 会先 attach/spawn 它再转发
(只读命令仍然如实回答"离线")。`fork`/`clone`/`switch_session`/`new_session`/
`navigate_tree`/`compact` 按 source **串行化** —— pi 的 RPC 是即发即忘,
并发执行会损坏运行时状态。

### 会话回退

pi 的 RPC 协议里没有 `navigate_tree`。hub 把它翻译成
`prompt "/pipilot-nav <entryId>"`(空 entryId → `/pipilot-undo`),由 PiPilot 扩展
调用 `ExtensionCommandContext.navigateTree`。相应地,`prompt` 通道**拒绝**
其它斜杠命令 —— 否则用户以为在发一句话,pi 却执行了一条扩展命令。

## Desktop source protocol

relay 使用：

- `desktop_register`：source identity、capabilities、初始 snapshot。
- `desktop_snapshot`：epoch/baseSeq、active branch entries、state、in-flight assistant message。
- `desktop_event`：epoch 内严格递增 seq。
- `remote_command` / `remote_result`：带 requestId、epoch 和 fence 的白名单命令。
- `desktop_ack`、`desktop_resync_required`、heartbeat、status。

Desktop source 一注册，Hub 会停止 headless 并禁用自动重启。多个 desktop TUI 可同时注册为不同 source，但手机不会按 activity 或 OS focus 自动切换。

## Headless 与会话命令

Headless 默认关闭：

```text
PIPILOT_HEADLESS_AUTO_START=false
```

仅显式设置为 `true` 才会在 Hub 启动时自动拉起，但不推荐，因为 pi 启动时可能向 pinned session 追加 metadata/custom entries。

Headless source 支持原生 Pi RPC 以及 bridge-local 命令：

| 命令 | 说明 |
|---|---|
| `bridge_list_dirs` | 只读扫描 session header，按 cwd 分组 |
| `bridge_list_sessions {cwd}` | 只读返回会话 metadata |
| `bridge_switch_dir {cwd,sessionPath?}` | 需要 lease；验证 cwd 后**打开另一个会话**(不再 SIGTERM 重启,当前会话的生成不被打断) |
| `bridge_get_config` | 返回非秘密运行配置 |
| `bridge_set_config {token}` | 需要 lease；更新 mobile token |

`bridge_switch_dir`、`switch_session`、`new_session`、`fork`、`export_html` 等均属于写命令。

## 已知的历史 bug(v3 修复)

桌面端消息不实时同步的**根因**不在 hub,而在 relay:`isCurrent(ctx)` 用对象身份
判断 ctx 是否属于当前会话,而 pi 的 `ExtensionRunner.emit()` **每次都新建一个
ExtensionContext 对象**。于是 `session_start` 之后的每一个事件、每一次快照、
每一次流式标志都被静默丢掉 —— 桌面源看起来在线,内容却永远停在注册那一刻。
现在改为比较会话文件路径(`extension/src/relay.ts` 的 `isCurrent`/`isBound`),
`extension/test/relay.test.ts` 用一个"新 ctx 对象"的断言钉住它。

## 进程池

一个 pi 进程只能持有一个会话,所以并发会话 = 多进程。池的核心不变量:

- **`open()` 永远不会 kill 任何东西** —— 切换会话是 attach 或 spawn。这正是
  「切换会话不打断电脑端生成」。
- 正在生成的会话**既不会被逐出、也不会被闲置回收**。
- 同一个会话文件绝不允许两个进程打开(claim 表);桌面 TUI 注册时,池里冲突的
  那**一个**会话让位,其余会话照常运行。
- 崩溃退避 1.5s×2^n(上限 30s),连续 5 次放弃并广播 `hub_session_died`。

`GET /health` 返回池状态(每个会话的 pid / alive / streaming / restarts)。

## 配置

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `PIPILOT_HOST` | `0.0.0.0` | mobile listener |
| `PIPILOT_PORT` | `9377` | HTTP/WebSocket 端口 |
| `PIPILOT_TOKEN` | config 或随机生成 | mobile token |
| `PIPILOT_DESKTOP_TOKEN` | config 或随机生成 | desktop registration token |
| `PI_CWD` | bridge 当前目录 | headless cwd |
| `PIPILOT_HEADLESS_AUTO_START` | `false` | 是否启动时自动拉起 headless |
| `PIPILOT_REPLAY_CAPACITY` | `1024` | 每 source 内存 event ring 条数上限 |
| `PIPILOT_REPLAY_BYTES` | `16MiB` | ring 的字节上限(每条 `message_update` 都带完整消息,只加条数是错的杠杆) |
| `PIPILOT_SNAPSHOT_TIMEOUT_MS` | `4000` | 向 desktop relay 索要按需快照的超时 |
| `PIPILOT_MAX_PI_PROCESSES` | `4` | 同时存活的 pi 进程数(并发会话上限) |
| `PIPILOT_SESSION_IDLE_TTL_MS` | `900000` | 无人观察且空闲多久后回收。**正在生成的会话永不回收** |
| `PIPILOT_LEASE_MIN_TTL_MS` | `3000` | 最短 lease TTL |
| `PIPILOT_LEASE_MAX_TTL_MS` | `8000` | 最长 lease TTL |
| `PIPILOT_HEADLESS_SOURCE_ID` | `headless:local` | 老协议的 source ID 别名(解析到引导会话) |
| `PIPILOT_HEADLESS_SOURCE_NAME` | `Local headless pi` | UI 名称 |

`bridge/config.json`（0600）保存 desktop/mobile token 与每目录 headless session pin。CLI/env 优先于文件配置。

## 验证

```bash
npm run typecheck
npm test
npm audit --omit=dev
node test-running-hub.mjs ws://127.0.0.1:9377?token=YOUR_TOKEN
```

`npm test` 不启动真实 pi，不读取或改写 `~/.pi/agent/sessions`。`test-running-hub.mjs` 不发送 pi mutation；它验证选择、只读同步、无 lease 拒绝和 acquire/release。

## 安全

- pi 进程无 sandbox，拥有当前用户权限。
- 不要把 `ws://` 暴露公网；使用可信 LAN 或 Tailscale。
- 不要让 headless 与 desktop TUI 同时写同一 session。
- relay event handler 不等待网络；流式 message 25ms 合并，tool update 100ms 合并，背压时重建 epoch/snapshot。
- replay ring 在 Hub 重启后丢失，因此 `hubId` 每次启动变化，客户端必须 snapshot。
