# My Goal Tracker

私人使用的 iPhone 目標記錄器：數值快照、每日完成紀錄、照片、回顧與完整備份。
目前只建立開發流程；app 尚未實作。

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
第一個 app 專案建立後，CI 自動啟用 iOS Simulator test job。
在 app 尚未存在時，該 job 會顯示 skipped，只有 repo 檢查能算通過。

約定 app 專案為 `ios/GoalTracker.xcodeproj`，shared scheme 為 `GoalTracker`，
並包含 `GoalTrackerTests` 和 `GoalTrackerUITests`。建立專案的任務需同時驗證這些約定。
Personal Team、手機配對與本機 signing 設定由 Xcode 管理，不放進 repo。
