<#
.SYNOPSIS
  Install the metrics client on this Windows machine.

.DESCRIPTION
  Windows counterpart of install-client.sh. Copies the PowerShell client scripts
  to ~/.claude-dashboard/bin and ensures the data directory exists. Idempotent.

  Windows-native gets the .ps1 scripts; the .sh versions cannot run without
  bash. WSL is a separate environment — run install-client.sh there.

  SCOPE: export-usage and sync-metrics only. The pipeline metrics helpers
  (pipeline-usage, record-pipeline-execution) are not ported, because the
  executing-pipeline skill degrades gracefully without them — it runs fully and
  simply records no per-stage cost. Repo-level cost is unaffected: the dashboard
  derives that from ccusage reading the transcripts directly.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$src  = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "bin"
$dest = if ($env:CLAUDE_DASHBOARD_HOME) { $env:CLAUDE_DASHBOARD_HOME }
        else { Join-Path $HOME ".claude-dashboard" }

function Ok   ($m) { Write-Host "[OK]  $m" -ForegroundColor Green }
function Info ($m) { Write-Host "[->]  $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "[!]   $m" -ForegroundColor Yellow }

Info "installing metrics client -> $dest"

New-Item -ItemType Directory -Path (Join-Path $dest "bin")  -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dest "data") -Force | Out-Null

$installed = 0
Get-ChildItem (Join-Path $src "*.ps1") -ErrorAction SilentlyContinue | ForEach-Object {
    $target = Join-Path $dest "bin\$($_.Name)"
    if ((Test-Path $target) -and ((Get-FileHash $_.FullName).Hash -eq (Get-FileHash $target).Hash)) {
        Ok "$($_.Name) already current"
    } else {
        Copy-Item $_.FullName $target -Force
        Ok "installed $($_.Name)"
        $installed++
    }
}
if ($installed -eq 0 -and -not (Get-ChildItem (Join-Path $dest "bin\*.ps1") -ErrorAction SilentlyContinue)) {
    Warn "no .ps1 client scripts found in $src"
}

# The metrics store accumulates; never clobber an existing one.
$store = Join-Path $dest "data\pipeline-executions.json"
if (-not (Test-Path $store)) {
    '{"executions":[]}' | Set-Content $store -Encoding UTF8
    Ok "initialised empty metrics store"
} else {
    Ok "metrics store exists - left alone"
}

Write-Host ""
Info "client installed. To collect and push:"
Write-Host "    $dest\bin\export-usage.ps1"
Write-Host "    $dest\bin\sync-metrics.ps1 -Hub mordor"
Write-Host ""
Info "to schedule it hourly, from the ClaudeSetup repo:"
Write-Host "    .\scripts\install-sync-schedule.ps1 -Hub mordor"
Write-Host ""

$cc = Join-Path $HOME "code\ClaudeDashboard\node_modules\.bin\ccusage.cmd"
if ((Test-Path $cc) -or (Get-Command ccusage -ErrorAction SilentlyContinue)) {
    Ok "ccusage available"
} else {
    Warn "ccusage not found - run 'npm install' in this repo before the first export"
}
