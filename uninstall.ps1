# ============================================================================
#  uninstall.ps1 - acs 一键卸载（默认保留 suppliers.json 用户数据）
#  动作: 移除三端挂载块（marker） → 删除 ~\.acs 程序文件（-Purge 连数据一起删）
# ============================================================================

param([switch]$Purge)

function Write-Step { param([string]$Msg) Write-Host ('  ▶ ' + $Msg) -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host ('  ✔ ' + $Msg) -ForegroundColor Green }

# 从配置文件中移除 marker 标记块（整块删除，其余内容原样保留）
# 按文件 BOM 探测编码: UTF-16 用原编码往返；其余走 Latin-1（28591）字节透明读写——
# 1 字节 = 1 字符，删块后字节级还原，修复 PS5.1 默认 ANSI 强解 UTF-8 中文致永久乱码、
# 以及一律按 UTF-8 重写破坏 UTF-16 / GBK 文件的问题
function Remove-AcsMount {
    param([string]$Path, [string]$Marker)
    if (-not (Test-Path $Path)) { return }
    $enc = $null
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = [Text.Encoding]::BigEndianUnicode }
    if ($enc) { $raw = $enc.GetString($bytes) } else { $raw = [Text.Encoding]::GetEncoding(28591).GetString($bytes) }
    if (-not $raw -or -not ($raw -match [regex]::Escape($Marker))) { return }
    $pattern = '(?s)\r?\n?# >>> acs \(AgentCliSwitch\) >>>.*?# <<< acs <<<\r?\n?'
    # 整块连同其前导换行一并移除（替换为空），其余字节原样保留，不改变文件的换行风格
    $new = [regex]::Replace($raw, $pattern, '')
    # 若仅剩孤立 UTF-8 BOM（Latin-1 视角的三字符，原文件只含挂载块）或纯空白 → 回归空文件
    $trimmed = $new.TrimEnd("`r", "`n")
    if ($trimmed -eq '' -or $trimmed -eq ([string][char]0xEF + [string][char]0xBB + [string][char]0xBF)) { $new = '' }
    if ($enc) {
        # 以无 BOM 前导的编码器写回（$raw 已含原文件 BOM 字符，默认编码器会再注入 preamble 形成双 BOM）
        $encNoBom = if ($bytes[0] -eq 0xFF) { New-Object System.Text.UnicodeEncoding($false, $false) } else { New-Object System.Text.UnicodeEncoding($true, $false) }
        [IO.File]::WriteAllText($Path, $new, $encNoBom)
    } else {
        # 无 BOM: Latin-1 原样写回（内容未被重解码，写 UTF-8 反而会在非 ASCII 字节处膨胀损坏）
        [IO.File]::WriteAllText($Path, $new, [Text.Encoding]::GetEncoding(28591))
    }
    Write-Ok ('已移除挂载: {0}' -f $Path)
}

Write-Host ''
Write-Host '  AgentCliSwitch（acs）卸载' -ForegroundColor Cyan
Write-Host ''

$doc = [Environment]::GetFolderPath('MyDocuments')
Remove-AcsMount -Path (Join-Path $doc 'PowerShell\Microsoft.PowerShell_profile.ps1') -Marker 'acs-menu.ps1'
Remove-AcsMount -Path (Join-Path $doc 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1') -Marker 'acs-menu.ps1'
Remove-AcsMount -Path (Join-Path $HOME '.bashrc') -Marker 'acs-menu.sh'

# 程序文件删除；用户数据默认保留（-Purge 才删）
$acsDir = Join-Path $HOME '.acs'
if (Test-Path $acsDir) {
    if ($Purge) {
        Remove-Item $acsDir -Recurse -Force
        Write-Ok ('已删除 {0}（含 suppliers.json 全部数据）' -f $acsDir)
    } else {
        Get-ChildItem $acsDir -File | Where-Object { $_.Name -ne 'suppliers.json' } | Remove-Item -Force
        Write-Ok ('已删除程序文件，保留用户数据: {0}\suppliers.json' -f $acsDir)
    }
}

Write-Host ''
Write-Ok '卸载完成。'
Write-Host ''
