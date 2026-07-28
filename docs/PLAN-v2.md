# PiPilot v2 规划

> 目标:把 MVP(单页对话 + 暗色 + 强制连接)升级为**可日常使用的 pi 移动客户端**:
> 先进 app 后配置、分页导航、Material Design、全配置持久化、会话管理(切换/读取)、按目录组织。

---

## 一、需求 → 方案映射

| 需求 | 方案 |
|---|---|
| 不要"先填连接才能进" | 去掉门控路由,app 直接进主框架;连接信息挪到设置页;有已存配置则启动自动连接,无配置显示空态引导 |
| app 分页 | `NavigationBar`(MD3 底部导航)三个页面:**对话 / 会话 / 设置** |
| 不要暗色调,用 Material Design | Material 3 主题,`ColorScheme.fromSeed`,**浅色为默认**,可选"跟随系统/深色";删除所有硬编码色值(0xFF0F1115 等),组件全面换成 M3 标准件 |
| 配置持久化 | 新增 `SettingsRepository`(SharedPreferences 封装),统一读写:连接、主题、模型偏好、每会话游标、最近目录/会话 |
| 切换会话 | 会话页列出会话 → 点击调用 RPC `switch_session {sessionPath}`;对话中禁止切换(先 abort) |
| 读取会话 | 进入会话时 `get_entries` 全量加载渲染(现有 reducer 已支持);历史会话只读预览 |
| 分目录处理 | 会话页按**工作目录**分组展示(pi 会话存储天然按 cwd 分目录);切换目录 = bridge 重启 pi 子进程到新 cwd |

---

## 二、已核实的技术前提

1. **会话存储布局**(实测):`~/.pi/agent/sessions/--编码cwd--/*.jsonl`
   - 目录名 = cwd 把 `/` 换成 `-`(如 `--home-sisct-Code-projects-FlutterProjects-PiPilot--`)
   - 文件名 = `时间戳_会话UUID.jsonl`
   - 首行元数据:`{"type":"session","id":...,"timestamp":...,"cwd":...}`;第二行 `session_info` 含 `name`
   - 解析成本极低:读前 2 行即可得到 id/cwd/name/时间,不需要全量解析
2. **RPC 命令**(rpc.md 确认):
   - `new_session`(可选 `parentSession`)→ 返回 `{cancelled}`
   - `switch_session {sessionPath}` → 返回 `{cancelled}`,可被扩展取消
   - `fork` / `clone` / `get_tree` / `get_entries {since}` 均可用
3. **关键限制**:
   - pi RPC **没有 list_sessions 命令** → 会话列表必须由 bridge 扫文件系统实现
   - pi RPC **没有 set_cwd** → 换工作目录必须重启 pi 子进程(几秒中断,期间 UI 显示"切换中")
   - 单 pi 进程架构下,切换目录/会话时需先 abort 运行中的任务

---

## 三、架构设计

### 3.1 App 结构(Flutter)

```
lib/
├── main.dart                    # ProviderScope + MD3 主题 + MainShell(不再有门控)
├── core/
│   ├── pi_connection.dart       # (现有,不动)WS 客户端
│   └── settings_repository.dart # 新增:SharedPreferences 统一持久化层
├── state/
│   ├── settings_provider.dart   # 新增:连接/主题/模型等设置 Notifier,改动即落盘
│   └── pi_session.dart          # 改造:事件 reducer 保留;连接参数改从 settings 读;
│                                #      去掉 hasSession 门控,暴露 connectionStatus
└── ui/
    ├── main_shell.dart          # 新增:Scaffold + NavigationBar + 3 页切换(IndexedStack 保活)
    ├── chat/
    │   ├── chat_screen.dart     # 改造:未连接空态(“去设置连接”按钮);顶栏显示 目录/会话名
    │   └── widgets/...          # 现有组件,M3 化(卡片/气泡颜色走 ColorScheme)
    ├── sessions/
    │   ├── sessions_screen.dart # 新增:目录分组列表 → 目录内会话列表(ExpansionTile 或二级页)
    │   └── session_actions.dart # 新增:新建会话 / 切换 / fork / 重命名
    └── settings/
        └── settings_screen.dart # 新增:见 3.4
```

### 3.2 页面与导航

- **MainShell**:`IndexedStack` 保活三页,`NavigationBar` 切换。
- **对话页**(默认页):现有聊天 UI;顶栏副标题 = `目录名 · 会话名 · 模型`;未连接时 body 显示空态插画 + "前往设置"按钮;断线自动重连逻辑保留。
- **会话页**:两级结构——目录行(显示 cwd、会话数、最近活跃时间)展开后是目录内会话列表(名称、时间、消息数);点击会话执行切换;右上角"新建会话"。
- **设置页**:分组列表(见 3.4)。

### 3.3 Bridge 扩展(bridge v2)

pi RPC 不够用,新增 **bridge 自有命令**(type 前缀 `bridge_`,与 pi 透传区分):

