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
  "version": 2,
  "hubId": "...",
  "clientId": "...",
  "capabilities": ["sources", "replay", "snapshot", "owner-lease", "desktop-relay"]
}
```

### Hub 命令

| 命令 | 说明 |
|---|---|
| `hub_list_sources` | 列出 desktop/headless sources、在线状态和公开 owner 状态 |
| `hub_select_source {sourceId}` | 为当前 mobile socket 选择 source；离线 headless 也可选择 |
| `hub_sync {cursor?}` | cursor 可重放时返回 replay；否则返回 snapshot；headless 返回 RPC snapshot barrier |
| `hub_acquire_owner {ttlMs}` | 获取 source 的唯一 owner lease；离线 headless 在此时启动 |
| `hub_renew_owner {leaseId,fence,ttlMs}` | 延长 lease |
| `hub_release_owner {leaseId,fence}` | 释放 lease |

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

### 观察者与写入

只读命令：`get_state`、`get_entries`、`get_available_models`、`get_available_thinking_levels`、`get_session_stats`。

其他命令默认视为写入，必须携带：

```json
{
  "_hub": {
    "leaseId": "...",
    "fence": 3
  }
}
```

Desktop relay 进一步只允许 `prompt`、`abort`、`set_model`、`set_thinking_level`。未知 desktop 命令即使有 lease 也会拒绝。

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
| `bridge_switch_dir {cwd,sessionPath?}` | 需要 lease；验证 cwd 与枚举出的 session path 后重启 headless |
| `bridge_get_config` | 返回非秘密运行配置 |
| `bridge_set_config {token}` | 需要 lease；更新 mobile token |

`bridge_switch_dir`、`switch_session`、`new_session`、`fork`、`export_html` 等均属于写命令。

## 配置

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `PIPILOT_HOST` | `0.0.0.0` | mobile listener |
| `PIPILOT_PORT` | `9377` | HTTP/WebSocket 端口 |
| `PIPILOT_TOKEN` | config 或随机生成 | mobile token |
| `PIPILOT_DESKTOP_TOKEN` | config 或随机生成 | desktop registration token |
| `PI_CWD` | bridge 当前目录 | headless cwd |
| `PIPILOT_HEADLESS_AUTO_START` | `false` | 是否启动时自动拉起 headless |
| `PIPILOT_REPLAY_CAPACITY` | `512` | 每 source 内存 event ring 数量 |
| `PIPILOT_LEASE_MIN_TTL_MS` | `5000` | 最短 lease TTL |
| `PIPILOT_LEASE_MAX_TTL_MS` | `30000` | 最长 lease TTL |
| `PIPILOT_HEADLESS_SOURCE_ID` | `headless:local` | 内置 source ID |
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
