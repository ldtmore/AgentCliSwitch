# ============================================================================
#  acs-menu.ps1 - AgentCliSwitch 多 CLI 多供应商切换菜单（PowerShell 5.1 / 7+）
#  数据文件: ~\.acs\clis.json（CLI 知识库） + ~\.acs\suppliers.json（用户供应商）
#  原理: 进程级环境变量注入 + try/finally 退出还原（继承 ccs 生产验证方案）
# ============================================================================

$script:AcsVersion  = 'v0.4.0'
$script:AcsDir      = Join-Path $HOME '.acs'
$script:AcsClisFile = Join-Path $script:AcsDir 'clis.json'
$script:AcsDataFile = Join-Path $script:AcsDir 'suppliers.json'
$script:AcsLastFile = Join-Path $script:AcsDir '.last'

# ----------------------------------------------------------------------------
# 配置加载
# ----------------------------------------------------------------------------

# 读取 clis.json（CLI 知识库），返回 OrderedDictionary[cliId] = 定义对象；失败返回 $null
function Get-AcsClis {
    param([switch]$Quiet)
    if (-not (Test-Path $script:AcsClisFile)) {
        if (-not $Quiet) { Write-Host '  ✘ 找不到 CLI 知识库 ~\.acs\clis.json（请重新运行安装脚本）' -ForegroundColor Red }
        return $null
    }
    try {
        $raw = Get-Content $script:AcsClisFile -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    } catch {
        if (-not $Quiet) { Write-Host ('  ✘ clis.json 解析失败: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        return $null
    }
    $clis = [ordered]@{}
    foreach ($p in $json.PSObject.Properties) {
        if ($p.Name -like '_*' -or $null -eq $p.Value -or $p.Value -isnot [PSCustomObject]) { continue }
        $clis[$p.Name] = $p.Value
    }
    if ($clis.Count -eq 0) {
        if (-not $Quiet) { Write-Host '  ✘ clis.json 里没有任何 CLI 定义' -ForegroundColor Red }
        return $null
    }
    return ,$clis
}

# 读取 suppliers.json（用户供应商），返回 OrderedDictionary[cliId] = 组对象；文件缺失返回空表
function Get-AcsSupplierMap {
    param([switch]$Quiet)
    if (-not (Test-Path $script:AcsDataFile)) {
        if (-not $Quiet) { Write-Host '  ✘ 找不到供应商配置 ~\.acs\suppliers.json（请先运行 acs add）' -ForegroundColor Red }
        return $null
    }
    try {
        $raw = Get-Content $script:AcsDataFile -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    } catch {
        if (-not $Quiet) { Write-Host ('  ✘ suppliers.json 解析失败: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        return $null
    }
    # 过滤掉 "_说明" 等元数据键，仅保留 CLI 组
    $map = [ordered]@{}
    foreach ($p in $json.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        if ($null -eq $p.Value -or $p.Value -isnot [PSCustomObject]) { continue }
        $map[$p.Name] = $p.Value
    }
    return ,$map
}

# 取某个 CLI 的供应商列表（OrderedDictionary[id] = @{ Desc; Env }），official 固定排最前
function Get-AcsSupplierList {
    param([string]$CliId, $Map)
    $group = $Map[$CliId]
    if ($null -eq $group) { return $null }
    $list = [ordered]@{}
    foreach ($p in $group.PSObject.Properties) {
        if ($null -eq $p.Value -or $p.Value -isnot [PSCustomObject]) { continue }
        $entry = @{ Desc = ''; Env = @{}; Preset = $null }
        foreach ($f in $p.Value.PSObject.Properties) {
            if ($f.Name -eq 'desc') { $entry.Desc = [string]$f.Value }
            elseif ($f.Name -eq 'env' -and $null -ne $f.Value) {
                foreach ($e in $f.Value.PSObject.Properties) { $entry.Env[$e.Name] = [string]$e.Value }
            }
            elseif ($f.Name -eq 'preset' -and $null -ne $f.Value) {
                # L2 hybrid 条目的预置元数据段（预置器、代理模式与启动参数构造消费）
                $pr = @{ BaseUrl = ''; Model = ''; ModelFast = ''; Protocol = 'openai'; WireApi = ''; Mode = 'direct' }
                foreach ($pf in $f.Value.PSObject.Properties) {
                    switch ($pf.Name) {
                        'baseUrl'   { $pr.BaseUrl = [string]$pf.Value }
                        'model'     { $pr.Model = [string]$pf.Value }
                        'modelFast' { $pr.ModelFast = [string]$pf.Value }
                        'protocol'  { $pr.Protocol = [string]$pf.Value }
                        'wireApi'   { $pr.WireApi = [string]$pf.Value }
                        'mode'      { $pr.Mode = [string]$pf.Value }
                    }
                }
                $entry.Preset = $pr
            }
        }
        $list[$p.Name] = $entry
    }
    if ($list.Count -eq 0) { return $null }
    # official 固定 [0]，其余按文件顺序
    $ordered = [ordered]@{}
    if ($null -ne $list['official']) { $ordered['official'] = $list['official'] }
    foreach ($k in $list.Keys) { if ($k -ne 'official') { $ordered[$k] = $list[$k] } }
    return ,$ordered
}

# ----------------------------------------------------------------------------
# 名称查找辅助（大小写不敏感 / 唯一前缀 / 纠错建议），逻辑沿用 ccs
# ----------------------------------------------------------------------------

# 大小写不敏感地精确查找 key，找到返回标准写法，找不到返回 $null
function Find-AcsKey {
    param($List, [string]$Name)
    foreach ($k in $List.Keys) { if ($k -ieq $Name) { return $k } }
    return $null
}

# 输错名字时给前缀匹配建议（输入是某 key 的前缀，或某 key 是输入的前缀）
function Find-AcsSuggestion {
    param($List, [string]$Name)
    foreach ($k in $List.Keys) {
        if ($k -like ($Name + '*') -or $Name -like ($k + '*')) { return $k }
    }
    return $null
}

# 前缀匹配：返回所有以 $Name 开头（不分大小写）的 key 数组
function Find-AcsPrefixMatches {
    param($List, [string]$Name)
    $m = @()
    foreach ($k in $List.Keys) { if ($k -like ($Name + '*')) { $m += $k } }
    return $m
}

# ----------------------------------------------------------------------------
# 环境变量清理与注入（核心：进程级 + 退出还原）
# ----------------------------------------------------------------------------

# 清理范围 = clis.json 该 CLI 的 baseEnvKeys ∪ suppliers.json 中该 CLI 出现过的所有 env 键
function Clear-AcsEnv {
    param($CliDef, $List)
    $vars = @()
    if ($null -ne $CliDef.baseEnvKeys) { $vars = @($CliDef.baseEnvKeys) }
    if ($List) {
        foreach ($e in $List.Values) {
            foreach ($k in $e.Env.Keys) { if ($vars -notcontains $k) { $vars += $k } }
        }
    }
    foreach ($v in $vars) { Remove-Item ('Env:' + $v) -ErrorAction SilentlyContinue }
}

# 以选中供应商拉起 CLI：official（env 为空）走清理分支；env 型注入变量；
# hybrid 型注入变量 + 按 launchStyle 构造启动参数（--profile / -m provider/model）
function Start-AcsSession {
    param([string]$CliId, $CliDef, [string]$Sel, $Entry, [string[]]$Rest)
    if (-not (Get-Command $CliDef.cmd -ErrorAction SilentlyContinue)) {
        Write-Host ('  ✘ 找不到 {0} 命令，请先安装 {1}' -f $CliDef.cmd, $CliDef.cmd) -ForegroundColor Red
        return
    }
    $list = $script:AcsCurrentList
    if ($Entry.Env.Count -eq 0) {
        # official 型条目：主动清理全部相关变量，回落 CLI 自身登录态
        Clear-AcsEnv -CliDef $CliDef -List $list
        Write-Host ('  ▶ 正在启动官方 {0} ...' -f $CliDef.name) -ForegroundColor Cyan
        & $CliDef.cmd @Rest
        Write-Host ''
        Write-Host '  ✔ 会话结束。' -ForegroundColor DarkGray
        # 会话结束引导：教育直达用法，减少下次再走菜单
        Write-Host ('  下次直达: acs {0} {1}' -f $CliId, $Sel) -ForegroundColor DarkGray
        return
    }
    Clear-AcsEnv -CliDef $CliDef -List $list
    foreach ($k in $Entry.Env.Keys) { Set-Item -Path ('Env:' + $k) -Value $Entry.Env[$k] }
    # hybrid 适配器：按 launchStyle 构造启动参数；配置里缺预置段时提示
    $launchArgs = @()
    $proxyProc = $null
    $portFile = $null
    if ($CliDef.adapter -eq 'hybrid' -and $Entry.preset) {
        $acsId = 'acs_' + $Sel
        # 代理模式：条目探测时端点不支持所需协议，拉起本地翻译代理并用 -c 覆盖 base_url
        if ($Entry.preset.Mode -eq 'proxy') {
            $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
            if (-not $nodeCmd) {
                Write-Host '  ✘ 代理模式需要 node（≥18），请先安装 Node.js，或 acs edit 改用支持协议的端点' -ForegroundColor Red
                return
            }
            $portFile = Join-Path $env:TEMP ('acs-proxy-' + [guid]::NewGuid().ToString('N') + '.port')
            $proxyProc = Start-Process -FilePath $nodeCmd.Source -ArgumentList @(
                (Join-Path $script:AcsDir 'acs-proxy.mjs'), '--port', '0',
                '--upstream', [string]$Entry.preset.BaseUrl, '--ppid', $PID, '--portfile', $portFile
            ) -WindowStyle Hidden -PassThru
            $port = $null
            for ($i = 0; $i -lt 25; $i++) {
                Start-Sleep -Milliseconds 200
                if (Test-Path $portFile) { $port = (Get-Content $portFile -Raw -ErrorAction SilentlyContinue).Trim(); if ($port) { break } }
            }
            if (-not $port) {
                Write-Host '  ✘ 翻译代理启动失败（可设 $env:ACS_PROXY_DEBUG=1 后重试排查），或 acs edit 换直连端点' -ForegroundColor Red
                try { $proxyProc.Kill() } catch { }
                return
            }
            Write-Host ('  ⚙ 翻译代理 127.0.0.1:' + $port + '（随 Codex 退出自动关闭）') -ForegroundColor DarkGray
            $launchArgs += @('-c', ('model_providers.' + $acsId + '.base_url=http://127.0.0.1:' + $port))
        }
        if ($CliDef.launchStyle -eq 'profile') { $launchArgs = @('--profile', $acsId) + $launchArgs }
        elseif ($CliDef.launchStyle -eq 'modelArg' -and $Entry.preset.model) { $launchArgs = @('-m', ($acsId + '/' + $Entry.preset.model)) + $launchArgs }
            elseif ($CliDef.launchStyle -eq 'envOnly' -and $CliId -eq 'crush') {
                # crush 无启动参数选模型：启动前把默认模型段同步为选中条目（唯一需要落盘的动作）
                Set-AcsCrushModel -Sel $Sel -Preset @{ Model = [string]$Entry.preset.model; Fast = [string]$Entry.preset.modelFast }
            }
        # 预置存在性检测：codex 检查独立 profile 文件；其余检查配置文件中的 acs_ 段
        $needPreset = $true
        if ($CliId -eq 'codex') {
            if (Test-Path (Join-Path $HOME ('.codex\' + $acsId + '.config.toml'))) { $needPreset = $false }
        } else {
            $cfgPath = $CliDef.configFile -replace '^~/', ($HOME + '/').Replace('\', '/') -replace '^~\\', ($HOME + '\')
            $cfgPath = $cfgPath -replace '/', '\'
            if (Test-Path $cfgPath) {
                $cfgRaw = Get-Content $cfgPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($cfgRaw -and $cfgRaw -match ('acs_' + [regex]::Escape($Sel))) { $needPreset = $false }
            }
        }
        if ($needPreset) {
            Write-Host ('  ⚠ 配置文件缺少预置段，请先运行: acs preset {0}' -f $CliId) -ForegroundColor Yellow
            return
        }
    }
    $allArgs = @($launchArgs) + @($Rest)
    Write-Host ('  ▶ 正在以 {0}（{1}）启动 {2} ...' -f $Sel, $Entry.Desc, $CliDef.name) -ForegroundColor Cyan
    # try/finally 保证被 Ctrl+C 打断时也能清理临时环境变量与翻译代理
    try {
        & $CliDef.cmd @allArgs
    } finally {
        foreach ($k in $Entry.Env.Keys) { Remove-Item ('Env:' + $k) -ErrorAction SilentlyContinue }
        if ($proxyProc) { try { $proxyProc.Kill() } catch { } }
        if ($portFile) { Remove-Item $portFile -Force -ErrorAction SilentlyContinue }
    }
    Write-Host ''
    Write-Host '  ✔ 会话结束，已清理临时环境变量。' -ForegroundColor DarkGray
    # 会话结束引导：教育直达用法，减少下次再走菜单
    Write-Host ('  下次直达: acs {0} {1}' -f $CliId, $Sel) -ForegroundColor DarkGray
}

# ----------------------------------------------------------------------------
# 界面渲染（宽度约定沿用 ccs：key 列 10~14 自适应，标题/分隔线总宽 46 显示列）
# ----------------------------------------------------------------------------

# 判断字符是否为宽字符（CJK/全角/emoji，显示宽度按 2 列计）
function Test-AcsWideChar {
    param([char]$Ch)
    $c = [int]$Ch
    return (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0x303E) -or
            ($c -ge 0x3041 -and $c -le 0x33FF) -or ($c -ge 0x3400 -and $c -le 0x4DBF) -or
            ($c -ge 0x4E00 -and $c -le 0x9FFF) -or ($c -ge 0xA000 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE4F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6) -or ($c -ge 0x1F300 -and $c -le 0x1FAFF) -or
            ($c -ge 0x20000))
}

# 计算字符串显示宽度（宽字符按 2 列）
function Get-AcsDisplayWidth {
    param([string]$Text)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) { if (Test-AcsWideChar -Ch $ch) { $w += 2 } else { $w++ } }
    return $w
}

# 按显示宽度截断文本，超出部分以 … 结尾（$MaxWidth 为可用显示列数）
function Get-AcsFitText {
    param([string]$Text, [int]$MaxWidth)
    if ([string]::IsNullOrEmpty($Text) -or $MaxWidth -lt 2) { return $Text }
    if ((Get-AcsDisplayWidth -Text $Text) -le $MaxWidth) { return $Text }
    $w = 0; $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $cw = 2; if (-not (Test-AcsWideChar -Ch $ch)) { $cw = 1 }
        if ($w + $cw + 2 -gt $MaxWidth) { break }   # 为省略号预留 2 列
        [void]$sb.Append($ch); $w += $cw
    }
    return ($sb.ToString() + '…')
}

# 终端可用宽度（取不到时按 100 列兜底）
function Get-AcsTermWidth {
    try { $w = [Console]::WindowWidth; if ($w -ge 20) { return $w } } catch { }
    return 100
}

# 统一标题行：── 标题 ─────（总显示宽 46 列，中文按 2）+ 可选暗色后缀
function Write-AcsHeader {
    param([string]$Title, [string]$Suffix = '', [string]$Color = 'Cyan')
    $used = 5 + (Get-AcsDisplayWidth -Text $Title) + 1
    $dash = 46 - $used
    if ($dash -lt 3) { $dash = 3 }
    Write-Host ('  ── {0} {1}' -f $Title, ('─' * $dash)) -ForegroundColor $Color -NoNewline
    if ($Suffix) { Write-Host (' {0}' -f $Suffix) -ForegroundColor DarkGray -NoNewline }
    Write-Host ''
}

# 向导必填字段输入：空值/校验失败只重问当前字段，不丢弃向导已录入内容（Ctrl+C 可整体退出）
# $Validate 返回错误文案（$null/空 = 通过）
function Read-AcsValidated {
    param([string]$Prompt, [scriptblock]$Validate = $null)
    while ($true) {
        $v = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($v)) { Write-Host '  ✘ 不能为空，请重新输入（Ctrl+C 退出向导）' -ForegroundColor Red; continue }
        if ($Validate) {
            $err = & $Validate $v
            if ($err) { Write-Host ('  ✘ {0}，请重新输入' -f $err) -ForegroundColor Red; continue }
        }
        return $v
    }
}

# 按 key 最大长度自适应列宽（10～14）
function Get-AcsKeyWidth {
    param($Order)
    $w = 10
    foreach ($k in $Order) { $l = [Math]::Min(14, $k.Length + 1); if ($l -gt $w) { $w = $l } }
    return $w
}

# 画一行供应商。信息层级：desc 显示名为主信息（默认亮色），key 为次要（暗色），序号为输入热键锚点（黄色）
# $Highlight：方向键高亮态（▸ 指针 + 内容转青色）；非高亮行首三空格与旧版格式对齐
function Write-AcsRow {
    param($Index, $IndexWidth, $Key, $Desc, [switch]$IsLast, [int]$KeyWidth = 10, [string]$Note = '', [switch]$Highlight)
    $ptr = ' '
    if ($Highlight) { $ptr = '▸' }
    # 注意：-f 优先级高于 +，须先拼好格式串再做格式化
    $fmt = ' {0} [{1,' + $IndexWidth + '}]  '
    Write-Host ($fmt -f $ptr, $Index) -ForegroundColor Yellow -NoNewline
    if ($Highlight) {
        Write-Host ($Key.PadRight($KeyWidth) + '  ') -ForegroundColor Cyan -NoNewline
        Write-Host $Desc -ForegroundColor Cyan -NoNewline
    } else {
        Write-Host ($Key.PadRight($KeyWidth) + '  ') -ForegroundColor DarkGray -NoNewline
        Write-Host $Desc -NoNewline
    }
    if ($Note) { Write-Host ('  ' + $Note) -ForegroundColor DarkGray -NoNewline }
    if ($IsLast) { Write-Host '  ● 上次' -ForegroundColor Green -NoNewline }
    Write-Host ''
}

# ----------------------------------------------------------------------------
# 通用选择器（方向键高亮 + 行输入混合；重定向/ISE/ACS_NO_ARROW/屏幕过小时自动降级）
# ----------------------------------------------------------------------------

# 方向键模式可用性探测
function Test-AcsArrowOk {
    if ($env:ACS_NO_ARROW) { return $false }
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
        $null = [Console]::KeyAvailable   # 真实控制台探测（ISE 等宿主会抛异常）
        return $true
    } catch { return $false }
}

# 通用单选器：绘制行区 + 分隔线 + 提示行 + 交互循环
#   $Rows      : @{ Key; Desc; Note; Last } 数组（Desc 请先经 Get-AcsFitText 截断）
#   $Parse     : param($text) → @{ ok = $true; value = 结果 } 或 @{ ok = $false; msg = 错误文案 }
#   $EscResult : 按 Esc 时返回的哨兵（供应商菜单传 'back'，其余传 'quit'/'cancel'）
#   $IndexBase : 序号显示基数（默认 0；列表从 1 编号时传 1；供应商菜单固定 0 = 官方通道）
# 返回：高亮行 Key（Enter 直接确认）/ Parse 的 value（输入命中）/ $EscResult
function Invoke-AcsSelect {
    param(
        [string]$Prompt = '选择',
        [string]$Hint = '',
        $Rows,
        [scriptblock]$Parse,
        [int]$Initial = 0,
        $EscResult = '__ESC__',
        [int]$KeyWidth = 10,
        [string]$LastMark = '',
        [string]$HintInput = '',
        [int]$IndexBase = 0
    )
    $rows = @($Rows)
    $n = $rows.Count
    $idxW = [Math]::Max(1, ([string][Math]::Max(1, ($IndexBase + $n - 1))).Length)
    $promptPrefix = '  {0} ' -f $Prompt

    # 方向键模式可用性：只要整块菜单（行区+空行+分隔线+提示行+错误行）放得下一屏即可。
    # 不要求光标下方有足够空间——二级菜单（供应商选择）绘制时光标通常已贴近屏底，
    # 初始绘制允许滚动，交互坐标在绘制完成后采集
    $arrow = Test-AcsArrowOk
    if ($arrow) {
        try { if ($n + 5 -gt [Console]::WindowHeight) { $arrow = $false } } catch { $arrow = $false }
    }

    # —— 行输入降级模式（行为与旧版一致：画行区 → 旧行输入提示 → 逐行交互）——
    if (-not $arrow) {
        for ($i = 0; $i -lt $n; $i++) {
            Write-AcsRow -Index ($IndexBase + $i) -IndexWidth $idxW -Key $rows[$i].Key -Desc $rows[$i].Desc `
                -IsLast:($rows[$i].Last) -KeyWidth $KeyWidth -Note $rows[$i].Note
        }
        Write-Host ''
        Write-Host ('  ' + ('─' * 46)) -ForegroundColor DarkGray
        Write-Host ('  ' + $(if ($HintInput) { $HintInput } else { $Hint })) -ForegroundColor DarkGray
        while ($true) {
            Write-Host $promptPrefix -ForegroundColor Yellow -NoNewline
            if ($LastMark) { Write-Host ('{0} ' -f $LastMark) -ForegroundColor DarkGray -NoNewline }
            Write-Host '▸ ' -ForegroundColor Yellow -NoNewline
            $text = Read-Host
            $r = & $Parse $text
            if ($r.ok) { return $r.value }
            Write-Host ('  ✘ {0}' -f $r.msg) -ForegroundColor Red
        }
    }

    $hi = [Math]::Max(0, [Math]::Min($Initial, $n - 1))
    try {
        # 初始绘制（可能触发滚动，属正常；交互坐标在绘制完成后采集）
        for ($i = 0; $i -lt $n; $i++) {
            Write-AcsRow -Index ($IndexBase + $i) -IndexWidth $idxW -Key $rows[$i].Key -Desc $rows[$i].Desc `
                -IsLast:($rows[$i].Last) -KeyWidth $KeyWidth -Note $rows[$i].Note -Highlight:($i -eq $hi)
        }
        Write-Host ''
        Write-Host ('  ' + ('─' * 46)) -ForegroundColor DarkGray
        if ($Hint) { Write-Host ('  ' + $Hint) -ForegroundColor DarkGray }
        # 保证提示行下方留有 1 行错误行：贴屏底时主动滚动一行，避免交互中滚动导致重绘坐标漂移
        $promptY = [Console]::CursorTop
        if ($promptY -gt [Console]::WindowHeight - 2) {
            Write-Host ''
            $promptY = [Console]::CursorTop - 1
        }
        $topY = $promptY - $n - 3   # 行区 n 行 + 空行 + 分隔线 + 提示行

        # 重绘行区并落回提示行（顺带清掉提示行上的输入残留；渲染期间隐藏光标防窜动）
        $redraw = {
            param($hi2)
            try { [Console]::CursorVisible = $false } catch { }
            [Console]::SetCursorPosition(0, $topY)
            for ($i = 0; $i -lt $n; $i++) {
                Write-AcsRow -Index ($IndexBase + $i) -IndexWidth $idxW -Key $rows[$i].Key -Desc $rows[$i].Desc `
                    -IsLast:($rows[$i].Last) -KeyWidth $KeyWidth -Note $rows[$i].Note -Highlight:($i -eq $hi2)
            }
            [Console]::SetCursorPosition(0, $promptY)
            [Console]::Write((' ' * [Math]::Max(1, [Console]::WindowWidth - 1)) + "`r")
            Write-Host $promptPrefix -ForegroundColor Yellow -NoNewline
            if ($LastMark) { Write-Host ('{0} ' -f $LastMark) -ForegroundColor DarkGray -NoNewline }
            Write-Host '▸ ' -ForegroundColor Yellow -NoNewline
            try { [Console]::CursorVisible = $true } catch { }
        }
        # 差分重绘：↑↓ 移动时只有新旧两行变化，仅重画这两行 + 提示行
        # （写入量从整表降到两行，配合藏光标消除光标窜动与闪烁；模式切换仍走全表 $redraw）
        $diffDraw = {
            param($oldHi, $newHi)
            try { [Console]::CursorVisible = $false } catch { }
            try {
                [Console]::SetCursorPosition(0, $topY + $oldHi)
                Write-AcsRow -Index ($IndexBase + $oldHi) -IndexWidth $idxW -Key $rows[$oldHi].Key -Desc $rows[$oldHi].Desc `
                    -IsLast:($rows[$oldHi].Last) -KeyWidth $KeyWidth -Note $rows[$oldHi].Note
                [Console]::SetCursorPosition(0, $topY + $newHi)
                Write-AcsRow -Index ($IndexBase + $newHi) -IndexWidth $idxW -Key $rows[$newHi].Key -Desc $rows[$newHi].Desc `
                    -IsLast:($rows[$newHi].Last) -KeyWidth $KeyWidth -Note $rows[$newHi].Note -Highlight
            } finally {
                [Console]::SetCursorPosition(0, $promptY)
                Write-Host $promptPrefix -ForegroundColor Yellow -NoNewline
                if ($LastMark) { Write-Host ('{0} ' -f $LastMark) -ForegroundColor DarkGray -NoNewline }
                Write-Host '▸ ' -ForegroundColor Yellow -NoNewline
                try { [Console]::CursorVisible = $true } catch { }
            }
        }
        & $redraw $hi

        # 交互循环：方向键移动 / Enter 确认 / Esc 返回；可打印字符进入预填行输入
        $buf = ''
        $lineMode = $false
        while ($true) {
            $key = [Console]::ReadKey($true)
            if (-not $lineMode) {
                switch ($key.Key) {
                    'UpArrow'   { $old = $hi; $hi = ($hi - 1 + $n) % $n; & $diffDraw $old $hi }
                    'DownArrow' { $old = $hi; $hi = ($hi + 1) % $n; & $diffDraw $old $hi }
                    'Enter'     { Write-Host ''; return $rows[$hi].Key }
                    'Escape'    { Write-Host ''; return $EscResult }
                    default {
                        $c = $key.KeyChar
                        if ($c -and -not [char]::IsControl($c)) { $lineMode = $true; $buf = [string]$c; Write-Host $c -NoNewline }
                    }
                }
            } else {
                switch ($key.Key) {
                    'Enter' {
                        $r = & $Parse $buf
                        if ($r.ok) { Write-Host ''; return $r.value }
                        Write-Host ''
                        Write-Host ('  ✘ {0}' -f $r.msg) -ForegroundColor Red
                        $lineMode = $false; $buf = ''
                        & $redraw $hi
                    }
                    'Backspace' {
                        if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1); Write-Host "`b `b" -NoNewline }
                    }
                    'Escape'    { $lineMode = $false; $buf = ''; & $redraw $hi }
                    'UpArrow'   { $hi = ($hi - 1 + $n) % $n; $lineMode = $false; $buf = ''; & $redraw $hi }
                    'DownArrow' { $hi = ($hi + 1) % $n; $lineMode = $false; $buf = ''; & $redraw $hi }
                    default {
                        $c = $key.KeyChar
                        if ($c -and -not [char]::IsControl($c)) { $buf += $c; Write-Host $c -NoNewline }
                    }
                }
            }
        }
    } catch {
        # 光标定位失败（窗口过小/尺寸变化）等异常：恢复光标可见后退回行输入模式兜底
        try { [Console]::CursorVisible = $true } catch { }
        Write-Host ''
        while ($true) {
            Write-Host $promptPrefix -ForegroundColor Yellow -NoNewline
            Write-Host '▸ ' -ForegroundColor Yellow -NoNewline
            $text = Read-Host
            $r = & $Parse $text
            if ($r.ok) { return $r.value }
            Write-Host ('  ✘ {0}' -f $r.msg) -ForegroundColor Red
        }
    }
}

# official 行备注：claude 检测官方登录态（其他 CLI 的登录检测二期待接入）
function Get-AcsOfficialNote {
    param([string]$CliId)
    if ($CliId -ne 'claude') { return '' }
    try {
        $f = Join-Path $HOME '.claude.json'
        if (Test-Path $f) {
            $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.oauthAccount -and $j.oauthAccount.emailAddress) { return '' }
        }
    } catch { }
    return '未登录'
}

# ----------------------------------------------------------------------------
# suppliers.json 写回（PS5.1 的 ConvertTo-Json 会把中文转义为 \uXXXX，这里还原）
# ----------------------------------------------------------------------------

# 还原 JSON 文本中的 \uXXXX 序列为真实字符（含代理对；先占位字面 \\ 防误伤）
function ConvertFrom-AcsUnicodeEscape {
    param([string]$Text)
    $text = $Text.Replace('\\', "`x01ACSBS`x01")
    $text = [regex]::Replace($text, '\\u([0-9a-fA-F]{4})', {
        param($m)
        try { return [char]::ConvertFromUtf32([Convert]::ToInt32($m.Groups[1].Value, 16)) } catch { return $m.Value }
    })
    return $text.Replace("`x01ACSBS`x01", '\\')
}

# 把供应商表写回 suppliers.json（递归转 PSObject → JSON → 中文还原，UTF-8 无 BOM）
function Save-AcsSupplierMap {
    param($Map)
    function Convert-ToPlain {
        param($Obj)
        if ($null -eq $Obj) { return $null }
        # 标量必须最先判断：cmdlet/Read-Host 返回的字符串附着 Length 等 NoteProperty 后
        # 会被 -is [PSCustomObject] 误判为对象而枚举出 {"Length":n}，因此标量检查先于一切容器分支，
        # 且用 "$Obj" 文本化剥壳（拼接创建新实例，丢弃附着属性）
        if ($Obj -is [string]) { return "$Obj" }
        if ($Obj -is [bool] -or $Obj -is [int] -or $Obj -is [long] -or $Obj -is [double]) { return $Obj }
        if ($Obj -is [PSCustomObject]) {
            $o = [ordered]@{}
            foreach ($p in $Obj.PSObject.Properties) { $o[$p.Name] = Convert-ToPlain $p.Value }
            return $o
        }
        # 字典类型（含 OrderedDictionary）必须先于 IEnumerable 处理，否则会被枚举成 DictionaryEntry 数组
        if ($Obj -is [System.Collections.IDictionary]) {
            $o = [ordered]@{}
            foreach ($k in $Obj.Keys) { $o[$k] = Convert-ToPlain $Obj[$k] }
            return $o
        }
        if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
            $a = @(); foreach ($i in $Obj) { $a += (Convert-ToPlain $i) }
            return $a
        }
        # 叶子值防御：未知对象立即拒绝写入，保护整份数据
        throw ('检测到非法供应商数据（类型 ' + $Obj.GetType().Name + '），已拒绝写入 suppliers.json 以保护数据')
    }
    $plain = Convert-ToPlain $Map
    $json = $plain | ConvertTo-Json -Depth 10
    $json = ConvertFrom-AcsUnicodeEscape -Text $json
    [IO.File]::WriteAllText($script:AcsDataFile, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

# ----------------------------------------------------------------------------
# L2 混合适配器：配置预置器（一次性生成，不含密钥；密钥走环境变量注入）
# ----------------------------------------------------------------------------

# 展开 ~/.xxx 形式路径为绝对路径
function Expand-AcsTildePath {
    param([string]$Path)
    if ($Path -like '~\*' -or $Path -like '~/*') { return Join-Path $HOME $Path.Substring(2) }
    return $Path
}

# 提取某 CLI 组的全部 hybrid 条目：OrderedDictionary[id] = @{ Desc; Env; Preset }
function Get-AcsHybridEntries {
    param([string]$CliId, $Map)
    $list = Get-AcsSupplierList -CliId $CliId -Map $Map
    if ($null -eq $list) { return $null }
    $out = [ordered]@{}
    foreach ($k in $list.Keys) {
        $src = $list[$k]
        $preset = $null
        # preset 段在 suppliers.json 里是嵌套对象，Get-AcsSupplierList 只解析了 desc/env，这里补读
        $group = $Map[$CliId]
        $raw = $group.PSObject.Properties[$k].Value
        if ($raw.PSObject.Properties['preset'] -and $null -ne $raw.preset) {
            $preset = @{ BaseUrl = ''; Model = ''; ModelFast = ''; Protocol = 'openai'; WireApi = '' }
            foreach ($f in $raw.preset.PSObject.Properties) {
                switch ($f.Name) {
                    'baseUrl'   { $preset.BaseUrl = [string]$f.Value }
                    'model'     { $preset.Model = [string]$f.Value }
                    'modelFast' { $preset.ModelFast = [string]$f.Value }
                    'protocol'  { $preset.Protocol = [string]$f.Value }
                    'wireApi'   { $preset.WireApi = [string]$f.Value }
                }
            }
        }
        if ($null -eq $preset) { continue }
        $out[$k] = @{ Desc = $src.Desc; Env = $src.Env; Preset = $preset }
    }
    if ($out.Count -eq 0) { return $null }
    return ,$out
}

# 推导 hybrid 条目的 key 环境变量名：<keyEnvPrefix>_<ID大写>_KEY
function Get-AcsHybridKeyVar {
    param($CliDef, [string]$Id)
    return ($CliDef.keyEnvPrefix.ToUpper() + '_' + $Id.ToUpper() + '_KEY')
}

# TOML marker 块替换：已有 acs 段则整段替换，否则追加到文件末尾（幂等）
function Update-AcsMarkerBlock {
    param([string]$Path, [string]$Block)
    $head = '# >>> acs managed (do not edit) >>>'
    $tail = '# <<< acs <<<'
    $raw = ''
    if (Test-Path $Path) { $raw = Get-Content $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue }
    if (-not $raw) { $raw = '' }
    # TOML 值内的引号转义已在生成阶段完成（desc 等），这里按 marker 原样拼接
    $full = $head + "`n" + $Block + "`n" + $tail
    if ($raw -match [regex]::Escape($head)) {
        $pattern = '(?s)' + [regex]::Escape($head) + '.*?' + [regex]::Escape($tail)
        $new = [regex]::Replace($raw, $pattern, $full.Replace('$', '$$'))
    } else {
        if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) { $raw += "`n" }
        $new = $raw + $full + "`n"
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($false)))
}

