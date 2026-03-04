# TmuxChat 藍圖改造任務書（保留核心 tmux 能力）

## 目標摘要
本任務將目前實作改造成符合 `docs/notification-blueprint.md` 的新架構與流程，並保留核心能力：iOS 遠端操作 tmux（sessions/input/output/delete）。

已鎖定決策：
1. 遷移策略：一次切換（Flag Day）。
2. 範圍：完整藍圖。
3. 程式碼策略：同 repo 多 binary。
4. 核心能力：保留 iOS 遠端 tmux 控制。
5. 通知策略：不做 dedupe、不做 throttle（保留靜音策略）。
6. 流程策略：移除 QR onboarding；移除 Cloudflare Access Service Token 相容模式。

## 已核准的藍圖例外
1. 保留 Claude/Codex `notify/hooks` 路徑，作為兼容通知來源（需送到 App）。
2. 不實作離線 queue + retry（best-effort）。
3. 通知導向鍵維持 `deviceId + paneTarget`，不改成 `host/session/pane`。
4. 保留 iOS 遠端 tmux 控制能力，不移除控制面 API。

## 完成定義（Definition of Done）
1. App onboarding 改為 App 內 SSH 連線並遠端安裝 host agent。
2. 通知鏈路改為：tmux bell -> host agent -> push server -> APNs -> iOS route。
3. iOS 仍可完整操作 tmux sessions/panes。
4. 舊 QR/setup token 與本地 `/notify` 流程移除（hooks 相容入口保留）。
5. 所有控制 API 不再有 open mode（不可匿名存取）。
6. SLO 指標可觀測：送達延遲、導向成功率、無效 token 清理率。

## 公開介面與型別變更

### `tmux-chatd`（保留控制面，移除舊註冊流程）
保留：
1. `GET /sessions`
2. `POST /sessions`
3. `POST /panes/{target}/input`
4. `POST /panes/{target}/escape`
5. `GET /panes/{target}/output`
6. `DELETE /panes/{target}`

移除：
1. `POST /register`（QR setup token）

調整：
1. `POST /notify` 保留為兼容入口（Claude/Codex/agent 路徑）。

CLI：
1. 移除 `setup`
2. 保留 `notify`
3. 保留 `hooks install/uninstall`
4. `devices` 保留 list/revoke，新增 `issue --name --json`

安全：
1. 控制 API 一律 Bearer token。
2. 移除 open mode。

### `push-server`（新 binary）
新增 API：
1. `POST /v1/pairings/start`
2. `POST /v1/pairings/complete`
3. `POST /v1/devices/register`
4. `POST /v1/events/bell`
5. `POST /v1/events/agent`
6. `POST /v1/mutes`
7. `DELETE /v1/mutes/{id}`

APNs payload：
1. `deviceId`
2. `paneTarget`
3. `title`
4. `body`
5. `eventTs`
6. `source`（`bell` 或 `agent`）

### `host-agent`（新 binary）
命令：
1. `install`
2. `pair --token`
3. `run`
4. `status`

行為：
1. 監聽 tmux `alert-bell` hook。
2. 出站送 `push-server /v1/events/bell`。
3. best-effort（不做 queue/retry）。

### iOS App
1. 移除 QR onboarding 與 setup token 註冊流程。
2. 新增 SSH onboarding（App 內 SSH 連線、遠端安裝 agent、pairing）。
3. 移除 Cloudflare Service Token UI/欄位/header。
4. 保留通知導向鍵：`deviceId + paneTarget`。
5. 保留既有 tmux 控制畫面流程。

## 分階段任務（Step-by-step）

### Phase 0 — 切換準備
- [x] 建立 Flag Day 時程與 owner
- [x] 建立 rollout/rollback 手冊
- [x] 鎖定 breaking changes（QR 移除、Service Token 移除）

### Phase 1 — Repo 與 CI 改造
- [x] 建立 workspace（`tmux-chatd` / `push-server` / `host-agent`）
- [x] CI 新增三個 binary build/test
- [x] iOS CI 保持可編譯

