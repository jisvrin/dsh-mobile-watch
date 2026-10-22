<#
.SYNOPSIS
  Decide whether the DSH mobile access service is alive; rebuild it if not.

.DESCRIPTION
  Called (20 s after DSH boots) by the dsh-mobile-watch plugin. Idempotent:
    - healthy  -> exit 0, touch nothing (no domain change, no email, no log noise)
    - missing  -> run refresh-mobile.ps1 (rebuild tunnel + web, then email the link)

  "Healthy" means BOTH:
    1. the DSH web profile is listening on the mobile port
    2. cloudflared is running

  A lock file prevents concurrent runs: DSH can mount the bundle more than once
  per boot (profile patch reload), and each mount fires the plugin.

.ENVIRONMENT
  DSH_HOME              default: %USERPROFILE%\.dsh
  DSH_MOBILE_PORT       default: 3081
#>

$ErrorActionPreference = 'Continue'

$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$WorkDir = Join-Path $DshHome 'web-service'
$Port    = if ($env:DSH_MOBILE_PORT) { [int]$env:DSH_MOBILE_PORT } else { 3081 }

$refresh   = Join-Path $WorkDir 'refresh-mobile.ps1'
$lockFile  = Join-Path $WorkDir 'check-mobile.lock'
$logFile   = Join-Path $WorkDir 'check-mobile.log'
$stateFile = Join-Path $WorkDir 'dsh-desktop-state.txt'

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

function Write-CheckLog([string]$msg) {
    try {
        Add-Content -LiteralPath $logFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding utf8
    } catch { }
}

# ---------- concurrency lock ----------
if (Test-Path -LiteralPath $lockFile) {
    $age = (Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime
    if ($age.TotalMinutes -lt 5) { exit 0 }
}
Set-Content -LiteralPath $lockFile -Value (Get-Date -Format 'o') -Encoding utf8

try {
    $listening = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    $cfAlive   = [bool](Get-Process cloudflared -ErrorAction SilentlyContinue)
    $serviceOk = ($listening.Count -gt 0) -and $cfAlive

    if ($serviceOk) {
        exit 0
    }

    $desk = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'profiles[\\/]desktop' } |
            Select-Object -First 1
    $deskInfo = if ($desk) { "DSH=$($desk.ProcessId)" } else { 'DSH=not-running' }

    Write-CheckLog ("rebuild needed: mobile service missing (port=$Port, cloudflared=$cfAlive, $deskInfo)")

    if (-not (Test-Path -LiteralPath $refresh)) {
        Write-CheckLog 'refresh-mobile.ps1 not found'
        exit 1
    }

    & $refresh 2>&1 | Out-Null
    Write-CheckLog 'rebuild done'
    Set-Content -LiteralPath $stateFile -Value $deskInfo -Encoding utf8
}
catch {
    Write-CheckLog ('check/rebuild error: ' + $_.Exception.Message)
}
finally {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

exit 0
