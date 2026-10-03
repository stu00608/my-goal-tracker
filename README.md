# My Goal Tracker

私人使用的 iPhone 目標記錄器：數值快照、每日完成紀錄、照片、回顧與完整備份。
第一版已包含數值快照、每日完成、圖表／日曆、三語、亮暗外觀、備份還原、本機提醒與小／中型 Widget。

## 開始工作

```sh
python3 scripts/dev.py setup
python3 scripts/dev.py check
python3 scripts/dev.py doctor
```

`setup` 只設定本 repo 的 Git hooks、fast-forward pull 與 fetch prune，沒有安裝套件。
`check` 驗證 repo 與工具腳本；`doctor` 檢查本機 iOS 工具鏈，兩者是不同的結果。
需要 Python 3.9+；iOS 開發需要完整 Xcode 與 iOS Simulator runtime。

| 文件 | 用途 |
| --- | --- |
| [產品 spec](docs/SPEC.md) | 已確認的範圍、統計規則、開發里程碑 |
| [Agent 規則](AGENTS.md) | 每次工作都適用的開發要點 |
| [交付 skill](.agents/skills/goal-tracker-delivery/SKILL.md) | 從任務到驗證、PR、整合的流程與 skill 選用 |
| [Orca 設定](docs/ORCA.md) | Worktree、setup hook、委派與工作範圍 |
| [Simulator 驗證](docs/SIMULATOR.md) | 實際 build、test、run、截圖與真機邊界 |

## Git 與 CI

私人 GitHub repo 使用 `main` 作為整合分支，功能在 Orca worktree 中以 PR 交付。
`.githooks/pre-commit` 執行 repo 檢查；CI 使用同一入口。
CI 在 macOS runner 實際執行原生邏輯與 UI 測試，拒絕空測試或 skipped 結果。

約定 app 專案為 `ios/GoalTracker.xcodeproj`，shared scheme 為 `GoalTracker`，
並包含 `GoalTrackerTests` 和 `GoalTrackerUITests`。建立專案的任務需同時驗證這些約定。
Personal Team、手機配對與本機 signing 設定由 Xcode 管理，不放進 repo。

## 執行 App

```sh
python3 scripts/dev.py doctor
python3 scripts/dev.py build
python3 scripts/dev.py test
python3 scripts/dev.py run
python3 scripts/dev.py run --scheme GoalTrackerWithWidget
open ios/GoalTracker.xcodeproj
```

核心 scheme 為 `GoalTracker`；含 Widget 使用 `GoalTrackerWithWidget`，最低 iOS 17。
Widget 只共享進度摘要，點擊回到今天。兩個版本保留同一份 App 私有資料。
真機使用自己的 Personal Team，
私人的 Team ID 僅存在被忽略的 `Signing.local.xcconfig` 或本機 build setting。
詳見 [Simulator 與真機驗證](docs/SIMULATOR.md)。

完整備份為版本化 JSON，包含照片的 app 自有 JPEG 副本。CSV 只供分析，不能還原。
為避免過量匯入，第一版單一備份上限 100 MB、數值上限 28 位數字；
照片每筆最多 6 張，保存時縮至 1600 像素，每張上限 2 MB。
外觀、語言、系統通知權限為本機偏好，不由備份取代。
