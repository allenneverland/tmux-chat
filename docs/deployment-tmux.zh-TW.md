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
printf '\a'
~/.local/bin/host-agent status --json
```

`push-server` metrics 的 `events_bell_total` 應增加。

## 6. 常見錯誤

- iOS onboarding 顯示 `tmux-chatd is not installed on remote host`
  - 先在主機安裝 `tmux-chatd` 再重試
- `host-agent pair` 失敗
  - pairing token 可能過期（預設 TTL 600 秒）
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
