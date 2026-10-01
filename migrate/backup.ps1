#Requires -Version 5.1
<#
.SYNOPSIS
  Claude / Claude Code 搬家：舊電腦「打包」腳本（在舊電腦被收走前執行）

.DESCRIPTION
  把這台電腦上「不會自動跟著 Claude 帳號 / GitHub / OneDrive 走」的東西打包成兩個檔案：
    1. 搬家包_<時間>.zip      — Claude 設定、skills、hooks、auto-memory、對話紀錄、
                                 非 git 專案資料夾、私人資料、環境清單（不含密鑰）
    2. 搬家包_<時間>.secrets.tar.enc — 密鑰（AES-256 加密，需密碼）
  預設輸出到 OneDrive\搬家包\，OneDrive 同步完成後即可在新電腦用 restore.ps1 還原。

.PARAMETER Dest            輸出資料夾（預設 OneDrive\搬家包）
.PARAMETER SkipTranscripts 不打包 Claude Code 對話紀錄（約 160MB）
.PARAMETER SkipPrivate     不打包私人資料（shangfu、Documents\NotebookLM、Desktop\AI…）
.PARAMETER SkipSecrets     不打包密鑰（新機就得全部重新申請/登入）
.PARAMETER Force           有未 commit / 未 push 的 repo 也照打包（不建議）
.PARAMETER DryRun          只列出會做什麼，不實際寫檔
.PARAMETER Password        加密密碼（測試用；正式執行請留空，改用互動輸入）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File backup.ps1 -DryRun
  powershell -ExecutionPolicy Bypass -File backup.ps1
