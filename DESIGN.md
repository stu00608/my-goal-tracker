# Goalooker Design System

這份文件定義 App 的視覺與互動語言，並列出 AI 實作過去反覆犯過的錯。任何 UI、互動、文案或 Widget 變更，
都先讀這份文件，再依 [Native UX quality](docs/UX-QUALITY.md) 跑「render → 批評 → 修正」流程。
產品行為以 [SPEC](docs/SPEC.md) 為準；SPEC 決定「要做什麼」，這份文件決定「長什麼樣子、怎麼說」。

## 1. 原則

1. **一個畫面一個主角。** 今天頁的主角是卡片網格；紀錄 sheet 的主角是數值（或完成狀態）與照片；
   詳情頁的主角是最上方的大數值與圖表。其他內容降一級：次要灰、較小字級，或收進子頁。
2. **文字少。** 能用狀態、圖示、停用或隱藏表達的，就不寫句子。SPEC 寫的規則是給工程師看的，
   不是畫面文案；「需要讓使用者知道」不等於「需要常駐一段說明」。
3. **原生優先。** 系統字體、語意色、`List`/`Form`、`NavigationStack`、sheet、`Menu`、`Picker`、
   `ContentUnavailableView`、`ShareLink`、`PhotosPicker`、SF Symbols。先找原生元件，沒有才自製。
4. **同一種東西只有一種長相。** 先找 repo 裡既有的元件（見第 6 節）再寫新的。
5. **回饋有溫度。** 使用者的每個動作都要有回饋：觸覺、symbol 轉場、數字滾動。達成目標是情緒高點，
   要做得有分量，但不打擾。
6. **漸進揭露。** 常用的放上面；進階設定用帶摘要值的子頁列收起來。

## 2. Layout 與 spacing

只用這組刻度：**4 / 8 / 12 / 16 / 20 / 24**。不要出現 6、10、13、18 這類魔術數字。

| 用途 | 值 | 程式碼 |
|---|---|---|
| 標題與副標、label 內部 | 4 | |
| 控制項與它的說明、圖示與文字 | 8 | |
| 網格間距、照片縮圖間距、區塊內群組 | 12 | `CardLayout.gridSpacing` |
| 畫面邊距、sheet 內距、toast 內距 | 16 | `CardLayout.screenInset` |
| 卡片文字、圖表、空狀態內縮（四側相同） | 14 | `CardLayout.textInset` / `plotInset` |
| ScrollView 中區塊之間 | 20 | |
| 海報、hero 內距 | 24 | |

- `List`/`Form` 用系統的 row inset。不要用 `listRowInsets(leading: 0)` 讓某一列貼邊，否則會和下面的列左緣錯開。
  需要滿版的只有 hero 區（數值、圖表），而且要整區滿版，不是單一標題。
- 不要讓 section footer 緊貼下一個 section header。根本解法是刪掉多餘的 footer，
  不是調整 `listSectionSpacing` 硬拉開。
- 卡片尺寸由 `CardLayout` 推導，不在呼叫端重算 `(width - 32 - 12) / 2` 這種式子。

## 3. 圓角、陰影、透明度

| 類別 | 值 |
|---|---|
| 圓角（一律 `style: .continuous`） | 照片縮圖 12；卡片、海報、toast、地圖 20（`CardLayout.radius`）；狀態圖示、徽章、日期格用 Circle |
| 透明度 | hairline 描邊 0.08；進度環軌道 0.12；muted 0.35。不要每個元件各自取值 |
| 陰影 | 只在照片或地圖上為文字做可讀性處理，用 `CardPhotoReadabilityGradient` 的角落漸層。不要用多層位移 shadow 模擬描邊 |

## 4. 字級

全部使用 Dynamic Type text style；數字一律 `.monospacedDigit()`。

