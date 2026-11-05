@echo off
rem Steam Launch Options: "<this folder>\Play.cmd" %command%
start "" "%~dp0KF2VR\app\runtime\pythonw.exe" "%~dp0KF2VR\play.py" %*
