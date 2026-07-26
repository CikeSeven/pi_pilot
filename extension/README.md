# PiPilot Desktop Relay

这是 PiPilot Source Hub 的桌面 TUI 适配器。它将当前 pi TUI 已加载的会话快照和实时事件发送到本机 bridge，并接受经过 owner lease 与 fencing token 校验的少量远程命令。

## 安全边界

- 只在 pi 的 `tui` 模式启动；不会在 `rpc`、`print` 或 `json` 模式注册。
- 快照只调用 `ReadonlySessionManager` 的读取 API，不写会话文件。
- 远程命令白名单只有 `prompt`、`abort`、`set_model`、`set_thinking_level`。
- 不支持任意 shell、文件路径、slash command、会话切换、fork、reload 或第三方扩展弹窗。
- bridge 注册连接仅允许 loopback，并使用独立于手机 token 的 desktop token。
- 每次 session start/reload/new/resume/fork 都生成新 epoch；旧 runtime、旧 epoch 和旧 fence 会被拒绝。

## 安装

在项目根目录执行：

```bash
cd bridge
npm run install:extension
```

安装器会：

1. 备份 `~/.pi/agent/settings.json`。
2. 在 `bridge/config.json` 生成并保存 desktop token。
3. 写入权限为 `0600` 的 `~/.pi/agent/pipilot-sync.json`。
4. 用 `pi install <本地 extension 目录>` 注册此 package。

安装不会打开或修改 `~/.pi/agent/sessions` 下的任何 JSONL。安装后，在需要同步的桌面 pi TUI 中执行 `/reload`；其他窗口不会自动成为当前 source。

## 配置

默认配置文件：`~/.pi/agent/pipilot-sync.json`

```json
{
  "url": "ws://127.0.0.1:9377/desktop",
  "token": "独立 desktop token"
}
```

也可使用环境变量覆盖：

- `PIPILOT_HUB_URL`
- `PIPILOT_DESKTOP_TOKEN`
- `PIPILOT_DESKTOP_LABEL`

relay 强制使用 loopback 主机。手机仍通过 bridge 的 LAN/Tailscale 地址连接。

## 开发验证

```bash
npm run typecheck
npm test
```

测试使用 fake context 与临时 loopback WebSocket，不创建或打开真实 session。
