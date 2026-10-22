<#
.SYNOPSIS
  (Re)build the DSH mobile access service: Cloudflare quick tunnel + web profile,
  then email the fresh link.

.DESCRIPTION
  Architecture:
      phone -> Cloudflare quick tunnel -> dsh web (--profile web, LAN IP:port)

  Important implementation notes (learned the hard way):

  * The web instance must be started with `--public-url` and `--trusted-host`,
    where **--trusted-host takes a BARE host, no scheme**. Passing
    "https://xxx.trycloudflare.com" makes dsh refuse to boot with
    "trustedHosts entry ... is not a bare host[:port] authority".

  * Do NOT put a host-rewriting reverse proxy in front of dsh. The auth cookie
    is signed with the authority in it; rewriting the Host makes the cookie
    authority mismatch the real domain and the browser then loops forever on
    303 redirects (the page never loads).

  * Every rebuild creates a new quick-tunnel domain AND a new web token, so the
    old link dies. That is why the link is emailed on every rebuild.

.ENVIRONMENT
  DSH_HOME                    default: %USERPROFILE%\.dsh
  DSH_MOBILE_PORT             default: 3081
  DSH_CLI                     dsh launcher, default: "dsh" (must be on PATH)
  DSH_MOBILE_CLOUDFLARED      cloudflared.exe path; auto-detected otherwise
  DSH_MOBILE_PROFILE          dsh profile name, default: web
#>

param([int]$Port = $(if ($env:DSH_MOBILE_PORT) { [int]$env:DSH_MOBILE_PORT } else { 3081 }))

$ErrorActionPreference = 'Continue'

$DshHome  = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$WorkDir  = Join-Path $DshHome 'web-service'
$Profile  = if ($env:DSH_MOBILE_PROFILE) { $env:DSH_MOBILE_PROFILE } else { 'web' }
$DshCli   = if ($env:DSH_CLI) { $env:DSH_CLI } else { 'dsh' }

$WebConsole  = Join-Path $WorkDir 'web.console.log'
$CfLog       = Join-Path $WorkDir 'cloudflared.log'
$UrlFile     = Join-Path $WorkDir 'mobile-urls.txt'
$WebLauncher = Join-Path $WorkDir 'web-launch.ps1'
$WebVbs      = Join-Path $WorkDir 'web-launch-hidden.vbs'
$CfVbs       = Join-Path $WorkDir 'cf-launch-hidden.vbs'

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

function Find-Cloudflared {
    if ($env:DSH_MOBILE_CLOUDFLARED -and (Test-Path -LiteralPath $env:DSH_MOBILE_CLOUDFLARED)) {
        return $env:DSH_MOBILE_CLOUDFLARED
    }
    $cmd = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(Get-ChildItem (Join-Path $DshHome 'mobile-access\components\cloudflared') -Recurse -Filter 'cloudflared.exe' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    return $null
}

# Physical adapter only: skip the virtual NICs (TUN/VPN/Hyper-V) that would give
# the phone an address it can never reach.
function Get-LanAddress {
    $cands = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            $_.SkipAsSource -ne $true
        })
    foreach ($c in $cands) {
        if ($c.InterfaceAlias -match 'vgate|TUN|Tap|WireGuard|Tailscale|ZeroTier|vEthernet|Loopback|Bluetooth') { continue }
        $a = Get-NetAdapter -InterfaceIndex $c.InterfaceIndex -ErrorAction SilentlyContinue
        if ($a -and $a.Physical -and $a.Status -eq 'Up') { return $c.IPAddress }
    }
    foreach ($c in $cands) {
        if ($c.InterfaceAlias -notmatch 'vgate|TUN|Tap|WireGuard|Tailscale|ZeroTier|vEthernet|Loopback') { return $c.IPAddress }
    }
    return $null
}

function Stop-ByPort([int]$p) {
    foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

# ---------- 1) LAN address ----------
$lan = Get-LanAddress
if (-not $lan) { Write-Host 'cannot resolve a LAN IPv4'; exit 1 }
Write-Host "LAN IP: $lan"

$cf = Find-Cloudflared
if (-not $cf) {
    Write-Host 'cloudflared.exe not found. Install it or set DSH_MOBILE_CLOUDFLARED.'
    exit 1
}

# ---------- 2) clean slate ----------
Stop-ByPort $Port
Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# ---------- 3) tunnel (points straight at the web port, Host untouched) ----------
Write-Host 'starting cloudflared...'
Remove-Item $CfLog -Force -ErrorAction SilentlyContinue
@"
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run """$cf"" tunnel --url http://${lan}:$Port --no-autoupdate --protocol http2 --logfile ""$CfLog""", 0, False
"@ | Set-Content -LiteralPath $CfVbs -Encoding utf8
Start-Process wscript.exe -ArgumentList "`"$CfVbs`"" -WindowStyle Hidden

$publicUrl = $null
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    $m = Select-String -Path $CfLog -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { $publicUrl = $m.Matches.Value; break }
}
if (-not $publicUrl) { Write-Host 'no tunnel domain assigned (see cloudflared.log)'; exit 1 }
$cfHost = ($publicUrl -replace '^https?://', '').TrimEnd('/')
Write-Host "tunnel: $publicUrl"

# ---------- 4) dsh web with bare-host trusted-host ----------
Write-Host 'starting dsh web...'
@"
`$ErrorActionPreference = 'Continue'
& '$DshCli' --profile $Profile --port $Port --host $lan --public-url $publicUrl --trusted-host $cfHost --no-open *>&1 | Tee-Object -FilePath '$WebConsole' -Append
"@ | Set-Content -LiteralPath $WebLauncher -Encoding utf8

@"
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run "pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ""$WebLauncher""", 0, False
"@ | Set-Content -LiteralPath $WebVbs -Encoding utf8
Start-Process wscript.exe -ArgumentList "`"$WebVbs`"" -WindowStyle Hidden

$webOk = $false
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 1
    if (@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
          Where-Object { $_.LocalAddress -eq $lan }).Count -gt 0) { $webOk = $true; break }
}
if (-not $webOk) { Write-Host 'dsh web did not start (see web.console.log)'; exit 1 }
Write-Host "dsh web OK: http://${lan}:$Port"

# ---------- 5) token (match THIS domain, or an old line from an earlier boot wins) ----------
$token = $null
$pattern = 'dsh web: ' + [regex]::Escape($publicUrl) + '/\?token=([A-Za-z0-9_\-]+)'
for ($i = 0; $i -lt 30 -and -not $token; $i++) {
    Start-Sleep -Seconds 1
    $m = Select-String -Path $WebConsole -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($m) { $token = $m.Matches[0].Groups[1].Value }
}

$suffix  = if ($token) { "?token=$token" } else { '' }
$lanUrl  = "http://${lan}:$Port/$suffix"
$pubFull = "$publicUrl/$suffix"

@(
    "generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "lan:      $lanUrl"
    "public:   $pubFull"
) | Set-Content -LiteralPath $UrlFile -Encoding utf8

Write-Host ''
Write-Host '=========== phone links ===========' -ForegroundColor Green
Write-Host "same WiFi : $lanUrl"
Write-Host "any network: $pubFull" -ForegroundColor Cyan
Write-Host ''

# ---------- 6) email (optional) ----------
$mail = Join-Path $DshHome 'send-mobile-url.ps1'
if (Test-Path -LiteralPath $mail) {
    try { & $mail } catch { }
}
