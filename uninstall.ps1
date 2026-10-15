# ============================================================================
#  uninstall.ps1 - acs 一键卸载（默认保留 suppliers.json 用户数据）
#  动作: 移除三端挂载块（marker） → 删除 ~\.acs 程序文件（-Purge 连数据一起删）
# ============================================================================

param([switch]$Purge)

function Write-Step { param([string]$Msg) Write-Host ('  ▶ ' + $Msg) -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host ('  ✔ ' + $Msg) -ForegroundColor Green }

# 从配置文件中移除 marker 标记块（整块删除，其余内容原样保留）
function Remove-AcsMount {
    param([string]$Path, [string]$Marker)
    if (-not (Test-Path $Path)) { return }
    $raw = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw -or -not ($raw -match [regex]::Escape($Marker))) { return }
    $pattern = '(?s)\r?\n?# >>> acs \(AgentCliSwitch\) >>>.*?# <<< acs <<<\r?\n?'
    $new = [regex]::Replace($raw, $pattern, "`n")
    $isBash = ($Path -like '*.bashrc') -or ($Path -like '*.bash_profile')
    if ($isBash) {
        [IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        [IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($true)))
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
