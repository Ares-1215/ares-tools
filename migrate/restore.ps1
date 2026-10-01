#Requires -Version 5.1
<#
.SYNOPSIS
  Claude / Claude Code 搬家：新電腦「還原」腳本

.DESCRIPTION
  讀取 backup.ps1 產生的 搬家包_<時間>.zip 與 .secrets.tar.enc，在新電腦上：
    tools   → 用 winget / uv / pip / npm 把工具裝回來
    files   → 把 ~\.claude（設定、skills、hooks、memory、對話紀錄）、專案設定、私人資料放回原位
    secrets → 解密密鑰：Firebase 金鑰、.env、GEMINI_API_KEY、Supabase token、gh / nlm / vercel 登入
    repos   → 依清單把 17 個 git repo clone 回原路徑，並補回未追蹤檔案
    tasks   → 重建工作排程 Supabase-KeepAlive
    verify  → 檢查版本、路徑，印出「必須手動做」的清單

  前提：新電腦已登入 Windows、已登入 OneDrive（私人帳號）且「搬家包」資料夾同步完成。
  執行前請關閉 Claude Desktop。

.PARAMETER Source   搬家包所在資料夾（預設 OneDrive\搬家包；自動挑最新的 zip）
.PARAMETER Zip      指定 zip 檔
.PARAMETER Secrets  指定 .secrets.tar.enc 檔
.PARAMETER Phase    要跑的階段，預設 all；可多選如 -Phase files,secrets
.PARAMETER DryRun   只列不做
.PARAMETER Password 密鑰包密碼（測試用；正式執行請留空）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File restore.ps1 -DryRun
  powershell -ExecutionPolicy Bypass -File restore.ps1
  powershell -ExecutionPolicy Bypass -File restore.ps1 -Phase verify
