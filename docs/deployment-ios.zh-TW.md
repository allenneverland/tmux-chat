# iOS App 發版與上架指南（繁體中文）

本文件涵蓋 `ios/` 客戶端的發版流程（TestFlight / App Store Connect），不屬於主機服務部署。

## 1. 文件定位

目前主機端對外可視為兩個系統：

- `push-server`
- `tmux`

其中 `tmux` 系統內部由 `tmux-chatd + host-agent` 組成。
對應文件：

- `docs/deployment-push-server.zh-TW.md`
- `docs/deployment-tmux.zh-TW.md`

## 2. 前置條件

- Xcode（可成功開啟 `ios/TmuxChat.xcodeproj`）
- Apple Developer / App Store Connect 權限
- `ios/TmuxChat/Config.xcconfig` 已設定

建立本機設定：

```bash
cp ios/TmuxChat/Config.xcconfig.sample ios/TmuxChat/Config.xcconfig
```

`Config.xcconfig` 至少要有：

```xcconfig
BASE_URL = https://your-tmux-chatd.example.com
PUSH_SERVER_BASE_URL = https://your-push-server.example.com
```

## 3. 發版（Binary）流程

目前 repository 內 `fastlane` 主要管理 metadata / screenshots。  
iOS binary（ipa）建議使用 Xcode Archive 流程上傳：

1. 在 Xcode 開啟 `ios/TmuxChat.xcodeproj`
2. 選 `TmuxChat` scheme + Any iOS Device
3. `Product > Archive`
4. Organizer 中 `Distribute App` 上傳至 TestFlight / App Store Connect

## 4. TestFlight 版本說明更新

編輯：

- `fastlane/changelog.txt`

再執行：

```bash
bundle exec fastlane ios update_changelog
```

## 5. App Store Metadata / Screenshots

先設定 App Store Connect API Key 環境變數：

```bash
export APP_STORE_CONNECT_API_KEY_ID=...
export APP_STORE_CONNECT_API_ISSUER_ID=...
export APP_STORE_CONNECT_API_KEY_PATH=...
```

常用命令：

```bash
bundle exec fastlane ios download_metadata
bundle exec fastlane ios download_screenshots
bundle exec fastlane ios upload_metadata
bundle exec fastlane ios upload_screenshots
bundle exec fastlane ios upload_all
```

## 6. 與主機端部署的關係

- 主機端部署：`push-server` / `tmux`（`tmux-chatd + host-agent`）
- 手機端發版：`ios/`（本文件）

兩者都要存在，整體通知與控制路徑才會完整。