| 層級 | 樣式 | 用在 |
|---|---|---|
| Hero 數值 | `@ScaledMetric(relativeTo: .largeTitle)` 的大字、semibold、等寬數字 | 紀錄 sheet 數值、詳情頁最上方 |
| 主數值 | `.title2.semibold().monospacedDigit()` | 卡片角落、進度環中心、Widget 數值 |
| 列標題 | `.body`，需要強調時 `.headline` | 清單列、表單列 |
| 次要資訊、日期 | `.subheadline` + `.secondary` | 列內副標、時間軸日期 |
| 說明文字 | Section footer（系統 footnote） | 只放真正必要的一句 |
| `.caption` | | 只用於圖例、軸標、卡片日期 |
| `.caption2` | | 只用於 Widget |

- 卡片上名稱不能比數值搶眼；同一個網格裡，所有卡片的主數值字級、字重相同。
- 空狀態（「尚無紀錄」「—」）一定比真實資料低調：caption 或次要灰，不能用和數值一樣的字級。
- 不寫 `.font(.system(size: N))`。裝飾用的大圖示用 `.largeTitle` 或 `@ScaledMetric`。
- `minimumScaleFactor` 不低於 0.5；大字級時改成換行或改版面，不要把字縮到看不見。
- 一張 sheet 不超過 4 個字級層級。

## 5. 顏色

| 用途 | 規則 |
|---|---|
| 次要文字 | 只用 `.secondary` / `.tertiary`。`TrackerColors.secondaryText` 已等同 `.secondary`，新程式碼直接寫 `.secondary` |
| Accent | `TrackerColors.accent`，與 Asset 的 `AccentColor` 相同，含暗色與增加對比變體 |
| Accent 用在哪 | 主要操作、選中狀態、完成狀態、圖表線、地圖標記、進度弧 |
| Accent 不用在哪 | 資料值、清單標題、時間軸數字。這些用 `.primary` |
| 條件狀態 | 符合 `.green`；不符合 `.orange`；未知或檢查中 `.secondary`。用 `.fill` 版本的 SF Symbol |
| 破壞性操作 | `role: .destructive`（系統紅） |
| 照片移除徽章 | `xmark.circle.fill`，palette：白色符號＋半透明深色底。不用鮮紅 |

- 全域 `.tint` 會把 borderless 按鈕裡的 `.primary` / `.secondary` 也染色。要中性色時明確寫 `Color.primary` / `Color.secondary`。
- 地圖標記一律 `.tint(TrackerColors.accent)`，範圍圈也用 accent，不用系統藍。

## 6. 元件目錄（先重用，再新增）

| 元件 | 位置 | 規則 |
|---|---|---|
| 卡片外框與背景 | `TrackerCardSurface`、`TrackerCardBackdrop`、`TrackerCardLabel`（TrackerCard.swift） | 背景滿版，文字疊在使用者選的角落；地圖或照片要加可讀性漸層 |
| 進度環 | `GoalProgressRing` | 環內是百分比或分數；名稱與日期置中排在下方 |
| 照片列 | `DraftPhotoRail`（Editors.swift） | 縮圖 104pt、間距 12、圓角 12；移除徽章命中區 ≥ 44pt，不被裁切 |
| 星期選擇 | `WeekdaySelector`（AchievementConditionEditor.swift） | 圓鈕、間距 4、依「星期第一天」偏好排序。提醒與條件共用，不要用 7 個 Toggle |
| 條件狀態 | `ConditionStatusView` + `ConditionPreviewUpdates` | 一列摘要＋`DisclosureGroup` 明細；單一群組時隱藏群組層；更新由紀錄頁管理 |
| 錯誤或暫態訊息 | `.statusToast(message:identifier:autoDismiss:)` | 語意色圖示、16 內距、圓角 20；不插入紅字欄位 |
| 詳情頁樣式 | `DetailStyle`（Views.swift） | 圖表高度只有 `chartHeight` 一種；延伸虛線只有 `dashed` 一種；列表日期用 `DetailStyle.date`（今年省略年份） |
| 項目編輯子頁 | `editorPage(_:content:)`（TrackerEditor.swift） | 主表單列用 `NavigationLink` 加右側摘要值；草稿 state 留在 `TrackerEditor`，子頁只拿 binding |
| 完成海報 | `AchievementPoster` | 縮圖網格與詳情共用；匯出圖保留完整日期與時間 |

