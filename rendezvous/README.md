# PiPilot Rendezvous

`rendezvous` 是 PiPilot P2P 连接的 WebSocket 信令服务。它只负责让 bridge host
和 Flutter guest 交换 SDP/ICE 信令；建立连接后，应用数据通过 WebRTC DataChannel
传输，不经过 rendezvous。

## 免预注册配对

服务端不维护设备表或设备白名单。bridge 使用设备名和配对 Key 动态创建内存房间，
手机提交相同的设备名和 Key 后加入房间。部署前无需在 rendezvous 配置中登记设备。

设备名规则：

- 长度为 3-64 个字符。
- 只允许英文字母、数字、点、下划线和连字符，即
  `^[A-Za-z0-9._-]{3,64}$`。

配对 Key 规则：

- 长度为 16-128 个可打印 ASCII 字符，即 `0x21` 到 `0x7e`。
- 小写字母、大写字母、数字和符号四类中至少包含三类。
- 不允许空格、换行、其它控制字符或非 ASCII 字符。

同一设备名同时只能由一个 host 占用，一个 host 可以接入多个手机。设备名按先到先得
分配；host 断开后房间立即删除，随后任何使用该设备名和任意合规 Key 的 host 都可以
重新创建房间。这是免预注册模式的安全边界，不是持久设备身份认证。

## 配置

需要 Node.js 运行环境。在本目录安装依赖并创建本地配置：

```bash
npm ci
cp config.example.json config.json
npm start
```

`config.json` 已被 Git 忽略。最小配置不包含任何 `devices` 字段：

```json
{
  "port": 9378,
  "host": "127.0.0.1",
  "stunUrls": [
    "stun:stun.example.com:3478"
  ],
  "turn": {
    "urls": [
      "turn:turn.example.com:3478?transport=udp"
    ],
    "secret": "replace-with-a-long-random-turn-rest-secret",
    "ttlSeconds": 600
  }
}
```

推荐只监听 `127.0.0.1`，由同机反向代理提供公网 TLS。以下环境变量可覆盖配置文件：

| 环境变量 | 对应配置 | 说明 |
|---|---|---|
| `PIPILOT_RDV_HOST` | `host` | 监听地址 |
| `PIPILOT_RDV_PORT` | `port` | 监听端口 |
| `PIPILOT_RDV_STUN_URLS` | `stunUrls` | 逗号分隔的 STUN URL |
| `PIPILOT_RDV_TURN_URLS` | `turn.urls` | 逗号分隔的 TURN URL |
| `PIPILOT_RDV_TURN_SECRET` | `turn.secret` | coturn TURN REST shared secret |
| `PIPILOT_RDV_TURN_TTL` | `turn.ttlSeconds` | 短期凭据有效期，限制为 60-3600 秒 |

`GET /health` 返回进程状态和当前房间数量。它不需要鉴权，不应直接暴露到不可信网络。

## WSS 反向代理

公网 App 和 bridge 必须使用经过有效证书认证的 `wss://`。客户端只允许回环地址使用
明文 `ws://`，用于本机开发。rendezvous 自身提供 HTTP/WebSocket，因此生产环境应由
Caddy、Nginx 等组件终止 TLS。

Nginx 示例：

```nginx
server {
    listen 443 ssl;
    server_name signal.example.com;

    ssl_certificate /etc/letsencrypt/live/signal.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/signal.example.com/privkey.pem;

    location /pipilot {
        proxy_pass http://127.0.0.1:9378;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 75s;
    }

    location = /health {
        allow 127.0.0.1;
        deny all;
        proxy_pass http://127.0.0.1:9378/health;
    }
}
```

对应的 App 和 bridge 信令地址为 `signal.example.com/pipilot`，两端会自动补成
`wss://signal.example.com/pipilot`。反向代理必须保留 WebSocket Upgrade。

## STUN 和 TURN

STUN 是可选的，只用于发现公网地址，不承载会话数据。困难 NAT 下需要独立部署
coturn，并将其 `static-auth-secret` 与 `turn.secret` 设为同一个高强度随机值。
rendezvous 在 host 或 guest 配对成功后按 TURN REST 规则签发短期用户名和凭据，
不会把 TURN shared secret 发给客户端。

TURN 的 UDP/TCP/TLS 监听端口和中继端口范围必须在防火墙中单独开放，它们不经过
上述 HTTP 反向代理。TURN 只能看到并转发 DTLS 加密后的 DataChannel 流量。配对 Key、
TURN shared secret 和 PiPilot Hub token 是三个不同的秘密，不应复用。

## 安全边界

- Key 在 WSS `hello` 帧中发送。rendezvous 只在房间内保存 Key 的 SHA-256 摘要，
  不写入磁盘或日志；但 rendezvous 进程和 TLS 终止方仍有能力读取原始 Key。
- WSS 防止链路上的被动窃听和篡改，不能防止信令服务运营者读取进程内数据。只在
  信任的主机上运行服务，并限制配置文件和运行日志的访问权限。
- 当前信令协议通过 WSS `hello` 发送 `secret`。App、bridge 和 rendezvous 必须同步
  升级，旧版客户端不兼容。
- 房间设备名不是长期所有权。host 下线后，另一 host 可以用相同设备名和不同合规 Key
  建立新房间；手机只应连接自己控制的信令服务并核对 bridge 配置。
- 配对 Key 只控制进入信令房间。DataChannel 建立后，bridge 仍使用独立的 Hub token
  鉴权手机访问权限。