#>
[CmdletBinding()]
param(
    [string]$Source = (Join-Path $env:OneDrive '搬家包'),
    [string]$Zip,
    [string]$Secrets,
    [ValidateSet('all', 'tools', 'files', 'secrets', 'repos', 'tasks', 'verify')]
    [string[]]$Phase = @('all'),
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
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$HomeDir   = $env:USERPROFILE
$Stamp     = Get-Date -Format 'yyyyMMdd-HHmm'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Warnings  = New-Object System.Collections.ArrayList
$Manual    = New-Object System.Collections.ArrayList
$script:SupabaseToken = $null
$RunAll = $Phase -contains 'all'
function Want($p) { return ($RunAll -or ($Phase -contains $p)) }

function Step($t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    [OK] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    [!!] $t" -ForegroundColor Yellow; [void]$Warnings.Add($t) }
function Info($t) { Write-Host "    $t" -ForegroundColor Gray }
function Todo($t) { [void]$Manual.Add($t) }
function Fail($t) { Write-Host ""; Write-Host "[X] $t" -ForegroundColor Red; exit 1 }

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Has-Cmd($c) { return [bool](Get-Command $c -ErrorAction SilentlyContinue) }

function Copy-Tree([string]$src, [string]$dst, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @()) {
    if (-not (Test-Path -LiteralPath $src)) { return }
    $rc = @($src, $dst, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/NC', '/NS', '/XJ')
    if ($ExcludeDirs.Count)  { $rc += '/XD'; $rc += $ExcludeDirs }
    if ($ExcludeFiles.Count) { $rc += '/XF'; $rc += $ExcludeFiles }
    if ($DryRun) { $rc += '/L' }
    & robocopy @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy 失敗 (code $LASTEXITCODE)：$src → $dst" }
}

# Windows 長路徑：.NET 要加 \?\ 前綴
$LongPrefix = '\\?' + '\'
function Get-LongPath([string]$p) { if ($p.StartsWith($LongPrefix)) { return $p } else { return $LongPrefix + $p } }
function Remove-Tree([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return }
    $empty = Join-Path $env:TEMP ("empty-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    & robocopy $empty $p /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
}

function Get-OpenSsl {
    $cands = @()
    $g = Get-Command git -ErrorAction SilentlyContinue
    if ($g) { $cands += (Join-Path (Split-Path (Split-Path $g.Source -Parent) -Parent) 'usr\bin\openssl.exe') }
    $cands += 'C:\Program Files\Git\usr\bin\openssl.exe'
    $cands += (Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\openssl.exe')
    $hit = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $hit) { $c = Get-Command openssl -ErrorAction SilentlyContinue; if ($c) { $hit = $c.Source } }
    return $hit
}

# =====================================================================
Write-Host ""
Write-Host "Claude / Claude Code 搬家還原  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor White
Write-Host "家目錄：$HomeDir   階段：$($Phase -join ',')" -ForegroundColor White
if ($DryRun) { Write-Host "（DryRun：只列不做）" -ForegroundColor Yellow }

# ---------- 找搬家包並解壓 ----------
if (-not $Zip) {
    if (-not (Test-Path -LiteralPath $Source)) { Fail "找不到搬家包資料夾：$Source（OneDrive 同步好了嗎？）" }
    $z = Get-ChildItem -LiteralPath $Source -Filter '搬家包_*.zip' | Sort-Object Name | Select-Object -Last 1
    if (-not $z) { Fail "在 $Source 找不到 搬家包_*.zip" }
    $Zip = $z.FullName
}
if (-not $Secrets) {
    $base = [IO.Path]::GetFileNameWithoutExtension($Zip)
    $cand = Join-Path (Split-Path $Zip -Parent) "$base.secrets.tar.enc"
    if (Test-Path -LiteralPath $cand) { $Secrets = $cand }
}
Info "搬家包：$Zip"
if ($Secrets) { Info "密鑰包：$Secrets" } else { Warn "找不到對應的 .secrets.tar.enc，secrets 階段會略過" }

$Extract = Join-Path $env:TEMP "migrate-restore-$Stamp"
Add-Type -AssemblyName System.IO.Compression.FileSystem
Step "解壓到暫存：$Extract"
[IO.Compression.ZipFile]::ExtractToDirectory($Zip, (Get-LongPath $Extract), [Text.Encoding]::UTF8)
$StageHome = Join-Path $Extract 'home'
$StageMeta = Join-Path $Extract 'meta'
$StageUntracked = Join-Path $Extract 'repo-untracked'
$manifest = (Get-Content (Join-Path $StageMeta 'manifest.json') -Raw -Encoding UTF8) | ConvertFrom-Json
$OldHome = $manifest.home
Info "來源：$($manifest.computer)\$($manifest.user)  建立於 $($manifest.created)"
$HomeChanged = ($OldHome -ne $HomeDir)
if ($HomeChanged) { Warn "家目錄不同（舊 $OldHome → 新 $HomeDir），會自動改寫設定檔內的路徑" }

# =====================================================================
if (Want 'tools') {
    Step "tools：安裝工具"
    if (-not (Has-Cmd winget)) { Warn "沒有 winget，請先從 Microsoft Store 安裝「應用程式安裝程式」後重跑 -Phase tools" }
    else {
        $checks = @{
            'Git.Git' = 'git'; 'GitHub.cli' = 'gh'; 'OpenJS.NodeJS' = 'node'; 'Python.Python.3.12' = 'python'
            'Gyan.FFmpeg' = 'ffmpeg'; 'Obsidian.Obsidian' = $null; 'Anthropic.Claude' = $null
        }
        foreach ($id in $manifest.wingetIds) {
            $cmd = $checks[$id]
            $installed = $false
            if ($cmd -and (Has-Cmd $cmd)) { $installed = $true }
            elseif (-not $cmd) {
                $out = (& winget list --id $id -e --source winget 2>$null | Out-String)
                if ($out -match [regex]::Escape($id)) { $installed = $true }
            }
            if ($installed) { Info "已安裝：$id"; continue }
            if ($DryRun) { Info "(dry) winget install $id"; continue }
            Info "安裝 $id …"
            & winget install -e --id $id --source winget --scope user --accept-package-agreements --accept-source-agreements --silent | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Info "  --scope user 失敗，改不帶 scope 再試"
                & winget install -e --id $id --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Null
            }
            if ($LASTEXITCODE -eq 0) { Ok "winget $id" } else { Warn "winget 安裝 $id 失敗 (code $LASTEXITCODE)，請手動安裝" }
        }
        Refresh-Path
    }

    # python 的 Scripts 夾若沒進 PATH（python 不是 'python' 而是 WindowsApps 的假捷徑），提醒
    if (-not (Has-Cmd python)) { Warn "python 不在 PATH，pip 階段會失敗；請重開 PowerShell 或檢查 Python 安裝選項 Add to PATH" }

    # uv + notebooklm-mcp-cli
    if (-not $DryRun) {
        if (-not (Has-Cmd uv)) {
            try { Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression; Refresh-Path; Ok "uv" }
            catch { Warn "安裝 uv 失敗（公司 TLS？）：$($_.Exception.Message)" }
        }
        if (Has-Cmd uv) {
            $env:UV_NATIVE_TLS = '1'; $env:UV_SYSTEM_CERTS = '1'
            foreach ($t in $manifest.uvTools) {
                & uv tool install $t --with pip-system-certs --force 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Ok "uv tool $t" } else { Warn "uv tool install $t 失敗，之後請手動：uv tool install $t --with pip-system-certs" }
            }
            Refresh-Path
        }
    } else { Info "(dry) uv + $($manifest.uvTools -join ',')" }

    # pip
    if ((Has-Cmd python) -and -not $DryRun) {
        & python -m pip install --upgrade pip 2>&1 | Out-Null
        foreach ($p in $manifest.pipPackages) {
            & python -m pip install $p 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Ok "pip $p" }
            else {
                & python -m pip install $p --trusted-host pypi.org --trusted-host files.pythonhosted.org 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Ok "pip $p (trusted-host)" } else { Warn "pip install $p 失敗" }
            }
        }
    } elseif ($DryRun) { Info "(dry) pip: $($manifest.pipPackages -join ', ')" }

    # npm -g
    if ((Has-Cmd npm) -and -not $DryRun) {
        foreach ($p in $manifest.npmGlobal) {
            & npm install -g $p 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Ok "npm -g $p" } else { Warn "npm install -g $p 失敗（TLS？試 npm config set strict-ssl false 後重裝，裝完改回 true）" }
        }
    } elseif ($DryRun) { Info "(dry) npm -g: $($manifest.npmGlobal -join ', ')" }
}

