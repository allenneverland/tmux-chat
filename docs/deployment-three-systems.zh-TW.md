# Reattach 三系統完整部署指南（繁體中文）

本文件提供 Reattach Flag Day 架構下的完整部署流程，涵蓋三個核心系統：

1. `push-server`（通知中樞，負責 APNs）
2. `reattachd`（tmux 控制面 API）
3. `host-agent`（主機端 bell relay）

適用版本：2026-03-03 後的 SSH onboarding 架構。

## 1. 架構與責任

```text
控制面：
iOS App --HTTPS--> reattachd --local--> tmux

通知面：
tmux alert-bell --> host-agent --> push-server --> APNs --> iOS
Claude/Codex hook --> reattachd notify --> push-server --> APNs --> iOS
```

元件責任：

- `push-server`：提供 pairing、device register、event ingest、mute API，並與 APNs 溝通。
- `reattachd`：提供 sessions/panes 控制 API，並保留 `/notify` 相容入口轉送到 `push-server`。
- `host-agent`：安裝 tmux `alert-bell` hook，將 bell 事件 best-effort 上報到 `push-server`。

## 2. 先決條件

部署前請先準備：

- 一台可連網主機（macOS 或 Linux）運行 `reattachd` + `host-agent` + tmux。
- 一個可對外服務的 `push-server` 位址（建議 HTTPS）。
- APNs 憑證資訊（僅放在 `push-server`）：
  - `APNS_KEY_BASE64`
  - `APNS_KEY_ID`
  - `APNS_TEAM_ID`
  - `APNS_BUNDLE_ID`
- 一組 `PUSH_SERVER_COMPAT_NOTIFY_TOKEN`（供 `reattachd /notify` 相容轉送使用）。

`.p8` 轉 base64（單行）範例：

```bash
base64 < AuthKey_XXXXXX.p8 | tr -d '\n'
```

## 3. 部署順序（建議）

依序部署：

1. `push-server`
2. `reattachd`
3. `host-agent`（通常由 iOS SSH onboarding 自動安裝）

此順序也與 rollout runbook 一致：`plans/phase0/rollout-rollback-runbook.md`。

## 4. 部署 push-server

### 4.1 使用 Docker（建議）

初始化本機 env 檔（只需第一次）：

```bash
make push-server-env-init
```

編輯 `ops/deploy/push-server.env`，填入：

```bash
PUSH_SERVER_PUBLIC_BASE_URL=...
PUSH_SERVER_COMPAT_NOTIFY_TOKEN=...
APNS_KEY_BASE64=...
APNS_KEY_ID=...
APNS_TEAM_ID=...
APNS_BUNDLE_ID=...
```

一鍵部署（不需把 APNs key 寫在指令列）：

```bash
make push-server-deploy
```

`make push-server-deploy` 會啟動互動式精靈，依序詢問並寫入 `ops/deploy/push-server.env`。

常用操作：

```bash
make push-server-status
make push-server-logs
make push-server-stop
```

### 4.2 Binary 直接執行（替代）

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

### 4.3 push-server 健康檢查

```bash
curl -fsS http://127.0.0.1:8790/healthz
curl -fsS http://127.0.0.1:8790/metrics | head
curl -fsS http://127.0.0.1:8790/metrics.json | head
```

## 5. 部署 reattachd

### 5.1 安裝

Homebrew（macOS）：

```bash
brew tap allenneverland/reattach
brew install reattachd
```

或 install script（macOS/Linux）：

```bash
curl -fsSL https://raw.githubusercontent.com/allenneverland/Reattach/main/install.sh | sh
```

### 5.2 macOS（launchd）快速部署

使用 repo 內 Makefile（會套入 push forwarding 變數）：

```bash
cp config.local.mk.sample config.local.mk
```

編輯 `config.local.mk`：

```makefile
PUSH_SERVER_BASE_URL = https://push.example.com
PUSH_SERVER_COMPAT_NOTIFY_TOKEN = CHANGE_ME_STRONG_TOKEN
```

部署：

```bash
make build
make install
make start
```

### 5.3 Linux（systemd）部署範例

