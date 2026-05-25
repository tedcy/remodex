param([switch]$NoPause)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

$Base = Join-Path $HOME 'remodex'
$LogDir = Join-Path $Base 'logs'
$DefaultLog = Join-Path $LogDir 'bridge-autostart.log'
$QrHtml = Join-Path $LogDir 'pairing-qr.html'
$BridgePidFile = Join-Path $LogDir 'bridge-runner.pid'
$Runner = Join-Path $Base 'start-remodex-local.ps1'
$RestartScriptName = 'restart-remodex-and-show-log.ps1'
$RunStartedAt = Get-Date
$RunStamp = $RunStartedAt.ToString('yyyyMMdd-HHmmss')
$Log = Join-Path $LogDir "bridge-autostart-$RunStamp.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Test-ExclusiveFileAccess {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $true
  }

  try {
    $stream = [System.IO.File]::Open(
      $Path,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
    $stream.Close()
    return $true
  } catch {
    return $false
  }
}

function Clear-LogFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $true
  }

  if (-not (Test-ExclusiveFileAccess -Path $Path)) {
    return $false
  }

  try {
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Stop-ProcessTree {
  param([int]$ProcessId)

  if ($ProcessId -le 0 -or $ProcessId -eq $PID) {
    return
  }

  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if (-not $process) {
    Write-Host "[remodex] Process $ProcessId is already gone."
    return
  }

  & taskkill.exe /PID $ProcessId /T /F *> $null
}

function Test-ProcessAlive {
  param([int]$ProcessId)

  if ($ProcessId -le 0) {
    return $false
  }

  return [bool](Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue)
}

if (Test-Path -LiteralPath $BridgePidFile) {
  $oldPid = (Get-Content -LiteralPath $BridgePidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($oldPid -match '^\d+$') {
    Stop-ProcessTree -ProcessId ([int]$oldPid)
  }
  Remove-Item -LiteralPath $BridgePidFile -Force -ErrorAction SilentlyContinue
}

Write-Host '[remodex] Stopping old Remodex processes ...'
$escapedLogDir = [regex]::Escape($LogDir)
$targetNames = @('cmd.exe', 'powershell.exe', 'node.exe', 'wscript.exe')
$processes = Get-CimInstance Win32_Process | Where-Object {
  $commandLine = $_.CommandLine
  $commandLine -and
  $targetNames -contains $_.Name.ToLowerInvariant() -and
  (
    $commandLine -like "*$Base*" -or
    $commandLine -match 'start-remodex-local\.ps1' -or
    $commandLine -match 'remodex\.js"?\s+run' -or
    $commandLine -match $escapedLogDir -or
    $commandLine -match 'bridge-autostart(?:-\d{8}-\d{6})?\.log'
  ) -and
  $commandLine -notlike "*$RestartScriptName*" -and
  $_.ProcessId -ne $PID
}
foreach ($process in $processes) {
  Stop-ProcessTree -ProcessId ([int]$process.ProcessId)
}
Start-Sleep -Seconds 1

Write-Host '[remodex] Preparing fresh run log ...'
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $QrHtml -Force -ErrorAction SilentlyContinue

Write-Host '[remodex] Starting Remodex hidden, logging to:'
Write-Host "  $Log"
$cmdLine = 'chcp 65001 >nul && set "REMODEX_PRINT_PAIRING_JSON=0" && set "REMODEX_PAIRING_QR_HTML=' + $QrHtml + '" && set "REMODEX_LOG_DIR=' + $LogDir + '" && cd /d "' + $Base + '" && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $Runner + '" >> "' + $Log + '" 2>&1'
$runnerCommand = $env:ComSpec + ' /d /c ' + $cmdLine
$startupInfo = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
$startupInfo.ShowWindow = 0
$createResult = ([wmiclass]'Win32_Process').Create($runnerCommand, $Base, $startupInfo)
if ($createResult.ReturnValue -ne 0) {
  throw "Failed to start Remodex runner via Win32_Process.Create. ReturnValue=$($createResult.ReturnValue)"
}
$bridgeRunnerPid = [int]$createResult.ProcessId
Set-Content -LiteralPath $BridgePidFile -Value $bridgeRunnerPid -Encoding ASCII

Write-Host ''
Write-Host '[remodex] Waiting for pairing code in log ...'
$text = ''
$code = ''
$qrReady = $false
for ($i = 0; $i -lt 45; $i++) {
  if (Test-Path -LiteralPath $QrHtml) {
    try {
      $qrItem = Get-Item -LiteralPath $QrHtml -ErrorAction Stop
      if ($qrItem.LastWriteTime -ge $RunStartedAt.AddSeconds(-2)) {
        $qrReady = $true
      }
    } catch {}
  }

  if (Test-Path -LiteralPath $Log) {
    try {
      $text = Get-Content -LiteralPath $Log -Raw -Encoding UTF8 -ErrorAction Stop
      if ($text -match '(?s)Or paste this pairing code in the iPhone app:\s*([A-Z2-9]{10})') {
        $code = $Matches[1]
      }
    } catch {}
  }

  if ($qrReady -and $code) {
    break
  }

  if (-not (Test-ProcessAlive -ProcessId $bridgeRunnerPid) -and -not $qrReady -and $i -ge 5) {
    break
  }

  Start-Sleep -Seconds 1
}

if ($qrReady) {
  Write-Host "[remodex] Opening QR image ..."
  Start-Process -FilePath $QrHtml | Out-Null
} else {
  Write-Host "[remodex] QR image was not created for this run."
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