# =====================================================================
if (Want 'files') {
    Step "files：還原 ~\.claude、專案設定、私人資料"
    $claudeRunning = [bool](Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)
    if ($claudeRunning -and -not $DryRun) { Fail "Claude Desktop 還開著，請先完全結束（系統匣右鍵 → Quit）再重跑 -Phase files" }
    if ($claudeRunning) { Warn "Claude Desktop 正在執行（正式跑時要先關）" }

    # 備份新機上已存在的關鍵檔
    $bk = Join-Path $HomeDir ".claude\backups\pre-restore-$Stamp"
    foreach ($f in @('.claude\settings.json', 'notebookLM\.mcp.json', 'notebookLM\.claude\settings.local.json')) {
        $p = Join-Path $HomeDir $f
        if (Test-Path -LiteralPath $p) {
            if (-not $DryRun) { New-Item -ItemType Directory -Path (Join-Path $bk (Split-Path $f -Parent)) -Force | Out-Null; Copy-Item -LiteralPath $p -Destination (Join-Path $bk $f) -Force }
            Info "新機原有 $f 已備份到 $bk"
        }
    }

    # 家目錄不同時：改名 auto-memory 專案資料夾（鍵值 = 專案路徑）
    if ($HomeChanged) {
        $oldKey = ($OldHome -replace '[:\\]', '-')
        $newKey = ($HomeDir -replace '[:\\]', '-')
        $projStage = Join-Path $StageHome '.claude\projects'
        foreach ($d in @(Get-ChildItem -LiteralPath $projStage -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name.StartsWith($oldKey)) {
                $nn = $newKey + $d.Name.Substring($oldKey.Length)
                if (-not $DryRun) { Rename-Item -LiteralPath $d.FullName -NewName $nn }
                Info "memory 專案鍵改名：$($d.Name) → $nn"
            }
        }
    }

    # 整棵 home 複製回去（.mcp.json 另外重寫）
    Copy-Tree $StageHome $HomeDir @() @('.mcp.json')
    Ok "home\ → $HomeDir"

    # 家目錄不同時：改寫文字設定內的舊路徑
    if ($HomeChanged -and -not $DryRun) {
        foreach ($f in @('notebookLM\.claude\settings.local.json', 'notebookLM\.claude\launch.json', 'notebookLM\supabase-keepalive.ps1', '.claude\settings.json')) {
            $p = Join-Path $HomeDir $f
            if (Test-Path -LiteralPath $p) {
                $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
                $t2 = $t.Replace($OldHome, $HomeDir).Replace(($OldHome -replace '\\', '\\\\'), ($HomeDir -replace '\\', '\\\\')).Replace(($OldHome -replace '\\', '/'), ($HomeDir -replace '\\', '/'))
                if ($t2 -ne $t) { [IO.File]::WriteAllText($p, $t2, $Utf8NoBom); Info "已改寫路徑：$f" }
            }
        }
    }

    # hook 腳本需要可執行位元無所謂（Windows），但確認存在
    if (-not (Test-Path (Join-Path $HomeDir '.claude\scripts\session-cleanup.sh'))) { Warn "session-cleanup.sh 沒還原到位，SessionEnd hook 會失效" }
    Todo "打開 Claude Desktop → 登入同一個帳號（claude.ai 端的對話、Memory、連接器會自動回來）"
    Todo "Claude Code 分頁開啟資料夾 $HomeDir\notebookLM；第一次會問是否信任 .mcp.json → 允許，再輸入 /mcp 確認 5 個 MCP 都連上"
    Todo "Obsidian：開啟 vault $($env:OneDrive)\secondbrain（舊機 Obsidian 登錄的是 Documents\Obsidian Vault，MCP 用的是 OneDrive\secondbrain，新機建議統一用 OneDrive\secondbrain）"
}