新增元件前，先搜尋是否已有相同用途的 view。照片列、星期選擇、地圖標記過去都各自被實作了 2～5 次，這是要避免的狀況。

## 7. 畫面結構

- **今天**：卡片網格是唯一主角。點卡片開紀錄 sheet；長按出 `contextMenu`（詳情、編輯、封存），長按後拖曳則排序。
  卡片下方不加工具列。大標題下方以 `.navigationSubtitle` 顯示日期（iOS 26 以上）。
- **紀錄 sheet**：標題是項目名稱。最上方工作區放數值 hero（或完成狀態）與照片列；接著是條件摘要、日期、備註、位置。
  數值區沒有輸入時，以淡色顯示前次數值或 0，不要只顯示一條「—」。
- **詳情**：最上方 hero（大數值、與上一筆的差異、目標進度）→ 圖表或日曆（期間與模式用 segmented，和圖表放在一起）
  → 2 欄指標格 → 近期紀錄（最多 5 筆，加「全部紀錄」）→ 描述、照片、地圖、里程碑、目標歷史。
  工具列：「編輯」文字按鈕＋「＋」。不放只有一個項目的「⋯」選單。
- **項目編輯**：主表單只放名稱、記錄方式、數值設定、目標。外觀、達成條件、提醒、描述與照片、圖表範圍都是子頁列，
  列上顯示目前值（「無」「關閉」「2 個條件」）。封存與刪除放在編輯頁底部。
- **完成**：海報縮圖網格，點一下直接開海報；分享用工具列上的一個 `ShareLink`。
- **設定**：外觀、記錄、Apple 健康、提醒、資料、關於。統計數字和破壞性動作分開；還原的摘要放在確認對話框裡。
- **空狀態**：整頁用 `ContentUnavailableView`，不要塞進 List 的某一列，也不要用一張白卡加一句灰字。

## 8. 文案

- 動詞用「記錄」，名詞用「紀錄」。placeholder 不寫「（選填）」。
- 一句話講完；不解釋實作細節（「嚴格比較」「依據可讀取的資料」「包含開始與結束的分鐘」都不該出現在畫面上）。
- 說明只在需要時出現：位置來源只在開關打開時顯示；錯誤只在發生時顯示。
- 數字用千分位與自然語言：「超過 6,000 步」，不寫「步數 > 6000」。七天都選時顯示「每天」。
- 改共用字串前，先 `grep` 這個 key 的所有使用處。只在某個畫面想用短字時，新增一個 key，不要縮短共用值。
- 三語同時改。ja 不要讓兩個不同概念用同一個詞。

### 術語

| 概念 | zh-Hant | en | ja |
|---|---|---|---|
| 使用者追蹤的東西 | 項目 | Item / Tracker | 項目 |
| 達成規則 | 目標 | Goal | 目標 |
| 數值型項目 | 數值 | Number | 数値 |
| 紀錄上的文字 | 備註 | Notes | 備考 |
| 項目的文字 | 描述 | Description | 説明 |
| 條件組合 | 群組 | Group | グループ |
| 達成歷史 | 里程碑 | Milestones | マイルストーン |
| 今天的快速完成 | 記錄完成／取消完成紀錄 | Mark complete / Undo completion | 完了を記録／完了記録を取り消す |
| 有限目標的手動完成 | 標記完成／取消完成 | Mark Complete / Undo Completion | 完了にする／完了を取り消す |

## 9. 動態與觸覺

| 事件 | 處理 |
|---|---|
| 快速完成或取消 | `.sensoryFeedback(.success / .impact)`；勾選圖示加 `.contentTransition(.symbolEffect(.replace))` |
| 數值滑動調整 | 每一步 `.selection` |
| 拖曳排序放下 | `.impact` |
| 錯誤 toast 出現 | `.error` |
| 一般狀態切換 | `.snappy` |
| 減少動態效果 | 改成淡入淡出或立即更新；CoreMotion 浮雕改成靜態 |

