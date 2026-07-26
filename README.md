# PiPilot

PiPilot 是 pi coding agent 的手机控制端。Flutter app 连接电脑上的 Source Hub，可观察并控制当前桌面 pi TUI；也可在桌面 TUI 未连接时显式启动 headless RPC source。

```text
Flutter App (手机)
        |
        | WebSocket + mobile token
        v
PiPilot Source Hub (bridge/)
        |                         |
        | loopback + desktop token| stdin/stdout JSONL
        v                         v
Desktop TUI Relay             Headless pi --mode rpc
(extension/,默认路径)          (必须显式启动)
```

## 主要能力

- 桌面当前会话同步：消息、思考、tool 生命周期、队列、模型、thinking、会话元数据。
- 断线恢复：`hubId + sourceId + epoch + seq` cursor，ring replay 不可用时回退 snapshot。
- 多窗口：每个 desktop pi 进程是独立 source；手机明确选择，不依赖不可靠的 OS 窗口焦点。
- 单写者：手机默认观察者；prompt/abort/model/thinking 等写命令必须先取得 owner lease。
- 防过期写入：lease 带 fencing token；旧 socket、旧 epoch、旧 fence 会被拒绝。
- Headless fallback：desktop source 断开后不会自动接管；用户可选择离线 headless source 并点击“启动”。
- 会话与目录管理：仅 headless source 支持 switch/new/fork/目录切换等 RPC 能力。

## 快速开始

### 1. 安装 bridge 与 desktop relay

```bash
cd bridge
npm install
npm run install:extension
```

安装器会备份 `~/.pi/agent/settings.json`，写入权限为 `0600` 的 desktop relay 配置，并注册本地 pi package。它不会读取或修改 session JSONL。

### 2. 启动 Source Hub

```bash
cd bridge
PIPILOT_TOKEN='换成强随机值' npm start
```

Hub 默认不启动 headless pi。手机 endpoint 监听 `0.0.0.0:9377`；desktop relay 只允许通过 `127.0.0.1:9377/desktop` 注册，并使用独立 token。

### 3. 让桌面 pi 窗口上线

在需要同步的桌面 pi TUI 中执行：

```text
/reload
```

该窗口会成为一个 desktop source。存在多个 TUI 时，在 app 的“会话”页明确选择目标 source。

### 4. 手机连接

安装或运行 app：

```bash
flutter run
# APK: build/app/outputs/flutter-apk/app-debug.apk
```

设置页填写电脑的 LAN/Tailscale 地址、端口 `9377` 和 `PIPILOT_TOKEN`。连接后先选择 source，再点击“接管控制”；不接管时仍可实时观察。

同一 WiFi 下使用真实 LAN 地址，例如 `10.183.39.204`，不要使用 Docker bridge 地址。若 UFW 默认拒绝入站，需要按当前子网开放 9377：

```bash
sudo ufw allow from 10.183.39.0/24 to any port 9377 proto tcp
```

## 安全与会话完整性

- pi 拥有启动用户的完整文件与 shell 权限。不要把明文 `ws://` endpoint 暴露到公网；跨网络优先使用 Tailscale。
- 手机 token 与 desktop registration token 分离。desktop token 保存在 `bridge/config.json` 和 `~/.pi/agent/pipilot-sync.json`，权限均为 `0600`。
- Source Hub 每个 source 同时只允许一个 owner lease；客户端断开、lease 过期、source 重建都会释放控制权。
- desktop TUI 注册后，Hub 会先停止 headless，避免两个 pi 进程同时写同一会话。
- Headless 默认关闭，因为即使没有 prompt，启动带持久 session 的 pi 也可能追加 `session_info` 或扩展自有 custom entry。只有用户显式启动时才允许该写入。
- relay 快照只使用 `ReadonlySessionManager`；自动化测试只用 fake/in-memory source，不打开真实 session。

## 项目结构

```text
lib/
  core/pi_connection.dart        WebSocket 与握手
  core/settings_repository.dart  持久化设置
  state/hub_models.dart          source/cursor 模型
  state/pi_session.dart          Hub + Pi RPC reducer、lease、replay/snapshot
  ui/chat/                       对话、观察/控制状态
  ui/sessions/                   source 选择、会话与目录
  ui/settings/                   Hub/source、模型、行为、统计
bridge/
  src/server.ts                  Source Hub 路由
  src/source_registry.ts         source、epoch/seq、replay ring
  src/owner_lease.ts             owner lease 与 fencing
  src/pi_process.ts              headless RPC adapter
extension/
  src/index.ts                   pi TUI extension 入口
  src/relay.ts                   snapshot、事件合并、重连、远程命令
```

## 验证

```bash
flutter analyze
flutter test

cd bridge
npm run typecheck
npm test
npm audit --omit=dev

cd ../extension
npm run typecheck
npm test
npm audit --omit=dev
```

bridge integration test 使用临时端口和 fake desktop transport，并通过 `PIPILOT_HEADLESS_AUTO_START=false` 保证不会启动真实 pi。

## 当前边界

- 不镜像原始 terminal 屏幕，也不检测 OS 当前聚焦窗口。
- 不代理第三方 TUI extension 的 select/input/editor 弹窗。
- desktop relay 不接受任意 shell、文件路径、slash command、session switch/fork/reload。
- 图片附件、大输出分块、Markdown/代码高亮和 TLS 自动配置仍待后续版本。