#>
[CmdletBinding()]
param(
    [string]$Dest = (Join-Path $env:OneDrive '搬家包'),
    [switch]$SkipTranscripts,
    [switch]$SkipPrivate,
    [switch]$SkipSecrets,
    [switch]$Force,
    [switch]$DryRun,
    [string]$Password
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [Text.Encoding]::UTF8

# 讓 .NET（powershell.exe 預設為舊式路徑處理）接受 \?\ 長路徑前綴；必須在任何 System.IO 呼叫前執行
try {
    [AppContext]::SetSwitch('Switch.System.IO.UseLegacyPathHandling', $false)
    [AppContext]::SetSwitch('Switch.System.IO.BlockLongPaths', $false)
    $acs = [System.AppContext].Assembly.GetType('System.AppContextSwitches')
    $acs.GetField('_useLegacyPathHandling', 'NonPublic,Static').SetValue($null, -1)
    $acs.GetField('_blockLongPaths', 'NonPublic,Static').SetValue($null, -1)
} catch { Write-Host "[!!] 無法啟用長路徑支援，超過 260 字元的檔案可能會失敗：$($_.Exception.Message)" -ForegroundColor Yellow }

# ---------- 共用 ----------
$HomeDir   = $env:USERPROFILE
$Stamp     = Get-Date -Format 'yyyyMMdd-HHmm'
$StageName = "migrate-stage-$Stamp"
$Stage     = Join-Path $env:TEMP $StageName       # 暫存區放 TEMP（純英文路徑、不進 OneDrive 同步），最後才壓成一個 zip 到 $Dest
$StageHome = Join-Path $Stage 'home'          # 與 %USERPROFILE% 1:1 對應的檔案
$StageMeta = Join-Path $Stage 'meta'          # 清單、匯出、說明
$StageUntracked = Join-Path $Stage 'repo-untracked'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Summary   = New-Object System.Collections.ArrayList
$Warnings  = New-Object System.Collections.ArrayList

function Step($t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    [OK] $t" -ForegroundColor Green; [void]$Summary.Add($t) }
function Warn($t) { Write-Host "    [!!] $t" -ForegroundColor Yellow; [void]$Warnings.Add($t) }
function Info($t) { Write-Host "    $t" -ForegroundColor Gray }
function Fail($t) { Write-Host ""; Write-Host "[X] $t" -ForegroundColor Red; exit 1 }

function Get-RelHome([string]$p) {
    $full = [IO.Path]::GetFullPath($p)
    if ($full.StartsWith($HomeDir, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($HomeDir.Length).TrimStart('\')
    }
    throw "不在使用者資料夾內：$p"
}

function Ensure-Dir([string]$p) {
    if ($DryRun) { return }
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# Windows 長路徑：.NET 要加 \?\ 前綴才能處理超過 260 字元的路徑（plugins cache 內有很深的檔案）
$LongPrefix = '\\?' + '\'
function Get-LongPath([string]$p) { if ($p.StartsWith($LongPrefix)) { return $p } else { return $LongPrefix + $p } }

# 刪整棵樹（含長路徑）：先用 robocopy 從空資料夾鏡像清空，再刪空殼
function Remove-Tree([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return }
    $empty = Join-Path $env:TEMP ("empty-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    & robocopy $empty $p /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
}

# robocopy：exit code 0-7 都算成功
function Copy-Tree([string]$src, [string]$dst, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @()) {
    if (-not (Test-Path -LiteralPath $src)) { Warn "來源不存在，略過：$src"; return }
    $rc = @($src, $dst, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/NC', '/NS', '/XJ')
    $xd = @('node_modules', '__pycache__', '.venv', 'venv', 'desktop.ini') + $ExcludeDirs
    $xf = @('desktop.ini', 'Thumbs.db', '*.log') + $ExcludeFiles
    $rc += '/XD'; $rc += $xd
    $rc += '/XF'; $rc += $xf
    if ($DryRun) { $rc += '/L' }
    & robocopy @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy 失敗 (code $LASTEXITCODE)：$src" }
}

function Copy-HomeTree([string]$src, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @()) {
    $rel = Get-RelHome $src
    Copy-Tree $src (Join-Path $StageHome $rel) $ExcludeDirs $ExcludeFiles
    Ok "資料夾  ~\$rel"
}

function Copy-HomeFile([string]$src) {
    if (-not (Test-Path -LiteralPath $src)) { Warn "檔案不存在，略過：$src"; return }
    $rel = Get-RelHome $src
    $dst = Join-Path $StageHome $rel
    Ensure-Dir (Split-Path $dst -Parent)
    if (-not $DryRun) { Copy-Item -LiteralPath $src -Destination $dst -Force }
    Ok "檔案    ~\$rel"
}

function Save-Text([string]$name, $content) {
    $p = Join-Path $StageMeta $name
    Ensure-Dir $StageMeta
    if ($DryRun) { Info "(dry) 寫入 meta\$name"; return }
    $text = if ($content -is [string]) { $content } else { ($content | Out-String) }
    [IO.File]::WriteAllText($p, $text, $Utf8NoBom)
}

function Find-GitRepos([string]$root, [int]$maxDepth) {
    $skip = @('AppData', 'node_modules', '.claude', 'Application Data', 'Cookies', 'Local Settings',
              'NetHood', 'PrintHood', 'Recent', 'SendTo', 'Templates', '「開始」功能表', 'Start Menu',
              '.notebooklm-mcp-cli', '.local', '.cache', '.vscode', 'Pictures', 'Music', 'Videos', '圖片', '音樂', '影片')
    $found = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@{ Path = $root; Depth = 0 })
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        $dirs = @()
        try { $dirs = Get-ChildItem -LiteralPath $cur.Path -Directory -Force -ErrorAction Stop } catch { continue }
        foreach ($d in $dirs) {
            if ($d.LinkType) { continue }   # 跳過 junction / symlink（OneDrive 資料夾也是 ReparsePoint，但 LinkType 為空，不能用 Attributes 判斷）
            if ($d.Name -eq '.git') { [void]$found.Add($cur.Path); continue }
            if ($skip -contains $d.Name) { continue }
            if ($cur.Depth + 1 -le $maxDepth) { $queue.Enqueue(@{ Path = $d.FullName; Depth = $cur.Depth + 1 }) }
        }
    }
    return $found
}

# =====================================================================
Write-Host ""
Write-Host "Claude / Claude Code 搬家打包  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor White
Write-Host "輸出：$Dest" -ForegroundColor White
if ($DryRun) { Write-Host "（DryRun：只列不做）" -ForegroundColor Yellow }

if (-not $env:OneDrive -and $Dest -like '*搬家包') { Fail "找不到 OneDrive 環境變數，請用 -Dest 指定輸出位置" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail "找不到 git，無法檢查 repo 狀態" }

# ---------- 步驟 0：git repo 健檢 ----------
Step "0. 掃描 git repo（確認都已 commit + push）"
$repos = Find-GitRepos $HomeDir 3
$repoList = New-Object System.Collections.ArrayList
$blockers = New-Object System.Collections.ArrayList
foreach ($r in $repos) {
    $rel = Get-RelHome $r
    $remote = (& git -C $r remote get-url origin 2>$null)
    $branch = (& git -C $r rev-parse --abbrev-ref HEAD 2>$null)
    $status = @(& git -c core.quotepath=off -C $r status --porcelain 2>$null)
    $untracked = @($status | Where-Object { $_ -like '?? *' } | ForEach-Object { $_.Substring(3).Trim('"') })
    $modified  = @($status | Where-Object { $_ -notlike '?? *' })
    $unpushed  = @(& git -C $r log --branches --not --remotes --oneline 2>$null)
    $inOneDrive = $r.StartsWith($env:OneDrive, [StringComparison]::OrdinalIgnoreCase)
    [void]$repoList.Add([ordered]@{
        rel = $rel; remote = $remote; branch = $branch
        modified = $modified.Count; untracked = $untracked.Count; unpushed = $unpushed.Count
        inOneDrive = $inOneDrive
    })
    $flag = ''
    if ($modified.Count -gt 0) { $flag += " 未commit:$($modified.Count)" }
    if ($unpushed.Count -gt 0) { $flag += " 未push:$($unpushed.Count)" }
    if ($untracked.Count -gt 0) { $flag += " 未追蹤:$($untracked.Count)" }
    if (-not $remote) { $flag += " 無remote" }
    if ($flag) { Warn "~\$rel ->$flag" } else { Info "~\$rel  OK  ($remote)" }

    if ($modified.Count -gt 0 -or $unpushed.Count -gt 0 -or -not $remote) { [void]$blockers.Add("~\$rel$flag") }

    # 未追蹤檔案不會在 GitHub 上，另外存一份
    if ($untracked.Count -gt 0) {
        foreach ($u in $untracked) {
            $srcU = Join-Path $r $u
            $dstU = Join-Path (Join-Path $StageUntracked $rel) $u
            if (Test-Path -LiteralPath $srcU -PathType Container) {
                Copy-Tree $srcU $dstU
            } else {
                Ensure-Dir (Split-Path $dstU -Parent)
                if (-not $DryRun) { Copy-Item -LiteralPath $srcU -Destination $dstU -Force }
            }
        }
        Ok "repo 未追蹤檔案已另存：~\$rel ($($untracked.Count) 項)"
    }
}
if ($blockers.Count -gt 0 -and -not $Force) {
    Write-Host ""
    Write-Host "以下 repo 還有未 commit / 未 push 的變更，搬家會遺失：" -ForegroundColor Red
    $blockers | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
    Fail "請先在各 repo 執行 git add/commit/push（或對 Claude 說「收工」），再重跑。確定要忽略就加 -Force。"
}

# ---------- 步驟 1：Claude Code 使用者層設定 ----------
Step "1. Claude Code 使用者層設定（~\.claude）"
$dotClaude = Join-Path $HomeDir '.claude'
Copy-HomeFile (Join-Path $dotClaude 'settings.json')
foreach ($opt in @('CLAUDE.md', 'keybindings.json', 'statusline.sh', 'statusline.ps1')) {
    $p = Join-Path $dotClaude $opt
    if (Test-Path -LiteralPath $p) { Copy-HomeFile $p }
}
Copy-HomeTree (Join-Path $dotClaude 'skills')
Copy-HomeTree (Join-Path $dotClaude 'scripts') @() @('*.log')
Copy-HomeTree (Join-Path $dotClaude 'scheduled-tasks')
Copy-HomeTree (Join-Path $dotClaude 'plugins')          # 含 cache，新機免重抓
# auto-memory（每個專案一個資料夾）
$projRoot = Join-Path $dotClaude 'projects'
$projDirs = @(Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue)
foreach ($pd in $projDirs) {
    $mem = Join-Path $pd.FullName 'memory'
    if (Test-Path -LiteralPath $mem) { Copy-HomeTree $mem }
    if (-not $SkipTranscripts) {
        # 對話紀錄 jsonl + 子目錄（含 memory，重複 copy 無妨）
        Copy-HomeTree $pd.FullName
    }
}
if ($SkipTranscripts) { Info "（已略過對話紀錄）" }
else {
    $ccs = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    if (Test-Path -LiteralPath $ccs) { Copy-HomeTree $ccs }
}
# ~/.claude.json 只留參考（含帳號快取，新機登入會重建）
$cj = Join-Path $HomeDir '.claude.json'
if (Test-Path -LiteralPath $cj) {
    Ensure-Dir $StageMeta
    if (-not $DryRun) { Copy-Item -LiteralPath $cj -Destination (Join-Path $StageMeta 'claude.json.reference') -Force }
    Ok "~\.claude.json 已存為參考（不直接還原）"
}
# Claude Desktop 偏好
$cdc = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
if (Test-Path -LiteralPath $cdc) { Copy-HomeFile $cdc }

# ---------- 步驟 2：專案層設定 + 非 git 專案 ----------
Step "2. notebookLM 工作目錄（專案層設定 + 沒有 git 的資料夾）"
$nb = Join-Path $HomeDir 'notebookLM'
$repoRels = @($repoList | ForEach-Object { $_.rel })
Copy-HomeFile (Join-Path $nb '.mcp.json')               # 內含 token，還原時會重寫；原檔只作參考
Copy-HomeTree (Join-Path $nb '.claude')
foreach ($e in @(Get-ChildItem -LiteralPath $nb -Force -ErrorAction SilentlyContinue)) {
    if ($e.Name -in @('.mcp.json', '.claude')) { continue }
    $rel = Get-RelHome $e.FullName
    if ($e.PSIsContainer) {
        if ($repoRels -contains $rel) { Info "git repo，交給 GitHub：~\$rel"; continue }
        Copy-HomeTree $e.FullName @() @('.env.local', '.env')   # .env 走密鑰包
    } else {
        if ($e.Extension -eq '.log') { continue }
        Copy-HomeFile $e.FullName
    }
}

# ---------- 步驟 3：其他本機工具設定 ----------
Step "3. 其他工具設定"
foreach ($p in @(
    (Join-Path $HomeDir '.gitconfig'),
    (Join-Path $HomeDir '.agent-reach')
)) {
    if (Test-Path -LiteralPath $p -PathType Container) { Copy-HomeTree $p }
    elseif (Test-Path -LiteralPath $p) { Copy-HomeFile $p }
}

# ---------- 步驟 4：私人資料 ----------
Step "4. 私人資料（不在 GitHub 也不在 OneDrive 的）"
if ($SkipPrivate) { Info "（已略過）" }
else {
    foreach ($p in @(
        (Join-Path $HomeDir 'shangfu'),
        (Join-Path $HomeDir 'Documents\NotebookLM'),
        (Join-Path $HomeDir 'Documents\Obsidian Vault'),
        (Join-Path $HomeDir 'Desktop\AI'),
        (Join-Path $HomeDir 'Claude')
    )) {
        if (Test-Path -LiteralPath $p) { Copy-HomeTree $p @('.git') } else { Info "不存在，略過：$p" }
    }
}

# ---------- 步驟 4.5：明文區遮蔽 token ----------
Step "4.5 遮蔽明文區的 token（.mcp.json / 權限白名單 / 對話紀錄；正本在加密包）"
if ($DryRun) { Info "(dry) 會執行 redact.ps1 -StageHome" }
else { & (Join-Path $PSScriptRoot 'redact.ps1') -StageHome $StageHome }

# ---------- 步驟 5：環境清單 ----------
Step "5. 環境清單（給 restore.ps1 與人看）"
Ensure-Dir $StageMeta
$claudeVer = ''
try { $claudeVer = (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'AnthropicClaude') -Directory -Filter 'app-*' | Sort-Object Name | Select-Object -Last 1).Name } catch {}
function Try-Cmd([scriptblock]$sb) { try { & $sb 2>&1 | Out-String } catch { "（失敗：$($_.Exception.Message)）" } }
Save-Text 'winget-list.txt'   (Try-Cmd { winget list --source winget })
Save-Text 'pip-freeze.txt'    (Try-Cmd { python -m pip freeze })
Save-Text 'npm-global.txt'    (Try-Cmd { npm ls -g --depth=0 })
Save-Text 'uv-tools.txt'      (Try-Cmd { uv tool list })
Save-Text 'gitconfig.txt'     (Try-Cmd { git config --global --list })
Save-Text 'user-path.txt'     ([Environment]::GetEnvironmentVariable('Path', 'User'))
Save-Text 'user-env-names.txt' (([Environment]::GetEnvironmentVariables('User').Keys | Sort-Object) -join "`n")
Save-Text 'scheduled-tasks.txt' (Try-Cmd { Get-ScheduledTask | Where-Object { $_.TaskPath -eq '\' } | Select-Object TaskName, State | Format-Table -AutoSize })
try {
    $xml = Export-ScheduledTask -TaskName 'Supabase-KeepAlive' -ErrorAction Stop
    Save-Text 'task-Supabase-KeepAlive.xml' $xml
    Ok "工作排程 Supabase-KeepAlive 已匯出"
} catch { Warn "匯出工作排程 Supabase-KeepAlive 失敗：$($_.Exception.Message)" }
$obsVaults = @()
try {
    $oj = Get-Content (Join-Path $env:APPDATA 'obsidian\obsidian.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $obsVaults = @($oj.vaults.PSObject.Properties | ForEach-Object { $_.Value.path })
} catch {}
$mcpNames = @()
try { $mcpNames = @(((Get-Content (Join-Path $nb '.mcp.json') -Raw -Encoding UTF8) | ConvertFrom-Json).mcpServers.PSObject.Properties.Name) } catch {}

$manifest = [ordered]@{
    created        = (Get-Date).ToString('s')
    computer       = $env:COMPUTERNAME
    user           = $env:USERNAME
    home           = $HomeDir
    oneDrive       = $env:OneDrive
    claudeDesktop  = $claudeVer
    node           = (Try-Cmd { node --version }).Trim()
    python         = (Try-Cmd { python --version }).Trim()
    mcpServers     = $mcpNames
    obsidianVaults = $obsVaults
    repos          = @($repoList)
    transcripts    = (-not $SkipTranscripts)
    private        = (-not $SkipPrivate)
    secrets        = (-not $SkipSecrets)
    pipPackages    = @('msvc-runtime', 'markitdown', 'markitdown-mcp', 'agent-reach', 'openai', 'pandas', 'openpyxl',
                       'pdfplumber', 'pillow', 'pillow_heif', 'yt-dlp', 'requests', 'numpy')
    npmGlobal      = @('@bitbonsai/mcpvault', 'vercel', 'mcporter')
    uvTools        = @('notebooklm-mcp-cli')
    wingetIds      = @('Git.Git', 'GitHub.cli', 'OpenJS.NodeJS', 'Python.Python.3.12', 'Gyan.FFmpeg', 'Obsidian.Obsidian', 'Anthropic.Claude')
}
Save-Text 'manifest.json' ($manifest | ConvertTo-Json -Depth 6)
Ok "manifest.json"

# ---------- 步驟 6：密鑰（加密） ----------
Step "6. 密鑰（AES-256 加密成 .secrets.tar.enc）"
$secretsOut = $null
if ($SkipSecrets) { Info "（已略過，新機需全部重新登入/申請）" }
else {
    $git = (Get-Command git).Source
    $gitRoot = Split-Path (Split-Path $git -Parent) -Parent
    $ssl = @((Join-Path $gitRoot 'usr\bin\openssl.exe'), 'C:\Program Files\Git\usr\bin\openssl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $ssl) { $c = Get-Command openssl -ErrorAction SilentlyContinue; if ($c) { $ssl = $c.Source } }
    $tar = 'C:\Windows\System32\tar.exe'
    if (-not $ssl) { Fail "找不到 openssl.exe（Git for Windows 內建），無法加密密鑰" }
    if (-not (Test-Path $tar)) { Fail "找不到 $tar" }

    $tmp = Join-Path $env:TEMP "migrate-secrets-$Stamp"
    $tmpHome = Join-Path $tmp 'home'
    $included = New-Object System.Collections.ArrayList
    function Add-Secret([string]$src) {
        if (-not (Test-Path -LiteralPath $src)) { Warn "密鑰不存在，略過：$src"; return }
        $rel = Get-RelHome $src
        $dst = Join-Path $tmpHome $rel
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        [void]$included.Add("~\$rel"); Info "+ ~\$rel"
    }
    Add-Secret (Join-Path $HomeDir '.firebase-keys\my-teaching-tools-sa.json')
    Add-Secret (Join-Path $HomeDir '.notebooklm-mcp-cli\auth.json')
    Add-Secret (Join-Path $env:APPDATA 'com.vercel.cli\Data\auth.json')
    foreach ($envf in @(Get-ChildItem -LiteralPath $nb -Recurse -Depth 2 -Force -Filter '.env*' -File -ErrorAction SilentlyContinue)) {
        if ($envf.FullName -match '\\node_modules\\') { continue }
        Add-Secret $envf.FullName
    }
    # 環境變數 / token 類
    $envLines = New-Object System.Collections.ArrayList
    $gem = [Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User')
    if ($gem) { [void]$envLines.Add("GEMINI_API_KEY=$gem"); [void]$included.Add('env:GEMINI_API_KEY'); Info "+ env GEMINI_API_KEY" }
    try {
        $mcp = (Get-Content (Join-Path $nb '.mcp.json') -Raw -Encoding UTF8) | ConvertFrom-Json
        $sb = $mcp.mcpServers.supabase.env.SUPABASE_ACCESS_TOKEN
        if ($sb) { [void]$envLines.Add("SUPABASE_ACCESS_TOKEN=$sb"); [void]$included.Add('SUPABASE_ACCESS_TOKEN (.mcp.json)'); Info "+ SUPABASE_ACCESS_TOKEN" }
    } catch { Warn "讀不到 .mcp.json 內的 SUPABASE_ACCESS_TOKEN" }
    $ghTok = ''
    try { $ghTok = (& gh auth token 2>$null) } catch {}
    if ($ghTok) { [void]$envLines.Add("GH_TOKEN=$ghTok"); [void]$included.Add('GH_TOKEN (gh auth token)'); Info "+ GitHub CLI token" }
    else { Warn "拿不到 gh token，新機請自行 gh auth login" }

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $tmp 'env.txt'), (($envLines -join "`n") + "`n"), $Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $tmp 'secrets-manifest.txt'), (($included -join "`n") + "`n"), $Utf8NoBom)

        # 密碼
        $pw = $Password
        if (-not $pw) {
            while ($true) {
                $s1 = Read-Host -AsSecureString "請設定密鑰包密碼（新機還原時要輸入，請記在腦袋或手機）"
                $s2 = Read-Host -AsSecureString "再輸入一次確認"
                $p1 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($s1))
                $p2 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($s2))
                if ($p1 -and $p1 -eq $p2 -and $p1.Length -ge 8) { $pw = $p1; break }
                Write-Host "    兩次不一致或少於 8 碼，再來一次" -ForegroundColor Yellow
            }
        }
        $tarPath = Join-Path $tmp 'secrets.tar'
        Push-Location $tmp
        try { & $tar -cf $tarPath 'home' 'env.txt' 'secrets-manifest.txt' } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { Fail "tar 打包密鑰失敗" }
        Ensure-Dir $Dest
        $secretsOut = Join-Path $Dest "搬家包_$Stamp.secrets.tar.enc"
        $env:MIGRATE_PW = $pw
        try {
            & $ssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -in $tarPath -out $secretsOut -pass env:MIGRATE_PW
            if ($LASTEXITCODE -ne 0) { Fail "openssl 加密失敗" }
        } finally {
            Remove-Item Env:\MIGRATE_PW -ErrorAction SilentlyContinue
            Remove-Tree $tmp
        }
        Ok "密鑰包：$secretsOut  ($([math]::Round((Get-Item $secretsOut).Length/1KB)) KB)"
    } else { Info "(dry) 會加密 $($included.Count) 項到 $Dest\搬家包_$Stamp.secrets.tar.enc" }
}

# ---------- 步驟 7：說明 + 壓縮 ----------
Step "7. 寫入說明並壓縮"
$readme = @"
# 搬家包 $Stamp

來源電腦：$($env:COMPUTERNAME)  使用者：$($env:USERNAME)  家目錄：$HomeDir
建立時間：$(Get-Date -Format 'yyyy-MM-dd HH:mm')

## 內容
- home\        → 直接對應到新電腦的 %USERPROFILE%（restore.ps1 會複製回去）
- meta\        → 環境清單、manifest.json、工作排程 XML、.claude.json 參考
- repo-untracked\ → 各 git repo 內「未追蹤」的檔案（GitHub 上沒有）
- 密鑰另外放在同層的 搬家包_$Stamp.secrets.tar.enc（需密碼）

## git repo（新機由 restore.ps1 重新 clone）
$(($repoList | ForEach-Object { "- ~\$($_.rel)  ←  $($_.remote)" }) -join "`n")

## 新電腦還原
1. 登入 OneDrive（私人帳號），等「搬家包」資料夾同步完成
2. 關閉 Claude Desktop
3. powershell -ExecutionPolicy Bypass -File "`$env:OneDrive\ares-tools\migrate\restore.ps1"
   （ares-tools 也在 OneDrive，會一起同步下來；或從 GitHub Ares-1215/ares-tools 取得）
4. 照 restore.ps1 最後列出的手動清單逐項確認

## 警告
$(if ($Warnings.Count) { ($Warnings | ForEach-Object { "- $_" }) -join "`n" } else { '- 無' })
"@
Save-Text 'README.md' $readme

$zipPath = Join-Path $Dest "搬家包_$Stamp.zip"
if ($DryRun) { Info "(dry) 會壓縮 $Stage → $zipPath" }
else {
    Ensure-Dir $Dest
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    $zipSrc = Get-LongPath $Stage
    Info "來源：[$zipSrc]"
    Info "目的：[$zipPath]"
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory($zipSrc, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false, [Text.Encoding]::UTF8)
    } catch {
        $ie = $_.Exception.InnerException
        if ($ie) { Write-Host "    壓縮失敗：$($ie.GetType().Name): $($ie.Message)" -ForegroundColor Red; Write-Host $ie.StackTrace -ForegroundColor DarkGray }
        Fail "壓縮失敗。暫存資料夾保留在 $Stage，可手動壓縮後再刪。"
    }
    Remove-Tree $Stage
    Ok "壓縮包：$zipPath  ($([math]::Round((Get-Item $zipPath).Length/1MB)) MB)"
}

# ---------- 結尾 ----------
Write-Host ""
Write-Host "================ 完成 ================" -ForegroundColor Green
Write-Host "  $zipPath"
if ($secretsOut) { Write-Host "  $secretsOut" }
if ($Warnings.Count) {
    Write-Host ""
    Write-Host "警告 ($($Warnings.Count))：" -ForegroundColor Yellow
    $Warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
Write-Host ""
Write-Host "交機前請務必確認：" -ForegroundColor White
Write-Host "  1. OneDrive 右下角圖示顯示「已同步」（搬家包很大，可能要等幾分鐘）"
Write-Host "  2. 到 onedrive.live.com 用瀏覽器看得到「搬家包」裡的 .zip 與 .enc"
Write-Host "  3. 密鑰包密碼記好；忘了就只能全部重新申請"
Write-Host "  4. 保險起見再複製一份到隨身碟"
