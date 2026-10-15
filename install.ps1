# ============================================================================
#  install.ps1 - acs 本地一键部署（幂等，重复运行安全）
#  动作: 复制脚本与配置到 ~\.acs → 首次生成 suppliers.json → 挂载三端
#  挂载: PS7 profile / PS5.1 profile / Git Bash .bashrc（marker 标记块）
# ============================================================================

$ErrorActionPreference = 'Stop'

# ============================================================================
# 远程一键安装支持: irm https://raw.githubusercontent.com/ldtmore/AgentCliSwitch/main/install.ps1 | iex
# 管道执行时拿不到脚本路径（$PSScriptRoot 为空）→ 先下载仓库归档到临时目录再安装
# ============================================================================
$tmp = $null
if (-not $PSScriptRoot) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ProgressPreference = 'SilentlyContinue'
    $repo = 'https://github.com/ldtmore/AgentCliSwitch/archive/refs/heads/main.zip'
    $tmp  = Join-Path ([IO.Path]::GetTempPath()) ('acs-install-' + [guid]::NewGuid().ToString('N'))
    Write-Host '  ▶ 远程安装：正在下载仓库归档...'
    Invoke-WebRequest -Uri $repo -OutFile ($tmp + '.zip') -UseBasicParsing
    Expand-Archive -Path ($tmp + '.zip') -DestinationPath $tmp -Force
    $repoRoot = Join-Path $tmp 'AgentCliSwitch-main'
    if (-not (Test-Path (Join-Path $repoRoot 'install.ps1'))) { throw '仓库归档解压失败（未找到 install.ps1）' }
} else {
    $repoRoot = $PSScriptRoot
}
$acsDir = Join-Path $HOME '.acs'

# 统一步骤输出（与 acs-menu 脚本一致的 ✔/⚠/▶ 图标体系）
function Write-Step { param([string]$Msg) Write-Host ('  ▶ ' + $Msg) -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host ('  ✔ ' + $Msg) -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host ('  ⚠ ' + $Msg) -ForegroundColor Yellow }

Write-Host ''
Write-Host '  ▶ AgentCliSwitch（acs）安装' -ForegroundColor Cyan
Write-Host ('  仓库: {0}' -f $repoRoot)
Write-Host ('  目标: {0}' -f $acsDir)
Write-Host ''

# ----------------------------------------------------------------------------
# 1. 复制脚本与配置（目录不存在则创建，已存在则覆盖）
# ----------------------------------------------------------------------------
if (-not (Test-Path $acsDir)) { New-Item -ItemType Directory -Path $acsDir | Out-Null }
foreach ($f in @('acs-menu.ps1', 'acs-menu.sh', 'acs-proxy.mjs')) {
    $src = Join-Path $repoRoot ("src\" + $f)
    if (-not (Test-Path $src)) { Write-Warn2 ("缺少 {0}，跳过" -f $f); continue }
    Copy-Item $src (Join-Path $acsDir $f) -Force
    Write-Ok ("已复制 {0}" -f $f)
}
foreach ($f in @('clis.json', 'suppliers.template.json')) {
    $src = Join-Path $repoRoot ("config\" + $f)
    if (-not (Test-Path $src)) { Write-Warn2 ("缺少 {0}，跳过" -f $f); continue }
    Copy-Item $src (Join-Path $acsDir $f) -Force
    Write-Ok ("已复制 {0}" -f $f)
}

# ----------------------------------------------------------------------------
# 2. 首次生成 suppliers.json（已存在则保留用户数据，绝不覆盖）
# ----------------------------------------------------------------------------
$dataFile = Join-Path $acsDir 'suppliers.json'
if (-not (Test-Path $dataFile)) {
    Copy-Item (Join-Path $acsDir 'suppliers.template.json') $dataFile
    Write-Ok '已从模板生成 suppliers.json（请编辑填入你的 API Key，或用 acs add 向导）'
} else {
    Write-Ok 'suppliers.json 已存在，保留现有配置'
}

# ----------------------------------------------------------------------------
# 3. 挂载三端（marker 标记块，幂等：已挂载则跳过）
# .bashrc 必须用 LF 换行（CRLF 会导致 bash 把 \r 当命令的一部分）
# PS Profile 用带 BOM 的 UTF-8 写入（PS5.1 中文需要），.bashrc 用无 BOM UTF-8 + LF
# ----------------------------------------------------------------------------
function Add-AcsMount {
    param([string]$Path, [string]$Block, [string]$Marker, [switch]$IsBash)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existing = ''
    if (Test-Path $Path) { $existing = Get-Content $Path -Raw -ErrorAction SilentlyContinue }
    if ($existing -and ($existing -match [regex]::Escape($Marker))) {
        Write-Ok ('已挂载（跳过）: {0}' -f $Path)
        return
    }
    $content = $existing
    if (-not $content) { $content = '' }
    if (-not $content.EndsWith("`n")) { $content += "`n" }
    $content += $Block
    if ($IsBash) {
        # 统一 LF 后以无 BOM UTF-8 写入
        $content = $content -replace "`r`n", "`n"
        [IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        [IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($true)))
    }
    Write-Ok ('已挂载: {0}' -f $Path)
}

$psBlock = @"

# >>> acs (AgentCliSwitch) >>>
. "`$HOME\.acs\acs-menu.ps1"
# <<< acs <<<
"@

$bashBlock = @'

# >>> acs (AgentCliSwitch) >>>
. "$HOME/.acs/acs-menu.sh"
# <<< acs <<<

'@

$doc = [Environment]::GetFolderPath('MyDocuments')
Add-AcsMount -Path (Join-Path $doc 'PowerShell\Microsoft.PowerShell_profile.ps1') -Block $psBlock -Marker 'acs-menu.ps1'
Add-AcsMount -Path (Join-Path $doc 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1') -Block $psBlock -Marker 'acs-menu.ps1'

$bashrc = Join-Path $HOME '.bashrc'
if (Test-Path (Join-Path $repoRoot 'src\acs-menu.sh')) {
    Add-AcsMount -Path $bashrc -Block $bashBlock -Marker 'acs-menu.sh' -IsBash
    # Git Bash 优先加载 .bash_profile：若它存在且未引用 .bashrc，上面的挂载不会生效
    $bashProfile = Join-Path $HOME '.bash_profile'
    if ((Test-Path $bashProfile) -and -not ((Get-Content $bashProfile -Raw -ErrorAction SilentlyContinue) -match '\.bashrc')) {
        Write-Warn2 '~\.bash_profile 存在但未加载 .bashrc，Git Bash 端菜单不会生效；请在 .bash_profile 里补一行: test -f ~/.bashrc && . ~/.bashrc'
    }
}

# ----------------------------------------------------------------------------
# 4. 完成提示
# ----------------------------------------------------------------------------
if ($tmp) {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item ($tmp + '.zip') -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Ok '安装完成！接下来：'
Write-Host ''
Write-Host '    1. 新开一个终端（PowerShell 或 Git Bash）'
Write-Host '    2. 运行 acs add 添加供应商（或编辑 ~\.acs\suppliers.json 填入 API Key）'
Write-Host '    3. 运行 acs 开始切换'
Write-Host '    4. acs status 随时体检排障；acs help 查看全部命令'
Write-Host ''
