<# Bounded synthetic controller/motion verification; never starts physical XR. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ReleaseRoot,
    [switch]$Run,
    [ValidateRange(0.25,30)][double]$CaptureIntervalSeconds=3,
    [ValidateRange(1,100)][int]$CaptureLimit=12,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$ServerRoot = 'D:\KF2-VR\build\multiplayer\server',
    [string]$CacheRoot = 'D:\KF2-VR\build\workshop-cache',
    [string]$UserConfigRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games/KillingFloor2/KFGame/Config'),
    [ValidateRange(10,300)][int]$ClientStartupTimeout = 120,
    [ValidateRange(10,300)][int]$HandshakeTimeout = 90
)
$ErrorActionPreference = 'Stop'
$testRepo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$testRelease = [IO.Path]::GetFullPath($ReleaseRoot)
$testArguments = @((Join-Path $testRelease 'tools/multiplayer/session.py'),
    '--release', $testRelease, '--game-root', $GameRoot, '--server-root', $ServerRoot,
    '--cache-root', $CacheRoot, '--user-config', $UserConfigRoot,
    '--output-root', (Join-Path $testRepo 'build/emulated-motion-sessions'),
    '--clients', '2', '--native-replay', '--server-adapter', '--motion-fixture', '--lan-no-voice',
    '--motion-capture-interval', "$CaptureIntervalSeconds", '--motion-capture-limit', "$CaptureLimit",
    '--duration', '45', '--client-startup-timeout', "$ClientStartupTimeout",
    '--startup-timeout', "$HandshakeTimeout", '--port', '18777', '--query-port', '38015')
if ($Run) { $testArguments += '--run' }
& (Join-Path $testRelease 'runtime/python.exe') -B @testArguments
if ($LASTEXITCODE -ne 0) { throw 'Emulated fixture failed; inspect its receipt and fix the concrete failure before another run.' }
