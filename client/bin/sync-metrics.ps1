<#
.SYNOPSIS
  Push this machine's metrics to the dashboard hub. (Windows)

.DESCRIPTION
  PowerShell counterpart of sync-metrics.sh, for Windows-native where there is
  no bash. WSL uses the .sh version.

  Each machine pushes files named for itself:
      <hub>:~/.claude-dashboard/data/usage-<machine>.json
  server.js merges them at read time. Machines never append to a shared file —
  several writers over a network is a corruption risk.

  TRANSPORT — Windows cannot RECEIVE ssh (no Tailscale SSH server), but it can
  SEND: OpenSSH client has shipped with Windows since 1809. So scp works. There
  is no rsync on Windows by default, hence scp rather than rsync.
  Falls back to Taildrop if scp is unavailable.

.PARAMETER Hub
  Hub machine name. Defaults to $env:CLAUDE_METRICS_HUB, else "mordor".
#>

[CmdletBinding()]
param([string]$Hub = "")

$ErrorActionPreference = "Stop"

if (-not $Hub) { $Hub = if ($env:CLAUDE_METRICS_HUB) { $env:CLAUDE_METRICS_HUB } else { "mordor" } }

$machine      = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
$machineLower = $machine.ToLower()
$dataDir      = if ($env:CLAUDE_DASHBOARD_DATA) { $env:CLAUDE_DASHBOARD_DATA }
                else { Join-Path $HOME ".claude-dashboard\data" }
$remoteDir    = ".claude-dashboard/data"
$binDir       = Split-Path -Parent $MyInvocation.MyCommand.Path

function Ok   ($m) { Write-Host "[OK]  $m" -ForegroundColor Green }
function Info ($m) { Write-Host "[->]  $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "[!]   $m" -ForegroundColor Yellow }
function Fail ($m) { Write-Host "[X]   $m" -ForegroundColor Red; exit 1 }

Info "machine: $machineLower   hub: $Hub"

# --- 1. refresh this machine's usage summary ---------------------------------
$export = Join-Path $binDir "export-usage.ps1"
if (Test-Path $export) {
    try {
        & $export -OutFile (Join-Path $dataDir "usage-$machineLower.json") | Out-Null
        Ok "exported usage-$machineLower.json"
    } catch {
        Warn "usage export failed ($($_.Exception.Message)) - syncing whatever exists"
    }
} else {
    Warn "export-usage.ps1 not found next to this script"
}

# --- 2. name the pipeline store per machine ----------------------------------
$localPipeline  = Join-Path $dataDir "pipeline-executions.json"
$stagedPipeline = Join-Path $dataDir "pipeline-$machineLower.json"
if (Test-Path $localPipeline) { Copy-Item $localPipeline $stagedPipeline -Force }

# --- 3. am I the hub? ---------------------------------------------------------
if ($machineLower -eq $Hub.ToLower()) { Ok "this machine IS the hub - nothing to send"; exit 0 }

# --- 4. is the hub reachable? -------------------------------------------------
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) { Fail "tailscale not installed" }

$status = tailscale status --json 2>$null | ConvertFrom-Json
$peer = $status.Peer.PSObject.Properties.Value | Where-Object { $_.HostName -ieq $Hub }
if (-not $peer)        { Fail "'$Hub' is not on this tailnet" }
if (-not $peer.Online) { Warn "'$Hub' is offline - records stay local, next sync will catch up"; exit 0 }

# --- 5. send ------------------------------------------------------------------
$files = @(
    (Join-Path $dataDir "usage-$machineLower.json"),
    $stagedPipeline
) | Where-Object { Test-Path $_ }

if (-not $files) { Fail "nothing to send" }

$sent = 0
if (Get-Command scp -ErrorAction SilentlyContinue) {
    Info "transport: scp over Tailscale SSH"
    # Create the destination first — scp will not make intermediate directories.
    & ssh -n $Hub "mkdir -p ~/$remoteDir" 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "cannot reach $Hub over SSH - is Tailscale SSH enabled there?" }
    foreach ($f in $files) {
        & scp -q $f "${Hub}:$remoteDir/$(Split-Path -Leaf $f)" 2>$null
        if ($LASTEXITCODE -eq 0) { Ok "sent $(Split-Path -Leaf $f) ($((Get-Item $f).Length) bytes)"; $sent++ }
        else { Warn "failed to send $(Split-Path -Leaf $f)" }
    }
} else {
    Warn "scp not found - falling back to Taildrop (needs manual pickup on the hub)"
    foreach ($f in $files) {
        & tailscale file cp $f "${Hub}:" 2>$null
        if ($LASTEXITCODE -eq 0) { Ok "taildropped $(Split-Path -Leaf $f)"; $sent++ }
    }
    if ($sent -gt 0) {
        Write-Host ""
        Write-Host "  Now ON $Hub :  tailscale file get ~/$remoteDir/"
    }
}

if ($sent -gt 0) { Ok "synced $sent file(s) to $Hub" } else { Fail "nothing sent" }
