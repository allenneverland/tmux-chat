# host-agent 部署指南（繁體中文）

本文件只涵蓋 `host-agent` 的部署與驗證。

## 1. 元件責任

`host-agent` 負責：

- 在主機安裝 tmux `alert-bell` hook
- 將 bell 事件上報到 `push-server`
- 持有 pairing 後取得的 ingest 憑證

## 2. 前置條件

- `push-server` 已部署可用
- `tmux-chatd` 已部署可用
- 主機已安裝 `tmux`

建議先完成：

- `docs/deployment-push-server.zh-TW.md`
- `docs/deployment-tmux-chatd.zh-TW.md`

## 3. 推薦路徑：由 iOS SSH onboarding 自動完成

在 iOS App 執行 `Add Server via SSH`，會自動：

- 遠端安裝 `host-agent`
- 啟動 pairing
- 完成 APNs 裝置註冊
- 驗證控制面

## 4. 手動部署（進階）

### 4.1 Build 並安裝

```bash
cargo build --release -p host-agent
install -m 755 ./target/release/host-agent ~/.local/bin/host-agent
```

### 4.2 安裝 hook 與本機設定

```bash
~/.local/bin/host-agent install --push-server-base-url https://push.example.com
```

### 4.3 配對

```bash
~/.local/bin/host-agent pair \
  --token '<pairing_token>' \
  --push-server-base-url 'https://push.example.com' \
  --json
```

### 4.4 檢查狀態

```bash
~/.local/bin/host-agent status --json
```

## 5. Tailscale-only 建議設定

若 `push-server` 透過 Tailscale 提供 HTTPS：

```bash
~/.local/bin/host-agent install --push-server-base-url https://<your-host>.ts.net:8790
```

> `host-agent` 實際送事件會使用 pairing 回傳的 `ingest_url`。
> 該 URL 由 `push-server` 的 `PUSH_SERVER_PUBLIC_BASE_URL` 決定。

## 6. Bell 路徑驗證

在 tmux pane 觸發 bell：

```bash
printf '\a'
```

確認：

- `~/.local/bin/host-agent status --json` 顯示 hook active
- `push-server` metrics 的 `events_bell_total` 增加

## 7. 常見錯誤

- `host-agent pair` 失敗
  - pairing token 可能過期（預設 TTL 600 秒）
- 事件沒送到 push-server
  - 檢查 `push-server-base-url` 或 pairing 回傳的 `ingest_url` 是否可達
- hook 沒生效
  - 檢查 tmux 是否真的載入了 `alert-bell` hook

## 8. 安全建議

- pairing token 視為短期敏感資料，避免落在共享歷史紀錄。
- 優先使用 HTTPS 或私有網路傳輸。
