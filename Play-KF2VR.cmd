@echo off
setlocal
title KF2 VR - Main
rem Use Windows PowerShell modules even when CMD inherits a PowerShell 7 environment.
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
set "menu_arg="
if "%~1"=="" set "menu_arg=-Gui"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\play-main.ps1" %menu_arg% %*
set "launch_exit=%errorlevel%"
if not "%launch_exit%"=="0" pause
exit /b %launch_exit%
