<#
.SYNOPSIS
  Email the current mobile access links to yourself.

.DESCRIPTION
  Reads the links written by refresh-mobile.ps1 (mobile-urls.txt) and sends them
  over SMTP. Silent no-op when the config file is absent, and a send failure
  never blocks the rebuild — it is only appended to mail.log.

.CONFIG
  %DSH_HOME%\web-service\mail-config.json

      {
        "host": "smtp.qq.com",
        "port": 587,
        "from": "you@qq.com",
        "to":   "you@qq.com",
        "password": "<SMTP authorization code>"
      }

  For QQ Mail: enable IMAP/SMTP in the mailbox settings and use the generated
  16-character authorization code — NOT the account password.

  The file contains a credential; create it yourself and restrict its ACL, e.g.
    icacls mail-config.json /inheritance:r /grant:r "$env:USERNAME:(R,W)"
#>

$ErrorActionPreference = 'Continue'

$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$WorkDir = Join-Path $DshHome 'web-service'
$cfgPath = Join-Path $WorkDir 'mail-config.json'
$urlsPath = Join-Path $WorkDir 'mobile-urls.txt'
$logPath = Join-Path $WorkDir 'mail.log'

function Write-MailLog([string]$msg) {
    try {
        Add-Content -LiteralPath $logPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding utf8
    } catch { }
}

if (-not (Test-Path -LiteralPath $cfgPath)) { Write-MailLog 'skip: mail-config.json missing'; exit 0 }
if (-not (Test-Path -LiteralPath $urlsPath)) { Write-MailLog 'skip: mobile-urls.txt missing'; exit 0 }

$cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
$lan = ''
$wan = ''
foreach ($line in Get-Content -LiteralPath $urlsPath) {
    if ($line -match '^lan:\s*(.+)$') { $lan = $Matches[1].Trim() }
    elseif ($line -match '^public:\s*(.+)$') { $wan = $Matches[1].Trim() }
    elseif ($line -match '^局域网:\s*(.+)$') { $lan = $Matches[1].Trim() }
    elseif ($line -match '^公网:\s*(.+)$') { $wan = $Matches[1].Trim() }
}
if (-not $wan) { Write-MailLog 'skip: no public url in mobile-urls.txt'; exit 0 }

$body = @"
DSH mobile access

time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

[any network - use this on the phone]
$wan

[same WiFi - faster]
$lan

---
The public address is a temporary Cloudflare quick tunnel: it changes every
time the service is rebuilt. Always use the newest mail.
"@

$mail = New-Object System.Net.Mail.MailMessage
$mail.From = New-Object System.Net.Mail.MailAddress($cfg.from)
$mail.To.Add($cfg.to)
$mail.Subject = ('[DSH] mobile access ' + (Get-Date -Format 'MM-dd HH:mm'))
$mail.SubjectEncoding = [System.Text.Encoding]::UTF8
$mail.Body = $body
$mail.BodyEncoding = [System.Text.Encoding]::UTF8
$mail.IsBodyHtml = $false

$smtp = New-Object System.Net.Mail.SmtpClient($cfg.host, [int]$cfg.port)
$smtp.EnableSsl = $true
$smtp.Timeout = 20000
$smtp.Credentials = New-Object System.Net.NetworkCredential($cfg.from, $cfg.password)

try {
    $smtp.Send($mail)
    Write-MailLog ('sent -> ' + $cfg.to)
    Write-Host ('mail sent to ' + $cfg.to)
} catch {
    $msg = $_.Exception.Message
    if ($_.Exception.InnerException) { $msg += ' | ' + $_.Exception.InnerException.Message }
    Write-MailLog ('send failed: ' + $msg)
    Write-Host ('mail failed (service keeps running): ' + $msg)
} finally {
    $smtp.Dispose()
    $mail.Dispose()
}
