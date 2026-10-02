# iOS Simulator 與真機驗證

## 工具鏈

iOS 使用 Apple 的 Simulator。只有 Command Line Tools 不包含完整 iOS SDK、Simulator 與 `simctl`。
安裝完整 Xcode、啟動一次完成必要元件與授權，並安裝一個相容的 iOS Simulator runtime。
不需要付費 Apple Developer Program 來執行 Simulator。

可用 Xcode Settings → Components 安裝 runtime。也可在完整 Xcode 可用後執行
`xcodebuild -downloadPlatform iOS`；它會下載大型元件，先確認可用空間。
參考 [Apple 元件安裝文件](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)。

若全域 developer directory 仍是 Command Line Tools，可以只為本次命令設定：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/dev.py doctor
```

不必為本專案修改全域 `xcode-select`，也不自動接受 Apple agreements。

## Agent 實際操作

```sh
python3 scripts/dev.py doctor
python3 scripts/dev.py devices
python3 scripts/dev.py build
python3 scripts/dev.py test --device <simulator-udid>
python3 scripts/dev.py run --device <simulator-udid>
python3 scripts/dev.py screenshot --device <simulator-udid>
```

`build` 是無簽名的 Simulator build。`test` 執行 shared scheme 的 tests，
保存 `.xcresult` 與 summary，拒絕空測試、失敗、跳過或不完整的結果。
`run` build 後 boot、install、launch，讀取 app 的實際 bundle ID；這只證明啟動。
`screenshot` 保存 PNG；agent 必須用影像工具打開檢視，不能只列出檔案路徑。
未指定裝置時，test/run 明確列出選用的可用 iPhone。截圖要求指定 UDID，避免截到其他 session。

沒有 app project、缺少 runtime、build/test 非零或 result bundle 無法解析時，命令失敗。
錯誤輸出與測試結果保存在本 worktree 的 `.artifacts/`；DerivedData 在 `.build/`。
沒有 app 時 CI 的 iOS job 是 skipped，不是 app 驗證通過。

## 驗證使用者流程

第一個 app 任務建立 shared `GoalTracker` scheme，包含 Swift Testing unit/integration tests
與 XCTest UI tests。UI tests 透過 accessibility identifiers 找控制項、輸入、點擊並斷言結果，
使用獨立測試資料，不能清空使用者的實際資料。重要 UI test 保存 screenshot attachments。
Swift Testing 驗證週／月界線、重複勾選、補登排序、數值精度、完整備份及失敗保留資料。
參考 [Apple 測試框架](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project)
與 [測試執行及結果](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results)。

UI 變更至少操作受影響流程並檢視結果；在地化／共用佈局變更才擴大到三語、亮暗、大字體。
用 CLI 的 `simctl ui <udid> appearance light|dark` 設定 Simulator 外觀。
本機互動驗證優先使用 Orca 的 worktree-scoped emulator bridge：

```sh
orca skills get orca-emulator
orca emulator devices --worktree active --json
orca emulator attach <simulator-udid> --worktree active --json
orca emulator ax --worktree active --json
orca emulator tap 0.5 0.8 --worktree active --json
orca emulator type "18.500" --worktree active --json
orca emulator kill --worktree active --json
```

先用 build/run 安裝並啟動 app，再 attach 同一 UDID。iOS 的 install/launch 由 Xcode/simctl
處理；Orca 的 install/launch verbs 是 Android-only。attach 前與每次操作後觀察最新畫面／AX。
tap 使用左上原點的 0..1 正規化座標，依 AX frame 中心選目標，不能直接傳 screenshot 像素。
`type` 只支援 US-ASCII；繁中／日文輸入改由 XCTest UI test 的 `typeText` 驗證，
不能宣稱 ASCII 流程涵蓋三語。結束後 kill helper；它會保留 booted Simulator。
不得使用 `--worktree all` 執行操作，也不關閉其他任務的 session。
Bridge 使用 private Simulator APIs，Xcode 更新後先重驗 attach／tap／AX 是否仍可用。
參考 [Orca 官方 iOS emulator guide](https://github.com/stablyai/orca/blob/main/skill-guides/orca-emulator.md)。

需要操作 Simulator 的 macOS 視窗或 bridge 不支援的 UI 時，才載入 `orca skills get computer-use`，
以最新 screenshot、正確 scale 與焦點操作，動作後重新觀察。
Simulator 的 macOS accessibility tree 未必暴露 iOS 控制項；可靠、可重跑的驗收仍使用 XCTest。
`simctl` 的截圖／啟動不能代替點擊與資料斷言；它沒有通用的 tap/type verbs。
缺少完整 Xcode/runtime 時，Orca 列出空 devices 不能算測試通過。

## 真機與免費簽署

開啟 app project，在 Xcode Settings → Accounts 登入使用者的 Apple Account，
Signing & Capabilities 選 Personal Team，連接並信任自己的 iPhone，依提示啟用 Developer Mode。
選手機為 run destination 後由 Xcode build/run。Team ID 不寫進 shared project；
需要共用 build setting 時使用被忽略的 `Signing.local.xcconfig`，不提交私人 signing 資訊。
免費描述檔只有 7 天效期，過期後從 Xcode 重新部署。
參考 [免費帳號限制](https://developer.apple.com/help/account/basics/about-your-developer-account)。

相機、相簿權限、通知／Focus、觸覺、效能與 widget signing 需要自己的 iPhone 實測。
Simulator 不完整模擬實體裝置能力；在交付報告中明確列出尚未驗證的真機項目。
參考 [Apple 裝置驗證說明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)。
