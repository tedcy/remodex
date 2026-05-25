$ErrorActionPreference = 'Stop'

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RuntimeDir = Join-Path $BaseDir 'runtime'
$RelayDir = Join-Path $RuntimeDir 'relay'
$BridgeDir = Join-Path $RuntimeDir 'phodex-bridge'
$LogDir = Join-Path $BaseDir 'logs'
$RelayEnvFile = Join-Path $BaseDir 'relay.env'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Import-RemodexEnvFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) {
      continue
    }
    if ($trimmed -match '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
      $name = $Matches[1]
      $value = $Matches[2].Trim()
    } else {
      continue
    }

    if ($name -notmatch '^REMODEX_') {
      continue
    }

    if ($value.Length -ge 2) {
      $first = $value.Substring(0, 1)
      $last = $value.Substring($value.Length - 1, 1)
      if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
  }

  return $true
}

$RelayConfigLoaded = Import-RemodexEnvFile -Path $RelayEnvFile
$RelayPort = if ($env:REMODEX_RELAY_PORT) { [int]$env:REMODEX_RELAY_PORT } else { 9000 }
$RelayHost = $env:REMODEX_RELAY_HOST
if (-not $RelayHost) {
  $candidate = Get-NetIPConfiguration |
    Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway } |
    Select-Object -First 1
  if ($candidate) {
    $RelayHost = ($candidate.IPv4Address | Select-Object -First 1).IPAddress
  }
}
if (-not $RelayHost) { $RelayHost = '127.0.0.1' }
$RelayUrl = if ($env:REMODEX_RELAY) { $env:REMODEX_RELAY } else { "ws://$($RelayHost):$RelayPort/relay" }
$UseLocalRelay = $RelayUrl -match '^ws://(127\.0\.0\.1|localhost)(:\d+)?/relay$' -or $RelayUrl -eq "ws://$($RelayHost):$RelayPort/relay"

$CodexBinRoot = Join-Path $HOME ([IO.Path]::Combine('AppData', 'Local', 'OpenAI', 'Codex', 'bin'))
$NodeExe = $null
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($nodeCommand) { $NodeExe = $nodeCommand.Source }
if (-not $NodeExe -and (Test-Path -LiteralPath $CodexBinRoot)) {
  $NodeExe = Get-ChildItem -LiteralPath $CodexBinRoot -Recurse -Filter node.exe -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -ExpandProperty FullName -First 1
}
if (-not $NodeExe) { throw 'node.exe not found. Install Node.js or install/run Codex App first.' }

$CodexExe = $null
if (Test-Path -LiteralPath $CodexBinRoot) {
  $CodexExe = Get-ChildItem -LiteralPath $CodexBinRoot -Recurse -Filter codex.exe -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -ExpandProperty FullName -First 1
}
if ($CodexExe) { $env:PATH = (Split-Path -Parent $CodexExe) + ';' + $env:PATH }

$ConfigFile = Join-Path $HOME '.codex\config.toml'
$SecretFile = Join-Path $HOME '.codex\auth_custom.toml'
function Set-RootModelProvider([string]$Provider) {
  if (-not (Test-Path -LiteralPath $ConfigFile)) { return }
  $text = Get-Content -Raw -LiteralPath $ConfigFile
  $replacement = 'model_provider = "' + $Provider + '"'
  if ($text -match '(?m)^\s*model_provider\s*=') {
    $regex = [regex]'(?m)^\s*model_provider\s*=.*$'
    $text = $regex.Replace($text, $replacement, 1)
  } else {
    $text = $replacement + [Environment]::NewLine + $text
  }
  Set-Content -LiteralPath $ConfigFile -Value $text -Encoding UTF8
}
if (Test-Path -LiteralPath $SecretFile) {
  $raw = Get-Content -Raw -LiteralPath $SecretFile
  $match = [regex]::Match($raw, '(?m)^\s*CLIPROXY_API_KEY\s*=\s*("(?:(?:\\.)|[^"\\])*")\s*(?:#.*)?$')
  if ($match.Success) {
    $env:CLIPROXY_API_KEY = $match.Groups[1].Value | ConvertFrom-Json
    Set-RootModelProvider 'cliproxyapi'
  } else {
    Write-Warning "CLIPROXY_API_KEY was not found in $SecretFile"
  }
} else {
  Write-Warning "Missing $SecretFile; Codex may need OpenAI login or another API key."
}

function Test-RelayHealth {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$RelayPort/health" -TimeoutSec 2
    return $response.StatusCode -ge 200 -and $response.StatusCode -lt 300
  } catch {
    return $false
  }
}

if ($UseLocalRelay -and -not (Test-Path -LiteralPath (Join-Path $RelayDir 'server.js'))) { throw "Missing relay runtime: $RelayDir" }
if (-not (Test-Path -LiteralPath (Join-Path $BridgeDir 'bin\remodex.js'))) { throw "Missing bridge runtime: $BridgeDir" }

$startedRelay = $null
$usingExistingRelay = $UseLocalRelay -and (Test-RelayHealth)
if ($UseLocalRelay -and -not $usingExistingRelay) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $relayOut = Join-Path $LogDir "relay-$stamp.out.log"
  $relayErr = Join-Path $LogDir "relay-$stamp.err.log"
  $relayCommand = '& { $env:PORT=''' + $RelayPort + '''; $env:RELAY_BIND_HOST=''0.0.0.0''; Set-Location -LiteralPath ''' + $RelayDir + '''; & ''' + $NodeExe + ''' ''.\server.js'' }'
  $startedRelay = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $relayCommand) -WorkingDirectory $RelayDir -WindowStyle Hidden -RedirectStandardOutput $relayOut -RedirectStandardError $relayErr -PassThru

  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if ($startedRelay.HasExited) { throw "Relay exited early. See $relayErr" }
    if (Test-RelayHealth) { $ready = $true; break }
  }
  if (-not $ready) { throw "Relay did not become healthy on port $RelayPort. See $relayErr" }
}

$env:REMODEX_RELAY = $RelayUrl
$env:REMODEX_DEVICE_STATE_DIR = Join-Path $BaseDir 'state'

Write-Host ''
Write-Host '[remodex-local] Relay URL:' $RelayUrl
if ($RelayConfigLoaded) {
  Write-Host '[remodex-local] Relay config:' $RelayEnvFile
} elseif ($env:REMODEX_RELAY) {
  Write-Host '[remodex-local] Relay config: REMODEX_RELAY from process environment'
} else {
  Write-Host '[remodex-local] Relay config: none, using local relay fallback'
}
if ($UseLocalRelay) {
  Write-Host '[remodex-local] Health:' "http://$($RelayHost):$RelayPort/health"
} else {
  Write-Host '[remodex-local] Health: using configured remote relay'
}
Write-Host '[remodex-local] Node:' $NodeExe
if ($CodexExe) { Write-Host '[remodex-local] Codex:' $CodexExe } else { Write-Host '[remodex-local] Codex: not found on PATH; bridge may fail to start codex app-server.' }
if ($env:CLIPROXY_API_KEY) { Write-Host '[remodex-local] Cliproxy key loaded from .codex\auth_custom.toml' }
Write-Host '[remodex-local] Scan the QR printed below from the iPhone app. Keep this window open.'
Write-Host ''

try {
  Push-Location $BridgeDir
  & $NodeExe '.\bin\remodex.js' run
  $exitCode = $LASTEXITCODE
  Pop-Location
  exit $exitCode
} finally {
  if ($startedRelay -and -not $startedRelay.HasExited) {
    Stop-Process -Id $startedRelay.Id -Force -ErrorAction SilentlyContinue
  }
}
