# ============================================================================
#  uninstall-remote.ps1 - acs remote uninstall bootstrap (irm | iex only)
#  Contract:
#    - No BOM, ASCII only: consumed via "irm ... | iex", where a BOM char
#      would stick to the first token and break parsing; ASCII keeps the
#      script independent of HTTP charset and console codepage.
#    - Downloads uninstall.ps1 to a temp file and invokes it from disk
#      (in -File mode its BOM and param binding both work normally).
#  Note: remote uninstall keeps user data (~\.acs\suppliers.json) by default.
#        For a full purge run ./uninstall.ps1 -Purge from a local clone.
# ============================================================================

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$Repo = 'ldtmore/AgentCliSwitch'
# jsDelivr first (reachable in mainland China), raw fallback
$Urls = @(
    ('https://cdn.jsdelivr.net/gh/' + $Repo + '@main/uninstall.ps1'),
    ('https://raw.githubusercontent.com/' + $Repo + '/main/uninstall.ps1')
)

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('acs-uninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    Write-Host ''
    Write-Host '  AgentCliSwitch (acs) remote uninstall' -ForegroundColor Cyan
    Write-Host ''
    $downloaded = $false
    foreach ($u in $Urls) {
        try { Invoke-WebRequest -Uri $u -OutFile $tmp -UseBasicParsing; $downloaded = $true; break } catch { }
    }
    if (-not $downloaded) { throw 'Download failed from both jsDelivr and raw (check network/proxy).' }
    & $tmp
    Write-Host ''
    Write-Host '  Note: user data (~\.acs\suppliers.json) is kept by default (remote cannot pass -Purge).' -ForegroundColor Yellow
    Write-Host '  Full purge (deletes suppliers.json incl. API keys): clone the repo and run ./uninstall.ps1 -Purge'
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
