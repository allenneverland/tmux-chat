# tmux 部署指南（繁體中文）

本文件涵蓋主機端 `tmux` 系統部署。  
此系統內含兩個元件：

- `tmux-chatd`：控制面 API（`/sessions`、`/panes/*`、`devices issue/revoke`）
- `host-agent`：通知 relay（tmux bell -> push-server）

## 1. 前置條件

- `push-server` 已部署可用（參考 `docs/deployment-push-server.zh-TW.md`）
- 主機已安裝 `tmux`
- iOS 裝置可透過 SSH 連到主機

## 2. 推薦路徑：iOS SSH onboarding

建議流程：

1. 在主機先安裝並啟動 `tmux-chatd`
2. 在 iOS App 內使用 `Add Server via SSH`

SSH onboarding 會自動：

- 檢查 `tmux-chatd` 是否存在
- 遠端安裝 `host-agent`
- 執行 push pairing 與 APNs 註冊
- 發放控制憑證並驗證 tmux API

## 3. 安裝與啟動 tmux-chatd

Homebrew（macOS）：

```bash
brew tap allenneverland/tmux-chat
brew install tmux-chatd
```

install script（macOS/Linux）：

```bash
curl -fsSL https://raw.githubusercontent.com/allenneverland/tmux-chat/main/install.sh | sh
```

macOS（launchd）啟動：

```bash
cp config.local.mk.sample config.local.mk
make build
make install
make start
make status
```

`config.local.mk` 最小建議：

```makefile
PUSH_SERVER_BASE_URL = http://127.0.0.1:8790
PUSH_SERVER_COMPAT_NOTIFY_TOKEN = CHANGE_ME_STRONG_TOKEN
```

Linux（systemd）可參考：

```ini
[Service]
ExecStart=/usr/local/bin/tmux-chatd
Environment=PUSH_SERVER_BASE_URL=http://127.0.0.1:8790
Environment=PUSH_SERVER_COMPAT_NOTIFY_TOKEN=CHANGE_ME_STRONG_TOKEN
```

## 4. 手動安裝 host-agent（進階）

若你不走 SSH onboarding，可手動：

```bash
cargo build --release -p host-agent
install -m 755 ./target/release/host-agent ~/.local/bin/host-agent
~/.local/bin/host-agent install --push-server-base-url https://push.example.com
~/.local/bin/host-agent pair --token '<pairing_token>' --push-server-base-url 'https://push.example.com' --json
~/.local/bin/host-agent status --json
```

## 5. 驗證

`tmux-chatd` 控制面：

```bash
curl -i http://127.0.0.1:8787/sessions
tmux-chatd devices issue --name "deploy-check" --json
curl -i -H "Authorization: Bearer <device_token>" http://127.0.0.1:8787/sessions
```

bell 通知路徑：

```bash
~/.local/bin/host-agent status --json
sleep 4 && true
```

先確認 `host-agent status --json` 內：

- `notification_ready` 為 `true`
- `readiness_errors` 為空陣列

`push-server` metrics 的 `events_bell_total` 應增加。
說明：`printf '\a'` 可能只觸發終端鈴聲，不一定會觸發 tmux `alert-bell` hook。

## 6. 常見錯誤

- iOS onboarding 顯示 `tmux-chatd is not installed on remote host`
  - 先在主機安裝 `tmux-chatd` 再重試
- `host-agent pair` 失敗
  - pairing token 可能過期（預設 TTL 600 秒）
- `host-agent status --json` 顯示 `notification_ready=false`
  - 先看 `readiness_errors` 欄位
  - Linux 常見是 `service_not_active`，用 `systemctl --user status tmux-chat-host-agent.service --no-pager -n 50` 排查
- `/notify` 502
  - `PUSH_SERVER_BASE_URL` 或 `PUSH_SERVER_COMPAT_NOTIFY_TOKEN` 設定錯誤

## 7. 安全建議

- 控制 API 一律使用 Bearer token
- 優先使用 HTTPS 或私有網路（如 Tailscale）
- 定期清理不用的裝置憑證：

```bash
tmux-chatd devices list
tmux-chatd devices revoke <device-id>
```

## 8. tmux-chatd 發布流程（GitHub Release）

當你修改了 `tmux-chatd` 或 `host-agent`，且希望：

- iOS onboarding 的「一鍵安裝」抓到新版本
- GitHub Release 產生新的 Linux/macOS tar.gz 資產

就必須跑一次正式發版（tag + release workflow）。

### 8.1 發版前檢查

在本機確認以下項目：

```bash
git status
```

- 工作樹乾淨（避免把半成品一起發布）
- 主要變更已合併到要發版的分支（通常 `master`）

建議至少跑：

```bash
xcodebuild -project ios/TmuxChat.xcodeproj -scheme TmuxChat -destination 'generic/platform=iOS Simulator' build
```

（如本機有 Rust 環境，也建議跑 `cargo build -p tmux-chatd -p host-agent`）

### 8.2 建立版本 tag

本專案 `release.yml` 會在 `v*` tag 被 push 時觸發。

```bash
git tag v1.0.6
git push origin v1.0.6
```

### 8.2.1 同步更新 iOS 固定 host-agent 版本（必要）

