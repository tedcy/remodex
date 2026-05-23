@echo off
set REMODEX_PRINT_PAIRING_JSON=0
set REMODEX_LOG_DIR=C:\Users\tedcy\remodex\logs
if not exist "%REMODEX_LOG_DIR%" mkdir "%REMODEX_LOG_DIR%"
cd /d C:\Users\tedcy\remodex
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\tedcy\remodex\start-remodex-local.ps1 >> "%REMODEX_LOG_DIR%\bridge-autostart.log" 2>&1
