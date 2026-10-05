<# Start a playable Portal Gun session. Close the game normally when finished;
   an owned background watcher restores temporary native files after exit. #>
[CmdletBinding()]
param(
    [Alias('CombinedBuildRoot')][string]$PortalBuildRoot,
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
    [switch]$EnablePortals,
    [switch]$VrScreenEffects,
    [ValidatePattern('^KF-[A-Za-z0-9_-]+$')][string]$Map = 'KF-BurningParis',
    [ValidateRange(0,3)][int]$Difficulty = 0,
    [ValidateRange(0,2)][int]$GameLength = 0,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $PortalBuildRoot) {
    foreach ($candidate in Get-ChildItem -LiteralPath (Join-Path $workspace 'build/combined-script-runs') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
        $recordPath = Join-Path $candidate.FullName 'run.json'
        if (-not (Test-Path -LiteralPath $recordPath)) { continue }
        $build = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        $candidatePortals = -not ($build.PSObject.Properties.Name -contains 'portals_enabled') -or [bool]$build.portals_enabled
        if ($candidatePortals -ne [bool]$EnablePortals) { continue }
        if ($build.success -is [bool] -and $build.success -and -not $build.prepared_only -and
            $build.verification_ready -is [bool] -and $build.verification_ready) {
            $PortalBuildRoot = $candidate.FullName; break
        }
    }
    if (-not $PortalBuildRoot) { throw 'A completed combined Source, Engineer and Portal build is required.' }
}
& (Join-Path $PSScriptRoot 'test-portal.ps1') -PortalBuildRoot $PortalBuildRoot -NativeBuildRoot $NativeBuildRoot `
    -GameRoot $GameRoot -UserConfigRoot $UserConfigRoot -Native -Playable -Stereo:$Stereo -FrameTimings:$FrameTimings -CaptureEyes:$CaptureEyes `
    -RenderDiagnostic:$RenderDiagnostic -NormalGame:$NormalGame -EnablePortals:$EnablePortals `
    -VrScreenEffects:$VrScreenEffects -PrepareOnly:$PrepareOnly -VmTimings:$VmTimings -EyeRenderPercent $EyeRenderPercent `
    -Map $Map -Difficulty $Difficulty -GameLength $GameLength