建立 `/etc/systemd/system/reattachd.service`：

```ini
[Unit]
Description=Reattach daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/reattachd
Restart=always
RestartSec=3
Environment=REATTACHD_BIND_ADDR=0.0.0.0
Environment=REATTACHD_PORT=8787
Environment=PUSH_SERVER_BASE_URL=https://push.example.com
Environment=PUSH_SERVER_COMPAT_NOTIFY_TOKEN=CHANGE_ME_STRONG_TOKEN

[Install]
WantedBy=multi-user.target
```

啟動：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now reattachd
sudo systemctl status reattachd --no-pager
```

## 6. 部署 host-agent

### 6.1 推薦：由 iOS SSH onboarding 自動安裝

iOS App 內執行 `Add Server via SSH` 時，會自動：

- 安裝 `host-agent`
- 呼叫 pairing 流程
- 完成 APNs device register
- 儲存 server 設定

### 6.2 手動部署（進階）

從原始碼 build 並安裝：

```bash
cargo build --release -p host-agent
install -m 755 ./target/release/host-agent ~/.local/bin/host-agent
```

安裝 tmux hook + 常駐服務：

```bash
~/.local/bin/host-agent install --push-server-base-url https://push.example.com
```

配對（需要 pairing token）：

```bash
~/.local/bin/host-agent pair \
  --token '<pairing_token>' \
  --push-server-base-url 'https://push.example.com' \
  --json
```

檢查狀態：

```bash
~/.local/bin/host-agent status --json
```

## 7. iOS 端設定

若為本地 Xcode build，設定：

檔案：`ios/Reattach/Config.xcconfig`

```xcconfig
BASE_URL = https://your-reattachd.example.com
PUSH_SERVER_BASE_URL = https://your-push-server.example.com
```

在 App 中執行 `Add Server via SSH`，完成 onboarding。

## 8. 一次性端到端驗證（Smoke Test）

### 8.1 驗證控制面認證

不帶 token 應為 401：

```bash
curl -i http://<reattachd-host>:8787/sessions
```

發 token：

```bash
reattachd devices issue --name "deploy-check" --json
```

帶 token 應成功：

```bash
curl -i \
  -H "Authorization: Bearer <device_token>" \
  http://<reattachd-host>:8787/sessions
```

### 8.2 驗證 `notify` 相容轉送

```bash
curl -i \
  -X POST http://<reattachd-host>:8787/notify \
  -H 'Content-Type: application/json' \
  -d '{"title":"deploy-test","body":"notify-forward-check","pane_target":"dev:0.0"}'
```

成功後確認 `push-server` 指標有變化：

- `events_agent_total`
- `apns_sent_total` 或 `apns_failed_total`

### 8.3 驗證 tmux bell 路徑

在 tmux pane 內觸發 bell（例如 `printf '\a'`），確認：

- `host-agent status --json` 顯示 hook active
- `push-server` 的 `events_bell_total` 增加

## 9. 觀測與告警

指標端點：

- `GET /metrics`
- `GET /metrics.json`

SLO 相關範本：

- `ops/observability/prometheus-alert-rules.yml`
- `ops/observability/grafana-dashboard-reattach-slo.json`

Flag Day 48h 檢查清單：

- `plans/phase8/observation-48h-checklist.md`

## 10. 常見錯誤與排查

- `POST /notify` 回 502：通常是 `PUSH_SERVER_BASE_URL` 或 `PUSH_SERVER_COMPAT_NOTIFY_TOKEN` 設定錯誤。
- `host-agent pair` 失敗：檢查 pairing token 是否過期（預設 TTL 600 秒）。
- `APNs not configured`：`push-server` 缺少 APNs 環境變數。
- iOS 點通知無法導頁：確認 payload 含 `deviceId + paneTarget`，且該 pane 仍存在。

## 11. 安全基線

- 控制 API 一律使用 Bearer Token（無 open mode）。
- 對外服務建議走 HTTPS / private network。
- `.p8` 僅存於 `push-server`，不要放在主機或 iOS 客戶端。
- 定期清理不用的控制 token：

```bash
reattachd devices list
reattachd devices revoke <device-id>
```
