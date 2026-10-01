# Claude / Claude Code 換電腦搬家手冊

> 情境：2027 年過年後從彰化轉運中心北調新豐總公司運務處，公司主機換新、舊機先收走（無重疊期）。
> Windows 登入工號不變（C:\Users\26516），OneDrive 是私人帳號（會跟著走）。

## 一句話結論

**可以接近無縫，但不是「登入就全部回來」。** 跟著帳號走的只有 claude.ai 雲端那一半；
Claude Code 在本機的記憶、skills、hooks、MCP 設定、密鑰、沒上 GitHub 的專案，全部只存在這台電腦的硬碟上，
必須在交機前用 `backup.ps1` 打包到 OneDrive，新機再用 `restore.ps1` 還原。

## 哪些會自動跟著走（不用管）

| 東西 | 靠什麼走 |
|---|---|
| claude.ai 對話紀錄、claude.ai 的 Memory、Projects、Artifacts | Claude 帳號（aa0982166464@gmail.com） |
| Cowork 連接器：Gmail、Google Drive、Claude Docs、排程任務（routines） | Claude 帳號 |
| 17 個 git repo（work-hub、attendance、misload、run-board…） | GitHub Ares-1215，全部乾淨且已 push |
| ares-tools 工作桌、secondbrain（Obsidian vault）、誤裝誤訂、work-hub備份 | OneDrive 私人帳號 |
| Supabase、Firebase、Vercel、NotebookLM、GitHub Pages 上的網站與資料 | 都在雲端，只需要金鑰 / 登入 |

## 哪些不會自動走（腳本負責）

| 類別 | 位置 | 搬法 |
|---|---|---|
| Claude Code auto-memory（39 個記憶檔，含 MEMORY.md 索引） | `~\.claude\projects\C--Users-26516-notebookLM\memory` | zip |
| 使用者層設定：hooks（SessionEnd 自動 commit）、enabledPlugins | `~\.claude\settings.json` + `~\.claude\scripts\session-cleanup.sh` | zip |
| 9 個 skills（startup / shutdown / draw / agent-reach / 設計品味…） | `~\.claude\skills` | zip |
| 外掛快取（frontend-design + marketplaces） | `~\.claude\plugins` | zip（300MB，免重抓） |
| Claude Code 對話紀錄（Code 分頁的歷史 session） | `~\.claude\projects\...\*.jsonl` + `AppData\Roaming\Claude\claude-code-sessions` | zip（可用 -SkipTranscripts 省掉） |
| 專案層設定：5 個 MCP（notebooklm / obsidian / supabase / firebase / markitdown）、權限白名單、launch.json | `notebookLM\.mcp.json`、`notebookLM\.claude\` | zip；.mcp.json 在新機依實際路徑**重寫** |
| 沒有 git 的專案：aoi-farewell、sunrise-0703（兩個 Vercel 站只有本機有原始碼！）、face-attendance、firebase-web、nba-video-pipeline、photo-organizer | `notebookLM\` | zip |
| 私人資料：shangfu（LINE/IG 匯出）、Documents\NotebookLM（成果）、Desktop\AI（懶人包 + zip）、Documents\Obsidian Vault | 各處 | zip（可用 -SkipPrivate 省掉） |
| 密鑰：Firebase 服務帳戶金鑰、GEMINI_API_KEY、Supabase PAT、兩個 .env.local（Vercel token）、gh token、nlm 登入、vercel 登入 | 各處 | **另外加密**成 .secrets.tar.enc |
| 工作排程 Supabase-KeepAlive（每週一 09:00） | Windows 工作排程器 | 匯出 XML，新機重建 |
| 工具本身：Git、GitHub CLI、Node 26、Python 3.12、FFmpeg、Obsidian、Claude Desktop、uv + notebooklm-mcp-cli、pip 套件、npm 全域套件 | 各處 | 新機用 winget / uv / pip / npm 重裝 |

## 流程

### A. 交機前（舊電腦，約 10 分鐘）

1. 把手上的工作收乾淨：各 repo `git push`，或對 Claude 說「收工」。
2. 先乾跑看清單：
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:OneDrive\ares-tools\migrate\backup.ps1" -DryRun
   ```
