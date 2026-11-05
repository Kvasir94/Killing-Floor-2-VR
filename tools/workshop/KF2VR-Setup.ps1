# Bundled setup only: no network script download or changes to game files.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'KF2VR\app\runtime\pythonw.exe') (Join-Path $PSScriptRoot 'setup.py')
if ($LASTEXITCODE) { throw 'KF2VR setup failed.' }