觸覺的 trigger 必須是**使用者的動作**（按下後遞增的計數器），不能是衍生狀態。
例如 `done` 會在跨午夜、還原備份、在別頁刪除紀錄時改變，用它當 trigger 會在使用者沒操作時震動。

## 10. 無障礙

- 互動範圍至少 44pt。大字級時改成單欄或換行，不靠縮字。
- 摘要列的標題已經說明狀態時，不要再加 `accessibilityValue` 重複朗讀；裝飾用的 ProgressView 或圖示設 `accessibilityHidden`。
- VoiceOver 的操作說明放 `accessibilityHint`，不要寫在可見的 footer。
- 圖表提供 `accessibilityChartDescriptor`。
- 亮色、暗色、增加對比、減少透明度、最大無障礙字級、三語都要實際截圖檢查。

## 11. 反模式：AI 實作過去反覆犯的錯

下面每一條都在這個 repo 真實出現過。寫 UI 或 review 時逐條對照。

| # | 反模式 | 為什麼不好 | 正確做法 |
|---|---|---|---|
| 1 | 把 SPEC 的句子直接當畫面文案，每個控制項下面掛一段 caption | 畫面變成文字牆，看起來沒設計過 | 只留使用者做決定必須知道的一句，其餘刪掉 |
| 2 | 預設建立空結構（例如新項目自帶一個空條件群組），再用停用控制項加警告句說明 | 使用者第一眼就看到錯誤狀態 | 沒有內容時只顯示「新增」；不能操作的控制項直接隱藏 |
| 3 | 只有一個項目的「⋯」選單 | 多一次點擊，又藏住主要動作 | 直接放文字按鈕 |
| 4 | 自己畫 chevron，點下卻是開 sheet | chevron 在 iOS 代表推入下一頁 | 推入用 `NavigationLink`；開 sheet 的列不加 chevron |
| 5 | Section header 重複導覽標題或第一列標籤（「記錄方式／記錄方式」） | 噪音 | 刪掉 header，或改成真正的分組名稱 |
| 6 | 自訂次要灰 `primary.opacity(0.72)`，和 `.secondary` 混用 | 層級被壓平，不跟增加對比調整 | 只用 `.secondary` / `.tertiary` |
| 7 | 全域 tint 把資料值、清單標題都染成 accent | accent 失去「這裡可以按」的意義 | 資料值用 `.primary`，accent 只給操作與狀態 |
| 8 | 空狀態用和資料一樣大的字，或放一個灰色圖表圖示當佔位 | 看起來像壞掉，或比真資料還醒目 | 留白，或用低調的 caption／「—」 |
| 9 | 數值輸入區只顯示一條灰線「—」 | 看起來像壞掉 | 淡色顯示前次數值或 0，加單位 |
| 10 | 紀錄 sheet 標題只寫「新增紀錄」 | 使用者不知道正在記錄哪個項目 | 標題用項目名稱 |
| 11 | 同一種元件各寫一份（照片列 3 份、星期選擇 2 份、地圖標記 5 種） | 間距、顏色、互動各不相同 | 抽成共用元件（第 6 節） |
| 12 | 可拖曳的 `Map` 放在可捲動的 List 裡 | 吃掉捲動手勢；只有一個點時放大到只剩一片底色 | `interactionModes: []`、設最小顯示範圍；標記仍可點 |
| 13 | 圖表 X 軸用預設標籤，最後一個被截成「1…」；沒資料時仍畫格線再疊一句字 | 看起來像壞掉 | 明確的 `AxisMarks`；沒資料時改用空狀態 |
| 14 | 觸覺回饋綁在衍生狀態上 | 跨午夜、還原時沒人操作也會震動 | 以使用者動作作為 trigger（第 9 節） |
| 15 | 為了讓某一頁變短，縮短共用字串的值（例如「全部條件組」改成「全部」） | 其他畫面失去上下文 | 新增專用 key |
| 16 | 翻譯複製貼上，兩個不同概念變成同一個詞（「有限目標」和「標記完成」都翻成「標記完成」） | 選項語意錯誤 | 改字串前對照使用處與相鄰選項 |
| 17 | 匯出或分享的圖片沿用列表的短日期格式 | 隔年再看就不知道是哪一年 | 匯出內容保留完整日期與時間 |
| 18 | List 列內放預設樣式的 Button，旁邊還有其他內容 | 點整列任何地方都會觸發按鈕 | 加 `.buttonStyle(.borderless)` |
| 19 | 可封存或可刪除的編輯頁，封存時直接讀 store 裡的舊資料 | 使用者剛改的內容被默默丟掉 | 封存走和儲存相同的草稿路徑 |
| 20 | 在 view 的初始值裡同步查 CoreLocation 或系統權限 | 每次重建 view 都卡主執行緒 | 只在 `task` 或 refresh 時非同步查詢 |
| 21 | 數值固定補零（「1.000」「20.000」） | 讀起來像假精度 | 目前是待決策事項（第 13 節）；同一個值在各處至少要用同一種格式 |
| 22 | 為了讓測試通過而放寬測試（例如「有出現捨棄對話框就點掉」） | 之後的錯誤 CI 抓不到 | 修產品行為，不放寬斷言 |
| 23 | 寫死字級 `.system(size: 44)`、`minimumScaleFactor(0.2)` | Dynamic Type 失效或字小到看不見 | 用 text style、`@ScaledMetric`，大字級時換版面 |
| 24 | 照片移除用整張 sheet 確認，徽章用鮮紅 × | 太重、太刺眼 | 中性 palette 徽章；確認維持輕量並明確對應到該張照片 |

