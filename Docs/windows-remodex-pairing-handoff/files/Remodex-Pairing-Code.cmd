@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\remodex\restart-remodex-and-show-log.ps1"
