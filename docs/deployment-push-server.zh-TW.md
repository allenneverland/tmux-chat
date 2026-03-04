# push-server 部署指南（繁體中文）

本文件只涵蓋 `push-server` 的部署與驗證。

## 1. 元件責任

`push-server` 負責：

- pairing (`/v1/pairings/start`, `/v1/pairings/complete`)
- APNs 裝置註冊 (`/v1/devices/register`)
- 事件接收 (`/v1/events/bell`, `/v1/events/agent`)
- 通知靜音與 metrics API

## 2. 先決條件

- 可執行 Docker 的主機（建議）
- APNs 憑證：
  - `APNS_KEY_BASE64`
  - `APNS_KEY_ID`
  - `APNS_TEAM_ID`
  - `APNS_BUNDLE_ID`
- 一組 `PUSH_SERVER_COMPAT_NOTIFY_TOKEN`（給 `tmux-chatd /notify` 相容轉送）
- 一個 iOS 與 host-agent 都可達的 URL 作為 `PUSH_SERVER_PUBLIC_BASE_URL`

`.p8` 轉 base64（單行）範例：

```bash
base64 < AuthKey_XXXXXX.p8 | tr -d '\n'
```

## 3. 一鍵部署（Docker，建議）

初始化 env 檔（第一次）：

```bash
make push-server-env-init
```

互動部署（會詢問並寫入 `ops/deploy/push-server.env`）：

```bash
make push-server-deploy
```

資料目錄預設（rootless）：

- `~/.local/share/tmux-chat/push-server`
- 若有設定 `XDG_DATA_HOME`，則為 `$XDG_DATA_HOME/tmux-chat/push-server`

若你要固定系統級路徑，可顯式指定：

```bash
PUSH_SERVER_HOST_DATA_DIR=/var/lib/tmux-chat/push-server make push-server-deploy
```

常用操作：

```bash
make push-server-status
make push-server-logs
make push-server-stop
```

## 4. `ops/deploy/push-server.env` 最小範例

```bash
PUSH_SERVER_PUBLIC_BASE_URL=https://push.example.com
PUSH_SERVER_COMPAT_NOTIFY_TOKEN=CHANGE_ME_STRONG_TOKEN
APNS_KEY_BASE64=REPLACE_WITH_BASE64_P8_CONTENT
APNS_KEY_ID=REPLACE_WITH_KEY_ID
APNS_TEAM_ID=REPLACE_WITH_TEAM_ID
APNS_BUNDLE_ID=REPLACE_WITH_APP_BUNDLE_ID
```

Tailscale-only 常見值：

```bash
PUSH_SERVER_PUBLIC_BASE_URL=https://<your-host>.ts.net:8790
```

## 5. Binary 直接執行（替代）

```bash
cargo build --release -p push-server

APNS_KEY_BASE64='...' \
APNS_KEY_ID='...' \
APNS_TEAM_ID='...' \
APNS_BUNDLE_ID='...' \
PUSH_SERVER_COMPAT_NOTIFY_TOKEN='CHANGE_ME_STRONG_TOKEN' \
PUSH_SERVER_PUBLIC_BASE_URL='https://push.example.com' \
./target/release/push-server --bind-addr 0.0.0.0 --port 8790
```

## 6. 健康檢查

```bash
curl -fsS http://127.0.0.1:8790/healthz
curl -fsS http://127.0.0.1:8790/metrics | head
curl -fsS http://127.0.0.1:8790/metrics.json | head
```

## 7. 常見錯誤

- `APNs not configured`
  - 代表 APNs 環境變數缺漏或空值。
- `/notify` 轉送回 502
  - 常見是 `PUSH_SERVER_COMPAT_NOTIFY_TOKEN` 與 `tmux-chatd` 端不一致。
- `host-agent pair` 回傳 ingest URL 不可達
  - 檢查 `PUSH_SERVER_PUBLIC_BASE_URL` 是否為 host-agent 可連到的 URL。
- `mkdir: cannot create directory '/var/lib/tmux-chat': Permission denied`
  - 代表你在非 root 權限使用系統級路徑。新版預設會改用 rootless 路徑。
  - 若你有既有 `/var/lib/tmux-chat/push-server` 資料但不可寫，部署會安全中止避免資料分裂；請先搬移資料後指定 `PUSH_SERVER_HOST_DATA_DIR` 再部署。

## 8. 安全建議

- `.p8` 僅放在 `push-server` 主機，不放在 iOS/其他主機。
- `push-server.env` 不提交版本控制（已 gitignore）。
- 對外入口建議 HTTPS 或私有網路（如 Tailscale）。
