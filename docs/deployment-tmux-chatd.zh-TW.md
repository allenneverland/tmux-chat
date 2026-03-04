# tmux-chatd 部署指南（繁體中文）

本文件只涵蓋 `tmux-chatd` 的部署與驗證。

## 1. 元件責任

`tmux-chatd` 負責：

- tmux 控制 API（`/sessions`, `/panes/*`）
- 裝置憑證發放/撤銷（`tmux-chatd devices ...`）
- `/notify` 相容入口，轉送事件到 `push-server`

## 2. 前置依賴

- 主機已安裝 `tmux`
- `push-server` 已部署完成
- 已準備 `PUSH_SERVER_COMPAT_NOTIFY_TOKEN`

建議先完成：`docs/deployment-push-server.zh-TW.md`

## 3. 安裝 tmux-chatd

Homebrew（macOS）：

```bash
brew tap allenneverland/tmux-chat
brew install tmux-chatd
```

install script（macOS/Linux）：

```bash
curl -fsSL https://raw.githubusercontent.com/allenneverland/tmux-chat/main/install.sh | sh
```

## 4. macOS（launchd）部署

建立本機設定：

```bash
cp config.local.mk.sample config.local.mk
```

編輯 `config.local.mk`（若 `push-server` 同機，建議 loopback）：

```makefile
PUSH_SERVER_BASE_URL = http://127.0.0.1:8790
PUSH_SERVER_COMPAT_NOTIFY_TOKEN = CHANGE_ME_STRONG_TOKEN
```

啟動：

```bash
make build
make install
make start
```

狀態與日誌：

```bash
make status
make logs
```

## 5. Linux（systemd）部署

建立 `/etc/systemd/system/tmux-chatd.service`：

```ini
[Unit]
Description=tmux-chat daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tmux-chatd
Restart=always
RestartSec=3
Environment=TMUX_CHATD_BIND_ADDR=0.0.0.0
Environment=TMUX_CHATD_PORT=8787
Environment=PUSH_SERVER_BASE_URL=http://127.0.0.1:8790
Environment=PUSH_SERVER_COMPAT_NOTIFY_TOKEN=CHANGE_ME_STRONG_TOKEN

[Install]
WantedBy=multi-user.target
```

啟動：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tmux-chatd
sudo systemctl status tmux-chatd --no-pager
```

## 6. Tailscale-only（建議）

若 iOS 透過 Tailscale 連線，建議使用：

```bash
tailscale serve --bg --https=8787 http://127.0.0.1:8787
tailscale serve status
```

iOS `BASE_URL` 可設為：

```text
https://<your-host>.ts.net:8787
```

## 7. 驗證

未帶 token 應 401：

```bash
curl -i http://127.0.0.1:8787/sessions
```

發放 token：

```bash
tmux-chatd devices issue --name "deploy-check" --json
```

帶 token 列 session：

```bash
curl -i \
  -H "Authorization: Bearer <device_token>" \
  http://127.0.0.1:8787/sessions
```

`/notify` 相容轉送測試：

```bash
curl -i \
  -X POST http://127.0.0.1:8787/notify \
  -H 'Content-Type: application/json' \
  -d '{"title":"deploy-test","body":"notify-forward-check","pane_target":"dev:0.0"}'
```

## 8. 常見錯誤

- `/notify` 502
  - 通常是 `PUSH_SERVER_BASE_URL` 或 `PUSH_SERVER_COMPAT_NOTIFY_TOKEN` 設定錯誤。
- `sessions` 一直 401
  - 檢查 Bearer token 是否有效，或重新 `devices issue`。
- systemd 啟不來
  - 確認 `ExecStart` 路徑是否為實際安裝位置。

## 9. 安全建議

- 控制 API 一律用 Bearer token（不開放 open mode）。
- 優先 HTTPS / private network。
- 定期清理不用的 token：

```bash
tmux-chatd devices list
tmux-chatd devices revoke <device-id>
```
