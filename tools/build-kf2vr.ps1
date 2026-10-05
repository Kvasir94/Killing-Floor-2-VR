<# Build and select the authoritative multiplayer/VR package from this checkout. #>
[CmdletBinding()]
param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
Push-Location $repo
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-hand-assets.ps1') -TimeoutSeconds 300
    if ($LASTEXITCODE -ne 0) { throw 'Shared VR asset build failed.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-multiplayer-native.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Native build or CTest failed.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-multiplayer-scripts.ps1') -IncludeVRClient
    if ($LASTEXITCODE -ne 0) { throw 'Script build failed.' }
    & $Python -m unittest discover -s tools/multiplayer -p 'test_*.py' -q
    if ($LASTEXITCODE -ne 0) { throw 'Offline multiplayer tests failed.' }
    & $Python tools/multiplayer/package.py
    if ($LASTEXITCODE -ne 0) { throw 'Packaging failed; previous main package remains selected.' }
    Write-Host 'Main package selected. Launch Play-KF2VR.cmd.'
} finally { Pop-Location }
