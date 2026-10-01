#Requires -Version 5.1
<#
.SYNOPSIS
  把「明文搬家包」裡不該出現的 token 遮掉（密鑰正本在加密的 .secrets.tar.enc 裡，不受影響）

.DESCRIPTION
  只處理設定檔與對話紀錄，不碰專案原始碼：
    notebookLM\.mcp.json、notebookLM\.claude\settings.local.json、
    .claude\projects\**\*.jsonl / *.json、AppData\Roaming\Claude\claude-code-sessions\**\*.json、
    meta\claude.json.reference
  兩種用法：
    -StageHome <暫存夾\home>   backup.ps1 在壓縮前呼叫，直接改暫存檔
    -Zip <搬家包.zip>          事後修補既有 zip（串流複製成新檔再取代，不把整包載入記憶體）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File redact.ps1 -Zip "$env:OneDrive\搬家包\搬家包_20261001-1931.zip"
#>
[CmdletBinding()]
param(
    [string]$StageHome,
    [string]$Zip,
    [string[]]$Literals = @()
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try {
    [AppContext]::SetSwitch('Switch.System.IO.UseLegacyPathHandling', $false)
    [AppContext]::SetSwitch('Switch.System.IO.BlockLongPaths', $false)
    $acs = [System.AppContext].Assembly.GetType('System.AppContextSwitches')
    $acs.GetField('_useLegacyPathHandling', 'NonPublic,Static').SetValue($null, -1)
    $acs.GetField('_blockLongPaths', 'NonPublic,Static').SetValue($null, -1)
} catch {}
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$LongPrefix = '\\?' + '\'

# ---------- 要遮的樣式 ----------
$Patterns = @(
    'sbp_[A-Za-z0-9]{20,}',                                            # Supabase PAT
    'gh[pousr]_[A-Za-z0-9]{20,}',                                      # GitHub token
    'AQ\.[A-Za-z0-9_\-]{20,}',                                         # Gemini API key（新版）
    'AIza[0-9A-Za-z_\-]{30,}',                                         # Google API key
    'eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}', # JWT（Supabase anon / service_role）
    '-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    '(?i)(?<=(?:token|secret|password|passwd|api[_-]?key|access[_-]?key)\\?["'']?\s*[:=]\s*\\?["'']?)[A-Za-z0-9_\-\.]{16,}'
)
# 相對 home 的目標（萬用字元；分隔符 / 或 \ 都算）
$TargetGlobs = @(
    'notebookLM/.mcp.json',
    'notebookLM/.claude/settings.local.json',
    '.claude/projects/*',
    'AppData/Roaming/Claude/claude-code-sessions/*',
    'meta/claude.json.reference'
)
function Is-Target([string]$relHome) {
    $r = $relHome -replace '\\', '/'
    foreach ($g in $TargetGlobs) { if ($r -like $g) { return ($r -match '\.(json|jsonl|reference)$') } }
    return $false
}

# ---------- 本機能拿到的密鑰正本，整串當字面值遮掉 ----------
function Get-LocalSecretLiterals {
    $lits = New-Object System.Collections.ArrayList
    $home_ = $env:USERPROFILE
    $g = [Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User'); if ($g) { [void]$lits.Add($g) }
    try {
        $m = (Get-Content (Join-Path $home_ 'notebookLM\.mcp.json') -Raw -Encoding UTF8) | ConvertFrom-Json
        foreach ($srv in $m.mcpServers.PSObject.Properties) {
            $envObj = $srv.Value.env
            if ($envObj) { foreach ($p in $envObj.PSObject.Properties) { if ($p.Name -match 'TOKEN|KEY|SECRET' -and $p.Value.Length -ge 16) { [void]$lits.Add($p.Value) } } }
        }
    } catch {}
    try { $t = (& gh auth token 2>$null); if ($t) { [void]$lits.Add($t.Trim()) } } catch {}
    foreach ($f in @(Get-ChildItem (Join-Path $home_ 'notebookLM') -Recurse -Depth 2 -Force -Filter '.env*' -File -ErrorAction SilentlyContinue)) {
        foreach ($line in Get-Content $f.FullName -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*["'']?([^"''#\s]{16,})') { [void]$lits.Add($Matches[1]) }
        }
    }
    try {
        $sa = Get-Content (Join-Path $home_ '.firebase-keys\my-teaching-tools-sa.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($sa.private_key_id) { [void]$lits.Add($sa.private_key_id) }
    } catch {}
    return @($lits | Where-Object { $_ } | Select-Object -Unique)
}

$script:Total = 0
function Redact-Text([string]$text) {
    $n = 0
    foreach ($lit in $Literals) {
        if ($lit.Length -lt 8) { continue }
        $c = ([regex]::Matches($text, [regex]::Escape($lit))).Count
        if ($c) { $text = $text.Replace($lit, '<<REDACTED>>'); $n += $c }
        # JSON 內可能被跳脫（例如 \n 變 \\n），私鑰類另外處理，這裡只管單行字串
    }
    foreach ($p in $Patterns) {
        $ms = [regex]::Matches($text, $p)
        if ($ms.Count) { $text = [regex]::Replace($text, $p, '<<REDACTED>>'); $n += $ms.Count }
    }
    $script:Total += $n
    return @{ Text = $text; Count = $n }
}

if (-not $Literals -or $Literals.Count -eq 0) { $Literals = Get-LocalSecretLiterals }
Write-Host "    遮蔽樣式 $($Patterns.Count) 種、字面值 $($Literals.Count) 筆" -ForegroundColor Gray

# ---------- 模式 1：暫存夾 ----------
if ($StageHome) {
    $root = $StageHome
    $files = Get-ChildItem -LiteralPath ($LongPrefix + $root) -Recurse -File -Force -ErrorAction SilentlyContinue
    $metaRef = Join-Path (Split-Path $root -Parent) 'meta\claude.json.reference'
    if (Test-Path -LiteralPath $metaRef) { $files = @($files) + @(Get-Item -LiteralPath $metaRef) }
    $touched = 0
    foreach ($f in $files) {
        $full = $f.FullName -replace '^\\\\\?\\', ''
        $rel = if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $full.Substring($root.Length).TrimStart('\') } else { 'meta\' + $f.Name }
        if (-not (Is-Target $rel)) { continue }
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $r = Redact-Text $text
        if ($r.Count -gt 0) { [IO.File]::WriteAllText($f.FullName, $r.Text, $Utf8NoBom); $touched++; Write-Host "    遮蔽 $($r.Count) 處：$rel" -ForegroundColor Gray }
    }
    Write-Host "    [OK] 明文區遮蔽完成：$touched 個檔案、共 $script:Total 處" -ForegroundColor Green
}

# ---------- 模式 2：既有 zip（串流複製成新檔） ----------
if ($Zip) {
    if (-not (Test-Path -LiteralPath $Zip)) { throw "找不到 $Zip" }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmp = "$Zip.redact.tmp"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $src = [IO.Compression.ZipFile]::Open($Zip, [IO.Compression.ZipArchiveMode]::Read, [Text.Encoding]::UTF8)
    $dst = [IO.Compression.ZipFile]::Open($tmp, [IO.Compression.ZipArchiveMode]::Create, [Text.Encoding]::UTF8)
    $touched = 0; $copied = 0
    try {
        foreach ($en in $src.Entries) {
            $name = $en.FullName
            $rel = $name -replace '^home[\\/]', ''
            $isTarget = ($name -match '^home[\\/]' -and (Is-Target $rel)) -or ($name -replace '\\', '/') -eq 'meta/claude.json.reference'
            $ne = $dst.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $ne.LastWriteTime = $en.LastWriteTime
            $outS = $ne.Open()
            try {
                if ($isTarget -and $en.Length -gt 0) {
                    $sr = New-Object IO.StreamReader($en.Open(), [Text.Encoding]::UTF8)
                    $text = $sr.ReadToEnd(); $sr.Dispose()
                    $r = Redact-Text $text
                    if ($r.Count -gt 0) { $touched++; Write-Host "    遮蔽 $($r.Count) 處：$name" -ForegroundColor Gray }
                    $bytes = $Utf8NoBom.GetBytes($r.Text)
                    $outS.Write($bytes, 0, $bytes.Length)
                } else {
                    $inS = $en.Open(); $inS.CopyTo($outS); $inS.Dispose()
                }
            } finally { $outS.Dispose() }
            $copied++
        }
    } finally { $src.Dispose(); $dst.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Zip -Force
    Write-Host "    [OK] zip 已重建：$copied 個項目、遮蔽 $touched 個檔案、共 $script:Total 處 → $Zip" -ForegroundColor Green
}