# =====================================================================
function Write-McpJson {
    $nb = Join-Path $HomeDir 'notebookLM'
    $out = Join-Path $nb '.mcp.json'
    $node = $null; $nodeDir = $null; $npx = $null; $mcpvault = $null; $mdmcp = $null
    if (Has-Cmd node) {
        $node = (Get-Command node).Source
        $nodeDir = Split-Path $node -Parent
        $npx = Join-Path $nodeDir 'node_modules\npm\bin\npx-cli.js'
        try { $npmRoot = (& npm root -g 2>$null | Out-String).Trim(); if ($npmRoot) { $mcpvault = Join-Path $npmRoot '@bitbonsai\mcpvault\dist\server.js' } } catch {}
    }
    if (Has-Cmd markitdown-mcp) { $mdmcp = (Get-Command markitdown-mcp).Source }
    elseif (Has-Cmd python) { $mdmcp = Join-Path (Split-Path (Get-Command python).Source -Parent) 'Scripts\markitdown-mcp.exe' }
    $nlm = Join-Path $HomeDir '.local\bin\notebooklm-mcp.exe'
    $vault = Join-Path $env:OneDrive 'secondbrain'
    $saKey = Join-Path $HomeDir '.firebase-keys\my-teaching-tools-sa.json'
    $token = $script:SupabaseToken
    if (-not $token) {
        # 已有新 .mcp.json（例如先前跑過 secrets）就沿用裡面的 token
        try { $old = (Get-Content $out -Raw -Encoding UTF8) | ConvertFrom-Json; $token = $old.mcpServers.supabase.env.SUPABASE_ACCESS_TOKEN } catch {}
    }
    if (-not $token) { $token = '<<請填入 Supabase PAT>>' ; Warn ".mcp.json 內的 SUPABASE_ACCESS_TOKEN 尚未填入（跑 secrets 階段會自動補）" }

    foreach ($chk in @(@('node', $node), @('npx-cli.js', $npx), @('mcpvault server.js', $mcpvault), @('markitdown-mcp', $mdmcp), @('notebooklm-mcp', $nlm), @('secondbrain vault', $vault), @('firebase SA key', $saKey))) {
        if (-not $chk[1] -or -not (Test-Path -LiteralPath $chk[1])) { Warn ".mcp.json 參照的 $($chk[0]) 不存在：$($chk[1])（該 MCP 會連不上，裝好後重跑 -Phase verify 會再重寫）" }
    }
    $cfg = [ordered]@{ mcpServers = [ordered]@{
        notebooklm = [ordered]@{ command = $nlm; args = @('--transport', 'stdio') }
        obsidian   = [ordered]@{ command = $node; args = @($mcpvault, $vault) }
        supabase   = [ordered]@{ command = $node; args = @($npx, '-y', '@supabase/mcp-server-supabase@latest', '--project-ref', 'hmqnlovyzlvvnkqmfwtt'); env = [ordered]@{ SUPABASE_ACCESS_TOKEN = $token } }
        firebase   = [ordered]@{ command = $node; args = @($npx, '-y', 'firebase-tools@latest', 'mcp', '--dir', $nb); env = [ordered]@{ GOOGLE_APPLICATION_CREDENTIALS = $saKey } }
        markitdown = [ordered]@{ command = $mdmcp; args = @() }
    } }
    $json = $cfg | ConvertTo-Json -Depth 6
    if ($DryRun) { Info "(dry) 會寫入 $out"; return }
    New-Item -ItemType Directory -Path $nb -Force | Out-Null
    [IO.File]::WriteAllText($out, $json, $Utf8NoBom)
    Ok ".mcp.json 已依新機路徑重寫：$out"
}

