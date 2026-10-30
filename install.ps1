# ============================================================================
#  install.ps1 - acs 本地一键部署（幂等，重复运行安全）
#  动作: 复制脚本与配置到 ~\.acs → 首次生成 suppliers.json → 挂载三端
#  挂载: PS7 profile / PS5.1 profile / Git Bash .bashrc（marker 标记块）
#  执行契约: 本文件必须带 BOM（PS5.1 本地 -File 无 BOM 会按 ANSI 误读中文），
#            因此仅支持本地执行；远程安装走无 BOM 的引导脚本:
#            irm https://cdn.jsdelivr.net/gh/ldtmore/AgentCliSwitch@main/install-remote.ps1 | iex
#            （引导下载全部资产落地后，以 -File 方式调用本文件，挂载逻辑单一来源）
# ============================================================================

$ErrorActionPreference = 'Stop'

# 误用兜底: irm 本文件 | iex 时 $PSScriptRoot 为空（且 BOM 会先污染首行报错）——给正确指引而非裸报错
if (-not $PSScriptRoot) {
    throw 'install.ps1 仅支持本地执行（在仓库目录内 ./install.ps1）；远程安装请执行: irm https://cdn.jsdelivr.net/gh/ldtmore/AgentCliSwitch@main/install-remote.ps1 | iex'
}
$repoRoot = $PSScriptRoot
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
    # 按目标文件 BOM 探测编码: UTF-16 用原编码往返；其余（UTF-8 带/无 BOM、ANSI、GBK）
    # 走 Latin-1 字节透明读写——挂载块为纯 ASCII，追加不破坏任何既有编码，
    # 修复 PS5.1 下 Get-Content 默认按 ANSI 误解 UTF-8 中文、写回即永久乱码的问题
    $enc = $null
    $bytes = @()
    if (Test-Path $Path) { $bytes = [IO.File]::ReadAllBytes($Path) }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = [Text.Encoding]::BigEndianUnicode }
    if ($enc) { $existing = $enc.GetString($bytes) } else { $existing = [Text.Encoding]::GetEncoding(28591).GetString($bytes) }
    if ($existing -and ($existing -match [regex]::Escape($Marker))) {
        Write-Ok ('已挂载（跳过）: {0}' -f $Path)
        return
    }
    $content = $existing
    if (-not $content) { $content = '' }
    if (-not $content.EndsWith("`n")) { $content += "`n" }
    $content += $Block
    if ($enc) {
        # UTF-16 文件: 以无 BOM 前导的编码器写回（$existing 已含原 BOM 字符，
        # 用默认编码器 WriteAllText 会再注入一份 preamble 形成双 BOM）
        $encNoBom = if ($bytes[0] -eq 0xFF) { New-Object System.Text.UnicodeEncoding($false, $false) } else { New-Object System.Text.UnicodeEncoding($true, $false) }
        [IO.File]::WriteAllText($Path, $content, $encNoBom)
    } elseif ($bytes.Count -eq 0) {
        # 新建: PS Profile 用带 BOM 的 UTF-8（PS5.1 后续中文所需）；.bashrc 用无 BOM + 统一 LF
        if ($IsBash) { $content = $content -replace "`r`n", "`n" }
        [IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding(-not $IsBash)))
    } else {
        # 既有无 BOM: Latin-1 字节透明写回，绝不注入 BOM / 不重编码
        # （.bashrc 场景仅将 CRLF 规范为 LF 满足 bash，其余字节原样保留）
        if ($IsBash) { $content = $content -replace "`r`n", "`n" }
        [IO.File]::WriteAllText($Path, $content, [Text.Encoding]::GetEncoding(28591))
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
Write-Host ''
Write-Ok '安装完成！接下来：'
Write-Host ''
Write-Host '    1. 新开一个终端（PowerShell 或 Git Bash）'
Write-Host '    2. 运行 acs add 添加供应商（或编辑 ~\.acs\suppliers.json 填入 API Key）'
Write-Host '    3. 运行 acs 开始切换'
Write-Host '    4. acs status 随时体检排障；acs help 查看全部命令'
Write-Host ''
