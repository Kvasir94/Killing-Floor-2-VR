<# Review a chosen saved clip through normal LAN replication without re-recording. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ReleaseRoot,
    [Parameter(Mandatory=$true)][string]$Clip,
    [switch]$Run,
    [ValidateRange(0,2)][int]$CameraMode=0,
    [ValidateRange(0.25,30)][double]$CaptureIntervalSeconds=3,
    [ValidateRange(1,100)][int]$CaptureLimit=100,
    [string]$GameRoot='D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$ServerRoot='D:\KF2-VR\build\multiplayer\server',
    [string]$CacheRoot='D:\KF2-VR\build\workshop-cache',
    [string]$UserConfigRoot=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games/KillingFloor2/KFGame/Config')
)
$ErrorActionPreference='Stop'
$reviewRepo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$reviewRelease=[IO.Path]::GetFullPath($ReleaseRoot)
$reviewArguments=@((Join-Path $reviewRelease 'tools/multiplayer/session.py'),
    '--release',$reviewRelease,'--motion-clip',[IO.Path]::GetFullPath($Clip),
    '--game-root',$GameRoot,'--server-root',$ServerRoot,'--cache-root',$CacheRoot,
    '--user-config',$UserConfigRoot,'--output-root',(Join-Path $reviewRepo 'build/saved-network-motion-sessions'),
    '--clients','2','--native-replay','--server-adapter','--lan-no-voice',
    '--motion-camera-mode',"$CameraMode",'--motion-capture-interval',"$CaptureIntervalSeconds",
    '--motion-capture-limit',"$CaptureLimit",'--duration','10',
    '--client-startup-timeout','120','--startup-timeout','90','--port','18777','--query-port','38015')
if($Run){$reviewArguments+='--run'}
& (Join-Path $reviewRelease 'runtime/python.exe') -B @reviewArguments
if($LASTEXITCODE -ne 0){throw 'Saved clip review failed; inspect its receipt before another run.'}