# =====================================================================
if (Want 'secrets') {
    Step "secrets：解密並放回密鑰"
    if (-not $Secrets) { Warn "沒有密鑰包，略過。新機需：Firebase 金鑰重下載、GEMINI_API_KEY 重設、Supabase PAT 重填、gh/nlm/vercel 重新登入" }
    else {
        $ssl = Get-OpenSsl
        if (-not $ssl) { Fail "找不到 openssl.exe（需先裝 Git），請先跑 -Phase tools" }
        $pw = $Password
        if (-not $pw) {
            $s = Read-Host -AsSecureString "請輸入密鑰包密碼"
            $pw = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($s))
        }
        $tmp = Join-Path $env:TEMP "migrate-secrets-restore-$Stamp"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $tarPath = Join-Path $tmp 'secrets.tar'
        $env:MIGRATE_PW = $pw
        try {
            & $ssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in $Secrets -out $tarPath -pass env:MIGRATE_PW 2>$null
            if ($LASTEXITCODE -ne 0) { Fail "解密失敗：密碼錯誤或檔案損毀" }
        } finally { Remove-Item Env:\MIGRATE_PW -ErrorAction SilentlyContinue }
        Push-Location $tmp
        try { & 'C:\Windows\System32\tar.exe' -xf $tarPath } finally { Pop-Location }
        Ok "密鑰包解密成功"
        try {
            Get-Content (Join-Path $tmp 'secrets-manifest.txt') -Encoding UTF8 | ForEach-Object { Info "  $_" }
            # 檔案類 → 放回家目錄
            $sh = Join-Path $tmp 'home'
            if (Test-Path -LiteralPath $sh) { Copy-Tree $sh $HomeDir; Ok "密鑰檔案已放回家目錄" }
            # 環境變數 / token 類
            foreach ($line in @(Get-Content (Join-Path $tmp 'env.txt') -Encoding UTF8)) {
                if ($line -notmatch '^([A-Z_]+)=(.+)$') { continue }
                $k = $Matches[1]; $v = $Matches[2]
                switch ($k) {
                    'GEMINI_API_KEY' {
                        if (-not $DryRun) { [Environment]::SetEnvironmentVariable('GEMINI_API_KEY', $v, 'User') }
                        Ok "使用者環境變數 GEMINI_API_KEY 已設定"
                    }
                    'SUPABASE_ACCESS_TOKEN' { $script:SupabaseToken = $v; Ok "Supabase PAT 已讀入（寫進 .mcp.json）" }
                    'GH_TOKEN' {
                        if ($DryRun) { Info "(dry) gh auth login --with-token"; break }
                        if (Has-Cmd gh) {
                            $v | & gh auth login --with-token 2>&1 | Out-Null
                            if ($LASTEXITCODE -eq 0) { & gh auth setup-git 2>&1 | Out-Null; Ok "gh 已用舊 token 登入並接好 git 認證" }
                            else { Warn "gh token 登入失敗（可能已過期），請手動 gh auth login"; Todo "gh auth login（瀏覽器 device flow）→ gh auth setup-git" }
                        } else { Warn "gh 未安裝，略過 token 登入" }
                    }
                }
            }
        } finally { Remove-Tree $tmp }
        Todo "nlm：執行 nlm doctor；若 Google 登入已過期就 nlm login"
        Todo "vercel：執行 vercel whoami；失效就 vercel login（aoi-farewell / sunrise-0703 部署用）"
    }
    Write-McpJson
} elseif (Want 'files') {
    Write-McpJson
}

