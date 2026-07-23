<#
.SYNOPSIS
  Summarise this machine's Claude Code usage for the dashboard hub. (Windows)

.DESCRIPTION
  PowerShell counterpart of export-usage.sh, for Windows-native where there is
  no bash. WSL uses the .sh version.

  Runs ccusage against the LOCAL transcripts and writes a compact, machine-tagged
  summary. Only the summary leaves the machine: the transcripts themselves run to
  hundreds of megabytes and are full conversation history, not just numbers.

  SLUG NORMALISATION — why this matters on Windows especially:
  ccusage reports `sessionId` as the project slug, which encodes the ABSOLUTE
  path. The same repo is:
      -Users-jkobrien-code-PDP      on macOS
      -home-jkobrien-code-PDP       on Linux
      -C--Users-jkobrien-code-PDP   on Windows
  Merging raw slugs would show one repo three times. We resolve each slug against
  the machine's real repo list and emit a repo NAME instead.

.PARAMETER OutFile
  Where to write. Defaults to ~/.claude-dashboard/data/usage-<machine>.json
#>

[CmdletBinding()]
param([string]$OutFile = "")

$ErrorActionPreference = "Stop"

$machine = $env:COMPUTERNAME
if (-not $machine) { $machine = [System.Net.Dns]::GetHostName() }
$machineLower = $machine.ToLower()

$dataDir = if ($env:CLAUDE_DASHBOARD_DATA) { $env:CLAUDE_DASHBOARD_DATA }
           else { Join-Path $HOME ".claude-dashboard\data" }
if (-not $OutFile) { $OutFile = Join-Path $dataDir "usage-$machineLower.json" }
New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null

# --- locate ccusage -----------------------------------------------------------
$ccusage = $null
foreach ($c in @(
    (Join-Path $HOME "code\ClaudeDashboard\node_modules\.bin\ccusage.cmd"),
    (Join-Path $HOME "code\ClaudeDashboard\node_modules\.bin\ccusage"),
    "ccusage"
)) {
    if ($c -eq "ccusage") {
        if (Get-Command ccusage -ErrorAction SilentlyContinue) { $ccusage = "ccusage"; break }
    } elseif (Test-Path $c) { $ccusage = $c; break }
}
if (-not $ccusage) {
    Write-Error "ccusage not found. Run 'npm install' in the ClaudeDashboard repo."
    exit 1
}

# --- CODE_ROOT, so slugs can be resolved to real repos ------------------------
$codeRoot = $env:CODE_ROOT
if (-not $codeRoot) {
    $envFile = Join-Path $HOME ".claude-env"
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            if ($_ -match '^\s*export\s+CODE_ROOT="?([^"]*)"?') {
                $codeRoot = $Matches[1] -replace '\$HOME', $HOME
            }
        }
    }
}
if (-not $codeRoot) { $codeRoot = Join-Path $HOME "code" }

# Repo names actually present on this machine. Resolving against these — rather
# than splitting the slug on separators — is what stops junk entries like "354".
$known = @{}
if (Test-Path $codeRoot) {
    Get-ChildItem $codeRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Path (Join-Path $_.FullName ".git")) { $known[$_.Name] = $true }
    }
}

function Resolve-Repo([string]$slug, [string]$projectPath) {
    foreach ($cand in @($projectPath, $slug)) {
        if (-not $cand) { continue }
        $parts = $cand -split '[\\/\-]' | Where-Object { $_ }
        for ($i = $parts.Count - 1; $i -ge 0; $i--) {
            if ($known.ContainsKey($parts[$i])) { return $parts[$i] }
        }
    }
    return $null
}

# --- run ccusage --------------------------------------------------------------
$sessionsRaw = & $ccusage session --json 2>$null | Out-String
$dailyRaw    = & $ccusage daily   --json 2>$null | Out-String
if (-not $sessionsRaw.Trim()) { Write-Error "ccusage returned nothing"; exit 1 }

$sessions = (ConvertFrom-Json $sessionsRaw).sessions
$daily    = if ($dailyRaw.Trim()) { (ConvertFrom-Json $dailyRaw).daily } else { @() }

# --- aggregate ----------------------------------------------------------------
$byRepo = @{}
$unattributedCost = 0.0
$unattributedTokens = 0
$unattributedSlugs = New-Object System.Collections.Generic.HashSet[string]

foreach ($s in $sessions) {
    $repo   = Resolve-Repo $s.sessionId $s.projectPath
    $cost   = [double]($s.totalCost   | ForEach-Object { if ($_) { $_ } else { 0 } })
    $tokens = [long]  ($s.totalTokens | ForEach-Object { if ($_) { $_ } else { 0 } })

    if (-not $repo) {
        $unattributedCost   += $cost
        $unattributedTokens += $tokens
        if ($s.sessionId) { [void]$unattributedSlugs.Add($s.sessionId) }
        continue
    }
    if (-not $byRepo.ContainsKey($repo)) {
        $byRepo[$repo] = [ordered]@{ cost = 0.0; tokens = 0; sessions = 0; models = @() }
    }
    $byRepo[$repo].cost     += $cost
    $byRepo[$repo].tokens   += $tokens
    $byRepo[$repo].sessions += 1
    foreach ($m in @($s.modelsUsed)) {
        if ($m -and $byRepo[$repo].models -notcontains $m) { $byRepo[$repo].models += $m }
    }
}
foreach ($k in @($byRepo.Keys)) {
    $byRepo[$k].cost   = [math]::Round($byRepo[$k].cost, 4)
    $byRepo[$k].models = @($byRepo[$k].models | Sort-Object)
}

# Totals, summed explicitly — see the note in the totals block below.
$repoCostSum  = 0.0
$repoTokenSum = [long]0
foreach ($v in $byRepo.Values) { $repoCostSum += [double]$v.cost; $repoTokenSum += [long]$v.tokens }

$doc = [ordered]@{
    machine      = $machine
    generated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    code_root    = $codeRoot
    totals       = [ordered]@{
        # Sum by hand: Measure-Object reads PROPERTIES, and these are ordered
        # dictionaries whose "cost"/"tokens" are KEYS. It silently returns
        # nothing rather than erroring, which produced a total of just the
        # unattributed figure while by_repo was perfectly correct.
        cost   = [math]::Round(($repoCostSum + $unattributedCost), 4)
        tokens = ($repoTokenSum + $unattributedTokens)
    }
    by_repo      = $byRepo
    unattributed = [ordered]@{
        cost   = [math]::Round($unattributedCost, 4)
        tokens = $unattributedTokens
        slugs  = @($unattributedSlugs | Sort-Object)
    }
    daily        = $daily
}

# Depth 10: the daily array nests, and PowerShell's default of 2 would silently
# truncate it to the string "System.Object[]".
$doc | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8

Write-Host "  machine     : $machine"
Write-Host "  repos       : $($byRepo.Count)"
Write-Host "  total cost  : `$$($doc.totals.cost)"
if ($unattributedCost -gt 0) {
    Write-Host "  unattributed: `$$([math]::Round($unattributedCost,2)) ($($unattributedSlugs.Count) slug(s))"
}
Write-Host "  written     : $OutFile ($((Get-Item $OutFile).Length) bytes)"
