<# Start a playable VR session from a combined build. Close the game normally when finished;
   an owned background watcher restores temporary native files after exit. #>
[CmdletBinding()]
param(
    [string]$CombinedBuildRoot,
    [string]$NativeBuildRoot,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$UserConfigRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games/KillingFloor2/KFGame/Config'),
    [switch]$Stereo,
    [switch]$FrameTimings,
    [switch]$VmTimings,
    [ValidateRange(50,100)][int]$EyeRenderPercent=100,
    [switch]$CaptureEyes,
    [switch]$RenderDiagnostic,
    [switch]$NormalGame,
    [switch]$VrScreenEffects,
    [ValidatePattern('^KF-[A-Za-z0-9_-]+$')][string]$Map = 'KF-BurningParis',
    [ValidateRange(0,3)][int]$Difficulty = 0,
    [ValidateRange(0,2)][int]$GameLength = 0,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $CombinedBuildRoot) {
    foreach ($candidate in Get-ChildItem -LiteralPath (Join-Path $workspace 'build/combined-script-runs') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
        $recordPath = Join-Path $candidate.FullName 'run.json'
        if (-not (Test-Path -LiteralPath $recordPath)) { continue }
        $build = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        if ($build.schema -ne 'kf2vr/combined-script-build/2') { continue }
        if ($build.success -is [bool] -and $build.success -and -not $build.prepared_only -and
            $build.verification_ready -is [bool] -and $build.verification_ready) {
            $CombinedBuildRoot = $candidate.FullName; break
        }
    }
    if (-not $CombinedBuildRoot) { throw 'A completed combined Source and Engineer build is required (tools/build-combined-scripts.ps1).' }
}
& (Join-Path $PSScriptRoot 'test-combined.ps1') -CombinedBuildRoot $CombinedBuildRoot -NativeBuildRoot $NativeBuildRoot `
    -GameRoot $GameRoot -UserConfigRoot $UserConfigRoot -Native -Playable -Stereo:$Stereo -FrameTimings:$FrameTimings -CaptureEyes:$CaptureEyes `
    -RenderDiagnostic:$RenderDiagnostic -NormalGame:$NormalGame `
    -VrScreenEffects:$VrScreenEffects -PrepareOnly:$PrepareOnly -VmTimings:$VmTimings -EyeRenderPercent $EyeRenderPercent `
    -Map $Map -Difficulty $Difficulty -GameLength $GameLength
