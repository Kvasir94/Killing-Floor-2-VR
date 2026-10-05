<# Human launch entry. The final playtest receipt selects the exact checked
   build; a newer unfinished compiler output must not silently replace it. #>
[CmdletBinding()]
param([ValidateSet('Normal','Practice')][string]$Mode='Normal', [switch]$CaptureEyes, [switch]$FrameTimings,
    [switch]$VmTimings,
    [ValidateRange(50,100)][int]$EyeRenderPercent=100,
    # Comparison run: keep the screen-space/lens/grain effects the VR policy
    # normally disables. See docs/VR_STEREO_IMAGE_QUALITY.md.
    [switch]$VrScreenEffects)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$receiptPath = Join-Path $workspace 'build/playtest-current.json'
if (-not (Test-Path -LiteralPath $receiptPath)) {
    throw 'The new playtest build is still being prepared. Wait for the ready confirmation.'
}
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
if (-not $receipt.ready -or -not $receipt.build_root) { throw 'The playtest build is not ready.' }
$launcherRoot = $workspace
if ($receipt.PSObject.Properties.Name -contains 'launcher_root' -and $receipt.launcher_root) {
    $launcherRoot = [IO.Path]::GetFullPath($receipt.launcher_root)
}
$launcher = Join-Path $launcherRoot 'tools/launch-portal.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'The selected playtest launcher snapshot is missing.' }
$performanceOptions = @{}
if ($VmTimings) { $performanceOptions['VmTimings'] = $true }
if ($EyeRenderPercent -ne 100) { $performanceOptions['EyeRenderPercent'] = $EyeRenderPercent }
& $launcher -CombinedBuildRoot $receipt.build_root `
    -Stereo -FrameTimings:$FrameTimings -NormalGame:($Mode -eq 'Normal') -CaptureEyes:$CaptureEyes `
    -VrScreenEffects:$VrScreenEffects @performanceOptions
