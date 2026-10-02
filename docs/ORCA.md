# Orca 開發流程

## 專案與 worktree

用即時查詢取得 repo ID，文件不綁定某台電腦的 ID：

```sh
orca skills get orca-cli
orca status --json
orca repo show --repo path:"$PWD" --json
```

Runtime 必須是 `ready` 且 `reachable: true`。`runtime_access_denied` 時，在獲授權的執行環境重試；
這不是需要重啟 Orca 的證據。

每個功能用獨立 worktree。先確認乾淨的 base 並 fetch，再使用目前 launcher 設定：

```sh
git fetch origin main
orca worktree create --repo path:"$PWD" --name snapshot-entry --base-branch origin/main --no-parent --setup run --agent codex --json
```

讀取回傳的完整 worktree ID 與 agent handle；任務開始前確認 setup 結果與 agent readiness。
相關或堆疊任務才指定 parent；同一檔案同一時間只有一個寫入者。

## Setup hook

在 Orca 的本專案設定中，Setup script 設為：

```sh
python3 scripts/dev.py setup
```

Setup run policy 為 run-by-default，agent startup 等 setup 成功後再開始。
Archive script 保持空白：目前沒有 setup 建立、需要自動清除的背景服務。
以 `orca repo show` 核對實際儲存的 `hookSettings`，不能只因腳本存在就宣稱已綁定。
若目前 CLI 沒有 setter，透過 Orca 專案設定 UI 操作；不編輯 Orca 的內部資料庫或 runtime state。

`setup` 不要求 Xcode，因此文件或工具任務不會因 iOS 工具鏈缺失而無法啟動。
App 任務另跑 `doctor`；setup 成功不是 Simulator 驗證。

## 任務 brief

每次工作交代：目標檔案／行為、預期變更、產品限制、可編輯範圍、可觀察驗收。
例如：在數值項目新增快照，支援日期／數值／文字；所有入口共用同一保存邏輯；
保存後重開 app 資料仍在，補登不改變較新紀錄的最新值，三語及大字體能操作。

一般任務由單一 agent 完成。使用者要求並行或委派時，才載入版本匹配的 orchestration guide：

```sh
orca skills get orchestration
```

透過 Run、Task、Dispatch 管理可獨立驗證的工作，處理 question／escalation／worker_done，
只有有效 settlement 才 release。不能用一般 subagent 替代 Orca provenance。
共享的 Xcode project、資料模型與 Simulator session 由協調者指定唯一 owner；UI 測試序列執行。

## Git 交付

以 feature branch 與 PR 交付，CI 檢查最新 head。使用者要求先看或不要 merge 時保留該 gate。
正常已授權功能持續完成驗證與整合；新增付費服務與正式外部發佈不由功能任務自動授權。
清理前保護 dirty/untracked 工作，以 diff 或 patch 證明 squash-merged 變更已在 main；
只清理本任務建立的 worktree，使用 Orca 的正式 archive/remove 流程。