# Codex 预置（profile v2 机制，2026-10 实测核实）：每个条目生成独立文件
# ~/.codex/acs_<id>.config.toml（codex --profile <name> 时叠加在 config.toml 之上），
# 并清理主 config.toml 中 legacy 的 acs marker 块（新版 codex 禁止两者共存）
function Preset-AcsCodex {
    param($CliDef, $Entries)
    $codexDir = Join-Path $HOME '.codex'
    if (-not (Test-Path $codexDir)) { New-Item -ItemType Directory -Path $codexDir -Force | Out-Null }
    # 1. 清理主 config.toml 里的 legacy acs marker 块（历史版本预置器写入的）
    $mainCfg = Join-Path $codexDir 'config.toml'
    if (Test-Path $mainCfg) {
        $raw = Get-Content $mainCfg -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($raw -and $raw -match [regex]::Escape('# >>> acs managed (do not edit) >>>')) {
            $pattern = '(?s)\r?\n?# >>> acs managed \(do not edit\) >>>.*?# <<< acs <<<\r?\n?'
            $new = [regex]::Replace($raw, $pattern, "`n")
            [IO.File]::WriteAllText($mainCfg, $new, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    # 2. 每条目写独立 profile 文件（顶层 model/model_provider + 自带的 model_providers 表）
    foreach ($id in $Entries.Keys) {
        $e = $Entries[$id]
        $acsId = 'acs_' + $id
        $keyVar = Get-AcsHybridKeyVar -CliDef $CliDef -Id $id
        $wire = $e.Preset.WireApi; if (-not $wire) { $wire = [string]$CliDef.wireApiDefault }
        $desc2 = [string]$e.Desc -replace '\\', '\\' -replace '"', '\"'
        $lines = @()
        $lines += ('model = "' + $e.Preset.Model + '"')
        $lines += ('model_provider = "' + $acsId + '"')
        $lines += ''
        $lines += ('[model_providers.' + $acsId + ']')
        $lines += ('name = "' + $desc2 + '"')
        $lines += ('base_url = "' + $e.Preset.BaseUrl + '"')
        $lines += ('env_key = "' + $keyVar + '"')
        $lines += ('wire_api = "' + $wire + '"')
        $pfile = Join-Path $codexDir ($acsId + '.config.toml')
        [IO.File]::WriteAllText($pfile, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    # 3. 清理已删除条目的残留 profile 文件
    foreach ($f in (Get-ChildItem $codexDir -Filter 'acs_*.config.toml' -ErrorAction SilentlyContinue)) {
        $fid = $f.Name -replace '^acs_', '' -replace '\.config\.toml$', ''
        if ($Entries.Keys -notcontains $fid) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# OpenCode 预置：opencode.json 的 provider.acs_*（JSON 命名空间合并，保留用户自有配置）
function Preset-AcsOpencode {
    param($CliDef, $Entries)
    $path = Expand-AcsTildePath $CliDef.configFile
    $obj = $null
    if (Test-Path $path) {
        try { $obj = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Write-Host ('  ✘ {0} 不是有效 JSON，拒绝写入（请先修复该文件）' -f $path) -ForegroundColor Red
            return $false
        }
    }
    if ($null -eq $obj) { $obj = [PSCustomObject]@{} }
    if (-not $obj.PSObject.Properties['provider']) { $obj | Add-Member -MemberType NoteProperty -Name 'provider' -Value ([PSCustomObject]@{}) }
    $prov = $obj.provider
    foreach ($n in @($prov.PSObject.Properties.Name)) { if ($n -like 'acs_*') { $prov.PSObject.Properties.Remove($n) } }
    foreach ($id in $Entries.Keys) {
        $e = $Entries[$id]
        $keyVar = Get-AcsHybridKeyVar -CliDef $CliDef -Id $id
        $npm = '@ai-sdk/openai-compatible'
        if ($e.Preset.Protocol -eq 'anthropic') { $npm = '@ai-sdk/anthropic' }
        $models = [PSCustomObject]@{}
        $models | Add-Member -MemberType NoteProperty -Name $e.Preset.Model -Value ([PSCustomObject]@{ name = $e.Preset.Model })
        if ($e.Preset.ModelFast) { $models | Add-Member -MemberType NoteProperty -Name $e.Preset.ModelFast -Value ([PSCustomObject]@{ name = $e.Preset.ModelFast }) }
        $acsEntry = [PSCustomObject]@{
            npm     = $npm
            name    = $e.Desc
            options = [PSCustomObject]@{ baseURL = $e.Preset.BaseUrl; apiKey = ('{env:' + $keyVar + '}') }
            models  = $models
        }
        $prov | Add-Member -MemberType NoteProperty -Name ('acs_' + $id) -Value $acsEntry
    }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertFrom-AcsUnicodeEscape -Text ($obj | ConvertTo-Json -Depth 10)
    [IO.File]::WriteAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

# Crush 预置：crush.json 的 providers.acs_*（base_url/api_key 用 $VAR 展开）+ models.large/small 默认段
# 注意：models.large 为全局唯一默认，多条目并行时以最后切换的为准（crush 限制，见调研报告）
function Preset-AcsCrush {
    param($CliDef, $Entries)
    $path = Expand-AcsTildePath $CliDef.configFile
    $obj = $null
    if (Test-Path $path) {
        try { $obj = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Write-Host ('  ✘ {0} 不是有效 JSON，拒绝写入（请先修复该文件）' -f $path) -ForegroundColor Red
            return $false
        }
    }
    if ($null -eq $obj) { $obj = [PSCustomObject]@{} }
    if (-not $obj.PSObject.Properties['providers']) { $obj | Add-Member -MemberType NoteProperty -Name 'providers' -Value ([PSCustomObject]@{}) }
    $prov = $obj.providers
    foreach ($n in @($prov.PSObject.Properties.Name)) { if ($n -like 'acs_*') { $prov.PSObject.Properties.Remove($n) } }
    $firstId = $null
    foreach ($id in $Entries.Keys) {
        $e = $Entries[$id]
        if (-not $firstId) { $firstId = $id }
        $keyVar = Get-AcsHybridKeyVar -CliDef $CliDef -Id $id
        $urlVar = $keyVar -replace '_KEY$', '_URL'
        $models = @()
        $models += [PSCustomObject]@{ id = $e.Preset.Model; name = $e.Preset.Model }
        if ($e.Preset.ModelFast) { $models += [PSCustomObject]@{ id = $e.Preset.ModelFast; name = $e.Preset.ModelFast } }
        $acsEntry = [PSCustomObject]@{
            name    = $e.Desc
            type    = $e.Preset.Protocol
            base_url = ('$' + $urlVar)
            api_key = ('$' + $keyVar)
            models  = $models
        }
        $prov | Add-Member -MemberType NoteProperty -Name ('acs_' + $id) -Value $acsEntry
    }
    # 默认模型段（acs 管理）：指向第一个条目；条目带快速模型时同步补 small 段
    if ($firstId) {
        $e = $Entries[$firstId]
        $m = [ordered]@{ large = [PSCustomObject]@{ model = $e.Preset.Model; provider = ('acs_' + $firstId) } }
        if ($e.Preset.ModelFast) { $m['small'] = [PSCustomObject]@{ model = $e.Preset.ModelFast; provider = ('acs_' + $firstId) } }
        $mObj = [PSCustomObject]$m
        if ($obj.PSObject.Properties['models']) { $obj.models = $mObj } else { $obj | Add-Member -MemberType NoteProperty -Name 'models' -Value $mObj }
    }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertFrom-AcsUnicodeEscape -Text ($obj | ConvertTo-Json -Depth 10)
    [IO.File]::WriteAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

# 预置器总入口：按 CLI 的 configFormat 分派生成
function Invoke-AcsPreset {
    param([string]$CliId)
    $clis = Get-AcsClis
    if ($null -eq $clis) { return }
    $map = Get-AcsSupplierMap
    if ($null -eq $map) { return }
    $cliDef = $clis[$CliId]
    if ($null -eq $cliDef) { Write-Host ('  ✘ 未知 CLI: {0}' -f $CliId) -ForegroundColor Red; return }
    if ($cliDef.adapter -ne 'hybrid') { Write-Host ('  ✘ {0} 是 {1} 适配器，无需预置' -f $CliId, $cliDef.adapter) -ForegroundColor Yellow; return }
    $entries = Get-AcsHybridEntries -CliId $CliId -Map $map
    if ($null -eq $entries) {
        Write-Host ('  ⚠ {0} 没有任何 hybrid 型供应商，跳过预置' -f $CliId) -ForegroundColor Yellow
        return
    }
    switch ($cliDef.configFormat) {
        'toml' {
            Preset-AcsCodex -CliDef $cliDef -Entries $entries
            Write-Host ('  ✔ 已预置 {0}（{1} 个供应商）→ {2}\acs_<供应商ID>.config.toml' -f $CliId, $entries.Count, (Join-Path $HOME '.codex')) -ForegroundColor Green
        }
        'json' {
            $ok = $false
            if ($CliId -eq 'opencode') { $ok = Preset-AcsOpencode -CliDef $cliDef -Entries $entries }
            elseif ($CliId -eq 'crush') { $ok = Preset-AcsCrush -CliDef $cliDef -Entries $entries }
            if ($ok) { Write-Host ('  ✔ 已预置 {0}（{1} 个供应商）→ {2}' -f $CliId, $entries.Count, (Expand-AcsTildePath $cliDef.configFile)) -ForegroundColor Green }
        }
        default { Write-Host ('  ✘ 未知配置格式: {0}' -f $cliDef.configFormat) -ForegroundColor Red }
    }
}

# Crush 启动前同步默认模型段（models.large/small 指向选中条目；crush 无法用启动参数选模型）
function Set-AcsCrushModel {
    param([string]$Sel, $Preset)
    $clis = Get-AcsClis -Quiet
    if ($null -eq $clis -or -not $clis['crush']) { return }
    $path = Expand-AcsTildePath $clis['crush'].configFile
    if (-not (Test-Path $path)) { return }
    try { $obj = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    if (-not $obj.PSObject.Properties['models']) { return }
    # large 指向选中条目主力；条目带快速模型时同步 small（M-B）
    $m = [ordered]@{ large = [PSCustomObject]@{ model = $Preset.Model; provider = ('acs_' + $Sel) } }
    if ($Preset.Fast) { $m['small'] = [PSCustomObject]@{ model = $Preset.Fast; provider = ('acs_' + $Sel) } }
    $obj.models = [PSCustomObject]$m
    $json = ConvertFrom-AcsUnicodeEscape -Text ($obj | ConvertTo-Json -Depth 10)
    [IO.File]::WriteAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}


function Add-AcsSupplier {
    param([string]$CliId, [switch]$Paste)

    # 剪贴板导入分支：解析粘贴的环境变量赋值块直接入库（仅 L1 型 CLI）
    if ($Paste) {
        $clis0 = Get-AcsClis
        if ($null -eq $clis0) { return }
        $map0 = Get-AcsSupplierMap
        if ($null -eq $map0) { return }
        if (-not $CliId) { Write-Host '  用法: acs add <cli> -paste（如 acs add claude -paste）' -ForegroundColor Yellow; return }
        $fc = Find-AcsKey -List $clis0 -Name $CliId
        if (-not $fc) { Write-Host ('  ✘ 未知 CLI: {0}' -f $CliId) -ForegroundColor Red; return }
        if ($clis0[$fc].adapter -ne 'env') {
            Write-Host '  ✘ 剪贴板导入仅支持纯环境变量型 CLI；hybrid 型请走 acs add 向导' -ForegroundColor Red
            return
        }
        $text = $null
        try { $text = Get-Clipboard -Raw } catch { }
        if ([string]::IsNullOrWhiteSpace($text)) { Write-Host '  ✘ 剪贴板为空，请先复制 export 块 / $env: 块 / .env 内容' -ForegroundColor Red; return }
        $pairs = Parse-AcsEnvText -Text $text
        if ($pairs.Count -eq 0) { Write-Host '  ✘ 剪贴板内容里没有解析到任何 KEY=VALUE 赋值' -ForegroundColor Red; return }
        Write-Host ('  ✔ 解析到 {0} 个变量：' -f $pairs.Count) -ForegroundColor Green
        foreach ($k in $pairs.Keys) {
            $v = $pairs[$k]
            $show = if ($v.Length -gt 10) { $v.Substring(0, 6) + '…' } else { $v }
            Write-Host ('    {0} = {1}' -f $k, $show) -ForegroundColor DarkGray
        }
        # 必填字段循环重试：输错只重问当前字段，不丢弃剪贴板解析结果（Ctrl+C 退出向导）
        $id = Read-AcsValidated -Prompt '  供应商 ID（英文短名）▸' -Validate { param($x) if ($x -match '[^a-zA-Z0-9_-]') { return 'ID 只能含字母/数字/下划线/中划线' } }
        $desc = Read-Host '  显示名 ▸'
        if ([string]::IsNullOrWhiteSpace($desc)) { $desc = $id }
        $envO = [ordered]@{}
        foreach ($k in $pairs.Keys) { $envO[$k] = $pairs[$k] }
        if ($null -eq $map0[$fc]) { $map0[$fc] = [PSCustomObject]@{} }
        if ($map0[$fc].PSObject.Properties[$id]) { Write-Host ('  ✘ 供应商已存在: {0}/{1}' -f $fc, $id) -ForegroundColor Red; return }
        $map0[$fc] | Add-Member -MemberType NoteProperty -Name $id -Value ([PSCustomObject]@{ desc = $desc; env = $envO })
        try {
            Save-AcsSupplierMap -Map $map0
            Write-Host ('  ✔ 已导入 {0}/{1}（{2} 个变量）' -f $fc, $id, $pairs.Count) -ForegroundColor Green
        } catch {
            Write-Host ('  ✘ 写入失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
        return
    }

    $clis = Get-AcsClis
    if ($null -eq $clis) { return }
    $map = Get-AcsSupplierMap
    if ($null -eq $map) { return }

    # 第一步：确定目标 CLI（参数指定则校验，否则菜单选择）
    if ($CliId) {
        $found = Find-AcsKey -List $clis -Name $CliId
        if (-not $found) { Write-Host ('  ✘ 未知 CLI: {0}' -f $CliId) -ForegroundColor Red; return }
        $CliId = $found
    } else {
        # 选择 CLI：方向键选择器 + 未安装标注（避免为未安装的 CLI 走完向导才发现装不了）
        $ids = @($clis.Keys)
        $rows = @()
        foreach ($a in $ids) {
            $note = ''
            if (-not (Get-Command $clis[$a].cmd -ErrorAction SilentlyContinue)) { $note = '未安装' }
            $rows += @{ Key = $a; Desc = [string]$clis[$a].name; Note = $note; Last = $false }
        }
        $keyW = 10
        foreach ($a in $ids) { $l = [Math]::Min(14, $a.Length + 1); if ($l -gt $keyW) { $keyW = $l } }
        $parse = {
            param($text)
            if ($text) {
                $exact = Find-AcsKey -List $clis -Name $text
                if ($exact) { return @{ ok = $true; value = $exact } }
                if ($text -match '^\d{1,2}$') {
                    if ([int]$text -ge 1 -and [int]$text -le $ids.Count) { return @{ ok = $true; value = $ids[[int]$text - 1] } }
                    return @{ ok = $false; msg = ('序号超出范围: {0}（有效范围 1-{1}）' -f $text, $ids.Count) }
                }
                return @{ ok = $false; msg = ('未知 CLI: {0}' -f $text) }
            }
            return @{ ok = $true; value = 'cancel' }   # 行输入模式回车 = 取消（沿用旧版语义）
        }
        Write-Host ''
        Write-AcsHeader -Title 'acs add · 选择 Agent CLI'
        Write-Host ''
        $picked = Invoke-AcsSelect -Prompt '选择 CLI' -Rows $rows -Initial 0 -Parse $parse -EscResult 'cancel' -KeyWidth $keyW -IndexBase 1 `
            -Hint '↑↓ 移动 · Enter 确认 · 输入序号/名字直达 · Esc 取消' `
            -HintInput '输入序号或名字直达（回车取消）'
        if ($picked -eq 'cancel' -or $picked -eq '__ESC__') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
        $CliId = $picked
    }
    $cliDef = $clis[$CliId]

    # 第二步：选内置预设
    $presetIds = @(); $presetDescs = @()
    if ($cliDef.presets) {
        foreach ($p in $cliDef.presets.PSObject.Properties) { $presetIds += $p.Name; $presetDescs += [string]$p.Value.desc }
    }
    if ($presetIds.Count -eq 0) { Write-Host '  ✘ 该 CLI 没有内置预设，请手编 suppliers.json' -ForegroundColor Red; return }
    # 选择预设：方向键选择器（warn 提示作行尾暗色备注）
    $rows = @()
    for ($i = 0; $i -lt $presetIds.Count; $i++) {
        $presetObj = $clis[$CliId].presets.($presetIds[$i])
        $rows += @{ Key = $presetIds[$i]; Desc = [string]$presetDescs[$i]; Note = ([string]$presetObj.warn); Last = $false }
    }
    $keyW = 10
    foreach ($p2 in $presetIds) { $l = [Math]::Min(14, $p2.Length + 1); if ($l -gt $keyW) { $keyW = $l } }
    $parse = {
        param($text)
        if ($text) {
            foreach ($n2 in $presetIds) { if ($n2 -ieq $text) { return @{ ok = $true; value = $n2 } } }
            if ($text -match '^\d{1,2}$') {
                if ([int]$text -ge 1 -and [int]$text -le $presetIds.Count) { return @{ ok = $true; value = $presetIds[[int]$text - 1] } }
                return @{ ok = $false; msg = ('序号超出范围: {0}（有效范围 1-{1}）' -f $text, $presetIds.Count) }
            }
            return @{ ok = $false; msg = ('未知预设: {0}' -f $text) }
        }
        return @{ ok = $true; value = 'cancel' }   # 行输入模式回车 = 取消（沿用旧版语义）
    }
    Write-Host ''
    Write-AcsHeader -Title ('选择 {0} 的供应商预设' -f $cliDef.name) -Suffix ('({0})' -f $CliId)
    Write-Host ''
    $picked = Invoke-AcsSelect -Prompt '选择预设' -Rows $rows -Initial 0 -Parse $parse -EscResult 'cancel' -KeyWidth $keyW -IndexBase 1 `
        -Hint '↑↓ 移动 · Enter 确认 · 输入序号/名字直达 · Esc 取消' `
        -HintInput '输入序号或名字直达（回车取消）'
    if ($picked -eq 'cancel' -or $picked -eq '__ESC__') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
    $preset = $clis[$CliId].presets.$picked
    if (-not $preset) { Write-Host '  已取消。' -ForegroundColor DarkGray; return }

    # 第三步：供应商 ID 与显示名（显示名默认自动生成「厂商 · 账号」格式，回车即得规范名）
    # 必填字段循环重试：输错只重问当前字段，不丢弃向导已录入内容（Ctrl+C 退出向导）
    $id = Read-AcsValidated -Prompt '  供应商 ID（英文短名，如 glmb / ds2）▸' -Validate { param($x) if ($x -match '[^a-zA-Z0-9_-]') { return 'ID 只能含字母/数字/下划线/中划线' } }
    $defDesc = [string]$preset.desc
    $suggestDesc = if ($defDesc -and $defDesc -ne $id) { $defDesc + ' · ' + $id } else { $id }
    $desc = Read-Host ('  显示名 [{0}] ▸' -f $suggestDesc)
    if ([string]::IsNullOrWhiteSpace($desc)) { $desc = $suggestDesc }

    # 第四步：按适配器类型组装条目（L1 = env 组；L2 = env 密钥 + preset 元数据段）
    $env = [ordered]@{}
    $presetSec = $null
    if ($cliDef.adapter -eq 'hybrid') {
        # L2：key 变量名按约定生成（ACS_<CLI>_<ID>_KEY），密钥只进 env，配置文件只存指针
        $keyVar = $cliDef.keyEnvPrefix.ToUpper() + '_' + $id.ToUpper() + '_KEY'
        $defUrl = [string]$preset.baseUrl
        $b = $defUrl
        if ($defUrl) {
            $x = Read-Host ('  API 端点 [{0}] ▸' -f $defUrl)
            if (-not [string]::IsNullOrWhiteSpace($x)) { $b = $x }
        } else {
            $b = Read-AcsValidated -Prompt '  API 端点 ▸'
        }
        if ($cliDef.launchStyle -eq 'envOnly') {
            # crush 型：base_url 同样走 $VAR 展开，与 key 一起进 env
            $env[$keyVar -replace '_KEY$', '_URL'] = $b
        }
        $key = Read-AcsValidated -Prompt ('  API Key（{0}）▸' -f $keyVar)
        $env[$keyVar] = $key
        # 协议兼容性探测（clis.json 声明 probePath 的 CLI 才触发，当前仅 codex）：录入时点告知并二选一引导
        $mode = 'direct'
        $probePath = [string]$cliDef.probePath
        while ($probePath) {
            Write-Host '  ⋯ 正在检测端点协议兼容性...' -ForegroundColor DarkGray
            $probe = Test-AcsEndpointProtocol -BaseUrl $b -ProbePath $probePath -ApiKey $key
            if ($probe -eq 'ok') { $mode = 'direct'; Write-Host '  ✔ 端点协议兼容，直连模式' -ForegroundColor Green; break }
            if ($probe -eq 'unsupported') {
                Write-Host ('  ✘ 该端点未实现 {0} 要求的 {1} 接口（404）' -f $cliDef.name, $probePath) -ForegroundColor Yellow
                $how = Read-Host '  ? 处理方式 [1]启用翻译代理(推荐) [2]重新输入端点 [3]仍保存此端点 ▸'
                if ($how -eq '1') {
                    $mode = 'proxy'
                    Write-Host '  ✔ 代理模式：启动时自动拉起翻译代理，随会话退出关闭' -ForegroundColor Green
                    break
                }
                if ($how -eq '3') {
                    $mode = 'direct'
                    Write-Host ('  ⚠ 已保存，但该端点不可用于 {0}' -f $cliDef.name) -ForegroundColor Yellow
                    break
                }
                $b = Read-Host '  API 端点 ▸'
                if ([string]::IsNullOrWhiteSpace($b)) { continue }
                continue
            }
            if ($probe -eq 'auth') {
                Write-Host '  ⚠ Key 校验未通过（401/403），请确认 Key 是否正确；供应商仍将保存' -ForegroundColor Yellow
                $mode = 'direct'; break
            }
            $r = Read-Host '  ? 探测未完成（网络原因），仍要保存吗? [y/N] ▸'
            if ($r -match '^[yY]') { $mode = 'direct'; break }
            Write-Host '  已取消。' -ForegroundColor DarkGray
            return
        }
        $defModel = [string]$preset.model
        $m = $defModel
        if ($defModel) {
            $x = Read-Host ('  默认模型 [{0}] ▸' -f $defModel)
            if (-not [string]::IsNullOrWhiteSpace($x)) { $m = $x }
        } else {
            $m = Read-AcsValidated -Prompt '  模型名 ▸'
        }
        $proto = [string]$preset.protocol; if (-not $proto) { $proto = 'openai' }
        $wire = [string]$cliDef.wireApiDefault
        $presetSec = [ordered]@{ baseUrl = $b; model = $m; protocol = $proto; mode = $mode }
        if ($probePath) { $presetSec.probedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        if ($wire) { $presetSec.wireApi = $wire }
        # 快速模型（M-B，multiModel CLI）：写入 preset.modelFast，预置器生成多模型候选
        if ($cliDef.multiModel) {
            $defFast = [string]$preset.modelFast
            if ($defFast) {
                $x = Read-Host ('  快速模型 [{0}] ▸' -f $defFast)
                $presetSec.modelFast = if ([string]::IsNullOrWhiteSpace($x)) { $defFast } else { $x.Trim() }
            } else {
                $x = Read-Host '  快速模型（可选，回车跳过）▸'
                if (-not [string]::IsNullOrWhiteSpace($x)) { $presetSec.modelFast = $x.Trim() }
            }
        }
    } else {
        if ($preset.baseUrl -and -not $preset.noBaseUrl) {
            $b = Read-Host ('  API 端点 [{0}] ▸' -f $preset.baseUrl)
            if ([string]::IsNullOrWhiteSpace($b)) { $b = [string]$preset.baseUrl }
            $env[$cliDef.baseUrlEnv] = $b
        } elseif (-not $preset.noBaseUrl) {
            $b = Read-Host ('  API 端点（{0}）▸' -f $cliDef.baseUrlEnv)
            if (-not [string]::IsNullOrWhiteSpace($b)) { $env[$cliDef.baseUrlEnv] = $b }
        }
        $key = Read-AcsValidated -Prompt ('  API Key（{0}）▸' -f $cliDef.keyEnv)
        $env[$cliDef.keyEnv] = $key
        # 预设附带 env 先合并；模型槽位随后按向导回答覆盖（向导值优先）
        if ($preset.env) {
            foreach ($p in $preset.env.PSObject.Properties) { $env[$p.Name] = [string]$p.Value }
        }
        $defModel = [string]$preset.model
        if ($CliId -ieq 'claude') {
            # claude 模型组（M-A）：主力 → OPUS/SONNET 槽位 + ANTHROPIC_MODEL（优先级最高，
            # 压过会话内 /model 写入全局 settings.json 的保存值，保证每次启动回到主力）；
            # 快速 → HAIKU 槽位（回车 = 同主力）；主力留空则跳过，保持 preset.env 既有行为
            $curSonnet = ''
            if ($preset.env -and $preset.env.ANTHROPIC_DEFAULT_SONNET_MODEL) { $curSonnet = [string]$preset.env.ANTHROPIC_DEFAULT_SONNET_MODEL }
            $main = $null
            if ($defModel -or $curSonnet) {
                $suggest = $defModel; if (-not $suggest) { $suggest = $curSonnet }
                $x = Read-Host ('  主力模型 [{0}] ▸' -f $suggest)
                $main = if ([string]::IsNullOrWhiteSpace($x)) { $suggest } else { $x.Trim() }
            } else {
                $x = Read-Host '  主力模型（回车跳过）▸'
                if (-not [string]::IsNullOrWhiteSpace($x)) { $main = $x.Trim() }
            }
            if ($main) {
                $x = Read-Host '  快速模型（回车 = 同主力）▸'
                $fast = if ([string]::IsNullOrWhiteSpace($x)) { $main } else { $x.Trim() }
                $env['ANTHROPIC_MODEL'] = $main
                $env['ANTHROPIC_DEFAULT_OPUS_MODEL'] = $main
                $env['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $main
                $env['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $fast
            }
        } elseif ($defModel) {
            $m = Read-Host ('  默认模型 [{0}] ▸' -f $defModel)
            if ([string]::IsNullOrWhiteSpace($m)) { $m = $defModel }
            $env[$cliDef.modelEnv] = $m
        }
    }

    # 重复 Key 检测（写入前，排除本条目槽位）：同一把 Key 已存在其他条目时提醒，不阻断
    $dupHits = @()
    foreach ($nv in $env.Values) {
        if (-not $nv -or $nv.Length -lt 10) { continue }
        foreach ($g2 in $map.Keys) {
            $l2 = Get-AcsSupplierList -CliId $g2 -Map $map
            if ($null -eq $l2) { continue }
            foreach ($k2 in $l2.Keys) {
                if ($g2 -eq $CliId -and $k2 -ieq $id) { continue }
                foreach ($ev in $l2[$k2].Env.Values) {
                    if ($ev -eq $nv) { $dupHits += ('{0}/{1}' -f $g2, $k2); break }
                }
            }
        }
    }
    $dupHits = @($dupHits | Select-Object -Unique)

    # 第五步：写回 suppliers.json（组不存在则创建；hybrid 写后联动预置器）
    if ($null -ne $presetSec) { $entry = [ordered]@{ desc = $desc; env = $env; preset = $presetSec } }
    else { $entry = [ordered]@{ desc = $desc; env = $env } }
    if ($null -eq $map[$CliId]) {
        $group = [PSCustomObject]@{ }
        $map[$CliId] = $group
    }
    $group = $map[$CliId]
    if ($null -eq $group.PSObject.Properties[$id]) {
        $group | Add-Member -MemberType NoteProperty -Name $id -Value ([PSCustomObject]$entry)
    } else {
        $over = Read-Host ('  ⚠ 供应商 {0} 已存在，覆盖? (y/N) ▸' -f $id)
        if ($over -notmatch '^[yY]') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
        $group.PSObject.Properties[$id].Value = [PSCustomObject]$entry
    }
    try {
        Save-AcsSupplierMap -Map $map
        Write-Host ('  ✔ 已写入 {0} · 组 {1} · 供应商 {2}（{3}）' -f $script:AcsDataFile, $CliId, $id, $desc) -ForegroundColor Green
    } catch {
        Write-Host ('  ✘ 写入失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return
    }
    if ($dupHits.Count -gt 0) {
        Write-Host ('  ⚠ 该 Key 与已有条目重复: {0}（如非有意请检查）' -f ($dupHits -join '、')) -ForegroundColor Yellow
    }
    if ($cliDef.adapter -eq 'hybrid') { Invoke-AcsPreset -CliId $CliId }
}

# ----------------------------------------------------------------------------
# acs edit / acs remove
# ----------------------------------------------------------------------------

# 编辑条目：逐项询问，回车保留原值；hybrid 条目改后联动预置器
function Edit-AcsSupplier {
    param([string]$CliId, [string]$ProvId)
    $clis = Get-AcsClis
    if ($null -eq $clis) { return }
    $map = Get-AcsSupplierMap
    if ($null -eq $map) { return }
    if (-not $CliId -or -not $ProvId) { Write-Host '  用法: acs edit <cli> <provider>' -ForegroundColor Yellow; return }
    $foundCli = Find-AcsKey -List $map -Name $CliId
    if (-not $foundCli) { Write-Host ('  ✘ suppliers.json 里没有 CLI 组: {0}' -f $CliId) -ForegroundColor Red; return }
    $group = $map[$foundCli]
    $foundProv = $null
    foreach ($p in $group.PSObject.Properties) { if ($p.Name -ieq $ProvId) { $foundProv = $p; break } }
    if (-not $foundProv) { Write-Host ('  ✘ 供应商不存在: {0}/{1}' -f $foundCli, $ProvId) -ForegroundColor Red; return }
    $cliDef = $clis[$foundCli]
    $entry = $foundProv.Value

    # desc
    $cur = [string]$entry.desc
    $v = Read-Host ('  显示名 [{0}] ▸' -f $cur)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $entry.desc = $v }

    # env 里的 key（L1: keyEnv；L2: *_KEY 结尾的变量）
    $keyName = $cliDef.keyEnv
    if ($cliDef.adapter -eq 'hybrid') {
        foreach ($k in @($entry.env.PSObject.Properties.Name)) { if ($k -like '*_KEY') { $keyName = $k } }
    }
    if ($entry.env -and $entry.env.PSObject.Properties[$keyName]) {
        $cur = [string]$entry.env.$keyName
        $v = Read-Host ('  API Key [{0}…{1}] ▸' -f $cur.Substring(0, [Math]::Min(6, $cur.Length)), $cur.Substring([Math]::Max(0, $cur.Length - 4)))
        if (-not [string]::IsNullOrWhiteSpace($v)) { $entry.env.$keyName = $v }
    }

    # baseUrl / model
    if ($cliDef.adapter -eq 'hybrid') {
        if ($entry.preset) {
            $cur = [string]$entry.preset.baseUrl
            $v = Read-Host ('  API 端点 [{0}] ▸' -f $cur)
            if (-not [string]::IsNullOrWhiteSpace($v)) { $entry.preset.baseUrl = $v }
            $cur = [string]$entry.preset.model
            $v = Read-Host ('  默认模型 [{0}] ▸' -f $cur)
            if (-not [string]::IsNullOrWhiteSpace($v)) { $entry.preset.model = $v }
            # 快速模型（M-B）：multiModel CLI 可改；留空保留原值
            if ($cliDef.multiModel) {
                $curFast = ''
                if ($entry.preset.PSObject.Properties['modelFast']) { $curFast = [string]$entry.preset.modelFast }
                if ($curFast) {
                    $v = Read-Host ('  快速模型 [{0}] ▸' -f $curFast)
                    if (-not [string]::IsNullOrWhiteSpace($v)) { Set-AcsObjProp $entry.preset 'modelFast' $v.Trim() }
                } else {
                    $v = Read-Host '  快速模型（可选，回车跳过）▸'
                    if (-not [string]::IsNullOrWhiteSpace($v)) { Set-AcsObjProp $entry.preset 'modelFast' $v.Trim() }
                }
            }
        }
    } else {
        if ($entry.env -and $entry.env.PSObject.Properties[$cliDef.baseUrlEnv]) {
            $cur = [string]$entry.env.($cliDef.baseUrlEnv)
            $v = Read-Host ('  API 端点 [{0}] ▸' -f $cur)
            if (-not [string]::IsNullOrWhiteSpace($v)) { $entry.env.($cliDef.baseUrlEnv) = $v }
        }
        if ($entry.env -and $entry.env.PSObject.Properties[$cliDef.modelEnv]) {
            $cur = [string]$entry.env.($cliDef.modelEnv)
            $v = Read-Host ('  默认模型 [{0}] ▸' -f $cur)
            if (-not [string]::IsNullOrWhiteSpace($v)) { $entry.env.($cliDef.modelEnv) = $v }
        }
        # claude 模型组（M-A）：主力改动同步三槽位 + ANTHROPIC_MODEL；快速模型可改
        if ($foundCli -ieq 'claude' -and $entry.env) {
            $hasGroup = $entry.env.PSObject.Properties['ANTHROPIC_MODEL'] -or $entry.env.PSObject.Properties['ANTHROPIC_DEFAULT_SONNET_MODEL']
            if ($hasGroup) {
                $main = ''
                if ($entry.env.PSObject.Properties['ANTHROPIC_MODEL']) { $main = [string]$entry.env.ANTHROPIC_MODEL }
                if (-not $main -and $entry.env.PSObject.Properties['ANTHROPIC_DEFAULT_SONNET_MODEL']) { $main = [string]$entry.env.ANTHROPIC_DEFAULT_SONNET_MODEL }
                $v = Read-Host ('  主力模型 [{0}] ▸' -f $main)
                if (-not [string]::IsNullOrWhiteSpace($v)) {
                    $entry.env.ANTHROPIC_MODEL = $v.Trim()
                    $entry.env.ANTHROPIC_DEFAULT_OPUS_MODEL = $v.Trim()
                    $entry.env.ANTHROPIC_DEFAULT_SONNET_MODEL = $v.Trim()
                }
                $curFast = ''
                if ($entry.env.PSObject.Properties['ANTHROPIC_DEFAULT_HAIKU_MODEL']) { $curFast = [string]$entry.env.ANTHROPIC_DEFAULT_HAIKU_MODEL }
                if ($curFast) {
                    $v = Read-Host ('  快速模型 [{0}] ▸' -f $curFast)
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $entry.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $v.Trim() }
                } else {
                    $v = Read-Host '  快速模型（回车跳过）▸'
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $entry.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $v.Trim() }
                }
            }
        }
    }

    try {
        Save-AcsSupplierMap -Map $map
        Write-Host ('  ✔ 已更新 {0}/{1}' -f $foundCli, $foundProv.Name) -ForegroundColor Green
    } catch {
        Write-Host ('  ✘ 写入失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return
    }
    if ($cliDef.adapter -eq 'hybrid') { Invoke-AcsPreset -CliId $foundCli }
}

# 删除条目：official 不可删；hybrid 条目删后联动预置器同步配置文件
function Remove-AcsSupplier {
    param([string]$CliId, [string]$ProvId)
    $map = Get-AcsSupplierMap
    if ($null -eq $map) { return }
    if (-not $CliId -or -not $ProvId) { Write-Host '  用法: acs remove <cli> <provider>' -ForegroundColor Yellow; return }
    $foundCli = Find-AcsKey -List $map -Name $CliId
    if (-not $foundCli) { Write-Host ('  ✘ suppliers.json 里没有 CLI 组: {0}' -f $CliId) -ForegroundColor Red; return }
    $group = $map[$foundCli]
    $foundProv = $null
    foreach ($p in $group.PSObject.Properties) { if ($p.Name -ieq $ProvId) { $foundProv = $p; break } }
    if (-not $foundProv) { Write-Host ('  ✘ 供应商不存在: {0}/{1}' -f $foundCli, $ProvId) -ForegroundColor Red; return }
    if ($foundProv.Name -eq 'official') { Write-Host '  ✘ official 官方入口不可删除' -ForegroundColor Red; return }
    $sure = Read-Host ('  ⚠ 确认删除 {0}/{1}（{2}）? (y/N) ▸' -f $foundCli, $foundProv.Name, $foundProv.Value.desc)
    if ($sure -notmatch '^[yY]') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
    $group.PSObject.Properties.Remove($foundProv.Name)
    try {
        Save-AcsSupplierMap -Map $map
        Write-Host ('  ✔ 已删除 {0}/{1}' -f $foundCli, $foundProv.Name) -ForegroundColor Green
    } catch {
        Write-Host ('  ✘ 写入失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return
    }
    # 若上次使用指向被删条目，清空记录
    if (Test-Path $script:AcsLastFile) {
        $raw = Get-Content $script:AcsLastFile -Raw -ErrorAction SilentlyContinue
        if ($raw -and $raw.Trim().StartsWith($foundCli + "`t" + $foundProv.Name + "`t")) { Remove-Item $script:AcsLastFile -Force -ErrorAction SilentlyContinue }
    }
    $clis = Get-AcsClis -Quiet
    if ($clis -and $clis[$foundCli] -and $clis[$foundCli].adapter -eq 'hybrid') { Invoke-AcsPreset -CliId $foundCli }
}

# ----------------------------------------------------------------------------
# acs import：ccs 迁移 + 现有配置捕获（v0.3）
# ----------------------------------------------------------------------------

# 解析环境变量赋值文本（剪贴板常见格式）→ OrderedDictionary[k]=v
# 支持：export K=V / set K=V / $env:K = "V" / K=V（.env 风格）；自动去包裹引号
function Parse-AcsEnvText {
    param([string]$Text)
    $pairs = [ordered]@{}
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -match '^(?:export|set)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $k = $Matches[1]; $v = $Matches[2] }
        elseif ($t -match '^\$env:([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $k = $Matches[1]; $v = $Matches[2] }
        elseif ($t -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $k = $Matches[1]; $v = $Matches[2] }
        else { continue }
        $v = $v.Trim()
        if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        if ($k) { $pairs[$k] = $v }
    }
    return ,$pairs
}

# 从 ccs 的 suppliers.json（~\.claude\suppliers.json）迁移 claude 组（env: 前缀键 → env 对象）
function Import-AcsCcs {
    $ccsFile = Join-Path $HOME '.claude\suppliers.json'
    if (-not (Test-Path $ccsFile)) {
        Write-Host '  ✘ 未找到 ccs 配置 ~\.claude\suppliers.json（未装过 ccs 则无需迁移）' -ForegroundColor Yellow
        return
    }
    try { $raw = Get-Content $ccsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        Write-Host ('  ✘ ccs 配置解析失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return
    }
    $map = Get-AcsSupplierMap
    if ($null -eq $map) { return }
    if ($null -eq $map['claude']) { $map['claude'] = [PSCustomObject]@{} }
    $group = $map['claude']
    $n = 0; $skip = 0
    foreach ($p in $raw.PSObject.Properties) {
        if ($p.Name -eq 'official' -or $null -eq $p.Value -or $p.Value -isnot [PSCustomObject]) { continue }
        if ($group.PSObject.Properties[$p.Name]) { $skip++; continue }
        $env = [ordered]@{}
        $desc = ''
        foreach ($f in $p.Value.PSObject.Properties) {
            if ($f.Name -eq 'desc') { $desc = [string]$f.Value }
            elseif ($f.Name -like 'env:*') { $env[$f.Name.Substring(4)] = [string]$f.Value }
        }
        $group | Add-Member -MemberType NoteProperty -Name $p.Name -Value ([PSCustomObject]@{ desc = $desc; env = $env })
        $n++
    }
    try {
        Save-AcsSupplierMap -Map $map
        Write-Host ('  ✔ ccs 迁移完成：导入 {0} 条，跳过已存在 {1} 条（official 由 acs 模板提供）' -f $n, $skip) -ForegroundColor Green
    } catch {
        Write-Host ('  ✘ 写入失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
}

# 捕获 Claude Code 现有全局配置（settings.json 的 env 段）为 imported 条目，不丢用户已有配置
function Import-AcsCapture {
    $sf = Join-Path $HOME '.claude\settings.json'
    if (-not (Test-Path $sf)) {
        Write-Host '  ✘ 未找到 ~\.claude\settings.json（Claude Code 尚未配置过）' -ForegroundColor Yellow
        return
    }
    $url = $null; $tok = $null
    try {
        $j = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.env) {
            if ($j.env.ANTHROPIC_BASE_URL) { $url = [string]$j.env.ANTHROPIC_BASE_URL }
            if ($j.env.ANTHROPIC_AUTH_TOKEN) { $tok = [string]$j.env.ANTHROPIC_AUTH_TOKEN }
            if ($j.env.ANTHROPIC_API_KEY -and -not $tok) { $tok = [string]$j.env.ANTHROPIC_API_KEY }
        }
    } catch { }
    if (-not $url -and -not $tok) {
        Write-Host '  ✘ settings.json 的 env 段没有 ANTHROPIC_* 供应商配置，无需捕获' -ForegroundColor Yellow
        return
    }
    $env = [ordered]@{}
    if ($url) { $env['ANTHROPIC_BASE_URL'] = $url }
    if ($tok) { $env['ANTHROPIC_AUTH_TOKEN'] = $tok }
    $host2 = '官方'
    if ($url) { try { $host2 = ([uri]$url).Host } catch { } }
    $sure = Read-Host ('  ⚠ 将当前配置捕获为条目 imported（{0}）? (Y/n) ▸' -f $host2)
    if ($sure -match '^[nN]') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
    $map = Get-AcsSupplierMap
    if ($null -eq $map) { return }
    if ($null -eq $map['claude']) { $map['claude'] = [PSCustomObject]@{} }
    if ($map['claude'].PSObject.Properties['imported']) {
        Write-Host '  ⚠ 供应商 imported 已存在，跳过（可先 acs remove claude imported 再捕获）' -ForegroundColor Yellow
        return
    }
    $map['claude'] | Add-Member -MemberType NoteProperty -Name 'imported' -Value ([PSCustomObject]@{ desc = ('迁移自 settings.json · ' + $host2); env = $env })
    try {
        Save-AcsSupplierMap -Map $map
        Write-Host '  ✔ 已捕获为 claude/imported' -ForegroundColor Green
    } catch {
        Write-Host ('  ✘ 写入失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
}

# acs import 总入口：$What = ccs | capture | 空（全部执行）
function Invoke-AcsImport {
    param([string]$What)
    Write-Host ''
    Write-AcsHeader -Title 'acs import'
    if (-not $What -or $What -eq 'ccs') { Import-AcsCcs }
    if (-not $What -or $What -eq 'capture') { Import-AcsCapture }
    Write-Host ''
}

# 交互删除（菜单 d 键）：列出全部条目，输入序号回车即移除（official 不可删）
function Remove-AcsInteractive {
    param([string]$CliId, $List)
    $order = @($List.Keys)
    $idxW = ([string]($order.Count - 1)).Length
    Write-Host ''
    Write-AcsHeader -Title ('删除 {0} 供应商' -f $CliId) -Color Yellow
    Write-Host ''
    for ($i = 0; $i -lt $order.Count; $i++) {
        $mark = ''
        if ($order[$i] -eq 'official') { $mark = '不可删' }
        Write-AcsRow -Index $i -IndexWidth $idxW -Key $order[$i] -Desc $List[$order[$i]].Desc -KeyWidth 10 -Note $mark
    }
    Write-Host ''
    $pick = Read-Host '  输入要删除的序号（回车取消）▸'
    if ([string]::IsNullOrWhiteSpace($pick)) { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
    if ($pick -notmatch '^\d{1,3}$' -or [int]$pick -ge $order.Count) {
        Write-Host ('  ✘ 无效序号: {0}' -f $pick) -ForegroundColor Red
        return
    }
    $target = $order[[int]$pick]
    if ($target -eq 'official') { Write-Host '  ✘ official 官方入口不可删除' -ForegroundColor Red; return }
    # 二次确认：Key 是手工录入的资产，误删可能无法恢复
    Write-Host ('  ⚠ 将删除 {0}/{1}（{2}），此操作不可撤销' -f $CliId, $target, $List[$target].Desc) -ForegroundColor Yellow
    $sure = Read-Host '  确认删除? (y/N) ▸'
    if ($sure -notmatch '^[yY]') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
    $map2 = Get-AcsSupplierMap
    if ($null -eq $map2) { return }
    $group = $map2[$CliId]
    $real = $null
    foreach ($p in $group.PSObject.Properties) { if ($p.Name -ieq $target) { $real = $p.Name; break } }
    $group.PSObject.Properties.Remove($real)
    try {
        Save-AcsSupplierMap -Map $map2
        Write-Host ('  ✔ 已删除 {0}/{1}' -f $CliId, $real) -ForegroundColor Green
    } catch {
        Write-Host ('  ✘ 删除失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return
    }
    # 上次使用指向被删条目时清空记录；hybrid CLI 联动预置器
    if (Test-Path $script:AcsLastFile) {
        $raw = Get-Content $script:AcsLastFile -Raw -ErrorAction SilentlyContinue
        if ($raw -and $raw.Trim().StartsWith($CliId + "`t" + $real + "`t")) { Remove-Item $script:AcsLastFile -Force -ErrorAction SilentlyContinue }
    }
    $clis = Get-AcsClis -Quiet
    if ($clis -and $clis[$CliId] -and $clis[$CliId].adapter -eq 'hybrid') { Invoke-AcsPreset -CliId $CliId }
}

# ----------------------------------------------------------------------------
# 协议探测（录入时/手动 recheck）：端点是否实现某 CLI 要求的协议接口
# ----------------------------------------------------------------------------

# 探测端点协议支持；返回 ok/unsupported/auth/unreachable/unknown
# 状态码语义: 2xx 与 400/405/422=路由存在; 404=不支持; 401/403=Key校验失败; 无响应=网络不通
function Test-AcsEndpointProtocol {
    param([string]$BaseUrl, [string]$ProbePath, [string]$ApiKey)
    $url = $BaseUrl.TrimEnd('/') + $ProbePath
    try {
        # 探测 body 使用无效模型名，路由存在时端点只会回参数错误（400），不会产生真实计费
        Invoke-WebRequest -Uri $url -Method Post -Body '{"model":"acs-probe","input":"ping","stream":false}' `
            -ContentType 'application/json' -Headers @{ Authorization = ('Bearer ' + $ApiKey) } `
            -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop | Out-Null
        return 'ok'
    } catch {
        $sc = $null
        try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($sc -in @(400, 405, 422)) { return 'ok' }
        if ($sc -eq 404) { return 'unsupported' }
        if ($sc -in @(401, 403)) { return 'auth' }
        if ($null -eq $sc) { return 'unreachable' }
        return 'unknown'
    }
}

# PSCustomObject 安全设值：属性不存在时用 Add-Member（点赋值对缺失属性会抛异常）
function Set-AcsObjProp {
    param($Obj, [string]$Name, $Value)
    if ($Obj.PSObject.Properties[$Name]) { $Obj.PSObject.Properties[$Name].Value = $Value }
    else { $Obj | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
}

# acs recheck <cli> <provider>：重新探测并更新条目的代理模式
function Invoke-AcsRecheck {
    param([string]$CliId, [string]$ProvId)
    $clis = Get-AcsClis
    if ($null -eq $clis) { return }
    $map = Get-AcsSupplierMap
    if ($null -eq $map) { return }
    if (-not $CliId -or -not $ProvId) { Write-Host '  用法: acs recheck <cli> <provider>' -ForegroundColor Yellow; return }
    $foundCli = Find-AcsKey -List $map -Name $CliId
    if (-not $foundCli) { Write-Host ('  ✘ 组不存在: {0}' -f $CliId) -ForegroundColor Red; return }
    $cliDef = $clis[$foundCli]
    $probePath = [string]$cliDef.probePath
    if (-not $probePath) { Write-Host ('  {0} 无需协议探测' -f $foundCli); return }
    $group = $map[$foundCli]
    $found = $null
    foreach ($p in $group.PSObject.Properties) { if ($p.Name -ieq $ProvId) { $found = $p; break } }
    if (-not $found) { Write-Host ('  ✘ 供应商不存在: {0}/{1}' -f $foundCli, $ProvId) -ForegroundColor Red; return }
    $entry = $found.Value
    if (-not $entry.preset) { Write-Host '  ✘ 仅 hybrid 型供应商需要探测' -ForegroundColor Yellow; return }
    $keyName = $null
    foreach ($k in @($entry.env.PSObject.Properties.Name)) { if ($k -like '*_KEY') { $keyName = $k; break } }
    $key = [string]$entry.env.$keyName
    $baseUrl = [string]$entry.preset.baseUrl
    Write-Host '  ⋯ 正在探测...' -ForegroundColor DarkGray
    $probe = Test-AcsEndpointProtocol -BaseUrl $baseUrl -ProbePath $probePath -ApiKey $key
    $mode = [string]$entry.preset.mode; if (-not $mode) { $mode = 'direct' }
    if ($probe -eq 'ok') {
        Write-Host '  ✔ 端点支持所需协议（直连）' -ForegroundColor Green
        Set-AcsObjProp $entry.preset 'mode' 'direct'
    } elseif ($probe -eq 'unsupported') {
        Write-Host ('  ✘ 端点不支持 {0} 要求的 {1} 接口（404）' -f $foundCli, $probePath) -ForegroundColor Yellow
        if ($mode -eq 'proxy') {
            Write-Host '  当前已是代理模式，启动时将自动翻译协议' -ForegroundColor DarkGray
        } else {
            $r = Read-Host '  ? 切换为本地翻译代理模式? [Y/n] ▸'
            if ($r -notmatch '^[nN]') { Set-AcsObjProp $entry.preset 'mode' 'proxy'; $mode = 'proxy'; Write-Host '  ✔ 已切换为代理模式' -ForegroundColor Green }
        }
    } elseif ($probe -eq 'auth') {
        Write-Host '  ⚠ Key 校验失败（401/403），请检查 Key 后重试' -ForegroundColor Yellow
    } else {
        Write-Host ('  ⚠ 探测未完成（{0}），供应商保持 {1} 模式' -f $probe, $mode) -ForegroundColor Yellow
    }
    Set-AcsObjProp $entry.preset 'probedAt' (Get-Date -Format 'yyyy-MM-dd HH:mm')
    try { Save-AcsSupplierMap -Map $map } catch { Write-Host ('  ✘ 写入失败: {0}' -f $_.Exception.Message) -ForegroundColor Red }
}

# ----------------------------------------------------------------------------
# acs list / acs status
# ----------------------------------------------------------------------------

# acs list [cli]：无交互列表 + 配置校验
function Show-AcsList {
    param([string]$CliId)
    $clis = Get-AcsClis -Quiet; if ($null -eq $clis) { return }
    $map = Get-AcsSupplierMap;  if ($null -eq $map) { return }
    Write-Host ''
    if ($CliId) {
        $found = Find-AcsKey -List $map -Name $CliId
        if (-not $found) { Write-Host ('  ✘ suppliers.json 里没有 CLI 组: {0}' -f $CliId) -ForegroundColor Red; return }
        $list = Get-AcsSupplierList -CliId $found -Map $map
        if ($null -eq $list) { Write-Host ('  ✘ 组 {0} 为空' -f $found) -ForegroundColor Red; return }
        $order = @($list.Keys)
        $keyW = Get-AcsKeyWidth -Order $order
        Write-AcsHeader -Title ('{0} 供应商列表' -f $clis[$found].name) -Suffix ('({0})' -f $found)
        Write-Host ''
        $i = 0
        foreach ($k in $order) {
            Write-AcsRow -Index $i -IndexWidth 1 -Key $k -Desc $list[$k].Desc -KeyWidth $keyW
            $i++
        }
        Write-Host ''
        Write-Host ('  ✔ {0} 项 · {1}' -f $order.Count, $script:AcsDataFile) -ForegroundColor DarkGray
        Write-Host ''
        return
    }
    # 全量概览
    Write-AcsHeader -Title 'acs 供应商总览'
    Write-Host ''
    foreach ($g in $map.Keys) {
        $list = Get-AcsSupplierList -CliId $g -Map $map
        if ($null -eq $list) { continue }
        $name = $g; if ($clis[$g]) { $name = $clis[$g].name }
        Write-Host ('  {0} ' -f $g) -NoNewline
        Write-Host ('({0})' -f $name) -ForegroundColor DarkGray
        foreach ($k in $list.Keys) {
            Write-Host ('    {0}' -f $k) -NoNewline
            Write-Host ('  {0}' -f $list[$k].Desc) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host ('  ✔ 配置正常 · {0}' -f $script:AcsDataFile) -ForegroundColor DarkGray
    Write-Host ''
}

# 检测某配置文件是否挂着 acs 引用（三端体检用）
function Test-AcsProfileMount {
    param([string]$Path, [string]$Marker)
    if ((Test-Path $Path) -and ((Get-Content $Path -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($Marker))) { return $true }
    return $false
}

# acs status：多 CLI 概览 + 三端挂载体检 + 供应商明细（指纹脱敏）
function Show-AcsStatus {
    $clis = Get-AcsClis -Quiet; if ($null -eq $clis) { return }
    $map = Get-AcsSupplierMap;  if ($null -eq $map) { return }
    Write-Host ''
    Write-AcsHeader -Title 'acs 状态'
    Write-Host ''

    # 上次使用（.last 格式: cli<TAB>provider<TAB>时间）
    $lastCli = ''; $lastProv = ''; $lastTime = ''
    if (Test-Path $script:AcsLastFile) {
        $raw = Get-Content $script:AcsLastFile -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $parts = $raw.Trim() -split "`t"
            if ($parts.Count -ge 2) { $lastCli = $parts[0]; $lastProv = $parts[1] }
            if ($parts.Count -ge 3) { $lastTime = $parts[2].Trim() }
        }
    }
    if ($lastCli) {
        $line = ('  上次使用  : {0} / {1}' -f $lastCli, $lastProv)
        if ($lastTime) { $line += (' · {0}' -f $lastTime) }
        Write-Host $line
    } else {
        Write-Host '  上次使用  : （无记录）' -ForegroundColor DarkGray
    }

    # 三端挂载检测（Documents 可能被 OneDrive 重定向，按候选路径找）
    $doc = [Environment]::GetFolderPath('MyDocuments')
    $ps7 = '✘'; $ps5 = '✘'; $bsh = '✘'
    if (Test-AcsProfileMount -Path (Join-Path $doc 'PowerShell\Microsoft.PowerShell_profile.ps1') -Marker 'acs-menu.ps1') { $ps7 = '✔' }
    if (Test-AcsProfileMount -Path (Join-Path $doc 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1') -Marker 'acs-menu.ps1') { $ps5 = '✔' }
    if (Test-AcsProfileMount -Path (Join-Path $HOME '.bashrc') -Marker 'acs-menu.sh') { $bsh = '✔' }
    Write-Host ('  菜单挂载  : {0} · PS7 {1} · PS5.1 {2} · Git Bash {3}' -f $script:AcsVersion, $ps7, $ps5, $bsh)
    Write-Host ''

    # CLI（已安装逐行列出，hybrid 的预置状态并入本行；未安装合并为一行——消除独立的"预置状态"段）
    Write-Host '  CLI' -ForegroundColor Cyan
    $notInstalled = @()
    foreach ($c in $clis.Keys) {
        $count = 0
        if ($map[$c]) { $l = Get-AcsSupplierList -CliId $c -Map $map; if ($l) { $count = $l.Count } }
        if (-not (Get-Command $clis[$c].cmd -ErrorAction SilentlyContinue)) { $notInstalled += $c; continue }
        $cfg = '未配置'; if ($count -gt 0) { $cfg = ('{0} 个供应商' -f $count) }
        Write-Host ('    {0}' -f $c.PadRight(11)) -NoNewline
        Write-Host ('{1} · {0}' -f $cfg, $clis[$c].name) -ForegroundColor DarkGray -NoNewline
        # hybrid 条目预置状态并入概览行（未安装的 hybrid 不占行：未装则预置无意义）
        if ($clis[$c].adapter -eq 'hybrid' -and $count -gt 0) {
            $entries = Get-AcsHybridEntries -CliId $c -Map $map
            $hCount = 0; if ($entries) { $hCount = $entries.Count }
            # codex 检查独立 profile 文件；其余检查配置文件中的 acs_ 段
            if ($c -eq 'codex') {
                $inCfg = (Get-ChildItem (Join-Path $HOME '.codex') -Filter 'acs_*.config.toml' -ErrorAction SilentlyContinue).Count
            } else {
                $cfgPath = Expand-AcsTildePath $clis[$c].configFile
                $inCfg = 0
                if (Test-Path $cfgPath) {
                    $raw2 = Get-Content $cfgPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($raw2) { $inCfg = ([regex]::Matches($raw2, 'acs_[A-Za-z0-9_-]+')).Count }
                }
            }
            if ($hCount -gt 0 -and $inCfg -eq 0) {
                Write-Host (' · ⚠ {0} 个未预置' -f $hCount) -ForegroundColor Yellow -NoNewline
            } elseif ($hCount -gt 0) {
                Write-Host ' · 预置已同步' -ForegroundColor DarkGray -NoNewline
            }
        }
        Write-Host ''
    }
    if ($notInstalled.Count -gt 0) {
        Write-Host ('    未安装    {0}' -f ($notInstalled -join ' · ')) -ForegroundColor DarkGray
    }
    Write-Host ''

    # 供应商明细：按 CLI 分组小标题 + 条目缩进；组内全部为官方入口时整组并入汇总行（消除零信息行）
    Write-Host '  供应商明细' -ForegroundColor Cyan
    $seen = @{}; $dups = @(); $onlyOfficial = @()
    foreach ($g in $map.Keys) {
        if (-not $clis[$g]) { continue }
        $list = Get-AcsSupplierList -CliId $g -Map $map
        if ($null -eq $list) { continue }
        # L1 取 keyEnv/baseUrlEnv；L2 hybrid 的 key 是 *_KEY 变量、端点在 preset 段
        $isHybrid = ($clis[$g].adapter -eq 'hybrid')
        $hasReal = $false
        foreach ($k in $list.Keys) { if ($list[$k].Env.Count -gt 0) { $hasReal = $true; break } }
        if (-not $hasReal) { $onlyOfficial += $g; continue }
        Write-Host ('    {0}' -f $g) -NoNewline
        Write-Host (' {0}' -f $clis[$g].name) -ForegroundColor DarkGray
        $keyW = 8
        foreach ($k in $list.Keys) { $l = [Math]::Min(14, $k.Length + 1); if ($l -gt $keyW) { $keyW = $l } }
        foreach ($k in $list.Keys) {
            if ($list[$k].Env.Count -eq 0) {
                Write-Host ('      {0}  OAuth 官方入口' -f $k.PadRight($keyW))
                continue
            }
            if ($isHybrid) {
                $tok = $null
                foreach ($ek in $list[$k].Env.Keys) { if ($ek -like '*_KEY') { $tok = $list[$k].Env[$ek]; break } }
                $url = $null
                if ($list[$k].Preset) { $url = [string]$list[$k].Preset.BaseUrl }
            } else {
                $tok = $list[$k].Env[$clis[$g].keyEnv]
                $url = $list[$k].Env[$clis[$g].baseUrlEnv]
            }
            $fp = '无 Key'
            if ($tok) {
                if ($tok.Length -ge 10) { $fp = $tok.Substring(0, 6) + '…' + $tok.Substring($tok.Length - 4) } else { $fp = 'Key 过短' }
                if ($seen.ContainsKey($tok)) { $dups += ('{0}/{1} 与 {2}/{3}' -f $g, $k, $seen[$tok][0], $seen[$tok][1]) } else { $seen[$tok] = @($g, $k) }
            }
            $host2 = ''
            if ($url) { try { $host2 = ([uri]$url).Host } catch { $host2 = $url } }
            Write-Host ('      {0}  {1}  → {2}' -f $k.PadRight($keyW), $fp, $host2)
        }
    }
    if ($onlyOfficial.Count -gt 0) {
        Write-Host ('    仅官方入口  {0}' -f ($onlyOfficial -join ' · ')) -ForegroundColor DarkGray
    }
    # 体检结论独立成段，与明细分离
    Write-Host ''
    Write-Host '  体检' -ForegroundColor Cyan
    if ($dups.Count -gt 0) {
        Write-Host ('    ⚠ Key 重复: {0}（如非有意，请检查 suppliers.json）' -f ($dups -join '；')) -ForegroundColor Yellow
    } else {
        Write-Host '    ✔ 无重复 Key' -ForegroundColor DarkGray
    }

    # 当前 shell 环境残留检测（手动 export 过或上次异常退出时会干扰 official 入口）
    $leftover = @()
    foreach ($c in $clis.Keys) {
        if ($null -eq $clis[$c].baseEnvKeys) { continue }
        foreach ($v in $clis[$c].baseEnvKeys) {
            $cur = [Environment]::GetEnvironmentVariable($v, 'Process')
            if ($cur) { $leftover += ('{0}/{1}' -f $c, $v) }
        }
    }
    if ($leftover.Count -gt 0) {
        Write-Host ('    ⚠ 当前 shell 存在供应商变量残留: {0}（acs 拉起时会自动清理；official 入口不受影响）' -f ($leftover -join '、')) -ForegroundColor Yellow
    } else {
        Write-Host '    ✔ 当前环境无供应商变量残留' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ----------------------------------------------------------------------------
# 主入口
# ----------------------------------------------------------------------------

# acs help：命令一览（按用途分组；左列按显示宽度补齐，中文按 2 列）
function Show-AcsHelp {
    Write-Host ''
    Write-AcsHeader -Title ('acs {0} · 命令一览' -f $script:AcsVersion)
    Write-Host ''
    Write-Host '  用法: acs [命令 | CLI名] [供应商] [CLI参数…]   名称支持唯一前缀直达'
    foreach ($grp in @(
        @('切换', @(
            @('acs',                        '交互菜单：选 CLI → 选供应商，回车 = 上次组合'),
            @('acs <cli>',                  '直接进入该 CLI 的供应商菜单'),
            @('acs <cli> <供应商>',          '直达启动，如 acs claude glmb')
        )),
        @('配置', @(
            @('acs add [cli]',              '添加供应商向导；-paste 从剪贴板导入环境变量块'),
            @('acs edit <cli> <供应商>',     '编辑条目（回车保留原值）'),
            @('acs remove <cli> <供应商>',   '删除条目（L2 CLI 联动更新预置）'),
            @('acs import [ccs|capture]',   '从 ccs 迁移 / 捕获 Claude 现有配置'),
            @('acs preset [cli]',           '重新生成 hybrid CLI 的配置预置段'),
            @('acs recheck <cli> <供应商>',  '重新探测端点协议兼容性')
        )),
        @('诊断', @(
            @('acs list [cli]',             '列出供应商配置（脱敏）'),
            @('acs status',                 '三端挂载体检 + 各 CLI 状态总览'),
            @('acs help / version',         '本帮助 / 版本号')
        ))
    )) {
        Write-Host ''
        Write-Host ('  {0}' -f $grp[0]) -ForegroundColor Cyan
        foreach ($h in $grp[1]) {
            # 目标 30 列须大于最长命令（acs recheck <cli> <供应商> = 27 显示列），否则补格触下限导致右列错位
            $pad = 30 - (Get-AcsDisplayWidth -Text $h[0])
            if ($pad -lt 2) { $pad = 2 }
            Write-Host ('    {0}{1}  {2}' -f $h[0], (' ' * $pad), $h[1])
        }
    }
    Write-Host ''
    Write-Host '  提示: 菜单内 ↑↓ 选择、Enter 确认、输入序号/名字直达、Esc 返回上级；' -ForegroundColor DarkGray
    Write-Host '        列表序号从 1 开始，供应商菜单中 0 固定为官方通道（official）' -ForegroundColor DarkGray
    Write-Host '  提示: 不想使用方向键可设 ACS_NO_ARROW=1（写入 Profile）' -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Acs {
    $clis = Get-AcsClis
    if ($null -eq $clis) { return }

    # 子命令分发（优先于 CLI 名匹配）
    if ($args.Count -gt 0) {
        $sc = ([string]$args[0]).ToLower()
        $isPaste = ($args -contains '-paste') -or ($args -contains '--paste')
        if ($sc -in @('help', '-h', '--help', '/?')) { Show-AcsHelp; return }
        if ($sc -in @('version', '-v', '--version')) { Write-Host ('  acs {0}' -f $script:AcsVersion); return }
        if ($sc -in @('add', '-a', '--add'))     {
            $cid = $null
            foreach ($a in @($args)[1..($args.Count - 1)]) { if (([string]$a) -notlike '-*') { $cid = [string]$a; break } }
            Add-AcsSupplier -CliId $cid -Paste:$isPaste; return
        }
        if ($sc -in @('edit', '-e', '--edit'))   { Edit-AcsSupplier -CliId ([string]$args[1]) -ProvId ([string]$args[2]); return }
        if ($sc -in @('remove', 'rm', '-r', '--remove')) { Remove-AcsSupplier -CliId ([string]$args[1]) -ProvId ([string]$args[2]); return }
        if ($sc -in @('import', '-i', '--import')) { $w = $null; if ($args.Count -gt 1) { $w = ([string]$args[1]).ToLower() }; Invoke-AcsImport -What $w; return }
        if ($sc -in @('recheck', '--recheck'))   { Invoke-AcsRecheck -CliId ([string]$args[1]) -ProvId ([string]$args[2]); return }
        if ($sc -in @('preset', '-p', '--preset')) {
            if ($args.Count -gt 1) { Invoke-AcsPreset -CliId ([string]$args[1]); return }
            # 无参数：对所有 hybrid CLI 逐个预置
            $all = Get-AcsClis -Quiet
            foreach ($c in $all.Keys) {
                if ($all[$c].adapter -eq 'hybrid') { Invoke-AcsPreset -CliId $c }
            }
            return
        }
        if ($sc -in @('list', '-l', '--list'))   { $cid = $null; if ($args.Count -gt 1) { $cid = [string]$args[1] }; Show-AcsList -CliId $cid; return }
        if ($sc -in @('status', '-s', '--status')) { Show-AcsStatus; return }
    }

    $map = Get-AcsSupplierMap
    if ($null -eq $map) {
        # 空状态引导：还没有配置文件时直接询问是否进入添加向导
        $r = Read-Host '  现在就运行 acs add 添加供应商吗? (Y/n) ▸'
        if ($r -notmatch '^[nN]') { Add-AcsSupplier }
        return
    }

    # 上次使用记录（cli<TAB>provider<TAB>时间）
    $lastCli = ''; $lastProv = ''
    if (Test-Path $script:AcsLastFile) {
        $raw = Get-Content $script:AcsLastFile -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $parts = $raw.Trim() -split "`t"
            if ($parts.Count -ge 2) { $lastCli = $parts[0]; $lastProv = $parts[1] }
        }
    }

    # 解析第一个参数：CLI id（精确/唯一前缀）；无参数则弹 CLI 菜单
    $cliId = $null; $sel = $null; $rest = @()
    if ($args.Count -gt 0) {
        $first = [string]$args[0]
        $cliId = Find-AcsKey -List $clis -Name $first
        if (-not $cliId) {
            $pm = @(Find-AcsPrefixMatches -List $clis -Name $first)
            if ($pm.Count -eq 1) { $cliId = $pm[0] }
            elseif ($pm.Count -gt 1) {
                Write-Host ('  ✘ {0} 个 CLI 前缀匹配: {1}' -f $pm.Count, ($pm -join ' ')) -ForegroundColor Red
                return
            }
        }
        if (-not $cliId) {
            Write-Host ('  ✘ 未知 CLI: {0}（可用: {1}；运行 acs help 查看全部命令）' -f $first, ($clis.Keys -join ' ')) -ForegroundColor Red
            return
        }
        if ($args.Count -gt 1) { $rest = @($args)[1..($args.Count - 1)] }
    }

    # 主流程外层循环：供应商菜单按 b 返回 CLI 选择，重新走一遍
    $goBack = $false
    $backFromProvider = $false
    while ($true) {
    # 无参数：CLI 选择菜单（仅一个已配置组时直接进入；b 返回后强制弹菜单）
    if (-not $cliId) {
        $active = @()
        foreach ($g in $map.Keys) { if (Get-AcsSupplierList -CliId $g -Map $map) { $active += $g } }
        if ($active.Count -eq 0) {
            # 空状态引导：直接询问是否进入添加向导
            Write-Host '  ⚠ suppliers.json 里还没有任何供应商' -ForegroundColor Yellow
            $r = Read-Host '  现在就添加供应商吗? (Y/n) ▸'
            if ($r -notmatch '^[nN]') { Add-AcsSupplier }
            return
        }
        if (-not $backFromProvider -and $active.Count -eq 1) { $cliId = $active[0] }
        else {
            # 行数据：desc = CLI 显示名，未安装时行尾暗色标注
            $rows = @()
            foreach ($a in $active) {
                $note = ''
                if (-not (Get-Command $clis[$a].cmd -ErrorAction SilentlyContinue)) { $note = '未安装' }
                $rows += @{ Key = $a; Desc = [string]$clis[$a].name; Note = $note; Last = ($a -eq $lastCli) }
            }
            $init = 0
            if ($lastCli -and ($active -contains $lastCli)) { $init = [array]::IndexOf($active, $lastCli) }
            $parse = {
                param($text)
                # 优先精确命中，其次单键命令，最后序号/报错——消除单字母歧义；序号从 1 起（0 保留给供应商菜单的官方通道）
                if ($text) {
                    $exact = Find-AcsKey -List $clis -Name $text
                    if ($exact -and ($active -contains $exact)) { return @{ ok = $true; value = $exact } }
                    if ($text -match '^[aA]$') { return @{ ok = $true; value = 'add' } }
                    if ($text -match '^[qQ]$') { return @{ ok = $true; value = 'quit' } }
                    if ($text -match '^\d{1,2}$') {
                        if ([int]$text -ge 1 -and [int]$text -le $active.Count) { return @{ ok = $true; value = $active[[int]$text - 1] } }
                        return @{ ok = $false; msg = ('序号超出范围: {0}（有效范围 1-{1}）' -f $text, $active.Count) }
                    }
                    return @{ ok = $false; msg = ('未配置或未知 CLI: {0}' -f $text) }
                }
                if ($lastCli -and ($active -contains $lastCli)) { return @{ ok = $true; value = $lastCli } }
                return @{ ok = $false; msg = '还没有使用记录，请输入序号或名字，或用方向键选择' }
            }
            Write-Host ''
            Write-AcsHeader -Title 'acs 选择 Agent CLI'
            Write-Host ''
            $picked = Invoke-AcsSelect -Prompt '选择 CLI' -Rows $rows -Initial $init -Parse $parse -EscResult 'quit' -KeyWidth 12 -IndexBase 1 `
                -Hint '↑↓ 移动 · Enter 确认 · 输入序号/名字直达 · a 添加供应商 · Esc 退出' `
                -HintInput '回车 = 上次使用 · 序号或名字直达 · a 添加 · q 退出' `
                -LastMark ('[上次 {0} {1}]' -f ($init + 1), $lastCli)
            if ($picked -eq 'quit' -or $picked -eq '__ESC__') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
            if ($picked -eq 'add') { Add-AcsSupplier; return }
            $cliId = $picked
        }
    }

    # 该 CLI 必须已有供应商配置
    $cliDef = $clis[$cliId]
    $script:AcsCurrentList = Get-AcsSupplierList -CliId $cliId -Map $map
    $list = $script:AcsCurrentList
    if ($null -eq $list) {
        Write-Host ('  ✘ {0} 还没有供应商配置，先运行: acs add {0}' -f $cliId) -ForegroundColor Yellow
        return
    }
    $order = @($list.Keys)

    # 解析供应商：rest 首元素若匹配（序号/精确名/唯一前缀）则选中，其余为透传参数
    if ($rest.Count -gt 0 -and ($rest[0] -is [string]) -and $rest[0] -notmatch '^-' -and $rest[0] -notmatch '^\d+$') {
        $p = [string]$rest[0]
        $found = Find-AcsKey -List $list -Name $p
        if (-not $found) {
            $pm = @(Find-AcsPrefixMatches -List $list -Name $p)
            if ($pm.Count -eq 1) { $found = $pm[0] }
            elseif ($pm.Count -gt 1) {
                Write-Host ('  ✘ {0} 个供应商前缀匹配: {1}' -f $pm.Count, ($pm -join ' ')) -ForegroundColor Red
                return
            }
        }
        if ($found) { $sel = $found; $rest = @($rest)[1..($rest.Count - 1)] }
        elseif ($p -ieq 'add') { Add-AcsSupplier -CliId $cliId; return }
    }

    # 供应商交互菜单（方向键/输入混合选择器；删除后重建行数据重选）
    if (-not $sel) {
        while ($true) {
            $lastHere = $null
            if ($lastCli -ieq $cliId -and $lastProv) { $lastHere = Find-AcsKey -List $list -Name $lastProv }
            $order = @($list.Keys)
            $keyW = Get-AcsKeyWidth -Order $order
            $idxW = [Math]::Max(1, ([string]([Math]::Max(1, $order.Count) - 1)).Length)
            # desc 按 CJK 显示宽度截断（为序号列/key 列/上次标记预留空间）
            $budget = (Get-AcsTermWidth) - (8 + $idxW + $keyW + 9)
            $rows = @()
            foreach ($k in $order) {
                $note = ''
                if ($k -eq 'official' -and $list[$k].Env.Count -eq 0) { $note = Get-AcsOfficialNote -CliId $cliId }
                $rows += @{ Key = $k; Desc = (Get-AcsFitText -Text ([string]$list[$k].Desc) -MaxWidth $budget); Note = $note; Last = ($k -eq $lastHere) }
            }
            $init = 0
            if ($lastHere) { $init = [array]::IndexOf($order, $lastHere) }
            $total = $order.Count
            $parse = {
                param($text)
                if ($text) {
                    # 优先精确命中（含单字母 id），其次单键命令，最后序号/唯一前缀——消除单字母歧义
                    $exact = Find-AcsKey -List $list -Name $text
                    if ($exact) { return @{ ok = $true; value = $exact } }
                    if ($text -match '^[aA]$') { return @{ ok = $true; value = 'add' } }
                    if ($text -match '^[bB]$') { return @{ ok = $true; value = 'back' } }
                    if ($text -match '^[dD]$') { return @{ ok = $true; value = 'delete' } }
                    if ($text -match '^[qQ]$') { return @{ ok = $true; value = 'quit' } }
                    if ($text -match '^\d{1,3}$') {
                        if ([int]$text -lt $total) { return @{ ok = $true; value = $order[[int]$text] } }
                        return @{ ok = $false; msg = ('序号超出范围: {0}（有效范围 0-{1}，0 = 官方通道）' -f $text, ($total - 1)) }
                    }
                    $pm = @(Find-AcsPrefixMatches -List $list -Name $text)
                    if ($pm.Count -eq 1) { return @{ ok = $true; value = $pm[0] } }
                    if ($pm.Count -gt 1) { return @{ ok = $false; msg = ('{0} 个前缀匹配: {1}（请输入更多字符）' -f $pm.Count, ($pm -join ' ')) } }
                    $msg = ('未知供应商: {0}' -f $text)
                    $sug = Find-AcsSuggestion -List $list -Name $text
                    if ($sug) { $msg += ('（是不是想输 {0}?）' -f $sug) }
                    return @{ ok = $false; msg = $msg }
                }
                if ($lastHere) { return @{ ok = $true; value = $lastHere } }
                return @{ ok = $false; msg = '还没有使用记录，请输入序号或名字，或用方向键选择' }
            }
            Write-Host ''
            Write-AcsHeader -Title ('{0} 供应商选择' -f $cliDef.name) -Suffix ('({0})' -f $cliId)
            Write-Host ''
            $lastMark = ''
            if ($lastHere) { $lastMark = ('[上次 {0} {1}]' -f $init, $lastHere) }
            $hintInput = '输入序号或名字直达 · a 添加 · d 删除 · b 返回 · q 退出'
            if ($lastHere) { $hintInput = '回车 = 上次使用 · 序号或名字直达 · a 添加 · d 删除 · b 返回 · q 退出' }
            $picked = Invoke-AcsSelect -Prompt '选择' -Rows $rows -Initial $init -Parse $parse -EscResult 'back' -KeyWidth $keyW `
                -Hint '↑↓ 移动 · Enter 确认 · 输入序号/名字直达 · a 添加 · d 删除 · Esc 返回' -LastMark $lastMark `
                -HintInput $hintInput
            # 动词分派
            if ($picked -eq 'add') { Add-AcsSupplier -CliId $cliId; return }
            if ($picked -eq 'quit' -or $picked -eq '__ESC__') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
            if ($picked -eq 'back') { $goBack = $true; break }
            if ($picked -eq 'delete') {
                # d 删除：交互移除（含二次确认）后刷新列表重选
                Remove-AcsInteractive -CliId $cliId -List $list
                $map2 = Get-AcsSupplierMap
                if ($null -eq $map2) { return }
                $map = $map2
                $script:AcsCurrentList = Get-AcsSupplierList -CliId $cliId -Map $map
                $list = $script:AcsCurrentList
                if ($null -eq $list) {
                    Write-Host ('  （{0} 已无供应商，可用 acs add {0} 重新添加）' -f $cliId) -ForegroundColor Yellow
                    return
                }
                continue
            }
            $sel = $picked
            break
        }
    }

    # b 返回上一步：清空选择重走 CLI 菜单；否则选中供应商，退出外层循环拉起会话
    if ($goBack) {
            $goBack = $false
            $cliId = $null; $sel = $null; $rest = @(); $backFromProvider = $true
            $map = Get-AcsSupplierMap
            if ($null -eq $map) { return }
            continue
        }
        break
    }

    # 命令存在性先行检查：避免为不存在的命令污染"上次使用"记录（Start-AcsSession 内保留幂等复查）
    if (-not (Get-Command $cliDef.cmd -ErrorAction SilentlyContinue)) {
        Write-Host ('  ✘ 找不到 {0} 命令，请先安装 {1}' -f $cliDef.cmd, $cliDef.cmd) -ForegroundColor Red
        return
    }
    # 记录上次使用并拉起会话
    try { Set-Content -Path $script:AcsLastFile -Value ($cliId + "`t" + $sel + "`t" + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -Encoding ASCII -ErrorAction Stop } catch { }
    Start-AcsSession -CliId $cliId -CliDef $cliDef -Sel $sel -Entry $list[$sel] -Rest ([string[]]$rest)
}

Set-Alias -Name acs -Value Invoke-Acs

# Tab 补全：第 1 参数=子命令+CLI 名；子命令的第二参数=CLI 名；edit/remove/recheck 的第三参数=供应商
Register-ArgumentCompleter -CommandName 'Invoke-Acs', 'acs' -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    try {
        # 注意类型名为 CommandElementAst（写错会被 catch 吞掉，导致 Tab 补全静默失效回退文件系统）
        $elemCount = $commandAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandElementAst] }, $true).Count
        if ($elemCount -gt 4) { return }
        $clis = Get-AcsClis -Quiet
        if ($null -eq $clis) { return }
        $subCmds = @('add', 'edit', 'remove', 'import', 'recheck', 'preset', 'list', 'status', 'help', 'version')
        # 第 1 个参数位置：子命令 + CLI 名
        if ($elemCount -le 2) {
            $cands = $subCmds + @($clis.Keys)
            $cands | Where-Object { $_ -like ($wordToComplete + '*') } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
            return
        }
        $cliWord = $commandAst.CommandElements[1].ToString().ToLower()
        $map = Get-AcsSupplierMap
        # 子命令路径：第二参数补 CLI 名；edit/remove/recheck 的第三参数补该 CLI 的供应商
        if ($subCmds -contains $cliWord) {
            if ($elemCount -eq 3 -and $cliWord -in @('add', 'edit', 'remove', 'recheck', 'list', 'preset')) {
                @($clis.Keys) | Where-Object { $_ -like ($wordToComplete + '*') } |
                    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
            } elseif ($elemCount -eq 4 -and $cliWord -in @('edit', 'remove', 'recheck') -and $commandAst.CommandElements.Count -gt 2) {
                $target = $commandAst.CommandElements[2].ToString()
                if ($map -and $map[$target]) {
                    $l = Get-AcsSupplierList -CliId $target -Map $map
                    if ($l) {
                        @($l.Keys) | Where-Object { $_ -like ($wordToComplete + '*') } |
                            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
                    }
                }
            }
            return
        }
        # CLI 路径：补全该 CLI 的供应商
        if ($map -and $map[$cliWord]) {
            $l = Get-AcsSupplierList -CliId $cliWord -Map $map
            if ($l) {
                @($l.Keys) | Where-Object { $_ -like ($wordToComplete + '*') } |
                    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
            }
        }
    } catch { }
}
