<# Explicit 9mm physical-reload diagnostic. Preparation never launches game/server sessions. #>
[CmdletBinding()]
param(
    [switch]$Run,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$ServerRoot,
    [string]$UserConfigRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games/KillingFloor2/KFGame/Config'),
    [string]$OutputRoot
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$selection = Get-Content -LiteralPath (Join-Path $repo 'build/multiplayer/current-release.json') -Raw | ConvertFrom-Json
if ($selection.release -notmatch '^KF2VR-Multiplayer-[0-9]{8}-[0-9]{6}$') { throw 'Invalid selected release.' }
$release = Join-Path $repo ('build/multiplayer/releases/' + $selection.release)
$python = Join-Path $release 'runtime/python.exe'
if ((Get-FileHash -LiteralPath (Join-Path $release 'release.json')).Hash -ne $selection.manifest_sha256) {
    throw 'Selected release manifest changed.'
}
# Preparing the immutable selected payload is safe while another chat edits
# sources. Actual execution additionally requires the current-source guard.
if ($Run) {
    & $python (Join-Path $repo 'tools/multiplayer/release_state.py') --workspace $repo
    if ($LASTEXITCODE -ne 0) { throw 'Selected package/source verification failed.' }
}
if (-not $ServerRoot) { $ServerRoot = Join-Path $repo 'build/multiplayer/server' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $repo 'build/reload-replay/network-9mm' }
$arguments = @((Join-Path $release 'tools/multiplayer/session.py'), '--release', $release,
    '--physical-reload-9mm', '--game-root', $GameRoot, '--server-root', $ServerRoot,
    '--user-config', $UserConfigRoot, '--output-root', $OutputRoot,
    '--cache-root', (Join-Path $repo 'build/workshop-cache'), '--duration', '30')
if ($Run) { $arguments += '--run' }
& $python @arguments
if ($LASTEXITCODE -ne 0) { throw '9mm physical reload diagnostic failed; inspect the printed session receipt.' }