iOS onboarding 會固定下載 `HostAgentReleaseTag` 指定的 host-agent，不再使用 `latest`。
每次發 host-agent 新版時，必須同步更新：

- `ios/TmuxChat/Info.plist` 的 `HostAgentReleaseTag`（例如 `v1.0.19`）
- `ios/TmuxChat/Info.plist` 的 `HostAgentRequiredStatusSchemaVersion`（目前為 `3`）

若 host-agent `status --json` 契約有破壞性調整，先提升 `status_schema_version`，再更新 iOS 的 required schema，最後才發佈 App。

### 8.3 Workflow 自動做的事

`.github/workflows/release.yml` 會：

1. 交叉編譯 `tmux-chatd`、`host-agent`
2. 打包並上傳 tar.gz 資產到 GitHub Release
3. 若有設定 `HOMEBREW_TAP_TOKEN`，自動更新 Homebrew tap Formula

目前輸出資產（5 組 target）：

- `tmux-chatd-linux-x86_64-gnu.tar.gz`
- `tmux-chatd-linux-aarch64-gnu.tar.gz`
- `tmux-chatd-linux-x86_64-musl.tar.gz`
- `tmux-chatd-darwin-x86_64.tar.gz`
- `tmux-chatd-darwin-aarch64.tar.gz`

以及對應的 `host-agent-*.tar.gz`。

### 8.4 發版後檢查（必要）

1. 到 GitHub Releases 確認該 tag 的資產完整存在。  
2. 在主機驗證新 API（本版 iOS 依賴）：

```bash
curl -i http://127.0.0.1:8787/healthz
curl -i http://127.0.0.1:8787/capabilities
curl -i -H "Authorization: Bearer <device_token>" http://127.0.0.1:8787/diagnostics
curl -s http://127.0.0.1:8787/capabilities | jq '{schema: .capabilities_schema_version, input_events_enabled: .features.input_events_v1.enabled, pane_input_events: .endpoints.pane_input_events, max_batch: .features.input_events_v1.max_batch, supports_repeat: .features.input_events_v1.supports_repeat}'
curl -i -X POST \
  -H "Authorization: Bearer <device_token>" \
  "http://127.0.0.1:8787/panes/input-probe/input-events?probe=true"
curl -i -X POST \
  -H "Authorization: Bearer <device_token>" \
  -H "Content-Type: application/json" \
  "http://127.0.0.1:8787/panes/input-probe/key?probe=true" \
  -d '{"key":"Enter"}'

# 或使用 Makefile 一次檢查（需 jq）
make control-plane-smoke \
  CONTROL_PLANE_BASE_URL=http://127.0.0.1:8787 \
  CONTROL_PLANE_TOKEN=<device_token>
```

3. iOS 端重新執行 `Reconnect & Re-pair`，確認：
   - 不再出現 `Server Upgrade Required`
   - sessions 可正常列出
   - `New Session` 可成功建立

> 目前 onboarding 會做 **雙驗證**：
> 1) SSH 主機 loopback（`127.0.0.1:8787`）必須通過 schema/probe 契約  
> 2) iOS 填入的外部 Control URL 也必須通過同一契約  
> 任一失敗都會中止，不會寫入半完成 server 設定。

### 8.5 常見失敗與處理

- **Release workflow 成功，但 iOS 仍抓舊版**
  - 檢查 iOS 是連到哪台主機、哪個 `tmux-chatd` binary（systemd/launchd 可能還在舊路徑）
- **找不到對應 Linux asset**
  - 檢查 Release 是否真的有 `tmux-chatd-linux-x86_64-gnu.tar.gz` 或 `...-musl.tar.gz`
- **onboarding 顯示 tmux-chatd latest 安裝失敗**
  - 現在策略是「安裝失敗即硬失敗」，不再沿用舊 binary 繼續
  - 先修復主機下載/發版資產問題，再重新 onboarding
- **`/capabilities` 或 `/diagnostics` 是 404，或 schema < 5**
  - 代表主機仍在跑舊版 `tmux-chatd`，需升級並重啟服務（iOS 現在要求 schema v5 + `pane_input_events`）
- **loopback 驗證成功，但外部 Control URL 驗證失敗**
  - 代表主機本機 daemon 正常，但反向代理/tunnel 指到錯主機或漏掉路由規則
  - 優先檢查 method+path 規則是否允許 `GET /capabilities`、`GET /diagnostics`、`POST /panes/*/input-events?probe=true`
- **`/capabilities` 顯示 `input_events_v1.enabled=true`，但 iOS 按快捷鍵仍失敗**
  - 優先檢查反向代理或 tunnel 是否放行 `POST /panes/*/input-events`
  - 確認 iOS `BASE_URL` 指向與 CLI 測試相同的主機/埠
  - 檢查服務實際執行的 binary 路徑（可能仍指向舊檔）
- **`POST /panes/input-probe/input-events?probe=true` 不是 204**
  - 代表 input-events 路由未完整通過反向代理 / tunnel，請檢查 method+path 規則是否允許 `POST /panes/*/input-events`
- **`POST /panes/input-probe/key?probe=true` 不是 410**
  - 新版 daemon 對舊快捷鍵路由預期回 `410 Gone`（`shortcut_contract_removed`）；若不是 410，通常是代理規則或路由指向錯誤
