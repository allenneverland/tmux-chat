# Reattach

[English](./README.md) | [繁體中文](./README.zh-TW.md)

**Reattach** 是一個 iOS 用的遠端 tmux 客戶端。  
你可以在任何地方控制 Mac/Linux 上的 tmux sessions，並在 tmux bell 或 coding-agent 事件發生時收到推播通知。

## Flag Day 遷移公告

此專案已遷移到「SSH onboarding + host-agent pairing」架構。

- QR onboarding 已移除。
- Cloudflare Access Service Token 相容模式已移除。
- Claude/Codex 的 `notify/hooks` 相容能力仍保留。

請參考公告：`docs/breaking-changes-flag-day-2026.md`。

## 架構

Reattach 現在由兩條互相配合的路徑組成：

1. 控制面（iOS -> reattachd -> tmux）
2. 通知面（tmux bell / agent hook -> host-agent 或 reattachd notify -> push-server -> APNs -> iOS）

```text
Control Plane
------------
iOS App --HTTPS--> reattachd --local--> tmux

Notification Plane
------------------
tmux alert-bell --> host-agent --> push-server --> APNs --> iOS
Claude/Codex hook --> reattachd notify --> push-server --> APNs --> iOS
```

## 元件

| 元件 | 說明 |
|-----------|-------------|
| `reattachd` | 提供 tmux 控制 API（`sessions` / `panes`）的 Rust daemon |
| `host-agent` | 主機端 relay agent，將 tmux bell 事件回報到 push-server |
| `push-server` | APNs 發送服務（pairing、裝置註冊、靜音規則、指標） |
| `ios/` | iOS App（SSH onboarding、遠端 tmux 控制、通知導頁） |
| `launchd/` | 主機服務的 launchd 範本 |
| `ops/observability/` | Prometheus 告警規則與 Grafana dashboard 範本 |

## 需求

- macOS 或 Linux 主機
- [tmux](https://github.com/tmux/tmux)
- 已開啟通知權限的 iOS 裝置
- iOS 裝置可透過 SSH 存取主機（網路路徑由使用者自行選擇：VPN、Tailscale、tunnel 等）

完整部署文件：
- `docs/deployment-three-systems.zh-TW.md`

## 快速開始

### 1. 在主機安裝 reattachd

方案 A：Homebrew（macOS）

```bash
brew tap allenneverland/reattach
brew install reattachd
brew services start reattachd
```

方案 B：安裝腳本（macOS / Linux）

```bash
curl -fsSL https://raw.githubusercontent.com/allenneverland/Reattach/main/install.sh | sh
```

### 2. 啟動 reattachd 服務

macOS（launchd 範例）：

```bash
mkdir -p ~/Library/Logs/Reattach
# create and load ~/Library/LaunchAgents/com.allenneverland.reattachd.plist
launchctl load ~/Library/LaunchAgents/com.allenneverland.reattachd.plist
```

Linux（systemd 範例）：

```bash
# create and enable /etc/systemd/system/reattachd.service
sudo systemctl daemon-reload
sudo systemctl enable --now reattachd
```

### 3. 選擇控制面 URL 的網路路徑

範例：

- 區域網路：`http://192.168.x.x:8787`
- VPN/Tailscale：`http://<private-ip>:8787`
- 含 TLS 的反向代理 / tunnel：`https://your-domain.example.com`

### 4. 在 iOS 透過 SSH onboarding 新增伺服器

在 iOS App 中：

1. 點選 `Add Server via SSH`。
2. 輸入控制面 URL（reattachd URL）。
3. 輸入 SSH 主機/使用者/port 與驗證資訊。
4. 繼續完成設定。

App 會自動：

- 驗證 SSH 連線
- 遠端安裝 `host-agent`
- 發放控制憑證（在主機執行 `reattachd devices issue --json`）
- 執行 push pairing 與 APNs 註冊
- 儲存伺服器設定並驗證 tmux API

### 5. 可選：安裝 coding-agent 通知 hooks

自動安裝：

```bash
reattachd hooks install
```

手動設定：

- Claude Code（`~/.claude/settings.json`）：
  - `hooks.Stop` matcher `""` command `reattachd notify`
  - `hooks.Notification` matcher `"permission_prompt"` command `reattachd notify`
- Codex（`~/.codex/config.toml`，top-level）：

```toml
notify = ["reattachd", "notify"]
```

## 進階：手動註冊裝置（疑難排解）

如果 SSH onboarding 暫時不可用，你可以先在主機手動發放憑證：

```bash
reattachd devices issue --name "<device-name>" --json
```

然後在 App 內使用以下資訊新增伺服器：

- `server_url`
- `device_id`
- `device_token`

## 開發

### 需求

- [Rust](https://rustup.rs/)
- Xcode（iOS 開發）
- Apple Developer 帳號（APNs 測試）

### Build

```bash
git clone https://github.com/allenneverland/Reattach.git
cd Reattach

cp config.local.mk.sample config.local.mk
cp ios/Reattach/Config.xcconfig.sample ios/Reattach/Config.xcconfig

make build
make install
make start
```

### 本機設定

`config.local.mk`：

```makefile
PUSH_SERVER_BASE_URL = http://127.0.0.1:8790
PUSH_SERVER_COMPAT_NOTIFY_TOKEN = CHANGE_ME
```

`ios/Reattach/Config.xcconfig`：

```xcconfig
BASE_URL = https:/$()/your-domain.example.com
PUSH_SERVER_BASE_URL = https://your-push-server.example.com
```

### 常用 Make targets

```bash
make build
make install
make uninstall
make start
make stop
make restart
make reinstall
make logs
make status
make install-hooks
make uninstall-hooks
```

### Docker 執行 push-server

一鍵部署（建議，機密寫在 env 檔）：

```bash
make push-server-env-init
# 執行互動精靈（會詢問並寫入 ops/deploy/push-server.env）
make push-server-deploy
make push-server-status
```

`ops/deploy/push-server.env` 已加入 `.gitignore`，可避免 APNs 金鑰出現在指令歷史。

其他 Docker 目標：

```bash
make push-server-docker-fmt
make push-server-docker-test
make push-server-docker-build
make push-server-docker-image
make push-server-docker-run
```

`push-server` 的機密環境變數（請放在 `ops/deploy/push-server.env`）：

```bash
APNS_KEY_BASE64=...
APNS_KEY_ID=...
APNS_TEAM_ID=...
APNS_BUNDLE_ID=...
PUSH_SERVER_COMPAT_NOTIFY_TOKEN=...
```

Metrics endpoints：

```bash
GET /metrics
GET /metrics.json
```

Observability 範本：

- `ops/observability/prometheus-alert-rules.yml`
- `ops/observability/grafana-dashboard-reattach-slo.json`

## 安全注意事項

- Reattach 可進行遠端命令執行，請謹慎部署。
- `reattachd` 預設綁定 `127.0.0.1:8787`。
- 所有控制 API 皆需 Bearer Token。
- 建議使用 HTTPS 或私有網路傳輸。
- 可透過以下指令輪替/撤銷未使用裝置：

```bash
reattachd devices list
reattachd devices revoke <device-id>
```

## Breaking Changes 參考

- `docs/breaking-changes-flag-day-2026.md`
- `plans/phase0/breaking-changes-lock.md`

## 授權

MIT
