@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Install KF2-VR for Epic Killing Floor 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0epic_desktop_install.ps1" %*
set "result=%errorlevel%"
echo.
pause
exit /b %result%