# =====================================================================
if (Want 'repos') {
    Step "repos：clone git repo 回原路徑"
    if (-not (Has-Cmd git)) { Warn "git 未安裝，略過" }
    else {
        # git 全域設定
        $gc = Join-Path $StageMeta 'gitconfig.txt'
        if (Test-Path $gc) {
            foreach ($line in Get-Content $gc -Encoding UTF8) {
                if ($line -match '^user\.(name|email)=(.+)$') { if (-not $DryRun) { & git config --global "user.$($Matches[1])" $Matches[2] } }
            }
        }
        if (-not $DryRun) { & git config --global windows.appendAtomically false; & git config --global core.quotepath off }
        if ((Has-Cmd gh) -and -not $DryRun) { & gh auth setup-git 2>&1 | Out-Null }

        foreach ($r in $manifest.repos) {
            $path = Join-Path $HomeDir $r.rel
            if ($r.inOneDrive) {
                if (Test-Path (Join-Path $path '.git')) { Info "OneDrive 已同步：~\$($r.rel)" }
                else { Warn "~\$($r.rel) 在 OneDrive 內但尚未同步下來，等 OneDrive 同步完即可（不 clone 以免衝突）" }
                continue
            }
            if (Test-Path (Join-Path $path '.git')) { Info "已存在：~\$($r.rel)"; continue }
            if (-not $r.remote) { Warn "~\$($r.rel) 沒有 remote，無法 clone" ; continue }
            if ($DryRun) { Info "(dry) git clone $($r.remote) → $path"; continue }
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            & git clone --quiet $r.remote $path 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                if ($r.branch -and $r.branch -ne 'HEAD') { & git -C $path checkout --quiet $r.branch 2>$null }
                Ok "clone ~\$($r.rel)"
            } else { Warn "clone 失敗：$($r.remote)（私有 repo 需先 gh auth login）" }
        }
        # 未追蹤檔案
        if (Test-Path -LiteralPath $StageUntracked) {
            Copy-Tree $StageUntracked $HomeDir
            Ok "各 repo 的未追蹤檔案已補回"
        }
    }
}

# =====================================================================
if (Want 'tasks') {
    Step "tasks：工作排程 Supabase-KeepAlive"
    $xmlPath = Join-Path $StageMeta 'task-Supabase-KeepAlive.xml'
    $script = Join-Path $HomeDir 'notebookLM\supabase-keepalive.ps1'
    if ($DryRun) { Info "(dry) Register-ScheduledTask Supabase-KeepAlive → $script" }
    elseif (Get-ScheduledTask -TaskName 'Supabase-KeepAlive' -ErrorAction SilentlyContinue) { Info "已存在，略過" }
    else {
        $done = $false
        if (Test-Path $xmlPath) {
            try {
                $xml = [IO.File]::ReadAllText($xmlPath, [Text.Encoding]::UTF8)
                if ($HomeChanged) { $xml = $xml.Replace($OldHome, $HomeDir) }
                Register-ScheduledTask -TaskName 'Supabase-KeepAlive' -Xml $xml -Force | Out-Null
                $done = $true; Ok "由匯出的 XML 重建"
            } catch { Info "XML 匯入失敗（$($_.Exception.Message)），改用內建定義" }
        }
        if (-not $done) {
            try {
                $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
                $t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 09:00
                $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
                Register-ScheduledTask -TaskName 'Supabase-KeepAlive' -Action $a -Trigger $t -Settings $s -Force | Out-Null
                Ok "已重建（每週一 09:00）"
            } catch { Warn "建立工作排程失敗：$($_.Exception.Message)"; Todo "手動建立工作排程 Supabase-KeepAlive：每週一 09:00 執行 $script" }
        }
    }
    if (-not (Test-Path $script)) { Warn "找不到 $script（files 階段應該會放回去）" }
}

