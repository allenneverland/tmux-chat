# Reattach藍圖（Blueprint）

> 文件目的：定義「像 message app 一樣，App 不開啟也可收通知」的完整產品與技術藍圖。  
> 文件性質：**規劃文件**，不包含程式實作。

## 1. 問題定義與目標

### 1.0 已鎖定產品決策（最新）

1. 安裝流程固定為：`下載 App -> App 內連上 SSH -> 由 App 透過 SSH 安裝 agent -> 完成`。
2. 不使用 QR code onboarding。
3. 不提供 Cloudflare Access Service Token 相容模式。
4. 不規範使用者如何連上 SSH（Tailscale / 網域 / Cloudflare Tunnel / VPN 皆屬使用者自行選擇）。

### 1.1 需求目標

1. 使用者離開 App 或鎖屏時，仍可收到 tmux bell 通知。
2. 點擊通知後，必須導向正確的 `pane`。
3. 通知不可被洗版，必須有靜音策略。
4. 必須具備可控安全性：裝置註冊、token 保護、撤銷機制。

### 1.2 成功指標（SLO）

1. 推播送達時間：bell 觸發後 **3-10 秒**內到達（網路正常時）。
2. 通知點擊導向成功率：`host/session/pane` 路由成功率 >= 99%。
3. APNs 無效 token 清理：24 小時內清理完成率 >= 99%。

### 1.3 非目標

1. 不採用 iOS 背景輪詢（不可靠且耗電）。
2. 不要求 tmux 主機開入站 port（避免暴露攻擊面）。
3. 不做完整帳號社交功能（好友/共享通知）。
4. 不提供 QR 註冊流程。
5. 不負責 SSH 連線基礎設施（只處理「連上 SSH 之後」的流程）。

## 2. 架構總覽

採三層架構：

1. iOS App（使用者端）
2. Host Relay Agent（安裝在使用者 tmux 主機）
3. Push Server（開發者集中維運，負責 APNs）

```text
tmux alert-bell
   -> host relay agent (outbound HTTPS)
   -> push server (security)
   -> APNs
   -> iOS app notification tap
   -> deep link to host/session/pane
```

## 3. 元件責任切分

### 3.1 iOS App

1. 申請通知權限（UserNotifications）。
2. 取得 APNs device token，向 Push Server 註冊裝置。
3. 建立 host pairing（取得 host ingest token 或 agent bootstrap 資訊）。
4. 提供「一鍵在遠端安裝 agent」流程（透過既有 SSH 連線能力）。
5. 接收推播 payload 並執行深連結路由。

### 3.2 Host Relay Agent（tmux 主機）

1. 監聽/接收 tmux bell 事件（hook 或輕量 CLI 觸發）。
2. 將 bell 事件送往 Push Server（僅出站 HTTPS）。
3. 提供離線緩衝與重試機制（避免短線漏通知）。
4. 以 system service 常駐（systemd/launchd user mode）。

### 3.3 Push Server

1. 提供裝置註冊、配對、撤銷 API。
2. 驗證 token 並做授權。
3. 執行 quiet hours 規則。
4. 送 APNs（token-based auth, `.p8` 只保留在 server）。
5. 處理 APNs 回應碼與無效 token 停用。
