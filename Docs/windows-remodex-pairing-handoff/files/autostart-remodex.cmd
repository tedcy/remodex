@echo off
chcp 65001 >nul
set "REMODEX_PRINT_PAIRING_JSON=0"
set "REMODEX_LOG_DIR=%USERPROFILE%\remodex\logs"
set "REMODEX_PAIRING_QR_HTML=%REMODEX_LOG_DIR%\pairing-qr.html"
if not exist "%REMODEX_LOG_DIR%" mkdir "%REMODEX_LOG_DIR%"
powershell.exe -NoProfile -Command "$p = Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*remodex.js run*' }; if ($p) { exit 0 } exit 1" >nul 2>nul
if not errorlevel 1 exit /b 0
for /f %%I in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "REMODEX_RUN_STAMP=%%I"
cd /d "%USERPROFILE%\remodex"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\remodex\start-remodex-local.ps1" >> "%REMODEX_LOG_DIR%\bridge-autostart-%REMODEX_RUN_STAMP%.log" 2>&1