# =====================================================================
if (Want 'verify') {
    Step "verify：檢查"
    Refresh-Path
    $rows = @()
    foreach ($c in @('git', 'gh', 'node', 'npm', 'python', 'pip', 'uv', 'nlm', 'ffmpeg', 'vercel', 'markitdown-mcp', 'agent-reach')) {
        $src = (Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $rows += [pscustomobject]@{ 工具 = $c; 狀態 = $(if ($src) { 'OK' } else { '缺' }); 位置 = $src }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host
    try { & gh auth status 2>&1 | Select-Object -First 3 | ForEach-Object { Info $_ } } catch {}

    $mem = Join-Path $HomeDir '.claude\projects'
    $memCount = @(Get-ChildItem -Path (Join-Path $mem '*\memory\*.md') -ErrorAction SilentlyContinue).Count
    $skillCount = @(Get-ChildItem -Path (Join-Path $HomeDir '.claude\skills') -Directory -ErrorAction SilentlyContinue).Count
    Info "auto-memory 檔案數：$memCount（舊機 39）   skills：$skillCount（舊機 9）"
    if (Test-Path (Join-Path $HomeDir '.claude\settings.json')) { Ok "~\.claude\settings.json（hooks / plugins）" } else { Warn "缺 ~\.claude\settings.json" }
    $mcpOut = Join-Path $HomeDir 'notebookLM\.mcp.json'
    if (Test-Path $mcpOut) {
        try {
            $m = (Get-Content $mcpOut -Raw -Encoding UTF8) | ConvertFrom-Json
            foreach ($n in $m.mcpServers.PSObject.Properties.Name) {
                $cmd = $m.mcpServers.$n.command
                if ($cmd -and (Test-Path -LiteralPath $cmd)) { Ok "MCP $n → $cmd" } else { Warn "MCP $n 的 command 不存在：$cmd" }
            }
            if ($m.mcpServers.supabase.env.SUPABASE_ACCESS_TOKEN -like '<<*') { Warn "Supabase token 未填（跑 -Phase secrets）" }
        } catch { Warn ".mcp.json 解析失敗" }
        if (-not (Want 'files') -and -not (Want 'secrets')) { Write-McpJson }
    } else { Warn "缺 notebookLM\.mcp.json" }
    if ([Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User')) { Ok "GEMINI_API_KEY" } else { Warn "缺 GEMINI_API_KEY（draw skill 用）" }
    if (Test-Path (Join-Path $HomeDir '.firebase-keys\my-teaching-tools-sa.json')) { Ok "Firebase 服務帳戶金鑰" } else { Warn "缺 Firebase 服務帳戶金鑰" }
    if (Get-ScheduledTask -TaskName 'Supabase-KeepAlive' -ErrorAction SilentlyContinue) { Ok "工作排程 Supabase-KeepAlive" } else { Warn "缺工作排程 Supabase-KeepAlive" }
    foreach ($r in $manifest.repos) { if (-not (Test-Path (Join-Path (Join-Path $HomeDir $r.rel) '.git'))) { Warn "repo 未就位：~\$($r.rel)" } }

    # 新站網路測試
    Info "測試對外連線（新豐網路的 TLS 攔截可能跟彰化不同）…"
    foreach ($u in @('https://github.com', 'https://pypi.org', 'https://registry.npmjs.org', 'https://generativelanguage.googleapis.com', 'https://hmqnlovyzlvvnkqmfwtt.supabase.co', 'https://notebooklm.google.com')) {
        try { $null = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 8; Ok "連線 $u" }
        catch {
            # 只要伺服器有回應（404/401 等）就代表 TLS 通了；真正要抓的是憑證/連線層錯誤
            if ($_.Exception -is [Net.WebException] -and $_.Exception.Response) { Ok "連線 $u（HTTP $([int]$_.Exception.Response.StatusCode)，TLS 正常）" }
            else { Warn "連線失敗 $u → $($_.Exception.Message.Split("`n")[0])" }
        }
    }
    Todo "若上面有 TLS 連線失敗：照 Obsidian 的踩雷筆記處理（uv 用 UV_NATIVE_TLS=1、pip 用 --trusted-host、Supabase 用 IRM + Tls12）"
    Todo "Claude Code 內執行 /plugin 確認 frontend-design 外掛啟用（plugins\cache 已一併搬回）"
    Todo "開 Claude Code 說「開工」，確認 startup skill 讀得到 Obsidian 工作筆記"
}

# ---------- 收尾 ----------
Remove-Tree $Extract
Write-Host ""
Write-Host "================ 還原結束 ================" -ForegroundColor Green
if ($Warnings.Count) {
    Write-Host ""
    Write-Host "警告 ($($Warnings.Count))：" -ForegroundColor Yellow
    $Warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($Manual.Count) {
    Write-Host ""
    Write-Host "接下來請手動完成：" -ForegroundColor White
    $i = 0; $Manual | ForEach-Object { $i++; Write-Host "  $i. $_" }
}