### Phase 2 — Push Server 實作
- [x] 抽離 APNs 發送模組
- [x] 完成 pairing API
- [x] 完成 APNs device 註冊 API
- [x] 完成 bell/agent 事件 ingest API
- [x] 完成 mute 規則 API
- [x] 保留 invalid token 自動清理

### Phase 3 — Host Agent 實作
- [x] 完成 tmux bell hook 安裝與觸發上報
- [x] 完成 pairing 與 token 存放
- [x] 完成常駐服務（launchd user / systemd user）
- [x] 完成 best-effort 上報（失敗記 log）

### Phase 4 — `tmux-chatd` 收斂
- [x] 刪除 `/register` 與 setup token
- [x] 移除 `setup` CLI 與 QR 相關文案
- [x] 保留 `notify/hooks` 並改為轉送 push-server
- [x] 新增 `devices issue --json`
- [x] auth middleware 改為無條件驗證（移除 open mode）

### Phase 5 — iOS Onboarding 改造
- [x] 新增 SSH 新增主機流程
- [x] App 透過 SSH 安裝 host-agent
- [x] App 完成 pairing 並註冊 APNs device
- [x] App 透過 SSH 取得 `tmux-chatd` 控制 token
- [x] 移除 QR Scanner 與相機權限文案
- [x] 移除 Cloudflare Service Token UI/邏輯

### Phase 6 — 通知導頁與靜音
- [x] 維持 `deviceId + paneTarget` 路由
- [x] 點擊通知切換 server 並導向 pane
- [x] pane 不存在時導向 session list 並提示
- [x] 新增靜音設定 UI（host/session/pane）

### Phase 7 — 觀測與 SLO
- [x] `push-server` 指標：
  - [x] `events_bell_total`
  - [x] `events_agent_total`
  - [x] `apns_sent_total`
  - [x] `apns_failed_total`
  - [x] `invalid_token_removed_total`
  - [x] `event_to_apns_latency_ms`
- [x] iOS 指標：
  - [x] `notification_tap_total`
  - [x] `route_success_total`
  - [x] `route_fallback_total`
- [x] 建立 dashboard 與 alert

### Phase 8 — 文件與上線
- [x] 更新 README/docs：改為 SSH onboarding
- [x] 文件保留 Claude/Codex hooks 兼容說明
- [x] 發布 breaking changes 公告
- [ ] Flag Day 上線與 48 小時觀察

## 測試計畫

### 單元測試
1. pairing token 發放/過期/兌換
2. push-server APNs 發送與 bad token 清理
3. `tmux-chatd` token 發放與驗證
4. host-agent bell 事件解析與送出

### 整合測試
1. App SSH onboarding E2E
2. bell -> host-agent -> push-server -> APNs(mock) E2E
3. Claude/Codex hook -> `tmux-chatd notify` -> push-server -> APNs E2E
4. 通知點擊 -> `deviceId + paneTarget` 導頁 E2E

### 回歸測試
1. sessions 列表、pane output、input、escape、delete
2. revoke 後 token 立即失效
3. push-server 暫停時流程不崩潰

### 失敗場景
1. SSH 連線失敗
2. pairing token 過期
3. APNs 429/5xx
4. pane 不存在
5. push-server 暫時不可用

## 風險與緩解
1. 一次切換風險高：先完成 rollout/rollback 自動化與演練。
2. SSH onboarding 複雜：先最小可用，再優化 UX。
3. 多 binary 維運成本增加：統一觀測、部署模板、告警標準。

## 假設與預設
1. tmux 控制 API 路徑先維持不變，避免 iOS UI 大量重寫。
2. push-server 為集中維運服務，APNs 金鑰僅在 push-server。
3. 不做 dedupe/throttle；只做靜音策略。
4. Cloudflare/Tailscale/VPN 屬使用者網路選擇，不做產品綁定。
5. 藍圖與本文件衝突時，以本 `TASK.md` 為執行基準。
