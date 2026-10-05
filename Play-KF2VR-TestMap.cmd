@echo off
setlocal
set "menu_arg="
if "%~1"=="" set "menu_arg=-Gui"
call "%~dp0Play-KF2VR.cmd" -TestMap %menu_arg% %*
exit /b %errorlevel%
