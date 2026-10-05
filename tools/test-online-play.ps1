<# Prepare (default) or run selected-release checks; smoke is deliberately small. #>
[CmdletBinding()]
param(
    [switch]$Run,
    [ValidateSet('smoke','online')][string]$Suite = 'smoke',
    [switch]$TestMap,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$ServerRoot = '',
    [string]$UserConfigRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games/KillingFloor2/KFGame/Config')
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $ServerRoot) { $ServerRoot = Join-Path $repo 'build/multiplayer/server' }
$selection = Get-Content -LiteralPath (Join-Path $repo 'build/multiplayer/current-release.json') -Raw | ConvertFrom-Json
if ($selection.release -notmatch '^KF2VR-Multiplayer-[0-9]{8}-[0-9]{6}$') { throw 'Invalid selected release.' }
$release = Join-Path $repo ('build/multiplayer/releases/' + $selection.release)
if ((Get-FileHash -LiteralPath (Join-Path $release 'release.json')).Hash -ne $selection.manifest_sha256) { throw 'Release manifest changed.' }
$arguments = @((Join-Path $repo 'tools/multiplayer/acceptance.py'), '--workspace', $repo,
    '--game-root', $GameRoot, '--server-root', $ServerRoot, '--user-config', $UserConfigRoot, '--suite', $Suite)
if ($Run) { $arguments += '--run' }
if ($TestMap) { $arguments += '--test-map' }
& (Join-Path $release 'runtime/python.exe') @arguments
if ($LASTEXITCODE -ne 0) { throw 'Online checks failed. Inspect the printed acceptance receipt; do not rerun blindly.' }