## 12. 交付前檢查清單

- [ ] 每個畫面的主角是什麼？其他內容是否已降級？
- [ ] 刪掉所有能刪的說明；剩下的每一句都能回答「沒有它，使用者會做錯什麼」。
- [ ] spacing 都在 4/8/12/16/20/24；圓角 12 或 20，`.continuous`。
- [ ] 次要文字都是 `.secondary`；accent 沒有用在資料值上。
- [ ] 數字都是 `monospacedDigit`；同一個值在各處格式相同。
- [ ] 重用了第 6 節的元件，沒有新增重複的實作。
- [ ] 互動有觸覺或轉場，而且只在使用者動作時觸發。
- [ ] 空狀態、錯誤、載入中、長名稱、大數字、多照片都看過。
- [ ] 亮色、暗色、最大字級、三語都實際截圖並打開檢查（UX-QUALITY 流程）。
- [ ] 第 11 節反模式逐條對照過。

## 13. 委派 UI 工作給其他 agent

這份文件的反模式大多來自委派出去的實作。交辦 UI 工作時：

1. 在任務說明裡指定要讀這份文件與 `docs/UX-QUALITY.md`，並列出要對照的第 11 節條目。
2. 明確寫出可編輯的檔案。共用的字串值、`project.pbxproj`、SPEC 段落各指定一個 owner。
3. 要求 before / after 截圖都實際打開檢查，並把截圖路徑寫進報告；不能只回報「測試通過」。
4. 收回後由協調者自己 review diff，特別是共用字串、匯出內容、觸覺 trigger、測試是否被放寬，以及跨畫面的副作用。
5. 改到相同畫面的多個 PR，依序合併，並在合併後的 main 上重新看一次實際畫面。

### 待決策事項（實作前先問使用者）

- 數值顯示小數位要固定位數，還是依輸入的位數自動顯示。
- 「今天」與「項目」分頁是否合併。
- 已設定的目標要怎麼移除，以及移除後在目標歷史中的語意。
- 卡片文字預設角落（目前是右下）。
- 達成目標時是否彈出完成卡片。
