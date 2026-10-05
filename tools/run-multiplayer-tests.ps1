<# Legacy targeted diagnostic build/fixture route. Normal selected-release smoke
   uses test-online-play.ps1. Default prints a plan; -Run starts this diagnostic. #>
[CmdletBinding()]
param(
    [switch]$Run,
    [ValidateSet(1,2)][int]$Clients = 1,
    [switch]$TransportOnly,
    [switch]$NativeReplay,
    [switch]$VRControls,
    [switch]$RoomMovement,
    [switch]$RoomClamp,
    [switch]$RoomResidual,
    [switch]$Recovery,
    [switch]$Lifecycle,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$ServerRoot,
    [string]$CacheRoot,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $CacheRoot) { $CacheRoot = Join-Path $projectRoot 'build/workshop-cache' }
if (-not $ServerRoot) { $ServerRoot = Join-Path $projectRoot 'build/multiplayer/server' }
$sessionArgs = @((Join-Path $PSScriptRoot 'multiplayer/session.py'), '--run', '--clients', "$Clients",
    '--game-root', $GameRoot, '--server-root', $ServerRoot, '--cache-root', $CacheRoot, '--startup-timeout', '120', '--duration', '15', '--online-server')
if (-not $TransportOnly) { $sessionArgs += '--combat' }
if ($NativeReplay) {
    $sessionArgs += '--native-replay'
    if (-not $TransportOnly) { $sessionArgs += '--damage','--movement' }
}
if ($VRControls -or $RoomMovement -or $RoomClamp -or $RoomResidual) {
    if (-not $NativeReplay) { throw '-VRControls, -RoomMovement, -RoomClamp and -RoomResidual require -NativeReplay.' }
    if ($RoomClamp -and $RoomMovement) { throw '-RoomClamp refuses moves on purpose; run it without -RoomMovement.' }
    if ($RoomResidual -and ($RoomMovement -or $RoomClamp)) { throw '-RoomResidual needs a pawn nothing else is displacing.' }
    if ($VRControls) { $sessionArgs += '--vr-controls' }
    if ($RoomMovement) { $sessionArgs += '--room-movement' }
    if ($RoomClamp) { $sessionArgs += '--room-clamp' }
    if ($RoomResidual) { $sessionArgs += '--room-residual' }
}
if ($Recovery) {
    if (-not $NativeReplay -or $Clients -ne 2 -or $TransportOnly) {
        throw '-Recovery requires -NativeReplay -Clients 2 without -TransportOnly.'
    }
    $sessionArgs += '--recovery'
}
if ($Lifecycle) {
    if (-not $NativeReplay -or $Clients -ne 2 -or $TransportOnly -or $Recovery) {
        throw '-Lifecycle requires -NativeReplay -Clients 2 without -TransportOnly or -Recovery.'
    }
    $sessionArgs += '--lifecycle'
}
Write-Output 'Network test plan: offline evidence checks, isolated builds, password-protected dedicated server and local client(s).'
Write-Output "Clients: $Clients. Recorded input: enabled. Fire/reload: $(-not $TransportOnly). Native replay: $NativeReplay. Headset: unused."
Write-Output 'Clients start only after the owned server advertises VAC disabled. Processes and original configuration hashes are recorded.'
Write-Output 'Limits: compiler 120s; server startup 120s; client startup 120s; observation up to 50s; owned-process cleanup up to 10s each.'
if ($Recovery) { Write-Output 'Recovery: 18s pose-upload gap during combat/movement, observer reconnect up to 120s, abrupt driver disconnect detection up to 120s.' }
if ($Lifecycle) { Write-Output 'Lifecycle: two active clients; stock death/respawn, armor purchase and Outpost server travel; observation up to 300s.' }
Write-Output "Results: $(Join-Path $projectRoot 'build/multiplayer')"
if (-not $Run) {
    Write-Output 'Prepared plan only. Nothing compiled or tested. Add -Run after approving the test.'
    return
}
Push-Location $projectRoot
try {
    & $Python -m unittest discover -s (Join-Path $PSScriptRoot 'multiplayer') -p 'test_*.py' -v
    if ($LASTEXITCODE -ne 0) { throw 'Offline evidence checks failed; no game process launched.' }
    & (Join-Path $PSScriptRoot 'install-multiplayer-server.ps1') -ServerRoot $ServerRoot
    & (Join-Path $PSScriptRoot 'build-multiplayer-scripts.ps1') -GameRoot $GameRoot -TimeoutSeconds 120 -IncludeVRClient:$NativeReplay
    if ($NativeReplay) { & (Join-Path $PSScriptRoot 'build-multiplayer-native.ps1') }
    & $Python @sessionArgs
    if ($LASTEXITCODE -ne 0) { throw 'Network diagnostic did not pass; inspect its run.json and role logs.' }
} finally {
    Pop-Location
}
