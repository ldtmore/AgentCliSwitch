# ============================================================================
#  install-remote.ps1 - acs 远程一键安装引导（仅供 irm | iex 执行）
#  执行契约:
#    - 本文件仅限 `irm https://.../install-remote.ps1 | iex` 方式执行，
#      不可本地 -File 运行（无 BOM 文件在 PS5.1 下 -File 会按 ANSI 误读中文）
#    - 必须保存为无 BOM 的 UTF-8: irm 按 HTTP charset=utf-8 解码文本响应，
#      BOM 字符 U+FEFF 会粘住首行 token 破坏 iex 解析（幽灵命令 + 变量污染）
#    - CI check-encoding 守护此规约
#  下载链: jsDelivr（大陆可达，默认）→ raw.githubusercontent.com（回退）
#  流程:   下载 6 个仓库文件到临时目录（保持 src/config 结构）→ 落地后以
#          -File 方式执行 install.ps1（$PSScriptRoot 生效，安装逻辑单一来源）
# ============================================================================

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$Repo = 'ldtmore/AgentCliSwitch'
# 双源回退: jsDelivr 优先（大陆可达），raw 兜底（能直连 GitHub 时）
$Sources = @(
    ('https://cdn.jsdelivr.net/gh/' + $Repo + '@main'),
    ('https://raw.githubusercontent.com/' + $Repo + '/main')
)

# 依次尝试双源下载单个文件（-OutFile 字节原样落盘，BOM / 换行与仓库 blob 保持一致）
function Get-AcsRemoteFile {
    param([string]$RelPath, [string]$DestPath)
    foreach ($src in $Sources) {
        try {
            Invoke-WebRequest -Uri ($src + '/' + $RelPath) -OutFile $DestPath -UseBasicParsing
            return $true
        } catch { }
    }
    return $false
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('acs-remote-' + [guid]::NewGuid().ToString('N'))
# 安装器与全部资产: 落地为与仓库一致的目录结构，供 install.ps1 按 $PSScriptRoot 取用
$files = @(
    'install.ps1',
    'src/acs-menu.ps1',
    'src/acs-menu.sh',
    'src/acs-proxy.mjs',
    'config/clis.json',
    'config/suppliers.template.json'
)
try {
    Write-Host ''
    Write-Host '  ▶ AgentCliSwitch（acs）远程安装' -ForegroundColor Cyan
    Write-Host ''
    foreach ($rel in $files) {
        $dest = Join-Path $tmp ($rel -replace '/', '\')
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        if (-not (Get-AcsRemoteFile -RelPath $rel -DestPath $dest)) {
            throw ('下载失败: ' + $rel + '（jsDelivr 与 raw 均不可达，请检查网络或代理后重试）')
        }
        Write-Host ('  ✔ 已下载 ' + $rel) -ForegroundColor Green
    }
    Write-Host ''
    # 落地执行安装器: 脚本调用下 $PSScriptRoot 指向临时目录，走本地安装分支
    & (Join-Path $tmp 'install.ps1')
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