3. 正式打包（會要你設一組密鑰包密碼，**記在手機**）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:OneDrive\ares-tools\migrate\backup.ps1"
   ```
   產出在 `OneDrive\搬家包\`：`搬家包_<時間>.zip`（約 600–700MB）＋ `搬家包_<時間>.secrets.tar.enc`（約 30KB）。
4. 等 OneDrive 右下角顯示「已同步」，再用瀏覽器到 onedrive.live.com 確認兩個檔案都在。
5. 保險：再複製一份到隨身碟。

腳本若發現有 repo 未 commit / 未 push 會直接停下來，不會讓你帶著遺漏交機。

### B. 新電腦（新豐，約 30–60 分鐘，大多在等安裝）

1. 登入 Windows（同工號）→ 登入 OneDrive 私人帳號 → 等 `搬家包` 和 `ares-tools` 兩個資料夾同步下來。
2. 若 winget 裝不了 Claude Desktop，先手動從 claude.ai/download 裝好並登入同一個帳號，然後**完全關閉** Claude。
3. 執行還原（會問密鑰包密碼）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:OneDrive\ares-tools\migrate\restore.ps1"
   ```
   可以分段跑：`-Phase tools`、`-Phase files,secrets`、`-Phase repos,tasks`、`-Phase verify`。
4. 照腳本最後印出的「接下來請手動完成」清單逐項做（開 Claude 登入、/mcp 檢查、Obsidian 開 vault、nlm login 等）。

### C. 新機必做的手動項目

- Claude Desktop 登入同一帳號；Claude Code 分頁開 `C:\Users\26516\notebookLM`，信任 `.mcp.json`，`/mcp` 看 5 個都連上。
- Obsidian 開 vault `OneDrive\secondbrain`（舊機 Obsidian 登錄的是 `Documents\Obsidian Vault`、MCP 用的卻是 `OneDrive\secondbrain`，新機統一用後者）。
- `nlm doctor`，Google 登入過期就 `nlm login`。
- `vercel whoami`，失效就 `vercel login`。
- `gh auth status`，若舊 token 失效就 `gh auth login` → `gh auth setup-git`。
- 說一次「開工」，確認 startup skill 讀得到工作筆記；說一次「收工」，確認 SessionEnd hook 會自動 commit。

## 風險與注意

- **新豐的網路不一定跟彰化一樣。** 彰化這邊公司 TLS 攔截擋了 Google Drive、免費生圖、uv 預設憑證；新豐可能更鬆或更緊。restore 的 verify 階段會打 6 個端點測試，失敗的照 Obsidian 踩雷筆記處理。
- **密碼忘了＝密鑰全部重來。** 重來的代價：Firebase 控制台重下載服務帳戶金鑰、Google AI Studio 重發 GEMINI key、Supabase 重發 PAT、Vercel 重新 login、`.env.local` 重建。都可重來，只是花時間。
- **公司新機若擋 winget `--scope user`**，腳本會自動改不帶 scope 再試；還是不行就要找資訊單位開權限。
- **若新機工號 / 家目錄不同**（例如不是 26516），restore 會自動改名 memory 專案鍵並改寫設定檔內的路徑，但建議還是用同工號。
- 搬家包放在私人 OneDrive，裡面有對話紀錄與私人資料；密鑰另外加密。搬完可以把 OneDrive 上的搬家包刪掉。
- `~\.claude.json`（帳號快取、實驗旗標）不還原，新機登入會重建；原檔留在 zip 的 `meta\claude.json.reference` 備查。

## 檔案說明

| 檔案 | 用途 |
|---|---|
| `backup.ps1` | 舊機打包。參數：`-DryRun`、`-SkipTranscripts`、`-SkipPrivate`、`-SkipSecrets`、`-Force`、`-Dest` |
| `restore.ps1` | 新機還原。參數：`-DryRun`、`-Phase tools/files/secrets/repos/tasks/verify`、`-Source`、`-Zip`、`-Secrets` |
| `README-搬家手冊.md` | 本文件 |

## 技術備註（給未來的 Claude）

- 兩支腳本都要 UTF-8 **含 BOM**，否則 Windows PowerShell 5.1 會把中文當 ANSI 讀壞。
- plugins cache 內有超過 260 字元的路徑：.NET ZipFile 要加 `\\?\` 前綴，腳本開頭已用 AppContext 開關關掉舊式路徑處理。
- `LP` 不能拿來當函式名（是 Out-Printer 的別名），所以叫 `Get-LongPath`。
- 刪長路徑資料夾用「robocopy 從空資料夾 /MIR 鏡像再 Remove-Item」。
- OneDrive 資料夾帶 ReparsePoint 屬性但 LinkType 為空，掃 repo 時用 LinkType 判斷才不會漏掉 ares-tools。
- 密鑰加密用 Git for Windows 內建的 openssl：`enc -aes-256-cbc -pbkdf2 -iter 200000`，密碼經環境變數傳入不留在命令列。
- 已於 2026-10-01 實測：打包（不含密鑰/私人資料）363MB 成功、restore -DryRun 全階段通過；密鑰加密段在第一次實測成功產出 30KB .enc。