| 命令 | 说明 |
|---|---|
| `bridge_list_dirs` | 扫描 `~/.pi/agent/sessions/`,返回目录列表:`[{cwd, dirName, sessionCount, lastActive}]` |
| `bridge_list_sessions {cwd}` | 读该目录所有 .jsonl 的前 2 行,返回:`[{path, id, name, timestamp, sizeBytes}]` |
| `bridge_switch_dir {cwd, sessionPath?}` | 优雅停掉当前 pi → 以新 cwd(及可选固定会话)重启 → 广播 `bridge_dir_switched` |
| `bridge_get_config` / `bridge_set_config` | bridge 端配置读写(token、默认 cwd 等),落盘 `bridge/config.json` |

其他改动:
- token 从"每次随机"改为**首次生成后写入 config.json 复用**(持久化要求;仍可 env 覆盖)
- 去掉"固定 session-id 文件"的单一绑定,改为 pi_process 支持重启时换 cwd/session 参数
- ~~单进程架构保持不变~~;**多 pi 进程池已在 v3 交付**(`bridge/src/pi_pool.ts`)

### 3.4 设置页内容

1. **连接**:主机/端口/token、"测试连接"按钮(调 `/health` + 握手)、状态指示
2. **外观**:主题模式(浅色/深色/跟随系统)
3. **模型**:模型下拉(`get_available_models`)、思考档位下拉;改动即时生效(`set_model` 等)并持久化为默认
4. **行为**:auto-compaction、auto-retry 开关(`set_auto_compaction` 等)
5. **当前会话**:目录、会话名、token 用量(`get_session_stats`)、"导出 HTML"(`export_html`)
6. **关于**:bridge 版本、pi 版本、协议说明

### 3.5 持久化设计(SettingsRepository)

| 键 | 内容 |
|---|---|
| `conn.host` / `conn.port` / `conn.token` | 连接配置 |
| `ui.themeMode` | 主题模式 |
| `pi.modelId` / `pi.thinkingLevel` | 启动后期望的模型/档位(连接后自动应用) |
| `sess.leafId:<sessionId>` | (现有)每会话增量同步游标 |
| `sess.lastCwd` / `sess.lastSessionPath` | 最近使用的目录与会话,启动自动恢复 |
| `ui.sessionsExpanded` 等 | 会话页展开状态等 UI 偏好 |

所有 provider 启动时从 repository hydrate;任何设置改动立即写盘。

---

## 四、实施阶段(每阶段可独立验证)

### P1 — 主题 + 骨架重构(app 纯前端,不动 bridge)
1. MD3 主题(light 默认 / system / dark),清除硬编码色
2. MainShell + NavigationBar 三分页(会话/设置先占位)
3. 去门控:直接进 app;对话页未连接空态
4. 连接表单迁入设置页
✅ 验证:analyze + test + 真机截图三页可切换

### P2 — 持久化层
1. SettingsRepository + settings provider
2. 连接/主题/模型偏好落盘;启动自动连接 + 恢复上次目录/会话
✅ 验证:杀 app 重开,配置全保留、自动重连

### P3 — bridge 会话能力
1. `bridge_list_dirs` / `bridge_list_sessions`(读文件头)
2. token 持久化 config.json
3. `bridge_switch_dir`(pi 进程重启换 cwd)
✅ 验证:node 测试客户端脚本跑通三个新命令

### P4 — 会话页
1. 目录分组 + 会话列表 UI
2. 切换会话(switch_session)/ 新建(new_session)/ fork
3. 切换目录(bridge_switch_dir,带"切换中"loading)
4. 历史会话读取渲染(现有 reducer 复用)
✅ 验证:真机切换两个不同目录的会话,消息正确加载

### P5 — 设置页补全
1. 模型/思考档位切换、auto-compact 等开关
2. session stats 展示、export_html
✅ 验证:全功能回归

---

## 五、风险与决策

| 风险/决策 | 结论 |
|---|---|
| 换目录必须重启 pi(几秒中断) | 接受;UI 上运行中禁止切换,切换时显示进度 |
| 会话文件格式解析 | 只读前 2 行元数据,不做全量解析,格式变更风险可控 |
| 单进程 vs 多进程池 | 本期单进程 + 快速切换;多目录并行明确归 v3 |
| 会话数多的目录(如 `~` 下 21 个) | 列表按时间倒序 + 分页/搜索留 v3,本期全量列表 |
| 暗色用户已有偏好 | 浅色默认,但保留深色选项(跟随系统) |

## 六、明确不做(v3 候选)

> **状态更新(v3 已交付)**:下面前四项已经做完 —— 进程池见 `bridge/src/pi_pool.ts`,
> 扩展 UI 回写见 `ui_request_card.dart`,高亮/diff 见 `code_block.dart`/`diff_view.dart`,
> 会话搜索与会话树见 `sessions_sheet.dart`/`session_tree_sheet.dart`。
> 本文件保留为 v2 的历史记录,新规划见根目录的 v3 计划。

- ~~多 pi 进程池 / 多目录并行~~ → v3 已交付
- ~~扩展 UI 交互回写(select/confirm/input 弹窗)~~ → v3 已交付
- ~~Markdown/代码高亮渲染~~ → v3 已交付(图片附件仍未做)
- ~~会话搜索、会话树可视化~~ → v3 已交付
- Tailscale 自动发现、TLS
