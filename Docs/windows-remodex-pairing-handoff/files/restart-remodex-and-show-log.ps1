param([switch]$NoPause)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

$Task = 'RemodexBridgeAutoStart'
$Base = 'C:\Users\tedcy\remodex'
$LogDir = Join-Path $Base 'logs'
$Log = Join-Path $LogDir 'bridge-autostart.log'
$QrHtml = Join-Path $LogDir 'pairing-qr.html'
$BridgePidFile = Join-Path $LogDir 'bridge-runner.pid'
$Runner = Join-Path $Base 'start-remodex-local.ps1'
$RestartScriptName = 'restart-remodex-and-show-log.ps1'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

Write-Host "[remodex] Stopping $Task ..."
& schtasks.exe /End /TN $Task | Out-Null
Start-Sleep -Seconds 1

if (Test-Path -LiteralPath $BridgePidFile) {
  $oldPid = (Get-Content -LiteralPath $BridgePidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($oldPid -match '^\d+$') {
    & taskkill.exe /PID $oldPid /T /F | Out-Null
  }
  Remove-Item -LiteralPath $BridgePidFile -Force -ErrorAction SilentlyContinue
}

Write-Host '[remodex] Stopping old Remodex processes ...'
$processes = Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -and
  (
    $_.CommandLine -like "*$Base*" -or
    $_.CommandLine -match 'remodex\.js"?\s+run'
  ) -and
  $_.CommandLine -notlike "*$RestartScriptName*" -and
  $_.ProcessId -ne $PID
}
foreach ($process in $processes) {
  try {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  } catch {}
}
Start-Sleep -Seconds 1

Write-Host '[remodex] Clearing old log ...'
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $QrHtml -Force -ErrorAction SilentlyContinue

Write-Host '[remodex] Starting Remodex hidden, logging to:'
Write-Host "  $Log"
$cmdLine = 'set "REMODEX_PRINT_PAIRING_JSON=0" && set "REMODEX_PAIRING_QR_HTML=' + $QrHtml + '" && set "REMODEX_LOG_DIR=' + $LogDir + '" && cd /d "' + $Base + '" && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $Runner + '" >> "' + $Log + '" 2>&1'
$bridgeRunner = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', $cmdLine) -WindowStyle Hidden -PassThru
Set-Content -LiteralPath $BridgePidFile -Value $bridgeRunner.Id -Encoding ASCII

Write-Host ''
Write-Host '[remodex] Waiting for pairing code in log ...'
$text = ''
$code = ''
for ($i = 0; $i -lt 45; $i++) {
  if (Test-Path -LiteralPath $Log) {
    try {
      $text = Get-Content -LiteralPath $Log -Raw -Encoding UTF8 -ErrorAction Stop
      if ($text -match '(?s)Or paste this pairing code in the iPhone app:\s*([A-Z2-9]{10})') {
        $code = $Matches[1]
        break
      }
    } catch {}
  }
  Start-Sleep -Seconds 1
}

if (Test-Path -LiteralPath $QrHtml) {
  Write-Host "[remodex] Opening QR image ..."
  Start-Process -FilePath $QrHtml | Out-Null
}

function Get-DisplayLog {
  param([string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $raw = [regex]::Replace(
    $raw,
    '(?s)Scan this QR with the iPhone:\s*.*?Or paste this pairing code in the iPhone app:',
    "[remodex] QR image opened separately.`r`n`r`nOr paste this pairing code in the iPhone app:"
  )
  $raw = [regex]::Replace(
    $raw,
    '(?s)Pairing JSON \(debug only; same sensitive bytes as the QR\):\s*\{.*?\}\s*',
    ''
  )
  return $raw
}

Write-Host ''
Write-Host '==================== Remodex pairing log ===================='
if (Test-Path -LiteralPath $Log) {
  Get-DisplayLog -Path $Log
} else {
  Write-Host "[remodex] Log was not created: $Log"
}
Write-Host '========================== end log =========================='

if ($code) {
  Write-Host ''
  Write-Host "PAIRING CODE: $code"
}
Write-Host ''
if (Test-Path -LiteralPath $QrHtml) {
  Write-Host "QR image: $QrHtml"
}
Write-Host 'Scan the opened QR image, or paste the pairing code above.'
Write-Host "Log file: $Log"

if (-not $NoPause) {
  Write-Host ''
  Read-Host 'Press Enter after scanning/pairing'
}
